"""Tests for kg.enrich — LLM-powered card enrichment."""

from __future__ import annotations

import asyncio
import contextlib
import json
import threading
import time
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from kg.cards import Card
from kg.enrich import _build_prompt, _parse_enrich_response
from kg.exceptions import QuotaExceededError
from kg.tracked_llm import TrackedLLM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_card(content: str = "hello", meaning: str = "你好", examples: list[str] | None = None) -> Card:
    return Card(content=content, meaning=meaning, examples=examples or [])


def _mock_response(content: str, prompt_tokens: int = 10, completion_tokens: int = 20):
    usage = SimpleNamespace(prompt_tokens=prompt_tokens, completion_tokens=completion_tokens)
    message = SimpleNamespace(content=content)
    choice = SimpleNamespace(message=message)
    return SimpleNamespace(choices=[choice], usage=usage)


@contextlib.asynccontextmanager
async def _max_loop_gap(settle: float = 0.05):
    """Measure event-loop responsiveness around the block.

    A ticker task sleeps 10 ms in a loop and records the largest wall-clock
    gap between its wake-ups, so any synchronous work on the loop thread
    (e.g. ``ThreadPoolExecutor.shutdown(wait=True)``) shows up as a gap. It
    keeps ticking ``settle`` seconds after the block, so a stall right after
    the generator closes is counted too.
    """
    stats = {"max_gap": 0.0}
    stop = asyncio.Event()

    async def _tick() -> None:
        last = time.monotonic()
        while not stop.is_set():
            await asyncio.sleep(0.01)
            now = time.monotonic()
            stats["max_gap"] = max(stats["max_gap"], now - last)
            last = now

    ticker = asyncio.create_task(_tick())
    await asyncio.sleep(0)
    try:
        yield stats
    finally:
        await asyncio.sleep(settle)
        stop.set()
        await ticker


class _ConsumerKeyError(KeyError):
    """A consumer-side failure like a missing LLM "word" key, raised only by a
    test consumer after it has received a message, so `pytest.raises` cannot
    be satisfied by a KeyError from the stream itself."""


class _GatedSyncRetry:
    """Stand-in for ``kg.enrich.sync_retry`` that simulates in-flight batches.

    The first call returns ``first`` (or raises it, if it is an exception);
    every later call parks on ``gate`` and then returns ``response``. A safety
    timer opens the gate after ``safety_release`` seconds, so code that blocks
    the loop until every batch has run fails the assertions instead of hanging
    the suite. ``calls`` counts LLM invocations across worker threads.
    """

    def __init__(self, first, response, *, safety_release: float = 1.0) -> None:
        self._first = first
        self._response = response
        self._lock = threading.Lock()
        self.calls = 0
        self.gate = threading.Event()
        self._timer = threading.Timer(safety_release, self.gate.set)

    def __enter__(self) -> _GatedSyncRetry:
        self._timer.start()
        return self

    def __exit__(self, *exc_info) -> None:
        self.gate.set()
        self._timer.cancel()

    def __call__(self, *args, **kwargs):
        with self._lock:
            self.calls += 1
            call_number = self.calls
        if call_number == 1:
            if isinstance(self._first, BaseException):
                raise self._first
            return self._first
        self.gate.wait(5)
        return self._response


# ---------------------------------------------------------------------------
# _build_prompt
# ---------------------------------------------------------------------------


class TestBuildPrompt:
    def test_single_card_with_example(self):
        card = _make_card("abandon", "放棄", ["He abandoned the project."])
        prompt = _build_prompt([card])
        assert "abandon" in prompt
        assert "放棄" in prompt
        assert "He abandoned the project." in prompt
        assert "context" in prompt

    def test_card_without_examples(self):
        card = _make_card("hello", "你好")
        prompt = _build_prompt([card])
        parsed = json.loads(prompt.split("分析以下單字（含現有翻譯和例句上下文）：\n")[1].split("\n\n回傳")[0])
        assert len(parsed) == 1
        assert "context" not in parsed[0]

    def test_multiple_cards(self):
        cards = [_make_card("a", "一"), _make_card("b", "二")]
        prompt = _build_prompt(cards)
        assert "a" in prompt
        assert "b" in prompt

    def test_private_disambiguation_context_is_not_card_example(self):
        card = _make_card("light", "光", ["The light was bright."])
        prompt = _build_prompt(
            [card],
            disambiguation_context_by_card_id={card.id: "a light meal after work"},
        )
        assert '"disambiguation_context": "a light meal after work"' in prompt
        assert '"context":' not in prompt
        assert "只供本次" in prompt


# ---------------------------------------------------------------------------
# _parse_enrich_response
# ---------------------------------------------------------------------------


class TestParseEnrichResponse:
    def test_json_array_direct(self):
        data = [{"word": "hello", "pos": "n."}]
        result = _parse_enrich_response(json.dumps(data))
        assert result == data

    def test_results_key(self):
        data = {"results": [{"word": "hello"}]}
        result = _parse_enrich_response(json.dumps(data))
        assert result == [{"word": "hello"}]

    def test_fallback_to_first_list_value(self):
        data = {"enrichments": [{"word": "hello"}]}
        result = _parse_enrich_response(json.dumps(data))
        assert result == [{"word": "hello"}]

    def test_empty_string(self):
        """Empty/null content → empty dict parse → empty list."""
        # json.loads("") raises; the function does `raw_content or "{}"`
        result = _parse_enrich_response("")
        assert result == []

    def test_none_content(self):
        result = _parse_enrich_response(None)
        assert result == []

    def test_invalid_json_raises(self):
        with pytest.raises(json.JSONDecodeError):
            _parse_enrich_response("not json at all {{{")

    def test_malformed_items_are_skipped_not_raised(self):
        data = [
            5,
            "x",
            {"word": None},
            {"word": ""},
            {"word": "bad_pos", "pos": ["n."], "note": 3, "meaning_fix": [], "collocations": "x"},
            {"word": "ok", "pos": "n.", "collocations": ["a b", 7]},
        ]
        result = _parse_enrich_response(json.dumps(data))
        assert result == [
            {"word": "bad_pos"},
            {"word": "ok", "pos": "n.", "collocations": ["a b"]},
        ]

    def test_non_list_results_value_returns_empty(self):
        assert _parse_enrich_response(json.dumps({"results": 7})) == []
        assert _parse_enrich_response(json.dumps({"results": {"word": "x"}})) == []

    def test_dict_no_list_values(self):
        result = _parse_enrich_response('{"status": "ok"}')
        assert result == []


# ---------------------------------------------------------------------------
# enrich_cards_stream
# ---------------------------------------------------------------------------


class TestEnrichCardsStream:
    @pytest.mark.asyncio
    async def test_empty_cards(self):
        from kg.enrich import enrich_cards_stream

        llm = TrackedLLM(MagicMock(), "test_user")
        results = []
        async for msg in enrich_cards_stream(llm, []):
            results.append(msg)
        assert len(results) == 1
        assert results[0]["status"] == "done"
        assert results[0]["total"] == 0

    @pytest.mark.asyncio
    async def test_multi_batch_yields_progress(self):
        from kg.enrich import enrich_cards_stream

        enriched = [{"word": "w", "pos": "n."}]
        resp = _mock_response(json.dumps(enriched))

        llm = TrackedLLM(MagicMock(), "test_user")

        with patch("kg.enrich.sync_retry", return_value=resp):
            cards = [_make_card(f"word{i}", f"意思{i}") for i in range(5)]
            results = []
            async for msg in enrich_cards_stream(llm, cards, batch_size=2):
                results.append(msg)

        # 5 cards / batch_size 2 = 3 batches → at least 3 progress messages
        running_msgs = [r for r in results if r["status"] == "running"]
        assert len(running_msgs) >= 3
        # Last running message should have current == total
        assert running_msgs[-1]["current"] == 5

    @pytest.mark.asyncio
    async def test_stream_queue_is_bounded(self):
        """The internal asyncio.Queue must have a bounded maxsize so a slow
        consumer can't let workers OOM the process with results."""
        from kg import enrich as enrich_mod
        from kg.enrich import enrich_cards_stream

        captured: dict[str, int] = {}
        original_queue = enrich_mod.asyncio.Queue

        def spy_queue(*args, **kwargs):
            captured["maxsize"] = kwargs.get("maxsize", 0 if not args else args[0])
            return original_queue(*args, **kwargs)

        resp = _mock_response(json.dumps([{"word": "x"}]))
        llm = TrackedLLM(MagicMock(), "u_test")

        with (
            patch("kg.enrich.sync_retry", return_value=resp),
            patch.object(enrich_mod.asyncio, "Queue", side_effect=spy_queue),
        ):
            cards = [_make_card()]
            async for _ in enrich_cards_stream(llm, cards):
                pass

        assert captured.get("maxsize", 0) > 0, (
            "enrich_cards_stream queue is unbounded — a stalled consumer would let workers buffer unlimited messages."
        )

    @staticmethod
    async def _drain_with_timeout(agen_factory, timeout: float = 5.0):
        """Drain an async generator, failing the test (rather than hanging the
        whole suite) if it doesn't complete within `timeout`. Used to detect
        the consumer/worker deadlock regression."""

        async def _drain():
            out = []
            async for msg in agen_factory():
                out.append(msg)
            return out

        try:
            return await asyncio.wait_for(_drain(), timeout=timeout)
        except TimeoutError:
            pytest.fail(
                "enrich_cards_stream deadlocked: a batch worker failed to emit "
                "its terminal message, tasks_remaining never reached 0, and the "
                "consumer's `await queue.get()` blocked forever."
            )

    @pytest.mark.asyncio
    async def test_stream_does_not_deadlock_on_scalar_json_response(self):
        """Regression (first-line defense): a malformed LLM response whose
        top-level JSON is a scalar/null (e.g. `"x"`, `5`, `null`) used to make
        _parse_enrich_response call `.values()` on a non-dict → AttributeError,
        which was NOT in the worker's catch tuple. It escaped the worker, no
        terminal message was enqueued, tasks_remaining never reached 0, and the
        consumer blocked forever. The stream MUST now complete with exactly one
        terminal message for the single batch (scalar JSON parses to an empty
        enrichment list — a clean success — instead of crashing)."""
        from kg.enrich import enrich_cards_stream

        resp = _mock_response('"unexpected-scalar"')
        llm = TrackedLLM(MagicMock(), "u_deadlock_scalar")

        with patch("kg.enrich.sync_retry", return_value=resp):
            results = await self._drain_with_timeout(
                lambda: enrich_cards_stream(llm, [_make_card("hello", "你好")], batch_size=1)
            )

        # tasks_remaining reached 0: the final yielded message accounts for the
        # batch (current == total) and the stream ended without blocking.
        assert results, "stream produced no messages"
        assert results[-1]["status"] in ("running", "error")
        assert results[-1]["current"] == results[-1]["total"] == 1

    @pytest.mark.asyncio
    async def test_stream_does_not_deadlock_on_unexpected_worker_exception(self):
        """Regression (catch-all guarantee): even an exception that bypasses
        _parse_enrich_response's defensive shaping — i.e. a brand-new exception
        type the original narrow catch tuple never anticipated — must still
        produce an error terminal and let the stream complete, rather than
        escaping the worker and deadlocking. Here parsing itself raises an
        unexpected error type."""
        from kg.enrich import enrich_cards_stream

        class WeirdError(Exception):
            """Not in any historical catch tuple."""

        resp = _mock_response('[{"word": "x"}]')
        llm = TrackedLLM(MagicMock(), "u_deadlock_weird")

        with (
            patch("kg.enrich.sync_retry", return_value=resp),
            patch("kg.enrich._parse_enrich_response", side_effect=WeirdError("boom")),
        ):
            results = await self._drain_with_timeout(
                lambda: enrich_cards_stream(llm, [_make_card("hello", "你好")], batch_size=1)
            )

        errors = [r for r in results if r["status"] == "error"]
        assert len(errors) == 1, f"expected one error terminal, got: {results}"
        assert "boom" in errors[0]["detail"]
        assert results[-1]["status"] == "error"

    @pytest.mark.asyncio
    async def test_stream_propagates_quota_exceeded(self):
        from kg.enrich import enrich_cards_stream

        llm = TrackedLLM(MagicMock(), "u_quota")

        headers = {"X-Quota-Fraction": "0.0", "X-Quota-Reset": "3600"}
        with patch("kg.enrich.sync_retry", side_effect=QuotaExceededError(reset_seconds=3600, headers=headers)):
            with pytest.raises(QuotaExceededError) as exc_info:
                async for _ in enrich_cards_stream(llm, [_make_card("hello", "你好")], batch_size=1):
                    pass

        assert exc_info.value.reset_seconds == 3600
        assert exc_info.value.headers == headers

    @pytest.mark.asyncio
    async def test_stream_token_tracking_via_tracked_llm(self):
        """Token tracking now happens inside TrackedLLM.chat(), not in stream consumer."""
        from kg.enrich import enrich_cards_stream

        resp = _mock_response(json.dumps([{"word": "x"}]), prompt_tokens=50, completion_tokens=25)
        llm = TrackedLLM(MagicMock(), "u_test")

        with patch("kg.enrich.sync_retry", return_value=resp):
            cards = [_make_card()]
            msgs = []
            async for msg in enrich_cards_stream(llm, cards):
                msgs.append(msg)
            # Stream should still yield running messages without usage key
            running = [m for m in msgs if m["status"] == "running"]
            assert len(running) >= 1
            assert "usage" not in running[0]

    # Early exit (#2262): 40 single-card batches on 4 workers. When the first
    # batch lands, 3 workers are parked inside the LLM call and the first
    # worker has picked up a 5th batch, so at most max_workers + 1 calls may
    # ever happen; the other 35 batches must be cancelled, not run and billed.
    _EARLY_EXIT_BATCHES = 40
    _EARLY_EXIT_WORKERS = 4

    @pytest.mark.asyncio
    async def test_consumer_exception_close_is_nonblocking_and_cancels_queued(self):
        from kg.enrich import enrich_cards_stream

        resp = _mock_response(json.dumps([{"word": "x"}]))
        llm = TrackedLLM(MagicMock(), "u_early_exit")
        cards = [_make_card(f"w{i}") for i in range(self._EARLY_EXIT_BATCHES)]

        with _GatedSyncRetry(resp, resp) as stub, patch("kg.enrich.sync_retry", stub):
            async with _max_loop_gap() as loop_gap:
                with pytest.raises(_ConsumerKeyError):
                    async with contextlib.aclosing(
                        enrich_cards_stream(llm, cards, batch_size=1, max_workers=self._EARLY_EXIT_WORKERS)
                    ) as stream:
                        async for msg in stream:
                            if msg["status"] == "running":
                                raise _ConsumerKeyError("word")
            calls_at_close = stub.calls
            stub.gate.set()
            await asyncio.sleep(0.3)

        assert loop_gap["max_gap"] < 0.2, (
            f"closing the stream stalled the event loop for {loop_gap['max_gap']:.2f}s "
            f"({calls_at_close} LLM calls had run by then)"
        )
        assert stub.calls <= self._EARLY_EXIT_WORKERS + 1, (
            f"{stub.calls}/{self._EARLY_EXIT_BATCHES} batches called the LLM after the consumer left"
        )
        assert stub.calls < self._EARLY_EXIT_BATCHES

    @pytest.mark.asyncio
    async def test_quota_abort_is_nonblocking_and_cancels_queued(self):
        from kg.enrich import enrich_cards_stream

        resp = _mock_response(json.dumps([{"word": "x"}]))
        llm = TrackedLLM(MagicMock(), "u_quota_abort")
        cards = [_make_card(f"w{i}") for i in range(self._EARLY_EXIT_BATCHES)]

        with (
            _GatedSyncRetry(QuotaExceededError(reset_seconds=60), resp) as stub,
            patch("kg.enrich.sync_retry", stub),
        ):
            async with _max_loop_gap() as loop_gap:
                with pytest.raises(QuotaExceededError) as exc_info:
                    async for _ in enrich_cards_stream(llm, cards, batch_size=1, max_workers=self._EARLY_EXIT_WORKERS):
                        pass
            calls_at_close = stub.calls
            stub.gate.set()
            await asyncio.sleep(0.3)

        assert exc_info.value.reset_seconds == 60
        assert loop_gap["max_gap"] < 0.2, (
            f"quota abort stalled the event loop for {loop_gap['max_gap']:.2f}s "
            f"({calls_at_close} LLM calls had run by then)"
        )
        assert stub.calls <= self._EARLY_EXIT_WORKERS + 1, (
            f"{stub.calls}/{self._EARLY_EXIT_BATCHES} batches called the LLM after the quota abort"
        )

    @pytest.mark.asyncio
    async def test_quota_exhaustion_drains_inflight_batches_before_raising(self):
        """#2243: batches already admitted (and billed) when another batch hits
        real exhaustion must still be yielded before QuotaExceededError."""
        from kg.enrich import enrich_cards_stream

        resp = _mock_response(json.dumps([{"word": "x"}]))
        llm = TrackedLLM(MagicMock(), "u_quota_drain")
        cards = [_make_card(f"w{i}") for i in range(3)]
        seen = []
        started = threading.Barrier(3, timeout=5)
        release = threading.Event()
        order = iter(range(3))
        order_lock = threading.Lock()

        def stub(*_a, **_k):
            with order_lock:
                n = next(order)
            started.wait()  # all three batches are admitted before any outcome
            if n == 0:
                raise QuotaExceededError(reset_seconds=60)
            release.wait(5)
            return resp

        asyncio.get_running_loop().call_later(0.3, release.set)
        with patch("kg.enrich.sync_retry", stub):
            with pytest.raises(QuotaExceededError):
                async for msg in enrich_cards_stream(llm, cards, batch_size=1, max_workers=3):
                    if msg.get("results"):
                        seen.append(msg)

        assert len(seen) == 2, f"admitted batches' results were dropped: {seen}"

    @pytest.mark.asyncio
    async def test_free_user_enforced_fanout_applies_all_batches(self, monkeypatch):
        """#2243: Free user ($0 recorded), enforce_quota=True, 3 concurrent
        batches: in-flight contention waits, no false quota exhaustion."""
        import time

        import kg.quota_service as qs
        from kg.enrich import enrich_cards_stream

        monkeypatch.setattr(qs, "_recorded_usd", lambda _uid: 0.0)
        monkeypatch.setattr(TrackedLLM, "_record_chat", lambda *a, **k: None)
        resp = _mock_response(json.dumps([{"word": "x"}]))

        def create(**_kwargs):
            time.sleep(0.05)
            return resp

        client = MagicMock()
        client.chat.completions.create.side_effect = create
        llm = TrackedLLM(client, "u_free_fanout", enforce_quota=True, is_pro=False)
        cards = [_make_card(f"w{i}") for i in range(3)]

        results = [m async for m in enrich_cards_stream(llm, cards, batch_size=1, max_workers=3) if m.get("results")]

        assert len(results) == 3
        assert client.chat.completions.create.call_count == 3

    @pytest.mark.asyncio
    async def test_early_exit_leaves_no_try_put_timers(self):
        """150 instant batches overflow the 100-slot queue while the consumer
        stalls, so ~50 terminal deliveries keep re-arming ``_try_put`` via
        ``loop.call_later``. Once the stream is closed nothing may re-arm."""
        from kg.enrich import enrich_cards_stream

        loop = asyncio.get_running_loop()
        original_call_later = loop.call_later
        try_put_arms = 0

        def spy_call_later(delay, callback, *args, **kwargs):
            nonlocal try_put_arms
            if getattr(callback, "__name__", "") == "_try_put":
                try_put_arms += 1
            return original_call_later(delay, callback, *args, **kwargs)

        resp = _mock_response(json.dumps([{"word": "x"}]))
        llm = TrackedLLM(MagicMock(), "u_try_put")
        cards = [_make_card(f"w{i}") for i in range(150)]

        with (
            patch("kg.enrich.sync_retry", return_value=resp),
            patch.object(loop, "call_later", spy_call_later),
        ):
            with pytest.raises(_ConsumerKeyError):
                async with contextlib.aclosing(enrich_cards_stream(llm, cards, batch_size=1, max_workers=5)) as stream:
                    async for _ in stream:
                        await asyncio.sleep(0.3)
                        raise _ConsumerKeyError("word")
            arms_at_close = try_put_arms
            await asyncio.sleep(0.1)
            arms_after_wait = try_put_arms

        assert arms_at_close > 0, "precondition: the stalled consumer must overflow the queue"
        assert arms_after_wait == arms_at_close, (
            f"_try_put re-armed {arms_after_wait - arms_at_close} times after the stream closed"
        )


class _MeaningCards:
    def __init__(self, cards):
        self._cards = cards
        self.updates: list[list[tuple[str, dict]]] = []

    def all(self, include_deleted=False, notebook_id=None):
        return list(self._cards)

    def batch_update(self, updates):
        self.updates.append(list(updates))
        return len(updates)

    def bump_enrich_attempts(self, _ids):
        return None


class _RecordingEmbeddings:
    def __init__(self):
        self.removed: list[str] = []

    def remove(self, card_id):
        self.removed.append(card_id)


class _RecordingGraph:
    def __init__(self, fail=False):
        self.queued: list[str] = []
        self._fail = fail

    def add_pending_judge(self, card_id):
        if self._fail:
            raise RuntimeError("judge queue down")
        self.queued.append(card_id)


def _patch_enrich_llm(monkeypatch, stream):
    import kg.deps_quota as deps_quota
    import kg.enrich as enrich_mod
    import kg.llm.providers as providers
    import kg.tracked_llm as tracked_llm

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", stream)
    monkeypatch.setattr(providers, "provider_for", lambda _task: SimpleNamespace(chat_model="m"))
    monkeypatch.setattr(tracked_llm, "TrackedLLM", lambda *_a, **_k: None)
    monkeypatch.setattr(deps_quota, "_is_pro", lambda _user: False)


def _enrich_step(cards, embeddings, graph):
    import logging

    from kg.pipeline_service.steps import _step_enrich

    user = {"id": "u_meaning", "dir": "/tmp/u_meaning", "config": {}}
    return asyncio.run(
        _step_enrich(
            "u_meaning",
            user,
            card_store_factory=lambda _d: cards,
            client_factory=lambda _provider: None,
            logger=logging.getLogger("test_enrich_meaning"),
            embedding_store_factory=lambda _d, **_k: embeddings,
            graph_store_factory=lambda _d, **_k: graph,
        )
    )


def _meaning_card(meaning="旧意思"):
    return SimpleNamespace(
        id="c1", content="evoke", pos=None, note=None, meaning=meaning, enrich_attempts=0, notebook_id="default"
    )


def test_pipeline_meaning_fix_evicts_vector_and_requeues_judging(monkeypatch):
    async def stream(llm, targets, **kwargs):
        yield {"status": "running", "results": [{"word": "evoke", "meaning_fix": "新意思"}]}

    _patch_enrich_llm(monkeypatch, stream)
    cards = _MeaningCards([_meaning_card()])
    embeddings, graph = _RecordingEmbeddings(), _RecordingGraph()

    _enrich_step(cards, embeddings, graph)

    assert cards.updates == [[("c1", {"meaning": "新意思"})]]
    assert embeddings.removed == ["c1"]
    assert graph.queued == ["c1"]


def test_pipeline_unchanged_meaning_fix_neither_evicts_nor_queues(monkeypatch):
    async def stream(llm, targets, **kwargs):
        yield {"status": "running", "results": [{"word": "evoke", "meaning_fix": "旧意思"}]}

    _patch_enrich_llm(monkeypatch, stream)
    embeddings, graph = _RecordingEmbeddings(), _RecordingGraph()

    _enrich_step(_MeaningCards([_meaning_card()]), embeddings, graph)

    assert embeddings.removed == []
    assert graph.queued == []


def test_pipeline_judge_queue_failure_does_not_fail_enrich_step(monkeypatch):
    async def stream(llm, targets, **kwargs):
        yield {"status": "running", "results": [{"word": "evoke", "meaning_fix": "新意思"}]}

    _patch_enrich_llm(monkeypatch, stream)
    cards = _MeaningCards([_meaning_card()])
    embeddings = _RecordingEmbeddings()

    updated = _enrich_step(cards, embeddings, _RecordingGraph(fail=True))

    assert updated == 1
    assert embeddings.removed == ["c1"]


def _two_meaning_fix_stream(monkeypatch):
    async def stream(llm, targets, **kwargs):
        yield {"status": "running", "results": [{"word": "evoke", "meaning_fix": "新意思"}]}
        yield {"status": "running", "results": [{"word": "luminous", "meaning_fix": "新光"}]}

    _patch_enrich_llm(monkeypatch, stream)


def _two_cards():
    return _MeaningCards(
        [
            _meaning_card(),
            SimpleNamespace(
                id="c2",
                content="luminous",
                pos=None,
                note=None,
                meaning="旧光",
                enrich_attempts=0,
                notebook_id="default",
            ),
        ]
    )


def test_pipeline_embedding_store_failure_skips_reembed_and_keeps_batches(monkeypatch):
    _two_meaning_fix_stream(monkeypatch)
    cards = _two_cards()

    import logging

    from kg.pipeline_service.steps import _step_enrich

    user = {"id": "u_meaning", "dir": "/tmp/u_meaning", "config": {}}
    updated = asyncio.run(
        _step_enrich(
            "u_meaning",
            user,
            card_store_factory=lambda _d: cards,
            client_factory=lambda _provider: None,
            logger=logging.getLogger("test_enrich_meaning"),
            embedding_store_factory=_raising_store,
            graph_store_factory=lambda _d, **_k: _RecordingGraph(),
        )
    )

    assert updated == 2
    assert cards.updates == [[("c1", {"meaning": "新意思"})], [("c2", {"meaning": "新光"})]]


def test_pipeline_graph_store_failure_skips_reembed_and_keeps_batches(monkeypatch):
    _two_meaning_fix_stream(monkeypatch)
    cards = _two_cards()

    import logging

    from kg.pipeline_service.steps import _step_enrich

    user = {"id": "u_meaning", "dir": "/tmp/u_meaning", "config": {}}
    updated = asyncio.run(
        _step_enrich(
            "u_meaning",
            user,
            card_store_factory=lambda _d: cards,
            client_factory=lambda _provider: None,
            logger=logging.getLogger("test_enrich_meaning"),
            embedding_store_factory=lambda _d, **_k: _RecordingEmbeddings(),
            graph_store_factory=_raising_store,
        )
    )

    assert updated == 2
    assert cards.updates == [[("c1", {"meaning": "新意思"})], [("c2", {"meaning": "新光"})]]


def _raising_store(*_args, **_kwargs):
    raise RuntimeError("store unavailable")


def test_reembed_best_effort_evicts_even_when_graph_store_fails_to_open():
    """#2957: evict must not depend on opening the graph; a failed graph only skips the judge requeue."""
    from kg.vocab_crud import reembed_meaning_edits_best_effort

    embeddings = _RecordingEmbeddings()

    reembed_meaning_edits_best_effort(
        ["c1"],
        open_embeddings=lambda: embeddings,
        open_graph=_raising_store,
    )

    assert embeddings.removed == ["c1"]
