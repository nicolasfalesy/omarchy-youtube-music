#!/usr/bin/env python3
"""A stand-in for the app's REST API, for tests/qml only.

tests/qml/run starts it inside the tests' own network namespace on
127.0.0.1:26599 (never the app's port). /api/v1/huge sends 64 MiB of junk;
/api/v1/endless streams junk (about 32 MB/s) until the client hangs up;
/api/v1/slow answers after 0.3 s; /api/v1/stats says how much of
the huge answer went out,
and counts every POST by path (POST /api/v1/reset clears the counts).
"""
import http.server, json, socketserver, sys, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 26599
stats = {"hugeSent": 0, "hugeDone": False, "posts": {}}

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send_json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/api/v1/stats":
            return self.send_json(stats)
        if self.path == "/api/v1/like-state":
            return self.send_json({"state": "LIKE"})
        if self.path == "/api/v1/slow":
            time.sleep(0.3)
            return self.send_json({"state": "LIKE"})
        if self.path == "/api/v1/endless":
            stats["hugeSent"] = 0
            stats["hugeDone"] = False
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            chunk = b"x" * 65536
            frame = b"%x\r\n" % len(chunk) + chunk + b"\r\n"
            try:
                while stats["hugeSent"] < (1 << 30):
                    self.wfile.write(frame)
                    stats["hugeSent"] += len(chunk)
                    time.sleep(0.002)
                stats["hugeDone"] = True
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True
            return
        if self.path == "/api/v1/huge":
            stats["hugeSent"] = 0
            stats["hugeDone"] = False
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(64 << 20))
            self.end_headers()
            chunk = b"x" * 65536
            try:
                for _ in range(1024):
                    self.wfile.write(chunk)
                    stats["hugeSent"] += len(chunk)
                stats["hugeDone"] = True
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

def _post(self):
    n = int(self.headers.get("Content-Length") or 0)
    if n: self.rfile.read(n)
    if self.path == "/api/v1/reset":
        stats["posts"] = {}
    else:
        stats["posts"][self.path] = stats["posts"].get(self.path, 0) + 1
    self.send_response(204)
    self.send_header("Content-Length", "0")
    self.end_headers()
H.do_POST = _post

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

S(("127.0.0.1", PORT), H).serve_forever()
