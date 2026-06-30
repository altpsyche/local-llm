"""Bob tool: git_status, git_log, git_diff."""
import subprocess
from pathlib import Path

_default_repo: str = ""


def configure(config: dict) -> None:
    global _default_repo
    _default_repo = str(Path(__file__).parent.parent.parent)


def _run_git(args: list, cwd: str) -> str:
    try:
        r = subprocess.run(
            ["git", "-C", cwd] + args,
            capture_output=True,
            text=True,
            timeout=15,
        )
        return r.stdout.strip() or r.stderr.strip() or "(empty)"
    except FileNotFoundError:
        return "git not found on PATH"
    except subprocess.TimeoutExpired:
        return "git command timed out"


def _git_status(path: str = None) -> str:
    p = path or _default_repo
    result = _run_git(["status", "--short"], p)
    return result if result != "(empty)" else "Clean working tree"


def _git_log(path: str = None, n: int = 10) -> str:
    p = path or _default_repo
    return _run_git(["log", "--oneline", f"-{min(n, 50)}"], p)


def _git_diff(path: str = None, file: str = None) -> str:
    p = path or _default_repo
    cmd = ["diff"] + ([file] if file else [])
    result = _run_git(cmd, p)
    return result[:3000]


def test() -> str:
    return _git_status()


TOOL_DEFS = [
    {
        "type": "function",
        "function": {
            "name": "git_status",
            "description": "Get the git working tree status of a repository",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Absolute path to git repo. Omit to use the current Bob repository.",
                    }
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "git_log",
            "description": "Get recent git commit history",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute path to git repo. Omit to use the current Bob repository."},
                    "n": {"type": "integer", "description": "Number of commits (default 10, max 50)"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "git_diff",
            "description": "Get git diff for the working tree or a specific file",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute path to git repo. Omit to use the current Bob repository."},
                    "file": {"type": "string", "description": "Specific file path to diff (optional)"},
                },
            },
        },
    },
]

DISPATCH = {
    "git_status": _git_status,
    "git_log": _git_log,
    "git_diff": _git_diff,
}
