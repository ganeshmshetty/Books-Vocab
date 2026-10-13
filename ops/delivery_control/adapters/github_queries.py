"""Read-only GitHub CLI queries for Issues, pull requests, and changed files."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from datetime import datetime
from typing import Any

from ..domain.candidate_issues import CANDIDATE_ISSUE_LABEL, CandidateIssueInventory
from ..domain.errors import DeliverySourceError
from ..domain.observations import PullRequestInventory, PullRequestSnapshot
from .errors import AdapterPayloadError
from .github_client import GitHubCliClient
from .github_file_paths import parse_open_pull_request_file_pages
from .github_parsing import (
    parse_candidate_issue_inventory,
    parse_changed_paths,
    parse_merge_times,
    parse_pull_request,
    parse_pull_request_inventory,
)

PR_FIELDS = (
    "id,number,url,headRefName,baseRefName,baseRefOid,headRefOid,state,isDraft,mergeable,title,body,"
    "autoMergeRequest,labels,createdAt,mergedAt,reviewDecision"
)

_PR_FILES_PAGE_SIZE = 100
_PR_FILES_MAX_PAGES = 30

OPEN_PR_FILES_QUERY = """
query DeliveryOpenPullRequestFiles($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(first: 100, states: OPEN, after: $endCursor) {
      nodes {
        number
        files(first: 100) {
          nodes { path changeType }
          pageInfo { hasNextPage endCursor }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
""".strip()

_PR_HISTORY_NODE_FIELDS = """
nodes {
  id
  number
  url
  headRefName
  baseRefName
  baseRefOid
  headRefOid
  state
  isDraft
  mergeable
  title
  body
  autoMergeRequest { __typename }
  labels(first: 100) {
    nodes { name }
    pageInfo { hasNextPage endCursor }
  }
  createdAt
  mergedAt
  reviewDecision
}
pageInfo { hasNextPage endCursor }
""".strip()


def _pull_request_history_query(branches: tuple[str, ...]) -> str:
    variables = ["$owner: String!", "$name: String!"]
    selections: list[str] = []
    for index in range(len(branches)):
        variable = f"$branch{index}"
        variables.append(f"{variable}: String!")
        selections.append(
            f"branch{index}: pullRequests("
            f"first: 100, states: [OPEN, CLOSED, MERGED], "
            f"headRefName: {variable}) {{\n{_PR_HISTORY_NODE_FIELDS}\n}}"
        )
    return (
        "query DeliveryPullRequestHistoryByBranch("
        + ", ".join(variables)
        + ") {\n"
        + "  repository(owner: $owner, name: $name) {\n"
        + "\n".join(f"    {selection}" for selection in selections)
        + "\n  }\n}"
    )


def _parse_pull_request_history_by_branch(
    payload: object, branches: tuple[str, ...]
) -> PullRequestInventory:
    if not isinstance(payload, Mapping):
        raise AdapterPayloadError("GitHub PR history GraphQL payload is malformed")
    if payload.get("errors"):
        raise AdapterPayloadError("GitHub PR history GraphQL response contains errors")
    data = payload.get("data")
    repository = data.get("repository") if isinstance(data, Mapping) else None
    if not isinstance(repository, Mapping):
        raise AdapterPayloadError("GitHub PR history repository payload is malformed")

    records: list[dict[str, Any]] = []
    for index, branch in enumerate(branches):
        connection = repository.get(f"branch{index}")
        if not isinstance(connection, Mapping):
            raise AdapterPayloadError(
                f"GitHub PR history branch[{index}] connection is malformed"
            )
        nodes = connection.get("nodes")
        page_info = connection.get("pageInfo")
        if not isinstance(nodes, list) or any(
            not isinstance(node, Mapping) for node in nodes
        ):
            raise AdapterPayloadError(
                f"GitHub PR history branch[{index}] nodes are malformed"
            )
        if (
            not isinstance(page_info, Mapping)
            or type(page_info.get("hasNextPage")) is not bool
        ):
            raise AdapterPayloadError(
                f"GitHub PR history branch[{index}] pageInfo is malformed"
            )
        if page_info["hasNextPage"]:
            raise AdapterPayloadError(
                f"GitHub PR history branch[{index}] pagination is incomplete"
            )
        for node in nodes:
            if node.get("headRefName") != branch:
                raise AdapterPayloadError(
                    f"GitHub PR history branch[{index}] returned a mismatched head"
                )
            labels = node.get("labels")
            if not isinstance(labels, Mapping):
                raise AdapterPayloadError(
                    "GitHub PR history labels connection is malformed"
                )
            label_page_info = labels.get("pageInfo")
            if (
                not isinstance(label_page_info, Mapping)
                or type(label_page_info.get("hasNextPage")) is not bool
            ):
                raise AdapterPayloadError(
                    "GitHub PR history labels pageInfo is malformed"
                )
            if label_page_info["hasNextPage"]:
                raise AdapterPayloadError(
                    "GitHub PR history label inventory is incomplete"
                )
            label_nodes = labels.get("nodes")
            if not isinstance(label_nodes, list):
                raise AdapterPayloadError(
                    "GitHub PR history labels nodes are malformed"
                )
            mapped = dict(node)
            mapped["labels"] = label_nodes
            if mapped.get("body") is None:
                mapped["body"] = ""
            records.append(mapped)
    return parse_pull_request_inventory(records)


class GitHubQueries:
    def __init__(
        self,
        *,
        client: GitHubCliClient,
        repository_name: Callable[[], str],
        pull_request_parser: Callable[
            [Mapping[str, Any]], PullRequestSnapshot
        ] = parse_pull_request,
        pull_request_inventory_parser: Callable[
            [object], PullRequestInventory
        ] = parse_pull_request_inventory,
        candidate_inventory_parser: Callable[
            [object], CandidateIssueInventory
        ] = parse_candidate_issue_inventory,
    ) -> None:
        self.client = client
        self.repository_name = repository_name
        self.pull_request_parser = pull_request_parser
        self.pull_request_inventory_parser = pull_request_inventory_parser
        self.candidate_inventory_parser = candidate_inventory_parser
        self._known_open_pr_numbers: frozenset[int] = frozenset()
        self._open_file_batch_attempted = False
        self._changed_paths_cache: dict[int, tuple[str, ...]] = {}

    def list_open_candidate_issues(self) -> CandidateIssueInventory:
        payload = self.client.load_json(
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
        )
        return self.candidate_inventory_parser(payload)

    def list_open_pull_requests(self) -> PullRequestInventory:
        payload = self.client.load_json(
            (
                "gh",
                "pr",
                "list",
                "--state",
                "open",
                "--limit",
                "200",
                "--json",
                PR_FIELDS,
            )
        )
        inventory = self.pull_request_inventory_parser(payload)
        self._known_open_pr_numbers = frozenset(
            item.number for item in inventory.records
        )
        self._open_file_batch_attempted = False
        self._changed_paths_cache = {}
        return inventory

    def list_pull_requests_for_branch(self, branch: str) -> PullRequestInventory:
        payload = self.client.load_json(
            (
                "gh",
                "pr",
                "list",
                "--state",
                "all",
                "--head",
                branch,
                "--limit",
                "100",
                "--json",
                PR_FIELDS,
            )
        )
        return self.pull_request_inventory_parser(payload)

    def list_pull_requests_for_branches(
        self, branches: tuple[str, ...]
    ) -> PullRequestInventory:
        """Read exact branch PR history in one bounded GraphQL request."""

        ordered_branches = tuple(dict.fromkeys(branches))
        if not ordered_branches:
            return PullRequestInventory(())
        repository = self.repository_name()
        owner, separator, name = repository.partition("/")
        if not separator or not owner or not name or "/" in name:
            raise AdapterPayloadError("GitHub repository name must be owner/name")
        payload = self.client.load_json(
            (
                "gh",
                "api",
                "graphql",
                "-f",
                f"query={_pull_request_history_query(ordered_branches)}",
                "-f",
                f"owner={owner}",
                "-f",
                f"name={name}",
                *[
                    argument
                    for index, branch in enumerate(ordered_branches)
                    for argument in ("-f", f"branch{index}={branch}")
                ],
            )
        )
        return _parse_pull_request_history_by_branch(payload, ordered_branches)

    def recent_merge_times(self, *, limit: int = 100) -> tuple[datetime, ...]:
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ValueError("merge history limit must be between 1 and 100")
        payload = self.client.load_json(
            (
                "gh",
                "pr",
                "list",
                "--state",
                "merged",
                "--limit",
                str(limit),
                "--json",
                "mergedAt",
            )
        )
        return parse_merge_times(payload)

    def get_pull_request(self, number: int) -> PullRequestSnapshot:
        payload = self.client.load_json(
            ("gh", "pr", "view", str(number), "--json", PR_FIELDS)
        )
        if not isinstance(payload, Mapping):
            raise AdapterPayloadError("GitHub PR view must be a JSON object")
        return self.pull_request_parser(payload)

    def changed_paths(self, number: int) -> tuple[str, ...]:
        if (
            not self._open_file_batch_attempted
            and number in self._known_open_pr_numbers
        ):
            self._prime_open_pr_file_paths()
        cached = self._changed_paths_cache.get(number)
        if cached is not None:
            return cached
        return self._list_pull_request_files(number)

    def _list_pull_request_files(self, number: int) -> tuple[str, ...]:
        """Walk REST PR files page by page so each page is ETag-revalidated."""

        repository = self.repository_name()
        pages: list[object] = []
        # One probe page past the bound: a full last page is only truncation if more follows.
        for page in range(1, _PR_FILES_MAX_PAGES + 2):
            payload = self.client.load_json(
                (
                    "gh",
                    "api",
                    f"repos/{repository}/pulls/{number}/files?per_page={_PR_FILES_PAGE_SIZE}&page={page}",
                )
            )
            if not isinstance(payload, list):
                raise AdapterPayloadError("GitHub PR files page is malformed")
            if page > _PR_FILES_MAX_PAGES:
                if payload:
                    raise AdapterPayloadError(
                        f"GitHub PR #{number} exceeds the "
                        f"{_PR_FILES_MAX_PAGES * _PR_FILES_PAGE_SIZE}-file pagination bound"
                    )
                break
            pages.append(payload)
            if len(payload) < _PR_FILES_PAGE_SIZE:
                break
        return parse_changed_paths(pages)

    def _prime_open_pr_file_paths(self) -> None:
        self._open_file_batch_attempted = True
        try:
            repository_name = self.repository_name()
            owner, separator, name = repository_name.partition("/")
            if not separator or not owner or not name or "/" in name:
                raise AdapterPayloadError("GitHub repository name must be owner/name")
            payload = self.client.load_json(
                (
                    "gh",
                    "api",
                    "graphql",
                    "--paginate",
                    "--slurp",
                    "-f",
                    f"query={OPEN_PR_FILES_QUERY}",
                    "-f",
                    f"owner={owner}",
                    "-f",
                    f"name={name}",
                )
            )
            batch = parse_open_pull_request_file_pages(payload)
        except DeliverySourceError:
            return
        self._changed_paths_cache.update(batch.paths_by_number)
