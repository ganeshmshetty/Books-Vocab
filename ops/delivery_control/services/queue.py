"""Exact admission into GitHub's native merge queue."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime

from ..domain.errors import PolicyViolation
from ..domain.models import HandbackReceipt
from ..domain.observations import CheckSnapshot, PullRequestSnapshot, RegistrySnapshot
from ..domain.policies import REQUIRED_CONTEXT, evaluate_merge_gate
from ..domain.states import HoldKind
from ..ports.git import GitQueryPort
from ..ports.github import GitHubCommandPort, GitHubQueryPort
from ..ports.registry import RegistryQueryPort
from .pr_contract import (
    parse_body_issues,
    pull_request_holds,
    render_pull_request_body,
)
from .receipt_registry import exact_published_record


@dataclass(frozen=True)
class QueueResult:
    pull_request: PullRequestSnapshot
    required: CheckSnapshot
    live_main_sha: str


class QueueService:
    def __init__(
        self,
        *,
        registry: RegistryQueryPort,
        git: GitQueryPort,
        github_query: GitHubQueryPort,
        github_command: GitHubCommandPort,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self.clock = clock
        self.registry = registry
        self.git = git
        self.github_query = github_query
        self.github_command = github_command

    def _record(self, receipt: HandbackReceipt) -> RegistrySnapshot:
        return exact_published_record(self.registry, receipt)

    def enqueue(
        self,
        *,
        receipt: HandbackReceipt,
        pull_request_number: int,
        holds: frozenset[HoldKind] = frozenset(),
    ) -> QueueResult:
        live_main_sha = self.git.origin_main_sha()
        record = self._record(receipt)
        if not self.github_query.merge_queue_enabled("main"):
            raise PolicyViolation("main does not require GitHub merge queue admission")
        # The `required` context gates every merge group, so the queue validates
        # the merged result and a merely lagging PR needs no reanchor.
        validates = REQUIRED_CONTEXT in self.github_query.required_status_contexts(
            "main"
        )
        pull_request = self.github_query.get_pull_request(pull_request_number)
        durable_holds = pull_request_holds(pull_request)
        expected_body = render_pull_request_body(
            receipt,
            holds=durable_holds,
            issues=parse_body_issues(pull_request.body),
        )
        if pull_request.body != expected_body:
            raise PolicyViolation("PR body differs from typed handback")
        changed_paths = set(self.github_query.changed_paths(pull_request_number))
        if not changed_paths or not changed_paths.issubset(receipt.scope.paths):
            raise PolicyViolation("PR paths differ from typed Scope")
        required = self.github_query.required_check_snapshot(
            pull_request_number, fresh=True
        )
        decision = evaluate_merge_gate(
            pull_request=pull_request,
            receipt=receipt,
            live_main_sha=live_main_sha,
            registry=record,
            required=required,
            evaluated_at=self.clock(),
            holds=holds | durable_holds,
            merge_queue_validates=validates,
        )
        if not decision.allowed:
            raise PolicyViolation("; ".join(decision.reasons))
        if not validates and self.git.origin_main_sha() != live_main_sha:
            raise PolicyViolation(
                "origin/main changed during queue admission; re-read the exact merge front"
            )
        self.github_command.enqueue(
            number=pull_request_number,
            expected_base_sha=pull_request.base_sha,
            expected_head_sha=receipt.head_sha,
            expected_body=expected_body,
        )
        return QueueResult(
            pull_request=pull_request,
            required=required,
            live_main_sha=live_main_sha,
        )
