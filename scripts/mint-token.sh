#!/usr/bin/env bash
# Mints an RS256 access token signed with the stand key.
#
# Usage: scripts/mint-token.sh <subject> [scope ...]
#   scripts/mint-token.sh alice mcp:echo
#   scripts/mint-token.sh bob mcp:echo mcp:sum
#
# Env: TOKEN_TTL (seconds, default 3600), ISSUER (default http://idp:8080, as seen from containers).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

key=generated/signing-key.pem
[[ -f "$key" ]] || { echo "no $key; run scripts/gen-keys.sh first" >&2; exit 1; }
[[ $# -ge 1 ]] || { echo "usage: $0 <subject> [scope ...]" >&2; exit 1; }

sub="$1"; shift
iss="${ISSUER:-http://idp:8080}"
now=$(date +%s)
exp=$((now + ${TOKEN_TTL:-3600}))

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

header=$(jq -cn '{alg: "RS256", typ: "JWT", kid: "stand-key-1"}' | b64url)
payload=$(jq -cn \
  --arg iss "$iss" --arg sub "$sub" --argjson iat "$now" --argjson exp "$exp" \
  --arg jti "$(cat /proc/sys/kernel/random/uuid)" \
  --args '{
    iss: $iss, sub: $sub, aud: "agentgateway-stand", client_id: "stand-client",
    iat: $iat, nbf: $iat, exp: $exp, jti: $jti, token_type: "Bearer",
    scope: $ARGS.positional
  }' "$@" | b64url)
sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" -binary | b64url)
printf '%s.%s.%s\n' "$header" "$payload" "$sig"
