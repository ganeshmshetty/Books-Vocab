"""In-process daily scheduler for log retention (#2091).

The backend process owns the schedule: the lifespan starts exactly one
``LogRetentionScheduler.run_forever`` task after the single-worker lock is
held, and cancels it before the lock is released. No host-level launchd or
cron job is involved.
"""

from __future__ import annotations

import asyncio
import json
import logging
import threading
from collections.abc import Callable
from datetime import datetime, time, timedelta, timezone
from typing import Any

from .log_retention import RetentionStopped, run_all

_logger = logging.getLogger(__name__)

# The SOP's "local 04:17" is Asia/Taipei. The container runs with TZ unset (UTC),
# so the zone is pinned rather than read from the host. Taiwan has observed UTC+8
# with no DST since 1979: a fixed offset is exact and needs no tz database in the
# python:3.13-slim runtime image.
RETENTION_TZ = timezone(timedelta(hours=8), "Asia/Taipei")
RETENTION_RUN_AT = time(4, 17)
# Longest single sleep. A host sleep or a clock step moves the wall clock relative
# to a monotonic sleep, so the wait re-reads the wall clock after every slice.
MAX_SLEEP_SECONDS = 300.0


def taipei_now() -> datetime:
    return datetime.now(RETENTION_TZ)


def next_run_at(now: datetime) -> datetime:
    """Return the next Taipei wall-clock ``RETENTION_RUN_AT`` strictly after ``now``.

    ``now`` must be timezone-aware: a naive value would be read in the host's zone.
    """
    if now.tzinfo is None:
        raise ValueError("next_run_at needs a timezone-aware datetime")
    local = now.astimezone(RETENTION_TZ)
    target = datetime.combine(local.date(), RETENTION_RUN_AT, tzinfo=RETENTION_TZ)
    if target <= local:
        target += timedelta(days=1)
    return target


class LogRetentionScheduler:
    def __init__(
        self,
        *,
        run_all_fn: Callable[..., dict[str, dict[str, int]]] = run_all,
        clock: Callable[[], datetime] = taipei_now,
        sleep_fn: Callable[[float], Any] = asyncio.sleep,
        logger: logging.Logger | Any = _logger,
    ) -> None:
        self._run_all_fn = run_all_fn
        self._clock = clock
        self._sleep_fn = sleep_fn
        self._logger = logger
        # Set on cancellation so an in-flight run stops at its next batch boundary.
        self._stop = threading.Event()

    async def run_next(self) -> None:
        """Wait until the next scheduled slot, then run the pruners once."""
        target = next_run_at(self._clock())
        await self._wait_until(target)
        await self._run_once()

    async def _wait_until(self, target: datetime) -> None:
        # Sleep in bounded slices and re-read the wall clock after each one. A
        # single sleep is computed once, so a host sleep or a clock step would
        # leave the run off the Taipei 04:17 slot.
        while True:
            remaining = (target - self._clock()).total_seconds()
            if remaining <= 0:
                return
            await self._sleep_fn(min(remaining, MAX_SLEEP_SECONDS))

    async def run_forever(self) -> None:
        while True:
            await self.run_next()

    async def _run_once(self) -> None:
        # run_all uses blocking sqlite connections; keep them off the event loop.
        # Cancelling the awaiting task does not stop a worker thread that already
        # started, so on cancellation we ask it to stop at the next batch boundary
        # and wait for it to finish before propagating: the lifespan must not
        # release the runtime root or worker lock under a live DELETE. Waiting
        # costs one batch, not the whole backlog. A run cancelled before its
        # thread started is skipped outright, so there is nothing to wait for.
        state_lock = threading.Lock()
        running = False
        cancelled = False
        finished = threading.Event()

        def _work() -> dict[str, dict[str, int]]:
            nonlocal running
            with state_lock:
                if cancelled:
                    return {}
                running = True
            try:
                return self._run_all_fn(should_stop=self._stop.is_set)
            except RetentionStopped:
                # Shutdown interrupted the run; its partial report is not logged.
                return {}
            finally:
                finished.set()

        try:
            report = await asyncio.to_thread(_work)
        except asyncio.CancelledError:
            self._stop.set()
            with state_lock:
                thread_started = running
                cancelled = not running
            if thread_started:
                await asyncio.to_thread(finished.wait)
            raise
        except Exception:
            self._logger.exception("log retention run failed; will retry at the next scheduled time")
            return
        # The prune has already committed by now. A report that cannot be
        # serialised must be logged, never raised: an exception here would end
        # run_forever and silently stop all future pruning until the next restart.
        try:
            summary = json.dumps(report, default=str)
        except Exception:
            self._logger.exception("log retention ran but its report could not be serialised")
            return
        self._logger.info("log retention run: %s", summary)
