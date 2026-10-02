"""Shared pieces for the tests. Runs only inside the namespace tests/run makes."""
import json
import os
import signal
import socket
import subprocess
import tempfile
import time
import unittest

REPO = os.environ["YTM_REPO"]
TOOLS = os.path.join(REPO, "tools")
SCRATCH = os.environ["YTM_SCRATCH"]
LIB = os.path.dirname(os.path.abspath(__file__))
SYSLOG = os.path.join(SCRATCH, "syslog.log")
CONFIG_REL = os.path.join(".config", "YouTube Music", "config.json")
TOKEN_REL = os.path.join(".local", "state", "omarchy", "nic-youtube-music", "token")

if os.getpid() == 1 or os.getuid() != 0 or not os.environ.get("YTM_SINK_PID"):
    raise SystemExit("run the tests with tests/run (they need its private namespaces)")


def wait_until(check, timeout=5.0, step=0.02):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if check():
            return True
        time.sleep(step)
    return bool(check())


class Conn:
    """One client of the bridge's socket, speaking its newline-framed JSON."""

    def __init__(self, path, timeout=5.0):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        self.s.connect(path)
        self.buf = b""

    def send(self, obj):
        self.s.sendall(json.dumps(obj).encode() + b"\n")

    def recv(self, timeout=5.0):
        self.s.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.s.recv(1 << 20)
            if not chunk:
                raise EOFError("bridge closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def close(self):
        self.s.close()


class Case(unittest.TestCase):
    """A fresh HOME, runtime folder and fake-app control folder per test, and
    nothing of a test left running after it."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(dir=SCRATCH, prefix="t")
        self.home = os.path.join(self.dir, "h")
        self.rt = os.path.join(self.dir, "rt")
        self.ctl = os.path.join(self.dir, "ctl")
        self.bin = os.path.join(self.dir, "bin")
        for d in (self.home, self.ctl, self.bin):
            os.makedirs(d)
        os.mkdir(self.rt, 0o700)
        self.applog = os.path.join(self.dir, "app.log")
        self.sock = os.path.join(self.rt, "nic-youtube-music", "cdp.sock")
        self.env = {
            "PATH": ":".join([self.bin, os.path.join(LIB, "bin"), "/usr/local/bin", "/usr/bin", "/bin"]),
            "LANG": "C.UTF-8",
            "HOME": self.home,
            "TMPDIR": self.dir,
            "XDG_RUNTIME_DIR": self.rt,
            "XDG_CONFIG_HOME": os.path.join(self.home, ".config"),
            "XDG_DATA_HOME": os.path.join(self.home, ".local", "share"),
            "XDG_CACHE_HOME": os.path.join(self.home, ".cache"),
            "XDG_STATE_HOME": os.path.join(self.home, ".local", "state"),
            "PYTHONDONTWRITEBYTECODE": "1",
            "FAKE_LOG": self.applog,
            "FAKE_CTL": self.ctl,
            "YTM_TOOLS": TOOLS,
        }
        self.procs = []

    def tearDown(self):
        keep = {1, os.getpid(), int(os.environ["YTM_SINK_PID"])}
        for name in os.listdir("/proc"):
            if name.isdigit() and int(name) not in keep:
                try:
                    os.kill(int(name), signal.SIGKILL)
                except OSError:
                    pass
        for p in self.procs:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass

    # --- helpers ---
    def ctl_on(self, name):
        open(os.path.join(self.ctl, name), "w").close()

    def app_events(self, ev=None):
        try:
            with open(self.applog) as f:
                events = [json.loads(line) for line in f if line.strip()]
        except FileNotFoundError:
            return []
        return [e for e in events if ev is None or e["ev"] == ev]

    def write_flags(self, text, name="youtube-music-flags.conf"):
        path = os.path.join(self.env["XDG_CONFIG_HOME"], name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
        return path

    def start_bridge(self, *args, env=None, tool=None):
        err = open(os.path.join(self.dir, "bridge%d.err" % len(self.procs)), "wb")
        p = subprocess.Popen([tool or os.path.join(TOOLS, "cdp-bridge"), *args], env=env or self.env,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err)
        p.errfile = err.name
        self.procs.append(p)
        return p

    def bridge_up(self, *args, **kw):
        p = self.start_bridge(*args, **kw)
        self.assertTrue(wait_until(lambda: os.path.exists(self.sock) and self.app_events("start")),
                        "the bridge did not start the app and serve its socket")
        return p

    def config_path(self):
        return os.path.join(self.home, CONFIG_REL)

    def write_config(self, obj):
        path = self.config_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(obj, f)
        return path

    def read_config(self):
        with open(self.config_path()) as f:
            return json.load(f)

    def token_path(self):
        return os.path.join(self.home, TOKEN_REL)

    def syslog_lines(self):
        try:
            with open(SYSLOG, errors="replace") as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []
