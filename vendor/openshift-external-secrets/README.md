# openshift-external-secrets

![Version: 0.0.4](https://img.shields.io/badge/Version-0.0.4-informational?style=flat-square)

A Helm chart to set up the Openshift External Secrets Operator

## Notable changes

v0.0.4: Add vault.externalAddress to allow configuration of separate, unmanaged vault

## Using a completely external Vault

Use this when HashiCorp Vault is **not** deployed by Validated Patterns on the hub (for example a shared corporate Vault or a cluster-external service).

1. **ClusterSecretStore backend** – Keep `global.secretStore.backend` as `vault` (or omit it; the chart defaults to Vault).

2. **Vault API URL** – Set `ocpExternalSecrets.vault.externalAddress` to the reachable HTTPS base URL of your Vault (same value you would put in `spec.provider.vault.server`), for example `https://vault.example.corp:8200`. When this is empty, the chart targets the framework hub route `vault-vault.<global.hubClusterDomain>` instead.

3. **KV engine** – Optional. Under `ocpExternalSecrets.vault.external`, set `kvPath` and/or `kvVersion` if your mount is not the default path `secret` or not KV v2. These keys are **only** read when `externalAddress` is non-empty; otherwise they are ignored.

4. **Arbitrary external auth provider** – When `ocpExternalSecrets.vault.externalAddress` is non-empty, you can provide `ocpExternalSecrets.vault.external.auth` to inject any supported ESO Vault auth block directly into `spec.provider.vault.auth` (for example AppRole, token, JWT/OIDC, LDAP, cert). This is the recommended path when your external Vault does not use Kubernetes auth from this chart.

5. **Kubernetes auth on the external Vault** – If you do not set `ocpExternalSecrets.vault.external.auth`, the chart uses Kubernetes auth. On the Vault side, configure a Kubernetes auth mount and role that trust the External Secrets Operator service account (`ocpExternalSecrets.rbac.serviceAccount` in this chart). In values, you can pin the store to that Vault configuration by setting **both** `ocpExternalSecrets.vault.external.kubernetesMountPath` and `ocpExternalSecrets.vault.external.kubernetesRole`. If either is left empty, the chart falls back to the usual hub/spoke auth fields (`vault.mountPath`, `rbac.rolename`, or spoke `global.clusterDomain`), which may not match your external Vault and should be overridden for a fully external setup.

6. **External Kubernetes auth token Secret reference** – When `ocpExternalSecrets.vault.externalAddress` is non-empty and you use the Kubernetes auth fallback path, you must set:
   - `ocpExternalSecrets.vault.external.secretRef.name`
   - `ocpExternalSecrets.vault.external.secretRef.namespace`
   - `ocpExternalSecrets.vault.external.secretRef.key`

   These values are used directly in `spec.provider.vault.auth.kubernetes.secretRef` and should point to an existing Secret that contains the JWT token expected by your external Vault Kubernetes auth mount. They are ignored when `ocpExternalSecrets.vault.external.auth` is set.

7. **TLS / CA** – If Vault presents a certificate signed by a CA that is not the cluster default, keep `ocpExternalSecrets.caProvider.enabled` true and point `hostCluster` or `clientCluster` at a ConfigMap or Secret that holds the PEM for that CA, depending on whether you render this chart on the hub or a spoke.

8. **Special Note** – The patterns framework will be unable to manage authentication, policy or inject secrets into a vault that it does not manage. In such cases, set `global.secretLoader.disabled` to `true` (in `values-global.yaml`) to prevent the secret loader from running locally during the `make install` phase.

Example fragment:

```yaml
global:
  secretStore:
    backend: vault

ocpExternalSecrets:
  vault:
    externalAddress: "https://vault.example.corp:8200"
    external:
      kvPath: "kv/my-team"
      kvVersion: "v2"
      auth:
        appRole:
          path: "approle"
          roleRef:
            name: "vault-approle"
            key: "role-id"
          secretRef:
            name: "vault-approle"
            key: "secret-id"
  caProvider:
    enabled: true
    hostCluster:
      type: Secret
      name: corp-vault-ca
      key: ca.crt
      namespace: external-secrets
```

<!-- prettier-ignore-start -->
## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| clusterGroup.applications | object | `{}` |  |
| global | object | depends on the individual settings | The global namespace containes some globally used variables used in patterns |
| global.clusterDomain | string | `"foo.example.com"` | The DNS entry for the cluster the chart is being rendered on |
| global.hubClusterDomain | string | `"hub.example.com"` | The DNS entry for the hub cluster |
| global.secretStore.backend | string | `"vault"` | The backend of ESO being used in the pattern |
| ocpExternalSecrets | object | depends on the individual settings | Dictionary of all the settings to configure this chart |
| ocpExternalSecrets.caProvider | object | depends on the individual settings | This controls how ESO connects to vault and it allows to specify where the public key of the CA that signed the API endpoint to talke to the vault |
| ocpExternalSecrets.caProvider.clientCluster | object | depends on the individual settings | Where to fetch the CA that signed the vault API endpoint when on a spoke cluster |
| ocpExternalSecrets.caProvider.clientCluster.key | string | `"hub-kube-root-ca.crt"` | Key of object where the CA is stored |
| ocpExternalSecrets.caProvider.clientCluster.name | string | `"hub-ca"` | Name of object where the CA is stored |
| ocpExternalSecrets.caProvider.clientCluster.namespace | string | `"external-secrets"` | Namespace of object where the CA is stored |
| ocpExternalSecrets.caProvider.clientCluster.type | string | `"Secret"` | Type of object where the CA is stored |
| ocpExternalSecrets.caProvider.enabled | bool | `true` | When set to true this uses a custom CA to talk to vault |
| ocpExternalSecrets.caProvider.hostCluster | object | depends on the individual settings | Where to fetch the CA that signed the vault API endpoint when on the hub cluster |
| ocpExternalSecrets.caProvider.hostCluster.key | string | `"ca.crt"` | Key of object where the CA is stored |
| ocpExternalSecrets.caProvider.hostCluster.name | string | `"kube-root-ca.crt"` | Name of object where the CA is stored |
| ocpExternalSecrets.caProvider.hostCluster.namespace | string | `"external-secrets"` | Namespace of object where the CA is stored |
| ocpExternalSecrets.caProvider.hostCluster.type | string | `"ConfigMap"` | Type of object where the CA is stored |
| ocpExternalSecrets.kubernetes | object | depends on the individual settings | Settings relevant when using the kubernetes backend |
| ocpExternalSecrets.kubernetes.remoteNamespace | string | `"validated-patterns-secrets"` | The remote namespace used in the ClusterSecretStore |
| ocpExternalSecrets.kubernetes.server.url | string | `"https://kubernetes.default"` | The URL used in the ClusterSecretStore |
| ocpExternalSecrets.rbac.rolename | string | `"hub-role"` | The name of the vault role when connecting to the vault from the hub |
| ocpExternalSecrets.rbac.serviceAccount | object | depends on the individual settings | ServiceAccount configuration for external secrets |
| ocpExternalSecrets.rbac.serviceAccount.name | string | `"ocp-external-secrets"` | The name of the service account used by external secrets |
| ocpExternalSecrets.rbac.serviceAccount.namespace | string | `"external-secrets"` | The namespace where the service account is created |
| ocpExternalSecrets.vault | object | depends on the individual settings | Some vault configuration entries |
| ocpExternalSecrets.vault.external | object | depends on the individual settings | Settings below apply only when `externalAddress` is non-empty (ignored for framework-managed hub Vault). |
| ocpExternalSecrets.vault.external.auth | object | `{}` | Arbitrary auth stanza rendered directly into `spec.provider.vault.auth` when `externalAddress` is non-empty. Use this for non-Kubernetes auth methods (for example AppRole, JWT/OIDC, token, LDAP, cert). When set, this takes precedence over `kubernetesMountPath`/`kubernetesRole` and `secretRef`. |
| ocpExternalSecrets.vault.external.kubernetesMountPath | string | `""` | Vault Kubernetes auth mount path for the external Vault. Must be set together with `kubernetesRole`; if either is empty, hub/spoke auth from this chart is used instead. |
| ocpExternalSecrets.vault.external.kubernetesRole | string | `""` | Vault Kubernetes auth role for the external Vault. Must be set together with `kubernetesMountPath`. |
| ocpExternalSecrets.vault.external.kvPath | string | `""` | KV mount path segment for `spec.provider.vault.path` (e.g. `secret` or a team-specific engine). Empty keeps the default `secret`. |
| ocpExternalSecrets.vault.external.kvVersion | string | `""` | KV version (`v1` or `v2`). Empty keeps the default `v2`. |
| ocpExternalSecrets.vault.external.secretRef | object | depends on the individual settings | Secret reference used for `spec.provider.vault.auth.kubernetes.secretRef` when `externalAddress` is non-empty. All fields are required in that case and should point to an existing Secret holding the Kubernetes auth JWT. Ignored when `external.auth` is provided. |
| ocpExternalSecrets.vault.external.secretRef.key | string | `""` | Secret key containing the JWT token for external Vault Kubernetes auth. Required when `externalAddress` is non-empty. |
| ocpExternalSecrets.vault.external.secretRef.name | string | `""` | Secret name for external Vault Kubernetes auth. Required when `externalAddress` is non-empty. |
| ocpExternalSecrets.vault.external.secretRef.namespace | string | `""` | Namespace of the secret for external Vault Kubernetes auth. Required when `externalAddress` is non-empty. |
| ocpExternalSecrets.vault.externalAddress | string | `""` | If non-empty, sets the Vault API URL on the ClusterSecretStore (`spec.provider.vault.server`), for example an external Vault reachable at an HTTPS URL you provide. When empty, the chart uses the in-cluster hub pattern `vault-vault` plus `global.hubClusterDomain` (no separate parameter required). |
| ocpExternalSecrets.vault.mountPath | string | `"hub"` | The vault secrets' path when connecting to it from the hub |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
<!-- prettier-ignore-end -->
