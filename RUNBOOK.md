# SAW Deployment Runbook

Manual commands for deploying and operating a Secure Agent Workspace on a cluster
with a pre-existing Keycloak and ArgoCD-managed gitops.

## Prerequisites

```bash
export KEYCLOAK_NS=openshell-agents
export SAW_NS=openshell-agents
export OPENSHELL_SAW_NAME=openshell-saw
```

## 1. Seed Vault with Secrets

Edit `secrets/seed-vault.yaml` with your provider credentials:

```yaml
inference:
  provider: openai
  model: publishers/prelude-maas/models/glm-53-flash
  api_key: <your-api-key>
  base_url: https://maas.apps.ocp.cloud.rhai-tmm.dev/v1
```

Then seed:

```bash
bash secrets/seed-vault.sh
```

## 2. Login (Device Code Flow)

Use device-code flow when the bastion and browser are on different machines
(the default browser flow redirects to localhost on the bastion, which the
laptop browser can't reach):

```bash
make login OIDC_FLOW=device-code KEYCLOAK_NS=openshell-agents
```

## 3. Configure the Gateway

The `make openshell-saw-configure-gateway` target triggers a browser auth
flow that won't work from a remote bastion. Instead, configure manually:

```bash
# Extract CA cert
GW_CONFIG_DIR="$HOME/.config/openshell/gateways/${OPENSHELL_SAW_NAME}"
mkdir -p "$GW_CONFIG_DIR/mtls"
NS=$SAW_NS VM_NAME=$OPENSHELL_SAW_NAME SSH_KEY_PATH=$HOME/.generated-ssh-keys/sandbox-ssh \
  OUT_FILE="$GW_CONFIG_DIR/mtls/ca.crt" \
  scripts/extract-gateway-ca.sh

# Extract mTLS client cert/key from the VM
SAW_NS=$SAW_NS VM_NAME=$OPENSHELL_SAW_NAME \
  scripts/openshell-saw-vm-ssh.sh \
  'cat ~/.local/state/openshell/tls/client/tls.crt' > "$GW_CONFIG_DIR/mtls/tls.crt"

SAW_NS=$SAW_NS VM_NAME=$OPENSHELL_SAW_NAME \
  scripts/openshell-saw-vm-ssh.sh \
  'cat ~/.local/state/openshell/tls/client/tls.key' > "$GW_CONFIG_DIR/mtls/tls.key"
chmod 600 "$GW_CONFIG_DIR/mtls/tls.key"

# Write gateway metadata (skip the built-in browser auth)
GW_URL=$(oc get route ${OPENSHELL_SAW_NAME}-gateway -n $SAW_NS -o jsonpath='https://{.spec.host}')
OIDC_ISSUER="https://$(scripts/keycloak-host.sh $KEYCLOAK_NS)/realms/openshell"
cat > "$GW_CONFIG_DIR/metadata.json" << EOF
{
  "name": "${OPENSHELL_SAW_NAME}",
  "gateway_endpoint": "${GW_URL}",
  "is_remote": true,
  "gateway_port": 0,
  "auth_mode": "oidc",
  "oidc_issuer_url": "${OIDC_ISSUER}",
  "oidc_client_id": "openshell-cli"
}
EOF

openshell gateway select $OPENSHELL_SAW_NAME
```

## 4. Verify

```bash
openshell sandbox list
openshell workspace list
```

## 5. Launch the TUI

The `openshell sandbox exec` and `openshell sandbox connect` sessions run in
an isolated network namespace that cannot reach the openclaw-gateway websocket
on `127.0.0.1:18789`. Use `openshell sandbox exec` to start the gateway in
the background, then launch the TUI in the same session:

```bash
openshell sandbox exec -n notebook --tty -- bash -c '
export OPENCLAW_HOME=/sandbox SQLITE_TMPDIR=/sandbox/.openclaw/state \
  TMPDIR=/sandbox/.openclaw/state OPENCLAW_NIX_MODE=0 TERM=xterm-256color
nohup openclaw gateway run --allow-unconfigured --bind loopback --port 18789 \
  > /tmp/openclaw-gateway.log 2>&1 &
sleep 10
exec openclaw tui'
```

## 6. Re-run the Setup Job

After changing gitops values (provider config, BOM profiles, governance
profiles), delete the completed Job so ArgoCD recreates it:

```bash
oc delete job openshell-saw-setup -n $SAW_NS
# ArgoCD auto-sync will recreate the Job within ~3 minutes.
# Or force sync:
# argocd app sync 09-openshell-saw
```

## 7. Update the Provider Base URL

If the setup Job doesn't set `OPENAI_BASE_URL` on the provider (older
gitops chart without the `baseUrlSecretKey` fix), set it manually:

```bash
openshell provider update openai \
  --config "OPENAI_BASE_URL=https://maas.apps.ocp.cloud.rhai-tmm.dev/v1"
```

## 8. Start the Gateway After VM Restart

The gitops chart's setup Job starts the gateway service but doesn't enable
it persistently. After a VM restart:

```bash
SAW_NS=$SAW_NS VM_NAME=$OPENSHELL_SAW_NAME \
  scripts/openshell-saw-vm-ssh.sh \
  'systemctl --user enable --now openshell-gateway'
```
