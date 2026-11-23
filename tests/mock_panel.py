# LOCKED test fixture: a stand-in for the fleet panel. Records what the agent sends.
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, outdir = int(sys.argv[1]), sys.argv[2]
os.makedirs(outdir, exist_ok=True)

REPLIES = {
    "/api/v1/enroll": {"device_token": "dev-token-123"},
    "/api/v1/report": {"target_rev": None, "poll_seconds": 900},
}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        reply = REPLIES.get(self.path)
        if reply is None:
            self.send_response(404)
            self.end_headers()
            return
        name = self.path.rsplit("/", 1)[-1]
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(outdir, name + ".json"), "wb") as f:
            f.write(body)
        with open(os.path.join(outdir, name + ".auth"), "w") as f:
            f.write(self.headers.get("Authorization", ""))
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
