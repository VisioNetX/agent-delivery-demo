#!/usr/bin/env python3
"""Stand in for Ollama and forward the demo agent's model calls to OpenRouter.

The agent asks for a fixed model name and authenticates with x-api-key.
OpenRouter wants its own model IDs and a bearer token, so this translates both.
The key stays in this process: it is read at a hidden prompt and never logged.
See "Hosted model through OpenRouter" in setup/README.md.

Usage: python3 -I hack/openrouter-proxy.py   (quit Ollama first: same port)
Env:   OPENROUTER_API_KEY (optional, else prompted)
       OPENROUTER_MODEL   (default anthropic/claude-haiku-5.5)
       PROXY_HOST         (default 127.0.0.1, which Docker Desktop forwards to)
       PROXY_PORT         (default 11434, the port the demo already uses)
"""

import getpass
import json
import os
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "https://openrouter.ai/api/v1/messages"
MODEL = os.environ.get("OPENROUTER_MODEL", "anthropic/claude-haiku-5.5")
HOST = os.environ.get("PROXY_HOST", "127.0.0.1")
PORT = int(os.environ.get("PROXY_PORT", "11434"))
KEY = os.environ.get("OPENROUTER_API_KEY") or getpass.getpass("OpenRouter key (hidden): ")

# Anthropic-only request fields that OpenRouter's docs don't promise to accept.
DROPPED_FIELDS = ("fallbacks", "output_config", "betas")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if not self.path.startswith("/v1/messages"):
            return self._reply(404, b'{"error":"not found"}')
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        asked = body.get("model")
        body["model"] = MODEL
        for field in DROPPED_FIELDS:
            body.pop(field, None)
        req = urllib.request.Request(UPSTREAM, data=json.dumps(body).encode(), method="POST", headers={
            "Authorization": f"Bearer {KEY}",
            "Content-Type": "application/json",
            "anthropic-version": self.headers.get("anthropic-version", "2023-06-01"),
        })
        started = time.time()
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                status, data = r.status, r.read()
        except urllib.error.HTTPError as e:
            status, data = e.code, e.read()
        except urllib.error.URLError as e:
            status, data = 502, json.dumps({"error": str(e.reason)}).encode()
        print(f"{asked} -> {MODEL} {status} {time.time() - started:.1f}s", flush=True)
        if status >= 400:
            print(f"  {data[:300].decode(errors='replace')}", flush=True)
        self._reply(status, data)

    def _reply(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"Forwarding {HOST}:{PORT} to OpenRouter as {MODEL}. Ctrl-C to stop.", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
