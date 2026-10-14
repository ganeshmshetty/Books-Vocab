from __future__ import annotations

import sys
from dataclasses import replace
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.domain.errors import CompareAndSwapConflict, PolicyViolation
from delivery_control.domain.models import HandbackReceipt, Scope
from delivery_control.domain.observations import (
    CanonicalCheckoutSnapshot,
    MergeQueueEntrySnapshot,
    PullRequestInventory,
    PullRequestSnapshot,
    RegistrySnapshot,
)
from delivery_control.services.abandon import AbandonService
from delivery_control.services.pr_contract import render_pull_request_body

BASE = "a" * 40
HEAD = "b" * 40
BRANCH = "feat/abandon"
WORKTREE = Path("/tmp/abandon").resolve()


def _receipt(*, scope: Scope | None = None) -> HandbackReceipt:
    return HandbackReceipt(
        lane_id="ISSUE-ABANDON",
        owner_thread_id="thread-owner",
        claim_generation=3,
        branch=BRANCH,
        worktree_path=str(WORKTREE),
        base_sha=BASE,
        parent_sha=BASE,
        head_sha=HEAD,
        origin_main_sha=BASE,
        content_digest="c" * 64,
        scope=scope or Scope.from_paths(modify=("ops/a.py",)),
    )


def _record(
    *,
    status: str = "published",
    owner: str = "thread-owner",
    receipt: HandbackReceipt | None = None,
) -> RegistrySnapshot:
    receipt = receipt or _receipt()
    return RegistrySnapshot(
        lane_id=receipt.lane_id,
        branch=receipt.branch,
        path=WORKTREE,
        status=status,
        scope=receipt.scope,
        base_sha=receipt.base_sha,
        claim_generation=receipt.claim_generation,
        external_ids=(receipt.lane_id,),
        owner_thread_id=owner,
        handed_back_sha=receipt.head_sha,
        handback_claim_generation=receipt.claim_generation,
        handback_valid=True,
        handback_digest=receipt.content_digest,
        handback_origin_main_sha=receipt.origin_main_sha,
    )


def _pr(
    *,
    state: str = "OPEN",
    head: str = HEAD,
    receipt: HandbackReceipt | None = None,
    labels: tuple[str, ...] = (),
) -> PullRequestSnapshot:
    receipt = receipt or _receipt()
    return PullRequestSnapshot(
        number=17,
        url="https://example.test/pull/17",
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=head,
        state=state,
        draft=False,
        mergeable=True,
        title="fix: abandoned lane",
        body=render_pull_request_body(receipt),
        node_id="PR_17",
        labels=labels,
    )


class FakeRegistry:
    def __init__(self, record: RegistrySnapshot | None = None) -> None:
        self.record = record or _record()
        self.fail_resolve = False
        self.fail_after_resolve = False
        self.actions: list[str] = []

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
        assert disposition == "abandoned"
        assert expected_claim_generation == self.record.claim_generation
        assert expected_branch == self.record.branch
        assert Path(expected_path) == self.record.path
        assert expected_head_sha == self.record.handed_back_sha
        assert terminal_proof is None
        self.actions.append("abandon-registry")
        if self.fail_resolve:
            raise CompareAndSwapConflict("registry CAS failed")
        self.record = replace(self.record, status="abandoned")
        if self.fail_after_resolve:
            raise CompareAndSwapConflict("registry readback was ambiguous")


class FakeGit:
    def __init__(
        self, *, canonical_branch: str = "main", canonical_clean: bool = True
    ) -> None:
        self.remote_sha: str | None = HEAD
        self.local_sha: str | None = None
        self.worktrees: tuple[object, ...] = ()
        self.fail_delete = False
        self.actions: list[str] = []
        self.canonical_branch = canonical_branch
        self.canonical_clean = canonical_clean

    def canonical_checkout(self) -> CanonicalCheckoutSnapshot:
        return CanonicalCheckoutSnapshot(
            path=Path("/repo"),
            branch=self.canonical_branch,
            head_sha=BASE,
            clean=self.canonical_clean,
        )

    def list_worktrees(self) -> tuple[object, ...]:
        return self.worktrees

    def local_branch_sha(self, branch: str) -> str | None:
        assert branch == BRANCH
        return self.local_sha

    def remote_branch_sha(self, branch: str) -> str | None:
        assert branch == BRANCH
        return self.remote_sha

    def delete_remote_branch(self, branch: str, *, expected_head_sha: str) -> None:
        assert branch == BRANCH and expected_head_sha == HEAD
        self.actions.append("delete-remote")
        if self.fail_delete:
            raise CompareAndSwapConflict("remote delete failed")
        self.remote_sha = None


@pytest.mark.parametrize(
    ("canonical_branch", "canonical_clean", "message"),
    (
        ("debug/owner", True, "canonical checkout must be on main"),
        ("main", False, "canonical checkout is dirty"),
    ),
)
def test_abandon_refuses_before_pr_or_remote_mutation_without_canonical_main(
    canonical_branch: str, canonical_clean: bool, message: str
) -> None:
    service, registry, git, github = _service(
        git=FakeGit(
            canonical_branch=canonical_branch,
            canonical_clean=canonical_clean,
        )
    )

    with pytest.raises(PolicyViolation, match=message):
        service.abandon(pull_request_number=17)

    assert github.actions == []
    assert registry.actions == []
    assert git.actions == []


class FakeGitHub:
    def __init__(
        self,
        pull_request: PullRequestSnapshot | None = None,
        *,
        actual_paths: tuple[str, ...] = ("ops/a.py",),
    ) -> None:
        self.pull_request = pull_request or _pr()
        self.inventory = PullRequestInventory((self.pull_request,))
        self.actual_paths = actual_paths
        self.queue_entry: MergeQueueEntrySnapshot | None = None
        self.fail_close = False
        self.fail_reopen = False
        self.actions: list[str] = []

    def list_pull_requests_for_branch(self, branch: str) -> PullRequestInventory:
        assert branch == BRANCH
        return self.inventory

    def get_pull_request(self, number: int) -> PullRequestSnapshot:
        assert number == 17
        return self.pull_request

    def changed_paths(self, number: int) -> tuple[str, ...]:
        assert number == 17
        return self.actual_paths

    def merge_queue_entry_snapshot(
        self, pull_request_id: str
    ) -> MergeQueueEntrySnapshot | None:
        assert pull_request_id == "PR_17"
        return self.queue_entry

    def close_pull_request(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> PullRequestSnapshot:
        assert number == 17
        assert expected_base_sha == BASE
        assert expected_head_sha == HEAD
        assert expected_body == self.pull_request.body
        self.actions.append("close-pr")
        if self.fail_close:
            raise CompareAndSwapConflict("close failed")
        self.pull_request = replace(self.pull_request, state="CLOSED")
        self.inventory = PullRequestInventory((self.pull_request,))
        return self.pull_request

    def reopen_pull_request(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> PullRequestSnapshot:
        assert number == 17
        assert expected_base_sha == BASE
        assert expected_head_sha == HEAD
        assert expected_body == self.pull_request.body
        self.actions.append("reopen-pr")
        if self.fail_reopen:
            raise CompareAndSwapConflict("reopen failed")
        self.pull_request = replace(self.pull_request, state="OPEN")
        self.inventory = PullRequestInventory((self.pull_request,))
        return self.pull_request


def _service(
    *,
    registry: FakeRegistry | None = None,
    git: FakeGit | None = None,
    github: FakeGitHub | None = None,
) -> tuple[AbandonService, FakeRegistry, FakeGit, FakeGitHub]:
    registry = registry or FakeRegistry()
    git = git or FakeGit()
    github = github or FakeGitHub()
    return (
        AbandonService(
            registry_query=registry,
            registry_command=registry,
            git_query=git,
            git_command=git,
            github_query=github,
            github_command=github,
        ),
        registry,
        git,
        github,
    )


def test_abandon_closes_exact_pr_terminalizes_registry_and_deletes_remote() -> None:
    service, registry, git, github = _service()

    result = service.abandon(pull_request_number=17)

    assert result.pull_request_state == "CLOSED"
    assert result.registry_status == "abandoned"
    assert result.remote_branch_absent
    assert github.actions == ["close-pr"]
    assert registry.actions == ["abandon-registry"]
    assert git.actions == ["delete-remote"]


def test_abandon_terminalizes_strict_scope_superset_as_explicit_non_delivery() -> None:
    receipt = _receipt(
        scope=Scope.from_paths(modify=("ops/a.py", "ops/declared-but-untouched.py"))
    )
    registry = FakeRegistry(_record(receipt=receipt))
    github = FakeGitHub(_pr(receipt=receipt))
    original_body = github.pull_request.body
    service, registry, git, github = _service(registry=registry, github=github)

    result = service.abandon(pull_request_number=17)

    assert result.pull_request_state == "CLOSED"
    assert result.registry_status == "abandoned"
    assert result.remote_branch_absent
    assert result.malformed_published_lane is True
    assert result.delivery_succeeded is False
    assert result.mismatch_evidence is not None
    assert result.mismatch_evidence.kind == "scope-strict-superset"
    assert result.mismatch_evidence.actual_changed_paths == ("ops/a.py",)
    assert result.mismatch_evidence.scope_only_paths == (
        "ops/declared-but-untouched.py",
    )
    assert github.pull_request.body == original_body
    assert registry.record.scope == receipt.scope
    assert github.actions == ["close-pr"]
    assert registry.actions == ["abandon-registry"]
    assert git.actions == ["delete-remote"]


@pytest.mark.parametrize(
    "actual_paths",
    (("ops/a.py", "ops/outside.py"), ("ops/outside.py",)),
)
def test_abandon_rejects_changed_paths_outside_typed_scope_before_mutation(
    actual_paths: tuple[str, ...],
) -> None:
    github = FakeGitHub(actual_paths=actual_paths)
    service, registry, git, github = _service(github=github)

    with pytest.raises(PolicyViolation):
        service.abandon(pull_request_number=17)

    assert github.actions == []
    assert registry.actions == []
    assert git.actions == []


def test_abandon_rejects_explicit_hold_before_mutation() -> None:
    github = FakeGitHub(_pr(labels=("delivery-hold:p1",)))
    github.inventory = PullRequestInventory((github.pull_request,))
    service, registry, git, github = _service(github=github)

    with pytest.raises(PolicyViolation, match="hold"):
        service.abandon(pull_request_number=17)

    assert github.actions == []
    assert registry.actions == []
    assert git.actions == []


def test_abandon_rejects_queued_pr_before_any_mutation() -> None:
    github = FakeGitHub()
    github.queue_entry = object()  # type: ignore[assignment]
    service, registry, git, github = _service(github=github)

    with pytest.raises(PolicyViolation, match="merge queue"):
        service.abandon(pull_request_number=17)

    assert github.actions == []
    assert registry.actions == []
    assert git.actions == []


def test_abandon_rejects_auto_merge_pr_before_any_mutation() -> None:
    github = FakeGitHub(replace(_pr(), auto_merge_enabled=True))
    service, registry, git, github = _service(github=github)

    with pytest.raises(PolicyViolation, match="merge queue"):
        service.abandon(pull_request_number=17)

    assert github.actions == []
    assert registry.actions == []
    assert git.actions == []


def test_abandon_rejects_nonunique_branch_history_before_any_mutation() -> None:
    github = FakeGitHub()
    github.inventory = PullRequestInventory(
        (github.pull_request, replace(github.pull_request, number=18))
    )
    service, registry, git, github = _service(github=github)

    with pytest.raises(PolicyViolation, match="unique"):
        service.abandon(pull_request_number=17)

    assert github.actions == []
    assert registry.actions == []
    assert git.actions == []


def test_abandon_rejects_pr_drift_between_branch_and_number_readbacks() -> None:
    github = FakeGitHub()
    github.inventory = PullRequestInventory(
        (replace(github.pull_request, body="concurrent edit"),)
    )
    service, registry, git, github = _service(github=github)

    with pytest.raises(CompareAndSwapConflict, match="between exact"):
        service.abandon(pull_request_number=17)

    assert github.actions == []
    assert registry.actions == []
    assert git.actions == []


@pytest.mark.parametrize(
    ("registry", "github", "message"),
    (
        (FakeRegistry(_record(owner="other-owner")), FakeGitHub(), "owner"),
        (FakeRegistry(), FakeGitHub(_pr(head="d" * 40)), "receipt"),
    ),
)
def test_abandon_rejects_owner_or_head_drift_before_mutation(
    registry: FakeRegistry, github: FakeGitHub, message: str
) -> None:
    service, registry, git, github = _service(registry=registry, github=github)

    with pytest.raises(PolicyViolation, match=message):
        service.abandon(pull_request_number=17)

    assert github.actions == []
    assert registry.actions == []
    assert git.actions == []


def test_registry_failure_reopens_only_the_exact_pr_closed_by_transaction() -> None:
    registry = FakeRegistry()
    registry.fail_resolve = True
    service, registry, git, github = _service(registry=registry)

    with pytest.raises(CompareAndSwapConflict, match="registry CAS failed"):
        service.abandon(pull_request_number=17)

    assert github.pull_request.state == "OPEN"
    assert github.actions == ["close-pr", "reopen-pr"]
    assert registry.record.status == "published"
    assert git.remote_sha == HEAD


def test_ambiguous_registry_failure_continues_after_exact_terminal_readback() -> None:
    registry = FakeRegistry()
    registry.fail_after_resolve = True
    service, registry, git, github = _service(registry=registry)

    result = service.abandon(pull_request_number=17)

    assert result.registry_status == "abandoned"
    assert github.actions == ["close-pr"]
    assert git.remote_sha is None


def test_failed_reopen_reports_compensation_blocker_without_more_mutation() -> None:
    registry = FakeRegistry()
    registry.fail_resolve = True
    github = FakeGitHub()
    github.fail_reopen = True
    service, registry, git, github = _service(
        registry=registry,
        github=github,
    )

    with pytest.raises(CompareAndSwapConflict, match="compensation failed"):
        service.abandon(pull_request_number=17)

    assert github.pull_request.state == "CLOSED"
    assert github.actions == ["close-pr", "reopen-pr"]
    assert registry.record.status == "published"
    assert git.remote_sha == HEAD


def test_remote_delete_failure_is_retriable_from_exact_abandoned_state() -> None:
    git = FakeGit()
    git.fail_delete = True
    service, registry, git, github = _service(git=git)

    with pytest.raises(CompareAndSwapConflict, match="remote delete failed"):
        service.abandon(pull_request_number=17)

    assert github.pull_request.state == "CLOSED"
    assert registry.record.status == "abandoned"
    assert git.remote_sha == HEAD

    git.fail_delete = False
    result = service.abandon(pull_request_number=17)

    assert result.remote_branch_absent
    assert github.actions == ["close-pr"]
    assert registry.actions == ["abandon-registry"]
    assert git.actions == ["delete-remote", "delete-remote"]


def test_abandon_rejects_preexisting_closed_pr_without_terminal_registry_proof() -> (
    None
):
    service, registry, git, github = _service(github=FakeGitHub(_pr(state="CLOSED")))

    with pytest.raises(PolicyViolation, match="OPEN"):
        service.abandon(pull_request_number=17)

    assert github.actions == []
    assert registry.record.status == "published"
    assert git.remote_sha == HEAD


def test_abandon_requires_post_publication_local_assets_to_be_absent() -> None:
    git = FakeGit()
    git.local_sha = HEAD
    service, registry, git, github = _service(git=git)

    with pytest.raises(PolicyViolation, match="local assets"):
        service.abandon(pull_request_number=17)

    assert github.actions == []
    assert registry.actions == []
    assert git.actions == []
