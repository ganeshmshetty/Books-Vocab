"""Regression: add_link must dedup the same pair across store boundaries (TOCTOU).

create_manual_link does check-then-act: find_link_between (None) → judge.evaluate
(LLM, seconds, no lock held) → add_link. Two concurrent manual-link requests for
the same pair both see None, both reach add_link, and -- because add_link did not
re-check existence under _lock -- both inserted, yielding two active links for one
pair. The fix makes add_link idempotent: under _lock and the persisted link file
lock, if an active/hidden link for the pair already exists, return it instead of
inserting a duplicate.
"""

from __future__ import annotations

import json
import threading
from pathlib import Path

import pytest

from kg.graph import GraphStore, LinkKind


@pytest.fixture()
def store(tmp_path):
    return GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )


def _active_links_for_pair(store, a, b):
    return [lk for lk in store.all_links() if lk.status == "active" and {lk.from_id, lk.to_id} == {a, b}]


def test_loading_persisted_duplicate_pair_keeps_one_deterministic_link(tmp_path: Path):
    """A historical TOCTOU duplicate must be repaired before a new add."""
    links_path = tmp_path / "links.json"
    first = {
        "id": "first",
        "from_id": "card_a",
        "to_id": "card_b",
        "kind": "contrasts_with",
        "confidence": 0.9,
        "reason": "first persisted winner",
        "created_at": "2026-09-01T00:00:00Z",
        "status": "active",
    }
    duplicate = {**first, "id": "duplicate", "reason": "stale duplicate"}
    links_path.write_text(json.dumps([first, duplicate]), encoding="utf-8")

    graph = GraphStore(
        links_path=links_path,
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )

    assert [link.id for link in _active_links_for_pair(graph, "card_a", "card_b")] == ["first"]
    assert json.loads(links_path.read_text(encoding="utf-8")) == [first]


def test_graph_state_isolated_by_user_and_notebook(tmp_path: Path):
    """Identical card IDs in separate user/notebook files never cross-pollinate."""
    user_a_notebook = GraphStore(
        links_path=tmp_path / "user-a" / "graph_reading.json",
        candidates_path=tmp_path / "user-a" / "candidates_reading.json",
        blocked_path=tmp_path / "user-a" / "blocked_reading.json",
    )
    user_a_other_notebook = GraphStore(
        links_path=tmp_path / "user-a" / "graph_work.json",
        candidates_path=tmp_path / "user-a" / "candidates_work.json",
        blocked_path=tmp_path / "user-a" / "blocked_work.json",
    )
    user_b_notebook = GraphStore(
        links_path=tmp_path / "user-b" / "graph_reading.json",
        candidates_path=tmp_path / "user-b" / "candidates_reading.json",
        blocked_path=tmp_path / "user-b" / "blocked_reading.json",
    )

    user_a_notebook.add_link("same-card-a", "same-card-b", LinkKind.SHARES_USAGE, 0.8, "user a")
    user_a_other_notebook.add_link("same-card-a", "same-card-b", LinkKind.CONTRASTS_WITH, 0.7, "other notebook")
    user_b_notebook.add_link("same-card-a", "same-card-b", LinkKind.SHARES_USAGE, 0.6, "user b")

    assert len(user_a_notebook.all_links()) == 1
    assert user_a_notebook.all_links()[0].reason == "user a"
    assert user_a_other_notebook.all_links()[0].reason == "other notebook"
    assert user_b_notebook.all_links()[0].reason == "user b"


def test_add_link_same_pair_is_idempotent(store):
    """Sequential add_link for the same pair must not create a duplicate.

    This models the check-then-act gap: the first add commits, then a second
    request (which read find_link_between == None before the first committed)
    calls add_link again for the same pair.
    """
    first = store.add_link("card_a", "card_b", LinkKind.CONTRASTS_WITH, 1.0, "r1")
    second = store.add_link("card_a", "card_b", LinkKind.SHARES_USAGE, 1.0, "r2")

    actives = _active_links_for_pair(store, "card_a", "card_b")
    assert len(actives) == 1, f"expected 1 active link, got {len(actives)}"
    # Idempotent: returns the existing link, not a fresh duplicate.
    assert second.id == first.id


def test_add_link_idempotent_reversed_direction(store):
    """Dedup is bidirectional: (a,b) then (b,a) must collapse to one link."""
    first = store.add_link("card_a", "card_b", LinkKind.CONTRASTS_WITH, 1.0, "r1")
    second = store.add_link("card_b", "card_a", LinkKind.CONTRASTS_WITH, 1.0, "r2")

    actives = _active_links_for_pair(store, "card_a", "card_b")
    assert len(actives) == 1
    assert second.id == first.id


def test_concurrent_add_link_same_pair_no_duplicate(store):
    """Two concurrent add_link for the SAME pair must yield exactly one link."""
    n_threads = 16
    barrier = threading.Barrier(n_threads)
    errors: list[Exception] = []

    def worker(i: int):
        try:
            barrier.wait(timeout=5)
            store.add_link("card_a", "card_b", LinkKind.CONTRASTS_WITH, 1.0, f"r{i}")
        except Exception as exc:
            errors.append(exc)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(n_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=10)

    assert not errors, f"Worker errors: {errors}"
    actives = _active_links_for_pair(store, "card_a", "card_b")
    assert len(actives) == 1, (
        f"TOCTOU: {n_threads} concurrent add_link produced {len(actives)} active links for one pair"
    )


def test_concurrent_add_link_across_instances_is_idempotent(tmp_path: Path):
    """Separate GraphStore instances must dedup the same persisted pair."""
    first = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )
    second = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )
    barrier = threading.Barrier(2)
    result_ids: list[str] = []
    errors: list[Exception] = []
    result_lock = threading.Lock()

    def add_link(graph: GraphStore) -> None:
        try:
            barrier.wait(timeout=5)
            link = graph.add_link(
                "card_a",
                "card_b",
                LinkKind.SHARES_USAGE,
                0.9,
                "cross-instance race",
            )
            with result_lock:
                result_ids.append(link.id)
        except Exception as exc:  # pragma: no cover - failure is asserted below
            with result_lock:
                errors.append(exc)

    threads = [
        threading.Thread(target=add_link, args=(first,)),
        threading.Thread(target=add_link, args=(second,)),
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=10)

    assert all(not thread.is_alive() for thread in threads)
    assert not errors
    assert len(result_ids) == 2

    reloaded = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )
    active_links = _active_links_for_pair(reloaded, "card_a", "card_b")
    assert len(active_links) == 1
    assert set(result_ids) == {active_links[0].id}

    winner_id = active_links[0].id
    assert first.get_link(winner_id) is not None
    assert second.get_link(winner_id) is not None
    assert first.find_link_between("card_a", "card_b").id == winner_id
    assert second.find_link_between("card_a", "card_b").id == winner_id


def test_batch_add_link_does_not_report_discarded_stale_instance_link(tmp_path: Path):
    """A stale pipeline store must not report a provisional loser as created."""
    first = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )
    second = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )

    winner = first.batch_add_links([("card_a", "card_b", LinkKind.CONTRASTS_WITH, 1.0, "winner")])[0]
    stale_created = second.batch_add_links([("card_a", "card_b", LinkKind.SHARES_USAGE, 0.9, "stale loser")])

    assert stale_created == []
    assert second.find_link_between("card_a", "card_b").id == winner.id
    reloaded = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )
    assert [link.id for link in _active_links_for_pair(reloaded, "card_a", "card_b")] == [winner.id]


def test_losing_snapshot_cannot_restore_duplicate_after_reconciliation(tmp_path: Path, monkeypatch):
    """A queued unrelated flush must not resurrect a discarded provisional ID."""
    winner_store = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )
    loser_store = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )
    winner = winner_store.add_link("card_a", "card_b", LinkKind.CONTRASTS_WITH, 1.0, "winner")

    original_read = loser_store._read_json_list
    first_read_started = threading.Event()
    allow_first_read = threading.Event()

    def controlled_read(path):
        if path == loser_store.links_path and not first_read_started.is_set():
            first_read_started.set()
            if not allow_first_read.wait(timeout=5):
                raise TimeoutError("timed out waiting to release duplicate read")
        return original_read(path)

    monkeypatch.setattr(loser_store, "_read_json_list", controlled_read)

    original_snapshot = loser_store._links_to_serializable
    unrelated_snapshot_ready = threading.Event()

    def tracked_snapshot():
        snapshot = original_snapshot()
        if len(snapshot) == 2:
            unrelated_snapshot_ready.set()
        return snapshot

    monkeypatch.setattr(loser_store, "_links_to_serializable", tracked_snapshot)
    errors: list[Exception] = []

    def add_pair(from_id: str, to_id: str):
        try:
            loser_store.add_link(from_id, to_id, LinkKind.SHARES_USAGE, 0.9, "race")
        except Exception as exc:  # pragma: no cover - assertion below reports it
            errors.append(exc)

    losing_add = threading.Thread(target=add_pair, args=("card_a", "card_b"))
    unrelated_add = threading.Thread(target=add_pair, args=("card_c", "card_d"))
    losing_add.start()
    assert first_read_started.wait(timeout=5)
    unrelated_add.start()
    assert unrelated_snapshot_ready.wait(timeout=5)

    allow_first_read.set()
    losing_add.join(timeout=10)
    unrelated_add.join(timeout=10)

    assert not errors
    assert not losing_add.is_alive() and not unrelated_add.is_alive()
    reloaded = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )
    assert [link.id for link in _active_links_for_pair(reloaded, "card_a", "card_b")] == [winner.id]
    assert loser_store.find_link_between("card_a", "card_b").id == winner.id


def test_add_link_does_not_return_pending_batch_link(store, monkeypatch):
    """add_link must not return a batch link that is not yet on disk (#3617).

    batch_add_links inserts provisional links under _lock and only afterwards
    takes the pair locks. A same-pair add_link landing in that gap finds the
    uncommitted row via _find_link_between_unlocked and returns it. The probe
    runs at the batch's first pair-lock acquisition: with the defect that is
    after the provisional insert; with the pair locks taken up front it is
    before any insert, and the add simply persists its own link.
    """
    links_path = store.links_path
    batch_idents: list[int] = []
    gated = threading.Event()
    add_results: list[tuple[str, bool]] = []
    errors: list[Exception] = []

    def persisted_ids() -> set[str]:
        if not links_path.exists():
            return set()
        rows = json.loads(links_path.read_text(encoding="utf-8"))
        return {
            row["id"] for row in rows if isinstance(row, dict) and row.get("status", "active") in ("active", "hidden")
        }

    def probe_add() -> None:
        try:
            link = store.add_link("card_a", "card_b", LinkKind.SHARES_USAGE, 0.9, "single")
            add_results.append((link.id, link.id in persisted_ids()))
        except Exception as exc:  # pragma: no cover - assertion below reports it
            errors.append(exc)

    original_pair_lock = store._pair_thread_lock

    def probing_pair_lock(pair):
        if batch_idents and threading.get_ident() == batch_idents[0] and not gated.is_set():
            gated.set()
            probe = threading.Thread(target=probe_add)
            probe.start()
            probe.join(timeout=5)
        return original_pair_lock(pair)

    monkeypatch.setattr(store, "_pair_thread_lock", probing_pair_lock)

    def run_batch() -> None:
        batch_idents.append(threading.get_ident())
        try:
            store.batch_add_links([("card_a", "card_b", LinkKind.CONTRASTS_WITH, 1.0, "batch")])
        except Exception as exc:  # pragma: no cover - assertion below reports it
            errors.append(exc)

    batch_thread = threading.Thread(target=run_batch)
    batch_thread.start()
    batch_thread.join(timeout=10)

    assert not errors
    assert not batch_thread.is_alive()
    assert gated.is_set()
    assert add_results, "concurrent add_link did not complete"
    returned_id, persisted_at_return = add_results[0]
    assert persisted_at_return, "add_link returned a link that was not yet persisted"
    reloaded = GraphStore(
        links_path=links_path,
        candidates_path=store.candidates_path,
        blocked_path=store.blocked_path,
    )
    assert [link.id for link in _active_links_for_pair(reloaded, "card_a", "card_b")] == [returned_id]


class _LiveCard:
    def __init__(self, card_id: str):
        self.id = card_id
        self.content = "word"
        self.meaning = "meaning"
        self.is_deleted = False
        self.is_archived = False
        self.notebook_id = "default"


class _LiveCards:
    def __init__(self, *card_ids: str):
        self._cards = {card_id: _LiveCard(card_id) for card_id in card_ids}
        self.touched: list[str] = []

    def get(self, card_id):
        return self._cards.get(card_id)

    def touch(self, card_id):
        self.touched.append(card_id)

    def delete(self, card_id):
        self._cards[card_id].is_deleted = True


def test_endpoint_deleted_between_recheck_and_add_link_gets_no_live_edge(store):
    """The delete path marks the card deleted, then runs cleanup_for_card; a manual link
    whose add_link lands after that cleanup must be refused, not persisted as a live edge."""
    from unittest.mock import MagicMock

    from kg.exceptions import NotFoundError
    from kg.vocab_graph_ops import create_manual_link

    cards = _LiveCards("card_a", "card_b")
    judge = MagicMock()
    judge.evaluate.return_value = MagicMock(link="shares_usage", reason="r")
    original_add_link = store.add_link

    def delete_cleanup_then_add(*args, **kwargs):
        cards.delete("card_b")
        store.cleanup_for_card("card_b", source="manual")
        return original_add_link(*args, **kwargs)

    store.add_link = delete_cleanup_then_add

    with pytest.raises(NotFoundError):
        create_manual_link(
            from_id="card_a", to_id="card_b", cards_store=cards, graph=store, judge=judge, notebook_id="default"
        )
    assert store.find_link_between("card_a", "card_b") is None


def test_refused_manual_link_keeps_user_deleted_pair_blocked(store):
    """A refused manual link must not unblock a pair the user deleted earlier."""
    from unittest.mock import MagicMock

    from kg.exceptions import NotFoundError
    from kg.vocab_graph_ops import create_manual_link

    cards = _LiveCards("card_a", "card_b")
    lk = store.add_link("card_a", "card_b", LinkKind.CONTRASTS_WITH, 0.9, "r")
    store.hard_delete_link(lk.id)
    assert store.is_blocked("card_a", "card_b") is True

    judge = MagicMock()
    judge.evaluate.return_value = MagicMock(link="shares_usage", reason="r")
    original_add_link = store.add_link

    def delete_cleanup_then_add(*args, **kwargs):
        cards.delete("card_b")
        store.cleanup_for_card("card_b", remove_blocked=False, source="manual")
        return original_add_link(*args, **kwargs)

    store.add_link = delete_cleanup_then_add

    with pytest.raises(NotFoundError):
        create_manual_link(
            from_id="card_a", to_id="card_b", cards_store=cards, graph=store, judge=judge, notebook_id="default"
        )
    assert store.is_blocked("card_a", "card_b") is True
