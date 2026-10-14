"""Tests for the merged _step_embed_and_judge pipeline step."""

from __future__ import annotations

import asyncio
from pathlib import Path
from types import SimpleNamespace

import pytest

from kg.judge import Judgement

# ── Fakes ──────────────────────────────────────────────────────


class _FakeLogger:
    def __init__(self) -> None:
        self.info_messages: list[str] = []
        self.warning_messages: list[str] = []
        self.error_messages: list[str] = []

    def info(self, msg, *args, **kwargs):
        self.info_messages.append(msg % args if args else msg)

    def warning(self, msg, *args, **kwargs):
        self.warning_messages.append(msg % args if args else msg)

    def error(self, msg, *args, **kwargs):
        self.error_messages.append(msg % args if args else msg)


def _make_card(cid: str, content: str, meaning: str, *, is_archived: bool = False, is_deleted: bool = False):
    return SimpleNamespace(
        id=cid,
        content=content,
        meaning=meaning,
        pos="n.",
        note="note",
        difficulty=None,
        is_deleted=is_deleted,
        is_archived=is_archived,
        notebook_id="default",
        embed_text=lambda c=content: c,
    )


class _FakeCards:
    def __init__(self, cards: list):
        self._cards = {c.id: c for c in cards}
        self.touched_ids: set[str] = set()

    def all(self, include_deleted=False, notebook_id=None):
        return list(self._cards.values())

    def get_batch(self, ids):
        return {cid: self._cards[cid] for cid in ids if cid in self._cards}

    def touch(self, card_id: str):
        self.touched_ids.add(card_id)

    def batch_touch(self, card_ids, *, notebook_id=None):
        self.touched_ids.update(card_ids)


class _FakeEmbeddings:
    def __init__(
        self, *, has_ids: set[str] | None = None, similar_map: dict[str, list[tuple[str, float]]] | None = None
    ):
        self._has = has_ids or set()
        self._similar = similar_map or {}
        self.added: list[tuple[str, str]] = []

    def has(self, card_id: str) -> bool:
        return card_id in self._has

    def add_batch(self, items: list[tuple[str, str]]) -> None:
        for cid, text in items:
            self._has.add(cid)
            self.added.append((cid, text))

    def find_similar(self, card_id: str, k: int = 12) -> list[tuple[str, float]]:
        return self._similar.get(card_id, [])


class _FakeGraph:
    def __init__(self, *, links: dict[str, list] | None = None, pending: list[str] | None = None):
        self._links: dict[str, list] = links or {}
        self._pending: list[str] = list(pending) if pending else []
        self.created_links: list = []
        self._blocked: set[tuple[str, str]] = set()
        self.added_pending: list[str] = []

    def add_pending_judge(self, card_ids: list[str]) -> None:
        self._pending.extend(card_ids)
        self.added_pending.extend(card_ids)

    def pop_pending_judge(self) -> list[str]:
        result = list(self._pending)
        self._pending.clear()
        return result

    def ack_pending_judge(self, card_ids: list[str]) -> None:
        pass

    def get_links_for(self, card_id: str) -> list:
        return self._links.get(card_id, [])

    def has_link(self, a: str, b: str) -> bool:
        return False

    def batch_add_links(self, links: list) -> list:
        self.created_links.extend(links)
        return links


class _FakeJudge:
    """Records calls and returns predetermined results."""

    def __init__(self, results: dict[str, dict[str, Judgement | None]] | None = None):
        self._results = results or {}
        self.calls: list[str] = []

    def evaluate_batch(self, target_word, target_meaning, candidates, *, from_id="", similarities=None, max_links=None):
        self.calls.append(from_id)
        return self._results.get(from_id, {cid: None for cid, _, _ in candidates})


class _FailingJudge:
    """Judge that fails after N calls."""

    def __init__(self, fail_after: int):
        self._fail_after = fail_after
        self._count = 0
        self.calls: list[str] = []

    def evaluate_batch(self, target_word, target_meaning, candidates, *, from_id="", similarities=None, max_links=None):
        self._count += 1
        self.calls.append(from_id)
        if self._count > self._fail_after:
            raise RuntimeError("judge exploded")
        return {cid: None for cid, _, _ in candidates}


@pytest.fixture(autouse=True)
def _judge_log_is_closed():
    from kg import judge_log

    judge_log._reset()
    yield
    judge_log._reset()
    assert judge_log._conn is None


# ── Tests ──────────────────────────────────────────────────────


def test_embed_and_judge_creates_links():
    """New card embedded, judged, links created in one step."""
    from kg.pipeline_service import _step_embed_and_judge

    cards_list = [
        _make_card("c1", "evoke", "to bring to mind"),
        _make_card("c2", "invoke", "to call upon"),
        _make_card("c3", "revoke", "to cancel"),
    ]
    cards = _FakeCards(cards_list)

    # c1 not embedded yet; c2, c3 already embedded
    similar_map = {
        "c1": [("c2", 0.85), ("c3", 0.80)],
    }
    embeddings = _FakeEmbeddings(has_ids={"c2", "c3"}, similar_map=similar_map)

    judge_results = {
        "c1": {
            "c2": Judgement(link="shares_usage", confidence=0.9, reason="相近用法"),
            "c3": None,
        },
    }

    graph = _FakeGraph(pending=[])  # pending will be populated by embed phase
    logger = _FakeLogger()

    # Patch Judge
    import kg.judge as judge_mod

    orig_judge = judge_mod.Judge
    fake_judge = _FakeJudge(judge_results)

    class PatchedJudge:
        def __init__(self, llm, **kwargs):
            pass

        def evaluate_batch(self, *args, **kwargs):
            return fake_judge.evaluate_batch(*args, **kwargs)

    judge_mod.Judge = PatchedJudge
    try:
        asyncio.run(
            _step_embed_and_judge(
                "u1",
                {"id": "u1", "dir": Path("/tmp/u1"), "config": {}},
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda v: v,
            )
        )
    finally:
        judge_mod.Judge = orig_judge

    # c1 should have been embedded
    assert embeddings.has("c1")
    # c1 should have been added to pending_judge then judged
    assert "c1" in fake_judge.calls
    # One link should have been created (c1→c2 shares_usage)
    assert len(graph.created_links) == 1
    assert graph.created_links[0][0] == "c1"
    assert graph.created_links[0][1] == "c2"


def test_embed_and_judge_respects_max_degree():
    """Cards at MAX_DEGREE are skipped during judging."""
    from kg.pipeline_service import _step_embed_and_judge
    from kg.vocab_graph import MAX_DEGREE

    cards_list = [
        _make_card("c1", "evoke", "to bring to mind"),
        _make_card("c2", "invoke", "to call upon"),
    ]
    cards = _FakeCards(cards_list)

    similar_map = {"c1": [("c2", 0.85)]}
    embeddings = _FakeEmbeddings(has_ids={"c1", "c2"}, similar_map=similar_map)

    # c1 already at MAX_DEGREE
    fake_links = [SimpleNamespace(id=f"link{i}", status="active") for i in range(MAX_DEGREE)]
    graph = _FakeGraph(pending=["c1"], links={"c1": fake_links})
    logger = _FakeLogger()

    import kg.judge as judge_mod

    orig_judge = judge_mod.Judge
    fake_judge = _FakeJudge({})

    class PatchedJudge:
        def __init__(self, llm, **kwargs):
            pass

        def evaluate_batch(self, *args, **kwargs):
            return fake_judge.evaluate_batch(*args, **kwargs)

    judge_mod.Judge = PatchedJudge
    try:
        asyncio.run(
            _step_embed_and_judge(
                "u1",
                {"id": "u1", "dir": Path("/tmp/u1"), "config": {}},
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda v: v,
            )
        )
    finally:
        judge_mod.Judge = orig_judge

    # Judge should NOT have been called for c1 (at MAX_DEGREE)
    assert "c1" not in fake_judge.calls
    # No links created
    assert len(graph.created_links) == 0


def test_embed_and_judge_error_recovery():
    """If judge fails midway, unprocessed cards are requeued."""
    from kg.pipeline_service import _step_embed_and_judge

    cards_list = [
        _make_card("c1", "evoke", "to bring to mind"),
        _make_card("c2", "invoke", "to call upon"),
        _make_card("c3", "revoke", "to cancel"),
        _make_card("c4", "provoke", "to anger"),
    ]
    cards = _FakeCards(cards_list)

    # All embedded, all have similar pairs
    similar_map = {
        "c1": [("c2", 0.85)],
        "c2": [("c1", 0.85)],
        "c3": [("c4", 0.85)],
        "c4": [("c3", 0.85)],
    }
    embeddings = _FakeEmbeddings(has_ids={"c1", "c2", "c3", "c4"}, similar_map=similar_map)
    graph = _FakeGraph(pending=["c1", "c2", "c3", "c4"])
    logger = _FakeLogger()

    import kg.judge as judge_mod

    orig_judge = judge_mod.Judge
    # Fail after 1 successful judge call
    failing_judge = _FailingJudge(fail_after=1)

    class PatchedJudge:
        def __init__(self, llm, **kwargs):
            pass

        def evaluate_batch(self, *args, **kwargs):
            return failing_judge.evaluate_batch(*args, **kwargs)

    judge_mod.Judge = PatchedJudge
    try:
        with pytest.raises(RuntimeError, match="judge exploded"):
            asyncio.run(
                _step_embed_and_judge(
                    "u1",
                    {"id": "u1", "dir": Path("/tmp/u1"), "config": {}},
                    card_store_factory=lambda d: cards,
                    graph_store_factory=lambda d, notebook_id="default": graph,
                    embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                    client_factory=lambda provider: None,
                    logger=logger,
                    link_kind_enum=lambda v: v,
                )
            )
    finally:
        judge_mod.Judge = orig_judge

    # Some cards should have been requeued (unprocessed from await iteration perspective)
    # Note: ThreadPoolExecutor submits all tasks concurrently, so all may execute,
    # but futures not yet awaited at exception time get their card IDs requeued.
    assert len(graph.added_pending) > 0


def test_to_side_max_degree_tracked_for_inflight_links():
    """C1: Multiple pending cards linking to the same other_id must not push
    its to-side degree above MAX_DEGREE, even when those links are still in-flight
    (not yet persisted to graph)."""
    from kg.pipeline_service import _step_embed_and_judge
    from kg.vocab_graph import MAX_DEGREE

    # Setup: other_id "target" already has MAX_DEGREE - 1 links.
    # Two pending cards (c1, c2) both want to link to "target".
    # Only the first should succeed; the second must be blocked by to-side tracking.
    cards_list = [
        _make_card("c1", "evoke", "to bring to mind"),
        _make_card("c2", "invoke", "to call upon"),
        _make_card("target", "provoke", "to anger"),
    ]
    cards = _FakeCards(cards_list)

    # Both c1 and c2 find "target" as similar
    similar_map = {
        "c1": [("target", 0.90)],
        "c2": [("target", 0.88)],
    }
    embeddings = _FakeEmbeddings(has_ids={"c1", "c2", "target"}, similar_map=similar_map)

    # "target" already has MAX_DEGREE - 1 links (one slot left)
    existing_target_links = [SimpleNamespace(id=f"link{i}", status="active") for i in range(MAX_DEGREE - 1)]
    graph = _FakeGraph(pending=["c1", "c2"], links={"target": existing_target_links})
    logger = _FakeLogger()

    # Judge approves both pairs
    judge_results = {
        "c1": {"target": Judgement(link="shares_usage", confidence=0.9, reason="related")},
        "c2": {"target": Judgement(link="shares_usage", confidence=0.9, reason="related")},
    }

    import kg.judge as judge_mod

    orig_judge = judge_mod.Judge
    fake_judge = _FakeJudge(judge_results)

    class PatchedJudge:
        def __init__(self, llm, **kwargs):
            pass

        def evaluate_batch(self, *args, **kwargs):
            return fake_judge.evaluate_batch(*args, **kwargs)

    judge_mod.Judge = PatchedJudge
    try:
        asyncio.run(
            _step_embed_and_judge(
                "u1",
                {"id": "u1", "dir": Path("/tmp/u1"), "config": {}},
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda v: v,
            )
        )
    finally:
        judge_mod.Judge = orig_judge

    # Only ONE link to "target" should be created (the first one fills the last slot).
    # The second must be blocked by to-side degree tracking.
    links_to_target = [lnk for lnk in graph.created_links if lnk[1] == "target"]
    assert len(links_to_target) == 1, (
        f"Expected 1 link to 'target' but got {len(links_to_target)}; to-side MAX_DEGREE was violated"
    )


# ── #3660: MAX_DEGREE counts both endpoints of an in-flight link ──────────


def _run_judge_step_for_degree(monkeypatch, *, card_ids, judge_results, similar_map):
    """Run _step_embed_and_judge over mutually similar pending cards; return (graph, judge_log_rejects)."""
    from kg import judge_log
    from kg.pipeline_service import _step_embed_and_judge

    cards = _FakeCards([_make_card(cid, cid, f"meaning {cid}") for cid in card_ids])
    embeddings = _FakeEmbeddings(has_ids=set(card_ids), similar_map=similar_map)
    graph = _FakeGraph(pending=list(card_ids))
    fake_judge = _FakeJudge(judge_results)

    class PatchedJudge:
        def __init__(self, llm, **kwargs):
            pass

        def evaluate_batch(self, *args, **kwargs):
            return fake_judge.evaluate_batch(*args, **kwargs)

    rejects: list[tuple[str, str, str]] = []
    monkeypatch.setattr(judge_log, "update_to_rejected", lambda f, t, reason: rejects.append((f, t, reason)) or 1)
    import kg.judge as judge_mod

    monkeypatch.setattr(judge_mod, "Judge", PatchedJudge)
    asyncio.run(
        _step_embed_and_judge(
            "u1",
            {"id": "u1", "dir": Path("/tmp/u1"), "config": {}},
            card_store_factory=lambda d: cards,
            graph_store_factory=lambda d, notebook_id="default": graph,
            embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
            client_factory=lambda provider: None,
            logger=_FakeLogger(),
            link_kind_enum=lambda v: v,
        )
    )
    return graph, rejects


def _distinct_neighbours(links, cid):
    return {lk[1] if lk[0] == cid else lk[0] for lk in links if cid in (lk[0], lk[1])}


def test_pending_card_that_is_also_a_link_target_respects_max_degree(monkeypatch):
    """#3660: c0 accepts six pending peers (its own cap), then c7 accepts c0 as a target. c0 is pending
    too, so its incoming count must not start from zero: the c7->c0 link must be capped."""
    from kg.vocab_graph import MAX_DEGREE

    ids = [f"c{i}" for i in range(8)]
    similar_map = {cid: [(other, 0.9 - 0.01 * j) for j, other in enumerate(ids) if other != cid] for cid in ids}
    judge_results = {
        "c0": {f"c{j}": Judgement(link="shares_usage", confidence=0.9, reason="related") for j in range(1, 7)},
        "c7": {"c0": Judgement(link="shares_usage", confidence=0.9, reason="related")},
    }

    graph, rejects = _run_judge_step_for_degree(
        monkeypatch, card_ids=ids, judge_results=judge_results, similar_map=similar_map
    )

    for cid in ids:
        assert len(_distinct_neighbours(graph.created_links, cid)) <= MAX_DEGREE, cid
    assert ("c7", "c0", "degree_cap") in rejects


def test_mutual_accepts_between_pending_cards_count_as_one_link(monkeypatch):
    """#3660: A accepts B and B accepts A is one link, so each endpoint has degree 1 and no duplicate is created."""
    ids = ["a", "b"]
    similar_map = {"a": [("b", 0.9)], "b": [("a", 0.9)]}
    judge_results = {
        "a": {"b": Judgement(link="shares_usage", confidence=0.9, reason="related")},
        "b": {"a": Judgement(link="shares_usage", confidence=0.9, reason="related")},
    }

    graph, rejects = _run_judge_step_for_degree(
        monkeypatch, card_ids=ids, judge_results=judge_results, similar_map=similar_map
    )

    assert len(graph.created_links) == 1
    assert rejects == []
