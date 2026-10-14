"""In-flight quota reservation — defends the gap between pre-flight check
and post-call `record()`.

Root cause: `check_quota` reads `used` from already-recorded token usage,
but quota is checked BEFORE the LLM call and tokens are recorded AFTER it.
Concurrent same-user requests (multi-tab translate, or a single pipeline
run fanning out 5-way enrich batches via ThreadPoolExecutor) all pass the
gate before the first `record()` lands → unbounded over-spend.

Fix: an in-memory per-user reservation registry. A caller optimistically
reserves an estimated cost before the call; the gate counts reservations
on top of recorded usage; the reservation is released once the real cost
is recorded.

DB isolation mirrors test_quota_service.py: patch `_get_conn`/`_lock`.
"""

from __future__ import annotations

import asyncio
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

import pytest

import kg.quota_service as qs


@pytest.fixture
def mock_db(tmp_path, monkeypatch):
    import kg.llm_error_log as llm_error_log
    import kg.token_tracker as token_tracker

    monkeypatch.setattr(token_tracker, "DATA_DIR", tmp_path)
    monkeypatch.setattr(token_tracker, "DB_PATH", tmp_path / "token_usage.db")
    monkeypatch.setattr(llm_error_log, "DATA_DIR", tmp_path)
    monkeypatch.setattr(llm_error_log, "DB_PATH", tmp_path / "llm_errors.db")
    token_tracker.reset()
    llm_error_log.reset()

    conn = sqlite3.connect(":memory:", check_same_thread=False)
    conn.execute(
        """
        CREATE TABLE token_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            call_type TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            provider TEXT,
            model TEXT
        )
        """
    )
    conn.commit()
    lock = threading.Lock()
    with patch("kg.quota_service._get_conn", return_value=conn), patch("kg.quota_service._lock", lock):
        yield conn

    token_tracker.reset()
    llm_error_log.reset()
    conn.close()

    assert token_tracker._conn is None, "token tracker connection leaked past fixture"
    assert llm_error_log._conn is None, "LLM error connection leaked past fixture"


@pytest.fixture(autouse=True)
def _stable_limits_and_clean_reservations():
    qs.configure_limits(pro=0.30, free=0.03)
    qs.clear_reservations()
    yield
    qs.clear_reservations()
    qs.configure_limits(pro=0.30, free=0.03)


# ── reservation primitive ─────────────────────────────────────────


def test_reservation_counts_against_quota(mock_db):
    """A reservation alone (no recorded usage) makes the gate see usage."""
    # Free limit $0.03. Reserve $0.02 → still under, not exceeded.
    with qs.reserve("u1", 0.02):
        q = qs.check_quota("u1", "translate", is_pro=False)
        assert q["exceeded"] is False
        assert q["fraction"] == pytest.approx(1.0 / 3.0, abs=0.01)


def test_reservation_released_on_context_exit(mock_db):
    """Once the with-block exits, the reservation no longer counts."""
    with qs.reserve("u1", 0.02):
        pass
    q = qs.check_quota("u1", "translate", is_pro=False)
    assert q["exceeded"] is False
    assert q["fraction"] == pytest.approx(1.0, abs=0.001)


def test_reservation_released_even_on_exception(mock_db):
    """A handler failure must not leak the reservation forever."""
    with pytest.raises(RuntimeError):
        with qs.reserve("u1", 0.02):
            raise RuntimeError("boom")
    q = qs.check_quota("u1", "translate", is_pro=False)
    assert q["fraction"] == pytest.approx(1.0, abs=0.001)


def test_stacked_reservations_block_when_sum_exceeds_limit(mock_db):
    """Two concurrent in-flight reservations whose sum tops the limit
    must make a third check report exceeded — the core defense."""
    with qs.reserve("u1", 0.02), qs.reserve("u1", 0.02):
        q = qs.check_quota("u1", "translate", is_pro=False)
        assert q["exceeded"] is True


# ── concurrency repro ─────────────────────────────────────────────


def test_concurrent_translate_requests_overspend_without_reservation(mock_db):
    """REPRODUCTION: without reservation, N concurrent same-user requests
    all see used=0 and pass the gate, even though each costs $0.012 and
    the free limit is $0.03 → only ~2 should be allowed.
    """
    passed = []

    def request_without_reservation():
        # Mirrors the OLD gate: check recorded usage only.
        q = qs.check_quota("u1", "translate", is_pro=False)
        if not q["exceeded"]:
            passed.append(True)
        # record() happens "later" — simulate the post-call lag by not
        # recording at all during the burst.

    with ThreadPoolExecutor(max_workers=10) as ex:
        for _ in range(10):
            ex.submit(request_without_reservation)

    # All 10 slip through — the bug. Free budget = $0.03 / $0.012 ≈ 2.
    assert len(passed) == 10, "expected the unguarded gate to leak all requests"


def test_concurrent_translate_requests_queue_behind_reservation(mock_db):
    """A burst of 10 concurrent same-user TrackedLLM calls through the
    production gate (`reserve(enforce=True)`) never has more than the Free
    budget in flight (2), yet every call is eventually admitted: in-flight-only
    contention waits instead of raising a false quota exhaustion (#2243)."""
    from kg.tracked_llm import TrackedLLM

    burst = 10
    assert qs.FREE_DAILY_LIMIT_USD == pytest.approx(0.03)
    assert qs.estimate_call_cost("translate") == pytest.approx(0.012)

    guard = threading.Lock()
    state = {"now": 0, "peak": 0, "done": 0}

    class _Client:
        class chat:  # noqa: N801
            class completions:  # noqa: N801
                @staticmethod
                def create(**_kwargs):
                    with guard:
                        state["now"] += 1
                        state["peak"] = max(state["peak"], state["now"])
                    time.sleep(0.02)
                    with guard:
                        state["now"] -= 1
                        state["done"] += 1
                    return _FakeResp(0, 0)

    def request():
        TrackedLLM(_Client(), "u1", enforce_quota=True, is_pro=False).chat("translate")

    with ThreadPoolExecutor(max_workers=burst) as ex:
        for f in [ex.submit(request) for _ in range(burst)]:
            f.result(timeout=30)

    assert state["done"] == burst
    assert state["peak"] <= 2
    assert qs._reserved_usd("u1") == 0.0


def test_reserve_waits_for_inflight_release_then_admits(mock_db):
    admitted = threading.Event()

    def contender():
        with qs.reserve("u1", 0.012, enforce=True, is_pro=False):
            admitted.set()

    with qs.reserve("u1", 0.012, enforce=True, is_pro=False):
        with qs.reserve("u1", 0.012, enforce=True, is_pro=False):
            t = threading.Thread(target=contender)
            t.start()
            assert not admitted.wait(0.2), "must wait while two reservations are in flight"
    t.join(timeout=5)
    assert admitted.is_set()
    assert qs._reserved_usd("u1") == 0.0


def test_reserve_real_exhaustion_raises_without_waiting(mock_db, monkeypatch):
    from kg.exceptions import QuotaExceededError

    # Real exhaustion is recorded >= limit (the gate's rule), not recorded + estimate > limit.
    monkeypatch.setattr(qs, "_recorded_usd", lambda _uid: 0.03)
    started = time.monotonic()
    with pytest.raises(QuotaExceededError):
        with qs.reserve("u1", 0.012, enforce=True, is_pro=False):
            pass
    assert time.monotonic() - started < 1.0


def test_reserve_admits_below_limit_when_nothing_in_flight(mock_db, monkeypatch):
    """#3654: Free limit 0.03, recorded 0.02, nothing in flight. The gate reports
    budget left, so admission must admit the call even though recorded + estimate
    crosses the limit. Rejecting here cut users off early with a fake 24h reset."""
    monkeypatch.setattr(qs, "_recorded_usd", lambda _uid: 0.02)
    assert qs.check_and_get_quota("u1", "translate", is_pro=False)["exceeded"] is False

    with qs.reserve("u1", qs.ESTIMATED_CALL_COST_USD, enforce=True, is_pro=False):
        assert qs._reserved_usd("u1") == pytest.approx(qs.ESTIMATED_CALL_COST_USD)
    assert qs._reserved_usd("u1") == 0.0


def test_reserve_real_exhaustion_reports_real_reset_and_gate_fraction(mock_db, monkeypatch):
    """#3654: a 429 from real exhaustion must carry the real reset (from the oldest
    recorded row, via _reset_seconds) and the gate's fraction, never the constants
    fraction 0.0 / reset 86400."""
    from datetime import UTC, datetime, timedelta

    from kg.exceptions import QuotaExceededError

    one_hour_ago = (datetime.now(UTC) - timedelta(hours=1)).isoformat()
    mock_db.execute(
        "INSERT INTO token_usage (user_id, call_type, input_tokens, output_tokens, created_at, provider, model)"
        " VALUES (?, ?, ?, ?, ?, ?, ?)",
        ("u1", "translate", 1_000_000, 0, one_hour_ago, None, None),
    )
    mock_db.commit()
    monkeypatch.setattr(qs, "_recorded_usd", lambda _uid: 0.03)

    gate = qs.check_and_get_quota("u1", "translate", is_pro=False)
    expected_reset = qs._reset_seconds("u1", 0.03, 0.03)
    assert expected_reset < qs._ROLLING_WINDOW_SECONDS

    with pytest.raises(QuotaExceededError) as exc_info:
        with qs.reserve("u1", qs.ESTIMATED_CALL_COST_USD, enforce=True, is_pro=False):
            pass
    headers = exc_info.value.headers
    assert headers["X-Quota-Reset"] == str(expected_reset)
    assert float(headers["X-Quota-Fraction"]) == gate["fraction"]


def test_reserve_inflight_wait_is_bounded(mock_db, monkeypatch):
    from kg.exceptions import QuotaExceededError

    monkeypatch.setattr(qs, "_ADMISSION_WAIT_SECONDS", 0.1)
    with qs.reserve("u1", 0.012, enforce=True, is_pro=False):
        with qs.reserve("u1", 0.012, enforce=True, is_pro=False):
            with pytest.raises(QuotaExceededError):
                with qs.reserve("u1", 0.012, enforce=True, is_pro=False):
                    pass
    assert qs._reserved_usd("u1") == 0.0


def test_third_concurrent_async_chat_is_not_rejected(mock_db):
    """Free user's 3rd concurrent async call (translate path) waits, no 429."""
    from kg.tracked_llm import TrackedLLM

    state = {"now": 0, "peak": 0}

    class _Client:
        class chat:  # noqa: N801
            class completions:  # noqa: N801
                @staticmethod
                async def create(**_kwargs):
                    state["now"] += 1
                    state["peak"] = max(state["peak"], state["now"])
                    await asyncio.sleep(0.02)
                    state["now"] -= 1
                    return _FakeResp(0, 0)

    async def main():
        llm = TrackedLLM(_Client(), "u1", enforce_quota=True, is_pro=False)
        return await asyncio.gather(*[llm.chat_async("translate") for _ in range(4)])

    assert len(asyncio.run(main())) == 4
    assert state["peak"] <= 2
    assert qs._reserved_usd("u1") == 0.0


# ── TrackedLLM integration ────────────────────────────────────────


class _FakeUsage:
    def __init__(self, prompt: int, completion: int) -> None:
        self.prompt_tokens = prompt
        self.completion_tokens = completion
        self.total_tokens = prompt + completion


class _FakeResp:
    def __init__(self, prompt: int, completion: int) -> None:
        self.usage = _FakeUsage(prompt, completion)


def test_tracked_llm_holds_reservation_during_call(mock_db):
    """While a TrackedLLM call is in flight, the user's reserved cost is
    non-zero — so a concurrent gate check sees the in-flight spend.
    """
    from kg.tracked_llm import TrackedLLM

    observed = {}

    class _SlowClient:
        class chat:  # noqa: N801
            class completions:  # noqa: N801
                @staticmethod
                def create(**_kwargs):
                    # Mid-call: the reservation must already be visible.
                    observed["reserved_mid_call"] = qs._reserved_usd("u1")
                    return _FakeResp(100, 50)

    llm = TrackedLLM(_SlowClient(), "u1")
    llm.chat("translate")

    assert observed["reserved_mid_call"] == pytest.approx(qs.ESTIMATED_CALL_COST_USD)
    # After the call returns, the reservation is released.
    assert qs._reserved_usd("u1") == 0.0


def test_tracked_llm_releases_reservation_on_call_failure(mock_db):
    """A failing LLM call must not leak the reservation."""
    from kg.tracked_llm import TrackedLLM

    class _BoomClient:
        class chat:  # noqa: N801
            class completions:  # noqa: N801
                @staticmethod
                def create(**_kwargs):
                    raise RuntimeError("api down")

    llm = TrackedLLM(_BoomClient(), "u1")
    with pytest.raises(RuntimeError, match="api down"):
        llm.chat("translate")
    assert qs._reserved_usd("u1") == 0.0


def test_tracked_llm_enforced_quota_blocks_before_call(mock_db, monkeypatch):
    from kg.exceptions import QuotaExceededError
    from kg.tracked_llm import TrackedLLM

    qs.configure_limits(pro=0.30, free=0.001)
    monkeypatch.setattr(qs, "_recorded_usd", lambda _uid: 0.001)

    class _Client:
        called = False

        class chat:  # noqa: N801
            class completions:  # noqa: N801
                @staticmethod
                def create(**_kwargs):
                    _Client.called = True
                    return _FakeResp(100, 50)

    llm = TrackedLLM(_Client(), "u1", enforce_quota=True, is_pro=False)

    with pytest.raises(QuotaExceededError):
        llm.chat("translate")
    assert _Client.called is False
    assert qs._reserved_usd("u1") == 0.0


def test_enforced_reservation_reads_recorded_usage_outside_reservation_lock(mock_db, monkeypatch):
    """Admission must not hold reservation_lock while reading SQLite usage.

    token_tracker.record() takes the DB lock first and then releases the
    reservation on context exit. Holding reservation_lock while waiting on the
    DB lock creates the reverse order and can deadlock under load.
    """
    calls = []

    def recorded(user_id: str) -> float:
        calls.append(user_id)
        assert qs._reservation_lock.locked() is False
        return 0.0

    monkeypatch.setattr(qs, "_recorded_usd", recorded)

    with qs.reserve("u1", 0.001, enforce=True, is_pro=False):
        assert qs._reserved_usd("u1") == pytest.approx(0.001)

    assert calls == ["u1"]


def test_enforced_reservation_retries_if_inflight_finishes_during_recorded_read(mock_db, monkeypatch):
    """If a reservation is released while recorded usage is being read, retry
    the DB read so admission does not miss both the old reservation and the
    newly recorded usage."""
    from kg.exceptions import QuotaExceededError

    qs.configure_limits(pro=0.30, free=0.021)
    with qs._reservation_lock:
        qs._reservations[999_001] = ("u1", 0.02)
        qs._reservation_version += 1

    calls = 0

    def recorded(user_id: str) -> float:
        nonlocal calls
        assert user_id == "u1"
        calls += 1
        if calls == 1:
            with qs._reservation_lock:
                qs._reservations.pop(999_001, None)
                qs._reservation_version += 1
            return 0.0
        return 0.021

    monkeypatch.setattr(qs, "_recorded_usd", recorded)

    with pytest.raises(QuotaExceededError):
        with qs.reserve("u1", 0.005, enforce=True, is_pro=False):
            pass

    assert calls == 2
    assert qs._reserved_usd("u1") == 0.0


def test_enforced_reservation_retries_on_equal_sum_reservation_swap(mock_db, monkeypatch):
    """Reservation total can stay unchanged while composition changes.

    Example: A finishes and moves from reservation to recorded usage while B
    adds an equal reservation. Admission must notice the version change and
    re-read recorded usage, not trust the unchanged reserved total.
    """
    from kg.exceptions import QuotaExceededError

    qs.configure_limits(pro=0.30, free=0.04)
    with qs._reservation_lock:
        qs._reservations[999_101] = ("u1", 0.02)
        qs._reservation_version += 1

    calls = 0

    def recorded(user_id: str) -> float:
        nonlocal calls
        assert user_id == "u1"
        calls += 1
        if calls == 1:
            with qs._reservation_lock:
                qs._reservations.pop(999_101, None)
                qs._reservations[999_102] = ("u1", 0.02)
                qs._reservation_version += 2
            return 0.0
        return 0.02

    monkeypatch.setattr(qs, "_recorded_usd", recorded)
    monkeypatch.setattr(qs, "_ADMISSION_WAIT_SECONDS", 0.0)

    with pytest.raises(QuotaExceededError):
        with qs.reserve("u1", 0.015, enforce=True, is_pro=False):
            pass

    assert calls == 2
    with qs._reservation_lock:
        qs._reservations.pop(999_102, None)
        qs._reservation_version += 1


def test_tracked_llm_pipeline_burst_blocks_via_gate(mock_db):
    """Simulated pipeline enrich fan-out: 5 concurrent TrackedLLM calls for
    a Free user. The reservation makes the gate observe in-flight spend, so
    a check during the burst reports the user as quota-exceeded.

    Workers stay inside the call until the gate has been read. The barrier
    alone releases them together with the main thread, so they could finish
    and drop their reservations before the read.
    """
    from kg.tracked_llm import TrackedLLM

    barrier = threading.Barrier(6)  # 5 workers + main thread
    gate_read = threading.Event()
    gate_seen_exceeded = []

    class _BlockingClient:
        class chat:  # noqa: N801
            class completions:  # noqa: N801
                @staticmethod
                def create(**_kwargs):
                    barrier.wait(timeout=5)  # all 5 reservations held at once
                    assert gate_read.wait(timeout=5), "gate was never read"
                    return _FakeResp(100, 50)

    def worker():
        TrackedLLM(_BlockingClient(), "u1").chat("translate")

    with ThreadPoolExecutor(max_workers=5) as ex:
        futs = [ex.submit(worker) for _ in range(5)]
        try:
            barrier.wait(timeout=5)  # all 5 calls now in flight, reservations held
            # 5 * $0.012 = $0.06 reserved > Free $0.03 → gate must block now.
            q = qs.check_quota("u1", "translate", is_pro=False)
            gate_seen_exceeded.append(q["exceeded"])
        finally:
            gate_read.set()
        for f in futs:
            f.result()

    assert gate_seen_exceeded == [True], "gate must see in-flight burst as over-quota"


def test_areserve_times_out_when_in_flight_blocks(mock_db, monkeypatch):
    """#3728: the async admission wait is bounded. A blocked areserve must raise
    QuotaExceededError with X-Quota-Reset once _ADMISSION_WAIT_SECONDS elapses,
    instead of polling forever and pinning the event loop task."""
    from kg.exceptions import QuotaExceededError

    monkeypatch.setattr(qs, "_ADMISSION_WAIT_SECONDS", 0.1)
    monkeypatch.setattr(qs, "_ADMISSION_POLL_SECONDS", 0.01)

    async def blocked():
        async with qs.areserve("u1", 0.02, enforce=True, is_pro=False):
            pass

    async def main():
        # Holding the whole Free budget keeps the second call blocked by in-flight spend.
        async with qs.areserve("u1", 0.03, enforce=True, is_pro=False):
            try:
                await asyncio.wait_for(blocked(), 2)
            except QuotaExceededError as exc:
                return exc
        raise AssertionError("second areserve was admitted while in-flight budget was full")

    err = asyncio.run(main())
    assert err.headers["X-Quota-Fraction"] == "0.0"
    assert "X-Quota-Reset" in err.headers
    assert qs._reserved_usd("u1") == 0.0
