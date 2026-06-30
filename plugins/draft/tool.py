"""Bob plugin tool: draft_text — draft written content via local LLM."""
import sys
from pathlib import Path

REPO = Path(__file__).parent.parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO))

from plugins.draft.invoke import draft

_cfg: dict = {}


def configure(config: dict) -> None:
    global _cfg
    _cfg = config


def test() -> str:
    return "draft_text: OK (no LLM call in test — use `bob draft 'test message' --type slack` to verify)"


TOOL_DEFS = [
    {
        "type": "function",
        "function": {
            "name": "draft_text",
            "description": (
                "Draft written content from a prompt — emails, PR descriptions, Slack messages, or docs. "
                "Use when the user asks to write, compose, or draft something. "
                "Returns only the drafted text, no preamble."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": "What to write. E.g. 'apologise for the late delivery' or 'explain the new caching layer'.",
                    },
                    "type": {
                        "type": "string",
                        "enum": ["email", "pr", "slack", "doc", "default"],
                        "description": (
                            "'email' = professional email with subject + signature. "
                            "'pr' = pull request description with markdown sections. "
                            "'slack' = brief direct message, no markdown headers. "
                            "'doc' = technical documentation in markdown. "
                            "'default' = general-purpose draft."
                        ),
                    },
                },
                "required": ["prompt"],
            },
        },
    }
]

DISPATCH = {
    "draft_text": lambda prompt, type="default": draft(prompt, type, _cfg),
}
