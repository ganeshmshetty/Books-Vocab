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


def test_same_pair_creator_never_returns_provisional_link_that_is_rolled_back(store, tmp_path):
    """#3576: a same-pair add_link must not return a provisional link whose post-insert check then rolls it back.

    The first creator is parked inside its post-insert require_live (the link is
    inserted in memory but not yet persisted). A second same-pair creator runs
    in the meantime. Whatever it returns must still exist after both calls end,
    both in memory and on disk, since the first creator's post-insert check fails
    and rolls its provisional link back.
    """
    in_post_check = threading.Event()
    release_post_check = threading.Event()
    card_a_checks = 0

    def require_live(card_id):
        nonlocal card_a_checks
        if card_id == "card_a":
            card_a_checks += 1
            if card_a_checks == 2:  # 1st is the pre-check, 2nd the post-insert check
                in_post_check.set()
                assert release_post_check.wait(5)
                raise Dead(card_id)

    first_errors: list[BaseException] = []
    second_results: list = []

    def first_creator():
        try:
            store.add_link("card_a", "card_b", LinkKind.SHARES_USAGE, 0.8, "r", require_live=require_live)
        except Dead as exc:
            first_errors.append(exc)

    def second_creator():
        second_results.append(store.add_link("card_a", "card_b", LinkKind.SHARES_USAGE, 0.8, "r"))

    first = threading.Thread(target=first_creator, daemon=True)
    first.start()
    assert in_post_check.wait(5)

    second = threading.Thread(target=second_creator, daemon=True)
    second.start()
    second.join(timeout=0.5)
    release_post_check.set()

    first.join(timeout=5)
    second.join(timeout=5)
    assert not first.is_alive() and not second.is_alive()
    assert len(first_errors) == 1
    assert len(second_results) == 1

    returned = second_results[0]
    assert returned.id in {lk.id for lk in _live_links(store, "card_a", "card_b")}

    reloaded = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )
    assert returned.id in {lk.id for lk in _live_links(reloaded, "card_a", "card_b")}
