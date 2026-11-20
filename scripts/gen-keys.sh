#!/usr/bin/env bash
# Generates the stand's signing key and publishes its public half as a JWKS that the
# local IdP container serves. Run once; rerunning keeps the existing key unless --force.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

out=generated
mkdir -p "$out"

if [[ -f "$out/signing-key.pem" && "${1:-}" != "--force" ]]; then
  echo "key exists: $out/signing-key.pem (use --force to replace)"
else
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$out/signing-key.pem" 2>/dev/null
  echo "generated $out/signing-key.pem"
fi

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

# Modulus and exponent as unsigned big-endian bytes, base64url-encoded (RFC 7518 §6.3.1).
n=$(openssl rsa -in "$out/signing-key.pem" -noout -modulus 2>/dev/null | cut -d= -f2 \
  | sed 's/^\(00\)*//' | xxd -r -p | b64url)
e=$(printf '%06x' "$(openssl rsa -in "$out/signing-key.pem" -noout -text 2>/dev/null \
  | sed -n 's/^publicExponent: \([0-9]*\).*/\1/p')" | sed 's/^\(00\)*//' | xxd -r -p | b64url)

kid=stand-key-1
jq -n --arg n "$n" --arg e "$e" --arg kid "$kid" \
  '{keys: [{kty: "RSA", use: "sig", alg: "RS256", kid: $kid, n: $n, e: $e}]}' \
  > idp/jwks.json
echo "wrote idp/jwks.json (kid $kid)"
