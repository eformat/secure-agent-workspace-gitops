#!/bin/sh
set -eu

K8S_API="https://kubernetes.default.svc"
SA_TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_CA="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
INIT_SECRET="vault-init"
BOUND_SA="ocp-external-secrets"
BOUND_NS="external-secrets"

k8s_token() {
  cat "$SA_TOKEN_FILE"
}

k8s_get_secret() {
  wget -q --ca-certificate="$SA_CA" \
    --header="Authorization: Bearer $(k8s_token)" \
    -O- "$K8S_API/api/v1/namespaces/vault/secrets/$INIT_SECRET" 2>/dev/null || true
}

k8s_create_secret() {
  _root_token="$1"
  _unseal_key="$2"
  _data="{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"$INIT_SECRET\",\"namespace\":\"vault\"},\"stringData\":{\"root_token\":\"$_root_token\",\"unseal_key\":\"$_unseal_key\"}}"
  wget -q --ca-certificate="$SA_CA" \
    --header="Authorization: Bearer $(k8s_token)" \
    --header="Content-Type: application/json" \
    --post-data="$_data" -O- \
    "$K8S_API/api/v1/namespaces/vault/secrets" > /dev/null
}

k8s_replace_secret() {
  _rv="$1"
  _root_token="$2"
  _unseal_key="$3"
  _data="{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"$INIT_SECRET\",\"namespace\":\"vault\",\"resourceVersion\":\"$_rv\"},\"stringData\":{\"root_token\":\"$_root_token\",\"unseal_key\":\"$_unseal_key\"}}"
  wget -q --ca-certificate="$SA_CA" \
    --header="Authorization: Bearer $(k8s_token)" \
    --header="Content-Type: application/json" \
    --post-data="$_data" -O- \
    "$K8S_API/api/v1/namespaces/vault/secrets/$INIT_SECRET" > /dev/null
}

extract_init_field() {
  _field="$1"
  _b64=$(printf '%s' "$2" | sed -n "s/.*\"$_field\":\"\\([^\"]*\\)\".*/\\1/p")
  [ -n "$_b64" ] || { echo "field $_field not found in $INIT_SECRET" >&2; exit 1; }
  printf '%s' "$_b64" | base64 -d
}

echo "Waiting for vault api at $VAULT_ADDR"
i=0
# vault status exits non-zero for uninitialized/sealed vaults - accept any
# response as long as the API returned JSON
until vault status -format=json > /tmp/status.json 2>/dev/null || [ -s /tmp/status.json ]; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "vault api unreachable after 60 attempts" >&2
    exit 1
  fi
  sleep 5
done

INITIALIZED=$(grep -o '"initialized":[a-z]*' /tmp/status.json | cut -d: -f2)
SEALED=$(grep -o '"sealed":[a-z]*' /tmp/status.json | cut -d: -f2)

if [ "$INITIALIZED" != "true" ]; then
  echo "Initializing vault (1 key share, 1 threshold)"
  vault operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/init.json
  _root=$(sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p' /tmp/init.json)
  _key=$(sed -n 's/.*"unseal_keys_b64":\["\([^"]*\)".*/\1/p' /tmp/init.json)
  if k8s_get_secret | grep -q '"kind":"Secret"'; then
    _rv=$(k8s_get_secret | sed -n 's/.*"resourceVersion":"\([^"]*\)".*/\1/p')
    k8s_replace_secret "$_rv" "$_root" "$_key"
  else
    k8s_create_secret "$_root" "$_key"
  fi
  SEALED=true
fi

if [ "$SEALED" = "true" ]; then
  echo "Vault sealed - unsealing from $INIT_SECRET"
  SECRET_JSON=$(k8s_get_secret)
  UNSEAL_KEY=$(extract_init_field unseal_key "$SECRET_JSON")
  vault operator unseal "$UNSEAL_KEY" > /dev/null
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
  SECRET_JSON=$(k8s_get_secret)
  VAULT_TOKEN=$(extract_init_field root_token "$SECRET_JSON")
  export VAULT_TOKEN
fi

echo "Enabling kubernetes auth at path 'hub' (idempotent)"
vault auth list -format=json | grep -q '"hub/"' || vault auth enable -path=hub kubernetes

echo "Writing auth/hub/config"
vault write auth/hub/config \
  kubernetes_host="$K8S_API" \
  token_reviewer_jwt="$(k8s_token)" \
  kubernetes_ca_cert=@"$SA_CA"

echo "Writing policy 'hub'"
vault policy write hub /policy/hub.hcl

echo "Writing role 'hub-role' bound to system:serviceaccount:$BOUND_NS:$BOUND_SA"
vault write auth/hub/role/hub-role \
  bound_service_account_names="$BOUND_SA" \
  bound_service_account_namespaces="$BOUND_NS" \
  policies=hub \
  ttl=1h

echo "Vault configuration complete"
