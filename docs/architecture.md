# How the stand works

## Request flow

1. The client sends an MCP JSON-RPC request with `Authorization: Bearer <JWT>` and a W3C `traceparent`.
2. **agentgateway `jwtAuth`** verifies the JWT against the IdP JWKS (`http://idp:8080/jwks.json`), issuer `http://idp:8080` and audience `agentgateway-stand`. Invalid or missing token: `401`.
3. **agentgateway `extAuthz`** runs only when `has(mcp.tool)`, i.e. for `tools/call`. `initialize`, `tools/list` and notifications skip the PDP. It POSTs an AuthZEN evaluation request to `http://cedarling:5000/cedarling/evaluation`; the body and headers are CEL expressions in [agentgateway/config.yaml](../agentgateway/config.yaml):

   | AuthZEN field | Value |
   |---|---|
   | `subject.properties.tokens` | `[{mapping: "Stand::Access_Token", payload: <raw JWT>}]` |
   | `action.name` | `Stand::Action::"call_tool"` |
   | `resource` | `Stand::Tool::"<tool name>"` with attribute `name` |
   | `context` | `{}` |

4. The **sidecar** calls Cedarling `authorize_multi_issuer`. Cedarling maps the token to a `Stand::Access_Token` entity, exposes it as `context.tokens.stand_access_token` (issuer name `Stand` + token kind) and evaluates [cedarling/policy-store.yaml](../cedarling/policy-store.yaml). It answers `200 {"decision": true|false, "context": {"request_id", "trace_execution_id", ...}}`.
5. agentgateway copies `decision`, `request_id` and `trace_execution_id` from the response body into `extauthz.*` (the `metadata` block).
6. **agentgateway `authorization`** enforces `!has(mcp.tool) || extauthz.decision == true`. This rule is required: the sidecar returns HTTP 200 for deny too, so `extAuthz` alone lets every call through.
7. Permitted calls go to the MCP server; denied ones get `403 authorization failed`. If the sidecar is down, `failureMode: deny` rejects the call.

## Policies

| Tool | Needs scope |
|---|---|
| `echo` | `mcp:echo` |
| `get_sum` | `mcp:sum` |
| `delete_records` | `mcp:admin` |

Anything without a matching `permit` is denied (Cedar default deny). Token claims become entity tags, so policies read them with `hasTag("scope")` / `getTag("scope")`.

## Why Cedarling does not verify the JWT signature

`CEDARLING_JWT_SIG_VALIDATION` is `disabled`. With validation on, Cedarling fetches the issuer's OpenID configuration and refuses plain `http` for non-loopback hosts. The stand IdP is plain HTTP, and agentgateway has already verified the signature, issuer, audience and expiry before calling the sidecar. In production enable it and serve the IdP over HTTPS, so the PDP does not trust the PEP blindly.

## Tracing and correlation

How agentgateway receives, continues and propagates the trace id, step by step: [tracing.md](tracing.md).

| Id | Created by | Where it shows up |
|---|---|---|
| W3C trace id | the client's `traceparent`; agentgateway continues it | Tempo spans; `trace_id` of the OTLP access log record in Loki |
| `Audit-Trace-ID` / TRACE `trace_execution_id` | agentgateway, from the trace id via CEL | sidecar response `context.trace_execution_id`; access log `authz.trace_execution_id` |
| Cedarling `request_id` (UUIDv7) | Cedarling, per decision | sidecar response `context.request_id`; access log `authz.cedarling_request_id`; Cedarling decision log `request_id` |

The path from a trace id to the decision is: Tempo/Loki by trace id → access log record → `authz.cedarling_request_id` → Cedarling decision log line with that `request_id`. `scripts/correlate.sh` does exactly this.

Spans in one trace: the inbound `tools/call` (or `POST /mcp/*` when denied), `ExtAuthz` (the call to the sidecar), and the upstream MCP call when permitted.

Gaps today, all on the sidecar side (details and fixes in [sidecar-changes.md](sidecar-changes.md)):

- agentgateway also sends `traceparent` to the sidecar, but the sidecar ignores it: no sidecar spans in Tempo.
- The sidecar and Cedarling log only to stdout, so their lines are not in Loki; `correlate.sh` reads them with `docker compose logs`.
- The Cedarling decision log carries `request_id`, not the trace id.

### Without a client `traceparent`

agentgateway starts a new trace and writes its own `traceparent` onto the request before route policies run, so the `Audit-Trace-ID` CEL still gets the trace id: "trace id = TRACE execution id" holds. The `uuid()` fallback fires only for a request that is not sampled and arrived without a header. Full details: [tracing.md](tracing.md).

## Telemetry pipeline

`grafana/otel-lgtm` is one container with an OpenTelemetry Collector, Tempo, Loki, Prometheus and Grafana. agentgateway sends:

- traces: `frontendPolicies.tracing` to `lgtm:4317` (OTLP gRPC), sampling every request;
- access logs: `frontendPolicies.accessLog.otlp` to the same receiver, with the extra fields from `accessLog.add` (`user.sub`, `mcp.tool`, `authz.*`).

Prometheus metrics stay on agentgateway's `:15020/metrics` and are not scraped by the stand.
