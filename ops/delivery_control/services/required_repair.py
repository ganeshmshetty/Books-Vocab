"""Fail-closed dispatch of one exact required-check workflow repair."""

from __future__ import annotations

from dataclasses import dataclass

from ..domain.errors import PolicyViolation
from ..domain.models import CheckStatus, HandbackReceipt
from ..domain.observations import CheckSnapshot, PullRequestSnapshot
from ..domain.states import HoldKind
from ..ports.github import GitHubQueryPort, GitHubWorkflowCommandPort
from ..ports.registry import RegistryQueryPort
from .pr_contract import (
    parse_body_issues,
    parse_pull_request_body,
    pull_request_holds,
    render_pull_request_body,
)
from .receipt_registry import exact_published_record

_REPAIRABLE = frozenset({CheckStatus.ABSENT, CheckStatus.FAILURE})


@dataclass(frozen=True)
class RequiredRepairResult:
    pull_request: PullRequestSnapshot
    required: CheckSnapshot
    holds: frozenset[HoldKind]
    dispatch_command: tuple[str, ...]
    dispatched: bool = True
    dispatch_action: str = "dispatch"
    dispatch_reason: str = ""
    merge_eligibility_assessed: bool = False


@dataclass(frozen=True)
class _RequiredContext:
    pull_request: PullRequestSnapshot
    receipt: HandbackReceipt
    holds: frozenset[HoldKind]


class RequiredRepairService:
    """Dispatch required only while every durable publication fact stays exact."""

    def __init__(
        self,
        *,
        registry: RegistryQueryPort,
        query: GitHubQueryPort,
        command: GitHubWorkflowCommandPort,
    ) -> None:
        self.registry = registry
        self.query = query
        self.command = command

    def _context(
        self,
        number: int,
        *,
        expected_receipt: HandbackReceipt | None = None,
    ) -> _RequiredContext:
        pull_request = self.query.get_pull_request(number)
        receipt = parse_pull_request_body(pull_request.body)
        if expected_receipt is not None and receipt != expected_receipt:
            raise PolicyViolation("PR receipt changed during required repair")
        record = exact_published_record(self.registry, receipt)
        published_target_base_sha = record.published_base_sha or record.base_sha

        inventory = self.query.list_pull_requests_for_branch(receipt.branch)
        if inventory.problems:
            raise PolicyViolation("GitHub PR mapping inventory is incomplete")
        if len(inventory.records) != 1 or inventory.records[0].number != number:
            raise PolicyViolation("operation lacks one unique GitHub PR mapping")
        mapped = inventory.records[0]
        if (
            mapped.branch != pull_request.branch
            or mapped.base_branch != pull_request.base_branch
            or mapped.base_sha != pull_request.base_sha
            or mapped.head_sha != pull_request.head_sha
            or mapped.state != pull_request.state
            or mapped.draft != pull_request.draft
            or mapped.body != pull_request.body
            or mapped.labels != pull_request.labels
        ):
            raise PolicyViolation("GitHub PR mapping differs from direct PR read")

        holds = pull_request_holds(pull_request)
        expected_body = render_pull_request_body(
            receipt, holds=holds, issues=parse_body_issues(pull_request.body)
        )
        if (
            pull_request.state != "OPEN"
            or pull_request.draft
            or pull_request.base_branch != "main"
            or pull_request.branch != receipt.branch
            or pull_request.base_sha != published_target_base_sha
            or pull_request.head_sha != receipt.head_sha
            or pull_request.body != expected_body
        ):
            raise PolicyViolation("PR tuple differs from the durable receipt")
        if not receipt.scope.allows_changed_paths(self.query.changed_paths(number)):
            raise PolicyViolation("PR paths differ from typed Scope")
        return _RequiredContext(pull_request, receipt, holds)

    def _required(self, number: int, *, head_sha: str) -> CheckSnapshot:
        required = self.query.required_check_snapshot(number, fresh=True)
        if required.head_sha != head_sha:
            raise PolicyViolation("required check differs from the exact PR HEAD")
        if required.status not in _REPAIRABLE:
            raise PolicyViolation(
                f"required check is already {required.status.value}; "
                "refusing duplicate dispatch"
            )
        return required

    def trigger(self, number: int) -> RequiredRepairResult:
        initial = self._context(number)
        self._required(number, head_sha=initial.receipt.head_sha)

        current = self._context(number, expected_receipt=initial.receipt)
        required = self._required(number, head_sha=current.receipt.head_sha)
        final = self._context(number, expected_receipt=current.receipt)

        outcome = self.command.trigger_required(
            number=number,
            branch=final.pull_request.branch,
            base_sha=final.pull_request.base_sha,
            head_sha=final.pull_request.head_sha,
        )
        return RequiredRepairResult(
            pull_request=final.pull_request,
            required=required,
            holds=final.holds,
            dispatch_command=outcome.command,
            dispatched=outcome.dispatched,
            dispatch_action=outcome.action,
            dispatch_reason=outcome.reason,
        )
