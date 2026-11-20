#!/usr/bin/env bash
# Stops the stand. --wipe also removes volumes and the generated key/JWKS.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "${1:-}" == "--wipe" ]]; then
  docker compose down -v --remove-orphans
  rm -rf generated idp/jwks.json
  echo "removed containers, volumes, generated key and JWKS"
else
  docker compose down --remove-orphans
fi
