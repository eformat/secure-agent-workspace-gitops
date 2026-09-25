#!/bin/bash
# One-stop bootstrap for ALL non-optional values:
#   1. derives the cluster domain from the connected cluster (oc)
#   2. fetches the vault root token from the vault-init secret
#   3. port-forwards the vault service (no route/DNS needed)
#   4. generates the sandbox ssh keypair if missing
#   5. seeds vault (KV v2) with ssh + inference + web-search
#   6. writes the derived cluster domain into the site values file
#
# Keys match the ExternalSecret remoteRefs in charts/pattern-secrets
# (vaultPrefix: secret/data/hub).
#
# Env overrides (all optional):
#   VAULT_TOKEN          root token (auto-fetched from vault-init secret)
#   VAULT_ADDR           vault API url (auto port-forward to svc/vault)
#   CLUSTER_DOMAIN       apps domain (auto-derived from oc)
#   SSH_KEY_PATH         (default ~/.generated-ssh-keys/sandbox-ssh)
#   GEMINI_API_KEY_PATH  (default ~/.gemini-api-key)
#   INFERENCE_PROVIDER   (default gemini)
#   INFERENCE_MODEL      (default gemini-2.5-flash)
set -euo pipefail

command -v vault >/dev/null 2>&1 || { echo "vault CLI required but not installed. Aborting." >&2; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "oc CLI required but not installed. Aborting." >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SITE_VALUES="${REPO_DIR}/applications/openshell-saw/overlay/values-site.yaml"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.generated-ssh-keys/sandbox-ssh}"
GEMINI_API_KEY_PATH="${GEMINI_API_KEY_PATH:-$HOME/.gemini-api-key}"
INFERENCE_PROVIDER="${INFERENCE_PROVIDER:-gemini}"
INFERENCE_MODEL="${INFERENCE_MODEL:-gemini-2.5-flash}"

# --- seed-vault.yaml (gitignored real values) overrides defaults ---
SEED_YAML="${REPO_DIR}/secrets/seed-vault.yaml"
if [ -f "$SEED_YAML" ]; then
  echo "Reading seed values from $SEED_YAML"
  eval "$(python3 - "$SEED_YAML" <<'PYEOF'
import sys, yaml, shlex
d = yaml.safe_load(open(sys.argv[1]))
inf = d.get("inference", {}) or {}
ws = d.get("web_search", {}) or {}
ssh = d.get("ssh", {}) or {}
def out(k, v):
    if v is not None and str(v) != "":
        print(f"{k}={shlex.quote(str(v))}")
out("SEED_INF_PROVIDER", inf.get("provider"))
out("SEED_INF_MODEL", inf.get("model"))
out("SEED_INF_API_KEY", inf.get("api_key"))
out("SEED_INF_API_KEY_PATH", inf.get("api_key_path"))
out("SEED_INF_BASE_URL", inf.get("base_url"))
out("SEED_WS_PROVIDER", ws.get("provider"))
out("SEED_WS_API_KEY", ws.get("api_key"))
out("SEED_SSH_KEY_PATH", ssh.get("private_key_path"))
out("SEED_SSH_PUB_PATH", ssh.get("public_key_path"))
PYEOF
)" || { echo "failed to parse $SEED_YAML" >&2; exit 1; }
  [ -n "${SEED_INF_PROVIDER:-}" ] && INFERENCE_PROVIDER="$SEED_INF_PROVIDER"
  [ -n "${SEED_INF_MODEL:-}" ] && INFERENCE_MODEL="$SEED_INF_MODEL"
fi
INFERENCE_BASE_URL="${INFERENCE_BASE_URL:-${SEED_INF_BASE_URL:-}}"

# --- 1. derive cluster domain ---
if [ -z "${CLUSTER_DOMAIN:-}" ]; then
  CLUSTER_DOMAIN="$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  [ -n "$CLUSTER_DOMAIN" ] || { echo "could not derive cluster domain (oc get ingress.config.openshift.io cluster). Set CLUSTER_DOMAIN env." >&2; exit 1; }
fi
echo "Cluster domain: $CLUSTER_DOMAIN"

# --- 2. vault root token ---
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(oc get secret vault-init -n vault -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || true)"
  [ -n "$VAULT_TOKEN" ] || { echo "could not fetch VAULT_TOKEN from secret vault-init -n vault (is the tree converged?). Set VAULT_TOKEN env." >&2; exit 1; }
  echo "VAULT_TOKEN fetched from vault-init secret"
fi
export VAULT_TOKEN

# --- 3. vault address (auto port-forward) ---
PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT
if [ -z "${VAULT_ADDR:-}" ]; then
  echo "Port-forwarding svc/vault (vault namespace) to localhost:8200"
  oc -n vault port-forward svc/vault 8200:8200 >/dev/null 2>&1 &
  PF_PID=$!
  VAULT_ADDR="https://127.0.0.1:8200"
  VAULT_SKIP_VERIFY=true
  for i in $(seq 1 15); do
    vault status >/dev/null 2>&1 && break
    sleep 1
  done
fi
export VAULT_ADDR
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"

# --- 4. ssh keypair ---
SSH_PRIV="${SEED_SSH_KEY_PATH:-$SSH_KEY_PATH}"
SSH_PUB="${SEED_SSH_PUB_PATH:-$SSH_KEY_PATH.pub}"
if [ ! -f "$SSH_PRIV" ]; then
  mkdir -p "$(dirname "$SSH_PRIV")"
  ssh-keygen -t ed25519 -f "$SSH_PRIV" -N "" -C "openshell-sandbox" >/dev/null
  echo "SSH keypair generated at $SSH_PRIV"
fi

# --- 5. seed vault ---
# inference api key: inline value (seed-vault.yaml) or file path
INF_API_KEY="${SEED_INF_API_KEY:-}"
if [ -z "$INF_API_KEY" ] && [ -n "${SEED_INF_API_KEY_PATH:-}" ]; then
  INF_API_KEY="$(cat "${SEED_INF_API_KEY_PATH/#\~/$HOME}")"
fi
if [ -z "$INF_API_KEY" ]; then
  INF_API_KEY_PATH="${GEMINI_API_KEY_PATH/#\~/$HOME}"
  [ -f "$INF_API_KEY_PATH" ] || { echo "required file missing: $INF_API_KEY_PATH (or set api_key in seed-vault.yaml)" >&2; exit 1; }
  INF_API_KEY="$(cat "$INF_API_KEY_PATH")"
fi

WS_PROVIDER="${SEED_WS_PROVIDER:-none}"
WS_API_KEY="${SEED_WS_API_KEY:-}"

echo "Seeding vault at $VAULT_ADDR (secret/hub/*)"

vault kv put secret/hub/ssh \
  private_key=@"$SSH_PRIV" \
  public_key=@"$SSH_PUB"

vault kv put secret/hub/inference \
  provider="$INFERENCE_PROVIDER" \
  model="$INFERENCE_MODEL" \
  api_key="$INF_API_KEY" \
  base_url="$INFERENCE_BASE_URL"

if [ -n "$WS_API_KEY" ]; then
  vault kv put secret/hub/web-search \
    provider="$WS_PROVIDER" \
    api_key="$WS_API_KEY"
else
  vault kv put secret/hub/web-search \
    provider="$WS_PROVIDER"
fi

# --- 6. write derived cluster domain into the site values file (commit the result) ---
if grep -q "CLUSTER_DOMAIN_PLACEHOLDER" "$SITE_VALUES" 2>/dev/null; then
  sed -i "s|CLUSTER_DOMAIN_PLACEHOLDER|${CLUSTER_DOMAIN}|" "$SITE_VALUES"
  echo "Updated $SITE_VALUES with cluster domain (commit this change)."
fi

echo "Done. ExternalSecrets in pattern-secrets will pull these at runtime."
