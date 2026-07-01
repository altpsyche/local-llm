"""Bob session store (M12) — persist agent conversations to SQLite.

A Session bundles an id, a rolling message history ({role, content} turns), and an optional
token budget. The agent HTTP server uses it to support multi-turn, multi-client conversations
and to bound spend per client; the CLI stays stateless. This is the seam for future
multi-user / MCP work — not a full identity system, just id + history + budget persistence.
"""
import json
import sqlite3
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).parent.parent


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class SessionStore:
    """Thread-safe (single connection + lock) SQLite-backed session store."""

    def __init__(self, db_path):
        self.path = Path(db_path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(str(self.path), check_same_thread=False)
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id           TEXT PRIMARY KEY,
                created_at   TEXT NOT NULL,
                updated_at   TEXT NOT NULL,
                history      TEXT NOT NULL DEFAULT '[]',
                token_budget INTEGER NOT NULL DEFAULT 0,
                tokens_spent INTEGER NOT NULL DEFAULT 0,
                client       TEXT
            )
            """
        )
        self._conn.commit()

    def create(self, token_budget: int = 0, client: str = "") -> dict:
        sid = uuid.uuid4().hex
        now = _now()
        with self._lock:
            self._conn.execute(
                "INSERT INTO sessions (id, created_at, updated_at, history, token_budget, tokens_spent, client)"
                " VALUES (?,?,?,?,?,?,?)",
                [sid, now, now, "[]", int(token_budget), 0, client],
            )
            self._conn.commit()
        return self.get(sid)

    def get(self, sid: str):
        row = self._conn.execute(
            "SELECT id, created_at, updated_at, history, token_budget, tokens_spent, client"
            " FROM sessions WHERE id=?",
            [sid],
        ).fetchone()
        if not row:
            return None
        return {
            "id": row[0],
            "created_at": row[1],
            "updated_at": row[2],
            "history": json.loads(row[3]),
            "token_budget": row[4],
            "tokens_spent": row[5],
            "client": row[6],
        }

    def append_turn(self, sid: str, user_content: str, assistant_content, tokens_used: int = 0):
        """Append a user turn (+ assistant reply if any) and add tokens_used to the tally."""
        s = self.get(sid)
        if s is None:
            return None
        history = s["history"]
        history.append({"role": "user", "content": user_content})
        if assistant_content is not None:
            history.append({"role": "assistant", "content": assistant_content})
        with self._lock:
            self._conn.execute(
                "UPDATE sessions SET history=?, tokens_spent=tokens_spent+?, updated_at=? WHERE id=?",
                [json.dumps(history), int(tokens_used), _now(), sid],
            )
            self._conn.commit()
        return self.get(sid)

    def over_budget(self, sid: str) -> bool:
        """True if the session has a positive token_budget and has reached/exceeded it."""
        s = self.get(sid)
        if not s or not s["token_budget"]:
            return False
        return s["tokens_spent"] >= s["token_budget"]

    def delete(self, sid: str) -> bool:
        with self._lock:
            cur = self._conn.execute("DELETE FROM sessions WHERE id=?", [sid])
            self._conn.commit()
        return cur.rowcount > 0

    def list_ids(self) -> list:
        return [
            r[0]
            for r in self._conn.execute(
                "SELECT id FROM sessions ORDER BY updated_at DESC"
            ).fetchall()
        ]
