# Fixes Audit — Session 2026-09-28

Status of every fix applied during the debugging session.

## Automated in Gitops (pushed)

| Fix | Files | Status |
|-----|-------|--------|
| VM `accessCredentials` for dynamic SSH keys | `templates/virtualmachine.yaml` | Done |
| SSH pubkey Secret template | `templates/secret-ssh-pubkey.yaml` (new) | Done |
| `sshKeySecretName` helper | `templates/_helpers.tpl` | Done |
| SELinux `setsebool -P virt_qemu_ga_manage_ssh on` in cloud-init | `templates/cloudinit-sandbox.yaml` | Done |
| Removed `ssh_authorized_keys` from cloud-init (conflicts with accessCredentials) | `templates/cloudinit-sandbox.yaml` | Done |
| `sshPublicKeySecret` value | `values.yaml` | Done |
| Governance `openai` profile: `inference_capable: true`, `endpoints: []` | `charts/governance-policy/profiles/openai.yaml` | Done |
| BOM provider: full model path `publishers/prelude-maas/models/glm-53-flash` | `charts/saw-bom/profiles/data-science/*/providers.yaml` | Done |
| BOM provider: `baseUrlSecretKey: base_url` | `charts/saw-bom/profiles/data-science/*/providers.yaml` | Done |
| `apply_bom.py`: `BASE_URL_CONFIG_KEYS`, `resolve_base_url()`, pass `--config OPENAI_BASE_URL` | `charts/saw-bom/scripts/apply_bom.py` | Done |
| `setup-bom-profiles.sh`: parse `baseUrlSecretKey`, export `PROV_*_BASE_URL`, mirror secrets to VM | `charts/openshell-saw/files/setup-bom-profiles.sh` | Done |

## Automated in Source Repo (needs push)

| Fix | File | Status |
|-----|------|--------|
| `oidc-login.sh`: PKCE for device-code flow (`code_challenge`/`code_verifier`) | `scripts/oidc-login.sh` | Changed locally, needs push |
| `oidc-login.sh`: removed `curl -f` from device-code token polling | `scripts/oidc-login.sh` | Changed locally, needs push |

## NOT YET AUTOMATED — needs fixing

| Fix | Impact | Suggested Fix |
|-----|--------|---------------|
| **Gateway service not enabled persistently** — after VM restart, `openshell-gateway.service` stays down because the setup Job starts but doesn't `enable` it | Gateway unreachable after any VM restart | Add `systemctl --user enable openshell-gateway` to the cloud-init `runcmd` or the setup Job's SSH phase |
| **Missing `logSerialConsole: true`** in VM spec | No serial console logs in virt-launcher pod for debugging | Add `logSerialConsole: true` under `spec.template.spec.domain.devices` in `virtualmachine.yaml` |
| **ClusterRole/Binding names not namespace-qualified** — `scc-rolebinding`, `clusterrole-registry`, `rolebinding-keycloak-admin` use bare release name | Multi-SAW deployments overwrite each other's RBAC | Qualify names with `{{ .Release.Namespace }}` like the source chart |
| **Missing OIDC roles in gateway.toml** — no `roles_claim`, `admin_role`, `user_role` | All authenticated users get the same access level | Add role config to the gateway.toml section in `cloudinit-sandbox.yaml` |
| **Missing `rolebinding-golden-image.yaml`** template | CDI cross-namespace DataVolume clone fails | Copy template from source chart |
| **mTLS not always enabled** — only set when OIDC is configured | In-VM installer can't authenticate without OIDC | Always set `OPENSHELL_ENABLE_MTLS_AUTH=true` in `cloudinit-sandbox.yaml` |
