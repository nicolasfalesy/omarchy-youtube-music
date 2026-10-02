"""tools/lock-api against the fake app (its API on 127.0.0.1:26538 inside the
test namespace). Every run must end with authStrategy AUTH_AT_FIRST on disk,
whatever happened (marketplace review rules 2 to 4: fail closed, check the live
state, check every write)."""
import base64
import ctypes
import json
import os
import signal
import stat
import subprocess
import time

from ytmtest import Case, TOOLS, wait_until

SECRET = "fake-secret-for-tests"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def fake_token(client, secret=SECRET):
    import hashlib
    import hmac
    head = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = b64url(json.dumps({"id": client, "iat": 1}).encode())
    sig = b64url(hmac.new(secret.encode(), (head + "." + body).encode(), hashlib.sha256).digest())
    return head + "." + body + "." + sig


def token_id(token):
    body = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))["id"]


class LockApiTest(Case):
    def setUp(self):
        super().setUp()
        self.env["FAKE_API"] = "1"

    def config(self, strategy="AUTH_AT_FIRST", clients=(), **extra):
        api = {"enabled": True, "hostname": "127.0.0.1", "port": 26538, "secret": SECRET,
               "authorizedClients": list(clients)}
        if strategy is not None:
            api["authStrategy"] = strategy
        api.update(extra)
        return self.write_config({"options": {}, "plugins": {"api-server": api}})

    def save_token(self, token):
        path = self.token_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(token + "\n")
        os.chmod(path, 0o600)

    def lock(self, timeout=90):
        p = subprocess.Popen([os.path.join(TOOLS, "lock-api")], env=self.env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.procs.append(p)
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out, err

    def assert_locked_on_disk(self):
        self.assertEqual(self.read_config()["plugins"]["api-server"]["authStrategy"], "AUTH_AT_FIRST")

    def read_token(self):
        with open(self.token_path()) as f:
            return f.read().strip()

    # --- the normal run ---
    def test_locks_and_saves_a_working_private_token(self):
        self.config()
        rc, out, err = self.lock()
        self.assertEqual(rc, 0, err)
        self.assertIn("Locked:", out)
        self.assert_locked_on_disk()
        st = os.stat(self.token_path())
        self.assertTrue(stat.S_ISREG(st.st_mode))
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o600)
        cid = token_id(self.read_token())
        self.assertIn(cid, self.read_config()["plugins"]["api-server"]["authorizedClients"])
        self.assertEqual(len(self.app_events("quit")), 1, "the app was quit (Browser.close), not killed")
        self.assertEqual(self.app_events("clobbered"), [], "config.json was written while the app ran")

    def test_already_locked_with_a_valid_token_changes_nothing(self):
        self.config(clients=["nic-bar-kept"])
        self.save_token(fake_token("nic-bar-kept"))
        rc, out, _ = self.lock()
        self.assertEqual(rc, 0)
        self.assertIn("Already locked", out)
        self.assertEqual(self.app_events("start"), [], "the app was not started")

    # --- failures still end locked ---
    def test_no_token_from_the_app_ends_locked(self):
        self.config()
        self.ctl_on("mint_empty")
        rc, out, err = self.lock()
        self.assertEqual(rc, 1)
        self.assertNotIn("Locked:", out)
        self.assertIn("gave no token", err)
        self.assert_locked_on_disk()

    def _signal_while_waiting(self, sig, code):
        self.config()
        self.ctl_on("shell_nowake")  # the app never comes up: lock-api waits
        p = subprocess.Popen([os.path.join(TOOLS, "lock-api")], env=self.env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.procs.append(p)
        self.assertTrue(wait_until(lambda: self.read_config()["plugins"]["api-server"].get("authStrategy") == "NONE", 10))
        time.sleep(0.3)
        p.send_signal(sig)
        out, err = p.communicate(timeout=30)
        self.assertEqual(p.returncode, code)
        self.assertNotIn("Locked:", out)
        self.assertIn("locked again", err)
        self.assert_locked_on_disk()

    def test_sigterm_ends_locked(self):
        self._signal_while_waiting(signal.SIGTERM, 143)

    def test_sighup_ends_locked(self):
        self._signal_while_waiting(signal.SIGHUP, 129)

    def test_sigint_ends_locked(self):
        self._signal_while_waiting(signal.SIGINT, 130)

    def test_unwritable_config_says_not_locked(self):
        # Starts open (NONE) so nothing is written before the end; the config
        # folder is then read-only, so the closing write fails. Root in the
        # namespace ignores file modes, hence a read-only bind mount.
        self.config(strategy="NONE")
        d = os.path.dirname(self.config_path())
        libc = ctypes.CDLL(None, use_errno=True)
        self.assertEqual(libc.mount(d.encode(), d.encode(), None, 4096, None), 0)
        self.assertEqual(libc.mount(None, d.encode(), None, 4096 | 32 | 1, None), 0)  # BIND|REMOUNT|RDONLY
        try:
            rc, out, err = self.lock()
        finally:
            libc.umount2(d.encode(), 2)
        self.assertEqual(rc, 1)
        self.assertNotIn("Locked:", out)
        self.assertIn("NOT LOCKED", err)

    def test_symlink_at_the_token_path_is_not_followed(self):
        self.config(strategy="NONE")  # open, so lock-api mints and writes the token
        victim = os.path.join(self.dir, "victim.txt")
        with open(victim, "w") as f:
            f.write("keep me\n")
        os.makedirs(os.path.dirname(self.token_path()))
        os.symlink(victim, self.token_path())
        rc, _, err = self.lock()
        self.assertEqual(rc, 0, err)
        with open(victim) as f:
            self.assertEqual(f.read(), "keep me\n")
        self.assertFalse(os.path.islink(self.token_path()))
        self.assertEqual(stat.S_IMODE(os.stat(self.token_path()).st_mode), 0o600)

    def test_app_that_will_not_quit_is_killed_then_locked(self):
        self.config()
        self.ctl_on("noquit")
        rc, out, err = self.lock(timeout=120)
        self.assertEqual(rc, 0, err)
        self.assertIn("Locked:", out)
        self.assert_locked_on_disk()
        self.assertEqual(self.app_events("quit"), [])
