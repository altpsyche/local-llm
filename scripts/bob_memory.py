"""Bob memory: store/recall via SQLite + BGE-M3 embeddings.

Usage:
  bob_memory.py [--db PATH] store "text" [--source user|session]
  bob_memory.py [--db PATH] recall "query" [--top 5] [--threshold 0.3]
  bob_memory.py [--db PATH] status
  bob_memory.py [--db PATH] clear [--yes]
  bob_memory.py [--db PATH] init-profile --name "Siva" --work "game dev"

Runs inside venv-litellm (has requests). Requires: sqlite-utils.
Embed endpoint: http://localhost:8081/v1/embeddings (BGE-M3, model=embed).
"""

import argparse
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import requests
    import sqlite_utils
except ImportError as e:
    print(f"Missing dependency: {e}. Run: pip install sqlite-utils requests", file=sys.stderr)
    sys.exit(1)

_DEFAULT_DB = Path(__file__).parent.parent / "data" / "bob.db"
EMBED_URL = "http://localhost:8081/v1/embeddings"
LITELLM_BASE = "http://localhost:8081/v1"
EMBED_MODEL = "embed"
_HEADERS = {"Authorization": "Bearer sk-local"}


def get_db(db_path) -> sqlite_utils.Database:
    db_path = Path(db_path)  # accept str (e.g. bob_core._get_db_path) or Path
    db_path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite_utils.Database(db_path)
    db.execute("""
        CREATE TABLE IF NOT EXISTS memories (
            id INTEGER PRIMARY KEY,
            content TEXT NOT NULL,
            embedding TEXT NOT NULL,
            source TEXT DEFAULT 'user',
            created_at TEXT DEFAULT (datetime('now')),
            last_used TEXT,
            use_count INTEGER DEFAULT 0
        )
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS profile (
            key TEXT PRIMARY KEY,
            value TEXT,
            updated_at TEXT DEFAULT (datetime('now'))
        )
    """)
    return db


def embed(text: str) -> list[float]:
    try:
        resp = requests.post(EMBED_URL, json={"model": EMBED_MODEL, "input": [text]}, headers=_HEADERS, timeout=15)
        resp.raise_for_status()
        return resp.json()["data"][0]["embedding"]
    except (requests.RequestException, KeyError, IndexError, ValueError) as e:
        raise RuntimeError(f"Embedding server unreachable or returned bad data at {EMBED_URL}: {e}") from e


def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    mag_a = math.sqrt(sum(x * x for x in a))
    mag_b = math.sqrt(sum(x * x for x in b))
    if mag_a == 0 or mag_b == 0:
        return 0.0
    return dot / (mag_a * mag_b)


# ---------------------------------------------------------------------------
# Importable core (M14) — one implementation for both the CLI (cmd_*) and
# bob_core.memory_store/recall. Neither prints; callers format their own output.
# ---------------------------------------------------------------------------

def store(content: str, db_path: Path, source: str = "user") -> tuple[int, bool]:
    """Insert a memory. Returns (id, is_new); is_new=False when a near-duplicate
    (cosine >= 0.95) already exists — that existing id is returned instead.
    Raises RuntimeError if the embed server is unreachable.

    Dedup is best-effort (M16): the read-then-insert is not transactional, so two
    concurrent stores of the same text could both insert — benign for a personal DB."""
    vec = embed(content)
    db = get_db(db_path)
    for eid, emb_json in db.execute("SELECT id, embedding FROM memories").fetchall():
        try:
            if cosine(vec, json.loads(emb_json)) >= 0.95:
                return eid, False
        except Exception:
            continue
    db["memories"].insert({
        "content": content,
        "embedding": json.dumps(vec),
        "source": source,
        "created_at": datetime.now(timezone.utc).isoformat(),
    })
    return db.execute("SELECT last_insert_rowid()").fetchone()[0], True


def recall(query: str, db_path: Path, k: int = 5, threshold: float = 0.3) -> list[dict]:
    """Return up to k memories matching query as {id, content, score} dicts (highest score
    first) and bump last_used/use_count on the hits. Raises RuntimeError if the embed server
    is unreachable. Returns [] for an empty query or an empty DB."""
    if not query.strip():
        return []
    db = get_db(db_path)
    rows = list(db.execute("SELECT id, content, embedding FROM memories").fetchall())
    if not rows:
        return []
    q_vec = embed(query)
    scored = []
    for row_id, content, emb_json in rows:
        try:
            score = cosine(q_vec, json.loads(emb_json))
        except Exception:
            continue
        if score >= threshold:
            scored.append({"id": row_id, "content": content, "score": round(score, 4)})
    scored.sort(key=lambda x: x["score"], reverse=True)
    results = scored[:k]
    if results:
        now = datetime.now(timezone.utc).isoformat()
        for r in results:
            db.execute(
                "UPDATE memories SET last_used=?, use_count=use_count+1 WHERE id=?",
                [now, r["id"]],
            )
    return results


def cmd_store(text: str, source: str, db_path: Path) -> None:
    try:
        mid, is_new = store(text, db_path, source=source)
    except RuntimeError as e:
        print(f"Cannot store memory — {e}", file=sys.stderr)
        return
    print(f"Stored memory (id={mid})" if is_new else f"Already stored (similar entry id={mid})")


def cmd_recall(query: str, top: int, threshold: float, db_path: Path) -> None:
    try:
        results = recall(query, db_path, k=top, threshold=threshold)
    except RuntimeError as e:
        print(f"Cannot recall — {e}", file=sys.stderr)
        print("[]")
        return
    print(json.dumps(results, ensure_ascii=False))


def cmd_status(db_path: Path) -> None:
    db = get_db(db_path)
    count = db.execute("SELECT COUNT(*) FROM memories").fetchone()[0]
    size_kb = db_path.stat().st_size / 1024 if db_path.exists() else 0
    last_row = db.execute("SELECT created_at FROM memories ORDER BY id DESC LIMIT 1").fetchone()
    last_stored = last_row[0] if last_row else "none"
    profile_rows = {r[0]: r[1] for r in db.execute("SELECT key, value FROM profile").fetchall()}
    print(f"DB:           {db_path}")
    print(f"Size:         {size_kb:.1f} KB")
    print(f"Memories:     {count}")
    print(f"Last stored:  {last_stored}")
    if profile_rows:
        print("Profile:")
        for k, v in profile_rows.items():
            print(f"  {k}: {v}")


def cmd_clear(yes: bool, db_path: Path) -> None:
    if not yes:
        ans = input("Delete ALL memories? This cannot be undone. Type 'yes' to confirm: ")
        if ans.strip().lower() != "yes":
            print("Aborted.")
            return
    db = get_db(db_path)
    db.execute("DELETE FROM memories")
    print("Memory cleared.")


def cmd_summarize_session(messages_file: str, model: str, db_path: Path) -> None:
    with open(messages_file, encoding="utf-8") as f:
        messages = json.load(f)

    turns = [m for m in messages if m.get("role") in ("user", "assistant")]
    if len(turns) < 2:
        print("Not enough turns to summarize.")
        return

    summary_prompt = [
        {
            "role": "system",
            "content": (
                "Summarize the following conversation into 2-5 bullet points capturing "
                "key facts, decisions, or preferences expressed by the user. Be concise."
            ),
        },
        {"role": "user", "content": json.dumps(turns)},
    ]

    try:
        resp = requests.post(
            f"{LITELLM_BASE}/chat/completions",
            json={"model": model, "messages": summary_prompt, "max_tokens": 256},
            headers=_HEADERS,
            timeout=60,
        )
        resp.raise_for_status()
        summary = resp.json()["choices"][0]["message"]["content"].strip()
    except (requests.RequestException, KeyError, IndexError, ValueError) as e:
        print(f"Session summary failed — LLM unreachable or bad response: {e}", file=sys.stderr)
        return
    if summary:
        cmd_store(summary, source="session", db_path=db_path)
        print("Session summarized and stored.")
    else:
        print("Empty summary returned — skipped.")


def cmd_init_profile(name: str, work: str, db_path: Path) -> None:
    db = get_db(db_path)
    now = datetime.now(timezone.utc).isoformat()
    for key, value in [("name", name), ("work", work)]:
        db.execute(
            "INSERT INTO profile (key, value, updated_at) VALUES (?, ?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
            [key, value, now],
        )
    print(f"Profile saved: name={name}, work={work}")


def main() -> None:
    parser = argparse.ArgumentParser(prog="bob_memory")
    parser.add_argument("--db", default=str(_DEFAULT_DB), help="Path to SQLite DB")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_store = sub.add_parser("store")
    p_store.add_argument("text")
    p_store.add_argument("--source", default="user")

    p_recall = sub.add_parser("recall")
    p_recall.add_argument("query")
    p_recall.add_argument("--top", type=int, default=5)
    p_recall.add_argument("--threshold", type=float, default=0.3)

    sub.add_parser("status")

    p_clear = sub.add_parser("clear")
    p_clear.add_argument("--yes", action="store_true")

    p_profile = sub.add_parser("init-profile")
    p_profile.add_argument("--name", required=True)
    p_profile.add_argument("--work", required=True)

    p_sum = sub.add_parser("summarize-session")
    p_sum.add_argument("--messages-file", required=True, help="Path to JSON file with messages array")
    p_sum.add_argument("--model", default="chat", help="LiteLLM model role to use for summarization")

    args = parser.parse_args()
    db_path = Path(args.db)

    if args.cmd == "store":
        cmd_store(args.text, args.source, db_path)
    elif args.cmd == "recall":
        cmd_recall(args.query, args.top, args.threshold, db_path)
    elif args.cmd == "status":
        cmd_status(db_path)
    elif args.cmd == "clear":
        cmd_clear(args.yes, db_path)
    elif args.cmd == "init-profile":
        cmd_init_profile(args.name, args.work, db_path)
    elif args.cmd == "summarize-session":
        cmd_summarize_session(args.messages_file, args.model, db_path)


if __name__ == "__main__":
    main()
