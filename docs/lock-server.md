# Optional: Cedarling TRACE records to a Janssen Lock Server

> **Status: not run on this stand.** The steps follow the Cedarling property reference and the separate Lock stand used for TRACE development; expect to adjust them. The base stand does not need Lock.

With TRACE enabled, Cedarling signs one `AUTHORIZATION_DECISION` record per decision that has a `TraceContext` and sends it to the Lock Server bulk endpoint in the background. The decision itself is never delayed. On this stand the `TraceContext` comes from the `Audit-*` headers that agentgateway sets, so the record's `trace_execution_id` equals the W3C trace id of the request.

## What you need

1. **A running Lock Server.** Lock ships with the Janssen server; the simplest local option is the Janssen all-in-one demo (`automation/start_janssen_aio_demo.sh` in the [jans](https://github.com/JanssenProject/jans) repo, PostgreSQL, ~10 min on first start). It is served at `https://demoexample.jans.io` with a self-signed certificate.
2. **Host name resolution.** The AIO certificate and well-known document use `demoexample.jans.io`:
   - on the host (WSL: the Linux distro), add `127.0.0.1 demoexample.jans.io` to `/etc/hosts`. WSL may regenerate `/etc/hosts` on restart unless `/etc/wsl.conf` has `[network]` `generateHosts = false`;
   - inside the `cedarling` container, the override below maps the name to the Docker host with `extra_hosts: demoexample.jans.io:host-gateway`.
3. **Lock configured for TRACE**: TRACE scopes for the client, the Cedarling DCR script granting `trace.write`, and a producer key registered for `AUTHORIZATION_DECISION`.
4. **A `.cjar` policy store.** TRACE puts the hash of the policy store archive (`bundle_hash`) into each record and refuses to start with a YAML/JSON or directory store. Serve the stand's policies as a `.cjar`, e.g. from Lock's policy store endpoint, and point `CEDARLING_POLICY_STORE_URI` at it.
5. **An Ed25519 signing key**, PKCS#8 PEM: `openssl genpkey -algorithm ed25519 -out generated/trace-key.pem`. Register its public key in Lock; Cedarling's default `kid` is the RFC 7638 thumbprint `sha256:<hex>`, logged at start-up.

## Configuration

Copy [lock/bootstrap.lock.example.json](../lock/bootstrap.lock.example.json) to `lock/bootstrap.lock.json` (git-ignored), fill in the SSA (or a pre-issued access token) and the policy store URI, and add `compose.override.yaml` (git-ignored):

```yaml
services:
  cedarling:
    environment:
      CEDARLING_BOOTSTRAP_CONFIG_FILE: /lock/bootstrap.lock.json
    volumes:
      - ./lock:/lock:ro
      - ./generated/trace-key.pem:/run/secrets/trace-key.pem:ro
    extra_hosts:
      - "demoexample.jans.io:host-gateway"
```

Then `docker compose up -d cedarling`. Cedarling logs the producer id, `kid` and key thumbprint at start-up; a missing or invalid key, or a non-`.cjar` store, stops it with a configuration error.

Key properties (full list: Cedarling properties reference, sections Lock and TRACE):

| Property | Stand value |
|---|---|
| `CEDARLING_LOCK` | `enabled` |
| `CEDARLING_LOCK_SERVER_CONFIGURATION_URI` | `https://demoexample.jans.io/.well-known/lock-server-configuration` |
| `CEDARLING_LOCK_SSA_JWT` or `CEDARLING_LOCK_ACCESS_TOKEN_JWT` | from Lock |
| `CEDARLING_LOCK_ACCEPT_INVALID_CERTS` | `enabled` (self-signed AIO; REST only) |
| `CEDARLING_TRACE` | `enabled` |
| `CEDARLING_TRACE_PRODUCER_ID` | `agentgateway-stand` |
| `CEDARLING_TRACE_SIGNING_KEY` | `/run/secrets/trace-key.pem` |
| `CEDARLING_TRACE_ENDPOINT` | `discovered` (`trace_bulk_endpoint` from the well-known document) |

## Check

1. `scripts/demo.sh`, note a trace id.
2. Sidecar response / access log: `trace_record_status` should not be `not_emitted_missing_context`.
3. In Lock, the record for that `trace_execution_id` is accepted, with consecutive `sequence_number` values and no `coverage_gap_flag` / `chain_link_failure_flag`.
4. On `docker compose stop cedarling`, gunicorn calls Cedarling `shut_down()`, which flushes queued records within `GUNICORN_GRACEFUL_TIMEOUT` (default 8 s).
