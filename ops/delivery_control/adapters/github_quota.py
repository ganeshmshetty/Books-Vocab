"""GitHub budget governor for the delivery control plane.

Budget state comes from the ``X-RateLimit-*`` response headers of two real probes:
``gh api -i graphql`` (the graphql resource) and ``gh api -i user`` (the core resource).
The governor takes the smaller ``remaining`` of the two. ``gh api rate_limit`` is never
consulted: it reported 5000 while real calls returned 403 (#2647). ``gh pr view`` and
friends emit no headers, so the probes sit beside them, not on them. The probe is
refreshed at most once per ``PROBE_TTL_SECONDS``; each probe is a counted request that
is logged as its own spend row, and local decrements keep the estimate honest between
probes. A resource whose probe yields no parseable headers is unknown and fails open.

Each call has one of three kinds. ``cached-read`` (gh JSON queries and GraphQL reads)
is cached and, below ``STALE_SERVE_BELOW`` remaining, an already-fetched result is
served from this process's cache instead of the network, but only while that entry is
younger than ``STALE_CACHE_TTL_SECONDS``. Accepted staleness window: up to
``STALE_CACHE_TTL_SECONDS`` for any read served from cache. Pushes, external merges
and state changes made by other processes, and git mutations made outside this
governor's gh calls, are not observed within that window. ``live-read`` (for example
``gh pr checks``, whose status gates merges) always reaches the network, is never
cached or stale-served, and changed nothing, so it does not evict the cache.
``mutation`` always reaches the network and evicts the whole cache, even when the
call raises, because a partial write may already have landed.

Stale serve is never applied inside an ``authoritative_reads()`` scope. The adapter
opens that scope around every mutation, its pre/post verification reads, the
required-check observation, and the merge-queue guard reads, because those reads decide
whether a write or a merge is authorized; a cached answer there would replay one stale
head on every retry, bind checks to an old head, or let a queued PR pass abandonment. Authoritative reads still pay the budget wait and the spend-log
row.

Below ``WAIT_BELOW`` the governor sleeps until the bottleneck resource resets (bounded
by ``MAX_RESET_WAITS``), then fails closed with ``GitHubQuotaExhausted``. Every governed
call, including probes, appends one NDJSON spend-log line under a lock; a spend-log
write or decode failure fails open (the call proceeds and its row is lost). The
spend log is
bounded: once it reaches ``SPEND_LOG_MAX_BYTES`` only the newest
``SPEND_LOG_KEEP_LINES`` rows are kept.
"""

from __future__ import annotations

import fcntl
import json
import os
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import IO, Literal

from ..ports.process import CommandResult, CommandRunnerPort
from .errors import AdapterError

STALE_SERVE_BELOW = 800
STALE_CACHE_TTL_SECONDS = 300.0
WAIT_BELOW = 50
PROBE_TTL_SECONDS = 60.0
MAX_RESET_WAITS = 3
SPEND_LOG_MAX_BYTES = 256 * 1024
SPEND_LOG_KEEP_LINES = 1_000
# One real request per resource; ``-i`` prints the response headers on stdout. The
# probes go straight to the raw runner, so they are never classified or governed.
_BUDGET_PROBES: tuple[tuple[tuple[str, ...], str, str], ...] = (
    (
        ("gh", "api", "-i", "graphql", "-f", "query={ viewer { login } }"),
        "graphql",
        "probe graphql",
    ),
    (("gh", "api", "-i", "user"), "core", "probe core"),
)

Outcome = Literal["probe", "network", "stale-cache", "waited"]
CallKind = Literal["cached-read", "live-read", "mutation"]


class GitHubQuotaExhausted(AdapterError):
    """Raised when the budget stays below WAIT_BELOW after bounded reset waits."""


@dataclass(frozen=True)
class BudgetState:
    remaining: int
    reset_epoch: int


def _last_response_headers(stdout: str) -> dict[str, str]:
    """Lower-cased headers of the last HTTP response in ``gh api -i`` stdout.

    Error responses print their status line and headers too, so a rate-limited 403
    still reports ``remaining: 0``; the body is never read.
    """
    lines = stdout.splitlines()
    statuses = [index for index, line in enumerate(lines) if line.startswith("HTTP/")]
    if not statuses:
        return {}
    headers: dict[str, str] = {}
    for line in lines[statuses[-1] + 1 :]:
        if not line.strip():
            break
        name, separator, value = line.partition(":")
        if separator:
            headers[name.strip().lower()] = value.strip()
    return headers


def _budget_from_headers(stdout: str, resource: str) -> BudgetState | None:
    headers = _last_response_headers(stdout)
    if headers.get("x-ratelimit-resource") != resource:
        return None
    try:
        return BudgetState(
            remaining=int(headers["x-ratelimit-remaining"]),
            reset_epoch=int(headers["x-ratelimit-reset"]),
        )
    except (KeyError, ValueError):
        return None


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
        self._read_cache: dict[tuple[str, ...], tuple[CommandResult, float]] = {}
        self._authoritative_depth = 0

    @contextmanager
    def authoritative_reads(self) -> Iterator[None]:
        """Reads issued in this scope always reach the network; stale serve is disabled."""
        self._authoritative_depth += 1
        try:
            yield
        finally:
            self._authoritative_depth -= 1

    def call(
        self,
        argv: tuple[str, ...],
        *,
        kind: CallKind,
        execute: Callable[[], CommandResult],
    ) -> tuple[CommandResult, bool]:
        """Return ``(result, executed)``; ``executed`` is False when served from cache."""
        self._refresh_if_stale()
        if self._budget is not None and self._budget.remaining < WAIT_BELOW:
            self._wait_for_reset(argv)
        budget = self._budget
        cached = self._read_cache.get(argv)
        if (
            kind == "cached-read"
            and self._authoritative_depth == 0
            and budget is not None
            and budget.remaining < STALE_SERVE_BELOW
            and cached is not None
            and self._clock() - cached[1] < STALE_CACHE_TTL_SECONDS
        ):
            self._record(argv, budget.remaining, "stale-cache", 0)
            return cached[0], False
        remaining = None if budget is None else budget.remaining
        try:
            result = execute()
        except BaseException:
            # A raised attempt still reached the transport: it spends budget and gets
            # its spend row (no exit code), so the log accounts for every call.
            self._settle(argv, kind, remaining, exit_code=None)
            raise
        self._settle(argv, kind, remaining, exit_code=result.exit_code)
        if kind == "cached-read" and result.exit_code == 0:
            self._remember(argv, result)
        return result, True

    def _settle(
        self,
        argv: tuple[str, ...],
        kind: CallKind,
        remaining: int | None,
        *,
        exit_code: int | None,
    ) -> None:
        """Account for one network attempt: evict on writes, spend one unit, log one row."""
        # Evict on every mutation attempt, not only on success: a write that
        # raises may already have landed on GitHub.
        if kind == "mutation":
            self._read_cache.clear()
        if self._budget is not None:
            self._budget = replace(
                self._budget, remaining=max(0, self._budget.remaining - 1)
            )
        self._record(argv, remaining, "network", exit_code)

    def _remember(self, argv: tuple[str, ...], result: CommandResult) -> None:
        """Cache one read and drop entries past their TTL so the cache stays bounded."""
        now = self._clock()
        expired = [
            key
            for key, (_, stored_at) in self._read_cache.items()
            if now - stored_at >= STALE_CACHE_TTL_SECONDS
        ]
        for key in expired:
            del self._read_cache[key]
        self._read_cache[argv] = (result, now)

    def _refresh_if_stale(self) -> None:
        if (
            self._probed_at is None
            or self._clock() - self._probed_at >= PROBE_TTL_SECONDS
        ):
            self._probe()

    def _probe(self) -> None:
        states: list[BudgetState] = []
        for argv, resource, endpoint in _BUDGET_PROBES:
            result = self._runner.run(argv, cwd=self._repo)
            state = _budget_from_headers(result.stdout, resource)
            if state is not None:
                states.append(state)
            self._record(
                argv,
                None if state is None else state.remaining,
                "probe",
                result.exit_code,
                endpoint=endpoint,
            )
        # Header values already include this probe's own request, so no decrement.
        self._budget = min(
            states, key=lambda state: (state.remaining, state.reset_epoch), default=None
        )
        self._probed_at = self._clock()

    def _wait_for_reset(self, argv: tuple[str, ...]) -> None:
        waits = 0
        while self._budget is not None and self._budget.remaining < WAIT_BELOW:
            if waits == MAX_RESET_WAITS:
                raise GitHubQuotaExhausted(
                    f"GitHub budget stayed below {WAIT_BELOW} after {waits} reset waits"
                )
            delay = max(0.0, self._budget.reset_epoch - self._clock())
            self._sleep(delay)
            waits += 1
            self._record(
                argv, self._budget.remaining, "waited", None, wait_seconds=delay
            )
            self._probe()

    def _record(
        self,
        argv: tuple[str, ...],
        remaining: int | None,
        outcome: Outcome,
        exit_code: int | None,
        *,
        wait_seconds: float | None = None,
        endpoint: str | None = None,
    ) -> None:
        row: dict[str, object] = {
            "ts": datetime.fromtimestamp(self._clock(), tz=UTC).isoformat(
                timespec="seconds"
            ),
            "endpoint": endpoint or " ".join(argv[1:3]),
            "remaining": remaining,
            "outcome": outcome,
            "exit_code": exit_code,
        }
        if wait_seconds is not None:
            row["wait_seconds"] = round(wait_seconds, 1)
        line = json.dumps(row, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        try:
            self._spend_log.parent.mkdir(parents=True, exist_ok=True)
            with self._spend_log.open("a+", encoding="utf-8") as stream:
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
                try:
                    _trim_spend_log(stream)
                    stream.write(line + "\n")
                    stream.flush()
                finally:
                    fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
        except (OSError, ValueError):
            # Observability must not block delivery: a spend-log write or decode failure
            # (ValueError covers UnicodeDecodeError while trimming) fails open.
            return


def _trim_spend_log(stream: IO[str]) -> None:
    """Keep only the newest rows once the log reaches its cap; caller holds the flock.

    Runs under the same lock as the append, so concurrent writers never interleave with
    the rewrite. In append mode every write lands at end-of-file, so truncating to zero
    and rewriting the kept tail leaves a well-formed NDJSON file.
    """
    if os.fstat(stream.fileno()).st_size < SPEND_LOG_MAX_BYTES:
        return
    stream.seek(0)
    kept = stream.readlines()[-SPEND_LOG_KEEP_LINES:]
    stream.seek(0)
    stream.truncate()
    stream.writelines(kept)
    stream.flush()
