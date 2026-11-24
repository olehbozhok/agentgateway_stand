#!/usr/bin/env bash
# e2e test runner (docs/e2e-openshell-design.md). Runs in the e2e service:
#   docker compose --profile e2e run --rm e2e
# 1. prepares the agent's OAuth client in the Janssen Auth Server;
# 2. prepares the OpenShell provider that mints the agent's token;
# 3. runs the agent in an OpenShell sandbox and collects its observations;
# 4. checks every case, the control run and the telemetry; exits 1 if any check fails.
set -euo pipefail

: "${OPENSHELL_GATEWAY_URL:?}" "${AGENT_IMAGE:?}" "${GRAFANA_URL:?}"
: "${AGENT_CLIENT_ID:?}" "${AGENT_CLIENT_SECRET:?}"

step() { printf '\n== %s\n' "$*"; }
failures=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
# check <description> <jq filter over the case object> <case number>
check() {
  local desc="$1" filter="$2" case="$3" obj
  obj=$(jq -c --argjson c "$case" 'select(.case == $c)' "$results" | head -1)
  if [[ -n "$obj" ]] && jq -e "$filter" <<<"$obj" >/dev/null 2>&1; then
    pass "$case. $desc"
  else
    fail "$case. $desc -- observed: ${obj:-<no result>}"
  fi
}

step "Janssen Auth Server: scopes and the agent client"
bash /stand/jans/setup.sh

step "OpenShell: provider for agentgateway (token minted by the OpenShell gateway)"
openshell gateway add "$OPENSHELL_GATEWAY_URL" --name stand >/dev/null 2>&1 || true
openshell gateway select stand >/dev/null
openshell provider delete agentgateway >/dev/null 2>&1 || true
openshell profile delete stand-agentgateway --global >/dev/null 2>&1 \
  || openshell profile delete stand-agentgateway >/dev/null 2>&1 || true
openshell profile import -f /stand/openshell/provider-agentgateway.yaml --global
# Created with a placeholder value; the refresh below replaces it with a real token.
openshell provider create --name agentgateway --type stand-agentgateway --credential MCP_TOKEN=pending
openshell provider refresh configure agentgateway --credential-key MCP_TOKEN \
  --strategy oauth2-client-credentials \
  --material client_id="$AGENT_CLIENT_ID" \
  --material client_secret="$AGENT_CLIENT_SECRET" \
  --material token_endpoint_auth_method=client_secret_basic \
  --secret-material-key client_secret
openshell provider refresh rotate --credential-key MCP_TOKEN agentgateway
openshell provider refresh status agentgateway | tail -1 | grep -q refreshed \
  || { echo "the OpenShell gateway could not get a token from the Auth Server"; exit 1; }

step "Agent in the OpenShell sandbox"
host_ip=$(jq -r 'select(.case == 15) | .ip' /state/control.jsonl)
sandbox="agent-$(date +%s)"   # names are limited to 19 characters
results=$(mktemp)
# The sandbox is kept until the telemetry checks are done: its supervisor exports OCSF records
# and spans in batches, and deleting it right after the agent exits drops the last batch.
trap 'openshell sandbox delete "$sandbox" >/dev/null 2>&1 || true' EXIT
# sh is the main process so that python3 (the agent) and curl are siblings: a child process
# inherits the permission of an allowed parent, which would hide the per-binary rule (case 12).
openshell sandbox create --name "$sandbox" --no-tty --from "$AGENT_IMAGE" \
  --policy /stand/openshell/sandbox-policy.yaml --provider agentgateway \
  --env HOST_REAL_IP="$host_ip" -- sh -c '
    python3 /usr/local/bin/agent.py run
    code=$(curl -sS -m 5 -o /dev/null -w "%{http_code}" -X POST http://host.docker.internal:3100/mcp 2>/dev/null || true)
    printf "{\"case\": 12, \"name\": \"curl, sibling of the agent, to agentgateway\", \"status\": \"%s\"}\n" "$code"
  ' 2>&1 | tee /dev/stderr | grep '^{"case"' > "$results" || true
cat /state/control.jsonl >> "$results"

step "Checks: chain"
nonce=$(cat /state/nonce)
check "token in the sandbox is a placeholder"      '.looks_like_jwt == false and (.value_prefix | startswith("openshell:resolve:"))' 1
check "demo page read, nonce matches"              ".status == 200 and .nonce == \"$nonce\"" 2
check "MCP session through agentgateway"           '.status == 200 and .session == true' 0
check "echo permitted"                             '.status == 200 and .text == "hello from the sandbox"' 3
check "get_sum permitted"                          '.status == 200 and .text == "5"' 4
check "delete_records denied by Cedar"             '.status == 403' 5

step "Checks: escape attempts (all blocked by OpenShell)"
check "MCP server directly"                        'has("error") and (.error | test("Permission denied|Errno 13"))' 6
check "external host"                              'has("error")' 7
check "real host IP with the allowed Host header"  'has("error")' 8
check "Host: evil.example on an allowed connection" '.status == 403' 9
check "write /etc/hosts"                           '.written == false' 10
check "own DNS query"                              '.answered == false' 11
check "curl, not in the rule"                      '.status == "000"' 12
check "placeholder to the MCP server port"         'has("error")' 13

step "Checks: control run without the sandbox"
check "MCP server answers directly"                '.status == 200' 14

step "Checks: telemetry"
since=$(( $(date +%s) - 900 ))000000000
loki() {
  curl -sS -G "$GRAFANA_URL/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "start=$since" --data-urlencode limit=1000 \
    | jq -r '.data.result[]?.values[]?[1]'
}
# Batched export plus ingestion delay: wait until the last case's denial (curl) has arrived.
for _ in $(seq 1 30); do
  ocsf=$(loki "{service_name=\"openshell-supervisor\"} |= \"$sandbox\"")
  grep -q "binary '/usr/bin/curl' not allowed" <<<"$ocsf" && break
  sleep 2
done
sleep 5   # agentgateway and Tempo records of the same requests
for reason in transparent_tcp_mapping_denied transparent_tcp_policy_denied \
              request_authority_mismatch policy_dns_ineligible "binary '/usr/bin/curl' not allowed"; do
  if grep -q "$reason" <<<"$ocsf"; then pass "OCSF denial recorded: $reason"; else fail "OCSF denial missing: $reason"; fi
done
permit_trace=$(jq -r 'select(.case == 3) | .trace_id' "$results")
deny_trace=$(jq -r 'select(.case == 5) | .trace_id' "$results")

# The access log fields are Loki structured metadata, so they are filtered, not grepped.
denied=$(curl -sS -G "$GRAFANA_URL/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
  --data-urlencode "query={service_name=\"agentgateway\"} | trace_id=\"$deny_trace\" | authz_decision=\"false\" | http_response_status_code=\"403\"" \
  --data-urlencode "start=$since" | jq '[.data.result[]?.values[]?] | length')
if [[ "${denied:-0}" -ge 1 ]]; then
  pass "agentgateway access log: the denied call has authz.decision=false and 403"
else
  fail "agentgateway access log: no authz.decision=false record for trace $deny_trace"
fi

# agentgateway names the upstream MCP span "tools/call tools_<tool>": present only when the
# call reached the MCP server.
spans() {
  curl -sS "$GRAFANA_URL/api/datasources/proxy/uid/tempo/api/traces/$1" \
    | jq -r '[.batches[]?.scopeSpans[]?.spans[]?.name] | join(",")'
}
permit_spans=$(spans "$permit_trace")
deny_spans=$(spans "$deny_trace")
if grep -q "tools/call tools_echo" <<<"$permit_spans"; then
  pass "Tempo: the permitted echo call reached the MCP server ($permit_spans)"
else
  fail "Tempo: no upstream span for the permitted call $permit_trace ($permit_spans)"
fi
if grep -q "ExtAuthz" <<<"$deny_spans" && ! grep -q "tools/call tools_" <<<"$deny_spans"; then
  pass "Tempo: the denied call stopped at ExtAuthz, MCP server not called ($deny_spans)"
else
  fail "Tempo: denied call $deny_trace has unexpected spans ($deny_spans)"
fi

# The supervisor's request span is a separate trace with a link to the agent's trace id. A
# TraceQL `link:traceID` search lags behind ingestion, so list the supervisor's request traces
# and read their links (base64 in Tempo's OTLP JSON). Spans arrive after OCSF records: poll.
linked_to() {
  local want="$1" t
  for t in $(curl -sS -G "$GRAFANA_URL/api/datasources/proxy/uid/tempo/api/search" \
      --data-urlencode 'q={ resource.service.name = "openshell-supervisor" && name = "openshell.http.request" }' \
      --data-urlencode "start=$(( $(date +%s) - 900 ))" --data-urlencode "end=$(date +%s)" \
      --data-urlencode limit=200 | jq -r '.traces[]?.traceID'); do
    curl -sS "$GRAFANA_URL/api/datasources/proxy/uid/tempo/api/traces/$t" \
      | jq -r '.batches[]?.scopeSpans[]?.spans[]? | select(.name == "openshell.http.request") | (.links // [])[].traceId' \
      | while read -r b64; do printf '%s' "$b64" | base64 -d | od -An -tx1 | tr -d ' \n'; echo; done \
      | grep -qx "$want" && return 0
  done
  return 1
}
linked=0
for _ in $(seq 1 30); do
  linked_to "$deny_trace" && { linked=1; break; }
  sleep 2
done
if [[ "$linked" -eq 1 ]]; then
  pass "Tempo: OpenShell supervisor trace links to the agent's trace $deny_trace"
else
  fail "Tempo: no OpenShell supervisor trace links to $deny_trace"
fi

step "Result"
if [[ "$failures" -eq 0 ]]; then
  echo "e2e PASSED"
else
  echo "e2e FAILED: $failures check(s)"
  exit 1
fi
