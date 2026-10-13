"""Regression #3569: add_link must not run require_live under GraphStore._lock.

require_live reads the cards DB, so calling it inside the graph critical section
serialises every graph mutation behind DB I/O. add_link checks liveness before the
lock and again after the insert; a delete that races in between deprecates the
link and add_link raises, so no live edge survives.
"""

from __future__ import annotations

import threading

import pytest

from kg.graph import GraphStore, LinkKind


class Dead(Exception):
    """Raised by the test require_live when an endpoint is no longer live."""


@pytest.fixture()
def store(tmp_path):
    return GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )


def _live_links(store, a, b):
    return [lk for lk in store.all_links() if lk.status == "active" and {lk.from_id, lk.to_id} == {a, b}]


def _run_in_thread(fn):
    worker = threading.Thread(target=fn, daemon=True)
    worker.start()
    worker.join(timeout=5)
    assert not worker.is_alive(), "graph call blocked: _lock is held while require_live runs"


def test_require_live_runs_without_graph_lock(store):
    lock_free: list[bool] = []

    def require_live(card_id):
        # _lock is a non-reentrant threading.Lock: a failed non-blocking acquire
        # from this same thread means add_link is holding it right now.
        got = store._lock.acquire(blocking=False)
        if got:
            store._lock.release()
        lock_free.append(got)

    store.add_link("card_a", "card_b", LinkKind.SHARES_USAGE, 0.8, "r", require_live=require_live)

    assert lock_free and all(lock_free)
    assert len(_live_links(store, "card_a", "card_b")) == 1


def test_dead_endpoint_refuses_and_inserts_nothing(store):
    def require_live(card_id):
        if card_id == "card_b":
            raise Dead(card_id)

    with pytest.raises(Dead):
        store.add_link("card_a", "card_b", LinkKind.SHARES_USAGE, 0.8, "r", require_live=require_live)

    assert store.all_links() == []


def test_delete_racing_past_precheck_leaves_no_live_edge(store):
    alive = {"card_a", "card_b"}
    card_a_checks = 0

    def require_live(card_id):
        nonlocal card_a_checks
        if card_id == "card_a":
            card_a_checks += 1
            if card_a_checks == 2:
                # Second check of card_a is the post-insert one. A delete
                # marks the card dead, then cleanup_for_card deprecates links.
                alive.discard(card_id)
                _run_in_thread(lambda: store.cleanup_for_card(card_id, remove_blocked=True, source="manual"))
        if card_id not in alive:
            raise Dead(card_id)

    with pytest.raises(Dead):
        store.add_link("card_a", "card_b", LinkKind.SHARES_USAGE, 0.8, "r", require_live=require_live)

    assert _live_links(store, "card_a", "card_b") == []
