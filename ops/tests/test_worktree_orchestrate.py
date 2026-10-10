from __future__ import annotations

import json
import shutil
import subprocess
import sys
from argparse import Namespace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Self

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))
import worktree_orchestrate as coordinator
from delivery_control.domain.models import CheckStatus, HandbackReceipt, Scope
from delivery_control.domain.observations import (
    CheckSnapshot,
    PullRequestInventory,
    PullRequestSnapshot,
)
from delivery_control.services.pr_contract import render_pull_request_body
from worktree_reanchor_core import (
    git_ops,
    lifecycle_proof,
    registry_ops,
    resume_git_ops,
)
from worktree_reanchor_core.errors import ReanchorRefused


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


def _commit(repo: Path, relative_path: str, contents: str, message: str) -> None:
    path = repo / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")
    _git(repo, "add", relative_path)
    _git(repo, "commit", "-qm", message)


def test_mutating_worktree_command_uses_shared_operation_lock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[tuple[str, object]] = []
    waits: list[float | None] = []

    class FakeLock:
        def __init__(
            self, repo: Path, *, command: str, wait_seconds: float | None = None
        ) -> None:
            events.append(("init", (repo, command)))
            waits.append(wait_seconds)

        def __enter__(self) -> Self:
            events.append(("enter", None))
            return self

        def __exit__(self, exc_type: object, exc: object, traceback: object) -> bool:
            events.append(("exit", None))
            return False

    monkeypatch.setattr(coordinator, "OperationLock", FakeLock)
    monkeypatch.setattr(coordinator, "cmd_open", lambda args: 0)
    assert coordinator.main(["open", "--intent", "test", "--slug", "lock"]) == 0
    assert events[0][0] == "init"
    assert events[0][1][1] == "worktree:open"  # type: ignore[index]
    assert [item[0] for item in events] == ["init", "enter", "exit"]
    assert waits == [None]

    events.clear()
    waits.clear()
    argv = ["--lock-timeout", "45", "open", "--intent", "test", "--slug", "lock"]
    assert coordinator.main(argv) == 0
    assert waits == [45.0]

    events.clear()
    monkeypatch.setattr(coordinator, "cmd_preflight", lambda args: 0)
    assert coordinator.main(["preflight"]) == 0
    assert events == []


def test_resolve_remove_deletes_exact_local_branch_after_remote_absence(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    branch = "debug/orphan"
    expected = "a" * 40
    worktree = tmp_path / "worktree"
    worktree.mkdir()
    calls: list[list[str]] = []

    def fake_git(args: list[str], cwd: Path = coordinator.ROOT) -> tuple[int, str]:
        calls.append(args)
        if args[:2] == ["show-ref", "--verify"]:
            return 0, f"{expected} refs/heads/{branch}"
        if args[:2] == ["ls-remote", "origin"]:
            return 0, ""
        if args == ["status", "--porcelain"]:
            return 0, ""
        if args == ["branch", "--show-current"]:
            return 0, branch
        return 0, ""

    registry_calls: list[list[str]] = []
    monkeypatch.setattr(coordinator, "_git", fake_git)
    monkeypatch.setattr(
        coordinator.registry,
        "main",
        lambda argv, acquire_lock=False, **_kw: registry_calls.append(argv) or 0,
    )

    args = Namespace(
        status="abandoned",
        branch=branch,
        path=str(worktree),
        state=None,
        json=True,
        expected_generation=0,
        expected_head_sha=expected,
        remove=True,
    )

    assert coordinator.cmd_resolve(args) == coordinator.EXIT_OK
    assert registry_calls
    assert ["branch", "-D", "--", branch] in calls
    assert calls.index(["branch", "-D", "--", branch]) > calls.index(
        ["worktree", "remove", str(worktree)]
    )


def _real_repo_with_lane_branch(tmp_path: Path, branch: str) -> tuple[Path, Path]:
    origin = tmp_path / "origin.git"
    repo = tmp_path / "repo"
    _git(tmp_path, "init", "-q", "--bare", str(origin))
    _git(tmp_path, "init", "-q", "-b", "main", str(repo))
    # Hermetic: never rely on the runner's global identity, signing, or hooks.
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test User")
    _git(repo, "config", "commit.gpgsign", "false")
    _git(repo, "config", "core.hooksPath", str(tmp_path / "no-hooks"))
    _commit(repo, "README.md", "base\n", "init")
    _git(repo, "remote", "add", "origin", str(origin))
    _git(repo, "push", "-q", "origin", "main")
    worktree = tmp_path / "lane-wt"
    _git(repo, "worktree", "add", "-q", "-b", branch, str(worktree), "main")
    _commit(worktree, "lane.txt", "lane\n", "lane work")
    return repo, worktree


@pytest.mark.parametrize("worktree_dir_present", [True, False])
def test_resolve_remove_branch_only_removes_real_worktree_and_branch(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    worktree_dir_present: bool,
) -> None:
    branch = "debug/orphan-e2e"
    repo, worktree = _real_repo_with_lane_branch(tmp_path, branch)
    head = _git(repo, "rev-parse", f"refs/heads/{branch}")
    if not worktree_dir_present:
        shutil.rmtree(worktree)

    monkeypatch.setattr(coordinator, "ROOT", repo)
    monkeypatch.setattr(coordinator, "_already_abandoned", lambda _args: False)
    monkeypatch.setattr(
        coordinator,
        "_cleanup_pending_retire_evidence",
        lambda _args: (None, None),
    )
    registry_calls: list[list[str]] = []
    monkeypatch.setattr(
        coordinator.registry,
        "main",
        lambda argv, acquire_lock=False, **_kw: (
            registry_calls.append(argv) or coordinator.registry.EXIT_OK
        ),
    )

    args = Namespace(
        status="abandoned",
        branch=branch,
        path=None,
        state=None,
        json=True,
        expected_generation=0,
        expected_head_sha=head,
        remove=True,
    )

    assert coordinator.cmd_resolve(args) == coordinator.EXIT_OK
    assert registry_calls
    assert not worktree.exists()
    branch_probe = subprocess.run(
        ["git", "-C", str(repo), "show-ref", "--verify", f"refs/heads/{branch}"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert branch_probe.returncode != 0
    worktree_list = _git(repo, "worktree", "list", "--porcelain")
    assert f"branch refs/heads/{branch}" not in worktree_list


def test_resolve_remove_preserves_assets_when_remote_branch_exists(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    branch = "debug/remote-drift"
    expected = "b" * 40
    calls: list[list[str]] = []

    def fake_git(args: list[str], cwd: Path = coordinator.ROOT) -> tuple[int, str]:
        calls.append(args)
        if args[:2] == ["show-ref", "--verify"]:
            return 0, f"{expected} refs/heads/{branch}"
        if args[:2] == ["ls-remote", "origin"]:
            return 0, f"{expected}\trefs/heads/{branch}"
        return 0, ""

    registry_calls: list[list[str]] = []
    monkeypatch.setattr(coordinator, "_git", fake_git)
    monkeypatch.setattr(
        coordinator.registry,
        "main",
        lambda argv, acquire_lock=False, **_kw: registry_calls.append(argv) or 0,
    )

    args = Namespace(
        status="abandoned",
        branch=branch,
        path=None,
        state=None,
        json=True,
        expected_generation=0,
        expected_head_sha=expected,
        remove=True,
    )

    assert coordinator.cmd_resolve(args) == coordinator.EXIT_BLOCK
    assert not registry_calls
    assert "remote branch exists" in capsys.readouterr().err
    assert ["branch", "-D", "--", branch] not in calls


def test_resolve_remove_preserves_branch_when_head_drifts_after_transition(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    branch = "debug/drift"
    expected = "c" * 40
    drifted = "d" * 40
    show_ref_calls = 0
    calls: list[list[str]] = []

    def fake_git(args: list[str], cwd: Path = coordinator.ROOT) -> tuple[int, str]:
        nonlocal show_ref_calls
        calls.append(args)
        if args[:2] == ["show-ref", "--verify"]:
            show_ref_calls += 1
            head = expected if show_ref_calls == 1 else drifted
            return 0, f"{head} refs/heads/{branch}"
        if args[:2] == ["ls-remote", "origin"]:
            return 0, ""
        return 0, ""

    registry_calls: list[list[str]] = []
    monkeypatch.setattr(coordinator, "_git", fake_git)
    monkeypatch.setattr(
        coordinator.registry,
        "main",
        lambda argv, acquire_lock=False, **_kw: registry_calls.append(argv) or 0,
    )

    args = Namespace(
        status="abandoned",
        branch=branch,
        path=None,
        state=None,
        json=True,
        expected_generation=0,
        expected_head_sha=expected,
        remove=True,
    )

    assert coordinator.cmd_resolve(args) == coordinator.EXIT_BLOCK
    assert registry_calls
    assert ["branch", "-D", "--", branch] not in calls


def _fixture_receipt_body(*, number: int, branch: str, base: str, head: str) -> str:
    receipt = HandbackReceipt(
        lane_id=f"DIRECT-PR-{number}",
        owner_thread_id="owner-thread-1",
        claim_generation=0,
        branch=branch,
        worktree_path=f"/tmp/pr-{number}",
        base_sha=base,
        parent_sha=base,
        head_sha=head,
        origin_main_sha=base,
        content_digest="e" * 64,
        scope=Scope.from_paths(modify=(f"ops/pr_{number}.py",)),
    )
    return render_pull_request_body(receipt)


class _FixtureRecoveryGitHub:
    def __init__(self, repo: Path, *, operation: str) -> None:
        self.repo = repo
        self.operation = operation

    def _pull_request(self, branch: str = "feat/exact-pr") -> PullRequestSnapshot:
        head = _git(self.repo, "rev-parse", f"refs/remotes/origin/{branch}")
        base = _git(self.repo, "merge-base", head, "refs/remotes/origin/main")
        return PullRequestSnapshot(
            number=42,
            url="https://example.test/pull/42",
            branch=branch,
            base_sha=base,
            head_sha=head,
            state="OPEN",
            draft=False,
            mergeable=True,
            node_id="PR_42",
            body=_fixture_receipt_body(
                number=42,
                branch=branch,
                base=base,
                head=head,
            ),
        )

    def list_pull_requests_for_branch(self, branch: str) -> PullRequestInventory:
        return PullRequestInventory((self._pull_request(branch),))

    def list_open_pull_requests(self) -> PullRequestInventory:
        return PullRequestInventory((self._pull_request(),))

    def required_check_snapshot(self, number: int) -> CheckSnapshot:
        assert number == 42
        status = (
            CheckStatus.FAILURE
            if self.operation == "resume-published"
            else CheckStatus.SUCCESS
        )
        return CheckSnapshot(
            status=status,
            head_sha=self._pull_request().head_sha,
            observed_at=datetime(2026, 8, 22, tzinfo=UTC),
            names=("required",),
        )

    def merge_queue_entry_snapshot(self, pull_request_id: str) -> None:
        assert pull_request_id == "PR_42"


@pytest.fixture(autouse=True)
def _recovery_github_fixture(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        lifecycle_proof,
        "build_github",
        lambda repo, *, operation: _FixtureRecoveryGitHub(repo, operation=operation),
    )


def _synthetic_rebase_refs(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test User")
    _commit(repo, "shared.txt", "base\n", "base")
    _git(repo, "branch", "base")
    _commit(repo, "ops/incoming_main.py", "incoming\n", "incoming main")
    _git(repo, "branch", "incoming-main")
    _git(repo, "checkout", "-q", "-b", "solver", "base")
    _commit(repo, "ios/issue_1033.py", "branch\n", "solver branch")
    return repo


def test_intent_type_is_only_branch_naming() -> None:
    assert coordinator._intent_type("fix crash in reader", None) == "debug"
    assert coordinator._intent_type("investigate sync drift", None) == "research"
    assert coordinator._intent_type("add reader filter", None) == "feat"
    assert coordinator._intent_type("anything", "debug") == "debug"


def test_open_help_documents_owner_bound_external_id_contract(
    capsys: pytest.CaptureFixture[str],
) -> None:
    with pytest.raises(SystemExit) as caught:
        coordinator._parser().parse_args(["open", "--help"])

    assert caught.value.code == 0
    help_text = " ".join(capsys.readouterr().out.split())
    assert "--external-id" in help_text
    assert "--delegated" in help_text
    assert "--codex-thread-id" in help_text
    assert "non-blank" in help_text
    assert "before base resolution, registry, branch, or worktree mutation" in help_text


def test_open_requires_external_id_before_registry_or_worktree_mutation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(coordinator, "_require_unfrozen", lambda command: None)
    monkeypatch.setattr(
        coordinator,
        "_resolve_commit",
        lambda *_args: pytest.fail("missing external id must fail before resolution"),
    )
    monkeypatch.setattr(
        coordinator,
        "_registry_register",
        lambda **_kwargs: pytest.fail("missing external id must not mutate registry"),
    )
    monkeypatch.setattr(
        coordinator,
        "_git",
        lambda *_args, **_kwargs: pytest.fail(
            "missing external id must not mutate git"
        ),
    )

    worktree = tmp_path / "worktree"
    args = Namespace(
        slug="missing-external-id",
        intent="fix direct lane identity",
        type="debug",
        path=str(worktree),
        external_id=[],
        base="origin/main",
        codex_thread_id="owner-thread",
        delegated=True,
        state=str(tmp_path / "registry.json"),
        scope=json.dumps(_scope_for("ops/example.py")),
        scope_file=None,
        json=True,
    )

    assert coordinator.cmd_open(args) == coordinator.EXIT_BLOCK

    payload = json.loads(capsys.readouterr().out)
    assert payload == {
        "schema": coordinator.SCHEMA,
        "action": "refused",
        "reason": "--external-id is required for delegated or owner-bound open",
    }
    assert not worktree.exists()


def _open_refusal_args(tmp_path: Path, **overrides: object) -> Namespace:
    values: dict[str, object] = {
        "slug": "refusal-lane",
        "intent": "fix direct lane identity",
        "type": "debug",
        "path": str(tmp_path / "worktree"),
        "external_id": ["DIRECT-TEST-REFUSAL"],
        "base": "origin/main",
        "codex_thread_id": "owner-thread",
        "delegated": True,
        "state": str(tmp_path / "registry.json"),
        "scope": json.dumps(_scope_for("ops/example.py")),
        "scope_file": None,
        "json": True,
    }
    values.update(overrides)
    return Namespace(**values)


@pytest.mark.parametrize(
    ("overrides", "reason"),
    [
        (
            {"scope": None},
            "--scope or --scope-file is required to open a lane (#2658)",
        ),
        (
            {"codex_thread_id": None},
            "--codex-thread-id is required for delegated open (#2658)",
        ),
    ],
)
def test_open_refuses_missing_scope_or_owner_before_any_mutation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    overrides: dict[str, object],
    reason: str,
) -> None:
    monkeypatch.setattr(coordinator, "_require_unfrozen", lambda command: None)
    for name in ("_resolve_commit", "_registry_register", "_git"):
        monkeypatch.setattr(
            coordinator,
            name,
            lambda *_a, **_k: pytest.fail("refusal must precede every mutation"),
        )

    args = _open_refusal_args(tmp_path, **overrides)

    assert coordinator.cmd_open(args) == coordinator.EXIT_USAGE
    payload = json.loads(capsys.readouterr().out)
    assert payload["action"] == "refused"
    assert payload["reason"] == reason
    assert not (tmp_path / "worktree").exists()
    assert not (tmp_path / "registry.json").exists()


def test_open_accepts_external_id_for_owner_bound_open(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    base_sha = "a" * 40
    registered: dict[str, object] = {}
    monkeypatch.setattr(coordinator, "_require_unfrozen", lambda command: None)
    monkeypatch.setattr(coordinator, "_resolve_commit", lambda *_args: base_sha)
    monkeypatch.setattr(
        coordinator,
        "_registry_register",
        lambda **kwargs: (
            registered.update(kwargs) or coordinator.registry.EXIT_OK,
            {
                "branch": "debug/owner-bound-open",
                "path": str(tmp_path / "worktree"),
                "claim_generation": 0,
                "base_sha": base_sha,
            },
        ),
    )
    git_calls: list[list[str]] = []
    monkeypatch.setattr(
        coordinator,
        "_git",
        lambda argv, cwd=coordinator.ROOT: git_calls.append(argv) or (0, ""),
    )

    args = Namespace(
        slug="owner-bound-open",
        intent="fix direct lane identity",
        type="debug",
        path=str(tmp_path / "worktree"),
        external_id=["DIRECT-TEST-OWNER-BOUND"],
        base="origin/main",
        codex_thread_id="owner-thread",
        delegated=True,
        state=str(tmp_path / "registry.json"),
        scope=json.dumps(_scope_for("ops/example.py")),
        scope_file=None,
        json=True,
    )

    assert coordinator.cmd_open(args) == coordinator.EXIT_OK

    payload = json.loads(capsys.readouterr().out)
    assert payload["action"] == "open"
    assert registered["external_ids"] == ["DIRECT-TEST-OWNER-BOUND"]
    assert git_calls == [
        [
            "worktree",
            "add",
            "-b",
            "debug/owner-bound-open",
            str(tmp_path / "worktree"),
            base_sha,
        ]
    ]


def test_open_uses_exact_base_for_failed_provisioning_compensation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    base_sha = "a" * 40
    compensation: list[str] = []
    git_calls: list[list[str]] = []
    monkeypatch.setattr(coordinator, "_require_unfrozen", lambda command: None)
    monkeypatch.setattr(coordinator, "_resolve_commit", lambda path, ref: base_sha)
    monkeypatch.setattr(
        coordinator,
        "_registry_register",
        lambda **kwargs: (
            coordinator.registry.EXIT_OK,
            {
                "branch": "feat/provision-failure",
                "path": str(tmp_path / "worktree"),
                "claim_generation": 2,
                "base_sha": base_sha,
            },
        ),
    )

    def fail_worktree_add(
        argv: list[str], cwd: Path = coordinator.ROOT
    ) -> tuple[int, str]:
        git_calls.append(argv)
        return 1, "injected add failure"

    monkeypatch.setattr(coordinator, "_git", fail_worktree_add)

    def fail_compensation(argv: list[str], **_kwargs: object) -> int:
        compensation.extend(argv)
        return coordinator.registry.EXIT_CLAIMED

    monkeypatch.setattr(coordinator.registry, "main", fail_compensation)
    args = Namespace(
        slug="provision-failure",
        intent="test provisioning",
        type="feat",
        path=str(tmp_path / "worktree"),
        external_id=["DIRECT-TEST"],
        base="origin/main",
        codex_thread_id="thread-test",
        delegated=True,
        state=str(tmp_path / "custom-registry.json"),
        scope=json.dumps(_scope_for("ops/a.py")),
        scope_file=None,
        json=True,
    )

    assert coordinator.cmd_open(args) == coordinator.EXIT_BLOCK

    payload = json.loads(capsys.readouterr().out)
    assert payload["reason"] == (
        "git worktree add failed and registry compensation failed"
    )
    assert git_calls[0][-1] == base_sha
    assert compensation[compensation.index("--expected-head-sha") + 1] == base_sha
    assert compensation[compensation.index("--state") + 1] == str(
        (tmp_path / "custom-registry.json").resolve()
    )


def test_open_compensates_against_existing_branch_head_after_add_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    base_sha = "a" * 40
    branch_sha = "b" * 40
    compensation: list[str] = []
    monkeypatch.setattr(coordinator, "_require_unfrozen", lambda command: None)
    resolved = iter((base_sha, branch_sha))
    monkeypatch.setattr(
        coordinator, "_resolve_commit", lambda path, ref: next(resolved)
    )
    monkeypatch.setattr(
        coordinator,
        "_registry_register",
        lambda **kwargs: (
            coordinator.registry.EXIT_OK,
            {
                "branch": "feat/existing-branch",
                "path": str(tmp_path / "worktree"),
                "claim_generation": 4,
                "base_sha": base_sha,
            },
        ),
    )
    monkeypatch.setattr(
        coordinator,
        "_git",
        lambda argv, cwd=coordinator.ROOT: (1, "branch already exists"),
    )
    monkeypatch.setattr(
        coordinator.registry,
        "main",
        lambda argv, **_kwargs: (
            compensation.extend(argv) or coordinator.registry.EXIT_CLAIMED
        ),
    )
    args = Namespace(
        slug="existing-branch",
        intent="test existing branch compensation",
        type="feat",
        path=str(tmp_path / "worktree"),
        external_id=["DIRECT-TEST-EXISTING"],
        base="origin/main",
        codex_thread_id="thread-test",
        delegated=False,
        state=str(tmp_path / "custom-registry.json"),
        scope=json.dumps(_scope_for("ops/a.py")),
        scope_file=None,
        json=True,
    )

    assert coordinator.cmd_open(args) == coordinator.EXIT_BLOCK

    payload = json.loads(capsys.readouterr().out)
    assert payload["reason"] == (
        "git worktree add failed and registry compensation failed"
    )
    assert compensation[compensation.index("--expected-head-sha") + 1] == branch_sha


def _scope_for(path: str) -> dict[str, object]:
    return {
        "schema": "kg.worktree.scope.v1",
        "files": [{"path": path, "operation": "modify"}],
    }


def test_gate_plan_routes_product_surfaces_to_existing_entry_points() -> None:
    plan = coordinator._plan_checks(
        [
            "backend/src/kg/app.py",
            "ios/BooksAndVocab/App.swift",
            "ops/example.sh",
            "docs/reference/tech_index.md",
        ]
    )
    names = {item["name"] for item in plan}
    assert "backend-tests" in names
    assert "ios-tests" in names
    assert "ops-tests" in names
    assert "docs-lint" in names
    assert "shell-syntax:ops/example.sh" in names
    levels = {item["name"]: item["level"] for item in plan}
    assert levels["git-diff-check"] == "block"
    assert levels["backend-tests"] == "block"
    assert levels["ops-tests"] == "block"
    assert levels["docs-lint"] == "block"
    assert levels["shell-syntax:ops/example.sh"] == "block"
    assert levels["ios-tests"] == "block"
    ios_check = next(item for item in plan if item["name"] == "ios-tests")
    assert ios_check["cmd"][-1] == "--json"
    assert ios_check["scope_files"] == [
        "backend/src/kg/app.py",
        "docs/reference/tech_index.md",
        "ios/BooksAndVocab/App.swift",
        "ops/example.sh",
    ]


def test_gate_plan_uses_a_leased_simulator_for_ios_checks() -> None:
    plan = coordinator._plan_checks(["ios/BooksAndVocab/App.swift"])

    ios_check = next(item for item in plan if item["name"] == "ios-tests")

    assert ios_check["cmd"] == [
        "./ops/ios_ops.sh",
        "test",
        "--unit",
        "--lease",
        "--json",
    ]


def test_run_check_remote_adapter_does_not_execute_arbitrary_command(
    tmp_path: Path,
) -> None:
    calls: list[dict[str, object]] = []

    class FakeRemoteAdapter:
        def adapt(
            self, request: object, receipt: object, **kwargs: object
        ) -> dict[str, object]:
            calls.append({"request": request, "receipt": receipt, **kwargs})
            return {
                "name": "remote-child",
                "kind": "remote",
                "cwd": ".",
                "level": "block",
                "status": "pass",
                "rc": 0,
                "duration_s": 0.1,
                "output_tail": "validated",
                "executed": True,
                "remote_validation": {"status": "validated"},
            }

    result = coordinator._run_check(
        {
            "name": "remote-child",
            "kind": "remote",
            "cwd": ".",
            "cmd": ["false"],
            "level": "block",
            "remote_adapter": FakeRemoteAdapter(),
            "remote_request": {"profile": "remote.echo"},
            "remote_receipt": {"signed": True},
            "remote_log": b"validated",
            "remote_artifact": b"artifact",
            "remote_current_head": "a" * 40,
        },
        tmp_path,
    )

    assert result["status"] == "pass"
    assert result["executed"] is True
    assert calls[0]["request"] == {"profile": "remote.echo"}
    assert calls[0]["current_head"] == "a" * 40


def test_run_check_remote_route_uses_named_adapter_route(
    tmp_path: Path,
) -> None:
    calls: list[dict[str, object]] = []

    class FakeRemoteAdapter:
        def run(self, profile: object, **kwargs: object) -> dict[str, object]:
            calls.append({"profile": profile, **kwargs})
            return {
                "name": "remote.echo",
                "kind": "remote",
                "level": "block",
                "status": "pass",
                "rc": 0,
                "executed": True,
                "remote_validation": {
                    "status": "fallback-local",
                    "reason": "transport-unavailable",
                },
            }

    local_check = lambda: {"status": "pass"}
    result = coordinator._run_check(
        {
            "name": "remote.echo",
            "kind": "remote",
            "cwd": ".",
            "cmd": ["false"],
            "level": "block",
            "remote_adapter": FakeRemoteAdapter(),
            "remote_profile": "remote.echo",
            "remote_source_commit": "a" * 40,
            "remote_tree_sha256": "b" * 64,
            "remote_spec_digest": "c" * 64,
            "remote_admission_snapshot": {"host": "felix"},
            "remote_local_check": local_check,
            "remote_transport": lambda _request: None,
            "remote_current_head": "a" * 40,
        },
        tmp_path,
    )

    assert result["status"] == "pass"
    assert calls[0]["profile"] == "remote.echo"
    assert calls[0]["current_head"] == "a" * 40


def test_gate_discards_remote_results_when_head_moves_before_record(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    remote_check = {
        "name": "remote-child",
        "kind": "remote",
        "cwd": ".",
        "level": "block",
        "remote_adapter": object(),
        "remote_request": {"profile": "remote.echo", "request_digest": "d" * 64},
    }
    monkeypatch.setattr(
        coordinator,
        "_changed_files",
        lambda worktree, base: ["ops/worktree_orchestrate.py"],
    )
    monkeypatch.setattr(
        coordinator,
        "_plan_checks",
        lambda files, **kwargs: [remote_check],
    )
    monkeypatch.setattr(
        coordinator,
        "_run_check",
        lambda check, worktree: {
            "name": "remote-child",
            "kind": "remote",
            "level": "block",
            "status": "pass",
            "rc": 0,
            "executed": True,
        },
    )
    heads = iter(("a" * 40, "b" * 40))
    monkeypatch.setattr(
        coordinator,
        "_git",
        lambda argv, cwd=coordinator.ROOT: (
            (0, next(heads)) if argv == ["rev-parse", "HEAD"] else (0, "")
        ),
    )
    gate_path = tmp_path / "state" / "gate.json"
    monkeypatch.setattr(
        coordinator,
        "_gate_record_path",
        lambda state, worktree: gate_path,
    )

    rc = coordinator.cmd_gate(
        Namespace(
            worktree=str(tmp_path),
            base="test-base",
            plan_only=False,
            state=None,
            json=True,
        )
    )

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert payload["verdict"] == "block"
    assert payload["reason"] == "head-moved-before-gate-record"
    assert payload["results"] == []
    assert not gate_path.exists()


def _run_local_gate(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    *,
    heads: tuple[tuple[int, str], ...],
    file_sets: tuple[list[str], ...],
) -> tuple[int, dict[str, Any], Path]:
    local_check = {"name": "local-child", "cwd": ".", "level": "block"}
    files = iter(file_sets)
    monkeypatch.setattr(
        coordinator, "_changed_files", lambda worktree, base: next(files)
    )
    monkeypatch.setattr(
        coordinator, "_plan_checks", lambda files, **kwargs: [local_check]
    )
    monkeypatch.setattr(
        coordinator,
        "_run_check",
        lambda check, worktree: {
            "name": "local-child",
            "level": "block",
            "status": "pass",
            "rc": 0,
            "executed": True,
        },
    )
    head_reads = iter(heads)
    monkeypatch.setattr(
        coordinator,
        "_git",
        lambda argv, cwd=coordinator.ROOT: (
            next(head_reads) if argv == ["rev-parse", "HEAD"] else (0, "")
        ),
    )
    gate_path = tmp_path / "state" / "gate.json"
    monkeypatch.setattr(
        coordinator, "_gate_record_path", lambda state, worktree: gate_path
    )
    rc = coordinator.cmd_gate(
        Namespace(
            worktree=str(tmp_path),
            base="test-base",
            plan_only=False,
            state=None,
            json=True,
        )
    )
    return rc, json.loads(capsys.readouterr().out), gate_path


_SAME_FILES = (["ops/a.py"], ["ops/a.py"])


@pytest.mark.parametrize(
    ("heads", "file_sets"),
    [
        pytest.param(((0, "a" * 40), (0, "b" * 40)), _SAME_FILES, id="head-moved"),
        pytest.param(
            ((0, "a" * 40), (0, "a" * 40)),
            (["ops/a.py"], ["ops/a.py", "ops/b.py"]),
            id="files-changed",
        ),
        pytest.param(((0, "a" * 40), (1, "")), _SAME_FILES, id="final-head-read-fails"),
    ],
)
def test_gate_local_route_blocks_without_record_when_state_moves(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    heads: tuple[tuple[int, str], ...],
    file_sets: tuple[list[str], ...],
) -> None:
    rc, payload, gate_path = _run_local_gate(
        tmp_path, monkeypatch, capsys, heads=heads, file_sets=file_sets
    )

    assert rc == coordinator.EXIT_BLOCK
    assert payload["verdict"] == "block"
    assert payload["reason"] == "head-moved-before-gate-record"
    assert payload["results"] == []
    assert not gate_path.exists()


def test_gate_local_route_blocks_when_initial_head_read_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    rc, payload, gate_path = _run_local_gate(
        tmp_path, monkeypatch, capsys, heads=((1, ""),), file_sets=(["ops/a.py"],)
    )

    assert rc == coordinator.EXIT_BLOCK
    assert payload["verdict"] == "block"
    assert payload["reason"] == "head-read-before-gate"
    assert payload["results"] == []
    assert not gate_path.exists()


def test_gate_local_route_records_pass_when_head_and_files_stable(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    rc, payload, gate_path = _run_local_gate(
        tmp_path,
        monkeypatch,
        capsys,
        heads=((0, "a" * 40), (0, "a" * 40)),
        file_sets=_SAME_FILES,
    )

    assert rc == coordinator.EXIT_OK
    assert payload["verdict"] == "pass"
    assert payload["head"] == "a" * 40
    assert json.loads(gate_path.read_text(encoding="utf-8"))["verdict"] == "pass"


def _ios_failure_output(*, file: Path | None) -> str:
    diagnostic = {
        "severity": "error",
        "category": "test",
        "file": str(file) if file is not None else None,
        "line": None,
        "column": None,
        "message": "BooksAndVocabTests/testSyncFails(): XCTAssertEqual failed",
        "raw": "BooksAndVocabTests/testSyncFails(): XCTAssertEqual failed",
    }
    return json.dumps(
        {
            "schema": "kg.ios.run.v1",
            "status": "fail",
            "result": "fail",
            "diagnostics": {
                "schema": "kg.ios.diagnostics.v1",
                "source": "xcresult-test-results",
                "result": "fail",
                "counts": {
                    "errors": 1,
                    "warnings": 0,
                    "failedTests": 1,
                },
                "diagnostics": [diagnostic],
                "truncated": False,
                "totalDiagnostics": 1,
            },
        }
    )


def _ios_failure_check(output: str, scope_files: list[str]) -> dict[str, object]:
    return {
        "name": "ios-tests",
        "kind": "shell",
        "cwd": ".",
        "cmd": [
            "bash",
            "-c",
            'printf "%s" "$1"; exit 7',
            "ios-check",
            output,
        ],
        "level": "block",
        "scope_files": scope_files,
    }


def test_run_check_downgrades_only_proven_scope_external_ios_failure(
    tmp_path: Path,
) -> None:
    external_file = tmp_path / "ios" / "BooksAndVocabTests" / "Unrelated.swift"
    result = coordinator._run_check(
        _ios_failure_check(
            _ios_failure_output(file=external_file),
            ["ios/BooksAndVocab/Changed.swift"],
        ),
        tmp_path,
    )

    assert result["status"] == "block"
    assert result["level"] == "advisory"
    assert result["rc"] == 7
    assert result["diagnostics"]["schema"] == "kg.ios.diagnostics.v1"
    assert result["failure_scope"]["verdict"] == "advisory"
    assert result["failure_scope"]["failure_files"] == [
        "ios/BooksAndVocabTests/Unrelated.swift"
    ]
    assert _ios_failure_output(file=external_file) in result["output_tail"]


def test_run_check_blocks_in_scope_ios_failure(tmp_path: Path) -> None:
    changed_file = tmp_path / "ios" / "BooksAndVocab" / "Changed.swift"
    result = coordinator._run_check(
        _ios_failure_check(
            _ios_failure_output(file=changed_file),
            ["ios/BooksAndVocab/Changed.swift"],
        ),
        tmp_path,
    )

    assert result["status"] == "block"
    assert result["level"] == "block"
    assert result["failure_scope"]["verdict"] == "block"
    assert result["failure_scope"]["reason"] == "failure-in-changed-scope"
    assert result["output_tail"]


def test_run_check_blocks_unknown_ios_failure(tmp_path: Path) -> None:
    result = coordinator._run_check(
        _ios_failure_check(
            _ios_failure_output(file=None),
            ["ios/BooksAndVocab/Changed.swift"],
        ),
        tmp_path,
    )

    assert result["status"] == "block"
    assert result["level"] == "block"
    assert result["failure_scope"]["verdict"] == "block"
    assert result["failure_scope"]["reason"] == "failure-location-unknown"


def test_run_check_recovers_external_ios_failure_from_recorded_issue_location(
    tmp_path: Path,
) -> None:
    external_file = tmp_path / "ios" / "BooksAndVocabTests" / "Unrelated.swift"
    external_file.parent.mkdir(parents=True)
    external_file.write_text("", encoding="utf-8")
    output = (
        _ios_failure_output(file=None)
        + "\n✘ Test testSyncFails() recorded an issue at "
        "Unrelated.swift:17:9: XCTAssertEqual failed\n"
    )

    result = coordinator._run_check(
        _ios_failure_check(output, ["ios/BooksAndVocab/Changed.swift"]),
        tmp_path,
    )

    assert result["status"] == "block"
    assert result["level"] == "advisory"
    assert result["failure_scope"]["verdict"] == "advisory"
    assert result["failure_scope"]["failure_files"] == [
        "ios/BooksAndVocabTests/Unrelated.swift"
    ]


def test_run_check_blocks_in_scope_ios_failure_recovered_from_recorded_issue_location(
    tmp_path: Path,
) -> None:
    changed_file = tmp_path / "ios" / "BooksAndVocab" / "Changed.swift"
    changed_file.parent.mkdir(parents=True)
    changed_file.write_text("", encoding="utf-8")
    output = (
        _ios_failure_output(file=None)
        + "\n✘ Test testChanged() recorded an issue at Changed.swift:23:5: "
        "XCTAssertTrue failed\n"
    )

    result = coordinator._run_check(
        _ios_failure_check(output, ["ios/BooksAndVocab/Changed.swift"]),
        tmp_path,
    )

    assert result["status"] == "block"
    assert result["level"] == "block"
    assert result["failure_scope"]["verdict"] == "block"
    assert result["failure_scope"]["reason"] == "failure-in-changed-scope"
    assert result["failure_scope"]["failure_files"] == [
        "ios/BooksAndVocab/Changed.swift"
    ]


def test_run_check_blocks_ambiguous_recorded_issue_location(
    tmp_path: Path,
) -> None:
    first = tmp_path / "ios" / "First" / "Shared.swift"
    second = tmp_path / "ios" / "Second" / "Shared.swift"
    first.parent.mkdir(parents=True)
    second.parent.mkdir(parents=True)
    first.write_text("", encoding="utf-8")
    second.write_text("", encoding="utf-8")
    output = (
        _ios_failure_output(file=None)
        + "\n✘ Test testAmbiguous() recorded an issue at Shared.swift:4:2: "
        "XCTFail\n"
    )

    result = coordinator._run_check(
        _ios_failure_check(output, ["ios/BooksAndVocab/Changed.swift"]),
        tmp_path,
    )

    assert result["status"] == "block"
    assert result["level"] == "block"
    assert result["failure_scope"]["verdict"] == "block"
    assert result["failure_scope"]["reason"] == "failure-location-unknown"


def test_gate_does_not_block_on_failed_advisory_ios_check(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: object,
) -> None:
    monkeypatch.setattr(
        coordinator,
        "_changed_files",
        lambda worktree, base: ["ios/BooksAndVocab/Changed.swift"],
    )

    def fake_run_check(check: dict[str, object], worktree: Path) -> dict[str, object]:
        failed = check["name"] == "ios-tests"
        return {
            "name": check["name"],
            "cmd": check["cmd"],
            "cwd": check["cwd"],
            "status": "block" if failed else "pass",
            "level": "advisory" if failed else check["level"],
            "rc": 7 if failed else 0,
            "duration_s": 0.001,
            "output_tail": "scope-external-ios-failure" if failed else "",
            "failure_scope": (
                {
                    "verdict": "advisory",
                    "reason": "all-failures-outside-changed-scope",
                    "failure_files": ["ios/BooksAndVocabTests/UnrelatedTests.swift"],
                }
                if failed
                else None
            ),
        }

    monkeypatch.setattr(coordinator, "_run_check", fake_run_check)
    monkeypatch.setattr(
        coordinator,
        "_gate_record_path",
        lambda state, worktree: tmp_path / "state" / "gate.json",
    )
    monkeypatch.setattr(
        coordinator,
        "_git",
        lambda argv, cwd=coordinator.ROOT: (
            (0, "test-head") if argv == ["rev-parse", "HEAD"] else (0, "")
        ),
    )

    rc = coordinator.cmd_gate(
        Namespace(
            worktree=str(tmp_path),
            base="test-base",
            plan_only=False,
            state=None,
            json=True,
        )
    )

    payload = json.loads(capsys.readouterr().out)
    ios_result = next(
        item for item in payload["results"] if item["name"] == "ios-tests"
    )
    assert rc == coordinator.EXIT_OK
    assert payload["verdict"] == "pass"
    assert ios_result["status"] == "block"
    assert ios_result["level"] == "advisory"
    assert ios_result["output_tail"] == "scope-external-ios-failure"


@pytest.mark.parametrize(
    "failure_reason",
    [
        "failure-in-changed-scope",
        "failure-location-unknown",
    ],
)
def test_gate_blocks_in_scope_or_unknown_ios_failure(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: object,
    failure_reason: str,
) -> None:
    monkeypatch.setattr(
        coordinator,
        "_changed_files",
        lambda worktree, base: ["ios/BooksAndVocab/Changed.swift"],
    )

    def fake_run_check(check: dict[str, object], worktree: Path) -> dict[str, object]:
        failed = check["name"] == "ios-tests"
        return {
            "name": check["name"],
            "cmd": check["cmd"],
            "cwd": check["cwd"],
            "status": "block" if failed else "pass",
            "level": "block" if failed else check["level"],
            "rc": 7 if failed else 0,
            "duration_s": 0.001,
            "output_tail": "ios-failure" if failed else "",
            "failure_scope": (
                {"verdict": "block", "reason": failure_reason} if failed else None
            ),
        }

    monkeypatch.setattr(coordinator, "_run_check", fake_run_check)
    monkeypatch.setattr(
        coordinator,
        "_gate_record_path",
        lambda state, worktree: tmp_path / "state" / "gate.json",
    )
    monkeypatch.setattr(
        coordinator,
        "_git",
        lambda argv, cwd=coordinator.ROOT: (
            (0, "test-head") if argv == ["rev-parse", "HEAD"] else (0, "")
        ),
    )

    rc = coordinator.cmd_gate(
        Namespace(
            worktree=str(tmp_path),
            base="test-base",
            plan_only=False,
            state=None,
            json=True,
        )
    )

    payload = json.loads(capsys.readouterr().out)
    ios_result = next(
        item for item in payload["results"] if item["name"] == "ios-tests"
    )
    assert rc == coordinator.EXIT_BLOCK
    assert payload["verdict"] == "block"
    assert ios_result["status"] == "block"
    assert ios_result["level"] == "block"
    assert ios_result["failure_scope"]["reason"] == failure_reason


def test_gate_still_blocks_failed_block_level_check(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: object,
) -> None:
    monkeypatch.setattr(
        coordinator,
        "_changed_files",
        lambda worktree, base: ["ops/worktree_orchestrate.py"],
    )

    def fake_run_check(check: dict[str, object], worktree: Path) -> dict[str, object]:
        failed = check["name"] == "ops-tests"
        return {
            "name": check["name"],
            "cmd": check["cmd"],
            "cwd": check["cwd"],
            "status": "block" if failed else "pass",
            "level": check["level"],
            "rc": 9 if failed else 0,
            "duration_s": 0.001,
            "output_tail": "scope-relevant-ops-failure" if failed else "",
        }

    monkeypatch.setattr(coordinator, "_run_check", fake_run_check)
    monkeypatch.setattr(
        coordinator,
        "_gate_record_path",
        lambda state, worktree: tmp_path / "state" / "gate.json",
    )
    monkeypatch.setattr(
        coordinator,
        "_git",
        lambda argv, cwd=coordinator.ROOT: (
            (0, "test-head") if argv == ["rev-parse", "HEAD"] else (0, "")
        ),
    )

    rc = coordinator.cmd_gate(
        Namespace(
            worktree=str(tmp_path),
            base="test-base",
            plan_only=False,
            state=None,
            json=True,
        )
    )

    payload = json.loads(capsys.readouterr().out)
    ops_result = next(
        item for item in payload["results"] if item["name"] == "ops-tests"
    )
    assert rc == coordinator.EXIT_BLOCK
    assert payload["verdict"] == "block"
    assert ops_result["status"] == "block"
    assert ops_result["level"] == "block"
    assert ops_result["output_tail"] == "scope-relevant-ops-failure"


def test_gate_plan_adds_pinned_changed_python_format_check(tmp_path: Path) -> None:
    for relative_path in ("ops/zeta.py", "ops/alpha.py"):
        path = tmp_path / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("value = 1\n")

    plan = coordinator._plan_checks(
        ["ops/zeta.py", "ops/alpha.py", "ops/deleted.py", "README.md"],
        worktree=tmp_path,
    )

    assert [item for item in plan if item["name"] == "python-format-check"] == [
        {
            "name": "python-format-check",
            "kind": "shell",
            "cwd": ".",
            "cmd": [
                "uv",
                "run",
                "--no-project",
                "--python",
                "3.13",
                "--with",
                "ruff==0.16.3",
                "ruff",
                "format",
                "--check",
                "ops/alpha.py",
                "ops/zeta.py",
            ],
            "level": "block",
        }
    ]


def test_gate_plan_skips_python_format_check_without_existing_python(
    tmp_path: Path,
) -> None:
    plan = coordinator._plan_checks(["README.md", "ops/example.sh"], worktree=tmp_path)

    assert not any(item["name"] == "python-format-check" for item in plan)


def test_gate_plan_skips_deleted_shell_file_in_target_worktree(tmp_path: Path) -> None:
    plan = coordinator._plan_checks(
        [".claude/skills/app-debug/find-polluter.sh"], worktree=tmp_path
    )
    names = {item["name"] for item in plan}
    assert "shell-syntax:.claude/skills/app-debug/find-polluter.sh" not in names


def test_gate_plan_never_mutates_remote_or_integrates_branches() -> None:
    plan = coordinator._plan_checks(["ops/worktree_orchestrate.py"])
    commands = [" ".join(item["cmd"]) for item in plan]
    rendered = " ".join(commands)
    assert "git merge" not in rendered
    assert "git push" not in rendered


def test_rebase_preflight_compares_declared_scope_only_to_incoming_main(
    tmp_path: Path,
) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    scope = {
        "schema": "kg.worktree.scope.v1",
        "files": [{"path": "ios/issue_1033.py", "operation": "modify"}],
    }

    result = coordinator._rebase_preflight(
        repo, base="base", incoming_main="incoming-main", scope=scope
    )

    assert result["verdict"] == "pass"
    assert result["incoming_main_files"] == ["ops/incoming_main.py"]
    assert result["branch_files"] == ["ios/issue_1033.py"]
    assert result["collisions"] == []


def test_rebase_preflight_blocks_declared_scope_collision(tmp_path: Path) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    scope = {
        "schema": "kg.worktree.scope.v1",
        "files": [{"path": "ops/incoming_main.py", "operation": "modify"}],
    }

    result = coordinator._rebase_preflight(
        repo, base="base", incoming_main="incoming-main", scope=scope
    )

    assert result["verdict"] == "block"
    assert result["collisions"] == ["ops/incoming_main.py"]


def test_rebase_preflight_fails_closed_for_missing_refs(tmp_path: Path) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    scope = {
        "schema": "kg.worktree.scope.v1",
        "files": [{"path": "ios/issue_1033.py", "operation": "modify"}],
    }

    missing_base = coordinator._rebase_preflight(
        repo, base="missing-base", incoming_main="incoming-main", scope=scope
    )
    missing_incoming = coordinator._rebase_preflight(
        repo, base="base", incoming_main="missing-incoming", scope=scope
    )

    assert missing_base["verdict"] == "block"
    assert missing_base["reason"] == "base ref cannot be resolved"
    assert missing_incoming["verdict"] == "block"
    assert missing_incoming["reason"] == "incoming-main ref cannot be resolved"


def test_rebase_preflight_fails_closed_for_unstructured_scope(tmp_path: Path) -> None:
    repo = _synthetic_rebase_refs(tmp_path)

    result = coordinator._rebase_preflight(
        repo, base="base", incoming_main="incoming-main", scope="ops/incoming_main.py"
    )

    assert result["verdict"] == "block"
    assert result["reason"] == "declared Scope is unstructured or invalid"


def test_preflight_uses_active_declared_scope_for_rebase_collision_check(
    tmp_path: Path, capsys: object
) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    scope = {
        "schema": "kg.worktree.scope.v1",
        "files": [{"path": "ios/issue_1033.py", "operation": "modify"}],
    }
    state_path = tmp_path / "worktree_registry.json"
    state_path.write_text(
        json.dumps(
            {
                "schema": "kg.worktree.registry.v2",
                "records": [
                    {
                        "branch": "solver",
                        "path": str(repo),
                        "status": "active",
                        "scope": scope,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    rc = coordinator.main(
        [
            "preflight",
            "--state",
            str(state_path),
            "--worktree",
            str(repo),
            "--base",
            "base",
            "--incoming-main",
            "incoming-main",
            "--json",
        ]
    )

    payload = json.loads(capsys.readouterr().out)
    assert rc == 0
    assert payload["verdict"] == "pass"
    assert payload["scope_files"] == ["ios/issue_1033.py"]
    assert payload["incoming_main_files"] == ["ops/incoming_main.py"]
    assert payload["branch_files"] == ["ios/issue_1033.py"]


def test_adopt_prefers_active_record_over_terminal_duplicate(
    tmp_path: Path, capsys: object
) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    scope = {
        "schema": "kg.worktree.scope.v1",
        "files": [{"path": "ios/issue_1033.py", "operation": "modify"}],
    }
    state_path = tmp_path / "worktree_registry.json"
    terminal = {
        "branch": "solver",
        "path": str(repo),
        "status": "abandoned",
        "base": "old-base",
        "scope": scope,
    }
    active = {
        "branch": "solver",
        "path": str(repo),
        "status": "active",
        "base": "base",
        "scope": scope,
        "claim_generation": 0,
    }
    state_path.write_text(
        json.dumps(
            {
                "schema": "kg.worktree.registry.v2",
                "records": [terminal, active],
            }
        ),
        encoding="utf-8",
    )

    rc = coordinator.main(
        [
            "adopt",
            "--state",
            str(state_path),
            "--worktree",
            str(repo),
            "--intent",
            "reanchor worker",
            "--base",
            "base",
            "--external-id",
            "ISSUE-1141",
            "--scope",
            json.dumps(scope),
            "--codex-thread-id",
            "worker-thread",
            "--delegated",
            "--json",
        ]
    )

    json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    matches = [record for record in state["records"] if record["branch"] == "solver"]
    assert rc == coordinator.EXIT_OK
    assert len(matches) == 2
    assert sum(record["status"] == "active" for record in matches) == 1
    assert (
        next(record for record in matches if record["status"] == "active")[
            "claim_generation"
        ]
        == 1
    )


def _handoff_fixture(tmp_path: Path) -> tuple[Path, Path, str, str]:
    repo = tmp_path / "handoff-repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test User")
    _commit(repo, "README.md", "base\n", "base")
    base_sha = _git(repo, "rev-parse", "HEAD")
    _git(repo, "checkout", "-q", "-b", "worker")
    _commit(repo, "ops/handoff_change.py", "change\n", "worker change")
    tip_sha = _git(repo, "rev-parse", "HEAD")
    handed_back_at = "2026-08-21T00:00:00Z"
    record = {
        "branch": "worker",
        "path": str(repo),
        "status": coordinator.registry.STATUS_ACTIVE,
        "external_ids": ["USER-20260821-im-handback-package"],
        "scope": {
            "schema": "kg.worktree.scope.v1",
            "files": [{"path": "ops/handoff_change.py", "operation": "modify"}],
        },
        "base": base_sha,
        "base_sha": base_sha,
        "claim_generation": 0,
        "handed_back_at": handed_back_at,
        "handed_back_sha": tip_sha,
    }
    record["handback_claim_generation"] = 0
    record["handback_seal"] = coordinator.registry._seal_with_digest(
        coordinator.registry._seal_body(
            record,
            base_sha=base_sha,
            tip_sha=tip_sha,
            outcomes=[{"id": "USER-20260821-im-handback-package", "status": "passed"}],
            handed_back_at=handed_back_at,
        )
    )
    state_path = tmp_path / "worktree_registry.json"
    coordinator.registry.save_state(
        state_path, {"schema": coordinator.registry.SCHEMA, "records": [record]}
    )
    gate_path = coordinator._gate_record_path(str(state_path), repo)
    gate_path.parent.mkdir(parents=True, exist_ok=True)
    gate_path.write_text(
        json.dumps(
            {
                "schema": coordinator.GATE_SCHEMA,
                "worktree": str(repo),
                "base": base_sha,
                "files": ["ops/handoff_change.py"],
                "verdict": "pass",
                "head": tip_sha,
                "results": [{"name": "git-diff-check", "status": "pass", "rc": 0}],
            }
        ),
        encoding="utf-8",
    )
    return repo, state_path, base_sha, tip_sha


def test_handoff_package_emits_exact_im_payload(tmp_path: Path, capsys: object) -> None:
    repo, state_path, base_sha, tip_sha = _handoff_fixture(tmp_path)

    rc = coordinator.main(
        [
            "handoff",
            "--state",
            str(state_path),
            "--worktree",
            str(repo),
            "--incoming-main",
            base_sha,
            "--json",
        ]
    )

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_OK
    assert payload["schema"] == "kg.worktree.handoff.v1"
    assert payload["status"] == "ready-for-im"
    assert payload["base_sha"] == base_sha
    assert payload["tip_sha"] == tip_sha
    assert payload["observed_main_sha"] == base_sha
    assert payload["scope"] == ["ops/handoff_change.py"]
    assert payload["handback_seal"]["tip_sha"] == tip_sha
    assert payload["validation"]["gate"]["verdict"] == "pass"


def test_handoff_package_preserves_historical_base_when_main_advanced(
    tmp_path: Path, capsys: object
) -> None:
    repo, state_path, base_sha, _ = _handoff_fixture(tmp_path)
    _git(repo, "checkout", "-q", "-b", "incoming-main", base_sha)
    _commit(repo, "main_only.py", "advanced\n", "advance main")
    incoming_sha = _git(repo, "rev-parse", "HEAD")
    _git(repo, "checkout", "-q", "worker")

    rc = coordinator.main(
        [
            "handoff",
            "--state",
            str(state_path),
            "--worktree",
            str(repo),
            "--incoming-main",
            incoming_sha,
            "--json",
        ]
    )

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_OK
    assert payload["status"] == "ready-for-im"
    assert payload["observed_main_sha"] == incoming_sha
    assert payload["base_sha"] == base_sha


def test_handoff_package_blocks_when_base_is_not_in_incoming_main_history(
    tmp_path: Path, capsys: object
) -> None:
    repo, state_path, _, _ = _handoff_fixture(tmp_path)
    _git(repo, "checkout", "-q", "--orphan", "unrelated-main")
    _git(repo, "rm", "-q", "-rf", ".")
    _commit(repo, "unrelated.txt", "unrelated\n", "unrelated main")
    incoming_sha = _git(repo, "rev-parse", "HEAD")
    _git(repo, "checkout", "-q", "worker")

    rc = coordinator.main(
        [
            "handoff",
            "--state",
            str(state_path),
            "--worktree",
            str(repo),
            "--incoming-main",
            incoming_sha,
            "--json",
        ]
    )

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert payload["status"] == "blocked"
    assert "not an ancestor" in payload["reason"]


def test_handoff_package_blocks_when_gate_base_is_stale(
    tmp_path: Path, capsys: object
) -> None:
    repo, state_path, base_sha, _ = _handoff_fixture(tmp_path)
    gate_path = coordinator._gate_record_path(str(state_path), repo)
    gate = json.loads(gate_path.read_text(encoding="utf-8"))
    gate["base"] = "stale-base"
    gate_path.write_text(json.dumps(gate), encoding="utf-8")

    rc = coordinator.main(
        [
            "handoff",
            "--state",
            str(state_path),
            "--worktree",
            str(repo),
            "--incoming-main",
            base_sha,
            "--json",
        ]
    )

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert payload["status"] == "blocked"
    assert payload["reason"] == "local gate base does not equal hand-back base"


def _reanchor_fixture(
    tmp_path: Path,
    *,
    conflict: bool = False,
    external_ids: list[str] | None = None,
) -> tuple[Path, Path, Path, dict[str, object]]:
    remote = tmp_path / "remote.git"
    _git(tmp_path, "init", "-q", "--bare", str(remote))
    seed = tmp_path / "seed"
    seed.mkdir()
    _git(seed, "init", "-q", "-b", "main")
    _git(seed, "config", "user.email", "test@example.com")
    _git(seed, "config", "user.name", "Test User")
    _commit(seed, "shared.txt", "base\n", "base")
    base_sha = _git(seed, "rev-parse", "HEAD")
    _git(seed, "remote", "add", "origin", str(remote))
    _git(seed, "push", "-q", "origin", "main")
    _git(seed, "checkout", "-q", "-b", "feat/exact-pr", base_sha)
    if conflict:
        _commit(seed, "shared.txt", "branch\n", "branch change")
        scope = _scope_for("shared.txt")
    else:
        _commit(seed, "ops/reanchor_change.py", "branch\n", "branch change")
        scope = {
            "schema": "kg.worktree.scope.v1",
            "files": [{"path": "ops/reanchor_change.py", "operation": "add"}],
        }
    remote_head = _git(seed, "rev-parse", "HEAD")
    _git(seed, "push", "-q", "origin", "feat/exact-pr")
    _git(seed, "checkout", "-q", "main")
    if conflict:
        _commit(seed, "shared.txt", "main\n", "advance main")
    else:
        _commit(seed, "main_only.txt", "main\n", "advance main")
    live_main = _git(seed, "rev-parse", "HEAD")
    _git(seed, "push", "-q", "origin", "main")

    repo = tmp_path / "control"
    _git(tmp_path, "clone", "-q", "--branch", "main", str(remote), str(repo))
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test User")
    record: dict[str, object] = {
        "branch": "feat/exact-pr",
        "path": str(tmp_path / "released-worktree"),
        "intent": "same-owner merge-front reanchor",
        "base": base_sha,
        "base_sha": base_sha,
        "status": "published",
        "external_ids": (
            ["DIRECT-REANCHOR-1"] if external_ids is None else external_ids
        ),
        "scope": scope,
        "codex_thread_id": "owner-thread-1",
        "delegated": True,
        "claim_generation": 4,
        "handed_back_at": "2026-08-21T00:00:00Z",
        "handed_back_sha": remote_head,
        "handback_claim_generation": 4,
    }
    record["handback_seal"] = coordinator.registry._seal_with_digest(
        coordinator.registry._seal_body(
            record,
            base_sha=base_sha,
            tip_sha=remote_head,
            outcomes=[{"name": "focused", "status": "success"}],
            handed_back_at="2026-08-21T00:00:00Z",
            origin_main_sha=base_sha,
        )
    )
    state_path = tmp_path / "worktree_registry.json"
    coordinator.registry.save_state(
        state_path,
        {"schema": coordinator.registry.SCHEMA, "records": [record]},
    )
    target = tmp_path / "released-worktree"
    expected = {
        "base_sha": base_sha,
        "remote_head": remote_head,
        "live_main": live_main,
        "scope": scope,
    }
    return repo, state_path, target, expected


def _reanchor_argv(
    repo: Path,
    state_path: Path,
    target: Path,
    expected: dict[str, object],
    *,
    owner: str = "owner-thread-1",
    lane: str = "DIRECT-REANCHOR-1",
    preserve_conflict: bool = False,
) -> list[str]:
    argv = [
        "reanchor",
        "--repo",
        str(repo),
        "--state",
        str(state_path),
        "--merge-front-pr",
        "42",
        "--lane",
        lane,
        "--branch",
        "feat/exact-pr",
        "--owner-thread-id",
        owner,
        "--claim-generation",
        "4",
        "--expected-remote-head",
        str(expected["remote_head"]),
        "--live-main",
        str(expected["live_main"]),
        "--path",
        str(target),
        "--json",
    ]
    if preserve_conflict:
        argv.append("--preserve-conflict")
    return argv


def _reanchor_handback_argv(
    repo: Path,
    state_path: Path,
    target: Path,
    expected: dict[str, object],
    *,
    owner: str = "owner-thread-1",
    generation: int = 4,
) -> list[str]:
    return [
        "reanchor-handback",
        "--repo",
        str(repo),
        "--state",
        str(state_path),
        "--lane",
        "DIRECT-REANCHOR-1",
        "--branch",
        "feat/exact-pr",
        "--owner-thread-id",
        owner,
        "--claim-generation",
        str(generation),
        "--expected-head-sha",
        str(expected["remote_head"]),
        "--live-main",
        str(expected["live_main"]),
        "--path",
        str(target),
        "--json",
    ]


def _prepare_reanchor_handback(
    tmp_path: Path,
    *,
    remove_remote: bool = True,
) -> tuple[Path, Path, Path, dict[str, object]]:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    if remove_remote:
        remote = tmp_path / "remote.git"
        _git(remote, "update-ref", "-d", "refs/heads/feat/exact-pr")
        _git(repo, "update-ref", "-d", "refs/remotes/origin/feat/exact-pr")
    _git(
        repo,
        "worktree",
        "add",
        "-b",
        "feat/exact-pr",
        str(target),
        str(expected["remote_head"]),
    )
    state = coordinator.registry.load_state(state_path)
    state["records"][0]["status"] = coordinator.registry.STATUS_ACTIVE
    state["records"][0]["path"] = str(target)
    coordinator.registry.save_state(state_path, state)
    return repo, state_path, target, expected


def test_reanchor_recreates_exact_remote_branch_for_same_owner(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    original = coordinator.registry.load_state(state_path)["records"][0]

    rc = coordinator.main(_reanchor_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    records = state["records"]
    old = records[0]
    active = [item for item in state["records"] if item["status"] == "active"]
    assert rc == coordinator.EXIT_OK
    assert payload["status"] == "ready-for-owner-tests"
    assert payload["merge_front_pr"] == 42
    assert _git(target, "branch", "--show-current") == "feat/exact-pr"
    assert (
        _git(target, "merge-base", "--is-ancestor", str(expected["live_main"]), "HEAD")
        == ""
    )
    assert (
        _git(repo, "ls-remote", "origin", "refs/heads/feat/exact-pr").split()[0]
        == expected["remote_head"]
    )
    assert [item["status"] for item in records] == ["abandoned", "active"]
    assert [item["claim_generation"] for item in records] == [4, 5]
    assert old["resolved_at"] is not None
    assert old["handed_back_sha"] == expected["remote_head"]
    assert old["handed_back_at"] == original["handed_back_at"]
    assert old["handback_claim_generation"] == original["handback_claim_generation"]
    assert old["handback_seal"] == original["handback_seal"]
    assert len(active) == 1
    assert active[0]["codex_thread_id"] == "owner-thread-1"
    assert active[0]["claim_generation"] == 5
    assert active[0]["base_sha"] == expected["live_main"]
    assert active[0]["scope"] == expected["scope"]
    assert active[0]["handed_back_sha"] is None


def test_reanchor_accepts_active_typed_handback_for_same_owner(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    state = coordinator.registry.load_state(state_path)
    state["records"][0]["status"] = coordinator.registry.STATUS_ACTIVE
    coordinator.registry.save_state(state_path, state)

    rc = coordinator.main(_reanchor_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    old, active = state["records"]
    assert rc == coordinator.EXIT_OK
    assert payload["status"] == "ready-for-owner-tests"
    assert old["status"] == "abandoned"
    assert old["handback_seal"]
    assert active["status"] == "active"
    assert active["claim_generation"] == 5
    assert active["base_sha"] == expected["live_main"]
    assert active["scope"] == old["scope"]


def test_reanchor_rejects_active_claim_without_typed_handback(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    state = coordinator.registry.load_state(state_path)
    state["records"][0]["status"] = coordinator.registry.STATUS_ACTIVE
    state["records"][0].pop("handback_seal")
    coordinator.registry.save_state(state_path, state)

    rc = coordinator.main(_reanchor_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    current = coordinator.registry.load_state(state_path)["records"]
    assert rc == coordinator.EXIT_BLOCK
    assert "typed hand-back" in payload["reason"]
    assert len(current) == 1
    assert current[0]["status"] == coordinator.registry.STATUS_ACTIVE
    assert not target.exists()


def test_reanchor_active_claim_preserves_owner_and_scope_guards(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    state = coordinator.registry.load_state(state_path)
    state["records"][0]["status"] = coordinator.registry.STATUS_ACTIVE
    state["records"][0]["scope"] = _scope_for("ops/other.py")
    coordinator.registry.save_state(state_path, state)

    rc = coordinator.main(_reanchor_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    current = coordinator.registry.load_state(state_path)["records"]
    assert rc == coordinator.EXIT_BLOCK
    assert "Scope" in payload["reason"]
    assert len(current) == 1
    assert current[0]["status"] == coordinator.registry.STATUS_ACTIVE
    assert not target.exists()


@pytest.mark.parametrize("mismatch", ("remote", "pr"))
def test_reanchor_active_claim_preserves_remote_and_pr_guards(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    mismatch: str,
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    state = coordinator.registry.load_state(state_path)
    state["records"][0]["status"] = coordinator.registry.STATUS_ACTIVE
    coordinator.registry.save_state(state_path, state)
    argv = _reanchor_argv(repo, state_path, target, expected)
    if mismatch == "remote":
        argv[argv.index("--expected-remote-head") + 1] = "a" * 40
    else:
        argv[argv.index("--merge-front-pr") + 1] = "41"

    rc = coordinator.main(argv)

    payload = json.loads(capsys.readouterr().out)
    current = coordinator.registry.load_state(state_path)["records"]
    assert rc == coordinator.EXIT_BLOCK
    assert payload["reason"]
    assert len(current) == 1
    assert current[0]["status"] == coordinator.registry.STATUS_ACTIVE
    assert not target.exists()


def test_reanchor_accepts_direct_assignment_with_branch_lane_fallback(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(
        tmp_path,
        external_ids=[],
    )

    rc = coordinator.main(
        _reanchor_argv(
            repo,
            state_path,
            target,
            expected,
            lane="feat/exact-pr",
        )
    )

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_OK
    assert payload["status"] == "ready-for-owner-tests"
    assert [item["status"] for item in state["records"]] == [
        "abandoned",
        "active",
    ]
    assert state["records"][1]["external_ids"] == []


def test_reanchor_machine_proof_rejects_non_front_before_local_mutation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)

    class NonFrontGitHub(_FixtureRecoveryGitHub):
        def list_open_pull_requests(self) -> PullRequestInventory:
            candidate = self._pull_request()
            earlier = PullRequestSnapshot(
                number=41,
                url="https://example.test/pull/41",
                branch="feat/earlier",
                base_sha=candidate.base_sha,
                head_sha=candidate.head_sha,
                state="OPEN",
                draft=False,
                mergeable=True,
                node_id="PR_41",
                body=_fixture_receipt_body(
                    number=41,
                    branch="feat/earlier",
                    base=candidate.base_sha,
                    head=candidate.head_sha,
                ),
            )
            return PullRequestInventory((candidate, earlier))

        def required_check_snapshot(self, number: int) -> CheckSnapshot:
            return CheckSnapshot(
                status=CheckStatus.SUCCESS,
                head_sha=self._pull_request().head_sha,
                observed_at=datetime(2026, 8, 22, tzinfo=UTC),
                names=("required",),
            )

        def merge_queue_entry_snapshot(self, pull_request_id: str) -> None:
            assert pull_request_id in {"PR_41", "PR_42"}

    monkeypatch.setattr(
        lifecycle_proof,
        "build_github",
        lambda repo, *, operation: NonFrontGitHub(repo, operation=operation),
    )

    rc = coordinator.main(_reanchor_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_BLOCK
    assert "deterministic merge-front" in payload["reason"]
    assert [item["status"] for item in state["records"]] == ["published"]
    assert not target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""


def test_reanchor_registry_save_failure_leaves_original_published(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)

    def fail_save(*args: object, **kwargs: object) -> None:
        raise OSError("injected registry save failure")

    monkeypatch.setattr(registry_ops.registry, "save_state", fail_save)

    rc = coordinator.main(_reanchor_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_BLOCK
    assert "registry save failure" in payload["reason"]
    assert [item["status"] for item in state["records"]] == ["published"]
    assert state["records"][0].get("resolved_at") is None
    assert not target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""


def test_reanchor_stale_remote_cas_compensates_local_assets(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    real_verify = git_ops.verify_remote_cas
    calls = 0

    def fail_final_cas(*args: object, **kwargs: object) -> None:
        nonlocal calls
        calls += 1
        if calls == 3:
            raise ReanchorRefused("remote branch changed during reanchor")
        real_verify(*args, **kwargs)

    monkeypatch.setattr(git_ops, "verify_remote_cas", fail_final_cas)

    rc = coordinator.main(_reanchor_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_BLOCK
    assert "remote branch changed" in payload["reason"]
    assert not target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""
    assert all(item["status"] != "active" for item in state["records"])


@pytest.mark.parametrize("status", ("published", "active"))
def test_reanchor_rejects_wrong_owner_before_git_mutation(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    status: str,
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    state = coordinator.registry.load_state(state_path)
    state["records"][0]["status"] = status
    coordinator.registry.save_state(state_path, state)

    rc = coordinator.main(
        _reanchor_argv(repo, state_path, target, expected, owner="other-owner")
    )

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert "owner" in payload["reason"]
    assert not target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""


def test_reanchor_rejects_scope_collision_without_creating_worktree(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    state = coordinator.registry.load_state(state_path)
    state["records"].append(
        {
            "branch": "feat/other",
            "path": str(tmp_path / "other"),
            "intent": "other owner",
            "base": str(expected["live_main"]),
            "base_sha": str(expected["live_main"]),
            "status": "active",
            "external_ids": ["DIRECT-OTHER"],
            "scope": expected["scope"],
            "codex_thread_id": "other-owner",
            "claim_generation": 0,
        }
    )
    coordinator.registry.save_state(state_path, state)

    rc = coordinator.main(_reanchor_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert "Scope" in payload["reason"] or "owned" in payload["reason"]
    assert not target.exists()


def test_reanchor_conflict_aborts_and_removes_only_created_local_assets(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path, conflict=True)

    rc = coordinator.main(_reanchor_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_BLOCK
    assert "conflict" in payload["reason"]
    assert payload["compensation"]["complete"] is True
    assert not target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""
    assert (
        _git(repo, "ls-remote", "origin", "refs/heads/feat/exact-pr").split()[0]
        == expected["remote_head"]
    )
    assert all(item["status"] != "active" for item in state["records"])


def test_reanchor_conflict_can_remain_registered_for_original_owner(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path, conflict=True)

    rc = coordinator.main(
        _reanchor_argv(repo, state_path, target, expected, preserve_conflict=True)
    )

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    active = [item for item in state["records"] if item["status"] == "active"]
    assert rc == coordinator.EXIT_BLOCK
    assert payload["status"] == "owner-action-required"
    assert payload["reason"] == "rebase conflict preserved for the original owner"
    assert target.exists()
    assert "UU shared.txt" in _git(target, "status", "--porcelain")
    assert len(active) == 1
    assert active[0]["claim_generation"] == 5
    assert active[0]["base_sha"] == expected["live_main"]
    assert "handback_seal" not in active[0]
    assert (
        _git(repo, "ls-remote", "origin", "refs/heads/feat/exact-pr").split()[0]
        == expected["remote_head"]
    )


def test_reanchor_handback_reanchors_owner_worktree_without_a_pull_request(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(coordinator, "_branch_pull_requests", lambda *_args: ())
    repo, state_path, target, expected = _prepare_reanchor_handback(tmp_path)

    rc = coordinator.main(_reanchor_handback_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    records = coordinator.registry.load_state(state_path)["records"]
    active = [item for item in records if item["status"] == "active"]
    assert rc == coordinator.EXIT_OK
    assert payload["action"] == "reanchor-handback"
    assert payload["status"] == "ready-for-owner-tests"
    assert payload["previous_head"] == expected["remote_head"]
    assert payload["base_sha"] == expected["live_main"]
    assert _git(target, "branch", "--show-current") == "feat/exact-pr"
    assert (
        _git(target, "merge-base", "--is-ancestor", str(expected["live_main"]), "HEAD")
        == ""
    )
    assert [item["status"] for item in records] == ["abandoned", "active"]
    assert active[0]["claim_generation"] == 5
    assert active[0]["base_sha"] == expected["live_main"]
    assert active[0]["handed_back_sha"] is None
    assert active[0].get("handback_seal") is None


def test_reanchor_handback_rejects_stale_supplied_live_main_before_rebase(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(coordinator, "_branch_pull_requests", lambda *_args: ())
    repo, state_path, target, expected = _prepare_reanchor_handback(tmp_path)
    argv = _reanchor_handback_argv(repo, state_path, target, expected)
    argv[argv.index("--live-main") + 1] = str(expected["base_sha"])

    rc = coordinator.main(argv)

    payload = json.loads(capsys.readouterr().out)
    record = coordinator.registry.load_state(state_path)["records"][0]
    assert rc == coordinator.EXIT_BLOCK
    assert "remote origin/main" in payload["reason"]
    assert payload["live_main"] == expected["base_sha"]
    assert payload["remote_main"] == expected["live_main"]
    assert _git(target, "rev-parse", "HEAD") == expected["remote_head"]
    assert record["status"] == coordinator.registry.STATUS_ACTIVE
    assert record["claim_generation"] == 4


def test_reanchor_handback_rolls_back_when_remote_main_changes_before_registry_update(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(coordinator, "_branch_pull_requests", lambda *_args: ())
    repo, state_path, target, expected = _prepare_reanchor_handback(tmp_path)
    remote_main_reads = iter((str(expected["live_main"]), "f" * 40))
    monkeypatch.setattr(
        coordinator,
        "_remote_main_sha",
        lambda _repo: next(remote_main_reads),
    )

    rc = coordinator.main(_reanchor_handback_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    record = coordinator.registry.load_state(state_path)["records"][0]
    assert rc == coordinator.EXIT_BLOCK
    assert payload["reason"] == "remote origin/main changed during reanchor"
    assert payload["live_main"] == expected["live_main"]
    assert payload["remote_main"] == "f" * 40
    assert _git(target, "rev-parse", "HEAD") == expected["remote_head"]
    assert record["status"] == coordinator.registry.STATUS_ACTIVE
    assert record["claim_generation"] == 4
    assert record["base_sha"] == expected["base_sha"]


def test_reanchor_handback_rejects_wrong_owner_before_rebase(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _prepare_reanchor_handback(tmp_path)

    rc = coordinator.main(
        _reanchor_handback_argv(repo, state_path, target, expected, owner="other-owner")
    )

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert "owner" in payload["reason"]
    assert _git(target, "rev-parse", "HEAD") == expected["remote_head"]


def test_reanchor_handback_rejects_existing_remote_branch_before_rebase(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _prepare_reanchor_handback(
        tmp_path, remove_remote=False
    )

    rc = coordinator.main(_reanchor_handback_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    record = coordinator.registry.load_state(state_path)["records"][0]
    assert rc == coordinator.EXIT_BLOCK
    assert "remote branch" in payload["reason"]
    assert _git(target, "rev-parse", "HEAD") == expected["remote_head"]
    assert record["status"] == coordinator.registry.STATUS_ACTIVE
    assert record["claim_generation"] == 4


def test_reanchor_handback_rejects_existing_pr_before_rebase(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(coordinator, "_branch_pull_requests", lambda *_args: (42,))
    repo, state_path, target, expected = _prepare_reanchor_handback(tmp_path)

    rc = coordinator.main(_reanchor_handback_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert "no branch PR" in payload["reason"]
    assert payload["pull_requests"] == [42]
    assert _git(target, "rev-parse", "HEAD") == expected["remote_head"]


def test_reanchor_handback_reports_declared_and_observed_scope_mismatch(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(coordinator, "_branch_pull_requests", lambda *_args: ())
    repo, state_path, target, expected = _prepare_reanchor_handback(tmp_path)
    state = coordinator.registry.load_state(state_path)
    state["records"][0]["scope"] = _scope_for("ops/declared.py")
    coordinator.registry.save_state(state_path, state)

    rc = coordinator.main(_reanchor_handback_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert payload["reason"] == "stored hand-back differs from the exact declared Scope"
    assert payload["declared_scope"] == [["ops/declared.py", "modify"]]
    assert payload["observed_scope"] == [["ops/reanchor_change.py", "add"]]
    assert _git(target, "rev-parse", "HEAD") == expected["remote_head"]


def test_reanchor_handback_rejects_incoming_scope_collision_before_rebase(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(coordinator, "_branch_pull_requests", lambda *_args: ())
    repo, state_path, target, expected = _prepare_reanchor_handback(tmp_path)
    _commit(repo, "ops/reanchor_change.py", "main\n", "main changes declared scope")
    _git(repo, "push", "-q", "origin", "main")
    expected["live_main"] = _git(repo, "rev-parse", "HEAD")

    rc = coordinator.main(_reanchor_handback_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert "collide" in payload["reason"]
    assert payload["collisions"] == ["ops/reanchor_change.py"]
    assert _git(target, "rev-parse", "HEAD") == expected["remote_head"]


def test_reanchor_handback_rolls_back_when_registry_update_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(coordinator, "_branch_pull_requests", lambda *_args: ())

    def fail_register(**_kwargs: object) -> None:
        raise ReanchorRefused("injected registry update failure")

    monkeypatch.setattr(
        coordinator.reanchor_registry_ops,
        "register_active",
        fail_register,
    )
    repo, state_path, target, expected = _prepare_reanchor_handback(tmp_path)

    rc = coordinator.main(_reanchor_handback_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    record = coordinator.registry.load_state(state_path)["records"][0]
    assert rc == coordinator.EXIT_BLOCK
    assert payload["reason"] == "injected registry update failure"
    assert _git(target, "rev-parse", "HEAD") == expected["remote_head"]
    assert record["status"] == coordinator.registry.STATUS_ACTIVE
    assert record["claim_generation"] == 4
    assert record["base_sha"] == expected["base_sha"]


def _resume_argv(
    repo: Path,
    state_path: Path,
    target: Path,
    expected: dict[str, object],
    *,
    owner: str = "owner-thread-1",
    generation: int = 4,
    remote_head: str | None = None,
    previous_handback: str | None = None,
) -> list[str]:
    argv = [
        "resume-published",
        "--repo",
        str(repo),
        "--state",
        str(state_path),
        "--lane",
        "DIRECT-REANCHOR-1",
        "--branch",
        "feat/exact-pr",
        "--owner-thread-id",
        owner,
        "--claim-generation",
        str(generation),
        "--expected-remote-head",
        remote_head or str(expected["remote_head"]),
        "--path",
        str(target),
        "--json",
    ]
    if previous_handback is not None:
        argv.extend(["--previous-handback", previous_handback])
    return argv


def test_resume_published_recreates_exact_head_and_preserves_recorded_base(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    original = coordinator.registry.load_state(state_path)["records"][0]

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    old, active = state["records"]
    assert rc == coordinator.EXIT_OK
    assert payload["schema"] == "kg.worktree.resume-published.v1"
    assert payload["status"] == "ready-for-owner-fix"
    assert payload["next_action"]
    assert payload["not_performed"] == ["tests", "hand-back", "push", "force-push"]
    assert _git(target, "branch", "--show-current") == original["branch"]
    assert _git(target, "rev-parse", "HEAD") == expected["remote_head"]
    assert old["status"] == "abandoned"
    assert old["resolved_at"] is not None
    assert old["handback_seal"] == original["handback_seal"]
    assert active["status"] == "active"
    assert active["claim_generation"] == 5
    assert active["base"] == original["base"]
    assert active["base_sha"] == original["base_sha"]
    assert active["scope"] == original["scope"]
    assert active["external_ids"] == original["external_ids"]
    assert active["codex_thread_id"] == original["codex_thread_id"]
    assert active["branch"] == original["branch"]
    assert active["handed_back_sha"] is None


def test_resume_published_rejects_requested_path_drift_before_mutation(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, _recorded_target, expected = _reanchor_fixture(tmp_path)
    wrong_target = tmp_path / "wrong-resume-target"
    before = coordinator.registry.load_state(state_path)
    original_path = Path(str(before["records"][0]["path"])).resolve()

    rc = coordinator.main(_resume_argv(repo, state_path, wrong_target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_BLOCK
    assert (
        payload["reason"] == "resume target path differs from exact original claim path"
    )
    assert payload["recorded_path"] == str(original_path)
    assert payload["requested_path"] == str(wrong_target.resolve())
    assert state == before
    assert not wrong_target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""


def test_resume_published_accepts_legacy_record_base_without_base_sha(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    state = coordinator.registry.load_state(state_path)
    state["records"][0].pop("base_sha")
    coordinator.registry.save_state(state_path, state)

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_OK
    assert payload["status"] == "ready-for-owner-fix"
    assert state["records"][1]["base_sha"] == expected["base_sha"]


def test_resume_published_refreshes_an_owner_advanced_published_head(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    _git(repo, "checkout", "-q", "-b", "owner-fix", str(expected["remote_head"]))
    _commit(repo, "ops/reanchor_change.py", "owner fix\n", "owner fix")
    advanced_head = _git(repo, "rev-parse", "HEAD")
    _git(repo, "push", "-q", "origin", "HEAD:refs/heads/feat/exact-pr")

    rc = coordinator.main(
        _resume_argv(
            repo,
            state_path,
            target,
            expected,
            remote_head=advanced_head,
            previous_handback=str(expected["remote_head"]),
        )
    )

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_OK
    assert payload["status"] == "ready-for-owner-fix"
    assert _git(target, "rev-parse", "HEAD") == advanced_head
    assert state["records"][0]["status"] == "abandoned"
    assert state["records"][1]["status"] == "active"
    assert state["records"][1]["claim_generation"] == 5
    assert state["records"][1]["handed_back_sha"] is None


def test_resume_published_compensates_when_required_failure_clears_midflight(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)

    class ClearingFailureGitHub(_FixtureRecoveryGitHub):
        required_reads = 0

        def required_check_snapshot(self, number: int) -> CheckSnapshot:
            self.required_reads += 1
            return CheckSnapshot(
                status=(
                    CheckStatus.FAILURE
                    if self.required_reads == 1
                    else CheckStatus.SUCCESS
                ),
                head_sha=self._pull_request().head_sha,
                observed_at=datetime(2026, 8, 22, tzinfo=UTC),
                names=("required",),
            )

    monkeypatch.setattr(
        lifecycle_proof,
        "build_github",
        lambda repo, *, operation: ClearingFailureGitHub(repo, operation=operation),
    )

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_BLOCK
    assert "required code failure" in payload["reason"]
    assert payload["compensation"]["complete"] is True
    assert [item["status"] for item in state["records"]] == ["published"]
    assert not target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""


@pytest.mark.parametrize(
    ("overrides", "reason_fragment"),
    [
        ({"owner": "other-owner"}, "owner"),
        ({"generation": 3}, "selector"),
        ({"remote_head": "0" * 40}, "hand-back"),
    ],
)
def test_resume_published_rejects_owner_generation_and_head_mismatch(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    overrides: dict[str, object],
    reason_fragment: str,
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected, **overrides))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_BLOCK
    assert reason_fragment in payload["reason"]
    assert [item["status"] for item in state["records"]] == ["published"]
    assert not target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""


@pytest.mark.parametrize("existing_asset", ["target", "branch"])
def test_resume_published_rejects_existing_target_or_local_branch(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    existing_asset: str,
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    if existing_asset == "target":
        target.mkdir()
    else:
        _git(repo, "branch", "feat/exact-pr", str(expected["remote_head"]))

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_BLOCK
    assert any(word in payload["reason"] for word in ("new", "exist", "duplicate"))
    assert [item["status"] for item in state["records"]] == ["published"]


def test_resume_published_rejects_remote_branch_drift(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    remote = Path(_git(repo, "remote", "get-url", "origin"))
    _git(
        tmp_path,
        "--git-dir",
        str(remote),
        "update-ref",
        "refs/heads/feat/exact-pr",
        str(expected["live_main"]),
    )

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert "remote branch changed" in payload["reason"]
    assert not target.exists()


def test_resume_published_save_failure_compensates_only_new_local_assets(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)

    def fail_save(*args: object, **kwargs: object) -> None:
        raise OSError("injected resume registry save failure")

    monkeypatch.setattr(registry_ops.registry, "save_state", fail_save)

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    remote_readback = _git(repo, "ls-remote", "origin", "refs/heads/feat/exact-pr")
    assert rc == coordinator.EXIT_BLOCK
    assert "registry save failure" in payload["reason"]
    assert payload["compensation"]["complete"] is True
    assert [item["status"] for item in state["records"]] == ["published"]
    assert not target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""
    assert remote_readback.split()[0] == expected["remote_head"]


def test_resume_published_git_failure_compensates_only_new_local_assets(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    real_git = resume_git_ops.git_ops._git

    def fail_switch(args: list[str], cwd: Path) -> tuple[int, str]:
        if args[:2] == ["switch", "-c"]:
            return 1, "injected local branch provisioning failure"
        return real_git(args, cwd)

    monkeypatch.setattr(resume_git_ops.git_ops, "_git", fail_switch)

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_BLOCK
    assert "branch recreation failed" in payload["reason"]
    assert payload["compensation"]["complete"] is True
    assert [item["status"] for item in state["records"]] == ["published"]
    assert not target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""
    assert (
        _git(repo, "ls-remote", "origin", "refs/heads/feat/exact-pr").split()[0]
        == expected["remote_head"]
    )


def test_resume_published_registry_fingerprint_cas_compensates_assets(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    real_provision = resume_git_ops.provision_exact

    def provision_then_drift(*args: object, **kwargs: object) -> str:
        head = real_provision(*args, **kwargs)
        state = coordinator.registry.load_state(state_path)
        state["records"][0]["intent"] = "concurrent owner update"
        coordinator.registry.save_state(state_path, state)
        return head

    monkeypatch.setattr(resume_git_ops, "provision_exact", provision_then_drift)

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    state = coordinator.registry.load_state(state_path)
    assert rc == coordinator.EXIT_BLOCK
    assert "registry claim changed" in payload["reason"]
    assert payload["compensation"]["complete"] is True
    assert [item["status"] for item in state["records"]] == ["published"]
    assert state["records"][0]["intent"] == "concurrent owner update"
    assert not target.exists()
    assert _git(repo, "branch", "--list", "feat/exact-pr") == ""


def test_resume_published_is_the_only_atomic_escape_from_published_ownership(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    state = coordinator.registry.load_state(state_path)
    original = state["records"][0]
    register_rc, refusal = coordinator.registry._register_record(
        state,
        branch="feat/competing",
        path=str(tmp_path / "competing"),
        intent="competing registration",
        base=str(original["base"]),
        external_ids=list(original["external_ids"]),
        scope=original["scope"],
        codex_thread_id="owner-thread-1",
        delegated=True,
    )
    assert register_rc != coordinator.registry.EXIT_OK
    assert "owned" in refusal["reason"]

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected))

    capsys.readouterr()
    records = coordinator.registry.load_state(state_path)["records"]
    assert rc == coordinator.EXIT_OK
    assert [(item["status"], item["claim_generation"]) for item in records] == [
        ("abandoned", 4),
        ("active", 5),
    ]


def test_resume_published_rejects_dirty_unreleased_recorded_worktree(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    released = tmp_path / "released-worktree"
    _git(
        repo,
        "worktree",
        "add",
        "-q",
        "-b",
        "stale-local",
        str(released),
        str(expected["base_sha"]),
    )
    (released / "dirty.txt").write_text("dirty\n", encoding="utf-8")

    rc = coordinator.main(_resume_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    assert rc == coordinator.EXIT_BLOCK
    assert any(word in payload["reason"] for word in ("released", "dirty", "new"))
    assert target.exists()


def test_resume_published_rejects_duplicate_and_unknown_registry_truth(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo, state_path, target, expected = _reanchor_fixture(tmp_path)
    state = coordinator.registry.load_state(state_path)
    duplicate = dict(state["records"][0])
    state["records"].append(duplicate)
    coordinator.registry.save_state(state_path, state)

    duplicate_rc = coordinator.main(_resume_argv(repo, state_path, target, expected))
    duplicate_payload = json.loads(capsys.readouterr().out)

    state = coordinator.registry.load_state(state_path)
    state["records"].pop()
    state["records"].append({"status": "unknown", "branch": "feat/unknown"})
    coordinator.registry.save_state(state_path, state)
    unknown_rc = coordinator.main(_resume_argv(repo, state_path, target, expected))
    unknown_payload = json.loads(capsys.readouterr().out)

    assert duplicate_rc == coordinator.EXIT_BLOCK
    assert "exactly one" in duplicate_payload["reason"]
    assert unknown_rc == coordinator.EXIT_BLOCK
    assert (
        "malformed" in unknown_payload["reason"]
        or "unknown" in unknown_payload["reason"]
    )
    assert not target.exists()


def _cleanup_pending_state(tmp_path: Path, *, branch: str, head: str) -> Path:
    state_path = tmp_path / "registry.json"
    state_path.write_text(
        json.dumps(
            {
                "schema": "kg.worktree.registry.v1",
                "records": [
                    {
                        "branch": branch,
                        "path": str(tmp_path / "gone"),
                        "status": "cleanup_pending",
                        "external_ids": [branch],
                        "claim_generation": 0,
                        "handed_back_sha": head,
                    }
                ],
            }
        )
    )
    return state_path


def _retire_args(state_path: Path, branch: str, head: str) -> Namespace:
    return Namespace(
        status="abandoned",
        branch=branch,
        path=None,
        state=str(state_path),
        json=True,
        expected_generation=0,
        expected_head_sha=head,
        remove=False,
    )


def _pr(number: int, branch: str, head: str, state: str) -> Namespace:
    return Namespace(number=number, branch=branch, head_sha=head, state=state)


@pytest.mark.parametrize(
    ("pulls", "remote", "expected_rc", "evidence_part"),
    [
        # force-moved remote, but the exact HEAD is a MERGED PR
        ([("MERGED", "a" * 40)], "f" * 40, 0, "MERGED"),
        # remote branch deleted and no PR is open
        ([], "", 0, "is gone"),
        # remote branch alive and nothing merged: keep the lease
        ([], "a" * 40, coordinator.EXIT_BLOCK, None),
        # an OPEN PR always keeps the lease, even if the remote is gone
        ([("OPEN", "a" * 40)], "", coordinator.EXIT_BLOCK, None),
        # MERGED PR for a different HEAD proves nothing about this lane
        ([("MERGED", "9" * 40)], "f" * 40, coordinator.EXIT_BLOCK, None),
        # CLOSED-unmerged PR with the remote deleted still needs the
        # closed-PR disposition flow, never the missing-remote shortcut
        ([("CLOSED", "a" * 40)], "", coordinator.EXIT_BLOCK, None),
        # MERGED PR for another HEAD plus a deleted remote is PR history too
        ([("MERGED", "9" * 40)], "", coordinator.EXIT_BLOCK, None),
    ],
)
def test_resolve_abandoned_retires_cleanup_pending_only_with_proof(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    pulls: list[tuple[str, str]],
    remote: str,
    expected_rc: int,
    evidence_part: str | None,
) -> None:
    branch = "fix/retire-me"
    head = "a" * 40
    state_path = _cleanup_pending_state(tmp_path, branch=branch, head=head)

    def fake_git(args: list[str], cwd: Path = coordinator.ROOT) -> tuple[int, str]:
        if args[:2] == ["ls-remote", "origin"]:
            return 0, f"{remote}\trefs/heads/{branch}" if remote else ""
        return 0, ""

    registry_calls: list[list[str]] = []
    monkeypatch.setattr(coordinator, "_git", fake_git)
    monkeypatch.setattr(
        coordinator,
        "_branch_pull_request_snapshots",
        lambda repo, name: tuple(
            _pr(index + 1, name, pr_head, state)
            for index, (state, pr_head) in enumerate(pulls)
        ),
    )
    monkeypatch.setattr(
        coordinator.registry,
        "main",
        lambda argv, acquire_lock=False, cleanup_pending_evidence=None: (
            registry_calls.append((argv, cleanup_pending_evidence)) or 0
        ),
    )

    rc = coordinator.cmd_resolve(_retire_args(state_path, branch, head))

    assert rc == expected_rc
    if evidence_part is None:
        assert not registry_calls
    else:
        argv, evidence = registry_calls[0]
        assert "--cleanup-pending-evidence" not in argv
        assert evidence_part in evidence


def test_resolve_abandoned_leaves_non_cleanup_pending_records_untouched(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state_path = tmp_path / "registry.json"
    state_path.write_text(
        json.dumps({"schema": "kg.worktree.registry.v1", "records": []})
    )
    registry_calls: list[list[str]] = []
    monkeypatch.setattr(
        coordinator,
        "_branch_pull_request_snapshots",
        lambda repo, name: pytest.fail("no PR lookup for non-cleanup_pending"),
    )
    monkeypatch.setattr(
        coordinator.registry,
        "main",
        lambda argv, acquire_lock=False, cleanup_pending_evidence=None: (
            registry_calls.append((argv, cleanup_pending_evidence)) or 0
        ),
    )

    rc = coordinator.cmd_resolve(_retire_args(state_path, "debug/x", "a" * 40))

    assert rc == 0
    assert registry_calls[0][1] is None


def test_adopt_scope_from_diff_derives_scope_from_the_branch_diff(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    state_path = tmp_path / "worktree_registry.json"
    argv = [
        "adopt",
        "--state",
        str(state_path),
        "--worktree",
        str(repo),
        "--intent",
        "agent worktree",
        "--base",
        "base",
        "--external-id",
        "ISSUE-9",
        "--codex-thread-id",
        "worker-thread",
        "--delegated",
        "--json",
    ]

    rc = coordinator.main([*argv, "--scope-from-diff"])
    capsys.readouterr()

    assert rc == coordinator.EXIT_OK
    [record] = coordinator.registry.load_state(state_path)["records"]
    assert record["scope"]["files"] == [
        {"path": "ios/issue_1033.py", "operation": "add"}
    ]

    conflict = coordinator.main([*argv, "--scope-from-diff", "--scope", '{"files":[]}'])
    assert conflict == coordinator.EXIT_USAGE
    assert "conflicts" in capsys.readouterr().out


def test_adopt_scope_from_diff_handles_non_ascii_paths(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    _commit(repo, "docs/reference/架構.rtf", "x\n", "non-ascii")
    state_path = tmp_path / "worktree_registry.json"
    rc = coordinator.main(
        [
            "adopt",
            "--state",
            str(state_path),
            "--worktree",
            str(repo),
            "--intent",
            "agent worktree",
            "--base",
            "base",
            "--external-id",
            "ISSUE-9",
            "--codex-thread-id",
            "worker-thread",
            "--delegated",
            "--scope-from-diff",
            "--json",
        ]
    )
    capsys.readouterr()

    assert rc == coordinator.EXIT_OK
    [record] = coordinator.registry.load_state(state_path)["records"]
    assert {"path": "docs/reference/架構.rtf", "operation": "add"} in record["scope"][
        "files"
    ]


def test_changed_files_returns_raw_non_ascii_names(tmp_path: Path) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    _commit(repo, "架構.rtf", "x\n", "tracked")
    (repo / "架構.rtf").write_text("changed\n", encoding="utf-8")
    (repo / "新增.md").write_text("new\n", encoding="utf-8")

    assert coordinator._changed_files(repo, "HEAD") == ["新增.md", "架構.rtf"]


def test_adopt_scope_from_diff_refuses_an_empty_diff(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    rc = coordinator.main(
        [
            "adopt",
            "--state",
            str(tmp_path / "r.json"),
            "--worktree",
            str(repo),
            "--intent",
            "x",
            "--base",
            "solver",
            "--scope-from-diff",
            "--json",
        ]
    )
    assert rc == coordinator.EXIT_USAGE
    assert "no changes" in capsys.readouterr().out


def _share(monkeypatch: pytest.MonkeyPatch, *paths: str) -> None:
    from lib import worktree_scope

    monkeypatch.setattr(worktree_scope, "SHARED_SCOPE_FILES", frozenset(paths))


def test_rebase_preflight_ignores_incoming_change_to_shared_scope_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    scope = _scope_for("ops/incoming_main.py")
    _share(monkeypatch, "ops/incoming_main.py")

    result = coordinator._rebase_preflight(
        repo, base="base", incoming_main="incoming-main", scope=scope
    )

    assert result["verdict"] == "pass"
    assert result["collisions"] == []
    # The shared file is still reported as declared Scope, never dropped.
    assert result["scope_files"] == ["ops/incoming_main.py"]
    assert result["incoming_main_files"] == ["ops/incoming_main.py"]


def test_reanchor_handback_leaves_shared_scope_file_overlap_to_rebase(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(coordinator, "_branch_pull_requests", lambda *_args: ())
    repo, state_path, target, expected = _prepare_reanchor_handback(tmp_path)
    _commit(repo, "ops/reanchor_change.py", "main\n", "main changes declared scope")
    _git(repo, "push", "-q", "origin", "main")
    expected["live_main"] = _git(repo, "rev-parse", "HEAD")
    _share(monkeypatch, "ops/reanchor_change.py")

    rc = coordinator.main(_reanchor_handback_argv(repo, state_path, target, expected))

    payload = json.loads(capsys.readouterr().out)
    # Not refused up front as a Scope collision: the real textual conflict
    # (both sides add the file) surfaces from git rebase, which is aborted.
    assert rc == coordinator.EXIT_BLOCK
    assert "collisions" not in payload
    assert payload["reason"].startswith("active handback rebase failed")
    assert _git(target, "rev-parse", "HEAD") == expected["remote_head"]


@pytest.mark.parametrize(
    "shared",
    [
        "ops/complexity_budget.json",
        "ops/test_ops.sh",
        "ops/tests/test_ops_ci_coverage.sh",
    ],
)
def test_adopt_accepts_scope_sharing_only_an_allowlisted_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], shared: str
) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    state_path = tmp_path / "worktree_registry.json"
    coordinator.registry.save_state(
        state_path,
        {
            "schema": coordinator.registry.SCHEMA,
            "records": [
                {
                    "branch": "feat/other",
                    "path": str(tmp_path / "other"),
                    "status": "active",
                    "external_ids": ["ISSUE-1"],
                    "scope": {
                        "schema": "kg.worktree.scope.v1",
                        "files": [
                            {
                                "path": shared,
                                "operation": "modify",
                            },
                            {"path": "ops/other.py", "operation": "modify"},
                        ],
                    },
                    "claim_generation": 1,
                }
            ],
        },
    )

    def adopt(*paths: str) -> int:
        scope = {
            "schema": "kg.worktree.scope.v1",
            "files": [{"path": item, "operation": "modify"} for item in paths],
        }
        rc = coordinator.main(
            [
                "adopt",
                "--state",
                str(state_path),
                "--worktree",
                str(repo),
                "--intent",
                "agent worktree",
                "--base",
                "base",
                "--external-id",
                "ISSUE-9",
                "--codex-thread-id",
                "worker-thread",
                "--delegated",
                "--scope",
                json.dumps(scope),
                "--json",
            ]
        )
        capsys.readouterr()
        return rc

    assert adopt(shared, "ops/other.py") == coordinator.registry.EXIT_CLAIMED
    assert adopt(shared, "ios/issue_1033.py") == coordinator.EXIT_OK
    [_, adopted] = coordinator.registry.load_state(state_path)["records"]
    assert adopted["scope"]["files"][0]["path"] == shared


def test_readopt_retires_and_adopts_under_one_lease(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """#2466: a competing overlapping `open` cannot slip in between the retire
    and the adopt, because both run inside one operation-lock lease."""
    repo = _synthetic_rebase_refs(tmp_path)
    state_path = tmp_path / "worktree_registry.json"
    scope = json.dumps(
        {
            "schema": "kg.worktree.scope.v1",
            "files": [{"path": "ios/issue_1033.py", "operation": "add"}],
        }
    )
    # the registry's stored head of an unsealed claim in another repo is its base
    head = _git(repo, "rev-parse", "main")
    adopt_argv = [
        "--state",
        str(state_path),
        "--worktree",
        str(repo),
        "--intent",
        "agent worktree",
        "--external-id",
        "ISSUE-9",
        "--scope",
        scope,
        "--codex-thread-id",
        "worker-thread",
        "--delegated",
        "--json",
    ]
    assert coordinator.main(["adopt", *adopt_argv, "--base", "main"]) == 0
    capsys.readouterr()

    competing: list[subprocess.CompletedProcess[str]] = []
    real_adopt = coordinator.cmd_adopt

    def adopt_with_a_rival(args: Namespace) -> int:
        competing.append(
            subprocess.run(
                [
                    sys.executable,
                    str(Path(coordinator.__file__)),
                    "open",
                    "--state",
                    str(state_path),
                    "--intent",
                    "rival",
                    "--slug",
                    "rival",
                    "--external-id",
                    "ISSUE-RIVAL",
                    "--scope",
                    scope,
                    "--codex-thread-id",
                    "rival-thread",
                    "--delegated",
                    "--json",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        )
        return real_adopt(args)

    monkeypatch.setattr(coordinator, "cmd_adopt", adopt_with_a_rival)

    rc = coordinator.main(
        [
            "readopt",
            *adopt_argv,
            "--base",
            "base",
            "--expected-generation",
            "0",
            "--expected-head-sha",
            head,
        ]
    )
    capsys.readouterr()

    assert rc == coordinator.EXIT_OK
    [rival] = competing
    assert rival.returncode != 0
    assert "delivery mutation already in progress" in rival.stdout + rival.stderr
    records = coordinator.registry.load_state(state_path)["records"]
    active = [r for r in records if r["status"] == "active"]
    assert [r["status"] for r in records].count("abandoned") == 1
    assert len(active) == 1
    assert active[0]["base_sha"] == _git(repo, "rev-parse", "base")
    assert active[0]["scope"]["files"] == [
        {"path": "ios/issue_1033.py", "operation": "add"}
    ]


def test_readopt_leaves_the_claim_when_the_retire_is_refused(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _synthetic_rebase_refs(tmp_path)
    state_path = tmp_path / "worktree_registry.json"
    argv = [
        "--state",
        str(state_path),
        "--worktree",
        str(repo),
        "--intent",
        "agent worktree",
        "--external-id",
        "ISSUE-9",
        "--scope-from-diff",
        "--codex-thread-id",
        "worker-thread",
        "--delegated",
        "--json",
    ]
    assert coordinator.main(["adopt", *argv, "--base", "main"]) == 0
    rc = coordinator.main(
        [
            "readopt",
            *argv,
            "--base",
            "base",
            "--expected-generation",
            "0",
            "--expected-head-sha",
            "0" * 40,  # not the claim's head: the registry CAS refuses
        ]
    )
    capsys.readouterr()
    assert rc != coordinator.EXIT_OK
    [record] = coordinator.registry.load_state(state_path)["records"]
    assert record["status"] == "active"


def test_retire_ghosts_dry_run_then_apply_abandons_only_the_ghost(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    scope = {
        "schema": "kg.worktree.scope.v1",
        "files": [{"path": "ops/ghost_scope.py", "operation": "modify"}],
    }
    live_dir = tmp_path / "live"
    live_dir.mkdir()

    def lane(branch: str, path: Path) -> dict:
        return {
            "branch": branch,
            "path": str(path),
            "intent": "fix",
            "base": "origin/main",
            "status": "active",
            "external_ids": [],
            "scope": scope if "ghost" in branch else None,
            "claim_generation": 0,
            "handed_back_at": None,
            "handed_back_sha": None,
        }

    state_file = tmp_path / "registry.json"
    coordinator.registry.save_state(
        state_file,
        {
            "schema": coordinator.registry.SCHEMA,
            "records": [
                lane("debug/ghost-2771", tmp_path / "gone"),
                lane("debug/live-2771", live_dir),
            ],
        },
    )

    class NoLock:
        def __init__(self, *a: object, **k: object) -> None: ...
        def __enter__(self) -> "NoLock":
            return self

        def __exit__(self, *a: object) -> bool:
            return False

    monkeypatch.setattr(coordinator, "OperationLock", NoLock)
    state = ["--state", str(state_file), "--json"]

    assert coordinator.main(["preflight", *state]) == 0
    listed = json.loads(capsys.readouterr().out)["ghosts"]
    assert [g["branch"] for g in listed] == ["debug/ghost-2771"]

    assert coordinator.main(["retire-ghosts", *state]) == 0
    assert not json.loads(capsys.readouterr().out)["retired"]
    statuses = {
        r["branch"]: r["status"]
        for r in coordinator.registry.load_state(state_file)["records"]
    }
    assert statuses == {"debug/ghost-2771": "active", "debug/live-2771": "active"}

    assert coordinator.main(["retire-ghosts", "--apply", *state]) == 0
    assert len(json.loads(capsys.readouterr().out)["retired"]) == 1
    statuses = {
        r["branch"]: r["status"]
        for r in coordinator.registry.load_state(state_file)["records"]
    }
    assert statuses == {"debug/ghost-2771": "abandoned", "debug/live-2771": "active"}

    new_state = coordinator.registry.load_state(state_file)
    rc, _ = coordinator.registry._register_record(
        new_state,
        branch="debug/new-2771",
        path=str(tmp_path / "new"),
        intent="fix",
        base="main",
        external_ids=[],
        scope=scope,
    )
    assert rc == coordinator.registry.EXIT_OK


def _rerun_resolve_world(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    record_extra: dict[str, Any],
) -> tuple[Namespace, list[list[str]], list[list[str]]]:
    branch = "debug/rerun"
    expected = "e" * 40
    worktree = tmp_path / "worktree"
    worktree.mkdir()
    calls: list[list[str]] = []

    def fake_git(args: list[str], cwd: Path = coordinator.ROOT) -> tuple[int, str]:
        calls.append(args)
        if args[:2] == ["show-ref", "--verify"]:
            return 0, f"{expected} refs/heads/{branch}"
        if args == ["branch", "--show-current"]:
            return 0, branch
        return 0, ""

    registry_calls: list[list[str]] = []
    monkeypatch.setattr(coordinator, "_git", fake_git)
    monkeypatch.setattr(
        coordinator.registry,
        "main",
        lambda argv, acquire_lock=False, **_kw: (
            registry_calls.append(argv) or coordinator.registry.EXIT_CLAIMED
        ),
    )
    state = tmp_path / "state.json"
    record = {
        "branch": branch,
        "path": str(worktree),
        "status": "abandoned",
        "claim_generation": 3,
        "handed_back_sha": expected,
        **record_extra,
    }
    state.write_text(json.dumps({"records": [record]}))
    args = Namespace(
        status="abandoned",
        branch=branch,
        path=str(worktree),
        state=str(state),
        json=True,
        expected_generation=3,
        expected_head_sha=expected,
        remove=True,
    )
    return args, calls, registry_calls


def test_resolve_remove_rerun_finishes_cleanup_of_an_already_abandoned_lane(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A cleanup that blocked after the abandon CAS can be re-driven (#2761)."""
    args, calls, registry_calls = _rerun_resolve_world(
        tmp_path, monkeypatch, record_extra={}
    )
    assert coordinator.cmd_resolve(args) == coordinator.EXIT_OK
    assert not registry_calls  # the CAS is not retried
    assert ["branch", "-D", "--", args.branch] in calls


def test_resolve_remove_rerun_ignores_a_mismatched_abandoned_record(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    args, calls, registry_calls = _rerun_resolve_world(
        tmp_path, monkeypatch, record_extra={"claim_generation": 2}
    )
    assert coordinator.cmd_resolve(args) == coordinator.registry.EXIT_CLAIMED
    assert ["branch", "-D", "--", args.branch] not in calls


@pytest.mark.parametrize(
    "contents",
    [b"{not json", b"[1, 2]", b"\xff\xfe\x00bad", b"null"],
    ids=["bad-json", "non-dict", "bad-utf8", "null"],
)
def test_freeze_fails_closed_on_unreadable_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, contents: bytes
) -> None:
    path = tmp_path / "worktree-freeze.json"
    path.write_bytes(contents)
    monkeypatch.setattr(coordinator, "_freeze_path", lambda: path)
    refusal = coordinator._require_unfrozen("open")
    assert refusal is not None
    assert "frozen" in refusal


def test_freeze_fails_closed_on_oserror(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = tmp_path / "worktree-freeze.json"
    path.mkdir()  # reading a directory raises OSError (not FileNotFoundError)
    monkeypatch.setattr(coordinator, "_freeze_path", lambda: path)
    assert coordinator._require_unfrozen("open") is not None


def test_freeze_absent_file_is_not_frozen(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        coordinator, "_freeze_path", lambda: tmp_path / "worktree-freeze.json"
    )
    assert coordinator._is_frozen() is None
    assert coordinator._require_unfrozen("open") is None
