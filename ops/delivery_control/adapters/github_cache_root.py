"""Shared on-disk root for GitHub read caches, common to every worktree of one repo."""

from __future__ import annotations

import hashlib
import os
import tempfile
from pathlib import Path


def _git_common_dir(repo: Path) -> Path | None:
    """Resolve the directory git shares across linked worktrees, from files alone.

    A removed lane has no live `.git`, so the nearest ancestor with one answers
    (lanes live under the canonical checkout's `.claude/worktrees/`). A `.git`
    file whose admin dir was pruned is dead and skipped, never recreated.
    """

    start = repo.resolve()
    for candidate in (start, *start.parents):
        dotgit = candidate / ".git"
        if dotgit.is_dir():
            return dotgit.resolve()
        try:
            text = dotgit.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if not text.startswith("gitdir:"):
            continue
        gitdir = (candidate / text.partition(":")[2].strip()).resolve()
        if not gitdir.is_dir():
            continue
        try:
            ref = (gitdir / "commondir").read_text(encoding="utf-8").strip()
        except OSError:
            return gitdir
        return (gitdir / ref).resolve()
    return None


def _token_identity() -> str:
    """Stable, non-reversible namespace for the credential; the token is never stored."""

    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]
    return "keyring"


def github_cache_dir(repo: Path) -> Path:
    """Cache root keyed by git common dir and token identity, shared by worktrees.

    Nothing resolves when no git dir sits above `repo`: fall back to the system
    temp dir, never under `repo`, so a dead worktree path gains no residue (#3404).
    """

    common = _git_common_dir(repo)
    base = (
        common / "kg-delivery-control" / "github"
        if common is not None
        else Path(tempfile.gettempdir()) / "kg-delivery-control" / "github"
    )
    return base / _token_identity()
