#!/usr/bin/env bash
# Shows everything the stand recorded for one request, given its W3C trace id
# (scripts/demo.sh prints it):
#   1. spans from Tempo
#   2. the agentgateway access log record from Loki (OTLP), with the Cedarling request_id
#   3. the Cedarling decision log line(s) from the sidecar's stdout, matched by request_id
#
# Usage: scripts/correlate.sh <trace_id>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

trace="${1:?usage: $0 <trace_id>}"
grafana="${GRAFANA_URL:-http://127.0.0.1:3001}"
since_ns="$(( $(date +%s) - ${LOOKBACK_SECONDS:-3600} ))000000000"

echo "== 1. Tempo spans (trace $trace)"
curl -sf "$grafana/api/datasources/proxy/uid/tempo/api/traces/$trace" \
  | jq -r '.batches[] | .scopeSpans[].spans[]
      | "  \(.name)\t\((.attributes // []) | map(select(.key | test("http.host|http.path|url.path|gen_ai.tool.name")))
          | map("\(.key)=\(.value.stringValue // .value.intValue)") | join(" "))"' \
  || echo "  not found (Tempo ingests with a few seconds of delay; retry)"

echo
echo "== 2. agentgateway access log (Loki)"
record=$(curl -sfG "$grafana/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
  --data-urlencode "query={service_name=\"agentgateway\"} | trace_id=\"$trace\"" \
  --data-urlencode "start=$since_ns" \
  | jq -c '[.data.result[].stream] | map(select((.authz_cedarling_request_id // "") != "")) | .[0] // empty')
if [[ -z "$record" ]]; then
  echo "  no record with a Cedarling decision for this trace id"
  exit 0
fi
jq -r '"  status=\(.http_response_status_code) tool=\(.mcp_tool // "-") sub=\(.jwt_sub // .user_sub // "-") error=\(.error // "-")
  authz.decision=\(.authz_decision)
  authz.cedarling_request_id=\(.authz_cedarling_request_id)
  authz.trace_execution_id=\(.authz_trace_execution_id)"' <<<"$record"

request_id=$(jq -r '.authz_cedarling_request_id // empty' <<<"$record")
echo
echo "== 3. Cedarling decision log (sidecar stdout, request_id $request_id)"
if [[ -z "$request_id" ]]; then
  echo "  no request_id in the access log record"
  exit 0
fi
docker compose logs --no-log-prefix cedarling 2>/dev/null \
  | grep -F "\"request_id\":\"$request_id\"" \
  | jq -c '{log_kind, decision, action, resource, diagnostics, tokens: (.tokens // .tokens_ids)}' 2>/dev/null \
  || echo "  not found in sidecar logs"
