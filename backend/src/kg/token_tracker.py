"""Per-user LLM token usage tracking (SQLite singleton)."""

from __future__ import annotations

import sqlite3
from collections.abc import Iterable
from datetime import UTC, datetime

from . import runtime_data_root
from .ops_shared import data_dir
from .sqlite_lifecycle import SQLiteLifecycle

DATA_DIR = data_dir()
DB_PATH = DATA_DIR / "token_usage.db"

_lifecycle = SQLiteLifecycle()
_lock = _lifecycle.lock
_conn: sqlite3.Connection | None = None
_INITIAL_DB_PATH = DB_PATH


def _get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is None and _lifecycle.connection is not None:
        _lifecycle.reset()
    db_path = DB_PATH if DB_PATH != _INITIAL_DB_PATH else runtime_data_root.current() / "token_usage.db"
    _conn = _lifecycle.get_connection(db_path, _initialize_schema)
    return _conn


def _initialize_schema(conn: sqlite3.Connection) -> None:
    from .sqlite_utils import ensure_columns

    conn.execute("""
            CREATE TABLE IF NOT EXISTS token_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id TEXT NOT NULL,
                call_type TEXT NOT NULL,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                cached_input_tokens INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                provider TEXT,
                model TEXT
            )
        """)
    # Migrate pre-existing DBs: provider/model were added so each row
    # carries the truth used to price it. Older rows stay NULL and fall
    # back to the currently-routed provider in token_cost_usd().
    ensure_columns(
        conn,
        "token_usage",
        {"provider": "TEXT", "model": "TEXT", "cached_input_tokens": "INTEGER NOT NULL DEFAULT 0"},
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_user ON token_usage(user_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_user_created ON token_usage(user_id, created_at)")
    # Bare created_at index for the retention pruner's
    # `DELETE ... WHERE created_at < ?`; the two composite indexes lead
    # with user_id so SQLite can't use them for a bare-created_at predicate.
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tu_created ON token_usage(created_at)")


def reset() -> None:
    global _conn
    _lifecycle.reset()
    _conn = None


def record(
    user_id: str,
    call_type: str,
    input_tokens: int,
    output_tokens: int,
    *,
    cached_input_tokens: int = 0,
    provider: str | None = None,
    model: str | None = None,
) -> None:
    """Record token usage for a user.

    ``provider`` / ``model`` pin the LLM that produced this row so cost can
    later be priced from the row itself, not from whatever is routed now.
    Both are optional; omitting them writes NULL (legacy / unknown callers).
    ``cached_input_tokens`` is the prompt-cache-hit subset of ``input_tokens``
    (priced at the provider's cache rate); 0 when the provider reports none.
    """
    if not user_id:
        return
    now = datetime.now(UTC).isoformat()
    with _lock:
        conn = _get_conn()
        try:
            conn.execute(
                "INSERT INTO token_usage "
                "(user_id, call_type, input_tokens, output_tokens, cached_input_tokens, created_at, provider, model) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    user_id,
                    call_type,
                    int(input_tokens or 0),
                    int(output_tokens or 0),
                    int(cached_input_tokens or 0),
                    now,
                    provider,
                    model,
                ),
            )
            conn.commit()
        except Exception:
            # Close the implicit transaction so the shared connection does not
            # keep the write lock and block every other writer on this DB.
            conn.rollback()
            raise


def get_all_stats() -> dict[str, dict]:
    """Return aggregated token usage per user per call_type.

    Each call_type bucket also carries ``cost_usd``: provider slices are priced
    at their own row provider (NULL → currently routed), then folded together.
    """
    from .quota_service import token_cost_usd  # local: quota_service imports us

    with _lock:
        conn = _get_conn()
        rows = conn.execute("""
            SELECT user_id, call_type, provider,
                   SUM(input_tokens) as total_input,
                   SUM(output_tokens) as total_output,
                   SUM(cached_input_tokens) as total_cached,
                   COUNT(*) as calls
            FROM token_usage
            GROUP BY user_id, call_type, provider
        """).fetchall()
    stats: dict[str, dict] = {}
    for user_id, call_type, provider, total_input, total_output, total_cached, calls in rows:
        bucket = stats.setdefault(user_id, {}).setdefault(
            call_type,
            {"input_tokens": 0, "output_tokens": 0, "calls": 0, "cost_usd": 0.0},
        )
        t_in = total_input or 0
        t_out = total_output or 0
        bucket["input_tokens"] += t_in
        bucket["output_tokens"] += t_out
        bucket["calls"] += calls
        bucket["cost_usd"] += token_cost_usd(call_type, t_in, t_out, provider=provider, cached_tokens=total_cached or 0)
    return stats


def delete_for_users(user_ids: Iterable[str]) -> int:
    """Delete every token_usage row owned by the supplied user IDs.

    Account erasure hook: the database lives at the data root, not under each
    user's directory. Idempotent; unrelated user IDs are never touched.
    """
    ids = tuple(dict.fromkeys(user_ids))
    if not ids:
        return 0
    with _lock:
        conn = _get_conn()
        try:
            deleted = conn.executemany(
                "DELETE FROM token_usage WHERE user_id = ?",
                ((user_id,) for user_id in ids),
            ).rowcount
            conn.commit()
        except Exception:
            # Same contract as record(): close the implicit transaction so the
            # shared connection does not keep the write lock on token_usage.db.
            conn.rollback()
            raise
    return deleted
