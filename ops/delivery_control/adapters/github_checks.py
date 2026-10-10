"""Required-check observation with exact pull-request HEAD binding."""

from __future__ import annotations

import json
import re
from collections.abc import Callable, Mapping
from datetime import UTC, datetime

from ..domain.check_states import FAILURE_STATES, SUCCESS_STATES, TERMINAL_STATES
from ..domain.errors import CompareAndSwapConflict
from ..domain.models import CheckStatus
from ..domain.observations import CheckSnapshot, PullRequestSnapshot
from ..domain.policies import REQUIRED_OBSERVATION_MAX_AGE
from .errors import AdapterCommandError, AdapterPayloadError
from .github_client import GitHubCliClient
from .github_required_batch import batch_required_snapshots
from .timestamps import parse_optional_timestamp

_NO_REQUIRED_CHECKS_RE = re.compile(
    r"no (?:required )?checks reported on the '([^'\n]+)' branch"
)
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


class GitHubChecks:
    def __init__(
        self,
        *,
        client: GitHubCliClient,
        get_pull_request: Callable[[int], PullRequestSnapshot],
        clock: Callable[[], datetime] = lambda: datetime.now(tz=UTC),
    ) -> None:
        self.client = client
        self.get_pull_request = get_pull_request
        self._clock = clock
        self._batched_required: dict[int, CheckSnapshot] = {}

    def prime_required_snapshots(self, numbers: tuple[int, ...]) -> None:
        """Prime an observation-only cache using bounded GraphQL batches."""

        self._batched_required = batch_required_snapshots(self.client, numbers)

    def _required_snapshot_live(
        self, number: int, *, before: PullRequestSnapshot
    ) -> CheckSnapshot:
        argv = (
            "gh",
            "pr",
            "checks",
            str(number),
            "--required",
            "--json",
            "name,state,startedAt,completedAt",
        )
        # ``gh pr checks`` reports an empty result with exit=1 and places the
        # human-readable contract message on stderr.  Observe the raw command
        # result here so the general client ``run`` fail-closed behavior stays
        # unchanged for every other caller.
        result = self.client.runner.run(argv, cwd=self.client.repo)
        output = result.stdout.strip()
        empty_result = _NO_REQUIRED_CHECKS_RE.fullmatch(output)
        stderr_empty_result = _NO_REQUIRED_CHECKS_RE.fullmatch(result.stderr.strip())
        if result.exit_code == 1 and not output and stderr_empty_result is not None:
            if stderr_empty_result.group(1) != before.branch:
                raise AdapterPayloadError(
                    "GitHub required checks zero-result branch does not match "
                    "the exact PR"
                )
            payload: object = []
        elif result.exit_code != 0 and not output:
            raise AdapterCommandError(result)
        elif empty_result is not None:
            if empty_result.group(1) != before.branch:
                raise AdapterPayloadError(
                    "GitHub required checks zero-result branch does not match "
                    "the exact PR"
                )
            payload: object = []
        else:
            try:
                payload = json.loads(output)
            except json.JSONDecodeError as error:
                raise AdapterPayloadError(
                    f"invalid JSON from {' '.join(argv)}"
                ) from error
        if not isinstance(payload, list):
            raise AdapterPayloadError("GitHub required checks must be a JSON list")
        observations: dict[str, tuple[str, datetime | None, datetime | None, int]] = {}
        for index, item in enumerate(payload):
            if not isinstance(item, Mapping):
                raise AdapterPayloadError(f"required check[{index}] is not an object")
            name = item.get("name")
            state = item.get("state")
            if type(name) is not str or type(state) is not str:
                raise AdapterPayloadError(f"required check[{index}] is malformed")
            state = state.upper()
            started_at = parse_optional_timestamp(
                item.get("startedAt"),
                field=f"required check[{index}] startedAt",
            )
            completed_at = parse_optional_timestamp(
                item.get("completedAt"),
                field=f"required check[{index}] completedAt",
            )
            if (
                started_at is not None
                and completed_at is not None
                and completed_at < started_at
            ):
                raise AdapterPayloadError(
                    f"required check[{index}] timestamps are inconsistent"
                )
            candidate = (state, started_at, completed_at, index)
            previous = observations.get(name)
            if previous is None or _prefer_newer_context(candidate, previous):
                observations[name] = candidate
        after = self.get_pull_request(number)
        if before.head_sha != after.head_sha:
            raise CompareAndSwapConflict(
                "PR HEAD changed while reading required checks"
            )
        starts = [item[1] for item in observations.values()]
        completions = [item[2] for item in observations.values()]
        return CheckSnapshot(
            status=_status_from_states({item[0] for item in observations.values()}),
            head_sha=after.head_sha,
            observed_at=self._clock(),
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

    def required_snapshot(self, number: int, *, fresh: bool = False) -> CheckSnapshot:
        before = self.get_pull_request(number)
        batched = self._batched_required.pop(number, None)
        # A primed batch older than the merge gate's cap would be refused there, so
        # it is re-read live instead of being admitted or left to fail closed.
        if (
            not fresh
            and batched is not None
            and batched.head_sha == before.head_sha
            and self._clock() - batched.observed_at <= REQUIRED_OBSERVATION_MAX_AGE
        ):
            return batched
        return self._required_snapshot_live(number, before=before)
