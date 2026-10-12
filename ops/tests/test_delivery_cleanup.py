from __future__ import annotations

import sys
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path
from unittest.mock import Mock

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.application_services import DeliveryApplication
from delivery_control.domain.errors import (
    CompareAndSwapConflict,
    DeliverySourceError,
    InvalidReceipt,
    PolicyViolation,
)
from delivery_control.domain.models import HandbackReceipt, Scope
from delivery_control.domain.observations import (
    CanonicalCheckoutSnapshot,
    FileChange,
    FileOperation,
    PhysicalWorktree,
    PullRequestSnapshot,
    RegistryInventory,
    RegistrySnapshot,
    WorktreeSnapshot,
)
from delivery_control.domain.states import HoldKind
from delivery_control.domain.terminal_proof_models import MergedPullRequestProof
from delivery_control.services.cleanup import CleanupService
from delivery_control.services.pr_contract import render_pull_request_body
from delivery_control.services.sync_main import MainSyncService

BASE = "a" * 40
HEAD = "b" * 40
MERGED_HEAD = "d" * 40
BRANCH = "feat/cleanup"
PATH = Path("/tmp/cleanup")


def _receipt() -> HandbackReceipt:
    return HandbackReceipt(
        lane_id="DIRECT-1",
        owner_thread_id="thread-1",
        claim_generation=2,
        branch=BRANCH,
        worktree_path=str(PATH),
        base_sha=BASE,
        parent_sha=BASE,
        head_sha=HEAD,
        origin_main_sha=BASE,
        content_digest="c" * 64,
        scope=Scope.from_paths(modify=("ops/a.py",)),
    )


def _record(receipt: HandbackReceipt, *, status: str = "active") -> RegistrySnapshot:
    return RegistrySnapshot(
        lane_id=receipt.lane_id,
        branch=receipt.branch,
        path=Path(receipt.worktree_path),
        status=status,
        scope=receipt.scope,
        base_sha=receipt.base_sha,
        claim_generation=receipt.claim_generation,
        owner_thread_id=receipt.owner_thread_id,
        handed_back_sha=receipt.head_sha,
        handback_claim_generation=receipt.claim_generation,
        handback_valid=True,
        handback_digest=receipt.content_digest,
        handback_origin_main_sha=receipt.origin_main_sha,
    )


def _snapshot(receipt: HandbackReceipt, *, clean: bool = True) -> WorktreeSnapshot:
    return WorktreeSnapshot(
        path=Path(receipt.worktree_path),
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        parent_sha=receipt.parent_sha,
        clean=clean,
        changes=(FileChange(FileOperation.MODIFY, "ops/a.py"),),
    )


def _pull_request(
    receipt: HandbackReceipt,
    *,
    state: str,
    body: str | None = None,
    labels: tuple[str, ...] = (),
) -> PullRequestSnapshot:
    return PullRequestSnapshot(
        number=9,
        url="https://example.test/pull/9",
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        state=state,
        draft=False,
        mergeable=True,
        title="fix: cleanup",
        body=body if body is not None else render_pull_request_body(receipt),
        labels=labels,
    )


def _merged_pull_request(
    receipt: HandbackReceipt, head_sha: str
) -> PullRequestSnapshot:
    # GitHub "Update branch" moves the head but never rewrites the PR body receipt.
    return replace(_pull_request(receipt, state="MERGED"), head_sha=head_sha)


class FakeRegistry:
    def __init__(self, record: RegistrySnapshot) -> None:
        self.record = record
        self.transitions: list[str] = []
        self.terminal_proofs: list[MergedPullRequestProof | None] = []

    def list_records(self) -> RegistryInventory:
        return RegistryInventory((self.record,))

    def get(self, lane_id: str) -> RegistrySnapshot | None:
        return self.record if self.record.lane_id == lane_id else None

    def find_exact_claim(
        self,
        *,
        lane_id: str,
        branch: str,
        path: Path,
        claim_generation: int,
    ) -> RegistrySnapshot | None:
        if (
            self.record.lane_id == lane_id
            and self.record.branch == branch
            and self.record.path == path
            and self.record.claim_generation == claim_generation
        ):
            return self.record
        return None

    def find_published_claim(
        self,
        *,
        lane_id: str,
        branch: str,
        path: Path,
        owner_thread_id: str,
        head_sha: str,
        scope: Scope,
    ) -> RegistrySnapshot | None:
        if (
            self.record.lane_id == lane_id
            and self.record.branch == branch
            and self.record.path == path
            and self.record.owner_thread_id == owner_thread_id
            and self.record.handed_back_sha == head_sha
            and self.record.status in {"active", "published", "cleanup_pending"}
        ):
            return self.record
        return None

    def resolve(
        self,
        lane_id: str,
        disposition: str,
        *,
        expected_claim_generation: int,
        expected_branch: str,
        expected_path: str,
        expected_head_sha: str,
        terminal_proof=None,
    ) -> None:
        assert lane_id == self.record.lane_id
        assert expected_claim_generation == self.record.claim_generation
        assert expected_branch == self.record.branch
        assert Path(expected_path) == self.record.path
        assert expected_head_sha == self.record.handed_back_sha
        if disposition == "merged":
            assert terminal_proof is not None
            assert terminal_proof.pr_number == 9
        else:
            assert terminal_proof is None
        self.terminal_proofs.append(terminal_proof)
        self.transitions.append(disposition)
        self.record = replace(self.record, status=disposition)


class TerminalThenCurrentRegistry(FakeRegistry):
    def __init__(
        self, terminal_record: RegistrySnapshot, current_record: RegistrySnapshot
    ) -> None:
        super().__init__(current_record)
        self.terminal_record = terminal_record

    def list_records(self) -> RegistryInventory:
        return RegistryInventory((self.terminal_record, self.record))

    def find_exact_claim(
        self,
        *,
        lane_id: str,
        branch: str,
        path: Path,
        claim_generation: int,
    ) -> RegistrySnapshot | None:
        for record in (self.terminal_record, self.record):
            if (
                record.lane_id == lane_id
                and record.branch == branch
                and record.path == path
                and record.claim_generation == claim_generation
            ):
                return record
        return None


class FakeGit:
    def __init__(
        self,
        receipt: HandbackReceipt,
        *,
        snapshot: WorktreeSnapshot | None = None,
        has_worktree: bool = True,
        local_sha: str | None = HEAD,
        remote_sha: str | None = HEAD,
        local_main: str = BASE,
        origin_main: str = BASE,
        origin_main_readbacks: tuple[str, ...] = (),
        remote_branch_readbacks: tuple[str | None, ...] = (),
        canonical_branch: str = "main",
        canonical_clean: bool = True,
        replacement_worktree_after_remove: PhysicalWorktree | None = None,
        ancestors: frozenset[tuple[str, str]] = frozenset(),
    ) -> None:
        self.ancestors = ancestors
        self.snapshot = snapshot or _snapshot(receipt)
        self.worktrees = (
            (
                PhysicalWorktree(
                    Path(receipt.worktree_path), receipt.head_sha, receipt.branch
                ),
            )
            if has_worktree
            else ()
        )
        self.local_sha = local_sha
        self.remote_sha = remote_sha
        self.local_main = local_main
        self.origin_main = origin_main
        self.origin_main_readbacks = list(origin_main_readbacks)
        self.remote_branch_readbacks = list(remote_branch_readbacks)
        self.canonical_branch = canonical_branch
        self.canonical_clean = canonical_clean
        self.replacement_worktree_after_remove = replacement_worktree_after_remove
        self.actions: list[str] = []

    def list_worktrees(self) -> tuple[PhysicalWorktree, ...]:
        return self.worktrees

    def canonical_checkout(self) -> CanonicalCheckoutSnapshot:
        return CanonicalCheckoutSnapshot(
            path=Path("/repo"),
            branch=self.canonical_branch,
            head_sha=self.local_main,
            clean=self.canonical_clean,
        )

    def inspect_worktree(self, path: Path, base_sha: str) -> WorktreeSnapshot:
        if path == Path("/repo"):
            return WorktreeSnapshot(
                path=path,
                branch=self.canonical_branch,
                base_sha=base_sha,
                head_sha=self.local_main,
                parent_sha=self.local_main,
                clean=self.canonical_clean,
                changes=(),
            )
        return self.snapshot

    def local_branch_sha(self, branch: str) -> str | None:
        return self.local_sha

    def remote_branch_sha(self, branch: str) -> str | None:
        if self.remote_branch_readbacks:
            self.remote_sha = self.remote_branch_readbacks.pop(0)
        return self.remote_sha

    def remove_worktree(self, path: Path, *, expected_head_sha: str) -> None:
        assert expected_head_sha == HEAD
        self.actions.append("remove-worktree")
        self.worktrees = (
            (self.replacement_worktree_after_remove,)
            if self.replacement_worktree_after_remove is not None
            else ()
        )

    def delete_local_branch(self, branch: str, *, expected_head_sha: str) -> None:
        assert expected_head_sha == self.local_sha
        self.actions.append("delete-local")
        self.local_sha = None

    def delete_remote_branch(self, branch: str, *, expected_head_sha: str) -> None:
        assert expected_head_sha == self.remote_sha
        self.actions.append("delete-remote")
        self.remote_sha = None

    def is_ancestor(self, ancestor_sha: str, descendant_sha: str) -> bool:
        return (ancestor_sha, descendant_sha) in self.ancestors

    def local_main_sha(self) -> str:
        return self.local_main

    def origin_main_sha(self) -> str:
        if self.origin_main_readbacks:
            self.origin_main = self.origin_main_readbacks.pop(0)
        return self.origin_main

    def fast_forward_main(
        self, *, expected_local_sha: str, expected_origin_sha: str
    ) -> str:
        assert expected_local_sha == self.local_main
        assert expected_origin_sha == self.origin_main
        self.actions.append("sync-main")
        self.local_main = self.origin_main
        return self.local_main


class FakeGitHub:
    def __init__(
        self,
        pull_request: PullRequestSnapshot,
        receipt: HandbackReceipt,
        *,
        pull_request_readbacks: tuple[PullRequestSnapshot, ...] = (),
        changed_paths: tuple[str, ...] | None = None,
    ) -> None:
        self.pull_request = pull_request
        self.receipt = receipt
        self.pull_request_readbacks = list(pull_request_readbacks)
        self.paths = receipt.scope.paths if changed_paths is None else changed_paths

    def get_pull_request(self, number: int) -> PullRequestSnapshot:
        assert number == self.pull_request.number
        if self.pull_request_readbacks:
            self.pull_request = self.pull_request_readbacks.pop(0)
        return self.pull_request

    def changed_paths(self, number: int) -> tuple[str, ...]:
        return self.paths


def _service(
    receipt: HandbackReceipt,
    *,
    registry: FakeRegistry,
    git: FakeGit,
    state: str,
) -> CleanupService:
    return CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(_pull_request(receipt, state=state), receipt),
    )


def test_publish_release_moves_durable_queue_to_github_and_removes_local_assets() -> (
    None
):
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt)

    result = _service(
        receipt, registry=registry, git=git, state="OPEN"
    ).release_after_publish(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending", "published"]
    assert git.actions == ["remove-worktree", "delete-local"]
    assert result.worktree_absent and result.local_branch_absent
    assert not result.remote_branch_absent


@pytest.mark.parametrize(
    ("canonical_branch", "canonical_clean", "message"),
    (
        ("debug/feature", True, "canonical checkout must be on main"),
        ("main", False, "canonical checkout is dirty"),
    ),
)
def test_publish_release_refuses_before_claim_lease_without_canonical_main(
    canonical_branch: str, canonical_clean: bool, message: str
) -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(
        receipt,
        canonical_branch=canonical_branch,
        canonical_clean=canonical_clean,
    )

    with pytest.raises(PolicyViolation, match=message):
        _service(
            receipt, registry=registry, git=git, state="OPEN"
        ).release_after_publish(receipt=receipt, pull_request_number=9)

    assert registry.transitions == []
    assert git.actions == []


@pytest.mark.parametrize(
    ("body", "labels"),
    (
        (
            render_pull_request_body(_receipt(), holds=frozenset({HoldKind.SECURITY})),
            (),
        ),
        (render_pull_request_body(_receipt()), ("delivery-hold:security",)),
        (render_pull_request_body(_receipt()) + "\nPUBLISH ONLY\n", ()),
    ),
    ids=("typed-hold", "label-hold", "legacy-hold"),
)
def test_publish_release_preserves_holds_while_releasing_local_assets(
    body: str, labels: tuple[str, ...]
) -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt)
    pull_request = _pull_request(
        receipt,
        state="OPEN",
        body=body,
        labels=labels,
    )
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(pull_request, receipt),
    )

    result = service.release_after_publish(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending", "published"]
    assert result.worktree_absent and result.local_branch_absent


def test_publish_release_blocks_dirty_worktree_before_releasing_claim() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt, snapshot=_snapshot(receipt, clean=False))

    with pytest.raises(PolicyViolation, match="worktree changed"):
        _service(
            receipt, registry=registry, git=git, state="OPEN"
        ).release_after_publish(receipt=receipt, pull_request_number=9)

    assert registry.transitions == []
    assert git.actions == []


def test_publish_release_retry_is_idempotent_after_local_assets_are_absent() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, status="published"))
    git = FakeGit(receipt, has_worktree=False, local_sha=None)

    result = _service(
        receipt, registry=registry, git=git, state="OPEN"
    ).release_after_publish(receipt=receipt, pull_request_number=9)

    assert registry.transitions == []
    assert git.actions == []
    assert result.worktree_absent and result.local_branch_absent


def test_publish_release_accepts_actual_changed_paths_as_scope_subset() -> None:
    receipt = replace(
        _receipt(),
        scope=Scope.from_paths(modify=("ops/a.py", "ops/b.py")),
    )
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt)
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(
            _pull_request(receipt, state="OPEN"),
            receipt,
            changed_paths=("ops/a.py",),
        ),
    )

    result = service.release_after_publish(receipt=receipt, pull_request_number=9)

    assert result.worktree_absent and result.local_branch_absent


def test_merged_cleanup_removes_exact_remote_and_terminalizes_registry() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, status="published"))
    git = FakeGit(receipt, has_worktree=False, local_sha=None)

    result = _service(
        receipt, registry=registry, git=git, state="MERGED"
    ).finalize_merged(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending", "merged"]
    assert git.actions == ["delete-remote"]
    assert result.remote_branch_absent


def test_merged_cleanup_reclaims_clean_terminal_pointer_residue(
    tmp_path: Path,
) -> None:
    receipt = replace(_receipt(), worktree_path=str(tmp_path / "stale-terminal"))
    residue = Path(receipt.worktree_path)
    residue.mkdir()
    (residue / ".git").write_text(
        f"gitdir: {tmp_path / 'missing-worktree-admin'}\n", encoding="utf-8"
    )

    class ResidueRemovingFakeGit(FakeGit):
        def remove_worktree(self, path: Path, *, expected_head_sha: str) -> None:
            super().remove_worktree(path, expected_head_sha=expected_head_sha)
            (path / ".git").unlink()
            path.rmdir()

    registry = FakeRegistry(_record(receipt, status="published"))
    git = ResidueRemovingFakeGit(receipt, has_worktree=False, local_sha=None)

    result = _service(
        receipt, registry=registry, git=git, state="MERGED"
    ).finalize_merged(receipt=receipt, pull_request_number=9)

    assert git.actions == ["remove-worktree", "delete-remote"]
    assert not residue.exists()
    assert result.worktree_absent


def test_merged_cleanup_refuses_registered_worktree_on_retry() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, status="merged"))
    git = FakeGit(receipt, has_worktree=True, local_sha=None, remote_sha=None)

    with pytest.raises(PolicyViolation, match="unreconciled assets"):
        _service(receipt, registry=registry, git=git, state="MERGED").finalize_merged(
            receipt=receipt, pull_request_number=9
        )

    assert git.actions == []


def test_publish_release_does_not_reclaim_terminal_pointer_residue_without_proof(
    tmp_path: Path,
) -> None:
    receipt = replace(_receipt(), worktree_path=str(tmp_path / "stale-open"))
    residue = Path(receipt.worktree_path)
    residue.mkdir()
    (residue / ".git").write_text(
        f"gitdir: {tmp_path / 'missing-open-admin'}\n", encoding="utf-8"
    )
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt, has_worktree=False, local_sha=None)

    _service(receipt, registry=registry, git=git, state="OPEN").release_after_publish(
        receipt=receipt, pull_request_number=9
    )

    assert git.actions == []
    assert residue.exists()


def test_application_cleanup_bridges_previous_body_to_current_registry_claim() -> None:
    current = _receipt()
    previous = replace(
        current,
        claim_generation=1,
        content_digest="d" * 64,
        scope=Scope.from_paths(modify=("ops/a.py", "ops/b.py")),
    )
    registry = FakeRegistry(_record(current, status="active"))
    git = FakeGit(current, has_worktree=False, local_sha=None)
    github = FakeGitHub(
        _pull_request(
            current,
            state="MERGED",
            body=render_pull_request_body(previous),
        ),
        current,
    )
    application = DeliveryApplication(
        repo=Path("/repo"),
        git=git,
        github=github,
        registry=registry,
        runtime=Mock(),
        telemetry=Mock(),
    )

    result = application.cleanup_merged(9)

    assert result["cleanup"].disposition == "merged"
    assert registry.transitions == ["cleanup_pending", "merged"]
    assert git.actions == ["delete-remote"]


def test_application_cleanup_skips_terminal_claim_for_current_generation() -> None:
    current = _receipt()
    previous = replace(current, claim_generation=1)
    terminal = _record(previous, status="abandoned")
    registry = TerminalThenCurrentRegistry(terminal, _record(current))
    git = FakeGit(current, has_worktree=False, local_sha=None)
    github = FakeGitHub(
        _pull_request(
            current,
            state="MERGED",
            body=render_pull_request_body(previous),
        ),
        current,
    )
    application = DeliveryApplication(
        repo=Path("/repo"),
        git=git,
        github=github,
        registry=registry,
        runtime=Mock(),
        telemetry=Mock(),
    )

    result = application.cleanup_merged(9)

    assert result["cleanup"].disposition == "merged"
    assert registry.transitions == ["cleanup_pending", "merged"]
    assert git.actions == ["delete-remote"]


@pytest.mark.parametrize(
    "mutate",
    (
        lambda record: replace(
            record,
            scope=Scope.from_paths(modify=("ops/other.py",)),
        ),
        lambda record: replace(
            record,
            handback_valid=False,
        ),
    ),
    ids=("previous-scope-does-not-contain-current", "invalid-current-handback"),
)
def test_application_cleanup_does_not_bridge_unproven_previous_receipt(
    mutate,
) -> None:
    current = _receipt()
    previous = replace(
        current,
        claim_generation=1,
        content_digest="d" * 64,
        scope=Scope.from_paths(modify=("ops/a.py", "ops/b.py")),
    )
    current_record = _record(current, status="published")
    current_record = mutate(current_record)
    registry = FakeRegistry(current_record)
    git = FakeGit(current, has_worktree=False, local_sha=None)
    github = FakeGitHub(
        _pull_request(
            current,
            state="MERGED",
            body=render_pull_request_body(previous),
        ),
        current,
    )
    application = DeliveryApplication(
        repo=Path("/repo"),
        git=git,
        github=github,
        registry=registry,
        runtime=Mock(),
        telemetry=Mock(),
    )

    with pytest.raises(PolicyViolation, match="current registry claim"):
        application.cleanup_merged(9)

    assert registry.transitions == []
    assert git.actions == []


def test_cleanup_refuses_remote_drift() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt, remote_sha="d" * 40)

    with pytest.raises(PolicyViolation, match="remote branch"):
        _service(
            receipt, registry=registry, git=git, state="OPEN"
        ).release_after_publish(receipt=receipt, pull_request_number=9)
    assert not git.actions


@pytest.mark.parametrize("state", ("OPEN", "MERGED"))
def test_cleanup_refuses_pr_retargeted_away_from_main(state: str) -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt)
    pull_request = replace(
        _pull_request(receipt, state=state),
        base_branch="release",
    )
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(pull_request, receipt),
    )

    with pytest.raises(PolicyViolation, match="exact handback"):
        if state == "OPEN":
            service.release_after_publish(receipt=receipt, pull_request_number=9)
        else:
            service.finalize_merged(receipt=receipt, pull_request_number=9)

    assert registry.transitions == []
    assert git.actions == []


@pytest.mark.parametrize("state", ("OPEN", "MERGED"))
def test_cleanup_rechecks_pr_after_lease_before_deleting_local_assets(
    state: str,
) -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt)
    exact = _pull_request(receipt, state=state)
    retargeted = replace(exact, base_branch="release")
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(
            exact,
            receipt,
            pull_request_readbacks=(exact, retargeted),
        ),
    )

    with pytest.raises(PolicyViolation, match="exact handback"):
        if state == "OPEN":
            service.release_after_publish(receipt=receipt, pull_request_number=9)
        else:
            service.finalize_merged(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending"]
    assert registry.record.status == "cleanup_pending"
    assert git.actions == []
    assert git.worktrees and git.local_sha == HEAD and git.remote_sha == HEAD


def test_publish_release_rechecks_pr_before_terminal_disposition() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt)
    exact = _pull_request(receipt, state="OPEN")
    retargeted = replace(exact, base_branch="release")
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(
            exact,
            receipt,
            pull_request_readbacks=(exact, exact, exact, retargeted),
        ),
    )

    with pytest.raises(PolicyViolation, match="exact handback"):
        service.release_after_publish(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending"]
    assert registry.record.status == "cleanup_pending"
    assert git.actions == ["remove-worktree", "delete-local"]
    assert git.remote_sha == HEAD


def test_publish_release_fails_closed_when_remote_branch_disappears_before_terminal_cas() -> (
    None
):
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt, remote_branch_readbacks=(HEAD, None))

    with pytest.raises(PolicyViolation, match="remote branch"):
        _service(
            receipt, registry=registry, git=git, state="OPEN"
        ).release_after_publish(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending"]
    assert registry.record.status == "cleanup_pending"
    assert git.actions == ["remove-worktree", "delete-local"]
    assert git.remote_sha is None


def test_merged_cleanup_rechecks_pr_before_remote_delete() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, status="published"))
    git = FakeGit(receipt, has_worktree=False, local_sha=None)
    exact = _pull_request(receipt, state="MERGED")
    retargeted = replace(exact, base_branch="release")
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(
            exact,
            receipt,
            pull_request_readbacks=(exact, exact, retargeted),
        ),
    )

    with pytest.raises(PolicyViolation, match="exact handback"):
        service.finalize_merged(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending"]
    assert registry.record.status == "cleanup_pending"
    assert git.actions == []
    assert git.remote_sha == HEAD


def test_merged_cleanup_rechecks_pr_before_terminal_disposition() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, status="published"))
    git = FakeGit(receipt, has_worktree=False, local_sha=None)
    exact = _pull_request(receipt, state="MERGED")
    retargeted = replace(exact, base_branch="release")
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(
            exact,
            receipt,
            pull_request_readbacks=(exact, exact, exact, retargeted),
        ),
    )

    with pytest.raises(PolicyViolation, match="exact handback"):
        service.finalize_merged(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending"]
    assert registry.record.status == "cleanup_pending"
    assert git.actions == ["delete-remote"]


def test_merged_cleanup_accepts_a_merged_head_that_contains_the_lane_tip() -> None:
    # #3323: "Update branch" moves the merged head past the lane tip.  Cleanup
    # proceeds on the real service; the proof keeps the lane head and records
    # the merged head beside it.
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, status="published"))
    git = FakeGit(
        receipt,
        has_worktree=False,
        local_sha=None,
        remote_sha=MERGED_HEAD,
        ancestors=frozenset({(HEAD, MERGED_HEAD)}),
    )
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(_merged_pull_request(receipt, MERGED_HEAD), receipt),
    )

    result = service.finalize_merged(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending", "merged"]
    assert git.actions == ["delete-remote"]
    assert result.remote_branch_absent
    proof = registry.terminal_proofs[-1]
    assert proof is not None
    assert proof.head_sha == HEAD
    assert proof.merged_head_sha == MERGED_HEAD


def test_merged_cleanup_refuses_a_merged_head_outside_the_lane_tip_history() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, status="published"))
    git = FakeGit(receipt, has_worktree=False, local_sha=None, remote_sha=MERGED_HEAD)
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(_merged_pull_request(receipt, MERGED_HEAD), receipt),
    )

    with pytest.raises(PolicyViolation, match="exact handback"):
        service.finalize_merged(receipt=receipt, pull_request_number=9)

    # Refused before the cleanup lease: no registry transition, no local asset touched.
    assert registry.transitions == []
    assert git.actions == []


def test_merged_cleanup_refuses_remote_moved_past_the_merged_head() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, status="published"))
    git = FakeGit(
        receipt,
        has_worktree=False,
        local_sha=None,
        remote_sha="e" * 40,
        ancestors=frozenset({(HEAD, MERGED_HEAD)}),
    )
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(_merged_pull_request(receipt, MERGED_HEAD), receipt),
    )

    with pytest.raises(PolicyViolation, match="remote branch changed"):
        service.finalize_merged(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending"]
    assert git.actions == []


def test_open_pr_release_keeps_the_exact_handback_head() -> None:
    # Containment licenses merged cleanup only; an OPEN PR must still be the
    # exact handback, even when its head contains the lane tip.
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt, status="published"))
    git = FakeGit(receipt, ancestors=frozenset({(HEAD, MERGED_HEAD)}))
    open_pull_request = replace(
        _pull_request(receipt, state="OPEN"), head_sha=MERGED_HEAD
    )
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(open_pull_request, receipt),
    )

    with pytest.raises(PolicyViolation, match="exact handback"):
        service.release_after_publish(receipt=receipt, pull_request_number=9)

    assert registry.transitions == []
    assert git.actions == []


def test_merged_proof_rejects_a_merged_head_equal_to_the_lane_tip() -> None:
    with pytest.raises(InvalidReceipt, match="merged_head_sha"):
        MergedPullRequestProof(
            lane_id="DIRECT-1",
            pr_number=9,
            branch=BRANCH,
            head_sha=HEAD,
            merged_head_sha=HEAD,
        )


def _bridged_application(
    current: HandbackReceipt, git: FakeGit, registry: FakeRegistry
) -> DeliveryApplication:
    previous = replace(
        current,
        claim_generation=1,
        content_digest="d" * 64,
        scope=Scope.from_paths(modify=("ops/a.py", "ops/b.py")),
    )
    github = FakeGitHub(
        replace(
            _pull_request(
                current,
                state="MERGED",
                body=render_pull_request_body(previous),
            ),
            head_sha=MERGED_HEAD,
        ),
        current,
    )
    return DeliveryApplication(
        repo=Path("/repo"),
        git=git,
        github=github,
        registry=registry,
        runtime=Mock(),
        telemetry=Mock(),
    )


def test_application_cleanup_bridges_a_merged_head_that_contains_the_lane_tip() -> None:
    current = _receipt()
    registry = FakeRegistry(_record(current, status="active"))
    git = FakeGit(
        current,
        has_worktree=False,
        local_sha=None,
        remote_sha=MERGED_HEAD,
        ancestors=frozenset({(HEAD, MERGED_HEAD)}),
    )

    result = _bridged_application(current, git, registry).cleanup_merged(9)

    assert result["cleanup"].disposition == "merged"
    assert registry.transitions == ["cleanup_pending", "merged"]
    assert git.actions == ["delete-remote"]


def test_application_cleanup_refuses_a_bridged_merged_head_outside_lane_history() -> (
    None
):
    current = _receipt()
    registry = FakeRegistry(_record(current, status="active"))
    git = FakeGit(
        current,
        has_worktree=False,
        local_sha=None,
        remote_sha=MERGED_HEAD,
    )

    with pytest.raises(PolicyViolation, match="cannot bridge"):
        _bridged_application(current, git, registry).cleanup_merged(9)

    assert registry.transitions == []
    assert git.actions == []


class LeaseRecorder:
    """Record which observed port calls run inside an operation-lease section."""

    def __init__(self) -> None:
        self.depth = 0
        self.calls: list[tuple[str, bool]] = []
        self.sections: list[list[str]] = []

    @contextmanager
    def lease(self, label: str) -> Iterator[None]:
        del label
        if self.depth == 0:
            self.sections.append([])
        self.depth += 1
        try:
            yield
        finally:
            self.depth -= 1

    def observe(self, target: object, prefix: str, *names: str) -> None:
        for name in names:
            original = getattr(target, name)

            def observed(
                *args: object,
                _name: str = f"{prefix}.{name}",
                _original: Callable[..., object] = original,
                **kwargs: object,
            ) -> object:
                call = f"{_name}:{args[1]}" if _name == "registry.resolve" else _name
                self.calls.append((call, self.depth > 0))
                if self.depth > 0:
                    self.sections[-1].append(call)
                return _original(*args, **kwargs)

            setattr(target, name, observed)


@pytest.mark.parametrize(
    ("state", "terminal", "pull_request_reads"),
    (("OPEN", "published", 4), ("MERGED", "merged", 5)),
)
def test_cleanup_holds_the_lease_only_around_registry_and_local_ref_sections(
    state: str, terminal: str, pull_request_reads: int
) -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt)
    github = FakeGitHub(_pull_request(receipt, state=state), receipt)
    recorder = LeaseRecorder()
    recorder.observe(
        git,
        "git",
        "canonical_checkout",
        "remove_worktree",
        "delete_local_branch",
        "remote_branch_sha",
        "delete_remote_branch",
    )
    recorder.observe(registry, "registry", "find_exact_claim", "resolve")
    recorder.observe(github, "github", "get_pull_request", "changed_paths")
    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=github,
        lease=recorder.lease,
    )

    if state == "OPEN":
        result = service.release_after_publish(receipt=receipt, pull_request_number=9)
    else:
        result = service.finalize_merged(receipt=receipt, pull_request_number=9)

    assert result.disposition == terminal
    assert recorder.depth == 0
    assert recorder.sections == [
        ["git.canonical_checkout"],
        [
            "registry.find_exact_claim",
            "registry.resolve:cleanup_pending",
            "registry.find_exact_claim",
        ],
        ["git.remove_worktree"],
        ["git.delete_local_branch"],
        [f"registry.resolve:{terminal}"],
    ]
    network = {
        "github.get_pull_request",
        "github.changed_paths",
        "git.remote_branch_sha",
        "git.delete_remote_branch",
    }
    assert [call for call, held in recorder.calls if call in network and held] == []
    assert (("git.delete_remote_branch", False) in recorder.calls) == (
        state == "MERGED"
    )
    assert [call for call, _ in recorder.calls].count(
        "github.get_pull_request"
    ) == pull_request_reads


def test_lease_refusal_mid_cleanup_resumes_from_cleanup_pending_on_rerun() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt)
    entries = 0

    @contextmanager
    def busy_at_local_branch_section(label: str) -> Iterator[None]:
        nonlocal entries
        entries += 1
        if entries == 4:
            raise DeliverySourceError(
                f"delivery mutation already in progress; command={label}; "
                "retry after the active operation exits"
            )
        yield

    service = CleanupService(
        registry_query=registry,
        registry_command=registry,
        git_query=git,
        git_command=git,
        github=FakeGitHub(_pull_request(receipt, state="MERGED"), receipt),
        lease=busy_at_local_branch_section,
    )

    with pytest.raises(DeliverySourceError, match="already in progress"):
        service.finalize_merged(receipt=receipt, pull_request_number=9)

    assert registry.record.status == "cleanup_pending"
    assert git.actions == ["remove-worktree"]
    assert git.local_sha == HEAD and git.remote_sha == HEAD

    result = service.finalize_merged(receipt=receipt, pull_request_number=9)

    assert result.disposition == "merged"
    assert registry.transitions == ["cleanup_pending", "merged"]
    assert git.actions == ["remove-worktree", "delete-local", "delete-remote"]


@pytest.mark.parametrize(
    "worktrees",
    (
        (PhysicalWorktree(PATH, HEAD, "feat/rebound"),),
        (PhysicalWorktree(Path("/tmp/other"), HEAD, BRANCH),),
        (
            PhysicalWorktree(PATH, HEAD, BRANCH),
            PhysicalWorktree(PATH, HEAD, BRANCH),
        ),
    ),
    ids=("sealed-path-branch-drift", "sealed-branch-path-drift", "duplicate-match"),
)
def test_cleanup_refuses_non_unique_sealed_path_branch_binding(
    worktrees: tuple[PhysicalWorktree, ...],
) -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    git = FakeGit(receipt)
    git.worktrees = worktrees

    with pytest.raises(PolicyViolation, match="sealed worktree path and branch"):
        _service(
            receipt, registry=registry, git=git, state="OPEN"
        ).release_after_publish(receipt=receipt, pull_request_number=9)

    assert registry.transitions == []
    assert git.actions == []


def test_cleanup_result_readback_refuses_rebound_sealed_path() -> None:
    receipt = _receipt()
    registry = FakeRegistry(_record(receipt))
    rebound = PhysicalWorktree(PATH, HEAD, "feat/rebound")
    git = FakeGit(receipt, replacement_worktree_after_remove=rebound)

    with pytest.raises(PolicyViolation, match="sealed worktree path and branch"):
        _service(
            receipt, registry=registry, git=git, state="OPEN"
        ).release_after_publish(receipt=receipt, pull_request_number=9)

    assert registry.transitions == ["cleanup_pending", "published"]
    assert git.actions == ["remove-worktree", "delete-local"]


def test_main_sync_is_noop_when_exact_and_ff_only_when_behind() -> None:
    receipt = _receipt()
    exact = FakeGit(receipt)
    behind = FakeGit(receipt, local_main="c" * 40, origin_main="d" * 40)

    exact_result = MainSyncService(
        canonical_path=Path("/repo"), query=exact, command=exact
    ).sync()
    behind_result = MainSyncService(
        canonical_path=Path("/repo"), query=behind, command=behind
    ).sync()

    assert not exact_result.changed
    assert exact.actions == []
    assert behind_result.changed
    assert behind_result.after_sha == "d" * 40
    assert behind.actions == ["sync-main"]


def test_main_sync_noop_refuses_fresh_origin_main_drift() -> None:
    drifted_origin = "d" * 40
    git = FakeGit(
        _receipt(),
        origin_main_readbacks=(BASE, drifted_origin),
    )

    with pytest.raises(CompareAndSwapConflict, match="origin/main changed"):
        MainSyncService(canonical_path=Path("/repo"), query=git, command=git).sync()

    assert git.actions == []


def test_main_sync_fast_forward_refuses_fresh_origin_main_drift() -> None:
    expected_origin = "d" * 40
    drifted_origin = "e" * 40
    git = FakeGit(
        _receipt(),
        local_main="c" * 40,
        origin_main=expected_origin,
        origin_main_readbacks=(expected_origin, drifted_origin),
    )

    with pytest.raises(CompareAndSwapConflict, match="origin/main changed"):
        MainSyncService(canonical_path=Path("/repo"), query=git, command=git).sync()

    assert git.actions == ["sync-main"]
    assert git.local_main == expected_origin


@pytest.mark.parametrize(
    ("canonical_branch", "canonical_clean"),
    (("feat/not-main", True), ("main", False)),
)
def test_main_sync_refuses_wrong_or_dirty_canonical_checkout(
    canonical_branch: str, canonical_clean: bool
) -> None:
    git = FakeGit(
        _receipt(),
        canonical_branch=canonical_branch,
        canonical_clean=canonical_clean,
    )

    with pytest.raises(PolicyViolation, match="canonical checkout"):
        MainSyncService(canonical_path=Path("/repo"), query=git, command=git).sync()
