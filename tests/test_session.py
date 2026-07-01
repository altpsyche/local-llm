"""M13 — SessionStore CRUD + budget (M12)."""
import os
import tempfile
import unittest
from pathlib import Path

import _common
from bob_session import SessionStore


class TestSessionStore(unittest.TestCase):
    def setUp(self):
        self.db = Path(tempfile.gettempdir()) / f"bob-sess-{os.getpid()}.db"
        self.store = SessionStore(self.db)

    def tearDown(self):
        self.store._conn.close()
        try:
            self.db.unlink()
        except OSError:
            pass

    def test_create_and_get(self):
        s = self.store.create(token_budget=100)
        got = self.store.get(s["id"])
        self.assertEqual(got["id"], s["id"])
        self.assertEqual(got["history"], [])
        self.assertEqual(got["token_budget"], 100)

    def test_get_unknown_is_none(self):
        self.assertIsNone(self.store.get("does-not-exist"))

    def test_append_turn_and_spend(self):
        s = self.store.create()
        self.store.append_turn(s["id"], "hello", "hi there", tokens_used=40)
        got = self.store.get(s["id"])
        self.assertEqual([m["role"] for m in got["history"]], ["user", "assistant"])
        self.assertEqual(got["tokens_spent"], 40)

    def test_budget_enforcement(self):
        s = self.store.create(token_budget=100)
        self.store.append_turn(s["id"], "a", "b", tokens_used=40)
        self.assertFalse(self.store.over_budget(s["id"]))
        self.store.append_turn(s["id"], "c", "d", tokens_used=70)
        self.assertTrue(self.store.over_budget(s["id"]))

    def test_zero_budget_never_over(self):
        s = self.store.create(token_budget=0)
        self.store.append_turn(s["id"], "a", "b", tokens_used=10_000)
        self.assertFalse(self.store.over_budget(s["id"]))

    def test_delete(self):
        s = self.store.create()
        self.assertTrue(self.store.delete(s["id"]))
        self.assertIsNone(self.store.get(s["id"]))


if __name__ == "__main__":
    unittest.main()
