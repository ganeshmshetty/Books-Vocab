"""Pipeline execution log (SQLite singleton) — records pipeline runs and their steps."""

from __future__ import annotations

import json
import logging
import sqlite3
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path

from . import runtime_data_root
from .ops_shared import data_dir
from .sqlite_lifecycle import SQLiteLifecycle

_DB_FILENAME = "pipeline_runs.db"
DATA_DIR = data_dir()
DB_PATH = DATA_DIR / _DB_FILENAME

_lifecycle = SQLiteLifecycle()
_lock = _lifecycle.lock
_conn: sqlite3.Connection | None = None
_INITIAL_DB_PATH = DB_PATH
_logger = logging.getLogger(__name__)


def _ensure_schema(conn: sqlite3.Connection) -> None:
    """Idempotent DDL — table + indexes. Side-effect-free (no row mutation)."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS pipeline_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id TEXT UNIQUE NOT NULL,
            user_id TEXT NOT NULL,
            notebook_id TEXT NOT NULL,
            trigger TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            status TEXT NOT NULL DEFAULT 'running',
            steps TEXT NOT NULL DEFAULT '[]'
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_pr_user ON pipeline_runs(user_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_pr_started ON pipeline_runs(started_at)")


def _connect(db_path: Path) -> sqlite3.Connection:
    global _conn
    if _conn is None and _lifecycle.connection is not None:
        _lifecycle.reset()
    _conn = _lifecycle.get_connection(db_path, _ensure_schema)
    return _conn


def _get_conn() -> sqlite3.Connection:
    """Acquire the singleton connection + ensure schema. **Read-safe**: opening
    the connection mutates no rows. Orphaned-run recovery is a *separate*,
    explicit step (:func:`reap_orphaned_runs`) wired into API startup — so a
    pure read (admin dashboard, telemetry query) can never trigger a write.

    The path follows :func:`runtime_data_root.current` — the root the running
    app holds the worker lock on — so runtime rows land where the startup
    sweep looks. A reassigned ``DB_PATH`` (test hook) still wins."""
    return _connect(DB_PATH if DB_PATH != _INITIAL_DB_PATH else runtime_data_root.current() / _DB_FILENAME)


def reset() -> None:
    global _conn
    _lifecycle.reset()
    _conn = None


def reap_orphaned_runs(data_root: Path) -> int:
    """Mark crashed ``running`` rows under ``data_root`` ``interrupted`` and return the count reaped.

    Single source of the crash-recovery semantic. Invoked **once at API
    startup** (lifespan, after the single-worker lock — see worker_guard),
    not lazily on first connection. Decoupling it from :func:`_get_conn` is
    the root-cause fix for the read-causes-write coupling that forced ops to
    re-implement a read-only path: connection acquisition is now provably
    side-effect-free, and the ``running→interrupted`` predicate lives in
    exactly one place. ``data_root`` is explicit (the locked
    ``settings.data_dir``), never re-read from ``KG_DATA_DIR``: the sweep is
    only safe for the directory whose worker lock this process holds.
    """
    with _lock:
        conn = _connect(data_root / _DB_FILENAME)
        cur = conn.execute(
            "UPDATE pipeline_runs SET status='interrupted', ended_at=? WHERE status='running'",
            (datetime.now(UTC).isoformat(),),
        )
        conn.commit()
        return cur.rowcount


def _reset() -> None:
    """Close & nullify connection (for tests)."""
    reset()


def _parse_steps(steps_json: str, *, run_id: str) -> list[dict] | None:
    """Parse a persisted step list, returning ``None`` for corrupt payloads."""
    try:
        steps = json.loads(steps_json)
    except (TypeError, json.JSONDecodeError) as exc:
        _logger.warning("Ignoring corrupt pipeline steps for run %s: %s", run_id, exc)
        return None
    if not isinstance(steps, list) or any(
        not isinstance(step, dict) or not isinstance(step.get("name"), str) for step in steps
    ):
        _logger.warning("Ignoring corrupt pipeline steps for run %s: invalid shape", run_id)
        return None
    return steps


def start_run(run_id: str, user_id: str, notebook_id: str, trigger: str) -> None:
    """Insert a new pipeline run with status='running', steps='[]'."""
    now = datetime.now(UTC).isoformat()
    with _lock:
        conn = _get_conn()
        conn.execute(
            "INSERT INTO pipeline_runs (run_id, user_id, notebook_id, trigger, started_at, steps) "
            "VALUES (?, ?, ?, ?, ?, '[]')",
            (run_id, user_id, notebook_id, trigger, now),
        )
        conn.commit()


def start_step(run_id: str, name: str) -> None:
    """Append a step entry with status='running', started_at=now to the run's steps JSON."""
    now = datetime.now(UTC).isoformat()
    with _lock:
        conn = _get_conn()
        row = conn.execute("SELECT steps FROM pipeline_runs WHERE run_id = ?", (run_id,)).fetchone()
        if not row:
            return
        steps = _parse_steps(row[0], run_id=run_id)
        if steps is None:
            return
        steps.append(
            {"name": name, "status": "running", "started_at": now, "ended_at": None, "items": 0, "error": None}
        )
        conn.execute(
            "UPDATE pipeline_runs SET steps = ? WHERE run_id = ?", (json.dumps(steps, ensure_ascii=False), run_id)
        )
        conn.commit()


def end_step(run_id: str, name: str, *, status: str = "ok", items: int = 0, error: str | None = None) -> None:
    """Update the matching step's status, ended_at, items, error in the steps JSON."""
    now = datetime.now(UTC).isoformat()
    with _lock:
        conn = _get_conn()
        row = conn.execute("SELECT steps FROM pipeline_runs WHERE run_id = ?", (run_id,)).fetchone()
        if not row:
            return
        steps = _parse_steps(row[0], run_id=run_id)
        if steps is None:
            return
        for step in reversed(steps):
            if step.get("name") == name:
                step["status"] = status
                step["ended_at"] = now
                step["items"] = items
                step["error"] = error
                break
        conn.execute(
            "UPDATE pipeline_runs SET steps = ? WHERE run_id = ?", (json.dumps(steps, ensure_ascii=False), run_id)
        )
        conn.commit()


def end_run(run_id: str, status: str) -> None:
    """Set ended_at and status on the run."""
    now = datetime.now(UTC).isoformat()
    with _lock:
        conn = _get_conn()
        conn.execute(
            "UPDATE pipeline_runs SET ended_at = ?, status = ? WHERE run_id = ?",
            (now, status, run_id),
        )
        conn.commit()


def _duration_s(start: str | None, end: str | None) -> float | None:
    """Seconds between two ISO timestamps, or None if either is missing or unparseable."""
    if not (start and end):
        return None
    try:
        return round((datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds(), 2)
    except (ValueError, TypeError):
        return None


_RUN_COLUMNS = "run_id, user_id, notebook_id, trigger, started_at, ended_at, status, steps"


def _run_from_row(row: tuple) -> dict:
    """Shape one ``_RUN_COLUMNS`` row as a run dict with parsed, timed steps."""
    run_id, uid, nb, trigger, started, ended, status, steps_json = row
    steps = _parse_steps(steps_json, run_id=run_id) or []
    for step in steps:
        step["duration_s"] = _duration_s(step.get("started_at"), step.get("ended_at"))
    return {
        "run_id": run_id,
        "user_id": uid,
        "notebook_id": nb,
        "trigger": trigger,
        "started_at": started,
        "ended_at": ended,
        "status": status,
        "duration_s": _duration_s(started, ended),
        "steps": steps,
    }


def get_runs(user_id: str, *, limit: int = 20) -> list[dict]:
    """Return recent runs for a user, newest first. Parses steps JSON."""
    with _lock:
        conn = _get_conn()
        rows = conn.execute(
            f"SELECT {_RUN_COLUMNS} FROM pipeline_runs WHERE user_id = ? "
            "ORDER BY julianday(started_at) DESC, started_at DESC LIMIT ?",
            (user_id, limit),
        ).fetchall()
    return [_run_from_row(row) for row in rows]


def get_run(run_id: str, user_id: str) -> dict | None:
    """Return ``user_id``'s run ``run_id`` in the ``get_runs`` shape, or None.

    A point lookup on the UNIQUE ``run_id``, independent of how many runs the
    user has; another user's run is None, never readable.
    """
    with _lock:
        conn = _get_conn()
        row = conn.execute(
            f"SELECT {_RUN_COLUMNS} FROM pipeline_runs WHERE run_id = ? AND user_id = ?",
            (run_id, user_id),
        ).fetchone()
    return _run_from_row(row) if row is not None else None


def delete_for_users(user_ids: Iterable[str]) -> int:
    """Delete every pipeline_runs row owned by the supplied user IDs.

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
                "DELETE FROM pipeline_runs WHERE user_id = ?",
                ((user_id,) for user_id in ids),
            ).rowcount
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return deleted
