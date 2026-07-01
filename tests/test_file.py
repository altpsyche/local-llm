"""N9 — file_read/file_write path allowlist + secrets denylist. Backs the SECURITY.md claim that
config.json (litellm key + api tokens), *.psd1, *.db, logs/, and .env* are unreadable even when
they sit inside an allowedReadPaths root (which defaults to the repo root)."""
import shutil
import tempfile
import unittest
from pathlib import Path

import _common  # noqa: F401 — puts scripts/tools on sys.path
import file  # scripts/tools/file.py


class TestFileTool(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="bob-file-"))
        (self.dir / "normal.txt").write_text("hello", encoding="utf-8")
        (self.dir / "config.json").write_text('{"litellmKey":"SUPERSECRET"}', encoding="utf-8")
        (self.dir / "user.psd1").write_text("@{}", encoding="utf-8")
        (self.dir / "sessions.db").write_text("dbbytes", encoding="utf-8")
        (self.dir / ".env").write_text("TOKEN=abc", encoding="utf-8")
        (self.dir / "logs").mkdir()
        (self.dir / "logs" / "a.log").write_text("logline", encoding="utf-8")
        file.configure({"agent": {"allowedReadPaths": [str(self.dir)]}})

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_reads_normal_file(self):
        self.assertEqual(file._file_read(str(self.dir / "normal.txt")), "hello")

    def test_denies_config_json_and_hides_secret(self):
        out = file._file_read(str(self.dir / "config.json"))
        self.assertIn("sensitive", out)
        self.assertNotIn("SUPERSECRET", out)  # the secret never leaks

    def test_denies_psd1(self):
        self.assertIn("sensitive", file._file_read(str(self.dir / "user.psd1")))

    def test_denies_db(self):
        self.assertIn("sensitive", file._file_read(str(self.dir / "sessions.db")))

    def test_denies_env(self):
        self.assertIn("sensitive", file._file_read(str(self.dir / ".env")))

    def test_denies_logs_dir(self):
        self.assertIn("sensitive", file._file_read(str(self.dir / "logs" / "a.log")))

    def test_denies_outside_allowed_root(self):
        other = Path(tempfile.mkdtemp(prefix="bob-other-"))
        try:
            (other / "f.txt").write_text("x", encoding="utf-8")
            self.assertIn("Access denied", file._file_read(str(other / "f.txt")))
        finally:
            shutil.rmtree(other, ignore_errors=True)

    def test_write_refuses_secret_even_when_allowed(self):
        file.configure({"agent": {"allowedWritePaths": [str(self.dir)]}})
        out = file._file_write(str(self.dir / "config.json"), "{}")
        self.assertIn("sensitive", out)


if __name__ == "__main__":
    unittest.main()
