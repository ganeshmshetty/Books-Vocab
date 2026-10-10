from __future__ import annotations

import argparse
import contextlib
import fcntl
import io
import json
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

import deliver
import worktree_orchestrate as coordinator
from delivery_control.adapters.operation_lock import OperationLock
from lib import worktree_scope

HEAD = "c" * 40
NEW_TIP = "d" * 40
BOT = "chatgpt-codex-connector[bot]"
HEAD_DATE = "2026-10-09T10:00:00Z"


def _review(
    status: str = "completed",
    conclusion: str = "success",
    job: bool = False,
    run: int = 1,
    output: dict[str, str] | None = None,
):
    """One `agent-review` check run: the Actions job, or a verdict it posted.

    Both name the workflow run that made them: the job by its details_url, the
    posted verdict by its external_id marker (as agent-review.yml writes them).
    """
    url = f"https://github.com/o/r/actions/runs/{run}"
    return {
        "name": "agent-review",
        "status": status,
        "conclusion": conclusion if status == "completed" else None,
        "external_id": "" if job else f"kg.agent-review.v1:{run}:{HEAD}",
        "details_url": f"{url}/job/9" if job else url,
        "output": output or {"title": None, "summary": None},
    }


class FakeWorld:
    """Scripts the answers of git/gh/registry/delivery and records every call."""

    def __init__(self, **state: Any) -> None:
        self.branch = state.get("branch", "feat/thing")
        self.dirty = state.get("dirty", False)
        self.ahead = state.get("ahead", "2")
        self.behind = state.get("behind", "0")
        self.rebase_ok = state.get("rebase_ok", True)
        self.record = state.get("record")
        self.prs = state.get("prs", [])
        self.checks = list(
            state.get("checks", [[{"name": "required", "state": "SUCCESS"}]])
        )
        self.pr_state = list(state.get("pr_state", ["MERGED"]))
        # `## Issues` body of the merged PR and the state GitHub reports per
        # linked Issue (a list is consumed one read at a time, last repeats).
        self.pr_body: str = state.get("pr_body", "")
        self.issue_states: dict[int, list[str]] = state.get("issue_states", {})
        self.merged_prs = state.get("merged_prs", {})
        self.diff = state.get("diff", "M\0ops/a.py\0A\0ops/b.py\0")
        self.fork = state.get("fork", "f" * 40)
        # origin/main; another delivery's fetch may move it during a lock wait
        # while HEAD (and so the merge-base) stays on the old main.
        self.trunk = self.fork
        self.trunk_moves_to: str | None = state.get("trunk_moves_to")
        self.changed_py = state.get("changed_py", ["ops/a.py", "ops/b.py"])
        self.format_rc = state.get("format_rc", 0)
        # ruff format rewrites the files (the worktree turns dirty) when True.
        self.format_changes = state.get("format_changes", False)
        self.format_pending = False
        self.fail_commands: set[str] = set(state.get("fail_commands", set()))
        self.stderr_for: dict[str, str] = state.get("stderr_for", {})
        self.lock_busy: dict[str, int] = dict(state.get("lock_busy", {}))
        self.now = 0.0
        self.sleeps: list[float] = []
        self.head = state.get("head", HEAD)
        self.review_runs = list(
            state.get("review_runs", [[_review(job=True), _review()]])
        )
        self.review_comments: list[dict[str, Any]] = state.get("review_comments", [])
        self.issue_comments: list[dict[str, Any]] = state.get("issue_comments", [])
        self.pr_reviews: list[dict[str, Any]] = state.get("pr_reviews", [])
        # Workflow runs by id (None: GitHub answers 404); a run not listed here
        # belongs to the PR whose head was last read, as the real ones do.
        self.actions_runs: dict[int, dict[str, Any] | None] = state.get(
            "actions_runs", {}
        )
        self.head_ref = state.get("head_ref", self.branch)
        self.viewed_pr = 0
        # Mid-redelivery change: the replaced PR is MERGED once this verb ran.
        self.merge_old_after = state.get("merge_old_after")
        # Per-branch registry/PR/remote facts that react to the mutations.
        self.records_by_branch: dict[str, list[dict[str, Any]]] = state.get(
            "records_by_branch", {}
        )
        self.prs_by_branch: dict[str, list[dict[str, Any]]] = state.get(
            "prs_by_branch", {}
        )
        self.remote_heads: dict[str, str] = state.get("remote_heads", {})
        # Hold/queue facts of the replaced PR, one dict per read (last repeats).
        self.pr_guard: list[dict[str, Any]] = list(state.get("pr_guard", []))
        # check runs of the merge group commit (the queue head), if any
        self.queue_runs: list[dict[str, Any]] = list(state.get("queue_runs", []))
        self.published_pr: dict[str, Any] | None = state.get(
            "published_pr", {"number": 77, "state": "OPEN", "url": "u"}
        )
        # How the new tip relates to the replaced lane's hand-back commit.
        self.old_is_ancestor: bool = state.get("old_is_ancestor", True)
        self.cherry: str = state.get("cherry", "")
        self.old_object_present: bool = state.get("old_object_present", True)
        self.calls: list[list[str]] = []
        self.cwds: list[Path | None] = []
        self.work = Path(tempfile.mkdtemp())
        self.canon = Path(tempfile.mkdtemp())

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds

    def names(self) -> list[str]:
        out = []
        for call in self.calls:
            if call[0].endswith("worktree_orchestrate.py"):
                out.append(call[1])
            elif call[0].endswith("delivery.py"):
                out.append(call[3])
        return out

    def __call__(self, cmd: list[str], cwd: Path | None) -> deliver.Proc:
        if cwd is not None and not cwd.exists():
            raise FileNotFoundError(cwd)  # what subprocess does in the real world
        self.calls.append(cmd)
        self.cwds.append(cwd)

        def ok(out: str = "") -> deliver.Proc:
            return deliver.Proc(0, out, "")

        head = cmd[0]
        if head == "bash":
            return deliver.Proc(
                1 if cmd[2] in self.fail_commands else 0,
                f"out of {cmd[2]}\nlast line\n",
                "",
            )
        if head == "git":
            sub = cmd[1:]
            while sub[:1] == ["-c"]:  # git -c key=value <subcommand>
                sub = sub[2:]
            if sub[:2] == ["rev-parse", "--abbrev-ref"]:
                return ok(self.branch)
            if sub[0] == "status":
                dirty = self.dirty or self.format_pending
                return ok(" M file\n" if dirty else "")
            if sub[0] == "fetch":
                return ok()
            if sub[0] == "rev-list":
                return ok(self.ahead if sub[2].endswith("..HEAD") else self.behind)
            if sub[0] == "rebase":
                if sub[1] == "--abort":
                    return ok()
                return deliver.Proc(
                    0 if self.rebase_ok else 1,
                    ""
                    if self.rebase_ok
                    else "CONFLICT (content): Merge conflict in ops/a.py\n",
                    "" if self.rebase_ok else "error: could not apply c0ffee0\n",
                )
            if sub[0] == "worktree":
                return ok(f"worktree {self.canon}\nHEAD abc\n")
            if sub[0] == "diff" and "--name-only" in sub:
                return ok("".join(f"{name}\n" for name in self.changed_py))
            if sub[0] == "diff":
                return ok(self.diff)
            if sub[0] == "add":
                return ok()
            if sub[0] == "commit":
                self.format_pending = False
                return ok("[branch abc1234] style: ruff format (pre-publish)\n")
            if sub[:2] == ["merge-base", "--is-ancestor"]:
                return deliver.Proc(0 if self.old_is_ancestor else 1, "", "")
            if sub[0] == "merge-base":
                return ok(self.fork)
            if sub[:2] == ["cat-file", "-e"]:
                return deliver.Proc(0 if self.old_object_present else 128, "", "")
            if sub[0] == "cherry":
                return ok(self.cherry)
            if sub[:2] == ["rev-parse", "--verify"]:
                return ok(NEW_TIP)
            if sub == ["rev-parse", deliver.TRUNK]:
                return ok(self.trunk)
            if sub[0] == "log":
                return ok("feat: the thing")
            if sub[0] == "rev-parse":
                return ok(str(self.canon))
            if sub[0] == "ls-remote":
                name = sub[2].removeprefix("refs/heads/")
                sha = self.remote_heads.get(name)
                return ok(f"{sha}\trefs/heads/{name}\n" if sha else "")
            if sub[0] == "push" and sub[-2] == "--delete":
                self.remote_heads.pop(sub[-1], None)
                return ok()
        if head == "uv":
            if self.format_rc:
                return deliver.Proc(self.format_rc, "", "error: Failed to parse a.py")
            self.format_pending = self.format_changes
            return ok("1 file reformatted\n" if self.format_changes else "")
        if head == "gh":
            if cmd[1:3] == ["repo", "view"]:
                return ok("o/r")
            if cmd[1:3] == ["pr", "close"]:
                for pr in sum(self.prs_by_branch.values(), []):
                    if str(pr["number"]) == cmd[3]:
                        pr["state"] = "CLOSED"
                return ok()
            if cmd[1:3] == ["pr", "list"] and "--head" in cmd:
                listed = self.prs_by_branch.get(cmd[cmd.index("--head") + 1])
                if listed is not None:
                    return ok(json.dumps(listed))
            if cmd[1:3] == ["pr", "list"]:
                if "merged" in cmd:
                    return ok(
                        str(self.merged_prs.get(cmd[cmd.index("--head") + 1], ""))
                    )
                if self.prs:
                    return ok(json.dumps(self.prs))
                published = (
                    [self.published_pr]
                    if self.published_pr
                    and any(
                        c[0].endswith("delivery.py") and c[3] == "publish"
                        for c in self.calls
                    )
                    else []
                )
                return ok(json.dumps(published))
            if cmd[1:3] == ["pr", "checks"]:
                batch = self.checks.pop(0) if len(self.checks) > 1 else self.checks[0]
                return ok(json.dumps(batch))
            if cmd[1:3] == ["api", "graphql"]:
                number = int(_value(cmd, "number=", prefix=True))
                pr = next(
                    p
                    for p in sum(self.prs_by_branch.values(), [])
                    if p["number"] == number
                )
                guard = self.pr_guard
                extra = guard.pop(0) if len(guard) > 1 else (guard or [{}])[0]
                node = {
                    "number": number,
                    "state": pr["state"],
                    "body": "",
                    "labels": {"nodes": []},
                    "autoMergeRequest": None,
                    "mergeQueueEntry": None,
                    **extra,
                }
                return ok(json.dumps({"data": {"repository": {"pullRequest": node}}}))
            if cmd[1] == "api" and "/pulls?state=closed" in cmd[-1]:
                closed = [
                    {
                        "number": number,
                        "merged_at": "2026-10-09T00:00:00Z",
                        "head": {"ref": branch, "sha": self.head},
                    }
                    for branch, number in self.merged_prs.items()
                ]
                closed.append(  # closed without merging: never a gc candidate
                    {"number": 5, "merged_at": None, "head": {"ref": "feat/open"}}
                )
                return ok(json.dumps([closed]))
            if cmd[1] == "api" and f"/commits/{QUEUE_HEAD}/check-runs" in cmd[-1]:
                return ok(json.dumps([{"check_runs": self.queue_runs}]))
            if cmd[1] == "api" and "/check-runs?" in cmd[-1]:
                runs = self.review_runs
                batch = runs.pop(0) if len(runs) > 1 else runs[0]
                return ok(
                    json.dumps([{"total_count": len(batch), "check_runs": batch}])
                )
            if cmd[1] == "api" and "/actions/runs/" in cmd[-1]:
                run_id = int(cmd[-1].rsplit("/", 1)[1])
                found = self.actions_runs.get(
                    run_id,
                    {
                        "event": "pull_request_target",
                        "head_branch": self.head_ref,
                        "pull_requests": [{"number": self.viewed_pr}],
                    },
                )
                if found is None:
                    return deliver.Proc(1, "", "gh: Not Found (HTTP 404)")
                return ok(json.dumps({"id": run_id, **found}))
            if cmd[1] == "api" and cmd[2].endswith(f"/commits/{self.head}"):
                return ok(HEAD_DATE + "\n")
            if cmd[1] == "api" and "/issues/" in cmd[-1]:
                return ok(json.dumps([self.issue_comments]))
            if cmd[1] == "api" and cmd[-1].endswith("/reviews?per_page=100"):
                return ok(json.dumps([self.pr_reviews]))
            if cmd[1] == "api" and cmd[-1].endswith("/comments?per_page=100"):
                return ok(json.dumps([self.review_comments]))
            if cmd[1:3] == ["issue", "view"]:
                reads = self.issue_states.get(int(cmd[3]), ["CLOSED"])
                return ok(reads.pop(0) if len(reads) > 1 else reads[0])
            if cmd[1:3] == ["pr", "view"] and cmd[cmd.index("--json") + 1] == "body":
                return ok(self.pr_body)
            if cmd[1:3] == ["pr", "view"]:
                self.viewed_pr = int(cmd[3])
            if cmd[1:3] == ["pr", "view"] and "headRefOid,headRefName" in cmd:
                return ok(
                    json.dumps({"headRefOid": self.head, "headRefName": self.head_ref})
                )
            if cmd[1:3] == ["pr", "view"]:
                return ok(
                    self.pr_state.pop(0) if len(self.pr_state) > 1 else self.pr_state[0]
                )
        if head.endswith("worktree_registry.py"):
            branch = cmd[cmd.index("--branch") + 1] if "--branch" in cmd else None
            if branch in self.records_by_branch:
                return ok(json.dumps({"records": self.records_by_branch[branch]}))
            return ok(json.dumps({"records": [self.record] if self.record else []}))
        if head.endswith(("worktree_orchestrate.py", "delivery.py")):
            verb = cmd[1] if head.endswith("worktree_orchestrate.py") else cmd[3]
            if self.lock_busy.get(verb, 0) > 0:  # the lock is taken before any change
                self.lock_busy[verb] -= 1
                if self.trunk_moves_to:  # the holder's sync-main fetched a new main
                    self.trunk = self.trunk_moves_to
                if head.endswith("delivery.py"):  # its CLI reports one JSON error
                    doc = {"command": verb, "error": _LOCKED, "ok": False}
                    return deliver.Proc(1, "", json.dumps(doc))
                return deliver.Proc(1, "", f"Traceback\nDeliverySourceError: {_LOCKED}")
            if verb == "resolve" and "--branch" in cmd:
                for record in self.records_by_branch.get(
                    cmd[cmd.index("--branch") + 1], []
                ):
                    record["status"] = cmd[cmd.index("--status") + 1]
            if verb == "publish":
                shutil.rmtree(
                    self.work, ignore_errors=True
                )  # publish retires the lane worktree
            if verb == self.merge_old_after:
                for old in self.prs_by_branch.get(OLD, []):
                    old["state"] = "MERGED"
            failing = verb in self.fail_commands
            if failing:
                return deliver.Proc(1, "", self.stderr_for.get(verb, "boom"))
            return ok("{}")
        raise AssertionError(f"unscripted call: {cmd}")


_LOCKED = (
    "delivery mutation already in progress; command=sync-main; "
    "retry after the active operation exits"
)


def ship(world: FakeWorld, *flags: str) -> tuple[int, dict[str, Any]]:
    argv = ["--timeout", "5", "--poll", "1"]
    if "--worktree" not in flags:
        argv += ["--worktree", str(world.work)]
    command = ["redeliver"] if flags[:1] == ("redeliver",) else []
    argv = [*command, *argv, *flags[len(command) :]]  # options follow redeliver
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
        code = deliver.main(
            argv, runner=world, sleep=world.sleep, clock=lambda: world.now
        )
    return code, json.loads(buf.getvalue().strip().splitlines()[-1])


# ---- pure helpers ---------------------------------------------------------


def test_scope_covers_add_modify_delete_and_splits_a_rename() -> None:
    scope = deliver.scope_from_name_status(
        "A\0new.py\0M\0old.py\0D\0gone.py\0R100\0from.py\0to.py\0"
    )
    assert scope["schema"] == "kg.worktree.scope.v1"
    assert scope["files"] == [
        {"operation": "add", "path": "new.py"},
        {"operation": "modify", "path": "old.py"},
        {"operation": "delete", "path": "gone.py"},
        {"operation": "delete", "path": "from.py"},
        {"operation": "add", "path": "to.py"},
    ]


def test_scope_from_nul_name_status_keeps_non_ascii_paths_unquoted() -> None:
    scope = deliver.scope_from_name_status(
        "M\0docs/reference/架構.rtf\0R100\0舊.md\0新.md\0A\0ops/x.py\0"
    )
    assert scope["files"] == [
        {"operation": "modify", "path": "docs/reference/架構.rtf"},
        {"operation": "delete", "path": "舊.md"},
        {"operation": "add", "path": "新.md"},
        {"operation": "add", "path": "ops/x.py"},
    ]
    worktree_scope.normalise_scope(scope)


def test_a_truncated_nul_name_status_is_refused() -> None:
    with pytest.raises(deliver.DeliverError):
        deliver.scope_from_name_status("R100\0only-old.md\0")


def test_an_unknown_git_status_is_refused_not_guessed() -> None:
    with pytest.raises(deliver.DeliverError):
        deliver.scope_from_name_status("U\0conflict.py\0")


def test_lane_id_is_derived_from_the_branch() -> None:
    assert (
        deliver.lane_from_branch("fix/a_b.c", "20261007")
        == "DIRECT-DELIVERY-FIX-A-B-C-20261007"
    )


@pytest.mark.parametrize("spec", ["nocommand", "=cmd", "label=", ""])
def test_malformed_check_specs_are_rejected(spec: str) -> None:
    with pytest.raises(deliver.DeliverError):
        deliver.parse_check(spec)


def test_check_outcomes_come_from_exit_codes_and_run_to_the_end() -> None:
    world = FakeWorld(fail_commands={"bad"})
    outcomes = deliver.run_checks(
        ["one=good", "two=bad", "three=good"], Path("."), world
    )
    assert [o["status"] for o in outcomes] == ["passed", "failed", "passed"]
    assert outcomes[0]["detail"] == "last line"
    assert [o["check"] for o in outcomes] == ["one", "two", "three"]


@pytest.mark.parametrize(
    ("record", "pr", "expected"),
    [
        (None, None, "adopt"),
        ({"status": "active"}, None, "hand-back"),
        ({"status": "active", "handback_seal": {"x": 1}}, None, "receipt"),
        ({"status": "published"}, None, "wait-required"),
        (None, {"state": "OPEN", "number": 1}, "wait-required"),
        ({"status": "published"}, {"state": "OPEN", "number": 1}, "wait-required"),
        ({"status": "active"}, {"state": "OPEN", "number": 1}, "hand-back"),
        (
            {"status": "active", "handback_seal": {"x": 1}},
            {"state": "OPEN", "number": 1},
            "receipt",
        ),
        (
            {"status": "cleanup_pending"},
            {"state": "OPEN", "number": 1},
            "release-published",
        ),
        ({"status": "published"}, {"state": "MERGED", "number": 1}, "cleanup"),
    ],
)
def test_resume_point_follows_registry_and_github(
    record: Any, pr: Any, expected: str
) -> None:
    assert deliver.next_stage(record, pr) == expected


@pytest.mark.parametrize(
    ("record", "pr"),
    [({"status": "abandoned"}, None), (None, {"state": "CLOSED", "number": 3})],
)
def test_dead_lanes_and_closed_prs_are_not_resumed(record: Any, pr: Any) -> None:
    with pytest.raises(deliver.DeliverError):
        deliver.next_stage(record, pr)


def test_required_state_defaults_to_pending() -> None:
    assert deliver.required_state([]) == "PENDING"
    assert deliver.required_state([{"name": "other", "state": "SUCCESS"}]) == "PENDING"
    assert (
        deliver.required_state([{"name": "required", "state": "FAILURE"}]) == "FAILURE"
    )


# ---- the whole flow -------------------------------------------------------


def test_new_lane_runs_every_stage_in_order_and_stops_before_merge() -> None:
    world = FakeWorld()
    code, result = ship(world, "--check", "unit=good")
    assert code == 0
    assert result["result"] == "ready-to-merge"
    assert result["pr"] == 77
    assert world.names() == ["adopt", "hand-back", "receipt", "publish"]
    publish = next(
        c for c in world.calls if c[0].endswith("delivery.py") and c[3] == "publish"
    )
    assert "--replaces-pr" not in publish  # only redeliver excludes a PR


def _publish_call(world: FakeWorld) -> list[str]:
    return next(
        c for c in world.calls if c[0].endswith("delivery.py") and c[3] == "publish"
    )


def test_issue_flags_are_passed_through_to_publish() -> None:
    world = FakeWorld()
    code, _ = ship(
        world, "--check", "unit=good", "--closes", "2029", "--closes", "2030"
    )
    assert code == 0
    cmd = _publish_call(world)
    assert cmd[cmd.index("--closes") :] == ["--closes", "2029", "--closes", "2030"]
    assert "--refs" not in cmd


def test_publish_args_are_unchanged_without_issue_flags() -> None:
    world = FakeWorld()
    code, _ = ship(world, "--check", "unit=good")
    assert code == 0
    cmd = _publish_call(world)
    assert "--closes" not in cmd and "--refs" not in cmd


def test_merge_flag_queues_waits_and_cleans_up_from_the_canonical_checkout() -> None:
    world = FakeWorld()
    code, result = ship(world, "--check", "unit=good", "--merge")
    assert code == 0
    assert result["result"] == "merged"
    assert world.names() == [
        "adopt",
        "hand-back",
        "receipt",
        "publish",
        "queue",
        "cleanup-merged",
        "sync-main",
    ]


def test_a_failing_check_stops_before_anything_is_claimed() -> None:
    world = FakeWorld(fail_commands={"bad"})
    code, result = ship(world, "--check", "ok=good", "--check", "broken=bad")
    assert code == 1
    assert "broken" in result["error"]
    assert world.names() == []


def _noisy_runner(rc: int) -> Any:
    def runner(cmd: list[str], cwd: Path | None) -> deliver.Proc:
        out = "".join(f"stdout line {n}\n" for n in range(1, 101))
        return deliver.Proc(rc, out, "FAILED test_x - boom\n\n" if rc else "")

    return runner


def test_a_failed_check_shows_its_tail_on_stderr_and_keeps_the_full_log(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (outcome,) = deliver.run_checks(
        ["unit=pytest"],
        tmp_path,
        _noisy_runner(1),
        log_dir=tmp_path / "logs",
        tag="b/x",
    )
    err = capsys.readouterr().err
    assert "stdout line 100" in err and "FAILED test_x - boom" in err
    assert "stdout line 50\n" not in err  # only the tail, not the whole run
    assert outcome["detail"] == "stdout line 100"  # stdout wins; stderr is in tail+log
    log = Path(outcome["log"])
    assert log.parent == tmp_path / "logs" and log.name.startswith("b-x-unit-")
    text = log.read_text()
    assert "stdout line 1\n" in text and "stdout line 100" in text and "boom" in text


def test_detail_is_the_last_stdout_line_even_when_stderr_also_has_output() -> None:
    def runner(cmd: list[str], cwd: Path | None) -> deliver.Proc:
        return deliver.Proc(0, "collected\n3 passed in 1s\n", "warning: x\n")

    (ok,) = deliver.run_checks(["unit=x"], Path("."), runner)
    assert ok["detail"] == "3 passed in 1s"

    def stderr_only(cmd: list[str], cwd: Path | None) -> deliver.Proc:
        return deliver.Proc(1, "  \n", "oops\nreal reason\n")

    (bad,) = deliver.run_checks(["unit=x"], Path("."), stderr_only)
    assert bad["detail"] == "real reason"


def test_a_passed_check_is_logged_but_stays_quiet(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (outcome,) = deliver.run_checks(
        ["unit=pytest"], tmp_path, _noisy_runner(0), log_dir=tmp_path / "logs"
    )
    assert capsys.readouterr().err == ""
    assert "stdout line 1\n" in Path(outcome["log"]).read_text()


def test_checks_without_a_log_dir_keep_the_old_shape() -> None:
    (outcome,) = deliver.run_checks(["unit=x"], Path("."), _noisy_runner(0))
    assert "log" not in outcome


def test_a_failed_deliver_check_reports_its_log_in_json_and_never_seals_it() -> None:
    world = FakeWorld(fail_commands={"bad"})
    code, result = ship(world, "--check", "ok=good", "--check", "broken=bad")
    assert code == 1
    by_label = {c["check"]: c for c in result["checks"]}
    log = Path(by_label["broken"]["log"])
    assert world.canon / ".cache" / "deliver-checks" in log.parents
    assert "out of bad" in log.read_text()
    passed = Path(by_label["ok"]["log"])
    assert passed.is_file()
    ok_world = FakeWorld()
    sealed: list[Any] = []

    def spy(cmd: list[str], cwd: Path | None) -> deliver.Proc:
        if "--outcomes" in cmd:  # the temp file is gone after the run
            sealed.extend(
                json.loads(Path(cmd[cmd.index("--outcomes") + 1]).read_text())
            )
        return ok_world(cmd, cwd)

    argv = ["--timeout", "5", "--poll", "0", "--worktree", str(ok_world.work)]
    with (
        contextlib.redirect_stdout(io.StringIO()),
        contextlib.redirect_stderr(io.StringIO()),
    ):
        assert deliver.main([*argv, "--check", "ok=good"], runner=spy) == 0
    assert sealed and all("log" not in o for o in sealed)


def test_a_new_lane_without_any_check_is_refused() -> None:
    code, result = ship(FakeWorld())
    assert code == 1
    assert "--check" in result["error"]


def test_a_published_lane_resumes_without_rerunning_checks() -> None:
    world = FakeWorld(
        record={
            "branch": "feat/thing",
            "status": "published",
            "external_ids": ["LANE-1"],
        },
        prs=[{"number": 9, "state": "OPEN"}],
    )
    code, result = ship(world)
    assert code == 0
    assert result["lane"] == "LANE-1"
    assert not any(c[0] == "bash" for c in world.calls)
    assert world.names() == []


def test_an_open_pr_on_a_half_published_lane_completes_publish_not_ready() -> None:
    world = FakeWorld(
        record={
            "branch": "feat/thing",
            "status": "active",
            "handback_seal": {"x": 1},
            "base_sha": "f" * 40,
            "external_ids": ["LANE-1"],
        },
        prs=[{"number": 9, "state": "OPEN"}],
    )
    code, result = ship(world)
    assert code == 0
    assert world.names() == ["receipt", "publish"]
    assert result["result"] == "ready-to-merge"


def test_a_cleanup_pending_lane_with_an_open_pr_is_released_before_waiting() -> None:
    world = FakeWorld(
        record={
            "branch": "feat/thing",
            "status": "cleanup_pending",
            "external_ids": ["LANE-1"],
        },
        prs=[{"number": 9, "state": "OPEN"}],
    )
    code, _result = ship(world)
    assert code == 0
    assert world.names() == ["release-published"]


def test_a_merged_pr_goes_straight_to_cleanup() -> None:
    world = FakeWorld(prs=[{"number": 9, "state": "MERGED"}])
    code, _result = ship(world, "--merge")
    assert code == 0
    assert world.names() == ["cleanup-merged", "sync-main"]


def test_dirty_trees_and_trunk_branches_are_refused() -> None:
    assert ship(FakeWorld(dirty=True), "--check", "u=good")[0] == 1
    assert ship(FakeWorld(branch="main"), "--check", "u=good")[0] == 1
    assert ship(FakeWorld(ahead="0"), "--check", "u=good")[0] == 1


def test_a_branch_that_cannot_rebase_is_aborted_and_not_claimed() -> None:
    world = FakeWorld(behind="3", rebase_ok=False)
    code, result = ship(world, "--check", "u=good")
    assert code == 1
    assert "rebase" in result["error"]
    assert "CONFLICT (content): Merge conflict in ops/a.py" in result["error"]
    assert ["git", "rebase", "--abort"] in world.calls
    assert world.names() == []


def test_a_red_required_check_fails_the_run() -> None:
    world = FakeWorld(checks=[[{"name": "required", "state": "FAILURE"}]])
    code, result = ship(world, "--check", "u=good")
    assert code == 1
    assert "FAILURE" in result["error"]


def test_it_waits_while_required_is_pending() -> None:
    pending = [{"name": "required", "state": "IN_PROGRESS"}]
    world = FakeWorld(
        checks=[pending, pending, [{"name": "required", "state": "SUCCESS"}]]
    )
    code, _ = ship(world, "--check", "u=good")
    assert code == 0
    assert sum(1 for c in world.calls if c[1:3] == ["pr", "checks"]) == 3


def test_a_stage_failure_names_the_stage() -> None:
    world = FakeWorld(fail_commands={"hand-back"})
    code, result = ship(world, "--check", "u=good")
    assert code == 1
    assert result["error"].startswith("hand-back failed")
    assert world.names().count("hand-back") == 1  # a real failure is not retried


_GITHUB = "GraphQL: Pull request is in unstable status (enqueuePullRequest)"
_ADAPTER = (
    "command failed with exit 1: gh api graphql -f query=mutation {"
    + "x" * 2000
    + "} -F pullRequestId=PR_1: "
    + _GITHUB
)
_TRACE = "Traceback (most recent call last):\n" + "  frame\n" * 100 + "Boom: cause"


@pytest.mark.parametrize(
    ("verb", "stderr", "detail"),
    [
        (  # delivery.py: progress lines, then one JSON error document
            "queue",
            "reading PR\n"
            + json.dumps({"command": "queue", "error": _ADAPTER, "ok": False}),
            _ADAPTER,
        ),
        ("adopt", _TRACE, _TRACE),  # anything else: the whole stream
    ],
    ids=["delivery-json-error", "traceback"],
)
def test_a_failed_stage_surfaces_the_whole_underlying_error(
    verb: str, stderr: str, detail: str
) -> None:
    world = FakeWorld(fail_commands={verb}, stderr_for={verb: stderr})
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1
    assert result["error"] == f"{verb} failed (rc=1): {detail}"


# ---- the delivery mutation lock -------------------------------------------


def test_a_busy_mutation_lock_is_waited_out_instead_of_failing() -> None:
    world = FakeWorld(lock_busy={"adopt": 1, "queue": 2})  # traceback / JSON shapes
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 0, result
    assert world.names().count("adopt") == 2
    assert world.names().count("queue") == 3
    waits = [line for line in result["log"] if "operation lock" in line]
    assert len(waits) == 3 and all("command=sync-main" in line for line in waits)


def test_the_lock_wait_is_bounded_and_names_the_holder() -> None:
    world = FakeWorld(lock_busy={"publish": 99})
    code, result = ship(world, "--check", "u=good", "--lock-timeout", "12")
    assert code == 1
    assert world.names().count("publish") == 4
    assert world.sleeps == [5, 5, 2]
    assert "lock is still held after 12s" in result["error"]
    assert _LOCKED in result["error"]


def test_the_lock_marker_is_the_lock_adapters_own_message() -> None:
    adapter = OPS / "delivery_control" / "adapters" / "operation_lock.py"
    assert deliver.LOCK_BUSY in adapter.read_text()


# ---- the agent-review gate on --merge -------------------------------------


def _calls_at(world: FakeWorld, wanted: Callable[[list[str]], bool]) -> list[int]:
    return [i for i, call in enumerate(world.calls) if wanted(call)]


def _is_review_read(call: list[str]) -> bool:
    return call[:2] == ["gh", "api"] and "/check-runs?" in call[-1]


def _is_queue(call: list[str]) -> bool:
    return call[0].endswith("delivery.py") and call[3] == "queue"


_FINDING = {
    "user": {"login": BOT},
    "commit_id": HEAD,
    "original_commit_id": HEAD,
    "path": "ops/a.py",
    "line": 12,
    "body": "**P2 Handle the empty case**\n\nWhy it breaks.",
    "html_url": "https://github.com/o/r/pull/77#discussion_r1",
}


def test_merge_waits_for_agent_review_to_complete_on_the_exact_head() -> None:
    orphan = _review("in_progress")  # the marker of a run that was cancelled
    world = FakeWorld(
        review_runs=[
            [],
            [_review("in_progress", job=True), orphan],
            [_review(job=True), orphan, _review()],
        ]
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 0, result
    reads = _calls_at(world, _is_review_read)
    assert len(reads) == 3
    assert all(f"/commits/{HEAD}/check-runs?" in world.calls[i][-1] for i in reads)
    assert reads[-1] < _calls_at(world, _is_queue)[0]
    assert result["review"] == {
        "head": HEAD,
        "verdict": "success",
        "findings": [],
        "accepted": None,
        "accepted_no_review": None,
    }


def test_merge_refuses_to_queue_when_agent_review_failed() -> None:
    failed = [_review(conclusion="failure", job=True), _review(conclusion="failure")]
    world = FakeWorld(review_runs=[failed])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1
    assert f"agent-review failed on {HEAD}" in result["error"]
    assert "--accept-review-findings" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_merge_refuses_on_inline_review_comments_on_the_head_and_lists_them() -> None:
    ignored = [
        {**_FINDING, "user": {"login": "someone"}},  # not the review bot
        {**_FINDING, "commit_id": "d" * 40, "original_commit_id": "d" * 40},
    ]
    world = FakeWorld(review_comments=[_FINDING, *ignored])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1
    assert f"1 inline review comment(s) on {HEAD}" in result["error"]
    assert (
        "ops/a.py:12: **P2 Handle the empty case** "
        "https://github.com/o/r/pull/77#discussion_r1"
    ) in result["error"]
    assert result["error"].count("ops/a.py:12") == 1
    assert not _calls_at(world, _is_queue)


def test_an_explicit_reason_accepts_the_review_findings_and_queues() -> None:
    world = FakeWorld(review_comments=[_FINDING])
    reason = "P2 tracked in #123"
    code, result = ship(
        world, "--check", "u=good", "--merge", "--accept-review-findings", reason
    )
    assert code == 0, result
    assert _calls_at(world, _is_queue)
    assert result["review"]["accepted"] == reason
    assert result["review"]["findings"][0]["where"] == "ops/a.py:12"
    assert any(reason in line for line in result["log"])


_NEUTRAL = [_review(job=True), _review(conclusion="neutral")]


def test_a_neutral_review_is_not_a_verdict_and_refuses_to_queue() -> None:
    """`neutral` only means the workflow stopped waiting for the bot (5 min)."""
    world = FakeWorld(review_runs=[_NEUTRAL])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert len(_calls_at(world, _is_review_read)) > 1  # kept polling to --timeout
    assert "never settled" in result["error"]
    assert "--accept-no-review" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_a_neutral_review_followed_by_a_blocker_is_not_queued() -> None:
    """PR #2082: neutral at 13:15, the bot's P1 failure verdict at 13:17."""
    later = [*_NEUTRAL, _review(conclusion="failure")]
    world = FakeWorld(review_runs=[_NEUTRAL, later])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert f"agent-review failed on {HEAD}" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_a_neutral_review_followed_by_a_review_is_queued() -> None:
    world = FakeWorld(review_runs=[_NEUTRAL, [*_NEUTRAL, _review()]])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 0, result
    assert result["review"]["verdict"] == "success"
    assert result["review"]["accepted_no_review"] is None


def _cr_verdict(
    head: str = HEAD,
    verdict: str = "APPROVE",
    association: str = "OWNER",
    login: str = "maintainer",
) -> dict[str, Any]:
    return {
        "user": {"login": login},
        "author_association": association,
        "created_at": "2026-10-09T10:10:00Z",
        "body": f"CR verdict: {verdict} {head}\nno P0/P1 at the exact head",
    }


def test_an_explicit_reason_queues_without_a_review_and_records_it() -> None:
    world = FakeWorld(review_runs=[_NEUTRAL], issue_comments=[_cr_verdict()])
    reason = "codex quota exhausted; reviewed by hand"
    code, result = ship(
        world, "--check", "u=good", "--merge", "--accept-no-review", reason
    )
    assert code == 0, result
    assert _calls_at(world, _is_queue)
    assert result["review"]["verdict"] == "neutral"
    assert result["review"]["accepted_no_review"] == reason
    assert any(reason in line for line in result["log"])


def test_accepting_no_review_never_queues_while_the_review_is_still_running() -> None:
    world = FakeWorld(review_runs=[[_review("in_progress", job=True)]])
    code, result = ship(
        world, "--check", "u=good", "--merge", "--accept-no-review", "no bot"
    )
    assert code == 1, result
    assert "timed out" in result["error"]
    assert not _calls_at(world, _is_queue)


# What agent-review.yml really posts when the bot never answered.
_UNAVAILABLE = {
    "title": "Independent agent review unavailable",
    "summary": f"No exact-head review or fresh reviewer reaction from {BOT} "
    f"was observed for {HEAD}.",
}
_NEUTRAL_UNAVAILABLE = [
    _review(job=True),
    _review(conclusion="neutral", output=_UNAVAILABLE),
]


def _polls(world: FakeWorld) -> int:
    return len(_calls_at(world, _is_review_read))


def test_accept_no_review_takes_a_settled_neutral_at_once_without_polling() -> None:
    world = FakeWorld(
        review_runs=[_NEUTRAL_UNAVAILABLE], issue_comments=[_cr_verdict()]
    )
    reason = "CR verdict: no blockers at the exact head"
    code, result = ship(
        world, "--check", "u=good", "--merge", "--accept-no-review", reason
    )
    assert code == 0, result
    assert _polls(world) == 1
    assert world.sleeps == []
    assert result["review"]["accepted_no_review"] == reason
    assert any(
        f"accepted #77 without an exact-head review ({reason})" in line
        for line in result["log"]
    )


def _quota_comment(login: str = BOT, at: str = "2026-10-09T10:05:00Z"):
    return {
        "user": {"login": login},
        "created_at": at,
        "body": "You have reached your Codex usage limits for code reviews.",
    }


def test_an_unavailable_title_alone_is_not_evidence_and_keeps_waiting() -> None:
    world = FakeWorld(review_runs=[_NEUTRAL_UNAVAILABLE])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert _polls(world) > 1
    assert "never settled" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_a_quota_comment_from_the_bot_refuses_at_once() -> None:
    world = FakeWorld(
        review_runs=[_NEUTRAL_UNAVAILABLE], issue_comments=[_quota_comment()]
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert _polls(world) == 1
    assert world.sleeps == []
    assert "agent-review neutral: review bot unavailable" in result["error"]
    assert "have CR review the exact head" in result["error"]
    assert "--accept-no-review '<CR verdict>'" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_a_quota_comment_from_a_non_bot_user_is_ignored() -> None:
    world = FakeWorld(
        review_runs=[_NEUTRAL_UNAVAILABLE],
        issue_comments=[_quota_comment(login="someone")],
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert _polls(world) > 1
    assert "never settled" in result["error"]


def test_a_quota_comment_older_than_the_head_commit_is_ignored() -> None:
    world = FakeWorld(
        review_runs=[_NEUTRAL_UNAVAILABLE],
        issue_comments=[_quota_comment(at="2026-10-09T09:00:00Z")],
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert _polls(world) > 1


def test_a_usage_limit_summary_also_counts_as_the_bot_being_down() -> None:
    quota = {"title": "Review", "summary": "You have reached your usage limits."}
    world = FakeWorld(
        review_runs=[[_review(job=True), _review(conclusion="neutral", output=quota)]]
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert _polls(world) == 1
    assert "review bot unavailable" in result["error"]


def test_a_neutral_without_the_marker_and_without_accept_keeps_waiting() -> None:
    other = {"title": "Something else", "summary": "stopped waiting"}
    world = FakeWorld(
        review_runs=[[_review(job=True), _review(conclusion="neutral", output=other)]]
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert _polls(world) > 1
    assert "never settled" in result["error"]


def test_a_pending_review_is_still_waited_for_before_a_neutral_is_accepted() -> None:
    world = FakeWorld(
        review_runs=[
            [_review("in_progress", job=True)],
            _NEUTRAL_UNAVAILABLE,
        ],
        issue_comments=[_cr_verdict()],
    )
    code, result = ship(
        world, "--check", "u=good", "--merge", "--accept-no-review", "CR ok"
    )
    assert code == 0, result
    assert _polls(world) == 2
    assert world.sleeps != []


@pytest.mark.parametrize(
    "comments",
    [
        [],
        [_cr_verdict(head="d" * 40)],
        [_cr_verdict(verdict="REQUEST_CHANGES")],
        [_cr_verdict(association="NONE")],
        [_cr_verdict(login=BOT)],
    ],
    ids=["none", "other-head", "rejecting", "untrusted-author", "review-bot"],
)
def test_accept_no_review_needs_a_recorded_cr_verdict_on_the_exact_head(
    comments: list[dict[str, Any]],
) -> None:
    world = FakeWorld(review_runs=[_NEUTRAL_UNAVAILABLE], issue_comments=comments)
    code, result = ship(
        world, "--check", "u=good", "--merge", "--accept-no-review", "looks fine"
    )
    assert code == 1, result
    assert "needs a recorded CR verdict" in result["error"]
    assert f"CR verdict: APPROVE {HEAD}" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_a_cr_verdict_in_a_pr_review_body_also_counts() -> None:
    world = FakeWorld(review_runs=[_NEUTRAL_UNAVAILABLE], pr_reviews=[_cr_verdict()])
    code, result = ship(
        world, "--check", "u=good", "--merge", "--accept-no-review", "CR ok"
    )
    assert code == 0, result
    assert _calls_at(world, _is_queue)


def test_accepting_no_review_does_not_override_a_failed_review() -> None:
    failed = [_review(conclusion="failure", job=True), _review(conclusion="failure")]
    world = FakeWorld(review_runs=[[*_NEUTRAL_UNAVAILABLE, *failed]])
    code, result = ship(
        world, "--check", "u=good", "--merge", "--accept-no-review", "CR ok"
    )
    assert code == 1, result
    assert f"agent-review failed on {HEAD}" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_without_merge_the_review_is_not_awaited() -> None:
    world = FakeWorld(review_runs=[[]])
    assert ship(world, "--check", "u=good")[0] == 0
    assert not _calls_at(world, _is_review_read)


_OF_PR_50 = {
    "event": "pull_request_target",
    "head_branch": "feat/old",
    "pull_requests": [{"number": 50}],
}


def test_a_review_run_of_another_pr_on_the_same_head_is_not_accepted() -> None:
    """redeliver's PR shares the replaced PR's head sha, so the commit-level
    check list also holds the replaced PR's runs: its success says nothing about
    this PR, and this PR was never reviewed."""
    world = FakeWorld(
        review_runs=[[_review(job=True), _review()]], actions_runs={1: _OF_PR_50}
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert "belong to other PRs" in result["error"]
    assert "#77" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_only_the_runs_of_this_pr_decide_among_runs_on_a_shared_head() -> None:
    """Positive control: the replaced PR's runs (here a failure) are ignored and
    this PR's own success is accepted."""
    old = [_review(job=True, run=1), _review(conclusion="failure", run=1)]
    own = [_review(job=True, run=2), _review(run=2)]
    world = FakeWorld(review_runs=[[*old, *own]], actions_runs={1: _OF_PR_50})
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 0, result
    assert result["review"]["verdict"] == "success"
    assert _calls_at(world, _is_queue)
    runs_read = [c[-1] for c in world.calls if "/actions/runs/" in c[-1]]
    assert sorted(set(runs_read)) == [
        "repos/o/r/actions/runs/1",
        "repos/o/r/actions/runs/2",
    ]


def test_a_run_without_pull_requests_is_owned_by_its_head_branch() -> None:
    world = FakeWorld(
        actions_runs={
            1: {"event": "pull_request_target", "head_branch": "feat/thing"},
        }
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 0, result


@pytest.mark.parametrize(
    "unattributed",
    [
        None,  # GitHub no longer has the run (404)
        {"event": "issue_comment", "head_branch": "main", "pull_requests": []},
        {"event": "pull_request_target", "head_branch": "feat/old"},
    ],
    ids=["run-not-found", "comment-run-names-no-pr", "head-branch-of-another-pr"],
)
def test_a_review_whose_owner_cannot_be_determined_is_not_accepted(
    unattributed: dict[str, Any] | None,
) -> None:
    world = FakeWorld(actions_runs={1: unattributed})
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert "belong to other PRs or could not be attributed" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_a_review_run_naming_no_workflow_run_is_not_accepted() -> None:
    bare = {**_review(job=True), "details_url": None}
    marker_only = {**_review(), "external_id": "", "details_url": ""}
    world = FakeWorld(review_runs=[[bare, marker_only]])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert not _calls_at(world, _is_queue)


@pytest.mark.parametrize(
    ("runs", "verdict"),
    [
        ([], None),
        ([_review("in_progress")], None),  # only an orphaned verdict marker
        ([_review(conclusion="cancelled", job=True)], None),
        ([_review("in_progress", job=True), _review()], None),  # still evaluating
        ([_review(job=True), _review(conclusion="neutral"), _review()], "success"),
        ([_review(job=True), _review(conclusion="neutral")], "neutral"),
        ([_review(job=True)], "success"),
        ([_review(job=True), _review(conclusion="failure"), _review()], "failure"),
    ],
)
def test_the_review_verdict_reads_every_run_on_the_head(
    runs: list[dict[str, Any]], verdict: str | None
) -> None:
    assert deliver.review_verdict(runs) == verdict


def _job(conclusion: str, started_at: str | None) -> dict[str, Any]:
    return {
        "name": "agent-review",
        "status": "completed",
        "conclusion": conclusion,
        "external_id": "",
        "started_at": started_at,
        "details_url": "https://github.com/o/r/actions/runs/1/job/9",
        "output": {"title": None, "summary": None},
    }


def test_a_stale_failed_run_does_not_override_a_newer_success() -> None:
    runs = [
        _job("failure", "2026-10-10T10:00:00Z"),
        _job("success", "2026-10-10T11:00:00Z"),
    ]
    assert deliver.review_verdict(runs) == "success"


def test_an_undated_failure_is_never_overridden_by_a_dated_success() -> None:
    runs = [_job("failure", None), _job("success", "2026-10-10T11:00:00Z")]
    assert deliver.review_verdict(runs) == "failure"


def test_a_newer_failed_run_overrides_an_older_success() -> None:
    runs = [
        _job("success", "2026-10-10T10:00:00Z"),
        _job("failure", "2026-10-10T11:00:00Z"),
    ]
    assert deliver.review_verdict(runs) == "failure"


def _check(name: str, state: str, started: str = "", link: str = "") -> dict[str, Any]:
    return {"name": name, "state": state, "startedAt": started, "link": link}


_REQUIRED_OK = _check("required", "SUCCESS")


def test_a_red_area_quality_job_refuses_to_queue_before_the_queue_call() -> None:
    world = FakeWorld(
        checks=[[_REQUIRED_OK, _check("ios-quality / ios-tests (unit)", "FAILURE")]],
        review_runs=[[_review(job=True), _review()]],
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1
    assert "ios-quality / ios-tests (unit)" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_a_skipped_area_caller_is_a_pass_not_a_hold() -> None:
    checks = [
        _REQUIRED_OK,
        _check("backend-quality", "SKIPPED"),
        _check("ops-suite / Linux ops shard 1", "SUCCESS"),
    ]
    world = FakeWorld(checks=[checks])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 0, result
    assert _calls_at(world, _is_queue)


@pytest.mark.parametrize("newer_first", [True, False])
def test_the_newest_area_run_by_started_at_decides_whatever_the_list_order(
    newer_first: bool,
) -> None:
    old = _check("backend-quality / backend-quality", "FAILURE", "2026-10-10T10:00:00Z")
    new = _check("backend-quality / backend-quality", "SUCCESS", "2026-10-10T11:00:00Z")
    batch = [new, old] if newer_first else [old, new]
    world = FakeWorld(checks=[[_REQUIRED_OK, *batch]])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 0, result
    assert _calls_at(world, _is_queue)


def test_an_area_shard_still_pending_at_the_timeout_holds_the_queue() -> None:
    shard = _check(
        "ops-suite / Linux ops shard 3", "IN_PROGRESS", "2026-10-10T10:00:00Z"
    )
    world = FakeWorld(checks=[[_REQUIRED_OK, shard]])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1
    assert "timed out" in result["error"] and "area quality" in result["error"]
    assert not _calls_at(world, _is_queue)


def test_a_failed_area_job_refuses_at_once_even_with_a_sibling_still_running() -> None:
    checks = [
        _REQUIRED_OK,
        _check("ios-quality / ios-tests (unit)", "FAILURE", "2026-10-10T10:00:00Z"),
        _check("ops-suite / Linux ops shard 3", "IN_PROGRESS", "2026-10-10T10:00:00Z"),
    ]
    world = FakeWorld(checks=[checks])
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1
    assert "ios-quality / ios-tests (unit)" in result["error"]
    assert not _calls_at(world, _is_queue)


QUEUE_HEAD = "9" * 40


def test_a_merge_group_failure_names_the_failing_check_from_the_queue_head() -> None:
    # The PR head is green; only the merge group (queue commit) failed and ejected it.
    ok = [_REQUIRED_OK, _check("ops-suite / Linux ops shard 1", "SUCCESS")]
    group_failure = {
        "name": "ops-suite / Linux ops shard 3",
        "conclusion": "failure",
        "started_at": "2026-10-10T10:00:00Z",
        "html_url": "https://github.com/o/r/actions/runs/77/job/3",
    }
    world = FakeWorld(
        checks=[ok, ok],
        pr_state=["OPEN"],
        prs_by_branch={"other/branch": [{"number": 77, "state": "OPEN"}]},
        pr_guard=[
            {"mergeQueueEntry": {"id": "q", "headCommit": {"oid": QUEUE_HEAD}}},
            {"mergeQueueEntry": None},
        ],
        queue_runs=[group_failure],
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 1, result
    assert "dequeued" in result["error"]
    assert "ops-suite / Linux ops shard 3" in result["error"]
    assert group_failure["html_url"] in result["error"]


def test_a_pr_merged_between_the_state_and_queue_reads_is_not_an_ejection() -> None:
    world = FakeWorld(
        pr_state=["OPEN", "MERGED"],  # the poll's state read, then the re-read
        prs_by_branch={"other/branch": [{"number": 77, "state": "OPEN"}]},
        pr_guard=[{"mergeQueueEntry": None}],
    )
    code, result = ship(world, "--check", "u=good", "--merge")
    assert code == 0, result
    assert result["result"] == "merged"


def test_the_review_bots_are_read_from_the_workflow() -> None:
    workflow = deliver.AGENT_REVIEW.read_text()
    assert deliver.review_bots(workflow) == (BOT, "chatgpt-codex-connector")
    with pytest.raises(deliver.DeliverError, match="cannot read the review bot"):
        deliver.review_bots("env: {}")


# ---- gc -------------------------------------------------------------------


def _gc_world(tmp_path: Path, **state: Any) -> FakeWorld:
    gone = tmp_path / "gone"
    present = tmp_path / "present"
    present.mkdir()
    world = FakeWorld(merged_prs={"feat/merged": 41, "feat/live": 42}, **state)
    records = [
        {
            "branch": "feat/merged",
            "status": "published",
            "path": str(gone),
            "handed_back_sha": HEAD,
        },
        {"branch": "feat/open", "status": "published", "path": str(gone)},
        # merged, but the worktree still exists (#2419)
        {
            "branch": "feat/live",
            "status": "published",
            "path": str(present),
            "handed_back_sha": HEAD,
        },
        # never published, so only the merged PR proves it is done
        {"branch": "feat/active", "status": "active", "path": str(gone)},
        {
            "branch": "feat/old",
            "status": "merged",
            "path": str(gone),
            "handed_back_sha": HEAD,
        },
    ]
    world.merged_prs["feat/old"] = 43
    world.merged_prs["feat/active"] = 44
    world.record = None
    original = world.__call__

    def with_records(cmd: list[str], cwd: Path | None) -> deliver.Proc:
        if cmd[0].endswith("worktree_registry.py"):
            world.calls.append(cmd)
            return deliver.Proc(0, json.dumps({"records": records}), "")
        return original(cmd, cwd)

    world.__call__ = with_records  # type: ignore[method-assign]
    return world


def _gc(world: FakeWorld, *, dry_run: bool = False) -> dict[str, Any]:
    import argparse

    return deliver.gc(
        argparse.Namespace(dry_run=dry_run), lambda cmd, cwd: world.__call__(cmd, cwd)
    )


def test_gc_retires_every_live_lane_whose_pr_merged_even_with_its_worktree(
    tmp_path: Path,
) -> None:
    world = _gc_world(tmp_path)
    result = _gc(world)
    assert result["retired"] == [
        {"branch": "feat/merged", "pr": 41, "applied": True},
        {"branch": "feat/live", "pr": 42, "applied": True},
    ]
    assert [k["branch"] for k in result["kept"]] == ["feat/open", "feat/active"]


def test_gc_asks_github_once_however_many_records_there_are(tmp_path: Path) -> None:
    world = _gc_world(tmp_path)
    _gc(world)
    assert [c for c in world.calls if c[1:3] == ["pr", "list"]] == []
    assert len([c for c in world.calls if c[1] == "api"]) == 1


def test_gc_keeps_a_lane_whose_head_is_not_in_the_merged_pr(tmp_path: Path) -> None:
    world = _gc_world(tmp_path, old_is_ancestor=False, head="b" * 40)
    result = _gc(world)
    assert result["retired"] == []
    assert {k["branch"] for k in result["kept"]} >= {"feat/merged", "feat/live"}


def test_gc_fails_loudly_when_github_cannot_be_read(tmp_path: Path) -> None:
    """A gh failure must not read as 'PR not merged' with exit 0 (#2760)."""
    world = _gc_world(tmp_path)
    inner = world.__call__

    def gh_down(cmd: list[str], cwd: Path | None) -> deliver.Proc:
        if cmd[:2] == ["gh", "api"]:
            return deliver.Proc(1, "", "API rate limit exceeded")
        return inner(cmd, cwd)

    with pytest.raises(deliver.DeliverError, match="rate limit"):
        deliver.gc(argparse.Namespace(dry_run=False), gh_down)
    assert "cleanup-merged" not in world.names()


def test_gc_dry_run_changes_nothing(tmp_path: Path) -> None:
    world = _gc_world(tmp_path)
    result = _gc(world, dry_run=True)
    assert [r["applied"] for r in result["retired"]] == [False, False]
    assert "cleanup-merged" not in world.names()


# ---- surviving the worktree's removal -------------------------------------


def test_nothing_runs_in_the_worktree_after_publish_removes_it() -> None:
    world = FakeWorld()
    code, _ = ship(world, "--check", "u=good", "--merge")
    assert code == 0  # FakeWorld raises FileNotFoundError for a vanished cwd
    published_at = next(
        i
        for i, c in enumerate(world.calls)
        if c[0].endswith("delivery.py") and c[3] == "publish"
    )
    assert all(cwd != world.work for cwd in world.cwds[published_at + 1 :])


def test_a_published_lane_resumes_from_its_branch_when_the_worktree_is_gone() -> None:
    world = FakeWorld(
        record={
            "branch": "feat/thing",
            "status": "published",
            "external_ids": ["LANE-1"],
        },
        prs=[{"number": 9, "state": "OPEN"}],
    )
    gone = str(world.work / "never-existed")
    code, result = ship(world, "--worktree", gone, "--branch", "feat/thing")
    assert code == 0
    assert result["lane"] == "LANE-1"
    assert not any(
        c[:2] == ["git", "status"] for c in world.calls
    )  # no preflight without a tree


def test_a_gone_worktree_without_a_branch_is_an_explicit_error() -> None:
    code, result = ship(FakeWorld(), "--worktree", "/definitely/not/here")
    assert code == 1
    assert "--branch" in result["error"]


def test_a_gone_worktree_cannot_start_a_new_lane() -> None:
    world = FakeWorld()  # no record, no PR -> would start at adopt
    code, result = ship(
        world, "--worktree", "/definitely/not/here", "--branch", "feat/thing"
    )
    assert code == 1
    assert "gone before the lane was published" in result["error"]


def test_a_branch_flag_that_disagrees_with_the_checkout_is_refused() -> None:
    code, result = ship(FakeWorld(), "--check", "u=good", "--branch", "other")
    assert code == 1
    assert "not the checked-out branch" in result["error"]


def test_a_branch_that_already_carries_the_date_does_not_repeat_it() -> None:
    assert (
        deliver.lane_from_branch("feat/x-20261007", "20261007")
        == "DIRECT-DELIVERY-FEAT-X-20261007"
    )


def _agent_record(**extra: Any) -> dict[str, Any]:
    return {
        "branch": "worktree-agent-abc123",
        "status": "active",
        "external_ids": ["LANE-A"],
        "claim_generation": 0,
        "handed_back_sha": "e" * 40,
        "base_sha": "1" * 40,  # adopted against a stale local main
        **extra,
    }


def test_an_agent_claim_with_a_stale_base_is_readopted_in_one_call() -> None:
    """#2466: retire + adopt are one orchestrator mutation (one lock lease)."""
    world = FakeWorld(branch="worktree-agent-abc123", record=_agent_record())
    code, result = ship(world, "--check", "docs=good")
    assert code == 0, result
    assert world.names() == ["readopt", "hand-back", "receipt", "publish"]
    readopt = next(c for c in world.calls if c[1:2] == ["readopt"])
    assert _value(readopt, "--expected-head-sha") == "e" * 40
    assert _value(readopt, "--expected-generation") == "0"
    assert _value(readopt, "--base") == "f" * 40  # world.fork


def _adopt_bases(world: FakeWorld) -> list[str]:
    return [
        _value(c, "--base")
        for c in world.calls
        if c[0].endswith("worktree_orchestrate.py") and c[1] in ("adopt", "readopt")
    ]


def test_a_readopt_after_a_lock_wait_declares_the_fork_not_a_moved_trunk() -> None:
    """adopt resolves a symbolic --base only when it finally runs; origin/main
    moved meanwhile is not in HEAD, and hand-back refuses that declared base."""
    moved = "9" * 40
    world = FakeWorld(
        branch="worktree-agent-abc123",
        record=_agent_record(),
        lock_busy={"readopt": 2},
        trunk_moves_to=moved,
    )
    code, result = ship(world, "--check", "docs=good")
    assert code == 0, result
    assert world.trunk == moved  # main really moved during the wait
    assert world.names() == [
        "readopt",
        "readopt",
        "readopt",
        "hand-back",
        "receipt",
        "publish",
    ]
    bases = _adopt_bases(world)
    assert bases == [world.fork] * 3
    assert all(deliver.SHA.fullmatch(b) for b in bases)
    assert deliver.TRUNK not in bases and moved not in bases


@pytest.mark.parametrize("record", [None, _agent_record()], ids=["fresh", "stale"])
def test_an_unpinnable_claim_base_fails_closed_before_any_claim(
    record: dict[str, Any] | None,
) -> None:
    world = FakeWorld(branch="worktree-agent-abc123", record=record, fork="f" * 7)
    code, result = ship(world, "--check", "docs=good")
    assert code == 1
    assert "cannot pin the claim base" in result["error"]
    assert world.names() == []


def test_a_claim_whose_base_is_the_fork_point_is_kept() -> None:
    world = FakeWorld(
        branch="worktree-agent-abc123", record=_agent_record(base_sha="f" * 40)
    )
    code, _ = ship(world, "--check", "docs=good")
    assert code == 0
    assert "resolve" not in world.names()
    assert "adopt" not in world.names()


def test_scope_from_diff_refreshes_a_drifted_active_claim_scope() -> None:
    record = _agent_record(
        base_sha="f" * 40,
        scope={"files": [{"path": "ops/a.py", "operation": "modify"}]},
    )
    world = FakeWorld(branch="worktree-agent-abc123", record=record)
    code, _ = ship(world, "--check", "docs=good", "--scope-from-diff")
    assert code == 0
    refresh = [
        c
        for c in world.calls
        if c[0].endswith("worktree_registry.py") and "scope-set" in c
    ]
    assert len(refresh) == 1

    same = FakeWorld(
        branch="worktree-agent-abc123",
        record=_agent_record(
            base_sha="f" * 40,
            scope=deliver.scope_from_name_status("M\0ops/a.py\0A\0ops/b.py\0"),
        ),
    )
    assert ship(same, "--check", "docs=good", "--scope-from-diff")[0] == 0
    assert not [c for c in same.calls if "scope-set" in c]
    plain = FakeWorld(branch="worktree-agent-abc123", record=record)
    ship(plain, "--check", "docs=good")
    assert not [c for c in plain.calls if "scope-set" in c]


def test_branch_resume_of_an_already_merged_lane_stops_with_a_clear_message() -> None:
    world = FakeWorld(prs=[{"number": 41, "state": "MERGED"}])
    code, result = ship(world, "--branch", "feat/thing", "--check", "u=good")
    assert code == 1
    assert result["error"] == "PR #41 already merged; start a new lane from origin/main"
    assert world.names() == []


def test_branch_resume_still_cleans_a_merged_lane_that_is_not_yet_retired() -> None:
    world = FakeWorld(
        prs=[{"number": 41, "state": "MERGED"}],
        record={"branch": "feat/thing", "status": "cleanup_pending"},
    )
    code, _ = ship(world, "--branch", "feat/thing")
    assert code == 0
    assert world.names() == ["cleanup-merged", "sync-main"]


def test_stale_local_main_base_is_detected_in_a_real_agent_style_checkout(
    tmp_path: Path,
) -> None:
    """Agent worktrees fork from a newer origin/main than the local main the
    claim was adopted against; the claim base is then not the fork point."""
    import subprocess

    def sh(*argv: str, cwd: Path = tmp_path) -> str:
        done = subprocess.run(
            list(argv), cwd=cwd, capture_output=True, text=True, check=True
        )
        return done.stdout.strip()

    repo = tmp_path / "repo"
    repo.mkdir()
    sh("git", "init", "-q", "-b", "main", cwd=repo)
    sh("git", "config", "user.email", "t@example.com", cwd=repo)
    sh("git", "config", "user.name", "T", cwd=repo)
    (repo / "a.txt").write_text("1")
    sh("git", "add", ".", cwd=repo)
    sh("git", "commit", "-qm", "one", cwd=repo)
    stale = sh("git", "rev-parse", "HEAD", cwd=repo)
    (repo / "merged_later.txt").write_text("2")
    sh("git", "add", ".", cwd=repo)
    sh("git", "commit", "-qm", "two", cwd=repo)
    sh("git", "update-ref", "refs/remotes/origin/main", "HEAD", cwd=repo)
    sh("git", "checkout", "-q", "-b", "worktree-agent-x", cwd=repo)
    (repo / "mine.txt").write_text("3")
    sh("git", "add", ".", cwd=repo)
    sh("git", "commit", "-qm", "mine", cwd=repo)
    sh("git", "update-ref", "refs/heads/main", stale, cwd=repo)  # stale local main

    args = deliver.build_parser().parse_args(["--worktree", str(repo)])
    delivery = deliver.Delivery(args, deliver.run, lambda _s: None)
    retired: list[list[str]] = []

    def spy(cmd: list[str], cwd: Path | None) -> deliver.Proc:
        if cmd[0].endswith("worktree_orchestrate.py"):
            retired.append(cmd)
            return deliver.Proc(0, "{}", "")
        return deliver.run(cmd, cwd)

    delivery.runner = spy
    assert delivery.claim_base_is_stale({"base_sha": stale})
    fork = sh("git", "merge-base", "HEAD", "origin/main", cwd=repo)
    assert not delivery.claim_base_is_stale({"base_sha": fork})
    assert not retired  # detection retires nothing: readopt does, atomically


def test_the_claim_base_stays_on_the_fork_when_origin_main_moves_on_real_git(
    tmp_path: Path,
) -> None:
    """origin/main fetched past the branch's fork point (M1 -> M2) is not in
    HEAD; the declared claim base must stay M1 so hand-back's ancestry holds."""
    import subprocess

    def sh(*argv: str) -> str:
        done = subprocess.run(
            list(argv), cwd=tmp_path, capture_output=True, text=True, check=True
        )
        return done.stdout.strip()

    sh("git", "init", "-q", "-b", "main")
    sh("git", "config", "user.email", "t@example.com")
    sh("git", "config", "user.name", "T")
    (tmp_path / "a.txt").write_text("1")
    sh("git", "add", ".")
    sh("git", "commit", "-qm", "M1")
    m1 = sh("git", "rev-parse", "HEAD")
    sh("git", "update-ref", "refs/remotes/origin/main", m1)
    sh("git", "checkout", "-q", "-b", "worktree-agent-x")
    (tmp_path / "mine.txt").write_text("2")
    sh("git", "add", ".")
    sh("git", "commit", "-qm", "mine")
    m2 = sh("git", "commit-tree", f"{m1}^{{tree}}", "-p", m1, "-m", "M2")
    sh("git", "update-ref", "refs/remotes/origin/main", m2)  # another lane's fetch

    args = deliver.build_parser().parse_args(["--worktree", str(tmp_path)])
    base = deliver.Delivery(args, deliver.run, lambda _s: None).claim_base()
    assert base == m1 and base != m2
    assert sh("git", "rev-parse", deliver.TRUNK) == m2  # what a symbolic base names

    def contains(sha: str) -> int:
        is_ancestor = ["git", "merge-base", "--is-ancestor", sha, "HEAD"]
        return deliver.run(is_ancestor, tmp_path).returncode

    assert contains(base) == 0  # hand-back's declared_base_sha check
    assert contains(m2) == 1


# ---- a lane waiting on the operation lock while origin/main moves ----------


def _flock_held(path: Path) -> bool:
    """True when another open file description holds the exclusive lease."""
    with path.open("a+") as probe:
        try:
            fcntl.flock(probe.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        fcntl.flock(probe.fileno(), fcntl.LOCK_UN)
        return False


def test_the_trunk_fetch_runs_under_the_operation_lease_and_waits_for_it() -> None:
    """A fetch rewrites the one shared refs/remotes/origin/main; two concurrent
    fetches make one fail 'cannot lock ref ... is at X but expected Y', so the
    fetch takes the lease every other ref mutation takes."""
    world = FakeWorld()
    lease = OperationLock(world.canon, command="test-holder").path
    lease.parent.mkdir(parents=True, exist_ok=True)
    holder = lease.open("a+")
    fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
    fetch_saw_lease: list[bool] = []

    def runner(cmd: list[str], cwd: Path | None) -> deliver.Proc:
        if cmd[:2] == ["git", "fetch"]:
            fetch_saw_lease.append(_flock_held(lease))
        return world(cmd, cwd)

    def release_after_first_wait(seconds: float) -> None:
        world.sleep(seconds)
        fcntl.flock(holder.fileno(), fcntl.LOCK_UN)  # the other operation ends

    buf = io.StringIO()
    argv = ["--timeout", "5", "--poll", "1", "--worktree", str(world.work)]
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
        code = deliver.main(
            [*argv, "--check", "docs=good"],
            runner=runner,
            sleep=release_after_first_wait,
            clock=lambda: world.now,
        )
    holder.close()
    result = json.loads(buf.getvalue().strip().splitlines()[-1])
    assert code == 0, result
    assert world.sleeps[:1] == [5]  # the fetch waited out the held lease
    assert fetch_saw_lease == [True]  # and ran holding the lease itself
    assert any("operation lock" in line for line in result["log"])


class RealLane:
    """A real lane worktree on a real bare origin, for the real registry CLI.

    ``advance_main()`` is another delivery landing a commit and fetching it:
    origin/main (the shared ref) moves to a commit the lane's HEAD lacks.
    """

    def __init__(self, root: Path) -> None:
        self.remote = root / "origin.git"
        self.seed = root / "seed"
        self.repo = root / "repo"
        self.lane = root / "lane"
        self.state = root / "registry.json"
        self.git("init", "-q", "--bare", "-b", "main", str(self.remote), cwd=root)
        self.git("clone", "-q", str(self.remote), str(self.seed), cwd=root)
        self.configure(self.seed)
        self.base = self.land("a.txt", "B")
        self.git("clone", "-q", str(self.remote), str(self.repo), cwd=root)
        self.configure(self.repo)
        self.git("worktree", "add", "-q", "-b", "lane-x", str(self.lane), cwd=self.repo)
        (self.lane / "lane.txt").write_text("mine")
        self.git("add", "lane.txt", cwd=self.lane)
        self.git("commit", "-qm", "feat: the lane", cwd=self.lane)

    @staticmethod
    def git(*argv: str, cwd: Path) -> str:
        done = subprocess.run(
            ["git", *argv], cwd=cwd, capture_output=True, text=True, check=True
        )
        return done.stdout.strip()

    def configure(self, repo: Path) -> None:
        self.git("config", "user.email", "t@example.com", cwd=repo)
        self.git("config", "user.name", "T", cwd=repo)

    def land(self, name: str, text: str) -> str:
        (self.seed / name).write_text(text)
        self.git("add", name, cwd=self.seed)
        self.git("commit", "-qm", f"main: {text}", cwd=self.seed)
        self.git("push", "-q", "origin", "main", cwd=self.seed)
        return self.git("rev-parse", "HEAD", cwd=self.seed)

    def advance_main(self) -> str:
        moved = self.land("b.txt", "B-prime")
        self.git("fetch", "-q", "origin", "main", cwd=self.lane)
        return moved

    def registry_record(self) -> dict[str, Any]:
        records = json.loads(self.state.read_text())["records"]
        (record,) = [r for r in records if r["branch"] == "lane-x"]
        return record


def _registry_runner(
    lane: RealLane, on_first_adopt: Callable[[], object]
) -> deliver.Runner:
    """Real git and the real registry CLIs; gh and delivery.py are scripted.

    delivery.py fails at `receipt`, so the run stops right after adopt and
    hand-back, whose registry state the test then reads.
    """

    def runner(cmd: list[str], cwd: Path | None) -> deliver.Proc:
        script = Path(cmd[0]).name
        if script == "gh":
            if cmd[1:3] == ["repo", "view"]:
                return deliver.Proc(0, "o/r\n", "")
            if cmd[1:3] == ["pr", "list"]:
                return deliver.Proc(0, "[]", "")
            raise AssertionError(f"unscripted gh call: {cmd}")
        if script == "delivery.py":
            return deliver.Proc(1, "", "stopped before receipt")
        if script in ("worktree_orchestrate.py", "worktree_registry.py"):
            if cmd[1] == "adopt":
                on_first_adopt()
            cmd = [sys.executable, *cmd, "--state", str(lane.state)]
        return deliver.run(cmd, cwd)

    return runner


def _deliver_lane(
    lane: RealLane,
    on_first_adopt: Callable[[], object],
    on_wait: Callable[[], object],
) -> tuple[int, dict[str, Any], str]:
    ticks = iter(range(10_000))
    buf, progress = io.StringIO(), io.StringIO()
    argv = ["--worktree", str(lane.lane), "--check", "unit=true"]
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(progress):
        code = deliver.main(
            argv,
            runner=_registry_runner(lane, on_first_adopt),
            sleep=lambda _seconds: on_wait(),
            clock=lambda: float(next(ticks)),
        )
    return (
        code,
        json.loads(buf.getvalue().strip().splitlines()[-1]),
        progress.getvalue(),
    )


def test_a_lane_waiting_for_the_lock_while_origin_main_moves_still_hands_back(
    tmp_path: Path,
) -> None:
    """The retro failure: a lane is adopted on base B, another delivery fetches
    origin/main to B' while this one waits for the operation lock, and hand-back
    then refused 'declared base is not an ancestor of worktree HEAD'."""
    lane = RealLane(tmp_path)
    anchor = coordinator.registry.common_anchor(coordinator.ROOT)
    lease = OperationLock(anchor, command="test-holder").path
    lease.parent.mkdir(parents=True, exist_ok=True)
    holder = lease.open("a+")
    moved: list[str] = []
    taken: list[bool] = []

    def take_lease() -> None:  # another operation grabs the lock before adopt
        if not taken:
            taken.append(True)
            fcntl.flock(holder.fileno(), fcntl.LOCK_EX)

    def main_moves_then_lock_frees() -> None:
        if not moved:
            moved.append(lane.advance_main())
            fcntl.flock(holder.fileno(), fcntl.LOCK_UN)

    code, result, progress = _deliver_lane(lane, take_lease, main_moves_then_lock_frees)
    holder.close()

    assert moved, "adopt never met the held lock; the scenario did not run"
    assert lane.git("rev-parse", "origin/main", cwd=lane.lane) == moved[0]
    assert "adopt: another delivery mutation holds the operation lock" in progress
    # The run stopped at the scripted receipt, i.e. past adopt and hand-back.
    assert code == 1
    assert "receipt failed" in result["error"], result
    assert "not an ancestor" not in result["error"]
    record = lane.registry_record()
    assert record["base_sha"] == lane.base != moved[0]  # the pinned fork, not B'
    assert record["handed_back_sha"] == lane.git("rev-parse", "HEAD", cwd=lane.lane)
    assert record["handback_seal"]["base_sha"] == lane.base


def test_a_symbolic_base_resolved_after_the_move_is_what_hand_back_refused(
    tmp_path: Path,
) -> None:
    """Control for the test above: declaring `origin/main` (what deliver sent
    before #2235) resolves it at adopt time, after the move, to B' - not in HEAD."""
    lane = RealLane(tmp_path)
    lane.advance_main()
    scope = tmp_path / "scope.json"
    scope.write_text(json.dumps({"files": [{"path": "lane.txt", "operation": "add"}]}))
    outcomes = tmp_path / "outcomes.json"
    outcomes.write_text(json.dumps([{"check": "unit", "status": "passed"}]))
    cli = [sys.executable, str(OPS / "worktree_orchestrate.py")]
    state = ["--state", str(lane.state), "--json"]
    adopt = [*cli, "adopt", "--worktree", str(lane.lane), "--base", deliver.TRUNK]
    adopt += ["--intent", "feat: the lane", "--external-id", "lane-x", *state]
    adopt += ["--scope-file", str(scope), "--codex-thread-id", "t", "--delegated"]
    assert deliver.run(adopt, lane.lane).returncode == 0
    hand_back = [*cli, "hand-back", "--branch", "lane-x", "--path", str(lane.lane)]
    refused = deliver.run([*hand_back, "--outcomes", str(outcomes), *state], lane.lane)
    assert refused.returncode != 0
    assert "declared base is not an ancestor of worktree HEAD" in refused.stderr


def _format_calls(world: FakeWorld) -> list[list[str]]:
    return [c for c in world.calls if c[0] == "uv"]


def _commits(world: FakeWorld) -> list[list[str]]:
    return [c for c in world.calls if c[:2] == ["git", "commit"]]


def test_the_format_step_runs_the_pr_gate_pinned_ruff_on_changed_python() -> None:
    world = FakeWorld()
    assert ship(world, "--check", "unit=good")[0] == 0
    (call,) = _format_calls(world)
    assert (
        "ruff==0.16.3" in deliver.PR_GATE.read_text()
    )  # the pin lives in the workflow
    assert call[call.index("--with") + 1] == "ruff==0.16.3"
    assert call[call.index("--python") + 1] == "3.13"
    assert "--no-project" in call and "format" in call
    assert call[call.index("format") :] == ["format", "ops/a.py", "ops/b.py"]
    assert "--check" not in call  # it rewrites; it does not merely report
    assert world.cwds[world.calls.index(call)] == world.work.resolve()


def test_the_pin_is_read_from_the_workflow_not_restated() -> None:
    bumped = deliver.ruff_format_command(
        "run: uv run --no-project --python 3.14 --with 'ruff==9.9.9' ruff format --check x"
    )
    assert "ruff==9.9.9" in bumped and "3.14" in bumped


def test_an_unreadable_pin_fails_closed() -> None:
    with pytest.raises(deliver.DeliverError, match="cannot read the pinned ruff"):
        deliver.ruff_format_command("run: ruff format --check x")


def test_already_formatted_python_makes_no_commit() -> None:
    world = FakeWorld()
    assert ship(world, "--check", "unit=good")[0] == 0
    assert _commits(world) == []


def test_unformatted_python_is_committed_before_checks_and_the_claim() -> None:
    world = FakeWorld(format_changes=True)
    code, result = ship(world, "--check", "unit=good")
    assert code == 0
    (commit,) = _commits(world)
    message = commit[commit.index("-m") + 1]
    assert message.splitlines()[0] == "style: ruff format (pre-publish)"
    assert "\nCo-Authored-By: " in message and "<noreply@anthropic.com>" in message
    add = [c for c in world.calls if c[:2] == ["git", "add"]]
    assert add == [["git", "add", "--", "ops/a.py", "ops/b.py"]]
    at = {id(c): i for i, c in enumerate(world.calls)}
    first_check = next(c for c in world.calls if c[0] == "bash")
    adopt = next(c for c in world.calls if c[0].endswith("worktree_orchestrate.py"))
    assert at[id(_format_calls(world)[0])] < at[id(add[0])] < at[id(commit)]
    assert at[id(commit)] < at[id(first_check)] < at[id(adopt)]
    assert any("format" in line for line in result["log"])


def test_the_format_commit_is_scoped_to_the_changed_files() -> None:
    world = FakeWorld(format_changes=True, changed_py=["ops/a.py"])
    assert ship(world, "--check", "unit=good")[0] == 0
    assert ["git", "add", "--", "ops/a.py"] in world.calls
    assert not [c for c in world.calls if c[:3] == ["git", "add", "-A"]]


def test_a_branch_without_python_changes_does_not_run_ruff_or_commit() -> None:
    world = FakeWorld(changed_py=[])
    assert ship(world, "--check", "unit=good")[0] == 0
    assert _format_calls(world) == []
    assert _commits(world) == []


def test_a_ruff_failure_stops_the_run_and_names_the_error() -> None:
    world = FakeWorld(format_rc=2)
    code, result = ship(world, "--check", "unit=good")
    assert code == 1
    assert "ruff format failed" in result["error"]
    assert "Failed to parse a.py" in result["error"]
    assert _commits(world) == []
    assert not [c for c in world.calls if c[0] == "bash"]  # no check ran
    assert world.names() == []  # nothing claimed, nothing handed back


def test_a_dirty_worktree_is_refused_before_ruff_runs() -> None:
    world = FakeWorld(dirty=True)
    code, result = ship(world, "--check", "unit=good")
    assert code == 1 and "uncommitted changes" in result["error"]
    assert _format_calls(world) == [] and _commits(world) == []


def test_the_format_step_itself_refuses_a_dirty_worktree() -> None:
    # preflight also refuses, but the step must not trust its caller: ruff would
    # otherwise fold the author's uncommitted edits into the format commit.
    world = FakeWorld(dirty=True)
    args = deliver.build_parser().parse_args(["--worktree", str(world.work)])
    step = deliver.Delivery(args, world, world.sleep, lambda: world.now)
    with pytest.raises(deliver.DeliverError, match="uncommitted changes"):
        step.format_changed_python()
    assert _format_calls(world) == [] and _commits(world) == []
    assert not [c for c in world.calls if c[:2] == ["git", "add"]]


def test_a_resumed_published_lane_is_not_reformatted() -> None:
    world = FakeWorld(
        record={"status": "published", "branch": "feat/thing"},
        prs=[{"number": 5, "state": "OPEN", "url": "u"}],
        format_changes=True,
    )
    assert ship(world)[0] == 0
    assert _format_calls(world) == [] and _commits(world) == []


# ---- redeliver: replace a published PR with a fixed lane ------------------

OLD = "feat/old"
PUBLISHED = "a" * 40
_HOLDS_BLOCK = (
    'body\n<!-- kg.delivery.holds.v1\n{"schema": "kg.delivery.holds.v1", '
    '"holds": ["security"]}\n-->\n'
)


def _replacement_world(
    *,
    generation: int = 0,
    old_status: str = "published",
    old_pr_state: str = "OPEN",
    remote: str | None = PUBLISHED,
    **state: Any,
) -> FakeWorld:
    lane = {
        "branch": OLD,
        "status": old_status,
        "claim_generation": generation,
        "handed_back_sha": PUBLISHED,
        "path": "/gone/old-lane",
        "external_ids": ["LANE-OLD"],
    }
    pr = {"number": 50, "state": old_pr_state, "url": "https://x/pull/50"}
    return FakeWorld(
        records_by_branch={
            OLD: state.pop("old_records", [lane]),
            **state.pop("new_records", {}),
        },
        prs_by_branch={OLD: state.pop("old_prs", [pr]), **state.pop("new_prs", {})},
        remote_heads={OLD: remote} if remote else {},
        **state,
    )


def redeliver(world: FakeWorld, *flags: str) -> tuple[int, dict[str, Any]]:
    worktree = [] if "--worktree" in flags else ["--worktree", str(world.work)]
    common = ["--timeout", "5", "--poll", "1", *worktree]
    return ship(world, "redeliver", "--branch", OLD, *common, *flags)


def _call(world: FakeWorld, *prefix: str) -> list[str] | None:
    return next((c for c in world.calls if c[: len(prefix)] == list(prefix)), None)


def _value(call: list[str], flag: str, prefix: bool = False) -> str:
    if prefix:  # a `-F name=value` field
        return next(a for a in call if a.startswith(flag)).removeprefix(flag)
    return call[call.index(flag) + 1]


@pytest.mark.parametrize("generation", [0, 1])
def test_redeliver_abandons_the_old_lane_with_the_registrys_generation_and_head(
    generation: int,
) -> None:
    world = _replacement_world(generation=generation)
    code, result = redeliver(world, "--check", "u=good", "--lane", "LANE-NEW")
    assert code == 0, result
    assert world.names() == ["resolve", "adopt", "hand-back", "receipt", "publish"]
    resolve = next(c for c in world.calls if c[1:2] == ["resolve"])
    assert _value(resolve, "--branch") == OLD
    assert _value(resolve, "--path") == "/gone/old-lane"
    assert _value(resolve, "--status") == "abandoned"
    assert _value(resolve, "--expected-generation") == str(generation)
    assert _value(resolve, "--expected-head-sha") == PUBLISHED
    close = _call(world, "gh", "pr", "close")
    assert close is not None and close[3] == "50"
    assert _value(close, "--comment").startswith("Superseded by #77 (u)")
    publish = next(
        i
        for i, c in enumerate(world.calls)
        if c[0].endswith("delivery.py") and c[3] == "publish"
    )
    assert world.calls.index(close) > publish  # the link exists before the close
    assert _value(world.calls[publish], "--replaces-pr") == "50"
    assert _call(world, "git", "push") == [
        "git",
        "push",
        f"--force-with-lease=refs/heads/{OLD}:{PUBLISHED}",
        "origin",
        "--delete",
        OLD,
    ]
    assert result["replaced"] == {
        "branch": OLD,
        "pr": 50,
        "claim_generation": generation,
        "published_head": PUBLISHED,
        "remote_branch": "deleted",
    }


def test_redeliver_keeps_an_old_remote_branch_that_moved_off_the_published_head() -> (
    None
):
    moved = "b" * 40
    world = _replacement_world(remote=moved)
    code, result = redeliver(world, "--check", "u=good")
    assert code == 0, result
    assert _call(world, "git", "push") is None
    assert result["replaced"]["remote_branch"] == (
        f"kept: at {moved}, not the published head {PUBLISHED}"
    )


@pytest.mark.parametrize(
    ("state", "flags", "message"),
    [
        ({"branch": OLD}, [], "commit the fix on a new branch"),
        ({"old_pr_state": "MERGED"}, [], "PR #50 is already merged"),
        ({"old_status": "active"}, [], "redeliver replaces a published lane"),
        ({"old_records": []}, [], f"no registry lane for {OLD}"),
        ({"old_prs": []}, [], f"no PR for {OLD}"),
        ({}, ["--lane", "LANE-OLD"], "is the replaced lane's id"),
        (
            {"pr_guard": [{"labels": {"nodes": [{"name": "delivery-hold:p1"}]}}]},
            [],
            "PR #50 carries a hard hold (p1)",
        ),
        (
            {"pr_guard": [{"body": _HOLDS_BLOCK}]},
            [],
            "PR #50 carries a hard hold (security)",
        ),
        (
            {"pr_guard": [{"autoMergeRequest": {"enabledAt": "t"}}]},
            [],
            "PR #50 is scheduled to merge",
        ),
        (
            {"pr_guard": [{"mergeQueueEntry": {"id": "q"}}]},
            [],
            "PR #50 is scheduled to merge",
        ),
    ],
)
def test_redeliver_refuses_before_touching_anything(
    state: dict[str, Any], flags: list[str], message: str
) -> None:
    world = _replacement_world(**state)
    code, result = redeliver(world, "--check", "u=good", *flags)
    assert code == 1
    assert message in result["error"]
    assert world.names() == []
    assert _call(world, "gh", "pr", "close") is None
    assert _call(world, "git", "push") is None


def test_redeliver_rereads_the_old_pr_before_abandoning_its_lane() -> None:
    """The checks can run for minutes; the old PR may get queued meanwhile."""
    world = _replacement_world(pr_guard=[{}, {"mergeQueueEntry": {"id": "q"}}])
    code, result = redeliver(world, "--check", "u=good")
    assert code == 1, result
    assert "PR #50 is scheduled to merge" in result["error"]
    assert "resolve" not in world.names()
    assert _call(world, "gh", "pr", "close") is None
    graphql = [c for c in world.calls if c[1:3] == ["api", "graphql"]]
    assert len(graphql) == 2


def test_redeliver_aborts_when_the_replaced_pr_merges_during_redelivery() -> None:
    """Checked at the lookup, not by the OPEN-only guard: a merged PR must not
    be reported as superseded, nor have its branch deleted."""
    world = _replacement_world(merge_old_after="publish")
    code, result = redeliver(world, "--check", "u=good")
    assert code == 1, result
    assert "PR #50 merged while #77 was replacing it" in result["error"]
    assert "not deleted" in result["error"]
    assert _call(world, "gh", "pr", "close") is None
    assert _call(world, "git", "push") is None
    assert world.remote_heads == {OLD: PUBLISHED}


def test_redeliver_rereads_the_old_pr_before_closing_it() -> None:
    world = _replacement_world(
        pr_guard=[{}, {}, {"labels": {"nodes": [{"name": "delivery-hold:p0"}]}}]
    )
    code, result = redeliver(world, "--check", "u=good")
    assert code == 1, result
    assert "PR #50 carries a hard hold (p0)" in result["error"]
    assert _call(world, "gh", "pr", "close") is None
    assert _call(world, "git", "push") is None


def test_delivery_options_before_redeliver_are_refused_not_dropped() -> None:
    argv = ["--worktree", "/fixed", "--merge", "redeliver", "--branch", OLD]
    with (
        contextlib.redirect_stderr(io.StringIO()) as err,
        pytest.raises(SystemExit) as stop,
    ):
        deliver.main(argv, runner=FakeWorld())
    assert stop.value.code == 2
    assert "--worktree, --merge" in err.getvalue()
    assert "after `redeliver`" in err.getvalue()
    parsed = deliver.build_parser().parse_args(
        ["redeliver", "--branch", OLD, "--worktree", "/fixed", "--merge"]
    )
    assert (parsed.worktree, parsed.merge) == ("/fixed", True)


def test_a_redeliver_rerun_skips_what_is_already_retired() -> None:
    world = _replacement_world(
        old_status="abandoned", old_pr_state="CLOSED", remote=None
    )
    code, result = redeliver(world, "--check", "u=good")
    assert code == 0, result
    assert world.names() == ["adopt", "hand-back", "receipt", "publish"]
    assert _call(world, "gh", "pr", "close") is None
    assert result["replaced"]["remote_branch"] == "absent"


def test_redeliver_resumes_from_the_new_branch_once_its_worktree_is_gone() -> None:
    world = _replacement_world(
        old_status="abandoned",
        new_records={"feat/new": [{"branch": "feat/new", "status": "published"}]},
        new_prs={"feat/new": [{"number": 77, "state": "OPEN", "url": "u"}]},
    )
    gone = str(world.work / "gone")
    code, result = redeliver(world, "--worktree", gone)
    assert code == 1 and "--new-branch" in result["error"]
    code, result = redeliver(world, "--worktree", gone, "--new-branch", "feat/new")
    assert code == 0, result
    assert world.names() == []  # already published: nothing re-claimed
    assert _call(world, "gh", "pr", "close") is not None
    assert result["pr"] == 77 and result["replaced"]["remote_branch"] == "deleted"


def test_the_old_remote_branch_is_deleted_only_at_the_published_head(
    tmp_path: Path,
) -> None:
    """Real git: the lease makes the delete a compare-and-swap on the remote."""
    import subprocess

    def sh(*argv: str, cwd: Path) -> str:
        done = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, check=True)
        return done.stdout.strip()

    remote, repo = tmp_path / "remote.git", tmp_path / "repo"
    sh("git", "init", "-q", "--bare", str(remote), cwd=tmp_path)
    sh("git", "init", "-q", "-b", "main", str(repo), cwd=tmp_path)
    sh("git", "config", "user.email", "t@example.com", cwd=repo)
    sh("git", "config", "user.name", "T", cwd=repo)
    sh("git", "remote", "add", "origin", str(remote), cwd=repo)
    (repo / "a.txt").write_text("1")
    sh("git", "add", ".", cwd=repo)
    sh("git", "commit", "-qm", "published", cwd=repo)
    published = sh("git", "rev-parse", "HEAD", cwd=repo)
    sh("git", "push", "-q", "origin", f"HEAD:refs/heads/{OLD}", cwd=repo)

    args = deliver.build_parser().parse_args(["--worktree", str(repo)])
    replacement = deliver.Replacement(
        deliver.Delivery(args, deliver.run, lambda _s: None), OLD
    )
    (repo / "a.txt").write_text("2")
    sh("git", "commit", "-qam", "pushed onto the PR", cwd=repo)
    moved = sh("git", "rev-parse", "HEAD", cwd=repo)
    sh("git", "push", "-q", "origin", f"HEAD:refs/heads/{OLD}", cwd=repo)
    assert replacement.drop_remote_branch(published) == (
        f"kept: at {moved}, not the published head {published}"
    )
    with pytest.raises(deliver.DeliverError, match="stale info|rejected"):
        replacement.delete_remote_branch(published)  # the lease refuses a moved ref
    assert sh("git", "ls-remote", "origin", f"refs/heads/{OLD}", cwd=repo)

    assert replacement.drop_remote_branch(moved) == "deleted"
    assert sh("git", "ls-remote", "origin", f"refs/heads/{OLD}", cwd=repo) == ""
    assert replacement.drop_remote_branch(moved) == "absent"


# ---- redeliver: the new tip has to carry the replaced lane's work ---------


def _lineage_refusal(**state: Any) -> tuple[FakeWorld, dict[str, Any]]:
    world = _replacement_world(**state)
    code, result = redeliver(world, "--check", "u=good")
    assert code == 1, result
    return world, result


@pytest.mark.parametrize(
    "state",
    [
        {"old_is_ancestor": False, "cherry": f"+ {'b' * 40}\n"},
        {"old_is_ancestor": False, "cherry": f"- {'b' * 40}\n+ {'e' * 40}\n"},
    ],
)
def test_redeliver_refuses_a_branch_that_does_not_carry_the_replaced_lane(
    state: dict[str, Any],
) -> None:
    """Any clean branch ahead of trunk used to retire an unrelated lane."""
    world, result = _lineage_refusal(**state)
    assert (
        f"does not carry the replaced lane's hand-back {PUBLISHED}" in result["error"]
    )
    assert world.names() == []  # nothing abandoned, adopted or published
    assert world.records_by_branch[OLD][0]["status"] == "published"
    assert _call(world, "gh", "pr", "close") is None
    assert _call(world, "git", "push") is None


def test_redeliver_names_the_unmatched_commits_of_the_replaced_lane() -> None:
    world, result = _lineage_refusal(
        old_is_ancestor=False, cherry=f"- {'b' * 40}\n+ {'e' * 40}\n"
    )
    assert ("e" * 12) in result["error"] and ("b" * 12) not in result["error"]


def test_redeliver_refuses_when_the_replaced_hand_back_is_not_in_the_repository() -> (
    None
):
    world, result = _lineage_refusal(old_object_present=False)
    assert f"hand-back {PUBLISHED} is not in this repository" in result["error"]
    assert world.names() == []


def test_redeliver_accepts_a_tip_that_contains_the_replaced_hand_back() -> None:
    world = _replacement_world(old_is_ancestor=True)
    code, result = redeliver(world, "--check", "u=good")
    assert code == 0, result
    assert world.names()[0] == "resolve"


def test_redeliver_accepts_a_tip_that_is_patch_equivalent_to_the_hand_back() -> None:
    world = _replacement_world(old_is_ancestor=False, cherry=f"- {'b' * 40}\n")
    code, result = redeliver(world, "--check", "u=good")
    assert code == 0, result
    assert world.names()[0] == "resolve"


def test_redeliver_compares_against_the_branch_when_the_worktree_is_gone() -> None:
    world = _replacement_world(
        old_status="abandoned",
        old_is_ancestor=False,
        cherry=f"+ {'b' * 40}\n",
        new_records={"feat/new": [{"branch": "feat/new", "status": "published"}]},
        new_prs={"feat/new": [{"number": 77, "state": "OPEN", "url": "u"}]},
    )
    gone = str(world.work / "gone")
    code, result = redeliver(world, "--worktree", gone, "--new-branch", "feat/new")
    assert code == 1 and "does not carry" in result["error"]
    assert _call(world, "gh", "pr", "close") is None
    assert _call(world, "git", "push") is None


def test_the_lineage_check_on_real_git(tmp_path: Path) -> None:
    """Ancestor and rebased tips pass; an unrelated or reworded one is refused."""
    import subprocess

    def sh(*argv: str) -> str:
        done = subprocess.run(
            argv, cwd=tmp_path, capture_output=True, text=True, check=True
        )
        return done.stdout.strip()

    def commit(name: str, text: str) -> None:
        (tmp_path / name).write_text(text)
        sh("git", "add", name)
        sh("git", "commit", "-qm", f"{name}: {text}")

    sh("git", "init", "-q", "-b", "main")
    sh("git", "config", "user.email", "t@example.com")
    sh("git", "config", "user.name", "T")
    commit("base.txt", "base")
    sh("git", "switch", "-q", "-c", "old")
    commit("one.txt", "1")
    commit("two.txt", "2")
    published = sh("git", "rev-parse", "HEAD")
    sh("git", "switch", "-q", "-c", "ancestor")  # old + a review fix
    commit("fix.txt", "fix")
    sh("git", "switch", "-q", "main")
    commit("main-moved.txt", "m")  # trunk moves on; old is now stale
    sh("git", "switch", "-q", "-c", "rebased")
    sh("git", "cherry-pick", "old~1", "old")
    commit("fix.txt", "fix")
    sh("git", "switch", "-q", "main")
    sh("git", "switch", "-q", "-c", "unrelated")
    commit("other.txt", "elsewhere")
    sh("git", "switch", "-q", "-c", "reworded", "main")
    sh("git", "cherry-pick", "old~1")
    commit("two.txt", "2 but different")  # the second commit's patch changed

    args = deliver.build_parser().parse_args(["--worktree", str(tmp_path)])
    replacement = deliver.Replacement(
        deliver.Delivery(args, deliver.run, lambda _s: None), "old"
    )
    record = {"handed_back_sha": published}
    for tip in ("ancestor", "rebased"):
        sh("git", "switch", "-q", tip)
        replacement.check_lineage(record)  # no raise
    for tip in ("unrelated", "reworded"):
        sh("git", "switch", "-q", tip)
        with pytest.raises(deliver.DeliverError, match="does not carry"):
            replacement.check_lineage(record)


# ---- redeliver: the guard holds across every lock-wait retry --------------


def test_redeliver_rechecks_the_old_pr_after_waiting_on_the_lock() -> None:
    """abandon waits out a busy lock; the PR may be queued during that wait."""
    world = _replacement_world(
        lock_busy={"resolve": 1},
        pr_guard=[{}, {}, {"mergeQueueEntry": {"id": "q"}}],
    )
    code, result = redeliver(world, "--check", "u=good")
    assert code == 1, result
    assert "PR #50 is scheduled to merge" in result["error"]
    assert world.names() == ["resolve"]  # the one refused attempt, no retry
    assert world.records_by_branch[OLD][0]["status"] == "published"
    assert _call(world, "gh", "pr", "close") is None
    assert _call(world, "git", "push") is None


def test_redeliver_rechecks_for_a_hold_added_during_the_lock_wait() -> None:
    world = _replacement_world(
        lock_busy={"resolve": 2},
        pr_guard=[{}, {}, {}, {"labels": {"nodes": [{"name": "delivery-hold:p0"}]}}],
    )
    code, result = redeliver(world, "--check", "u=good")
    assert code == 1, result
    assert "PR #50 carries a hard hold (p0)" in result["error"]
    assert world.names() == ["resolve", "resolve"]
    assert world.records_by_branch[OLD][0]["status"] == "published"


def test_redeliver_still_abandons_when_the_pr_stays_clean_across_the_wait() -> None:
    world = _replacement_world(lock_busy={"resolve": 1}, trunk_moves_to="9" * 40)
    code, result = redeliver(world, "--check", "u=good")
    assert code == 0, result
    assert world.names()[:2] == ["resolve", "resolve"]
    assert _adopt_bases(world) == [world.fork]  # not the main fetched meanwhile
    graphql = [c for c in world.calls if c[1:3] == ["api", "graphql"]]
    assert len(graphql) >= 3  # run, retire, and once more before the retry


# --- post-merge verification that every Closes issue closed (#2654) ---------

_CLOSES_BODY = "## Issues\nCloses #2029\nCloses #2030\nRefs #9\n\n"


def _issue_views(world: FakeWorld) -> list[str]:
    return [c[3] for c in world.calls if c[1:3] == ["issue", "view"]]


def test_merge_verifies_every_closes_issue_is_closed_after_cleanup() -> None:
    world = FakeWorld(pr_body=_CLOSES_BODY)
    code, result = ship(world, "--check", "unit=good", "--merge")
    assert code == 0
    assert result["result"] == "merged"
    assert _issue_views(world) == ["2029", "2030"]  # Refs #9 is not read
    assert world.names()[-2:] == ["cleanup-merged", "sync-main"]


def test_merge_waits_briefly_for_github_to_close_the_issue() -> None:
    world = FakeWorld(pr_body=_CLOSES_BODY, issue_states={2029: ["OPEN", "CLOSED"]})
    code, result = ship(world, "--check", "unit=good", "--merge")
    assert code == 0, result
    assert _issue_views(world) == ["2029", "2029", "2030"]


def test_merge_fails_loudly_when_a_closes_issue_is_still_open() -> None:
    world = FakeWorld(pr_body=_CLOSES_BODY, issue_states={2030: ["OPEN"]})
    code, result = ship(world, "--check", "unit=good", "--merge")
    assert code == 1
    assert "#2030" in result["error"] and "still open" in result["error"]


def test_a_merged_pr_without_closes_reads_no_issue() -> None:
    world = FakeWorld(prs=[{"number": 9, "state": "MERGED"}], pr_body="no issues")
    code, _ = ship(world, "--merge")
    assert code == 0
    assert _issue_views(world) == []


def test_run_survives_non_utf8_output(tmp_path: Path) -> None:
    """A check that prints invalid UTF-8 must not crash the delivery (#2770)."""
    cmd = [
        sys.executable,
        "-c",
        "import sys; sys.stdout.buffer.write(b'ok \\xff\\xfe bad')",
    ]
    done = deliver.run(cmd, tmp_path)
    assert done.returncode == 0
    assert done.stdout.startswith("ok ")
    assert "bad" in done.stdout


@pytest.mark.parametrize("state", ["TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"])
def test_every_red_required_state_fails_the_run(state: str) -> None:
    """A terminal-red required check must fail fast, not poll to timeout (#2447)."""
    world = FakeWorld(checks=[[{"name": "required", "state": state}]])
    code, result = ship(world, "--check", "u=good")
    assert code == 1
    assert state in result["error"]


@pytest.mark.parametrize("state", ["SKIPPED", "NEUTRAL"])
def test_a_skipped_or_neutral_required_check_passes(state: str) -> None:
    world = FakeWorld(checks=[[{"name": "required", "state": state}]])
    code, _ = ship(world, "--check", "u=good")
    assert code == 0
