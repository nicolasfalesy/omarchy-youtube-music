#!/usr/bin/env python3
"""PID 1 of the test namespace (started by tests/run through unshare).

Sets up the namespace, then runs the tests in a child and reaps every orphan
(the tools start things with setsid -f, and orphans land here):
  - loopback up, so the fake app can serve 127.0.0.1:26538 in here only;
  - a tmpfs on /opt with the fake app at /opt/YouTube Music/youtube-music,
    the path tools/cdp-bridge, tools/setup and tools/lock-api use;
  - /dev/log bound to a test socket; a child copies what arrives into
    $YTM_SCRATCH/syslog.log, so tests can read what a tool sent to the journal
    and nothing reaches the real one.
Usage: nsinit.py <pattern>... -- [test name...]
"""
import ctypes
import fcntl
import os
import signal
import socket
import struct
import sys
import unittest

MS_BIND = 4096
SCRATCH = os.environ["YTM_SCRATCH"]
HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
libc = ctypes.CDLL(None, use_errno=True)


def mount(src, target, fstype, flags, data=None):
    if libc.mount(src.encode() if src else None, target.encode(),
                  fstype.encode() if fstype else None, flags,
                  data.encode() if data else None) != 0:
        e = ctypes.get_errno()
        raise OSError(e, "mount %s: %s" % (target, os.strerror(e)))


def loopback_up():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ifr = struct.pack("16sH14x", b"lo", 0)
    flags = struct.unpack("16sH14x", fcntl.ioctl(s, 0x8913, ifr))[1]  # SIOCGIFFLAGS
    fcntl.ioctl(s, 0x8914, struct.pack("16sH14x", b"lo", flags | 1))  # SIOCSIFFLAGS, IFF_UP
    s.close()


def fake_app_at_opt():
    mount("tmpfs", "/opt", "tmpfs", 0, "mode=755")
    os.mkdir("/opt/YouTube Music")
    path = "/opt/YouTube Music/youtube-music"
    # exec -a keeps the app's own path as argv[0], as the real binary shows it
    # in /proc/<pid>/cmdline (lock-api and setup find the app by it).
    with open(path, "w") as f:
        f.write('#!/bin/bash\nexec -a "$0" python3 %s "$@"\n' % os.path.join(HERE, "fakeapp.py"))
    os.chmod(path, 0o755)


def syslog_sink():
    target = os.path.realpath("/dev/log")
    if not os.path.exists(target):
        return 0
    sock_path = os.path.join(SCRATCH, "devlog")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    s.bind(sock_path)
    mount(sock_path, target, None, MS_BIND)
    pid = os.fork()
    if pid == 0:
        with open(os.path.join(SCRATCH, "syslog.log"), "ab", buffering=0) as out:
            while True:
                out.write(s.recv(65536).rstrip(b"\n") + b"\n")
    s.close()
    return pid


def run_tests(patterns, names):
    sys.path[:0] = [TESTS, HERE]
    loader = unittest.TestLoader()
    if names:
        suite = loader.loadTestsFromNames(names)
    else:
        suite = unittest.TestSuite(loader.discover(TESTS, pattern=p, top_level_dir=TESTS) for p in patterns)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() and result.testsRun else 1


def main():
    if os.getpid() != 1 or os.getuid() != 0:
        sys.exit("nsinit.py runs only as PID 1 of the namespace tests/run makes")
    sep = sys.argv.index("--")
    patterns, names = sys.argv[1:sep], sys.argv[sep + 1:]
    loopback_up()
    fake_app_at_opt()
    os.environ["YTM_SINK_PID"] = str(syslog_sink())
    child = os.fork()
    if child == 0:
        code = run_tests(patterns, names)
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(code)
    code = 1
    while True:
        try:
            pid, status = os.wait()
        except ChildProcessError:
            break
        if pid == child:
            code = os.waitstatus_to_exitcode(status)
            break
    os.kill(-1, signal.SIGKILL)  # everything left in the namespace
    sys.exit(code)


if __name__ == "__main__":
    main()
