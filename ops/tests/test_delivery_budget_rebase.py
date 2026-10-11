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


def test_budget_rebase_opens_no_editor_on_a_dumb_terminal(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """CI has no editor and TERM=dumb; the rebase must finish without asking for a message."""
    repo = build_lane(tmp_path, clash=False, lane_grows=True)
    for name in ("GIT_EDITOR", "EDITOR", "VISUAL"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("TERM", "dumb")

    rebase(repo)

    assert sh(repo, "git", "log", "-1", "--format=%s") == (
        "chore(ops): raise complexity ceiling after rebase onto origin/main"
    )
    assert sh(repo, "git", "status", "--porcelain") == ""


def build_fork_credit_lane(tmp_path: Path) -> Path:
    """The lane forked with 30 lines of ceiling room; trunk later spends all but one of them.

    Fork (C0): ops 100 lines, ceiling 130.  The lane adds 10 ops lines and raises the ceiling to 160.
    Trunk (C1): adds 25 ops lines and lowers the ceiling to 126, so the rebase conflicts on the
    ceiling line and deliver takes trunk's 126.  Against C1 the lane has 1 line of room and grew 10,
    so it is over.  Only its fork's 30 lines would excuse it, and CI never sees that fork.
    """
    repo = tmp_path / "repo"
    repo.mkdir()
    sh(repo, "git", "init", "-q", "-b", "main")
    sh(repo, "git", "config", "user.email", "t@example.com")
    sh(repo, "git", "config", "user.name", "T")
    write(repo, "ops/a.py", "a\n" * 100)
    write(repo, "docs/d.md", "d\n" * 5)
    write(repo, ".github/workflows/w.yml", "w\n" * 5)
    write(repo, BUDGET, budget_text(130))
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-qm", "base")

    sh(repo, "git", "switch", "-q", "-c", "lane")
    write(repo, "ops/b.py", "b\n" * 10)
    write(repo, BUDGET, budget_text(160))
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-qm", "feat(ops): lane growth (#3004)")

    sh(repo, "git", "switch", "-q", "main")
    write(repo, "ops/a.py", "a\n" * 125)
    write(repo, BUDGET, budget_text(126))
    sh(repo, "git", "commit", "-qam", "chore: trunk moves on")
    sh(repo, "git", "update-ref", "refs/remotes/origin/main", "main")
    sh(repo, "git", "switch", "-q", "lane")
    return repo


def test_lift_judges_the_lane_without_its_fork_point(tmp_path: Path) -> None:
    repo = build_fork_credit_lane(tmp_path)
    rebase(repo)

    # 135 measured against trunk's 126 is 10 lines of lane growth over 1 line of base room.  The
    # raise is judged the way CI judges it (no fork point), so it holds in both views.
    ceilings = json.loads(sh(repo, "git", "show", f"HEAD:{BUDGET}"))["ceilings"]
    assert ceilings["ops"] == 140
    assert "- ops: 126 -> 140 (measured 135 + 5)" in sh(
        repo, "git", "log", "-1", "--format=%B"
    )
    assert complexity.main(["check", "--no-fork-points"], repo=repo) == 0
    assert complexity.main(["check"], repo=repo) == 0


@pytest.mark.parametrize(
    ("failure", "raised", "match"),
    [
        (OSError("disk full"), deliver.DeliverError, "budget lift failed"),
        (KeyboardInterrupt(), KeyboardInterrupt, None),
    ],
)
def test_a_failed_lift_rolls_the_rebase_back_so_a_rerun_completes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    failure: BaseException,
    raised: type[BaseException],
    match: str | None,
) -> None:
    repo = build_lane(tmp_path, clash=False, lane_grows=True)
    lane_tip = sh(repo, "git", "rev-parse", "HEAD")
    lane_budget = sh(repo, "git", "show", f"HEAD:{BUDGET}")
    real_lift = complexity.lift

    def lift_then_fail(path: Path, base: str | None = None):
        real_lift(path, base)  # writes the budget file, then the commit step is lost
        raise failure

    monkeypatch.setattr(complexity, "lift", lift_then_fail)
    with pytest.raises(raised, match=match):
        rebase(repo)
    # The whole rebase is undone: lane tip, budget file and worktree are as they were before.
    assert sh(repo, "git", "rev-parse", "HEAD") == lane_tip
    assert sh(repo, "git", "show", f"HEAD:{BUDGET}") == lane_budget
    assert sh(repo, "git", "status", "--porcelain") == ""
    assert not (repo / ".git" / "rebase-merge").exists()

    monkeypatch.setattr(complexity, "lift", real_lift)
    # A rerun redoes the rebase and the raise, instead of finding the lane already behind.
    rebase(repo)
    ceilings = json.loads(sh(repo, "git", "show", f"HEAD:{BUDGET}"))["ceilings"]
    assert ceilings["ops"] == 116
    assert sh(repo, "git", "log", "-1", "--format=%s") == (
        "chore(ops): raise complexity ceiling after rebase onto origin/main"
    )


def test_lift_never_raises_on_the_base_itself(tmp_path: Path) -> None:
    """HEAD equal to the base has no lane to charge: a red trunk must stay visible, unraised."""
    repo = tmp_path / "repo"
    repo.mkdir()
    sh(repo, "git", "init", "-q", "-b", "main")
    sh(repo, "git", "config", "user.email", "t@example.com")
    sh(repo, "git", "config", "user.name", "T")
    write(repo, "ops/a.py", "a\n" * 105)
    write(repo, BUDGET, budget_text(100))
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-qm", "base")
    sh(repo, "git", "update-ref", "refs/remotes/origin/main", "main")

    assert complexity.lift(repo, "origin/main") == {}
    assert (repo / BUDGET).read_text() == budget_text(100)
