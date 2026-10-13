"""Per-user podcast playback progress store (SQLite singleton).

Companion to ``podcast_log.db`` and ``pipeline_runs.db`` — shares the same
threading.Lock + ``check_same_thread=False`` pattern with WAL + busy_timeout
via :func:`init_sqlite_pragmas`.

Schema:

* Composite primary key ``(user_id, series_id, ep_num)`` so each user has at
  most one row per episode. Last-write-wins by ``updated_at`` is enforced in
  :func:`upsert` (not by a trigger) so a stale write returns the existing
  newer row to the caller without clobbering it.
* ``updated_at`` is stored as the client-supplied ISO8601 string verbatim —
  iOS is the source of truth for monotonicity within a single device, and
  cross-device drift is resolved on wall-clock comparison just like
  ``PodcastProgress.updatedAt`` on the client.

The DB lives at ``podcast_progress.db`` under the :func:`set_data_dir`
override, else under the runtime data root (:func:`kg.runtime_data_root.current`).
First-time access auto-creates the table; no manual migration needed.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path

from . import runtime_data_root
from .sqlite_lifecycle import SQLiteLifecycle

_lifecycle = SQLiteLifecycle()
_lock = _lifecycle.lock
_conn: sqlite3.Connection | None = None
_override_data_dir: Path | None = None


def set_data_dir(path: Path | None) -> None:
    """Override the data_dir used by the singleton.

    Called from ``api.create_app`` so that the progress DB lives next to the
    same per-instance ``data_dir`` as the rest of the singletons honored via
    ``app.state.kg_settings``. Passing ``None`` reverts to
    :func:`kg.runtime_data_root.current` (used by tests after swap-back).
    """
    global _override_data_dir, _conn
    with _lock:
        _override_data_dir = path
        _lifecycle.reset()
        _conn = None


def _resolve_data_dir() -> Path:
    if _override_data_dir is not None:
        return _override_data_dir
    return runtime_data_root.current()


def _get_conn() -> sqlite3.Connection:
    """Return the singleton connection, opening it on first use.

    Re-opens automatically when the resolved data_dir changes between calls
    so the test fixture (which swaps ``data_dir`` per test) sees an isolated DB.
    """
    global _conn
    if _conn is None and _lifecycle.connection is not None:
        _lifecycle.reset()
    _conn = _lifecycle.get_connection(_resolve_data_dir() / "podcast_progress.db", _initialize_schema)
    return _conn


def _initialize_schema(conn: sqlite3.Connection) -> None:
    from .sqlite_utils import init_sqlite_pragmas

    init_sqlite_pragmas(conn)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS podcast_progress (
            user_id TEXT NOT NULL,
            series_id TEXT NOT NULL,
            ep_num INTEGER NOT NULL,
            position_sec REAL NOT NULL,
            duration_sec REAL NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (user_id, series_id, ep_num)
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_pp_user ON podcast_progress(user_id)")


def parse_instant(value: str) -> datetime | None:
    """Parse an ISO8601 ``updated_at`` to an aware UTC datetime.

    The shared canonicaliser for podcast ``updated_at`` instants: the LWW
    store (below) and the HTTP router's ``_canonical_updated_at`` both go
    through this so the store-layer and HTTP-layer agree bit-for-bit.

    Returns ``None`` if the string is unparseable so the caller can fall
    back to a conservative decision. Accepts both integer-second
    (``...:00+00:00``) and fractional-second (``...:00.250000+00:00``)
    widths — iOS started emitting the latter via ``.withFractionalSeconds``,
    so a stored integer-second row and an incoming fractional-second write
    can legitimately denote the same instant. ``datetime.fromisoformat``
    handles both transparently; comparing the parsed datetimes is the only
    correct ordering (a bare lexicographic compare misranks mixed widths
    because ASCII ``'+'`` < ``'.'``).
    """
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError, AttributeError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC)


def reset() -> None:
    """Close + nullify connection + clear override (for tests)."""
    global _conn, _override_data_dir
    with _lock:
        _lifecycle.reset()
        _conn = None
        _override_data_dir = None


def _reset() -> None:
    reset()


def _row_dict(series_id: str, ep_num: int, position_sec, duration_sec, updated_at) -> dict:
    """The on-the-wire progress record shape, shared by every read/write path."""
    return {
        "series_id": series_id,
        "ep_num": ep_num,
        "position_sec": position_sec,
        "duration_sec": duration_sec,
        "updated_at": updated_at,
    }


def upsert(
    *,
    user_id: str,
    series_id: str,
    ep_num: int,
    position_sec: float,
    duration_sec: float,
    updated_at: str,
) -> dict:
    """Insert or update the row for ``(user_id, series_id, ep_num)``.

    Last-write-wins by ``updated_at``: a strictly-older incoming write is
    ignored and the existing row is returned unchanged; a strictly-newer one
    overwrites. When the two instants are *equal* (same wall-clock second,
    possibly spelled in different ISO8601 widths) the timestamp can no longer
    order them, so the tie is broken by ``position_sec`` — the larger one
    wins. This mirrors iOS ``PodcastProgressStore.mergeRemoteProgress``
    (``remoteWins = item.positionSec > local.lastPlayedTime``); without it the
    backend kept a first-writer-wins rule and two devices pushing different
    positions at the same second would diverge from the server forever
    (each device retains its own larger local position, every pull/push
    re-diverges). The position tie-break applies ONLY at an equal instant —
    a strictly-older write still loses regardless of how large its position
    is, so the timestamp ordering is not overridden.

    The comparison is on the *parsed* instants, not the raw ISO8601 strings.
    iOS emits fractional-second timestamps (``.withFractionalSeconds``) while
    older rows are integer-second; a lexicographic compare misranks those
    mixed widths (ASCII ``'+'`` 0x2B < ``'.'`` 0x2E, so ``"...:00+00:00"``
    always sorts before ``"...:00.250000+00:00"`` regardless of the actual
    instant). Parsing both sides with :func:`parse_instant` makes the LWW
    decision correct independently of how each side was serialised and does
    not rely on every caller pre-canonicalising its input.
    """
    incoming_dt = parse_instant(updated_at)
    with _lock:
        conn = _get_conn()
        row = conn.execute(
            "SELECT position_sec, duration_sec, updated_at FROM podcast_progress "
            "WHERE user_id = ? AND series_id = ? AND ep_num = ?",
            (user_id, series_id, ep_num),
        ).fetchone()
        stored_dt = parse_instant(row[2]) if row is not None else None
        # Stale decision. Comparison is on parsed instants; if either side is
        # unparseable, fall back to the raw string compare so a malformed
        # value can never crash the write path.
        if row is not None:
            if stored_dt is not None and incoming_dt is not None:
                if stored_dt == incoming_dt:
                    # Same instant — timestamp cannot order the two writes.
                    # Break the tie by position_sec (larger wins), matching the
                    # iOS mergeRemoteProgress rule so device<->server converges.
                    stale = float(position_sec) <= float(row[0])
                else:
                    stale = stored_dt > incoming_dt
            else:
                stale = row[2] >= updated_at
        else:
            stale = False
        if stale:
            # Existing row wins (strictly newer, or same instant with a
            # position >= the incoming one) — ignore the stale write.
            return _row_dict(series_id, ep_num, row[0], row[1], row[2])
        conn.execute(
            """
            INSERT INTO podcast_progress
                (user_id, series_id, ep_num, position_sec, duration_sec, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, series_id, ep_num) DO UPDATE SET
                position_sec = excluded.position_sec,
                duration_sec = excluded.duration_sec,
                updated_at = excluded.updated_at
            """,
            (user_id, series_id, ep_num, position_sec, duration_sec, updated_at),
        )
        conn.commit()
    return _row_dict(series_id, ep_num, position_sec, duration_sec, updated_at)


def get_single(*, user_id: str, series_id: str, ep_num: int) -> dict | None:
    with _lock:
        conn = _get_conn()
        row = conn.execute(
            "SELECT position_sec, duration_sec, updated_at FROM podcast_progress "
            "WHERE user_id = ? AND series_id = ? AND ep_num = ?",
            (user_id, series_id, ep_num),
        ).fetchone()
    if row is None:
        return None
    return _row_dict(series_id, ep_num, row[0], row[1], row[2])


def list_for_user(*, user_id: str, limit: int = 500) -> list[dict]:
    with _lock:
        conn = _get_conn()
        rows = conn.execute(
            "SELECT series_id, ep_num, position_sec, duration_sec, updated_at "
            "FROM podcast_progress WHERE user_id = ? "
            "ORDER BY unixepoch(updated_at, 'subsec') IS NOT NULL DESC, "
            "unixepoch(updated_at, 'subsec') DESC, updated_at DESC "
            "LIMIT ?",
            (user_id, limit),
        ).fetchall()
    return [_row_dict(s, e, p, d, u) for s, e, p, d, u in rows]


def delete_for_users(user_ids: Iterable[str]) -> int:
    """Delete every playback-progress row owned by the supplied user IDs.

    Account erasure needs this global store cleanup because the database lives
    at the data root rather than under each user's directory. Repeated calls
    are safe: already-absent rows are simply not counted, and unrelated user
    IDs are never included in the parameterized deletes.
    """
    ids = tuple(dict.fromkeys(user_ids))
    if not ids:
        return 0

    with _lock:
        conn = _get_conn()
        try:
            cursor = conn.executemany(
                "DELETE FROM podcast_progress WHERE user_id = ?",
                ((user_id,) for user_id in ids),
            )
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return cursor.rowcount
