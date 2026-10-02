#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


CONFIG = Path("/srv/fixture-config.json")
STATE = Path("/state")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        if self.path != "/config.json":
            self.send_error(404)
            return

        if self.headers.get("User-Agent") != "sing-box":
            self.send_error(403, "sing-box User-Agent required")
            return

        STATE.mkdir(parents=True, exist_ok=True)
        (STATE / "user-agent.ok").write_text(self.headers["User-Agent"], encoding="ascii")
        payload = CONFIG.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    json.loads(CONFIG.read_text(encoding="utf-8"))
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
