#!/usr/bin/env bash
# Latency benchmark of the Cedarling sidecar path vs. gateway baselines (see bench/bench.py).
# The stand must be up (scripts/up.sh). Results: bench-results/<timestamp>/bench.{md,json}.
#
# Usage: scripts/bench.sh [bench.py options]
#   scripts/bench.sh                                  full run, ~12 min
#   scripts/bench.sh --rounds 200 --waits 50 --wait-budget 20 --seconds 5   quick check
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

out="bench-results/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"
token=$(TOKEN_TTL=86400 scripts/mint-token.sh bench mcp:echo)

# Host and image facts next to the numbers, so a result can be read later.
{
  echo "date: $(date -u +%FT%TZ)"
  echo "host: $(uname -srm)"
  echo "cpus: $(nproc)"
  docker compose images --format '{{.Service}} {{.Repository}}:{{.Tag}}' 2>/dev/null || true
} > "$out/env.txt"

docker compose --profile bench build -q bench
docker compose --profile bench run --rm \
  -e BENCH_TOKEN="$token" \
  -v "$PWD/$out:/out" \
  --user "$(id -u):$(id -g)" \
  bench "$@"

echo
echo "results: $out"
