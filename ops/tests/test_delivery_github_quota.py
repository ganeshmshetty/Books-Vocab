# ruff: noqa: E402

from __future__ import annotations

import json
import sys
from collections.abc import Callable
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters import github_commands, github_quota
from delivery_control.adapters.errors import AdapterError
from delivery_control.adapters.github_cli import GitHubCliAdapter
from delivery_control.adapters.github_quota import (
    MAX_RESET_WAITS,
    PROBE_TTL_SECONDS,
    RATE_LIMIT_ARGV,
    STALE_CACHE_TTL_SECONDS,
    STALE_SERVE_BELOW,
    WAIT_BELOW,
    GitHubQuotaExhausted,
    GitHubQuotaGovernor,
)
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
        self.probe_stdout: str | None = None
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        self.calls.append(argv)
        if argv == RATE_LIMIT_ARGV:
            if self.probe_exit:
                return CommandResult(argv, self.probe_exit, "", "HTTP 500")
            if self.probe_stdout is not None:
                return CommandResult(argv, 0, self.probe_stdout, "")
            resource = {
                "limit": 5000,
                "used": 0,
                "remaining": self.remaining,
                "reset": self.reset,
            }
            return CommandResult(
                argv,
                0,
                json.dumps({"resources": {"core": resource, "graphql": resource}}),
                "",
            )
        if argv[:3] == ("gh", "repo", "view"):
            return CommandResult(
                argv, 0, json.dumps({"nameWithOwner": "owner/name"}), ""
            )
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


def _governor(
    runner: FakeRunner, clock: FakeClock, spend_log: Path, repo: Path = REPO
) -> GitHubQuotaGovernor:
    return GitHubQuotaGovernor(
        repo=repo,
        runner=runner,
        spend_log=spend_log,
        clock=clock.now,
        sleep=clock.sleep,
    )


def _call(
    governor: GitHubQuotaGovernor,
    runner: FakeRunner,
    argv: tuple[str, ...],
    *,
    read_only: bool,
):
    return governor.call(
        argv, read_only=read_only, execute=lambda: runner.run(argv, cwd=REPO)
    )


def _spend_rows(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def test_budget_below_800_serves_cached_read_without_network_call(
    tmp_path: Path,
) -> None:
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


def test_stale_cache_entry_older_than_ttl_is_not_served(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")

    _call(governor, runner, READ, read_only=True)
    runner.remaining = STALE_SERVE_BELOW - 1
    clock.t += STALE_CACHE_TTL_SECONDS + 1
    _, executed = _call(governor, runner, READ, read_only=True)

    assert executed is True
    assert runner.count(READ) == 2


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


def test_write_clears_read_cache_so_stale_reads_are_not_served_after_mutation(
    tmp_path: Path,
) -> None:
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


def test_quota_exhaustion_is_a_structured_adapter_error() -> None:
    assert issubclass(GitHubQuotaExhausted, AdapterError)


def test_probe_failure_fails_open_without_waiting(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=0)
    runner.probe_exit = 1
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")

    _, executed = _call(governor, runner, READ, read_only=True)

    assert executed is True
    assert clock.slept == []


@pytest.mark.parametrize(
    "probe_stdout",
    [
        "not json",
        json.dumps(["not", "a", "mapping"]),
        json.dumps({"resources": {"core": {"remaining": 0, "reset": 1_000}}}),
        json.dumps(
            {
                "resources": {
                    "core": {"remaining": "x", "reset": 1_000},
                    "graphql": {"remaining": 0, "reset": 1},
                }
            }
        ),
    ],
)
def test_malformed_rate_limit_payload_fails_open_without_waiting(
    tmp_path: Path, probe_stdout: str
) -> None:
    runner = FakeRunner(remaining=0)
    runner.probe_stdout = probe_stdout
    clock = FakeClock()
    spend_log = tmp_path / "spend.ndjson"
    governor = _governor(runner, clock, spend_log)

    result, executed = _call(governor, runner, WRITE, read_only=False)

    assert executed is True
    assert result.exit_code == 0
    assert clock.slept == []
    assert _spend_rows(spend_log)[0]["remaining"] is None


def test_every_governed_call_appends_one_spend_log_line(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    spend_log = tmp_path / "spend.ndjson"
    governor = _governor(runner, clock, spend_log)

    _call(governor, runner, READ, read_only=True)
    _call(governor, runner, WRITE, read_only=False)

    rows = _spend_rows(spend_log)
    assert [row["endpoint"] for row in rows] == [
        "api rate_limit",
        "issue list",
        "issue comment",
    ]
    assert [row["outcome"] for row in rows] == ["probe", "network", "network"]
    assert all(row["ts"] for row in rows)
    assert rows[1]["remaining"] == 5_000


def test_stale_cache_serve_is_logged_as_stale_cache_outcome(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    spend_log = tmp_path / "spend.ndjson"
    governor = _governor(runner, clock, spend_log)

    _call(governor, runner, READ, read_only=True)
    runner.remaining = STALE_SERVE_BELOW - 1
    clock.t += PROBE_TTL_SECONDS + 1
    _call(governor, runner, READ, read_only=True)

    row = _spend_rows(spend_log)[-1]
    assert row["outcome"] == "stale-cache"
    assert row["exit_code"] == 0
    assert row["remaining"] == STALE_SERVE_BELOW - 1


def test_reset_wait_is_logged_as_waited_outcome_with_wait_seconds(
    tmp_path: Path,
) -> None:
    runner = FakeRunner(remaining=WAIT_BELOW - 1, reset=1_120)
    clock = FakeClock(on_sleep=lambda _seconds: setattr(runner, "remaining", 5_000))
    spend_log = tmp_path / "spend.ndjson"
    governor = _governor(runner, clock, spend_log)

    _call(governor, runner, WRITE, read_only=False)

    waited = [row for row in _spend_rows(spend_log) if row["outcome"] == "waited"]
    assert len(waited) == 1
    assert waited[0]["wait_seconds"] == 120.0
    assert waited[0]["exit_code"] is None


def test_spend_log_write_failure_fails_open(tmp_path: Path) -> None:
    blocker = tmp_path / "not-a-directory"
    blocker.write_text("", encoding="utf-8")
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    governor = _governor(runner, clock, blocker / "spend.ndjson")

    result, executed = _call(governor, runner, WRITE, read_only=False)

    assert executed is True
    assert result.exit_code == 0
    assert runner.count(WRITE) == 1


def test_adapter_queue_and_issue_graphql_reads_are_served_from_cache_below_800(
    tmp_path: Path,
) -> None:
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson", repo=tmp_path)
    adapter = GitHubCliAdapter(repo=tmp_path, runner=runner, quota=governor)
    queue_read = "query DeliveryQueueRead { viewer { login } }"

    first_queue = adapter.queue._graphql(queue_read)
    first_issue = adapter._issue_queries._graphql(cursor=None)
    runner.remaining = STALE_SERVE_BELOW - 1
    clock.t += PROBE_TTL_SECONDS + 1
    second_queue = adapter.queue._graphql(queue_read)
    second_issue = adapter._issue_queries._graphql(cursor=None)

    assert second_queue == first_queue
    assert second_issue == first_issue
    assert sum(1 for call in runner.calls if call[:3] == ("gh", "api", "graphql")) == 2
    assert clock.slept == []


def test_adapter_queue_and_issue_graphql_wait_below_50_before_running(
    tmp_path: Path,
) -> None:
    runner = FakeRunner(remaining=WAIT_BELOW - 1, reset=1_120)
    clock = FakeClock(on_sleep=lambda _seconds: setattr(runner, "remaining", 5_000))
    governor = _governor(runner, clock, tmp_path / "spend.ndjson", repo=tmp_path)
    adapter = GitHubCliAdapter(repo=tmp_path, runner=runner, quota=governor)

    adapter.queue._graphql("query DeliveryQueueRead { viewer { login } }")
    adapter._issue_queries._graphql(cursor=None)

    assert clock.slept == [120.0]
    assert sum(1 for call in runner.calls if call[:3] == ("gh", "api", "graphql")) == 2


def test_adapter_passes_non_gh_argv_through_without_governing(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=WAIT_BELOW - 1)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson", repo=tmp_path)
    adapter = GitHubCliAdapter(repo=tmp_path, runner=runner, quota=governor)

    adapter.runner.run(("git", "status", "--porcelain"), cwd=tmp_path)

    assert runner.calls == [("git", "status", "--porcelain")]
    assert clock.slept == []


def test_adapter_without_injected_quota_leaves_fake_runner_ungoverned(
    tmp_path: Path,
) -> None:
    runner = FakeRunner(remaining=WAIT_BELOW - 1)
    adapter = GitHubCliAdapter(repo=tmp_path, runner=runner)

    adapter.queue._graphql("query DeliveryQueueRead { viewer { login } }")

    assert RATE_LIMIT_ARGV not in runner.calls
    assert adapter.quota is None


OLD_HEAD = "a" * 40
NEW_HEAD = "b" * 40


def _pr_payload(head_sha: str) -> dict[str, object]:
    return {
        "id": "PR_node_7",
        "number": 7,
        "url": "https://github.com/owner/name/pull/7",
        "headRefName": "debug/issue-2873-wave",
        "baseRefName": "main",
        "baseRefOid": "c" * 40,
        "headRefOid": head_sha,
        "state": "OPEN",
        "isDraft": False,
        "mergeable": "MERGEABLE",
        "title": "t",
        "body": "b",
        "labels": [],
        "autoMergeRequest": None,
        "createdAt": None,
        "mergedAt": None,
        "reviewDecision": None,
    }


class HeadRunner(FakeRunner):
    """Serves PR views whose headRefOid is ``head``; tests move ``head`` out-of-band."""

    def __init__(self, *, remaining: int, head: str) -> None:
        super().__init__(remaining=remaining)
        self.head = head
        self.views = 0

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        if argv[:3] == ("gh", "pr", "view"):
            self.calls.append(argv)
            self.views += 1
            return CommandResult(argv, 0, json.dumps(_pr_payload(self.head)), "")
        return super().run(argv, cwd=cwd)


def test_read_after_write_verification_reads_fresh_head_below_800(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A git push is not a gh call, so the governor cannot clear its read cache for it.
    # The PR head moves OLD -> NEW out-of-band; the verification reads of
    # update_pull_request must reach the network, not replay the cached OLD_HEAD on
    # every retry and fail closed with a CAS conflict.
    monkeypatch.setattr(github_commands, "_READ_AFTER_WRITE_DELAY_SECONDS", 0.0)
    runner = HeadRunner(remaining=5_000, head=OLD_HEAD)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson", repo=tmp_path)
    adapter = GitHubCliAdapter(repo=tmp_path, runner=runner, quota=governor)
    assert adapter.get_pull_request(7).head_sha == OLD_HEAD
    runner.head = NEW_HEAD
    runner.remaining = STALE_SERVE_BELOW - 1
    clock.t += PROBE_TTL_SECONDS + 1

    snapshot = adapter.update_pull_request(
        number=7, title="t", body="b", expected_head_sha=NEW_HEAD
    )

    # Reads: initial, pre-write verification, post-write verification.
    assert snapshot.head_sha == NEW_HEAD
    assert runner.views == 3


def test_authoritative_scope_bypasses_stale_serve_and_restores_after_exit(
    tmp_path: Path,
) -> None:
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")

    _call(governor, runner, READ, read_only=True)
    runner.remaining = STALE_SERVE_BELOW - 1
    clock.t += PROBE_TTL_SECONDS + 1
    with governor.authoritative_reads():
        _, inside = _call(governor, runner, READ, read_only=True)
    _, outside = _call(governor, runner, READ, read_only=True)

    assert inside is True
    assert outside is False
    assert runner.count(READ) == 2


def test_budget_exactly_at_wait_threshold_does_not_wait(tmp_path: Path) -> None:
    runner = FakeRunner(remaining=WAIT_BELOW)
    clock = FakeClock()
    governor = _governor(runner, clock, tmp_path / "spend.ndjson")

    _, executed = _call(governor, runner, WRITE, read_only=False)

    assert executed is True
    assert clock.slept == []
    assert runner.count(WRITE) == 1


def test_spend_log_is_capped_to_newest_rows(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(github_quota, "SPEND_LOG_MAX_BYTES", 2_000)
    monkeypatch.setattr(github_quota, "SPEND_LOG_KEEP_LINES", 5)
    runner = FakeRunner(remaining=5_000)
    clock = FakeClock()
    spend_log = tmp_path / "spend.ndjson"
    governor = _governor(runner, clock, spend_log)

    for _ in range(40):
        _call(governor, runner, WRITE, read_only=False)

    rows = _spend_rows(spend_log)
    assert spend_log.stat().st_size < 2 * 2_000
    assert len(rows) < 41  # one probe plus 40 calls: older rows were trimmed away
    remaining = [row["remaining"] for row in rows]
    assert remaining == sorted(remaining, reverse=True)
    assert rows[-1]["remaining"] == 5_000 - 39
