"""deliver's rebase onto origin/main resolves a budget-only conflict itself (#3004).

Real git on a fixture repo: a lane's ceiling line and trunk's ceiling line collide, and deliver
must take trunk's ceilings, finish the rebase, and raise only the areas the lane is over.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

import complexity
import deliver

BUDGET = complexity.BUDGET_FILE


def sh(repo: Path, *argv: str) -> str:
    done = subprocess.run(argv, cwd=repo, capture_output=True, text=True, check=True)
    return done.stdout.strip()


def write(repo: Path, rel: str, text: str) -> None:
    (repo / rel).parent.mkdir(parents=True, exist_ok=True)
    (repo / rel).write_text(text)


def budget_text(ops: int) -> str:
    data = {
        "schema": complexity.SCHEMA,
        "note": "fixture",
        "ceilings": {"ops": ops, "docs": 1000, "workflows": 1000},
        "slack": {"ops": 2000, "docs": 1000, "workflows": 250},
    }
    return json.dumps(data, indent=2) + "\n"


def build_lane(tmp_path: Path, *, clash: bool, lane_grows: bool) -> Path:
    """Fork at C0 (ops 100 lines, ceiling 100); lane raises the ceiling to 120; trunk moves to C1.

    ``clash`` makes both sides rewrite ``ops/a.py`` line 1 (a second, non-budget conflict).
    ``lane_grows`` adds 10 lines of ``ops/b.py`` to the lane commit.
    """
    repo = tmp_path / "repo"
    repo.mkdir()
    sh(repo, "git", "init", "-q", "-b", "main")
    sh(repo, "git", "config", "user.email", "t@example.com")
    sh(repo, "git", "config", "user.name", "T")
    write(repo, "ops/a.py", "a\n" * 100)
    write(repo, "docs/d.md", "d\n" * 5)
    write(repo, ".github/workflows/w.yml", "w\n" * 5)
    write(repo, BUDGET, budget_text(100))
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-qm", "base")

    sh(repo, "git", "switch", "-q", "-c", "lane")
    if clash:
        write(repo, "ops/a.py", "lane\n" + "a\n" * 99)
    if lane_grows:
        write(repo, "ops/b.py", "b\n" * 10)
    write(repo, BUDGET, budget_text(120))
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-qm", "feat(ops): lane growth (#3004)")

    sh(repo, "git", "switch", "-q", "main")
    if clash:
        write(repo, "ops/a.py", "main\n" + "a\n" * 99 + "m\n")
    else:
        write(repo, "ops/a.py", "a\n" * 100 + "m\n")
    write(repo, BUDGET, budget_text(101))
    sh(repo, "git", "commit", "-qam", "chore: trunk moves on")
    sh(repo, "git", "update-ref", "refs/remotes/origin/main", "main")
    sh(repo, "git", "switch", "-q", "lane")
    return repo


def rebase(repo: Path) -> deliver.Delivery:
    args = deliver.build_parser().parse_args(["--worktree", str(repo)])
    delivery = deliver.Delivery(args, deliver.run, lambda _s: None)
    delivery.rebase_if_behind()
    return delivery


def test_budget_only_conflict_takes_trunk_ceiling_and_raises_the_lane_overage(
    tmp_path: Path,
) -> None:
    repo = build_lane(tmp_path, clash=False, lane_grows=True)
    rebase(repo)

    # The lane's own 120 is gone; trunk's 101 was re-raised to measured (111) + LIFT_MARGIN.
    ceilings = json.loads(sh(repo, "git", "show", f"HEAD:{BUDGET}"))["ceilings"]
    assert ceilings == {"ops": 116, "docs": 1000, "workflows": 1000}
    # Rebase finished: the lane commit is replayed, then exactly one named raise commit on top.
    assert sh(repo, "git", "log", "-2", "--format=%s").splitlines() == [
        "chore(ops): raise complexity ceiling after rebase onto origin/main",
        "feat(ops): lane growth (#3004)",
    ]
    body = sh(repo, "git", "log", "-1", "--format=%B")
    assert "- ops: 101 -> 116 (measured 111 + 5)" in body
    assert "- docs" not in body and "- workflows" not in body
    assert sh(repo, "git", "status", "--porcelain") == ""
    assert not (repo / ".git" / "rebase-merge").exists()


def test_budget_plus_another_conflicted_path_still_aborts(tmp_path: Path) -> None:
    repo = build_lane(tmp_path, clash=True, lane_grows=True)
    lane_tip = sh(repo, "git", "rev-parse", "HEAD")

    with pytest.raises(deliver.DeliverError, match="does not rebase cleanly"):
        rebase(repo)

    assert sh(repo, "git", "rev-parse", "HEAD") == lane_tip
    assert sh(repo, "git", "status", "--porcelain") == ""
    assert not (repo / ".git" / "rebase-merge").exists()


def test_nothing_to_raise_leaves_the_budget_equal_to_trunk(tmp_path: Path) -> None:
    repo = build_lane(tmp_path, clash=False, lane_grows=False)
    rebase(repo)

    # The lane commit held only the ceiling line: trunk already carries it, so it is skipped
    # and HEAD is trunk itself, with no raise commit.
    assert sh(repo, "git", "rev-parse", "HEAD") == sh(
        repo, "git", "rev-parse", "origin/main"
    )
    assert sh(repo, "git", "show", f"HEAD:{BUDGET}") == sh(
        repo, "git", "show", f"origin/main:{BUDGET}"
    )
