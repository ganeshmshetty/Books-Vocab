"""CAS-guarded removal of local worktree and branch assets.

The registry owns the local ownership disposition.  This module owns the
follow-up physical cleanup, and deliberately keeps remote branches outside its
mutation surface.  Every physical removal remains bound to exact clean
branch/worktree checks; native Git removal remains the final physical gate.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable
from pathlib import Path

from worktree_registry_core.handback_cli import is_commit_sha

Git = Callable[[list[str], Path], tuple[int, str]]
PathResolver = Callable[[str], Path]


def _local_branch_head(
    branch: str,
    *,
    root: Path,
    git: Git,
) -> tuple[str | None, str | None]:
    ref = f"refs/heads/{branch}"
    rc, output = git(["show-ref", "--verify", ref], root)
    if rc == 1 and not output.strip():
        return None, None
    if rc != 0:
        return None, f"local branch lookup failed: {output or 'unknown git error'}"
    fields = output.split()
    if len(fields) != 2 or fields[1] != ref or not is_commit_sha(fields[0]):
        return None, "local branch lookup returned malformed ref evidence"
    return fields[0], None


def _remote_branch_head(
    branch: str,
    *,
    root: Path,
    git: Git,
) -> tuple[str | None, str | None]:
    ref = f"refs/heads/{branch}"
    rc, output = git(["ls-remote", "origin", ref], root)
    if rc != 0:
        return None, f"remote branch lookup failed: {output or 'unknown git error'}"
    if not output.strip():
        return None, None
    fields = output.split()
    if len(fields) != 2 or fields[1] != ref or not is_commit_sha(fields[0]):
        return None, "remote branch lookup returned malformed ref evidence"
    return fields[0], None


def resolve_remove_target(
    args: argparse.Namespace,
    *,
    root: Path,
    path_resolver: PathResolver,
    git: Git,
) -> tuple[str | None, Path | None, str | None]:
    """Resolve and validate the exact local cleanup target without mutation."""

    worktree = path_resolver(args.path) if args.path else None
    branch = args.branch.strip() if isinstance(args.branch, str) else None
    if not branch:
        if worktree is None or not worktree.exists():
            return (
                None,
                worktree,
                "resolve --remove requires --branch when the worktree path is absent",
            )
        rc, output = git(["branch", "--show-current"], worktree)
        branch = output.strip() if rc == 0 else ""
        if not branch:
            return None, worktree, "cannot derive a branch from the target worktree"
    if branch in {"main", "master"}:
        return None, worktree, f"protected branch cannot be removed: {branch}"
    rc, _ = git(["check-ref-format", "--branch", branch], root)
    if rc != 0:
        return None, worktree, f"invalid local branch name: {branch}"
    if worktree is None:
        worktree = _worktree_for_branch(branch, root=root, git=git)
    if worktree == root:
        return None, worktree, "canonical repository worktree cannot be removed"
    return branch, worktree, None


def _worktree_for_branch(branch: str, *, root: Path, git: Git) -> Path | None:
    """Return the linked worktree that has `branch` checked out, if any."""

    rc, output = git(["worktree", "list", "--porcelain"], root)
    if rc != 0:
        return None
    worktree: Path | None = None
    for line in output.splitlines():
        if line.startswith("worktree "):
            worktree = Path(line[len("worktree ") :])
        elif line == f"branch refs/heads/{branch}":
            return worktree
    return None


def preflight_resolve_remove(
    *,
    branch: str,
    worktree: Path | None,
    expected_head_sha: str,
    root: Path,
    git: Git,
) -> str | None:
    """Check branch/worktree/remote invariants before registry CAS."""

    if not is_commit_sha(expected_head_sha):
        return "resolve --remove requires a valid expected HEAD SHA"
    local_head, problem = _local_branch_head(branch, root=root, git=git)
    if problem:
        return problem
    if local_head is not None and local_head != expected_head_sha:
        return (
            "local branch HEAD drifted before registry CAS: "
            f"expected {expected_head_sha}, observed {local_head}"
        )
    remote_head, problem = _remote_branch_head(branch, root=root, git=git)
    if problem:
        return problem
    if remote_head is not None:
        return f"remote branch exists; preserve local assets: {branch}"
    if worktree is None or not worktree.exists():
        return None
    rc, output = git(["status", "--porcelain"], worktree)
    if rc != 0:
        return f"target worktree status is unreadable: {output or 'unknown git error'}"
    if output.strip():
        return "target worktree is dirty; preserve it"
    rc, observed_branch = git(["branch", "--show-current"], worktree)
    if rc != 0 or observed_branch.strip() != branch:
        return (
            f"target worktree branch mismatch: expected {branch}, "
            f"observed {observed_branch.strip() or 'unknown'}"
        )
    return None


def cleanup_resolved_local_assets(
    *,
    branch: str,
    worktree: Path | None,
    expected_head_sha: str,
    root: Path,
    git: Git,
    exit_block: int,
    exit_ok: int,
) -> int:
    """Remove only exact local assets after a successful registry transition."""

    remote_head, problem = _remote_branch_head(branch, root=root, git=git)
    if problem:
        print(f"✗ resolve --remove blocked: {problem}", file=sys.stderr)
        return exit_block
    if remote_head is not None:
        print(
            f"✗ resolve --remove blocked: remote branch appeared after CAS: {branch}",
            file=sys.stderr,
        )
        return exit_block
    if worktree and worktree.exists():
        git_rc, output = git(["worktree", "remove", str(worktree)], root)
        if git_rc != 0:
            print(f"✗ worktree remove failed: {output}", file=sys.stderr)
            return exit_block
    elif worktree is not None:
        # Directory already gone but git still holds its registration; prune
        # stale entries so the checked-out branch becomes deletable.
        git_rc, output = git(["worktree", "prune"], root)
        if git_rc != 0:
            print(f"✗ worktree prune failed: {output}", file=sys.stderr)
            return exit_block
    local_head, problem = _local_branch_head(branch, root=root, git=git)
    if problem:
        print(f"✗ resolve --remove blocked: {problem}", file=sys.stderr)
        return exit_block
    if local_head is None:
        return exit_ok
    if local_head != expected_head_sha:
        print(
            "✗ resolve --remove blocked: local branch HEAD drifted after CAS: "
            f"expected {expected_head_sha}, observed {local_head}",
            file=sys.stderr,
        )
        return exit_block
    remote_head, problem = _remote_branch_head(branch, root=root, git=git)
    if problem:
        print(f"✗ resolve --remove blocked: {problem}", file=sys.stderr)
        return exit_block
    if remote_head is not None:
        print(
            "✗ resolve --remove blocked: remote branch appeared before local deletion: "
            f"{branch}",
            file=sys.stderr,
        )
        return exit_block
    git_rc, output = git(["branch", "-D", "--", branch], root)
    if git_rc != 0:
        print(f"✗ local branch removal failed: {output}", file=sys.stderr)
        return exit_block
    return exit_ok


__all__ = [
    "cleanup_resolved_local_assets",
    "preflight_resolve_remove",
    "resolve_remove_target",
]
