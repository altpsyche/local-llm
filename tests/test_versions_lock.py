"""ND1 (contract C2) — versions.lock is the generated reproducibility pin, read by both langs.
Proves: the committed lock parses + has the required shape; a model verifies against its true SHA
and FAILS against a wrong one (the 'wrong pinned version fails the gate' case); and drift detection
flags a moved model checksum. The pwsh generator/sync-gate side is covered by test-dry-run.ps1 [13]."""
import hashlib
import tempfile
import unittest
from pathlib import Path

import _common  # noqa: F401 — puts scripts/ on sys.path
from bob import versions


class TestLockShape(unittest.TestCase):
    def test_committed_lock_parses_and_is_well_formed(self):
        lk = versions.load_lock()
        for key in ("lockVersion", "release", "submodules", "toolchain", "requirements", "models"):
            self.assertIn(key, lk, f"versions.lock missing '{key}'")
        self.assertIsInstance(lk["submodules"], dict)
        self.assertTrue(lk["submodules"], "no submodules pinned")
        # every submodule commit is a 40-hex sha (or None if unresolved)
        for sub, sha in lk["submodules"].items():
            if sha is not None:
                self.assertRegex(sha, r"^[0-9a-f]{40}$", sub)
        # every model entry carries repo/path/revision/sha256 (sha256 may be null until first fetch)
        self.assertTrue(lk["models"])
        for gguf, meta in lk["models"].items():
            for field in ("repo", "path", "revision", "sha256"):
                self.assertIn(field, meta, f"{gguf} missing {field}")
            if meta["sha256"] is not None:
                self.assertRegex(meta["sha256"], r"^[0-9a-f]{64}$", gguf)

    def test_cpu_tier_model_is_pinned_by_revision(self):
        # The NC8 CPU-tier GGUF that ND2 serves in CI must be present + revision-pinned (sha may be
        # null pre-first-fetch — TOFU-then-lock, per the locked decision).
        lk = versions.load_lock()
        cpu = lk["models"].get("qwen2.5-0.5b-instruct-q8_0.gguf")
        self.assertIsNotNone(cpu, "CPU-tier GGUF missing from versions.lock")
        self.assertTrue(cpu["repo"] and cpu["path"] and cpu["revision"])


class TestVerifyModel(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="bob-vlock-"))
        self.f = self.tmp / "m.gguf"
        self.f.write_bytes(b"hello-bob-model")
        self.good = hashlib.sha256(self.f.read_bytes()).hexdigest()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_correct_hash_passes(self):
        self.assertTrue(versions.verify_model(self.f, self.good))
        self.assertTrue(versions.verify_model(self.f, self.good.upper()))  # case-insensitive

    def test_wrong_hash_fails(self):
        # This is the deliberately-wrong-pin case the gate must catch.
        self.assertFalse(versions.verify_model(self.f, "0" * 64))

    def test_unpinned_is_a_pass(self):
        # sha256 null/empty == unpinned (e.g. CPU GGUF pre-first-fetch): nothing to verify against.
        self.assertTrue(versions.verify_model(self.f, None))
        self.assertTrue(versions.verify_model(self.f, ""))

    def test_missing_file_fails_when_pinned(self):
        self.assertFalse(versions.verify_model(self.tmp / "nope.gguf", self.good))


class TestDrift(unittest.TestCase):
    def test_model_checksum_drift_detected(self):
        tmp = Path(tempfile.mkdtemp(prefix="bob-vlock-repo-"))
        try:
            (tmp / "models").mkdir()
            (tmp / "models" / "m.gguf").write_bytes(b"actual-bytes")
            lock = {
                "submodules": {},  # skip git in this synthetic repo
                "models": {"m.gguf": {"sha256": "f" * 64}},  # pin a hash that won't match
            }
            drift = versions.check_reproducibility(repo=tmp, lock=lock)
            self.assertEqual(len(drift), 1)
            self.assertEqual(drift[0]["kind"], "model")
            self.assertEqual(drift[0]["name"], "m.gguf")
        finally:
            import shutil
            shutil.rmtree(tmp, ignore_errors=True)

    def test_no_drift_when_unpinned_or_absent(self):
        tmp = Path(tempfile.mkdtemp(prefix="bob-vlock-repo-"))
        try:
            (tmp / "models").mkdir()
            (tmp / "models" / "present.gguf").write_bytes(b"x")
            lock = {
                "submodules": {},
                "models": {
                    "present.gguf": {"sha256": None},       # unpinned -> skipped
                    "absent.gguf": {"sha256": "a" * 64},    # pinned but not on disk -> not drift
                },
            }
            self.assertEqual(versions.check_reproducibility(repo=tmp, lock=lock), [])
        finally:
            import shutil
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
