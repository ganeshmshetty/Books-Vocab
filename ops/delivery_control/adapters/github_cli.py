"""Stable GitHub CLI adapter facade composed from focused components."""

from __future__ import annotations

from collections.abc import Mapping
from contextlib import AbstractContextManager, nullcontext
from datetime import datetime
from pathlib import Path
from typing import Any

from ..domain.candidate_issues import CandidateIssue, CandidateIssueInventory
from ..domain.demand_issues import (
    DemandIssue,
    DemandIssueInventory,
    IssueCloseReceipt,
    IssueIntakeReceipt,
)
from ..domain.observations import (
    CheckSnapshot,
    MergeQueueEntrySnapshot,
    PullRequestInventory,
    PullRequestSnapshot,
)
from ..ports.github import RequiredTriggerOutcome
from ..ports.process import CommandRunnerPort
from .errors import AdapterCommandError, AdapterPayloadError
from .github_checks import GitHubChecks
from .github_client import GitHubCliClient
from .github_commands import GitHubCommands
from .github_governed_runner import govern_runner
from .github_issue_commands import GitHubIssueCommands
from .github_issue_queries import GitHubIssueQueries
from .github_parsing import (
    parse_candidate_issue,
    parse_candidate_issue_inventory,
    parse_pull_request,
    parse_pull_request_inventory,
)
from .github_queries import PR_FIELDS, GitHubQueries
from .github_queue import GitHubQueueGraphQLAdapter
from .github_quota import GitHubQuotaGovernor
from .github_rules import GitHubRules, read_repository_name
from .subprocess_runner import SubprocessCommandRunner

_PR_FIELDS = PR_FIELDS


class GitHubCliAdapter:
    """Compatibility facade implementing the GitHub query and command ports."""

    def __init__(
        self,
        *,
        repo: Path | None = None,
        runner: CommandRunnerPort | None = None,
        quota: GitHubQuotaGovernor | None = None,
    ) -> None:
        self.repo = (repo or Path.cwd()).resolve()
        raw_runner = runner or SubprocessCommandRunner()
        if quota is None and isinstance(raw_runner, SubprocessCommandRunner):
            quota = GitHubQuotaGovernor(
                repo=self.repo,
                runner=raw_runner,
                spend_log=self.repo / ".cache" / "github_spend.ndjson",
            )
        self.quota = quota
        # Single governed chokepoint: every adapter below receives this runner.
        self.runner = govern_runner(raw_runner, quota)
        self._pull_request_snapshot_cache: dict[int, PullRequestSnapshot] = {}
        self._required_observation_numbers: tuple[int, ...] = ()
        self._open_observations_pending = False
        self.queue = GitHubQueueGraphQLAdapter(repo=self.repo, runner=self.runner)
        self._client = GitHubCliClient(repo=self.repo, runner=self.runner)
        self._rules = GitHubRules(
            client=self._client,
            repository_name=self._repo_name,
        )
        self._queries = GitHubQueries(
            client=self._client,
            repository_name=self._repo_name,
            pull_request_parser=self._pull_request,
            pull_request_inventory_parser=self._pull_request_inventory,
            candidate_inventory_parser=self._candidate_issue_inventory,
        )
        self._issue_queries = GitHubIssueQueries(
            repo=self.repo,
            runner=self.runner,
            repository_name=self._repo_name,
        )
        self._issue_commands = GitHubIssueCommands(
            repo=self.repo,
            runner=self.runner,
            client=self._client,
            query=self._issue_queries,
        )
        self._checks = GitHubChecks(
            client=self._client,
            get_pull_request=self.get_pull_request,
        )
        self._commands = GitHubCommands(
            client=self._client,
            queue=self.queue,
            find_open_pull_request=self.find_open_pull_request,
            # Mutations must never authorize from the read-only inventory
            # cache.  Their pre/post checks use an exact live query instead.
            get_pull_request=self._queries.get_pull_request,
            merge_queue_enabled=self.merge_queue_enabled,
        )

    def _run(self, argv: tuple[str, ...], *, allow_nonzero: bool = False) -> str:
        return self._client.run(argv, allow_nonzero=allow_nonzero)

    def _json(self, argv: tuple[str, ...], *, allow_nonzero: bool = False) -> Any:
        return self._client.load_json(argv, allow_nonzero=allow_nonzero)

    def _authoritative(self) -> AbstractContextManager[None]:
        """Scope for mutations and their guard/verification reads; stale serve is off here."""
        return nullcontext() if self.quota is None else self.quota.authoritative_reads()

    @staticmethod
    def _pull_request(payload: Mapping[str, Any]) -> PullRequestSnapshot:
        return parse_pull_request(payload)

    @classmethod
    def _pull_request_inventory(cls, payload: object) -> PullRequestInventory:
        return parse_pull_request_inventory(payload, parse_record=cls._pull_request)

    @staticmethod
    def _candidate_issue(payload: Mapping[str, Any]) -> CandidateIssue:
        return parse_candidate_issue(payload)

    @classmethod
    def _candidate_issue_inventory(cls, payload: object) -> CandidateIssueInventory:
        return parse_candidate_issue_inventory(
            payload,
            parse_record=cls._candidate_issue,
        )

    def list_open_candidate_issues(self) -> CandidateIssueInventory:
        return self._queries.list_open_candidate_issues()

    def list_open_issues(self) -> DemandIssueInventory:
        return self._issue_queries.list_open_issues()

    def admit_candidate(self, **kwargs: Any) -> DemandIssue:
        with self._authoritative():
            return self._issue_commands.admit_candidate(**kwargs)

    def create_issue(self, **kwargs: Any) -> IssueIntakeReceipt:
        with self._authoritative():
            return self._issue_commands.create_issue(**kwargs)

    def close_issue(self, **kwargs: Any) -> IssueCloseReceipt:
        with self._authoritative():
            return self._issue_commands.close_issue(**kwargs)

    def list_open_pull_requests(self) -> PullRequestInventory:
        self.queue.clear_observed_snapshots()
        inventory = self._queries.list_open_pull_requests()
        self._pull_request_snapshot_cache = {
            item.number: item for item in inventory.records
        }
        self._required_observation_numbers = tuple(
            item.number for item in inventory.records
        )
        self._open_observations_pending = True
        return inventory

    def prime_open_observations(self) -> None:
        """Batch queue observations for one read-only inventory pass."""

        # The batch feeds merge-queue guards, so its read is authoritative too.
        with self._authoritative():
            try:
                self.queue.prime_open_snapshots(repository_name=self._repo_name())
            except (AdapterCommandError, AdapterPayloadError):
                # A failed optimization must fall back to exact per-PR reads.
                self.queue.clear_observed_snapshots()
            finally:
                self._open_observations_pending = False

    def _ensure_open_observations(self) -> None:
        if self._open_observations_pending:
            self.prime_open_observations()

    def list_pull_requests_for_branch(self, branch: str) -> PullRequestInventory:
        return self._queries.list_pull_requests_for_branch(branch)

    def list_pull_requests_for_branches(
        self, branches: tuple[str, ...]
    ) -> PullRequestInventory:
        return self._queries.list_pull_requests_for_branches(branches)

    def recent_merge_times(self, *, limit: int = 100) -> tuple[datetime, ...]:
        return self._queries.recent_merge_times(limit=limit)

    def find_open_pull_request(self, branch: str) -> PullRequestSnapshot | None:
        inventory = self.list_open_pull_requests()
        if inventory.problems:
            raise AdapterPayloadError("GitHub PR inventory contains malformed entries")
        matches = [item for item in inventory.records if item.branch == branch]
        if len(matches) > 1:
            raise AdapterPayloadError(f"multiple open PRs found for {branch}")
        return matches[0] if matches else None

    def get_pull_request(self, number: int) -> PullRequestSnapshot:
        cached = self._pull_request_snapshot_cache.pop(number, None)
        if cached is not None:
            return cached
        return self._queries.get_pull_request(number)

    def required_check_snapshot(
        self, number: int, *, fresh: bool = False
    ) -> CheckSnapshot:
        # Required checks gate merges, and the head reads around them bind the
        # observation to a PR head: both are authoritative, so no cached pr view or
        # batch can pin the checks to an old head.
        with self._authoritative():
            # Decisions that mutate (merge admission, repair dispatch) must not act on
            # a primed tick-start batch; only observation reads may use it.
            if fresh:
                return self._checks.required_snapshot(number, fresh=True)
            if self._required_observation_numbers:
                numbers = self._required_observation_numbers
                self._required_observation_numbers = ()
                prime = getattr(self._checks, "prime_required_snapshots", None)
                if callable(prime):
                    try:
                        prime(numbers)
                    except (AdapterCommandError, AdapterPayloadError):
                        # The singular exact-head read remains the compatibility
                        # fallback when batch observation is unavailable or fails.
                        pass
            return self._checks.required_snapshot(number)

    def changed_paths(self, number: int) -> tuple[str, ...]:
        return self._queries.changed_paths(number)

    def _repo_name(self) -> str:
        return read_repository_name(self._client)

    def branch_is_protected(self, branch: str) -> bool:
        return self._rules.branch_is_protected(branch)

    def required_status_contexts(self, branch: str) -> tuple[str, ...]:
        return self._rules.required_status_contexts(branch)

    def merge_queue_enabled(self, branch: str) -> bool:
        return self.queue.is_configured(
            repository_name=self._repo_name(),
            branch=branch,
        )

    def merge_queue_entry_id(self, pull_request_id: str) -> str | None:
        # Abandon and legacy cleanup refuse a PR already in the queue: this guard
        # must not be answered from a stale cache entry.
        with self._authoritative():
            self._ensure_open_observations()
            return self.queue.observed_snapshot(pull_request_id).entry_id

    def merge_queue_entry_snapshot(
        self, pull_request_id: str
    ) -> MergeQueueEntrySnapshot | None:
        with self._authoritative():
            self._ensure_open_observations()
            return self.queue.observed_snapshot(pull_request_id).entry

    def trigger_required(
        self,
        *,
        number: int,
        branch: str,
        base_sha: str,
        head_sha: str,
    ) -> RequiredTriggerOutcome:
        with self._authoritative():
            return self._commands.trigger_required(
                number=number,
                branch=branch,
                base_sha=base_sha,
                head_sha=head_sha,
            )

    def trigger_readiness(
        self,
        *,
        number: int,
        branch: str,
        head_sha: str,
    ) -> tuple[str, ...]:
        with self._authoritative():
            return self._commands.trigger_readiness(
                number=number,
                branch=branch,
                head_sha=head_sha,
            )

    def create_pull_request(
        self, *, branch: str, title: str, body: str
    ) -> PullRequestSnapshot:
        with self._authoritative():
            return self._commands.create_pull_request(
                branch=branch, title=title, body=body
            )

    def update_pull_request(
        self,
        *,
        number: int,
        title: str,
        body: str,
        expected_head_sha: str,
    ) -> PullRequestSnapshot:
        self._pull_request_snapshot_cache.pop(number, None)
        with self._authoritative():
            return self._commands.update_pull_request(
                number=number,
                title=title,
                body=body,
                expected_head_sha=expected_head_sha,
            )

    def mark_ready(self, number: int) -> PullRequestSnapshot:
        self._pull_request_snapshot_cache.pop(number, None)
        with self._authoritative():
            return self._commands.mark_ready(number)

    def close_pull_request(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> PullRequestSnapshot:
        self._pull_request_snapshot_cache.pop(number, None)
        with self._authoritative():
            return self._commands.close_pull_request(
                number=number,
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
        self._pull_request_snapshot_cache.pop(number, None)
        with self._authoritative():
            return self._commands.reopen_pull_request(
                number=number,
                expected_base_sha=expected_base_sha,
                expected_head_sha=expected_head_sha,
                expected_body=expected_body,
            )

    def enqueue(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> None:
        with self._authoritative():
            self._commands.enqueue(
                number=number,
                expected_base_sha=expected_base_sha,
                expected_head_sha=expected_head_sha,
                expected_body=expected_body,
            )
