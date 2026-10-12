"""GitHub pull-request mutations guarded by exact readback checks."""

from __future__ import annotations

import re
import time
from collections.abc import Callable, Mapping
from datetime import UTC, datetime

from ..domain.errors import CompareAndSwapConflict
from ..domain.observations import PullRequestSnapshot
from ..ports.github import RequiredTriggerOutcome
from ..ports.process import CommandResult
from .errors import AdapterCommandError, AdapterPayloadError
from .github_client import GitHubCliClient
from .github_queue import GitHubQueueGraphQLAdapter
from .github_required_run import (
    JobCounts,
    assess_active_run,
    parse_job_counts,
    run_jobs_command,
    wedged_run_after,
)
from .timestamps import parse_optional_timestamp

_READ_AFTER_WRITE_ATTEMPTS = 5
_READ_AFTER_WRITE_DELAY_SECONDS = 1.0
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_ACTIVE_RUN_STATUSES = frozenset(
    {"queued", "in_progress", "waiting", "requested", "pending"}
)
_FAILED_JOB_CONCLUSIONS = frozenset({"failure", "cancelled", "timed_out"})
_CANCEL_REREAD_ATTEMPTS = 3
_CANCEL_REREAD_DELAY_SECONDS = 1.0
_CANCEL_COMPLETED_RACE_MARKER = "cannot cancel a workflow run that is completed"


# createdAt survives a rerun; startedAt/updatedAt restart with each attempt and
# anchor the wedged-run age (see _attempt_started_at).
_REQUIRED_RUN_LIST_FIELDS = "databaseId,headBranch,headSha,event,status,conclusion,createdAt,startedAt,updatedAt"


def _is_already_running(result: CommandResult) -> bool:
    detail = f"{result.stdout}\n{result.stderr}".casefold()
    return "403" in detail and "already running" in detail


def _required_run_list_command(*, branch: str, head_sha: str) -> tuple[str, ...]:
    return (
        "gh",
        "run",
        "list",
        "--workflow",
        "pr-gate.yml",
        "--branch",
        branch,
        "--event",
        "pull_request",
        "--commit",
        head_sha,
        "--limit",
        "20",
        "--json",
        _REQUIRED_RUN_LIST_FIELDS,
    )


def _required_run_view_command(*, database_id: int) -> tuple[str, ...]:
    return (
        "gh",
        "run",
        "view",
        str(database_id),
        "--json",
        "databaseId,headBranch,headSha,event,status,conclusion,createdAt",
    )


def _select_exact_required_run(
    payload: object,
    *,
    branch: str,
    head_sha: str,
) -> tuple[datetime, int, str, str | None]:
    if not isinstance(payload, list):
        raise AdapterPayloadError("GitHub required workflow list must be a JSON list")

    candidates: list[tuple[datetime, int, str, str | None, datetime]] = []
    for index, item in enumerate(payload):
        if not isinstance(item, Mapping):
            raise AdapterPayloadError(f"GitHub required workflow[{index}] is malformed")
        database_id = item.get("databaseId")
        head_branch = item.get("headBranch")
        observed_head = item.get("headSha")
        event = item.get("event")
        status = item.get("status")
        conclusion = item.get("conclusion")
        if type(database_id) is not int or database_id <= 0:
            raise AdapterPayloadError(
                f"GitHub required workflow[{index}] databaseId is malformed"
            )
        if (
            type(head_branch) is not str
            or type(observed_head) is not str
            or _SHA_RE.fullmatch(observed_head) is None
            or type(event) is not str
            or type(status) is not str
            or conclusion is not None
            and type(conclusion) is not str
        ):
            raise AdapterPayloadError(
                f"GitHub required workflow[{index}] identity is malformed"
            )
        created_at = parse_optional_timestamp(
            item.get("createdAt"),
            field=f"GitHub required workflow[{index}] createdAt",
        )
        if created_at is None:
            raise AdapterPayloadError(
                f"GitHub required workflow[{index}] createdAt is required"
            )
        if (
            head_branch != branch
            or observed_head != head_sha
            or event != "pull_request"
        ):
            continue
        candidates.append(
            (
                created_at,
                database_id,
                status.casefold(),
                conclusion,
                _attempt_started_at(item, index=index, created_at=created_at),
            )
        )

    if not candidates:
        raise AdapterPayloadError(
            "no exact pull_request pr-gate run exists for the required PR HEAD"
        )
    _, database_id, status, conclusion, attempt_started_at = max(
        candidates, key=lambda item: (item[0], item[1])
    )
    return attempt_started_at, database_id, status, conclusion


def _attempt_started_at(
    item: Mapping[str, object], *, index: int, created_at: datetime
) -> datetime:
    """Latest of createdAt/startedAt/updatedAt: when the current attempt began.

    GitHub keeps ``createdAt`` across re-run attempts, so measuring wedged age
    from it alone would re-fire recovery on every tick after the first rerun.
    gh renders a never-started attempt's startedAt as the zero time, which the
    ``max`` ignores.
    """

    stamps = [created_at]
    for key in ("startedAt", "updatedAt"):
        stamp = parse_optional_timestamp(
            item.get(key), field=f"GitHub required workflow[{index}] {key}"
        )
        if stamp is not None:
            stamps.append(stamp)
    return max(stamps)


class GitHubCommands:
    def __init__(
        self,
        *,
        client: GitHubCliClient,
        queue: GitHubQueueGraphQLAdapter,
        find_open_pull_request: Callable[[str], PullRequestSnapshot | None],
        get_pull_request: Callable[[int], PullRequestSnapshot],
        merge_queue_enabled: Callable[[str], bool],
    ) -> None:
        self.client = client
        self.queue = queue
        self.find_open_pull_request = find_open_pull_request
        self.get_pull_request = get_pull_request
        self.merge_queue_enabled = merge_queue_enabled

    def _read_until_head(
        self,
        *,
        number: int,
        expected_head_sha: str,
        conflict_message: str,
    ) -> PullRequestSnapshot:
        for attempt in range(_READ_AFTER_WRITE_ATTEMPTS):
            snapshot = self.get_pull_request(number)
            if snapshot.head_sha == expected_head_sha:
                return snapshot
            if attempt + 1 < _READ_AFTER_WRITE_ATTEMPTS:
                time.sleep(_READ_AFTER_WRITE_DELAY_SECONDS)
        raise CompareAndSwapConflict(conflict_message)

    def _load_job_counts(self, database_id: int) -> JobCounts:
        return parse_job_counts(
            self.client.load_json(run_jobs_command(database_id=database_id))
        )

    def trigger_required(
        self,
        *,
        number: int,
        branch: str,
        base_sha: str,
        head_sha: str,
    ) -> RequiredTriggerOutcome:
        del number, base_sha
        list_argv = _required_run_list_command(branch=branch, head_sha=head_sha)
        attempt_started_at, database_id, status, conclusion = (
            _select_exact_required_run(
                self.client.load_json(list_argv),
                branch=branch,
                head_sha=head_sha,
            )
        )
        recovered_reason: str | None = None
        if status in _ACTIVE_RUN_STATUSES:
            assessment = assess_active_run(
                database_id=database_id,
                status=status,
                attempt_started_at=attempt_started_at,
                now=datetime.now(tz=UTC),
                threshold=wedged_run_after(),
                load_jobs=lambda: self._load_job_counts(database_id),
            )
            if not assessment.wedged:
                # A waiting or partially executing run is evidence, not an
                # obstacle: never cancel it and never dispatch a duplicate.
                return RequiredTriggerOutcome((), "wait", assessment.reason)
            recovered_reason = assessment.reason
            database_id, status, conclusion = self._cancel_wedged_run(
                list_argv=list_argv,
                database_id=database_id,
                branch=branch,
                head_sha=head_sha,
            )
        if status != "completed" or conclusion is None:
            raise AdapterPayloadError(
                "exact pull_request pr-gate run has an invalid terminal state"
            )
        if conclusion.casefold() == "success":
            raise AdapterPayloadError(
                "exact pull_request pr-gate run already succeeded; refusing duplicate rerun"
            )
        if recovered_reason is not None:
            # No job ever ran, so there is no green evidence to preserve.
            return self._rerun(
                database_id,
                failed_only=False,
                action="recover_wedged_run",
                reason=f"{recovered_reason}; cancelled and rerun in full",
            )
        failed_only = conclusion.casefold() in _FAILED_JOB_CONCLUSIONS
        return self._rerun(
            database_id,
            failed_only=failed_only,
            action="rerun_failed_jobs" if failed_only else "rerun",
            reason=(
                f"run {database_id} finished {conclusion}; "
                + (
                    "rerunning only its failed jobs to keep green evidence"
                    if failed_only
                    else "rerunning it in full"
                )
            ),
        )

    def _rerun(
        self, database_id: int, *, failed_only: bool, action: str, reason: str
    ) -> RequiredTriggerOutcome:
        argv = (
            ("gh", "run", "rerun", "--failed", str(database_id))
            if failed_only
            else ("gh", "run", "rerun", str(database_id))
        )
        try:
            self.client.run(argv)
        except AdapterCommandError as error:
            if not _is_already_running(error.result):
                raise
            # GitHub refuses to rerun a run that is still in progress (HTTP 403
            # "already running"): that run is the evidence to wait on, not a failure.
            return RequiredTriggerOutcome(
                (), "wait", f"{reason}; rerun refused, the run is already running"
            )
        return RequiredTriggerOutcome(argv, action, reason)

    def _cancel_wedged_run(
        self,
        *,
        list_argv: tuple[str, ...],
        database_id: int,
        branch: str,
        head_sha: str,
    ) -> tuple[int, str, str | None]:
        cancel_argv = ("gh", "run", "cancel", "--force", str(database_id))
        cancel_result = self.client.runner.run(cancel_argv, cwd=self.client.repo)
        # Cancellation is asynchronous and may race with GitHub's own terminal
        # transition. Never infer cancellation from exit status; select the
        # same exact run again before rerunning it. GitHub can report the run
        # as already completed while the list endpoint briefly continues to
        # expose its queued state, so only that specific race gets a bounded
        # additional read window.
        cancel_detail = f"{cancel_result.stdout}\n{cancel_result.stderr}".casefold()
        completed_race = (
            cancel_result.exit_code != 0
            and _CANCEL_COMPLETED_RACE_MARKER in cancel_detail
        )
        reread_attempts = _CANCEL_REREAD_ATTEMPTS if completed_race else 1
        for attempt in range(reread_attempts):
            _, database_id, status, conclusion = _select_exact_required_run(
                self.client.load_json(list_argv),
                branch=branch,
                head_sha=head_sha,
            )
            if status not in _ACTIVE_RUN_STATUSES:
                return database_id, status, conclusion
            if attempt + 1 < reread_attempts:
                time.sleep(_CANCEL_REREAD_DELAY_SECONDS)
        if not completed_race:
            if cancel_result.exit_code != 0:
                raise AdapterCommandError(cancel_result)
            raise AdapterPayloadError(
                "stale exact pull_request pr-gate run remained active after forced cancel"
            )
        return self._view_completed_race(
            database_id=database_id, branch=branch, head_sha=head_sha
        )

    def _view_completed_race(
        self, *, database_id: int, branch: str, head_sha: str
    ) -> tuple[int, str, str | None]:
        view_argv = _required_run_view_command(database_id=database_id)
        for attempt in range(_CANCEL_REREAD_ATTEMPTS):
            _, viewed_id, status, conclusion = _select_exact_required_run(
                [self.client.load_json(view_argv)],
                branch=branch,
                head_sha=head_sha,
            )
            if viewed_id != database_id:
                raise AdapterPayloadError(
                    "authoritative exact pull_request pr-gate run identity changed"
                )
            if status not in _ACTIVE_RUN_STATUSES:
                return viewed_id, status, conclusion
            if attempt + 1 < _CANCEL_REREAD_ATTEMPTS:
                time.sleep(_CANCEL_REREAD_DELAY_SECONDS)
        raise AdapterPayloadError(
            "authoritative exact pull_request pr-gate run remained active "
            "after completed-cancel race"
        )

    def trigger_readiness(
        self,
        *,
        number: int,
        branch: str,
        head_sha: str,
    ) -> tuple[str, ...]:
        argv = (
            "gh",
            "workflow",
            "run",
            "pr-readiness.yml",
            "--ref",
            branch,
            "-f",
            f"pr_number={number}",
            "-f",
            f"head_sha={head_sha}",
        )
        self.client.run(argv)
        return argv

    def create_pull_request(
        self, *, branch: str, title: str, body: str
    ) -> PullRequestSnapshot:
        self.client.run(
            (
                "gh",
                "pr",
                "create",
                "--base",
                "main",
                "--head",
                branch,
                "--title",
                title,
                "--body",
                body,
            )
        )
        created = self.find_open_pull_request(branch)
        if created is None:
            raise CompareAndSwapConflict("created PR did not read back by branch")
        return created

    def update_pull_request(
        self,
        *,
        number: int,
        title: str,
        body: str,
        expected_head_sha: str,
    ) -> PullRequestSnapshot:
        self._read_until_head(
            number=number,
            expected_head_sha=expected_head_sha,
            conflict_message="PR HEAD changed before metadata update",
        )
        self.client.run(
            ("gh", "pr", "edit", str(number), "--title", title, "--body", body)
        )
        return self._read_until_head(
            number=number,
            expected_head_sha=expected_head_sha,
            conflict_message="PR HEAD changed during metadata update",
        )

    def mark_ready(self, number: int) -> PullRequestSnapshot:
        before = self.get_pull_request(number)
        self.client.run(("gh", "pr", "ready", str(number)))
        after = self.get_pull_request(number)
        if after.head_sha != before.head_sha:
            raise CompareAndSwapConflict("PR HEAD changed while marking ready")
        return after

    def close_pull_request(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> PullRequestSnapshot:
        return self._change_pull_request_state(
            number=number,
            command="close",
            before_state="OPEN",
            after_state="CLOSED",
            expected_base_sha=expected_base_sha,
            expected_head_sha=expected_head_sha,
            expected_body=expected_body,
        )

    def reopen_pull_request(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> PullRequestSnapshot:
        return self._change_pull_request_state(
            number=number,
            command="reopen",
            before_state="CLOSED",
            after_state="OPEN",
            expected_base_sha=expected_base_sha,
            expected_head_sha=expected_head_sha,
            expected_body=expected_body,
        )

    def _change_pull_request_state(
        self,
        *,
        number: int,
        command: str,
        before_state: str,
        after_state: str,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> PullRequestSnapshot:
        before = self.get_pull_request(number)
        if (
            before.state != before_state
            or before.merged_at is not None
            or before.base_branch != "main"
            or before.base_sha != expected_base_sha
            or before.head_sha != expected_head_sha
            or before.body != expected_body
        ):
            raise CompareAndSwapConflict(f"PR tuple changed before {command}")
        self.client.run(("gh", "pr", command, str(number)))
        after = self.get_pull_request(number)
        if (
            after.state != after_state
            or after.merged_at is not None
            or after.base_branch != "main"
            or after.base_sha != expected_base_sha
            or after.head_sha != expected_head_sha
            or after.body != expected_body
        ):
            raise CompareAndSwapConflict(f"PR tuple changed during {command}")
        return after

    def enqueue(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> None:
        before = self.get_pull_request(number)
        if (
            before.base_branch != "main"
            or before.base_sha != expected_base_sha
            or before.head_sha != expected_head_sha
            or before.body != expected_body
        ):
            raise CompareAndSwapConflict("PR tuple changed before enqueue")
        if not self.merge_queue_enabled("main"):
            raise CompareAndSwapConflict("main has no native merge queue rule")
        self.queue.enqueue(
            pull_request_id=before.node_id,
            expected_base_sha=expected_base_sha,
            expected_head_sha=expected_head_sha,
            expected_body=expected_body,
        )
