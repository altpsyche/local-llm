"""Bob plugin tool: summarise_text — summarise content via local LLM."""
import sys
from pathlib import Path

REPO = Path(__file__).parent.parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO))

from plugins.summarise.invoke import summarise

_cfg: dict = {}


def configure(config: dict) -> None:
    global _cfg
    _cfg = config


def test() -> str:
    return "summarise_text: OK (no LLM call in test — use `bob summarise README.md --length short` to verify)"


TOOL_DEFS = [
    {
        "type": "function",
        "function": {
            "name": "summarise_text",
            "description": (
                "Summarise a block of text or file content via the local LLM. "
                "Use when the user asks to summarise, condense, or get a quick overview of something. "
                "Pass the content directly as a string."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": "The text to summarise.",
                    },
                    "length": {
                        "type": "string",
                        "enum": ["short", "medium", "long"],
                        "description": (
                            "'short' = 2-3 sentences. "
                            "'medium' = a paragraph (default). "
                            "'long' = structured summary with key points."
                        ),
                    },
                },
                "required": ["content"],
            },
        },
    }
]

DISPATCH = {
    "summarise_text": lambda content, length="medium": summarise(content, length, _cfg),
}
