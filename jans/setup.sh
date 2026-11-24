#!/usr/bin/env bash
# Creates, or updates, what the e2e test needs in the Janssen Auth Server: the scopes mcp:echo,
# mcp:sum and mcp:admin, and the agent's OAuth client. The client gets client_credentials with
# mcp:echo and mcp:sum only (not mcp:admin, so the delete_records call is a real deny), access
# tokens as JWT, and agentgateway-stand as an additional audience.
#
# Uses the config API with the stand's admin client (CN_CONFIG_API_TEST_CLIENT_* in
# jans/compose.yaml). Idempotent: safe to run on every e2e start.
set -euo pipefail

: "${JANS_URL:?}" "${JANS_CA:?}" "${ADMIN_CLIENT_ID:?}" "${ADMIN_CLIENT_SECRET:?}"
: "${AGENT_CLIENT_ID:?}" "${AGENT_CLIENT_SECRET:?}"
AUDIENCE="${AGENT_AUDIENCE:-agentgateway-stand}"
API="$JANS_URL/jans-config-api/api/v1"

curl_() { curl -sS --fail-with-body --cacert "$JANS_CA" "$@"; }

token=$(curl_ -u "$ADMIN_CLIENT_ID:$ADMIN_CLIENT_SECRET" -d grant_type=client_credentials \
  --data-urlencode "scope=https://jans.io/oauth/config/scopes.readonly https://jans.io/oauth/config/scopes.write https://jans.io/oauth/config/openid/clients.readonly https://jans.io/oauth/config/openid/clients.write" \
  "$JANS_URL/jans-auth/restv1/token" | jq -r .access_token)
auth=(-H "Authorization: Bearer $token" -H "Content-Type: application/json")

# Prints the DN of scope $1, creating the scope first if needed.
scope_dn() {
  local id="$1" dn
  dn=$(curl_ "${auth[@]}" "$API/scopes?pattern=$id&limit=50" \
    | jq -r --arg id "$id" '(.entries // [])[] | select(.id == $id) | .dn' | head -1)
  if [[ -z "$dn" ]]; then
    dn=$(curl_ "${auth[@]}" -X POST "$API/scopes" -d "$(jq -n --arg id "$id" \
      '{id: $id, displayName: $id, description: "MCP tool access on the agentgateway stand", scopeType: "oauth"}')" \
      | jq -r .dn)
    echo "created scope $id" >&2
  fi
  echo "$dn"
}

echo_dn=$(scope_dn mcp:echo)
sum_dn=$(scope_dn mcp:sum)
scope_dn mcp:admin >/dev/null

client=$(jq -n \
  --arg id "$AGENT_CLIENT_ID" --arg secret "$AGENT_CLIENT_SECRET" --arg aud "$AUDIENCE" \
  --arg echo "$echo_dn" --arg sum "$sum_dn" '{
    inum: $id,
    clientName: "agentgateway-stand agent",
    displayName: "agentgateway-stand agent",
    clientSecret: $secret,
    applicationType: "web",
    grantTypes: ["client_credentials"],
    responseTypes: ["token"],
    # The config API requires one even for a client_credentials-only client; never used.
    redirectUris: ["https://localhost/unused"],
    tokenEndpointAuthMethod: "client_secret_basic",
    accessTokenAsJwt: true,
    scopes: [$echo, $sum],
    attributes: {additionalAudience: [$aud]}
  }')

status=$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$JANS_CA" "${auth[@]}" \
  "$API/openid/clients/$AGENT_CLIENT_ID")
if [[ "$status" == 200 ]]; then
  curl_ "${auth[@]}" -X PUT "$API/openid/clients" -d "$client" >/dev/null
  echo "updated client $AGENT_CLIENT_ID"
else
  curl_ "${auth[@]}" -X POST "$API/openid/clients" -d "$client" >/dev/null
  echo "created client $AGENT_CLIENT_ID"
fi
