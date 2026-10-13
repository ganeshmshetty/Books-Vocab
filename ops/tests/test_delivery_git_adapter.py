from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.errors import AdapterCommandError, AdapterPayloadError
from delivery_control.adapters.git_cli import GitCliAdapter
from delivery_control.adapters.git_parsing import (
    parse_branch_inventory,
    parse_changed_files,
    parse_unreachable_commit_shas,
    parse_worktrees,
)
from delivery_control.domain.branch_refs import BranchInventory
from delivery_control.domain.errors import CompareAndSwapConflict
from delivery_control.domain.observations import (
    FileChange,
    FileOperation,
    PhysicalWorktree,
)
from delivery_control.domain.unreachable_commits import (
    UnreachableCommitEvidence,
    UnreachableCommitInventory,
)
from delivery_control.ports.process import CommandResult


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def test_git_adapter_stale_idle_checkout_reports_no_phantom_changes(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "base.txt").write_text("base\n", encoding="utf-8")
    _git(repo, "add", "base.txt")
    _git(repo, "commit", "-qm", "base")
    stale_head = _git(repo, "rev-parse", "HEAD")
    (repo / "landed.txt").write_text("landed on main\n", encoding="utf-8")
    _git(repo, "add", "landed.txt")
    _git(repo, "commit", "-qm", "main advances")
    live_main = _git(repo, "rev-parse", "HEAD")
    _git(repo, "switch", "-q", "--detach", stale_head)

    snapshot = GitCliAdapter(repo=repo).inspect_worktree(repo, live_main)

    # The checkout added nothing; files main changed after it must not be
    # attributed to it, or an idle checkout fabricates Scope collisions.
    assert snapshot.changes == ()
    assert snapshot.changed_paths == ()


def test_git_adapter_computes_operation_aware_exact_base_diff(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "base.txt").write_text("base\n", encoding="utf-8")
    _git(repo, "add", "base.txt")
    _git(repo, "commit", "-qm", "base")
    base_sha = _git(repo, "rev-parse", "HEAD")
    _git(repo, "switch", "-qc", "feat/example")
    (repo / "base.txt").write_text("changed\n", encoding="utf-8")
    (repo / "ops").mkdir()
    (repo / "ops" / "change.py").write_text("value = 1\n", encoding="utf-8")
    _git(repo, "add", ".")
    _git(repo, "commit", "-qm", "change")

    snapshot = GitCliAdapter(repo=repo).inspect_worktree(repo, base_sha)

    assert snapshot.clean
    assert snapshot.changes == (
        FileChange(FileOperation.MODIFY, "base.txt"),
        FileChange(FileOperation.ADD, "ops/change.py"),
    )


def test_git_adapter_normalizes_rename_and_copy_without_losing_changed_paths(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "rename-source.txt").write_text("rename only\n", encoding="utf-8")
    (repo / "copy-source.txt").write_text("copy only\n", encoding="utf-8")
    _git(repo, "add", ".")
    _git(repo, "commit", "-qm", "base")
    base_sha = _git(repo, "rev-parse", "HEAD")
    _git(repo, "switch", "-qc", "feat/example")
    (repo / "rename-source.txt").rename(repo / "rename-destination.txt")
    (repo / "copy-destination.txt").write_text(
        (repo / "copy-source.txt").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    _git(repo, "add", ".")
    _git(repo, "commit", "-qm", "rename and copy")

    snapshot = GitCliAdapter(repo=repo).inspect_worktree(repo, base_sha)

    assert snapshot.changes == (
        FileChange(FileOperation.ADD, "copy-destination.txt"),
        FileChange(FileOperation.ADD, "rename-destination.txt"),
        FileChange(FileOperation.DELETE, "rename-source.txt"),
    )
    assert snapshot.changed_paths == (
        "copy-destination.txt",
        "rename-destination.txt",
        "rename-source.txt",
    )


def test_git_adapter_reads_canonical_checkout_without_mutation(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "tracked.txt").write_text("clean\n", encoding="utf-8")
    _git(repo, "add", "tracked.txt")
    _git(repo, "commit", "-qm", "base")

    clean = GitCliAdapter(repo=repo).canonical_checkout()
    assert clean.branch == "main"
    assert clean.clean

    (repo / "tracked.txt").write_text("dirty\n", encoding="utf-8")
    dirty = GitCliAdapter(repo=repo).canonical_checkout()
    assert not dirty.clean
    assert dirty.head_sha == clean.head_sha


def test_git_adapter_distinguishes_existing_and_missing_local_branches(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "tracked.txt").write_text("base\n", encoding="utf-8")
    _git(repo, "add", "tracked.txt")
    _git(repo, "commit", "-qm", "base")
    head = _git(repo, "rev-parse", "HEAD")
    adapter = GitCliAdapter(repo=repo)

    assert adapter.local_branch_sha("main") == head
    assert adapter.local_branch_sha("feat/missing") is None


def test_git_adapter_inspects_unreachable_commit_without_creating_a_ref(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "base.txt").write_text("base\n", encoding="utf-8")
    _git(repo, "add", "base.txt")
    _git(repo, "commit", "-qm", "base")
    _git(repo, "switch", "-qc", "feat/unreachable")
    (repo / "unreachable.txt").write_text("preserve\n", encoding="utf-8")
    _git(repo, "add", "unreachable.txt")
    _git(repo, "commit", "-qm", "preserve unreachable change")
    commit_sha = _git(repo, "rev-parse", "HEAD")
    _git(repo, "switch", "-q", "main")
    _git(repo, "branch", "-D", "feat/unreachable")

    adapter = GitCliAdapter(repo=repo)
    evidence = adapter.inspect_unreachable_commit(
        commit_sha=commit_sha,
        max_paths=200,
    )

    assert isinstance(evidence, UnreachableCommitEvidence)
    assert evidence.complete
    assert evidence.unreachable is True
    assert evidence.parent_shas
    assert evidence.subject == "preserve unreachable change"
    assert evidence.changed_paths == ("unreachable.txt",)
    assert evidence.disposition == "preserve_for_owner_correlation"
    assert not _git(repo, "branch", "--all", "--contains", commit_sha)

    bounded = adapter.inspect_unreachable_commit(
        commit_sha=commit_sha,
        max_paths=1,
    )
    assert bounded.changed_paths == ("unreachable.txt",)


@pytest.mark.parametrize("max_paths", [0, 201, "200", True, 1.5, None])
def test_git_adapter_rejects_unbounded_path_limit(
    tmp_path: Path, max_paths: object
) -> None:
    with pytest.raises(AdapterPayloadError, match="between 1 and 200"):
        GitCliAdapter(repo=tmp_path).inspect_unreachable_commit(
            commit_sha="a" * 40,
            max_paths=max_paths,  # type: ignore[arg-type]
        )


def test_git_adapter_reads_ancestor_relation_without_mutation(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "tracked.txt").write_text("base\n", encoding="utf-8")
    _git(repo, "add", "tracked.txt")
    _git(repo, "commit", "-qm", "base")
    base = _git(repo, "rev-parse", "HEAD")
    (repo / "tracked.txt").write_text("tip\n", encoding="utf-8")
    _git(repo, "commit", "-qam", "tip")
    tip = _git(repo, "rev-parse", "HEAD")

    adapter = GitCliAdapter(repo=repo)

    assert adapter.is_ancestor(base, tip)
    assert not adapter.is_ancestor(tip, base)


def test_git_adapter_ancestor_query_treats_absent_object_as_not_contained(
    tmp_path: Path,
) -> None:
    # #3348: a merged PR head that was never fetched locally is an absent
    # object (git rc 128, "Not a valid commit name").  That is a typed "not
    # contained" answer, not an adapter command failure.
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "tracked.txt").write_text("base\n", encoding="utf-8")
    _git(repo, "add", "tracked.txt")
    _git(repo, "commit", "-qm", "base")
    base = _git(repo, "rev-parse", "HEAD")
    absent = "c" * 40

    adapter = GitCliAdapter(repo=repo)

    assert adapter.is_ancestor(absent, base) is False
    assert adapter.is_ancestor(base, absent) is False



def test_git_adapter_reads_patch_equivalence_without_mutation(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "tracked.txt").write_text("base\n", encoding="utf-8")
    _git(repo, "add", "tracked.txt")
    _git(repo, "commit", "-qm", "base")
    _git(repo, "switch", "-qc", "feat/equivalent")
    (repo / "tracked.txt").write_text("tip\n", encoding="utf-8")
    _git(repo, "commit", "-qam", "feature change")
    feature_tip = _git(repo, "rev-parse", "HEAD")
    _git(repo, "switch", "-q", "main")
    (repo / "tracked.txt").write_text("tip\n", encoding="utf-8")
    _git(repo, "commit", "-qam", "equivalent main change")
    main_tip = _git(repo, "rev-parse", "HEAD")

    adapter = GitCliAdapter(repo=repo)

    assert adapter.is_patch_equivalent(feature_tip, main_tip)


@pytest.mark.parametrize(
    ("formatted_source", "expected"),
    (
        (
            ("value = function(\n    first,\n    second,\n)\n"),
            True,
        ),
        (
            ("value = function(\n    first,\n    third,\n)\n"),
            False,
        ),
    ),
)
def test_git_adapter_classifies_whitespace_normalized_patch_equivalence(
    tmp_path: Path,
    formatted_source: str,
    expected: bool,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "sample.py").write_text(
        "value = function(first, first)\n",
        encoding="utf-8",
    )
    _git(repo, "add", "sample.py")
    _git(repo, "commit", "-qm", "base")
    old_base = _git(repo, "rev-parse", "HEAD")

    _git(repo, "switch", "-qc", "old-feature")
    (repo / "sample.py").write_text(
        "value = function(first, second)\n",
        encoding="utf-8",
    )
    _git(repo, "commit", "-qam", "feature change")
    old_head = _git(repo, "rev-parse", "HEAD")

    _git(repo, "switch", "-q", "main")
    (repo / "unrelated.txt").write_text("new base\n", encoding="utf-8")
    _git(repo, "add", "unrelated.txt")
    _git(repo, "commit", "-qm", "advance base")
    new_base = _git(repo, "rev-parse", "HEAD")

    _git(repo, "switch", "-qc", "new-feature")
    (repo / "sample.py").write_text(
        "value = function(first, second)\n",
        encoding="utf-8",
    )
    _git(repo, "commit", "-qam", "feature change")
    (repo / "sample.py").write_text(
        formatted_source,
        encoding="utf-8",
    )
    _git(repo, "commit", "-qam", "format feature test")
    new_head = _git(repo, "rev-parse", "HEAD")
    refs_before = _git(repo, "for-each-ref", "--format=%(refname) %(objectname)")

    adapter = GitCliAdapter(repo=repo)

    assert (
        adapter.is_whitespace_normalized_patch_equivalent(
            old_base,
            old_head,
            new_base,
            new_head,
        )
        is expected
    )
    assert (
        _git(repo, "for-each-ref", "--format=%(refname) %(objectname)") == refs_before
    )
    assert _git(repo, "branch", "--show-current") == "new-feature"


def test_git_adapter_reports_unique_patch_as_not_equivalent(tmp_path: Path) -> None:
    runner = StaticRunner([CommandResult(("git",), 0, f"+ {'c' * 40}\n", "")])

    assert not GitCliAdapter(repo=tmp_path, runner=runner).is_patch_equivalent(
        "a" * 40, "b" * 40
    )


@pytest.mark.parametrize(
    "stdout",
    ("malformed output\n", f"- {'z' * 40}\n"),
)
def test_git_adapter_rejects_malformed_patch_equivalence_output(
    tmp_path: Path, stdout: str
) -> None:
    runner = StaticRunner([CommandResult(("git",), 0, stdout, "")])

    with pytest.raises(AdapterPayloadError, match="git cherry returned malformed"):
        GitCliAdapter(repo=tmp_path, runner=runner).is_patch_equivalent(
            "a" * 40, "b" * 40
        )


def test_git_adapter_propagates_patch_equivalence_command_failure(
    tmp_path: Path,
) -> None:
    runner = StaticRunner([CommandResult(("git",), 128, "", "fatal: cherry failed")])

    with pytest.raises(AdapterCommandError, match="cherry failed"):
        GitCliAdapter(repo=tmp_path, runner=runner).is_patch_equivalent(
            "a" * 40, "b" * 40
        )


def test_git_adapter_bounds_patch_equivalence_query(
    tmp_path: Path,
) -> None:
    runner = TimeoutAwareRunner()

    with pytest.raises(AdapterCommandError, match="timed out"):
        GitCliAdapter(repo=tmp_path, runner=runner).is_patch_equivalent(
            "a" * 40, "b" * 40
        )

    assert runner.timeout_seconds == 5.0


@pytest.mark.parametrize("stderr", ("fatal: permission denied", "runner unavailable"))
def test_git_adapter_ancestor_query_propagates_source_failures(
    tmp_path: Path, stderr: str
) -> None:
    runner = StaticRunner([CommandResult(("git",), 128, "", stderr)])

    with pytest.raises(AdapterCommandError, match=stderr.removeprefix("fatal: ")):
        GitCliAdapter(repo=tmp_path, runner=runner).is_ancestor("a" * 40, "b" * 40)


def test_git_new_remote_branch_push_uses_absent_ref_lease(tmp_path: Path) -> None:
    head = "b" * 40
    runner = StaticRunner(
        [
            CommandResult(("git",), 0, "feat/one\n", ""),
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), 0, f"{head}\trefs/heads/feat/one\n", ""),
        ]
    )
    adapter = GitCliAdapter(repo=tmp_path, runner=runner)

    adapter.push_branch(
        worktree=tmp_path,
        branch="feat/one",
        expected_local_sha=head,
        expected_remote_sha=None,
    )

    push = next(call for call in runner.calls if "push" in call)
    assert "--force-with-lease=refs/heads/feat/one:" in push


def test_git_local_branch_delete_uses_atomic_expected_old_sha(tmp_path: Path) -> None:
    head = "b" * 40
    runner = StaticRunner(
        [
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), 1, "", ""),
        ]
    )
    adapter = GitCliAdapter(repo=tmp_path, runner=runner)

    adapter.delete_local_branch("feat/one", expected_head_sha=head)

    assert any(
        call[-4:] == ("update-ref", "-d", "refs/heads/feat/one", head)
        for call in runner.calls
    )


def test_git_root_commit_is_the_only_absent_parent_state(tmp_path: Path) -> None:
    head = "b" * 40
    base = "a" * 40
    runner = StaticRunner(
        [
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 0, "feat/one\n", ""),
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), 0, "", ""),
        ]
    )

    snapshot = GitCliAdapter(repo=tmp_path, runner=runner).inspect_worktree(
        tmp_path, base
    )

    assert snapshot.parent_sha == base


@pytest.mark.parametrize(
    ("exit_code", "stderr"),
    (
        (128, "fatal: permission denied"),
        (128, "fatal: loose object is corrupt"),
        (1, "runner unavailable"),
    ),
)
def test_git_parent_readback_propagates_source_failures(
    tmp_path: Path, exit_code: int, stderr: str
) -> None:
    head = "b" * 40
    runner = StaticRunner(
        [
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 0, "feat/one\n", ""),
            CommandResult(("git",), exit_code, "", stderr),
        ]
    )

    with pytest.raises(AdapterCommandError, match=stderr.removeprefix("fatal: ")):
        GitCliAdapter(repo=tmp_path, runner=runner).inspect_worktree(tmp_path, "a" * 40)


def test_git_local_branch_reports_only_missing_exact_ref_as_absent(
    tmp_path: Path,
) -> None:
    runner = StaticRunner([CommandResult(("git",), 1, "", "")])

    assert (
        GitCliAdapter(repo=tmp_path, runner=runner).local_branch_sha("feat/missing")
        is None
    )
    assert runner.calls[0][-4:] == (
        "show-ref",
        "--verify",
        "--quiet",
        "refs/heads/feat/missing",
    )


@pytest.mark.parametrize(
    ("exit_code", "stderr"),
    (
        (128, "fatal: permission denied"),
        (128, "fatal: loose object is corrupt"),
        (1, "runner unavailable"),
    ),
)
def test_git_local_branch_readback_propagates_source_failures(
    tmp_path: Path, exit_code: int, stderr: str
) -> None:
    runner = StaticRunner([CommandResult(("git",), exit_code, "", stderr)])

    with pytest.raises(AdapterCommandError, match=stderr.removeprefix("fatal: ")):
        GitCliAdapter(repo=tmp_path, runner=runner).local_branch_sha("feat/one")


def test_git_local_branch_readback_propagates_corrupt_referenced_object(
    tmp_path: Path,
) -> None:
    head = "b" * 40
    runner = StaticRunner(
        [
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 128, "", "fatal: loose object is corrupt"),
        ]
    )

    with pytest.raises(AdapterCommandError, match="loose object is corrupt"):
        GitCliAdapter(repo=tmp_path, runner=runner).local_branch_sha("feat/one")


@pytest.mark.parametrize(
    ("exit_code", "stderr"),
    (
        (128, "fatal: permission denied"),
        (128, "fatal: loose object is corrupt"),
        (1, "runner unavailable"),
    ),
)
def test_git_local_branch_delete_propagates_failed_absence_readback(
    tmp_path: Path, exit_code: int, stderr: str
) -> None:
    head = "b" * 40
    runner = StaticRunner(
        [
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), exit_code, "", stderr),
        ]
    )

    with pytest.raises(AdapterCommandError, match=stderr.removeprefix("fatal: ")):
        GitCliAdapter(repo=tmp_path, runner=runner).delete_local_branch(
            "feat/one", expected_head_sha=head
        )


def test_git_worktree_remove_is_idempotent_only_when_inventory_is_absent(
    tmp_path: Path,
) -> None:
    runner = StaticRunner([CommandResult(("git",), 0, "", "")])

    GitCliAdapter(repo=tmp_path, runner=runner).remove_worktree(
        tmp_path / "missing", expected_head_sha="b" * 40
    )

    assert len(runner.calls) == 1
    assert runner.calls[0][-3:] == ("worktree", "list", "--porcelain")


def test_git_worktree_remove_reclaims_clean_broken_pointer_residue(
    tmp_path: Path,
) -> None:
    residue = tmp_path / "stale-terminal"
    residue.mkdir()
    (residue / ".git").write_text(
        f"gitdir: {tmp_path / 'missing-worktree-admin'}\n", encoding="utf-8"
    )
    runner = StaticRunner([CommandResult(("git",), 0, "", "")])

    GitCliAdapter(repo=tmp_path, runner=runner).remove_worktree(
        residue, expected_head_sha="b" * 40
    )

    assert not residue.exists()


def test_git_worktree_remove_refuses_non_clean_or_live_pointer_residue(
    tmp_path: Path,
) -> None:
    cases = (
        ("untracked", "gitdir: /missing/admin\n"),
        ("live-metadata", None),
    )
    for name, pointer in cases:
        residue = tmp_path / name
        residue.mkdir()
        if pointer is None:
            gitdir = tmp_path / "live-admin"
            gitdir.mkdir()
            pointer = f"gitdir: {gitdir}\n"
        (residue / ".git").write_text(pointer, encoding="utf-8")
        if name == "untracked":
            (residue / "untracked.txt").write_text("changed\n", encoding="utf-8")
        runner = StaticRunner([CommandResult(("git",), 0, "", "")])

        with pytest.raises(CompareAndSwapConflict, match="residue"):
            GitCliAdapter(repo=tmp_path, runner=runner).remove_worktree(
                residue, expected_head_sha="b" * 40
            )

        assert residue.exists()
        assert (residue / ".git").exists()


@pytest.mark.parametrize(
    ("exit_code", "stderr"),
    (
        (128, "fatal: permission denied"),
        (128, "fatal: loose object is corrupt"),
        (1, "runner unavailable"),
    ),
)
def test_git_worktree_remove_propagates_failed_absence_readback(
    tmp_path: Path, exit_code: int, stderr: str
) -> None:
    head = "b" * 40
    worktree = tmp_path / "worktree"
    porcelain = f"worktree {worktree}\nHEAD {head}\nbranch refs/heads/feat/one\n"
    runner = StaticRunner(
        [
            CommandResult(("git",), 0, porcelain, ""),
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), exit_code, "", stderr),
        ]
    )

    with pytest.raises(AdapterCommandError, match=stderr.removeprefix("fatal: ")):
        GitCliAdapter(repo=tmp_path, runner=runner).remove_worktree(
            worktree, expected_head_sha=head
        )


def test_git_remote_branch_delete_uses_exact_lease(tmp_path: Path) -> None:
    head = "b" * 40
    runner = StaticRunner(
        [
            CommandResult(("git",), 0, f"{head}\trefs/heads/feat/one\n", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), 0, "", ""),
        ]
    )
    adapter = GitCliAdapter(repo=tmp_path, runner=runner)

    adapter.delete_remote_branch("feat/one", expected_head_sha=head)

    push = next(call for call in runner.calls if "push" in call)
    assert f"--force-with-lease=refs/heads/feat/one:{head}" in push
    assert ":refs/heads/feat/one" in push


@pytest.mark.parametrize(
    ("exit_code", "stderr"),
    (
        (128, "fatal: permission denied"),
        (128, "fatal: loose object is corrupt"),
        (1, "runner unavailable"),
    ),
)
def test_git_remote_branch_delete_propagates_failed_absence_readback(
    tmp_path: Path, exit_code: int, stderr: str
) -> None:
    head = "b" * 40
    runner = StaticRunner(
        [
            CommandResult(("git",), 0, f"{head}\trefs/heads/feat/one\n", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), exit_code, "", stderr),
        ]
    )

    with pytest.raises(AdapterCommandError, match=stderr.removeprefix("fatal: ")):
        GitCliAdapter(repo=tmp_path, runner=runner).delete_remote_branch(
            "feat/one", expected_head_sha=head
        )


def test_git_push_lease_failure_is_a_compare_and_swap_conflict(tmp_path: Path) -> None:
    head = "b" * 40
    runner = StaticRunner(
        [
            CommandResult(("git",), 0, "feat/one\n", ""),
            CommandResult(("git",), 0, f"{head}\n", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), 1, "", "stale info"),
        ]
    )
    adapter = GitCliAdapter(repo=tmp_path, runner=runner)

    with pytest.raises(CompareAndSwapConflict, match="lease"):
        adapter.push_branch(
            worktree=tmp_path,
            branch="feat/one",
            expected_local_sha=head,
            expected_remote_sha=None,
        )


def test_git_cleanup_refuses_canonical_checkout_and_main(tmp_path: Path) -> None:
    adapter = GitCliAdapter(repo=tmp_path, runner=StaticRunner([]))

    with pytest.raises(CompareAndSwapConflict, match="canonical"):
        adapter.remove_worktree(tmp_path, expected_head_sha="b" * 40)
    with pytest.raises(CompareAndSwapConflict, match="local main"):
        adapter.delete_local_branch("main", expected_head_sha="b" * 40)
    with pytest.raises(CompareAndSwapConflict, match="remote main"):
        adapter.delete_remote_branch("main", expected_head_sha="b" * 40)


def test_git_adapter_collects_branch_refs_with_two_bulk_queries(
    tmp_path: Path,
) -> None:
    local_sha = "a" * 40
    remote_sha = "b" * 40
    runner = StaticRunner(
        [
            CommandResult(
                ("git",),
                0,
                f"main\t{local_sha}\nfeat/one\t{remote_sha}\n",
                "",
            ),
            CommandResult(
                ("git",),
                0,
                (f"{remote_sha}\trefs/heads/feat/one\n{local_sha}\trefs/heads/main\n"),
                "",
            ),
        ]
    )
    adapter = GitCliAdapter(repo=tmp_path, runner=runner)

    inventory = adapter.branch_inventory()

    assert inventory == BranchInventory(
        local=(("feat/one", remote_sha), ("main", local_sha)),
        remote=(("feat/one", remote_sha), ("main", local_sha)),
    )
    assert len(runner.calls) == 2
    assert runner.calls[0][-2:] == (
        "--format=%(refname:strip=2)%09%(objectname)",
        "refs/heads",
    )
    assert runner.calls[1][-3:] == ("ls-remote", "--heads", "origin")


def test_git_adapter_bounds_origin_main_remote_ref_query(
    tmp_path: Path,
) -> None:
    runner = TimeoutAwareRunner()

    with pytest.raises(AdapterCommandError, match="timed out"):
        GitCliAdapter(repo=tmp_path, runner=runner).origin_main_sha()

    assert runner.timeout_seconds == 30.0


def test_git_adapter_bounds_single_remote_branch_ref_query(
    tmp_path: Path,
) -> None:
    runner = TimeoutAwareRunner()

    with pytest.raises(AdapterCommandError, match="timed out"):
        GitCliAdapter(repo=tmp_path, runner=runner).remote_branch_sha("feat/one")

    assert runner.timeout_seconds == 30.0


def test_git_adapter_bounds_bulk_remote_branch_ref_query(
    tmp_path: Path,
) -> None:
    runner = RemoteInventoryTimeoutRunner()

    with pytest.raises(AdapterCommandError, match="timed out"):
        GitCliAdapter(repo=tmp_path, runner=runner).branch_inventory()

    assert runner.timeout_seconds == 30.0


def test_git_adapter_preserves_fsck_diagnostics_and_commit_quarantine(
    tmp_path: Path,
) -> None:
    commit_a = "a" * 40
    commit_b = "b" * 40
    runner = StaticRunner(
        [
            CommandResult(
                ("git",),
                8,
                (
                    f"unreachable blob {'c' * 40}\n"
                    f"unreachable commit {commit_b}\n"
                    f"unreachable commit {commit_a}\n"
                ),
                "error: refs/.DS_Store: badRefName: invalid refname format\n",
            ),
            CommandResult(
                ("git",),
                0,
                f"{commit_a}\0{'d' * 40}\0subject a",
                "",
            ),
            CommandResult(("git",), 0, "", ""),
            CommandResult(
                ("git",),
                0,
                f"{commit_b}\0{'d' * 40}\0subject b",
                "",
            ),
            CommandResult(("git",), 0, "", ""),
        ]
    )
    adapter = GitCliAdapter(repo=tmp_path, runner=runner)

    inventory = adapter.unreachable_commit_inventory()

    assert inventory.shas == (commit_a, commit_b)
    assert inventory.problems == (
        "git fsck exited with 8",
        "error: refs/.DS_Store: badRefName: invalid refname format",
    )
    assert inventory.complete is False
    assert tuple(item.commit_sha for item in inventory.evidence) == (
        commit_a,
        commit_b,
    )
    assert all(item.complete is False for item in inventory.evidence)
    assert sum(call[-4] == "fsck" for call in runner.calls) == 1


def test_git_adapter_projects_bounded_sample_evidence_from_one_fsck_inventory(
    tmp_path: Path,
) -> None:
    commit_a = "a" * 40
    commit_b = "b" * 40
    parent = "c" * 40
    runner = StaticRunner(
        [
            CommandResult(
                ("git",),
                0,
                f"unreachable commit {commit_b}\nunreachable commit {commit_a}\n",
                "",
            ),
            CommandResult(
                ("git",),
                0,
                f"{commit_a}\0{parent}\0valid subject",
                "",
            ),
            CommandResult(("git",), 0, "", ""),
            CommandResult(("git",), 0, "malformed metadata", ""),
        ]
    )

    inventory = GitCliAdapter(
        repo=tmp_path, runner=runner
    ).unreachable_commit_inventory()

    assert inventory.count == 2
    assert len(inventory.evidence) == 2
    valid, malformed = inventory.evidence
    assert valid.commit_sha == commit_a
    assert valid.complete is True
    assert valid.subject == "valid subject"
    assert malformed.commit_sha == commit_b
    assert malformed.complete is False
    assert malformed.disposition == "preserve_with_source_problem"
    assert malformed.source_problem_scope == "git_objects"
    assert malformed.error == "unreachable commit metadata is malformed"
    assert inventory.complete is False
    assert any("unreachable commit b" in problem for problem in inventory.problems)
    assert sum("fsck" in call for call in runner.calls) == 1


def test_git_adapter_caps_unreachable_commit_evidence_at_twenty_objects(
    tmp_path: Path,
) -> None:
    commits = tuple(f"{index:040x}" for index in range(21))
    parent = "f" * 40
    responses = [
        CommandResult(
            ("git",),
            0,
            "".join(f"unreachable commit {commit}\n" for commit in commits),
            "",
        )
    ]
    for index, commit in enumerate(commits[:20]):
        responses.extend(
            [
                CommandResult(
                    ("git",),
                    0,
                    f"{commit}\0{parent}\0subject {index}",
                    "",
                ),
                CommandResult(("git",), 0, "", ""),
            ]
        )

    runner = StaticRunner(responses)
    inventory = GitCliAdapter(
        repo=tmp_path, runner=runner
    ).unreachable_commit_inventory()

    assert inventory.count == 21
    assert len(inventory.sample) == 20
    assert len(inventory.evidence) == 20
    assert tuple(item.commit_sha for item in inventory.evidence) == commits[:20]
    assert sum("fsck" in call for call in runner.calls) == 1
    assert len(runner.calls) == 41


def test_git_adapter_bounds_fsck_and_preserves_timeout_as_incomplete(
    tmp_path: Path,
) -> None:
    runner = TimeoutAwareRunner()

    inventory = GitCliAdapter(
        repo=tmp_path, runner=runner
    ).unreachable_commit_inventory()

    assert inventory == UnreachableCommitInventory(
        problems=(
            "git fsck exited with 124",
            "command timed out after 30s",
        ),
        complete=False,
    )
    assert runner.timeout_seconds == 30.0


def test_unreachable_commit_parser_ignores_non_commit_objects() -> None:
    assert parse_unreachable_commit_shas(
        f"unreachable tree {'a' * 40}\n"
        f"unreachable commit {'b' * 40}\n"
        f"unreachable commit {'b' * 40}\n"
    ) == ("b" * 40,)


def test_git_parsers_normalize_payloads_without_a_runner(tmp_path: Path) -> None:
    head = "a" * 40
    other = "b" * 40
    worktree = tmp_path / "linked"

    assert parse_changed_files(
        "R100\0old.txt\0new.txt\0C100\0source.txt\0copy.txt\0"
    ) == (
        FileChange(FileOperation.ADD, "copy.txt"),
        FileChange(FileOperation.ADD, "new.txt"),
        FileChange(FileOperation.DELETE, "old.txt"),
    )
    assert parse_worktrees(
        f"worktree {worktree}\nHEAD {head}\nbranch refs/heads/feat/one\n\n"
        f"worktree {tmp_path / 'detached'}\nHEAD {other}\ndetached\nprunable\n"
    ) == (
        PhysicalWorktree(
            path=worktree.resolve(),
            head_sha=head,
            branch="feat/one",
            prunable=False,
        ),
        PhysicalWorktree(
            path=(tmp_path / "detached").resolve(),
            head_sha=other,
            branch=None,
            prunable=True,
        ),
    )
    assert parse_branch_inventory(
        f"main\t{head}\nfeat/one\t{other}\n",
        f"{other}\trefs/heads/feat/one\n{head}\trefs/heads/main\n",
    ) == BranchInventory(
        local=(("feat/one", other), ("main", head)),
        remote=(("feat/one", other), ("main", head)),
    )


@pytest.mark.parametrize("max_commit_summaries", (0, 21, 10**9, 1.5, True))
def test_git_adapter_rejects_overlarge_commit_summary_requests(
    tmp_path: Path,
    max_commit_summaries: object,
) -> None:
    runner = StaticRunner([])
    adapter = GitCliAdapter(repo=tmp_path, runner=runner)

    with pytest.raises(AdapterPayloadError, match="between 1 and 20"):
        adapter.inspect_branch_content(
            branch="backup/orphan",
            base_sha="a" * 40,
            max_commit_summaries=max_commit_summaries,
        )

    assert runner.calls == []


def test_git_adapter_preserves_valid_commit_summary_bounds(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "README").write_text("base\n", encoding="utf-8")
    _git(repo, "add", "README")
    _git(repo, "commit", "-qm", "base")
    base_sha = _git(repo, "rev-parse", "HEAD")
    _git(repo, "switch", "-qc", "backup/orphan")
    (repo / "README").write_text("feature\n", encoding="utf-8")
    _git(repo, "add", "README")
    _git(repo, "commit", "-qm", "feature")

    adapter = GitCliAdapter(repo=repo)
    one = adapter.inspect_branch_content(
        branch="backup/orphan",
        base_sha=base_sha,
        max_commit_summaries=1,
    )
    twenty = adapter.inspect_branch_content(
        branch="backup/orphan",
        base_sha=base_sha,
        max_commit_summaries=20,
    )

    assert one.commit_subjects == twenty.commit_subjects == ("feature",)
    assert one.changed_paths == twenty.changed_paths == ("README",)


class StaticRunner:
    def __init__(self, responses: list[CommandResult]) -> None:
        self.responses = list(responses)
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        self.calls.append(argv)
        return self.responses.pop(0)


class TimeoutAwareRunner:
    def __init__(self) -> None:
        self.timeout_seconds: float | None = None

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        raise AssertionError(f"unexpected unbounded runner call: {argv}")

    def run_with_timeout(
        self,
        argv: tuple[str, ...],
        *,
        cwd: Path | None = None,
        timeout_seconds: float,
    ) -> CommandResult:
        self.timeout_seconds = timeout_seconds
        return CommandResult(
            argv=argv,
            exit_code=124,
            stdout="",
            stderr=f"command timed out after {timeout_seconds:g}s",
            timed_out=True,
        )


class RemoteInventoryTimeoutRunner(TimeoutAwareRunner):
    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        if argv[-1] == "refs/heads":
            return CommandResult(
                argv=argv,
                exit_code=0,
                stdout="main\t" + "a" * 40 + "\n",
                stderr="",
            )
        raise AssertionError(f"unexpected unbounded remote query: {argv}")
