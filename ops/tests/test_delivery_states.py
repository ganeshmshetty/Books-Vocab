from __future__ import annotations

import sys
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.domain.models import (
    HandbackReceipt,
    Scope,
)
from delivery_control.domain.observations import (
    CheckSnapshot,
    FileChange,
    FileOperation,
    PullRequestSnapshot,
    RegistrySnapshot,
    WorktreeSnapshot,
)
from delivery_control.domain.policies import evaluate_merge_gate, evaluate_publication
from delivery_control.domain.states import (
    CheckStatus,
    HoldKind,
    LaneFacts,
    LaneState,
    NextAction,
    derive_lane_decision,
)
from delivery_control.services.correlation import collision_keys


@pytest.mark.parametrize(
    ("facts", "state", "action"),
    [
        (
            LaneFacts(duplicate_pr=True),
            LaneState.BLOCKED_DUPLICATE,
            NextAction.DEDUPLICATE,
        ),
        (
            LaneFacts(scope_collision=True),
            LaneState.BLOCKED_COLLISION,
            NextAction.RESOLVE_COLLISION,
        ),
        (
            LaneFacts(merged=True, cleanup_complete=True),
            LaneState.DONE,
            NextAction.NONE,
        ),
        (
            LaneFacts(abandoned=True, cleanup_complete=True),
            LaneState.DONE,
            NextAction.NONE,
        ),
        (
            LaneFacts(merged=True, cleanup_policy_passed=True),
            LaneState.TERMINAL_CLEANUP,
            NextAction.CLEANUP,
        ),
        (
            LaneFacts(pr_open=True, holds=frozenset({HoldKind.SECURITY})),
            LaneState.SECURITY_HOLD,
            NextAction.WAIT_CLEARANCE,
        ),
        (
            LaneFacts(pr_open=True, pr_draft=True),
            LaneState.PR_DRAFT,
            NextAction.FINALIZE_PR,
        ),
        (
            LaneFacts(pr_open=True, required_status=CheckStatus.FAILURE),
            LaneState.REQUIRED_FAILED,
            NextAction.REPAIR_REQUIRED,
        ),
        (
            LaneFacts(pr_open=True, pr_contract_valid=False),
            LaneState.PR_CONTRACT_FAILED,
            NextAction.REPAIR_PR_CONTRACT,
        ),
        (
            LaneFacts(
                pr_open=True,
                queued=True,
                required_status=CheckStatus.FAILURE,
            ),
            LaneState.PR_QUEUED,
            NextAction.WAIT_MERGE,
        ),
        (
            LaneFacts(
                pr_open=True,
                required_status=CheckStatus.SUCCESS,
                mergeable=True,
                merge_policy_passed=True,
            ),
            LaneState.READY_TO_QUEUE,
            NextAction.ENQUEUE,
        ),
        (
            LaneFacts(pr_open=True, required_status=CheckStatus.PENDING),
            LaneState.PR_WAITING_REQUIRED,
            NextAction.WAIT_REQUIRED,
        ),
        (
            LaneFacts(
                published=True,
                pr_open=True,
                required_status=CheckStatus.SUCCESS,
                mergeable=True,
                reanchor_policy_passed=True,
            ),
            LaneState.REANCHOR,
            NextAction.REANCHOR,
        ),
        (
            LaneFacts(handback_valid=True, transport_policy_passed=True),
            LaneState.HANDBACK_PUBLISHABLE,
            NextAction.PUBLISH,
        ),
        (LaneFacts(dirty=True), LaneState.BLOCKED_DIRTY, NextAction.RECOVER_DIRTY),
        (
            LaneFacts(
                has_worktree=True,
                owner_known=True,
                owner_reachable=True,
                dirty=True,
            ),
            LaneState.ACTIVE_DEVELOPMENT,
            NextAction.CONTINUE_WORK,
        ),
        (
            LaneFacts(has_worktree=True, owner_known=True, owner_reachable=True),
            LaneState.ACTIVE_DEVELOPMENT,
            NextAction.CONTINUE_WORK,
        ),
        (
            LaneFacts(has_worktree=True, owner_known=False),
            LaneState.BLOCKED_OWNER,
            NextAction.RECOVER_OWNER,
        ),
        (
            LaneFacts(
                has_worktree=True,
                owner_known=True,
                owner_reachable=False,
            ),
            LaneState.BLOCKED_OWNER,
            NextAction.RECOVER_OWNER,
        ),
        (
            LaneFacts(
                has_worktree=True,
                owner_known=True,
                owner_reachable=False,
                handback_valid=True,
                transport_policy_passed=True,
            ),
            LaneState.HANDBACK_PUBLISHABLE,
            NextAction.PUBLISH,
        ),
        (
            LaneFacts(
                has_worktree=True,
                owner_known=True,
                owner_reachable=True,
                has_committed_diff=False,
                abandonment_policy_passed=True,
            ),
            LaneState.ABANDONABLE_NOOP,
            NextAction.ABANDON,
        ),
        (LaneFacts(), LaneState.UNKNOWN, NextAction.INSPECT),
    ],
)
def test_lane_state_is_derived_deterministically(
    facts: LaneFacts,
    state: LaneState,
    action: NextAction,
) -> None:
    decision = derive_lane_decision(facts)
    assert decision.state is state
    assert decision.next_action is action


def test_duplicate_beats_a_superficially_ready_pr() -> None:
    decision = derive_lane_decision(
        LaneFacts(
            duplicate_pr=True,
            pr_open=True,
            required_status=CheckStatus.SUCCESS,
            mergeable=True,
        )
    )
    assert decision.state is LaneState.BLOCKED_DUPLICATE


def test_published_local_assets_are_drained_before_waiting_on_ci() -> None:
    decision = derive_lane_decision(
        LaneFacts(
            published=True,
            local_assets_present=True,
            pr_open=True,
            required_status=CheckStatus.PENDING,
        )
    )
    assert decision.state is LaneState.PUBLISHED_LOCAL_CLEANUP
    assert decision.next_action is NextAction.CLEANUP_LOCAL


def test_stale_required_green_exact_pr_reanchors_instead_of_waiting() -> None:
    decision = derive_lane_decision(
        LaneFacts(
            published=True,
            pr_open=True,
            pr_contract_valid=True,
            required_status=CheckStatus.SUCCESS,
            mergeable=True,
            merge_policy_passed=False,
            reanchor_policy_passed=True,
        )
    )

    assert decision.state is LaneState.REANCHOR
    assert decision.next_action is NextAction.REANCHOR


def test_generic_merge_policy_failure_does_not_claim_reanchor_is_safe() -> None:
    decision = derive_lane_decision(
        LaneFacts(
            published=True,
            pr_open=True,
            pr_contract_valid=True,
            required_status=CheckStatus.SUCCESS,
            mergeable=True,
            merge_policy_passed=False,
            reanchor_policy_passed=False,
        )
    )

    assert decision.state is LaneState.PR_WAITING_REQUIRED
    assert decision.next_action is NextAction.WAIT_REQUIRED


def _receipt(*, base_sha: str = "a" * 40) -> HandbackReceipt:
    return HandbackReceipt(
        lane_id="DIRECT-1",
        owner_thread_id="thread-1",
        claim_generation=2,
        branch="feat/example",
        worktree_path="/tmp/example",
        base_sha=base_sha,
        parent_sha=base_sha,
        head_sha="b" * 40,
        origin_main_sha="c" * 40,
        content_digest="d" * 64,
        scope=Scope.from_paths(modify=("ops/a.py",)),
    )


def test_publication_policy_does_not_require_current_base_or_local_quality() -> None:
    receipt = _receipt(base_sha="a" * 40)
    worktree = WorktreeSnapshot(
        path=Path("/tmp/example"),
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        parent_sha=receipt.parent_sha,
        clean=True,
        changes=(FileChange(FileOperation.MODIFY, "ops/a.py"),),
    )
    registry = _registry(receipt)
    assert evaluate_publication(
        receipt=receipt,
        registry=registry,
        worktree=worktree,
        duplicate_pr=False,
        scope_collision=False,
    ).allowed


GATE_NOW = datetime(2026, 8, 21, tzinfo=UTC)


def _registry(
    receipt: HandbackReceipt, *, published_base_sha: str | None = None
) -> RegistrySnapshot:
    return RegistrySnapshot(
        lane_id=receipt.lane_id,
        branch=receipt.branch,
        path=Path(receipt.worktree_path),
        status="active",
        scope=receipt.scope,
        base_sha=receipt.base_sha,
        claim_generation=receipt.claim_generation,
        owner_thread_id=receipt.owner_thread_id,
        handed_back_sha=receipt.head_sha,
        handback_claim_generation=receipt.claim_generation,
        handback_valid=True,
        published_base_sha=published_base_sha,
    )


def test_merge_policy_requires_exact_live_base_required_success_and_no_hold() -> None:
    receipt = _receipt(base_sha="a" * 40)
    pull_request = PullRequestSnapshot(
        number=1,
        url="https://example.test/pull/1",
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        state="OPEN",
        draft=False,
        mergeable=True,
    )
    allowed = evaluate_merge_gate(
        pull_request=pull_request,
        receipt=receipt,
        registry=_registry(receipt),
        evaluated_at=GATE_NOW,
        live_main_sha="a" * 40,
        required=CheckSnapshot(
            status=CheckStatus.SUCCESS,
            head_sha=receipt.head_sha,
            observed_at=datetime(2026, 8, 21, tzinfo=UTC),
            names=("required",),
        ),
    )
    stale = evaluate_merge_gate(
        pull_request=pull_request,
        receipt=receipt,
        registry=_registry(receipt),
        evaluated_at=GATE_NOW,
        live_main_sha="c" * 40,
        required=CheckSnapshot(
            status=CheckStatus.SUCCESS,
            head_sha=receipt.head_sha,
            observed_at=datetime(2026, 8, 21, tzinfo=UTC),
            names=("required",),
        ),
    )
    held = evaluate_merge_gate(
        pull_request=pull_request,
        receipt=receipt,
        registry=_registry(receipt),
        evaluated_at=GATE_NOW,
        live_main_sha="a" * 40,
        required=CheckSnapshot(
            status=CheckStatus.SUCCESS,
            head_sha=receipt.head_sha,
            observed_at=datetime(2026, 8, 21, tzinfo=UTC),
            names=("required",),
        ),
        holds=frozenset({HoldKind.SECURITY}),
    )
    assert allowed.allowed
    assert not stale.allowed
    assert "stale" in " ".join(stale.reasons)
    assert not held.allowed


def test_merge_policy_uses_published_pr_target_after_handback_base_advances() -> None:
    receipt = _receipt(base_sha="a" * 40)
    pull_request = PullRequestSnapshot(
        number=1,
        url="https://example.test/pull/1",
        branch=receipt.branch,
        base_sha="c" * 40,
        head_sha=receipt.head_sha,
        state="OPEN",
        draft=False,
        mergeable=True,
    )
    decision = evaluate_merge_gate(
        pull_request=pull_request,
        receipt=receipt,
        registry=_registry(receipt, published_base_sha="c" * 40),
        evaluated_at=GATE_NOW,
        live_main_sha="c" * 40,
        required=CheckSnapshot(
            status=CheckStatus.SUCCESS,
            head_sha=receipt.head_sha,
            observed_at=datetime(2026, 8, 21, tzinfo=UTC),
            names=("required",),
        ),
    )

    assert decision.allowed


def test_merge_policy_rejects_published_pr_target_that_is_not_live() -> None:
    receipt = _receipt(base_sha="a" * 40)
    pull_request = PullRequestSnapshot(
        number=1,
        url="https://example.test/pull/1",
        branch=receipt.branch,
        base_sha="c" * 40,
        head_sha=receipt.head_sha,
        state="OPEN",
        draft=False,
        mergeable=True,
    )
    decision = evaluate_merge_gate(
        pull_request=pull_request,
        receipt=receipt,
        registry=_registry(receipt, published_base_sha="b" * 40),
        evaluated_at=GATE_NOW,
        live_main_sha="c" * 40,
        required=CheckSnapshot(
            status=CheckStatus.SUCCESS,
            head_sha=receipt.head_sha,
            observed_at=datetime(2026, 8, 21, tzinfo=UTC),
            names=("required",),
        ),
    )

    assert not decision.allowed
    assert "stale" in " ".join(decision.reasons)


def test_merge_policy_requires_published_target_for_stale_handback() -> None:
    receipt = _receipt(base_sha="a" * 40)
    pull_request = PullRequestSnapshot(
        number=1,
        url="https://example.test/pull/1",
        branch=receipt.branch,
        base_sha="c" * 40,
        head_sha=receipt.head_sha,
        state="OPEN",
        draft=False,
        mergeable=True,
    )
    decision = evaluate_merge_gate(
        pull_request=pull_request,
        receipt=receipt,
        registry=_registry(receipt),
        evaluated_at=GATE_NOW,
        live_main_sha="c" * 40,
        required=CheckSnapshot(
            status=CheckStatus.SUCCESS,
            head_sha=receipt.head_sha,
            observed_at=datetime(2026, 8, 21, tzinfo=UTC),
            names=("required",),
        ),
    )

    assert not decision.allowed
    assert "stale" in " ".join(decision.reasons)


def test_merge_policy_rejects_success_from_another_head() -> None:
    receipt = _receipt()
    pull_request = PullRequestSnapshot(
        number=1,
        url="https://example.test/pull/1",
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        state="OPEN",
        draft=False,
        mergeable=True,
    )
    decision = evaluate_merge_gate(
        pull_request=pull_request,
        receipt=receipt,
        registry=_registry(receipt),
        evaluated_at=GATE_NOW,
        live_main_sha=receipt.base_sha,
        required=CheckSnapshot(
            status=CheckStatus.SUCCESS,
            head_sha="e" * 40,
            observed_at=datetime(2026, 8, 21, tzinfo=UTC),
            names=("required",),
        ),
    )
    assert not decision.allowed
    assert "another HEAD" in " ".join(decision.reasons)


@pytest.mark.parametrize(
    ("changes", "validates", "reason"),
    [
        ({}, True, None),
        ({}, False, "stale"),
        ({"mergeable": False, "conflicting": True}, True, "reanchor_required"),
        ({"head_sha": "e" * 40}, True, "PR head differs"),
        ({"base_sha": "c" * 40}, True, "differs from published registry base"),
    ],
)
def test_merge_queue_admits_lagging_pr_unless_conflicting_or_moved(
    changes: dict[str, object], validates: bool, reason: str | None
) -> None:
    receipt = _receipt(base_sha="a" * 40)
    lagging = PullRequestSnapshot(
        number=1,
        url="https://example.test/pull/1",
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        state="OPEN",
        draft=False,
        mergeable=True,
    )
    decision = evaluate_merge_gate(
        pull_request=replace(lagging, **changes),
        receipt=receipt,
        registry=_registry(receipt),
        evaluated_at=GATE_NOW,
        live_main_sha="c" * 40,
        required=CheckSnapshot(
            status=CheckStatus.SUCCESS,
            head_sha=receipt.head_sha,
            observed_at=datetime(2026, 8, 21, tzinfo=UTC),
            names=("required",),
        ),
        merge_queue_validates=validates,
    )

    assert decision.allowed is (reason is None)
    assert reason is None or reason in " ".join(decision.reasons)


@pytest.mark.parametrize(
    ("changes", "validates", "reason"),
    [
        ({}, True, None),
        ({}, False, "stale"),
        ({"mergeable": False, "conflicting": True}, True, "reanchor_required"),
        ({"head_sha": "e" * 40}, True, "PR head differs"),
        # the PR target no longer matches the registry's published base
        ({"base_sha": "a" * 40}, True, "differs from published registry base"),
    ],
)
def test_merge_queue_admits_lagging_published_registry_base(
    changes: dict[str, object], validates: bool, reason: str | None
) -> None:
    """The production "registry base is stale" refusal: published base lags main."""
    receipt = _receipt(base_sha="a" * 40)
    published = "b" * 40
    lagging = PullRequestSnapshot(
        number=1,
        url="https://example.test/pull/1",
        branch=receipt.branch,
        base_sha=published,
        head_sha=receipt.head_sha,
        state="OPEN",
        draft=False,
        mergeable=True,
    )
    decision = evaluate_merge_gate(
        pull_request=replace(lagging, **changes),
        receipt=receipt,
        registry=_registry(receipt, published_base_sha=published),
        evaluated_at=GATE_NOW,
        live_main_sha="c" * 40,
        required=CheckSnapshot(
            status=CheckStatus.SUCCESS,
            head_sha=receipt.head_sha,
            observed_at=datetime(2026, 8, 21, tzinfo=UTC),
            names=("required",),
        ),
        merge_queue_validates=validates,
    )

    assert decision.allowed is (reason is None)
    assert reason is None or reason in " ".join(decision.reasons)


@pytest.mark.parametrize(
    "facts",
    [
        LaneFacts(
            has_worktree=True,
            owner_known=True,
            owner_reachable=True,
            dirty=True,
            handback_valid=True,
        ),
        LaneFacts(
            has_worktree=True,
            owner_known=True,
            owner_reachable=False,
            has_committed_diff=False,
        ),
        LaneFacts(
            pr_open=True,
            required_status=CheckStatus.SUCCESS,
            mergeable=True,
        ),
    ],
)
def test_observations_without_policy_decisions_never_trigger_side_effects(
    facts: LaneFacts,
) -> None:
    assert derive_lane_decision(facts).next_action not in {
        NextAction.PUBLISH,
        NextAction.ABANDON,
        NextAction.ENQUEUE,
    }


def test_publication_rejects_operation_or_generation_mismatch() -> None:
    receipt = _receipt()
    registry = _registry(receipt)
    wrong_generation = RegistrySnapshot(
        **{
            **registry.__dict__,
            "claim_generation": registry.claim_generation + 1,
        }
    )
    worktree = WorktreeSnapshot(
        path=Path(receipt.worktree_path),
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        parent_sha=receipt.parent_sha,
        clean=True,
        changes=(FileChange(FileOperation.ADD, "ops/a.py"),),
    )
    decision = evaluate_publication(
        receipt=receipt,
        registry=wrong_generation,
        worktree=worktree,
        duplicate_pr=False,
        scope_collision=False,
    )
    assert not decision.allowed
    assert "generation" in " ".join(decision.reasons)
    assert "operations" in " ".join(decision.reasons)


def test_publication_accepts_normalized_rename_and_copy_scope() -> None:
    receipt = HandbackReceipt(
        **{
            **_receipt().__dict__,
            "scope": Scope.from_paths(
                delete=("ops/old.py",),
                add=("ops/copied.py", "ops/new.py"),
            ),
        }
    )
    worktree = WorktreeSnapshot(
        path=Path(receipt.worktree_path),
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        parent_sha=receipt.parent_sha,
        clean=True,
        changes=(
            FileChange(FileOperation.ADD, "ops/copied.py"),
            FileChange(FileOperation.ADD, "ops/new.py"),
            FileChange(FileOperation.DELETE, "ops/old.py"),
        ),
    )

    assert evaluate_publication(
        receipt=receipt,
        registry=_registry(receipt),
        worktree=worktree,
        duplicate_pr=False,
        scope_collision=False,
    ).allowed


def test_publication_rejects_rename_scope_that_omits_the_source_path() -> None:
    receipt = HandbackReceipt(
        **{
            **_receipt().__dict__,
            "scope": Scope.from_paths(add=("ops/new.py",)),
        }
    )
    worktree = WorktreeSnapshot(
        path=Path(receipt.worktree_path),
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        parent_sha=receipt.parent_sha,
        clean=True,
        changes=(
            FileChange(FileOperation.ADD, "ops/new.py"),
            FileChange(FileOperation.DELETE, "ops/old.py"),
        ),
    )

    decision = evaluate_publication(
        receipt=receipt,
        registry=_registry(receipt),
        worktree=worktree,
        duplicate_pr=False,
        scope_collision=False,
    )

    assert not decision.allowed
    assert "physical operations or paths differ from Scope" in decision.reasons


def test_normalized_rename_source_participates_in_scope_collision() -> None:
    rename_scope = Scope.from_paths(
        delete=("ops/old.py",),
        add=("ops/new.py",),
    )

    assert collision_keys(
        {
            "rename": set(rename_scope.paths),
            "other": {"ops/old.py"},
        }
    ) == {"other", "rename"}


def test_merge_policy_rejects_required_success_observed_too_long_ago() -> None:
    receipt = _receipt(base_sha="a" * 40)
    pull_request = PullRequestSnapshot(
        number=1,
        url="https://example.test/pull/1",
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        state="OPEN",
        draft=False,
        mergeable=True,
    )
    decision = evaluate_merge_gate(
        pull_request=pull_request,
        receipt=receipt,
        registry=_registry(receipt),
        evaluated_at=GATE_NOW + timedelta(seconds=301),
        live_main_sha="a" * 40,
        required=CheckSnapshot(
            status=CheckStatus.SUCCESS,
            head_sha=receipt.head_sha,
            observed_at=GATE_NOW,
            names=("required",),
        ),
    )

    assert not decision.allowed
    assert "required checks observation is stale" in decision.reasons
