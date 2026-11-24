# How tracing works on the stand

This page explains how a W3C trace id gets into agentgateway, what agentgateway does with it, where it is sent next, and where you can see it. It describes agentgateway `v1.7.0` (the image in [compose.yaml](../compose.yaml)) and the config in [agentgateway/config.yaml](../agentgateway/config.yaml).

## The short version

- agentgateway gets trace context from **one place only: the `traceparent` HTTP request header** (W3C Trace Context). It does not read B3, Jaeger (`uber-trace-id`) or the MCP `_meta.traceparent` sent by the client.
- If there is a valid `traceparent`, agentgateway **keeps its trace id** and adds its own spans to that trace. If there is none, or it is malformed, agentgateway **starts a new trace**.
- agentgateway then **rewrites the `traceparent` header** on the request, so everything after it (extAuthz, the MCP server) receives the same trace id with agentgateway's span as parent.
- Spans go to Tempo and access log records go to Loki, both over OTLP to `lgtm:4317`. Both carry the trace id.

```
client                    agentgateway                                   Cedarling sidecar   mcp-server
  │ traceparent:            │                                                   │                │
  │ 00-T-C-01               │                                                   │                │
  ├────────────────────────▶│ 1. parse traceparent → trace id T                 │                │
  │                         │ 2. sampling decision                              │                │
  │                         │ 3. new span G (trace T, parent C)                 │                │
  │                         │    rewrite header: traceparent 00-T-G-01          │                │
  │                         │ 4. extAuthz span A (parent G)                     │                │
  │                         ├── traceparent 00-T-A-01, Audit-Trace-ID: T ──────▶│ (ignores       │
  │                         │◀─ decision, request_id, trace_execution_id ───────┤  traceparent)  │
  │                         │ 5. MCP span M (parent G)                          │                │
  │                         ├── traceparent 00-T-M-01 (header and _meta) ───────────────────────▶│
  │                         │ 6. export spans G, A, M + access log, all with T  │                │
  │                         ├──▶ lgtm:4317 (Tempo, Loki)                        │                │
```

`T` is the 32-hex trace id. `C`, `G`, `A` and `M` are 16-hex span ids.

## Step by step

### 1. Parsing the incoming header

The value has to be exactly `version-traceid-spanid-flags` with field lengths `2-32-16-2` in hex, for example:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                └ flags: 01 = sampled
             │  │                                └ parent span id (the client's span)
             │  └ trace id
             └ version
```

agentgateway rejects it, and acts as if no header was sent, when:

- it does not have 4 fields, or a field has the wrong length;
- a field is not hex;
- the version is `ff`, or the trace id or span id is all zeros.

agentgateway does not parse `tracestate` or `baggage`. They stay on the request as ordinary headers.

### 2. Sampling decision

`frontendPolicies.tracing` has three CEL settings. Exactly one of them decides, depending on the incoming header:

| Incoming `traceparent` | Setting that decides | Default if not set | On the stand |
|---|---|---|---|
| none or malformed | `randomSampling` | `false` (not traced) | `true` → traced |
| valid, flags `01` (sampled) | `clientSampling` | `true` (traced) | not set → traced |
| valid, flags `00` (not sampled) | `parentNotSampled` | `false` (not traced) | not set → **not traced** |

Each setting is a CEL expression: `true`, `false`, or a probability such as `0.1`.

So on the stand every request is traced, **except** one whose client explicitly sent a `traceparent` with flags `00`.

Whatever the decision, agentgateway keeps the incoming trace id for the access log (see [Access log](#where-to-see-the-trace-id)).

### 3. agentgateway's own span and the header rewrite

Only for a sampled request:

- With a valid incoming header, agentgateway creates a new span id `G` in the **same trace** `T`; the client's span `C` becomes its parent.
- Without one, it generates a random trace id and span id: **a new trace**.
- It sets the sampled flag and **overwrites** `traceparent` on the request with `00-T-G-01`.

This happens in the frontend policies, before any route policy runs. From now on, every CEL expression that reads `request.headers["traceparent"]` sees the rewritten value: the same trace id `T` as the client (or the new one), and agentgateway's span id.

For a request that is **not** sampled, none of this happens. No spans are written, and the client's `traceparent`, if there was one, goes upstream unchanged.

### 4. extAuthz call to Cedarling

For `tools/call`, agentgateway calls the sidecar inside a client span (`ExtAuthz` in Tempo, parent `G`). Two things carry the trace to the sidecar:

| Header | Value | Set by |
|---|---|---|
| `traceparent` | `00-T-A-01` (`A` = the extAuthz span) | agentgateway, automatically |
| `Audit-Trace-ID` | `T` (32 hex) | the CEL in `config.yaml`: `request.headers["traceparent"].split("-")[1]` |

The sidecar **ignores `traceparent`**, so it adds no spans of its own. It does use `Audit-Trace-ID`: Cedarling uses it as the TRACE `trace_execution_id` and sends it back in `context.trace_execution_id`.

The CEL falls back to `uuid()` when there is no `traceparent`. Because of step 3, that only happens for a request that is not sampled and arrived without a header. In every other case `Audit-Trace-ID` equals the trace id, **including** when the client sent no `traceparent` and agentgateway started a new trace.

### 5. MCP upstream call

The call to `mcp-server` runs in another client span (`M`, parent `G`, attributes `mcp.method.name`, `gen_ai.tool.name`). The trace context goes out twice:

- as the `traceparent` HTTP header (`00-T-M-01`);
- inside the JSON-RPC message, as `params._meta.traceparent` (plus `tracestate` and `baggage` if the client sent them), following MCP SEP-414. This is the only way to pass trace context to stdio MCP servers, which have no headers.

The demo MCP server has no OpenTelemetry instrumentation, so it ignores both.

### 6. Export

- **Spans**: `frontendPolicies.tracing.host: lgtm:4317`, OTLP gRPC. They are exported when the request finishes.
- **Access log**: `frontendPolicies.accessLog.otlp`, same receiver. Each record carries `trace_id` and `span_id` as OTLP log fields, plus the extra `accessLog.add` fields (`authz.cedarling_request_id`, `authz.trace_execution_id`, ...).

## Where to see the trace id

| Place | Field | Present when |
|---|---|---|
| Tempo | trace `T`: spans `G` (inbound, for example `tools/call`), `ExtAuthz`, the MCP call | sampled |
| Loki, `{service_name="agentgateway"}` | `trace_id`, `span_id` | always if a trace id exists: sampled requests, or unsampled ones with a client `traceparent` |
| Loki, same record | `authz.trace_execution_id` | `tools/call` only; equals `T` (see step 4) |
| Sidecar response / TRACE record | `context.trace_execution_id` | `tools/call` only |
| Cedarling decision log (sidecar stdout) | none; only `request_id` | link it through `authz.cedarling_request_id` in the access log |

For an unsampled request without a client header there is no trace id anywhere. The access log has no `trace_id`, and `authz.trace_execution_id` is a random UUID.

## Cases at a glance

| Client sends | Traced | Trace id in Tempo and Loki | `Audit-Trace-ID` to Cedarling |
|---|---|---|---|
| `traceparent ...-01` | yes | the client's | the client's trace id |
| no `traceparent` | yes (`randomSampling: true`) | new, made by agentgateway | agentgateway's new trace id |
| malformed `traceparent` | yes, as "none" | new, made by agentgateway | agentgateway's new trace id |
| `traceparent ...-00` | no | Loki only: the client's | the client's trace id |

## Try it

```bash
scripts/demo.sh                    # every tools/call gets a fresh traceparent; prints its trace id
scripts/correlate.sh <trace_id>    # Tempo spans → access log → Cedarling decision for that id
```

Send your own trace id:

```bash
TP="00-$(openssl rand -hex 16)-$(openssl rand -hex 8)-01"
echo "$TP"
# add  -H "traceparent: $TP"  to any curl against http://127.0.0.1:3000/mcp
```

In Grafana (http://127.0.0.1:3001): Explore → Tempo → search by trace id; Explore → Loki → `{service_name="agentgateway"} | trace_id="<trace_id>"`.

## Known gaps

- The Cedarling sidecar does not continue the trace: no sidecar spans, and its logs stay on stdout without a trace id. Fixes are proposed in [sidecar-changes.md](sidecar-changes.md).
- The demo MCP server is not instrumented, so the trace ends at agentgateway's MCP span.
- agentgateway does not read `_meta.traceparent` from the client's MCP message, only the HTTP header. A client that puts trace context only into `_meta` gets a new trace.
