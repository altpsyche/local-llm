"""NB3 (contracts C3 secrets, C4 data-dir) — the OS-abstraction seam for the Python runtime.

One place that knows about the OS, so the rest of the Python core stays OS-neutral:
  - default_shell()  the agent tool shell, always OS-native (pwsh on Windows, bash/sh elsewhere)
  - data_dir()/cache_dir()  repo-relative data/ + logs/ by default; BOB_DATA_DIR override (C4)
  - secret(name)     env -> OS keychain -> <data_dir>/secrets.json -> default (C3); never a tracked file
  - notify()         WinRT toast on Windows, notify-send elsewhere, no-op if neither

Per-OS branches key off platform.system() so tests can monkeypatch it.
"""
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def is_windows() -> bool:
    return platform.system() == "Windows"


# --- shell (C1: the agent tool shell is OS-native, independent of pwsh-for-orchestration) --------

def default_shell() -> list:
    """Argv prefix for running a command *string* in the OS-native shell.

    Windows -> pwsh (byte-identical to the pre-NB3 hardcode); elsewhere -> bash, falling back to
    sh. Append the command string to run it: subprocess.run(default_shell() + [cmd]).
    """
    if is_windows():
        return ["pwsh", "-NonInteractive", "-Command"]
    shell = shutil.which("bash") or shutil.which("sh") or "sh"
    return [shell, "-c"]


# --- data / state location (C4) ------------------------------------------------------------------

def _repo_data() -> Path:
    return REPO / "data"


def data_dir() -> Path:
    """The directory for state (sessions.db, bob.db, schedules.json, secrets.json).

    C4: repo-relative data/ by default (local-first, zero migration). Only when BOB_DATA_DIR is
    set (a future system-install / multi-user mode) does it move — and existing data/* is copied
    once so nothing is lost.
    """
    override = os.environ.get("BOB_DATA_DIR")
    if not override:
        d = _repo_data()
        d.mkdir(parents=True, exist_ok=True)
        return d
    d = Path(override).expanduser()
    d.mkdir(parents=True, exist_ok=True)
    _migrate_once(_repo_data(), d)
    return d


def cache_dir() -> Path:
    """Log/cache directory: repo-relative logs/ by default, <BOB_DATA_DIR>/logs when overridden."""
    override = os.environ.get("BOB_DATA_DIR")
    d = (Path(override).expanduser() / "logs") if override else (REPO / "logs")
    d.mkdir(parents=True, exist_ok=True)
    return d


def _migrate_once(src: Path, dst: Path) -> None:
    """One-time copy of existing data/* into a freshly-used BOB_DATA_DIR (C4). Marked with a
    .migrated stamp so it never re-copies (and never clobbers newer files in dst)."""
    stamp = dst / ".migrated"
    if stamp.exists() or not src.exists() or src.resolve() == dst.resolve():
        return
    for item in src.iterdir():
        target = dst / item.name
        if target.exists():
            continue
        try:
            if item.is_dir():
                shutil.copytree(item, target)
            else:
                shutil.copy2(item, target)
        except OSError:
            pass  # best-effort migration; a partial copy must not crash startup
    stamp.write_text("", encoding="utf-8")


# --- secrets (C3) --------------------------------------------------------------------------------

def secrets_file() -> Path:
    """The resolved secrets.json path (under data_dir(); data/ is gitignored, so never tracked)."""
    return data_dir() / "secrets.json"


def secret(name: str, default=None, config: dict = None):
    """Resolve a secret by name with precedence env -> OS keychain -> secrets.json -> default (C3).

    Env keys checked: the exact name, then BOB_<UPPER>. Keychain via the optional `keyring`
    package (skipped if not installed). No secret is ever read from a git-tracked file.
    """
    # 1. process env
    val = os.environ.get(name) or os.environ.get("BOB_" + name.upper())
    if val:
        return val
    # 2. OS keychain (Credential Manager / Keychain / secret-tool) — optional dependency
    try:
        import keyring  # type: ignore

        val = keyring.get_password("bob", name)
        if val:
            return val
    except Exception:
        pass  # keyring absent or backend unavailable — fall through to the file
    # 3. <data_dir>/secrets.json (never a tracked file)
    sf = secrets_file()
    if sf.exists():
        try:
            data = json.loads(sf.read_text(encoding="utf-8"))
            if isinstance(data, dict) and data.get(name):
                return data[name]
        except (json.JSONDecodeError, OSError):
            pass  # a malformed secrets file must not leak or crash — treat as absent
    # 4. default (may be a config-carried reference/value on Windows)
    return default


# --- notifications -------------------------------------------------------------------------------

def notify(title: str, body: str) -> bool:
    """Best-effort desktop notification. Returns True if a backend fired. No-op (False) when none
    is available — e.g. Linux without notify-send, or any headless box."""
    if is_windows():
        return _notify_windows(title, body)
    send = shutil.which("notify-send")
    if send:
        try:
            subprocess.run([send, title, body], check=False, timeout=5)
            return True
        except (OSError, subprocess.SubprocessError):
            return False
    return False


def _notify_windows(title: str, body: str) -> bool:  # pragma: no cover — exercised only on Windows
    try:
        from win10toast import ToastNotifier  # type: ignore

        ToastNotifier().show_toast(title, body, threaded=True)
        return True
    except Exception:
        # WinRT/toast is handled by scripts/bob-toast.ps1 in the PowerShell layer today; the
        # Python seam is a no-op fallback rather than a hard dependency.
        return False
