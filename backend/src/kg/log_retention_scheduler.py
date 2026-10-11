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
from datetime import datetime, time, timedelta
from typing import Any

from .log_retention import run_all

_logger = logging.getLogger(__name__)

RETENTION_RUN_AT = time(4, 17)


def next_run_at(now: datetime) -> datetime:
    """Return the next local wall-clock ``RETENTION_RUN_AT`` strictly after ``now``.

    ``now`` is naive local time (``datetime.now()``), so the schedule follows
    the host's local clock as the SOP describes.
    """
    target = datetime.combine(now.date(), RETENTION_RUN_AT)
    if target <= now:
        target += timedelta(days=1)
    return target


class LogRetentionScheduler:
    def __init__(
        self,
        *,
        run_all_fn: Callable[[], dict[str, dict[str, int]]] = run_all,
        clock: Callable[[], datetime] = datetime.now,
        sleep_fn: Callable[[float], Any] = asyncio.sleep,
        logger: logging.Logger | Any = _logger,
    ) -> None:
        self._run_all_fn = run_all_fn
        self._clock = clock
        self._sleep_fn = sleep_fn
        self._logger = logger

    async def run_next(self) -> None:
        """Sleep until the next scheduled slot, then run the pruners once."""
        now = self._clock()
        target = next_run_at(now)
        await self._sleep_fn((target - now).total_seconds())
        await self._run_once()

    async def run_forever(self) -> None:
        while True:
            await self.run_next()

    async def _run_once(self) -> None:
        # run_all uses blocking sqlite connections; keep them off the event loop.
        # Cancelling the awaiting task does not stop a worker thread that already
        # started, so on cancellation we wait for it to finish before propagating:
        # the lifespan must not release the runtime root or worker lock under a
        # live DELETE. A run cancelled before its thread started is skipped
        # outright, so there is nothing to wait for and no hang on shutdown.
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
                return self._run_all_fn()
            finally:
                finished.set()

        try:
            report = await asyncio.to_thread(_work)
        except asyncio.CancelledError:
            with state_lock:
                thread_started = running
                cancelled = not running
            if thread_started:
                await asyncio.to_thread(finished.wait)
            raise
        except Exception:
            self._logger.exception("log retention run failed; will retry at the next scheduled time")
            return
        self._logger.info("log retention run: %s", json.dumps(report))
