"""NB3 — shell_run runs in the OS-native shell (osenv.default_shell) and stays fail-closed:
no stdin => cancelled, and it never executes without an explicit 'y'."""
import unittest
from unittest import mock

import _common  # noqa: F401 — puts scripts/tools on sys.path
import osenv
import shell


class TestShellRun(unittest.TestCase):
    def test_cancels_without_stdin(self):
        with mock.patch("builtins.input", side_effect=EOFError):
            self.assertEqual(shell._shell_run("echo hi"), "Cancelled (no stdin).")

    def test_cancels_on_non_yes(self):
        with mock.patch("builtins.input", return_value="n"):
            self.assertEqual(shell._shell_run("echo hi"), "Cancelled by user.")

    def test_builds_os_native_argv(self):
        captured = {}

        class _R:
            returncode = 0
            stdout = "ok"
            stderr = ""

        def _fake_run(argv, **kw):
            captured["argv"] = argv
            return _R()

        with mock.patch("builtins.input", return_value="y"), \
             mock.patch("shell.subprocess.run", side_effect=_fake_run):
            out = shell._shell_run("echo hi")
        self.assertEqual(out, "ok")
        # wiring: default_shell() prefix + the command string, whatever the host OS
        self.assertEqual(captured["argv"], osenv.default_shell() + ["echo hi"])


if __name__ == "__main__":
    unittest.main()
