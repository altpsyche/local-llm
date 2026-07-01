"""M13 — bob_memory importable core (M14-blocker) with the embed server mocked."""
import shutil
import tempfile
import unittest
from pathlib import Path

import _common
import bob_memory


def _fake_embed(text: str):
    # Deterministic: identical text -> identical vector (so dedup fires); different text differs.
    return [float(len(text)), float(sum(ord(c) for c in text) % 97), 1.0]


class TestMemoryCore(unittest.TestCase):
    def setUp(self):
        self._orig = bob_memory.embed
        bob_memory.embed = _fake_embed
        # Unique DB per test — sqlite keeps the file open, so isolate rather than delete-between.
        self.dir = Path(tempfile.mkdtemp(prefix="bob-mem-"))
        self.db = self.dir / "m.db"

    def tearDown(self):
        bob_memory.embed = self._orig
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_store_returns_id_and_is_new(self):
        mid, is_new = bob_memory.store("first fact", self.db)
        self.assertIsInstance(mid, int)
        self.assertTrue(is_new)

    def test_store_dedups_identical(self):
        mid, _ = bob_memory.store("same text", self.db)
        mid2, is_new = bob_memory.store("same text", self.db)
        self.assertFalse(is_new)
        self.assertEqual(mid, mid2)

    def test_recall_finds_match(self):
        bob_memory.store("the user likes powershell", self.db)
        hits = bob_memory.recall("the user likes powershell", self.db, k=3, threshold=0.3)
        self.assertTrue(hits)
        self.assertIn("powershell", hits[0]["content"])

    def test_recall_empty_query(self):
        self.assertEqual(bob_memory.recall("", self.db), [])

    def test_store_accepts_str_path(self):
        # bob_core._get_db_path passes a str; get_db must coerce (regression for the masked bug).
        mid, _ = bob_memory.store("str path fact", str(self.db))
        self.assertIsInstance(mid, int)

    def test_embed_failure_raises_runtimeerror(self):
        def boom(_):
            raise RuntimeError("embed down")
        bob_memory.embed = boom
        with self.assertRaises(RuntimeError):
            bob_memory.store("x", self.db)


if __name__ == "__main__":
    unittest.main()
