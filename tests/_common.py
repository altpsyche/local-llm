"""Shared test helpers (M13). Import first — it puts scripts/ and scripts/tools/ on sys.path
so the tests run under both `python -m unittest discover -s tests` and `pytest`."""
import os
import sys
from types import SimpleNamespace

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for _p in (os.path.join(REPO, "scripts"), os.path.join(REPO, "scripts", "tools")):
    if _p not in sys.path:
        sys.path.insert(0, _p)


def fake_config(**over):
    """A minimal but complete config dict for tests — no config.json / network needed."""
    cfg = {
        "litellmPort": 8081,
        "litellmKey": "sk-test",
        "searxngPort": 8888,
        "routing": {
            "defaultRole": "chat", "proRole": "chat-pro",
            "codeRole": "coder", "proCodeRole": "coder-pro",
            "thinkRole": "planner", "proThinkRole": "planner-pro",
            "agentRole": "agent",
        },
        "vision": {"visionRole": "vision", "visionProRole": "vision-pro"},
        "persona": {"systemPrompt": "You are Bob."},
        "memory": {"enabled": False},
        "agent": {
            "toolFormat": "hermes", "maxSteps": 5,
            "maxContextTokens": 0, "maxToolResultTokens": 1000,
        },
    }
    for k, v in over.items():
        cfg[k] = v
    return cfg


class FakeRegistry:
    """Stand-in for ToolRegistry with scripted dispatch results."""

    def __init__(self, results=None):
        self.tool_schemas = []
        self.exit_voice_tools = set()
        self._loaded_names = set()   # /health reads these
        self.errors = []
        self._results = results or {}

    def dispatch_call(self, name, arguments_json):
        return self._results.get(name, f"[{name} ran]")


def scripted_client(turns):
    """A fake OpenAI client whose create() returns each item of `turns` in order.
    Each turn is the assistant content string (Hermes tool calls inline as <tool_call>…)."""
    state = {"i": 0}

    class _C:
        def __init__(self):
            self.chat = SimpleNamespace(completions=self)

        def create(self, model, messages, tools, stream, timeout):
            i = state["i"]
            state["i"] += 1
            content = turns[min(i, len(turns) - 1)]
            msg = SimpleNamespace(content=content, tool_calls=None)
            return SimpleNamespace(choices=[SimpleNamespace(message=msg)])

    return _C()


def stream_client(deltas):
    """A fake client whose streaming create() yields chunks for each string in `deltas`."""
    class _Chunk:
        def __init__(self, text):
            self.choices = [SimpleNamespace(delta=SimpleNamespace(content=text, tool_calls=None))]

    class _C:
        def __init__(self):
            self.chat = SimpleNamespace(completions=self)

        def create(self, model, messages, tools, stream, timeout):
            return iter(_Chunk(d) for d in deltas)

    return _C()
