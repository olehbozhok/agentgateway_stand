"""Latency benchmark: what does the Cedarling sidecar (extAuthz over HTTP) add to an MCP tool call?

Runs inside the compose network (service `bench`, profile `bench`), so every path pays the same
Docker networking cost. Scenarios:

  direct       client -> mcp-server                                   (no gateway)
  gw-plain     client -> agentgateway (jwtAuth) -> mcp-server           (gateway baseline)
  gw-cel       ... + mcpAuthorization CEL, in process                   (built-in policy engine)
  gw-extauthz  ... + extAuthz HTTP -> Cedarling sidecar + require rule  (the stand's /mcp route)
  pdp-only     client -> Cedarling sidecar /cedarling/evaluation       (PDP alone)

Phase 1 (latency): requests are sent one at a time, interleaved across scenarios in random order
per round, so slow drift of the host affects all scenarios equally. Each tool workload
(`echo` = no work, `wait` = simulated upstream API latency) is a separate run.
Phase 2 (throughput): fixed-duration closed-loop load at several concurrency levels.

Output: JSON with raw samples and a Markdown summary in /out.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import random
import statistics
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import httpx
import numpy as np
from scipy import stats

GW = os.environ.get("BENCH_GATEWAY", "http://agentgateway:3000")
MCP_DIRECT = os.environ.get("BENCH_MCP_DIRECT", "http://mcp-server:8000/mcp")
PDP = os.environ.get("BENCH_PDP", "http://cedarling:5000/cedarling/evaluation")

ROUTES = {
    "direct": MCP_DIRECT,
    "gw-plain": f"{GW}/bench/plain",
    "gw-cel": f"{GW}/bench/cel",
    "gw-extauthz": f"{GW}/mcp",
}
ACCEPT = "application/json, text/event-stream"


def tool_call(tool: str, args: dict, rid: int) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "method": "tools/call", "params": {"name": tool, "arguments": args}}


def pdp_body(token: str, tool: str) -> dict:
    # Same AuthZEN request agentgateway builds in agentgateway/config.yaml.
    return {
        "subject": {"type": "user", "id": "bench", "properties": {"tokens": [{"mapping": "Stand::Access_Token", "payload": token}]}},
        "action": {"name": 'Stand::Action::"call_tool"'},
        "resource": {
            "type": "Tool",
            "id": tool,
            "properties": {"cedar_entity_mapping": {"entity_type": "Stand::Tool", "id": tool}, "name": tool},
        },
        "context": {},
    }


def parse_rpc(resp: httpx.Response) -> dict:
    text = resp.text
    if "text/event-stream" in resp.headers.get("content-type", ""):
        data = [line[5:].strip() for line in text.splitlines() if line.startswith("data:")]
        text = data[-1] if data else "{}"
    return json.loads(text) if text else {}


@dataclass
class Session:
    """One MCP session on one scenario: initialize once, then reuse for every call."""

    name: str
    client: httpx.AsyncClient
    token: str
    session_id: str | None = None
    rid: int = 0

    def headers(self) -> dict:
        h = {"authorization": f"Bearer {self.token}", "content-type": "application/json", "accept": ACCEPT}
        if self.session_id:
            h["mcp-session-id"] = self.session_id
        return h

    async def open(self) -> None:
        if self.name == "pdp-only":
            return
        url = ROUTES[self.name]
        init = {
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "bench", "version": "1"}},
        }
        r = await self.client.post(url, json=init, headers=self.headers())
        r.raise_for_status()
        self.session_id = r.headers.get("mcp-session-id")
        await self.client.post(url, json={"jsonrpc": "2.0", "method": "notifications/initialized"}, headers=self.headers())

    async def call(self, tool: str, args: dict) -> tuple[float, bool]:
        """Returns (latency seconds, ok)."""
        self.rid += 1
        t0 = time.perf_counter()
        if self.name == "pdp-only":
            r = await self.client.post(PDP, json=pdp_body(self.token, tool), headers={"content-type": "application/json"})
            dt = time.perf_counter() - t0
            ok = r.status_code == 200 and r.json().get("decision") is True
            return dt, ok
        r = await self.client.post(ROUTES[self.name], json=tool_call(tool, args, self.rid), headers=self.headers())
        dt = time.perf_counter() - t0
        ok = r.status_code == 200 and "result" in parse_rpc(r) and not parse_rpc(r)["result"].get("isError")
        return dt, ok


@dataclass
class Series:
    samples: list[float] = field(default_factory=list)
    errors: int = 0


def summarize_ms(xs: list[float]) -> dict:
    a = np.array(xs) * 1000
    return {
        "n": int(a.size),
        "mean": float(a.mean()),
        "median": float(np.median(a)),
        "p90": float(np.percentile(a, 90)),
        "p99": float(np.percentile(a, 99)),
        "stdev": float(a.std(ddof=1)),
    }


def median_diff_ci(x: list[float], base: list[float], rng: np.random.Generator, iters: int = 4000) -> tuple[float, float, float]:
    """Median(x) - median(base) in ms, with a 95% bootstrap percentile CI."""
    xa, ba = np.array(x) * 1000, np.array(base) * 1000
    point = float(np.median(xa) - np.median(ba))
    bx = np.median(rng.choice(xa, (iters, xa.size)), axis=1)
    bb = np.median(rng.choice(ba, (iters, ba.size)), axis=1)
    lo, hi = np.percentile(bx - bb, [2.5, 97.5])
    return point, float(lo), float(hi)


async def latency_run(token: str, tool: str, args: dict, scenarios: list[str], rounds: int, warmup: int) -> dict[str, Series]:
    limits = httpx.Limits(max_connections=len(scenarios) + 2, max_keepalive_connections=len(scenarios) + 2)
    async with httpx.AsyncClient(timeout=60, limits=limits) as client:
        sessions = {s: Session(s, client, token) for s in scenarios}
        for s in sessions.values():
            await s.open()
        series = {s: Series() for s in scenarios}
        order = list(scenarios)
        for i in range(warmup + rounds):
            random.shuffle(order)
            for s in order:
                if s == "pdp-only" and tool != "echo":
                    continue
                dt, ok = await sessions[s].call(tool, args)
                if i < warmup:
                    continue
                if ok:
                    series[s].samples.append(dt)
                else:
                    series[s].errors += 1
        return {s: v for s, v in series.items() if v.samples or v.errors}


async def throughput_run(token: str, scenario: str, concurrency: int, seconds: float) -> dict:
    limits = httpx.Limits(max_connections=concurrency + 2, max_keepalive_connections=concurrency + 2)
    async with httpx.AsyncClient(timeout=60, limits=limits) as client:
        sessions = [Session(scenario, client, token) for _ in range(concurrency)]
        for s in sessions:
            await s.open()
        lat: list[float] = []
        errors = 0
        stop = time.perf_counter() + seconds

        async def worker(s: Session) -> None:
            nonlocal errors
            while time.perf_counter() < stop:
                dt, ok = await s.call("echo", {"text": "x"})
                if ok:
                    lat.append(dt)
                else:
                    errors += 1

        t0 = time.perf_counter()
        await asyncio.gather(*(worker(s) for s in sessions))
        elapsed = time.perf_counter() - t0
        out = summarize_ms(lat) if lat else {}
        out.update({"rps": len(lat) / elapsed, "errors": errors, "concurrency": concurrency})
        return out


def fmt(x: float) -> str:
    return f"{x:.2f}"


async def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--rounds", type=int, default=1000, help="rounds for the echo workload")
    p.add_argument("--warmup", type=int, default=100)
    p.add_argument("--waits", default="50,200,1000", help="simulated upstream latencies, ms")
    p.add_argument("--wait-budget", type=float, default=90, help="seconds per wait workload (sets its rounds)")
    p.add_argument("--concurrency", default="1,8,32")
    p.add_argument("--seconds", type=float, default=15, help="duration of each throughput run")
    p.add_argument("--skip-throughput", action="store_true")
    p.add_argument("--out", default="/out")
    a = p.parse_args()

    token = os.environ["BENCH_TOKEN"]
    rng = np.random.default_rng(42)
    random.seed(42)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    result: dict = {"started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "latency": {}, "throughput": {}}
    md: list[str] = []

    workloads = [("echo", {"text": "x"}, a.rounds, ["direct", "gw-plain", "gw-cel", "gw-extauthz", "pdp-only"])]
    for w in [int(x) for x in a.waits.split(",") if x]:
        per_round = 2 * (w / 1000 + 0.01)
        rounds = max(30, int(a.wait_budget / per_round))
        workloads.append((f"wait-{w}ms", {"ms": w}, rounds, ["gw-plain", "gw-extauthz"]))

    for name, args, rounds, scenarios in workloads:
        tool = "echo" if name == "echo" else "wait"
        print(f"latency: {name}, {rounds} rounds x {len(scenarios)} scenarios", file=sys.stderr, flush=True)
        series = await latency_run(token, tool, args, scenarios, rounds, min(a.warmup, rounds // 5 + 1))
        base = series["gw-plain"].samples
        rows = {}
        for s, v in series.items():
            row = summarize_ms(v.samples)
            row["errors"] = v.errors
            if s not in ("gw-plain", "pdp-only"):
                d, lo, hi = median_diff_ci(v.samples, base, rng)
                u = stats.mannwhitneyu(v.samples, base, alternative="two-sided")
                base_median_ms = statistics.median(base) * 1000
                row.update({
                    "delta_median_vs_gw_plain": d,
                    "delta_ci95": [lo, hi],
                    "mannwhitney_p": float(u.pvalue),
                    "delta_pct_of_gw_plain_median": 100 * d / base_median_ms,
                })
            rows[s] = row
        result["latency"][name] = {"rounds": rounds, "scenarios": rows, "samples_ms": {s: [x * 1000 for x in v.samples] for s, v in series.items()}}

        md.append(f"### {name} ({rounds} rounds, interleaved)\n")
        md.append("| scenario | median ms | p90 | p99 | mean | Δ median vs gw-plain, ms [95% CI] | Δ % | Mann-Whitney p | errors |")
        md.append("|---|---|---|---|---|---|---|---|---|")
        for s, r in rows.items():
            if "delta_median_vs_gw_plain" in r:
                lo, hi = r["delta_ci95"]
                delta = f"{fmt(r['delta_median_vs_gw_plain'])} [{fmt(lo)}, {fmt(hi)}]"
                pct = f"{r['delta_pct_of_gw_plain_median']:.1f}%"
                pv = f"{r['mannwhitney_p']:.2g}"
            else:
                delta, pct, pv = "–", "–", "–"
            md.append(f"| {s} | {fmt(r['median'])} | {fmt(r['p90'])} | {fmt(r['p99'])} | {fmt(r['mean'])} | {delta} | {pct} | {pv} | {r['errors']} |")
        md.append("")

    if not a.skip_throughput:
        md.append("### throughput, echo, closed loop\n")
        md.append("| scenario | concurrency | req/s | median ms | p99 ms | errors |")
        md.append("|---|---|---|---|---|---|")
        for s in ["gw-plain", "gw-cel", "gw-extauthz", "pdp-only"]:
            for c in [int(x) for x in a.concurrency.split(",")]:
                print(f"throughput: {s} c={c}", file=sys.stderr, flush=True)
                r = await throughput_run(token, s, c, a.seconds)
                result["throughput"].setdefault(s, []).append(r)
                md.append(f"| {s} | {c} | {r['rps']:.0f} | {fmt(r.get('median', 0))} | {fmt(r.get('p99', 0))} | {r['errors']} |")
        md.append("")

    (out / "bench.json").write_text(json.dumps(result))
    (out / "bench.md").write_text("\n".join(md))
    print("\n".join(md))


if __name__ == "__main__":
    asyncio.run(main())
