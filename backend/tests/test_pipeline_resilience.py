from __future__ import annotations

import asyncio
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest
from openai import OpenAIError

from kg.pipeline_service import (
    _step_embed_and_judge,
    _step_enrich,
    run_pipeline_background,
)


@pytest.fixture(autouse=True)
def _close_pipeline_log():
    from kg import pipeline_log

    pipeline_log._reset()
    try:
        yield
    finally:
        pipeline_log._reset()
        assert pipeline_log._conn is None, "pipeline_log SQLite connection leaked from test"


async def _async_lock():
    return asyncio.Lock()


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


class _CardsBothFields:
    """Cards that already have pos+note — enrich step should be skipped."""

    def all(self, include_deleted: bool = False, notebook_id: str | None = None):
        return [
            SimpleNamespace(
                id="c1",
                content="evoke",
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

    def batch_update_if_unchanged(self, updates):
        self.batch_update([(card_id, kwargs) for card_id, kwargs, _expected in updates])
        return []

    def batch_update(self, updates):
        return 0

    def get(self, card_id):
        return None


class _CardsNeedEnrich:
    """Cards that need enrichment (no pos/note)."""

    def __init__(self, fail_count: int = 0):
        self.calls = 0
        self.fail_count = fail_count

    def all(self, include_deleted: bool = False, notebook_id: str | None = None):
        return [
            SimpleNamespace(
                id="c1",
                content="evoke",
                pos=None,
                note=None,
                enrich_attempts=0,
                difficulty=None,
                is_deleted=False,
                notebook_id="default",
            )
        ]

    def update(self, card_id, **kwargs):
        return None

    def batch_update_if_unchanged(self, updates):
        self.batch_update([(card_id, kwargs) for card_id, kwargs, _expected in updates])
        return []

    def batch_update(self, updates):
        return 0


class _GraphOk:
    def pop_candidates(self):
        return []

    def pop_pending_judge(self):
        return []

    def add_pending_judge(self, card_ids):
        pass

    def add_candidate(self, *args):
        pass

    def batch_add_candidates(self, items):
        return 0


class _EmbeddingsOk:
    def has(self, card_id):
        return True


class _EmbeddingsMissing:
    """Embedding store that reports missing and records add() calls."""

    def __init__(self):
        self.added: list[str] = []
        self.add_thread_ids: list[int] = []

    def has(self, card_id):
        return False

    def add(self, card_id, text):
        self.added.append(card_id)
        self.add_thread_ids.append(threading.get_ident())

    def add_batch(self, items):
        for card_id, text in items:
            self.add(card_id, text)

    def find_similar(self, card_id, k=3):
        return []


async def _make_lock():
    return asyncio.Lock()


def test_enrich_step_retries_on_transient_failure():
    """Enrich step 瞬時失敗後第二次成功（retry 呼叫）。"""
    logger = _FakeLogger()
    user = {"id": "u1", "dir": Path("/tmp/u1"), "config": {}}
    enrich_calls = []

    async def fake_enrich_stream(client, targets, **kwargs):
        enrich_calls.append(1)
        if len(enrich_calls) == 1:
            from openai import OpenAIError

            raise OpenAIError("rate limit")
        # second call: yield empty — no updates
        return
        yield  # make it an async generator

    original = None

    async def run():
        nonlocal original
        # Patch enrich_cards_stream inside _step_enrich lazy import scope
        import kg.enrich as enrich_mod

        original_stream = enrich_mod.enrich_cards_stream

        async def patched_stream(client, targets, **kwargs):
            enrich_calls.append(1)
            if len(enrich_calls) == 1:
                from openai import OpenAIError

                raise OpenAIError("rate limit")
            if False:
                yield  # make async generator

        enrich_mod.enrich_cards_stream = patched_stream
        try:
            await run_pipeline_background(
                user,
                get_user_lock_fn=lambda uid: _async_lock(),
                card_store_factory=lambda d: _CardsNeedEnrich(),
                graph_store_factory=lambda d, notebook_id="default": _GraphOk(),
                embedding_store_factory=lambda d, llm=None, notebook_id="default": _EmbeddingsOk(),
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda v: v,
            )
        finally:
            enrich_mod.enrich_cards_stream = original_stream

    asyncio.run(run())
    # After retry, enrich should have been called twice (1 fail + 1 success)
    assert len(enrich_calls) == 2
    # No error logged for enrich (retry succeeded)
    assert logger.error_messages == []
    assert "[u1] Pipeline completed." in logger.info_messages
    assert not any("Pipeline halted" in m or "cancelled" in m for m in logger.warning_messages)


def test_embed_step_runs_in_executor_thread():
    """Embed step 的 sync 操作在非 event-loop thread 執行。"""
    logger = _FakeLogger()
    user = {"id": "u2", "dir": Path("/tmp/u2"), "config": {}}
    embeddings = _EmbeddingsMissing()
    event_loop_thread_id = None

    async def run():
        nonlocal event_loop_thread_id
        event_loop_thread_id = threading.get_ident()
        await run_pipeline_background(
            user,
            get_user_lock_fn=lambda uid: _async_lock(),
            card_store_factory=lambda d: _CardsBothFields(),
            graph_store_factory=lambda d, notebook_id="default": _GraphOk(),
            embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
            client_factory=lambda provider: None,
            logger=logger,
            link_kind_enum=lambda v: v,
        )

    asyncio.run(run())

    # _step_embed_and_judge offloads the synchronous embeddings.add_batch onto a
    # thread-pool executor (steps.py: loop.run_in_executor(None, add_batch, ...)),
    # so the embedding work for the missing card must NOT run on the event-loop
    # thread. This exercises the real production path (the old version tested a
    # now-deleted _sync_embed_loop helper directly).
    assert embeddings.add_thread_ids, "add_batch should have run for the missing card"
    assert all(tid != event_loop_thread_id for tid in embeddings.add_thread_ids), (
        "embedding work must run off the event-loop thread"
    )


# ════════════════════════════════════════════════════════════════════════
# Cascading-failure fakes shared by partial-failure / quota / rollback tests.
# ════════════════════════════════════════════════════════════════════════


class _CardWithMeaning:
    """Minimal card stand-in for embed+judge step."""

    def __init__(self, cid: str) -> None:
        self.id = cid
        self.content = cid
        self.meaning = f"meaning of {cid}"
        self.pos = "n."
        self.note = "ok"
        self.difficulty = 5.0
        self.is_deleted = False
        self.is_archived = False
        self.notebook_id = "default"

    def embed_text(self) -> str:
        return self.content


class _CardsForJudge:
    """Card store returning N cards already enriched + embedded.

    Captures batch_update / batch_touch invocations so tests can prove
    judge-phase commits survive a later cascading failure.
    """

    def __init__(self, count: int) -> None:
        self._cards = {f"c{i}": _CardWithMeaning(f"c{i}") for i in range(count)}
        self.batch_update_calls: list[list] = []
        self.batch_touch_calls: list[tuple[set, str | None]] = []

    def all(self, include_deleted: bool = False, notebook_id: str | None = None):
        return list(self._cards.values())

    def get(self, card_id):
        return self._cards.get(card_id)

    def get_batch(self, card_ids):
        return {cid: self._cards[cid] for cid in card_ids if cid in self._cards}

    def update(self, card_id, **kwargs):
        return None

    def batch_update_if_unchanged(self, updates):
        self.batch_update([(card_id, kwargs) for card_id, kwargs, _expected in updates])
        return []

    def batch_update(self, updates):
        self.batch_update_calls.append(list(updates))
        return len(updates)

    def batch_touch(self, ids, notebook_id=None):
        self.batch_touch_calls.append((set(ids), notebook_id))
        return len(ids)


class _GraphRecording:
    """Graph store that records pending_judge mutations + persisted links."""

    def __init__(self, pending: list[str] | None = None) -> None:
        self._pending: list[str] = list(pending or [])
        self.added_pending: list[list[str]] = []
        self.acked_pending: list[str] = []
        self.persisted_links: list[tuple] = []
        self._existing_links: set[tuple[str, str]] = set()

    def pop_pending_judge(self):
        out = list(self._pending)
        self._pending = []
        return out

    def add_pending_judge(self, card_ids):
        ids = list(card_ids)
        self.added_pending.append(ids)
        self._pending.extend(ids)

    def ack_pending_judge(self, card_ids):
        self.acked_pending.extend(card_ids)

    def has_link(self, a, b):
        return (a, b) in self._existing_links or (b, a) in self._existing_links

    def get_links_for(self, card_id):
        return []

    def batch_add_links(self, links):
        # Mirror real store: persist and return GraphLink-like stand-ins.
        persisted = []
        for from_id, to_id, kind, conf, reason in links:
            self.persisted_links.append((from_id, to_id, kind, conf, reason))
            self._existing_links.add((from_id, to_id))
            persisted.append(
                SimpleNamespace(
                    from_id=from_id,
                    to_id=to_id,
                    kind=kind,
                    confidence=conf,
                    reason=reason,
                )
            )
        return persisted

    def batch_add_candidates(self, items):
        return len(items)

    def pop_candidates(self):
        return []

    def add_candidate(self, *a, **k):
        pass


class _EmbeddingsAlreadyHave:
    """Embeddings exist for every card; find_similar returns a fixed
    other-card pool so the judge phase has work to do."""

    def __init__(self, all_ids: list[str]) -> None:
        self._all = list(all_ids)

    def has(self, card_id):
        return True

    def find_similar(self, card_id, k=3):
        # Every other card looks similar above threshold (0.71 > 0.70).
        return [(other, 0.95) for other in self._all if other != card_id][:k]

    def add(self, *a, **k):
        pass

    def add_batch(self, *a, **k):
        pass


class _SimilarityEmbeddings(_EmbeddingsAlreadyHave):
    """Configurable similarity fake for pending-judge durability tests."""

    def __init__(
        self,
        all_ids: list[str],
        *,
        error_type: type[Exception] | None = None,
        empty: bool = False,
    ) -> None:
        super().__init__(all_ids)
        self.error_type = error_type
        self.empty = empty
        self.fail = error_type is not None

    def find_similar(self, card_id, k=3):
        if self.fail:
            raise self.error_type("similarity lookup failed")
        if self.empty:
            return []
        return super().find_similar(card_id, k=k)


class _BatchSimilarityEmbeddings(_SimilarityEmbeddings):
    def find_similar_batch(self, card_ids, k=3):
        return {card_id: self.find_similar(card_id, k=k) for card_id in card_ids}


def _make_judgement(link: str = "shares_usage", confidence: float = 0.9, reason: str = "ok"):
    """Build a Judgement-like object (only fields the pipeline reads)."""
    return SimpleNamespace(link=link, confidence=confidence, reason=reason)


# ════════════════════════════════════════════════════════════════════════
# Cascading-failure tests
# ════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize("lookup_mode", ["batch", "per-card"])
@pytest.mark.parametrize("error_type", [OSError, ValueError])
def test_similarity_lookup_failure_requeues_for_later_judge(lookup_mode, error_type):
    """A failed similarity lookup must leave the popped card durably pending."""
    logger = _FakeLogger()
    uid = f"u_similarity_{lookup_mode}_{error_type.__name__}"
    user = {"id": uid, "dir": Path(f"/tmp/{uid}"), "config": {}}
    cards = _CardsForJudge(count=2)
    graph = _GraphRecording(pending=["c1"])
    embeddings_cls = _BatchSimilarityEmbeddings if lookup_mode == "batch" else _SimilarityEmbeddings
    embeddings = embeddings_cls(["c0", "c1"], error_type=error_type)

    class _AcceptingJudge:
        def __init__(self, *args, **kwargs):
            pass

        def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
            return {
                candidate_id: _make_judgement() if index == 0 else None
                for index, (candidate_id, _word, _meaning) in enumerate(candidates)
            }

    async def run_twice():
        import kg.judge as judge_mod

        original_judge = judge_mod.Judge
        judge_mod.Judge = _AcceptingJudge
        try:
            first_result = await _step_embed_and_judge(
                uid,
                user,
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda value: value,
            )
            assert first_result == 0
            assert graph._pending == ["c1"]
            assert graph.added_pending == [["c1"]]

            embeddings.fail = False
            second_result = await _step_embed_and_judge(
                uid,
                user,
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda value: value,
            )
            return first_result, second_result
        finally:
            judge_mod.Judge = original_judge

    first_result, second_result = asyncio.run(run_twice())

    assert first_result == 0
    assert second_result == 1
    assert graph._pending == []
    assert len(graph.persisted_links) == 1
    assert len({(from_id, to_id) for from_id, to_id, *_ in graph.persisted_links}) == 1


@pytest.mark.parametrize("lookup_mode", ["batch", "per-card"])
def test_empty_similarity_result_consumes_pending_without_requeue(lookup_mode):
    """A genuine empty result is normal completion, not a retryable failure."""
    logger = _FakeLogger()
    uid = f"u_empty_similarity_{lookup_mode}"
    user = {"id": uid, "dir": Path(f"/tmp/{uid}"), "config": {}}
    cards = _CardsForJudge(count=2)
    graph = _GraphRecording(pending=["c1"])
    embeddings_cls = _BatchSimilarityEmbeddings if lookup_mode == "batch" else _SimilarityEmbeddings
    embeddings = embeddings_cls(["c0", "c1"], empty=True)

    result = asyncio.run(
        _step_embed_and_judge(
            uid,
            user,
            card_store_factory=lambda d: cards,
            graph_store_factory=lambda d, notebook_id="default": graph,
            embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
            client_factory=lambda provider: None,
            logger=logger,
            link_kind_enum=lambda value: value,
        )
    )

    assert result == 0
    assert graph._pending == []
    assert graph.added_pending == []
    assert graph.persisted_links == []


def test_judge_partial_failure_does_not_corrupt_remaining():
    """Judge raises on the 5th of 10 pending cards.

    Expected (matches `_step_embed_and_judge` lines 317-334):
    - Cards 0..3 produce links → persisted via batch_add_links
    - Card 4 (the failing one) + cards 5..9 → requeued via add_pending_judge
    - Total persisted + requeued == 10 (no orphan)
    - Exception re-raised
    """
    logger = _FakeLogger()
    uid = "u_judge_partial"
    user = {"id": uid, "dir": Path("/tmp/u_judge_partial"), "config": {}}

    pending_ids = [f"c{i}" for i in range(10)]
    cards = _CardsForJudge(count=10)
    graph = _GraphRecording(pending=list(pending_ids))
    embeddings = _EmbeddingsAlreadyHave(pending_ids)

    # Judge tasks run concurrently in a ThreadPoolExecutor — but the
    # results are awaited in deterministic order (futures[0], futures[1], …).
    # So even if c4's evaluate_batch finishes before c0..c3, the `await fut`
    # loop only OBSERVES it after c0..c3 succeed. To assert the partial-
    # commit invariant we fail BY card identity (c4), not by call count.
    call_log: list[str] = []

    class _FakeJudge:
        def __init__(self, *args, **kwargs):
            pass

        def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
            call_log.append(target_word)
            if target_word == "c4":
                raise OpenAIError("judge LLM rate-limited on card 5")
            # Otherwise: return ONE accepted link per candidate (first only)
            results = {}
            for i, (cid, _w, _m) in enumerate(candidates):
                results[cid] = _make_judgement() if i == 0 else None
            return results

    async def run():
        import kg.judge as judge_mod

        original_judge = judge_mod.Judge
        judge_mod.Judge = _FakeJudge
        # _step_embed_and_judge imports Judge lazily — also patch ps reference
        # if it has been cached. (It hasn't, but defensive.)
        try:
            await _step_embed_and_judge(
                uid,
                user,
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = original_judge

    # The exception is re-raised by _step_embed_and_judge (line 334)
    with pytest.raises(OpenAIError):
        asyncio.run(run())

    # ── Invariants ──
    # 1. c4 was invoked (it's the failing one). Other cards may have also
    #    been invoked since the executor pool runs them concurrently —
    #    that's fine; the await-loop only PROCESSES results in order until
    #    c4's future raises.
    assert "c4" in call_log, "c4 must have been dispatched to the executor"

    # 2. Partial links persisted from cards 0..3 (one link each, total 4).
    #    The await loop reads futures[0..3] successfully then hits c4 which
    #    raises → exception handler persists what's already in all_links.
    #    Later futures that already finished are salvaged too (#2699), so
    #    acked is c0..c3 plus any subset of c5..c9, and acked + requeued is a
    #    disjoint cover of all 10 cards.
    assert len(graph.persisted_links) >= 4
    assert set(graph.acked_pending) >= {"c0", "c1", "c2", "c3"}
    assert "c4" not in graph.acked_pending
    requeued_flat = [cid for batch in graph.added_pending for cid in batch]
    assert "c4" in requeued_flat, "the failing card must be requeued, not orphaned"
    assert sorted(requeued_flat + list(graph.acked_pending)) == sorted(pending_ids)

    # 4. batch_touch called for persisted links (incremental-sync wakeup).
    assert cards.batch_touch_calls, "persisted links must trigger batch_touch"


def test_judge_failure_during_result_consumption_does_not_orphan_card():
    """Bug A: exception thrown WHILE consuming a card's judge results.

    `_step_embed_and_judge` increments `processed` immediately after `await
    fut` succeeds, *before* walking `results.items()`. If the exception
    fires inside that inner loop (e.g. `link_kind_enum` rejects an illegal
    enum value, or a dict access raises), `processed` has already counted
    the card → `futures[processed:]` EXCLUDES it → the card is requeued
    neither here nor anywhere, and its partially-consumed results are lost.

    Here c4's `evaluate_batch` returns normally but its judgement carries an
    illegal link kind; `link_kind_enum` raises on it. c4 must still be
    requeued (not orphaned).
    """
    logger = _FakeLogger()
    uid = "u_judge_consume_fail"
    user = {"id": uid, "dir": Path("/tmp/u_judge_consume_fail"), "config": {}}

    pending_ids = [f"c{i}" for i in range(10)]
    cards = _CardsForJudge(count=10)
    graph = _GraphRecording(pending=list(pending_ids))
    embeddings = _EmbeddingsAlreadyHave(pending_ids)

    class _JudgeIllegalKindForC4:
        def __init__(self, *args, **kwargs):
            pass

        def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
            results = {}
            for i, (cid, _w, _m) in enumerate(candidates):
                if i != 0:
                    results[cid] = None
                    continue
                # c4's first candidate carries an illegal link kind so the
                # downstream `link_kind_enum(...)` call raises — INSIDE the
                # result-consumption loop, after `await fut` succeeded.
                kind = "__ILLEGAL_KIND__" if target_word == "c4" else "shares_usage"
                results[cid] = _make_judgement(link=kind)
            return results

    def _strict_link_kind_enum(value):
        if value == "__ILLEGAL_KIND__":
            raise ValueError(f"illegal link kind: {value}")
        return value

    async def run():
        import kg.judge as judge_mod

        original_judge = judge_mod.Judge
        judge_mod.Judge = _JudgeIllegalKindForC4
        try:
            await _step_embed_and_judge(
                uid,
                user,
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=_strict_link_kind_enum,
            )
        finally:
            judge_mod.Judge = original_judge

    with pytest.raises(ValueError, match="illegal link kind"):
        asyncio.run(run())

    # ── Invariants ──
    # Cards 0..3 produced one valid link each; later completed futures are
    # salvaged too (#2699).
    assert len(graph.persisted_links) >= 4
    requeued = [cid for batch in graph.added_pending for cid in batch]
    assert "c4" in requeued, (
        f"c4 raised while its results were being consumed — it must be requeued, not orphaned. requeued={requeued}"
    )
    assert len(requeued) == len(set(requeued)), f"a card was requeued more than once: {sorted(requeued)}"
    assert sorted(requeued + list(graph.acked_pending)) == sorted(f"c{i}" for i in range(10))


def test_quota_exhaustion_mid_run_halts_gracefully():
    """Pipeline run hits QuotaExceededError mid judge phase.

    Spec: pipeline should treat quota exhaustion the same way it treats any
    step failure — current step's partial work persists, unprocessed cards
    requeue, pipeline_log marks the run as failed (not stuck "running"),
    and `run_pipeline_background` does NOT propagate the exception.

    Current code bug (pre-fix): `_STEP_ERRORS` / outer-catch in
    `run_pipeline_background` do NOT include `KGError`, so
    QuotaExceededError leaks out → pipeline_log.end_run("failed") is never
    called → run hangs "running" in telemetry. This test pins the spec.
    """
    from kg.exceptions import QuotaExceededError

    logger = _FakeLogger()
    uid = "u_quota_exhaust"
    user = {"id": uid, "dir": Path("/tmp/u_quota_exhaust"), "config": {}}

    pending_ids = [f"c{i}" for i in range(4)]
    cards = _CardsForJudge(count=4)
    graph = _GraphRecording(pending=list(pending_ids))
    embeddings = _EmbeddingsAlreadyHave(pending_ids)

    call_log: list[str] = []

    class _QuotaJudge:
        def __init__(self, *args, **kwargs):
            pass

        def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
            call_log.append(target_word)
            if len(call_log) >= 2:
                # Quota dies on the 2nd call — simulating mid-run exhaustion.
                raise QuotaExceededError(3600)
            results = {}
            for i, (cid, _w, _m) in enumerate(candidates):
                results[cid] = _make_judgement() if i == 0 else None
            return results

    # Pipeline_log telemetry observer — capture end_run status.
    end_run_calls: list[tuple[str, str]] = []

    async def run():
        import kg.judge as judge_mod
        import kg.pipeline_log as pipeline_log

        original_judge = judge_mod.Judge
        original_end_run = pipeline_log.end_run
        judge_mod.Judge = _QuotaJudge

        def spy_end_run(run_id, status, **kwargs):
            end_run_calls.append((run_id, status))
            return None

        pipeline_log.end_run = spy_end_run
        try:
            await run_pipeline_background(
                user,
                get_user_lock_fn=lambda u: _async_lock(),
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = original_judge
            pipeline_log.end_run = original_end_run

    # Spec: run_pipeline_background must NOT propagate the exception.
    # (Whole-pipeline failure is recorded in pipeline_log, not bubbled.)
    asyncio.run(run())

    # ── Invariants ──
    # 1. Partial judge work persisted (the 1st evaluate_batch produced a link).
    assert len(graph.persisted_links) == 1, (
        f"Expected 1 partial link committed before quota hit, got {len(graph.persisted_links)}"
    )

    # 2. Unprocessed cards requeued — no orphans dropped on the floor.
    requeued = [cid for batch in graph.added_pending for cid in batch]
    # Exact count depends on how many judge_tasks were prepared; we just
    # require at least the failing card got requeued (no orphan).
    assert requeued, "quota-exhaustion mid-run must requeue unprocessed cards"

    # 3. Pipeline_log MUST mark the run as ended (failed) — otherwise the
    #    run sits forever as "running" in telemetry.
    assert end_run_calls, (
        "pipeline_log.end_run must be called even on quota exhaustion (otherwise the run hangs in 'running' state)"
    )
    statuses = [s for _, s in end_run_calls]
    assert "quota_exhausted" in statuses, f"quota exhaustion must end_run with 'quota_exhausted' status, got {statuses}"


def test_judge_quota_rejection_does_not_discard_other_billed_results():
    """#2243: one judge call rejected for quota must not orphan the other
    cards' completed (billed, judge_log-accepted) results: their links are
    persisted and acked; only the rejected card is requeued."""
    from kg.exceptions import QuotaExceededError

    logger = _FakeLogger()
    uid = "u_judge_quota_collect"
    user = {"id": uid, "dir": Path("/tmp/u_judge_quota_collect"), "config": {}}
    pending_ids = [f"c{i}" for i in range(4)]
    cards = _CardsForJudge(count=4)
    graph = _GraphRecording(pending=list(pending_ids))
    embeddings = _EmbeddingsAlreadyHave(pending_ids)

    class _QuotaOnC1Judge:
        def __init__(self, *args, **kwargs):
            pass

        def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
            if target_word == "c1":
                raise QuotaExceededError(3600)
            return {cid: _make_judgement() if i == 0 else None for i, (cid, _w, _m) in enumerate(candidates)}

    async def run():
        import kg.judge as judge_mod

        original_judge = judge_mod.Judge
        judge_mod.Judge = _QuotaOnC1Judge
        try:
            await _step_embed_and_judge(
                uid,
                user,
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = original_judge

    with pytest.raises(QuotaExceededError):
        asyncio.run(run())

    assert len(graph.persisted_links) == 3, graph.persisted_links
    assert sorted(graph.acked_pending) == ["c0", "c2", "c3"]
    assert [cid for batch in graph.added_pending for cid in batch] == ["c1"]


def test_judge_skips_cards_from_other_notebooks():
    """#2532: a pending entry / stale vector whose card now lives in another
    notebook must neither be judged nor offered as a candidate, or a
    cross-notebook link is created."""
    logger = _FakeLogger()
    uid = "u_judge_nb_guard"
    user = {"id": uid, "dir": Path("/tmp/u_judge_nb_guard"), "config": {}}
    pending_ids = ["c0", "c1", "c2"]
    cards = _CardsForJudge(count=3)
    cards._cards["c1"].notebook_id = "elsewhere"
    graph = _GraphRecording(pending=list(pending_ids))
    embeddings = _EmbeddingsAlreadyHave(pending_ids)
    judged: list[tuple[str, list[str]]] = []

    class _RecordingJudge:
        def __init__(self, *args, **kwargs):
            pass

        def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
            judged.append((target_word, [cid for cid, _w, _m in candidates]))
            return {cid: _make_judgement() for cid, _w, _m in candidates}

    async def run():
        import kg.judge as judge_mod

        original_judge = judge_mod.Judge
        judge_mod.Judge = _RecordingJudge
        try:
            await _step_embed_and_judge(
                uid,
                user,
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = original_judge

    asyncio.run(run())

    assert judged, "in-notebook cards must still be judged"
    assert all(target != "c1" and "c1" not in cands for target, cands in judged), judged
    assert all("c1" not in (a, b) for a, b, *_ in graph.persisted_links), graph.persisted_links


def test_embed_step_failure_after_judge_commit_does_not_revert_judge():
    """A later pipeline step failing must NOT revert a previously committed
    earlier step.

    Scenario: judge phase commits 1 link, then the next step (Difficulty,
    via `cards.batch_update`) raises. The committed judge link must survive
    (no rollback) and pipeline_log records the partial completion.
    """
    logger = _FakeLogger()
    uid = "u_step_rollback"
    user = {"id": uid, "dir": Path("/tmp/u_step_rollback"), "config": {}}

    pending_ids = ["c0", "c1"]

    class _CardsThatFailDifficulty(_CardsForJudge):
        """Difficulty step calls batch_update with zipf scores — raise there.

        But judge phase also calls batch_update for enrich (no-op here since
        cards are already enriched). We distinguish by call ordering:
        the LAST batch_update is the difficulty step.
        """

        def __init__(self, count: int) -> None:
            super().__init__(count)
            self._raise_on_difficulty = False

        def batch_update_if_unchanged(self, updates):
            self.batch_update([(card_id, kwargs) for card_id, kwargs, _expected in updates])
            return []

        def batch_update(self, updates):
            self.batch_update_calls.append(list(updates))
            if self._raise_on_difficulty:
                # Difficulty step: blow up AFTER judge has committed links.
                raise OSError("disk full while writing difficulty scores")
            return len(updates)

    cards = _CardsThatFailDifficulty(count=2)
    graph = _GraphRecording(pending=list(pending_ids))
    embeddings = _EmbeddingsAlreadyHave(pending_ids)

    class _SuccessJudge:
        def __init__(self, *args, **kwargs):
            pass

        def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
            results = {}
            for i, (cid, _w, _m) in enumerate(candidates):
                results[cid] = _make_judgement() if i == 0 else None
            return results

    async def run():
        import kg.judge as judge_mod

        original_judge = judge_mod.Judge
        judge_mod.Judge = _SuccessJudge
        # Arm difficulty-step failure AFTER enrich (which is skipped since
        # cards already have pos/note) and AFTER judge commit.
        cards._raise_on_difficulty = True
        try:
            await run_pipeline_background(
                user,
                get_user_lock_fn=lambda u: _async_lock(),
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = original_judge

    asyncio.run(run())

    # ── Invariants ──
    # 1. Judge phase committed the mutual c0<->c1 accepts as ONE link (#3660: both directions are one pair).
    assert len(graph.persisted_links) == 1, (
        f"Expected 1 committed judge link before difficulty failure, got {len(graph.persisted_links)}"
    )

    # 2. Difficulty step actually attempted batch_update (and raised).
    assert cards.batch_update_calls, "difficulty step must have attempted batch_update before failing"

    # 3. Pipeline_log run is closed (no hanging "running" state) and
    #    difficulty step is logged as failed — judge is NOT reverted.
    #    The committed links must still be in graph.persisted_links above,
    #    and graph.added_pending should be empty (nothing requeued for
    #    judge — all 2 cards processed successfully).
    assert not graph.added_pending, (
        f"judge processed all cards successfully — no requeue expected, but got {graph.added_pending}"
    )

    # 4. The difficulty step error is logged (step isolation: error swallowed
    #    by `_run_step`, not propagated).
    assert any("Difficulty failed" in m for m in logger.error_messages), (
        f"difficulty failure must be logged as step error; got errors: {logger.error_messages}"
    )


class _RecLogger:
    def __init__(self) -> None:
        self.warning_messages: list[str] = []

    def info(self, *a, **k):
        pass

    def warning(self, msg, *args, **k):
        self.warning_messages.append(msg % args if args else msg)

    def error(self, *a, **k):
        pass


class _CardsRecordingUpdates:
    """One un-enriched card; records batch_update calls, or raises ``fail``."""

    def __init__(self, fail: BaseException | None = None) -> None:
        self.updates: list[list[tuple[str, dict]]] = []
        self._fail = fail

    def all(self, include_deleted: bool = False, notebook_id: str | None = None):
        return [SimpleNamespace(id="c1", content="evoke", pos=None, note=None, enrich_attempts=0)]

    def batch_update_if_unchanged(self, updates):
        self.batch_update([(card_id, kwargs) for card_id, kwargs, _expected in updates])
        return []

    def batch_update(self, updates):
        if self._fail is not None:
            raise self._fail
        self.updates.append(list(updates))
        return len(updates)


async def _run_step_enrich(uid: str, cards, logger) -> int:
    user = {"id": uid, "dir": Path(f"/tmp/{uid}"), "config": {}}
    return await _step_enrich(
        uid,
        user,
        card_store_factory=lambda d: cards,
        client_factory=lambda provider: None,
        logger=logger,
    )


def test_step_enrich_skips_malformed_llm_items(monkeypatch):
    """LLM JSON is untrusted: non-dict items and items without a str "word"
    are skipped and counted, and the valid item in the same batch still lands."""
    import kg.enrich as enrich_mod

    async def fake_stream(llm, targets, **kwargs):
        yield {
            "status": "running",
            "results": [5, "x", {"pos": "n."}, {"word": None}, {"word": "Evoke", "pos": "v.", "note": "n"}],
        }

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", fake_stream)
    cards = _CardsRecordingUpdates()
    logger = _RecLogger()

    updated = asyncio.run(_run_step_enrich("u_malformed", cards, logger))

    assert updated == 1
    assert cards.updates == [[("c1", {"pos": "v.", "note": "n"})]]
    assert "[u_malformed] Skipped 4 malformed enrichment items" in logger.warning_messages


def test_step_enrich_survives_mistyped_optional_fields(monkeypatch):
    """pos as a list / mistyped meaning_fix must not abort the step
    (``_normalize_pos`` would call ``.strip()`` on a list); valid fields of the
    same item still land and mistyped collocations entries are filtered."""
    import kg.enrich as enrich_mod

    async def fake_stream(llm, targets, **kwargs):
        yield {
            "status": "running",
            "results": [
                {"word": "Evoke", "pos": ["v."], "note": "n", "meaning_fix": 5, "collocations": ["a b", 3]},
            ],
        }

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", fake_stream)
    cards = _CardsRecordingUpdates()
    logger = _RecLogger()

    updated = asyncio.run(_run_step_enrich("u_mistyped", cards, logger))

    assert updated == 1
    assert cards.updates == [[("c1", {"note": "n", "collocations": ["a b"]})]]


def test_step_enrich_skips_non_list_results(monkeypatch):
    """`_parse_enrich_response` returns `data["results"]` verbatim, so a batch's
    results can be any JSON value; a non-iterable one must not crash the step."""
    import kg.enrich as enrich_mod

    async def fake_stream(llm, targets, **kwargs):
        yield {"status": "running", "results": 7}

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", fake_stream)
    cards = _CardsRecordingUpdates()
    logger = _RecLogger()

    updated = asyncio.run(_run_step_enrich("u_scalar", cards, logger))

    assert updated == 0
    assert cards.updates == []
    assert "[u_scalar] Skipped 1 malformed enrichment items" in logger.warning_messages


def test_step_enrich_closes_stream_when_consumer_raises(monkeypatch):
    """A consumer-side failure (SQLite busy timeout in batch_update) must close
    the enrich stream before the exception reaches the caller, so its executor
    is shut down now instead of whenever the generator is garbage-collected
    (and before _run_step's retry can start a second stream)."""
    import sqlite3

    import kg.enrich as enrich_mod

    closed: list[bool] = []

    async def fake_stream(llm, targets, **kwargs):
        try:
            yield {"status": "running", "results": [{"word": "evoke", "pos": "v.", "note": "n"}]}
        finally:
            closed.append(True)

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", fake_stream)
    cards = _CardsRecordingUpdates(fail=sqlite3.OperationalError("database is locked"))

    async def run() -> None:
        with pytest.raises(sqlite3.OperationalError, match="database is locked"):
            await _run_step_enrich("u_locked", cards, _RecLogger())
        # No await in between: an un-closed generator is only finalized later,
        # by the loop's asyncgen hook scheduling aclose() as a new task.
        assert closed == [True]

    asyncio.run(run())


def test_step_enrich_raises_when_all_batches_error(monkeypatch):
    """An error terminal with zero results must fail the step, not record ok/0."""
    import kg.enrich as enrich_mod

    async def fake_stream(llm, targets, **kwargs):
        yield {"status": "error", "detail": "provider down"}

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", fake_stream)
    with pytest.raises(RuntimeError, match="provider down"):
        asyncio.run(_run_step_enrich("u_allerr", _CardsRecordingUpdates(), _RecLogger()))


def test_step_enrich_matches_nfc_and_whitespace_variants(monkeypatch):
    """Result word differing by NFC form / surrounding whitespace still updates its card."""
    import kg.enrich as enrich_mod

    async def fake_stream(llm, targets, **kwargs):
        yield {"status": "running", "results": [{"word": "  Café ", "pos": "n.", "note": "n"}]}

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", fake_stream)
    cards = _CardsRecordingUpdates()
    cards.all = lambda **kw: [SimpleNamespace(id="c1", content="café", pos=None, note=None, enrich_attempts=0)]
    updated = asyncio.run(_run_step_enrich("u_nfc", cards, _RecLogger()))
    assert updated == 1


def test_step_enrich_stops_rebilling_cards_the_llm_never_returns(monkeypatch, tmp_path):
    """A card the LLM never matches must stop being a target after the attempt cap."""
    import kg.enrich as enrich_mod
    from kg.cards import CardStore
    from kg.pipeline_service.steps import ENRICH_MAX_ATTEMPTS

    seen: list[int] = []

    async def fake_stream(llm, targets, **kwargs):
        seen.append(len(targets))
        yield {
            "status": "running",
            "card_ids": [t.id for t in targets],
            "results": [{"word": "unrelated", "pos": "n.", "note": "n"}],
        }

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", fake_stream)
    store = CardStore(path=tmp_path / "cards.db")
    store.add("ghostword", "meaning")
    for _ in range(ENRICH_MAX_ATTEMPTS + 2):
        asyncio.run(_run_step_enrich("u_cap", store, _RecLogger()))
    assert seen == [1] * ENRICH_MAX_ATTEMPTS
    # force still re-enriches regardless of the counter
    asyncio.run(_step_enrich_force(store))
    assert seen[-1] == 1 and len(seen) == ENRICH_MAX_ATTEMPTS + 1


def test_step_enrich_empty_results_success_batch_still_consumes_an_attempt(monkeypatch, tmp_path):
    """A billed success batch answering with results == [] must still stop re-billing at the cap."""
    import kg.enrich as enrich_mod
    from kg.cards import CardStore
    from kg.pipeline_service.steps import ENRICH_MAX_ATTEMPTS

    seen: list[int] = []

    async def fake_stream(llm, targets, **kwargs):
        seen.append(len(targets))
        yield {"status": "running", "card_ids": [t.id for t in targets], "results": []}

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", fake_stream)
    store = CardStore(path=tmp_path / "cards.db")
    store.add("emptyword", "meaning")
    for _ in range(ENRICH_MAX_ATTEMPTS + 2):
        asyncio.run(_run_step_enrich("u_empty", store, _RecLogger()))
    assert seen == [1] * ENRICH_MAX_ATTEMPTS


def test_step_enrich_failed_batch_does_not_consume_an_attempt(monkeypatch, tmp_path):
    """Only cards in a batch that answered (success terminal) lose an attempt; errored batches don't."""
    import kg.enrich as enrich_mod
    from kg.cards import CardStore

    store = CardStore(path=tmp_path / "cards.db")
    answered = store.add("answered", "meaning")
    errored = store.add("errored", "meaning")

    async def fake_stream(llm, targets, **kwargs):
        yield {
            "status": "running",
            "card_ids": [answered.id],
            "results": [{"word": "unrelated", "pos": "n.", "note": "n"}],
        }
        yield {"status": "error", "detail": "provider 5xx", "results": []}

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", fake_stream)
    asyncio.run(_run_step_enrich("u_partial", store, _RecLogger()))
    attempts = {c.id: c.enrich_attempts for c in store.all()}
    assert attempts == {answered.id: 1, errored.id: 0}


async def _step_enrich_force(store) -> int:
    return await _step_enrich(
        "u_cap",
        {"id": "u_cap", "dir": Path("/tmp/u_cap"), "config": {}},
        card_store_factory=lambda d: store,
        client_factory=lambda provider: None,
        logger=_RecLogger(),
        force=True,
    )


def test_judge_abort_salvages_completed_futures_after_failing_card():
    """#2699: c1 fails while c2/c3 already finished (billed, judge_log accepted=1).

    The abort path must persist+ack c2/c3 rather than requeue and re-judge them.
    """
    import threading

    logger = _FakeLogger()
    uid = "u_judge_salvage"
    user = {"id": uid, "dir": Path("/tmp/u_judge_salvage"), "config": {}}
    pending_ids = [f"c{i}" for i in range(4)]
    cards = _CardsForJudge(count=4)
    graph = _GraphRecording(pending=list(pending_ids))
    embeddings = _EmbeddingsAlreadyHave(pending_ids)
    others_done = threading.Event()
    finished: set[str] = set()
    lock = threading.Lock()

    class _FailC1Judge:
        def __init__(self, *args, **kwargs):
            pass

        def evaluate_batch(self, target_word, target_meaning, candidates, **kwargs):
            if target_word == "c1":
                assert others_done.wait(10)
                raise OpenAIError("judge LLM down on c1")
            with lock:
                finished.add(target_word)
                if {"c0", "c2", "c3"} <= finished:
                    others_done.set()
            return {cid: _make_judgement() if i == 0 else None for i, (cid, _w, _m) in enumerate(candidates)}

    async def run():
        import kg.judge as judge_mod

        original_judge = judge_mod.Judge
        judge_mod.Judge = _FailC1Judge
        try:
            await _step_embed_and_judge(
                uid,
                user,
                card_store_factory=lambda d: cards,
                graph_store_factory=lambda d, notebook_id="default": graph,
                embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
                client_factory=lambda provider: None,
                logger=logger,
                link_kind_enum=lambda v: v,
            )
        finally:
            judge_mod.Judge = original_judge

    with pytest.raises(OpenAIError):
        asyncio.run(run())

    assert sorted(graph.acked_pending) == ["c0", "c2", "c3"]
    requeued = [cid for batch in graph.added_pending for cid in batch]
    assert requeued == ["c1"]
    assert len(graph.persisted_links) == 3
