from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

import delivery_control.services.orphan_branch as orphan_branch_module
from delivery_control.domain.branch_refs import BranchInventory
from delivery_control.domain.errors import (
    DeliverySourceError,
    PolicyViolation,
)
from delivery_control.domain.models import Scope
from delivery_control.domain.observations import (
    CanonicalCheckoutSnapshot,
    InventoryProblem,
    PhysicalWorktree,
    PullRequestInventory,
    RegistryInventory,
    RegistrySnapshot,
)
from delivery_control.services.orphan_branch import (
    OrphanBranchDiscardService,
)

BASE = "a" * 40
HEAD = "b" * 40
BRANCH = "feat/orphan"
OTHER_BRANCH = "feat/other-orphan"
PATH = Path("/tmp/orphan")


class FakeRegistry:
    def __init__(self, inventory: RegistryInventory | None = None) -> None:
        self.inventory = inventory or RegistryInventory(())

    def list_records(self) -> RegistryInventory:
        return self.inventory


class FakeGit:
    def __init__(
        self,
        *,
        local: str | None = HEAD,
        remote: str | None = None,
        physical: tuple[PhysicalWorktree, ...] = (),
        canonical_branch: str = "main",
        canonical_head: str = BASE,
        canonical_clean: bool = True,
        origin: str = BASE,
        ancestor: bool = True,
        patch_equivalent: bool = False,
        failure: str | None = None,
        branch_inventory: BranchInventory | None = None,
    ) -> None:
        self.local = local
        self.remote = remote
        self.physical = physical
        self.canonical_branch = canonical_branch
        self.canonical_head = canonical_head
        self.canonical_clean = canonical_clean
        self.origin = origin
        self.ancestor = ancestor
        self.patch_equivalent = patch_equivalent
        self.failure = failure
        self.actions: list[str] = []
        self.branch_inventory_snapshot = branch_inventory or BranchInventory(
            local=((BRANCH, local),) if local is not None else (),
            remote=((BRANCH, remote),) if remote is not None else (),
        )
        self.canonical_calls = 0
        self.origin_calls = 0
        self.worktree_calls = 0
        self.branch_inventory_calls = 0
        self.local_calls = 0
        self.remote_calls = 0
        self.patch_equivalent_calls = 0

    def canonical_checkout(self) -> CanonicalCheckoutSnapshot:
        self.canonical_calls += 1
        return CanonicalCheckoutSnapshot(
            Path("/repo"),
            self.canonical_branch,
            self.canonical_head,
            self.canonical_clean,
        )

    def origin_main_sha(self) -> str:
        self.origin_calls += 1
        return self.origin

    def list_worktrees(self) -> tuple[PhysicalWorktree, ...]:
        self.worktree_calls += 1
        return self.physical

    def branch_inventory(self) -> BranchInventory:
        self.branch_inventory_calls += 1
        return self.branch_inventory_snapshot

    def local_branch_sha(self, branch: str) -> str | None:
        self.local_calls += 1
        if self.failure == "local":
            raise DeliverySourceError("local ref unavailable")
        return self.local

    def remote_branch_sha(self, branch: str) -> str | None:
        self.remote_calls += 1
        if self.failure == "remote":
            raise DeliverySourceError("remote ref unavailable")
        return self.remote

    def is_ancestor(self, ancestor_sha: str, descendant_sha: str) -> bool:
        if self.failure == "ancestor":
            raise DeliverySourceError("ancestor query unavailable")
        return self.ancestor

    def is_patch_equivalent(self, branch_sha: str, main_sha: str) -> bool:
        self.patch_equivalent_calls += 1
        if self.failure == "patch_equivalent":
            raise DeliverySourceError("patch-equivalence query unavailable")
        return self.patch_equivalent

    def delete_local_branch(self, branch: str, *, expected_head_sha: str) -> None:
        assert expected_head_sha == HEAD
        self.actions.append("delete-local")
        self.local = None

    def delete_remote_branch(self, branch: str, *, expected_head_sha: str) -> None:
        assert expected_head_sha == HEAD
        self.actions.append("delete-remote")
        self.remote = None


class FakeGitHub:
    def __init__(self, inventory: PullRequestInventory | None = None) -> None:
        self.inventory = inventory or PullRequestInventory(())
        self.calls = 0

    def list_pull_requests_for_branch(self, branch: str) -> PullRequestInventory:
        self.calls += 1
        return self.inventory


def _build_service(
    *,
    git: FakeGit,
    registry: FakeRegistry | None = None,
    github: FakeGitHub | None = None,
) -> OrphanBranchDiscardService:
    return OrphanBranchDiscardService(
        registry=registry or FakeRegistry(),
        git_query=git,
        git_command=git,
        github=github or FakeGitHub(),
    )


def test_discards_unregistered_local_branch_already_in_main() -> None:
    git = FakeGit()

    result = _build_service(git=git).discard(
        branch=BRANCH,
        expected_head_sha=HEAD,
        operator="supervisor",
        reason="exact ancestor orphan with no owner or PR",
    )

    assert result.disposition == "orphan_local_discarded"
    assert result.main_sha == BASE
    assert result.local_branch_absent and result.remote_branch_absent
    assert result.worktree_absent
    assert len(result.proof_digest) == 64
    assert git.actions == ["delete-local"]


def test_discards_unregistered_remote_branch_already_in_main() -> None:
    git = FakeGit(local=None, remote=HEAD)

    result = _build_service(git=git).discard_remote(
        branch=BRANCH,
        expected_head_sha=HEAD,
        operator="supervisor",
        reason="exact remote ancestor orphan with no owner or PR",
    )

    assert result.disposition == "orphan_remote_discarded"
    assert result.main_sha == BASE
    assert result.local_branch_absent and result.remote_branch_absent
    assert result.worktree_absent
    assert len(result.proof_digest) == 64
    assert git.actions == ["delete-remote"]


def test_discards_exact_paired_local_and_remote_orphan_refs() -> None:
    git = FakeGit(local=HEAD, remote=HEAD)

    result = _build_service(git=git).discard_remote(
        branch=BRANCH,
        expected_head_sha=HEAD,
        operator="supervisor",
        reason="exact paired refs are already represented in main",
    )

    assert result.disposition == "orphan_remote_discarded"
    assert result.local_branch_absent and result.remote_branch_absent
    assert git.actions == ["delete-local", "delete-remote"]


def test_remote_preflight_is_eligible_only_for_exact_remote_ref() -> None:
    git = FakeGit(local=None, remote=HEAD)

    result = _build_service(git=git).preflight_remote(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert result.eligible
    assert result.schema == "kg.delivery.orphan-branch-preflight.v1"
    assert result.side == "remote"
    assert result.blockers == ()
    assert git.actions == []


def test_remote_preflight_accepts_exact_paired_local_ref() -> None:
    git = FakeGit(local=HEAD, remote=HEAD)

    result = _build_service(git=git).preflight_remote(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert result.eligible
    assert any("paired local branch" in check for check in result.passed_checks)
    assert git.actions == []


def test_remote_discard_fails_closed_on_remote_drift() -> None:
    git = FakeGit(local=None, remote="c" * 40)

    with pytest.raises(PolicyViolation, match="remote orphan branch changed"):
        _build_service(git=git).discard_remote(
            branch=BRANCH,
            expected_head_sha=HEAD,
            operator="supervisor",
            reason="must not delete a drifted remote ref",
        )

    assert git.actions == []


_REMOTE_CLAIM = RegistrySnapshot(
    lane_id="LANE",
    branch=BRANCH,
    path=PATH,
    status="abandoned",
    scope=Scope.from_paths(modify=("ops/example.py",)),
    base_sha=BASE,
    claim_generation=0,
)


@pytest.mark.parametrize(
    ("registry", "git", "github", "message"),
    (
        (
            FakeRegistry(RegistryInventory((_REMOTE_CLAIM,))),
            FakeGit(local=None, remote=HEAD),
            FakeGitHub(),
            "registry claim",
        ),
        (
            FakeRegistry(),
            FakeGit(local=None, remote=HEAD),
            FakeGitHub(PullRequestInventory((object(),))),
            "PR history",
        ),
        (
            FakeRegistry(),
            FakeGit(
                local=None,
                remote=HEAD,
                physical=(PhysicalWorktree(PATH, HEAD, BRANCH),),
            ),
            FakeGitHub(),
            "physical worktree",
        ),
        (
            FakeRegistry(),
            FakeGit(local=None, remote=HEAD, canonical_branch="feature"),
            FakeGitHub(),
            "canonical checkout must be on main",
        ),
        (
            FakeRegistry(),
            FakeGit(local=None, remote=HEAD, canonical_clean=False),
            FakeGitHub(),
            "canonical checkout is dirty",
        ),
        (
            FakeRegistry(),
            FakeGit(local=None, remote=HEAD, canonical_head=HEAD),
            FakeGitHub(),
            "not equal to live origin/main",
        ),
        (
            FakeRegistry(),
            FakeGit(local=None, remote=HEAD, ancestor=False),
            FakeGitHub(),
            "not an ancestor",
        ),
        (
            FakeRegistry(),
            FakeGit(local="c" * 40, remote=HEAD),
            FakeGitHub(),
            "paired local branch changed",
        ),
        (
            FakeRegistry(),
            FakeGit(local=None, remote=None),
            FakeGitHub(),
            "remote orphan branch changed",
        ),
    ),
)
def test_remote_discard_refuses_each_unproven_precondition(
    registry: FakeRegistry,
    git: FakeGit,
    github: FakeGitHub,
    message: str,
) -> None:
    with pytest.raises(PolicyViolation, match=message):
        _build_service(git=git, registry=registry, github=github).discard_remote(
            branch=BRANCH,
            expected_head_sha=HEAD,
            operator="supervisor",
            reason="test",
        )
    assert git.actions == []


def test_preflight_is_read_only_and_reports_all_passed_checks() -> None:
    git = FakeGit()

    result = _build_service(git=git).preflight(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert result.schema == "kg.delivery.orphan-branch-preflight.v1"
    assert result.eligible
    assert result.main_sha == BASE
    assert result.blockers == ()
    assert len(result.passed_checks) == 7
    assert git.actions == []


def test_preflight_uses_branch_history_snapshot_without_querying_per_branch() -> None:
    github = FakeGitHub()
    result = _build_service(git=FakeGit(), github=github).preflight(
        branch=BRANCH,
        expected_head_sha=HEAD,
        pr_history=PullRequestInventory(()),
    )

    assert result.eligible
    assert github.calls == 0


def test_preflight_many_reuses_one_stable_git_snapshot() -> None:
    git = FakeGit(
        branch_inventory=BranchInventory(
            local=((BRANCH, HEAD), (OTHER_BRANCH, HEAD)),
        )
    )

    results = _build_service(git=git).preflight_many(
        branches=((BRANCH, HEAD), (OTHER_BRANCH, HEAD)),
        pr_history=PullRequestInventory(()),
    )

    assert tuple(results) == (BRANCH, OTHER_BRANCH)
    assert all(item.eligible for item in results.values())
    assert git.canonical_calls == 1
    assert git.origin_calls == 1
    assert git.worktree_calls == 1
    assert git.branch_inventory_calls == 1
    assert git.local_calls == 0
    assert git.remote_calls == 0


def test_preflight_many_stops_patch_equivalence_after_batch_budget(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ticks = iter((0.0, 31.0, 31.0))
    monkeypatch.setattr(orphan_branch_module, "monotonic", lambda: next(ticks))
    git = FakeGit(
        ancestor=False,
        branch_inventory=BranchInventory(
            local=((BRANCH, HEAD), (OTHER_BRANCH, HEAD)),
        ),
    )

    results = _build_service(git=git).preflight_many(
        branches=((BRANCH, HEAD), (OTHER_BRANCH, HEAD)),
        pr_history=PullRequestInventory(()),
    )

    assert git.patch_equivalent_calls == 0
    assert all(
        "patch-equivalence batch budget exhausted" in item.blockers[0]
        for item in results.values()
    )


def test_preflight_reports_blocker_without_deleting() -> None:
    git = FakeGit(remote=HEAD, ancestor=False)

    result = _build_service(git=git).preflight(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert result.eligible is False
    assert "remote ref" in "; ".join(result.blockers)
    assert "ancestor" in "; ".join(result.blockers)
    assert "patch-equivalence not evaluated because other blockers exist" in "; ".join(
        result.blockers
    )
    assert result.patch_equivalent_to_main is None
    assert git.patch_equivalent_calls == 0
    assert git.actions == []


@pytest.mark.parametrize("status", ("merged", "abandoned"))
def test_terminal_target_registry_problem_is_audit_only_for_preflight_and_discard(
    status: str,
) -> None:
    registry = FakeRegistry(
        RegistryInventory(
            (),
            (
                InventoryProblem(
                    "registry",
                    BRANCH,
                    "registry base must be an exact commit SHA",
                    identity_kind="branch",
                    record_status=status,
                ),
            ),
        )
    )

    preflight_git = FakeGit()
    preflight = _build_service(git=preflight_git, registry=registry).preflight(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert preflight.eligible
    assert preflight.blockers == ()
    assert any("audit evidence" in check for check in preflight.passed_checks)
    assert preflight_git.patch_equivalent_calls == 0

    discard_git = FakeGit()
    result = _build_service(git=discard_git, registry=registry).discard(
        branch=BRANCH,
        expected_head_sha=HEAD,
        operator="supervisor",
        reason="terminal malformed registry record is audit-only",
    )

    assert result.disposition == "orphan_local_discarded"
    assert discard_git.actions == ["delete-local"]


@pytest.mark.parametrize("status", ("active", "cleanup_pending", "published"))
def test_nonterminal_or_published_target_registry_problem_stays_fail_closed(
    status: str,
) -> None:
    registry = FakeRegistry(
        RegistryInventory(
            (),
            (
                InventoryProblem(
                    "registry",
                    BRANCH,
                    "registry record is malformed",
                    identity_kind="branch",
                    record_status=status,
                ),
            ),
        )
    )
    git = FakeGit()

    result = _build_service(git=git, registry=registry).preflight(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert result.eligible is False
    assert "registry has a source problem" in "; ".join(result.blockers)
    assert result.patch_equivalent_to_main is None
    assert git.patch_equivalent_calls == 0


@pytest.mark.parametrize(
    "problem",
    (
        InventoryProblem(
            "registry",
            "registry-global",
            "registry source is incomplete",
        ),
        InventoryProblem(
            "registry",
            BRANCH,
            "terminal record has no explicit identity kind",
            record_status="abandoned",
        ),
        InventoryProblem(
            "registry",
            "other-branch",
            "terminal record is not scoped to the target",
            identity_kind="branch",
            record_status="abandoned",
        ),
    ),
)
def test_unscoped_or_mixed_registry_source_problems_stay_fail_closed(
    problem: InventoryProblem,
) -> None:
    registry = FakeRegistry(
        RegistryInventory(
            (),
            (
                InventoryProblem(
                    "registry",
                    BRANCH,
                    "registry base must be an exact commit SHA",
                    identity_kind="branch",
                    record_status="abandoned",
                ),
                problem,
            ),
        )
    )
    git = FakeGit()

    result = _build_service(git=git, registry=registry).preflight(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert result.eligible is False
    assert "registry has a source problem" in "; ".join(result.blockers)
    assert result.patch_equivalent_to_main is None
    assert git.patch_equivalent_calls == 0


def test_preflight_skips_patch_equivalence_for_pr_history_blocker() -> None:
    git = FakeGit(ancestor=False)
    github = FakeGitHub(
        PullRequestInventory((SimpleNamespace(branch=BRANCH),))  # type: ignore[arg-type]
    )

    result = _build_service(git=git, github=github).preflight(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert result.eligible is False
    assert "PR history" in "; ".join(result.blockers)
    assert "patch-equivalence not evaluated because other blockers exist" in "; ".join(
        result.blockers
    )
    assert result.patch_equivalent_to_main is None
    assert git.patch_equivalent_calls == 0


def test_preflight_accepts_nonancestor_tip_when_patches_are_equivalent() -> None:
    git = FakeGit(ancestor=False, patch_equivalent=True)

    result = _build_service(git=git).preflight(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert result.eligible
    assert result.patch_equivalent_to_main is True
    assert any("patch-equivalent" in check for check in result.passed_checks)
    assert result.blockers == ()
    assert git.patch_equivalent_calls == 1
    assert git.actions == []


def test_discards_nonancestor_tip_when_patches_are_equivalent() -> None:
    git = FakeGit(ancestor=False, patch_equivalent=True)

    result = _build_service(git=git).discard(
        branch=BRANCH,
        expected_head_sha=HEAD,
        operator="supervisor",
        reason="exact patch-equivalent orphan with no owner or PR",
    )

    assert result.disposition == "orphan_local_discarded"
    assert git.actions == ["delete-local"]


def test_preflight_fails_closed_when_patch_equivalence_evidence_is_unavailable() -> (
    None
):
    result = _build_service(
        git=FakeGit(ancestor=False, failure="patch_equivalent")
    ).preflight(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert result.eligible is False
    assert "patch-equivalence query failed" in "; ".join(result.blockers)


@pytest.mark.parametrize(
    ("failure", "message"),
    (
        ("local", "local branch HEAD query failed"),
        ("remote", "remote branch query failed"),
        ("ancestor", "ancestor query failed"),
    ),
)
def test_preflight_fails_closed_when_git_evidence_is_unavailable(
    failure: str, message: str
) -> None:
    result = _build_service(git=FakeGit(failure=failure)).preflight(
        branch=BRANCH,
        expected_head_sha=HEAD,
    )

    assert result.eligible is False
    assert message in "; ".join(result.blockers)


@pytest.mark.parametrize(
    ("field", "value", "message"),
    (
        ("canonical_branch", "feat/other", "canonical checkout must be on main"),
        ("canonical_clean", False, "canonical checkout is dirty"),
        ("canonical_head", HEAD, "canonical main is not equal"),
        ("origin", HEAD, "canonical main is not equal"),
        ("ancestor", False, "not an ancestor"),
    ),
)
def test_refuses_when_main_or_ancestry_proof_is_not_exact(
    field: str, value: object, message: str
) -> None:
    git = FakeGit(**{field: value})  # type: ignore[arg-type]

    with pytest.raises(PolicyViolation, match=message):
        _build_service(git=git).discard(
            branch=BRANCH,
            expected_head_sha=HEAD,
            operator="supervisor",
            reason="test",
        )
    assert git.actions == []


def test_refuses_registry_claim_pr_history_worktree_remote_and_missing_ref() -> None:
    claim = RegistrySnapshot(
        lane_id="LANE",
        branch=BRANCH,
        path=PATH,
        status="abandoned",
        scope=Scope.from_paths(modify=("ops/example.py",)),
        base_sha=BASE,
        claim_generation=0,
    )
    cases = (
        (
            FakeRegistry(RegistryInventory((claim,))),
            FakeGit(),
            FakeGitHub(),
            "registry claim",
        ),
        (
            FakeRegistry(),
            FakeGit(),
            FakeGitHub(PullRequestInventory((object(),))),
            "PR history",
        ),
        (
            FakeRegistry(),
            FakeGit(physical=(PhysicalWorktree(PATH, HEAD, BRANCH),)),
            FakeGitHub(),
            "physical worktree",
        ),
        (FakeRegistry(), FakeGit(remote=HEAD), FakeGitHub(), "remote ref"),
        (FakeRegistry(), FakeGit(local=None), FakeGitHub(), "absent"),
    )

    for registry, git, github, message in cases:
        with pytest.raises(PolicyViolation, match=message):
            _build_service(git=git, registry=registry, github=github).discard(
                branch=BRANCH,
                expected_head_sha=HEAD,
                operator="supervisor",
                reason="test",
            )
        assert git.actions == []
