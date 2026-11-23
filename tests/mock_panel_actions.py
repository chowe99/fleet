# LOCKED test fixture: a stand-in panel that serves queued actions.
# The test writes <outdir>/queue.json; each action is served until the agent reports a final
# result (done/failed) for it. Every report is saved as <outdir>/report-<n>.json.
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, outdir = int(sys.argv[1]), sys.argv[2]
os.makedirs(outdir, exist_ok=True)
QUEUE = os.path.join(outdir, "queue.json")


def count():
    return len([f for f in os.listdir(outdir) if f.startswith("report-")])


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path == "/api/v1/enroll":
            reply = {"device_token": "dev-token-123"}
        elif self.path == "/api/v1/report":
            with open(os.path.join(outdir, f"report-{count() + 1}.json"), "w") as f:
                json.dump(body, f)
            final = {r.get("id") for r in body.get("action_results") or [] if r.get("status") in ("done", "failed")}
            queue = json.load(open(QUEUE)) if os.path.exists(QUEUE) else []
            queue = [a for a in queue if a["id"] not in final]
            with open(QUEUE, "w") as f:
                json.dump(queue, f)
            reply = {"target_rev": None, "poll_seconds": 900}
            if queue:
                reply["actions"] = queue
        else:
            self.send_response(404)
            self.end_headers()
            return
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
