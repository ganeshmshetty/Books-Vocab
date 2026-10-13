"""Bounded GraphQL batch reader for required GitHub check observations."""

from __future__ import annotations

import re
from collections.abc import Mapping
from datetime import UTC, datetime

from ..domain.check_states import FAILURE_STATES, SUCCESS_STATES, TERMINAL_STATES
from ..domain.models import CheckStatus
from ..domain.observations import CheckSnapshot
from .errors import AdapterPayloadError
from .github_client import GitHubCliClient
from .timestamps import parse_optional_timestamp

_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_MAX_BATCH_SIZE = 50
_FAILURE_STATES = FAILURE_STATES
_SUCCESS_STATES = SUCCESS_STATES
_TERMINAL_STATES = TERMINAL_STATES


def _status_from_states(states: set[str]) -> CheckStatus:
    if not states:
        return CheckStatus.ABSENT
    if states & _FAILURE_STATES:
        return CheckStatus.FAILURE
    if states <= _SUCCESS_STATES:
        return CheckStatus.SUCCESS
    return CheckStatus.PENDING


def _context_recency_key(
    *,
    started_at: datetime | None,
    completed_at: datetime | None,
    index: int,
) -> tuple[datetime, datetime, datetime, int]:
    earliest = datetime.min.replace(tzinfo=UTC)
    return (
        completed_at or started_at or earliest,
        completed_at or earliest,
        started_at or earliest,
        index,
    )


def _prefer_newer_context(
    candidate: tuple[str, datetime | None, datetime | None, int],
    previous: tuple[str, datetime | None, datetime | None, int],
) -> bool:
    # A timestamp-less pending duplicate cannot safely be proven stale.  Keep
    # it as the observation so a stale terminal result never masks liveness.
    candidate_unstamped_pending = (
        candidate[0] not in _TERMINAL_STATES
        and candidate[1] is None
        and candidate[2] is None
    )
    previous_unstamped_pending = (
        previous[0] not in _TERMINAL_STATES
        and previous[1] is None
        and previous[2] is None
    )
    if candidate_unstamped_pending != previous_unstamped_pending:
        return candidate_unstamped_pending
    return _context_recency_key(
        started_at=candidate[1],
        completed_at=candidate[2],
        index=candidate[3],
    ) >= _context_recency_key(
        started_at=previous[1],
        completed_at=previous[2],
        index=previous[3],
    )


def _required_checks_query(numbers: tuple[int, ...]) -> str:
    fragments: list[str] = []
    for number in numbers:
        fragments.append(
            f"""
      pr_{number}: pullRequest(number: {number}) {{
        number
        headRefOid
        commits(last: 1) {{
          nodes {{
            commit {{
              statusCheckRollup {{
                contexts(first: 100) {{
                  pageInfo {{
                    hasNextPage
                  }}
                  nodes {{
                    __typename
                    ... on CheckRun {{
                      name
                      status
                      conclusion
                      startedAt
                      completedAt
                      isRequired(pullRequestNumber: {number})
                    }}
                    ... on StatusContext {{
                      context
                      state
                      isRequired(pullRequestNumber: {number})
                    }}
                  }}
                }}
              }}
            }}
          }}
        }}
      }}"""
        )
    return (
        "query DeliveryRequiredChecks($owner: String!, $name: String!) {"
        " repository(owner: $owner, name: $name) {" + "".join(fragments) + " } }"
    )


def _repository_name(client: GitHubCliClient) -> tuple[str, str]:
    payload = client.load_json(("gh", "repo", "view", "--json", "nameWithOwner"))
    if (
        not isinstance(payload, Mapping)
        or type(payload.get("nameWithOwner")) is not str
    ):
        raise AdapterPayloadError("GitHub repository identity is malformed")
    owner, separator, name = payload["nameWithOwner"].partition("/")
    if not separator or not owner or not name or "/" in name:
        raise AdapterPayloadError("GitHub repository identity must be owner/name")
    return owner, name


def _snapshot_from_node(
    node: object, *, number: int, observed_at: datetime
) -> CheckSnapshot:
    if not isinstance(node, Mapping):
        raise AdapterPayloadError(f"required PR {number} is malformed")
    if node.get("number") != number:
        raise AdapterPayloadError(f"required PR {number} number does not match alias")
    head_sha = node.get("headRefOid")
    if type(head_sha) is not str or _SHA_RE.fullmatch(head_sha) is None:
        raise AdapterPayloadError(f"required PR {number} HEAD is malformed")
    commits = node.get("commits")
    commit_nodes = commits.get("nodes") if isinstance(commits, Mapping) else None
    if not isinstance(commit_nodes, list) or len(commit_nodes) > 1:
        raise AdapterPayloadError(
            f"required PR {number} commit connection is malformed"
        )
    if commit_nodes and not isinstance(commit_nodes[0], Mapping):
        raise AdapterPayloadError(
            f"required PR {number} commit connection is malformed"
        )
    commit = commit_nodes[0].get("commit") if commit_nodes else None
    rollup = commit.get("statusCheckRollup") if isinstance(commit, Mapping) else None
    contexts = rollup.get("contexts") if isinstance(rollup, Mapping) else None
    if not isinstance(contexts, Mapping):
        raise AdapterPayloadError(f"required PR {number} check connection is malformed")
    page_info = contexts.get("pageInfo")
    if (
        not isinstance(page_info, Mapping)
        or type(page_info.get("hasNextPage")) is not bool
    ):
        raise AdapterPayloadError(
            f"required PR {number} check connection pageInfo is malformed"
        )
    if page_info["hasNextPage"]:
        raise AdapterPayloadError(
            f"required PR {number} check connection hasNextPage=true"
        )
    context_nodes = contexts.get("nodes")
    if not isinstance(context_nodes, list):
        raise AdapterPayloadError(f"required PR {number} check connection is malformed")

    observations: dict[str, tuple[str, datetime | None, datetime | None, int]] = {}
    context_kinds: dict[str, str] = {}
    for index, item in enumerate(context_nodes):
        if not isinstance(item, Mapping):
            raise AdapterPayloadError(
                f"required PR {number} check[{index}] is malformed"
            )
        typename = item.get("__typename")
        if typename == "CheckRun":
            name = item.get("name")
            required = item.get("isRequired")
            raw_status = item.get("status")
            conclusion = item.get("conclusion")
            if type(name) is not str or type(required) is not bool:
                raise AdapterPayloadError(
                    f"required PR {number} check[{index}] is malformed"
                )
            if not required:
                continue
            if type(raw_status) is not str:
                raise AdapterPayloadError(
                    f"required PR {number} check[{index}] status is malformed"
                )
            if conclusion is not None and type(conclusion) is not str:
                raise AdapterPayloadError(
                    f"required PR {number} check[{index}] conclusion is malformed"
                )
            if raw_status.upper() == "COMPLETED" and conclusion is None:
                raise AdapterPayloadError(
                    f"required PR {number} check[{index}] conclusion is malformed"
                )
            state = conclusion if raw_status.upper() == "COMPLETED" else raw_status
            started_at = parse_optional_timestamp(
                item.get("startedAt"),
                field=f"required PR {number} check[{index}] startedAt",
            )
            completed_at = parse_optional_timestamp(
                item.get("completedAt"),
                field=f"required PR {number} check[{index}] completedAt",
            )
        elif typename == "StatusContext":
            name = item.get("context")
            required = item.get("isRequired")
            state = item.get("state")
            if (
                type(name) is not str
                or type(required) is not bool
                or type(state) is not str
            ):
                raise AdapterPayloadError(
                    f"required PR {number} status context[{index}] is malformed"
                )
            if not required:
                continue
            started_at = None
            completed_at = None
        else:
            raise AdapterPayloadError(
                f"required PR {number} check[{index}] has unknown type"
            )
        state = state.upper()
        previous_kind = context_kinds.get(name)
        if previous_kind is not None and previous_kind != typename:
            raise AdapterPayloadError(
                f"required PR {number} context kinds for {name!r} are ambiguous"
            )
        context_kinds[name] = typename
        if (
            started_at is not None
            and completed_at is not None
            and completed_at < started_at
        ):
            raise AdapterPayloadError(
                f"required PR {number} check[{index}] timestamps are inconsistent"
            )
        candidate = (state, started_at, completed_at, index)
        previous = observations.get(name)
        if previous is None or _prefer_newer_context(candidate, previous):
            observations[name] = candidate

    starts = [item[1] for item in observations.values()]
    completions = [item[2] for item in observations.values()]

    return CheckSnapshot(
        status=_status_from_states({item[0] for item in observations.values()}),
        head_sha=head_sha,
        observed_at=observed_at,
        names=tuple(sorted(observations)),
        started_at=(
            min(item for item in starts if item is not None)
            if starts and all(item is not None for item in starts)
            else None
        ),
        completed_at=(
            max(item for item in completions if item is not None)
            if completions and all(item is not None for item in completions)
            else None
        ),
    )


def batch_required_snapshots(
    client: GitHubCliClient, numbers: tuple[int, ...]
) -> dict[int, CheckSnapshot]:
    if type(numbers) is not tuple or any(
        type(number) is not int or number <= 0 for number in numbers
    ):
        raise AdapterPayloadError("required PR numbers must be positive integers")
    if len(set(numbers)) != len(numbers):
        raise AdapterPayloadError("required PR numbers must be unique")
    if not numbers:
        return {}
    owner, name = _repository_name(client)
    snapshots: dict[int, CheckSnapshot] = {}
    for start in range(0, len(numbers), _MAX_BATCH_SIZE):
        chunk = numbers[start : start + _MAX_BATCH_SIZE]
        payload = client.load_json(
            (
                "gh",
                "api",
                "graphql",
                "-f",
                f"query={_required_checks_query(chunk)}",
                "-f",
                f"owner={owner}",
                "-f",
                f"name={name}",
            )
        )
        if not isinstance(payload, Mapping) or payload.get("errors"):
            raise AdapterPayloadError(
                "GitHub required-check GraphQL response contains errors"
            )
        fetched_at = client.last_fetched_at
        if fetched_at is None:
            raise AdapterPayloadError("GitHub required-check read has no fetch time")
        # A body served from cache is observed when it was fetched, not when it was reused.
        observed_at = datetime.fromtimestamp(fetched_at, tz=UTC)
        data = payload.get("data")
        repository = data.get("repository") if isinstance(data, Mapping) else None
        if not isinstance(repository, Mapping):
            raise AdapterPayloadError("GitHub required-check repository is malformed")
        for number in chunk:
            snapshots[number] = _snapshot_from_node(
                repository.get(f"pr_{number}"), number=number, observed_at=observed_at
            )
    return snapshots
