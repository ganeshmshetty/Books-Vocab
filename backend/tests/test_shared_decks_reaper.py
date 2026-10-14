"""Issue #2269: startup reaper compensates stale staged copy notebooks."""

from __future__ import annotations

import logging
import sqlite3
from datetime import UTC, datetime, timedelta

from kg.cards import CardStore
from kg.notebook import NotebookStore
from kg.shared_decks.copy import compensate_staged_copy
from kg.shared_decks.reaper import reap_stale_staged_copies
from kg.shared_decks.store import SharedDeckStore
from test_vocab_staged_filter import _add, _list


def _age(nbs: NotebookStore, notebook_id: str, minutes: int) -> None:
    stamp = (datetime.now(UTC) - timedelta(minutes=minutes)).strftime("%Y-%m-%d %H:%M:%S.%f")
    with sqlite3.connect(nbs.path) as conn:
        conn.execute("UPDATE notebook SET created_at = ? WHERE id = ?", (stamp, notebook_id))


def _reap(tmp_path, **kwargs) -> int:
    kwargs.setdefault("shared_decks_path", tmp_path / "shared_decks.db")
    return reap_stale_staged_copies(tmp_path, older_than=timedelta(minutes=10), **kwargs)


def _orphan(tmp_path):
    """One user with an old un-logged staged notebook (plus a live one), each
    holding one card. Returns ``(user_dir, cards, nbs, staged, live)``."""
    user_dir = tmp_path / "users" / "u1"
    user_dir.mkdir(parents=True)
    cards = CardStore(user_dir / "cards.db")
    nbs = NotebookStore(user_dir / "notebooks.db")
    staged = nbs.create(name="orphan", is_staged=True)
    live = nbs.create(name="live")
    for nb in (staged, live):
        _add(cards, nb.id, f"c-{nb.name}", datetime.now(UTC))
    _age(nbs, staged.id, 60)
    return user_dir, cards, nbs, staged, live


def test_reaper_compensates_only_orphaned_stale_staged(tmp_path):
    user_dir = tmp_path / "users" / "u1"
    user_dir.mkdir(parents=True)
    shared = SharedDeckStore(tmp_path / "shared_decks.db")
    cards = CardStore(user_dir / "cards.db")
    nbs = NotebookStore(user_dir / "notebooks.db")

    old = nbs.create(name="old", is_staged=True)
    fresh = nbs.create(name="fresh", is_staged=True)
    logged = nbs.create(name="logged", is_staged=True)
    live = nbs.create(name="live")
    for nb in (old, fresh, logged, live):
        _add(cards, nb.id, f"c-{nb.name}", datetime.now(UTC))
    for nb in (old, logged, live):
        _age(nbs, nb.id, 60)
    assert shared.record_copy("u1", "k", "deck", 1, logged.id)
    graph = user_dir / f"graph_{old.id}.json"
    graph.write_text("[]")

    assert _reap(tmp_path) == 1

    remaining = {n.id for n in nbs.all(include_deleted=True, include_staged=True)}
    assert remaining == {fresh.id, logged.id, live.id}
    assert not graph.exists()
    tomb = {c.content: c.is_deleted for c in cards.all(include_deleted=True)}
    assert tomb["c-old"] is True
    assert tomb["c-fresh"] is False and tomb["c-logged"] is False and tomb["c-live"] is False


def test_reaper_noop_without_users_dir(tmp_path):
    assert _reap(tmp_path) == 0


def test_reaper_survives_corrupt_user_db_and_still_reaps_other_users(tmp_path, caplog):
    """A corrupt per-user notebooks.db must be logged and skipped like any other
    per-user failure; it must not escape and abort lifespan startup (#3820)."""
    user_a = tmp_path / "users" / "a"
    user_a.mkdir(parents=True)
    (user_a / "notebooks.db").write_bytes(b"this is not a sqlite database" * 100)
    user_b = tmp_path / "users" / "b"
    user_b.mkdir()
    cards = CardStore(user_b / "cards.db")
    nbs = NotebookStore(user_b / "notebooks.db")
    staged = nbs.create(name="orphan", is_staged=True)
    _add(cards, staged.id, "c-orphan", datetime.now(UTC))
    _age(nbs, staged.id, 60)

    with caplog.at_level(logging.WARNING, logger="kg.shared_decks.reaper"):
        assert _reap(tmp_path) == 1

    assert nbs.staged_ids() == []
    assert any(r.levelno == logging.WARNING and r.getMessage().endswith("for a") for r in caplog.records)


def test_reaper_reads_copy_log_from_the_configured_path(tmp_path):
    """The copy log lives wherever settings say; the reaper must not assume
    ``<data_root>/shared_decks.db`` or it would reap a committed copy."""
    user_dir, cards, nbs, staged, _live = _orphan(tmp_path)
    custom = tmp_path / "elsewhere" / "catalog.db"
    custom.parent.mkdir()
    shared = SharedDeckStore(custom)
    assert shared.record_copy("u1", "k", "deck", 1, staged.id)

    assert _reap(tmp_path, shared_decks_path=custom) == 0

    assert nbs.staged_ids() == [staged.id]
    assert {c.content: c.is_deleted for c in cards.all(include_deleted=True)}["c-orphan"] is False


# ── a failed cleanup must keep the staged marker and not be counted ──


def test_reaper_keeps_notebook_staged_and_uncounted_when_tombstoning_fails(tmp_path, monkeypatch):
    """If cards.db cannot be tombstoned (e.g. locked) the notebook must stay
    staged: dropping it would strip the only marker hiding the live cards from
    global pulls and leave later sweeps nothing to retry."""
    user_dir, cards, nbs, staged, _live = _orphan(tmp_path)

    def locked(self, notebook_id):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(CardStore, "soft_delete_by_notebook", locked)

    assert _reap(tmp_path) == 0

    assert nbs.staged_ids() == [staged.id]
    rows = {c.content: c.is_deleted for c in cards.all(include_deleted=True)}
    assert rows == {"c-orphan": False, "c-live": False}
    pulled, _ = _list(user_dir, cards, nbs, since=None)
    assert pulled == ["c-live"]  # the orphan's live card is still hidden from the global pull

    monkeypatch.undo()  # the lock clears: the next sweep finishes the job
    assert _reap(tmp_path) == 1
    assert nbs.staged_ids() == []
    assert {c.content: c.is_deleted for c in cards.all(include_deleted=True)}["c-orphan"] is True


# ── compensate_staged_copy reports success; notebook is removed LAST ──


def test_compensate_reports_success_and_removes_everything(tmp_path):
    user_dir, cards, nbs, staged, _live = _orphan(tmp_path)
    graph = user_dir / f"graph_{staged.id}.json"
    graph.write_text("[]")

    assert compensate_staged_copy(cards, nbs, user_dir, staged.id) is True

    assert nbs.staged_ids() == []
    assert not graph.exists()
    assert {c.content: c.is_deleted for c in cards.all(include_deleted=True)}["c-orphan"] is True


def test_compensate_reports_failure_and_keeps_notebook_when_tombstoning_fails(tmp_path, monkeypatch):
    user_dir, cards, nbs, staged, _live = _orphan(tmp_path)

    def locked(self, notebook_id):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(CardStore, "soft_delete_by_notebook", locked)

    assert compensate_staged_copy(cards, nbs, user_dir, staged.id) is False

    assert nbs.staged_ids() == [staged.id]
    assert {c.content: c.is_deleted for c in cards.all(include_deleted=True)}["c-orphan"] is False


def test_compensate_reports_failure_and_keeps_notebook_when_graph_cleanup_fails(tmp_path):
    """The graph file is removed before the notebook, so a stuck file keeps the
    staged marker (and a retry) instead of orphaning the file forever."""
    user_dir, cards, nbs, staged, _live = _orphan(tmp_path)
    stuck = user_dir / f"graph_{staged.id}.json"
    stuck.mkdir()  # unlink() on a directory raises OSError
    (stuck / "pin").write_text("x")

    assert compensate_staged_copy(cards, nbs, user_dir, staged.id) is False
    assert nbs.staged_ids() == [staged.id]

    (stuck / "pin").unlink()
    stuck.rmdir()
    assert compensate_staged_copy(cards, nbs, user_dir, staged.id) is True  # idempotent retry
    assert nbs.staged_ids() == []


def test_compensate_reports_failure_when_notebook_delete_fails_then_retry_succeeds(tmp_path, monkeypatch):
    user_dir, cards, nbs, staged, _live = _orphan(tmp_path)

    def locked(self, notebook_id):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(NotebookStore, "hard_delete", locked)
    assert compensate_staged_copy(cards, nbs, user_dir, staged.id) is False
    assert nbs.staged_ids() == [staged.id]  # still staged → still hidden, still sweepable

    monkeypatch.undo()
    assert compensate_staged_copy(cards, nbs, user_dir, staged.id) is True
    assert nbs.staged_ids() == []
