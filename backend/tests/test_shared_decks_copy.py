"""Phase 2 — POST /api/decks/{id}/copy: server-side clone of an official deck
into the copier's private Notebook.

The load-bearing guardrails (all asserted here):

* fresh SRS + fresh id + provenance stamp, ordinary reviewable cards, zero
  dictionary sidecars and review_events.
* strictly-monotonic (distinct) updated_at — §4.4 timestamp-tie pagination skip.
* mid-copy crash leaves NO half-product (materialization barrier + compensation).
* two copies of one deck → two uniquely-named notebooks → world-export still
  succeeds (duplicate-name trap).
* same idempotency_key retry → same notebook, no duplicate, no double download.
* copied count == source snapshot (fail-loud on NOCASE/NFC collapse).
* download_count atomic increment.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime, timedelta

import pytest
from sqlmodel import Session

from kg.cards import CardStore
from kg.exceptions import ConflictError, NotFoundError
from kg.notebook import NotebookStore
from kg.shared_decks.copy import copy_shared_deck, reveal_uncounted_copies
from kg.shared_decks.store import SharedDeck, SharedDeckCopyLog, SharedDeckStore
from ops_helpers import run_ops_cli as _cli

_DECK_CARDS = [
    {
        "content": "meticulous",
        "pos": "adj.",
        "meaning": "一絲不苟的",
        "examples": ["Her **meticulous** notes."],
        "collocations": ["meticulous planning"],
        "note": "teacher note",
        "difficulty": 4.5,
        "mode": "recognition",
        "root_form": None,
        "inflections": [],
    },
    {"content": "wince", "pos": "v.", "meaning": "畏縮", "mode": "recognition"},
    {"content": "ubiquitous", "pos": "adj.", "meaning": "無所不在的", "mode": "recognition"},
]


def _publish_deck(shared_store, *, deck_id="deck_a", title="Official Starter", cards=None):
    return shared_store.publish_official(
        deck_id=deck_id,
        title=title,
        cards=cards if cards is not None else _DECK_CARDS,
        color="#112233",
        cover_pattern="waves",
        language_pair="en-zh",
        category="language",
        publisher_display_name="KG Team",
    )


def _stores(tmp_path, uid="u1"):
    user_dir = tmp_path / "users" / uid
    user_dir.mkdir(parents=True)
    shared_store = SharedDeckStore(tmp_path / "shared_decks.db")
    card_store = CardStore(user_dir / "cards.db")
    notebook_store = NotebookStore(user_dir / "notebooks.db")
    return user_dir, shared_store, card_store, notebook_store


def _dictionary_sidecar_count(cards_db) -> int:
    """Transitional assertion helper: retired schemas omit the table entirely."""
    with sqlite3.connect(cards_db) as conn:
        exists = conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='dictionary_entry'").fetchone()
        if exists is None:
            return 0
        return conn.execute("SELECT COUNT(*) FROM dictionary_entry").fetchone()[0]


def _copy(
    shared_store,
    card_store,
    notebook_store,
    user_dir,
    *,
    deck_id="deck_a",
    copier_id="u1",
    key="k1",
    notebook_name=None,
    on_card=None,
):
    return copy_shared_deck(
        shared_store=shared_store,
        card_store=card_store,
        notebook_store=notebook_store,
        user_dir=user_dir,
        deck_id=deck_id,
        copier_id=copier_id,
        idempotency_key=key,
        notebook_name=notebook_name,
        _on_card=on_card,
    )


# ── 1. fresh SRS + fresh id + provenance + zero review_events ───────


def test_copy_yields_fresh_srs_fresh_ids_and_provenance(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    src = shared.all_cards("deck_a", version=1)
    src_guids = {c.content: c.content_guid for c in src}

    outcome = _copy(shared, cards, nbs, user_dir)

    nb = nbs.get(outcome.notebook_id)
    assert nb is not None and not nb.is_deleted
    assert nb.is_default is False
    assert nb.source_shared_deck_id == "deck_a"
    assert nb.source_version == 1

    copied = list(cards.all(notebook_id=nb.id))
    assert len(copied) == len(src) == outcome.card_count
    src_ids = {c.id for c in src}
    src_by_content = {c.content: c for c in src}
    for c in copied:
        # model-default SRS (fresh schedule; author's schedule cannot leak)
        assert c.review_count == 0
        assert c.lapse_count == 0
        assert c.review_streak == 0
        assert c.next_review_at is None
        assert c.last_reviewed_at is None
        assert c.review_interval_hours == 12.0
        assert c.last_review_feedback == -1
        assert c.is_deleted is False
        assert c.id not in src_ids  # freshly minted id
        assert c.source_shared_card_guid == src_guids[c.content]
        # The official content plane is copied verbatim. Keep this exhaustive:
        # adding a published field without copying it must fail this contract.
        source = src_by_content[c.content]
        for field in (
            "content",
            "meaning",
            "pos",
            "examples",
            "collocations",
            "note",
            "difficulty",
            "mode",
            "root_form",
            "inflections",
        ):
            assert getattr(c, field) == getattr(source, field), field

    # Explicit regression anchors for fields the generic add() path cannot carry.
    meticulous = next(c for c in copied if c.content == "meticulous")
    assert meticulous.note == "teacher note"
    assert meticulous.difficulty == 4.5
    assert _dictionary_sidecar_count(user_dir / "cards.db") == 0

    # SRS isolation: the copy path never constructs a ReviewEventStore, so no
    # review-history plane exists for the copied cards.
    assert not (user_dir / "review_events.db").exists()


# ── 2. strictly-monotonic (distinct) updated_at (§4.4) ─────────────


def test_copy_stamps_distinct_monotonic_updated_at(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    outcome = _copy(shared, cards, nbs, user_dir)
    copied = list(cards.all(notebook_id=outcome.notebook_id))
    stamps = [c.updated_at for c in copied]
    # No two cards share an updated_at → a keyset page boundary can never land
    # mid-tie-group and silently drop the rest (§4.4).
    assert len(set(stamps)) == len(stamps)


# ── 3. mid-copy crash → no half-product (barrier + compensation) ───


def test_midcopy_crash_leaves_no_halfproduct(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)

    def boom(i):
        if i == 1:
            raise RuntimeError("injected mid-copy crash")

    started = datetime.now(UTC)
    with pytest.raises(RuntimeError, match="injected"):
        _copy(shared, cards, nbs, user_dir, on_card=boom)

    # compensation hard-deleted the partial notebook and TOMBSTONED its cards
    # (soft delete, bumped updated_at) so a client that already pulled them
    # gets deletions on incremental sync (#2269).
    assert list(nbs.all(include_deleted=True, include_staged=True)) == []
    assert cards.count() == 0
    rows = list(cards.all(include_deleted=True))
    assert len(rows) == 2 and all(c.is_deleted for c in rows)
    assert {c.id for c in cards.get_modified_since(started - timedelta(seconds=1))} == {c.id for c in rows}
    assert _dictionary_sidecar_count(user_dir / "cards.db") == 0


def test_midcopy_crash_with_failed_cleanup_keeps_notebook_staged_and_cards_hidden(tmp_path, monkeypatch):
    """The original fault still propagates, but if the cards cannot be tombstoned
    the notebook must stay staged: deleting it would strip the only marker hiding
    the partial cards from global pulls, and nothing would ever retry the cleanup."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)

    def boom(i):
        if i == 1:
            raise RuntimeError("injected mid-copy crash")

    def locked(self, notebook_id):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(CardStore, "soft_delete_by_notebook", locked)
    with pytest.raises(RuntimeError, match="injected mid-copy crash"):
        _copy(shared, cards, nbs, user_dir, on_card=boom)

    staged = nbs.staged_ids()
    assert len(staged) == 1
    rows = list(cards.all(include_deleted=True))
    assert len(rows) == 2 and not any(c.is_deleted for c in rows)
    assert cards.get_modified_since(datetime(2000, 1, 1), exclude_notebook_ids=staged) == []


# ── 4. two copies → unique names → world-export succeeds ───────────


def test_copy_twice_unique_names_and_world_export_ok(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)

    o1 = _copy(shared, cards, nbs, user_dir, key="k1")
    o2 = _copy(shared, cards, nbs, user_dir, key="k2")
    assert o1.notebook_id != o2.notebook_id
    names = {o1.notebook_name, o2.notebook_name}
    assert len(names) == 2
    assert "Official Starter" in names  # first keeps the base title

    # The duplicate-name trap: two same-titled active notebooks would make
    # world-export fail-loud. Unique naming keeps it replayable.
    r = _cli(str(tmp_path), "world-export", "u1")
    assert r.returncode == 0, r.stderr
    exported = json.loads(r.stdout)
    nb_names = [n["name"] for n in exported["notebooks"]]
    assert len(nb_names) == len(set(nb_names)), nb_names


# ── 5. idempotent retry → same notebook, no dup, no double download ─


def test_copy_idempotent_retry(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)

    o1 = _copy(shared, cards, nbs, user_dir, key="same-key")
    assert o1.already_copied is False
    o2 = _copy(shared, cards, nbs, user_dir, key="same-key")
    assert o2.already_copied is True
    assert o2.notebook_id == o1.notebook_id

    # exactly one copy notebook, and the download counted once
    assert len([n for n in nbs.all() if not n.is_default]) == 1
    assert shared.get("deck_a").download_count == 1


def test_replay_repairs_download_count_after_counter_finalizer_crash(tmp_path, monkeypatch):
    """A retry must finish the counter after materialize already succeeded."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)

    real_finalize = shared.finalize_copy_download
    calls = {"count": 0}

    def fail_once(copier_id, idempotency_key, deck_id):
        calls["count"] += 1
        if calls["count"] == 1:
            raise RuntimeError("injected counter finalizer crash")
        return real_finalize(copier_id, idempotency_key, deck_id)

    monkeypatch.setattr(shared, "finalize_copy_download", fail_once)
    with pytest.raises(RuntimeError, match="counter finalizer"):
        _copy(shared, cards, nbs, user_dir, key="counter-retry")

    log = shared.get_copy_log("u1", "counter-retry")
    assert log is not None
    assert nbs.get(log.result_notebook_id).is_staged is False
    assert shared.get("deck_a").download_count == 0

    replay = _copy(shared, cards, nbs, user_dir, key="counter-retry")

    assert replay.already_copied is True
    assert replay.notebook_id == log.result_notebook_id
    assert shared.get("deck_a").download_count == 1


def test_existing_copy_log_is_marked_counted_during_migration(tmp_path):
    """Legacy rows must not be counted again when replay support is deployed."""
    db_path = tmp_path / "shared_decks.db"
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            """
            CREATE TABLE shared_deck_copy_log (
                copier_id TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                source_shared_deck_id TEXT NOT NULL,
                source_version INTEGER NOT NULL DEFAULT 0,
                result_notebook_id TEXT NOT NULL DEFAULT '',
                created_at DATETIME,
                PRIMARY KEY (copier_id, idempotency_key)
            )
            """
        )
        conn.execute(
            """
            INSERT INTO shared_deck_copy_log
                (copier_id, idempotency_key, source_shared_deck_id, result_notebook_id)
            VALUES (?, ?, ?, ?)
            """,
            ("u1", "legacy-key", "deck_a", "notebook-a"),
        )
        conn.commit()

    shared = SharedDeckStore(db_path)
    try:
        log = shared.get_copy_log("u1", "legacy-key")
        assert isinstance(log, SharedDeckCopyLog)
        assert log.download_counted is True
    finally:
        shared.close()


def test_copy_rejects_cross_deck_idempotency_reuse(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared, deck_id="deck_a")
    _publish_deck(shared, deck_id="deck_b", title="Official Follow-up")

    first = _copy(shared, cards, nbs, user_dir, deck_id="deck_a", key="same-key")

    with pytest.raises(ConflictError, match="idempotency key"):
        _copy(shared, cards, nbs, user_dir, deck_id="deck_b", key="same-key")

    log = shared.get_copy_log("u1", "same-key")
    assert log is not None
    assert log.source_shared_deck_id == "deck_a"
    assert log.result_notebook_id == first.notebook_id
    assert [n.id for n in nbs.all() if not n.is_default] == [first.notebook_id]
    assert cards.count() == first.card_count
    assert shared.get("deck_a").download_count == 1
    assert shared.get("deck_b").download_count == 0


def test_race_winner_replay_rejects_cross_deck_idempotency_reuse(tmp_path, monkeypatch):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared, deck_id="deck_a")
    _publish_deck(shared, deck_id="deck_b", title="Official Follow-up")
    first = _copy(shared, cards, nbs, user_dir, deck_id="deck_a", key="same-key")

    real_get_copy_log = shared.get_copy_log
    calls = {"count": 0}

    def hide_existing_log(copier_id, idempotency_key):
        calls["count"] += 1
        if calls["count"] == 1:
            return None
        return real_get_copy_log(copier_id, idempotency_key)

    monkeypatch.setattr(shared, "get_copy_log", hide_existing_log)
    with pytest.raises(ConflictError, match="idempotency key"):
        _copy(shared, cards, nbs, user_dir, deck_id="deck_b", key="same-key")

    assert calls["count"] == 2
    assert [n.id for n in nbs.all() if not n.is_default] == [first.notebook_id]
    assert cards.count() == first.card_count
    assert shared.get("deck_a").download_count == 1
    assert shared.get("deck_b").download_count == 0


def test_replay_self_heals_staged_notebook(tmp_path, monkeypatch):
    """Crash-window recovery: a prior copy committed its idempotency log but
    crashed BEFORE revealing the notebook, leaving it staged (is_staged=True,
    NOT user-deleted). A same-key retry reveals it via _replay — never a dup.

    Staging uses a dedicated is_staged flag, never is_deleted, so materialize's
    reveal can never be confused with (or resurrect) a real user soft-delete."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)

    # Inject a crash in the reveal window: materialize raises on the first copy,
    # AFTER record_copy has committed the idempotency log (point of no return).
    calls = {"n": 0}
    real_materialize = nbs.materialize

    def flaky(nid):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("injected crash before reveal")
        return real_materialize(nid)

    monkeypatch.setattr(nbs, "materialize", flaky)
    with pytest.raises(RuntimeError, match="injected"):
        _copy(shared, cards, nbs, user_dir, key="k1")

    log = shared.get_copy_log("u1", "k1")
    assert log is not None  # the crash was AFTER the point of no return
    staged = nbs.get(log.result_notebook_id)
    assert staged.is_staged is True
    assert staged.is_deleted is False
    assert log.result_notebook_id not in {n.id for n in nbs.all()}  # hidden

    # same-key retry → _replay reveals via the real materialize, no second dup
    o2 = _copy(shared, cards, nbs, user_dir, key="k1")
    assert o2.already_copied is True
    assert o2.notebook_id == log.result_notebook_id
    nb = nbs.get(log.result_notebook_id)
    assert nb.is_staged is False
    assert nb.is_deleted is False
    assert len([n for n in nbs.all() if not n.is_default]) == 1
    assert shared.get("deck_a").download_count == 1


def test_replay_does_not_resurrect_user_deleted_notebook(tmp_path):
    """is_deleted is NOT overloaded as the staging barrier: once a copy is
    materialized and the user soft-deletes it, a same-key retry (cross-device
    outbox replay against the permanent copy_log) must NOT revive it. materialize
    only flips is_staged→False and never touches is_deleted, so a user-deleted
    (is_staged=False, is_deleted=True) copy stays deleted."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    o1 = _copy(shared, cards, nbs, user_dir, key="k1")

    assert nbs.delete(o1.notebook_id) is True  # user soft-deletes the copy
    assert nbs.get(o1.notebook_id).is_deleted is True

    o2 = _copy(shared, cards, nbs, user_dir, key="k1")  # same-key retry
    assert o2.already_copied is True
    assert o2.notebook_id == o1.notebook_id
    nb = nbs.get(o1.notebook_id)
    assert nb.is_deleted is True  # stays deleted — NO resurrection
    assert nb.is_staged is False
    assert o1.notebook_id not in {n.id for n in nbs.all()}


# ── 5b. concurrent same-user copies → serialized, no duplicate name ─


def test_concurrent_same_user_copies_no_duplicate_active_name(tmp_path):
    """Two concurrent same-user copies with DISTINCT idempotency keys (an iOS
    double-tap mints two keys) must not each read the pre-create notebook
    snapshot, pick the SAME unique name, and both INSERT → two same-named
    active notebooks. That breaks world-export's name→id map (§2 name
    uniqueness is mandatory). The per-user copy lock serializes them so the
    second copy sees the first's materialized notebook and disambiguates."""
    import threading

    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)

    a_mid = threading.Event()  # A: inside its critical section (holds the lock)
    a_go = threading.Event()  # main → A: you may finish
    results: dict[str, object] = {}
    errors: dict[str, BaseException] = {}

    def a_on_card(i):
        if i == 0:
            a_mid.set()
            # Hold INSIDE the copy critical section until released, so a
            # concurrent same-user copy must queue behind us if the lock works.
            assert a_go.wait(timeout=10)

    def run_a():
        try:
            results["a"] = _copy(shared, cards, nbs, user_dir, key="ka", on_card=a_on_card)
        except BaseException as exc:  # noqa: BLE001
            errors["a"] = exc

    def run_b():
        try:
            results["b"] = _copy(shared, cards, nbs, user_dir, key="kb")
        except BaseException as exc:  # noqa: BLE001
            errors["b"] = exc

    ta = threading.Thread(target=run_a)
    ta.start()
    assert a_mid.wait(timeout=10), "copy A never entered its critical section"

    tb = threading.Thread(target=run_b)
    tb.start()
    # B must block on the per-user lock while A holds it. Without the lock B
    # would race to completion here (and pick the same name).
    tb.join(timeout=0.5)
    assert tb.is_alive(), "copy B was NOT serialized behind A (no per-user lock)"

    a_go.set()
    ta.join(timeout=10)
    tb.join(timeout=10)
    assert not errors, errors

    names = {results["a"].notebook_name, results["b"].notebook_name}
    assert len(names) == 2, f"duplicate active notebook name: {names}"
    assert "Official Starter" in names  # first copy keeps the base title

    # The real consequence: world-export must still produce a replayable spec.
    r = _cli(str(tmp_path), "world-export", "u1")
    assert r.returncode == 0, r.stderr
    exported = json.loads(r.stdout)
    nb_names = [n["name"] for n in exported["notebooks"]]
    assert len(nb_names) == len(set(nb_names)), nb_names


def test_full_sync_list_excludes_staged_notebook(tmp_path):
    """The full-sync notebook list — all(include_deleted=True), what
    GET /api/notebooks (no cursor) sends to the client — must EXCLUDE staged
    copy-in-progress notebooks. include_deleted carries soft-delete tombstones
    for delete-propagation; staged is an orthogonal axis that only teardown /
    leak-detection callers (include_staged=True) may see. Otherwise a half-copied
    notebook surfaces on the client as a live notebook."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    nbs.create(name="Live Book")
    nbs.create(name="Staged Copy", is_staged=True)
    deleted = nbs.create(name="Deleted Book")
    nbs.delete(deleted.id)

    full = nbs.all(include_deleted=True)  # exactly what the full-sync router sends
    names = {n.name for n in full}
    assert "Staged Copy" not in names, "staged notebook leaked to full-sync client"
    assert "Live Book" in names
    assert "Deleted Book" in names  # tombstone still propagates

    # leak-detection callers can still surface staged rows explicitly
    everything = {n.name for n in nbs.all(include_deleted=True, include_staged=True)}
    assert "Staged Copy" in everything


def test_staged_notebook_excluded_from_world_export(tmp_path):
    """A copy-in-progress (staged) notebook must never leak into world-export.
    The raw-SQL readers filter is_deleted only, so moving the barrier to
    is_staged forces them to exclude is_staged too — else a half-copied notebook
    pollutes a replayable world spec (and could inject a duplicate name)."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    o1 = _copy(shared, cards, nbs, user_dir, key="k1")  # a real, visible copy

    # a staged (copy-in-progress) notebook sitting in the DB, not yet revealed
    nbs.create(name="Ghost Deck", is_staged=True)

    r = _cli(str(tmp_path), "world-export", "u1")
    assert r.returncode == 0, r.stderr
    exported = json.loads(r.stdout)
    names = [n["name"] for n in exported["notebooks"]]
    assert "Ghost Deck" not in names, f"staged notebook leaked into export: {names}"
    assert o1.notebook_name in names  # the materialized copy is present


def test_world_export_tolerates_db_without_is_staged_column(tmp_path):
    """A legacy notebooks.db predating the is_staged migration must still export
    — the raw readers probe for the column and skip the filter when it is
    absent (a WHERE on a missing column would be a hard parse error)."""
    import sqlite3

    user_dir = tmp_path / "users" / "u1"
    user_dir.mkdir(parents=True)
    conn = sqlite3.connect(str(user_dir / "notebooks.db"))
    conn.execute(
        "CREATE TABLE notebook (id TEXT PRIMARY KEY, name TEXT, color TEXT, "
        "cover_pattern TEXT, sort_order INTEGER DEFAULT 0, "
        "is_default INTEGER DEFAULT 0, created_at TEXT, updated_at TEXT, "
        "is_deleted INTEGER DEFAULT 0)"  # NOTE: no is_staged column
    )
    conn.execute(
        "INSERT INTO notebook (id, name, sort_order, is_default, is_deleted) VALUES ('n1', 'Legacy Book', 0, 0, 0)"
    )
    conn.commit()
    conn.close()

    r = _cli(str(tmp_path), "world-export", "u1")
    assert r.returncode == 0, r.stderr
    names = [n["name"] for n in json.loads(r.stdout)["notebooks"]]
    assert names == ["Legacy Book"]


# ── 6. count-equality: NOCASE/NFC collapse fails loud ──────────────


def test_homograph_collapse_fails_loud(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    # Two homographs distinct by (pos, meaning) → two distinct shared cards, but
    # they collapse under the card table's (content COLLATE NOCASE, notebook_id)
    # uniqueness. Count-equality must catch that, not silently drop a card.
    _publish_deck(
        shared,
        cards=[
            {"content": "Lead", "pos": "n.", "meaning": "鉛", "mode": "recognition"},
            {"content": "lead", "pos": "v.", "meaning": "帶領", "mode": "recognition"},
        ],
    )
    assert len(shared.all_cards("deck_a", version=1)) == 2

    with pytest.raises(ConflictError):
        _copy(shared, cards, nbs, user_dir)
    # fail-loud rolls back — no partial notebook, no partial cards
    assert list(nbs.all(include_deleted=True, include_staged=True)) == []
    assert cards.count() == 0


# ── 6b. record_copy failure compensates the staged copy ────────────


def test_record_copy_failure_compensates_staged_rows(tmp_path, monkeypatch):
    """record_copy only converts an idempotency collision to False; any OTHER
    fault (e.g. OperationalError: database is locked) escapes. The staged
    notebook + cards are written BEFORE the copy_log, so an escaping record_copy
    must still compensate — else they leak as invisible orphan rows forever."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)

    def boom(*a, **k):
        raise RuntimeError("database is locked")  # a non-IntegrityError fault

    monkeypatch.setattr(shared, "record_copy", boom)
    with pytest.raises(RuntimeError, match="locked"):
        _copy(shared, cards, nbs, user_dir)

    # compensation erased the whole partial copy — no staged notebook, no cards,
    # and no copy_log pointing at a phantom notebook.
    assert list(nbs.all(include_deleted=True, include_staged=True)) == []
    assert cards.count() == 0
    assert shared.get_copy_log("u1", "k1") is None


# ── 7. download_count atomic increment (sequential) ────────────────


def test_download_count_increments_per_distinct_copy(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    for i in range(3):
        _copy(shared, cards, nbs, user_dir, key=f"k{i}")
    assert shared.get("deck_a").download_count == 3
    # a retry (existing key) does not re-increment
    _copy(shared, cards, nbs, user_dir, key="k0")
    assert shared.get("deck_a").download_count == 3


# ── 8. unknown deck → NotFound ─────────────────────────────────────


def test_copy_unknown_deck_raises_notfound(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    with pytest.raises(NotFoundError):
        _copy(shared, cards, nbs, user_dir, deck_id="ghost")


def test_public_community_deck_copy_remains_outside_official_copy_scope(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    with Session(shared.engine) as session:
        deck = session.get(SharedDeck, "deck_a")
        deck.source = "community"
        deck.owner_id = "owner-1"
        deck.visibility = "public"
        session.add(deck)
        session.commit()

    with pytest.raises(ConflictError, match="Only official decks"):
        _copy(shared, cards, nbs, user_dir)

    assert list(nbs.all(include_deleted=True, include_staged=True)) == []
    assert cards.count() == 0
    assert shared.get_copy_log("u1", "k1") is None
    assert shared.get("deck_a").download_count == 0


# ── 9. router wiring: authed POST end-to-end ───────────────────────


def test_copy_endpoint_end_to_end(isolated_api):
    env = isolated_api
    shared = SharedDeckStore(env.data_dir / "shared_decks.db")
    _publish_deck(shared)

    # unauthenticated → rejected (no silent guest write)
    anon = env.client.post("/api/decks/deck_a/copy", json={"idempotencyKey": "x"})
    assert anon.status_code in (401, 403)

    r = env.client.post(
        "/api/decks/deck_a/copy",
        headers=env.headers,
        json={"idempotencyKey": "req-1"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["alreadyCopied"] is False
    assert body["cardCount"] == len(_DECK_CARDS)
    nb_id = body["notebookId"]

    # The regular vocab projection is the copied deck's only card surface.
    # iOS targeted pull must see every copied card immediately, with no
    # dictionary projection or review opt-in required.
    vocab = env.client.get("/api/vocab", params={"notebook_id": nb_id}, headers=env.headers)
    assert vocab.status_code == 200, vocab.text
    copied_cards = vocab.json()
    assert {card["content"] for card in copied_cards} == {card["content"] for card in _DECK_CARDS}
    assert all("cardRole" not in card for card in copied_cards)
    assert all("reviewEligible" not in card for card in copied_cards)

    # the notebook shows up in the copier's list
    nbs = env.client.get("/api/notebooks", headers=env.headers)
    assert nbs.status_code == 200
    assert any(n["id"] == nb_id for n in nbs.json())

    # idempotent retry → same notebook
    r2 = env.client.post(
        "/api/decks/deck_a/copy",
        headers=env.headers,
        json={"idempotencyKey": "req-1"},
    )
    assert r2.status_code == 200, r2.text
    assert r2.json()["alreadyCopied"] is True
    assert r2.json()["notebookId"] == nb_id


def test_copy_endpoint_rejects_overlong_notebook_name(isolated_api):
    env = isolated_api
    shared = SharedDeckStore(env.data_dir / "shared_decks.db")
    _publish_deck(shared)
    r = env.client.post(
        "/api/decks/deck_a/copy",
        headers=env.headers,
        json={"idempotencyKey": "req-long", "notebookName": "x" * 101},
    )
    assert r.status_code == 422, r.text


def test_user_copy_lock_not_evicted_while_held(tmp_path, monkeypatch):
    """LRU eviction must never drop a held lock (#2697): a second copy for the
    same user would otherwise mint a fresh lock and run concurrently."""
    from kg.shared_decks import copy as copy_mod

    monkeypatch.setattr(copy_mod, "_MAX_USER_COPY_LOCKS", 2)
    monkeypatch.setattr(copy_mod, "_USER_COPY_LOCKS", copy_mod.OrderedDict())
    held = copy_mod._user_copy_lock(tmp_path / "u0")
    with held:
        for i in range(1, 5):
            copy_mod._user_copy_lock(tmp_path / f"u{i}")
        assert copy_mod._user_copy_lock(tmp_path / "u0") is held
    # Released locks are evictable again, so the cache returns to its cap.
    copy_mod._user_copy_lock(tmp_path / "u9")
    assert len(copy_mod._USER_COPY_LOCKS) <= 2


# ── 10. reveal sweep (#3897): a committed copy whose reveal raised ──


def _sweep(tmp_path) -> int:
    return reveal_uncounted_copies(tmp_path, shared_decks_path=tmp_path / "shared_decks.db")


def test_reveal_sweep_completes_copy_whose_materialize_raised(tmp_path, monkeypatch):
    """The copy is durable (copy_log committed) when materialize raises. No
    client retry happens, so only the sweep can finish the reveal."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)

    real_materialize = nbs.materialize
    calls = {"n": 0}

    def fail_once(nid):
        calls["n"] += 1
        if calls["n"] == 1:
            raise sqlite3.OperationalError("database is locked")
        return real_materialize(nid)

    monkeypatch.setattr(nbs, "materialize", fail_once)
    with pytest.raises(sqlite3.OperationalError):
        _copy(shared, cards, nbs, user_dir, key="k1")

    log = shared.get_copy_log("u1", "k1")
    assert log is not None and log.download_counted is False
    nb_id = log.result_notebook_id
    assert nbs.get(nb_id).is_staged is True
    before = {c.id: c.updated_at for c in cards.all(notebook_id=nb_id)}

    assert _sweep(tmp_path) == 1

    assert nbs.get(nb_id).is_staged is False
    after = {c.id: c.updated_at for c in cards.all(notebook_id=nb_id)}
    assert after.keys() == before.keys()
    assert all(after[cid] > before[cid] for cid in before)  # restamped after the flip
    assert shared.get_copy_log("u1", "k1").download_counted is True
    assert shared.get("deck_a").download_count == 1
    assert _sweep(tmp_path) == 0  # a settled copy is never touched again
    assert shared.get("deck_a").download_count == 1


def test_reveal_sweep_completes_copy_whose_restamp_raised(tmp_path, monkeypatch):
    """Flip committed, restamp raised: the sweep redoes the whole reveal (the
    marker is still unset), so the restamp and the counter both land once."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)

    real_restamp = CardStore.restamp_by_notebook
    calls = {"n": 0}

    def fail_once(self, notebook_id, start):
        calls["n"] += 1
        if calls["n"] == 1:
            raise sqlite3.OperationalError("database is locked")
        return real_restamp(self, notebook_id, start)

    monkeypatch.setattr(CardStore, "restamp_by_notebook", fail_once)
    with pytest.raises(sqlite3.OperationalError):
        _copy(shared, cards, nbs, user_dir, key="k1")

    log = shared.get_copy_log("u1", "k1")
    assert nbs.get(log.result_notebook_id).is_staged is False  # flip already landed
    assert log.download_counted is False

    assert _sweep(tmp_path) == 1

    assert shared.get_copy_log("u1", "k1").download_counted is True
    assert shared.get("deck_a").download_count == 1


def test_reveal_sweep_waits_for_inflight_copy_under_user_lock(tmp_path):
    """Sync semantics: a sweep must not reveal while a request still holds the
    per-user copy lock (the request's own _reveal is inside that critical
    section). Held lock → the sweep thread cannot finish."""
    import threading

    from kg.shared_decks import copy as copy_mod

    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    _copy(shared, cards, nbs, user_dir, key="k1")
    nb_id = shared.get_copy_log("u1", "k1").result_notebook_id
    # Simulate a committed-but-unrevealed copy.
    with sqlite3.connect(user_dir / "notebooks.db") as conn:
        conn.execute("UPDATE notebook SET is_staged = 1 WHERE id = ?", (nb_id,))
    with sqlite3.connect(shared.path) as conn:
        conn.execute("UPDATE shared_deck_copy_log SET download_counted = 0 WHERE idempotency_key = 'k1'")
        conn.execute("UPDATE shared_deck SET download_count = 0 WHERE id = 'deck_a'")

    result: dict[str, int] = {}
    with copy_mod._user_copy_lock(user_dir):
        worker = threading.Thread(target=lambda: result.setdefault("n", _sweep(tmp_path)))
        worker.start()
        worker.join(timeout=0.5)
        assert worker.is_alive()  # blocked behind the in-flight copy
        assert nbs.get(nb_id).is_staged is True
    worker.join(timeout=10)
    assert not worker.is_alive()
    assert result["n"] == 1
    assert nbs.get(nb_id).is_staged is False


def test_reveal_sweep_timer_settles_copy_without_restart(tmp_path, monkeypatch):
    """The periodic loop (not only the startup pass) settles a stranded copy."""
    import asyncio

    from kg.shared_decks.copy import run_reveal_sweep_forever

    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    real_materialize = nbs.materialize
    calls = {"n": 0}

    def fail_once(nid):
        calls["n"] += 1
        if calls["n"] == 1:
            raise sqlite3.OperationalError("database is locked")
        return real_materialize(nid)

    monkeypatch.setattr(nbs, "materialize", fail_once)
    with pytest.raises(sqlite3.OperationalError):
        _copy(shared, cards, nbs, user_dir, key="k1")
    nb_id = shared.get_copy_log("u1", "k1").result_notebook_id

    async def run_loop():
        task = asyncio.create_task(
            run_reveal_sweep_forever(
                tmp_path,
                shared_decks_path=tmp_path / "shared_decks.db",
                interval=timedelta(milliseconds=10),
            )
        )
        for _ in range(500):
            if shared.get_copy_log("u1", "k1").download_counted:
                break
            await asyncio.sleep(0.01)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(run_loop())

    assert nbs.get(nb_id).is_staged is False
    assert shared.get("deck_a").download_count == 1


def test_reveal_sweep_keeps_copy_staged_when_source_deck_row_is_gone(tmp_path):
    """Never flip a notebook visible when its counter cannot commit: a missing
    source deck leaves the copy staged (hidden) instead of half-revealing it."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    shared.record_copy("u1", "orphan-log", "deck_gone", 1, nbs.create(name="x", is_staged=True).id)
    nb_id = shared.get_copy_log("u1", "orphan-log").result_notebook_id

    assert _sweep(tmp_path) == 0

    assert nbs.get(nb_id).is_staged is True
    assert shared.get_copy_log("u1", "orphan-log").download_counted is False


# ── 11. same-key replay is keyed by the copy log, not discoverability (#3898) ──


def _hide_deck(shared, deck_id="deck_a"):
    """Unpublish/hide: the source row stays, the discoverability gate closes."""
    with Session(shared.engine) as session:
        deck = session.get(SharedDeck, deck_id)
        deck.is_deleted = True
        session.commit()


def _download_count(shared, deck_id="deck_a") -> int:
    with sqlite3.connect(shared.path) as conn:
        return conn.execute("SELECT download_count FROM shared_deck WHERE id = ?", (deck_id,)).fetchone()[0]


def test_same_key_replay_survives_source_hidden_after_copy(tmp_path):
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    o1 = _copy(shared, cards, nbs, user_dir, key="k1")

    _hide_deck(shared)
    o2 = _copy(shared, cards, nbs, user_dir, key="k1")  # transport retry after unpublish

    assert o2.already_copied is True
    assert o2.notebook_id == o1.notebook_id
    assert _download_count(shared) == 1
    assert len([n for n in nbs.all() if not n.is_default]) == 1


def test_same_key_replay_completes_interrupted_reveal_of_hidden_source(tmp_path):
    """Reveal was interrupted (staged, marker unset) and the source got hidden
    before the retry: the retry must still finish the reveal and count it once."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    o1 = _copy(shared, cards, nbs, user_dir, key="k1")
    with sqlite3.connect(user_dir / "notebooks.db") as conn:
        conn.execute("UPDATE notebook SET is_staged = 1 WHERE id = ?", (o1.notebook_id,))
    with sqlite3.connect(shared.path) as conn:
        conn.execute("UPDATE shared_deck_copy_log SET download_counted = 0 WHERE idempotency_key = 'k1'")
        conn.execute("UPDATE shared_deck SET download_count = 0 WHERE id = 'deck_a'")
    _hide_deck(shared)

    o2 = _copy(shared, cards, nbs, user_dir, key="k1")

    assert o2.already_copied is True
    assert nbs.get(o1.notebook_id).is_staged is False
    assert _download_count(shared) == 1


def test_new_key_on_hidden_source_still_returns_notfound(tmp_path):
    """The discoverability gate stays for NEW copies: a hidden deck is 404 and
    nothing is staged, logged, or counted."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared)
    _hide_deck(shared)

    with pytest.raises(NotFoundError):
        _copy(shared, cards, nbs, user_dir, key="k2")

    assert shared.get_copy_log("u1", "k2") is None
    assert list(nbs.all(include_staged=True)) == []
    assert _download_count(shared) == 0


def test_cross_deck_replay_onto_hidden_deck_is_notfound_not_conflict(tmp_path):
    """A key bound to deck X, replayed against a HIDDEN deck Y, must answer 404
    exactly like a nonexistent deck. A 409 would confirm Y exists to any caller
    holding a key: an existence oracle for hidden decks (#3898 review)."""
    user_dir, shared, cards, nbs = _stores(tmp_path)
    _publish_deck(shared, deck_id="deck_a")
    _publish_deck(shared, deck_id="deck_b", title="Official Follow-up")
    _copy(shared, cards, nbs, user_dir, deck_id="deck_a", key="k1")
    _hide_deck(shared, deck_id="deck_b")

    with pytest.raises(NotFoundError):
        _copy(shared, cards, nbs, user_dir, deck_id="deck_b", key="k1")
    with pytest.raises(NotFoundError):
        _copy(shared, cards, nbs, user_dir, deck_id="deck_nonexistent", key="k1")

    assert _download_count(shared, "deck_a") == 1
    assert _download_count(shared, "deck_b") == 0
    assert len([n for n in nbs.all() if not n.is_default]) == 1
