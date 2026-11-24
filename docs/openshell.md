# OpenShell: reference notes for this stand

Context for anyone (human or AI assistant) who works on the agentgateway stand and needs OpenShell. Every statement is marked:

- **[verified]**: tried on this machine on 2026-11-24 with OpenShell `0.1.10` (WSL2 kernel `6.18.33.2-microsoft-standard-WSL2`, Docker Desktop, Docker Engine `29.9.1`, cgroup v2).
- **[docs]**: taken from the OpenShell `v0.1.10` documentation and not tried here.

## What it is

OpenShell is a runtime that runs an AI agent (any process) in a sandbox and enforces a declarative policy on what the process may touch: files (Landlock), syscalls (seccomp), network egress (a per-sandbox proxy), and credentials (providers). It is Apache-2.0, originally from NVIDIA, now a CNCF project.

- Repo: <https://github.com/ai-openshell/openshell>
- Docs: <https://docs.nvidia.com/openshell/latest/> (index for tools: <https://docs.nvidia.com/openshell/latest/llms.txt>)
- Docs sources: `docs/**/*.mdx` in the repo; for the release used here read them at tag `v0.1.10`, e.g. `https://raw.githubusercontent.com/ai-openshell/openshell/v0.1.10/docs/how-it-works/policies/schema.mdx`.
- Releases: GitHub releases; images on `quay.io/ai-openshell/{gateway,supervisor,sandbox}:<version>`.

## Components

| Component | Role |
|---|---|
| `openshell` CLI | Talks gRPC to a gateway: sandboxes, policies, providers, logs. Static musl binary |
| Gateway (`openshell-gateway`) | Control plane: stores sandboxes, policies and providers (SQLite by default), mints sandbox JWTs, drives a compute driver, exports OTLP |
| Compute driver | Creates sandboxes: `docker`, `podman`, `kubernetes`, `vm` (libkrun) |
| Supervisor | One per sandbox. Applies the policy, runs the egress proxy, resolves DNS, injects credentials, writes OCSF audit events and spans |
| Workload container | The agent itself. With the Docker driver it runs with `network=none` |

With the Docker driver each sandbox is two containers: the workload (no network) and a supervisor in host network mode (`supervisor_network_mode = "host"`, the default; `bridge` is the alternative) [docs]. The workload's TCP opens and DNS queries are intercepted with seccomp user notification and handed to the supervisor, so ignoring proxy environment variables does not bypass it [docs].

Kernel requirements, probed at sandbox start, failing closed: Landlock ABI 3+, seccomp user notification with `SECCOMP_IOCTL_NOTIF_ADDFD`, same-UID `process_vm_readv` or `/proc/<pid>/mem`, `SO_BINDTODEVICE` [docs]. On this machine all of them are present [verified]. WSL2 is listed as "experimental" by the project.

## Running it fully in Docker [verified]

Nothing is installed on the host. The official `deploy/docker/docker-compose.yml` and `gateway.toml` from the repo work with three changes:

1. **Data directory.** The gateway extracts the supervisor binary into its data directory and passes that path to Docker as a bind-mount source, so the directory must have the same absolute path on the host and in the container. The upstream file uses `/var/lib/openshell`; any absolute path works, e.g. a directory inside the stand (git-ignored). Replace it everywhere in both files.
2. **Pin versions.** Use `quay.io/ai-openshell/gateway:0.1.10` and set `sandbox_runtime_image` and `supervisor_image` in `gateway.toml` to `:0.1.10` (the upstream files use `latest`).
3. **CLI in a container.** The CLI needs an `ssh` client to stream a sandbox's output: without it `sandbox create -- <cmd>` fails with `No such file or directory (os error 2)` after the sandbox starts. Image: `FROM alpine:3.20` + `RUN apk add --no-cache openssh-client`, with the musl `openshell` binary from the release mounted or copied in.

Supervisors run in host network mode and call the gateway back on `http://127.0.0.1:8080`, so the gateway's port must be published on the host loopback. On Docker Desktop that loopback is the Docker VM's, where published ports are visible. The CLI can run either with `--network host` (`http://127.0.0.1:8080`) or on the Compose network (`http://openshell-gateway:8080`) when `gateway.toml` binds `0.0.0.0:8080`; the stand's runner does the latter. The gateway takes about 20 s after start to open its listener (it pulls the supervisor and sandbox images first), so an early CLI call is refused.

```sh
# wrapper used here; $OS_HOME holds CLI state (gateway registration), $WORK is mounted for policy files
docker run --rm -i --network host \
  -v "$OS_BIN/openshell:/usr/local/bin/openshell:ro" \
  -v "$OS_HOME:/root" -v "$WORK:/work" -w /work \
  openshell-cli openshell "$@"

openshell gateway add http://127.0.0.1:8080 --name local   # once
openshell status                                            # Status: Connected
```

The upstream `gateway.toml` sets `allow_unauthenticated_users = true` and `disable_tls = true`: fine for a local stand only.

## Sandboxes

```sh
openshell sandbox create --name demo --no-keep --from my-image:tag --policy /work/policy.yaml \
  --provider agw --env KEY=value -- sh -c '...'
openshell sandbox create --name worker --detach -- ./worker     # long-running
openshell sandbox exec -n demo -- ls -la /sandbox
openshell sandbox delete demo
openshell logs demo --source sandbox -n 200                     # do not use --level warn: it hides policy events
```

- `--from` takes a locally built image tag; it does not build Dockerfiles [docs]. Images built with the local Docker engine are used directly [verified].
- The trailing command is the main process; without `--no-keep` the sandbox stays after it exits [verified].
- `--upload` cannot be combined with a trailing command [verified]; bake files into the image instead.
- The process runs as `uid=1000(ubuntu)`, `NoNewPrivs: 1`, `Seccomp: 2` [verified].
- The default filesystem policy is Landlock read-only on `/etc` and denies reading paths such as `/opt`: a script copied to `/opt` failed with `Permission denied`; `/usr/local/bin` works [verified]. `/sandbox` is the writable workspace.
- The default image `nvcr.io/nvidia/base/ubuntu:24.04` has no `curl` or `python3` [verified].

## Network policy

Default deny. A rule lists endpoints and binaries; every listed binary may reach every listed endpoint [docs].

```yaml
version: 1
network_policies:
  agw:
    endpoints:
      - host: host.docker.internal
        port: 3000
        protocol: rest          # L7 inspection; also websocket, graphql, mcp, json-rpc, tcp
        access: full            # or read-only (GET/HEAD/OPTIONS), or explicit rules / deny_rules
        enforcement: enforce    # default is audit (log only)
    binaries:
      - path: /usr/bin/python3*
```

`openshell policy lint /work/policy.yaml` checks a file offline; `openshell policy set` and `openshell policy update` change a running sandbox; `openshell policy get <sandbox> --full` shows the effective policy including provider rules [docs].

Behaviour seen on this stand [verified]:

| Attempt from inside the sandbox | Result | OCSF reason |
|---|---|---|
| allowed binary to allowed `host:port` | allowed | `CONNECT_L7 allowed` |
| allowed binary to another port on the same host | `Errno 13 Permission denied` | `transparent_tcp_mapping_denied` |
| connect to the host's real IP (`192.168.65.254`) with an allowed `Host` header | `Errno 13` | `transparent_tcp_policy_denied` |
| allowed connection, `Host: evil.example` | HTTP `403` from the proxy | `request_authority_mismatch` + a Detection Finding |
| write to `/etc/hosts` | `PermissionError` | (Landlock) |
| own DNS query, UDP to `8.8.8.8:53` | `Errno 89` | `policy_dns_ineligible` |
| `curl` (not in the rule) to the allowed endpoint, started by `sh` | connection refused | `binary '/usr/bin/curl' not allowed in policy` |
| `curl` started **by the allowed `python3`** | **allowed** | `CONNECT_L7 allowed` |
| `127.0.0.1:<port>` | refused: the sandbox's own loopback | |

Rules to remember:

- **Child processes inherit the permission of an allowed binary** [docs, verified]. If the agent's main process is `python3` and the rule allows `python3`, everything the agent spawns is allowed too. To test per-binary rules, start the agent from a launcher that is not in any rule (`sh -c '...'`) and run the other binaries as siblings.
- **Reaching the Docker host**: use `host.docker.internal` with an explicit rule [verified]. Loopback, link-local and unspecified addresses (including `169.254.169.254`) are always blocked; exact hostnames may reach RFC 1918 addresses; wildcard hosts need `allowed_ips` [docs]. `host.openshell.internal` is documented for services on the gateway host [docs], not tried.
- **DNS**: the supervisor answers DNS for the workload with placeholder addresses (`198.18.0.x` here) and resolves the real destination itself through its trusted resolver, re-validating when the 1-30 s mapping expires [docs, verified]. The agent cannot point a name at another address. The trusted resolver is the supervisor container's own; the Docker driver has no option to set a custom resolver [docs], so DNS rebinding with a controlled DNS server cannot be staged on this stand.
- **TLS**: for inspected HTTPS endpoints the proxy terminates TLS with a per-sandbox CA, exported to the workload via `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`; `tls: skip` disables inspection and credential injection. Private upstream CAs: `[openshell.supervisor.network] additional_ca_bundle` [docs]. Plain `http://` endpoints work with L7 inspection and credential injection [verified].

## Providers (credentials)

A provider profile (YAML, imported into the gateway) declares credentials, how they are placed on requests, and the endpoints and binaries they are bound to. A provider instance holds the values [docs].

```yaml
id: stand-agw
display_name: Stand agentgateway
category: other
credentials:
  - name: mcp_token
    env_vars: [MCP_TOKEN]
    required: true
    auth_style: bearer          # basic, bearer, header, query, path, path_subtree
    header_name: authorization
endpoints:
  - host: host.docker.internal
    port: 3999
    protocol: rest
    access: full
    enforcement: enforce
binaries:
  - path: /usr/bin/python3*
```

```sh
openshell profile lint -f /work/profile.yaml
openshell profile import -f /work/profile.yaml --global
openshell provider create --name agw --type stand-agw --credential MCP_TOKEN=<value>
openshell sandbox create ... --provider agw -- ...
```

[verified] with a static value:

- The workload sees only a placeholder: `MCP_TOKEN=openshell:resolve:env:v5065996417018920340_MCP_TOKEN`.
- The agent sends `Authorization: Bearer $MCP_TOKEN`; the upstream receives the real value. This works for plain `http://` to `host.docker.internal`.
- The provider's endpoints and binaries become a generated rule `_provider_agw` in the effective policy, so no separate network rule is needed.
- Sending the placeholder to any other port or host is blocked by the network policy.
- **The secret is hidden only while the upstream does not reflect it.** An echo server that returned request headers gave the agent the real token in the response body. agentgateway does not echo headers.

OAuth2 client credentials [verified against the stand's Janssen Auth Server]: a credential declares `refresh.strategy: oauth2_client_credentials` with `token_url`, `scopes`, `refresh_before`, `max_lifetime` and material `client_id`, `client_secret` (`secret: true`). The **gateway** mints and refreshes the token; the sandbox never sees the client secret or the token, only the placeholder. Full profile: [openshell/provider-agentgateway.yaml](../openshell/provider-agentgateway.yaml). Configure it after creating the provider (with a dummy initial value):

```sh
openshell provider create --name agentgateway --type stand-agentgateway --credential MCP_TOKEN=pending
openshell provider refresh configure agentgateway \
  --credential-key MCP_TOKEN --strategy oauth2-client-credentials \
  --material client_id="$ID" --material client_secret="$SECRET" \
  --material token_endpoint_auth_method=client_secret_basic \
  --secret-material-key client_secret
openshell provider refresh rotate --credential-key MCP_TOKEN agentgateway   # mint now
openshell provider refresh status agentgateway   # STATUS refreshed, EXPIRES_AT, NEXT_REFRESH
```

- `token_endpoint_auth_method` defaults to `client_secret_post`; a Janssen client registered with `client_secret_basic` needs the material key above.
- The gateway, not the sandbox, needs network access and CA trust for `token_url`. The gateway image is distroless and reads `SSL_CERT_FILE`: pointing it at the stand CA was enough.
- The gateway logs `provider credential refresh completed ... status=refreshed expires_at=...`; with `refresh_before: "120s"` and a 300 s token, the next refresh is 3 minutes after the last.

Not suitable here: `token_grant` (proxy-side injection without a placeholder) authenticates the client with a SPIFFE JWT-SVID, which the Janssen Auth Server does not accept [docs].

## Observability

### OTLP export [verified]

```toml
[openshell.gateway.otlp]
endpoint     = "http://host.docker.internal:4317"   # gRPC; protocol = "http/protobuf" for :4318
service_name = "openshell-gateway"

[openshell.gateway.otlp.ocsf]      # audit events as OTLP log records; off by default
enabled = true

[openshell.gateway.otlp.metrics]   # off by default
enabled = true
```

- The gateway passes the endpoint to every supervisor, so it must be reachable from the gateway container and from supervisors (host network): `host.docker.internal:4317` works for both on Docker Desktop.
- `OTEL_EXPORTER_OTLP_*ENDPOINT` variables are ignored by design; `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_TRACES_SAMPLER`, `OTEL_EXPORTER_OTLP_HEADERS` are honoured [docs].
- Services seen in Tempo: `openshell-gateway`, `openshell-driver-docker`, `openshell-supervisor`; in Loki: `openshell-gateway`, `openshell-supervisor`.
- Agent traces (workload OTLP relayed by the supervisor at `192.0.0.8:4318`) need `[openshell.gateway.otlp.agent] enabled = true` [docs], not tried.

### OCSF audit events [verified]

Each supervisor decision is an OCSF JSON record in Loki (`{service_name="openshell-supervisor"}`); `openshell logs <sandbox> --source sandbox` shows a one-line form, e.g. `OCSF NET:OPEN [MED] DENIED /usr/bin/curl(64) -> httpbin.org:443 [policy:- engine:opa] [reason:no matching policy]` [docs].

Useful fields: `class_name` (`Network Activity`, `HTTP Activity`, `Detection Finding`, `SSH Activity`), `action` / `disposition` (`Allowed`, `Denied`), `status_detail` (the reason code), `firewall_rule.name` (the policy rule, e.g. `_provider_agw`), `actor.process.name`, `cmd_line`, `parent_process`, `dst_endpoint.{hostname,ip,port}`, `http_request.{http_method,url}`, `trace.uid`, `device.container.{name,image}`.

### Trace correlation [verified]

- The proxy forwards the workload's `traceparent` header upstream unchanged, so agentgateway continues the agent's trace id.
- The supervisor creates its own trace per request (spans `openshell.http.request`, `openshell.policy.evaluate`, `openshell.credential.prepare`, `openshell.upstream.send`, `openshell.http.response`). `openshell.http.request` carries a **span link** to the agent's trace id with attributes `openshell.correlation.source = http.traceparent` and `openshell.correlation.trust = workload`. The workload's trace is never used as parent [docs].
- OCSF HTTP records carry the supervisor's trace id in `trace.uid`, not the agent's.

So from the agent's trace id: agentgateway and Cedarling spans are in the same trace; the OpenShell decision is the trace that links to it.

### Metrics [docs]

Prometheus `/metrics` on the gateway only, enabled with `metrics_bind_address` under `[openshell.gateway]`, plaintext and unauthenticated. Prefixes: `openshell_server_*`, `openshell_gateway_interceptor_*`, `openshell_ocsf_*`, `openshell_supervisor_config_*`.

## Gotchas

| Symptom | Cause |
|---|---|
| `Error: × No such file or directory (os error 2)` right after `Starting sandbox` | The CLI has no `ssh` client |
| CLI `Connection refused` to `http://gateway:8080` | Use `--network host` and `http://127.0.0.1:8080` |
| `bash: /opt/x.sh: Permission denied` | Landlock filesystem policy; put files under `/usr/local/bin` or `/sandbox` |
| A binary not in the rule still gets through | It was started by an allowed binary; children inherit |
| Agent sees the real secret | The upstream reflected the request header |
| `127.0.0.1:<port>` refused | That is the sandbox loopback; use `host.docker.internal` |
| An L7 rule (`access`, `rules`, `deny_rules`) only logs | `enforcement` defaults to `audit`; set `enforce` [docs]. Connections that match no rule are denied either way [verified] |
| OCSF records or spans of a sandbox are missing | It was deleted (e.g. `--no-keep`) before the supervisor exported its last batch; keep it until the telemetry is in [verified] |
| TraceQL `{ link:traceID = "..." }` finds nothing although the link exists | The search index lags behind ingestion; fetch the supervisor's `openshell.http.request` traces and read `links` [verified] |
| `name exceeds maximum length (20 > 19)` | Sandbox names are limited to 19 characters [verified] |
| `Unknown gateway 'http://...'` | The CLI reads `OPENSHELL_GATEWAY` as a gateway **name**; do not put a URL in that variable [verified] |
| `custom provider profile '...' already exists` on import | Import does not overwrite; delete the provider and the profile first, or use `openshell profile update` [verified] |
| `provider refresh rotate` prints usage | It needs `--credential-key <KEY>` [verified] |
| Docker `--wait` reports failure for `openshell-init` style one-shots | Expected for exited one-shot services nobody depends on; start without `--wait` and let dependants wait [verified] |
