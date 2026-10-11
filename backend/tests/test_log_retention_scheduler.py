"""Tests for the in-process daily log-retention scheduler (#2091)."""

from __future__ import annotations

import asyncio
import logging
import threading
import time
from datetime import datetime

import pytest

from kg.log_retention_scheduler import LogRetentionScheduler, next_run_at


def test_next_run_at_returns_today_0417_when_before_target():
    now = datetime(2026, 10, 11, 4, 16, 30)

    assert next_run_at(now) == datetime(2026, 10, 11, 4, 17)


def test_next_run_at_rolls_to_tomorrow_at_or_after_target():
    assert next_run_at(datetime(2026, 10, 11, 4, 17, 0)) == datetime(2026, 10, 12, 4, 17)
    assert next_run_at(datetime(2026, 10, 11, 23, 0, 0)) == datetime(2026, 10, 12, 4, 17)


def test_run_next_sleeps_until_target_and_runs_run_all_exactly_once():
    now = datetime(2026, 10, 11, 4, 16, 0)
    sleeps: list[float] = []
    calls: list[int] = []

    async def _sleep(seconds: float) -> None:
        sleeps.append(seconds)

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        calls.append(1)
        return {}

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=lambda: now, sleep_fn=_sleep)

    asyncio.run(scheduler.run_next())

    assert sleeps == [60.0]
    assert calls == [1]


def test_run_all_executes_off_the_event_loop_thread():
    now = datetime(2026, 10, 11, 4, 16, 0)
    seen: list[int] = []

    async def _sleep(seconds: float) -> None:
        return None

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        seen.append(threading.get_ident())
        return {}

    async def _drive() -> None:
        loop_thread = threading.get_ident()
        scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=lambda: now, sleep_fn=_sleep)
        await scheduler.run_next()
        assert seen and seen[0] != loop_thread

    asyncio.run(_drive())


def test_run_failure_is_logged_and_does_not_stop_the_scheduler(caplog):
    now = datetime(2026, 10, 11, 4, 16, 0)

    async def _sleep(seconds: float) -> None:
        return None

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        raise RuntimeError("disk full")

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=lambda: now, sleep_fn=_sleep)

    with caplog.at_level(logging.ERROR, logger="kg.log_retention_scheduler"):
        asyncio.run(scheduler.run_next())

    assert any("log retention run failed" in r.message for r in caplog.records)


def test_run_next_sleeps_a_full_day_when_called_exactly_at_target():
    at_target = datetime(2026, 10, 11, 4, 17, 0)
    sleeps: list[float] = []

    async def _sleep(seconds: float) -> None:
        sleeps.append(seconds)

    scheduler = LogRetentionScheduler(run_all_fn=lambda **_: {}, clock=lambda: at_target, sleep_fn=_sleep)

    asyncio.run(scheduler.run_next())

    assert sleeps == [24 * 3600.0]


class _StopForever(Exception):
    """Raised by the injected sleep to end run_forever deterministically."""


def test_run_forever_keeps_scheduling_after_a_failed_run():
    now = datetime(2026, 10, 11, 4, 16, 0)
    sleeps = 0
    calls: list[int] = []

    async def _sleep(seconds: float) -> None:
        nonlocal sleeps
        sleeps += 1
        if sleeps == 3:
            raise _StopForever

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("disk full")
        return {}

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=lambda: now, sleep_fn=_sleep)

    with pytest.raises(_StopForever):
        asyncio.run(scheduler.run_forever())

    assert len(calls) == 2


def test_run_forever_survives_a_report_that_cannot_be_serialised(caplog):
    # A circular report makes json.dumps raise ValueError after the prune has
    # already committed. That must be logged, not allowed to end the loop.
    now = datetime(2026, 10, 11, 4, 16, 0)
    sleeps = 0
    calls: list[int] = []

    async def _sleep(seconds: float) -> None:
        nonlocal sleeps
        sleeps += 1
        if sleeps == 3:
            raise _StopForever

    def _run_all(*, should_stop) -> dict[str, dict[str, int]]:
        calls.append(1)
        cyclic: dict = {"deleted": 1}
        cyclic["self"] = cyclic
        return {"pipeline_log": cyclic}

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=lambda: now, sleep_fn=_sleep)

    with caplog.at_level(logging.ERROR, logger="kg.log_retention_scheduler"), pytest.raises(_StopForever):
        asyncio.run(scheduler.run_forever())

    assert len(calls) == 2
    assert any("could not be serialised" in r.message for r in caplog.records)


def test_run_logs_a_non_json_value_instead_of_failing(caplog):
    now = datetime(2026, 10, 11, 4, 16, 0)

    async def _sleep(seconds: float) -> None:
        return None

    def _run_all(*, should_stop) -> dict[str, dict[str, object]]:
        return {"token_usage": {"deleted": 2, "days": 90, "cutoff": datetime(2026, 7, 13, 4, 17)}}

    scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=lambda: now, sleep_fn=_sleep)

    with caplog.at_level(logging.INFO, logger="kg.log_retention_scheduler"):
        asyncio.run(scheduler.run_next())

    assert any(r.message.startswith("log retention run:") and '"deleted": 2' in r.message for r in caplog.records)


def test_cancelling_a_run_stops_it_at_the_next_batch_boundary():
    # Lifespan teardown cancels the scheduler and then waits for the worker
    # thread before releasing the worker lock. A run over a large backlog must
    # observe the stop request and end, instead of draining the whole backlog.
    from kg.log_retention import RetentionStopped

    now = datetime(2026, 10, 11, 4, 16, 0)
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

    async def _sleep(seconds: float) -> None:
        return None

    async def _drive() -> None:
        scheduler = LogRetentionScheduler(run_all_fn=_run_all, clock=lambda: now, sleep_fn=_sleep)
        task = asyncio.create_task(scheduler.run_next())
        assert await asyncio.to_thread(started.wait, 5)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(_drive())
    assert stop_seen.is_set()
