"""Data consistency scanner — find orphan rows / dangling references.

Five categories:
  1. cards.notebook_id → notebooks.id missing
  2. graph_links {from_id,to_id} → cards.id missing
  3. translate_log.user_id → users.json key missing
  4. judge_log {from_id,to_id} → cards.id missing (per user, per notebook)
  5. token_usage.user_id → users.json key missing

CLI:
    uv run python -m kg.orphan_scan --report                 # list + counts
    uv run python -m kg.orphan_scan --fix --dry-run          # preview deletions
    uv run python -m kg.orphan_scan --fix --confirm          # actually clean

The admin endpoint at ``GET /api/admin/orphans/scan`` is read-only and
exposes :func:`scan` results.

Fix policy:
  - Orphan card → set ``is_deleted = 1`` (soft delete, recoverable).
  - Orphan graph link → strip entry from JSON via atomic write.
  - Orphan translate_log / judge_log / token_usage rows → hard DELETE.
  - Fail closed: ``fix()`` (dry-run included) aborts with
    :class:`UserRegistryUnavailable` when ``users.json`` is missing, unreadable,
    malformed, not an object, or yields zero users while any log table still
    has rows — otherwise every row would look like a ghost and be deleted.
    ``scan()`` stays tolerant and flags ``user_registry_loaded: False``.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sqlite3
import sys
from pathlib import Path
from typing import Any

from ._fsutil import fsync_dir as _fsync_dir
from .sentry_init import init_sentry

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


class UserRegistryUnavailable(RuntimeError):
    """``users.json`` could not be trusted as the source of live user ids."""


def _load_user_ids(data_dir: Path, *, strict: bool = False) -> set[str]:
    """Read users.json and return the set of real user ids (skip ``_meta``).

    Non-strict (scan / admin endpoint): any failure warns and yields an empty
    set. ``strict=True`` (destructive paths) raises
    :class:`UserRegistryUnavailable` instead.
    """
    return _read_user_registry(data_dir, strict=strict)[0]


def _read_user_registry(data_dir: Path, *, strict: bool = False) -> tuple[set[str], bool]:
    """Return ``(user_ids, loaded_ok)``; see :func:`_load_user_ids`."""
    users_file = data_dir / "users.json"
    try:
        payload = json.loads(users_file.read_text())
        if not isinstance(payload, dict):
            raise ValueError("users.json top level is not an object")
    except (OSError, ValueError) as exc:  # JSONDecodeError is a ValueError
        if strict:
            raise UserRegistryUnavailable(f"cannot load user registry {users_file}: {exc}") from exc
        logger.warning("Could not load %s: %s", users_file, exc)
        return set(), False
    return {k for k in payload if isinstance(k, str) and not k.startswith("_")}, True


def _user_log_tables_have_rows(data_dir: Path) -> bool:
    """True if any user-keyed log table (translate_log/judge_log/token_usage) has rows."""
    for db, table in (
        ("translate_log.db", "translate_log"),
        ("judge_log.db", "judge_log"),
        ("token_usage.db", "token_usage"),
    ):
        db_path = data_dir / db
        if not db_path.exists():
            continue
        with sqlite3.connect(str(db_path)) as conn:
            try:
                if conn.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone():
                    return True
            except sqlite3.OperationalError:
                continue
    return False


def _iter_user_dirs(data_dir: Path, known_users: set[str]) -> list[tuple[str, Path]]:
    """List (user_id, user_dir) for every users/<uid> directory that maps to
    a real user.  Directories without a matching users.json entry are skipped
    (they are themselves orphans, but cleaning them up is outside this scope)."""
    users_root = data_dir / "users"
    if not users_root.exists():
        return []
    out: list[tuple[str, Path]] = []
    for entry in users_root.iterdir():
        if not entry.is_dir():
            continue
        if entry.name in known_users:
            out.append((entry.name, entry))
    return out


def _all_cards_with_state(cards_db: Path) -> list[tuple[str, str, int]]:
    """Return ``[(card_id, notebook_id, is_deleted), ...]`` — full set."""
    if not cards_db.exists():
        return []
    with sqlite3.connect(str(cards_db)) as conn:
        return conn.execute("SELECT id, notebook_id, is_deleted FROM card").fetchall()


def _judge_rows_for_user(data_dir: Path, uid: str) -> bool:
    """True if judge_log.db has at least one row for ``uid``."""
    judge_db = data_dir / "judge_log.db"
    if not judge_db.exists():
        return False
    with sqlite3.connect(str(judge_db)) as conn:
        try:
            return conn.execute("SELECT 1 FROM judge_log WHERE user_id = ? LIMIT 1", (uid,)).fetchone() is not None
        except sqlite3.OperationalError:
            return False


def _live_notebook_ids(nb_db: Path) -> set[str]:
    """Return the set of notebook ids that exist (incl. soft-deleted).

    Soft-deleted notebooks still count as 'existing' for the cards→notebook
    orphan check — only fully-missing rows are flagged."""
    if not nb_db.exists():
        return set()
    with sqlite3.connect(str(nb_db)) as conn:
        rows = conn.execute("SELECT id FROM notebook").fetchall()
    return {row[0] for row in rows}


def _list_graph_files(user_dir: Path) -> list[tuple[str, Path]]:
    """Return ``[(notebook_id, graph_path), ...]``."""
    out: list[tuple[str, Path]] = []
    for path in user_dir.glob("graph_*.json"):
        nb_id = path.stem[len("graph_") :]
        if not nb_id:
            continue
        out.append((nb_id, path))
    return out


#: Maximum number of timestamped ``.bak.<ts>`` files retained per graph file.
#: Older backups are pruned (oldest first) after each successful rewrite to
#: prevent unbounded growth in ``users/<uid>/`` directories.
_BAK_RETENTION = 3


def _prune_old_backups(path: Path) -> None:
    """Keep only the newest ``_BAK_RETENTION`` ``<path>.bak.<ts>`` files."""
    parent = path.parent
    stem = path.name  # includes ``.json``
    pattern = f"{stem}.bak.*"
    backups = sorted(parent.glob(pattern))  # lexicographic on .bak.<ts> == chronological
    excess = len(backups) - _BAK_RETENTION
    for old in backups[: max(0, excess)]:
        try:
            old.unlink()
        except OSError:
            logger.warning("Could not prune old backup %s", old)


def _atomic_write_json(path: Path, data: Any) -> None:
    """Write ``data`` to ``path`` atomically with timestamped backup retention.

    Sequence: write tmp → fsync(tmp) → timestamped backup of existing → rename
    → fsync(parent dir). ``os.replace`` is the POSIX-atomic rename primitive.
    fsync(tmp) ensures the payload is on disk before rename so a crash can't
    leave a half-written file under ``path``; fsync(parent dir) ensures the
    rename's directory-entry update is itself durable. Old backups beyond
    ``_BAK_RETENTION`` are pruned.
    """
    import time

    tmp = path.with_suffix(".json.tmp")
    payload = json.dumps(data, indent=2, ensure_ascii=False)
    tmp.write_text(payload)
    # Flush payload to disk before rename — without this a power loss between
    # rename and writeback can leave ``path`` pointing at zero-byte content.
    fd = os.open(str(tmp), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    if path.exists():
        # Timestamped backup so retention can prune oldest first. Resolution is
        # nanoseconds to keep filenames unique under rapid successive rewrites.
        ts = time.strftime("%Y%m%dT%H%M%S") + f"_{time.time_ns() % 1_000_000_000:09d}"
        backup = path.with_suffix(f".json.bak.{ts}")
        os.replace(str(path), str(backup))
    os.replace(str(tmp), str(path))
    # Persist the directory entry change so the rename survives a crash.
    _fsync_dir(path.parent)
    _prune_old_backups(path)


# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------


def _scan_user_orphans(db_path: Path, table: str, user_ids: set[str]) -> list[dict[str, Any]]:
    """Rows in ``table`` whose ``user_id`` has no live user.

    ``sample_ids`` (≤10) lets an admin spot-check ghost rows in dry-run reports
    before authorising a destructive ``fix --confirm`` run. A missing DB file or
    missing table yields an empty list (tolerant by design).
    """
    if not db_path.exists():
        return []
    orphans: list[dict[str, Any]] = []
    with sqlite3.connect(str(db_path)) as conn:
        try:
            rows = conn.execute(f"SELECT user_id, COUNT(*) FROM {table} GROUP BY user_id").fetchall()
        except sqlite3.OperationalError as exc:
            logger.warning("Failed to query orphan user rows from %s (%s)", table, exc)
            rows = []
        for uid, count in rows:
            if uid and uid not in user_ids:
                sample = [
                    r[0]
                    for r in conn.execute(
                        f"SELECT id FROM {table} WHERE user_id = ? ORDER BY id LIMIT 10",
                        (uid,),
                    ).fetchall()
                ]
                orphans.append({"user_id": uid, "rows": count, "sample_ids": sample})
    return orphans


def _scan_cards_and_graph_orphans(
    user_dirs: list[tuple[str, Path]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, set[str]]]:
    """Single pass over each user's cards.db + graph files.

    Returns ``(cards_orphan, graph_orphan, user_live_cards)``. The
    ``user_live_cards`` map is built here and threaded into the judge_log pass
    so cards.db is read exactly once per user — re-scanning a second time was
    wasteful and risked a TOCTOU race with concurrent writes.
    """
    cards_orphan: list[dict[str, Any]] = []
    graph_orphan: list[dict[str, Any]] = []
    user_live_cards: dict[str, set[str]] = {}

    for uid, udir in user_dirs:
        cards_db = udir / "cards.db"
        nb_db = udir / "notebooks.db"
        # Single pass over cards.db: walk all rows once and derive both the
        # live-id set (for graph/judge checks) and the orphan list.
        all_card_rows = _all_cards_with_state(cards_db)
        live_card_ids = {cid for cid, _nb, is_del in all_card_rows if not is_del}
        user_live_cards[uid] = live_card_ids
        nb_ids = _live_notebook_ids(nb_db)

        # 1. cards → notebook
        for cid, nb_id, is_deleted in all_card_rows:
            if is_deleted:
                continue
            if nb_id not in nb_ids:
                cards_orphan.append(
                    {
                        "user_id": uid,
                        "card_id": cid,
                        "notebook_id": nb_id,
                    }
                )

        # 2. graph_links → cards (per notebook)
        for nb_id, graph_path in _list_graph_files(udir):
            try:
                links = json.loads(graph_path.read_text())
            except (OSError, json.JSONDecodeError) as exc:
                logger.warning("Skipping malformed graph file for user %s: %s", uid, exc)
                continue
            if not isinstance(links, list):
                continue
            for lk in links:
                if not isinstance(lk, dict):
                    continue
                missing = []
                from_id = lk.get("from_id")
                to_id = lk.get("to_id")
                if from_id and from_id not in live_card_ids:
                    missing.append(from_id)
                if to_id and to_id not in live_card_ids:
                    missing.append(to_id)
                if missing:
                    graph_orphan.append(
                        {
                            "user_id": uid,
                            "notebook_id": nb_id,
                            "link_id": lk.get("id"),
                            "from_id": from_id,
                            "to_id": to_id,
                            "missing": missing,
                        }
                    )

    return cards_orphan, graph_orphan, user_live_cards


def _scan_judge_log_orphans(
    data_dir: Path,
    user_live_cards: dict[str, set[str]],
) -> list[dict[str, Any]]:
    """judge_log rows whose endpoints are missing/non-live cards.

    Reuses ``user_live_cards`` populated by :func:`_scan_cards_and_graph_orphans`
    rather than re-reading cards.db. The live-card set is passed in explicitly
    so this pass never re-scans the database.
    """
    judge_orphan: list[dict[str, Any]] = []
    judge_db = data_dir / "judge_log.db"
    if not judge_db.exists():
        return judge_orphan
    with sqlite3.connect(str(judge_db)) as conn:
        try:
            rows = conn.execute("SELECT id, user_id, notebook_id, from_id, to_id FROM judge_log").fetchall()
        except sqlite3.OperationalError as exc:
            logger.warning("Failed to query orphan judge_log rows: %s", exc)
            rows = []
    for row_id, uid, nb_id, from_id, to_id in rows:
        live = user_live_cards.get(uid)
        if live is None:
            # judge_log row for a user we don't know — covered by the
            # user-orphan category indirectly; flag both endpoints.
            judge_orphan.append(
                {
                    "id": row_id,
                    "user_id": uid,
                    "notebook_id": nb_id,
                    "from_id": from_id,
                    "to_id": to_id,
                    "missing": [from_id, to_id],
                }
            )
            continue
        missing = [c for c in (from_id, to_id) if c and c not in live]
        if missing:
            judge_orphan.append(
                {
                    "id": row_id,
                    "user_id": uid,
                    "notebook_id": nb_id,
                    "from_id": from_id,
                    "to_id": to_id,
                    "missing": missing,
                }
            )
    return judge_orphan


def scan(*, data_dir: Path) -> dict[str, Any]:
    """Read-only scan; returns a structured report.

    Shape::

        {
          "cards_orphan_notebook":      {"count": N, "items": [...]},
          "graph_links_orphan_card":    {"count": N, "items": [...]},
          "translate_log_orphan_user":  {"count": N, "items": [...]},
          "judge_log_orphan_card":      {"count": N, "items": [...]},
          "token_usage_orphan_user":    {"count": N, "items": [...]},
          "total": int,
          "user_registry_loaded": bool,  # False → user-keyed results untrustworthy
        }
    """
    data_dir = Path(data_dir)
    user_ids, registry_loaded = _read_user_registry(data_dir)
    user_dirs = _iter_user_dirs(data_dir, user_ids)

    # cards/graph pass builds ``user_live_cards`` once; the judge_log pass
    # reuses it (explicit hand-off — no second cards.db read).
    cards_orphan, graph_orphan, user_live_cards = _scan_cards_and_graph_orphans(user_dirs)

    # 4. judge_log — reuses ``user_live_cards`` from the cards/graph pass.
    judge_orphan = _scan_judge_log_orphans(data_dir, user_live_cards)

    # 3. translate_log → user
    translate_orphan = _scan_user_orphans(data_dir / "translate_log.db", "translate_log", user_ids)

    # 5. token_usage → user
    token_orphan = _scan_user_orphans(data_dir / "token_usage.db", "token_usage", user_ids)

    report = {
        "cards_orphan_notebook": {"count": len(cards_orphan), "items": cards_orphan},
        "graph_links_orphan_card": {"count": len(graph_orphan), "items": graph_orphan},
        "translate_log_orphan_user": {
            "count": len(translate_orphan),
            "items": translate_orphan,
        },
        "judge_log_orphan_card": {"count": len(judge_orphan), "items": judge_orphan},
        "token_usage_orphan_user": {"count": len(token_orphan), "items": token_orphan},
    }
    report["total"] = sum(v["count"] for v in report.values())
    report["user_registry_loaded"] = registry_loaded
    return report


# ---------------------------------------------------------------------------
# Fix
# ---------------------------------------------------------------------------


class OrphanFixAborted(RuntimeError):
    """Raised when ``fix()`` detects a graph file mutated mid-run.

    The fixer captures each graph file's ``mtime`` immediately before the
    rewrite phase begins; if the same path's ``mtime`` no longer matches at
    write time, another writer raced us and we abort rather than clobber it.
    Recover by running ``scan`` again (or quiescing the API) and retrying.
    """


def _delete_rows(db_path: Path, sql: str, params: list[tuple[Any, ...]]) -> None:
    """Run a parameterised DELETE against ``db_path`` (the DB ``scan()`` read).

    Opens its own connection so ``fix(data_dir=X)`` mutates exactly ``X``'s log
    DBs and never the process-wide module singletons. No-op when ``params`` is
    empty or the DB file / table is missing. Any other ``OperationalError``
    (locked, readonly, I/O) propagates so ``fix()``/the CLI fail loudly instead
    of reporting a deletion that never happened.
    """
    if not params or not db_path.exists():
        return
    conn = sqlite3.connect(str(db_path))
    try:
        conn.executemany(sql, params)
        conn.commit()
    except sqlite3.OperationalError as exc:
        if "no such table" not in str(exc):
            raise
        logger.warning("orphan delete skipped for %s: %s", db_path, exc)
    finally:
        conn.close()


def _delete_rows_by_user(db_path: Path, table: str, user_ids: list[str]) -> None:
    """Hard-DELETE all rows in ``table`` of ``db_path`` belonging to ghost users."""
    _delete_rows(db_path, f"DELETE FROM {table} WHERE user_id = ?", [(uid,) for uid in user_ids])


def fix(
    *,
    data_dir: Path,
    confirm: bool = False,
    dry_run: bool = True,
) -> dict[str, Any]:
    """Remove or soft-delete every orphan returned by :func:`scan`.

    Safety:
      - ``confirm`` must be ``True`` (raises ``ValueError`` otherwise).
      - ``dry_run=True`` reports counts without mutating anything.
      - Graph rewrites are guarded by an ``mtime`` check captured before the
        mutate phase; if any ``graph_*.json`` changed after scan,
        :class:`OrphanFixAborted` is raised before further writes.
      - Card soft-deletes go through ``CardStore`` so writes share the same
        per-process lock as the running API.

    Operational notes:
      - **CLI/offline tool only.** The admin endpoint deliberately imports
        :func:`scan` (read-only) and never :func:`fix`. Run during backend
        downtime or after stopping the API container.
      - There is no cross-process lock around the multi-step rewrite, so even
        with the mtime guard, prefer to quiesce the API before calling.
    """
    if not confirm:
        raise ValueError("orphan_scan.fix(): refusing to run without explicit confirm=True")

    # Fail closed BEFORE scan so even a dry-run never reports a bogus
    # "everything is a ghost" plan.
    user_ids = _load_user_ids(data_dir, strict=True)
    if not user_ids and _user_log_tables_have_rows(data_dir):
        raise UserRegistryUnavailable(
            f"user registry in {data_dir / 'users.json'} is empty but log tables have rows; refusing to treat all as orphans"
        )

    # A missing notebooks.db would make every live card look orphaned (#2705).
    for uid, udir in _iter_user_dirs(data_dir, user_ids):
        nb_db = udir / "notebooks.db"
        if not nb_db.exists() and any(not is_del for _cid, _nb, is_del in _all_cards_with_state(udir / "cards.db")):
            raise UserRegistryUnavailable(
                f"notebooks.db missing for user {uid} while cards.db has live cards; refusing to treat all as orphans"
            )
        # A missing cards.db would make every graph link / judge_log row look orphaned (#3434).
        if not (udir / "cards.db").exists() and (any(udir.glob("graph_*.json")) or _judge_rows_for_user(data_dir, uid)):
            raise UserRegistryUnavailable(
                f"cards.db missing for user {uid} while graph or judge_log data exists; refusing to treat all as orphans"
            )

    report = scan(data_dir=data_dir)
    summary: dict[str, Any] = {
        "dry_run": dry_run,
        "cards_orphan_notebook": {
            "would_delete": report["cards_orphan_notebook"]["count"],
        },
        "graph_links_orphan_card": {
            "would_delete": report["graph_links_orphan_card"]["count"],
        },
        "translate_log_orphan_user": {
            "would_delete": sum(it.get("rows", 0) for it in report["translate_log_orphan_user"]["items"])
            or report["translate_log_orphan_user"]["count"],
        },
        "judge_log_orphan_card": {
            "would_delete": report["judge_log_orphan_card"]["count"],
        },
        "token_usage_orphan_user": {
            "would_delete": sum(it.get("rows", 0) for it in report["token_usage_orphan_user"]["items"])
            or report["token_usage_orphan_user"]["count"],
        },
    }
    summary["total_deleted"] = report["total"]

    if dry_run:
        return summary

    # --- mutate ---
    # Lazy CardStore import keeps the CLI usable without the full app context.
    from .cards import CardStore

    # 1. soft-delete orphan cards via CardStore.delete — shares the API's
    # in-process write lock and uses the canonical soft-delete code path.
    cards_by_user: dict[str, list[str]] = {}
    for item in report["cards_orphan_notebook"]["items"]:
        cards_by_user.setdefault(item["user_id"], []).append(item["card_id"])
    for uid, card_ids in cards_by_user.items():
        cards_db = data_dir / "users" / uid / "cards.db"
        if not cards_db.exists():
            continue
        store = CardStore(cards_db)
        for cid in card_ids:
            store.delete(cid)

    # 2. strip orphan graph links — group by (user, notebook) file.
    # Capture mtime per file before any rewrite so a racing writer is detected
    # before we clobber its changes. We don't hold a cross-process lock here,
    # so this guard is the next best thing: re-scan and abort on drift.
    graph_by_file: dict[tuple[str, str], set[str]] = {}
    for item in report["graph_links_orphan_card"]["items"]:
        key = (item["user_id"], item["notebook_id"])
        link_id = item.get("link_id")
        if link_id is not None:
            graph_by_file.setdefault(key, set()).add(link_id)
    mtimes: dict[Path, float] = {}
    for (uid, nb_id), _ in graph_by_file.items():
        graph_path = data_dir / "users" / uid / f"graph_{nb_id}.json"
        if graph_path.exists():
            mtimes[graph_path] = graph_path.stat().st_mtime_ns
    for (uid, nb_id), bad_link_ids in graph_by_file.items():
        graph_path = data_dir / "users" / uid / f"graph_{nb_id}.json"
        if not graph_path.exists():
            continue
        # mtime guard — abort the entire fix if any racing writer touched it.
        current_mtime = graph_path.stat().st_mtime_ns
        if mtimes.get(graph_path) != current_mtime:
            raise OrphanFixAborted(
                f"graph file {graph_path} changed mid-run "
                f"(expected mtime_ns={mtimes.get(graph_path)}, "
                f"got {current_mtime}); aborting before clobbering."
            )
        try:
            links = json.loads(graph_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            logger.warning(
                "Could not read graph file for cleanup %s / user %s: %s",
                graph_path,
                uid,
                exc,
            )
            continue
        if not isinstance(links, list):
            continue
        kept = [lk for lk in links if lk.get("id") not in bad_link_ids]
        _atomic_write_json(graph_path, kept)

    # 3-5. delete log rows directly in data_dir's DBs (not the module singletons)
    _delete_rows_by_user(
        data_dir / "translate_log.db",
        "translate_log",
        [it["user_id"] for it in report["translate_log_orphan_user"]["items"]],
    )
    _delete_rows(
        data_dir / "judge_log.db",
        "DELETE FROM judge_log WHERE id = ?",
        [(it["id"],) for it in report["judge_log_orphan_card"]["items"]],
    )
    _delete_rows_by_user(
        data_dir / "token_usage.db",
        "token_usage",
        [it["user_id"] for it in report["token_usage_orphan_user"]["items"]],
    )

    return summary


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _resolve_data_dir() -> Path:
    from .settings import load_settings

    return load_settings().data_dir


def main(argv: list[str] | None = None) -> int:
    init_sentry(job="orphan_scan")
    parser = argparse.ArgumentParser(
        prog="kg.orphan_scan",
        description="Scan KG data for orphan rows; optionally clean them up.",
    )
    # --report and --fix are the two mutually-exclusive actions. One must be
    # specified explicitly — there is no implicit default, so an accidental
    # bare invocation prints help and exits non-zero instead of silently
    # running a scan.
    action = parser.add_mutually_exclusive_group()
    action.add_argument(
        "--report",
        action="store_true",
        help="Print the orphan scan report and exit.",
    )
    action.add_argument(
        "--fix",
        action="store_true",
        help="Run the fixer.  Requires --confirm to actually mutate; without --confirm, runs in dry-run mode.",
    )
    parser.add_argument(
        "--confirm",
        action="store_true",
        help="Acknowledge that --fix will mutate data.  Without this flag, --fix is forced into dry-run mode.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="With --fix, show what would be deleted without changing anything.",
    )
    parser.add_argument(
        "--data-dir",
        default=None,
        help="Override data directory (defaults to KGSettings.data_dir).",
    )
    args = parser.parse_args(argv)

    if not (args.report or args.fix):
        parser.print_help(sys.stderr)
        print(
            "\nerror: one of --report or --fix is required.",
            file=sys.stderr,
        )
        return 2

    data_dir = Path(args.data_dir) if args.data_dir else _resolve_data_dir()

    if args.fix:
        # Without --confirm we force dry-run + warn loudly.
        dry_run = args.dry_run or not args.confirm
        if not args.confirm:
            print("WARN: --fix without --confirm — running in dry-run mode. Re-run with --confirm to actually mutate.")
        try:
            summary = fix(data_dir=data_dir, confirm=True, dry_run=dry_run)
        except (UserRegistryUnavailable, OrphanFixAborted) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        return 0

    # args.report is True (mutex group guarantees this branch).
    report = scan(data_dir=data_dir)
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
