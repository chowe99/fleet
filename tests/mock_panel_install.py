# LOCKED test fixture: a stand-in panel for the installer test. It runs on the test host; the VMs reach
# it at http://10.0.2.2:<port> through QEMU user networking. Not running = "the panel is unreachable".
# Every request is appended to <outdir>/requests.jsonl as {"method", "path", "auth", "body"}.
# - POST /api/v1/migration-status: 401 unless "Authorization: Bearer <token>"; then 404, as the real panel
#   answers for a PC whose Windows inventory it never saw (e.g. one installed from a USB stick).
# - POST /api/v1/enroll: 401 unless body.enroll_token == <token>; then {"device_token": "dev-token-install"}.
# - POST /api/v1/report: {"target_rev": null, "poll_seconds": 900}.
# - POST /api/v1/escrow: 401 unless "Bearer dev-token-install"; then saves the body as escrow.json.
# Anything else: 404.
# Usage: mock_panel_install.py <port> <outdir> <token>
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, outdir, token = int(sys.argv[1]), sys.argv[2], sys.argv[3]
os.makedirs(outdir, exist_ok=True)
DEVICE_TOKEN = "dev-token-install"
lock = threading.Lock()


def record(entry):
    with lock, open(os.path.join(outdir, "requests.jsonl"), "a") as f:
        f.write(json.dumps(entry) + "\n")
        f.flush()
        os.fsync(f.fileno())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        try:
            body = json.loads(raw or b"null")
        except ValueError:
            body = {"_unparsed": raw.decode(errors="replace")}
        auth = self.headers.get("Authorization", "")
        record({"method": method, "path": self.path, "auth": auth, "body": body})
        if method != "POST":
            return self.reply(404, {"error": "not found"})
        if self.path == "/api/v1/migration-status":
            if auth != f"Bearer {token}":
                return self.reply(401, {"error": "unauthorised"})
            return self.reply(404, {"error": "unknown PC"})
        if self.path == "/api/v1/enroll":
            if not isinstance(body, dict) or body.get("enroll_token") != token:
                return self.reply(401, {"error": "unauthorised"})
            return self.reply(200, {"device_token": DEVICE_TOKEN})
        if self.path == "/api/v1/report":
            return self.reply(200, {"target_rev": None, "poll_seconds": 900})
        if self.path == "/api/v1/escrow":
            if auth != f"Bearer {DEVICE_TOKEN}":
                return self.reply(401, {"error": "unauthorised"})
            with lock, open(os.path.join(outdir, "escrow.json"), "w") as f:
                f.write(json.dumps(body))
            return self.reply(200, {"ok": True})
        return self.reply(404, {"error": "not found"})

    def do_POST(self):
        self.handle_any("POST")

    def do_GET(self):
        self.handle_any("GET")

    def do_HEAD(self):
        self.handle_any("HEAD")


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
