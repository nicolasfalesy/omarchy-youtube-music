"""tools/cdp-bridge against the fake app: no GUI, no network, seconds."""
import os
import stat
import subprocess
import time

from ytmtest import TOOLS, Case, Conn, wait_until


def switches(pid):
    """Times the process went to sleep and woke (voluntary + forced)."""
    with open("/proc/%d/status" % pid) as f:
        return sum(int(line.split()[1]) for line in f if "ctxt_switches:" in line)


def cpu_seconds(pid):
    fields = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


class BridgeTest(Case):
    def test_relay_each_answer_goes_to_the_connection_that_asked(self):
        self.bridge_up()
        a, b = Conn(self.sock), Conn(self.sock)
        # Both widget copies count their ids from 1.
        a.send({"id": 1, "method": "Runtime.evaluate", "sessionId": "S1", "params": {"expression": "1"}})
        b.send({"id": 1, "method": "Target.getTargets", "params": {}})
        ra, rb = a.recv(), b.recv()
        self.assertEqual((ra["id"], ra["result"]), (1, {"echo": "Runtime.evaluate"}))
        self.assertEqual(rb["id"], 1)
        self.assertIn("targetInfos", rb["result"])

    def test_events_go_to_every_connection(self):
        self.bridge_up()
        a, b = Conn(self.sock), Conn(self.sock)
        b.send({"id": 7, "method": "Target.getTargets", "params": {}})
        b.recv()  # b is registered before the event
        a.send({"id": 1, "method": "Runtime.evaluate", "params": {"expression": "fake.event"}})
        got_a = [a.recv(), a.recv()]
        self.assertIn({"method": "Fake.event", "params": {}}, got_a)
        self.assertEqual(b.recv(), {"method": "Fake.event", "params": {}})

    def test_socket_and_folder_are_private(self):
        self.bridge_up()
        self.assertEqual(stat.S_IMODE(os.stat(self.sock).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.sock)).st_mode), 0o700)

    def test_refuses_a_shared_runtime_folder(self):
        os.chmod(self.rt, 0o755)
        p = self.start_bridge()
        self.assertEqual(p.wait(timeout=5), 1)
        self.assertEqual(self.app_events("start"), [])

    def test_second_bridge_leaves_the_running_one_alone(self):
        self.bridge_up()
        second = self.start_bridge()
        self.assertEqual(second.wait(timeout=5), 0)
        time.sleep(0.3)
        self.assertEqual(len(self.app_events("start")), 1)
        c = Conn(self.sock)
        c.send({"id": 1, "method": "Target.getTargets", "params": {}})
        self.assertEqual(c.recv()["id"], 1)

    def test_stale_socket_from_a_dead_bridge_is_replaced(self):
        os.mkdir(os.path.dirname(self.sock), 0o700)
        import socket as s
        dead = s.socket(s.AF_UNIX, s.SOCK_STREAM)
        dead.bind(self.sock)
        dead.close()  # the file stays, nothing listens
        self.bridge_up()
        c = Conn(self.sock)
        c.send({"id": 3, "method": "Target.getTargets", "params": {}})
        self.assertEqual(c.recv()["id"], 3)

    def test_browser_close_quits_the_app_and_the_bridge(self):
        p = self.bridge_up()
        Conn(self.sock).send({"id": 1, "method": "Browser.close", "params": {}})
        self.assertEqual(p.wait(timeout=10), 0)
        self.assertEqual([e["why"] for e in self.app_events("quit")], ["Browser.close"])
        self.assertFalse(os.path.exists(self.sock), "the socket is removed on exit")

    def test_app_arguments_keep_ordinary_flags(self):
        self.write_flags("# a comment\n--ozone-platform=wayland\n\n--enable-features=Foo\n")
        self.bridge_up("music://x")
        argv = self.app_events("start")[0]["argv"]
        self.assertEqual(argv, ["--ozone-platform=wayland", "--enable-features=Foo",
                                "--remote-debugging-pipe", "music://x"])

    def test_debugging_switches_never_reach_the_app(self):
        # Electron honours Node's --inspect* in this build (its NodeCliInspect
        # fuse is on), which opens an unauthenticated debugger on a TCP port.
        # Chromium also reads switches with one dash, and Node reads "_" as "-".
        self.write_flags("--ozone-platform=wayland\n--inspect=127.0.0.1:9229\n--inspect-brk\n"
                         "--inspect-port=9230 --inspect_brk=1\n-remote-debugging-port=9222\n"
                         "--remote-debugging-address=0.0.0.0\n--remote-debugging-pipe\n")
        self.bridge_up("--inspect-brk-node", "--remote-debugging-port=9333", "music://ok")
        argv = self.app_events("start")[0]["argv"]
        self.assertEqual(argv, ["--ozone-platform=wayland", "--remote-debugging-pipe", "music://ok"])

    def test_node_environment_switches_are_dropped(self):
        env = dict(self.env, NODE_OPTIONS="--inspect=127.0.0.1:9229", ELECTRON_RUN_AS_NODE="1")
        self.bridge_up(env=env)
        self.assertEqual(sorted(self.app_events("start")[0]["env"]), ["ELECTRON_IS_DEV"])

    def test_a_connection_that_stops_reading_does_not_stall_the_others(self):
        self.bridge_up()
        stuck, other = Conn(self.sock), Conn(self.sock)
        # More than the socket buffers hold, and never read.
        stuck.send({"id": 1, "method": "Runtime.evaluate", "params": {"expression": "fake.big:%d" % (8_000_000)}})
        time.sleep(0.3)
        other.send({"id": 1, "method": "Target.getTargets", "params": {}})
        self.assertEqual(other.recv(timeout=2)["id"], 1)
        # The stuck one still gets its whole answer once it reads.
        self.assertEqual(len(stuck.recv(timeout=10)["result"]["blob"]), 8_000_000)

    def test_a_connection_too_far_behind_is_dropped(self):
        p = self.bridge_up()
        stuck, other = Conn(self.sock), Conn(self.sock)
        for i in range(4):  # 96 MB queued for one reader: past the cap
            stuck.send({"id": i, "method": "Runtime.evaluate", "params": {"expression": "fake.big:%d" % (24_000_000)}})
        time.sleep(2)
        other.send({"id": 5, "method": "Target.getTargets", "params": {}})
        self.assertEqual(other.recv(timeout=5)["id"], 5)
        with self.assertRaises((EOFError, ConnectionResetError)):
            while True:
                stuck.recv(timeout=10)
        self.assertIsNone(p.poll(), "the bridge keeps running")

    def test_malformed_messages_from_the_app_are_skipped(self):
        p = self.bridge_up()
        c = Conn(self.sock)
        c.send({"id": 1, "method": "Runtime.evaluate", "params": {"expression": "fake.bad"}})
        self.assertEqual(c.recv(), {"id": 1, "result": {"after": "fake.bad"}})
        self.assertIsNone(p.poll())

    def test_malformed_lines_from_a_client_are_skipped(self):
        p = self.bridge_up()
        bad, good = Conn(self.sock), Conn(self.sock)
        bad.s.sendall(b"[" * 200000 + b"]" * 200000 + b"\n" + b'{"id":{"a":1},"method":"Target.getTargets"}\n'
                      + b"\xff\xfe\n[1,2]\n")
        time.sleep(0.3)
        good.send({"id": 2, "method": "Target.getTargets", "params": {}})
        self.assertEqual(good.recv()["id"], 2)
        self.assertIsNone(p.poll())

    def test_an_answer_over_the_size_cap_becomes_an_error(self):
        self.bridge_up()
        c = Conn(self.sock)
        c.send({"id": 1, "method": "Runtime.evaluate", "params": {"expression": "fake.big:%d" % (40 * 1024 * 1024)}})
        c.send({"id": 2, "method": "Target.getTargets", "params": {}})
        first = c.recv(timeout=20)
        self.assertEqual(first["id"], 1)
        self.assertIn("error", first)
        self.assertEqual(c.recv()["id"], 2, "the next answer still arrives whole")

    def test_a_client_line_over_the_size_cap_drops_that_client(self):
        p = self.bridge_up()
        big, good = Conn(self.sock), Conn(self.sock)
        try:
            big.s.sendall(b"x" * (33 * 1024 * 1024))
        except (BrokenPipeError, ConnectionResetError):
            pass
        with self.assertRaises((EOFError, ConnectionResetError)):
            big.recv(timeout=10)
        good.send({"id": 3, "method": "Target.getTargets", "params": {}})
        self.assertEqual(good.recv()["id"], 3)
        self.assertIsNone(p.poll())

    def test_only_the_methods_the_widget_uses_reach_the_app(self):
        self.bridge_up()
        c = Conn(self.sock)
        refused = [
            ("Network.getAllCookies", {}),
            ("Storage.getCookies", {}),
            ("Target.createTarget", {"url": "https://music.youtube.com/"}),
            ("Target.exposeDevToolsProtocol", {"targetId": "T1"}),
            ("Browser.setDownloadBehavior", {"behavior": "allow"}),
            ("Page.navigate", {"url": "http://music.youtube.com/"}),
            ("Page.navigate", {"url": "https://music.youtube.com.example.org/"}),
            ("Page.navigate", {"url": "https://example.org/?u=https://music.youtube.com/"}),
            ("Page.navigate", {"url": "https://user@music.youtube.com/"}),
            ("Page.navigate", {"url": "https://music.youtube.com:8443/"}),
            ("Page.navigate", {"url": "javascript:alert(1)"}),
            ("Page.navigate", {"url": "file:///etc/passwd"}),
            ("Page.navigate", {}),
            ("Page.navigate", {"url": ["https://music.youtube.com/"]}),
        ]
        for i, (method, params) in enumerate(refused, 1):
            c.send({"id": i, "method": method, "params": params, "sessionId": "S1"})
            got = c.recv()
            self.assertEqual(got["id"], i, method)
            self.assertIn("error", got, "%s %s was let through" % (method, params))
        allowed = [("Target.getTargets", {}), ("Target.attachToTarget", {"targetId": "T1", "flatten": True}),
                   ("Runtime.evaluate", {"expression": "1"}), ("Page.navigate", {"url": "https://music.youtube.com/"}),
                   ("Page.navigate", {"url": "https://music.youtube.com/library?x=1"})]
        for i, (method, params) in enumerate(allowed, 100):
            c.send({"id": i, "method": method, "params": params})
            got = c.recv()
            self.assertEqual(got["id"], i)
            self.assertNotIn("error", got, method)
        arrived = [(e["method"], e["url"]) for e in self.app_events("cdp")]
        self.assertEqual(arrived, [(m, p.get("url")) for m, p in allowed])
        c.send({"id": 200, "method": "Browser.close"})
        self.assertEqual(c.recv()["id"], 200)

    def journal_since(self, before):
        return [line for line in self.syslog_lines()[before:] if "cdp-bridge[" in line]

    def test_a_failed_start_is_logged_to_the_journal(self):
        # The widget starts the bridge detached, with stderr on /dev/null.
        before = len(self.syslog_lines())
        os.chmod(self.rt, 0o755)
        self.assertEqual(self.start_bridge().wait(timeout=5), 1)
        self.assertTrue(wait_until(lambda: any("not a private directory" in line for line in self.journal_since(before)), 2),
                        self.journal_since(before))

    def test_dropped_flags_and_refusals_are_logged_to_the_journal(self):
        before = len(self.syslog_lines())
        self.write_flags("--inspect=127.0.0.1:9229\n")
        self.bridge_up()
        c = Conn(self.sock)
        c.send({"id": 1, "method": "Network.getAllCookies"})
        c.recv()
        lines = lambda: self.journal_since(before)
        self.assertTrue(wait_until(lambda: any("ignoring --inspect " in line for line in lines()), 2), lines())
        self.assertTrue(wait_until(lambda: any("Network.getAllCookies" in line for line in lines()), 2), lines())
        self.assertFalse(any("9229" in line for line in lines()), "only the switch name is logged")

    def test_a_big_answer_costs_the_bridge_little_cpu(self):
        # Measured 2026-10-01: 24 MB took 1.2 s of bridge CPU before the
        # buffer and id-swap change, about 20 ms after. The limit leaves room
        # for slow machines but fails on the old quadratic path.
        p = self.bridge_up()
        c = Conn(self.sock)
        costs = []
        for i in range(3):
            before = cpu_seconds(p.pid)
            c.send({"id": i, "method": "Runtime.evaluate", "params": {"expression": "fake.big:24000000"}})
            self.assertEqual(len(c.recv(timeout=30)["result"]["blob"]), 24_000_000)
            costs.append(cpu_seconds(p.pid) - before)
        self.assertLess(sorted(costs)[1], 0.25, costs)

    def test_answers_in_other_shapes_still_route(self):
        self.ctl_on("spaced")  # {"result": ..., "id": N}: the JSON path
        self.bridge_up()
        a, b = Conn(self.sock), Conn(self.sock)
        a.send({"id": "x", "method": "Target.getTargets", "params": {}})
        b.send({"id": 1, "method": "Runtime.evaluate", "params": {"expression": "1"}})
        self.assertEqual(a.recv()["id"], "x")
        self.assertEqual(b.recv(), {"id": 1, "result": {"echo": "Runtime.evaluate"}})

    def test_an_answer_with_a_raw_newline_never_breaks_the_framing(self):
        self.bridge_up()
        c = Conn(self.sock)
        c.send({"id": 1, "method": "Runtime.evaluate", "params": {"expression": "fake.newline"}})
        c.send({"id": 2, "method": "Runtime.evaluate", "params": {"expression": "1"}})
        self.assertEqual(c.recv()["id"], 2, "the broken answer is dropped whole, the next one arrives")

    def test_an_idle_bridge_does_not_wake_up(self):
        # It used to poll the app every second (a 1 s select timeout).
        p = self.bridge_up()
        Conn(self.sock).close()
        time.sleep(0.5)
        before = switches(p.pid)
        time.sleep(3)
        self.assertLessEqual(switches(p.pid) - before, 1)

    def test_sigterm_stops_the_bridge_at_once(self):
        p = self.bridge_up()
        time.sleep(0.2)
        t0 = time.monotonic()
        p.terminate()
        self.assertTrue(wait_until(lambda: not os.path.exists(self.sock), 0.5), "socket still there 0.5 s after SIGTERM")
        p.wait(timeout=5)
        self.assertLess(time.monotonic() - t0, 2)
        self.assertTrue(wait_until(lambda: self.app_events("quit"), 2), "the app quit on its pipe closing")

    def test_the_bridge_ends_when_the_app_dies(self):
        p = self.bridge_up()
        os.kill(self.app_events("start")[0]["pid"], 9)
        self.assertEqual(p.wait(timeout=2), 0)
        self.assertFalse(os.path.exists(self.sock))


class SourcePackageTest(Case):
    """The AUR source package pear-desktop: /usr/bin/pear-desktop runs the
    system electronNN on /usr/lib/pear-desktop/app.asar. The bridge starts
    that Electron itself (its /usr/bin/electronNN wrapper would pass its own
    flags files on unfiltered), in the same argument order, and filters
    every flags file the two launchers read."""

    def test_starts_the_system_electron_on_the_app(self):
        exe, asar = self.use_source_package()
        self.write_flags("--ozone-platform=wayland\n# a comment\n--inspect=127.0.0.1:9229\n  -remote-debugging-port=9\n",
                         name="electron42-flags.conf")
        self.write_flags("--enable-features=X --remote-debugging-port=9222\n--inspect-brk\n", name="pear-flags.conf")
        self.write_flags("--only-for-the-bin-package\n")
        self.bridge_up("music://x")
        start = self.app_events("start")[0]
        self.assertEqual(start["argv"], ["--ozone-platform=wayland", asar, "--enable-features=X",
                                         "--remote-debugging-pipe", "music://x"])
        self.assertIn("ELECTRON_FORCE_IS_PACKAGED", start["env"])
        c = Conn(self.sock)
        c.send({"id": 1, "method": "Browser.close"})
        self.assertEqual(c.recv()["id"], 1)

    def test_falls_back_to_the_shared_electron_flags_file(self):
        _, asar = self.use_source_package(electron="electron43")
        self.write_flags("--from-the-shared-file\n", name="electron-flags.conf")
        self.bridge_up()
        self.assertEqual(self.app_events("start")[0]["argv"], ["--from-the-shared-file", asar, "--remote-debugging-pipe"])

    def test_which_names_the_installed_app(self):
        r = subprocess.run([os.path.join(TOOLS, "cdp-bridge"), "--which"], env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual((r.returncode, r.stdout), (0, "/opt/YouTube Music/youtube-music\n\n"))
        exe, asar = self.use_source_package()
        r = subprocess.run([os.path.join(TOOLS, "cdp-bridge"), "--which"], env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual((r.returncode, r.stdout), (0, exe + "\n" + asar + "\n"))

    def test_nothing_installed_is_said_plainly(self):
        self.use_source_package()
        os.remove(self.env["NIC_YTM_LAUNCHER"])
        before = len(self.syslog_lines())
        p = self.start_bridge()
        self.assertEqual(p.wait(timeout=5), 1)
        with open(p.errfile) as f:
            self.assertIn("not installed", f.read())
        self.assertEqual(self.app_events("start"), [])
        self.assertTrue(wait_until(lambda: any("not installed" in l for l in self.syslog_lines()[before:]), 2))


def race_once(case):
    """Two bridges started at the same moment (two widget copies waking the
    app, or the menu entry and a wake). Exactly one app must start, nothing may
    crash, and the socket must answer."""
    first, second = case.start_bridge(), case.start_bridge()
    case.assertTrue(wait_until(lambda: os.path.exists(case.sock) and case.app_events("start")))
    time.sleep(0.5)  # a second app, if any, has started by now
    starts = len(case.app_events("start"))
    errs = ""
    for p in (first, second):
        with open(p.errfile, errors="replace") as f:
            errs += f.read()
    c = Conn(case.sock)
    c.send({"id": 1, "method": "Target.getTargets", "params": {}})
    answered = c.recv()["id"] == 1
    c.send({"id": 2, "method": "Browser.close", "params": {}})
    c.close()
    for p in (first, second):
        p.wait(timeout=10)
    return starts, "Traceback" in errs, answered


class BridgeRaceTest(Case):
    def test_two_bridges_at_once_start_one_app(self):
        for _ in range(3):
            self.tearDown()
            self.setUp()
            self.assertEqual(race_once(self), (1, False, True))
