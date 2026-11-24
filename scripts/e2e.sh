#!/usr/bin/env bash
# Starts the e2e profile (Janssen Auth Server, OpenShell and the default stand) and runs the
# end-to-end test: an agent in an OpenShell sandbox calls MCP tools through agentgateway with a
# token from the Auth Server. Exit code 0 = every check passed.
# First start pulls images and initializes the Auth Server: several minutes.
# Design: docs/e2e-openshell-design.md
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ -f generated/signing-key.pem ]] || scripts/gen-keys.sh

# No --wait: one-shot services (certificates, the control run) exit, which --wait treats as
# failure. `run` waits for every depends_on condition of the runner, the Auth Server included.
docker compose --profile e2e up -d --build
docker compose --profile e2e run --rm e2e
