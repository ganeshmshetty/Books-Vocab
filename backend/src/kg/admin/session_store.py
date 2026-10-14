"""Revocation ledger for admin session cookies.

Admin cookies are stateless HMAC tokens, so logging out needs a server-side
record. This ledger holds the nonce of every logged-out session until that
session's absolute expiry: a replayed cookie is refused even after a process
restart. Rows past their expiry are pruned because the signature check already
rejects them.
"""

from __future__ import annotations

import sqlite3
import time
from pathlib import Path

from .. import runtime_data_root
from ..sqlite_lifecycle import SQLiteLifecycle

_lifecycle = SQLiteLifecycle()


def _db_path() -> Path:
    return runtime_data_root.current() / "admin_sessions.db"


def _initialize_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
            CREATE TABLE IF NOT EXISTS revoked_admin_sessions (
                nonce      TEXT PRIMARY KEY,
                expires_at INTEGER NOT NULL
            )
            """
    )


def _get_conn() -> sqlite3.Connection:
    return _lifecycle.get_connection(_db_path(), _initialize_schema)


def revoke(nonce: str, expires_at: int) -> None:
    """Record ``nonce`` as revoked until ``expires_at`` (epoch seconds)."""
    with _lifecycle.lock:
        conn = _get_conn()
        conn.execute("DELETE FROM revoked_admin_sessions WHERE expires_at < ?", (int(time.time()),))
        conn.execute(
            "INSERT OR REPLACE INTO revoked_admin_sessions (nonce, expires_at) VALUES (?, ?)",
            (nonce, expires_at),
        )
        conn.commit()


def is_revoked(nonce: str) -> bool:
    with _lifecycle.lock:
        row = _get_conn().execute("SELECT 1 FROM revoked_admin_sessions WHERE nonce = ?", (nonce,)).fetchone()
    return row is not None


def reset() -> None:
    """Close the cached connection; the next call reopens the ledger from disk."""
    _lifecycle.reset()
