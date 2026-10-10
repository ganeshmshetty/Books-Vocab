#!/usr/bin/env -S uv run --python 3.13 python
"""Deliver one worktree branch through the official flow with a single command.

    ./ops/deliver.py --check "unit=uv run pytest -q" --merge

It only sequences the existing tools (`worktree_orchestrate.py`, `delivery.py`,
`gh`); it owns no state.  Where the lane stands is read back from the registry
and GitHub on every run, so a run that died halfway is simply run again.

Stages: checks -> adopt -> hand-back -> receipt -> publish -> wait-required ->
(with --merge) wait agent-review -> queue -> wait-merged -> cleanup -> sync-main.
--merge waits until agent-review on the exact head settles to success or
failure (`neutral` is the workflow giving up on the bot, not a verdict; only
--accept-no-review '<reason>' queues on it), and refuses to queue while it
failed or the review bot left inline comments on the head, unless
--accept-review-findings gives a reason.  A mutation that meets a busy delivery lock retries (--lock-timeout).
A failed stage reports the underlying error whole.

Before the checks run, the changed ``*.py`` files are formatted with the very
``ruff format`` the pr-gate pins (version read from pr-gate.yml, never restated
here).  A rewrite is committed in the lane worktree as ``style: ruff format
(pre-publish)`` so the checks and the hand-back see the formatted code; nothing
runs when no Python file changed, and a worktree that is dirty beforehand is
refused rather than folded into that commit.

Outcomes written into the hand-back receipt come only from the ``--check``
commands this run executed: status from the exit code, detail from the last
non-empty line of stdout (stderr only when stdout is empty).  Each check's full output is also kept under the
canonical checkout's ``.cache/deliver-checks/`` (gitignored) and a failed check
prints its last lines to stderr; the failure JSON lists the checks with their
``log`` paths.  Logs hold raw test output, never the environment.  There is no way to pass an outcome in by hand.

``deliver.py gc`` retires lanes whose PR is already merged (the ghost claims
`doctor.py` reports) via `delivery.py cleanup-merged`, worktree present or not,
after one REST read of the closed PRs.

``deliver.py redeliver --branch <published-lane-branch> --worktree <fixed-tip>
[--lane <new-lane>] --check ... [--merge]`` replaces a published PR after review
fixes (see ``Replacement``); delivery options go after ``redeliver``.

Exit code: 0 delivered (or stopped where asked), 1 a stage failed, 2 usage.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from delivery_control.adapters.operation_lock import OperationLock
from delivery_control.domain.check_states import FAILURE_STATES, SUCCESS_STATES
from delivery_control.domain.errors import DeliverySourceError, PolicyViolation
from delivery_control.services.pr_contract import (
    parse_body_holds,
    pull_request_label_holds,
    salvage_body_issues,
)
from lib import worktree_scope

SCHEMA = "kg.deliver.v1"
TRUNK = "origin/main"
OPS = Path(__file__).resolve().parent
PR_GATE = OPS.parent / ".github" / "workflows" / "pr-gate.yml"
# Raised by delivery_control/adapters/operation_lock.py (a test pins the text).
LOCK_BUSY = "delivery mutation already in progress"
LOCK_RETRY_SECONDS = 5.0
# GitHub closes `Closes #N` issues a moment after the merge event (#2654).
ISSUE_CLOSE_POLLS = 5
ISSUE_CLOSE_POLL_SECONDS = 3.0
AGENT_REVIEW = OPS.parent / ".github" / "workflows" / "agent-review.yml"
REVIEW_CHECK = "agent-review"
# The workflow posts its verdicts as extra check runs carrying this external_id
# prefix; a run cancelled by a newer event leaves its in_progress one behind.
REVIEW_MARKER = "kg.agent-review.v1:"
REVIEW_FAILED = frozenset(
    {"failure", "timed_out", "action_required", "startup_failure"}
)
SHA = re.compile(r"[0-9a-f]{40}")
FORMAT_COMMIT_MESSAGE = (
    "style: ruff format (pre-publish)\n\nCo-Authored-By: Claude <noreply@anthropic.com>"
)
# What delivery.py abandon-pr refuses on, read for the PR redeliver replaces.
PR_GUARD_QUERY = (
    "query($owner: String!, $name: String!, $number: Int!) {"
    " repository(owner: $owner, name: $name) { pullRequest(number: $number) {"
    " number state body labels(first: 100) { nodes { name } }"
    " autoMergeRequest { enabledAt } mergeQueueEntry { id } } } }"
)
QUEUE_ENTRY_QUERY = (
    "query($owner: String!, $name: String!, $number: Int!) {"
    " repository(owner: $owner, name: $name) { pullRequest(number: $number) {"
    " mergeQueueEntry { id headCommit { oid } } } } }"
)
# Area quality suites that merge_group re-runs; a red one on the head ejects the PR.
# GitHub names each job ``<area> / <job>``; a bare ``<area>`` is a caller-level job.
AREA_QUALITY_CHECKS = ("backend-quality", "ops-suite", "ios-quality")


class DeliverError(Exception):
    """A stage failed; the message says which and why.

    ``extra`` is merged into the failure JSON (additive fields only).
    """

    def __init__(self, message: str, extra: dict[str, Any] | None = None):
        super().__init__(message)
        self.extra = extra or {}


@dataclass(frozen=True)
class Proc:
    returncode: int
    stdout: str
    stderr: str


Runner = Callable[[list[str], Path | None], Proc]


def run(cmd: list[str], cwd: Path | None = None) -> Proc:
    done = subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    return Proc(done.returncode, done.stdout, done.stderr)


def progress(message: str) -> None:
    """Progress goes to stderr; stdout stays one JSON document."""
    print(f"deliver: {message}", file=sys.stderr, flush=True)


def failure_detail(done: Proc) -> str:
    """Everything a failed command said, never a tail.

    ``delivery.py`` reports a failure as one JSON document (``ok: false``) after
    its progress lines; its ``error`` is the underlying cause, often a GitHub
    message that follows a long GraphQL query, so it is returned whole.  Any
    other command's streams are returned whole.
    """
    for stream in (done.stderr, done.stdout):
        for line in reversed(stream.strip().splitlines()):
            try:
                doc = json.loads(line)
            except ValueError:
                continue
            if isinstance(doc, dict) and doc.get("ok") is False:
                if isinstance(doc.get("error"), str):
                    return doc["error"]
    return "\n".join(s.strip() for s in (done.stderr, done.stdout) if s.strip())


@dataclass(frozen=True)
class LockWait:
    """Bounded wait while another delivery mutation holds the operation lock.

    Every delivery/registry/worktree mutation takes the lock before it changes
    anything, so an attempt refused with ``LOCK_BUSY`` did nothing and is safe
    to repeat.
    """

    timeout: float
    sleep: Callable[[float], None]
    clock: Callable[[], float]
    say: Callable[[str], None]

    def backoff(self, stage: str, detail: str, started: float) -> None:
        """One busy refusal: sleep before the next attempt, or give up at the timeout."""
        left = started + self.timeout - self.clock()
        if left <= 0:
            raise DeliverError(
                f"{stage}: the delivery mutation lock is still held after "
                f"{self.timeout:g}s: {detail}"
            )
        self.say(
            f"{stage}: another delivery mutation holds the operation lock "
            f"({detail}); retrying for up to {left:g}s more"
        )
        self.sleep(min(LOCK_RETRY_SECONDS, left))


def must(
    runner: Runner,
    cmd: list[str],
    cwd: Path | None,
    stage: str,
    lock: LockWait | None = None,
    before_retry: Callable[[], object] | None = None,
) -> Proc:
    """Run ``cmd``; on a busy lock wait and retry, up to the lock timeout.

    ``before_retry`` runs after every lock wait, before the next attempt: a
    caller whose precondition can lapse while it waits re-checks it there (and
    raises to stop the retry).
    """
    started = lock.clock() if lock else 0.0
    while True:
        done = runner(cmd, cwd)
        if done.returncode == 0:
            return done
        detail = failure_detail(done) or "no output"
        if lock is None or LOCK_BUSY not in detail:
            raise DeliverError(f"{stage} failed (rc={done.returncode}): {detail}")
        lock.backoff(stage, detail, started)
        if before_retry is not None:
            before_retry()


# --- pure helpers -----------------------------------------------------------


def scope_from_name_status(text: str) -> dict[str, Any]:
    """`git diff --name-status -z` -> a kg.worktree.scope.v1 document.

    A rename is a delete of the old path plus an add of the new one, which is
    how Scope overlap has to see it.
    """
    try:
        return worktree_scope.scope_from_name_status(text)
    except ValueError as exc:
        raise DeliverError(str(exc)) from exc


def _scope_key(scope: object) -> list[tuple[str, str]]:
    files = scope.get("files") if isinstance(scope, dict) else None
    return sorted(
        (str(item.get("path")), str(item.get("operation")))
        for item in files or []
        if isinstance(item, dict)
    )


def lane_from_branch(branch: str, stamp: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9]+", "-", branch).strip("-").upper()
    return (
        f"DIRECT-DELIVERY-{slug}"
        if slug.endswith(stamp)
        else f"DIRECT-DELIVERY-{slug}-{stamp}"
    )


def parse_check(spec: str) -> tuple[str, str]:
    label, sep, command = spec.partition("=")
    if not sep or not label.strip() or not command.strip():
        raise DeliverError(f"--check wants 'label=command', got {spec!r}")
    return label.strip(), command.strip()


TAIL_LINES = 40


def _slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._]+", "-", text).strip("-")[:60] or "x"


def run_checks(
    specs: list[str],
    cwd: Path,
    runner: Runner,
    log_dir: Path | None = None,
    tag: str = "",
) -> list[dict[str, str]]:
    """Run every check (no early exit) and report what actually happened.

    With ``log_dir`` each check's full output goes to a file named in the
    outcome's ``log``; a failed check also prints its last ``TAIL_LINES`` lines
    to stderr so the progress stream says why it failed.
    """
    outcomes = []
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
    for spec in specs:
        label, command = parse_check(spec)
        done = runner(["bash", "-c", command], cwd)
        ok = done.returncode == 0
        text = "\n".join(p for p in (done.stdout, done.stderr) if p.strip())
        # detail keeps the historical rule: stdout's last line, stderr only when
        # stdout is empty (uv/pytest warnings on stderr must not mask "3 passed").
        lines = (done.stdout.strip() or done.stderr.strip()).splitlines()
        lines = [ln for ln in lines if ln.strip()]
        outcome = {
            "check": label,
            "status": "passed" if ok else "failed",
            "detail": (lines[-1].strip() if lines else f"rc={done.returncode}")[:120],
        }
        if log_dir is not None:
            log = log_dir / f"{_slug(tag)}-{_slug(label)}-{stamp}.log"
            try:
                log_dir.mkdir(parents=True, exist_ok=True)
                log.write_text(f"$ {command}\n# rc={done.returncode}\n{text}\n")
                outcome["log"] = str(log)
            except OSError as exc:
                print(f"deliver: cannot write check log: {exc}", file=sys.stderr)
        if not ok:
            print(
                f"deliver: check {label!r} output (last {TAIL_LINES} lines):",
                file=sys.stderr,
            )
            for line in text.splitlines()[-TAIL_LINES:]:
                print(f"deliver:   | {line}", file=sys.stderr)
            if "log" in outcome:
                print(f"deliver: full output: {outcome['log']}", file=sys.stderr)
        outcomes.append(outcome)
    return outcomes


def ruff_format_command(workflow: str) -> list[str]:
    """The pr-gate's pinned format invocation, minus the files and the mode flag.

    The workflow is the single source of the pin; if its shape changes so this
    can no longer find it, fail closed instead of guessing a version.
    """
    found = re.search(
        r"uv run --no-project --python (\S+) --with 'ruff==([0-9][^']*)' ruff format",
        workflow,
    )
    if not found:
        raise DeliverError(
            f"cannot read the pinned ruff from {PR_GATE.name}; "
            "update deliver.ruff_format_command with the workflow"
        )
    python, version = found.groups()
    return [
        "uv",
        "run",
        "--no-project",
        "--python",
        python,
        "--with",
        f"ruff=={version}",
        "ruff",
        "format",
    ]


def next_stage(record: dict[str, Any] | None, pr: dict[str, Any] | None) -> str:
    """Where a (re)run has to start, given what the registry and GitHub already hold."""
    if pr is not None:
        if pr.get("state") == "MERGED":
            return "cleanup"
        if pr.get("state") == "OPEN":
            # A publish that died after creating the PR leaves the lane short
            # of ``published``; waiting would queue an unpublished record (#2448).
            status = record.get("status") if record else None
            if status == "active":
                return "receipt" if record.get("handback_seal") else "hand-back"
            if status == "cleanup_pending":
                return "release-published"
            return "wait-required"
        raise DeliverError(
            f"PR #{pr.get('number')} is {pr.get('state')}; open a fresh lane"
        )
    if record is None:
        return "adopt"
    status = record.get("status")
    if status == "active":
        return "receipt" if record.get("handback_seal") else "hand-back"
    if status == "published":
        return "wait-required"
    raise DeliverError(f"lane is {status!r}; resolve it before delivering again")


def review_bots(workflow: str) -> tuple[str, ...]:
    """The reviewer logins agent-review.yml trusts; read there, never restated."""
    bots = re.findall(r"^\s*REVIEW_BOT(?:_CURRENT)?:\s*(\S+)\s*$", workflow, re.M)
    if not bots:
        raise DeliverError(
            f"cannot read the review bot from {AGENT_REVIEW.name}; "
            "update deliver.review_bots with the workflow"
        )
    return tuple(bots)


QUOTA_MARKER = "usage limit"


def review_verdict(runs: list[dict[str, Any]]) -> str | None:
    """The settled `agent-review` verdict of one head, or None while pending.

    Pending while an Actions job run is unfinished or nothing has concluded
    (orphaned in_progress verdict markers are ignored); failure if any run
    failed; otherwise the best posted verdict, or the job's own conclusion
    when it posted none.
    """
    runs = [r for r in runs if r.get("name") == REVIEW_CHECK]

    def marker(run: dict[str, Any]) -> bool:
        return str(run.get("external_id") or "").startswith(REVIEW_MARKER)

    if any(r.get("status") != "completed" and not marker(r) for r in runs):
        return None
    done = [r for r in runs if r.get("status") == "completed"]
    # A failure stands unless a strictly newer success superseded it (a rerun);
    # ties keep the failure, and an undated failure (no start time to compare)
    # always stands: fail closed.
    failed_at = [started_of(r) for r in done if r.get("conclusion") in REVIEW_FAILED]
    passed_at = [started_of(r) for r in done if r.get("conclusion") == "success"]
    if failed_at and (
        not passed_at or "" in failed_at or max(failed_at) >= max(passed_at)
    ):
        return "failure"
    verdicts = {r.get("conclusion") for r in done if marker(r)} or {
        r.get("conclusion") for r in done
    }
    return next((v for v in ("success", "neutral") if v in verdicts), None)


def quota_text(text: Any) -> bool:
    return QUOTA_MARKER in str(text or "").lower()


def bot_down(runs: list[dict[str, Any]]) -> bool:
    """Whether a completed neutral `agent-review` run itself reports a quota stop.

    The workflow's own neutral title ("review unavailable") is posted on every
    neutral, so it is no evidence: the bot may still review later.
    """
    return any(
        quota_text(
            f"{(r.get('output') or {}).get('title')} {(r.get('output') or {}).get('summary')}"
        )
        for r in runs
        if r.get("status") == "completed" and r.get("conclusion") == "neutral"
    )


def quota_reply(items: list[dict[str, Any]], since: str, bots: tuple[str, ...]) -> bool:
    """A comment/review by the review bot saying it is out of quota, at or after ``since``."""
    for item in items:
        posted = str(item.get("created_at") or item.get("submitted_at") or "")
        if (
            (item.get("user") or {}).get("login") in bots
            and quota_text(item.get("body"))
            and since
            and posted >= since
        ):
            return True
    return False


CR_VERDICT = re.compile(r"(?im)^[ \t]*CR verdict:[ \t]*(approve|approved)\b")
CR_TRUSTED = frozenset({"OWNER", "MEMBER", "COLLABORATOR"})


def cr_verdict_recorded(
    items: list[dict[str, Any]], head: str, bots: tuple[str, ...]
) -> bool:
    """A maintainer comment/review on the PR saying `CR verdict: APPROVE <head>`.

    The verdict must name the exact head, come from a repository maintainer and
    not from the review bot, so `--accept-no-review` cites something on the PR
    rather than free text.
    """
    return any(
        (item.get("user") or {}).get("login") not in bots
        and item.get("author_association") in CR_TRUSTED
        and head in str(item.get("body") or "")
        and CR_VERDICT.search(str(item.get("body") or "")) is not None
        for item in items
    )


def review_run_id(run: dict[str, Any]) -> int | None:
    """The Actions workflow run behind one `agent-review` check run, if it names one.

    The verdict marker is ``kg.agent-review.v1:<run id>:<sha>``; the Actions
    job's own check run links ``.../actions/runs/<run id>/job/<job id>``.
    """
    marker = str(run.get("external_id") or "")
    if marker.startswith(REVIEW_MARKER):
        found = re.match(r"(\d+):", marker.removeprefix(REVIEW_MARKER))
    else:
        found = re.search(r"/actions/runs/(\d+)", str(run.get("details_url") or ""))
    return int(found.group(1)) if found else None


def workflow_run_is_of(run: dict[str, Any], number: int, head_ref: str) -> bool:
    """Whether a workflow run was triggered by PR ``number``.

    A head sha is not enough: redeliver's replacement PR shares the replaced
    PR's sha, and the commit-level check list holds both PRs' runs.  The run's
    ``pull_requests`` names its PR; a run that names none (GitHub leaves it
    empty at times) is owned only by its ``head_branch`` being this PR's head
    ref.  Comment-triggered runs carry the default branch, so they match
    neither and are never attributed.
    """
    numbers = [p.get("number") for p in run.get("pull_requests") or []]
    if numbers:
        return number in numbers
    return bool(head_ref) and run.get("head_branch") == head_ref


def review_findings(
    comments: list[dict[str, Any]], head: str, bots: tuple[str, ...]
) -> list[dict[str, str]]:
    """The inline comments the review bot left on this exact head."""
    return [
        {
            "where": ":".join(
                str(part)
                for part in (c.get("path"), c.get("line") or c.get("original_line"))
                if part
            ),
            "summary": next(
                (s.strip() for s in str(c.get("body") or "").splitlines() if s.strip()),
                "",
            ),
            "url": str(c.get("html_url") or ""),
        }
        for c in comments
        if (c.get("user") or {}).get("login") in bots
        and head in (c.get("commit_id"), c.get("original_commit_id"))
    ]


def required_state(checks: list[dict[str, Any]]) -> str:
    states = [c.get("state") for c in checks if c.get("name") == "required"]
    if not states:
        return "PENDING"
    return str(states[0])


def started_of(run: dict[str, Any]) -> str:
    """ISO start time of a check run; ``""`` when GitHub gave none (sorts oldest)."""
    return str(run.get("started_at") or run.get("startedAt") or "")


def newest_by_name(checks: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """The newest run per check name, by start time (the list order breaks ties)."""
    newest: dict[str, dict[str, Any]] = {}
    for check in checks:
        name = check.get("name")
        if name is None:
            continue
        if name not in newest or started_of(check) >= started_of(newest[name]):
            newest[name] = check
    return newest


def check_state(check: dict[str, Any]) -> str:
    """``failed`` / ``passed`` for a terminal state, ``pending`` for anything else."""
    state = str(check.get("state") or "")
    if state in FAILURE_STATES:
        return "failed"
    if state in SUCCESS_STATES:
        return "passed"
    return "pending"


def area_of(name: str) -> str | None:
    """The AREA_QUALITY_CHECKS suite a check run belongs to, e.g. ``ios-quality``."""
    return next(
        (a for a in AREA_QUALITY_CHECKS if name == a or name.startswith(f"{a} / ")),
        None,
    )


# --- stages -----------------------------------------------------------------


class Delivery:
    def __init__(
        self,
        args: argparse.Namespace,
        runner: Runner,
        sleep: Callable[[float], None],
        clock: Callable[[], float] = time.monotonic,
    ):
        self.args = args
        self.runner = runner
        self.sleep = sleep
        self.clock = clock
        self.work = Path(args.worktree).resolve()
        self.canon: Path | None = None
        self.log: list[str] = []
        self.extra: dict[str, Any] = {}
        self.queued = False  # set once `queue` succeeded; a later dequeue is ejection
        self.queue_head: str | None = None  # merge group commit last seen in the queue
        self.lock = LockWait(args.lock_timeout, sleep, clock, self.say)
        # redeliver's hooks: retire the replaced lane before this one claims
        # its Scope, and supersede the replaced PR once this one exists.
        self.before_claim: Callable[[], object] = lambda: None
        self.after_publish: Callable[[dict[str, Any]], object] = lambda _pr: None
        # the open PR redeliver closes after publishing; publish preflight must
        # not count it as a Scope collision.
        self.replaces_pr: int | None = None

    def mutate(
        self,
        cmd: list[str],
        cwd: Path | None,
        stage: str,
        before_retry: Callable[[], object] | None = None,
    ) -> Proc:
        """Run a delivery/registry/worktree mutation, waiting out a busy lock."""
        return must(self.runner, cmd, cwd, stage, self.lock, before_retry)

    @property
    def home(self) -> Path:
        """Where to run repo-wide commands: publish deletes the lane worktree mid-run."""
        return self.work if self.work.exists() else (self.canon or Path.cwd())

    def git(self, *argv: str, stage: str = "git") -> str:
        return must(self.runner, ["git", *argv], self.home, stage).stdout.strip()

    def say(self, message: str) -> None:
        self.log.append(message)
        progress(message)

    def canonical(self) -> Path:
        out = self.git(
            "worktree", "list", "--porcelain", stage="locate canonical checkout"
        )
        return Path(out.splitlines()[0].removeprefix("worktree ").strip())

    def gh_repo(self) -> str:
        return must(
            self.runner,
            ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
            self.home,
            "resolve repository",
        ).stdout.strip()

    def registry_records(self, branch: str) -> list[dict[str, Any]]:
        out = must(
            self.runner,
            [str(OPS / "worktree_registry.py"), "list", "--json", "--branch", branch],
            self.home,
            "read registry",
        ).stdout
        data = json.loads(out)
        records = data["records"] if isinstance(data, dict) else data
        return [r for r in records if r.get("branch") == branch]

    def registry_record(self, branch: str) -> dict[str, Any] | None:
        live = [
            r for r in self.registry_records(branch) if r.get("status") != "abandoned"
        ]
        return live[-1] if live else None

    def pull_request(self, repo: str, branch: str) -> dict[str, Any] | None:
        out = must(
            self.runner,
            [
                "gh",
                "pr",
                "list",
                "--repo",
                repo,
                "--head",
                branch,
                "--state",
                "all",
                "--json",
                "number,state,url",
                "-q",
                "sort_by(.number) | reverse",
            ],
            self.home,
            "look up PR",
        ).stdout.strip()
        prs = json.loads(out or "[]")
        return prs[0] if prs else None

    def fetch_trunk(self) -> None:
        """Refresh origin/main holding the delivery operation lease.

        A fetch rewrites the one refs/remotes/origin/main that every worktree
        shares; run beside another fetch or a delivery's sync-main it fails
        with "cannot lock ref ... is at X but expected Y".  Taking the lease
        every other ref mutation takes serializes it; a busy lease is waited
        out like any other mutation's.
        """
        started = self.lock.clock()
        while True:
            try:
                with OperationLock(self.canonical(), command="deliver:fetch"):
                    self.git("fetch", "-q", "origin", "main", stage="preflight")
                return
            except DeliverySourceError as exc:
                if LOCK_BUSY not in str(exc):
                    raise
                self.lock.backoff("preflight fetch", str(exc), started)

    def preflight(self) -> str:
        branch = self.git("rev-parse", "--abbrev-ref", "HEAD", stage="preflight")
        if branch in ("main", "HEAD"):
            raise DeliverError(
                f"refusing to deliver from {branch!r}; use a lane worktree branch"
            )
        if self.git("status", "--porcelain", stage="preflight"):
            raise DeliverError("worktree has uncommitted changes; commit them first")
        self.fetch_trunk()
        if self.git("rev-list", "--count", f"{TRUNK}..HEAD", stage="preflight") == "0":
            raise DeliverError(f"branch has no commits ahead of {TRUNK}")
        return branch

    def rebase_if_behind(self) -> None:
        behind = self.git("rev-list", "--count", f"HEAD..{TRUNK}", stage="preflight")
        if behind == "0":
            return
        done = self.runner(["git", "rebase", TRUNK], self.work)
        if done.returncode != 0:
            self.runner(["git", "rebase", "--abort"], self.work)
            raise DeliverError(
                f"branch is {behind} commit(s) behind {TRUNK} and does not rebase "
                f"cleanly (rebase aborted):\n{failure_detail(done) or 'no output'}"
            )
        self.say(f"rebased onto {TRUNK} ({behind} commit(s))")

    def format_changed_python(self) -> None:
        """Format the changed Python files with the pr-gate's pinned ruff; commit any rewrite.

        The pr-gate fails a PR whose changed ``*.py`` files are not ruff-formatted,
        so deliver applies the same pinned ``ruff format`` first.  Only a clean
        worktree is touched, so the commit holds exactly the formatter's rewrite;
        it lands before the checks run, so they test what gets handed back.
        """
        names = self.git(
            "diff", "--name-only", "--diff-filter=d", f"{TRUNK}...HEAD", "--", "*.py"
        )
        files = [line for line in names.splitlines() if line.strip()]
        if not files:
            self.say("format: no changed Python files")
            return
        if self.git("status", "--porcelain", stage="format"):
            raise DeliverError(
                "worktree has uncommitted changes; commit them before the "
                "pre-publish format step"
            )
        try:
            base = ruff_format_command(PR_GATE.read_text())
        except OSError as exc:
            raise DeliverError(f"cannot read {PR_GATE}: {exc}") from exc
        done = self.runner([*base, *files], self.work)
        if done.returncode != 0:
            raise DeliverError(
                f"ruff format failed (rc={done.returncode}): "
                f"{failure_detail(done) or 'no output'}"
            )
        if not self.git("status", "--porcelain", stage="format"):
            self.say(f"format ok: {len(files)} changed Python file(s)")
            return
        self.git("add", "--", *files, stage="format commit")
        self.git("commit", "-m", FORMAT_COMMIT_MESSAGE, stage="format commit")
        self.say(
            f"format: committed ruff rewrite of {len(files)} changed Python file(s)"
        )

    def abandon(
        self,
        branch: str,
        path: str | None,
        generation: object,
        head: str,
        stage: str,
        before_retry: Callable[[], object] | None = None,
    ) -> None:
        """Retire one exact claim through the registry's compare-and-swap."""
        self.mutate(
            [str(OPS / "worktree_orchestrate.py"), "resolve", "--branch", branch]
            + (["--path", path] if path else [])
            + ["--status", "abandoned", "--expected-generation", str(generation)]
            + ["--expected-head-sha", head, "--json"],
            self.home,
            stage,
            before_retry,
        )

    def claim_base(self) -> str:
        """The exact commit a claim declares as its base: HEAD's fork from trunk.

        Never the symbolic ``origin/main``: adopt resolves that only when it
        finally runs, after any lock wait, and another delivery's fetch may
        have moved it to a commit HEAD does not contain, which hand-back then
        refuses as a declared base that is not an ancestor of HEAD.
        """
        base = self.git("merge-base", "HEAD", TRUNK, stage="claim base")
        if not SHA.fullmatch(base):
            raise DeliverError(
                f"cannot pin the claim base: merge-base HEAD {TRUNK} gave {base!r}"
            )
        return base

    def claim_base_is_stale(self, record: dict[str, Any]) -> bool:
        """Whether an active claim's base is not the branch's fork point.

        A claim adopted against a stale local ``main`` records that old base;
        once the branch sits on a newer ``origin/main`` the three-dot diff then
        includes merged main commits and the receipt refuses.  The caller
        re-adopts with ``worktree_orchestrate.py readopt``, which retires the
        claim and adopts again under one operation-lock lease.
        """
        return record.get("base_sha") != self.claim_base()

    def wait_for(self, what: str, probe: Callable[[], str | None]) -> str:
        deadline = self.clock() + self.args.timeout
        while True:
            result = probe()
            if result is not None:
                return result
            if self.clock() >= deadline:
                raise DeliverError(
                    f"timed out after {self.args.timeout}s waiting for {what}"
                )
            self.sleep(self.args.poll)

    def deliver(self) -> dict[str, Any]:
        if self.work.exists():
            branch = self.preflight()
            if self.args.branch and self.args.branch != branch:
                raise DeliverError(
                    f"--branch {self.args.branch!r} is not the checked-out branch {branch!r}"
                )
        elif self.args.branch:
            branch = self.args.branch
        else:
            raise DeliverError(
                f"worktree {self.work} is gone; pass --branch to resume a published lane"
            )
        repo = self.gh_repo()
        canon = self.canon = self.canonical()
        delivery = [str(canon / "ops" / "delivery.py"), "--repo", str(canon)]
        record = self.registry_record(branch)
        pr = self.pull_request(repo, branch)
        if (
            self.args.branch
            and pr is not None
            and pr.get("state") == "MERGED"
            and (record is None or record.get("status") in ("merged", "abandoned"))
        ):
            raise DeliverError(
                f"PR #{pr.get('number')} already merged; start a new lane from {TRUNK}"
            )
        stage = next_stage(record, pr)
        lane = self.args.lane or (
            record["external_ids"][0] if record and record.get("external_ids") else None
        )
        lane = lane or lane_from_branch(branch, time.strftime("%Y%m%d", time.gmtime()))
        self.say(f"branch={branch} lane={lane} starts at {stage}")
        if stage in ("adopt", "hand-back", "receipt") and not self.work.exists():
            raise DeliverError(
                f"worktree {self.work} is gone before the lane was published; recreate it"
            )

        if stage in ("adopt", "hand-back", "receipt"):
            self.rebase_if_behind()
        stale_claim: tuple[int, str] | None = None  # (generation, head) to retire
        if (
            stage in ("hand-back", "receipt")
            and record is not None
            and self.claim_base_is_stale(record)
        ):
            self.say(
                f"claim base {record.get('base_sha')} is not the fork point "
                f"{self.claim_base()}; re-adopting"
            )
            head = str(
                record.get("handed_back_sha")
                or self.git("rev-parse", "HEAD", stage="preflight")
            )
            stale_claim = (int(record.get("claim_generation") or 0), head)
            record, stage = None, "adopt"
        if stage in ("adopt", "hand-back"):
            if not self.args.check:
                raise DeliverError(
                    "pass at least one --check: an outcome has to come from a command that ran"
                )
            self.format_changed_python()
            outcomes = run_checks(
                self.args.check,
                self.work,
                self.runner,
                log_dir=canon / ".cache" / "deliver-checks",
                tag=branch,
            )
            failed = [o for o in outcomes if o["status"] != "passed"]
            for o in outcomes:
                self.say(f"check {o['status']}: {o['check']}")
            if failed:
                raise DeliverError(
                    "check(s) failed: " + ", ".join(o["check"] for o in failed),
                    {"checks": outcomes},
                )
            # Local log paths stay out of the sealed outcomes (they reach the PR body).
            outcomes = [{k: v for k, v in o.items() if k != "log"} for o in outcomes]
            self.before_claim()
            with tempfile.TemporaryDirectory() as tmp:
                scope = scope_from_name_status(
                    self.git(
                        "-c",
                        "core.quotepath=false",
                        "diff",
                        "--name-status",
                        "-z",
                        f"{TRUNK}...HEAD",
                    )
                )
                scope_file, outcome_file = (
                    Path(tmp, "scope.json"),
                    Path(tmp, "outcomes.json"),
                )
                scope_file.write_text(json.dumps(scope))
                outcome_file.write_text(json.dumps(outcomes))
                orchestrate = str(OPS / "worktree_orchestrate.py")
                if (
                    stage == "hand-back"
                    and self.args.scope_from_diff
                    and _scope_key(record and record.get("scope")) != _scope_key(scope)
                ):
                    # The lane grew past the Scope it was adopted with.
                    self.mutate(
                        [
                            str(OPS / "worktree_registry.py"),
                            "scope-set",
                            "--branch",
                            branch,
                            "--path",
                            str(self.work),
                            "--scope-file",
                            str(scope_file),
                        ],
                        self.work,
                        "scope-set",
                    )
                    self.say("scope refreshed from the diff")
                if stage == "adopt":
                    intent = self.args.intent or self.git("log", "-1", "--format=%s")
                    self.mutate(
                        [
                            orchestrate,
                            "readopt" if stale_claim else "adopt",
                            "--worktree",
                            str(self.work),
                            "--base",
                            self.claim_base(),
                            "--intent",
                            intent,
                            "--external-id",
                            lane,
                            "--scope-file",
                            str(scope_file),
                            "--codex-thread-id",
                            self.args.thread_id,
                            "--delegated",
                            *(
                                [
                                    "--expected-generation",
                                    str(stale_claim[0]),
                                    "--expected-head-sha",
                                    stale_claim[1],
                                ]
                                if stale_claim
                                else []
                            ),
                            "--json",
                        ],
                        self.work,
                        "adopt",
                    )
                    self.say("adopted")
                self.mutate(
                    [
                        orchestrate,
                        "hand-back",
                        "--branch",
                        branch,
                        "--path",
                        str(self.work),
                        "--outcomes",
                        str(outcome_file),
                        "--json",
                    ],
                    self.home,
                    "hand-back",
                )
                self.say("handed back")
            stage = "receipt"
        elif stage == "receipt":
            self.before_claim()
        if stage == "receipt":
            self.mutate(
                [*delivery, "receipt", "--lane", lane],
                self.home,
                "receipt",
            )
            title = self.args.title or self.git("log", "-1", "--format=%s")
            self.mutate(
                [
                    *delivery,
                    "publish",
                    "--lane",
                    lane,
                    "--title",
                    title,
                    *[
                        item
                        for flag, numbers in (
                            ("--closes", self.args.closes),
                            ("--refs", self.args.refs),
                        )
                        for number in numbers
                        for item in (flag, str(number))
                    ],
                    *(
                        ["--replaces-pr", str(self.replaces_pr)]
                        if self.replaces_pr is not None
                        else []
                    ),
                ],
                self.home,
                "publish",
            )
            pr = self.pull_request(repo, branch)
            if pr is None:
                raise DeliverError(
                    "publish reported success but no PR exists for the branch"
                )
            self.say(f"published PR #{pr['number']}")
            stage = "wait-required"
        if pr is None:
            raise DeliverError("no PR to wait on")
        number = int(pr["number"])
        self.after_publish(pr)
        if stage == "release-published":
            self.mutate(
                [*delivery, "release-published", "--pr", str(number)],
                self.home,
                "release-published",
            )
            self.say(f"released the local lane of published #{number}")
            stage = "wait-required"
        if stage == "wait-required":
            self.wait_for("required check", lambda: self._required(repo, number))
            self.say(f"required passed on #{number}")
            if not self.args.merge:
                return self.summary(branch, lane, number, "ready-to-merge")
            self.extra["review"] = self.review_gate(repo, number)
            self.area_quality_gate(repo, number)
            self.mutate(
                [*delivery, "queue", "--pr", str(number)],
                self.home,
                "queue",
            )
            self.queued = True
            self.say(f"queued #{number}")
            self.wait_for("merge", lambda: self._merged(repo, number))
            stage = "cleanup"
        if stage == "cleanup":
            # The worktree may be the very directory being retired; run from the canonical checkout.
            self.mutate(
                [*delivery, "cleanup-merged", "--pr", str(number)],
                canon,
                "cleanup-merged",
            )
            self.mutate([*delivery, "sync-main"], canon, "sync-main")
            self.say(f"merged #{number}; lane cleaned and main synced")
            self.verify_issues_closed(repo, number)
        return self.summary(branch, lane, number, "merged")

    def verify_issues_closed(self, repo: str, number: int) -> None:
        """Every ``Closes`` issue of the merged PR must be closed now (#2654).

        The lane is already cleaned, so this only reports: a still-open issue
        means the PR never linked it (or GitHub did not process the keyword).
        """
        body = must(
            self.runner,
            [
                "gh",
                "pr",
                "view",
                str(number),
                "--repo",
                repo,
                "--json",
                "body",
                "-q",
                ".body",
            ],
            self.home,
            "read PR body",
        ).stdout
        for issue in salvage_body_issues(body).closes:
            for attempt in range(ISSUE_CLOSE_POLLS):
                state = must(
                    self.runner,
                    [
                        "gh",
                        "issue",
                        "view",
                        str(issue),
                        "--repo",
                        repo,
                        "--json",
                        "state",
                        "-q",
                        ".state",
                    ],
                    self.home,
                    "read issue state",
                ).stdout.strip()
                if state == "CLOSED":
                    self.say(f"issue #{issue} closed by #{number}")
                    break
                if attempt + 1 < ISSUE_CLOSE_POLLS:
                    self.sleep(ISSUE_CLOSE_POLL_SECONDS)
            else:
                raise DeliverError(
                    f"#{number} merged with Closes #{issue} but issue #{issue} is "
                    "still open; close it with a link to the merged PR "
                    "(owner preference: close each issue when its fix merges)"
                )

    def _pr_checks(self, repo: str, number: int) -> list[dict[str, Any]]:
        out = must(
            self.runner,
            ["gh", "pr", "checks", str(number), "--repo", repo]
            + ["--json", "name,state,startedAt,link"],
            self.home,
            "read checks",
        ).stdout
        return json.loads(out or "[]")

    def area_quality_gate(self, repo: str, number: int) -> None:
        """Hold the queue on the exact head's area quality jobs (#2833, #2870).

        The newest run per full check name decides, then runs aggregate by area.
        Any failed or cancelled job refuses before `queue`, since merge_group
        re-runs the same suite and would only eject the PR later; otherwise any
        pending job is waited for.  A timeout while still pending raises from
        wait_for: a HOLD, never a pass.  SKIPPED counts as passed.
        """

        def settled() -> list[str] | None:
            newest = newest_by_name(self._pr_checks(repo, number))
            states = {
                name: check_state(check)
                for name, check in newest.items()
                if area_of(name) is not None
            }
            failed = sorted(name for name, s in states.items() if s == "failed")
            if failed:
                return failed
            if "pending" in states.values():
                return None
            return []

        failed = self.wait_for(f"area quality checks on #{number}", settled)
        if failed:
            raise DeliverError(
                f"refusing to queue #{number}: area quality check(s) failed on its "
                f"head: {', '.join(failed)}; fix and redeliver"
            )

    def _queue_entry(self, repo: str, number: int) -> dict[str, Any] | None:
        """The PR's merge queue entry, or None; remembers its merge group commit."""
        owner, _, name = repo.partition("/")
        out = must(
            self.runner,
            ["gh", "api", "graphql", "-f", f"query={QUEUE_ENTRY_QUERY}"]
            + ["-f", f"owner={owner}", "-f", f"name={name}"]
            + ["-F", f"number={number}"],
            self.home,
            "read the merge queue entry",
        ).stdout
        entry = json.loads(out)["data"]["repository"]["pullRequest"]["mergeQueueEntry"]
        head = ((entry or {}).get("headCommit") or {}).get("oid")
        if head:
            self.queue_head = head
        return entry

    def _ejected(self, repo: str, number: int) -> DeliverError:
        # merge_group runs on the queue commit, not the PR head: read the last
        # group this PR sat in, falling back to the head when none was seen.
        if self.queue_head:
            runs = self.gh_pages(
                f"repos/{repo}/commits/{self.queue_head}/check-runs?filter=latest",
                "check_runs",
            )
            checks, link = list(newest_by_name(runs).values()), "html_url"
        else:
            checks, link = self._pr_checks(repo, number), "link"
        failing = [
            f"{c.get('name')} ({c.get(link) or 'no link'})"
            for c in checks
            if str(c.get("conclusion") or c.get("state") or "").upper()
            in FAILURE_STATES
        ]
        detail = "; ".join(failing) or "no failing check reported"
        return DeliverError(
            f"#{number} was dequeued from the merge queue without merging; "
            f"failing check: {detail}"
        )

    def _required(self, repo: str, number: int) -> str | None:
        out = must(
            self.runner,
            ["gh", "pr", "checks", str(number), "--repo", repo, "--json", "name,state"],
            self.home,
            "read checks",
        ).stdout
        state = required_state(json.loads(out or "[]"))
        if state in SUCCESS_STATES:
            return state
        if state in FAILURE_STATES:
            raise DeliverError(f"required check is {state} on #{number}; see the PR")
        return None

    def _pr_state(self, repo: str, number: int) -> str:
        return must(
            self.runner,
            [
                "gh",
                "pr",
                "view",
                str(number),
                "--repo",
                repo,
                "--json",
                "state",
                "-q",
                ".state",
            ],
            self.home,
            "read PR state",
        ).stdout.strip()

    def _merged(self, repo: str, number: int) -> str | None:
        out = self._pr_state(repo, number)
        if out == "MERGED":
            return out
        if out == "CLOSED":
            raise DeliverError(f"#{number} was closed without merging")
        # Open after our own queue call with no entry left: ejected, not slow.
        if self.queued and out == "OPEN" and self._queue_entry(repo, number) is None:
            # The merge group may have landed between the two reads: re-read.
            if self._pr_state(repo, number) == "MERGED":
                return "MERGED"
            raise self._ejected(repo, number)
        return None

    def gh_pages(self, endpoint: str, key: str | None = None) -> list[dict[str, Any]]:
        """Every item of a paginated REST list (``key``: the list inside a page)."""
        out = must(
            self.runner,
            ["gh", "api", "--paginate", "--slurp", endpoint],
            self.home,
            f"read {endpoint}",
        ).stdout
        return [
            item
            for page in json.loads(out or "[]")
            for item in (page.get(key, []) if key else page)
        ]

    def runs_of_pr(
        self,
        repo: str,
        number: int,
        head_ref: str,
        runs: list[dict[str, Any]],
        owners: dict[int, bool],
    ) -> list[dict[str, Any]]:
        """The `agent-review` check runs triggered by PR ``number``.

        Fail closed: a run whose workflow run cannot be read, or that names no
        PR of this one, is dropped.  ``owners`` caches decided runs only, so a
        failed read is retried on the next poll.
        """
        mine = []
        for run in runs:
            run_id = review_run_id(run) if run.get("name") == REVIEW_CHECK else None
            if run_id is None:
                continue
            if run_id not in owners:
                done = self.runner(
                    ["gh", "api", f"repos/{repo}/actions/runs/{run_id}"], self.home
                )
                try:
                    doc = json.loads(done.stdout) if done.returncode == 0 else None
                except ValueError:
                    doc = None
                if not isinstance(doc, dict):
                    continue
                owners[run_id] = workflow_run_is_of(doc, number, head_ref)
            if owners[run_id]:
                mine.append(run)
        return mine

    def bot_out_of_quota(
        self, repo: str, number: int, head: str, bots: tuple[str, ...]
    ) -> bool:
        """Positive evidence the review bot refused for quota after this head existed."""
        since = must(
            self.runner,
            [
                "gh",
                "api",
                f"repos/{repo}/commits/{head}",
                "--jq",
                ".commit.committer.date",
            ],
            self.home,
            "read head commit date",
        ).stdout.strip()
        return any(
            quota_reply(
                self.gh_pages(f"repos/{repo}/{kind}/{number}/{leaf}?per_page=100"),
                since,
                bots,
            )
            for kind, leaf in (("issues", "comments"), ("pulls", "reviews"))
        )

    def review_gate(self, repo: str, number: int) -> dict[str, Any]:
        """Settle `agent-review` on the PR's exact head before it may be queued."""
        view = json.loads(
            must(
                self.runner,
                ["gh", "pr", "view", str(number), "--repo", repo]
                + ["--json", "headRefOid,headRefName"],
                self.home,
                "read PR head",
            ).stdout
        )
        head, head_ref = str(view["headRefOid"]), str(view["headRefName"])
        try:
            bots = review_bots(AGENT_REVIEW.read_text())
        except OSError as exc:
            raise DeliverError(f"cannot read {AGENT_REVIEW}: {exc}") from exc
        runs = f"repos/{repo}/commits/{head}/check-runs?check_name={REVIEW_CHECK}"
        seen: list[str | None] = [None]
        owners: dict[int, bool] = {}
        foreign = [0]

        def settled() -> str | None:
            # `neutral` only says the workflow stopped waiting (20 x 15s) for
            # the bot; the bot often reviews later and a new run posts the
            # real verdict, so only success/failure ends the wait, unless the
            # operator already accepts no review or the run says the bot is down.
            listed = self.gh_pages(f"{runs}&filter=all&per_page=100", "check_runs")
            mine = self.runs_of_pr(repo, number, head_ref, listed, owners)
            foreign[0] = sum(r.get("name") == REVIEW_CHECK for r in listed) - len(mine)
            seen[0] = review_verdict(mine)
            if seen[0] == "neutral" and (
                no_review
                or bot_down(mine)
                or self.bot_out_of_quota(repo, number, head, bots)
            ):
                return "neutral"  # settled for good: do not wait out --timeout
            return seen[0] if seen[0] in ("success", "failure") else None

        no_review = (self.args.accept_no_review or "").strip()
        try:
            verdict = self.wait_for(f"{REVIEW_CHECK} on {head}", settled)
        except DeliverError as exc:
            if seen[0] is None and foreign[0]:
                raise DeliverError(
                    f"refusing to queue #{number}: {foreign[0]} {REVIEW_CHECK} "
                    f"run(s) on {head} belong to other PRs or could not be "
                    f"attributed to #{number} (a PR sharing this head), and none "
                    f"of #{number}'s own settled within {self.args.timeout}s"
                ) from exc
            if seen[0] != "neutral":
                raise
            if not no_review:
                raise DeliverError(
                    f"refusing to queue #{number}: {REVIEW_CHECK} on {head} never "
                    f"settled to success/failure within {self.args.timeout}s; "
                    f"'neutral' only means the workflow stopped waiting for "
                    f"{bots[0]}, not that it reviewed the head\nwait and re-run, "
                    "or pass --accept-no-review '<reason>'"
                ) from exc
            verdict = "neutral"
        if verdict == "neutral":
            if not no_review:
                raise DeliverError(
                    f"refusing to queue #{number}: {REVIEW_CHECK} neutral: review "
                    f"bot unavailable ({bots[0]} did not review {head}); have CR "
                    "review the exact head and re-run with "
                    "--accept-no-review '<CR verdict>'"
                )
            if not cr_verdict_recorded(
                self.gh_pages(f"repos/{repo}/issues/{number}/comments?per_page=100")
                + self.gh_pages(f"repos/{repo}/pulls/{number}/reviews?per_page=100"),
                head,
                bots,
            ):
                raise DeliverError(
                    f"refusing to queue #{number}: --accept-no-review needs a "
                    f"recorded CR verdict on the PR, and none names {head}; have "
                    "CR review the exact head, then a maintainer comments "
                    f"'CR verdict: APPROVE {head}' on the PR "
                    "(docs/sop/review_discipline.md) and re-run"
                )
            self.say(f"accepted #{number} without an exact-head review ({no_review})")
        findings = review_findings(
            self.gh_pages(f"repos/{repo}/pulls/{number}/comments?per_page=100"),
            head,
            bots,
        )
        self.say(f"{REVIEW_CHECK} {verdict} on #{number} at {head}")
        problems = [f"{REVIEW_CHECK} failed on {head}"] if verdict == "failure" else []
        if findings:
            listed = "".join(
                f"\n  {f['where']}: {f['summary']} {f['url']}" for f in findings
            )
            problems.append(
                f"{len(findings)} inline review comment(s) on {head}:{listed}"
            )
        reason = (self.args.accept_review_findings or "").strip()
        if problems and not reason:
            raise DeliverError(
                f"refusing to queue #{number}: "
                + "; ".join(problems)
                + "\nfix and redeliver, or pass --accept-review-findings '<reason>'"
            )
        if problems:
            self.say(f"accepted for #{number} ({reason}): " + "; ".join(problems))
        return {
            "head": head,
            "verdict": verdict,
            "findings": findings,
            "accepted": reason if problems else None,
            "accepted_no_review": no_review if verdict == "neutral" else None,
        }

    def summary(
        self, branch: str, lane: str, number: int, result: str
    ) -> dict[str, Any]:
        return {
            "schema": SCHEMA,
            "branch": branch,
            "lane": lane,
            "pr": number,
            "result": result,
            "log": self.log,
            **self.extra,
        }


# --- redeliver --------------------------------------------------------------


class Replacement:
    """Replace a published PR with a new lane built from a fixed worktree.

    Pushing review fixes onto a published PR makes its head differ from the
    sealed hand-back, which ``delivery.py queue`` refuses.  The fixes go on a
    new branch and are delivered as a new lane instead.  The published lane
    still owns its Scope, so it is abandoned before the new lane claims, with
    the generation and head read from the registry; once the new PR exists the
    old one is closed with a link to it, and its remote branch is deleted only
    while it is still the published head.  Every step re-reads its facts, so a
    rerun resumes where the last one stopped.  (``delivery.py abandon-pr`` does
    not fit: it refuses a PR whose head moved, and closes before the
    replacement exists.  Its other refusals are kept: see ``guard``.)
    """

    def __init__(self, delivery: Delivery, old_branch: str) -> None:
        self.d = delivery
        self.old = old_branch
        self.new_branch = ""
        self.old_number = 0

    def guard(self, repo: str) -> dict[str, Any]:
        """Refuse to retire an old PR that is held or already scheduled to merge.

        A hard hold lives on the PR (label or typed body block) and is cleared
        only by ``delivery.py reconcile-holds``; closing the PR would drop it.
        A PR with auto-merge or a merge-queue entry may merge under us.  Read
        fresh before each step that retires something, as ``abandon-pr`` does.
        """
        owner, _, name = repo.partition("/")
        out = must(
            self.d.runner,
            ["gh", "api", "graphql", "-f", f"query={PR_GUARD_QUERY}"]
            + ["-f", f"owner={owner}", "-f", f"name={name}"]
            + ["-F", f"number={self.old_number}"],
            self.d.home,
            "read the replaced PR",
        ).stdout
        node = json.loads(out)["data"]["repository"]["pullRequest"]
        labels = tuple(str(n.get("name")) for n in node["labels"]["nodes"])
        try:
            holds = parse_body_holds(str(node.get("body") or ""))
            holds |= pull_request_label_holds(SimpleNamespace(labels=labels))
        except PolicyViolation as exc:
            raise DeliverError(f"PR #{self.old_number}: {exc}") from exc
        if holds and node.get("state") == "OPEN":
            raise DeliverError(
                f"PR #{self.old_number} carries a hard hold "
                f"({', '.join(sorted(h.value for h in holds))}); replacing it would "
                "drop the hold: clear it with `delivery.py reconcile-holds` first"
            )
        if node.get("autoMergeRequest") or node.get("mergeQueueEntry"):
            raise DeliverError(
                f"PR #{self.old_number} is scheduled to merge (auto-merge or merge "
                "queue); dequeue it before replacing it"
            )
        if node.get("state") == "MERGED":
            raise DeliverError(f"PR #{self.old_number} merged; nothing to replace")
        return node

    def lane(self) -> dict[str, Any]:
        records = self.d.registry_records(self.old)
        if not records:
            raise DeliverError(f"no registry lane for {self.old}")
        record = records[-1]
        if record.get("status") not in ("published", "abandoned"):
            raise DeliverError(
                f"lane {self.old} is {record.get('status')!r}; "
                "redeliver replaces a published lane"
            )
        return record

    def run(self) -> dict[str, Any]:
        d = self.d
        if d.work.exists():
            self.new_branch = d.git("rev-parse", "--abbrev-ref", "HEAD")
        elif d.args.branch:
            self.new_branch = d.args.branch
        else:
            raise DeliverError(
                f"worktree {d.work} is gone; pass --new-branch to resume the replacement"
            )
        if self.new_branch == self.old:
            raise DeliverError(
                f"{self.old} is the published lane being replaced; commit the fix "
                "on a new branch (git switch -c <name>) and redeliver from there"
            )
        repo = d.gh_repo()
        record = self.lane()
        if d.args.lane and d.args.lane in (record.get("external_ids") or []):
            raise DeliverError(f"--lane {d.args.lane} is the replaced lane's id")
        pr = d.pull_request(repo, self.old)
        if pr is None:
            raise DeliverError(f"no PR for {self.old}; nothing to replace")
        if pr.get("state") == "MERGED":
            raise DeliverError(
                f"PR #{pr['number']} is already merged; nothing to replace"
            )
        self.old_number = int(pr["number"])
        self.guard(repo)
        self.check_lineage(record)  # before any hook can retire or close anything
        d.replaces_pr = self.old_number
        d.before_claim = lambda: self.retire(repo)
        d.after_publish = lambda new: self.supersede(repo, new)
        return d.deliver()

    def new_tip(self) -> str:
        """The commit being delivered: the worktree's HEAD, else the pushed branch."""
        d = self.d
        revs = (
            ["HEAD"]
            if d.work.exists()
            else [self.new_branch, f"origin/{self.new_branch}"]
        )
        for rev in revs:
            done = d.runner(
                ["git", "rev-parse", "--verify", f"{rev}^{{commit}}"], d.home
            )
            if done.returncode == 0 and done.stdout.strip():
                return done.stdout.strip()
        raise DeliverError(f"cannot resolve the new lane's tip ({', '.join(revs)})")

    def check_lineage(self, record: dict[str, Any]) -> None:
        """Refuse a new tip that is not the replaced lane's work plus its fixes.

        Redeliver abandons the old lane, closes its PR and may delete its
        branch, so it must not do that for an unrelated branch.  The tip has to
        contain the lane's recorded hand-back commit, or carry a patch-equivalent
        of every commit it added (a rebase), as ``git cherry`` judges.
        """
        d = self.d
        old = str(record.get("handed_back_sha") or "")
        if not SHA.fullmatch(old):
            raise DeliverError(
                f"lane {self.old} records no hand-back commit ({old!r}) to compare "
                f"{self.new_branch} against; redeliver cannot tell it replaces that lane"
            )
        if d.runner(["git", "cat-file", "-e", f"{old}^{{commit}}"], d.home).returncode:
            raise DeliverError(
                f"the replaced lane's hand-back {old} is not in this repository; "
                "fetch it, then redeliver"
            )
        tip = self.new_tip()
        contained = d.runner(["git", "merge-base", "--is-ancestor", old, tip], d.home)
        if contained.returncode == 0:
            return
        if contained.returncode != 1:
            raise DeliverError(
                f"compare with the replaced lane failed (rc={contained.returncode}): "
                f"{failure_detail(contained) or 'no output'}"
            )
        cherry = must(d.runner, ["git", "cherry", tip, old], d.home, "compare commits")
        lost = [
            line[1:].strip()[:12]
            for line in cherry.stdout.splitlines()
            if line.startswith("+")
        ]
        if lost:
            raise DeliverError(
                f"{self.new_branch} ({tip}) does not carry the replaced lane's "
                f"hand-back {old}: not an ancestor, and no patch-equivalent commit "
                f"for {', '.join(lost)}. Redeliver only a branch built on the "
                "published lane (its commits kept or rebased unchanged, fixes added)"
            )

    def retire(self, repo: str) -> dict[str, Any]:
        """Abandon the replaced lane with the registry's own CAS facts."""
        record = self.lane()
        if record.get("status") == "abandoned":
            return record
        self.guard(repo)  # the checks ran meanwhile; the PR may have moved on
        generation = record.get("claim_generation", 0)
        head = str(record.get("handed_back_sha") or "")
        if type(generation) is not int or generation < 0 or not SHA.fullmatch(head):
            raise DeliverError(
                f"lane {self.old} has no exact claim_generation/handed_back_sha "
                f"to abandon it with ({generation!r}, {head!r})"
            )
        path = str(record["path"]) if record.get("path") else None
        # A busy lock makes abandon wait; the PR may be queued or held meanwhile,
        # so it is read again before every retry, not only before the first try.
        self.d.abandon(
            self.old,
            path,
            generation,
            head,
            "abandon the replaced lane",
            lambda: self.guard(repo),
        )
        self.d.say(f"abandoned lane {self.old} (generation {generation}, head {head})")
        return record

    def supersede(self, repo: str, new: dict[str, Any]) -> None:
        """Close the replaced PR with a link to ``new``; drop its published branch."""
        record = self.retire(repo)  # a resumed run can start past the claim
        old = self.d.pull_request(repo, self.old)
        if old is not None and old.get("state") == "MERGED":
            # guard() only reads an OPEN PR; a merge during the redelivery
            # must stop here, before anything is closed or deleted.
            raise DeliverError(
                f"PR #{old['number']} merged while #{new['number']} was replacing "
                f"it; the old remote branch {self.old} was not deleted and "
                f"#{new['number']} is published: close it if the merged PR "
                "already carries the change"
            )
        if old is not None and old.get("state") == "OPEN":
            self.guard(repo)
            note = (
                f"Superseded by #{new['number']} ({new.get('url')}): the review "
                f"fixes were redelivered from `{self.new_branch}`; this PR's lane "
                "was abandoned by `ops/deliver.py redeliver`."
            )
            must(
                self.d.runner,
                ["gh", "pr", "close", str(old["number"]), "--repo", repo]
                + ["--comment", note],
                self.d.home,
                "close the replaced PR",
            )
            self.d.say(f"closed #{old['number']}, superseded by #{new['number']}")
        head = str(record.get("handed_back_sha") or "")
        self.d.extra["replaced"] = {
            "branch": self.old,
            "pr": old["number"] if old else None,
            "claim_generation": record.get("claim_generation", 0),
            "published_head": head,
            "remote_branch": self.drop_remote_branch(head),
        }

    def drop_remote_branch(self, head: str) -> str:
        """Delete the replaced branch on origin only while it is the published head."""
        out = self.d.git("ls-remote", "origin", f"refs/heads/{self.old}")
        remote = out.split()[0] if out else None
        if remote is None:
            return "absent"
        if remote != head or not SHA.fullmatch(head):
            kept = f"kept: at {remote}, not the published head {head}"
            self.d.say(f"remote {self.old} {kept}")
            return kept
        self.delete_remote_branch(head)
        self.d.say(f"deleted remote {self.old} at {head}")
        return "deleted"

    def delete_remote_branch(self, head: str) -> None:
        """The lease makes the delete a compare-and-swap on the remote ref."""
        self.d.git(
            "push",
            f"--force-with-lease=refs/heads/{self.old}:{head}",
            "origin",
            "--delete",
            self.old,
            stage="delete the replaced remote branch",
        )


def redeliver(
    args: argparse.Namespace,
    runner: Runner,
    sleep: Callable[[float], None],
    clock: Callable[[], float],
) -> dict[str, Any]:
    lane_args = argparse.Namespace(**{**vars(args), "branch": args.new_branch})
    return Replacement(Delivery(lane_args, runner, sleep, clock), args.old_branch).run()


# --- gc ---------------------------------------------------------------------


# A lane that still owns its Scope; merged/abandoned records are history.
GC_STATUSES = frozenset({"active", "published", "cleanup_pending"})


def _merged_pulls(
    runner: Runner, repo: str, canon: Path
) -> dict[str, list[tuple[int, str]]]:
    """Head branch -> [(PR number, head sha)] of merged PRs, in one REST read.

    One paginated core-quota call replaces a GraphQL ``gh pr list`` per record
    (#2419), which exhausted the shared GraphQL quota on a large registry.
    """
    out = must(
        runner,
        ["gh", "api", "--paginate", "--slurp"]
        + [f"repos/{repo}/pulls?state=closed&per_page=100"],
        canon,
        "list closed PRs",
    ).stdout
    merged: dict[str, list[tuple[int, str]]] = {}
    for page in json.loads(out or "[]"):
        for pr in page:
            head = pr.get("head") or {}
            if pr.get("merged_at") and head.get("ref"):
                merged.setdefault(str(head["ref"]), []).append(
                    (int(pr["number"]), str(head.get("sha") or ""))
                )
    return merged


def _worktree_head(runner: Runner, rec: dict[str, Any]) -> str:
    path = Path(str(rec.get("path", "")))
    if not path.is_dir():
        return ""
    found = runner(["git", "rev-parse", "HEAD"], path)
    return found.stdout.strip() if found.returncode == 0 else ""


def gc(
    args: argparse.Namespace, runner: Runner, lock: LockWait | None = None
) -> dict[str, Any]:
    canon = Path(
        must(
            runner, ["git", "rev-parse", "--show-toplevel"], None, "locate repo"
        ).stdout.strip()
    )
    repo = must(
        runner,
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        canon,
        "resolve repository",
    ).stdout.strip()
    data = json.loads(
        must(
            runner,
            [str(OPS / "worktree_registry.py"), "list", "--json"],
            canon,
            "read registry",
        ).stdout
    )
    records = data["records"] if isinstance(data, dict) else data
    merged = _merged_pulls(runner, repo, canon)
    retired, kept, seen = [], [], set()
    for rec in records:
        if rec.get("status") not in GC_STATUSES:
            continue
        branch = str(rec["branch"])
        candidates = merged.get(branch, [])
        if not candidates:
            if rec.get("status") == "published":
                kept.append({"branch": branch, "why": "published, PR not merged"})
            continue
        lane_head = str(rec.get("handed_back_sha") or "") or _worktree_head(runner, rec)
        found = next(
            (
                number
                for number, pr_head in candidates
                if lane_head
                and (
                    lane_head == pr_head
                    or runner(
                        ["git", "merge-base", "--is-ancestor", lane_head, pr_head],
                        canon,
                    ).returncode
                    == 0
                )
            ),
            None,
        )
        if found is None:
            kept.append(
                {"branch": branch, "why": "merged PR does not contain the lane HEAD"}
            )
            continue
        if args.dry_run:
            retired.append({"branch": branch, "pr": found, "applied": False})
            continue
        if found not in seen:  # two records for one PR: one cleanup
            seen.add(found)
            must(
                runner,
                [
                    str(canon / "ops" / "delivery.py"),
                    "--repo",
                    str(canon),
                    "cleanup-merged",
                    "--pr",
                    str(found),
                ],
                canon,
                "cleanup-merged",
                lock,
            )
        retired.append({"branch": branch, "pr": found, "applied": True})
    return {"schema": SCHEMA, "retired": retired, "kept": kept}


# --- cli --------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    options = argparse.ArgumentParser(add_help=False)
    options.add_argument("--worktree", default=".", help="lane worktree (default: cwd)")
    options.add_argument(
        "--check",
        action="append",
        default=[],
        metavar="LABEL=CMD",
        help="verification to run and record; repeatable",
    )
    options.add_argument(
        "--scope-from-diff",
        action="store_true",
        help=(
            "derive Scope (add/modify/delete) from the worktree's diff against "
            f"{TRUNK}; a new lane always does, this also refreshes the Scope of "
            "an already-adopted lane (e.g. an agent worktree) before hand-back"
        ),
    )
    options.add_argument("--lane", help="external id; derived from the branch when new")
    options.add_argument("--title", help="PR title; default is the last commit subject")
    for flag, meaning in (("--closes", "fully resolves"), ("--refs", "only advances")):
        options.add_argument(
            flag,
            type=int,
            action="append",
            default=[],
            metavar="N",
            help=f"issue this PR {meaning} (repeatable); default: lane external ids",
        )
    options.add_argument(
        "--intent", help="lane intent; default is the last commit subject"
    )
    options.add_argument(
        "--thread-id",
        default="deliver-cli",
        help="owner thread id recorded on the claim",
    )
    options.add_argument(
        "--merge",
        action="store_true",
        help=(
            f"wait for {REVIEW_CHECK} on the exact head, then queue, wait for "
            "the merge, clean up and sync"
        ),
    )
    options.add_argument(
        "--accept-review-findings",
        metavar="REASON",
        help=(
            f"with --merge: queue although {REVIEW_CHECK} failed or the review "
            "bot left inline comments on the head; the reason is logged"
        ),
    )
    options.add_argument(
        "--accept-no-review",
        metavar="REASON",
        help=(
            f"with --merge: queue although {REVIEW_CHECK} only reached neutral "
            "(the bot never reviewed the head) by --timeout; needs a maintainer "
            "comment 'CR verdict: APPROVE <head sha>' on the PR; the reason is logged"
        ),
    )
    options.add_argument(
        "--timeout", type=int, default=1500, help="seconds per wait (default 1500)"
    )
    options.add_argument(
        "--poll", type=int, default=30, help="seconds between polls (default 30)"
    )
    options.add_argument(
        "--lock-timeout",
        type=int,
        default=600,
        help=(
            "seconds a mutation keeps retrying while another delivery mutation "
            "holds the operation lock (default 600)"
        ),
    )
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        parents=[options],
    )
    parser.add_argument(
        "--branch", help="resume a published lane whose worktree is already gone"
    )
    sub = parser.add_subparsers(dest="command")
    clean = sub.add_parser("gc", help="retire lanes whose PR already merged")
    clean.add_argument("--dry-run", action="store_true")
    again = sub.add_parser(
        "redeliver",
        parents=[options],
        help="replace a published PR with a new lane from a fixed worktree",
        description="Delivery options go after `redeliver`.",
    )
    again.add_argument(
        "--branch",
        dest="old_branch",
        required=True,
        help="branch of the published lane whose PR is replaced",
    )
    again.add_argument(
        "--new-branch", help="resume a replacement whose worktree is already gone"
    )
    return parser


def main(
    argv: list[str] | None = None,
    runner: Runner = run,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "redeliver":
        # The subcommand re-declares every delivery option and its defaults
        # overwrite anything given before it; refuse instead of dropping it.
        raw = list(sys.argv[1:] if argv is None else argv)
        flags = {s for a in parser._actions for s in a.option_strings} - {
            "-h",
            "--help",
        }
        early = [t.split("=", 1)[0] for t in raw[: raw.index("redeliver")]]
        early = list(dict.fromkeys(t for t in early if t in flags))
        if early:
            parser.error(
                f"{', '.join(early)} must go after `redeliver`; "
                "options before it would be ignored"
            )
    try:
        if args.command == "gc":
            lock = LockWait(args.lock_timeout, sleep, clock, progress)
            result = gc(args, runner, lock)
        elif args.command == "redeliver":
            result = redeliver(args, runner, sleep, clock)
        else:
            result = Delivery(args, runner, sleep, clock).deliver()
    except DeliverError as exc:
        print(
            json.dumps(
                {"schema": SCHEMA, "ok": False, "error": str(exc), **exc.extra},
                ensure_ascii=False,
            ),
            file=sys.stdout,
        )
        print(f"deliver: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({**result, "ok": True}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
