from __future__ import annotations

import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.github_client import GitHubCliClient
from delivery_control.adapters.github_required_batch import batch_required_snapshots
from delivery_control.ports.process import CommandResult

HEAD = "a" * 40
FETCHED = 1_000_000.0
_REPO_VIEW = ("gh", "repo", "view")
_GRAPHQL = ("gh", "api", "graphql")


class StaticRunner:
    def __init__(self, responses: list[CommandResult]) -> None:
        self.responses = list(responses)
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        self.calls.append(argv)
        return self.responses.pop(0)


def _required_pr_body(number: int = 12) -> dict[str, object]:
    context = {
        "__typename": "CheckRun",
        "name": "required",
        "status": "COMPLETED",
        "conclusion": "SUCCESS",
        "startedAt": "2026-08-23T00:00:00Z",
        "completedAt": "2026-08-23T00:00:01Z",
        "isRequired": True,
    }
    return {
        "data": {
            "repository": {
                f"pr_{number}": {
                    "number": number,
                    "headRefOid": HEAD,
                    "commits": {
                        "nodes": [
                            {
                                "commit": {
                                    "statusCheckRollup": {
                                        "contexts": {
                                            "pageInfo": {"hasNextPage": False},
                                            "nodes": [context],
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


def _graphql_http(remaining: int) -> str:
    head = (
        "HTTP/2.0 200 OK\r\n"
        f"X-Ratelimit-Remaining: {remaining}\r\n"
        f"X-Ratelimit-Reset: {int(FETCHED) + 3600}\r\n"
        "X-Ratelimit-Resource: graphql\r\n\r\n"
    )
    return head + json.dumps(_required_pr_body())


def test_required_snapshot_under_low_quota_is_revalidated_live(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    cache = tmp_path / "cache"
    first = StaticRunner(
        [
            CommandResult(
                _REPO_VIEW, 0, json.dumps({"nameWithOwner": "owner/repo"}), ""
            ),
            CommandResult(_GRAPHQL, 0, _graphql_http(remaining=500), ""),
        ]
    )
    batch_required_snapshots(
        GitHubCliClient(
            repo=tmp_path, runner=first, cache_dir=cache, now=lambda: FETCHED
        ),
        (12,),
    )

    # Low quota must not admit the body fetched 60s ago: the gate re-reads GraphQL.
    second = StaticRunner(
        [
            CommandResult(
                _REPO_VIEW, 0, json.dumps({"nameWithOwner": "owner/repo"}), ""
            ),
            CommandResult(_GRAPHQL, 0, _graphql_http(remaining=499), ""),
        ]
    )
    client = GitHubCliClient(
        repo=tmp_path, runner=second, cache_dir=cache, now=lambda: FETCHED + 60
    )
    snapshots = batch_required_snapshots(client, (12,))

    assert len(second.calls) == 2
    assert snapshots[12].observed_at == datetime.fromtimestamp(FETCHED + 60, tz=UTC)
