#!/usr/bin/env -S uv run --python 3.13 python
"""Read-only project health: one report that answers "is the loop still closed?".

It aggregates what other tools already know and adds only the judgements none of
them make: a CI check that has stayed red on main (known-red), how far production
trails main, claims whose worktree is gone, whether production crash reporting
and Sentry release integration are actually wired, and whether open issues can
be verified by their own acceptance commands.

Nothing here writes to the repository, the registry or GitHub.  Issue acceptance
commands are *reported* by default; ``--run-acceptance`` executes them, and only
for issues authored by the repository owner or a member (issue text is data, anyone can file
one), one at a time, with a timeout.

Exit code: 0 all ok, 1 warnings, 2 at least one blocker.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

SCHEMA = "kg.doctor.v1"

# A check that stays red on main this long is normalised deviance, not noise.
KNOWN_RED_MIN_STREAK = 3
KNOWN_RED_MIN_DAYS = 3
# Production that trails main this far (or this old) accumulates unbounded risk.
RELEASE_GAP_WARN_COMMITS = 200
RELEASE_GAP_BLOCK_COMMITS = 1000
RELEASE_GAP_WARN_DAYS = 14
RELEASE_GAP_BLOCK_DAYS = 45
PROD_INFO_URL = "https://wordnexus.lol/api/system/info"
DISK_GUARD_FILE = (
    Path.home() / "Library" / "Application Support" / "KG" / "disk_guard.json"
)
FULL_SHA = re.compile(r"[0-9a-f]{40}")
SENTRY_ENV_FILE_HINT = "~/.secrets/sentry.env"
SENTRY_DSN_FIX = (
    "fix: add SENTRY_DSN=<backend project DSN> to felix ~/kg-prod/backend/.env, then on felix "
    "`cd ~/kg-prod/backend && docker compose up -d --build --force-recreate` "
    "(docs/sop/deploy.md §Sentry)"
)
_REAL_CONCLUSIONS = {"success", "failure", "timed_out", "startup_failure"}
_LIVE_CLAIM_STATUSES = {"active", "published", "cleanup_pending"}
_ORDER = {"ok": 0, "warn": 1, "block": 2}


@dataclass(frozen=True)
class Finding:
    section: str
    level: str
    summary: str
    detail: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------
# Pure evaluators (everything below is unit-tested without any I/O)
# --------------------------------------------------------------------------


def evaluate_git(facts: dict[str, Any]) -> Finding:
    problems = []
    if facts.get("branch") != "main":
        problems.append(f"checkout is on {facts.get('branch')!r}, not main")
    if facts.get("dirty"):
        problems.append(f"{facts['dirty']} uncommitted path(s)")
    if facts.get("local") != facts.get("origin"):
        problems.append(
            "local main differs from origin/main (run delivery.py sync-main)"
        )
    if problems:
        return Finding("git", "warn", "canonical checkout needs attention", problems)
    return Finding("git", "ok", "canonical checkout is clean main == origin/main")


def evaluate_registry(records: list[dict[str, Any]]) -> Finding:
    live = [r for r in records if r.get("status") in _LIVE_CLAIM_STATUSES]
    detail = []
    for record in live:
        label = f"{record.get('branch')} [{record.get('status')}]"
        if not os.path.exists(str(record.get("path", ""))):
            detail.append(f"ghost claim (worktree path gone): {label}")
        if record.get("status") == "active" and not record.get("codex_thread_id"):
            detail.append(f"ownerless active claim: {label}")
    if detail:
        return Finding(
            "registry",
            "warn",
            f"{len(live)} live claim(s), {len(detail)} problem(s)",
            detail,
        )
    return Finding("registry", "ok", f"{len(live)} live claim(s), none stale")


def _parse_time(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def evaluate_ci(runs: list[dict[str, Any]], now: datetime) -> list[Finding]:
    """Judge each workflow by how long it has been failing on main."""

    by_workflow: dict[str, list[dict[str, Any]]] = {}
    for run in runs:
        if run.get("conclusion") in _REAL_CONCLUSIONS:
            by_workflow.setdefault(str(run.get("workflowName")), []).append(run)
    findings = []
    for name, items in sorted(by_workflow.items()):
        items.sort(key=lambda r: r["createdAt"], reverse=True)
        streak = []
        for run in items:
            if run["conclusion"] == "success":
                break
            streak.append(run)
        if len(streak) >= KNOWN_RED_MIN_STREAK:
            age = (now - _parse_time(streak[-1]["createdAt"])).total_seconds() / 86400
            if age >= KNOWN_RED_MIN_DAYS:
                findings.append(
                    Finding(
                        "ci",
                        "block",
                        f"{name} known-red: {len(streak)} consecutive failures on main over {age:.0f} days",
                        [
                            "fix it or demote it; a check nobody acts on trains everyone to ignore red",
                            f"newest failure: {streak[0]['createdAt']} {streak[0].get('url', '(no url)')}",
                            f"oldest in streak: {streak[-1]['createdAt']} {streak[-1].get('url', '(no url)')}",
                        ],
                    )
                )
                continue
        findings.append(
            Finding(
                "ci", "ok", f"{name} not known-red ({len(streak)} recent failure(s))"
            )
        )
    return findings or [
        Finding("ci", "warn", "no finished workflow runs found on main")
    ]


def evaluate_release_gap(
    sha: str | None, behind: int | None, age_days: float | None
) -> Finding:
    if not sha or behind is None or age_days is None:
        return Finding(
            "release",
            "warn",
            "production version unknown (cannot measure the gap to main)",
        )
    summary = f"production {sha[:9]} trails main by {behind} commit(s), {age_days:.0f} day(s) old"
    if behind >= RELEASE_GAP_BLOCK_COMMITS or age_days >= RELEASE_GAP_BLOCK_DAYS:
        return Finding(
            "release",
            "block",
            summary,
            ["unreleased risk grows with every merge; ship smaller, more often"],
        )
    if behind >= RELEASE_GAP_WARN_COMMITS or age_days >= RELEASE_GAP_WARN_DAYS:
        return Finding("release", "warn", summary)
    return Finding("release", "ok", summary)


def evaluate_sentry(
    prod: dict[str, Any] | None,
    local: dict[str, Any] | None,
    *,
    check_local: bool = True,
) -> Finding:
    """Is production crash reporting on, and can deploys/releases feed Sentry?

    ``prod`` is the /api/system/info payload (None when unreachable); ``local``
    is ``ops/sentry_release.sh check --json`` (key presence only, never values).
    """

    detail: list[str] = []
    version = prod.get("version") if prod else None
    if prod is None:
        detail.append(
            "production /api/system/info unreachable: Sentry state unknown (offline?)"
        )
    else:
        if prod.get("sentry") is not True:
            detail.append(
                f"production backend Sentry is off (sentry={json.dumps(prod.get('sentry'))}): "
                f"backend crashes are invisible. {SENTRY_DSN_FIX}"
            )
        if not (isinstance(version, str) and FULL_SHA.fullmatch(version)):
            detail.append(
                f"production reports version {version!r}, not a full sha: its Sentry release "
                "cannot match the recorded kg-backend@<full sha>. fix: the next deploy "
                "(reconciler or devops.sh deploy) writes the full sha to backend/VERSION"
            )
    if check_local:
        if local is None:
            detail.append(
                "could not run `ops/sentry_release.sh check --json`: release integration unverified"
            )
        else:
            keys = local.get("keys", {})

            def missing(*names: str) -> list[str]:
                return [name for name in names if not keys.get(name)]

            gap = missing("SENTRY_AUTH_TOKEN", "SENTRY_ORG", "SENTRY_PROJECT_BACKEND")
            if gap:
                detail.append(
                    f"backend deploys SKIP recording the Sentry release/deploy: {', '.join(gap)} "
                    f"missing. fix: add to {SENTRY_ENV_FILE_HINT} (token scope project:releases)"
                )
            gap = missing("SENTRY_AUTH_TOKEN", "SENTRY_ORG", "SENTRY_PROJECT_IOS")
            if gap:
                detail.append(
                    f"ios_release.sh --upload SKIPs the dSYM upload: {', '.join(gap)} missing. "
                    f"fix: add to {SENTRY_ENV_FILE_HINT} (token scope project:releases)"
                )
            if local.get("api_url") == "invalid":
                detail.append(
                    f"SENTRY_API_URL is not https (or loopback http). fix: correct it in {SENTRY_ENV_FILE_HINT}"
                )
            if local.get("uploader") == "missing":
                detail.append(
                    "uvx not on PATH: dSYM upload SKIPs (pinned sentry-cli runs via uvx). fix: install uv"
                )
    if detail:
        return Finding(
            "sentry", "warn", f"{len(detail)} Sentry release-integration gap(s)", detail
        )
    scope = (
        "deploy/dSYM recording configured"
        if check_local
        else "local config not checked"
    )
    return Finding(
        "sentry",
        "ok",
        f"production Sentry on, release kg-backend@{str(version)[:9]}…; {scope}",
    )


def evaluate_disk(guard: dict[str, Any] | None) -> Finding:
    if not guard:
        return Finding("disk", "ok", "no disk guard state on this machine")
    verdict = str(guard.get("verdict"))
    level = {
        "ok": "ok",
        "warning": "warn",
        "block": "block",
        "critical": "block",
    }.get(verdict, "warn")
    return Finding("disk", level, f"disk guard {verdict}: {guard.get('reason')}")


def evaluate_complexity(
    rows: list[dict[str, Any]] | None, ops_to_ios: float | None
) -> Finding:
    if rows is None:
        return Finding(
            "complexity",
            "warn",
            "complexity budget unreadable (ops/complexity_budget.json)",
        )
    over = [r for r in rows if r["over"]]
    ratio = f", ops:ios {ops_to_ios}" if ops_to_ios is not None else ""
    if over:
        return Finding(
            "complexity",
            "warn",
            f"{len(over)} area(s) over their line budget{ratio}",
            [
                f"{r['area']}: {r['lines']:,} lines > ceiling {r['ceiling']:,}"
                for r in over
            ],
        )
    tight = min(rows, key=lambda r: r["headroom"])
    return Finding(
        "complexity",
        "ok",
        f"within budget; tightest is {tight['area']} ({tight['headroom']:,} lines headroom){ratio}",
    )


def evaluate_delivery(data: dict[str, Any] | None, now: datetime) -> Finding:
    import delivery_metrics

    if data is None:
        return Finding(
            "delivery", "warn", "delivery metrics unavailable (gh/git read failed)"
        )
    summary = delivery_metrics.summarize(
        data["prs"], data["releases"], now, data["issues"]
    )
    level, problems = delivery_metrics.judge(summary)
    text = delivery_metrics.describe(summary)
    if data.get("truncated"):
        text += f" (WARNING: fetch hit the {delivery_metrics.FETCH_LIMIT}-item cap; counts are a lower bound)"
        level = "warn"
        problems = [
            *problems,
            "metrics truncated at the fetch cap; numbers are a lower bound",
        ]
    return Finding("delivery", level, text, problems)


REVIEW_QUOTA_PHRASE = "usage limits"
REVIEW_QUOTA_WINDOW_DAYS = 30
REVIEW_QUOTA_RECENT_DAYS = 3
REVIEW_QUOTA_NOTE = (
    "Codex review quota looks exhausted: agent-review settles neutral; use the "
    "recorded CR fallback in docs/sop/review_discipline.md"
)
REVIEW_FALLBACK_HEADING = "### Recorded CR fallback"


def evaluate_review_quota(
    data: dict[str, int] | None, *, fallback_documented: bool = False
) -> Finding:
    """How often the review bot answered "usage limits"; a documented CR fallback makes it informational."""
    if data is None:
        return Finding(
            "review", "warn", "review bot quota unavailable (gh read failed)"
        )
    text = (
        f"{data['month']} PR(s) got the review bot's usage-limit reply in "
        f"{REVIEW_QUOTA_WINDOW_DAYS}d, {data['recent']} in the last "
        f"{REVIEW_QUOTA_RECENT_DAYS}d"
    )
    if data["recent"]:
        level = "ok" if fallback_documented else "warn"
        return Finding("review", level, text, [REVIEW_QUOTA_NOTE])
    return Finding("review", "ok", text)


ACCEPTANCE_TRUSTED_ASSOCIATIONS = frozenset({"OWNER", "MEMBER"})


# Solver Packets and issue forms fence runnable commands under several headings
# (Acceptance, Done when, Verification commands, and the Chinese 驗收/驗證 forms).
ACCEPTANCE_HEADING = re.compile(
    r"^#{2,3}\s+(?:Acceptance\b|Done when\b|Verification\b|驗收|驗證|完成判準)[^\n]*$(.*?)(?=^#{2,3}\s|\Z)",
    re.MULTILINE | re.DOTALL,
)
# Epics are planning containers; their child issues carry the runnable commands.
ACCEPTANCE_EXEMPT_LABELS = frozenset({"epic"})


def parse_acceptance(body: str | None) -> list[str]:
    """Shell commands in fenced blocks under every acceptance or verification heading."""

    if not body:
        return []
    return [
        block.strip()
        for section in ACCEPTANCE_HEADING.finditer(body)
        for block in re.findall(
            r"```(?:sh|bash|shell)\n(.*?)```", section.group(1), re.DOTALL
        )
        if block.strip()
    ]


def runnable_issues(issues: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Only owner/member-authored issues may have their acceptance text executed."""

    return [
        i
        for i in issues
        if i.get("authorAssociation") in ACCEPTANCE_TRUSTED_ASSOCIATIONS
        and parse_acceptance(i.get("body"))
    ]


def _labels(issue: dict[str, Any]) -> set[str]:
    return {label.get("name") for label in issue.get("labels", [])}


def evaluate_issues(
    issues: list[dict[str, Any]], results: dict[int, dict[str, Any]] | None = None
) -> Finding:
    detail = []
    level = "ok"
    unverifiable = []
    for issue in issues:
        number = issue["number"]
        if not parse_acceptance(issue.get("body")):
            if not _labels(issue) & ACCEPTANCE_EXEMPT_LABELS:
                unverifiable.append(f"#{number} has no machine acceptance command")
            continue
        if results and number in results:
            outcome = results[number]
            if outcome["passed"]:
                detail.append(f"#{number} acceptance PASSES on this checkout: close it")
                level = max(level, "warn", key=_ORDER.get)
            else:
                detail.append(f"#{number} acceptance not yet met ({outcome['reason']})")
    detail.extend(unverifiable)
    if unverifiable:
        level = max(level, "warn", key=_ORDER.get)
    return Finding(
        "issues",
        level,
        f"{len(issues)} open issue(s), {len(unverifiable)} without a machine acceptance command",
        detail,
    )


def run_acceptance(
    issues: list[dict[str, Any]], *, cwd: Path, timeout: int = 300
) -> dict[int, dict[str, Any]]:
    results: dict[int, dict[str, Any]] = {}
    for issue in runnable_issues(issues):
        passed, reason = True, "all commands exited 0"
        for command in parse_acceptance(issue["body"]):
            try:
                done = subprocess.run(
                    ["bash", "-c", command],
                    cwd=cwd,
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                    check=False,
                )
            except subprocess.TimeoutExpired:
                passed, reason = False, f"timed out after {timeout}s"
                break
            if done.returncode != 0:
                passed, reason = False, f"exit {done.returncode}"
                break
        results[issue["number"]] = {"passed": passed, "reason": reason}
    return results


def exit_code(findings: list[Finding]) -> int:
    return max((_ORDER[f.level] for f in findings), default=0)


def render_json(findings: list[Finding], *, now: datetime) -> str:
    worst = max((f.level for f in findings), key=_ORDER.get, default="ok")
    return json.dumps(
        {
            "schema": SCHEMA,
            "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "worst": worst,
            "findings": [asdict(f) for f in findings],
        },
        indent=2,
        ensure_ascii=False,
    )


def render_text(findings: list[Finding]) -> str:
    mark = {"ok": "ok   ", "warn": "WARN ", "block": "BLOCK"}
    lines = []
    for f in findings:
        lines.append(f"[{mark[f.level]}] {f.section:9} {f.summary}")
        lines.extend(f"            - {d}" for d in f.detail)
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Collectors (thin; each turns an existing tool's output into plain data)
# --------------------------------------------------------------------------


def _run(
    cmd: list[str], cwd: Path, timeout: int = 60
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=False
    )


def collect_git(repo: Path) -> dict[str, Any]:
    def out(*args: str) -> str:
        return _run(["git", *args], repo).stdout.strip()

    return {
        "branch": out("branch", "--show-current"),
        "dirty": len(
            [line for line in out("status", "--porcelain").splitlines() if line]
        ),
        "local": out("rev-parse", "main"),
        "origin": out("rev-parse", "origin/main"),
    }


def collect_registry(repo: Path) -> list[dict[str, Any]]:
    done = _run([str(repo / "ops" / "worktree_orchestrate.py"), "list", "--json"], repo)
    return (
        json.loads(done.stdout).get("records", [])
        if done.returncode == 0 and done.stdout
        else []
    )


def collect_ci(repo: Path, run: Any = _run) -> list[dict[str, Any]]:
    """Recent main runs of every active workflow, each with its *own* history.

    One shared ``--limit`` is useless: a noisy workflow (agent-review fires on every
    PR event) fills the window and leaves hours of history for the others, so a
    three-day streak could never be seen.
    """

    listing = run(["gh", "workflow", "list", "--json", "name,state"], repo)
    if listing.returncode or not listing.stdout:
        return []
    runs: list[dict[str, Any]] = []
    for workflow in json.loads(listing.stdout):
        if workflow.get("state") != "active":
            continue
        done = run(
            [
                "gh",
                "run",
                "list",
                "--workflow",
                workflow["name"],
                "--branch",
                "main",
                "--limit",
                "40",
                "--json",
                "workflowName,conclusion,status,createdAt,url",
            ],
            repo,
        )
        if not done.returncode and done.stdout:
            runs.extend(json.loads(done.stdout))
    return runs


def prod_request() -> urllib.request.Request:
    # The edge rejects Python's default User-Agent with 403, so identify ourselves.
    return urllib.request.Request(PROD_INFO_URL, headers={"User-Agent": "kg-doctor/1"})


def collect_prod_info() -> dict[str, Any] | None:
    """One read-only probe of production, shared by the release and Sentry checks."""

    try:
        with urllib.request.urlopen(prod_request(), timeout=10) as response:
            payload = json.load(response)
    except (OSError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def collect_release_gap(
    repo: Path, now: datetime, info: dict[str, Any] | None
) -> tuple[str | None, int | None, float | None]:
    sha = info.get("version") if info else None
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        return None, None, None
    behind = _run(["git", "rev-list", "--count", f"{sha}..origin/main"], repo)
    stamp = _run(["git", "log", "-1", "--format=%ct", sha], repo)
    if behind.returncode or stamp.returncode or not stamp.stdout.strip():
        return sha, None, None
    age = (now.timestamp() - int(stamp.stdout.strip())) / 86400
    return sha, int(behind.stdout.strip()), age


def collect_sentry_local(
    repo: Path, env: dict[str, str] | None = None
) -> dict[str, Any] | None:
    try:
        done = subprocess.run(
            [str(repo / "ops" / "sentry_release.sh"), "check", "--json"],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
            env=env,
        )
        payload = json.loads(done.stdout) if done.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    return payload if isinstance(payload, dict) else None


def collect_complexity(repo: Path) -> tuple[list[dict[str, Any]] | None, float | None]:
    import complexity

    try:
        measured = complexity.measure(repo)
        budget = complexity.load_budget(repo / complexity.BUDGET_FILE)
    except (complexity.BudgetError, subprocess.CalledProcessError):
        return None, None
    return complexity.evaluate(measured, budget), complexity.ratio(measured)


def collect_delivery(repo: Path) -> dict[str, Any] | None:
    import delivery_metrics

    return delivery_metrics.collect(repo)


def collect_review_quota(
    repo: Path, now: datetime, run: Any = _run
) -> dict[str, int] | None:
    """PRs carrying a usage-limit comment, over the month and the recent days."""

    counts: dict[str, int] = {}
    for key, days in (
        ("month", REVIEW_QUOTA_WINDOW_DAYS),
        ("recent", REVIEW_QUOTA_RECENT_DAYS),
    ):
        since = (now - timedelta(days=days)).strftime("%Y-%m-%d")
        done = run(
            ["gh", "pr", "list", "--state", "all", "--limit", "1000"]
            + ["--search", f'"{REVIEW_QUOTA_PHRASE}" in:comments updated:>={since}']
            + ["--json", "number"],
            repo,
        )
        if done.returncode or not done.stdout:
            return None
        counts[key] = len(json.loads(done.stdout))
    return counts


def collect_review_fallback_documented(repo: Path) -> bool:
    """Whether the SOP still records the CR fallback that settles exhausted-quota reviews."""
    sop = repo / "docs" / "sop" / "review_discipline.md"
    return sop.is_file() and REVIEW_FALLBACK_HEADING in sop.read_text(encoding="utf-8")


def collect_disk() -> dict[str, Any] | None:
    try:
        return json.loads(DISK_GUARD_FILE.read_text())
    except (OSError, ValueError):
        return None


class IssueFetchError(RuntimeError):
    """gh could not list issues; carries gh's stderr so the report can say why."""


def collect_issues(repo: Path) -> list[dict[str, Any]]:
    # The REST issues endpoint, not `gh issue list --json`: it has no result cap
    # once paginated and no GraphQL field that can fail the whole request.
    done = _run(
        [
            "gh",
            "api",
            "--paginate",
            "repos/{owner}/{repo}/issues?state=open&per_page=100",
        ],
        repo,
        timeout=120,
    )
    if done.returncode != 0:
        raise IssueFetchError(
            done.stderr.strip() or f"gh api exited {done.returncode} with no stderr"
        )
    # --paginate prints one JSON array per page, back to back.
    decoder, text, pos, entries = json.JSONDecoder(), done.stdout, 0, []
    try:
        while text[pos:].strip():
            pos += len(text[pos:]) - len(text[pos:].lstrip())
            page, pos = decoder.raw_decode(text, pos)
            entries.extend(page)
    except ValueError as exc:
        raise IssueFetchError(f"unparseable gh api output: {exc}") from exc
    issues = [
        {**entry, "authorAssociation": entry.get("author_association")}
        for entry in entries
        if "pull_request" not in entry
    ]
    return exclude_health_report(issues)


HEALTH_LABEL = "health-report"


def exclude_health_report(issues: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The weekly report is this tool's own output; counting it would make it self-referential."""
    return [issue for issue in issues if HEALTH_LABEL not in _labels(issue)]


# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Read-only project health report.")
    parser.add_argument(
        "--ci",
        action="store_true",
        help="skip checks that only exist on a developer machine (checkout state, claims, disk guard)",
    )
    parser.add_argument(
        "--repo", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument(
        "--json", action="store_true", help="machine-readable report on stdout"
    )
    parser.add_argument(
        "--run-acceptance",
        action="store_true",
        help="execute the acceptance commands of owner/member-authored open issues on this checkout",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    repo = args.repo.resolve()
    now = datetime.now(timezone.utc)
    git = None if args.ci and not args.run_acceptance else collect_git(repo)
    issues_error = None
    try:
        issues = collect_issues(repo)
    except IssueFetchError as exc:
        issues, issues_error = [], str(exc)
    results = None
    if args.run_acceptance and issues_error is None:
        if git["branch"] != "main" or git["dirty"] or git["local"] != git["origin"]:
            print(
                "doctor: --run-acceptance needs a clean main == origin/main checkout",
                file=sys.stderr,
            )
            return 2
        print(
            "doctor: running acceptance commands of owner/member-authored issues",
            file=sys.stderr,
        )
        results = run_acceptance(issues, cwd=repo)
    ci = evaluate_ci(collect_ci(repo), now)
    prod_info = collect_prod_info()
    gap = evaluate_release_gap(*collect_release_gap(repo, now, prod_info))
    sentry = evaluate_sentry(
        prod_info,
        None if args.ci else collect_sentry_local(repo),
        check_local=not args.ci,
    )
    complexity_finding = evaluate_complexity(*collect_complexity(repo))
    delivery = evaluate_delivery(collect_delivery(repo), now)
    review = evaluate_review_quota(
        collect_review_quota(repo, now),
        fallback_documented=collect_review_fallback_documented(repo),
    )
    issues_finding = (
        Finding("issues", "warn", "could not list open issues via gh", [issues_error])
        if issues_error is not None
        else evaluate_issues(issues, results)
    )
    if args.ci:
        findings = [
            *ci,
            gap,
            sentry,
            delivery,
            review,
            complexity_finding,
            issues_finding,
        ]
    else:
        findings = [
            evaluate_git(git),
            evaluate_registry(collect_registry(repo)),
            *ci,
            gap,
            sentry,
            delivery,
            review,
            evaluate_disk(collect_disk()),
            complexity_finding,
            issues_finding,
        ]
    print(render_json(findings, now=now) if args.json else render_text(findings))
    return exit_code(findings)


if __name__ == "__main__":
    sys.exit(main())
