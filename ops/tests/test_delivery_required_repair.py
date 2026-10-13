from __future__ import annotations

import sys
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
ROOT = OPS.parent
sys.path.insert(0, str(OPS))

from delivery_control.cli import _jsonable
from delivery_control.domain.errors import PolicyViolation
from delivery_control.domain.models import CheckStatus, HandbackReceipt, Scope
from delivery_control.domain.observations import (
    CheckSnapshot,
    PullRequestInventory,
    PullRequestSnapshot,
    RegistryInventory,
    RegistrySnapshot,
)
from delivery_control.domain.states import HoldKind
from delivery_control.ports.github import RequiredTriggerOutcome
from delivery_control.services.pr_contract import render_pull_request_body
from delivery_control.services.required_repair import RequiredRepairService

BASE = "a" * 40
HEAD = "b" * 40


def _receipt() -> HandbackReceipt:
    return HandbackReceipt(
        lane_id="DIRECT-REQUIRED",
        owner_thread_id="thread-required",
        claim_generation=4,
        branch="feat/required",
        worktree_path="/tmp/required",
        base_sha=BASE,
        parent_sha=BASE,
        head_sha=HEAD,
        origin_main_sha=BASE,
        content_digest="c" * 64,
        scope=Scope.from_paths(modify=("ops/a.py",)),
    )


def _record(
    receipt: HandbackReceipt, *, published_base_sha: str | None = None
) -> RegistrySnapshot:
    return RegistrySnapshot(
        lane_id=receipt.lane_id,
        branch=receipt.branch,
        path=Path(receipt.worktree_path),
        status="published",
        scope=receipt.scope,
        base_sha=receipt.base_sha,
        claim_generation=receipt.claim_generation,
        published_base_sha=published_base_sha,
        owner_thread_id=receipt.owner_thread_id,
        handed_back_sha=receipt.head_sha,
        handback_claim_generation=receipt.claim_generation,
        handback_valid=True,
        handback_digest=receipt.content_digest,
        handback_origin_main_sha=receipt.origin_main_sha,
    )


def _pull_request(
    receipt: HandbackReceipt, *, base_sha: str | None = None
) -> PullRequestSnapshot:
    holds = frozenset({HoldKind.SECURITY})
    return PullRequestSnapshot(
        number=17,
        url="https://example.test/pull/17",
        branch=receipt.branch,
        base_sha=base_sha or receipt.base_sha,
        head_sha=receipt.head_sha,
        state="OPEN",
        draft=False,
        mergeable=False,
        title="fix: required trigger",
        body=render_pull_request_body(receipt, holds=holds),
        labels=("delivery-hold:security",),
    )


class FakeRegistry:
    def __init__(self, record: RegistrySnapshot) -> None:
        self.record = record
        self.reads = 0

    def list_records(self) -> RegistryInventory:
        self.reads += 1
        return RegistryInventory((self.record,))


class FakeGitHub:
    def __init__(
        self,
        pull_request: PullRequestSnapshot,
        *,
        statuses: tuple[CheckStatus, ...],
        changed_paths: tuple[str, ...] = ("ops/a.py",),
    ) -> None:
        self.pull_request = pull_request
        self.statuses = list(statuses)
        self.paths = changed_paths
        self.mapping = (pull_request,)
        self.dispatches: list[tuple[int, str, str, str]] = []
        self.outcome = RequiredTriggerOutcome(
            ("gh", "workflow", "run", "pr-gate.yml"), "dispatch", "fake dispatch"
        )
        self.get_reads = 0
        self.drift_after_first_read: PullRequestSnapshot | None = None

    def get_pull_request(self, number: int) -> PullRequestSnapshot:
        assert number == 17
        self.get_reads += 1
        if self.get_reads > 1 and self.drift_after_first_read is not None:
            return self.drift_after_first_read
        return self.pull_request

    def list_pull_requests_for_branch(self, branch: str) -> PullRequestInventory:
        assert branch == "feat/required"
        return PullRequestInventory(self.mapping)

    def changed_paths(self, number: int) -> tuple[str, ...]:
        assert number == 17
        return self.paths

    def required_check_snapshot(
        self, number: int, *, fresh: bool = False
    ) -> CheckSnapshot:
        assert number == 17
        status = self.statuses.pop(0)
        return CheckSnapshot(
            status=status,
            head_sha=HEAD,
            observed_at=datetime(2026, 8, 22, tzinfo=UTC),
            names=() if status is CheckStatus.ABSENT else ("required",),
        )

    def trigger_required(
        self, *, number: int, branch: str, base_sha: str, head_sha: str
    ) -> RequiredTriggerOutcome:
        self.dispatches.append((number, branch, base_sha, head_sha))
        return self.outcome


def _service(
    status: CheckStatus,
) -> tuple[RequiredRepairService, FakeRegistry, FakeGitHub]:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    github = FakeGitHub(_pull_request(receipt), statuses=(status, status))
    return (
        RequiredRepairService(registry=registry, query=github, command=github),
        registry,
        github,
    )


@pytest.mark.parametrize("status", [CheckStatus.ABSENT, CheckStatus.FAILURE])
def test_required_repair_dispatches_only_repairable_statuses(
    status: CheckStatus,
) -> None:
    service, registry, github = _service(status)

    result = service.trigger(17)

    assert github.dispatches == [(17, "feat/required", BASE, HEAD)]
    assert result.required.status is status
    assert result.holds == frozenset({HoldKind.SECURITY})
    assert result.merge_eligibility_assessed is False
    assert registry.reads >= 2
    assert github.get_reads >= 2


def test_required_repair_reports_wait_decision_without_dispatch_claim() -> None:
    service, _, github = _service(CheckStatus.ABSENT)
    github.outcome = RequiredTriggerOutcome(
        (), "wait", "run 7 is queued for 20m; legitimate runner wait"
    )

    result = service.trigger(17)

    assert result.dispatched is False
    assert result.dispatch_command == ()
    payload = _jsonable(result)
    assert payload["dispatched"] is False
    assert payload["dispatch_action"] == "wait"
    assert (
        payload["dispatch_reason"] == "run 7 is queued for 20m; legitimate runner wait"
    )


def test_required_repair_reports_dispatch_decision_reason() -> None:
    service, _, github = _service(CheckStatus.FAILURE)

    payload = _jsonable(service.trigger(17))

    assert payload["dispatched"] is True
    assert payload["dispatch_action"] == "dispatch"
    assert payload["dispatch_reason"] == "fake dispatch"


def test_required_repair_accepts_recorded_published_target_base() -> None:
    target_base = "d" * 40
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, published_base_sha=target_base))
    github = FakeGitHub(
        _pull_request(receipt, base_sha=target_base),
        statuses=(CheckStatus.ABSENT, CheckStatus.ABSENT),
    )
    service = RequiredRepairService(registry=registry, query=github, command=github)

    service.trigger(17)

    assert github.dispatches == [(17, "feat/required", target_base, HEAD)]


def test_required_repair_accepts_actual_changed_paths_as_scope_subset() -> None:
    receipt = replace(
        _receipt(),
        scope=Scope.from_paths(modify=("ops/a.py", "ops/b.py")),
    )
    registry = FakeRegistry(_record(receipt))
    github = FakeGitHub(
        _pull_request(receipt),
        statuses=(CheckStatus.ABSENT, CheckStatus.ABSENT),
        changed_paths=("ops/a.py",),
    )
    service = RequiredRepairService(registry=registry, query=github, command=github)

    service.trigger(17)

    assert github.dispatches == [(17, "feat/required", BASE, HEAD)]


def test_required_repair_rejects_unrecorded_published_target_base_drift() -> None:
    target_base = "d" * 40
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, published_base_sha=target_base))
    github = FakeGitHub(
        _pull_request(receipt),
        statuses=(CheckStatus.ABSENT, CheckStatus.ABSENT),
    )
    service = RequiredRepairService(registry=registry, query=github, command=github)

    with pytest.raises(PolicyViolation, match="PR tuple differs"):
        service.trigger(17)

    assert github.dispatches == []


@pytest.mark.parametrize("status", [CheckStatus.PENDING, CheckStatus.SUCCESS])
def test_required_repair_refuses_running_or_successful_required(
    status: CheckStatus,
) -> None:
    service, _, github = _service(status)

    with pytest.raises(PolicyViolation, match="required check is already"):
        service.trigger(17)

    assert github.dispatches == []


def test_required_repair_refuses_required_that_becomes_pending() -> None:
    service, _, github = _service(CheckStatus.ABSENT)
    github.statuses = [CheckStatus.ABSENT, CheckStatus.PENDING]

    with pytest.raises(PolicyViolation, match="required check is already pending"):
        service.trigger(17)

    assert github.dispatches == []


def test_required_repair_requires_published_registry_receipt() -> None:
    service, registry, github = _service(CheckStatus.ABSENT)
    registry.record = replace(registry.record, status="active")

    with pytest.raises(PolicyViolation, match="published state"):
        service.trigger(17)

    assert github.dispatches == []


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ({"base_sha": "d" * 40}, "PR tuple differs"),
        ({"head_sha": "d" * 40}, "PR tuple differs"),
        ({"body": "tampered"}, "typed delivery receipt"),
    ],
)
def test_required_repair_refuses_pr_contract_drift(
    change: dict[str, object], message: str
) -> None:
    service, _, github = _service(CheckStatus.ABSENT)
    github.pull_request = replace(github.pull_request, **change)
    github.mapping = (github.pull_request,)

    with pytest.raises(PolicyViolation, match=message):
        service.trigger(17)

    assert github.dispatches == []


def test_required_repair_refuses_nonunique_branch_mapping_or_scope() -> None:
    service, _, github = _service(CheckStatus.ABSENT)
    github.mapping = (github.pull_request, replace(github.pull_request, number=18))

    with pytest.raises(PolicyViolation, match="unique GitHub PR mapping"):
        service.trigger(17)

    github.mapping = (github.pull_request,)
    github.paths = ("ops/other.py",)
    with pytest.raises(PolicyViolation, match="PR paths differ"):
        service.trigger(17)


def test_required_repair_rereads_contract_before_dispatch() -> None:
    service, _, github = _service(CheckStatus.ABSENT)
    github.drift_after_first_read = replace(github.pull_request, head_sha="d" * 40)

    with pytest.raises(PolicyViolation, match="differs"):
        service.trigger(17)

    assert github.dispatches == []


def test_pr_gate_manual_dispatch_is_exact_sha_only() -> None:
    workflow = (ROOT / ".github/workflows/pr-gate.yml").read_text(encoding="utf-8")

    for field in ("pr_number", "base_sha", "head_sha"):
        assert f"      {field}:" in workflow
    assert "HEAD^" not in workflow
    assert "EVENT_SHA: ${{ github.sha }}" in workflow
    assert 'if [[ "$EVENT_SHA" != "$HEAD_SHA" ]]' in workflow
    # The whitespace check starts at the merge base: BASE_SHA is main's tip when
    # the run started, so a direct two-point diff would also contain the reverse
    # of every main commit merged after the PR forked.
    assert (
        'git diff --check "$(git merge-base "$BASE_SHA" "$HEAD_SHA")" "$HEAD_SHA"'
        in workflow
    )
    assert 'git diff --check "$BASE_SHA" "$HEAD_SHA"' not in workflow
    assert workflow.count("ref: ${{ env.HEAD_SHA }}") == 3
    assert workflow.count("Verify exact head checkout") == 3
