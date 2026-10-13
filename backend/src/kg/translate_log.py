"""Translate/explain LLM call log + cross-user cache (SQLite singleton)."""

from __future__ import annotations

import os
import sqlite3
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta
from pathlib import Path

from . import runtime_data_root
from .sqlite_lifecycle import SQLiteLifecycle

CACHE_TTL_DAYS_DEFAULT = 30

_lifecycle = SQLiteLifecycle()
_lock = _lifecycle.lock
_conn: sqlite3.Connection | None = None


def _cache_ttl_days() -> int:
    """Resolve translate cache TTL (days) from env on every call.

    Env: ``TRANSLATE_CACHE_TTL_DAYS``.

    Semantics:
      - unset / empty string → default (``CACHE_TTL_DAYS_DEFAULT`` = 30 days)
      - non-integer (e.g. ``"30.5"``, ``"abc"``) → fallback to default
      - negative integer (e.g. ``"-5"``) → fallback to default
      - **``"0"`` → disable cache** (always miss): ``lookup()`` uses
        ``created_at > now - 0 days``, so every existing row is filtered out.
        Use this to force fresh LLM calls after a prompt change without a
        code release.
      - positive integer → that many days
    """
    raw = os.getenv("TRANSLATE_CACHE_TTL_DAYS")
    if raw is None or raw == "":
        return CACHE_TTL_DAYS_DEFAULT
    try:
        val = int(raw)
    except ValueError:
        return CACHE_TTL_DAYS_DEFAULT
    return val if val >= 0 else CACHE_TTL_DAYS_DEFAULT


def _db_path() -> Path:
    return runtime_data_root.current() / "translate_log.db"


def _initialize_schema(conn: sqlite3.Connection) -> None:
    from .sqlite_utils import ensure_columns

    conn.execute("""
            CREATE TABLE IF NOT EXISTS translate_log (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id     TEXT NOT NULL,
                operation   TEXT NOT NULL,
                word        TEXT NOT NULL,
                context     TEXT,
                context_hash TEXT NOT NULL,
                source_lang TEXT NOT NULL,
                target_lang TEXT NOT NULL,
                response_raw TEXT NOT NULL,
                latency_ms  INTEGER,
                created_at  TEXT NOT NULL
            )
        """)
    # Precise cache-hit counter: every short-circuited cache hit gets one row.
    # Separate table so the existing translate_log (= misses / LLM calls) stays
    # canonical and we can compute hit rate = hits / (hits + misses).
    conn.execute("""
            CREATE TABLE IF NOT EXISTS translate_cache_hits (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id     TEXT,
                operation   TEXT NOT NULL,
                word        TEXT NOT NULL,
                context_hash TEXT NOT NULL,
                source_lang TEXT NOT NULL,
                target_lang TEXT NOT NULL,
                created_at  TEXT NOT NULL
            )
        """)
    # Migration: add `model` column to both tables for cache-key inclusion.
    # Translation output is model-dependent (prompt format, instruction
    # following, style), so switching model must invalidate prior cache rows.
    # Pre-migration rows default to model='' — they only match requests that
    # also pass model='' (none in current code paths), so legacy entries
    # expire naturally via TTL without being served to mismatched callers.
    for table in ("translate_log", "translate_cache_hits"):
        ensure_columns(conn, table, {"model": "TEXT NOT NULL DEFAULT ''"})
    # Rebuild cache lookup index to include model. Old name retained for
    # any external observers; content now covers the new key shape.
    conn.execute("DROP INDEX IF EXISTS idx_tl_cache")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_tl_cache ON translate_log(word, context_hash, source_lang, target_lang, operation, model)"
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tl_user ON translate_log(user_id, created_at)")
    # Bare created_at index for the retention pruner's
    # `DELETE ... WHERE created_at < ?`; idx_tl_user leads with user_id so
    # SQLite can't use it for a bare-created_at predicate (idx_tch_created
    # already covers translate_cache_hits the same way).
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tl_created ON translate_log(created_at)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tch_created ON translate_cache_hits(created_at)")


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
    reset()


def lookup(
    word: str,
    context_hash: str,
    source_lang: str,
    target_lang: str,
    operation: str,
    model: str = "",
) -> str | None:
    """Return cached LLM response for the given key (incl. model), or None.

    `model` is part of the cache key — different models produce different
    outputs (prompt format, instruction-following, style), so a row written
    by one model must not satisfy a request for another. Default `""` keeps
    legacy callers (tests, scripts) compiling; production paths in
    `translate_service` always pass an explicit model.
    """
    cutoff = (datetime.now(UTC) - timedelta(days=_cache_ttl_days())).isoformat()
    with _lock:
        conn = _get_conn()
        row = conn.execute(
            "SELECT response_raw FROM translate_log WHERE word=? AND context_hash=? AND source_lang=? AND target_lang=? AND operation=? AND model=? AND julianday(created_at)>julianday(?) ORDER BY id DESC LIMIT 1",
            (word, context_hash, source_lang, target_lang, operation, model, cutoff),
        ).fetchone()
    return row[0] if row else None


def record(
    *,
    user_id,
    operation,
    word,
    context,
    context_hash,
    source_lang,
    target_lang,
    response_raw,
    latency_ms,
    model: str = "",
) -> None:
    if not user_id:
        return
    now = datetime.now(UTC).isoformat()
    with _lock:
        conn = _get_conn()
        conn.execute(
            "INSERT INTO translate_log (user_id, operation, word, context, context_hash, source_lang, target_lang, response_raw, latency_ms, created_at, model) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (
                user_id,
                operation,
                word,
                context,
                context_hash,
                source_lang,
                target_lang,
                response_raw,
                int(latency_ms or 0),
                now,
                model,
            ),
        )
        conn.commit()


def record_cache_hit(
    *,
    user_id: str | None,
    operation: str,
    word: str,
    context_hash: str,
    source_lang: str,
    target_lang: str,
    model: str = "",
) -> None:
    """Record one translate cache hit.

    Called from `translate_service` whenever `lookup()` short-circuits an LLM
    call. Counts toward the precise cache hit rate exposed by admin
    observability. user_id may be None for anonymous/unauth calls — still
    counted. `model` is captured for parity with the miss table.
    """
    now = datetime.now(UTC).isoformat()
    with _lock:
        conn = _get_conn()
        conn.execute(
            "INSERT INTO translate_cache_hits (user_id, operation, word, context_hash, source_lang, target_lang, created_at, model) VALUES (?,?,?,?,?,?,?,?)",
            (user_id, operation, word, context_hash, source_lang, target_lang, now, model),
        )
        conn.commit()


def get_log(
    user_id: str,
    *,
    limit: int = 200,
    q: str | None = None,
    op: str | None = None,
) -> list[dict]:
    """Return translate log entries for a user, newest first.

    Filters:
      - ``op``: exact match against ``operation`` (e.g. ``translate_quick``).
      - ``q``: case-insensitive substring match against ``word`` OR ``context``.
        SQL ``LIKE`` wildcards (``%``, ``_``) inside ``q`` are escaped via an
        explicit ``ESCAPE`` clause so admin search input can't accidentally
        match everything.
    """
    where = ["user_id = ?"]
    params: list = [user_id]

    if op:
        where.append("operation = ?")
        params.append(op)

    q_clean = (q or "").strip()
    if q_clean:
        escaped = q_clean.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        like = f"%{escaped}%"
        where.append("(LOWER(word) LIKE LOWER(?) ESCAPE '\\' OR LOWER(IFNULL(context,'')) LIKE LOWER(?) ESCAPE '\\')")
        params.extend([like, like])

    # One list drives both the SELECT and the zip below, so a schema drift
    # surfaces as an explicit SQL error (missing column) rather than zip()
    # silently truncating the row and dropping a field — which `SELECT *` paired
    # with a hand-maintained column list would hide. `model` is appended via
    # ALTER TABLE after the 11 CREATE-TABLE columns.
    cols = [
        "id",
        "user_id",
        "operation",
        "word",
        "context",
        "context_hash",
        "source_lang",
        "target_lang",
        "response_raw",
        "latency_ms",
        "created_at",
        "model",
    ]
    sql = f"SELECT {', '.join(cols)} FROM translate_log WHERE " + " AND ".join(where) + " ORDER BY id DESC LIMIT ?"
    params.append(limit)

    with _lock:
        conn = _get_conn()
        rows = conn.execute(sql, tuple(params)).fetchall()
    return [dict(zip(cols, row, strict=True)) for row in rows]


def delete_for_users(user_ids: Iterable[str]) -> int:
    """Delete every row owned by the supplied user IDs (miss log and cache-hit log).

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
                "DELETE FROM translate_log WHERE user_id = ?",
                ((user_id,) for user_id in ids),
            ).rowcount
            deleted += conn.executemany(
                "DELETE FROM translate_cache_hits WHERE user_id = ?",
                ((user_id,) for user_id in ids),
            ).rowcount
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return deleted
