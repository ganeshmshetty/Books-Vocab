from __future__ import annotations

import ast
import json
import sys
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters import github_commands, github_parsing
from delivery_control.adapters.errors import AdapterCommandError, AdapterPayloadError
from delivery_control.adapters.github_cli import GitHubCliAdapter
from delivery_control.adapters.github_client import GitHubCliClient
from delivery_control.domain.candidate_issues import CANDIDATE_ISSUE_LABEL
from delivery_control.domain.errors import CompareAndSwapConflict
from delivery_control.domain.models import CheckStatus
from delivery_control.domain.observations import (
    InventoryProblem,
)
from delivery_control.ports.process import CommandResult


class StaticRunner:
    def __init__(self, responses: list[CommandResult]) -> None:
        self.responses = list(responses)
        self.calls: list[tuple[str, ...]] = []
        self.cwds: list[Path | None] = []

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        self.calls.append(argv)
        self.cwds.append(cwd)
        return self.responses.pop(0)


def _with_include(argv: tuple[str, ...]) -> tuple[str, ...]:
    """Expected outgoing argv for a governed ``gh api`` read."""

    return (argv[0], argv[1], "--include", *argv[2:])


JOBS_COMMAND = ("gh", "run", "view", "12345", "--json", "jobs")
ZERO_JOBS = json.dumps(
    {
        "jobs": [
            {
                "name": "queued-job",
                "status": "queued",
                "conclusion": None,
                "startedAt": "0001-01-01T00:00:00Z",
            }
        ]
    }
)


def _pr_payload() -> dict[str, object]:
    return {
        "id": "PR_kwDOexample",
        "number": 12,
        "url": "https://example.test/pull/12",
        "headRefName": "feat/one",
        "baseRefName": "main",
        "baseRefOid": "a" * 40,
        "headRefOid": "b" * 40,
        "state": "OPEN",
        "isDraft": False,
        "mergeable": "MERGEABLE",
        "title": "fix: one",
        "body": "## Scope\n- ops/a.py\n\n## Validation\n- required",
        "autoMergeRequest": None,
    }


def _graphql_pr_node(payload: dict[str, object]) -> dict[str, object]:
    return {
        **payload,
        "labels": {
            "nodes": [],
            "pageInfo": {"hasNextPage": False, "endCursor": None},
        },
    }


def _candidate_payload(number: int) -> dict[str, object]:
    return {
        "number": number,
        "url": f"https://github.com/owner/repo/issues/{number}",
        "state": "OPEN",
        "labels": [{"name": CANDIDATE_ISSUE_LABEL}],
        "body": (
            "<!-- kg.delivery.candidate.v1\n"
            + json.dumps(
                {
                    "schema": "kg.delivery.candidate.v1",
                    "severity": "P2",
                    "priority": number,
                    "scope": {
                        "schema": "kg.worktree.scope.v1",
                        "files": [
                            {
                                "operation": "modify",
                                "path": f"ops/issue_{number}.py",
                            }
                        ],
                    },
                    "acceptance": [f"Issue {number} is fixed."],
                    "initial_holds": [],
                },
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n-->"
        ),
    }


def _queue_configuration_payload(*, configured: bool) -> dict[str, object]:
    return {
        "data": {
            "repository": {
                "mergeQueue": (
                    {"configuration": {"mergingStrategy": "ALLGREEN"}}
                    if configured
                    else None
                )
            }
        }
    }


def test_github_json_query_retries_transient_failure_once() -> None:
    repo = Path("/tmp/kg-github-retry")
    argv = ("gh", "repo", "view", "--json", "nameWithOwner")
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "TLS handshake timeout"),
            CommandResult(argv, 0, '{"nameWithOwner":"owner/repo"}', ""),
        ]
    )

    payload = GitHubCliClient(repo=repo, runner=runner).load_json(argv)

    assert payload == {"nameWithOwner": "owner/repo"}
    assert runner.calls == [argv, argv]
    assert runner.cwds == [repo, repo]


def test_github_json_query_retries_timed_out_result_once() -> None:
    argv = ("gh", "repo", "view", "--json", "nameWithOwner")
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "", timed_out=True),
            CommandResult(argv, 0, '{"nameWithOwner":"owner/repo"}', ""),
        ]
    )

    payload = GitHubCliClient(
        repo=Path("/tmp/kg-github-retry"), runner=runner
    ).load_json(argv)

    assert payload == {"nameWithOwner": "owner/repo"}
    assert runner.calls == [argv, argv]


def test_github_json_query_retry_exhaustion_preserves_command_failure() -> None:
    repo = Path("/tmp/kg-github-retry")
    argv = ("gh", "repo", "view", "--json", "nameWithOwner")
    first = CommandResult(argv, 1, "", "connection reset by peer")
    second = CommandResult(argv, 1, "", "connection refused")
    runner = StaticRunner([first, second])

    with pytest.raises(AdapterCommandError) as error:
        GitHubCliClient(repo=repo, runner=runner).load_json(argv)

    assert error.value.result is second
    assert runner.calls == [argv, argv]
    assert runner.cwds == [repo, repo]


def test_github_json_query_does_not_retry_permanent_failure() -> None:
    argv = ("gh", "repo", "view", "--json", "nameWithOwner")
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "HTTP 403: permission denied"),
            CommandResult(argv, 0, '{"nameWithOwner":"owner/repo"}', ""),
        ]
    )

    with pytest.raises(AdapterCommandError):
        GitHubCliClient(repo=Path("/tmp/kg-github-retry"), runner=runner).load_json(
            argv
        )

    assert runner.calls == [argv]


def test_github_json_query_does_not_retry_malformed_json() -> None:
    argv = ("gh", "repo", "view", "--json", "nameWithOwner")
    runner = StaticRunner(
        [
            CommandResult(argv, 0, "not-json", ""),
            CommandResult(argv, 0, '{"nameWithOwner":"owner/repo"}', ""),
        ]
    )

    with pytest.raises(AdapterPayloadError, match="invalid JSON"):
        GitHubCliClient(repo=Path("/tmp/kg-github-retry"), runner=runner).load_json(
            argv
        )

    assert runner.calls == [argv]


def test_github_mutation_does_not_retry_transient_failure() -> None:
    argv = ("gh", "workflow", "run", "pr-gate.yml")
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "temporary network failure"),
            CommandResult(argv, 0, "", ""),
        ]
    )

    with pytest.raises(AdapterCommandError):
        GitHubCliClient(repo=Path("/tmp/kg-github-retry"), runner=runner).run(argv)

    assert runner.calls == [argv]


def test_github_graphql_mutation_does_not_retry_transient_failure() -> None:
    argv = (
        "gh",
        "api",
        "graphql",
        "-f",
        "query=mutation DeliveryCreateIssue { createIssue { issue { number } } }",
    )
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "connection reset by peer"),
            CommandResult(argv, 0, '{"data":{}}', ""),
        ]
    )

    with pytest.raises(AdapterCommandError):
        GitHubCliClient(repo=Path("/tmp/kg-github-retry"), runner=runner).load_json(
            argv
        )

    assert runner.calls == [argv]


def test_github_graphql_mutation_with_flags_before_endpoint_does_not_retry() -> None:
    argv = (
        "gh",
        "api",
        "--method",
        "GET",
        "graphql",
        "-f",
        "query=mutation DeliveryCreateIssue { createIssue { issue { number } } }",
    )
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "connection reset by peer"),
            CommandResult(argv, 0, '{"data":{}}', ""),
        ]
    )

    with pytest.raises(AdapterCommandError):
        GitHubCliClient(repo=Path("/tmp/kg-github-retry"), runner=runner).load_json(
            argv
        )

    assert runner.calls == [argv]


def test_github_graphql_query_with_flags_before_endpoint_retries() -> None:
    argv = (
        "gh",
        "api",
        "--method",
        "GET",
        "graphql",
        "-f",
        "query=query Viewer { viewer { login } }",
    )
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "connection reset by peer"),
            CommandResult(argv, 0, '{"data":{"viewer":{"login":"octocat"}}}', ""),
        ]
    )

    assert GitHubCliClient(repo=Path("/tmp/kg-github-retry"), runner=runner).load_json(
        argv
    ) == {"data": {"viewer": {"login": "octocat"}}}
    assert runner.calls == [_with_include(argv), _with_include(argv)]


def test_github_json_query_exposes_each_command_attempt() -> None:
    repo = Path("/tmp/kg-github-retry")
    argv = ("gh", "repo", "view", "--json", "nameWithOwner")
    first = CommandResult(argv, 1, "", "connection reset by peer")
    second = CommandResult(argv, 0, '{"nameWithOwner":"owner/repo"}', "")
    client = GitHubCliClient(repo=repo, runner=StaticRunner([first, second]))

    assert client.load_json(argv) == {"nameWithOwner": "owner/repo"}
    attempts = client.last_command_attempts
    assert len(attempts) == 2
    assert attempts[0].argv == argv
    assert attempts[0].cwd == repo
    assert attempts[0].result is first
    assert attempts[1].argv == argv
    assert attempts[1].cwd == repo
    assert attempts[1].result is second


@pytest.mark.parametrize(
    "field_flag",
    ("-f", "--field", "-F", "--raw-field", "--input"),
)
def test_github_api_fields_without_method_do_not_retry(
    field_flag: str,
) -> None:
    argv = ("gh", "api", "repos/owner/repo", field_flag, "key=value")
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "connection reset by peer"),
            CommandResult(argv, 0, '{"ok":true}', ""),
        ]
    )

    with pytest.raises(AdapterCommandError):
        GitHubCliClient(repo=Path("/tmp/kg-github-retry"), runner=runner).load_json(
            argv
        )

    assert runner.calls == [argv]


def test_github_api_without_method_or_input_retries() -> None:
    argv = ("gh", "api", "repos/owner/repo")
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "TLS handshake timeout"),
            CommandResult(argv, 0, '{"ok":true}', ""),
        ]
    )

    assert GitHubCliClient(repo=Path("/tmp/kg-github-retry"), runner=runner).load_json(
        argv
    ) == {"ok": True}
    assert runner.calls == [_with_include(argv), _with_include(argv)]


def test_github_api_explicit_get_retries() -> None:
    argv = ("gh", "api", "repos/owner/repo", "--method", "GET")
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "temporary network failure"),
            CommandResult(argv, 0, '{"ok":true}', ""),
        ]
    )

    assert GitHubCliClient(repo=Path("/tmp/kg-github-retry"), runner=runner).load_json(
        argv
    ) == {"ok": True}
    assert runner.calls == [_with_include(argv), _with_include(argv)]


@pytest.mark.parametrize("method", ("POST", "PATCH", "DELETE"))
def test_github_api_explicit_mutation_methods_do_not_retry(method: str) -> None:
    argv = ("gh", "api", "repos/owner/repo", "--method", method)
    runner = StaticRunner(
        [
            CommandResult(argv, 1, "", "connection refused"),
            CommandResult(argv, 0, '{"ok":true}', ""),
        ]
    )

    with pytest.raises(AdapterCommandError):
        GitHubCliClient(repo=Path("/tmp/kg-github-retry"), runner=runner).load_json(
            argv
        )

    assert runner.calls == [argv]


@pytest.mark.parametrize(
    ("parser", "message"),
    (
        (
            github_parsing.parse_pull_request,
            "GitHub PR payload must be an object",
        ),
        (
            github_parsing.parse_candidate_issue,
            "GitHub candidate Issue payload must be an object",
        ),
        (
            github_parsing.parse_demand_issue,
            "GitHub raw Issue payload must be an object",
        ),
    ),
    ids=("pull-request", "candidate-issue", "demand-issue"),
)
@pytest.mark.parametrize("payload", (None, [], "not-an-object"))
def test_direct_github_parsers_reject_non_objects(
    parser, message: str, payload: object
) -> None:
    with pytest.raises(AdapterPayloadError, match=message):
        parser(payload)


def test_demand_issue_inventory_preserves_non_object_problems() -> None:
    inventory = github_parsing.parse_demand_issue_inventory([None, [], "not-an-object"])

    assert inventory.records == ()
    assert inventory.raw_count == 3
    assert [problem.identity for problem in inventory.problems] == [
        "entry[0]",
        "entry[1]",
        "entry[2]",
    ]
    assert [problem.reason for problem in inventory.problems] == [
        "raw Issue entry is not an object",
        "raw Issue entry is not an object",
        "raw Issue entry is not an object",
    ]


def test_github_adapter_reads_open_exact_label_candidate_issues() -> None:
    wrong_label = _candidate_payload(22)
    wrong_label["labels"] = [{"name": "delivery:candidates"}]
    missing_contract = _candidate_payload(23)
    missing_contract["body"] = "No typed contract"
    runner = StaticRunner(
        [
            CommandResult(
                argv=("gh", "issue", "list"),
                exit_code=0,
                stdout=json.dumps(
                    [_candidate_payload(21), wrong_label, missing_contract, 7]
                ),
                stderr="",
            )
        ]
    )

    inventory = GitHubCliAdapter(runner=runner).list_open_candidate_issues()

    assert [item.number for item in inventory.records] == [21]
    assert inventory.records[0].spec.priority == 21
    assert [item.identity for item in inventory.problems] == [
        "Issue#22",
        "Issue#23",
        "entry[3]",
    ]
    assert "typed candidate contract" in inventory.problems[1].reason
    assert runner.calls == [
        (
            "gh",
            "issue",
            "list",
            "--state",
            "open",
            "--label",
            CANDIDATE_ISSUE_LABEL,
            "--limit",
            "1000",
            "--json",
            "number,url,state,labels,body",
        )
    ]


def test_github_adapter_surfaces_malformed_entries() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                argv=("gh", "pr", "list"),
                exit_code=0,
                stdout=json.dumps([_pr_payload(), 7]),
                stderr="",
            )
        ]
    )
    inventory = GitHubCliAdapter(runner=runner).list_open_pull_requests()
    assert [item.number for item in inventory.records] == [12]
    assert inventory.problems == (
        InventoryProblem("github", "entry[1]", "PR entry is not an object"),
    )


def test_github_adapter_reads_terminal_prs_for_one_published_branch() -> None:
    merged = _pr_payload()
    merged["state"] = "MERGED"
    runner = StaticRunner([CommandResult(("gh",), 0, json.dumps([merged]), "")])

    inventory = GitHubCliAdapter(runner=runner).list_pull_requests_for_branch(
        "feat/one"
    )

    assert inventory.records[0].state == "MERGED"
    assert "--state" in runner.calls[0]
    assert "all" in runner.calls[0]
    assert "--head" in runner.calls[0]


def test_github_adapter_reads_branch_history_with_one_snapshot() -> None:
    second = _pr_payload()
    second["number"] = 13
    second["headRefName"] = "feat/two"
    page = {
        "data": {
            "repository": {
                "branch0": {
                    "nodes": [_graphql_pr_node(_pr_payload())],
                    "pageInfo": {"hasNextPage": False, "endCursor": None},
                },
                "branch1": {
                    "nodes": [_graphql_pr_node(second)],
                    "pageInfo": {"hasNextPage": False, "endCursor": None},
                },
            }
        }
    }
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps({"nameWithOwner": "owner/repo"}), ""),
            CommandResult(("gh",), 0, json.dumps(page), ""),
        ]
    )

    inventory = GitHubCliAdapter(runner=runner).list_pull_requests_for_branches(
        ("feat/one", "feat/two")
    )

    assert [item.number for item in inventory.records] == [12, 13]
    assert len(runner.calls) == 2
    assert runner.calls[1][:4] == ("gh", "api", "--include", "graphql")
    query_argument = next(item for item in runner.calls[1] if item.startswith("query="))
    assert "DeliveryPullRequestHistoryByBranch" in query_argument
    assert "headRefName: $branch0" in query_argument
    assert "--paginate" not in runner.calls[1]


@pytest.mark.parametrize(
    ("page_info", "message"),
    (
        ({"hasNextPage": True, "endCursor": "cursor"}, "pagination is incomplete"),
        ({"hasNextPage": "yes", "endCursor": None}, "pageInfo is malformed"),
    ),
)
def test_github_adapter_fails_closed_on_history_page_contract(
    page_info: dict[str, object], message: str
) -> None:
    page = {
        "data": {
            "repository": {
                "branch0": {
                    "nodes": [],
                    "pageInfo": page_info,
                }
            }
        }
    }
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps({"nameWithOwner": "owner/repo"}), ""),
            CommandResult(("gh",), 0, json.dumps(page), ""),
        ]
    )

    with pytest.raises(AdapterPayloadError, match=message):
        GitHubCliAdapter(runner=runner).list_pull_requests_for_branches(("feat/one",))


def test_github_changed_paths_preserve_rename_source_and_destination() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh",),
                0,
                json.dumps(
                    [
                        {
                            "filename": "ops/new.py",
                            "previous_filename": "ops/old.py",
                            "status": "renamed",
                        },
                        {"filename": "ops/added.py", "status": "added"},
                    ]
                ),
                "",
            ),
        ]
    )

    paths = GitHubCliAdapter(runner=runner).changed_paths(12)

    assert paths == ("ops/added.py", "ops/new.py", "ops/old.py")
    assert runner.calls[1][:3] == ("gh", "api", "--include")
    assert runner.calls[1][-1].endswith("repos/owner/repo/pulls/12/files?per_page=100&page=1")


def test_github_changed_paths_reject_rename_without_previous_filename() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(
                ("gh",),
                0,
                json.dumps([{"filename": "ops/new.py", "status": "renamed"}]),
                "",
            ),
        ]
    )

    with pytest.raises(AdapterPayloadError, match="previous_filename"):
        GitHubCliAdapter(runner=runner).changed_paths(12)


def test_github_create_pr_explicitly_targets_main() -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, "https://example.test/pull/12", ""),
            CommandResult(("gh",), 0, json.dumps([_pr_payload()]), ""),
        ]
    )

    created = GitHubCliAdapter(runner=runner).create_pull_request(
        branch="feat/one",
        title="fix: one",
        body="body",
    )

    assert created.number == 12
    create_call = runner.calls[0]
    assert create_call[0:3] == ("gh", "pr", "create")
    assert create_call[create_call.index("--base") + 1] == "main"


def test_github_required_check_snapshot_is_bound_to_exact_head() -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps(_pr_payload()), ""),
            CommandResult(
                ("gh",),
                0,
                json.dumps([{"state": "SUCCESS", "name": "required"}]),
                "",
            ),
            CommandResult(("gh",), 0, json.dumps(_pr_payload()), ""),
        ]
    )
    snapshot = GitHubCliAdapter(runner=runner).required_check_snapshot(12)
    assert snapshot.status is CheckStatus.SUCCESS
    assert snapshot.head_sha == "b" * 40
    assert snapshot.names == ("required",)


def test_github_adapter_parses_pr_labels_and_required_timing_window() -> None:
    pull_request = _pr_payload()
    pull_request.update(
        {
            "labels": [{"name": "delivery-hold:security"}],
            "createdAt": "2026-08-21T00:00:00Z",
            "mergedAt": None,
        }
    )
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps(pull_request), ""),
            CommandResult(
                ("gh",),
                0,
                json.dumps(
                    [
                        {
                            "state": "SUCCESS",
                            "name": "readiness",
                            "startedAt": "2026-08-21T00:00:10Z",
                            "completedAt": "2026-08-21T00:00:20Z",
                        },
                        {
                            "state": "SUCCESS",
                            "name": "required",
                            "startedAt": "2026-08-21T00:00:15Z",
                            "completedAt": "2026-08-21T00:00:45Z",
                        },
                    ]
                ),
                "",
            ),
            CommandResult(("gh",), 0, json.dumps(pull_request), ""),
        ]
    )

    snapshot = GitHubCliAdapter(runner=runner).required_check_snapshot(12)

    assert snapshot.started_at is not None and snapshot.started_at.second == 10
    assert snapshot.completed_at is not None and snapshot.completed_at.second == 45
    assert snapshot.duration_seconds == 35.0
    assert GitHubCliAdapter._pull_request(pull_request).labels == (
        "delivery-hold:security",
    )


def test_github_merge_history_is_typed_and_sorted() -> None:
    runner = StaticRunner(
        [
            CommandResult(
                ("gh",),
                0,
                json.dumps(
                    [
                        {"mergedAt": "2026-08-21T00:05:00Z"},
                        {"mergedAt": "2026-08-21T00:00:00Z"},
                    ]
                ),
                "",
            )
        ]
    )

    observed = GitHubCliAdapter(runner=runner).recent_merge_times(limit=20)

    assert [item.minute for item in observed] == [0, 5]


def test_github_required_checks_preserve_empty_nonzero_command_failure() -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps(_pr_payload()), ""),
            CommandResult(("gh",), 1, "", "network failure"),
        ]
    )

    with pytest.raises(AdapterCommandError):
        GitHubCliAdapter(runner=runner).required_check_snapshot(12)


def test_github_adapter_reads_unique_required_status_contexts() -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps({"nameWithOwner": "owner/repo"}), ""),
            CommandResult(
                ("gh",),
                0,
                json.dumps(
                    {
                        "required_status_checks": {
                            "contexts": ["required"],
                            "checks": [
                                {"context": "required", "app_id": 15368},
                                {
                                    "context": "validate PR readiness contract",
                                    "app_id": 15368,
                                },
                            ],
                        }
                    }
                ),
                "",
            ),
            CommandResult(
                ("gh",),
                0,
                json.dumps(
                    [
                        {
                            "type": "required_status_checks",
                            "parameters": {
                                "required_status_checks": [
                                    {"context": "ruleset-required"}
                                ]
                            },
                        },
                        {"type": "merge_queue", "parameters": {}},
                    ]
                ),
                "",
            ),
        ]
    )

    contexts = GitHubCliAdapter(runner=runner).required_status_contexts("main")

    assert contexts == (
        "required",
        "ruleset-required",
        "validate PR readiness contract",
    )


def test_github_adapter_rejects_malformed_effective_required_status_contexts() -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps({"nameWithOwner": "owner/repo"}), ""),
            CommandResult(("gh",), 0, json.dumps({"required_status_checks": None}), ""),
            CommandResult(
                ("gh",),
                0,
                json.dumps(
                    [
                        {
                            "type": "required_status_checks",
                            "parameters": {"required_status_checks": [7]},
                        }
                    ]
                ),
                "",
            ),
        ]
    )

    with pytest.raises(AdapterPayloadError, match="required contexts"):
        GitHubCliAdapter(runner=runner).required_status_contexts("main")


def test_github_adapter_rejects_malformed_required_status_contexts() -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps({"nameWithOwner": "owner/repo"}), ""),
            CommandResult(
                ("gh",),
                0,
                json.dumps({"required_status_checks": {"contexts": [7]}}),
                "",
            ),
        ]
    )

    with pytest.raises(AdapterPayloadError, match="required contexts"):
        GitHubCliAdapter(runner=runner).required_status_contexts("main")


def test_github_enqueue_delegates_to_native_queue_without_direct_merge() -> None:
    queue_state = {
        "data": {
            "node": {
                "id": "PR_kwDOexample",
                "baseRefName": "main",
                "baseRefOid": "a" * 40,
                "headRefOid": "b" * 40,
                "body": _pr_payload()["body"],
                "state": "OPEN",
                "mergeQueueEntry": None,
            }
        }
    }
    enqueued = {"data": {"enqueuePullRequest": {"mergeQueueEntry": {"id": "MQE_1"}}}}
    queued = json.loads(json.dumps(queue_state))
    queued["data"]["node"]["mergeQueueEntry"] = {
        "id": "MQE_1",
        "enqueuedAt": "2026-08-21T12:00:00Z",
    }
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps(_pr_payload()), ""),
            CommandResult(("gh",), 0, json.dumps({"nameWithOwner": "owner/repo"}), ""),
            CommandResult(
                ("gh",),
                0,
                json.dumps(_queue_configuration_payload(configured=True)),
                "",
            ),
            CommandResult(("gh",), 0, json.dumps(queue_state), ""),
            CommandResult(("gh",), 0, json.dumps(enqueued), ""),
            CommandResult(("gh",), 0, json.dumps(queued), ""),
        ]
    )
    adapter = GitHubCliAdapter(runner=runner)

    adapter.enqueue(
        number=12,
        expected_base_sha="a" * 40,
        expected_head_sha="b" * 40,
        expected_body=str(_pr_payload()["body"]),
    )

    assert all(call[:3] != ("gh", "pr", "merge") for call in runner.calls)
    enqueue_call = next(
        call for call in runner.calls if "enqueuePullRequest" in " ".join(call)
    )
    assert f"expectedHeadOid={'b' * 40}" in enqueue_call


def test_github_enqueue_refuses_branch_without_merge_queue_rule() -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps(_pr_payload()), ""),
            CommandResult(("gh",), 0, json.dumps({"nameWithOwner": "owner/repo"}), ""),
            CommandResult(
                ("gh",),
                0,
                json.dumps(_queue_configuration_payload(configured=False)),
                "",
            ),
        ]
    )

    with pytest.raises(CompareAndSwapConflict, match="no native merge queue"):
        GitHubCliAdapter(runner=runner).enqueue(
            number=12,
            expected_base_sha="a" * 40,
            expected_head_sha="b" * 40,
            expected_body=str(_pr_payload()["body"]),
        )


def test_github_adapter_observes_native_queue_entry() -> None:
    queue_state = {
        "data": {
            "node": {
                "id": "PR_kwDOexample",
                "baseRefName": "main",
                "baseRefOid": "a" * 40,
                "headRefOid": "b" * 40,
                "body": "body",
                "state": "OPEN",
                "mergeQueueEntry": {
                    "id": "MQE_1",
                    "enqueuedAt": "2026-08-21T12:00:00Z",
                },
            }
        }
    }
    runner = StaticRunner([CommandResult(("gh",), 0, json.dumps(queue_state), "")])

    entry_id = GitHubCliAdapter(runner=runner).merge_queue_entry_id("PR_kwDOexample")

    assert entry_id == "MQE_1"


def test_github_enqueue_rejects_body_drift_before_graphql_mutation() -> None:
    drifted = _pr_payload()
    drifted["body"] = "tampered"
    runner = StaticRunner([CommandResult(("gh",), 0, json.dumps(drifted), "")])

    with pytest.raises(CompareAndSwapConflict, match="before enqueue"):
        GitHubCliAdapter(runner=runner).enqueue(
            number=12,
            expected_base_sha="a" * 40,
            expected_head_sha="b" * 40,
            expected_body=str(_pr_payload()["body"]),
        )

    assert all("enqueuePullRequest" not in " ".join(call) for call in runner.calls)


def test_github_metadata_update_requires_expected_handback_head(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload = _pr_payload()
    payload["headRefOid"] = "c" * 40
    monkeypatch.setattr(github_commands.time, "sleep", lambda _: None)
    runner = StaticRunner([CommandResult(("gh",), 0, json.dumps(payload), "")] * 5)

    with pytest.raises(CompareAndSwapConflict, match="before metadata"):
        GitHubCliAdapter(runner=runner).update_pull_request(
            number=12,
            title="fix: exact",
            body="## Scope\nexact",
            expected_head_sha="b" * 40,
        )

    assert len(runner.calls) == 5


def test_github_metadata_update_waits_for_eventual_head_readback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    stale = _pr_payload()
    stale["headRefOid"] = "c" * 40
    before = _pr_payload()
    after = _pr_payload()
    after["body"] = "updated body"
    monkeypatch.setattr(github_commands.time, "sleep", lambda _: None)
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps(stale), ""),
            CommandResult(("gh",), 0, json.dumps(before), ""),
            CommandResult(("gh",), 0, "", ""),
            CommandResult(("gh",), 0, json.dumps(after), ""),
        ]
    )

    result = GitHubCliAdapter(runner=runner).update_pull_request(
        number=12,
        title="fix: exact",
        body="updated body",
        expected_head_sha="b" * 40,
    )

    assert result.body == "updated body"
    assert runner.calls[2][:3] == ("gh", "pr", "edit")


def test_github_metadata_update_fails_closed_after_post_write_head_drift(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    after_drift = _pr_payload()
    after_drift["headRefOid"] = "d" * 40
    monkeypatch.setattr(github_commands.time, "sleep", lambda _: None)
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps(_pr_payload()), ""),
            CommandResult(("gh",), 0, "", ""),
            *[CommandResult(("gh",), 0, json.dumps(after_drift), "")] * 5,
        ]
    )

    with pytest.raises(CompareAndSwapConflict, match="during metadata"):
        GitHubCliAdapter(runner=runner).update_pull_request(
            number=12,
            title="fix: exact",
            body="updated body",
            expected_head_sha="b" * 40,
        )


@pytest.mark.parametrize(
    ("command", "before_state", "after_state"),
    (("close", "OPEN", "CLOSED"), ("reopen", "CLOSED", "OPEN")),
)
def test_github_pr_state_mutation_has_exact_tuple_cas_and_readback(
    command: str, before_state: str, after_state: str
) -> None:
    before = _pr_payload()
    before["state"] = before_state
    after = _pr_payload()
    after["state"] = after_state
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps(before), ""),
            CommandResult(("gh",), 0, "", ""),
            CommandResult(("gh",), 0, json.dumps(after), ""),
        ]
    )
    adapter = GitHubCliAdapter(runner=runner)
    method = getattr(adapter, f"{command}_pull_request")

    result = method(
        number=12,
        expected_base_sha="a" * 40,
        expected_head_sha="b" * 40,
        expected_body=str(before["body"]),
    )

    assert result.state == after_state
    assert runner.calls[1] == ("gh", "pr", command, "12")


def test_github_close_rejects_tuple_drift_before_mutation() -> None:
    drifted = _pr_payload()
    drifted["headRefOid"] = "d" * 40
    runner = StaticRunner([CommandResult(("gh",), 0, json.dumps(drifted), "")])

    with pytest.raises(CompareAndSwapConflict, match="before close"):
        GitHubCliAdapter(runner=runner).close_pull_request(
            number=12,
            expected_base_sha="a" * 40,
            expected_head_sha="b" * 40,
            expected_body=str(drifted["body"]),
        )

    assert len(runner.calls) == 1


def test_github_adapter_reruns_exact_pull_request_workflow_run() -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    rerun_command = ("gh", "run", "rerun", "--failed", "12345")
    runner = StaticRunner(
        [
            CommandResult(
                list_command,
                0,
                json.dumps(
                    [
                        {
                            "databaseId": 12345,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "pull_request",
                            "status": "completed",
                            "conclusion": "failure",
                            "createdAt": "2026-08-29T00:00:00Z",
                        }
                    ]
                ),
                "",
            ),
            CommandResult(rerun_command, 0, "", ""),
        ]
    )
    adapter = GitHubCliAdapter(runner=runner)

    command = adapter.trigger_required(
        number=12,
        branch="feat/one",
        base_sha="a" * 40,
        head_sha=head_sha,
    )

    assert command.command == rerun_command
    assert command.action == "rerun_failed_jobs"
    assert runner.calls == [list_command, rerun_command]


def test_github_adapter_selects_latest_exact_pull_request_run() -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    rerun_command = ("gh", "run", "rerun", "--failed", "12346")
    runner = StaticRunner(
        [
            CommandResult(
                list_command,
                0,
                json.dumps(
                    [
                        {
                            "databaseId": 12345,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "pull_request",
                            "status": "completed",
                            "conclusion": "failure",
                            "createdAt": "2026-08-29T00:00:00Z",
                        },
                        {
                            "databaseId": 12346,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "pull_request",
                            "status": "completed",
                            "conclusion": "cancelled",
                            "createdAt": "2026-08-29T00:01:00Z",
                        },
                        {
                            "databaseId": 12347,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "workflow_dispatch",
                            "status": "completed",
                            "conclusion": "success",
                            "createdAt": "2026-08-29T00:02:00Z",
                        },
                    ]
                ),
                "",
            ),
            CommandResult(rerun_command, 0, "", ""),
        ]
    )

    command = GitHubCliAdapter(runner=runner).trigger_required(
        number=12,
        branch="feat/one",
        base_sha="a" * 40,
        head_sha=head_sha,
    )

    assert command.command == rerun_command
    assert command.action == "rerun_failed_jobs"
    assert runner.calls == [list_command, rerun_command]


def test_github_adapter_refuses_required_rerun_without_exact_pull_request_run() -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    runner = StaticRunner(
        [
            CommandResult(
                list_command,
                0,
                json.dumps(
                    [
                        {
                            "databaseId": 12347,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "workflow_dispatch",
                            "status": "completed",
                            "conclusion": "failure",
                            "createdAt": "2026-08-29T00:00:00Z",
                        }
                    ]
                ),
                "",
            )
        ]
    )

    with pytest.raises(AdapterPayloadError, match="no exact pull_request"):
        GitHubCliAdapter(runner=runner).trigger_required(
            number=12,
            branch="feat/one",
            base_sha="a" * 40,
            head_sha=head_sha,
        )

    assert runner.calls == [list_command]


def test_github_adapter_waits_without_duplicate_rerun_while_run_is_active() -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    runner = StaticRunner(
        [
            CommandResult(
                list_command,
                0,
                json.dumps(
                    [
                        {
                            "databaseId": 12345,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "pull_request",
                            "status": "in_progress",
                            "conclusion": None,
                            "createdAt": "2026-08-29T00:00:00Z",
                        }
                    ]
                ),
                "",
            )
        ]
    )

    outcome = GitHubCliAdapter(runner=runner).trigger_required(
        number=12,
        branch="feat/one",
        base_sha="a" * 40,
        head_sha=head_sha,
    )

    assert outcome.dispatched is False
    assert outcome.action == "wait"
    assert outcome.reason

    assert runner.calls == [list_command]


def test_github_adapter_recovers_stale_queued_exact_run() -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    cancel_command = ("gh", "run", "cancel", "--force", "12345")
    rerun_command = ("gh", "run", "rerun", "12345")
    runner = StaticRunner(
        [
            CommandResult(
                list_command,
                0,
                json.dumps(
                    [
                        {
                            "databaseId": 12345,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "pull_request",
                            "status": "queued",
                            "conclusion": None,
                            "createdAt": "2020-01-01T00:00:00Z",
                        }
                    ]
                ),
                "",
            ),
            CommandResult(JOBS_COMMAND, 0, ZERO_JOBS, ""),
            CommandResult(cancel_command, 0, "", ""),
            CommandResult(
                list_command,
                0,
                json.dumps(
                    [
                        {
                            "databaseId": 12345,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "pull_request",
                            "status": "completed",
                            "conclusion": "failure",
                            "createdAt": "2020-01-01T00:00:00Z",
                        }
                    ]
                ),
                "",
            ),
            CommandResult(rerun_command, 0, "", ""),
        ]
    )

    command = GitHubCliAdapter(runner=runner).trigger_required(
        number=12,
        branch="feat/one",
        base_sha="a" * 40,
        head_sha=head_sha,
    )

    assert command.command == rerun_command
    assert command.action == "recover_wedged_run"
    assert runner.calls == [
        list_command,
        JOBS_COMMAND,
        cancel_command,
        list_command,
        rerun_command,
    ]


def test_github_adapter_retries_cancel_race_until_exact_run_is_terminal(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    cancel_command = ("gh", "run", "cancel", "--force", "12345")
    rerun_command = ("gh", "run", "rerun", "12345")
    queued_payload = json.dumps(
        [
            {
                "databaseId": 12345,
                "headBranch": "feat/one",
                "headSha": head_sha,
                "event": "pull_request",
                "status": "queued",
                "conclusion": None,
                "createdAt": "2020-01-01T00:00:00Z",
            }
        ]
    )
    completed_payload = json.dumps(
        [
            {
                "databaseId": 12345,
                "headBranch": "feat/one",
                "headSha": head_sha,
                "event": "pull_request",
                "status": "completed",
                "conclusion": "failure",
                "createdAt": "2020-01-01T00:00:00Z",
            }
        ]
    )
    runner = StaticRunner(
        [
            CommandResult(list_command, 0, queued_payload, ""),
            CommandResult(JOBS_COMMAND, 0, ZERO_JOBS, ""),
            CommandResult(
                cancel_command,
                1,
                "",
                "Cannot cancel a workflow run that is completed",
            ),
            CommandResult(list_command, 0, queued_payload, ""),
            CommandResult(list_command, 0, completed_payload, ""),
            CommandResult(rerun_command, 0, "", ""),
        ]
    )

    monkeypatch.setattr(github_commands.time, "sleep", lambda _: None)
    command = GitHubCliAdapter(runner=runner).trigger_required(
        number=12,
        branch="feat/one",
        base_sha="a" * 40,
        head_sha=head_sha,
    )

    assert command.command == rerun_command
    assert command.action == "recover_wedged_run"
    assert runner.calls == [
        list_command,
        JOBS_COMMAND,
        cancel_command,
        list_command,
        list_command,
        rerun_command,
    ]


def test_github_adapter_reads_exact_run_view_after_stale_cancel_race(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    cancel_command = ("gh", "run", "cancel", "--force", "12345")
    view_command = (
        "gh",
        "run",
        "view",
        "12345",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt",
    )
    rerun_command = ("gh", "run", "rerun", "12345")
    queued_payload = json.dumps(
        [
            {
                "databaseId": 12345,
                "headBranch": "feat/one",
                "headSha": head_sha,
                "event": "pull_request",
                "status": "queued",
                "conclusion": None,
                "createdAt": "2020-01-01T00:00:00Z",
            }
        ]
    )
    terminal_payload = json.dumps(
        {
            "databaseId": 12345,
            "headBranch": "feat/one",
            "headSha": head_sha,
            "event": "pull_request",
            "status": "completed",
            "conclusion": "failure",
            "createdAt": "2020-01-01T00:00:00Z",
        }
    )
    runner = StaticRunner(
        [
            CommandResult(list_command, 0, queued_payload, ""),
            CommandResult(JOBS_COMMAND, 0, ZERO_JOBS, ""),
            CommandResult(
                cancel_command,
                1,
                "",
                "Cannot cancel a workflow run that is completed",
            ),
            CommandResult(list_command, 0, queued_payload, ""),
            CommandResult(list_command, 0, queued_payload, ""),
            CommandResult(list_command, 0, queued_payload, ""),
            CommandResult(view_command, 0, terminal_payload, ""),
            CommandResult(rerun_command, 0, "", ""),
        ]
    )

    monkeypatch.setattr(github_commands.time, "sleep", lambda _: None)
    command = GitHubCliAdapter(runner=runner).trigger_required(
        number=12,
        branch="feat/one",
        base_sha="a" * 40,
        head_sha=head_sha,
    )

    assert command.command == rerun_command
    assert command.action == "recover_wedged_run"
    assert runner.calls == [
        list_command,
        JOBS_COMMAND,
        cancel_command,
        list_command,
        list_command,
        list_command,
        view_command,
        rerun_command,
    ]


def test_github_adapter_keeps_cancel_race_fail_closed_if_run_view_stays_active(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    cancel_command = ("gh", "run", "cancel", "--force", "12345")
    view_command = (
        "gh",
        "run",
        "view",
        "12345",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt",
    )
    queued_payload = json.dumps(
        {
            "databaseId": 12345,
            "headBranch": "feat/one",
            "headSha": head_sha,
            "event": "pull_request",
            "status": "queued",
            "conclusion": None,
            "createdAt": "2020-01-01T00:00:00Z",
        }
    )
    runner = StaticRunner(
        [
            CommandResult(
                list_command,
                0,
                json.dumps([json.loads(queued_payload)]),
                "",
            ),
            CommandResult(JOBS_COMMAND, 0, ZERO_JOBS, ""),
            CommandResult(
                cancel_command,
                1,
                "",
                "Cannot cancel a workflow run that is completed",
            ),
            CommandResult(
                list_command,
                0,
                json.dumps([json.loads(queued_payload)]),
                "",
            ),
            CommandResult(
                list_command,
                0,
                json.dumps([json.loads(queued_payload)]),
                "",
            ),
            CommandResult(
                list_command,
                0,
                json.dumps([json.loads(queued_payload)]),
                "",
            ),
            CommandResult(view_command, 0, queued_payload, ""),
            CommandResult(view_command, 0, queued_payload, ""),
            CommandResult(view_command, 0, queued_payload, ""),
        ]
    )

    monkeypatch.setattr(github_commands.time, "sleep", lambda _: None)
    with pytest.raises(
        AdapterPayloadError, match="authoritative exact.*remained active"
    ):
        GitHubCliAdapter(runner=runner).trigger_required(
            number=12,
            branch="feat/one",
            base_sha="a" * 40,
            head_sha=head_sha,
        )

    assert runner.calls == [
        list_command,
        JOBS_COMMAND,
        cancel_command,
        list_command,
        list_command,
        list_command,
        view_command,
        view_command,
        view_command,
    ]


def test_github_adapter_does_not_cancel_recent_queued_exact_run() -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    runner = StaticRunner(
        [
            CommandResult(
                list_command,
                0,
                json.dumps(
                    [
                        {
                            "databaseId": 12345,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "pull_request",
                            "status": "queued",
                            "conclusion": None,
                            "createdAt": "2099-01-01T00:00:00Z",
                        }
                    ]
                ),
                "",
            )
        ]
    )

    outcome = GitHubCliAdapter(runner=runner).trigger_required(
        number=12,
        branch="feat/one",
        base_sha="a" * 40,
        head_sha=head_sha,
    )

    assert outcome.dispatched is False
    assert outcome.action == "wait"
    assert outcome.reason

    assert runner.calls == [list_command]


def test_github_adapter_keeps_stale_run_fail_closed_if_cancel_does_not_finish() -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    cancel_command = ("gh", "run", "cancel", "--force", "12345")
    queued_payload = json.dumps(
        [
            {
                "databaseId": 12345,
                "headBranch": "feat/one",
                "headSha": head_sha,
                "event": "pull_request",
                "status": "queued",
                "conclusion": None,
                "createdAt": "2020-01-01T00:00:00Z",
            }
        ]
    )
    runner = StaticRunner(
        [
            CommandResult(list_command, 0, queued_payload, ""),
            CommandResult(JOBS_COMMAND, 0, ZERO_JOBS, ""),
            CommandResult(cancel_command, 0, "", ""),
            CommandResult(list_command, 0, queued_payload, ""),
        ]
    )

    with pytest.raises(AdapterPayloadError, match="remained active"):
        GitHubCliAdapter(runner=runner).trigger_required(
            number=12,
            branch="feat/one",
            base_sha="a" * 40,
            head_sha=head_sha,
        )

    assert runner.calls == [list_command, JOBS_COMMAND, cancel_command, list_command]


def test_github_adapter_refuses_duplicate_rerun_after_exact_success() -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    runner = StaticRunner(
        [
            CommandResult(
                list_command,
                0,
                json.dumps(
                    [
                        {
                            "databaseId": 12345,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "pull_request",
                            "status": "completed",
                            "conclusion": "success",
                            "createdAt": "2026-08-29T00:00:00Z",
                        }
                    ]
                ),
                "",
            )
        ]
    )

    with pytest.raises(AdapterPayloadError, match="already succeeded"):
        GitHubCliAdapter(runner=runner).trigger_required(
            number=12,
            branch="feat/one",
            base_sha="a" * 40,
            head_sha=head_sha,
        )

    assert runner.calls == [list_command]


def test_github_adapter_dispatches_readiness_after_exact_metadata_publish() -> None:
    runner = StaticRunner([CommandResult(("gh",), 0, "", "")])
    adapter = GitHubCliAdapter(runner=runner)

    command = adapter.trigger_readiness(
        number=12,
        branch="feat/one",
        head_sha="b" * 40,
    )

    assert command == (
        "gh",
        "workflow",
        "run",
        "pr-readiness.yml",
        "--ref",
        "feat/one",
        "-f",
        "pr_number=12",
        "-f",
        f"head_sha={'b' * 40}",
    )
    assert runner.calls == [command]


def test_github_adapter_reports_required_workflow_rerun_failure() -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    rerun_command = ("gh", "run", "rerun", "12345")
    runner = StaticRunner(
        [
            CommandResult(
                list_command,
                0,
                json.dumps(
                    [
                        {
                            "databaseId": 12345,
                            "headBranch": "feat/one",
                            "headSha": head_sha,
                            "event": "pull_request",
                            "status": "completed",
                            "conclusion": "failure",
                            "createdAt": "2026-08-29T00:00:00Z",
                        }
                    ]
                ),
                "",
            ),
            CommandResult(rerun_command, 1, "", "workflow rerun rejected"),
        ]
    )

    with pytest.raises(
        AdapterCommandError,
        match=r"gh run rerun 12345.*workflow rerun rejected",
    ):
        GitHubCliAdapter(runner=runner).trigger_required(
            number=12,
            branch="feat/one",
            base_sha="a" * 40,
            head_sha=head_sha,
        )


_HOSTILE_VALUES = ("null", "true", "2026", "@x")


@pytest.mark.parametrize(
    ("stderr", "in_progress"),
    [
        ("HTTP 403: This workflow run is already running", True),
        ("HTTP 403: Resource not accessible by integration", False),
    ],
)
def test_a_rerun_refused_for_a_run_already_running_is_in_progress_not_an_error(
    stderr: str, in_progress: bool
) -> None:
    head_sha = "b" * 40
    list_command = (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        "feat/one",
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt",
    )
    rerun_command = ("gh", "run", "rerun", "--failed", "12345")
    listed = json.dumps(
        [
            {
                "databaseId": 12345,
                "headBranch": "feat/one",
                "headSha": head_sha,
                "event": "pull_request",
                "status": "completed",
                "conclusion": "failure",
                "createdAt": "2026-08-29T00:00:00Z",
            }
        ]
    )
    runner = StaticRunner(
        [
            CommandResult(list_command, 0, listed, ""),
            CommandResult(rerun_command, 1, "", stderr),
        ]
    )
    adapter = GitHubCliAdapter(runner=runner)

    def trigger():
        return adapter.trigger_required(
            number=12, branch="feat/one", base_sha="a" * 40, head_sha=head_sha
        )

    if not in_progress:
        with pytest.raises(AdapterCommandError, match="403"):
            trigger()
        return
    command = trigger()
    assert not command.dispatched
    assert command.command == ()
    assert command.action == "wait"
    assert "already running" in command.reason
    assert runner.calls == [list_command, rerun_command]


def _gh_fields(argv: tuple[str, ...]) -> list[tuple[str, str]]:
    """(flag, "name=value") pairs for every -f/-F field of a gh api argv."""
    return [
        (flag, argv[index + 1])
        for index, flag in enumerate(argv)
        if flag in {"-f", "-F"}
    ]


def test_branch_history_sends_branch_names_as_raw_string_fields() -> None:
    empty = {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}
    page = {"data": {"repository": {f"branch{i}": empty for i in range(4)}}}
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps({"nameWithOwner": "owner/repo"}), ""),
            CommandResult(("gh",), 0, json.dumps(page), ""),
        ]
    )

    GitHubCliAdapter(runner=runner).list_pull_requests_for_branches(_HOSTILE_VALUES)

    fields = _gh_fields(runner.calls[1])
    assert ("-f", "owner=owner") in fields and ("-f", "name=repo") in fields
    for index, value in enumerate(_HOSTILE_VALUES):
        assert ("-f", f"branch{index}={value}") in fields
    assert not [flag for flag, _ in fields if flag == "-F"]


def test_adapters_use_typed_field_only_for_the_int_number_variable() -> None:
    """`-F` coerces null/true/digits/@file; only a genuine Int may use it."""
    adapters = OPS / "delivery_control" / "adapters"
    typed: list[tuple[str, int]] = []
    for path in sorted(adapters.glob("*.py")):
        if path.name == "github_client.py":  # classifies both flags, sends none
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"))
        typed.extend(
            (path.name, node.lineno)
            for node in ast.walk(tree)
            if isinstance(node, ast.Constant) and node.value == "-F"
        )
    assert [name for name, _ in typed] == ["github_issue_commands.py"]
    source = (adapters / "github_issue_commands.py").read_text(encoding="utf-8")
    assert (
        'for variable, int_value in int_variables:\n            argv.extend(("-F"'
        in source
    )
