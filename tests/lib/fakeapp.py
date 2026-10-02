#!/usr/bin/env python3
"""Test stand-in for the YouTube Music app (pear-desktop). Never the real app.

It plays the parts the tools depend on, and logs what it saw as JSON lines in
$FAKE_LOG, so a test can check what reached the app:
  - start: the arguments it got, and which of a few environment names were set
    (names only);
  - the DevTools pipe (with --remote-debugging-pipe): NUL-framed JSON commands
    on fd 3, answers on fd 4, written compactly the way Chromium writes them
    ({"id":N,"result":...}); every command's method is logged ("cdp");
  - config.json: read at start (created on a first run, as the app does) and
    written back from memory when it quits, as the real app does. If the file
    changed on disk while it ran, it logs "clobbered": a tool wrote it while
    the app was up, and that write is now lost;
  - the API server (FAKE_API=1, and the config has it enabled) on
    127.0.0.1:<port>: authStrategy NONE answers anyone; otherwise only a
    Bearer JWT (HS256, the config's secret) whose id is in authorizedClients.
    POST /auth/<id> mints a token, under NONE only. Each request is logged with
    whether it carried a valid token, never the token itself.
Runtime.evaluate of "fake.big:<bytes>", "fake.event", "fake.bad" or
"fake.newline" are test
hooks (see fake()).
Control files in $FAKE_CTL: noquit (ignore Browser.close and pipe EOF),
mint_empty (mint answers {}), die_after_mint (exit right after a mint),
spaced (answers as {"result": ..., "id": N}, not Chromium's compact form).
"""
import base64
import hashlib
import hmac
import http.server
import json
import os
import secrets
import sys
import threading
import time

LOG = os.environ.get("FAKE_LOG", "")
CTL = os.environ.get("FAKE_CTL", "")
CFG = os.path.join(os.environ["HOME"], ".config", "YouTube Music", "config.json")
ENV_NAMES = ("NODE_OPTIONS", "ELECTRON_RUN_AS_NODE", "ELECTRON_IS_DEV", "ELECTRON_FORCE_IS_PACKAGED", "FAKE_API")
lock = threading.Lock()


def ctl(name):
    return bool(CTL) and os.path.exists(os.path.join(CTL, name))


def log(ev, **kw):
    if not LOG:
        return
    kw["ev"] = ev
    with lock, open(LOG, "a") as f:
        f.write(json.dumps(kw) + "\n")


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_dec(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class App:
    def __init__(self):
        if os.path.exists(CFG):
            with open(CFG, encoding="utf-8") as f:
                self.disk = f.read()
            self.mem = json.loads(self.disk)
        else:
            os.makedirs(os.path.dirname(CFG), exist_ok=True)
            self.mem = {"options": {"resumeOnStart": True, "tray": True, "startAtLogin": True,
                                    "autoUpdates": True}, "plugins": {}}
            self.disk = json.dumps(self.mem, indent=2)
            with open(CFG, "w", encoding="utf-8") as f:
                f.write(self.disk)

    @property
    def api(self):
        return self.mem.setdefault("plugins", {}).setdefault("api-server", {})

    def write_back(self):
        try:
            with open(CFG, encoding="utf-8") as f:
                now = f.read()
        except OSError:
            now = None
        if now != self.disk:
            log("clobbered")
        with open(CFG, "w", encoding="utf-8") as f:
            f.write(json.dumps(self.mem, indent=2))

    def quit(self, why):
        if ctl("noquit"):
            log("quit-ignored", why=why)
            return
        self.write_back()
        log("quit", why=why)
        os._exit(0)

    # --- API server ---
    def secret(self):
        if not self.api.get("secret"):
            self.api["secret"] = "fake-secret-" + secrets.token_hex(8)
        return self.api["secret"].encode()

    def mint(self, client):
        head = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
        body = b64url(json.dumps({"id": client, "iat": int(time.time())}).encode())
        sig = b64url(hmac.new(self.secret(), (head + "." + body).encode(), hashlib.sha256).digest())
        return head + "." + body + "." + sig

    def bearer_ok(self, header):
        if not header.startswith("Bearer "):
            return False
        parts = header[7:].strip().split(".")
        if len(parts) != 3:
            return False
        want = b64url(hmac.new(self.secret(), (parts[0] + "." + parts[1]).encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(want, parts[2]):
            return False
        try:
            client = json.loads(b64url_dec(parts[1])).get("id")
        except ValueError:
            return False
        return client in self.api.get("authorizedClients", [])

    def serve_api(self):
        app = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, code, body=b"{}"):
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                valid = app.bearer_ok(self.headers.get("Authorization", ""))
                none = app.api.get("authStrategy", "AUTH_AT_FIRST") == "NONE"
                log("api", method="GET", path=self.path, bearer=valid, answered=none or valid)
                self.reply(200 if none or valid else 401, b'{"state":0}')

            def do_POST(self):
                if not self.path.startswith("/auth/"):
                    return self.reply(404)
                client = self.path[len("/auth/"):]
                if app.api.get("authStrategy", "AUTH_AT_FIRST") != "NONE":
                    log("api", method="POST", path="/auth", minted=False)
                    return self.reply(403)
                clients = app.api.setdefault("authorizedClients", [])
                if client not in clients:
                    clients.append(client)
                log("api", method="POST", path="/auth", minted=True)
                self.reply(200, b"{}" if ctl("mint_empty") else
                           json.dumps({"accessToken": app.mint(client)}).encode())
                if ctl("die_after_mint"):  # the answer is out (unbuffered); then gone
                    log("died")
                    os._exit(1)

        http.server.HTTPServer.allow_reuse_address = True
        try:
            server = http.server.HTTPServer((self.api.get("hostname", "127.0.0.1"), int(self.api.get("port", 26538))), Handler)
        except OSError as e:
            log("api-bind-failed", error=str(e))
            return
        threading.Thread(target=server.serve_forever, daemon=True).start()

    # --- DevTools pipe ---
    def answer(self, cmd, result):
        msg = {"id": cmd["id"], "result": result}
        if "sessionId" in cmd:
            msg["sessionId"] = cmd["sessionId"]
        if ctl("spaced"):
            msg = {"result": result, "id": cmd["id"]}
            data = json.dumps(msg).encode()
        else:
            data = json.dumps(msg, separators=(",", ":")).encode()
        self.send(data)

    def send(self, data):
        data += b"\0"
        while data:
            data = data[os.write(4, data):]

    def fake(self, cmd, expr):
        """Test hooks, reached through Runtime.evaluate (a method the bridge
        lets through): fake.big:<bytes> answers that much filler, fake.event
        sends an event first, fake.bad sends malformed messages first."""
        if expr.startswith("fake.big:"):
            return self.answer(cmd, {"blob": "x" * int(expr.split(":")[1])})
        if expr == "fake.newline":  # not valid JSON: a raw newline inside a string
            return self.send(b'{"id":%d,"result":{"v":"a\nb"}}' % cmd["id"])
        if expr == "fake.event":
            self.send(json.dumps({"method": "Fake.event", "params": {}}, separators=(",", ":")).encode())
        elif expr == "fake.bad":
            # Odd things a broken peer could write: ids that are not numbers,
            # nesting deeper than any parser allows, not JSON at all.
            for junk in (b'{"id":[1],"result":{}}', b'{"id":{"a":1},"result":{}}',
                         b'{"id":true,"result":{}}', b"[" * 200000 + b"]" * 200000,
                         b"[1,2,3]", b"not json \xff"):
                self.send(junk)
        self.answer(cmd, {"after": expr})

    def serve_pipe(self):
        buf = b""
        while True:
            chunk = os.read(3, 1 << 16)
            if not chunk:
                self.quit("pipe-eof")
                while True:  # noquit: keep running with no pipe
                    time.sleep(3600)
            buf += chunk
            *raws, buf = buf.split(b"\0")
            for raw in raws:
                cmd = json.loads(raw)
                method = cmd.get("method")
                log("cdp", method=method, session=cmd.get("sessionId"), url=(cmd.get("params") or {}).get("url"))
                params = cmd.get("params") or {}
                if method == "Browser.close":
                    self.answer(cmd, {})
                    self.quit("Browser.close")
                elif method == "Runtime.evaluate" and str(params.get("expression", "")).startswith("fake."):
                    self.fake(cmd, params["expression"])
                elif method == "Target.getTargets":
                    self.answer(cmd, {"targetInfos": [{"type": "page", "url": "https://music.youtube.com/", "targetId": "T1"}]})
                elif method == "Target.attachToTarget":
                    self.answer(cmd, {"sessionId": "S1"})
                else:
                    self.answer(cmd, {"echo": method})


def main():
    log("start", pid=os.getpid(), argv=sys.argv[1:], env=[n for n in ENV_NAMES if n in os.environ])
    app = App()
    if os.environ.get("FAKE_API") == "1" and app.api.get("enabled"):
        app.serve_api()
    if "--remote-debugging-pipe" in sys.argv:
        app.serve_pipe()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
