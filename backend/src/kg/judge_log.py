"""Judge decision log (SQLite singleton) — records ALL judge decisions."""

from __future__ import annotations

import sqlite3
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path

from . import runtime_data_root
from .ops_shared import data_dir
from .sqlite_lifecycle import SQLiteLifecycle

DATA_DIR = data_dir()
DB_PATH = DATA_DIR / "judge_log.db"

_lifecycle = SQLiteLifecycle()
_lock = _lifecycle.lock
_conn: sqlite3.Connection | None = None
_INITIAL_DB_PATH = DB_PATH

# Business rule (shared by admin_trends + admin_observability auto-reject
# metrics): a degree_cap rejection is structural (graph topology hit a degree
# limit), not a judge quality signal, so it is excluded from rejection counts.
DEGREE_CAP_EXCLUSION_SQL = "(reject_reason IS NULL OR reject_reason != 'degree_cap')"

_LOG_COLS = [
    "id",
    "user_id",
    "notebook_id",
    "from_id",
    "to_id",
    "similarity",
    "verdict",
    "confidence",
    "accepted",
    "reject_reason",
    "reason",
    "source",
    "created_at",
]
_COLS_SQL = ", ".join(_LOG_COLS)


def _accepted_from_storage(value: object) -> bool:
    """Normalize legacy SQLite text booleans while preserving native values."""
    if isinstance(value, str):
        return value.strip().casefold() in {"1", "true"}
    return bool(value)


def _initialize_schema(conn: sqlite3.Connection) -> None:
    from .sqlite_utils import init_sqlite_pragmas

    init_sqlite_pragmas(conn)
    conn.execute("""
            CREATE TABLE IF NOT EXISTS judge_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id TEXT NOT NULL,
                notebook_id TEXT NOT NULL,
                from_id TEXT NOT NULL,
                to_id TEXT NOT NULL,
                similarity REAL,
                verdict TEXT NOT NULL,
                confidence REAL NOT NULL,
                accepted INTEGER NOT NULL,
                reject_reason TEXT,
                reason TEXT,
                source TEXT NOT NULL DEFAULT 'auto',
                created_at TEXT NOT NULL
            )
        """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_jl_user_nb ON judge_log(user_id, notebook_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_jl_created ON judge_log(created_at)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_jl_user_source ON judge_log(user_id, source)")


def _db_path() -> Path:
    return DB_PATH if DB_PATH != _INITIAL_DB_PATH else runtime_data_root.current() / "judge_log.db"


def _get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is None and _lifecycle.connection is not None:
        _lifecycle.reset()
    _conn = _lifecycle.get_connection(_db_path(), _initialize_schema)
    return _conn


def reset() -> None:
    global _conn
    _lifecycle.reset()
    _conn = None


def _reset() -> None:
    """Close & nullify connection (for tests)."""
    reset()


def record(
    *,
    user_id: str,
    notebook_id: str,
    from_id: str,
    to_id: str,
    similarity: float | None,
    verdict: str,
    confidence: float,
    accepted: bool,
    reject_reason: str | None = None,
    reason: str = "",
    source: str = "auto",
) -> None:
    """Record a judge decision."""
    if not user_id:
        return
    now = datetime.now(UTC).isoformat()
    with _lock:
        conn = _get_conn()
        conn.execute(
            """INSERT INTO judge_log
               (user_id, notebook_id, from_id, to_id, similarity,
                verdict, confidence, accepted, reject_reason, reason, source, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                user_id,
                notebook_id,
                from_id,
                to_id,
                similarity,
                verdict,
                float(confidence),
                int(accepted),
                reject_reason,
                reason,
                source,
                now,
            ),
        )
        conn.commit()


def update_to_rejected(
    from_id: str,
    to_id: str,
    *,
    reason: str,
    source: str = "auto",
) -> bool:
    """Flip the most recent ``(from_id, to_id, source, accepted=1)`` row into
    ``accepted=0`` with ``reject_reason=reason``.

    Used when the LLM accepted a candidate but a downstream constraint
    (e.g. degree cap) rejected it. Mutating the existing row — rather than
    appending a second one — keeps ``get_acceptance_stats`` from double-counting
    the candidate against the model's acceptance rate.

    Returns ``True`` iff a row was updated.
    """
    with _lock:
        conn = _get_conn()
        cur = conn.execute(
            "UPDATE judge_log SET accepted=0, reject_reason=? "
            "WHERE id = ("
            "  SELECT id FROM judge_log "
            "  WHERE from_id=? AND to_id=? AND source=? AND accepted=1 "
            "  ORDER BY id DESC LIMIT 1"
            ")",
            (reason, from_id, to_id, source),
        )
        conn.commit()
        return cur.rowcount > 0


_LOG_COLS = [
    "id",
    "user_id",
    "notebook_id",
    "from_id",
    "to_id",
    "similarity",
    "verdict",
    "confidence",
    "accepted",
    "reject_reason",
    "reason",
    "source",
    "created_at",
]
_COLS_SQL = ", ".join(_LOG_COLS)


def get_log(user_id: str, *, notebook_id: str | None = None, limit: int = 1000) -> list[dict]:
    """Retrieve judge log entries for a user.

    Intentional test-only / read API: kept public as the row-level read
    counterpart to ``record`` / ``get_acceptance_stats``. No production caller
    today (admin history uses ``translate_log.get_log``); exercised by
    ``test_judge_log``, ``test_judge_edges`` and ``test_judge_log_integration``.
    """
    with _lock:
        conn = _get_conn()
        if notebook_id is not None:
            rows = conn.execute(
                f"SELECT {_COLS_SQL} FROM judge_log WHERE user_id = ? AND notebook_id = ? ORDER BY id DESC LIMIT ?",
                (user_id, notebook_id, limit),
            ).fetchall()
        else:
            rows = conn.execute(
                f"SELECT {_COLS_SQL} FROM judge_log WHERE user_id = ? ORDER BY id DESC LIMIT ?",
                (user_id, limit),
            ).fetchall()
    result = []
    for row in rows:
        d = dict(zip(_LOG_COLS, row, strict=True))
        d["accepted"] = _accepted_from_storage(d["accepted"])
        result.append(d)
    return result


def get_acceptance_stats(*, user_id: str | None = None) -> dict:
    """Return judge acceptance stats. Optionally filtered by user_id.

    Excludes rows with ``reject_reason='degree_cap'`` — those are pipeline
    cap evictions, not model decisions, so they would otherwise depress
    the apparent model acceptance rate.
    """
    if not DB_PATH.exists():
        return {"total": 0, "accepted": 0, "rejected": 0, "rate": None}
    base_where = f"source = 'auto' AND {DEGREE_CAP_EXCLUSION_SQL}"
    with _lock:
        conn = _get_conn()
        if user_id is not None:
            row = conn.execute(
                f"SELECT COUNT(*) AS total, SUM(accepted) AS accepted "
                f"FROM judge_log WHERE {base_where} AND user_id = ?",
                (user_id,),
            ).fetchone()
        else:
            row = conn.execute(
                f"SELECT COUNT(*) AS total, SUM(accepted) AS accepted FROM judge_log WHERE {base_where}"
            ).fetchone()
    total = row[0] or 0
    accepted = row[1] or 0
    rejected = total - accepted
    return {
        "total": total,
        "accepted": accepted,
        "rejected": rejected,
        "rate": round(accepted / total, 4) if total > 0 else None,
    }


def delete_for_users(user_ids: Iterable[str]) -> int:
    """Delete every row owned by the supplied user IDs (judge decisions).

    Account erasure hook: the database lives at the data root, not under each
    user's directory. Idempotent; unrelated user IDs are never touched.
    """
    ids = tuple(dict.fromkeys(user_ids))
    if not ids:
        return 0

    deleted = 0
    with _lock:
        conn = _get_conn()
        try:
            deleted += conn.executemany(
                "DELETE FROM judge_log WHERE user_id = ?",
                ((user_id,) for user_id in ids),
            ).rowcount
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return deleted
