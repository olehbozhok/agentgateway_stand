"""Times Cedarling's authorize_multi_issuer in process (no HTTP, no Flask).

Runs inside the sidecar container, with the same bootstrap and policy store, to split the sidecar
latency into "Cedar decision" and "HTTP + Flask + JSON" parts.
Usage (scripts/bench.sh --inproc does this):
  docker compose exec -T -e BENCH_TOKEN=... cedarling python - < bench/cedarling_inproc.py
"""

import json
import os
import statistics
import time

from cedarling_python import (
    AuthorizeMultiIssuerRequest,
    BootstrapConfig,
    Cedarling,
    EntityData,
    TokenInput,
)

with open(os.environ.get("CEDARLING_BOOTSTRAP_CONFIG_FILE", "/cedarling/bootstrap.json")) as f:
    cfg = json.load(f)
cfg["CEDARLING_LOG_TYPE"] = os.environ.get("LOG_TYPE", "off")  # "off": decision only; "std_out": as the sidecar runs
cedarling = Cedarling(BootstrapConfig.load_from_json(json.dumps(cfg)))

token = os.environ["BENCH_TOKEN"]
resource = EntityData.from_dict({"cedar_entity_mapping": {"entity_type": "Stand::Tool", "id": "echo"}, "name": "echo"})


def once() -> float:
    req = AuthorizeMultiIssuerRequest(
        tokens=[TokenInput(mapping="Stand::Access_Token", payload=token)],
        action='Stand::Action::"call_tool"',
        resource=resource,
        context={},
    )
    t0 = time.perf_counter()
    res = cedarling.authorize_multi_issuer(req)
    dt = time.perf_counter() - t0
    assert res.is_allowed(), "expected ALLOW for echo with mcp:echo"
    return dt


for _ in range(500):
    once()
xs = sorted(once() * 1000 for _ in range(int(os.environ.get("N", "5000"))))
n = len(xs)
print(json.dumps({
    "n": n,
    "median_ms": statistics.median(xs),
    "p90_ms": xs[int(n * 0.9)],
    "p99_ms": xs[int(n * 0.99)],
    "mean_ms": statistics.fmean(xs),
}))
