"""NB4 (contract C6) — the command registry: the single source for dispatch (C1), help, and NE's
catalog. Each entry is {name, group, summary, args, runtime, handler}:

  name     fully-qualified command path ("agent", "agent serve", "setup")
  group    catalog grouping for help/splash
  summary  one-line description
  args     usage hint ("" if none)
  runtime  "python" (handled by this package) | "pwsh" (the orchestration scripts)
  handler  cli.py handler key for python commands (None for pwsh)

config/verbs.json is *generated from* this registry (verbs_json_dict / write_verbs) and read by the
shim so the shim and `python -m bob` route from the same data. Phased migration (C1): chat/voice/
describe/recall are pwsh today and stay so until a later module ports them to Python.
"""
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent  # scripts/bob/registry.py -> repo
VERBS_FILE = REPO / "config" / "verbs.json"

COMMANDS = [
    # --- Python runtime (this package) ---------------------------------------------------------
    {"name": "agent", "group": "Agent runtime", "summary": "Run the agent on a one-shot goal",
     "args": "<goal>", "runtime": "python", "handler": "agent_run"},
    {"name": "agent serve", "group": "Agent runtime", "summary": "Start the agent HTTP server (FastAPI, Bearer auth)",
     "args": "", "runtime": "python", "handler": "agent_serve"},
    {"name": "agent mcp", "group": "Agent runtime", "summary": "Expose Bob's tools over MCP (stdio)",
     "args": "", "runtime": "python", "handler": "agent_mcp"},
    {"name": "agent tools", "group": "Agent runtime", "summary": "List the agent's discovered tools",
     "args": "", "runtime": "python", "handler": "agent_tools"},
    {"name": "clip", "group": "Runtime", "summary": "Clip a URL into memory",
     "args": "<url> [--note <text>]", "runtime": "python", "handler": "clip"},
    {"name": "skill", "group": "Runtime", "summary": "Run a skill (arrives in a later module)",
     "args": "<name>", "runtime": "python", "handler": "skill"},

    # --- pwsh orchestration / bootstrap (existing scripts; run before or without the venv) ------
    {"name": "setup", "group": "Provisioner", "summary": "Pre-flight health check / first-run setup",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "up", "group": "Provisioner", "summary": "Bring the local stack up",
     "args": "[-NoOpen] [-WithServices]", "runtime": "pwsh", "handler": None},
    {"name": "down", "group": "Provisioner", "summary": "Stop services (alias of stop)",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "restart", "group": "Provisioner", "summary": "Restart the inference endpoint",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "serve", "group": "Provisioner", "summary": "Launch the inference stack (llama-swap + LiteLLM)",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "stop", "group": "Provisioner", "summary": "Stop all Bob services",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "services", "group": "Provisioner", "summary": "Manage the Docker service stack",
     "args": "<up|down|...>", "runtime": "pwsh", "handler": None},
    {"name": "gen", "group": "Provisioner", "summary": "Regenerate runtime configs from models.psd1",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "fetch", "group": "Provisioner", "summary": "Download model files",
     "args": "[--list]", "runtime": "pwsh", "handler": None},
    {"name": "build", "group": "Provisioner", "summary": "Build llama.cpp (CUDA, or --cpu for no-GPU)",
     "args": "[--cpu] [--force]", "runtime": "pwsh", "handler": None},
    {"name": "doctor", "group": "Provisioner", "summary": "Extended pre-flight diagnostics",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "update", "group": "Provisioner", "summary": "Update submodules and rebuild",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "status", "group": "Provisioner", "summary": "Show endpoint + model status",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "profile", "group": "Provisioner", "summary": "Show or set the active model profile",
     "args": "[<name>]", "runtime": "pwsh", "handler": None},
    {"name": "mlock", "group": "Provisioner", "summary": "Grant/check the mlock privilege",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "models", "group": "Provisioner", "summary": "List configured models",
     "args": "", "runtime": "pwsh", "handler": None},

    # --- pwsh interactive runtime (phased — Python migration is a later module, C1) -------------
    {"name": "chat", "group": "Interactive (pwsh, phased)", "summary": "Interactive chat REPL",
     "args": "[--code|--think|--pro]", "runtime": "pwsh", "handler": None},
    {"name": "voice", "group": "Interactive (pwsh, phased)", "summary": "Voice conversation loop",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "describe", "group": "Interactive (pwsh, phased)", "summary": "Describe an image (vision)",
     "args": "<image>", "runtime": "pwsh", "handler": None},
    {"name": "recall", "group": "Interactive (pwsh, phased)", "summary": "Recall from memory",
     "args": "<query>", "runtime": "pwsh", "handler": None},

    # --- pwsh agent orchestration subcommands (Windows Scheduled Tasks) -------------------------
    {"name": "agent install", "group": "Agent orchestration", "summary": "Register the BobAgent scheduled task",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "agent uninstall", "group": "Agent orchestration", "summary": "Remove the BobAgent scheduled task",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "agent status", "group": "Agent orchestration", "summary": "Show BobAgent task status",
     "args": "", "runtime": "pwsh", "handler": None},
    {"name": "agent schedule", "group": "Agent orchestration", "summary": "Manage scheduled agent goals",
     "args": "<add|list|run|remove|enable|disable>", "runtime": "pwsh", "handler": None},
    {"name": "agent log", "group": "Agent orchestration", "summary": "Tail the agent log",
     "args": "", "runtime": "pwsh", "handler": None},
]

_VALID_RUNTIMES = {"python", "pwsh"}


def commands() -> list:
    """All command entries (a copy, so callers can't mutate the registry)."""
    return [dict(c) for c in COMMANDS]


def by_name() -> dict:
    return {c["name"]: c for c in COMMANDS}


def verbs_json_dict() -> dict:
    """The data the shim reads: command-path -> runtime, plus the unknown-command default."""
    return {"commands": {c["name"]: c["runtime"] for c in COMMANDS}, "default": "python"}


def write_verbs(path: Path = None) -> Path:
    """(Re)generate config/verbs.json from the registry. Atomic write (temp + replace)."""
    import os

    path = path or VERBS_FILE
    tmp = path.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(verbs_json_dict(), indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    return path


def _check(path: Path = None) -> int:
    """Verify config/verbs.json matches the registry. Returns 0 if in sync, 1 if stale/missing —
    used as a pre-commit / CI gate so a registry edit can't land with a stale verbs.json."""
    path = path or VERBS_FILE
    if not path.exists():
        print(f"verbs.json missing at {path} — run: python -m bob.registry", file=sys.stderr)
        return 1
    disk = json.loads(path.read_text(encoding="utf-8"))
    if disk != verbs_json_dict():
        print("verbs.json is STALE (out of sync with the command registry) — "
              "run: python -m bob.registry", file=sys.stderr)
        return 1
    print("verbs.json in sync")
    return 0


if __name__ == "__main__":
    if "--check" in sys.argv[1:]:
        sys.exit(_check())
    p = write_verbs()
    print(f"wrote {p}")
