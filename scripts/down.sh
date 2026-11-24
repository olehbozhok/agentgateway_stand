#!/usr/bin/env bash
# Stops the stand, including the e2e profile and any sandbox OpenShell left running.
# --wipe also removes volumes (the Auth Server's data among them), the OpenShell data
# directory, and the generated key/JWKS.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

openshell_data="${OPENSHELL_DATA_DIR:-/tmp/agw-stand-openshell}"

# Sandboxes are created by the OpenShell gateway, not by Compose.
sandboxes=$(docker ps -aq --filter label=openshell.sandbox_namespace=agw-stand)
[[ -n "$sandboxes" ]] && docker rm -f $sandboxes >/dev/null

if [[ "${1:-}" == "--wipe" ]]; then
  docker compose --profile e2e --profile e2e-run --profile bench down -v --remove-orphans
  rm -rf generated idp/jwks.json
  # Written as root by the OpenShell gateway container, so removed from a container too.
  if [[ -d "$openshell_data" ]]; then
    parent=$(dirname "$openshell_data")
    docker run --rm -v "$parent:/parent" alpine:3.20 rm -rf "/parent/$(basename "$openshell_data")"
  fi
  echo "removed containers, volumes, OpenShell data, generated key and JWKS"
else
  docker compose --profile e2e --profile e2e-run --profile bench down --remove-orphans
fi
