# LOCKED test fixture: a stand-in panel that hosts the customer's config. Enrol and report as usual
# (report asks for revision abc123); GET /api/v1/config/<rev>.tar.gz demands HTTP basic auth and
# records the path and Authorization header it was fetched with.
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, outdir = int(sys.argv[1]), sys.argv[2]
os.makedirs(outdir, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/api/v1/enroll":
            return self.reply({"device_token": "dev-token-123"})
        if self.path == "/api/v1/report":
            return self.reply({"target_rev": "abc123", "poll_seconds": 900})
        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/api/v1/config/"):
            auth = self.headers.get("Authorization", "")
            if not auth:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="fleet"')
                self.end_headers()
                return
            for name, value in (("path", self.path), ("auth", auth)):
                with open(os.path.join(outdir, f"config-fetch.{name}"), "w") as f:
                    f.write(value)
        self.send_response(404)
        self.end_headers()

    do_HEAD = do_GET


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
