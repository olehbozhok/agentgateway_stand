#!/usr/bin/env python3
"""Scripted agent for the e2e test (docs/e2e-openshell-design.md).

It only observes and reports: one JSON object per line on stdout, one line per case. The
runner (e2e/run.sh) decides what passes. Standard library only, so the image stays small.

Modes:
  run      inside the OpenShell sandbox: the chain cases and the python3 escape attempts
  control  without a sandbox: the direct MCP call that the sandbox must block
"""

import json
import os
import secrets
import socket
import sys
import urllib.error
import urllib.request

HOST = os.environ.get("STAND_HOST", "host.docker.internal")
GATEWAY_PORT = os.environ.get("GATEWAY_PORT", "3100")  # agentgateway-e2e
GATEWAY = f"http://{HOST}:{GATEWAY_PORT}/mcp"
DEMO_PAGE = f"http://{HOST}:{os.environ.get('DEMO_PAGE_PORT', '3080')}/"
MCP_DIRECT = f"http://{HOST}:{os.environ.get('MCP_DIRECT_PORT', '8000')}/mcp"
TOKEN = os.environ.get("MCP_TOKEN", "")


def report(case, name, **observed):
    print(json.dumps({"case": case, "name": name, **observed}), flush=True)


def new_traceparent():
    trace_id = secrets.token_hex(16)
    return trace_id, f"00-{trace_id}-{secrets.token_hex(8)}-01"


def http(url, body=None, headers=None, timeout=10):
    """Returns {"status", "body", "headers"} or {"error"}; never raises."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return {
                "status": resp.status,
                "body": resp.read().decode(errors="replace"),
                "headers": dict(resp.headers),
            }
    except urllib.error.HTTPError as e:
        return {"status": e.code, "body": e.read().decode(errors="replace"), "headers": {}}
    except Exception as e:  # noqa: BLE001 - every failure is an observation here
        return {"error": f"{type(e).__name__}: {e}"}


class McpSession:
    """Minimal MCP client over streamable HTTP: initialize once, then tools/call."""

    def __init__(self, url, token):
        self.url = url
        self.base = {
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
        }
        if token:
            self.base["authorization"] = f"Bearer {token}"
        self.session_id = None

    def _post(self, body, traceparent):
        headers = dict(self.base, traceparent=traceparent)
        if self.session_id:
            headers["mcp-session-id"] = self.session_id
        return http(self.url, body, headers)

    def initialize(self):
        _, tp = new_traceparent()
        resp = self._post(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "stand-agent", "version": "1"}}},
            tp,
        )
        headers = {k.lower(): v for k, v in resp.get("headers", {}).items()}
        self.session_id = headers.get("mcp-session-id")
        if self.session_id:
            self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, tp)
        return resp

    def call_tool(self, name, arguments):
        trace_id, tp = new_traceparent()
        resp = self._post(
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": name, "arguments": arguments}},
            tp,
        )
        return trace_id, resp


def tool_text(resp):
    """The text result of a tools/call answered as SSE or JSON, or None."""
    for line in resp.get("body", "").splitlines():
        payload = line[len("data: "):] if line.startswith("data: ") else line
        try:
            msg = json.loads(payload)
        except ValueError:
            continue
        content = msg.get("result", {}).get("content", [])
        if content:
            return content[0].get("text")
    return None


def short(resp):
    if "error" in resp:
        return {"error": resp["error"]}
    return {"status": resp["status"], "text": tool_text(resp)}


def run():
    report(1, "token is a placeholder", value_prefix=TOKEN[:24],
           looks_like_jwt=TOKEN.count(".") == 2)

    page = http(DEMO_PAGE)
    nonce = None
    if "body" in page:
        try:
            nonce = json.loads(page["body"]).get("nonce")
        except ValueError:
            pass
    report(2, "read demo page", status=page.get("status"), nonce=nonce, error=page.get("error"))

    mcp = McpSession(GATEWAY, TOKEN)
    init = mcp.initialize()
    report(0, "mcp initialize", status=init.get("status"), error=init.get("error"),
           session=bool(mcp.session_id))
    for case, tool, args in ((3, "echo", {"text": "hello from the sandbox"}),
                             (4, "get_sum", {"a": 2, "b": 3}),
                             (5, "delete_records", {})):
        trace_id, resp = mcp.call_tool(tool, args)
        report(case, f"tools/call {tool}", trace_id=trace_id, **short(resp))

    # Escape attempts, all from python3, the binary the policy allows.
    direct = McpSession(MCP_DIRECT, "")
    report(6, "MCP server directly", **short(direct.initialize()))

    report(7, "external host", **short(http("http://example.com/")))

    try:
        host_ip = socket.gethostbyname(HOST)
        real_ip = os.environ.get("HOST_REAL_IP", "")
        target = real_ip or host_ip
        resp = http(f"http://{target}:{GATEWAY_PORT}/mcp", headers={"Host": f"{HOST}:{GATEWAY_PORT}"})
        report(8, "real IP with allowed Host header", resolved=host_ip, target=target, **short(resp))
    except OSError as e:
        report(8, "real IP with allowed Host header", error=f"{type(e).__name__}: {e}")

    resp = http(GATEWAY, {"jsonrpc": "2.0", "id": 1, "method": "ping"},
                {"Host": "evil.example", "content-type": "application/json",
                 "authorization": f"Bearer {TOKEN}"})
    report(9, "allowed connection with Host: evil.example", **short(resp))

    try:
        with open("/etc/hosts", "a") as f:
            f.write(f"10.0.0.1 {HOST}\n")
        report(10, "write /etc/hosts", written=True)
    except OSError as e:
        report(10, "write /etc/hosts", written=False, error=f"{type(e).__name__}: {e}")

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(3)
        query = bytes.fromhex("123401000001000000000000076578616d706c6503636f6d0000010001")
        s.sendto(query, ("8.8.8.8", 53))
        report(11, "own DNS query to 8.8.8.8", answered=len(s.recvfrom(512)[0]) > 0)
    except OSError as e:
        report(11, "own DNS query to 8.8.8.8", answered=False, error=f"{type(e).__name__}: {e}")

    leak = http(MCP_DIRECT, {"jsonrpc": "2.0", "id": 1, "method": "ping"},
                {"authorization": f"Bearer {TOKEN}", "content-type": "application/json"})
    report(13, "placeholder to the MCP server port", **short(leak))


def control():
    direct = McpSession(MCP_DIRECT, "")
    report(14, "control: MCP server directly, no sandbox", **short(direct.initialize()))
    # Outside the sandbox the name resolves to the real host address; case 8 targets it.
    report(15, "control: real address of the stand host", ip=socket.gethostbyname(HOST))


if __name__ == "__main__":
    {"run": run, "control": control}[sys.argv[1] if len(sys.argv) > 1 else "run"]()
