from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol, runtime_checkable

from ..domain.candidate_issues import CandidateIssueInventory, CandidateSpec
from ..domain.demand_issues import (
    DemandIssue,
    IssueIntakeReceipt,
    IssueIntakeRequest,
)
from ..domain.observations import (
    CheckSnapshot,
    MergeQueueEntrySnapshot,
    PullRequestInventory,
    PullRequestSnapshot,
)


@dataclass(frozen=True)
class RequiredTriggerOutcome:
    """One `trigger-required` decision; empty ``command`` means nothing mutated."""

    command: tuple[str, ...]
    action: str
    reason: str

    @property
    def dispatched(self) -> bool:
        return bool(self.command)


@runtime_checkable
class GitHubQueryPort(Protocol):
    def list_open_candidate_issues(self) -> CandidateIssueInventory: ...

    def list_open_pull_requests(self) -> PullRequestInventory: ...

    def list_pull_requests_for_branch(self, branch: str) -> PullRequestInventory: ...

    def find_open_pull_request(self, branch: str) -> PullRequestSnapshot | None: ...

    def get_pull_request(self, number: int) -> PullRequestSnapshot: ...

    def required_check_snapshot(
        self, number: int, *, fresh: bool = False
    ) -> CheckSnapshot: ...

    def changed_paths(self, number: int) -> tuple[str, ...]: ...

    def branch_is_protected(self, branch: str) -> bool: ...

    def required_status_contexts(self, branch: str) -> tuple[str, ...]: ...

    def merge_queue_enabled(self, branch: str) -> bool: ...

    def merge_queue_entry_id(self, pull_request_id: str) -> str | None: ...

    def merge_queue_entry_snapshot(
        self, pull_request_id: str
    ) -> MergeQueueEntrySnapshot | None: ...


@runtime_checkable
class GitHubIssueCommandPort(Protocol):
    """Optional mutation capability for one explicitly triaged Issue."""

    def admit_candidate(
        self,
        *,
        issue_number: int,
        expected_updated_at: datetime,
        expected_body_sha256: str,
        spec: CandidateSpec,
        triage_reason: str,
        operator: str,
    ) -> DemandIssue: ...


@runtime_checkable
class GitHubIssueIntakePort(Protocol):
    """Optional mutation capability for one explicit raw Issue intake."""

    def create_issue(self, *, request: IssueIntakeRequest) -> IssueIntakeReceipt: ...


@runtime_checkable
class GitHubWorkflowCommandPort(Protocol):
    def trigger_readiness(
        self,
        *,
        number: int,
        branch: str,
        head_sha: str,
    ) -> tuple[str, ...]: ...

    def trigger_required(
        self,
        *,
        number: int,
        branch: str,
        base_sha: str,
        head_sha: str,
    ) -> RequiredTriggerOutcome: ...


@runtime_checkable
class GitHubCommandPort(Protocol):
    def create_pull_request(
        self,
        *,
        branch: str,
        title: str,
        body: str,
    ) -> PullRequestSnapshot: ...

    def update_pull_request(
        self,
        *,
        number: int,
        title: str,
        body: str,
        expected_head_sha: str,
    ) -> PullRequestSnapshot: ...

    def mark_ready(self, number: int) -> PullRequestSnapshot: ...

    def close_pull_request(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> PullRequestSnapshot: ...

    def reopen_pull_request(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> PullRequestSnapshot: ...

    def enqueue(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> None: ...
