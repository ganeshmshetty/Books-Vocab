from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
REPO = OPS.parent
sys.path.insert(0, str(OPS))

import complexity
import doctor


def _budget(ops: int = 1000, docs: int = 500, workflows: int = 100) -> dict:
    return {
        "schema": complexity.SCHEMA,
        "slack": {"ops": 50, "docs": 20, "workflows": 5},
        "ceilings": {"ops": ops, "docs": docs, "workflows": workflows},
    }


MEASURED = {"ops": 900, "docs": 400, "workflows": 90, "reference": 300}


def _git_repo(tmp_path: Path, files: dict[str, str]) -> Path:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    for name, text in files.items():
        target = tmp_path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    subprocess.run(["git", "-C", str(tmp_path), "add", "-A"], check=True)
    return tmp_path


# ---- the repository itself must honour its budget (this is the teeth) ----------


def test_the_repository_is_within_its_complexity_budget(
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Same entry the operator runs: delta-aware on PRs, absolute on push to main."""
    code = complexity.main(["check", *complexity.ci_args()], repo=REPO)
    captured = capsys.readouterr()
    assert code == 0, captured.out + captured.err


# ---- measuring -----------------------------------------------------------------


def test_measure_counts_authored_lines_per_area_and_ignores_untracked_and_data_files(
    tmp_path: Path,
) -> None:
    repo = _git_repo(
        tmp_path,
        {
            "ops/a.py": "1\n2\n3\n",
            "ops/tests/b.py": "1\n",
            "docs/x.md": "1\n2\n",
            ".github/workflows/w.yml": "1\n",
            "ios/App.swift": "1\n2\n3\n4\n",
            "backend/ignored.py": "1\n" * 50,
            "ops/fixtures/world.json": "1\n" * 500,
            "ops/ui.plist": "1\n" * 40,
        },
    )
    (repo / "ops" / "untracked.py").write_text("1\n" * 99)
    assert complexity.measure(repo) == {
        "ops": 4,
        "docs": 2,
        "workflows": 1,
        "reference": 4,
    }


def test_a_file_without_a_trailing_newline_counts_like_wc(tmp_path: Path) -> None:
    repo = _git_repo(tmp_path, {"ops/a.py": "one\ntwo"})
    assert complexity.count_lines(repo, "ops/") == 1


# ---- evaluating ----------------------------------------------------------------


def test_each_area_is_judged_against_its_own_ceiling() -> None:
    rows = {
        r["area"]: r for r in complexity.evaluate({**MEASURED, "ops": 1001}, _budget())
    }
    assert rows["ops"]["over"] is True
    assert rows["ops"]["headroom"] == -1
    assert rows["docs"]["over"] is False
    assert rows["docs"]["headroom"] == 100


def test_exactly_at_the_ceiling_is_allowed() -> None:
    assert not any(
        r["over"] for r in complexity.evaluate({**MEASURED, "ops": 1000}, _budget())
    )


# ---- ratchet -------------------------------------------------------------------


def test_ratchet_lowers_to_measured_plus_slack() -> None:
    assert complexity.ratcheted(MEASURED, _budget()) == {
        "ops": 950,
        "docs": 420,
        "workflows": 95,
    }


def test_ratchet_never_raises_a_ceiling() -> None:
    grown = {**MEASURED, "ops": 5000, "docs": 5000, "workflows": 5000}
    assert complexity.ratcheted(grown, _budget()) == {
        "ops": 1000,
        "docs": 500,
        "workflows": 100,
    }


def test_ratchet_command_rewrites_the_file_only_when_something_drops(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _git_repo(
        tmp_path,
        {
            "ops/a.py": "1\n" * 10,
            "docs/x.md": "1\n",
            ".github/workflows/w.yml": "1\n",
            "ios/a.swift": "1\n",
        },
    )
    path = repo / complexity.BUDGET_FILE
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(_budget()))
    assert complexity.main(["ratchet"], repo=repo) == 0
    after = json.loads(path.read_text())["ceilings"]
    assert after == {"ops": 60, "docs": 21, "workflows": 6}
    assert "ratchet: wrote" in capsys.readouterr().out
    before = path.read_text()
    assert complexity.main(["ratchet"], repo=repo) == 0
    assert path.read_text() == before
    assert "nothing to lower" in capsys.readouterr().out


# ---- budget file validation ------------------------------------------------------


@pytest.mark.parametrize(
    "mutate",
    [
        lambda b: b.update(schema="wrong"),
        lambda b: b["ceilings"].pop("docs"),
        lambda b: b["slack"].pop("ops"),
    ],
)
def test_a_malformed_budget_is_rejected(tmp_path: Path, mutate) -> None:
    budget = _budget()
    mutate(budget)
    path = tmp_path / "b.json"
    path.write_text(json.dumps(budget))
    with pytest.raises(complexity.BudgetError):
        complexity.load_budget(path)


def test_an_unreadable_budget_is_a_usage_error_not_a_pass(tmp_path: Path) -> None:
    repo = _git_repo(tmp_path, {"ops/a.py": "1\n"})
    assert complexity.main(["check"], repo=repo) == 2


def test_check_fails_with_the_remedy_when_over(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _git_repo(tmp_path, {"ops/a.py": "1\n" * 30, "ios/a.swift": "1\n"})
    path = repo / complexity.BUDGET_FILE
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(_budget(ops=10)))
    assert complexity.main(["check"], repo=repo) == 1
    err = capsys.readouterr().err
    assert "over budget: ops" in err
    assert "raise the ceiling" in err


# ---- doctor integration ----------------------------------------------------------


def test_doctor_reports_over_budget_areas_by_name() -> None:
    rows = complexity.evaluate({**MEASURED, "docs": 600}, _budget())
    finding = doctor.evaluate_complexity(rows, 1.7)
    assert finding.level == "warn"
    assert finding.detail == ["docs: 600 lines > ceiling 500"]


def test_doctor_reports_the_tightest_area_when_within_budget() -> None:
    finding = doctor.evaluate_complexity(complexity.evaluate(MEASURED, _budget()), 1.72)
    assert finding.level == "ok"
    assert "workflows" in finding.summary
    assert "ops:ios 1.72" in finding.summary


def test_doctor_warns_when_the_budget_cannot_be_read() -> None:
    assert doctor.evaluate_complexity(None, None).level == "warn"


# ---- lane gate (#2679): a lane is charged for its own growth, not for main's state ----


def _commit(repo: Path, message: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), "-c", "user.email=t@t", "-c", "user.name=t"]
        + ["commit", "-q", "-m", message],
        check=True,
    )


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), "-c", "user.email=t@t", "-c", "user.name=t", *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _add(repo: Path, name: str, lines: int) -> None:
    (repo / name).write_text("1\n" * lines)
    _git(repo, "add", "-A")


def _headroom_repo(tmp_path: Path, ceiling: int = 40) -> Path:
    # base ops=30 lines; default ceiling 40 -> headroom 10 (slack 50 deliberately larger)
    repo = _git_repo(tmp_path, {"ops/a.py": "1\n" * 30, "ios/a.swift": "1\n"})
    (repo / complexity.BUDGET_FILE).write_text(json.dumps(_budget(ops=ceiling)))
    _git(repo, "add", "-A")
    _commit(repo, "base")
    return repo


def _check(repo: Path, *extra: str) -> int:
    return complexity.main(["check", "--base", "HEAD", *extra], repo=repo)


def test_a_lane_adding_more_than_the_base_headroom_fails_with_the_remedy(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _headroom_repo(tmp_path)
    _add(repo, "ops/big.py", 20)  # 20 > headroom 10, < slack 50
    assert _check(repo) == 1
    assert "raise the ceiling" in capsys.readouterr().err


def test_a_lane_adding_within_the_base_headroom_passes(tmp_path: Path) -> None:
    repo = _headroom_repo(tmp_path)
    _add(repo, "ops/small.py", 10)  # exactly the headroom
    assert _check(repo) == 0


def test_a_lane_that_raises_the_ceiling_passes_and_is_then_judged_against_it(
    tmp_path: Path,
) -> None:
    repo = _headroom_repo(tmp_path)
    _add(repo, "ops/big.py", 20)  # tree = 50
    (repo / complexity.BUDGET_FILE).write_text(json.dumps(_budget(ops=60)))
    assert _check(repo) == 0
    (repo / complexity.BUDGET_FILE).write_text(json.dumps(_budget(ops=45)))
    assert _check(repo) == 1  # bumped, but still not enough


def test_a_red_base_tolerates_only_a_change_that_adds_nothing_and_warns(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _headroom_repo(tmp_path, ceiling=10)  # base 30 > ceiling 10
    assert _check(repo) == 0
    err = capsys.readouterr()
    assert "WARNING" in err.err and "rebaseline" in err.err
    _add(repo, "ops/b.py", 1)
    assert _check(repo) == 1


def test_two_sibling_lanes_each_fitting_the_base_headroom_both_pass(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _headroom_repo(tmp_path)  # headroom 10
    trunk = _git(repo, "branch", "--show-current")
    _git(repo, "checkout", "-q", "-b", "lane-a")
    _add(repo, "ops/a_lane.py", 8)
    _commit(repo, "lane A")
    _git(repo, "checkout", "-q", trunk)
    _git(repo, "checkout", "-q", "-b", "lane-b")
    _add(repo, "ops/b_lane.py", 8)
    _commit(repo, "lane B")
    # trunk now contains A; B's merge-base with trunk is still the original base
    _git(repo, "checkout", "-q", trunk)
    _git(repo, "merge", "-q", "--no-ff", "-m", "A", "lane-a")
    _git(repo, "checkout", "-q", "lane-b")
    assert complexity.main(["check", "--base", trunk], repo=repo) == 0
    # the CI merge commit (trunk + B): absolute 46 > 40 is a warning, not a failure
    _git(repo, "checkout", "-q", trunk)
    _git(repo, "merge", "-q", "--no-ff", "-m", "B", "lane-b")
    assert complexity.main(["check", "--base", "HEAD^1"], repo=repo) == 0
    assert "WARNING" in capsys.readouterr().err


def _rebased_sibling(tmp_path: Path, own_lines: int) -> tuple[Path, str]:
    """Base headroom 10; lane A (8 lines) is merged to trunk; lane B (``own_lines``) is rebased on it."""
    repo = _headroom_repo(tmp_path)
    trunk = _git(repo, "branch", "--show-current")
    _git(repo, "checkout", "-q", "-b", "lane-a")
    _add(repo, "ops/a_lane.py", 8)
    _commit(repo, "lane A")
    _git(repo, "checkout", "-q", trunk)
    _git(repo, "checkout", "-q", "-b", "lane-b")
    _add(repo, "ops/b_lane.py", own_lines)
    _commit(repo, "lane B")
    _git(repo, "checkout", "-q", trunk)
    _git(repo, "merge", "-q", "--no-ff", "-m", "A", "lane-a")
    _git(repo, "checkout", "-q", "lane-b")
    _git(repo, "rebase", "-q", trunk)  # what deliver.py does before the checks
    return repo, trunk


def test_a_sibling_rebased_onto_main_keeps_its_original_fork_allowance(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo, trunk = _rebased_sibling(tmp_path, 8)
    assert complexity.main(["check", "--base", trunk], repo=repo) == 0
    assert "WARNING" in capsys.readouterr().err  # 46 > 40, but B's own 8 fits its 10


def test_a_rebased_sibling_whose_own_delta_exceeds_the_original_headroom_fails(
    tmp_path: Path,
) -> None:
    repo, trunk = _rebased_sibling(tmp_path, 12)
    assert complexity.main(["check", "--base", trunk], repo=repo) == 1


def test_fork_base_env_overrides_the_reflog(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo, trunk = _rebased_sibling(tmp_path, 8)
    original = _git(repo, "merge-base", "lane-b", "lane-a^")
    _git(repo, "checkout", "-q", "--detach")  # no branch -> no reflog fork
    assert complexity.main(["check", "--base", trunk], repo=repo) == 1
    monkeypatch.setenv("KG_COMPLEXITY_FORK_BASE", original)
    assert complexity.main(["check", "--base", trunk], repo=repo) == 0


def test_a_missing_object_at_the_base_falls_back_to_absolute_not_a_crash(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _headroom_repo(tmp_path)

    def broken(*_a, **_k):
        raise IndexError("missing")

    monkeypatch.setattr(complexity, "count_lines_at", broken)
    assert _check(repo) == 0
    assert "absolute" in capsys.readouterr().err


def test_main_itself_over_budget_fails_without_a_base_flag(tmp_path: Path) -> None:
    repo = _headroom_repo(tmp_path, ceiling=10)
    assert complexity.main(["check"], repo=repo) == 1  # HEAD is the base: absolute


def test_absolute_mode_fails_when_over_budget_whatever_the_lane_added(
    tmp_path: Path,
) -> None:
    repo = _headroom_repo(tmp_path, ceiling=10)
    assert _check(repo, "--absolute") == 1
    assert _check(repo, "--strict") == 1


def test_base_count_uses_the_same_counting_rule_as_the_tree(tmp_path: Path) -> None:
    repo = _git_repo(
        tmp_path,
        {
            "ops/a.py": "one\ntwo",  # no trailing newline
            "ops/world.json": "1\n" * 50,  # data, ignored
            "docs/x.md": "1\n",
            ".github/workflows/w.yml": "1\n",
        },
    )
    _commit(repo, "base")
    for name, prefix in complexity.AREAS.items():
        assert complexity.count_lines_at(
            repo, "HEAD", prefix
        ) == complexity.count_lines(repo, prefix), name


def test_a_change_to_a_data_file_costs_nothing(tmp_path: Path) -> None:
    repo = _headroom_repo(tmp_path)
    _add(repo, "ops/world.json", 500)
    assert _check(repo) == 0


def test_no_usable_base_falls_back_to_absolute_and_says_so(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _git_repo(tmp_path, {"ops/a.py": "1\n" * 30, "ios/a.swift": "1\n"})
    path = repo / complexity.BUDGET_FILE
    path.write_text(json.dumps(_budget(ops=10)))
    assert complexity.main(["check"], repo=repo) == 1
    assert "absolute" in capsys.readouterr().err


def test_ci_entry_is_strict_on_push_and_delta_aware_on_pull_request() -> None:
    assert complexity.ci_args({"GITHUB_EVENT_NAME": "push"}) == ["--strict"]
    assert complexity.ci_args({"GITHUB_EVENT_NAME": "pull_request"}) == []
    assert complexity.ci_args({}) == []


def test_the_ci_test_uses_the_check_entry_point_with_a_red_base(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = _headroom_repo(tmp_path, ceiling=10)
    monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request")
    assert (
        complexity.main(["check", "--base", "HEAD", *complexity.ci_args()], repo=repo)
        == 0
    )
    monkeypatch.setenv("GITHUB_EVENT_NAME", "push")
    assert (
        complexity.main(["check", "--base", "HEAD", *complexity.ci_args()], repo=repo)
        == 1
    )


def test_merge_group_head_is_charged_against_main_tip_headroom_not_the_pr_fork(
    tmp_path: Path,
) -> None:
    """#2869: A (8) merged, group head = merge(main, B (8)); 16 > headroom 10 must be red."""
    repo = _headroom_repo(tmp_path)
    trunk = _git(repo, "branch", "--show-current")
    _git(repo, "checkout", "-q", "-b", "lane-a")
    _add(repo, "ops/a_lane.py", 8)
    _commit(repo, "lane A")
    _git(repo, "checkout", "-q", trunk)
    _git(repo, "checkout", "-q", "-b", "lane-b")
    _add(repo, "ops/b_lane.py", 8)
    _commit(repo, "lane B")
    _git(repo, "checkout", "-q", trunk)
    _git(repo, "merge", "-q", "--no-ff", "-m", "A", "lane-a")
    _git(repo, "checkout", "-q", "-b", "group")
    _git(repo, "merge", "-q", "--no-ff", "-m", "group", "lane-b")
    argv = ["check", "--base", trunk]
    assert complexity.main(argv, repo=repo) == 0  # PR-style: B alone fits its fork
    assert complexity.main([*argv, "--no-fork-points"], repo=repo) == 1


# ---- per-lane budget fragments (#3155): a raise is a file, so lanes never share a line ----

FRAGMENTS = "ops/complexity_budget.d"


def _base(repo: Path, ops: int = 1000, docs: int = 500, workflows: int = 100) -> None:
    path = repo / complexity.BUDGET_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(_budget(ops=ops, docs=docs, workflows=workflows)))


def _payload(
    raises: dict | None = None,
    *,
    schema: str = "kg.complexity-budget-raise.v1",
    issue: object = 3155,
    note: str = "why",
) -> dict:
    return {
        "schema": schema,
        "issue": issue,
        "raise": {"ops": 1} if raises is None else raises,
        "note": note,
    }


def _fragment(repo: Path, name: str, raises: dict, *, note: str = "why") -> Path:
    path = repo / FRAGMENTS / f"{name}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(_payload(raises, note=note)))
    return path


def test_fragments_add_to_the_base_ceiling(tmp_path: Path) -> None:
    repo = _git_repo(
        tmp_path,
        {"ops/a.py": "1\n" * 10, "docs/x.md": "1\n", ".github/workflows/w.yml": "1\n"},
    )
    _base(repo, ops=1000)
    _fragment(repo, "lane-a", {"ops": 6})
    _fragment(repo, "lane-b", {"ops": 4, "docs": 3})
    budget = complexity.load_budget(repo / complexity.BUDGET_FILE)
    assert budget["ceilings"] == {"ops": 1010, "docs": 503, "workflows": 100}


def test_check_judges_against_the_effective_ceiling(tmp_path: Path) -> None:
    repo = _git_repo(tmp_path, {"ops/a.py": "1\n" * 1010, "ios/a.swift": "1\n"})
    _base(repo, ops=1000)
    _fragment(repo, "lane-a", {"ops": 10})
    assert complexity.main(["check"], repo=repo) == 0
    (repo / "ops" / "a.py").write_text("1\n" * 1011)
    assert complexity.main(["check"], repo=repo) == 1


def test_check_lists_the_fragments_it_applied(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _git_repo(tmp_path, {"ops/a.py": "1\n" * 10, "ios/a.swift": "1\n"})
    _base(repo, ops=5)
    _fragment(repo, "lane-a", {"ops": 6})
    assert complexity.main(["check"], repo=repo) == 0
    out = capsys.readouterr().out
    assert "lane-a" in out and "ops +6" in out


@pytest.mark.parametrize(
    "payload",
    [
        _payload({"ios": 3}),  # unknown area
        _payload({"ops": 0}),  # non-positive
        _payload({"ops": -2}),
        _payload({"ops": 2.5}),  # non-integer
        _payload({"ops": "5"}),
        _payload({"ops": True}),
        _payload({}),  # names no area
        _payload(schema="kg.complexity-budget-raise.v0"),  # wrong schema
        _payload(issue="3155"),
    ],
)
def test_a_malformed_fragment_is_a_usage_error_that_names_the_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], payload: dict
) -> None:
    repo = _git_repo(tmp_path, {"ops/a.py": "1\n", "ios/a.swift": "1\n"})
    _base(repo)
    path = repo / FRAGMENTS / "lane-bad.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload))
    assert complexity.main(["check"], repo=repo) == 2
    assert "lane-bad.json" in capsys.readouterr().err


def _lane_on_trunk(
    tmp_path: Path,
    trunk_files: dict[str, str],
    lane_files: dict[str, str],
    *,
    ops: int = 1000,
) -> tuple[Path, str]:
    """A trunk commit, then a lane branch committing ``lane_files`` on top.  HEAD is the lane, so
    ``raise --base <trunk>`` charges the lane's own growth.  Returns (repo, trunk branch name)."""
    repo = _git_repo(tmp_path, trunk_files)
    _base(repo, ops=ops)
    _git(repo, "add", "-A")
    _commit(repo, "trunk")
    trunk = _git(repo, "branch", "--show-current")
    _git(repo, "checkout", "-q", "-b", "lane-a")
    for name, text in lane_files.items():
        (repo / name).parent.mkdir(parents=True, exist_ok=True)
        (repo / name).write_text(text)
    _git(repo, "add", "-A")
    _commit(repo, "lane")
    return repo, trunk


def test_raise_writes_a_fragment_for_the_areas_the_lane_is_over_only(
    tmp_path: Path,
) -> None:
    repo, trunk = _lane_on_trunk(
        tmp_path,
        {
            "ops/a.py": "1\n" * 1000,
            "docs/x.md": "1\n",
            ".github/workflows/w.yml": "1\n",
        },
        {"ops/a.py": "1\n" * 1020},
    )
    argv = ["raise", "--base", trunk, "--issue", "3155", "--name", "lane-a"]
    assert complexity.main([*argv, "--note", "ops grew"], repo=repo) == 0
    assert json.loads((repo / FRAGMENTS / "lane-a.json").read_text()) == {
        "schema": "kg.complexity-budget-raise.v1",
        "issue": 3155,
        "raise": {
            "ops": 80
        },  # measured 1020 - effective 1000 + LIFT_MARGIN["ops"] 60; docs and workflows fit
        "note": "ops grew",
    }
    assert (
        json.loads((repo / complexity.BUDGET_FILE).read_text())["ceilings"]["ops"]
        == 1000
    )
    assert complexity.main(["check", "--base", trunk], repo=repo) == 0


def test_raise_tops_up_the_same_lane_fragment(tmp_path: Path) -> None:
    repo, trunk = _lane_on_trunk(
        tmp_path,
        {"ops/a.py": "1\n" * 1000, "ios/a.swift": "1\n"},
        {"ops/a.py": "1\n" * 1020},
    )
    argv = [
        "raise",
        "--base",
        trunk,
        "--issue",
        "3155",
        "--name",
        "lane-a",
        "--note",
        "x",
    ]
    assert complexity.main(argv, repo=repo) == 0
    (repo / "ops" / "a.py").write_text("1\n" * 1090)
    assert complexity.main(argv, repo=repo) == 0
    raised = json.loads((repo / FRAGMENTS / "lane-a.json").read_text())["raise"]
    assert raised == {"ops": 150}  # 80 + (1090 - 1080 + 60)
    assert (
        complexity.load_budget(repo / complexity.BUDGET_FILE)["ceilings"]["ops"] == 1150
    )


def test_the_lift_margin_is_per_area_ops_60_docs_30_workflows_10() -> None:
    assert complexity.LIFT_MARGIN == {"ops": 60, "docs": 30, "workflows": 10}
    measured = {"ops": 10, "docs": 10, "workflows": 10}
    ceilings = {"ops": 0, "docs": 0, "workflows": 0}
    assert complexity.plan_raise(measured, ceilings) == {
        "ops": 70,
        "docs": 40,
        "workflows": 20,
    }


def test_two_sibling_lanes_each_adding_the_ops_margin_compose_under_the_raised_ceiling(
    tmp_path: Path,
) -> None:
    # Base ops sits exactly at its ceiling (headroom 0). Each sibling adds 60 ops lines (its own margin) and
    # raises with `raise`: each lane passes alone, and the merged tree admits both without an OVER.
    repo = _git_repo(
        tmp_path,
        {"ops/a.py": "1\n" * 1000, "docs/x.md": "1\n", ".github/workflows/w.yml": "1\n"},
    )
    _base(repo, ops=1000)
    _git(repo, "add", "-A")
    _commit(repo, "base")
    trunk = _git(repo, "branch", "--show-current")
    for lane, module in (("lane-a", "a_lane.py"), ("lane-b", "b_lane.py")):
        _git(repo, "checkout", "-q", trunk)
        _git(repo, "checkout", "-q", "-b", lane)
        _add(repo, f"ops/{module}", 60)
        _git(repo, "add", "-A")
        _commit(repo, f"{lane}: growth")  # raise refuses while HEAD is the base
        argv = ["raise", "--base", trunk, "--name", lane, "--note", "sibling growth"]
        assert complexity.main(argv, repo=repo) == 0, lane
        _git(repo, "add", "-A")
        _commit(repo, f"{lane}: raise")
        assert complexity.main(["check", "--base", trunk], repo=repo) == 0, lane
    _git(repo, "checkout", "-q", trunk)
    _git(repo, "merge", "-q", "--no-ff", "-m", "A", "lane-a")
    _git(repo, "merge", "-q", "--no-ff", "-m", "B", "lane-b")
    # 1120 measured <= 1240 effective (1000 + 120 + 120): each raise covered its own 60 plus the margin
    assert complexity.main(["check", "--strict"], repo=repo) == 0


def test_raise_writes_nothing_when_the_lane_stays_within_its_headroom(
    tmp_path: Path,
) -> None:
    repo, trunk = _lane_on_trunk(
        tmp_path,
        {"ops/a.py": "1\n" * 10, "ios/a.swift": "1\n"},
        {"ops/b.py": "1\n" * 10},
    )  # 10 new lines against 990 of headroom
    argv = [
        "raise",
        "--base",
        trunk,
        "--issue",
        "3155",
        "--name",
        "lane-a",
        "--note",
        "x",
    ]
    assert complexity.main(argv, repo=repo) == 0
    assert not (repo / FRAGMENTS / "lane-a.json").exists()


def test_a_lane_that_grows_nothing_never_absorbs_a_red_trunk(tmp_path: Path) -> None:
    repo, trunk = _lane_on_trunk(
        tmp_path,
        {
            "ops/a.py": "1\n" * 1020,
            "ios/a.swift": "1\n",
        },  # trunk is already 20 over its 1000 ceiling
        {"ios/a.swift": "1\n" * 3},  # the lane adds no counted ops line
    )
    argv = [
        "raise",
        "--base",
        trunk,
        "--issue",
        "3155",
        "--name",
        "lane-a",
        "--note",
        "x",
    ]
    assert complexity.main(argv, repo=repo) == 0
    assert not (repo / FRAGMENTS / "lane-a.json").exists()
    assert complexity.main(["check", "--base", trunk], repo=repo) == 0  # WARNING only


def test_raise_is_refused_on_main_so_a_red_trunk_stays_visible(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _git_repo(tmp_path, {"ops/a.py": "1\n" * 1020, "ios/a.swift": "1\n"})
    _base(repo, ops=1000)
    _git(repo, "add", "-A")
    _commit(repo, "trunk")
    argv = [
        "raise",
        "--base",
        "HEAD",
        "--issue",
        "3155",
        "--name",
        "lane-a",
        "--note",
        "x",
    ]
    assert complexity.main(argv, repo=repo) == 2
    assert "HEAD is the base" in capsys.readouterr().err
    assert not (repo / FRAGMENTS).exists()
    assert complexity.main(["check", "--strict"], repo=repo) == 1


def test_raise_is_refused_without_a_readable_base(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo, _ = _lane_on_trunk(
        tmp_path,
        {"ops/a.py": "1\n" * 1000, "ios/a.swift": "1\n"},
        {"ops/a.py": "1\n" * 1020},
    )
    argv = [
        "raise",
        "--base",
        "no-such-ref",
        "--issue",
        "3155",
        "--name",
        "lane-a",
        "--note",
        "x",
    ]
    assert complexity.main(argv, repo=repo) == 2
    assert "no readable base" in capsys.readouterr().err
    assert not (repo / FRAGMENTS).exists()


def test_raise_on_a_detached_head_needs_an_explicit_name(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo, trunk = _lane_on_trunk(
        tmp_path,
        {"ops/a.py": "1\n" * 1000, "ios/a.swift": "1\n"},
        {"ops/a.py": "1\n" * 1020},
    )
    _git(repo, "checkout", "-q", "--detach")
    argv = ["raise", "--base", trunk, "--issue", "3155", "--note", "x"]
    assert complexity.main(argv, repo=repo) == 2
    assert "pass --name" in capsys.readouterr().err
    assert not (repo / FRAGMENTS).exists()


def test_raise_refuses_a_name_that_is_not_a_plain_file_name(tmp_path: Path) -> None:
    repo, trunk = _lane_on_trunk(
        tmp_path,
        {"ops/a.py": "1\n" * 1000, "ios/a.swift": "1\n"},
        {"ops/a.py": "1\n" * 1020},
    )
    argv = [
        "raise",
        "--base",
        trunk,
        "--issue",
        "3155",
        "--name",
        "../escape",
        "--note",
        "x",
    ]
    assert complexity.main(argv, repo=repo) == 2
    assert not (repo / "ops" / "escape.json").exists()


def test_fold_keeps_every_effective_ceiling_and_leaves_no_fragments(
    tmp_path: Path,
) -> None:
    repo = _git_repo(
        tmp_path,
        {"ops/a.py": "1\n" * 10, "docs/x.md": "1\n", ".github/workflows/w.yml": "1\n"},
    )
    _base(repo, ops=1000)
    _fragment(repo, "lane-a", {"ops": 6})
    _fragment(repo, "lane-b", {"ops": 4, "docs": 3})
    before = complexity.load_budget(repo / complexity.BUDGET_FILE)["ceilings"]
    assert complexity.main(["fold"], repo=repo) == 0
    assert list((repo / FRAGMENTS).glob("*.json")) == []
    assert json.loads((repo / complexity.BUDGET_FILE).read_text())["ceilings"] == before
    assert complexity.load_budget(repo / complexity.BUDGET_FILE)["ceilings"] == before


def test_ratchet_folds_the_fragments_into_the_base_when_it_lowers(
    tmp_path: Path,
) -> None:
    repo = _git_repo(
        tmp_path,
        {"ops/a.py": "1\n" * 100, "docs/x.md": "1\n", ".github/workflows/w.yml": "1\n"},
    )
    _base(repo, ops=1000)
    _fragment(repo, "lane-a", {"ops": 50})
    assert complexity.main(["ratchet"], repo=repo) == 0
    base = json.loads((repo / complexity.BUDGET_FILE).read_text())
    assert base["ceilings"] == {"ops": 150, "docs": 21, "workflows": 6}
    assert list((repo / FRAGMENTS).glob("*.json")) == []


def test_the_base_budget_carries_no_free_text_history() -> None:
    base = json.loads((REPO / complexity.BUDGET_FILE).read_text())
    assert set(base) == {"schema", "slack", "ceilings"}


def _two_fragment_lanes(tmp_path: Path) -> tuple[Path, str]:
    """Base ops 30 under ceiling 40 (headroom 10).  lane-a adds 20 and raises 15 (50 - 40 + 5); lane-b adds 12
    and raises 7 (42 - 40 + 5), the exact amount ``raise`` would write for it: both lanes are over their own headroom."""
    repo = _git_repo(tmp_path, {"ops/a.py": "1\n" * 30, "ios/a.swift": "1\n"})
    _base(repo, ops=40)
    _git(repo, "add", "-A")
    _commit(repo, "base")
    trunk = _git(repo, "branch", "--show-current")
    _git(repo, "checkout", "-q", "-b", "lane-a")
    _add(repo, "ops/a_lane.py", 20)
    _fragment(repo, "lane-a", {"ops": 15})
    _git(repo, "add", "-A")
    _commit(repo, "lane A")
    _git(repo, "checkout", "-q", trunk)
    _git(repo, "checkout", "-q", "-b", "lane-b")
    _add(repo, "ops/b_lane.py", 12)
    _fragment(repo, "lane-b", {"ops": 7})
    _git(repo, "add", "-A")
    _commit(repo, "lane B")
    _git(repo, "checkout", "-q", trunk)
    return repo, trunk


@pytest.mark.parametrize("first, second", [("lane-a", "lane-b"), ("lane-b", "lane-a")])
def test_two_lanes_each_adding_a_fragment_merge_in_either_order_without_a_conflict(
    tmp_path: Path, first: str, second: str
) -> None:
    repo, trunk = _two_fragment_lanes(tmp_path)
    for lane in (first, second):  # each lane passes its own PR gate against the base
        _git(repo, "checkout", "-q", lane)
        assert complexity.main(["check", "--base", trunk], repo=repo) == 0, lane
        _git(repo, "checkout", "-q", trunk)
    _git(repo, "merge", "-q", "--no-ff", "-m", first, first)
    before_second = _git(repo, "rev-parse", "HEAD")
    _git(
        repo, "merge", "-q", "--no-ff", "-m", second, second
    )  # raises CalledProcessError on conflict
    assert complexity.main(["check", "--base", before_second], repo=repo) == 0
    assert (
        complexity.main(["check", "--strict"], repo=repo) == 0
    )  # 62 measured (30 + 20 + 12) <= 62 effective (40 + 15 + 7): each raise covers exactly its own growth
