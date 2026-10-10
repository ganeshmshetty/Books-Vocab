#!/usr/bin/env -S uv run --python 3.13 python
"""Turn the first red area suite on `main` into one P1 fix issue (Issue #2642).

Run by `.github/workflows/main-watch.yml` with the `workflow_run` fields in
`WATCH_*` env vars (never interpolated into a shell):

* red push-to-main run, no open issue for its area -> open one (P1, `main-red`)
* red run, the area already has an open issue      -> link the run there
* anything else (green, cancelled, PR, queue)      -> do nothing

Closing an issue is the fixer's call.  `--dry-run` prints the decision only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Mapping
from typing import Any

LABEL = "main-red"
PRIORITY = "P1"
RED = frozenset({"failure", "timed_out", "startup_failure"})
# Workflows that run on every push to main, named by the area a failure breaks.
AREAS = {
    "backend-quality": "backend",
    "ios-quality": "ios",
    "ops-suite": "ops",
    "design-system": "design-system",
    "ui-quality-gate": "ui-quality",
    "llm-eval": "llm-eval",
}
# Area -> taxonomy area label (issue_management.md: one area per issue). An
# unmapped area gets no area label, so triage assigns one instead of a guess.
AREA_LABELS = {
    "backend": "area/backend",
    "ios": "area/ios",
    "design-system": "area/ios",
    "ui-quality": "area/ios",
    "ops": "area/ops-ci",
    "llm-eval": "area/lab-podcast",
}
FIELDS = ("workflow", "conclusion", "event", "branch", "sha", "url")


def area_of(workflow: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", workflow.lower()).strip("-")
    return AREAS.get(workflow) or slug or "unknown"


def marker(area: str) -> str:
    return f"<!-- main-watch:{area} -->"


def _plain(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9 ._-]", "", text)[:80]


def plan(run: Mapping[str, str], open_issues: list[dict[str, Any]]) -> dict[str, Any]:
    if run["event"] != "push" or run["branch"] != "main":
        return {"action": "noop", "reason": "not a main push"}
    if run["conclusion"] not in RED:
        return {"action": "noop", "reason": f"{run['conclusion']} is not red"}
    area, name = area_of(run["workflow"]), _plain(run["workflow"])
    area_label = [AREA_LABELS[area]] if area in AREA_LABELS else []
    for issue in open_issues:
        if marker(area) in issue["body"]:
            linked = re.compile(re.escape(run["url"]) + r"(?![0-9])")
            if any(linked.search(t) for t in [issue["body"], *issue["comments"]]):
                return {"action": "noop", "reason": "run already linked"}
            return {
                "action": "comment",
                "number": issue["number"],
                "body": f"Still red on `main` at {run['sha']}: `{name}` "
                f"({run['conclusion']}) {run['url']}",
            }
    return {
        "action": "create",
        "title": f"main is red: {area} ({name}) at {run['sha'][:9]}",
        "labels": [PRIORITY, "needs-triage", *area_label, "bug", LABEL],
        "body": f"{marker(area)}\n`main` went red in the **{area}** area; the next "
        f"PR should not be the one that finds out.\n\n- Workflow: `{name}` "
        f"({run['conclusion']})\n- Commit: {run['sha']}\n- Run: {run['url']}\n\n"
        "Fix `main` first; later red pushes in this area are linked here "
        "instead of opening more issues. Close once the area is green.\n",
    }


def run_from_env(env: Mapping[str, str]) -> dict[str, str]:
    names = {field: f"WATCH_{field.upper()}" for field in FIELDS}
    missing = [n for n in names.values() if not env.get(n)]
    if missing:
        raise SystemExit(f"main_watch: missing {', '.join(missing)}")
    return {field: env[name] for field, name in names.items()}


def gh(*argv: str, stdin: str | None = None) -> str:
    done = subprocess.run(
        ["gh", *argv], input=stdin, capture_output=True, text=True, check=False
    )
    if done.returncode != 0:
        raise SystemExit(
            f"main_watch: gh {argv[0]} failed: {done.stderr.strip()[-300:]}"
        )
    return done.stdout


def find_open_issues(repo: str | None) -> list[dict[str, Any]]:
    scope = ["--repo", repo] if repo else []
    fields = "number,body,comments"
    out = gh("issue", "list", *scope, "--label", LABEL, "--state", "open",
             "--json", fields, "--limit", "100")  # fmt: skip
    return [
        {
            "number": i["number"],
            "body": i.get("body") or "",
            "comments": [c.get("body") or "" for c in i.get("comments", [])],
        }
        for i in json.loads(out or "[]")
    ]


def apply(decision: dict[str, Any], repo: str | None) -> None:
    scope = ["--repo", repo] if repo else []
    if decision["action"] == "create":
        gh("label", "create", LABEL, *scope, "--color", "b60205", "--force",
           "--description", "System: main went red; one open issue per area")  # fmt: skip
        labels = [p for label in decision["labels"] for p in ("--label", label)]
        gh("issue", "create", *scope, "--title", decision["title"], *labels,
           "--body-file", "-", stdin=decision["body"])  # fmt: skip
    elif decision["action"] == "comment":
        gh("issue", "comment", str(decision["number"]), *scope,
           "--body-file", "-", stdin=decision["body"])  # fmt: skip


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", help="owner/name; default is the current repository")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    run = run_from_env(os.environ)
    watched = run["event"] == "push" and run["branch"] == "main"
    decision = plan(run, find_open_issues(args.repo) if watched else [])
    print(json.dumps(decision, ensure_ascii=False))
    if not args.dry_run:
        apply(decision, args.repo)
    return 0


if __name__ == "__main__":
    sys.exit(main())
