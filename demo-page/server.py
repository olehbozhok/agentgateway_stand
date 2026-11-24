#!/usr/bin/env python3
"""Demo page the sandboxed agent may read: plain HTTP, a fresh nonce per start.

The nonce is also written to /state/nonce, where the e2e runner reads it: an agent that
reports the same nonce read this page, not a cached or redirected one. The page never
reflects request headers, so a token placed on a request cannot come back to the agent.
"""

import http.server
import json
import pathlib
import os
import secrets

NONCE = secrets.token_hex(16)
pathlib.Path("/state/nonce").write_text(NONCE)
# The control run of the agent image writes its result here as a non-root user.
os.chmod("/state", 0o1777)
BODY = json.dumps({"page": "agentgateway stand demo page", "nonce": NONCE}).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
