"""github_cache_dir never recreates residue under a removed lane worktree (#3404)."""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.github_cache_root import github_cache_dir
from delivery_control.adapters.github_client import GitHubCliClient
from delivery_control.ports.process import CommandResult


class _Runner:
    def __init__(self, stdout: str) -> None:
        self.stdout = stdout

    def run(self, argv: tuple[str, ...], *, cwd: Path | None = None) -> CommandResult:
        return CommandResult(argv, 0, self.stdout, "")


@pytest.fixture(autouse=True)
def _no_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)


def _canonical(tmp_path: Path) -> Path:
    canonical = tmp_path / "kg"
    (canonical / ".git").mkdir(parents=True)
    return canonical


@pytest.mark.parametrize("residue_dir", [False, True], ids=["lane-gone", "lane-dir"])
def test_removed_lane_resolves_to_canonical_common_dir(
    tmp_path: Path, residue_dir: bool
) -> None:
    canonical = _canonical(tmp_path)
    lane = canonical / ".claude" / "worktrees" / "issue-x-r1"
    if residue_dir:
        lane.mkdir(parents=True)

    cache = github_cache_dir(lane)

    assert cache.is_relative_to(canonical / ".git" / "kg-delivery-control" / "github")
    assert not any(lane.rglob("*"))


def test_pruned_admin_dir_is_dead_and_never_recreated(tmp_path: Path) -> None:
    canonical = _canonical(tmp_path)
    lane = canonical / ".claude" / "worktrees" / "issue-x-r1"
    lane.mkdir(parents=True)
    admin = canonical / ".git" / "worktrees" / "issue-x-r1"
    (lane / ".git").write_text(f"gitdir: {admin}\n", encoding="utf-8")

    cache = github_cache_dir(lane)

    assert cache.is_relative_to(canonical / ".git" / "kg-delivery-control" / "github")
    assert not admin.exists()
    assert not any(lane.rglob("*.json"))


def test_github_read_after_lane_removal_leaves_lane_clean(tmp_path: Path) -> None:
    canonical = _canonical(tmp_path)
    lane = canonical / ".claude" / "worktrees" / "issue-x-r1"
    http = 'HTTP/2.0 200 OK\r\nEtag: "v1"\r\n'
    http += "X-Ratelimit-Remaining: 4000\r\nX-Ratelimit-Reset: 4600\r\n"
    http += "X-Ratelimit-Resource: core\r\n\r\n[1]"
    client = GitHubCliClient(repo=lane, runner=_Runner(http), now=lambda: 1000.0)

    assert client.load_json(("gh", "api", "repos/owner/repo/pulls")) == [1]
    assert not any(lane.rglob("*"))
    assert any((canonical / ".git" / "kg-delivery-control").rglob("*.json"))


def test_no_git_anywhere_falls_back_to_system_temp_not_repo(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    system_tmp = tmp_path / "systmp"
    monkeypatch.setattr(tempfile, "gettempdir", lambda: str(system_tmp))
    repo = tmp_path / "orphan" / "lane"
    repo.mkdir(parents=True)

    cache = github_cache_dir(repo)

    assert cache == system_tmp / "kg-delivery-control" / "github" / "keyring"
    assert not (repo / ".cache").exists()
    assert not any(repo.iterdir())
