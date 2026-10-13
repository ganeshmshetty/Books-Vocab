from __future__ import annotations

import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.errors import (
    AdapterCommandError,
    AdapterPayloadError,
)
from delivery_control.adapters.github_checks import GitHubChecks
from delivery_control.adapters.github_client import GitHubCliClient
from delivery_control.domain.errors import CompareAndSwapConflict
from delivery_control.domain.models import CheckStatus
from delivery_control.domain.observations import PullRequestSnapshot
from delivery_control.ports.process import CommandResult

HEAD = "a" * 40
BASE = "b" * 40
_DEFAULT_PAGE_INFO = object()


class StaticRunner:
    def __init__(self, responses: list[CommandResult]) -> None:
        self.responses = list(responses)
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        self.calls.append(argv)
        if not self.responses:
            raise AssertionError(f"unexpected command: {argv}")
        return self.responses.pop(0)


def _pr(number: int, *, head: str = HEAD) -> PullRequestSnapshot:
    return PullRequestSnapshot(
        number=number,
        url=f"https://example.test/pull/{number}",
        branch=f"feat/{number}",
        base_sha=BASE,
        head_sha=head,
        state="OPEN",
        draft=False,
        mergeable=True,
        node_id=f"PR_{number}",
        body="body",
    )


def _context_payload(
    *,
    number: int,
    head: str = HEAD,
    conclusion: str = "SUCCESS",
    required: bool = True,
    page_info: object = _DEFAULT_PAGE_INFO,
) -> dict[str, object]:
    if page_info is _DEFAULT_PAGE_INFO:
        page_info = {"hasNextPage": False}
    return {
        "data": {
            "repository": {
                f"pr_{number}": {
                    "number": number,
                    "headRefOid": head,
                    "commits": {
                        "nodes": [
                            {
                                "commit": {
                                    "statusCheckRollup": {
                                        "contexts": {
                                            "pageInfo": page_info,
                                            "nodes": [
                                                {
                                                    "__typename": "CheckRun",
                                                    "name": "required",
                                                    "status": "COMPLETED",
                                                    "conclusion": conclusion,
                                                    "startedAt": "2026-08-23T00:00:00Z",
                                                    "completedAt": "2026-08-23T00:00:01Z",
                                                    "isRequired": required,
                                                },
                                                {
                                                    "__typename": "CheckRun",
                                                    "name": "advisory",
                                                    "status": "COMPLETED",
                                                    "conclusion": "FAILURE",
                                                    "startedAt": "2026-08-23T00:00:00Z",
                                                    "completedAt": "2026-08-23T00:00:01Z",
                                                    "isRequired": False,
                                                },
                                            ],
                                        }
                                    }
                                }
                            }
                        ]
                    },
                }
            }
        }
    }


def _agent_review_context(
    *,
    conclusion: str,
    started_at: str,
    completed_at: str,
) -> dict[str, object]:
    return {
        "__typename": "CheckRun",
        "name": "agent-review",
        "status": "COMPLETED",
        "conclusion": conclusion,
        "startedAt": started_at,
        "completedAt": completed_at,
        "isRequired": True,
    }


def _pending_agent_review_context(
    *,
    started_at: str | None = None,
) -> dict[str, object]:
    return {
        "__typename": "CheckRun",
        "name": "agent-review",
        "status": "IN_PROGRESS",
        "conclusion": None,
        "startedAt": started_at,
        "completedAt": None,
        "isRequired": True,
    }


def _checks(runner: StaticRunner, number: int = 12) -> GitHubChecks:
    client = GitHubCliClient(repo=Path("/repo"), runner=runner)
    return GitHubChecks(client=client, get_pull_request=lambda _: _pr(number))


def test_batch_required_snapshot_filters_advisory_and_consumes_once() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh", "api", "graphql"),
                0,
                json.dumps(_context_payload(number=12)),
                "",
            ),
        ]
    )
    checks = _checks(runner)

    checks.prime_required_snapshots((12,))
    snapshot = checks.required_snapshot(12)

    assert snapshot.status is CheckStatus.SUCCESS
    assert snapshot.names == ("required",)
    assert snapshot.head_sha == HEAD
    assert len(runner.calls) == 2
    query = next(part for part in runner.calls[1] if part.startswith("query="))
    assert "pullRequest(number: 12)" in query
    argv = runner.calls[1]
    assert argv[argv.index("owner=owner") - 1] == "-f"
    assert argv[argv.index("name=repo") - 1] == "-f"
    assert "-F" not in argv


def test_batch_required_snapshot_uses_latest_duplicate_required_context() -> None:
    payload = _context_payload(number=12)
    contexts = payload["data"]["repository"]["pr_12"]["commits"]["nodes"][0]["commit"][
        "statusCheckRollup"
    ]["contexts"]["nodes"]
    contexts.extend(
        [
            _agent_review_context(
                conclusion="CANCELLED",
                started_at="2026-08-23T00:00:00Z",
                completed_at="2026-08-23T00:00:01Z",
            ),
            _agent_review_context(
                conclusion="SUCCESS",
                started_at="2026-08-23T00:00:02Z",
                completed_at="2026-08-23T00:00:03Z",
            ),
        ]
    )
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh", "api", "graphql"),
                0,
                json.dumps(payload),
                "",
            ),
        ]
    )
    checks = _checks(runner)

    checks.prime_required_snapshots((12,))
    snapshot = checks.required_snapshot(12)

    assert snapshot.status is CheckStatus.SUCCESS
    assert snapshot.names == ("agent-review", "required")


def test_live_required_snapshot_uses_latest_duplicate_required_context() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                0,
                json.dumps(
                    [
                        {
                            "name": "agent-review",
                            "state": "CANCELLED",
                            "startedAt": "2026-08-23T00:00:00Z",
                            "completedAt": "2026-08-23T00:00:01Z",
                        },
                        {
                            "name": "required",
                            "state": "SUCCESS",
                            "startedAt": "2026-08-23T00:00:00Z",
                            "completedAt": "2026-08-23T00:00:01Z",
                        },
                        {
                            "name": "agent-review",
                            "state": "SUCCESS",
                            "startedAt": "2026-08-23T00:00:02Z",
                            "completedAt": "2026-08-23T00:00:03Z",
                        },
                    ]
                ),
                "",
            ),
        ]
    )

    snapshot = _checks(runner).required_snapshot(12)

    assert snapshot.status is CheckStatus.SUCCESS
    assert snapshot.names == ("agent-review", "required")


def test_batch_required_snapshot_orders_duplicate_terminal_results_by_completion() -> (
    None
):
    payload = _context_payload(number=12)
    contexts = payload["data"]["repository"]["pr_12"]["commits"]["nodes"][0]["commit"][
        "statusCheckRollup"
    ]["contexts"]["nodes"]
    contexts.extend(
        [
            _agent_review_context(
                conclusion="FAILURE",
                started_at="2026-08-23T00:00:10Z",
                completed_at="2026-08-23T00:00:20Z",
            ),
            _agent_review_context(
                conclusion="SUCCESS",
                started_at="2026-08-23T00:00:05Z",
                completed_at="2026-08-23T00:00:30Z",
            ),
        ]
    )
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh", "api", "graphql"),
                0,
                json.dumps(payload),
                "",
            ),
        ]
    )

    checks = _checks(runner)
    checks.prime_required_snapshots((12,))

    assert checks.required_snapshot(12).status is CheckStatus.SUCCESS


def test_live_required_snapshot_orders_duplicate_terminal_results_by_completion() -> (
    None
):
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                0,
                json.dumps(
                    [
                        {
                            "name": "agent-review",
                            "state": "FAILURE",
                            "startedAt": "2026-08-23T00:00:10Z",
                            "completedAt": "2026-08-23T00:00:20Z",
                        },
                        {
                            "name": "agent-review",
                            "state": "SUCCESS",
                            "startedAt": "2026-08-23T00:00:05Z",
                            "completedAt": "2026-08-23T00:00:30Z",
                        },
                    ]
                ),
                "",
            ),
        ]
    )

    assert _checks(runner).required_snapshot(12).status is CheckStatus.SUCCESS


def test_batch_required_snapshot_keeps_latest_duplicate_failure() -> None:
    payload = _context_payload(number=12)
    contexts = payload["data"]["repository"]["pr_12"]["commits"]["nodes"][0]["commit"][
        "statusCheckRollup"
    ]["contexts"]["nodes"]
    contexts.extend(
        [
            _agent_review_context(
                conclusion="SUCCESS",
                started_at="2026-08-23T00:00:01Z",
                completed_at="2026-08-23T00:00:02Z",
            ),
            _agent_review_context(
                conclusion="FAILURE",
                started_at="2026-08-23T00:00:03Z",
                completed_at="2026-08-23T00:00:04Z",
            ),
        ]
    )
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh", "api", "graphql"),
                0,
                json.dumps(payload),
                "",
            ),
        ]
    )

    checks = _checks(runner)
    checks.prime_required_snapshots((12,))

    assert checks.required_snapshot(12).status is CheckStatus.FAILURE


def test_live_required_snapshot_keeps_latest_duplicate_failure() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                0,
                json.dumps(
                    [
                        {
                            "name": "agent-review",
                            "state": "SUCCESS",
                            "startedAt": "2026-08-23T00:00:01Z",
                            "completedAt": "2026-08-23T00:00:02Z",
                        },
                        {
                            "name": "agent-review",
                            "state": "FAILURE",
                            "startedAt": "2026-08-23T00:00:03Z",
                            "completedAt": "2026-08-23T00:00:04Z",
                        },
                    ]
                ),
                "",
            ),
        ]
    )

    assert _checks(runner).required_snapshot(12).status is CheckStatus.FAILURE


def test_batch_required_snapshot_does_not_hide_unstamped_pending_duplicate() -> None:
    payload = _context_payload(number=12)
    contexts = payload["data"]["repository"]["pr_12"]["commits"]["nodes"][0]["commit"][
        "statusCheckRollup"
    ]["contexts"]["nodes"]
    contexts.extend(
        [
            _agent_review_context(
                conclusion="SUCCESS",
                started_at="2026-08-23T00:00:01Z",
                completed_at="2026-08-23T00:00:02Z",
            ),
            _pending_agent_review_context(),
        ]
    )
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh", "api", "graphql"),
                0,
                json.dumps(payload),
                "",
            ),
        ]
    )

    checks = _checks(runner)
    checks.prime_required_snapshots((12,))

    assert checks.required_snapshot(12).status is CheckStatus.PENDING


def test_live_required_snapshot_does_not_hide_unstamped_pending_duplicate() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                0,
                json.dumps(
                    [
                        {
                            "name": "agent-review",
                            "state": "SUCCESS",
                            "startedAt": "2026-08-23T00:00:01Z",
                            "completedAt": "2026-08-23T00:00:02Z",
                        },
                        {
                            "name": "agent-review",
                            "state": "IN_PROGRESS",
                            "startedAt": None,
                            "completedAt": None,
                        },
                    ]
                ),
                "",
            ),
        ]
    )

    assert _checks(runner).required_snapshot(12).status is CheckStatus.PENDING


def test_batch_required_snapshot_rejects_mixed_required_context_kinds() -> None:
    payload = _context_payload(number=12)
    contexts = payload["data"]["repository"]["pr_12"]["commits"]["nodes"][0]["commit"][
        "statusCheckRollup"
    ]["contexts"]["nodes"]
    contexts.append(
        {
            "__typename": "StatusContext",
            "context": "required",
            "state": "FAILURE",
            "isRequired": True,
        }
    )
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh", "api", "graphql"),
                0,
                json.dumps(payload),
                "",
            ),
        ]
    )

    with pytest.raises(AdapterPayloadError, match="context kinds"):
        _checks(runner).prime_required_snapshots((12,))


def test_live_required_snapshot_fails_closed_on_head_drift() -> None:
    heads = iter((HEAD, "c" * 40))
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                0,
                json.dumps(
                    [
                        {
                            "name": "required",
                            "state": "SUCCESS",
                            "startedAt": None,
                            "completedAt": None,
                        }
                    ]
                ),
                "",
            ),
        ]
    )
    client = GitHubCliClient(repo=Path("/repo"), runner=runner)
    checks = GitHubChecks(
        client=client,
        get_pull_request=lambda _: _pr(12, head=next(heads)),
    )

    with pytest.raises(CompareAndSwapConflict, match="HEAD changed"):
        checks.required_snapshot(12)


def test_live_required_snapshot_normalizes_exact_zero_check_result() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                1,
                "no checks reported on the 'feat/12' branch\n",
                "",
            ),
        ]
    )

    snapshot = _checks(runner).required_snapshot(12)

    assert snapshot.status is CheckStatus.ABSENT
    assert snapshot.names == ()
    assert snapshot.head_sha == HEAD


def test_live_required_snapshot_normalizes_exact_zero_check_stderr_result() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                1,
                "",
                "no checks reported on the 'feat/12' branch\n",
            ),
        ]
    )

    snapshot = _checks(runner).required_snapshot(12)

    assert snapshot.status is CheckStatus.ABSENT
    assert snapshot.names == ()
    assert snapshot.head_sha == HEAD


def test_live_required_snapshot_normalizes_required_zero_check_stderr_result() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                1,
                "",
                "no required checks reported on the 'feat/12' branch\n",
            ),
        ]
    )

    snapshot = _checks(runner).required_snapshot(12)

    assert snapshot.status is CheckStatus.ABSENT
    assert snapshot.names == ()
    assert snapshot.head_sha == HEAD


def test_live_required_snapshot_rejects_zero_check_branch_drift() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                1,
                "no checks reported on the 'different-branch' branch\n",
                "",
            ),
        ]
    )

    with pytest.raises(AdapterPayloadError, match="zero-result branch"):
        _checks(runner).required_snapshot(12)


def test_live_required_snapshot_rejects_stderr_zero_check_branch_drift() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                1,
                "",
                "no checks reported on the 'different-branch' branch\n",
            ),
        ]
    )

    with pytest.raises(AdapterPayloadError, match="zero-result branch"):
        _checks(runner).required_snapshot(12)


def test_live_required_snapshot_rejects_non_contract_non_json_result() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                1,
                "no checks were found",
                "",
            ),
        ]
    )

    with pytest.raises(AdapterPayloadError, match="invalid JSON"):
        _checks(runner).required_snapshot(12)


def test_live_required_snapshot_rejects_non_contract_stderr_result() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "pr", "checks"),
                1,
                "",
                "no checks were found",
            ),
        ]
    )

    with pytest.raises(AdapterCommandError):
        _checks(runner).required_snapshot(12)


@pytest.mark.parametrize(
    ("page_info", "message"),
    [
        ({"hasNextPage": True}, "hasNextPage=true"),
        ({}, "pageInfo is malformed"),
        (None, "pageInfo is malformed"),
    ],
)
def test_batch_rejects_incomplete_required_context_connection(
    page_info: object, message: str
) -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh", "api", "graphql"),
                0,
                json.dumps(_context_payload(number=12, page_info=page_info)),
                "",
            ),
        ]
    )
    checks = _checks(runner)

    with pytest.raises(AdapterPayloadError, match=message):
        checks.prime_required_snapshots((12,))


def test_batch_head_drift_falls_back_to_exact_live_check() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh", "api", "graphql"),
                0,
                json.dumps(_context_payload(number=12, head="c" * 40)),
                "",
            ),
            CommandResult(
                ("gh", "pr", "checks"),
                0,
                json.dumps(
                    [
                        {
                            "name": "required",
                            "state": "SUCCESS",
                            "startedAt": None,
                            "completedAt": None,
                        }
                    ]
                ),
                "",
            ),
        ]
    )
    checks = _checks(runner)

    checks.prime_required_snapshots((12,))
    snapshot = checks.required_snapshot(12)

    assert snapshot.status is CheckStatus.SUCCESS
    assert any(call[:3] == ("gh", "pr", "checks") for call in runner.calls)


def test_batch_rejects_malformed_repository_identity() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "not/a/repository/name"}),
                "",
            )
        ]
    )
    checks = _checks(runner)

    with pytest.raises(AdapterPayloadError, match="owner/name"):
        checks.prime_required_snapshots((12,))


def test_deliver_and_control_plane_share_terminal_check_states() -> None:
    """One definition of red/green so deliver and the control plane cannot disagree (#2447)."""
    from delivery_control.adapters import github_checks, github_required_batch
    from delivery_control.domain import check_states

    assert "STARTUP_FAILURE" in check_states.FAILURE_STATES
    assert github_required_batch._FAILURE_STATES is check_states.FAILURE_STATES
    assert github_checks._FAILURE_STATES is check_states.FAILURE_STATES
    assert (
        github_required_batch._status_from_states({"STARTUP_FAILURE"}).name == "FAILURE"
    )


def test_primed_required_snapshot_older_than_cap_is_reread_live() -> None:
    now = [1_000.0]
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh", "api", "graphql"),
                0,
                json.dumps(_context_payload(number=12)),
                "",
            ),
            CommandResult(
                ("gh", "pr", "checks"),
                0,
                json.dumps(
                    [
                        {
                            "name": "required",
                            "state": "SUCCESS",
                            "startedAt": None,
                            "completedAt": None,
                        }
                    ]
                ),
                "",
            ),
        ]
    )
    client = GitHubCliClient(repo=Path("/repo"), runner=runner, now=lambda: now[0])
    checks = GitHubChecks(
        client=client,
        get_pull_request=lambda _: _pr(12),
        clock=lambda: datetime.fromtimestamp(now[0], tz=UTC),
    )
    checks.prime_required_snapshots((12,))

    now[0] += 400

    snapshot = checks.required_snapshot(12)

    assert runner.calls[-1][:3] == ("gh", "pr", "checks")
    assert snapshot.observed_at == datetime.fromtimestamp(1_400.0, tz=UTC)
    assert snapshot.status is CheckStatus.SUCCESS


def test_fresh_required_snapshot_ignores_a_primed_success_and_reads_live_failure() -> (
    None
):
    # Merge admission must not act on a primed tick-start SUCCESS when the check
    # re-ran red inside the cap window.
    now = [1_000.0]
    runner = StaticRunner(
        [
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh", "api", "graphql"),
                0,
                json.dumps(_context_payload(number=12)),
                "",
            ),
            CommandResult(
                ("gh", "pr", "checks"),
                0,
                json.dumps(
                    [
                        {
                            "name": "required",
                            "state": "FAILURE",
                            "startedAt": None,
                            "completedAt": None,
                        }
                    ]
                ),
                "",
            ),
        ]
    )
    client = GitHubCliClient(repo=Path("/repo"), runner=runner, now=lambda: now[0])
    checks = GitHubChecks(
        client=client,
        get_pull_request=lambda _: _pr(12),
        clock=lambda: datetime.fromtimestamp(now[0], tz=UTC),
    )
    checks.prime_required_snapshots((12,))

    now[0] += 60

    snapshot = checks.required_snapshot(12, fresh=True)

    assert runner.calls[-1][:3] == ("gh", "pr", "checks")
    assert snapshot.status is CheckStatus.FAILURE
