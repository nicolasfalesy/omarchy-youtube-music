"""tools/setup against the fake app: it changes the app's settings only while
the app is closed (the app writes its settings back when it quits), writes
every file safely (a new temp file in the same folder, then a rename), and
ends with the API locked."""
import hashlib
import os
import stat
import subprocess

from ytmtest import Case, TOOLS

SECRET = "fake-secret-for-tests"
OFF = ("resumeOnStart", "tray", "startAtLogin")


class SetupTest(Case):
    def setUp(self):
        super().setUp()
        self.env["FAKE_API"] = "1"

    def setup_run(self, timeout=120):
        p = subprocess.Popen([os.path.join(TOOLS, "setup")], env=self.env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.procs.append(p)
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out, err

    def profile(self, **api):
        conf = {"options": {k: True for k in OFF + ("autoUpdates",)},
                "plugins": {"api-server": dict({"enabled": True, "authStrategy": "AUTH_AT_FIRST", "secret": SECRET}, **api)}}
        return self.write_config(conf)

    def assert_set_up(self):
        conf = self.read_config()
        for key in OFF:
            self.assertIs(conf["options"][key], False, key)
        api = conf["plugins"]["api-server"]
        self.assertEqual((api["enabled"], api["hostname"], api["port"], api["useHttps"]), (True, "127.0.0.1", 26538, False))
        self.assertEqual(api["authStrategy"], "AUTH_AT_FIRST")
        self.assertEqual(stat.S_IMODE(os.stat(self.token_path()).st_mode), 0o600)
        self.assertEqual(self.app_events("clobbered"), [], "a setting was written while the app ran, and the app wrote over it")
        entry = os.path.join(self.env["XDG_DATA_HOME"], "applications", "com.github.th-ch.youtube-music.desktop")
        self.assertEqual(stat.S_IMODE(os.stat(entry).st_mode), 0o644)
        with open(entry) as f:
            self.assertIn('Exec="%s/cdp-bridge" %%U' % TOOLS, f.read())

    def leftovers(self):
        found = []
        for d in (os.path.dirname(self.config_path()), self.env["XDG_CONFIG_HOME"],
                  os.path.dirname(self.token_path())):
            if os.path.isdir(d):
                found += [n for n in os.listdir(d) if n.startswith(".")]  # replace_with's temp names
        return found

    def test_running_app_is_quit_before_its_settings_change(self):
        self.profile()
        self.bridge_up()  # the app runs, with the old settings in memory
        rc, out, err = self.setup_run()
        self.assertEqual(rc, 0, err)
        self.assertIn("Done.", out)
        self.assert_set_up()
        self.assertGreaterEqual(len(self.app_events("quit")), 2, "quit by setup, then by lock-api")
        self.assertEqual(self.leftovers(), [])

    def test_first_run_starts_the_app_once_to_create_its_settings(self):
        rc, out, err = self.setup_run()
        # The fake app's first config has no API server; setup turns it on.
        self.assertEqual(rc, 0, err)
        self.assert_set_up()

    def test_app_that_will_not_quit_leaves_settings_alone(self):
        path = self.profile()
        self.bridge_up()
        self.ctl_on("shell_noquit")
        with open(path, "rb") as f:
            before = hashlib.sha256(f.read()).hexdigest()
        rc, _, err = self.setup_run()
        self.assertEqual(rc, 1)
        self.assertIn("did not quit", err)
        with open(path, "rb") as f:
            self.assertEqual(hashlib.sha256(f.read()).hexdigest(), before)

    def test_debug_port_lines_are_removed_with_a_private_backup(self):
        self.profile()
        flags = self.write_flags("--ozone-platform=wayland\n--remote-debugging-port=9222\n")
        rc, _, err = self.setup_run()
        self.assertEqual(rc, 0, err)
        with open(flags) as f:
            self.assertEqual(f.read(), "--ozone-platform=wayland\n")
        self.assertEqual(stat.S_IMODE(os.stat(flags).st_mode), 0o600)
        baks = [n for n in os.listdir(os.path.dirname(flags)) if n.startswith("youtube-music-flags.conf.bak.")]
        self.assertEqual(len(baks), 1)
        bak = os.path.join(os.path.dirname(flags), baks[0])
        self.assertEqual(stat.S_IMODE(os.stat(bak).st_mode), 0o600)
        with open(bak) as f:
            self.assertIn("--remote-debugging-port=9222", f.read())

    def test_symlinked_config_does_not_write_through_the_link(self):
        victim = os.path.join(self.dir, "victim.json")
        with open(victim, "w") as f:
            f.write("{}\n")
        real = self.profile()
        os.rename(real, real + ".real")
        os.symlink(real + ".real", real)
        os.symlink(victim, os.path.join(os.path.dirname(real), "config.json.tmp"))  # the old fixed temp name
        rc, _, err = self.setup_run()
        self.assertEqual(rc, 0, err)
        with open(victim) as f:
            self.assertEqual(f.read(), "{}\n")
        self.assertFalse(os.path.islink(real))
