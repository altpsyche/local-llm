"""Bob tool: memory_recall and memory_store via bob_memory.py."""
import sys
from pathlib import Path

_cfg: dict = {}


def configure(config: dict) -> None:
    global _cfg
    _cfg = config
    scripts_dir = str(Path(__file__).parent.parent)
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)


def _memory_recall(query: str, k: int = 5) -> str:
    from bob_core import memory_recall
    return memory_recall(query, k=k, config=_cfg)


def _memory_store(content: str, tags: str = "") -> str:
    from bob_core import memory_store
    return memory_store(content, tags=tags, config=_cfg)


def test() -> str:
    return _memory_recall("test query", k=2)


TOOL_DEFS = [
    {
        "type": "function",
        "function": {
            "name": "memory_recall",
            "description": "Search Bob's memory for relevant facts and past context",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"},
                    "k": {"type": "integer", "description": "Number of results (default 5)"},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "memory_store",
            "description": "Save a fact or note to Bob's persistent memory",
            "parameters": {
                "type": "object",
                "properties": {
                    "content": {"type": "string", "description": "Text to store"},
                    "tags": {"type": "string", "description": "Comma-separated tags (optional)"},
                },
                "required": ["content"],
            },
        },
    },
]

DISPATCH = {
    "memory_recall": _memory_recall,
    "memory_store": _memory_store,
}
