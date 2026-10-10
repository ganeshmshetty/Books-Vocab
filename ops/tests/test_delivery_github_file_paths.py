from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.errors import AdapterPayloadError  # noqa: E402
from delivery_control.adapters.github_file_paths import (  # noqa: E402
    PullRequestFilePathBatch,
    parse_open_pull_request_file_pages,
)
from delivery_control.adapters.github_queries import GitHubQueries  # noqa: E402
from delivery_control.adapters.github_parsing import parse_pull_request_inventory  # noqa: E402


def _page(
    nodes: list[dict[str, Any]],
    *,
    has_next: bool = False,
    end_cursor: str | None = None,
) -> dict[str, Any]:
    return {
        "data": {
            "repository": {
                "pullRequests": {
                    "nodes": nodes,
                    "pageInfo": {"hasNextPage": has_next, "endCursor": end_cursor},
                }
            }
        }
    }


def _pr(
    number: int, files: list[dict[str, str]], *, has_next: bool = False
) -> dict[str, Any]:
    return {
        "number": number,
        "files": {
            "nodes": files,
            "pageInfo": {
                "hasNextPage": has_next,
                "endCursor": "file-next" if has_next else None,
            },
        },
    }


def _file(path: str, change_type: str) -> dict[str, str]:
    return {"path": path, "changeType": change_type}


def test_parser_returns_sorted_paths_for_safe_change_types() -> None:
    result = parse_open_pull_request_file_pages(
        _page(
            [
                _pr(
                    12,
                    [_file("ops/z.py", "MODIFIED"), _file("ops/a.py", "ADDED")],
                )
            ]
        )
    )

    assert result == PullRequestFilePathBatch(
        {12: ("ops/a.py", "ops/z.py")}, frozenset()
    )


def test_parser_falls_back_for_renames_and_large_file_connections() -> None:
    result = parse_open_pull_request_file_pages(
        _page(
            [
                _pr(12, [_file("ops/new.py", "RENAMED")]),
                _pr(13, [_file("ops/large.py", "MODIFIED")], has_next=True),
            ]
        )
    )

    assert result.paths_by_number == {}
    assert result.fallback_numbers == frozenset({12, 13})


def test_parser_combines_outer_pages_and_rejects_incomplete_pagination() -> None:
    payload = [
        _page(
            [_pr(12, [_file("ops/a.py", "ADDED")])], has_next=True, end_cursor="next"
        ),
        _page([_pr(13, [_file("ops/b.py", "DELETED")])]),
    ]

    result = parse_open_pull_request_file_pages(payload)

    assert result.paths_by_number == {12: ("ops/a.py",), 13: ("ops/b.py",)}
    with pytest.raises(AdapterPayloadError, match="ended before"):
        parse_open_pull_request_file_pages(
            [_page([_pr(12, [_file("ops/a.py", "ADDED")])]), _page([])]
        )


def test_parser_rejects_graphql_errors_and_duplicate_prs() -> None:
    with pytest.raises(AdapterPayloadError, match="GraphQL"):
        parse_open_pull_request_file_pages({"errors": [{"message": "rate limit"}]})
    with pytest.raises(AdapterPayloadError, match="duplicate PR"):
        parse_open_pull_request_file_pages(_page([_pr(12, []), _pr(12, [])]))


class FakeClient:
    def __init__(self, responses: list[object]) -> None:
        self.responses = list(responses)
        self.calls: list[tuple[str, ...]] = []

    def load_json(
        self, argv: tuple[str, ...], *, allow_nonzero: bool = False
    ) -> object:
        self.calls.append(argv)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def _pr_inventory_payload() -> list[dict[str, object]]:
    return [
        {
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
            "body": "body",
            "autoMergeRequest": None,
        }
    ]


def test_queries_prime_one_graphql_batch_and_cache_safe_paths() -> None:
    client = FakeClient(
        [
            _pr_inventory_payload(),
            _page(
                [_pr(12, [_file("ops/z.py", "MODIFIED"), _file("ops/a.py", "ADDED")])]
            ),
        ]
    )
    queries = GitHubQueries(
        client=client,
        repository_name=lambda: "owner/repo",
        pull_request_inventory_parser=parse_pull_request_inventory,
    )

    queries.list_open_pull_requests()

    assert queries.changed_paths(12) == ("ops/a.py", "ops/z.py")
    assert queries.changed_paths(12) == ("ops/a.py", "ops/z.py")
    assert len(client.calls) == 2
    assert client.calls[1][:5] == ("gh", "api", "graphql", "--paginate", "--slurp")


def test_queries_uses_rest_fallback_for_rename() -> None:
    client = FakeClient(
        [
            _pr_inventory_payload(),
            _page([_pr(12, [_file("ops/new.py", "RENAMED")])]),
            [
                {
                    "filename": "ops/new.py",
                    "previous_filename": "ops/old.py",
                    "status": "renamed",
                }
            ],
        ]
    )
    queries = GitHubQueries(
        client=client,
        repository_name=lambda: "owner/repo",
        pull_request_inventory_parser=parse_pull_request_inventory,
    )

    queries.list_open_pull_requests()

    assert queries.changed_paths(12) == ("ops/new.py", "ops/old.py")
    assert len(client.calls) == 3
    assert client.calls[2][-1] == "repos/owner/repo/pulls/12/files?per_page=100&page=1"
