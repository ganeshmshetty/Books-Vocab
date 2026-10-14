"""Startup reaper for orphaned staged shared-deck copies (#2269).

A copy stages its notebook hidden (``is_staged``) and compensates on any
in-process failure. A hard crash between staging and compensation (or between
the cards landing and ``record_copy``) leaves a staged notebook with committed
cards and no ``shared_deck_copy_log`` row — invisible but never cleaned. This
sweep compensates those: cards tombstoned, graph file and notebook row removed.
A notebook whose cleanup failed stays staged (cards still hidden) and is retried
by the next sweep; it is not counted as reaped.

A staged notebook WITH a copy_log row is a committed copy awaiting reveal; the
retry's ``_replay`` self-heals it, so it is left alone, as is anything younger
than ``older_than`` (a live copy may still be running).
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path

from ..cards import CardStore
from ..notebook import NotebookStore
from .copy import compensate_staged_copy
from .store import SharedDeckStore

_LOGGER = logging.getLogger(__name__)

DEFAULT_STALE_AFTER = timedelta(minutes=10)


def reap_stale_staged_copies(
    data_root: Path,
    *,
    shared_decks_path: Path,
    older_than: timedelta = DEFAULT_STALE_AFTER,
) -> int:
    """Compensate stale, un-logged staged notebooks under ``data_root``.
    ``shared_decks_path`` is the copy-log catalog (``KGSettings.shared_decks_path``).
    Returns the number of notebooks FULLY reaped; one whose cleanup failed stays
    staged for the next sweep and is not counted. Per-user failures are logged and
    skipped so one bad user dir cannot block startup."""
    users_dir = data_root / "users"
    if not users_dir.is_dir():
        return 0
    cutoff = datetime.now(UTC) - older_than
    shared = SharedDeckStore(shared_decks_path)
    reaped = 0
    try:
        for user_dir in sorted(p for p in users_dir.iterdir() if (p / "notebooks.db").is_file()):
            notebooks = None
            cards = None
            try:
                notebooks = NotebookStore(user_dir / "notebooks.db")
                for notebook_id in notebooks.staged_older_than(cutoff):
                    if shared.has_copy_log_for_notebook(notebook_id):
                        continue
                    if cards is None:
                        cards = CardStore(user_dir / "cards.db")
                    if compensate_staged_copy(cards, notebooks, user_dir, notebook_id):
                        reaped += 1
            except Exception:  # noqa: BLE001 — never block startup on one user
                _LOGGER.warning("staged copy reaper failed for %s", user_dir.name, exc_info=True)
            finally:
                if notebooks is not None:
                    notebooks.close()
                if cards is not None:
                    cards.close()
    finally:
        shared.close()
    return reaped
