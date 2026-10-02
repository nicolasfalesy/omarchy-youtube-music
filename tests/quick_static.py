"""Static checks on the tools: they parse, and shellcheck is clean."""
import ast
import os
import shutil
import subprocess
import unittest

from ytmtest import REPO, TOOLS

SHELL = [os.path.join(TOOLS, "lock-api"), os.path.join(TOOLS, "setup"),
         os.path.join(REPO, "tests", "run"), os.path.join(REPO, "tests", "lib", "bin", "omarchy-shell")]


class StaticTest(unittest.TestCase):
    def test_python_parses(self):
        for path in (os.path.join(TOOLS, "cdp-bridge"),):
            with open(path) as f:
                ast.parse(f.read(), path)  # never py_compile: it writes __pycache__ next to the file

    def test_shell_syntax(self):
        for path in SHELL:
            r = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, path + ": " + r.stderr)

    @unittest.skipUnless(shutil.which("shellcheck"), "shellcheck is not installed")
    def test_shellcheck(self):
        r = subprocess.run(["shellcheck", "-S", "warning", *SHELL], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout)
