from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path

import pytest
from delivery_control.adapters.errors import AdapterPayloadError
from delivery_control.adapters.registry_query import terminal_claim
from delivery_control.domain.errors import PolicyViolation
from delivery_control.domain.models import Scope
from delivery_control.domain.observations import (
    CanonicalCheckoutSnapshot,
    FileChange,
    PhysicalWorktree,
    PullRequestInventory,
    PullRequestSnapshot,
    RegistrySnapshot,
    WorktreeSnapshot,
)
from delivery_control.ports.registry import LegacyTerminalClaim
from delivery_control.services.legacy_cleanup import LegacyTerminalCleanupService

BASE = "a" * 40
HEAD = "b" * 40
BRANCH = "debug/legacy"
PATH = Path("/tmp/legacy-terminal")
SCOPE = Scope.from_paths(modify=("ops/example.py",))


def _record(*, status: str, handed_back_sha: str | None = HEAD) -> RegistrySnapshot:
    return RegistrySnapshot(
        lane_id="LEGACY-1",
        branch=BRANCH,
        path=PATH,
        status=status,
        scope=SCOPE,
        base_sha=BASE,
        claim_generation=1,
        external_ids=("#1",),
        handed_back_sha=handed_back_sha,
    )


def _legacy_record(*, handed_back_sha: str | None = None) -> LegacyTerminalClaim:
    return LegacyTerminalClaim(
        lane_id=BRANCH,
        branch=BRANCH,
        path=PATH,
        status="merged",
        scope=SCOPE,
        base_sha="main",
        handed_back_sha=handed_back_sha,
    )


def _pr(*, state: str, merged: bool = False) -> PullRequestSnapshot:
    return PullRequestSnapshot(
        number=1,
        url="https://example.test/pull/1",
        branch=BRANCH,
        base_sha=BASE,
        head_sha=HEAD,
        state=state,
        draft=False,
        mergeable=True,
        body="legacy PR body",
        node_id="PR_1",
        merged_at=datetime.now(timezone.utc) if merged else None,
    )


class FakeRegistry:
    def __init__(self, record: RegistrySnapshot) -> None:
        self.record = record

    def find_terminal_claim(self, *, branch: str) -> RegistrySnapshot | None:
        return self.record if self.record.branch == branch else None


class FakeGit:
    def __init__(
        self,
        *,
        local: str | None = HEAD,
        remote: str | None = HEAD,
        physical: tuple[PhysicalWorktree, ...] = (),
        canonical_branch: str = "main",
        canonical_clean: bool = True,
        snapshot_clean: bool = True,
        snapshot_head: str = HEAD,
        snapshot_branch: str = BRANCH,
        snapshot_changes: tuple[FileChange, ...] = (
            FileChange("modify", "ops/example.py"),
        ),
    ) -> None:
        self.local = local
        self.remote = remote
        self.physical = physical
        self.canonical_branch = canonical_branch
        self.canonical_clean = canonical_clean
        self.snapshot_clean = snapshot_clean
        self.snapshot_head = snapshot_head
        self.snapshot_branch = snapshot_branch
        self.snapshot_changes = snapshot_changes
        self.actions: list[str] = []

    def list_worktrees(self) -> tuple[PhysicalWorktree, ...]:
        return self.physical

    def canonical_checkout(self) -> CanonicalCheckoutSnapshot:
        return CanonicalCheckoutSnapshot(
            path=Path("/repo"),
            branch=self.canonical_branch,
            head_sha=BASE,
            clean=self.canonical_clean,
        )

    def inspect_worktree(self, path: Path, base_sha: str) -> WorktreeSnapshot:
        return WorktreeSnapshot(
            path=path,
            branch=self.snapshot_branch,
            base_sha=base_sha,
            head_sha=self.snapshot_head,
            parent_sha=BASE,
            clean=self.snapshot_clean,
            changes=self.snapshot_changes,
        )

    def local_branch_sha(self, branch: str) -> str | None:
        return self.local

    def remote_branch_sha(self, branch: str) -> str | None:
        return self.remote

    def delete_local_branch(self, branch: str, *, expected_head_sha: str) -> None:
        assert expected_head_sha in {BASE, HEAD}
        self.actions.append("delete-local")
        self.local = None

    def delete_remote_branch(self, branch: str, *, expected_head_sha: str) -> None:
        assert expected_head_sha in {BASE, HEAD}
        self.actions.append("delete-remote")
        self.remote = None

    def remove_worktree(self, path: Path, *, expected_head_sha: str) -> None:
        assert expected_head_sha in {BASE, HEAD}
        self.actions.append("remove-worktree")
        self.physical = ()


class FakeGitHub:
    def __init__(
        self,
        pull_request: PullRequestSnapshot,
        *,
        history: tuple[PullRequestSnapshot, ...] | None = None,
        changed_paths: tuple[str, ...] = SCOPE.paths,
    ) -> None:
        self.pull_request = pull_request
        self.history = history
        self.changed_paths_value = changed_paths
        self.closed = False

    def get_pull_request(self, number: int) -> PullRequestSnapshot:
        assert number == self.pull_request.number
        return self.pull_request

    def list_pull_requests_for_branch(self, branch: str) -> PullRequestInventory:
        if branch != self.pull_request.branch or self.pull_request.number < 0:
            return PullRequestInventory(())
        return PullRequestInventory(self.history or (self.pull_request,))

    def changed_paths(self, number: int) -> tuple[str, ...]:
        return self.changed_paths_value

    def merge_queue_entry_snapshot(self, pull_request_id: str):
        return None

    def close_pull_request(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> PullRequestSnapshot:
        assert number == self.pull_request.number
        assert expected_base_sha == BASE
        assert expected_head_sha == HEAD
        assert expected_body == self.pull_request.body
        self.pull_request = replace(self.pull_request, state="CLOSED")
        self.closed = True
        return self.pull_request


def _service(record: RegistrySnapshot, git: FakeGit, github: FakeGitHub):
    return LegacyTerminalCleanupService(
        registry=FakeRegistry(record),
        git_query=git,
        git_command=git,
        github_query=github,
        github_command=github,
    )


def test_legacy_merged_cleanup_removes_exact_local_and_remote_assets() -> None:
    git = FakeGit()
    result = _service(
        _record(status="merged"), git, FakeGitHub(_pr(state="MERGED", merged=True))
    ).cleanup_merged_pr(1)

    assert result.disposition == "merged"
    assert result.local_branch_absent and result.remote_branch_absent
    assert git.actions == ["delete-local", "delete-remote"]


def test_legacy_merged_cleanup_accepts_symbolic_base_without_typed_handback() -> None:
    git = FakeGit()
    result = _service(
        _legacy_record(),
        git,
        FakeGitHub(_pr(state="MERGED", merged=True)),
    ).cleanup_merged_pr(1)

    assert result.disposition == "merged"
    assert result.local_branch_absent and result.remote_branch_absent
    assert git.actions == ["delete-local", "delete-remote"]


def test_legacy_merged_cleanup_refuses_duplicate_branch_history() -> None:
    pull_request = _pr(state="MERGED", merged=True)
    github = FakeGitHub(
        pull_request, history=(pull_request, replace(pull_request, number=2))
    )

    with pytest.raises(PolicyViolation, match="one unique PR"):
        _service(_legacy_record(), FakeGit(), github).cleanup_merged_pr(1)


def test_legacy_merged_cleanup_refuses_dirty_physical_worktree() -> None:
    physical = (PhysicalWorktree(PATH, HEAD, BRANCH),)
    git = FakeGit(physical=physical, snapshot_clean=False)

    with pytest.raises(PolicyViolation, match="dirty or differs"):
        _service(
            _legacy_record(),
            git,
            FakeGitHub(_pr(state="MERGED", merged=True)),
        ).cleanup_merged_pr(1)
    assert git.actions == []


@pytest.mark.parametrize("field", ("base_sha", "head_sha"))
def test_legacy_merged_cleanup_refuses_pr_tuple_drift_before_next_delete(
    field: str,
) -> None:
    first = _pr(state="MERGED", merged=True)
    second = replace(first, **{field: "c" * 40})
    github = FakeGitHub(first, history=(first,))
    original_get = github.get_pull_request
    calls = 0

    def drifting_get(number: int) -> PullRequestSnapshot:
        nonlocal calls
        calls += 1
        return original_get(number) if calls == 1 else second

    github.get_pull_request = drifting_get  # type: ignore[method-assign]

    with pytest.raises(PolicyViolation, match="merged PR changed"):
        _service(_legacy_record(), FakeGit(), github).cleanup_merged_pr(1)


def test_legacy_merged_cleanup_refuses_pr_scope_drift_before_next_delete() -> None:
    pull_request = _pr(state="MERGED", merged=True)
    github = FakeGitHub(pull_request, history=(pull_request,))
    calls = 0

    def drifting_paths(number: int) -> tuple[str, ...]:
        nonlocal calls
        calls += 1
        return SCOPE.paths if calls <= 2 else ("ops/changed.py",)

    github.changed_paths = drifting_paths  # type: ignore[method-assign]

    with pytest.raises(PolicyViolation, match="merged PR changed"):
        _service(_legacy_record(), FakeGit(), github).cleanup_merged_pr(1)


def test_legacy_merged_cleanup_refuses_remote_drift() -> None:
    git = FakeGit(remote="c" * 40)
    with pytest.raises(PolicyViolation, match="remote branch"):
        _service(
            _record(status="merged"), git, FakeGitHub(_pr(state="MERGED", merged=True))
        ).cleanup_merged_pr(1)
    assert git.actions == []


@pytest.mark.parametrize(
    ("canonical_branch", "canonical_clean", "message"),
    (
        ("debug/feature", True, "canonical checkout must be on main"),
        ("main", False, "canonical checkout is dirty"),
    ),
)
def test_legacy_merged_cleanup_refuses_before_asset_delete_without_main(
    canonical_branch: str, canonical_clean: bool, message: str
) -> None:
    git = FakeGit(
        canonical_branch=canonical_branch,
        canonical_clean=canonical_clean,
    )

    with pytest.raises(PolicyViolation, match=message):
        _service(
            _record(status="merged"),
            git,
            FakeGitHub(_pr(state="MERGED", merged=True)),
        ).cleanup_merged_pr(1)

    assert git.actions == []


def test_legacy_abandoned_pr_closes_and_removes_remote_only() -> None:
    git = FakeGit(local=None)
    github = FakeGitHub(_pr(state="OPEN"))
    result = _service(_record(status="abandoned"), git, github).abandon_open_pr(1)

    assert result.pull_request_state == "CLOSED"
    assert github.closed
    assert git.actions == ["delete-remote"]


def test_legacy_abandoned_pr_with_auto_merge_is_refused_before_any_mutation() -> None:
    git = FakeGit(local=None)
    github = FakeGitHub(replace(_pr(state="OPEN"), auto_merge_enabled=True))

    with pytest.raises(PolicyViolation, match="not safe to abandon"):
        _service(_record(status="abandoned"), git, github).abandon_open_pr(1)

    assert not github.closed
    assert git.actions == []


def test_legacy_abandoned_branch_at_base_can_be_released_without_pr() -> None:
    branch = "debug/no-pr"
    record = replace(
        _record(status="abandoned", handed_back_sha=None), branch=branch, base_sha=BASE
    )
    git = FakeGit(local=BASE, remote=None)
    github = FakeGitHub(replace(_pr(state="CLOSED"), number=-1, branch=branch))
    result = _service(record, git, github).cleanup_abandoned_branch(branch)

    assert result.disposition == "abandoned"
    assert result.local_branch_absent and result.remote_branch_absent
    assert git.actions == ["delete-local"]


def test_legacy_abandoned_branch_releases_exact_clean_physical_worktree() -> None:
    branch = "debug/no-pr"
    record = replace(
        _record(status="abandoned", handed_back_sha=None), branch=branch, base_sha=BASE
    )
    physical = (PhysicalWorktree(PATH, BASE, branch),)
    git = FakeGit(
        local=BASE,
        remote=None,
        physical=physical,
        snapshot_head=BASE,
        snapshot_branch=branch,
        snapshot_changes=(),
    )
    github = FakeGitHub(replace(_pr(state="CLOSED"), number=-1, branch=branch))

    result = _service(record, git, github).cleanup_abandoned_branch(branch)

    assert result.disposition == "abandoned"
    assert result.worktree_absent
    assert result.local_branch_absent and result.remote_branch_absent
    assert git.actions == ["remove-worktree", "delete-local"]


def test_legacy_abandoned_cleanup_refuses_before_ref_delete_without_main() -> None:
    branch = "debug/no-pr"
    record = replace(_record(status="abandoned", handed_back_sha=None), branch=branch)
    git = FakeGit(local=BASE, remote=None, canonical_branch="debug/feature")
    github = FakeGitHub(replace(_pr(state="CLOSED"), number=-1, branch=branch))

    with pytest.raises(PolicyViolation, match="canonical checkout must be on main"):
        _service(record, git, github).cleanup_abandoned_branch(branch)

    assert git.actions == []


def test_terminal_claim_ignores_unrelated_malformed_history(tmp_path: Path) -> None:
    raw = {
        "branch": BRANCH,
        "path": str(tmp_path / "legacy"),
        "status": "merged",
        "external_ids": ["#1"],
        "base_sha": BASE,
        "scope": {
            "schema": "kg.worktree.scope.v1",
            "files": [{"operation": "modify", "path": "ops/example.py"}],
        },
        "claim_generation": 1,
    }

    record = terminal_claim({"records": [{"branch": "broken"}, raw]}, branch=BRANCH)

    assert record is not None
    assert record.branch == BRANCH
    assert record.status == "merged"


def test_terminal_claim_rejects_duplicate_target_history(tmp_path: Path) -> None:
    raw = {
        "branch": BRANCH,
        "path": str(tmp_path / "legacy"),
        "status": "abandoned",
        "external_ids": ["#1"],
        "base_sha": BASE,
        "scope": {
            "schema": "kg.worktree.scope.v1",
            "files": [{"operation": "modify", "path": "ops/example.py"}],
        },
        "claim_generation": 1,
    }

    with pytest.raises(AdapterPayloadError, match="multiple registry claims"):
        terminal_claim({"records": [raw, raw]}, branch=BRANCH)
