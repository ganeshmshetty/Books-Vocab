"""Tests for the in-process daily log-retention scheduler (#2091)."""

from __future__ import annotations

import asyncio
import logging
import threading
from datetime import datetime

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

    def _run_all() -> dict[str, dict[str, int]]:
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

    def _run_all() -> dict[str, dict[str, int]]:
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

    def _run_all() -> dict[str, dict[str, int]]:
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

    scheduler = LogRetentionScheduler(run_all_fn=lambda: {}, clock=lambda: at_target, sleep_fn=_sleep)

    asyncio.run(scheduler.run_next())

    assert sleeps == [24 * 3600.0]
