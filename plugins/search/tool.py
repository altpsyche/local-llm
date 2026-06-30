"""Bob plugin tool: search_code — search files with ripgrep, synthesise via LLM."""
import sys
from pathlib import Path

REPO = Path(__file__).parent.parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO))

from plugins.search.invoke import run_rg, synthesise

_cfg: dict = {}


def configure(config: dict) -> None:
    global _cfg
    _cfg = config


def _search_code(query: str, path: str = ".", ext: str = None) -> str:
    search_path = str(Path(path).resolve())
    matches = run_rg(query, search_path, ext)
    if matches.startswith("(no matches") or matches.startswith("(search"):
        return matches
    from bob_core import check_litellm
    if not check_litellm(_cfg):
        return matches
    return synthesise(query, matches, _cfg)


def test() -> str:
    import shutil
    rg_available = "ripgrep available" if shutil.which("rg") else "ripgrep not found (findstr fallback active)"
    return f"search_code: OK — {rg_available}"


TOOL_DEFS = [
    {
        "type": "function",
        "function": {
            "name": "search_code",
            "description": (
                "Search files in a directory using ripgrep, then synthesise the results via LLM. "
                "Use for searching local code, configs, or text files — NOT for web/internet searches. "
                "Returns an LLM-analysed summary of the matches with file names and line numbers."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search term or pattern. E.g. 'load_config', 'TODO', 'API endpoints'.",
                    },
                    "path": {
                        "type": "string",
                        "description": "Directory to search. Defaults to current working directory.",
                    },
                    "ext": {
                        "type": "string",
                        "description": "File extension filter. E.g. '.py', '.ts', '.md'. Omit to search all files.",
                    },
                },
                "required": ["query"],
            },
        },
    }
]

DISPATCH = {
    "search_code": _search_code,
}
