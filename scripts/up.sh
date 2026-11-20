#!/usr/bin/env bash
# Starts the stand: generates the signing key on first run, builds and starts all services,
# and waits until agentgateway answers.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

for tool in docker openssl jq curl xxd; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

[[ -f generated/signing-key.pem ]] || scripts/gen-keys.sh

docker compose up -d --build --wait --wait-timeout 180

echo
echo "stand is up:"
echo "  MCP via agentgateway  http://127.0.0.1:3000/mcp"
echo "  Cedarling sidecar     http://127.0.0.1:5000/swagger-ui"
echo "  Grafana (Tempo/Loki)  http://127.0.0.1:3001   (anonymous admin)"
echo "  agentgateway metrics  http://127.0.0.1:15020/metrics"
echo
echo "next: scripts/demo.sh, then scripts/correlate.sh <trace_id>"
