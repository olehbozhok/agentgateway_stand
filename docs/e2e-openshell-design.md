# Design: end-to-end test with an agent in an OpenShell sandbox

Status: implemented (`scripts/e2e.sh`, all checks pass from a clean start). Lock/TRACE is a later stage. OpenShell facts used here, and how they were checked: [openshell.md](openshell.md).

## Goal

Show one chain working end to end, and show that it cannot be bypassed:

> An agent running in an OpenShell sandbox calls MCP tools through agentgateway, using an access token issued by the Janssen Auth Server. agentgateway asks Cedarling for every tool call.

The test passes only if all of these hold:

1. A tool call that the policies permit reaches the MCP server.
2. A correct tool call that the policies deny never reaches the MCP server, even though the agent sends it.
3. The agent cannot reach the MCP server, or anything else, by any path other than the ones its sandbox policy names, and cannot redirect an allowed name to another address.
4. The agent never holds the client secret or the access token.
5. Every allow and deny, in OpenShell, agentgateway and Cedarling, can be found in Grafana from the agent's trace id.

## Roles

| Component | Role |
|---|---|
| Janssen Auth Server | Issues the access token (`client_credentials`) |
| OpenShell gateway | Gets the token from the Auth Server and refreshes it; manages the sandbox |
| OpenShell supervisor | Enforces the sandbox policy; puts the real token on the agent's requests to agentgateway |
| Agent | Scripted Python process in the sandbox: reads the demo page, calls tools, then tries to escape |
| Demo page | Plain HTTP page with data the agent is allowed to read |
| agentgateway (`agentgateway-e2e`) | Policy enforcement point: verifies the JWT, asks Cedarling, enforces the decision |
| Cedarling (Flask sidecar) | Policy decision point: Cedar policies over the token's scopes |
| MCP server | The protected tools (`echo`, `get_sum`, `delete_records`) |
| LGTM | Collects traces and logs from all of the above |

Cedarling runs only behind agentgateway, not inside the agent: a check inside the agent protects nothing, because the agent can skip it.

## Flow

```text
 Janssen Auth Server <-- client_credentials (client secret) -- OpenShell gateway
                                                                     |
                                                       token, refreshed before expiry
                                                                     v
 +-------------------- OpenShell sandbox --------------------+   supervisor (proxy)
 | sh                                                         |        |
 |  +- agent (python3), env MCP_TOKEN = placeholder           |        |
 |  |   GET  demo page :3080 ---------------------------------+--> allowed --> demo page
 |  |   POST :3100/mcp, Bearer <placeholder>, traceparent ----+--> allowed, placeholder --> real token
 |  |                                                         |        --> agentgateway-e2e --> jwtAuth --> extAuthz --> Cedarling
 |  |                                                         |                             --> MCP server (only on permit)
 |  |   anything else ----------------------------------------+--> denied, OCSF record
 |  +- curl (probe) ------------------------------------------+--> denied: binary not in the rule
 +------------------------------------------------------------+
```

## Decisions

1. **Everything runs in Docker; nothing is installed on the host.** The OpenShell gateway runs as a Compose service; its CLI runs in the test runner image; sandboxes are sibling containers created through the Docker socket. OpenShell is pinned to `0.1.10`. Its data directory is an absolute path used identically on the host and in the gateway container, because the gateway passes it to Docker as a bind-mount source.

2. **The stand owns its Auth Server.** The `e2e` profile starts the Janssen all-in-one server with Consul, Vault, PostgreSQL and Traefik, adapted from `automation/start_janssen_aio_demo.sh` in the jans repo: relative paths, named volumes, a CA and certificate made by an init container, Traefik configured from a file. Its name `jans.stand.test` is an alias of Traefik on the Compose network, so every service reaches it by its public name without host entries.

3. **The agent never talks to the Auth Server and never sees the secret or the token.** An OpenShell provider for agentgateway declares the token as an `oauth2_client_credentials` credential (`client_secret_basic`): the OpenShell gateway mints it and refreshes it 120 s before it expires (Janssen tokens live 300 s). The agent sees only a placeholder, sends it as `Authorization: Bearer <placeholder>`, and the supervisor replaces it with the token only on requests to agentgateway. The OpenShell gateway trusts the stand CA through `SSL_CERT_FILE`.

4. **One OAuth client for the agent, created by the runner through the config API.** The config API is called with the all-in-one server's test client, whose id and secret are pinned through `CN_CONFIG_API_TEST_CLIENT_*` on the server's first start. The agent's client has grant type `client_credentials`; scopes `mcp:echo` and `mcp:sum`, not `mcp:admin`, so the deny case is real; `accessTokenAsJwt = true` (Janssen issues opaque tokens by default); `additionalAudience = agentgateway-stand` (otherwise `aud` holds only the `client_id`). The config API requires a redirect URI even for this client; a never-used one is set. The script updates an existing client, so it runs on every test.

5. **Cedarling trusts both issuers, each with its own token type.** Cedarling requires one name per issuer and one token entity type per issuer, and names the context key after the issuer. The Auth Server is the trusted issuer `Jans` with token type `Jans::Access_Token` (`context.tokens.jans_access_token`); the static IdP stays `Stand` with `Stand::Access_Token`. Each policy accepts the scope from either token. With signature and status validation disabled, Cedarling does not fetch the issuer's discovery document at start, so the default profile starts without the Auth Server.

6. **A second agentgateway for the e2e profile.** agentgateway exits at start when a JWKS cannot be loaded, so the Auth Server cannot be added to the default gateway without making the whole stand depend on it. `agentgateway-e2e` (host port 3100) has the same `/mcp` route with the Auth Server as its only issuer, starts after the Auth Server is healthy, and uses the same Cedarling sidecar and MCP server. The default gateway, `demo.sh` and `bench.sh` are unchanged.

7. **The sandbox policy allows exactly two destinations, both for `python3` only**: `agentgateway-e2e` (through the provider) and the demo page. Both are on the Docker host and are reached as `host.docker.internal:<port>`; inside the sandbox `127.0.0.1` is the sandbox's own loopback.

8. **The sandbox's main process is `sh`, not `python3`.** OpenShell lets child processes inherit an allowed binary's permission. With `sh` as the main process, `python3` (the agent) and `curl` (the wrong-binary probe) are siblings, and the per-binary rule can be tested.

9. **The demo page is plain HTTP and returns a nonce generated per start**; it also writes the nonce to a volume the runner reads. A nonce from anywhere else, such as a cached or spoofed response, fails the test. The page never reflects request headers.

10. **Bypass targets are reachable on purpose.** The MCP server is published on the host (port 8000). Otherwise a blocked direct call would only show that a port is closed. A control run of the agent image without OpenShell reaches the MCP server directly; that shows the blocks come from the sandbox. The control run is also non-root.

11. **OpenShell telemetry goes to the stand's LGTM**: traces, OCSF audit events and metrics over OTLP to `host.docker.internal:4317`, which the gateway container and the host-networked supervisors both reach. The agent sends a `traceparent` on every request; OpenShell forwards it unchanged, so agentgateway and Cedarling join the agent's trace, and the supervisor's request span links to that trace id.

12. **The runner keeps the sandbox until the telemetry checks are done.** The supervisor exports in batches, and deleting the sandbox right after the agent exits drops the last batch. The runner waits for the last expected OCSF record and for the supervisor's linked span, polling for up to a minute each, and deletes the sandbox on exit. It reads the supervisor's span links from the traces themselves, because a TraceQL `link:traceID` search lags behind ingestion.

13. **One command**: `scripts/e2e.sh` starts the `e2e` profile and runs the runner (`docker compose --profile e2e run --rm e2e`); exit code 0 means every check passed. `scripts/down.sh --wipe` removes everything, including sandboxes and the OpenShell data directory.

## Checks

### Chain

| # | Action (in the sandbox, `python3`) | Expected |
|---|---|---|
| 1 | Read `MCP_TOKEN` | A placeholder, not a JWT |
| 2 | Read the demo page | `200`; nonce matches the page's |
| 0 | MCP `initialize` through agentgateway | `200` and a session |
| 3 | `tools/call echo` | `200`, tool result |
| 4 | `tools/call get_sum` | `200`, tool result |
| 5 | `tools/call delete_records` | `403` |

### Escape attempts (all must fail)

| # | Action | OCSF reason |
|---|---|---|
| 6 | `python3` to the MCP server's published port | `transparent_tcp_mapping_denied` |
| 7 | `python3` to an external host (`example.com`) | no matching policy |
| 8 | `python3` to the host's real IP on the agentgateway port, with the allowed `Host` header | `transparent_tcp_policy_denied` |
| 9 | `python3` to agentgateway with `Host: evil.example` | `request_authority_mismatch` (HTTP `403` from the proxy) |
| 10 | Append to `/etc/hosts` | Landlock `PermissionError` |
| 11 | `python3` sends its own DNS query (UDP `8.8.8.8:53`) | `policy_dns_ineligible` |
| 12 | `curl` (sibling of the agent) to agentgateway | `binary '/usr/bin/curl' not allowed` |
| 13 | `python3` sends the placeholder to the MCP server's port | denied; the real token never leaves |

### Control (no sandbox)

| # | Action | Expected |
|---|---|---|
| 14 | Same image, no sandbox, case 6 | MCP server answers |

### Telemetry

| Check | Where |
|---|---|
| OCSF denials with the five reasons above, for this sandbox | Loki, `{service_name="openshell-supervisor"}` |
| The denied call has `authz.decision = false` and `403` | Loki, agentgateway access log, by the call's trace id |
| The permitted call has an upstream span `tools/call tools_echo` | Tempo, by the call's trace id |
| The denied call has an `ExtAuthz` span and no upstream span: the MCP server was not called | Tempo, by the call's trace id |
| A supervisor `openshell.http.request` span links to the denied call's trace id | Tempo |

## Known limits

| Limit | Why |
|---|---|
| The secret stays hidden only while upstreams do not reflect it | An echo upstream returned the real token to the agent in the spike. Neither agentgateway nor the demo page reflects request headers, and case 13 checks that no other destination receives the token |
| DNS rebinding through a controlled DNS server is not tested | The supervisor resolves names with its container's resolver, which the Docker driver cannot change. Cases 10 and 11 cover redirection attempts by the agent |
| OpenShell marks WSL2 support "experimental" | Version pinned; the test runs on WSL2 with Docker Desktop |

## Later stages

- **Lock/TRACE**: Cedarling decisions sent to a Lock Server, reusing the TRACE stand in `trace_feature/trace`; the stand's Auth Server already runs with Lock enabled.
- **Cedarling JWT signature validation**: turn on `CEDARLING_JWT_SIG_VALIDATION` once the sidecar trusts the stand CA, so the decision point does not rely only on the gateway.
- **LLM agent**: the same sandbox and policy with a model choosing the tools; its API key through an OpenShell provider.
