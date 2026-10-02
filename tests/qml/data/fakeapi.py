#!/usr/bin/env python3
"""A stand-in for the app's REST API, for tests/qml only.

tests/qml/run starts it inside the tests' own network namespace on
127.0.0.1:26599 (never the app's port). /api/v1/endless streams junk until
the client hangs up (about 32 MB/s); /api/v1/stats says how much went out.
"""
import http.server, json, socketserver, sys, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 26599
stats = {"hugeSent": 0, "hugeDone": False}

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
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

S(("127.0.0.1", PORT), H).serve_forever()
