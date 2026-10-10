"""Shared on-disk root for GitHub read caches, common to every worktree of one repo."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path


def _git_common_dir(repo: Path) -> Path | None:
    """Resolve the directory git shares across linked worktrees, from files alone."""

    dotgit = repo / ".git"
    if dotgit.is_dir():
        return dotgit.resolve()
    try:
        text = dotgit.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not text.startswith("gitdir:"):
        return None
    gitdir = (repo / text.partition(":")[2].strip()).resolve()
    try:
        commondir = gitdir / (gitdir / "commondir").read_text(encoding="utf-8").strip()
    except OSError:
        return gitdir
    return commondir.resolve()


def _token_identity() -> str:
    """Stable, non-reversible namespace for the credential; the token is never stored."""

    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]
    return "keyring"


def github_cache_dir(repo: Path) -> Path:
    """Cache root keyed by git common dir and token identity, shared by worktrees."""

    common = _git_common_dir(repo)
    base = (
        common / "kg-delivery-control" / "github"
        if common is not None
        else repo / ".cache" / "delivery-control" / "github"
    )
    return base / _token_identity()
