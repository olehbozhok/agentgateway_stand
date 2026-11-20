#!/usr/bin/env bash
# Calls MCP tools through agentgateway as different users and prints the decisions.
# Every tools/call carries a fresh W3C traceparent; its trace id is printed so you can
# look the request up in Grafana (Tempo, Loki) and in the Cedarling sidecar log.
#
# Usage: scripts/demo.sh            run the scenario table below
#        scripts/demo.sh call <subject> <tool> <json-args> [scope ...]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

URL="${AGW_URL:-http://127.0.0.1:3000/mcp}"

new_traceparent() {
  local trace span
  trace=$(openssl rand -hex 16)
  span=$(openssl rand -hex 8)
  printf '00-%s-%s-01' "$trace" "$span"
}

# rpc <token> <session|-> <traceparent> <json-body>; prints headers+body.
rpc() {
  local token="$1" session="$2" tp="$3" body="$4"
  local args=(-sS -D - -X POST "$URL"
    -H "authorization: Bearer $token"
    -H 'content-type: application/json'
    -H 'accept: application/json, text/event-stream'
    -H "traceparent: $tp"
    -d "$body")
  [[ "$session" != "-" ]] && args+=(-H "mcp-session-id: $session")
  curl "${args[@]}"
}

# call <subject> <tool> <json-args> [scope ...]
call() {
  local sub="$1" tool="$2" targs="$3"; shift 3
  local token session tp out status
  token=$(scripts/mint-token.sh "$sub" "$@")

  out=$(rpc "$token" - "$(new_traceparent)" \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"stand-demo","version":"1"}}}')
  session=$(printf '%s' "$out" | tr -d '\r' | sed -n 's/^mcp-session-id: //Ip' | head -1)
  rpc "$token" "${session:--}" "$(new_traceparent)" \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

  tp=$(new_traceparent)
  out=$(rpc "$token" "${session:--}" "$tp" \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$targs}}")
  status=$(printf '%s' "$out" | head -1 | awk '{print $2}')
  local result
  result=$(printf '%s' "$out" | tr -d '\r' | sed -n 's/^data: //p' | tail -1)
  [[ -z "$result" ]] && result=$(printf '%s' "$out" | tr -d '\r' | sed '1,/^$/d')
  printf '%-6s %-15s scopes=%-22s HTTP %s  trace_id=%s\n         %s\n' \
    "$sub" "$tool" "${*:-<none>}" "$status" "$(cut -d- -f2 <<<"$tp")" "${result:0:160}"
}

if [[ "${1:-}" == "call" ]]; then
  shift
  call "$@"
  exit
fi

echo "== expected: permit"
call alice echo           '{"text":"hello"}'   mcp:echo
call bob   get_sum        '{"a":2,"b":3}'      mcp:echo mcp:sum
call root  delete_records '{"table":"users"}'  mcp:admin
echo
echo "== expected: deny (Cedar has no matching permit)"
call alice get_sum        '{"a":2,"b":3}'      mcp:echo
call bob   delete_records '{"table":"users"}'  mcp:echo mcp:sum
call eve   echo           '{"text":"hi"}'
