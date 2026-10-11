"""Tests for the in-process daily log-retention scheduler (#2091)."""

from __future__ import annotations

import asyncio
import inspect
import logging
import threading
import time
from datetime import UTC, datetime, timedelta, timezone

import pytest

from kg.log_retention_scheduler import LogRetentionScheduler, next_run_at

# The SOP's "local 04:17" is Asia/Taipei (UTC+8, no DST), independent of the container's TZ.
TAIPEI = timezone(timedelta(hours=8), "Asia/Taipei")
MAX_SLICE_SECONDS = 300.0


def _taipei(*args: int) -> datetime:
    return datetime(*args, tzinfo=TAIPEI)


class _FakeWallClock:
    """A wall clock that the injected sleep advances, as a real clock would."""

    def __init__(self, now: datetime) -> None:
        self.now = now
        self.sleeps: list[float] = []

    def __call__(self) -> datetime:
        return self.now

    async def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += timedelta(seconds=seconds)


class _StopForever(Exception):
    """Raised by the injected sleep to end run_forever deterministically."""


def test_next_run_at_returns_today_0417_taipei_when_before_target():
    assert next_run_at(_taipei(2026, 10, 11, 4, 16, 30)) == _taipei(2026, 10, 11, 4, 17)


def test_next_run_at_rolls_to_tomorrow_at_or_after_target():
    assert next_run_at(_taipei(2026, 10, 11, 4, 17, 0)) == _taipei(2026, 10, 12, 4, 17)
    assert next_run_at(_taipei(2026, 10, 11, 23, 0, 0)) == _taipei(2026, 10, 12, 4, 17)


def test_next_run_at_pins_0417_taipei_for_a_utc_instant():
    # 20:00 UTC on 2026-10-11 is 04:00 Taipei on 2026-10-12, so the next slot is
    # 04:17 Taipei that day, i.e. 20:17 UTC on 2026-10-11.
    now = datetime(2026, 10, 11, 20, 0, tzinfo=UTC)

    assert next_run_at(now) == datetime(2026, 10, 11, 20, 17, tzinfo=UTC)


def test_next_run_at_rejects_a_naive_datetime():
    # A naive value would be read in the host's zone, which is UTC in the container.
    with pytest.raises(ValueError):
        next_run_at(datetime(2026, 10, 11, 4, 16, 30))


def test_default_clock_reads_taipei_wall_time():
    # The container runs with TZ unset; the default clock must still be Taipei.
    clock = inspect.signature(LogRetentionScheduler.__init__).parameters["clock"].default

    assert clock().utcoffset() == timedelta(hours=8)


def test_run_next_sleeps_until_target_and_runs_run_all_exactly_once():
    wall = _FakeWallClock(_taipei(2026, 10, 11, 4, 16, 0))
    calls: list[int] = []

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        calls.append(1)
        return {}

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=wall, sleep_fn=wall.sleep)

    asyncio.run(scheduler.run_next())

    assert wall.sleeps == [60.0]
    assert calls == [1]


def test_run_next_waits_in_bounded_slices():
    # 4h17m to the slot. One long sleep is computed once and would wake late after a host sleep.
    wall = _FakeWallClock(_taipei(2026, 10, 11, 0, 0, 0))
    scheduler = LogRetentionScheduler(run_all_fn=lambda **_: {}, clock=wall, sleep_fn=wall.sleep)

    asyncio.run(scheduler.run_next())

    assert sum(wall.sleeps) == pytest.approx(4 * 3600 + 17 * 60)
    assert max(wall.sleeps) <= MAX_SLICE_SECONDS


def test_run_next_rechecks_wall_clock_after_a_clock_step_back():
    # An NTP step back by an hour mid-wait must not fire the run an hour early.
    wall = _FakeWallClock(_taipei(2026, 10, 11, 4, 16, 0))
    target = _taipei(2026, 10, 11, 4, 17)
    fired_at: list[datetime] = []
    stepped = False

    async def _sleep(seconds: float) -> None:
        nonlocal stepped
        await wall.sleep(seconds)
        if not stepped:
            stepped = True
            wall.now -= timedelta(hours=1)

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        fired_at.append(wall.now)
        return {}

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=wall, sleep_fn=_sleep)

    asyncio.run(scheduler.run_next())

    assert fired_at == [target]


def test_run_all_executes_off_the_event_loop_thread():
    wall = _FakeWallClock(_taipei(2026, 10, 11, 4, 16, 0))
    seen: list[int] = []

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        seen.append(threading.get_ident())
        return {}

    async def _drive() -> None:
        loop_thread = threading.get_ident()
        scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=wall, sleep_fn=wall.sleep)
        await scheduler.run_next()
        assert seen and seen[0] != loop_thread

    asyncio.run(_drive())


def test_run_failure_is_logged_and_does_not_stop_the_scheduler(caplog):
    wall = _FakeWallClock(_taipei(2026, 10, 11, 4, 16, 0))

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        raise RuntimeError("disk full")

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=wall, sleep_fn=wall.sleep)

    with caplog.at_level(logging.ERROR, logger="kg.log_retention_scheduler"):
        asyncio.run(scheduler.run_next())

    assert any("log retention run failed" in r.message for r in caplog.records)


def test_run_next_sleeps_a_full_day_when_called_exactly_at_target():
    wall = _FakeWallClock(_taipei(2026, 10, 11, 4, 17, 0))
    scheduler = LogRetentionScheduler(run_all_fn=lambda **_: {}, clock=wall, sleep_fn=wall.sleep)

    asyncio.run(scheduler.run_next())

    assert sum(wall.sleeps) == pytest.approx(24 * 3600.0)
    assert max(wall.sleeps) <= MAX_SLICE_SECONDS


def test_run_forever_keeps_scheduling_after_a_failed_run():
    wall = _FakeWallClock(_taipei(2026, 10, 11, 4, 16, 0))
    calls: list[int] = []

    async def _sleep(seconds: float) -> None:
        if len(calls) >= 2:
            raise _StopForever
        await wall.sleep(seconds)

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("disk full")
        return {}

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=wall, sleep_fn=_sleep)

    with pytest.raises(_StopForever):
        asyncio.run(scheduler.run_forever())

    assert len(calls) == 2


def test_run_forever_survives_a_report_that_cannot_be_serialised(caplog):
    # A circular report makes json.dumps raise ValueError after the prune has
    # already committed. That must be logged, not allowed to end the loop.
    wall = _FakeWallClock(_taipei(2026, 10, 11, 4, 16, 0))
    calls: list[int] = []

    async def _sleep(seconds: float) -> None:
        if len(calls) >= 2:
            raise _StopForever
        await wall.sleep(seconds)

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        calls.append(1)
        cyclic: dict = {"deleted": 1}
        cyclic["self"] = cyclic
        return {"pipeline_log": cyclic}

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=wall, sleep_fn=_sleep)

    with caplog.at_level(logging.ERROR, logger="kg.log_retention_scheduler"), pytest.raises(_StopForever):
        asyncio.run(scheduler.run_forever())

    assert len(calls) == 2
    assert any("could not be serialised" in r.message for r in caplog.records)


def test_run_logs_a_non_json_value_instead_of_failing(caplog):
    wall = _FakeWallClock(_taipei(2026, 10, 11, 4, 16, 0))

    def _run_all(*, should_stop) -> dict[str, dict[str, object]]:
        return {"token_usage": {"deleted": 2, "days": 90, "cutoff": datetime(2026, 7, 13, 4, 17)}}

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=wall, sleep_fn=wall.sleep)

    with caplog.at_level(logging.INFO, logger="kg.log_retention_scheduler"):
        asyncio.run(scheduler.run_next())

    assert any(r.message.startswith("log retention run:") and '"deleted": 2' in r.message for r in caplog.records)


def test_cancelling_a_run_stops_it_at_the_next_batch_boundary():
    # Lifespan teardown cancels the scheduler and then waits for the worker
    # thread before releasing the worker lock. A run over a large backlog must
    # observe the stop request and end, instead of draining the whole backlog.
    from kg.log_retention import RetentionStopped

    wall = _FakeWallClock(_taipei(2026, 10, 11, 4, 16, 0))
    started = threading.Event()
    stop_seen = threading.Event()

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        started.set()
        deadline = time.monotonic() + 5
        while not should_stop() and time.monotonic() < deadline:
            time.sleep(0.005)
        if should_stop():
            stop_seen.set()
            raise RetentionStopped("stop requested")
        return {}

    async def _drive() -> None:
        scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=wall, sleep_fn=wall.sleep)
        task = asyncio.create_task(scheduler.run_next())
        assert await asyncio.to_thread(started.wait, 5)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(_drive())
    assert stop_seen.is_set()
