# LOCKED test fixture: a stand-in panel for disk-encryption escrow and lost/stolen PC actions.
# Same action protocol as mock_panel_actions.py: <outdir>/queue.json is served in check-in replies
# until the PC reports a final result (done/failed); every report is saved as <outdir>/report-<n>.json.
# Plus POST /api/v1/escrow: saves the body as escrow.json and the Authorization header as escrow.auth.
# While <outdir>/escrow-down exists, escrow answers 503 and appends a line to escrow-attempts.
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, outdir = int(sys.argv[1]), sys.argv[2]
os.makedirs(outdir, exist_ok=True)
QUEUE = os.path.join(outdir, "queue.json")


def count():
    return len([f for f in os.listdir(outdir) if f.startswith("report-")])


def save(name, text):
    with open(os.path.join(outdir, name), "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path == "/api/v1/enroll":
            return self.reply(200, {"device_token": "dev-token-123"})
        if self.path == "/api/v1/escrow":
            if os.path.exists(os.path.join(outdir, "escrow-down")):
                with open(os.path.join(outdir, "escrow-attempts"), "a") as f:
                    f.write("503\n")
                return self.reply(503, {"error": "unavailable"})
            save("escrow.json", json.dumps(body))
            save("escrow.auth", self.headers.get("Authorization", ""))
            return self.reply(200, {"ok": True})
        if self.path == "/api/v1/report":
            save(f"report-{count() + 1}.json", json.dumps(body))
            final = {r.get("id") for r in body.get("action_results") or [] if r.get("status") in ("done", "failed")}
            queue = json.load(open(QUEUE)) if os.path.exists(QUEUE) else []
            queue = [a for a in queue if a["id"] not in final]
            save("queue.json", json.dumps(queue))
            out = {"target_rev": None, "poll_seconds": 900}
            if queue:
                out["actions"] = queue
            return self.reply(200, out)
        self.reply(404, {"error": "not found"})


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
