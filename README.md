# agentgateway + Cedarling stand

A local Docker Compose stand where [agentgateway](https://agentgateway.dev) protects an MCP server and delegates every `tools/call` decision to [Cedarling](https://github.com/JanssenProject/jans/tree/main/jans-cedarling) running as the Flask AuthZEN sidecar. Traces and access logs go over OTLP to Grafana (Tempo, Loki), and one trace id links a request across agentgateway, the sidecar and the Cedarling decision log.

```text
client ──JWT + traceparent──▶ agentgateway :3000 ──▶ mcp-server (echo, get_sum, delete_records)
                                  │  jwtAuth (JWKS from idp)
                                  │  extAuthz HTTP ──AuthZEN + Audit-* headers──▶ cedarling sidecar :5000
                                  │  authorization: require extauthz.decision
                                  └─ OTLP traces + access logs ──▶ lgtm (Tempo, Loki, Grafana :3001)
```

How each piece works and why it is configured this way: [docs/architecture.md](docs/architecture.md).

## Requirements

- Docker with Compose v2.20+ (`docker compose up --wait`). On WSL: Docker Desktop with WSL integration enabled for the distro.
- `bash`, `openssl`, `jq`, `curl`, `xxd`.
- Free localhost ports: 3000, 3001, 4317, 4318, 5000, 15020.

No `/etc/hosts` entries are needed: services find each other by Compose service name, and you reach them on `127.0.0.1`. The optional Lock Server setup is the exception, see [docs/lock-server.md](docs/lock-server.md).

## Run

```bash
scripts/up.sh                       # first run pulls images and builds the MCP server, ~2 min
scripts/demo.sh                     # 3 permitted and 3 denied tool calls, prints trace ids
scripts/correlate.sh <trace_id>     # Tempo spans + access log + Cedarling decision for one call
scripts/down.sh                     # stop; --wipe also deletes the generated key
```

Expected `demo.sh` output (trace ids differ):

```text
== expected: permit
alice  echo            scopes=mcp:echo               HTTP 200  trace_id=1ce21a34...
bob    get_sum         scopes=mcp:echo mcp:sum       HTTP 200  trace_id=29f8b1c0...
root   delete_records  scopes=mcp:admin              HTTP 200  trace_id=ea702b2a...

== expected: deny (Cedar has no matching permit)
alice  get_sum         scopes=mcp:echo               HTTP 403  trace_id=4760dadf...
bob    delete_records  scopes=mcp:echo mcp:sum       HTTP 403  trace_id=dd91b8a7...
eve    echo            scopes=<none>                 HTTP 403  trace_id=dbe006e1...
```

A single call with your own scopes: `scripts/demo.sh call <subject> <tool> '<json args>' [scope ...]`.

## Benchmark

`scripts/bench.sh` measures what the sidecar adds to an MCP tool call (~10 min, results in `bench-results/`, git-ignored). It compares, inside the Compose network:

| Scenario | Path |
|---|---|
| `direct` | client → MCP server |
| `gw-plain` | client → agentgateway (JWT only, route `/bench/plain`) → MCP server: the baseline |
| `gw-cel` | + in-process `mcpAuthorization` CEL (route `/bench/cel`) |
| `gw-extauthz` | + extAuthz → Cedarling sidecar (route `/mcp`) |
| `pdp-only` | client → sidecar evaluation endpoint |

Tools: `echo` (no work) and `wait` (sleeps 50/200/1000 ms, standing in for a tool that calls an external API). Requests are interleaved across scenarios in random order; the summary gives median deltas against `gw-plain` with 95% bootstrap CIs and Mann-Whitney p-values, then closed-loop throughput at 1/8/32 concurrent clients. Quick check: `scripts/bench.sh --rounds 200 --waits 50 --wait-budget 20 --seconds 5`.

Cedarling's own decision time, without HTTP, inside the sidecar container:

```bash
T=$(scripts/mint-token.sh bench mcp:echo)
docker compose exec -T -e BENCH_TOKEN="$T" cedarling python - < bench/cedarling_inproc.py
```

Results of 2026-11-23 on one WSL2 host: the sidecar path adds a median of 2.8 ms to an `echo` call (4 ms to `wait` calls), of which Cedarling's decision is about 0.05 ms; that is 48% of an empty tool call, 2% of a 200 ms one and 0.4% of a 1 s one.

## Endpoints

| What | URL |
|---|---|
| MCP through agentgateway | http://127.0.0.1:3000/mcp |
| Cedarling sidecar (AuthZEN), Swagger | http://127.0.0.1:5000/swagger-ui |
| Grafana: Explore > Tempo or Loki (anonymous admin) | http://127.0.0.1:3001 |
| agentgateway Prometheus metrics | http://127.0.0.1:15020/metrics |

In Grafana, Loki query for the gateway's access logs: `{service_name="agentgateway"}`; for one request add `| trace_id="<trace_id>"`.

## Layout

| Path | Purpose |
|---|---|
| [compose.yaml](compose.yaml) | All services |
| [agentgateway/config.yaml](agentgateway/config.yaml) | Gateway: JWT auth, extAuthz to Cedarling, decision enforcement, OTLP |
| [cedarling/bootstrap.json](cedarling/bootstrap.json) | Cedarling bootstrap properties |
| [cedarling/policy-store.yaml](cedarling/policy-store.yaml) | Cedar schema, policies and trusted issuer |
| [idp/](idp/) | Static "IdP": OpenID discovery + JWKS served by nginx |
| [mcp-server/](mcp-server/) | Demo MCP server (Python, FastMCP) |
| [scripts/](scripts/) | `up`, `down`, `gen-keys`, `mint-token`, `demo`, `correlate`, `bench` |
| [bench/](bench/) | Latency benchmark client and in-process Cedarling timer |
| [docs/sidecar-changes.md](docs/sidecar-changes.md) | What the Flask sidecar needs for proper tracing and OTEL logs |
| [docs/lock-server.md](docs/lock-server.md) | Optional: Cedarling TRACE records to a Janssen Lock Server |

## Configuration knobs

Environment variables read by `compose.yaml` (put them in `.env`, which git ignores):

| Variable | Default |
|---|---|
| `AGENTGATEWAY_IMAGE` | `cr.agentgateway.dev/agentgateway:v1.7.0` |
| `CEDARLING_SIDECAR_IMAGE` | `ghcr.io/janssenproject/jans/cedarling-flask-sidecar:0.0.0-nightly` |
| `LGTM_VERSION` | `0.11.0` |

To try a locally built sidecar or gateway, build the image and point the variable at it.

Policy and config files are mounted as directories: after editing `cedarling/*` run `docker compose restart cedarling`; agentgateway reloads `agentgateway/config.yaml` on change.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `cedarling` stays `unhealthy` | `docker compose logs cedarling`: usually a policy store parse error, printed with the failing field |
| All calls `403` | Check that `idp` serves `/jwks.json` and the token is fresh (`TOKEN_TTL`, default 1 h); `scripts/gen-keys.sh --force` changes the key, so mint new tokens |
| `correlate.sh` finds nothing | Tempo and Loki ingest with a few seconds of delay; retry. Records older than `LOOKBACK_SECONDS` (default 3600) are not searched |
| Port already in use | Another stand (e.g. `examples/mcp-telemetry`) holds 3000/4317; stop it |
