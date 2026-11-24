#!/usr/bin/env sh
# Starts Vault, then initializes and unseals it on first run and creates the AppRole the
# Janssen server logs in with. The role and secret ids go to /vault/approle, a volume the
# jans container mounts read-only. Adapted from automation/start_janssen_aio_demo.sh.
set -e

/usr/local/bin/docker-entrypoint.sh "$@" &
VAULT_PID=$!
export VAULT_ADDR=http://127.0.0.1:8200
keys=/vault/config/vault_key_token.txt

until vault status >/dev/null 2>&1 || [ $? -eq 2 ]; do sleep 1; done

if vault status 2>/dev/null | grep -q 'Initialized *false'; then
  echo "[vault] initializing"
  vault operator init -key-shares=1 -key-threshold=1 > "$keys"
fi

if vault status 2>/dev/null | grep -q 'Sealed *true'; then
  echo "[vault] unsealing"
  vault operator unseal "$(grep 'Unseal Key 1' "$keys" | awk -F ': ' '{print $2}')" >/dev/null
fi

vault login -no-print "$(grep 'Initial Root Token' "$keys" | awk -F ': ' '{print $2}')"

vault secrets list | grep -q '^secret/' || vault secrets enable -path=secret -version=1 kv
vault policy list | grep -q '^jans$' || vault policy write jans /stand/vault-policy.hcl
if ! vault auth list | grep -q '^approle/'; then
  vault auth enable approle
  vault write auth/approle/role/jans policies=jans secret_id_ttl=0 token_num_uses=0 \
    token_ttl=20m token_max_ttl=30m secret_id_num_uses=0
fi

vault read -field=role_id auth/approle/role/jans/role-id > /vault/approle/vault_role_id
vault write -f -field=secret_id auth/approle/role/jans/secret-id > /vault/approle/vault_secret_id
echo "[vault] configured"
wait $VAULT_PID
