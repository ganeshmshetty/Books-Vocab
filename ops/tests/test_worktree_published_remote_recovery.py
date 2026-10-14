from __future__ import annotations

import sys
from dataclasses import replace
from pathlib import Path
from typing import Any

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

import worktree_orchestrate as coordinator
from delivery_control.domain.models import HandbackReceipt, Scope
from delivery_control.domain.observations import (
    PullRequestInventory,
    PullRequestSnapshot,
)
from delivery_control.services.pr_contract import render_pull_request_body
from worktree_reanchor_core import published_remote_recovery as recovery
from worktree_reanchor_core.errors import ReanchorRefused

BASE = "a" * 40
LIVE_MAIN = "b" * 40
HEAD = "c" * 40
LANE = "DIRECT-RECOVERY-1"
BRANCH = "debug/published-recovery"
OWNER = "owner-thread-1"


def _scope() -> dict[str, object]:
    return {
        "schema": "kg.worktree.scope.v1",
        "files": [{"path": "ops/recovery_change.py", "operation": "add"}],
    }


def _fixture(tmp_path: Path) -> tuple[Path, dict[str, Any], PullRequestSnapshot]:
    released = tmp_path / "released"
    record: dict[str, Any] = {
        "branch": BRANCH,
        "path": str(released),
        "intent": "published remote recovery",
        "base": BASE,
        "base_sha": BASE,
        "status": "published",
        "external_ids": [LANE],
        "scope": _scope(),
        "codex_thread_id": OWNER,
        "delegated": True,
        "claim_generation": 0,
        "handed_back_at": "2026-08-25T00:00:00Z",
        "handed_back_sha": HEAD,
        "handback_claim_generation": 0,
    }
    record["handback_seal"] = coordinator.registry._seal_with_digest(
        coordinator.registry._seal_body(
            record,
            base_sha=BASE,
            tip_sha=HEAD,
            outcomes=[{"name": "focused", "status": "success"}],
            handed_back_at=record["handed_back_at"],
            origin_main_sha=BASE,
        )
    )
    receipt = HandbackReceipt(
        lane_id=LANE,
        owner_thread_id=OWNER,
        claim_generation=0,
        branch=BRANCH,
        worktree_path=str(released),
        base_sha=BASE,
        parent_sha=BASE,
        head_sha=HEAD,
        origin_main_sha=BASE,
        content_digest=record["handback_seal"]["digest"],
        scope=Scope.from_paths(add=("ops/recovery_change.py",)),
    )
    pull_request = PullRequestSnapshot(
        number=42,
        url="https://example.test/pull/42",
        branch=BRANCH,
        base_sha=BASE,
        head_sha=HEAD,
        state="OPEN",
        draft=False,
        mergeable=True,
        node_id="PR_42",
        body=render_pull_request_body(receipt),
    )
    state_path = tmp_path / "worktree_registry.json"
    coordinator.registry.save_state(
        state_path,
        {"schema": coordinator.registry.SCHEMA, "records": [record]},
    )
    return state_path, record, pull_request


class FakeGitHub:
    def __init__(
        self,
        pull_request: PullRequestSnapshot,
        *,
        queue_entry: object | None = None,
        duplicate_history: bool = False,
        readbacks: tuple[PullRequestSnapshot, ...] = (),
        changed_paths: tuple[str, ...] = ("ops/recovery_change.py",),
    ) -> None:
        self.pull_request = pull_request
        self.queue_entry = queue_entry
        self.duplicate_history = duplicate_history
        self.readbacks = list(readbacks)
        self.changed_paths_value = changed_paths

    def get_pull_request(self, number: int) -> PullRequestSnapshot:
        assert number == self.pull_request.number
        if self.readbacks:
            self.pull_request = self.readbacks.pop(0)
        return self.pull_request

    def list_pull_requests_for_branch(self, branch: str) -> PullRequestInventory:
        assert branch == self.pull_request.branch
        records = (
            (self.pull_request, self.pull_request)
            if self.duplicate_history
            else (self.pull_request,)
        )
        return PullRequestInventory(records)

    def changed_paths(self, number: int) -> tuple[str, ...]:
        assert number == self.pull_request.number
        return self.changed_paths_value

    def merge_queue_entry_snapshot(self, pull_request_id: str) -> object | None:
        assert pull_request_id == self.pull_request.node_id
        return self.queue_entry


class FakeGit:
    def __init__(
        self,
        *,
        race_before_push: str | None = None,
        post_push_remote: str | None = None,
        post_push_readback_failure: bool = False,
        remove_failure: bool = False,
        compensate_failure: bool = False,
        delete_remote_failure: bool = False,
    ) -> None:
        self.remote: str | None = None
        self.local: str | None = None
        self.target_exists = False
        self.race_before_push = race_before_push
        self.post_push_remote = post_push_remote
        self.post_push_readback_failure = post_push_readback_failure
        self.remove_failure = remove_failure
        self.compensate_failure = compensate_failure
        self.delete_remote_failure = delete_remote_failure
        self.remote_delete_performed = False
        self.actions: list[str] = []

    def validate_repository(self) -> None:
        return None

    def remote_branch_sha(self, branch: str) -> str | None:
        assert branch == BRANCH
        return self.remote

    def live_main_sha(self) -> str:
        return LIVE_MAIN

    def local_branch_sha(self, branch: str) -> str | None:
        assert branch == BRANCH
        return self.local

    def validate_released_assets(
        self, *, recorded_path: Path, target: Path, branch: str
    ) -> None:
        assert not recorded_path.exists()
        assert not target.exists()
        assert self.local is None

    def fetch_pr_head(self, *, pull_request_number: int, expected_head: str) -> str:
        assert pull_request_number == 42
        return expected_head

    def validate_source(
        self, *, base_sha: str, head_sha: str, declared: tuple[tuple[str, str], ...]
    ) -> None:
        assert (base_sha, head_sha) == (BASE, HEAD)
        assert declared == (("ops/recovery_change.py", "add"),)

    def provision_exact(
        self,
        *,
        target: Path,
        branch: str,
        head_sha: str,
        base_sha: str,
        declared: tuple[tuple[str, str], ...],
        attempt: recovery.RecoveryAttempt,
    ) -> None:
        assert (branch, head_sha, base_sha) == (BRANCH, HEAD, BASE)
        assert declared == (("ops/recovery_change.py", "add"),)
        self.target_exists = True
        self.local = HEAD
        attempt.target_created = True
        attempt.branch_created = True
        self.actions.append("provision")

    def validate_local_exact(
        self, *, target: Path, branch: str, expected_head: str
    ) -> None:
        assert target and branch == BRANCH and expected_head == HEAD
        assert self.target_exists and self.local == HEAD

    def push_empty_lease(
        self,
        *,
        target: Path,
        branch: str,
        expected_head: str,
        attempt: recovery.RecoveryAttempt,
    ) -> None:
        assert target and branch == BRANCH and expected_head == HEAD
        assert self.remote is None
        self.actions.append("push")
        if self.race_before_push is not None:
            self.remote = self.race_before_push
            raise ReanchorRefused("remote branch changed before empty lease push")
        self.remote = HEAD
        attempt.remote_created_by_attempt = True
        if self.post_push_remote is not None:
            self.remote = self.post_push_remote
            raise ReanchorRefused("post-push remote readback differed")
        if self.post_push_readback_failure:
            raise ReanchorRefused("post-push remote readback failed")

    def remove_local_assets(
        self, *, target: Path, branch: str, expected_head: str
    ) -> None:
        assert target and branch == BRANCH and expected_head == HEAD
        self.actions.append("remove-local")
        if self.remove_failure:
            raise ReanchorRefused("injected local cleanup failure")
        self.target_exists = False
        self.local = None

    def compensate_local_assets(
        self,
        *,
        target: Path,
        branch: str,
        expected_head: str,
        attempt: recovery.RecoveryAttempt,
    ) -> dict[str, object]:
        self.actions.append("compensate-local")
        if self.compensate_failure:
            return {"complete": False, "path_remaining": True, "branch_remaining": True}
        self.target_exists = False
        self.local = None
        return {"complete": True, "path_remaining": False, "branch_remaining": False}

    def delete_remote_exact(self, *, branch: str, expected_head: str) -> None:
        assert branch == BRANCH and expected_head == HEAD
        self.actions.append("delete-remote")
        if self.delete_remote_failure:
            raise ReanchorRefused("injected remote compensation failure")
        if self.remote not in {None, HEAD}:
            raise ReanchorRefused("remote branch drifted before compensation")
        self.remote = None
        self.remote_delete_performed = True


def _perform(
    tmp_path: Path,
    *,
    git: FakeGit | None = None,
    github: FakeGitHub | None = None,
    owner: str = OWNER,
    claim_generation: int = 0,
    expected_head: str = HEAD,
) -> tuple[dict[str, object], FakeGit, dict[str, Any]]:
    state_path, record, pull_request = _fixture(tmp_path)
    fake_git = git or FakeGit()
    fake_github = github or FakeGitHub(pull_request)
    payload = recovery.perform_recovery(
        repo=tmp_path / "repo",
        state_path=state_path,
        pull_request_number=42,
        lane_id=LANE,
        branch=BRANCH,
        owner_thread_id=owner,
        claim_generation=claim_generation,
        expected_base_sha=BASE,
        expected_head_sha=expected_head,
        target=tmp_path / "recovered",
        git=fake_git,
        github=fake_github,
    )
    return payload, fake_git, record


def test_recovery_command_is_separate_and_requires_explicit_pr() -> None:
    args = coordinator._parser().parse_args(
        [
            "recover-published-remote",
            "--pr",
            "1584",
            "--lane",
            LANE,
            "--branch",
            BRANCH,
            "--owner-thread-id",
            OWNER,
            "--claim-generation",
            "0",
            "--expected-base",
            BASE,
            "--expected-head",
            HEAD,
            "--path",
            "/tmp/recovered",
        ]
    )
    assert args.command == "recover-published-remote"
    assert args.pull_request_number == 1584


def test_missing_remote_recovery_pushes_exact_head_and_keeps_remote(
    tmp_path: Path,
) -> None:
    payload, git, _ = _perform(tmp_path)

    assert payload["status"] == "recovered"
    assert payload["pull_request"] == 42
    assert payload["head"] == HEAD
    assert payload["remote_branch"] == BRANCH
    assert git.remote == HEAD
    assert git.actions == ["provision", "push", "remove-local"]


def test_git_push_marks_attempt_owned_before_post_push_readback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    remote_reads = iter(("", f"{'d' * 40} refs/heads/{BRANCH}"))
    calls: list[list[str]] = []

    def fake_git(args: list[str], cwd: Path) -> tuple[int, str]:
        del cwd
        calls.append(args)
        if args == ["branch", "--show-current"]:
            return 0, BRANCH
        if args == ["rev-parse", "--verify", "HEAD^{commit}"]:
            return 0, HEAD
        if args == ["status", "--porcelain=v1", "--untracked-files=all"]:
            return 0, ""
        if args[:3] == ["ls-remote", "--heads", "origin"]:
            value = next(remote_reads)
            return 0, value
        if args[:2] == ["push", "origin"]:
            return 0, ""
        raise AssertionError(args)

    monkeypatch.setattr(recovery.git_ops, "_git", fake_git)
    attempt = recovery.RecoveryAttempt()
    git = recovery.RecoveryGit(tmp_path / "repo")

    with pytest.raises(ReanchorRefused, match="readback"):
        git.push_empty_lease(
            target=tmp_path / "target",
            branch=BRANCH,
            expected_head=HEAD,
            attempt=attempt,
        )

    assert attempt.remote_created_by_attempt is True
    push = next(args for args in calls if args[:2] == ["push", "origin"])
    assert f"--force-with-lease=refs/heads/{BRANCH}:" in push
    assert f"{HEAD}:refs/heads/{BRANCH}" in push


def test_recovery_refuses_remote_race_without_unowned_delete(tmp_path: Path) -> None:
    git = FakeGit(race_before_push="d" * 40)

    with pytest.raises(ReanchorRefused, match="remote branch") as caught:
        _perform(tmp_path, git=git)

    assert caught.value.details["compensation"]["complete"] is True
    assert git.actions == ["provision", "push", "compensate-local"]
    assert git.remote == "d" * 40
    assert "delete-remote" not in git.actions


def test_post_push_readback_failure_compensates_attempt_owned_ref(
    tmp_path: Path,
) -> None:
    git = FakeGit(post_push_readback_failure=True)

    with pytest.raises(ReanchorRefused, match="post-push") as caught:
        _perform(tmp_path, git=git)

    compensation = caught.value.details["compensation"]
    assert compensation["remote"]["created_by_attempt"] is True
    assert compensation["complete"] is True
    assert git.remote is None
    assert git.remote_delete_performed is True


def test_post_push_remote_drift_fails_closed_without_unowned_delete(
    tmp_path: Path,
) -> None:
    git = FakeGit(post_push_remote="d" * 40)

    with pytest.raises(ReanchorRefused, match="post-push") as caught:
        _perform(tmp_path, git=git)

    compensation = caught.value.details["compensation"]
    assert compensation["remote"]["created_by_attempt"] is True
    assert compensation["remote"]["complete"] is False
    assert compensation["complete"] is False
    assert git.remote == "d" * 40
    assert git.remote_delete_performed is False


def test_recovery_refuses_pr_body_or_typed_receipt_mismatch(tmp_path: Path) -> None:
    state_path, _, pull_request = _fixture(tmp_path)
    del state_path
    pull_request = replace(pull_request, body="mismatch")
    with pytest.raises(ReanchorRefused, match="PR body"):
        _perform(tmp_path, github=FakeGitHub(pull_request))


@pytest.mark.parametrize(
    ("field", "message"),
    (("base_sha", "PR base"), ("head_sha", "PR HEAD")),
)
def test_recovery_refuses_pr_base_or_head_mismatch(
    tmp_path: Path, field: str, message: str
) -> None:
    _, _, pull_request = _fixture(tmp_path)
    mismatched = replace(pull_request, **{field: "d" * 40})

    with pytest.raises(ReanchorRefused, match=message):
        _perform(tmp_path, github=FakeGitHub(mismatched))


def test_recovery_refuses_pr_scope_mismatch(tmp_path: Path) -> None:
    _, _, pull_request = _fixture(tmp_path)

    with pytest.raises(ReanchorRefused, match="changed paths"):
        _perform(
            tmp_path,
            github=FakeGitHub(
                pull_request,
                changed_paths=("ops/other_change.py",),
            ),
        )


def test_recovery_refuses_registry_digest_mismatch(tmp_path: Path) -> None:
    state_path, _, pull_request = _fixture(tmp_path)
    state = coordinator.registry.load_state(state_path)
    state["records"][0]["handback_seal"]["digest"] = "d" * 64
    coordinator.registry.save_state(state_path, state)

    with pytest.raises(ReanchorRefused, match="immutable handback seal"):
        recovery.perform_recovery(
            repo=tmp_path / "repo",
            state_path=state_path,
            pull_request_number=42,
            lane_id=LANE,
            branch=BRANCH,
            owner_thread_id=OWNER,
            claim_generation=0,
            expected_base_sha=BASE,
            expected_head_sha=HEAD,
            target=tmp_path / "recovered",
            git=FakeGit(),
            github=FakeGitHub(pull_request),
        )


def test_recovery_refuses_owner_registry_mismatch(tmp_path: Path) -> None:
    with pytest.raises(ReanchorRefused, match="owner"):
        _perform(tmp_path, owner="other-owner")


def test_recovery_ignores_terminal_history_when_selecting_published_claim(
    tmp_path: Path,
) -> None:
    state_path, record, pull_request = _fixture(tmp_path)
    historical = dict(record)
    historical["status"] = "abandoned"
    historical["claim_generation"] = 9
    historical["handback_claim_generation"] = 9
    historical["resolved_at"] = "2026-08-26T00:00:00Z"
    state = coordinator.registry.load_state(state_path)
    state["records"] = [historical, record]
    coordinator.registry.save_state(state_path, state)

    payload = recovery.perform_recovery(
        repo=tmp_path / "repo",
        state_path=state_path,
        pull_request_number=42,
        lane_id=LANE,
        branch=BRANCH,
        owner_thread_id=OWNER,
        claim_generation=0,
        expected_base_sha=BASE,
        expected_head_sha=HEAD,
        target=tmp_path / "recovered",
        git=FakeGit(),
        github=FakeGitHub(pull_request),
    )

    assert payload["status"] == "recovered"
    assert payload["head"] == HEAD


def test_recovery_rejects_multiple_live_registry_claims(tmp_path: Path) -> None:
    state_path, record, pull_request = _fixture(tmp_path)
    second_live = dict(record)
    second_live["claim_generation"] = 1
    second_live["handback_claim_generation"] = 1
    state = coordinator.registry.load_state(state_path)
    state["records"] = [record, second_live]
    coordinator.registry.save_state(state_path, state)

    with pytest.raises(ReanchorRefused, match="unambiguous"):
        recovery.perform_recovery(
            repo=tmp_path / "repo",
            state_path=state_path,
            pull_request_number=42,
            lane_id=LANE,
            branch=BRANCH,
            owner_thread_id=OWNER,
            claim_generation=0,
            expected_base_sha=BASE,
            expected_head_sha=HEAD,
            target=tmp_path / "recovered",
            git=FakeGit(),
            github=FakeGitHub(pull_request),
        )


@pytest.mark.parametrize(
    "github",
    [
        FakeGitHub(
            PullRequestSnapshot(
                number=42,
                url="https://example.test/pull/42",
                branch=BRANCH,
                base_sha=BASE,
                head_sha=HEAD,
                state="OPEN",
                draft=False,
                mergeable=True,
                node_id="PR_42",
                body="mismatch",
                labels=("delivery-hold:security",),
            )
        ),
    ],
)
def test_recovery_rejects_security_hold_before_local_mutation(
    tmp_path: Path, github: FakeGitHub
) -> None:
    with pytest.raises(ReanchorRefused, match="hold"):
        _perform(tmp_path, github=github)


def test_recovery_refuses_auto_merge_ownership_before_local_mutation(
    tmp_path: Path,
) -> None:
    _, _, pull_request = _fixture(tmp_path)
    git = FakeGit()
    with pytest.raises(ReanchorRefused, match="auto-merge ownership"):
        _perform(
            tmp_path,
            git=git,
            github=FakeGitHub(replace(pull_request, auto_merge_enabled=True)),
        )
    assert git.actions == []


def test_recovery_rejects_native_queue_ownership_and_duplicate_history(
    tmp_path: Path,
) -> None:
    state_path, _, pull_request = _fixture(tmp_path)
    del state_path
    with pytest.raises(ReanchorRefused, match="merge queue"):
        _perform(tmp_path, github=FakeGitHub(pull_request, queue_entry="queue-1"))

    with pytest.raises(ReanchorRefused, match="exactly one"):
        _perform(tmp_path, github=FakeGitHub(pull_request, duplicate_history=True))


def test_recovery_compensates_remote_when_final_pr_readback_drifts(
    tmp_path: Path,
) -> None:
    state_path, _, pull_request = _fixture(tmp_path)
    drifted = replace(pull_request, head_sha="d" * 40)
    github = FakeGitHub(
        pull_request,
        readbacks=(pull_request, pull_request, pull_request, drifted),
    )

    with pytest.raises(ReanchorRefused, match="PR HEAD") as caught:
        recovery.perform_recovery(
            repo=tmp_path / "repo",
            state_path=state_path,
            pull_request_number=42,
            lane_id=LANE,
            branch=BRANCH,
            owner_thread_id=OWNER,
            claim_generation=0,
            expected_base_sha=BASE,
            expected_head_sha=HEAD,
            target=tmp_path / "recovered",
            git=FakeGit(),
            github=github,
        )

    assert caught.value.details["compensation"]["complete"] is True


def test_recovery_reports_remote_compensation_failure_without_success(
    tmp_path: Path,
) -> None:
    state_path, _, pull_request = _fixture(tmp_path)
    drifted = replace(pull_request, body="changed body")
    github = FakeGitHub(
        pull_request,
        readbacks=(pull_request, pull_request, pull_request, drifted),
    )
    git = FakeGit(delete_remote_failure=True)

    with pytest.raises(ReanchorRefused, match="PR body") as caught:
        recovery.perform_recovery(
            repo=tmp_path / "repo",
            state_path=state_path,
            pull_request_number=42,
            lane_id=LANE,
            branch=BRANCH,
            owner_thread_id=OWNER,
            claim_generation=0,
            expected_base_sha=BASE,
            expected_head_sha=HEAD,
            target=tmp_path / "recovered",
            git=git,
            github=github,
        )

    assert caught.value.details["compensation"]["complete"] is False
    assert git.remote == HEAD


def test_recovery_reports_local_compensation_failure_without_success(
    tmp_path: Path,
) -> None:
    state_path, _, pull_request = _fixture(tmp_path)
    git = FakeGit(remove_failure=True, compensate_failure=True)

    with pytest.raises(ReanchorRefused, match="local cleanup") as caught:
        recovery.perform_recovery(
            repo=tmp_path / "repo",
            state_path=state_path,
            pull_request_number=42,
            lane_id=LANE,
            branch=BRANCH,
            owner_thread_id=OWNER,
            claim_generation=0,
            expected_base_sha=BASE,
            expected_head_sha=HEAD,
            target=tmp_path / "recovered",
            git=git,
            github=FakeGitHub(pull_request),
        )

    assert caught.value.details["compensation"]["complete"] is False
    assert git.remote is None
