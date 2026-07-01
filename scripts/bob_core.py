"""Shared Bob Python core: config, LLM client, memory access.

Import this in any Bob Python script instead of duplicating config loading
or calling bob_memory.py via subprocess.

Usage:
    from bob_core import load_config, get_llm_client, memory_recall, memory_store
"""
import json
import sys
from pathlib import Path
from typing import Optional

REPO = Path(__file__).parent.parent

# NB1 (contract C2) — one neutral source of truth for the shared constants (ports + role table),
# read by both Python and PowerShell (scripts/_models.ps1) from config/defaults.json. No more
# hand-mirrored dicts. bob_config.py (NB2) reads the same file's "runtime" section.
_DEFAULTS_FILE = REPO / "config" / "defaults.json"
_defaults_cache: Optional[dict] = None


def load_defaults() -> dict:
    """Load and cache config/defaults.json (the neutral shared-constants file, NB1).

    Raises RuntimeError with a clear message if the file is missing or lacks the required
    top-level keys — a dropped key fails loudly at import rather than resolving to None.
    """
    global _defaults_cache
    if _defaults_cache is None:
        if not _DEFAULTS_FILE.exists():
            raise RuntimeError(
                f"config/defaults.json not found at {_DEFAULTS_FILE}\n"
                "This file is the neutral single source of truth for ports + roles (NB1)."
            )
        data = json.loads(_DEFAULTS_FILE.read_text(encoding="utf-8"))
        for key in ("ports", "roleTable"):
            if key not in data or not isinstance(data[key], dict):
                raise RuntimeError(f"config/defaults.json missing required '{key}' section")
        _defaults_cache = data
    return _defaults_cache


# M6 — single source of truth for service-port defaults on the Python side, now loaded from
# config/defaults.json (NB1) rather than a mirrored literal. config.json (written by Get-BobConfig)
# normally carries these; this dict is the only literal fallback, read via _port().
_PORT_DEFAULTS = load_defaults()["ports"]


def _port(config: dict, name: str) -> int:
    """Resolve a service port from config, falling back to the one central default dict."""
    if name not in _PORT_DEFAULTS:
        raise KeyError(f"unknown port key '{name}'; known: {', '.join(_PORT_DEFAULTS)}")
    return int(config.get(name, _PORT_DEFAULTS[name]))


def get_role(config: dict, task: str = "chat", pro: bool = False) -> str:
    """M8 — resolve a model role from config for a task (mirrors Get-RoleForTask in PowerShell).

    task: chat | code | think | voice | vision | agent
    pro:  prefer the *-pro variant where one exists.
    Centralizes the routing lookup so the plugins don't each re-derive it. NB1: the task->key
    mapping and fallback literals live in config/defaults.json roleTable, not inline here.
    """
    table = load_defaults()["roleTable"]
    entry = table.get(task) or table["chat"]
    # vision routing lives in its own config section, not under routing.
    section = config.get(entry.get("section", "routing"), {})
    base_key, pro_key = entry["base"], entry["pro"]
    if pro:
        return section.get(pro_key) or section.get(base_key) or entry["proFallback"]
    return section.get(base_key) or entry["fallback"]


def load_config() -> dict:
    """Load merged bob config.

    On Windows `Get-BobConfig` (PowerShell) writes the full data/config.json and this reads it,
    unchanged. NB2 (contract C2): if data/config.json is absent — e.g. on a non-Windows box with
    no PowerShell in the loop — resolve the runtime-subset config in Python from the neutral
    sources (config/defaults.json + config/user.json) instead of failing. The runtime no longer
    *requires* `bob gen`.
    """
    path = REPO / "data" / "config.json"
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    import bob_config  # local import: avoids a cycle (bob_config imports bob_core)

    return bob_config.resolve_runtime_config()


def _litellm_key(config: dict) -> str:
    """Return the LiteLLM master key, resolved through the C3 secret seam (NB3): env -> keychain
    -> data/secrets.json -> the config value (sk-local default). On Windows with no env/secret set
    this is unchanged (the config value wins as the default)."""
    import osenv

    return osenv.secret("litellmKey", default=config.get("litellmKey", "sk-local"), config=config)


def get_llm_client(config: Optional[dict] = None):
    """Return an OpenAI client pointed at the LiteLLM proxy."""
    from openai import OpenAI

    cfg = config or load_config()
    port = _port(cfg, "litellmPort")
    return OpenAI(base_url=f"http://localhost:{port}/v1", api_key=_litellm_key(cfg))


def check_litellm(config: Optional[dict] = None) -> bool:
    """Return True if the LiteLLM proxy port is open (TCP connect; avoids slow /health backend checks)."""
    import socket

    cfg = config or load_config()
    port = _port(cfg, "litellmPort")
    try:
        with socket.create_connection(("localhost", port), timeout=3):
            return True
    except OSError:
        return False


def capability_probe(config: Optional[dict] = None) -> tuple:
    """NB5 provisioner contract — a startup readiness check. Returns (ok, message). The runtime's
    only hard needs are (a) a resolvable config (always true here — load_config resolves in Python
    if PowerShell hasn't run) and (b) a reachable OpenAI-compatible endpoint. Callers print the
    message and degrade rather than assuming a provisioner ran."""
    cfg = config or load_config()
    port = _port(cfg, "litellmPort")
    if check_litellm(cfg):
        return (True, f"OK — LiteLLM endpoint reachable on :{port}.")
    return (
        False,
        f"LiteLLM endpoint not reachable on :{port}. Start the inference stack (`bob serve` on "
        "Windows) or point litellmPort at any running OpenAI-compatible endpoint (see docs/PORTABILITY.md).",
    )


def _get_db_path(config: Optional[dict] = None) -> str:
    cfg = config or load_config()
    rel = cfg.get("memory", {}).get("dbPath", "data/bob.db")
    return str(REPO / rel.replace("\\", "/"))


def memory_store(content: str, tags: str = "", config: Optional[dict] = None) -> str:
    """Store content in bob.db directly (no subprocess)."""
    cfg = config or load_config()
    db_path = _get_db_path(cfg)
    _ensure_memory_importable()
    import bob_memory  # type: ignore

    mid, is_new = bob_memory.store(content, db_path=db_path)
    return f"Stored (id={mid}): {content[:80]}" if is_new else f"Already stored (similar id={mid})"


def memory_recall(query: str, k: int = 5, config: Optional[dict] = None) -> str:
    """Recall top-k results from bob.db. Returns newline-joined content strings."""
    cfg = config or load_config()
    db_path = _get_db_path(cfg)
    _ensure_memory_importable()
    import bob_memory  # type: ignore

    results = bob_memory.recall(query, k=k, db_path=db_path)
    if not results:
        return "(no results)"
    return "\n".join(r["content"] for r in results)


def _ensure_memory_importable() -> None:
    scripts_dir = str(REPO / "scripts")
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)
