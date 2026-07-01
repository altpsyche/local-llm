"""M13 gap-close — agent HTTP server: auth (M5/M12), session routes, completion recording,
budget, and the SSE endpoint shape (M15). Calls the route functions directly (no live socket)
with fake registry/LLM so it stays hermetic and offline."""
import shutil
import tempfile
import unittest
from pathlib import Path

import _common
import bob_agent_server as srv
import bob_loop
from bob_session import SessionStore
from fastapi import HTTPException

GOOD = "Bearer sk-test"


class TestServer(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="bob-srv-"))
        srv._config = _common.fake_config()
        srv._accepted_tokens = {"sk-test"}
        srv._registry = _common.FakeRegistry()
        srv._sessions = SessionStore(self.dir / "s.db")

    def tearDown(self):
        srv._sessions._conn.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    # --- auth (M5/M12) -------------------------------------------------------
    def test_auth_rejects_bad_token(self):
        with self.assertRaises(HTTPException) as ctx:
            srv._require_auth("Bearer nope")
        self.assertEqual(ctx.exception.status_code, 401)

    def test_auth_accepts_configured_token(self):
        srv._require_auth(GOOD)  # must not raise

    def test_health_needs_no_auth(self):
        self.assertEqual(srv.health()["status"], "ok")

    def test_completion_requires_auth(self):
        with self.assertRaises(HTTPException) as ctx:
            srv.agent_completions(srv.AgentRequest(goal="hi"), authorization="")
        self.assertEqual(ctx.exception.status_code, 401)

    # --- sessions (M12) ------------------------------------------------------
    def test_session_lifecycle(self):
        sid = srv.create_session(srv.SessionCreate(token_budget=50), authorization=GOOD)["session_id"]
        self.assertEqual(srv.get_session(sid, authorization=GOOD)["id"], sid)
        self.assertTrue(srv.delete_session(sid, authorization=GOOD)["deleted"])

    def test_unknown_session_404(self):
        with self.assertRaises(HTTPException) as ctx:
            srv.get_session("nope", authorization=GOOD)
        self.assertEqual(ctx.exception.status_code, 404)

    def test_completion_records_turn(self):
        sid = srv.create_session(srv.SessionCreate(), authorization=GOOD)["session_id"]
        orig = bob_loop.run_agent
        bob_loop.run_agent = lambda *a, **k: ("answer", False)
        try:
            resp = srv.agent_completions(
                srv.AgentRequest(goal="hi", session_id=sid), authorization=GOOD)
        finally:
            bob_loop.run_agent = orig
        self.assertEqual(resp.result, "answer")
        self.assertEqual(resp.session_id, sid)
        self.assertEqual(len(srv.get_session(sid, authorization=GOOD)["history"]), 2)

    def test_completion_over_budget_402(self):
        sid = srv.create_session(srv.SessionCreate(token_budget=1), authorization=GOOD)["session_id"]
        srv._sessions.append_turn(sid, "x", "y", tokens_used=10)  # exhaust the 1-token budget
        with self.assertRaises(HTTPException) as ctx:
            srv.agent_completions(srv.AgentRequest(goal="hi", session_id=sid), authorization=GOOD)
        self.assertEqual(ctx.exception.status_code, 402)

    # --- SSE endpoint shape (M15) -------------------------------------------
    def test_stream_requires_auth(self):
        with self.assertRaises(HTTPException):
            srv.agent_completions_stream(srv.AgentRequest(goal="hi"), authorization="")

    def test_stream_returns_event_stream(self):
        orig = bob_loop.run_agent_events
        bob_loop.run_agent_events = lambda *a, **k: iter(
            [{"type": "final", "result": "ok", "exit_requested": False, "reason": "answer"}]
        )
        try:
            resp = srv.agent_completions_stream(srv.AgentRequest(goal="hi"), authorization=GOOD)
        finally:
            bob_loop.run_agent_events = orig
        self.assertEqual(resp.media_type, "text/event-stream")


if __name__ == "__main__":
    unittest.main()
