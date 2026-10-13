from __future__ import annotations

import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.errors import AdapterPayloadError
from delivery_control.adapters.github_cli import GitHubCliAdapter
from delivery_control.adapters.github_client import GitHubCliClient
from delivery_control.adapters.github_queries import GitHubQueries
from delivery_control.adapters.github_queue import (
    GitHubQueueGraphQLAdapter,
)
from delivery_control.adapters.rest_conditional_cache import (
    ConditionalRestCache,
    RestReadError,
)
from delivery_control.ports.process import CommandResult


class StaticRunner:
    def __init__(self, responses: list[CommandResult]) -> None:
        self.responses = list(responses)
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        self.calls.append(argv)
        return self.responses.pop(0)


def _state(
    *,
    pull_request_id: str = "PR_kwDOexample",
    number: int = 12,
    head: str = "b" * 40,
    entry_id: str | None = None,
) -> dict[str, object]:
    return {
        "id": pull_request_id,
        "number": number,
        "baseRefName": "main",
        "baseRefOid": "a" * 40,
        "headRefOid": head,
        "body": "body",
        "state": "OPEN",
        "mergeQueueEntry": (
            {"id": entry_id, "enqueuedAt": "2026-08-22T12:00:00Z"} if entry_id else None
        ),
    }


def _page(*nodes: dict[str, object]) -> dict[str, object]:
    return {
        "data": {
            "repository": {
                "pullRequests": {
                    "nodes": list(nodes),
                    "pageInfo": {"hasNextPage": False, "endCursor": "end"},
                }
            }
        }
    }


def _node_payload(*, number: int = 12, head: str = "b" * 40) -> dict[str, object]:
    return {
        "id": "PR_kwDOexample",
        "number": number,
        "url": f"https://example.test/pull/{number}",
        "headRefName": "feat/one",
        "baseRefName": "main",
        "baseRefOid": "a" * 40,
        "headRefOid": head,
        "state": "OPEN",
        "isDraft": False,
        "mergeable": "MERGEABLE",
        "title": "fix: one",
        "body": "body",
        "autoMergeRequest": None,
    }


def test_queue_batch_is_consumed_once_and_mutation_snapshot_stays_live() -> None:
    batch = _page(_state(), _state(pull_request_id="PR_kwDOsecond", number=13))
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps(batch), ""),
            CommandResult(("gh",), 0, json.dumps({"data": {"node": _state()}}), ""),
        ]
    )
    queue = GitHubQueueGraphQLAdapter(repo=Path("/repo"), runner=runner)

    queue.prime_open_snapshots(repository_name="owner/repo")
    assert queue.observed_snapshot("PR_kwDOexample").head_sha == "b" * 40
    assert queue.observed_snapshot("PR_kwDOexample").head_sha == "b" * 40
    assert len(runner.calls) == 2
    assert "--paginate" in runner.calls[0]
    assert "DeliveryQueueState" in " ".join(runner.calls[1])


def test_adapter_reuses_open_pr_snapshot_once_then_refreshes() -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh", "pr", "list"), 0, json.dumps([_node_payload()]), ""),
            CommandResult(
                ("gh", "repo", "view"),
                0,
                json.dumps({"nameWithOwner": "owner/repo"}),
                "",
            ),
            CommandResult(("gh", "graphql"), 0, json.dumps(_page(_state())), ""),
            CommandResult(
                ("gh", "pr", "view"),
                0,
                json.dumps(_node_payload(head="c" * 40)),
                "",
            ),
        ]
    )
    adapter = GitHubCliAdapter(repo=Path("/repo"), runner=runner)

    adapter.list_open_pull_requests()
    adapter.prime_open_observations()

    assert adapter.get_pull_request(12).head_sha == "b" * 40
    assert adapter.get_pull_request(12).head_sha == "c" * 40
    assert sum(1 for call in runner.calls if call[:3] == ("gh", "pr", "view")) == 1


def test_pr_mutation_bypasses_read_only_snapshot_cache() -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh", "pr", "list"), 0, json.dumps([_node_payload()]), ""),
            CommandResult(
                ("gh", "pr", "view"),
                0,
                json.dumps(_node_payload(head="c" * 40)),
                "",
            ),
            CommandResult(("gh", "pr", "edit"), 0, "", ""),
            CommandResult(
                ("gh", "pr", "view"),
                0,
                json.dumps(_node_payload(head="c" * 40)),
                "",
            ),
            CommandResult(
                ("gh", "pr", "view"),
                0,
                json.dumps(_node_payload(head="c" * 40)),
                "",
            ),
        ]
    )
    adapter = GitHubCliAdapter(repo=Path("/repo"), runner=runner)

    adapter.list_open_pull_requests()
    updated = adapter.update_pull_request(
        number=12,
        title="fix: updated",
        body="updated body",
        expected_head_sha="c" * 40,
    )

    assert updated.head_sha == "c" * 40
    assert adapter.get_pull_request(12).head_sha == "c" * 40
    assert sum(1 for call in runner.calls if call[:3] == ("gh", "pr", "view")) == 3


def test_required_observations_are_primed_once_after_open_inventory() -> None:
    runner = StaticRunner(
        [CommandResult(("gh", "pr", "list"), 0, json.dumps([_node_payload()]), "")]
    )
    adapter = GitHubCliAdapter(repo=Path("/repo"), runner=runner)
    calls: list[tuple[int, ...]] = []
    sentinel = object()
    adapter._checks.prime_required_snapshots = lambda numbers: calls.append(numbers)
    adapter._checks.required_snapshot = lambda number: sentinel

    adapter.list_open_pull_requests()

    assert adapter.required_check_snapshot(12) is sentinel
    assert adapter.required_check_snapshot(12) is sentinel
    assert calls == [(12,)]


def test_malformed_queue_batch_falls_back_to_exact_live_snapshot() -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, json.dumps({"data": {"repository": None}}), ""),
            CommandResult(
                ("gh",), 0, json.dumps({"data": {"node": _state(entry_id="MQE_1")}}), ""
            ),
        ]
    )
    queue = GitHubQueueGraphQLAdapter(repo=Path("/repo"), runner=runner)

    queue.prime_open_snapshots(repository_name="owner/repo")

    assert queue.observed_snapshot("PR_kwDOexample").entry_id == "MQE_1"
    assert "DeliveryQueueState" in " ".join(runner.calls[1])


def _http(
    status: int,
    body: str = "",
    *,
    etag: str | None = None,
    remaining: int | None = None,
    reset: int | None = None,
) -> str:
    """Render ``gh api --include`` stdout: status line, headers, blank line, body."""

    lines = [f"HTTP/2.0 {status} {'OK' if status == 200 else 'Not Modified'}"]
    if etag is not None:
        lines.append(f"Etag: {etag}")
    if remaining is not None:
        lines.append(f"X-Ratelimit-Remaining: {remaining}")
        lines.append(f"X-Ratelimit-Reset: {reset if reset is not None else 4102444800}")
        lines.append("X-Ratelimit-Resource: core")
    return "\r\n".join(lines) + "\r\n\r\n" + body


_FILES_URL = "repos/owner/repo/pulls/12/files?per_page=100&page=1"
_FILES_ARGV = ("gh", "api", _FILES_URL)


def test_api_read_stores_etag_and_revalidates_with_304(tmp_path: Path) -> None:
    body = json.dumps([{"filename": "ops/a.py", "status": "added"}])
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, _http(200, body, etag='"v1"'), ""),
            CommandResult(("gh",), 0, _http(304, etag='"v1"'), ""),
        ]
    )
    client = GitHubCliClient(repo=tmp_path, runner=runner, cache_dir=tmp_path / "c")

    assert client.load_json(_FILES_ARGV) == json.loads(body)
    assert client.load_json(_FILES_ARGV) == json.loads(body)

    assert 'If-None-Match: "v1"' not in runner.calls[0]
    assert 'If-None-Match: "v1"' in runner.calls[1]
    assert len(runner.calls) == 2


def test_api_read_invalidates_cache_on_change_and_on_untagged_response(
    tmp_path: Path,
) -> None:
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, _http(200, '["A"]', etag='"v1"'), ""),
            CommandResult(("gh",), 0, _http(200, '["B"]', etag='"v2"'), ""),
            CommandResult(("gh",), 0, _http(200, '["C"]'), ""),
            CommandResult(("gh",), 0, _http(200, '["D"]', etag='"v4"'), ""),
        ]
    )
    client = GitHubCliClient(repo=tmp_path, runner=runner, cache_dir=tmp_path / "c")

    assert client.load_json(_FILES_ARGV) == ["A"]
    assert client.load_json(_FILES_ARGV) == ["B"]
    assert client.load_json(_FILES_ARGV) == ["C"]
    assert 'If-None-Match: "v2"' in runner.calls[2]
    assert client.load_json(_FILES_ARGV) == ["D"]
    assert not any("If-None-Match" in part for part in runner.calls[3])


def test_changed_paths_pages_are_revalidated_per_page(tmp_path: Path) -> None:
    page_one = json.dumps(
        [{"filename": f"ops/f{index}.py", "status": "modified"} for index in range(100)]
    )
    page_two = json.dumps([{"filename": "ops/last.py", "status": "added"}])
    runner = StaticRunner(
        [
            CommandResult(("gh",), 0, _http(200, page_one, etag='"p1"'), ""),
            CommandResult(("gh",), 0, _http(200, page_two, etag='"p2"'), ""),
            CommandResult(("gh",), 0, _http(304, etag='"p1"'), ""),
            CommandResult(("gh",), 0, _http(304, etag='"p2"'), ""),
        ]
    )
    client = GitHubCliClient(repo=tmp_path, runner=runner, cache_dir=tmp_path / "c")
    queries = GitHubQueries(client=client, repository_name=lambda: "owner/repo")

    first = queries.changed_paths(12)
    second = GitHubQueries(client=client, repository_name=lambda: "owner/repo")
    paths = second.changed_paths(12)

    assert len(first) == 101
    assert paths == first
    assert [call[-1].split("&page=")[1] for call in runner.calls] == [
        "1",
        "2",
        "1",
        "2",
    ]
    assert 'If-None-Match: "p1"' in runner.calls[2]
    assert 'If-None-Match: "p2"' in runner.calls[3]


class RestRunner:
    """Scripted ``gh api --include`` replies for the legacy delivery script's runner."""

    def __init__(self, replies: list[tuple[int, str]]) -> None:
        self.replies = list(replies)
        self.calls: list[list[str]] = []

    def __call__(self, argv: list[str], cwd: Path | None) -> SimpleNamespace:
        self.calls.append(list(argv))
        code, stdout = self.replies.pop(0)
        return SimpleNamespace(returncode=code, stdout=stdout, stderr="")


_RUN_URL = "repos/owner/repo/actions/runs/7"


def test_rest_read_304_hit_serves_the_cached_body(tmp_path: Path) -> None:
    runner = RestRunner(
        [(0, _http(200, '{"id": 7}', etag='"r1"')), (0, _http(304, etag='"r1"'))]
    )
    rest = ConditionalRestCache(runner, tmp_path / "c")

    assert rest.get(_RUN_URL, tmp_path) == {"id": 7}
    assert rest.get(_RUN_URL, tmp_path) == {"id": 7}

    assert "If-None-Match" not in " ".join(runner.calls[0])
    assert 'If-None-Match: "r1"' in runner.calls[1]
    assert len(runner.calls) == 2


def test_rest_read_invalidates_on_change_and_on_untagged_response(
    tmp_path: Path,
) -> None:
    runner = RestRunner(
        [
            (0, _http(200, '["A"]', etag='"v1"')),
            (0, _http(200, '["B"]', etag='"v2"')),
            (0, _http(200, '["C"]')),
            (0, _http(200, '["D"]', etag='"v4"')),
        ]
    )
    rest = ConditionalRestCache(runner, tmp_path / "c")

    assert rest.get(_RUN_URL, tmp_path) == ["A"]
    assert rest.get(_RUN_URL, tmp_path) == ["B"]
    assert 'If-None-Match: "v1"' in " ".join(runner.calls[1])
    assert rest.get(_RUN_URL, tmp_path) == ["C"]
    assert 'If-None-Match: "v2"' in " ".join(runner.calls[2])
    assert rest.get(_RUN_URL, tmp_path) == ["D"]
    assert "If-None-Match" not in " ".join(runner.calls[3])


def test_rest_read_error_status_raises_and_stores_nothing(tmp_path: Path) -> None:
    runner = RestRunner([(1, _http(404, '{"message": "Not Found"}'))])
    rest = ConditionalRestCache(runner, tmp_path / "c")

    with pytest.raises(RestReadError, match="404"):
        rest.get(_RUN_URL, tmp_path)
    assert list((tmp_path / "c").rglob("*.json")) == []


def test_rest_read_without_headers_returns_body_uncached(tmp_path: Path) -> None:
    runner = RestRunner([(0, '{"id": 7}')])
    rest = ConditionalRestCache(runner, tmp_path / "c")

    assert rest.get(_RUN_URL, tmp_path) == {"id": 7}
    assert list((tmp_path / "c").rglob("*.json")) == []


_PULLS = "repos/owner/repo/pulls?state=closed&per_page=100"


def test_rest_pages_are_revalidated_one_by_one(tmp_path: Path) -> None:
    full = json.dumps([{"number": n} for n in range(100)])
    tail = json.dumps([{"number": 100}])
    runner = RestRunner(
        [
            (0, _http(200, full, etag='"p1"')),
            (0, _http(200, tail, etag='"p2"')),
            (0, _http(304, etag='"p1"')),
            (0, _http(304, etag='"p2"')),
        ]
    )
    rest = ConditionalRestCache(runner, tmp_path / "c")

    first = rest.get_pages(_PULLS, tmp_path)
    second = rest.get_pages(_PULLS, tmp_path)

    assert len(first) == 101
    assert second == first
    assert [call[-1].rsplit("page=", 1)[1] for call in runner.calls] == [
        "1",
        "2",
        "1",
        "2",
    ]
    assert 'If-None-Match: "p2"' in " ".join(runner.calls[3])


def test_rest_pages_select_the_named_key(tmp_path: Path) -> None:
    body = json.dumps({"total_count": 1, "check_runs": [{"name": "agent-review"}]})
    runner = RestRunner([(0, _http(200, body, etag='"c1"'))])
    rest = ConditionalRestCache(runner, tmp_path / "c")

    runs = rest.get_pages(
        "repos/owner/repo/commits/abc/check-runs?check_name=x&per_page=100",
        tmp_path,
        key="check_runs",
    )

    assert runs == [{"name": "agent-review"}]


def _files_page(page: int, size: int) -> str:
    return json.dumps(
        [
            {"filename": f"ops/p{page}_{index}.py", "status": "modified"}
            for index in range(size)
        ]
    )


def test_changed_paths_accepts_exactly_the_pagination_bound(tmp_path: Path) -> None:
    # 30 full pages is 3000 files; an empty page 31 proves the PR is complete, not truncated.
    responses = [
        CommandResult(
            ("gh",), 0, _http(200, _files_page(page, 100), etag=f'"p{page}"'), ""
        )
        for page in range(1, 31)
    ]
    responses.append(CommandResult(("gh",), 0, _http(200, "[]", etag='"p31"'), ""))
    runner = StaticRunner(responses)
    client = GitHubCliClient(repo=tmp_path, runner=runner, cache_dir=tmp_path / "c")
    queries = GitHubQueries(client=client, repository_name=lambda: "owner/repo")

    paths = queries.changed_paths(12)

    assert len(paths) == 3000
    assert len(runner.calls) == 31


def test_changed_paths_rejects_a_pr_with_more_than_the_pagination_bound(
    tmp_path: Path,
) -> None:
    responses = [
        CommandResult(
            ("gh",), 0, _http(200, _files_page(page, 100), etag=f'"p{page}"'), ""
        )
        for page in range(1, 31)
    ]
    responses.append(
        CommandResult(("gh",), 0, _http(200, _files_page(31, 1), etag='"p31"'), "")
    )
    runner = StaticRunner(responses)
    client = GitHubCliClient(repo=tmp_path, runner=runner, cache_dir=tmp_path / "c")
    queries = GitHubQueries(client=client, repository_name=lambda: "owner/repo")

    with pytest.raises(AdapterPayloadError, match="pagination bound"):
        queries.changed_paths(12)
