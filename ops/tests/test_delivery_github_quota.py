from __future__ import annotations

import json
import sys
from collections.abc import Callable
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.github_client import GitHubCliClient
from delivery_control.adapters.github_quota import (
    MAX_RESET_WAITS,
    PROBE_TTL_SECONDS,
    RATE_LIMIT_ARGV,
    STALE_SERVE_BELOW,
    WAIT_BELOW,
    GitHubQuotaExhausted,
    GitHubQuotaGovernor,
)
from delivery_control.adapters.subprocess_runner import SubprocessCommandRunner
from delivery_control.ports.process import CommandResult

READ = ("gh", "issue", "list", "--json", "number")
WRITE = ("gh", "issue", "comment", "1", "--body", "x")
REPO = Path("/repo")


class FakeRunner:
    """Answers the rate_limit probe from ``budget``; other calls get a numbered body."""

    def __init__(self, *, remaining: int, reset: int = 9_999) -> None:
        self.remaining = remaining
        self.reset = reset
        self.probe_exit = 0
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        self.calls.append(argv)
        if argv == RATE_LIMIT_ARGV:
            if self.probe_exit:
                return CommandResult(argv, self.probe_exit, "", "HTTP 500")
            resource = {"limit": 5000, "used": 0, "remaining": self.remaining, "reset": self.reset}
            return CommandResult(argv, 0, json.dumps({"resources": {"core": resource, "graphql": resource}}), "")
        return CommandResult(argv, 0, json.dumps({"n": len(self.calls)}), "")

    def count(self, argv: tuple[str, ...]) -> int:
        return sum(1 for call in self.calls if call == argv)


class FakeClock:
    def __init__(self, on_sleep: Callable[[float], None] | None = None) -> None:
        self.t = 1_000.0
        self.slept: list[float] = []
        self._on_sleep = on_sleep

    def now(self) -> float:
        return self.t

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.t += seconds
        if self._on_sleep is not None:
            self._on_sleep(seconds)


def _governor(runner: FakeRunner, clock: FakeClock, spend_log: Path) -> GitHubQuotaGovernor:
    return GitHubQuotaGovernor(
        repo=REPO,
        runner=runner,
        spend_log=spend_log,
        clock=clock.now,
        sleep=clock.sleep,
    )


def _call(governor: GitHubQuotaGovernor, runner: FakeRunner, argv: tuple[str, ...], *, read_only: bool):
    return governor.call(argv, read_only=read_only, execute=lambda: runner.run(argv, cwd=REPO))


def _spend_rows(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def test_budget_below_800_serves_cached_read_without_network_call(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")

    first, first_executed = _call(governor, runner, READ, read_only=True)
    runner.remaining = STALE_SERVE_BELOW - 1
    clock.t += PROBE_TTL_SECONDS + 1
    second, second_executed = _call(governor, runner, READ, read_only=True)

    assert first_executed is True
    assert second_executed is False
    assert second == first
    assert runner.count(READ) == 1


def test_budget_at_800_passes_reads_through(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=STALE_SERVE_BELOW)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")

    _call(governor, runner, READ, read_only=True)
    clock.t += PROBE_TTL_SECONDS + 1
    _, executed = _call(governor, runner, READ, read_only=True)

    assert executed is True
    assert runner.count(READ) == 2
    assert clock.slept == []


def test_write_clears_read_cache_so_stale_reads_are_not_served_after_mutation(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")

    _call(governor, runner, READ, read_only=True)
    runner.remaining = STALE_SERVE_BELOW - 1
    clock.t += PROBE_TTL_SECONDS + 1
    _call(governor, runner, WRITE, read_only=False)
    _, executed = _call(governor, runner, READ, read_only=True)

    assert executed is True
    assert runner.count(READ) == 2


def test_budget_below_50_waits_until_reset_then_proceeds(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=WAIT_BELOW - 1, reset=1_120)
    clock = FakeClock(on_sleep=lambda _seconds: setattr(runner, "remaining", 5_000))
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")

    _, executed = _call(governor, runner, WRITE, read_only=False)

    assert executed is True
    assert clock.slept == [120.0]
    assert runner.count(WRITE) == 1


def test_budget_still_below_50_after_bounded_waits_fails_closed(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=WAIT_BELOW - 1, reset=1_000)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")

    with pytest.raises(GitHubQuotaExhausted):
        _call(governor, runner, WRITE, read_only=False)

    assert len(clock.slept) == MAX_RESET_WAITS
    assert runner.count(WRITE) == 0


def test_probe_failure_fails_open_without_waiting(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=0)
    runner.probe_exit = 1
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")

    _, executed = _call(governor, runner, READ, read_only=True)

    assert executed is True
    assert clock.slept == []


def test_every_governed_call_appends_one_spend_log_line(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    spend_log = tmp_path / "spend.ndjson"
    governor = _governor(runner, clock, spend_log)

    _call(governor, runner, READ, read_only=True)
    _call(governor, runner, WRITE, read_only=False)

    rows = _spend_rows(spend_log)
    assert [row["endpoint"] for row in rows] == ["api rate_limit", "issue list", "issue comment"]
    assert [row["outcome"] for row in rows] == ["probe", "network", "network"]
    assert all(row["ts"] for row in rows)
    assert rows[1]["remaining"] == 5_000


def test_client_serves_cached_read_through_governor(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")
    client = GitHubCliClient(repo=REPO, runner=runner, quota=governor)

    first = client.load_json(READ)
    runner.remaining = STALE_SERVE_BELOW - 1
    clock.t += PROBE_TTL_SECONDS + 1
    second = client.load_json(READ)

    assert second == first
    assert runner.count(READ) == 1
    assert client.last_command_attempts == ()


def test_client_enables_governor_only_for_real_subprocess_runner(tmp_path: Path) -> None:
    assert GitHubCliClient(repo=REPO, runner=FakeRunner(remaining=5_000)).quota is None
    assert isinstance(GitHubCliClient(repo=tmp_path, runner=SubprocessCommandRunner()).quota, GitHubQuotaGovernor)
