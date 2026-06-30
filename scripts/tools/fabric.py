"""Bob tool: fabric_run — runs a fabric pattern on text input."""
import shutil
import subprocess
import sys

_fabric_available: bool = False


def configure(config: dict) -> None:
    global _fabric_available
    _fabric_available = bool(shutil.which("fabric"))
    if not _fabric_available:
        # Also check bin/ in the repo
        from pathlib import Path
        repo_bin = Path(__file__).parent.parent.parent / "bin" / "fabric.exe"
        _fabric_available = repo_bin.exists()


def _fabric_run(pattern: str, input: str) -> str:
    if not _fabric_available:
        return (
            "fabric not found on PATH.\n"
            "Run: bob fabric-setup   (installs and configures fabric)"
        )
    try:
        r = subprocess.run(
            ["fabric", "--pattern", pattern],
            input=input,
            capture_output=True,
            text=True,
            timeout=120,
        )
        output = r.stdout.strip()
        err = r.stderr.strip()
        if not output and err:
            return f"fabric error: {err[:1000]}"
        return output[:4000] if output else "(no output)"
    except subprocess.TimeoutExpired as exc:
        if exc.process:
            exc.process.kill()
        return "fabric timed out after 120s."
    except Exception as e:
        return f"fabric_run error: {e}"


def test() -> str:
    if not _fabric_available:
        return "fabric not available — skipping test"
    # Use a simple built-in pattern that always works
    result = _fabric_run("summarize", "The quick brown fox jumps over the lazy dog.")
    return result or "(fabric returned empty output)"


TOOL_DEFS = [
    {
        "type": "function",
        "function": {
            "name": "fabric_run",
            "description": (
                "Run a fabric AI pattern on text input. "
                "Patterns include: summarize, extract_wisdom, improve_writing, "
                "create_outline, analyze_paper, write_essay, and many more. "
                "Use `bob fabric -l` to see all available patterns."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {
                        "type": "string",
                        "description": "Fabric pattern name (e.g. 'summarize', 'extract_wisdom')",
                    },
                    "input": {
                        "type": "string",
                        "description": "Text to process with the pattern",
                    },
                },
                "required": ["pattern", "input"],
            },
        },
    }
]

DISPATCH = {"fabric_run": _fabric_run}
