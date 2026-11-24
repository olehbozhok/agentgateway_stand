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

The `e2e` profile adds an end-to-end test on top: an agent in an [OpenShell](https://github.com/ai-openshell/openshell) sandbox calls the same tools through agentgateway with a token from a Janssen Auth Server, and tries to get around the gateway. See [End-to-end test](#end-to-end-test-e2e-profile).

## Requirements

- Docker with Compose v2.23+ (`include`, volume `subpath`). On WSL: Docker Desktop with WSL integration enabled for the distro; the e2e profile also needs host networking enabled in Docker Desktop.
- `bash`, `openssl`, `jq`, `curl`, `xxd`.
- Free localhost ports: 3000, 3001, 4317, 4318, 5000, 8000, 15020; for the e2e profile also 3080, 3100, 8080, 8443.
- For the e2e profile: about 5 GB of free memory for Docker (the Auth Server alone is limited to 4 GB).

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

## End-to-end test (e2e profile)

An agent runs in an OpenShell sandbox, calls MCP tools through agentgateway with an access token from a Janssen Auth Server, and then tries to get around the gateway. The test passes only if permitted calls work, the denied call is stopped by Cedar, every escape attempt is blocked by OpenShell, the agent never holds the secret or the token, and all of it can be found in Grafana. Design and reasons: [docs/e2e-openshell-design.md](docs/e2e-openshell-design.md); OpenShell notes: [docs/openshell.md](docs/openshell.md).

```text
                  Janssen Auth Server (jans, traefik: https://jans.stand.test)
                        ^ client_credentials, refreshed
                        |
               OpenShell gateway --> creates the sandbox, holds the token
                                                   |
 +-------- OpenShell sandbox (default deny) -------+------------------------+
 | agent (python3), MCP_TOKEN = placeholder                                 |
 |   --> demo page :3080                     allowed, python3 only          |
 |   --> agentgateway-e2e :3100 --> placeholder replaced by the real token  |
 |   --> anything else                       denied, OCSF record            |
 +--------------------------------------------------------------------------+
 agentgateway-e2e --> jwtAuth (Auth Server JWKS) --> extAuthz --> Cedarling --> mcp-server
```

```bash
scripts/e2e.sh                  # start the e2e profile and run the test; exit code 0 = pass
                                # first run: image pulls and Auth Server setup, several minutes
docker compose --profile e2e run --rm e2e   # run the test again on a running stand
scripts/down.sh --wipe          # stop everything and remove the Auth Server's data
```

Expected result (abridged):

```text
== Checks: chain
  PASS  1. token in the sandbox is a placeholder
  PASS  2. demo page read, nonce matches
  PASS  3. echo permitted
  PASS  4. get_sum permitted
  PASS  5. delete_records denied by Cedar
== Checks: escape attempts (all blocked by OpenShell)
  PASS  6. MCP server directly
  ...
  PASS  12. curl, not in the rule
== Checks: control run without the sandbox
  PASS  14. MCP server answers directly
== Checks: telemetry
  PASS  OCSF denial recorded: request_authority_mismatch
  ...
  PASS  Tempo: OpenShell supervisor trace links to the agent's trace 4efff1f4...
e2e PASSED
```

What the profile adds:

| Service | Role |
|---|---|
| `jans-init`, `consul`, `vault`, `postgresql`, `jans`, `traefik` | Janssen Auth Server owned by the stand ([jans/](jans/)); `jans-init` makes its CA and TLS certificate |
| `openshell-init`, `openshell-gateway` | OpenShell gateway with the Docker driver ([openshell/](openshell/)); sandboxes are sibling containers |
| `agentgateway-e2e` | A second agentgateway that trusts the Auth Server, on port 3100 ([e2e/agentgateway/config.yaml](e2e/agentgateway/config.yaml)) |
| `demo-page` | Plain HTTP page with a nonce per start, the one other thing the agent may read |
| `agent-control` | Builds the agent image and runs it once without a sandbox: the control case |
| `e2e` | Test runner ([e2e/run.sh](e2e/run.sh)); started only by `docker compose run` |

The default stand is unchanged: `scripts/up.sh`, `demo.sh` and `bench.sh` do not start or need the Auth Server or OpenShell.

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
| MCP server, directly (the e2e test's bypass target) | http://127.0.0.1:8000/mcp |
| e2e: agentgateway trusting the Auth Server | http://127.0.0.1:3100/mcp |
| e2e: demo page | http://127.0.0.1:3080 |
| e2e: Janssen Auth Server | https://127.0.0.1:8443 (`curl --resolve jans.stand.test:8443:127.0.0.1 https://jans.stand.test:8443/...`) |
| e2e: OpenShell gateway (gRPC, used by the CLI and the sandbox supervisors) | http://127.0.0.1:8080 |

In Grafana, Loki query for the gateway's access logs: `{service_name="agentgateway"}`; for one request add `| trace_id="<trace_id>"`. OpenShell's audit records: `{service_name="openshell-supervisor"}` (one OCSF JSON record per allow or deny, with binary, destination and reason).

## Layout

| Path | Purpose |
|---|---|
| [compose.yaml](compose.yaml) | All services |
| [agentgateway/config.yaml](agentgateway/config.yaml) | Gateway: JWT auth, extAuthz to Cedarling, decision enforcement, OTLP |
| [cedarling/bootstrap.json](cedarling/bootstrap.json) | Cedarling bootstrap properties |
| [cedarling/policy-store.yaml](cedarling/policy-store.yaml) | Cedar schema, policies and trusted issuer |
| [idp/](idp/) | Static "IdP": OpenID discovery + JWKS served by nginx |
| [mcp-server/](mcp-server/) | Demo MCP server (Python, FastMCP) |
| [scripts/](scripts/) | `up`, `down`, `gen-keys`, `mint-token`, `demo`, `correlate`, `bench`, `e2e` |
| [bench/](bench/) | Latency benchmark client and in-process Cedarling timer |
| [jans/](jans/) | e2e: Janssen Auth Server services, certificate init, Vault setup, `setup.sh` for the agent's scopes and client |
| [openshell/](openshell/) | e2e: OpenShell gateway, the agent's provider profile (token) and sandbox network policy |
| [e2e/](e2e/) | e2e: services, the second agentgateway's config, runner image and `run.sh` |
| [agent/](agent/) | e2e: the scripted agent |
| [demo-page/](demo-page/) | e2e: the page the agent may read |
| [docs/e2e-openshell-design.md](docs/e2e-openshell-design.md) | e2e: what the test proves and why it is built this way |
| [docs/openshell.md](docs/openshell.md) | OpenShell reference notes: setup in Docker, policies, providers, telemetry, gotchas |
| [docs/tracing.md](docs/tracing.md) | How the W3C trace id enters agentgateway and where it goes next |
| [docs/sidecar-changes.md](docs/sidecar-changes.md) | What the Flask sidecar needs for proper tracing and OTEL logs |
| [docs/lock-server.md](docs/lock-server.md) | Optional: Cedarling TRACE records to a Janssen Lock Server |

## Configuration knobs

Environment variables read by `compose.yaml` (put them in `.env`, which git ignores):

| Variable | Default |
|---|---|
| `AGENTGATEWAY_IMAGE` | `cr.agentgateway.dev/agentgateway:v1.7.0` |
| `CEDARLING_SIDECAR_IMAGE` | `ghcr.io/janssenproject/jans/cedarling-flask-sidecar:0.0.0-nightly` |
| `LGTM_VERSION` | `0.11.0` |
| `JANS_IMAGE` (e2e) | `ghcr.io/janssenproject/jans/all-in-one:0.0.0-nightly` |
| `OPENSHELL_VERSION` (e2e) | `0.1.10`; keep `openshell/gateway.toml` and `e2e/Dockerfile` on the same version |
| `OPENSHELL_DATA_DIR` (e2e) | `/tmp/agw-stand-openshell`; must be an absolute path, used as the same path on the host and in the gateway container |
| `JANS_ADMIN_CLIENT_ID`, `JANS_ADMIN_CLIENT_SECRET` (e2e) | stand-only config API client, pinned on the Auth Server's first start |
| `AGENT_CLIENT_ID`, `AGENT_CLIENT_SECRET` (e2e) | stand-only OAuth client of the agent |

To try a locally built sidecar or gateway, build the image and point the variable at it.

Policy and config files are mounted as directories: after editing `cedarling/*` run `docker compose restart cedarling`; agentgateway reloads `agentgateway/config.yaml` on change.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `cedarling` stays `unhealthy` | `docker compose logs cedarling`: usually a policy store parse error, printed with the failing field |
| All calls `403` | Check that `idp` serves `/jwks.json` and the token is fresh (`TOKEN_TTL`, default 1 h); `scripts/gen-keys.sh --force` changes the key, so mint new tokens |
| `correlate.sh` finds nothing | Tempo and Loki ingest with a few seconds of delay; retry. Records older than `LOOKBACK_SECONDS` (default 3600) are not searched |
| Port already in use | Another stand (e.g. `examples/mcp-telemetry`) holds 3000/4317; stop it |
| e2e: `setup.sh` fails with `401` from the token endpoint | The Auth Server's data predates the pinned admin client; `scripts/down.sh --wipe` and start again |
| e2e: `the OpenShell gateway could not get a token from the Auth Server` | `docker compose logs openshell-gateway \| grep refresh`; the Auth Server must be healthy and `jans-init` must have made `ca.crt` |
| e2e: sandbox fails with `No such file or directory (os error 2)` | The runner image has no ssh client; rebuild it: `docker compose --profile e2e build e2e` |
| e2e: calls through agentgateway-e2e time out | It started before the Auth Server served its JWKS and exited; `docker compose --profile e2e up -d agentgateway-e2e` |
| e2e: a sandbox is left after an interrupted run | `scripts/down.sh` removes sandboxes labelled `agw-stand` |
