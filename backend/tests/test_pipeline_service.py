from __future__ import annotations

import asyncio
from pathlib import Path
from types import SimpleNamespace

import pytest

from kg.pipeline_service import run_pipeline_background


@pytest.fixture(scope="module", autouse=True)
def _reset_pipeline_log():
    """Close pipeline telemetry's SQLite singleton around this module."""
    from kg import pipeline_log

    pipeline_log.reset()
    yield
    pipeline_log.reset()


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


class _CardsOk:
    def all(self, include_deleted: bool = False, notebook_id: str | None = None):
        return [
            SimpleNamespace(
                id="c1",
                content="evoke",
                meaning="to bring to mind",
                pos="v.",
                note="note",
                difficulty=None,
                is_deleted=False,
                is_archived=False,
                notebook_id="default",
                embed_text=lambda: "evoke",
            )
        ]

    def update(self, card_id, **kwargs):
        return None

    def batch_update(self, updates):
        return 0

    def get(self, card_id):
        return None

    def get_batch(self, ids):
        cards = {c.id: c for c in self.all()}
        return {cid: cards[cid] for cid in ids if cid in cards}


class _GraphOk:
    def pop_candidates(self):
        return []

    def pop_pending_judge(self):
        return []

    def add_pending_judge(self, card_ids):
        pass

    def get_links_for(self, card_id):
        return []

    def has_link(self, a, b):
        return False

    def candidate_count(self):
        return 0

    def link_count(self):
        return 0


class _EmbeddingsBoom:
    def has(self, card_id):
        raise RuntimeError("embedding unavailable")


async def _locked_lock():
    lock = asyncio.Lock()
    await lock.acquire()
    return lock


def test_pipeline_service_waits_when_lock_is_held():
    """Regression guard for the 2026-04-11 incident's second root cause.

    Previously: if another run held the per-user lock, the pipeline silently
    skipped and returned 200 without doing any work — causing cards to sit
    forever in pending_judge_<notebook>.json. With the fix, the pipeline
    MUST wait on the lock instead of silently skipping, so concurrent
    triggers for different notebooks under the same user all run.
    """
    logger = _FakeLogger()
    user = {"id": "u_wait", "dir": Path("/tmp/u_wait"), "config": {}}

    async def scenario():
        external_lock = asyncio.Lock()
        await external_lock.acquire()

        async def get_user_lock_fn(user_id: str):
            return external_lock

        task = asyncio.create_task(
            run_pipeline_background(
                user,
                get_user_lock_fn=get_user_lock_fn,
                card_store_factory=lambda user_dir: _CardsOk(),
                graph_store_factory=lambda user_dir, notebook_id="default": _GraphOk(),
                embedding_store_factory=lambda user_dir, llm=None, notebook_id="default": _EmbeddingsBoom(),
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda value: value,
            )
        )

        # Let the task progress to the point where it tries to acquire the lock.
        await asyncio.sleep(0.05)

        # Critical invariant: the task must NOT have returned early.
        assert not task.done(), (
            "Pipeline must wait on the lock, not silently skip. "
            "This is the regression guard for the 2026-04-11 lock-skip bug."
        )
        # The old bug's signature log line must never appear again.
        assert not any("Pipeline already running" in m for m in logger.info_messages), (
            "'Pipeline already running, skipping' was the old bug's signature — must never appear."
        )

        # Release the external lock and let the queued pipeline run.
        external_lock.release()
        await task

        assert any("Pipeline started." in m for m in logger.info_messages)
        assert any("Pipeline completed." in m for m in logger.info_messages)

    asyncio.run(scenario())


def test_pipeline_service_concurrent_triggers_different_notebooks_all_run():
    """Two concurrent triggers for the same user but different notebooks
    must BOTH produce real work. This is the exact scenario of the
    2026-04-11 evening incident: new notebook "Test" with one card +
    default with a migrated orphan — previously only default's pipeline
    ran while the second silently bounced off the lock.

    To reliably exercise the contended-lock code path, the test itself
    holds the shared lock until both tasks have queued up on it, then
    releases. Without this, the mock-based pipeline (with `_CardsOk`'s
    synchronous return path) completes end-to-end without ever yielding
    control, so `asyncio.gather` would effectively serialize the two
    calls and the contended branch would never be exercised.
    """
    logger = _FakeLogger()
    user = {"id": "u_concurrent", "dir": Path("/tmp/u_concurrent"), "config": {}}
    shared_lock = asyncio.Lock()

    async def get_user_lock_fn(user_id: str):
        return shared_lock

    def make_call(notebook_id: str):
        return run_pipeline_background(
            user,
            get_user_lock_fn=get_user_lock_fn,
            card_store_factory=lambda user_dir: _CardsOk(),
            graph_store_factory=lambda user_dir, notebook_id="default": _GraphOk(),
            embedding_store_factory=lambda user_dir, llm=None, notebook_id="default": _EmbeddingsBoom(),
            client_factory=lambda provider: None,
            logger=logger,
            link_kind_enum=lambda value: value,
            notebook_id=notebook_id,
        )

    async def run_both():
        # Force contention by pre-holding the lock before spawning the two tasks.
        await shared_lock.acquire()
        task_a = asyncio.create_task(make_call("default"))
        task_b = asyncio.create_task(make_call("notebook_b"))
        # Let both tasks progress up to the point where they try to acquire
        # the lock (they will each log "lock held, queueing" before suspending).
        await asyncio.sleep(0.05)
        shared_lock.release()
        await asyncio.gather(task_a, task_b)

    asyncio.run(run_both())

    # Both calls must reach "Pipeline started." — this is the core correctness
    # property that the lock-skip bug violated.
    started = [m for m in logger.info_messages if "Pipeline started." in m]
    assert len(started) == 2, f"Expected 2 pipeline starts, got {len(started)}: {started}"

    # Both must complete (the skip branch would return before logging this).
    completed = [m for m in logger.info_messages if "Pipeline completed." in m]
    assert len(completed) == 2, f"Expected 2 pipeline completions, got {len(completed)}"

    # Must actually exercise the contended-lock path. Without this guard, a
    # future refactor that serializes the two calls (e.g. removes all awaits
    # before the work starts) would make the test pass without touching the
    # queue path.
    assert any("lock held, queueing" in m for m in logger.info_messages), (
        "Test did not exercise the contended-lock path — queue codepath untested."
    )

    # Regression guard: no silent skip.
    assert not any("Pipeline already running" in m for m in logger.info_messages)


def test_pipeline_service_logs_error_when_step_fails():
    logger = _FakeLogger()
    user = {"id": "u2", "dir": Path("/tmp/u2"), "config": {}}

    async def get_user_lock_fn(user_id: str):
        return asyncio.Lock()

    asyncio.run(
        run_pipeline_background(
            user,
            get_user_lock_fn=get_user_lock_fn,
            card_store_factory=lambda user_dir: _CardsOk(),
            graph_store_factory=lambda user_dir, notebook_id="default": _GraphOk(),
            embedding_store_factory=lambda user_dir, llm=None, notebook_id="default": _EmbeddingsBoom(),
            client_factory=lambda provider: None,
            logger=logger,
            link_kind_enum=lambda value: value,
        )
    )

    assert any("Embed" in message for message in logger.error_messages)
    assert any("Pipeline completed." in message for message in logger.info_messages)


# ---------------------------------------------------------------------------
# Parallel _step_link tests
# ---------------------------------------------------------------------------

import threading
import time


class _ConcurrentJudge:
    """Judge that records concurrent execution and measures overlap."""

    def __init__(self, delay: float = 0.05):
        self.delay = delay
        self.calls: list[str] = []
        self.max_concurrent = 0
        self._active = 0
        self._lock = threading.Lock()

    def evaluate(self, word_a, meaning_a, word_b, meaning_b):
        with self._lock:
            self._active += 1
            if self._active > self.max_concurrent:
                self.max_concurrent = self._active
        time.sleep(self.delay)
        with self._lock:
            self._active -= 1
            self.calls.append(f"{word_a}-{word_b}")
        return None  # no link to create


class _GraphWithCandidates:
    def __init__(self, pairs: list[tuple[str, str]]):
        self._pairs = pairs
        self.batch_links_called = False
        self._pending: list[str] = []

    def pop_candidates(self):
        return [SimpleNamespace(from_id=a, to_id=b) for a, b in self._pairs]

    def pop_pending_judge(self):
        result = list(self._pending)
        self._pending.clear()
        return result

    def add_pending_judge(self, card_ids):
        self._pending.extend(card_ids)

    def ack_pending_judge(self, card_ids):
        pass

    def get_links_for(self, card_id):
        return []

    def has_link(self, a, b):
        return False

    def batch_add_links(self, links):
        self.batch_links_called = True
        return links

    def requeue_candidates(self, candidates):
        pass


class _CardsForLink:
    def __init__(self, ids: list[str]):
        self._cards = {
            cid: SimpleNamespace(
                id=cid,
                content=f"word_{cid}",
                meaning=f"meaning_{cid}",
                pos="n.",
                note="some note",
                is_deleted=False,
                is_archived=False,
                embed_text=lambda: "text",
                difficulty=None,
                notebook_id="default",
            )
            for cid in ids
        }

    def all(self, include_deleted=False, notebook_id=None):
        return list(self._cards.values())

    def batch_update(self, updates):
        return 0

    def get_batch(self, ids):
        return {cid: self._cards[cid] for cid in ids if cid in self._cards}


class _EmbeddingsWithSimilar:
    """Embeddings that return similar pairs for concurrency test."""

    def __init__(self, similar_map: dict[str, list[tuple[str, float]]]):
        self._similar = similar_map

    def has(self, card_id):
        return True

    def add_batch(self, items):
        pass

    def find_similar(self, card_id, k=12):
        return self._similar.get(card_id, [])


class _GraphWithPending:
    """Graph with pending_judge cards for concurrency test."""

    def __init__(self, pending: list[str]):
        self._pending = list(pending)
        self.batch_links_called = False
        self.created_links: list = []

    def pop_pending_judge(self):
        result = list(self._pending)
        self._pending.clear()
        return result

    def add_pending_judge(self, card_ids):
        self._pending.extend(card_ids)

    def ack_pending_judge(self, card_ids):
        pass

    def get_links_for(self, card_id):
        return []

    def has_link(self, a, b):
        return False

    def batch_add_links(self, links):
        self.batch_links_called = True
        self.created_links.extend(links)
        return links


def test_step_embed_and_judge_touches_cards_after_creating_links():
    """Cards involved in newly created links must have updated_at bumped.

    Root cause of the "0 links" iOS display bug: pipeline creates links via
    batch_add_links but never touches the cards, so incremental sync
    (filtered by updated_at) never sends the new links to the client.
    """
    from kg.pipeline_service import _step_embed_and_judge

    ids = ["from1", "to1"]
    similar_map = {"from1": [("to1", 0.9)]}

    class _TrackingCards(_CardsForLink):
        def __init__(self, card_ids):
            super().__init__(card_ids)
            self.touched_ids: set[str] = set()

        def touch(self, card_id):
            self.touched_ids.add(card_id)

        def batch_touch(self, card_ids, *, notebook_id=None):
            self.touched_ids.update(card_ids)

    class _GraphCreatesLinks(_GraphWithPending):
        def batch_add_links(self, links):
            self.batch_links_called = True
            self.created_links.extend(links)
            return links  # production returns GraphLink objects; touch uses all_links not created

    tracking_cards = _TrackingCards(ids)
    graph = _GraphCreatesLinks(["from1"])

    async def run():
        import kg.judge as judge_mod

        orig = judge_mod.Judge

        class FakeJudge:
            def __init__(self, llm, **kwargs):
                pass

            def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
                results = {}
                for cid, _word, _meaning in candidates:
                    results[cid] = SimpleNamespace(link="shares_usage", confidence=0.9, reason="test")
                return results

        judge_mod.Judge = FakeJudge
        try:
            user = {"id": "u_touch", "dir": None, "config": {}}
            await _step_embed_and_judge(
                "u_touch",
                user,
                card_store_factory=lambda d: tracking_cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": _EmbeddingsWithSimilar(similar_map),
                client_factory=lambda provider: None,
                logger=_FakeLogger(),
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = orig

    asyncio.run(run())

    assert graph.batch_links_called, "Expected batch_add_links to be called"
    assert len(graph.created_links) >= 1, f"Expected at least 1 link, got {len(graph.created_links)}"
    # Both from_id and to_id must be touched
    assert "from1" in tracking_cards.touched_ids, f"from_id 'from1' not touched. Touched: {tracking_cards.touched_ids}"
    assert "to1" in tracking_cards.touched_ids, f"to_id 'to1' not touched. Touched: {tracking_cards.touched_ids}"


def test_step_embed_and_judge_no_touch_when_no_links_created():
    """When judge rejects all candidates, no cards should be touched."""
    from kg.pipeline_service import _step_embed_and_judge

    ids = ["c1", "c2"]
    similar_map = {"c1": [("c2", 0.9)]}

    class _TrackingCards(_CardsForLink):
        def __init__(self, card_ids):
            super().__init__(card_ids)
            self.touched_ids: set[str] = set()

        def batch_touch(self, card_ids, *, notebook_id=None):
            self.touched_ids.update(card_ids)

    tracking_cards = _TrackingCards(ids)
    graph = _GraphWithPending(["c1"])

    async def run():
        import kg.judge as judge_mod

        orig = judge_mod.Judge

        class RejectAllJudge:
            def __init__(self, llm, **kwargs):
                pass

            def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
                return {cid: None for cid, _, _ in candidates}

        judge_mod.Judge = RejectAllJudge
        try:
            user = {"id": "u_no_touch", "dir": None, "config": {}}
            await _step_embed_and_judge(
                "u_no_touch",
                user,
                card_store_factory=lambda d: tracking_cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": _EmbeddingsWithSimilar(similar_map),
                client_factory=lambda provider: None,
                logger=_FakeLogger(),
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = orig

    asyncio.run(run())

    assert tracking_cards.touched_ids == set(), (
        f"No links created, but cards were touched: {tracking_cards.touched_ids}"
    )


def test_step_embed_and_judge_touches_cards_on_exception_path():
    """When judge crashes mid-batch, partially created links must still touch cards.

    Expected contract: the judge exception is re-raised (not swallowed), the
    link judged before the crash (ok1 → ok2) is persisted and both of its cards
    are touched, and the crashing card is requeued for the next run.
    """
    from kg.pipeline_service import _step_embed_and_judge

    ids = ["ok1", "ok2", "boom1", "boom2"]
    # ok1 → ok2 will succeed, boom1 → boom2 will crash. The crash is keyed on
    # the card, not on call order: judge calls run on a thread pool, so a call
    # counter would make the outcome depend on scheduling.
    similar_map = {
        "ok1": [("ok2", 0.9)],
        "boom1": [("boom2", 0.9)],
    }

    class _TrackingCards(_CardsForLink):
        def __init__(self, card_ids):
            super().__init__(card_ids)
            self.touched_ids: set[str] = set()

        def batch_touch(self, card_ids, *, notebook_id=None):
            self.touched_ids.update(card_ids)

    class _GraphWithRequeue(_GraphWithPending):
        def __init__(self, pending):
            super().__init__(pending)
            self.requeued: list[str] = []

        def add_pending_judge(self, card_ids):
            self.requeued.extend(card_ids)

    tracking_cards = _TrackingCards(ids)
    graph = _GraphWithRequeue(["ok1", "boom1"])

    async def run():
        import kg.judge as judge_mod

        orig = judge_mod.Judge

        class CrashOnBoomJudge:
            def __init__(self, llm, **kwargs):
                pass

            def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
                if kwargs["from_id"] == "boom1":
                    raise RuntimeError("judge crashed")
                return {
                    cid: SimpleNamespace(link="shares_usage", confidence=0.9, reason="test") for cid, _, _ in candidates
                }

        judge_mod.Judge = CrashOnBoomJudge
        try:
            user = {"id": "u_exc", "dir": None, "config": {}}
            await _step_embed_and_judge(
                "u_exc",
                user,
                card_store_factory=lambda d: tracking_cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": _EmbeddingsWithSimilar(similar_map),
                client_factory=lambda provider: None,
                logger=_FakeLogger(),
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = orig

    with pytest.raises(RuntimeError, match="judge crashed"):
        asyncio.run(run())

    assert graph.created_links == [("ok1", "ok2", "shares_usage", 0.9, "test")]
    assert tracking_cards.touched_ids == {"ok1", "ok2"}
    assert graph.requeued == ["boom1"]


def test_step_embed_and_judge_runs_judge_concurrently():
    """_step_embed_and_judge 必須並行呼叫 judge.evaluate_batch（max_concurrent > 1）。"""
    from kg.pipeline_service import _step_embed_and_judge

    # 10 cards, each similar to the next
    ids = [f"c{i}" for i in range(10)]
    similar_map = {ids[i]: [(ids[j], 0.85)] for i in range(10) for j in range(10) if i != j}
    fake_judge = _ConcurrentJudge(delay=0.05)

    async def run():
        import kg.judge as judge_mod

        orig = judge_mod.Judge

        class FakeJudge:
            def __init__(self, llm, **kwargs):
                pass

            def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
                results = {}
                for cid, word, meaning in candidates:
                    r = fake_judge.evaluate(target_word, target_meaning, word, meaning)
                    results[cid] = r
                return results

        judge_mod.Judge = FakeJudge
        try:
            user = {"id": "u_par", "dir": None, "config": {}}
            await _step_embed_and_judge(
                "u_par",
                user,
                card_store_factory=lambda d: _CardsForLink(ids),
                graph_store_factory=lambda d, notebook_id="default": _GraphWithPending(ids),
                embedding_store_factory=lambda d, llm=None, notebook_id="default": _EmbeddingsWithSimilar(similar_map),
                client_factory=lambda provider: None,
                logger=_FakeLogger(),
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = orig

    asyncio.run(run())

    # 並行驗證：若仍為串行，max_concurrent == 1；並行後應 > 1
    assert fake_judge.max_concurrent > 1, (
        f"Expected concurrent judge calls, got max_concurrent={fake_judge.max_concurrent}. "
        "Looks like _step_embed_and_judge is still sequential."
    )
    assert len(fake_judge.calls) >= 5, f"Expected at least 5 judge calls, got {len(fake_judge.calls)}"


# ── auto_link 開關(user config auto_link group)──────────────────────────


@pytest.mark.parametrize("enabled", [False, "false"])
def test_step_embed_and_judge_skips_judge_when_auto_link_disabled(enabled):
    """auto_link.enabled=False → Phase 2 不消費 pending_judge:待判集合保留、
    judge LLM 不建構、不產生連結。重新開啟後下一輪 pipeline 可續判。"""
    from kg.pipeline_service import _step_embed_and_judge

    ids = ["c1", "c2"]
    similar_map = {"c1": [("c2", 0.9)]}
    cards = _CardsForLink(ids)
    graph = _GraphWithPending(["c1"])

    async def run():
        import kg.judge as judge_mod

        orig = judge_mod.Judge

        class ExplodingJudge:
            def __init__(self, llm, **kwargs):
                raise AssertionError("Judge must not be constructed when auto_link is disabled")

        judge_mod.Judge = ExplodingJudge
        try:
            user = {
                "id": "u_al_off",
                "dir": None,
                "config": {"auto_link": {"enabled": enabled, "updated_at": 1.0}},
            }
            return await _step_embed_and_judge(
                "u_al_off",
                user,
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": _EmbeddingsWithSimilar(similar_map),
                client_factory=lambda provider: None,
                logger=_FakeLogger(),
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = orig

    created = asyncio.run(run())

    assert created == 0
    assert graph._pending == ["c1"], f"pending_judge must be preserved when auto_link disabled, got {graph._pending}"
    assert graph.batch_links_called is False


def test_step_embed_and_judge_still_embeds_when_auto_link_disabled():
    """關閉 auto_link 只擋 judge:新卡仍照常 embed 並加入 pending_judge 待判集合。"""
    from kg.pipeline_service import _step_embed_and_judge

    ids = ["c1", "c2"]

    class _EmbeddingsMissingThenAdd(_EmbeddingsWithSimilar):
        def __init__(self):
            super().__init__({})
            self._added: set[str] = set()
            self.add_batch_called = False

        def has(self, card_id):
            return card_id in self._added

        def add_batch(self, items):
            self.add_batch_called = True
            self._added.update(cid for cid, _ in items)

    embeddings = _EmbeddingsMissingThenAdd()
    cards = _CardsForLink(ids)
    graph = _GraphWithPending([])

    async def run():
        user = {
            "id": "u_al_embed",
            "dir": None,
            "config": {"auto_link": {"enabled": False, "updated_at": 1.0}},
        }
        return await _step_embed_and_judge(
            "u_al_embed",
            user,
            card_store_factory=lambda d: cards,
            graph_store_factory=lambda d, notebook_id="default": graph,
            embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
            client_factory=lambda provider: None,
            logger=_FakeLogger(),
            link_kind_enum=lambda v: v,
        )

    created = asyncio.run(run())

    assert created == 0
    assert embeddings.add_batch_called, "embed must still run when auto_link disabled"
    assert sorted(graph._pending) == sorted(ids), (
        f"newly embedded cards must queue into pending_judge, got {graph._pending}"
    )
    assert graph.batch_links_called is False


# --------------------------------------------------------------------- #
# D3: judge step uses find_similar_batch (with fallback)
# --------------------------------------------------------------------- #
class _BatchEmbeddings:
    """Embeddings double exposing BOTH find_similar and find_similar_batch,
    so the judge step takes the batched path. Counts each call so tests can
    assert exactly one batch lookup for the whole pending set."""

    def __init__(self, similar_map: dict[str, list[tuple[str, float]]]):
        self._similar = similar_map
        self.batch_calls = 0
        self.single_calls = 0
        self.batch_arg_ids: list[str] | None = None

    def has(self, card_id):
        return True

    def add_batch(self, items):
        pass

    def find_similar(self, card_id, k=12):
        self.single_calls += 1
        return self._similar.get(card_id, [])

    def find_similar_batch(self, card_ids, k=12):
        self.batch_calls += 1
        self.batch_arg_ids = list(card_ids)
        return {cid: self._similar.get(cid, []) for cid in card_ids}


class _TouchableCards(_CardsForLink):
    """_CardsForLink + the batch_touch hook the judge step calls after linking."""

    def __init__(self, card_ids):
        super().__init__(card_ids)
        self.touched_ids: set[str] = set()

    def batch_touch(self, card_ids, *, notebook_id=None):
        self.touched_ids.update(card_ids)


def _run_judge(user, cards, graph, embeddings):
    """Drive _step_embed_and_judge with a link-accepting fake judge."""
    from kg.pipeline_service import _step_embed_and_judge

    async def run():
        import kg.judge as judge_mod

        orig = judge_mod.Judge

        class FakeJudge:
            def __init__(self, llm, **kwargs):
                pass

            def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
                return {
                    cid: SimpleNamespace(link="shares_usage", confidence=0.9, reason="t") for cid, _w, _m in candidates
                }

        judge_mod.Judge = FakeJudge
        try:
            await _step_embed_and_judge(
                user["id"],
                user,
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=_FakeLogger(),
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = orig

    asyncio.run(run())


def test_step_judge_uses_find_similar_batch():
    """When the store supports find_similar_batch, the judge step must call it
    ONCE for the whole eligible pending set (not per-card find_similar)."""
    ids = ["a", "b", "c"]
    similar_map = {"a": [("b", 0.9)], "b": [("c", 0.9)], "c": [("a", 0.9)]}
    cards = _TouchableCards(ids)
    graph = _GraphWithPending(["a", "b", "c"])
    emb = _BatchEmbeddings(similar_map)

    _run_judge({"id": "u_batch", "dir": None, "config": {}}, cards, graph, emb)

    assert emb.batch_calls == 1, f"expected 1 batch call, got {emb.batch_calls}"
    assert emb.single_calls == 0, f"batched path must not call find_similar, got {emb.single_calls}"
    # Only eligible (non-deleted/archived, under degree) ids are queried.
    assert set(emb.batch_arg_ids or []) == set(ids)


def test_step_judge_candidates_unchanged():
    """The batched path must produce the SAME links as the per-card fallback.

    Run the identical scenario twice: once with a store exposing
    find_similar_batch (batched path), once with a store exposing only
    find_similar (fallback path). The set of created links must be identical."""
    ids = ["a", "b", "c"]
    similar_map = {"a": [("b", 0.9), ("c", 0.1)], "b": [("c", 0.95)], "c": []}

    # Batched path
    graph_batch = _GraphWithPending(["a", "b", "c"])
    graph_batch.created_links = []

    def _capture_batch(links):
        graph_batch.created_links.extend(links)
        graph_batch.batch_links_called = True
        return links

    graph_batch.batch_add_links = _capture_batch
    _run_judge(
        {"id": "u1", "dir": None, "config": {}}, _TouchableCards(ids), graph_batch, _BatchEmbeddings(similar_map)
    )

    # Fallback path (only find_similar)
    graph_single = _GraphWithPending(["a", "b", "c"])
    graph_single.created_links = []

    def _capture_single(links):
        graph_single.created_links.extend(links)
        graph_single.batch_links_called = True
        return links

    graph_single.batch_add_links = _capture_single
    _run_judge(
        {"id": "u2", "dir": None, "config": {}}, _TouchableCards(ids), graph_single, _EmbeddingsWithSimilar(similar_map)
    )

    def _norm(links):
        # Links are (from, to, kind, conf, reason) tuples; compare unordered
        # by the (from, to) identity that the candidate filter determines.
        return sorted((lk[0], lk[1]) for lk in links)

    assert _norm(graph_batch.created_links) == _norm(graph_single.created_links), (
        f"batch links {_norm(graph_batch.created_links)} != fallback links {_norm(graph_single.created_links)}"
    )


# ---------------------------------------------------------------------------
# #3661: enrich writes are compare-and-set on the snapshot they decided from
# ---------------------------------------------------------------------------


class _EnrichRecordingEmbeddings:
    def __init__(self):
        self.removed: list[str] = []

    def remove(self, card_id):
        self.removed.append(card_id)


class _EnrichRecordingGraph:
    def __init__(self):
        self.queued: list[str] = []

    def add_pending_judge(self, card_id):
        self.queued.append(card_id)


def _patch_enrich_stream(monkeypatch, stream):
    import kg.deps_quota as deps_quota
    import kg.enrich as enrich_mod
    import kg.llm.providers as providers
    import kg.tracked_llm as tracked_llm

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", stream)
    monkeypatch.setattr(providers, "provider_for", lambda _task: SimpleNamespace(chat_model="m"))
    monkeypatch.setattr(tracked_llm, "TrackedLLM", lambda *_a, **_k: None)
    monkeypatch.setattr(deps_quota, "_is_pro", lambda _user: False)


def test_step_enrich_skips_write_for_card_edited_during_stream(monkeypatch, tmp_path):
    """#3661: a user edit made while the LLM stream is in flight must not be overwritten by enrich."""
    import logging

    from kg.cards import CardStore
    from kg.pipeline_service.steps import _step_enrich

    cards = CardStore(tmp_path / "cards.db")
    card = cards.add(content="evoke", meaning="", pos=None, notebook_id="default")
    embeddings, graph = _EnrichRecordingEmbeddings(), _EnrichRecordingGraph()

    async def stream(llm, targets, **kwargs):
        # The user edits the card after the enrich snapshot was taken and before the result lands.
        cards.update(card.id, note="user note", meaning="user meaning")
        yield {
            "status": "running",
            "card_ids": [card.id],
            "results": [
                {
                    "word": "evoke",
                    "pos": "verb",
                    "note": "REGENERATED",
                    "collocations": ["a b"],
                    "meaning_fix": "LLM meaning",
                }
            ],
        }

    _patch_enrich_stream(monkeypatch, stream)
    user = {"id": "u_enrich_race", "dir": "/tmp/u_enrich_race", "config": {}}

    updated = asyncio.run(
        _step_enrich(
            "u_enrich_race",
            user,
            card_store_factory=lambda _d: cards,
            client_factory=lambda _provider: None,
            logger=logging.getLogger("test_enrich_race"),
            embedding_store_factory=lambda _d, **_k: embeddings,
            graph_store_factory=lambda _d, **_k: graph,
        )
    )

    after = cards.get(card.id)
    assert after.note == "user note"
    assert after.meaning == "user meaning"
    assert after.pos is None
    assert updated == 0
    assert embeddings.removed == []
    assert graph.queued == []


def test_step_enrich_still_writes_when_card_unchanged_during_stream(monkeypatch, tmp_path):
    """#3661 companion: the compare-and-set must not block an ordinary enrich write."""
    import logging

    from kg.cards import CardStore
    from kg.pipeline_service.steps import _step_enrich

    cards = CardStore(tmp_path / "cards.db")
    card = cards.add(content="evoke", meaning="旧", pos=None, notebook_id="default")

    async def stream(llm, targets, **kwargs):
        yield {
            "status": "running",
            "card_ids": [card.id],
            "results": [{"word": "evoke", "pos": "verb", "note": "REGENERATED", "meaning_fix": "新"}],
        }

    _patch_enrich_stream(monkeypatch, stream)
    user = {"id": "u_enrich_ok", "dir": "/tmp/u_enrich_ok", "config": {}}

    updated = asyncio.run(
        _step_enrich(
            "u_enrich_ok",
            user,
            card_store_factory=lambda _d: cards,
            client_factory=lambda _provider: None,
            logger=logging.getLogger("test_enrich_ok"),
            embedding_store_factory=lambda _d, **_k: _EnrichRecordingEmbeddings(),
            graph_store_factory=lambda _d, **_k: _EnrichRecordingGraph(),
        )
    )

    after = cards.get(card.id)
    assert (after.pos, after.note, after.meaning) == ("verb", "REGENERATED", "新")
    assert updated == 1


def test_default_enrich_skips_write_for_card_edited_during_stream(monkeypatch, tmp_path):
    """#3661: the add-link single-card enrich path uses the same compare-and-set."""
    import logging

    from kg.cards import CardStore
    from kg.vocab_add_link_operation import _default_enrich

    cards = CardStore(tmp_path / "cards.db")
    card = cards.add(content="evoke", meaning="", pos=None, notebook_id="default")
    snapshot = cards.get(card.id)
    embeddings, graph = _EnrichRecordingEmbeddings(), _EnrichRecordingGraph()

    async def stream(llm, targets, **kwargs):
        cards.update(card.id, note="user note", meaning="user meaning")
        yield {
            "status": "running",
            "card_ids": [card.id],
            "results": [{"word": "evoke", "pos": "verb", "note": "REGENERATED", "meaning_fix": "LLM meaning"}],
        }

    _patch_enrich_stream(monkeypatch, stream)
    user = {"id": "u_add_link_race", "dir": "/tmp/u_add_link_race", "config": {}}

    asyncio.run(
        _default_enrich(
            card=snapshot,
            cards=cards,
            user=user,
            client_factory=lambda _provider: None,
            logger=logging.getLogger("test_default_enrich_race"),
            graph=graph,
            open_embeddings=lambda: embeddings,
        )
    )

    after = cards.get(card.id)
    assert after.note == "user note"
    assert after.meaning == "user meaning"
    assert after.pos is None
    assert embeddings.removed == []
    assert graph.queued == []
