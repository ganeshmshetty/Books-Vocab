"""Log real LLM infrastructure failures (429/5xx/timeout) — the missing signal.

Unlike token_tracker (which only records successful calls with usage data),
this singleton captures exceptions that abort before a response is returned.
Every row represents a terminal LLM failure that the SDK's default retries
could not recover from. Best-effort recording: the tracked_llm wrapper
swallows any recording error so an LLM outage can never be masked by a
logging fault.
"""

from __future__ import annotations

import re
import sqlite3
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta

from . import runtime_data_root
from .ops_shared import data_dir
from .sqlite_lifecycle import SQLiteLifecycle

DATA_DIR = data_dir()
DB_PATH = DATA_DIR / "llm_errors.db"

_lifecycle = SQLiteLifecycle()
_lock = _lifecycle.lock
_conn: sqlite3.Connection | None = None
_INITIAL_DB_PATH = DB_PATH

_BEARER_RE = re.compile(
    r"([\"']?Authorization[\"']?\s*[:=]\s*[\"']?Bearer\s+)([^\s,;\"'}]+)",
    re.IGNORECASE,
)
_SECRET_ASSIGNMENT_RE = re.compile(
    r"(?P<keyquote>[\"']?)"
    r"(?P<key>"
    r"[A-Z0-9_-]*(?:api[_-]?key|password|secret|credentials?)[A-Z0-9_-]*"
    r"|(?:access|refresh|id|auth|bearer)[_-]?token"
    r"|token"
    r")"
    r"(?P=keyquote)"
    r"(?P<sep>\s*[:=]\s*)"
    r"(?P<valuequote>[\"']?)"
    r"(?P<value>[^\s,;\"'}]+)"
    r"(?P=valuequote)",
    re.IGNORECASE,
)
_OPENAI_STYLE_KEY_RE = re.compile(r"\bsk-[A-Za-z0-9._-]+")


def _get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is None and _lifecycle.connection is not None:
        _lifecycle.reset()
    db_path = DB_PATH if DB_PATH != _INITIAL_DB_PATH else runtime_data_root.current() / "llm_errors.db"
    _conn = _lifecycle.get_connection(db_path, _initialize_schema)
    return _conn


def _initialize_schema(conn: sqlite3.Connection) -> None:
    from .sqlite_utils import ensure_columns

    conn.execute("""
            CREATE TABLE IF NOT EXISTS llm_errors (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id TEXT NOT NULL,
                call_type TEXT NOT NULL,
                provider TEXT,
                model TEXT,
                error_class TEXT NOT NULL,
                status_code INTEGER,
                message TEXT,
                created_at TEXT NOT NULL
            )
        """)
    # Ensure columns for future migrations (mirrors token_tracker pattern).
    ensure_columns(
        conn,
        "llm_errors",
        {
            "provider": "TEXT",
            "model": "TEXT",
            "status_code": "INTEGER",
            "message": "TEXT",
        },
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_le_user ON llm_errors(user_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_le_user_created ON llm_errors(user_id, created_at)")
    # Bare created_at index for the retention pruner.
    conn.execute("CREATE INDEX IF NOT EXISTS idx_le_created ON llm_errors(created_at)")
    # Match count_errors_since's UTC-normalizing expression index.
    conn.execute("CREATE INDEX IF NOT EXISTS idx_le_created_utc ON llm_errors(datetime(created_at))")


def _reset() -> None:
    """Close & nullify connection (for tests)."""
    reset()


def reset() -> None:
    global _conn
    _lifecycle.reset()
    _conn = None


def redact_message(message: str | None) -> str:
    """Remove secret-like values from provider/SDK error text before logging."""
    if not message:
        return ""
    redacted = _BEARER_RE.sub(r"\1[REDACTED]", message)
    redacted = _SECRET_ASSIGNMENT_RE.sub(
        lambda match: (
            f"{match.group('keyquote')}{match.group('key')}{match.group('keyquote')}"
            f"{match.group('sep')}{match.group('valuequote')}[REDACTED]"
            f"{match.group('valuequote')}"
        ),
        redacted,
    )
    return _OPENAI_STYLE_KEY_RE.sub("[REDACTED]", redacted)


def record(
    *,
    user_id: str,
    call_type: str,
    provider: str | None = None,
    model: str | None = None,
    error_class: str,
    status_code: int | None = None,
    message: str | None = None,
) -> None:
    """Record a terminal LLM failure.

    ``error_class`` is ``type(exc).__name__`` (e.g. ``"RateLimitError"``).
    ``status_code`` is the HTTP status when available (429, 500, etc.);
    ``None`` for timeouts and connection errors.
    ``message`` is ``str(exc)`` truncated to 500 chars.
    """
    if not user_id:
        return
    now = datetime.now(UTC).isoformat()
    with _lock:
        conn = _get_conn()
        conn.execute(
            "INSERT INTO llm_errors "
            "(user_id, call_type, provider, model, error_class, status_code, message, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (user_id, call_type, provider, model, error_class, status_code, redact_message(message)[:500], now),
        )
        conn.commit()


def count_errors_since(window_min: int) -> int:
    """Count terminal LLM failures recorded in the last ``window_min`` minutes.

    Windowed by ``created_at`` (event-occurrence time), mirroring the
    judge/translate observability checks. SQLite normalizes ISO 8601 offsets
    before comparing timestamps so rows written with non-UTC offsets are
    filtered by their actual UTC instant. Parameterised query under the
    singleton lock; read-only.
    """
    cutoff = (datetime.now(UTC) - timedelta(minutes=window_min)).isoformat()
    with _lock:
        conn = _get_conn()
        row = conn.execute(
            "SELECT COUNT(*) FROM llm_errors WHERE datetime(created_at) >= datetime(?)",
            (cutoff,),
        ).fetchone()
    return int(row[0] or 0)


def delete_for_users(user_ids: Iterable[str]) -> int:
    """Delete every row owned by the supplied user IDs (LLM error log).

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
                "DELETE FROM llm_errors WHERE user_id = ?",
                ((user_id,) for user_id in ids),
            ).rowcount
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return deleted
