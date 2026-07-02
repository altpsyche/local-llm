"""ND1 (contract C2) — versions.lock reader/validator for the Python side.

versions.lock is a GENERATED neutral JSON lock (see scripts/_versions.ps1 `Write-VersionsLock` /
`bob lock`) pinning submodule commits, per-venv requirements, minimum toolchain versions, and the
model manifest (repo -> revision -> sha256, incl. the NC8 CPU-tier GGUF). It is generated from
existing single sources (git gitlinks + models.psd1 + manifest.json + pip freeze) — the pwsh side
owns generation because models.psd1 is PowerShell-only; Python only READS it, to verify model
checksums on fetch and to report reproducibility.

Mirrors bob_core.load_defaults(): fail loud with a clear message if the lock is missing rather than
resolving to None.
"""
import hashlib
import json
import subprocess
from pathlib import Path
from typing import Optional

REPO = Path(__file__).resolve().parent.parent.parent  # scripts/bob/versions.py -> repo
LOCK_FILE = REPO / "versions.lock"


def load_lock(path: Optional[Path] = None) -> dict:
    """Load and parse versions.lock. Raises RuntimeError if missing (it is generated: run `bob lock`)."""
    path = path or LOCK_FILE
    if not path.exists():
        raise RuntimeError(
            f"versions.lock not found at {path} — it is generated; run: bob lock"
        )
    return json.loads(path.read_text(encoding="utf-8"))


def sha256_file(path, _chunk: int = 1 << 20) -> str:
    """Streaming SHA256 (lowercase hex) — GGUFs are multi-GB, so never read the whole file at once."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(_chunk), b""):
            h.update(block)
    return h.hexdigest().lower()


def verify_model(path, expected_sha: Optional[str]) -> bool:
    """True iff the file at `path` hashes to `expected_sha` (case-insensitive).

    A falsy `expected_sha` means the model is unpinned (e.g. the CPU GGUF before its first fetch) —
    there is nothing to verify against, so this returns True. A missing file returns False.
    """
    if not expected_sha:
        return True
    p = Path(path)
    if not p.exists():
        return False
    return sha256_file(p) == expected_sha.strip().lower()


def check_reproducibility(repo: Optional[Path] = None, lock: Optional[dict] = None) -> list:
    """Return a list of drift dicts {kind, name, expected, actual}; empty when reproducible.

    Compares the lock to what is actually installed: submodule checked-out HEADs (via git) and, for
    models that are present AND pinned, the on-disk SHA256. Unpinned or not-downloaded models are
    skipped — they are not drift. Used by tests and (via the pwsh mirror) by `bob doctor`.
    """
    repo = repo or REPO
    lock = lock if lock is not None else load_lock()
    drift = []
    for sub, want in (lock.get("submodules") or {}).items():
        full = Path(repo) / sub
        if not want or not full.exists():
            continue
        try:
            head = subprocess.run(
                ["git", "-C", str(full), "rev-parse", "HEAD"],
                capture_output=True, text=True, timeout=10,
            ).stdout.strip()
        except Exception:
            head = ""
        if head and head != want:
            drift.append({"kind": "submodule", "name": sub, "expected": want, "actual": head})
    for gguf, meta in (lock.get("models") or {}).items():
        want = (meta or {}).get("sha256")
        if not want:
            continue
        f = Path(repo) / "models" / gguf
        if not f.exists():
            continue
        actual = sha256_file(f)
        if actual != want.strip().lower():
            drift.append({"kind": "model", "name": gguf, "expected": want, "actual": actual})
    return drift


if __name__ == "__main__":
    # `python -m bob.versions` — print a short reproducibility summary (read-only).
    import sys

    try:
        lk = load_lock()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        sys.exit(1)
    d = check_reproducibility(lock=lk)
    print(f"versions.lock release {lk.get('release')} — "
          f"{len(lk.get('submodules') or {})} submodules, {len(lk.get('models') or {})} models")
    if d:
        for item in d:
            print(f"  DRIFT {item['kind']} {item['name']}: locked {item['expected'][:12]} "
                  f"!= actual {item['actual'][:12]}")
        sys.exit(1)
    print("  reproducible (no drift vs installed state)")
