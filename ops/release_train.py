#!/usr/bin/env -S uv run --python 3.13 python
"""Read-only release preflight: "is it safe to advance origin/prod right now?".

Every check here exists because skipping it already cost something:

* ``trunk`` / ``ci``     - never ship a red or unsynced main (reuses doctor.py).
* ``prod-ff``            - the reconciler pulls ``--ff-only``; a diverged prod ref
                           means it alerts and deploys nothing.
* ``format-drift``       - release.sh must edit backend/src/kg/api.py and the PR
                           gate formats changed files, so an unformatted api.py
                           turns the candidate PR red.
* ``prod-clone``         - felix ``~/kg-prod`` must be exactly ``origin/prod``;
                           a rewritten history leaves it diverged and ff-only
                           refuses (found live on 2026-10-07).
* ``reconciler``         - dry-run verdict must be healthy, not poisoned/locked.
* ``alignment``          - live ``/api/system/info`` must already match the last
                           release, otherwise a previous rollout is unresolved.
* ``backup``             - a verified pre-deploy backup newer than 24h.
* ``env``                - required production env present.
* ``hot-path``           - auth/billing/LLM/handler files in the range are listed:
                           shipping them needs an explicit go from the owner.

Nothing here writes to the repository, GitHub or production.  The one remote
side effect is ``git fetch origin prod`` inside felix's own clone, which the
reconciler performs every 90 seconds anyway.

Exit code: 0 ready, 1 ready with warnings, 2 blocked.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import doctor  # same directory; reused for Finding, rendering, CI and git facts

Finding = doctor.Finding
Runner = Callable[..., subprocess.CompletedProcess[str]]

# release.sh edits these .py files; the PR gate format-checks every changed .py.
RELEASE_TOUCHED_PY = ("backend/src/kg/api.py",)
HOT_PATH = re.compile(
    r"backend/src/kg/(?:.*(?:auth|billing|llm|provider|handler|payment|entitle).*)"
)
BACKUP_MAX_AGE_HOURS = 24
FELIX_SSH = os.environ.get("KG_FELIX_SSH", "chenliangyu@100.118.39.104")


# --- pure evaluators --------------------------------------------------------


def evaluate_prod_ff(is_ancestor: bool, behind: int) -> Finding:
    if not is_ancestor:
        return Finding(
            "prod-ff",
            "block",
            "origin/prod is not an ancestor of origin/main",
            ["the reconciler pulls --ff-only; this release would deploy nothing"],
        )
    return Finding(
        "prod-ff", "ok", f"origin/prod fast-forwards to main (+{behind} commit(s))"
    )


def evaluate_format(drift: dict[str, bool]) -> Finding:
    bad = sorted(path for path, unformatted in drift.items() if unformatted)
    if bad:
        return Finding(
            "format-drift",
            "block",
            f"{len(bad)} file(s) the release must touch are unformatted on main",
            [
                f"{path}: ship a format-only PR first, then rebuild the candidate"
                for path in bad
            ],
        )
    return Finding("format-drift", "ok", "release-touched Python files are formatted")


def evaluate_prod_clone(facts: dict[str, Any] | None) -> Finding:
    if facts is None:
        return Finding("prod-clone", "warn", "felix production clone not inspected")
    problems = []
    if facts["ahead"] or facts["behind"]:
        problems.append(
            f"HEAD vs origin/prod: ahead {facts['ahead']}, behind {facts['behind']}"
            + (
                " (diverged: realign with `git reset --keep origin/prod` after proving the trees match)"
                if facts["ahead"] and facts["behind"]
                else ""
            )
        )
    if facts["dirty"]:
        problems.append("working tree has local changes")
    if problems:
        return Finding(
            "prod-clone",
            "block",
            "felix ~/kg-prod is not exactly origin/prod",
            problems,
        )
    return Finding("prod-clone", "ok", "felix ~/kg-prod == origin/prod, clean")


def evaluate_reconciler(verdict: dict[str, Any] | None, loaded: bool) -> Finding:
    if verdict is None:
        return Finding("reconciler", "block", "reconciler dry-run produced no verdict")
    state = verdict.get("verdict")
    if state in ("poisoned-skip", "rollback-failed"):
        return Finding(
            "reconciler",
            "block",
            f"reconciler is {state}",
            ["clear the poison deliberately first"],
        )
    if state == "locked":
        return Finding(
            "reconciler", "warn", "reconciler holds the deploy lock right now"
        )
    if not loaded:
        return Finding(
            "reconciler", "block", "launchd job com.kg.reconcile is not loaded"
        )
    return Finding("reconciler", "ok", f"reconciler healthy (dry-run verdict: {state})")


def evaluate_alignment(
    live: str | None, prod_sha: str, deployed: str | None
) -> Finding:
    if not live:
        return Finding("alignment", "warn", "live version unavailable")
    problems = []
    if not prod_sha.startswith(live):
        problems.append(
            f"live {live} is not origin/prod {prod_sha[:9]}: a rollout is unresolved or never ran"
        )
    if deployed and not (deployed.startswith(live) or live.startswith(deployed)):
        problems.append(f"live {live} != felix backend/VERSION {deployed}")
    if problems:
        return Finding(
            "alignment", "warn", "production is not on the last released ref", problems
        )
    return Finding("alignment", "ok", f"live {live} == origin/prod")


def evaluate_backup(newest_age_hours: float | None) -> Finding:
    if newest_age_hours is None:
        return Finding(
            "backup",
            "block",
            "no local pre-deploy backup found",
            ["./ops/devops_kg_safe.sh backup"],
        )
    if newest_age_hours > BACKUP_MAX_AGE_HOURS:
        return Finding(
            "backup",
            "block",
            f"newest backup is {newest_age_hours:.0f}h old (limit {BACKUP_MAX_AGE_HOURS}h)",
            ["./ops/devops_kg_safe.sh backup"],
        )
    return Finding("backup", "ok", f"backup is {newest_age_hours:.1f}h old")


def evaluate_env(output: str | None) -> Finding:
    if output is None:
        return Finding("env", "warn", "production env not checked")
    missing = [
        line.strip() for line in output.splitlines() if line.strip().startswith("✗")
    ]
    if missing:
        return Finding(
            "env",
            "block",
            f"{len(missing)} env-check failure(s) (missing var, unsafe flag or backend startup rule)",
            missing,
        )
    return Finding("env", "ok", "required production env present")


def evaluate_hot_path(changed: list[str]) -> Finding:
    hot = sorted(path for path in changed if HOT_PATH.search(path))
    if hot:
        return Finding(
            "hot-path",
            "warn",
            f"{len(hot)} auth/billing/LLM/handler file(s) in this release: needs the owner's explicit go",
            hot[:12] + ([f"... and {len(hot) - 12} more"] if len(hot) > 12 else []),
        )
    return Finding("hot-path", "ok", "no hot-path files in the release range")


# --- collectors -------------------------------------------------------------


def _run(
    cmd: list[str], cwd: Path | None = None, stdin: str | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd,
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
        timeout=180,
    )


def git_out(repo: Path, *argv: str, run: Runner = _run) -> str:
    done = run(["git", *argv], cwd=repo)
    if done.returncode != 0:
        raise RuntimeError(f"git {' '.join(argv)} failed: {done.stderr.strip()[-200:]}")
    return done.stdout.strip()


def collect_format(repo: Path, run: Runner = _run) -> dict[str, bool]:
    drift = {}
    for path in RELEASE_TOUCHED_PY:
        source = git_out(repo, "show", f"origin/main:{path}", run=run)
        done = run(
            [
                "uv",
                "run",
                "--quiet",
                "--no-project",
                "--python",
                "3.13",
                "--with",
                "ruff==0.16.3",
                "ruff",
                "format",
                "--check",
                "--stdin-filename",
                path,
                "-",
            ],
            cwd=repo,
            stdin=source + "\n",
        )
        drift[path] = done.returncode != 0
    return drift


def collect_prod_clone(run: Runner = _run) -> dict[str, Any] | None:
    script = (
        "cd ~/kg-prod && git fetch -q origin prod && "
        'echo "$(git rev-list --left-right --count HEAD...origin/prod)" && '
        "git status --porcelain | wc -l && cat backend/VERSION"
    )
    done = run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", FELIX_SSH, script]
    )
    if done.returncode != 0:
        return None
    lines = done.stdout.strip().splitlines()
    ahead, behind = (int(n) for n in lines[0].split())
    return {
        "ahead": ahead,
        "behind": behind,
        "dirty": int(lines[1]) > 0,
        "version": lines[2].strip(),
    }


def collect_reconciler(run: Runner = _run) -> tuple[dict[str, Any] | None, bool]:
    script = (
        "cd ~/kg-prod && KG_RECON_REPO=~/kg-prod ops/kg_reconcile.sh --dry-run 2>/dev/null | tail -1; "
        "echo ---; launchctl list | grep -c com.kg.reconcile"
    )
    done = run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", FELIX_SSH, script]
    )
    if done.returncode != 0:
        return None, False
    head, _, tail = done.stdout.partition("---")
    try:
        verdict = json.loads(head.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return None, tail.strip() == "1"
    return verdict, tail.strip() == "1"


def collect_backup_age(repo: Path, now: float | None = None) -> float | None:
    newest = None
    for path in (repo / "backups").glob("data_*.tar.gz"):
        newest = max(newest or 0.0, path.stat().st_mtime)
    return None if newest is None else ((now or time.time()) - newest) / 3600


def collect_env(repo: Path, run: Runner = _run) -> str | None:
    done = run([str(repo / "ops" / "devops_kg_safe.sh"), "env-check"], cwd=repo)
    return done.stdout if done.returncode == 0 or done.stdout else None


# --- assembly ---------------------------------------------------------------


def ci_findings(runs: list[dict[str, Any]]) -> list[Finding]:
    """Non-ok CI findings, or the ok line only when every workflow is readable and green."""

    ci = [
        f
        for f in doctor.evaluate_ci(runs, datetime.now(timezone.utc))
        if f.level != "ok"
    ]
    return ci or [Finding("ci", "ok", "no workflow is known-red on main")]


def build_findings(repo: Path, *, remote: bool, run: Runner = _run) -> list[Finding]:
    findings = [doctor.evaluate_git(doctor.collect_git(repo))]
    findings += ci_findings(doctor.collect_ci(repo))

    git_out(repo, "fetch", "-q", "origin", "main", "prod", run=run)
    done = run(
        ["git", "merge-base", "--is-ancestor", "origin/prod", "origin/main"], cwd=repo
    )
    behind = int(
        git_out(repo, "rev-list", "--count", "origin/prod..origin/main", run=run)
    )
    findings.append(evaluate_prod_ff(done.returncode == 0, behind))
    findings.append(evaluate_format(collect_format(repo, run)))
    changed = git_out(
        repo,
        "diff",
        "--name-only",
        "origin/prod",
        "origin/main",
        "--",
        "backend/src",
        run=run,
    )
    findings.append(evaluate_hot_path(changed.splitlines()))

    clone = collect_prod_clone(run) if remote else None
    findings.append(evaluate_prod_clone(clone))
    if remote:
        verdict, loaded = collect_reconciler(run)
        findings.append(evaluate_reconciler(verdict, loaded))
    # --skip-remote stays offline: no prod probe, so the live version is unavailable.
    info = doctor.collect_prod_info() if remote else None
    live, _behind, _age = doctor.collect_release_gap(
        repo, datetime.now(timezone.utc), info
    )
    prod_sha = git_out(repo, "rev-parse", "origin/prod", run=run)
    findings.append(
        evaluate_alignment(live, prod_sha, clone["version"] if clone else None)
    )
    findings.append(evaluate_backup(collect_backup_age(repo)))
    findings.append(evaluate_env(collect_env(repo, run) if remote else None))
    return findings


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--repo", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--skip-remote",
        action="store_true",
        help="do not ssh to felix (offline preflight)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    findings = build_findings(Path(args.repo), remote=not args.skip_remote)
    now = datetime.now(timezone.utc)
    print(
        doctor.render_json(findings, now=now)
        if args.json
        else doctor.render_text(findings)
    )
    return doctor.exit_code(findings)


if __name__ == "__main__":
    sys.exit(main())
