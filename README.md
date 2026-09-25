# secure-agent-workspace-gitops

ArgoCD app-of-apps monorepo for the secure-agent-workspace pattern. Replaces the
Validated Patterns imperative installer (rhvp.cluster_utils / ansible / helm --set
juggling) with declarative sync-wave ordered ArgoCD Applications.

Layout follows the rhoai-cluster-pool conventions:

    app-of-apps/root-application.yaml   # root Application (directory generator -> app-of-apps/hub)
    app-of-apps/hub/*.yaml              # child Application manifests, sync-wave annotated
    applications/<name>/                # kustomize per app: base (+ overlay where site-specific)
    bootstrap/                          # one-time RBAC applied by CI/human before bootstrap
    charts/                             # pattern helm charts (moved from secure-agent-workspace)
    vendor/                             # vendored framework charts (no remote chart sources)
    secrets/                            # seed-vault template (real values gitignored)

## Prerequisites

- OpenShift cluster with a default StorageClass
- Red Hat GitOps operator installed (openshift-gitops instance exists)
- `oc` logged into the cluster (kubeadmin or a user that can apply bootstrap/)
- `vault` CLI on the laptop for the one-time vault seed
- git remote set (`make bootstrap` resolves repoURL from `git remote get-url origin`)

## Deploy

### 1. Bootstrap

Applies the traced installer RBAC + the root Application:

    make bootstrap

### 2. Wait for the tree to converge

    make wait

Sync waves order everything; the root Application self-heals and prunes:

    w0 namespaces -> w1 subscriptions -> w2 vault -> w3 vault-config
    -> w4 eso -> w5 openshift-cnv -> w6 pattern-secrets
    -> w7 keycloak + governance -> w8 saw-bom -> w9 openshell-saw

Convergence means the vault-config Job has initialized + unsealed vault and
configured kubernetes auth (role `hub-role` bound to the ESO SA).

### 3. Seed vault (one-stop)

`seed-vault` is self-sufficient - it derives the cluster domain from the
connected cluster (`oc get ingress.config.openshift.io cluster`), fetches the
vault root token from the `vault-init` secret, port-forwards the vault service
(no route/DNS needed), generates the sandbox ssh keypair if missing, seeds
vault (ssh + inference + web-search), and writes the derived cluster domain
into `applications/openshell-saw/overlay/values-site.yaml` (commit that change):

    make seed-vault

The only file it cannot create is the inference API key at ~/.gemini-api-key.
Env overrides: `VAULT_TOKEN`, `VAULT_ADDR`, `CLUSTER_DOMAIN`, `SSH_KEY_PATH`,
`GEMINI_API_KEY_PATH`, `INFERENCE_PROVIDER`, `INFERENCE_MODEL`.

### 4. Verify

ESO ExternalSecrets pull the seeded secrets on their next refresh
(pattern-secrets refreshInterval: 15s):

    oc get externalsecrets -A
    oc get applications -n openshift-gitops

## Values

### MUST be set (deployment-blocking)

| Value | Where | Why |
|---|---|---|
| git remote pushed + set | `git remote get-url origin` | repoURL for all Applications; `REPO_URL_PLACEHOLDER` is resolved from it at `make bootstrap` |
| `global.clusterDomain` | `applications/openshell-saw/overlay/values-site.yaml` | chart helpers resolve the OIDC issuer URL and gateway route host from it; derived from the connected cluster by `make seed-vault` - commit the updated file |
| inference API key file | `~/.gemini-api-key` | seed-vault fails if missing (the one value it cannot create) |
| OCP cluster + default StorageClass | cluster | storage is required by the workload charts |
| Red Hat GitOps operator | cluster | provides the `openshift-gitops` instance the root Application lives in |

### Optional variables (defaults exist)

| Value | Where | Default | Notes |
|---|---|---|---|
| `accessControl.owner` | values-site.yaml | `alice` (fallback in `run-setup.sh`) | set explicitly in the overlay |
| `nemoclawCliImage` | openshell-saw chart | `quay.io/rh-ai-quickstart/nemoclaw-cli:latest` | chart default |
| `job.waitForSecrets` | values-site.yaml | `false` | set `true` when secrets flow via ESO |
| `job.hostAliases` | values-site.yaml | unset | cluster-specific LB VIP workaround (workshop cluster) |
| `dashboard.insecureSkipIssuerTlsVerify` | values-site.yaml | `false` | cluster-specific TLS issuer workaround |
| `dashboard.keycloakNamespace` | openshell-saw chart | `.Release.Namespace` | namespace holding the `<keycloakName>-initial-admin` secret |
| `keycloak.hostname` | openshell-keycloak chart | unset | RHBK operator computes the route when unset |
| `oidc.keycloakName` | openshell-saw chart | `openshell-keycloak` | |
| `oidc.realm` | openshell-saw chart | `openshell` | realm name for OIDC issuer URL |
| `oidc.clientId` | openshell-saw chart | `openshell-cli` | |
| `oidc.token` | openshell-saw chart | unset | token path when Keycloak is external |
| `VAULT_TOKEN` | seed-vault | auto-fetched from `vault-init` secret | override for out-of-band seeding |
| `VAULT_ADDR` | seed-vault | auto port-forward to `svc/vault` (localhost:8200) | override for route/external access |
| `CLUSTER_DOMAIN` | seed-vault | auto-derived from `oc get ingress.config.openshift.io cluster` | override for disconnected clusters |
| `VAULT_SKIP_VERIFY` | seed-vault | `true` with the auto port-forward | serving cert is for in-cluster DNS |
| `SSH_KEY_PATH` | seed-vault | `~/.generated-ssh-keys/sandbox-ssh` | |
| `GEMINI_API_KEY_PATH` | seed-vault | `~/.gemini-api-key` | |
| `INFERENCE_PROVIDER` / `INFERENCE_MODEL` | seed-vault | `gemini` / `gemini-2.5-flash` | |
| `web-search.provider` | seed-vault | `none` | |
| `ARGO_NS` / `ROOT_APP` / `REPO_URL` | Makefile | `openshift-gitops` / `secure-agent-workspace` / git remote | |
| `targetRevision` | app-of-apps | `main` | branch ArgoCD tracks |
| ESO chart values | `applications/eso/base/values.yaml` | see file | `externalAddress`, secretRef, caProvider - baked in; tune only for an external vault |
| vault-config image / ttl | `applications/vault-config/base/job.yaml` | `hashicorp/vault:1.20` / `600s` | |

## Teardown

    make destroy            # deletes the root Application (prune cascades to children)
    make destroy-olm        # deletes the OLM subscriptions left after prune

## Notes

- repoURL in app-of-apps/root-application.yaml assumes
  https://github.com/eformat/secure-agent-workspace-gitops.git - adjust if the
  remote differs.
- The pattern repo (secure-agent-workspace) keeps app source; its charts moved here.
- Status: statically verified (kustomize builds for all 11 app dirs, sync-wave
  ordering, YAML lint, parity vs the empirical installer run). First deploy
  pending - waiting on a test cluster.
