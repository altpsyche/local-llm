"""M13 — agent loop event generator (M15 refactor): tool step, final, streaming, history."""
import unittest

import _common
import bob_core
import bob_loop


class TestAgentLoop(unittest.TestCase):
    def setUp(self):
        self.cfg = _common.fake_config()
        self._orig_check = bob_core.check_litellm
        self._orig_client = bob_core.get_llm_client
        bob_core.check_litellm = lambda config=None: True

    def tearDown(self):
        bob_core.check_litellm = self._orig_check
        bob_core.get_llm_client = self._orig_client

    def test_tool_step_then_final(self):
        turns = [
            '<tool_call>{"name": "echo", "arguments": {"x": "hi"}}</tool_call>',
            "All done.",
        ]
        bob_core.get_llm_client = lambda config=None: _common.scripted_client(turns)
        reg = _common.FakeRegistry({"echo": "echoed hi"})
        events = list(bob_loop.run_agent_events("go", self.cfg, agency="silent", registry=reg))
        types = [e["type"] for e in events]
        self.assertEqual(types, ["tool_call", "tool_result", "final"])
        self.assertEqual(events[0]["name"], "echo")
        self.assertEqual(events[1]["result"], "echoed hi")
        self.assertEqual(events[-1]["result"], "All done.")

    def test_run_agent_wrapper_returns_result(self):
        bob_core.get_llm_client = lambda config=None: _common.scripted_client(["Just answer."])
        result, exit_req = bob_loop.run_agent("q", self.cfg, agency="silent",
                                              registry=_common.FakeRegistry())
        self.assertEqual(result, "Just answer.")
        self.assertFalse(exit_req)

    def test_streaming_emits_tokens_and_final(self):
        bob_core.get_llm_client = lambda config=None: _common.stream_client(["Hel", "lo ", "world."])
        events = list(bob_loop.run_agent_events("hi", self.cfg, agency="silent",
                                                registry=_common.FakeRegistry(), stream=True))
        tokens = [e["text"] for e in events if e["type"] == "token"]
        final = [e for e in events if e["type"] == "final"][-1]
        self.assertEqual("".join(tokens), "Hello world.")
        self.assertEqual(final["result"], "Hello world.")

    def test_preflight_failure_yields_error(self):
        bob_core.check_litellm = lambda config=None: False
        events = list(bob_loop.run_agent_events("x", self.cfg, agency="silent",
                                                registry=_common.FakeRegistry()))
        self.assertEqual(events[-1]["type"], "error")
        self.assertIn("not reachable", events[-1]["message"])

    def test_history_is_seeded(self):
        captured = {}

        class Recorder:
            def __init__(self):
                self.chat = type("C", (), {"completions": self})()

            def create(self, model, messages, tools, stream, timeout):
                captured["messages"] = messages
                from types import SimpleNamespace
                return SimpleNamespace(choices=[SimpleNamespace(
                    message=SimpleNamespace(content="ok", tool_calls=None))])

        bob_core.get_llm_client = lambda config=None: Recorder()
        history = [{"role": "user", "content": "earlier"}, {"role": "assistant", "content": "reply"}]
        list(bob_loop.run_agent_events("now", self.cfg, agency="silent",
                                       registry=_common.FakeRegistry(), history=history))
        roles = [m["role"] for m in captured["messages"]]
        self.assertEqual(roles, ["system", "user", "assistant", "user"])
        self.assertEqual(captured["messages"][-1]["content"], "now")


if __name__ == "__main__":
    unittest.main()
