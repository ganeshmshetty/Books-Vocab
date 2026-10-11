"""GitHub budget governor for the delivery control plane.

Budget state comes from ``gh api rate_limit``: it reports the same core/graphql
counters as the X-RateLimit headers, is not counted against the budget, and works
for every gh subcommand (``gh pr view`` and friends are GraphQL-backed and emit no
headers). The probe is refreshed at most once per ``PROBE_TTL_SECONDS``; local
decrements keep the estimate honest between probes.

Below ``STALE_SERVE_BELOW`` remaining, an already-fetched read-only result is served
from this process's cache instead of the network. Below ``WAIT_BELOW`` the governor
sleeps until the bottleneck resource resets (bounded by ``MAX_RESET_WAITS``). Every
governed call, including probes, appends one NDJSON spend-log line under a lock.
"""

from __future__ import annotations

import fcntl
import json
import time
from collections.abc import Callable
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from ..ports.process import CommandResult, CommandRunnerPort

STALE_SERVE_BELOW = 800
WAIT_BELOW = 50
PROBE_TTL_SECONDS = 60.0
MAX_RESET_WAITS = 3
RATE_LIMIT_ARGV = ("gh", "api", "rate_limit")
_BUDGET_RESOURCES = ("core", "graphql")

Outcome = Literal["probe", "network", "stale-cache", "waited"]


class GitHubQuotaExhausted(RuntimeError):
    """Raised when the budget stays below WAIT_BELOW after bounded reset waits."""


@dataclass(frozen=True)
class BudgetState:
    remaining: int
    reset_epoch: int


def _parse_rate_limit(stdout: str) -> BudgetState | None:
    try:
        resources = json.loads(stdout)["resources"]
        pairs = [(int(resources[name]["remaining"]), int(resources[name]["reset"])) for name in _BUDGET_RESOURCES]
    except (json.JSONDecodeError, KeyError, TypeError, ValueError):
        return None
    remaining, reset_epoch = min(pairs)
    return BudgetState(remaining=remaining, reset_epoch=reset_epoch)


class GitHubQuotaGovernor:
    def __init__(
        self,
        *,
        repo: Path,
        runner: CommandRunnerPort,
        spend_log: Path,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._repo = repo
        self._runner = runner
        self._spend_log = spend_log.expanduser().resolve()
        self._clock = clock
        self._sleep = sleep
        self._budget: BudgetState | None = None
        self._probed_at: float | None = None
        self._read_cache: dict[tuple[str, ...], CommandResult] = {}

    def call(
        self,
        argv: tuple[str, ...],
        *,
        read_only: bool,
        execute: Callable[[], CommandResult],
    ) -> tuple[CommandResult, bool]:
        """Return ``(result, executed)``; ``executed`` is False when served from cache."""
        self._refresh_if_stale()
        if self._budget is not None and self._budget.remaining < WAIT_BELOW:
            self._wait_for_reset(argv)
        budget = self._budget
        if read_only and budget is not None and budget.remaining < STALE_SERVE_BELOW and argv in self._read_cache:
            self._record(argv, budget.remaining, "stale-cache", 0)
            return self._read_cache[argv], False
        remaining = None if budget is None else budget.remaining
        result = execute()
        if not read_only:
            self._read_cache.clear()
        elif result.exit_code == 0:
            self._read_cache[argv] = result
        if self._budget is not None:
            self._budget = replace(self._budget, remaining=max(0, self._budget.remaining - 1))
        self._record(argv, remaining, "network", result.exit_code)
        return result, True

    def _refresh_if_stale(self) -> None:
        if self._probed_at is None or self._clock() - self._probed_at >= PROBE_TTL_SECONDS:
            self._probe()

    def _probe(self) -> None:
        result = self._runner.run(RATE_LIMIT_ARGV, cwd=self._repo)
        state = _parse_rate_limit(result.stdout) if result.exit_code == 0 else None
        self._budget = state
        self._probed_at = self._clock()
        self._record(
            RATE_LIMIT_ARGV,
            None if state is None else state.remaining,
            "probe",
            result.exit_code,
        )

    def _wait_for_reset(self, argv: tuple[str, ...]) -> None:
        waits = 0
        while self._budget is not None and self._budget.remaining < WAIT_BELOW:
            if waits == MAX_RESET_WAITS:
                raise GitHubQuotaExhausted(f"GitHub budget stayed below {WAIT_BELOW} after {waits} reset waits")
            delay = max(0.0, self._budget.reset_epoch - self._clock())
            self._sleep(delay)
            waits += 1
            self._record(argv, self._budget.remaining, "waited", None, wait_seconds=delay)
            self._probe()

    def _record(
        self,
        argv: tuple[str, ...],
        remaining: int | None,
        outcome: Outcome,
        exit_code: int | None,
        *,
        wait_seconds: float | None = None,
    ) -> None:
        row: dict[str, object] = {
            "ts": datetime.fromtimestamp(self._clock(), tz=UTC).isoformat(timespec="seconds"),
            "endpoint": " ".join(argv[1:3]),
            "remaining": remaining,
            "outcome": outcome,
            "exit_code": exit_code,
        }
        if wait_seconds is not None:
            row["wait_seconds"] = round(wait_seconds, 1)
        line = json.dumps(row, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        self._spend_log.parent.mkdir(parents=True, exist_ok=True)
        with self._spend_log.open("a", encoding="utf-8") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
            try:
                stream.write(line + "\n")
                stream.flush()
            finally:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
