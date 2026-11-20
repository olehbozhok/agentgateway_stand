# Cedarling Flask sidecar: changes for tracing and OTEL logs

Status of the sidecar as used by the stand (`cedarling-flask-sidecar:0.0.0-nightly`, source `jans-cedarling/flask-sidecar`) and what to change so a request can be followed end to end with standard OpenTelemetry tooling.

## What works today

- `POST /cedarling/evaluation` reads four headers ([cedarling_authorize_usecase.py](https://github.com/JanssenProject/jans/blob/main/jans-cedarling/flask-sidecar/main/domain/usecases/cedarling_authorize_usecase.py)): `Audit-Trace-ID`, `Audit-Execution-Authority`, `Audit-Workload-ID`, `Audit-Workload-Instance-ID`. They become Cedarling `AuthorizeOptions.trace` (`TraceContext`).
- The response `context` carries `request_id`, `trace_execution_id`, `policy_store_id`, `policy_store_version` and `trace_record_status` when available.
- The stand derives `Audit-Trace-ID` from the client's W3C trace id in agentgateway CEL, so correlation works without sidecar changes, see [architecture.md](architecture.md#tracing-and-correlation).

## What is missing

Observed on the stand:

1. **`traceparent` is ignored.** agentgateway sends a W3C `traceparent` for its `ExtAuthz` span on every evaluation call; the sidecar neither continues the trace nor uses it as a fallback for `Audit-Trace-ID`. Every PEP has to know the custom `Audit-*` headers.
2. **No spans.** There is no OpenTelemetry instrumentation, so the trace in Tempo ends at agentgateway's `ExtAuthz` span; the time spent in Flask vs. in Cedarling is invisible.
3. **Logs only on stdout, without trace ids.** Sidecar logs (structlog JSON) and Cedarling logs (`CEDARLING_LOG_TYPE=std_out`) cannot be exported over OTLP, and no line carries `trace_id`/`span_id`.
4. **The Cedarling decision log has no trace id.** It has `request_id` only; to find a decision by trace id you need the PEP's access log as a bridge (`authz.cedarling_request_id` on the stand).
5. **`Audit-Trace-ID` without `Audit-Execution-Authority` is a `400`.** A PEP that only knows the trace id cannot send it; there is no configurable default for the authority as there is for the workload id (`SIDECAR_TRACE_WORKLOAD_ID`).
6. **The "Cedarling evaluation result" log line is written before `request_id` and `trace_execution_id` are added** to the result, so the sidecar's own log line cannot be joined with the Cedarling decision log.
7. **No health endpoint.** Orchestrators have to probe `/.well-known/authzen-configuration`.

## Proposed changes

In priority order. 1–3 are what the stand needs to show the sidecar in the same trace and in Loki.

| # | Change | Details | Config |
|---|---|---|---|
| 1 | OpenTelemetry tracing | `opentelemetry-instrumentation-flask` (continues incoming `traceparent`), a child span `cedarling.authorize` around `authorize_multi_issuer` with attributes `cedarling.decision`, `cedarling.request_id`, `cedarling.policy_store_id`, `cedarling.policy_store_version`, `trace.execution_id`. OTLP exporter. Off unless an endpoint is configured; no cost on the hot path when off. | standard `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME` (default `cedarling-sidecar`), `OTEL_TRACES_SAMPLER` |
| 2 | OTLP logs with trace context | Bridge structlog/stdlib logging to the OTEL logs SDK (`LoggingHandler`, OTLP log exporter) and add `trace_id`/`span_id` to every record, also on stdout. | `OTEL_LOGS_EXPORTER=otlp`; stdout stays the default |
| 3 | Cedarling logs through the sidecar | Run Cedarling with `CEDARLING_LOG_TYPE=memory`, after each evaluation pop its logs for the `request_id` (the sidecar already calls `get_logs_by_request_id_and_tag`) and re-emit them through #2 under the current span. Then the decision log lands in Loki with `trace_id`. Keep `std_out` as an option for deployments that collect container logs. | `SIDECAR_FORWARD_CEDARLING_LOGS=true` |
| 4 | `traceparent` fallback for TRACE | If `Audit-Trace-ID` is absent and `traceparent` is valid, use its 32-hex trace id as `trace_execution_id`. Explicit `Audit-*` headers keep priority. | `SIDECAR_TRACE_FROM_TRACEPARENT=true` (default on) |
| 5 | Default execution authority | Use a configured authority when the header is missing instead of `400`; still `400` when neither is available and `Audit-Trace-ID` is present. | `SIDECAR_TRACE_EXECUTION_AUTHORITY` |
| 6 | Log the final result | Write the "evaluation result" line after `request_id`, `trace_execution_id`, policy store id/version are added. | – |
| 7 | Echo correlation ids in response headers | `Audit-Trace-ID` and `Cedarling-Request-ID` response headers, so PEPs that cannot parse the body (or proxies in between) can log them. | – |
| 8 | Health endpoints | `GET /healthz` (process up) and `GET /readyz` (Cedarling initialised, policy store loaded). | – |
| 9 | Docs and tests | README env table; tests for header precedence (Audit-* > traceparent), malformed `traceparent`, missing authority with and without default; a test that the exported span is a child of the incoming `traceparent`. | – |

### Out of the sidecar's scope

- **Trace id in the Cedarling decision log itself** (gap 4) is a Cedarling core change: write `trace_execution_id` from `AuthorizeOptions.trace` into `DecisionLogEntry`. With #3 the sidecar can attach it on re-emit, so the core change is not blocking.
- **TRACE records to Lock** need no sidecar change beyond 4–5: Cedarling emits a record per decision whenever `TraceContext` is present and `CEDARLING_TRACE=enabled`. See [lock-server.md](lock-server.md).

## After the change: stand updates

- `compose.yaml`: add `OTEL_EXPORTER_OTLP_ENDPOINT=http://lgtm:4317`, `OTEL_SERVICE_NAME=cedarling-sidecar`, `SIDECAR_FORWARD_CEDARLING_LOGS=true` to the `cedarling` service and point `CEDARLING_SIDECAR_IMAGE` at the new build.
- `agentgateway/config.yaml`: the `audit-trace-id` CEL header can be dropped (the sidecar takes the trace id from `traceparent`).
- `scripts/correlate.sh`: read step 3 from Loki (`{service_name="cedarling-sidecar"} | trace_id="..."`) instead of `docker compose logs`.
