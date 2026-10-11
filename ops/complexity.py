#!/usr/bin/env -S uv run --python 3.13 python
"""Complexity budget: the delivery tooling may not quietly outgrow the product.

Line ceilings (authored code and docs only, never data files) for the areas that only ever grow by accretion (`ops/`,
`docs/`, `.github/workflows/`) live in ``ops/complexity_budget.json``.

    ./ops/complexity.py check      # exit 1 when an area is over its ceiling
    ./ops/complexity.py ratchet    # lower ceilings to current + slack; never raises
    ./ops/complexity.py show       # numbers, headroom, and ops : ios ratio

Going over means one of two visible acts in the PR: delete something, or edit the
ceiling in the budget file so a reviewer sees the number and the reason.  The
ceiling is therefore a decision, not a side effect.  ``ratchet`` only moves it
down, so deletions are banked and cannot be spent again silently.

A lane gate charges a lane only for its own growth.  Per area, delta = lines now minus lines at the
merge-base (``origin/main``, else ``main``), counted by the same ``count_lines`` rule on both sides.
The lane passes when delta <= the headroom the area had at the merge-base (ceiling read from the
budget file *at the base*), or when the lane itself raises the ceiling in the budget file (then the
new ceiling is judged absolutely).  Two sibling lanes that each fit the base headroom therefore both
pass, also after a rebase onto each other (headroom = the larger of the current merge-base's and the
lane's original fork point's: ``KG_COMPLEXITY_FORK_BASE``, else the branch's reflog creation commit,
else the CI merge commit's PR fork); absolute overflow of the checked tree is then only a WARNING that main needs a rebaseline PR.
On main itself (HEAD is the base) or with ``--absolute``/``--strict`` (CI on push to ``main``, see
``ci_args``) the absolute check fails, so a red trunk stays visible.  ``--base REF`` overrides the
base; with no usable base the absolute judgement applies, loudly.

Exit code: 0 within budget, 1 over budget, 2 usage or unreadable budget.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

SCHEMA = "kg.complexity-budget.v1"
BUDGET_FILE = "ops/complexity_budget.json"
AREAS = {
    "ops": "ops/",
    "docs": "docs/",
    "workflows": ".github/workflows/",
}
# The product the tooling serves; reported as a ratio, never budgeted.
REFERENCE_AREA = "ios/"
# Only authored text counts.  Fixtures, plists and recordings are data: regenerating
# one is not a change in complexity and must not be able to turn the gate red.
COUNTED_SUFFIXES = (".py", ".sh", ".md", ".yml", ".yaml", ".swift")
# Headroom a lift leaves above measured: the minimal margin every manual raise in the budget note used.
# Deliberately not the ratchet's ``slack`` (ops 2000), which would loosen the ceiling by thousands of lines.
LIFT_MARGIN = 5


class BudgetError(Exception):
    pass


def count_lines(repo: Path, prefix: str) -> int:
    listing = subprocess.run(
        ["git", "ls-files", "-z", "--", prefix],
        cwd=repo,
        capture_output=True,
        check=True,
    ).stdout
    total = 0
    for raw in listing.split(b"\0"):
        if not raw:
            continue
        path = repo / raw.decode()
        if path.suffix in COUNTED_SUFFIXES and path.is_file() and not path.is_symlink():
            total += path.read_bytes().count(b"\n")
    return total


def ci_args(env: dict[str, str] | None = None) -> list[str]:
    """Extra ``check`` flags for the CI entry: absolute on push to main, delta-aware on PRs."""
    event = (os.environ if env is None else env).get("GITHUB_EVENT_NAME")
    return ["--strict"] if event == "push" else []


def head_sha(repo: Path) -> str | None:
    found = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True
    )
    return found.stdout.strip() if found.returncode == 0 else None


def merge_base(repo: Path, base: str | None) -> str | None:
    """Commit to diff against, or None when there is no usable base (absolute mode)."""
    for ref in [base] if base else ["origin/main", "main"]:
        found = subprocess.run(
            ["git", "merge-base", "HEAD", ref],
            cwd=repo,
            capture_output=True,
            text=True,
        )
        if found.returncode == 0 and found.stdout.strip():
            return found.stdout.strip()
    return None


def count_lines_at(repo: Path, rev: str, prefix: str) -> int:
    """``count_lines`` over the tree of ``rev`` (same suffix and symlink rules)."""
    listing = subprocess.run(
        ["git", "ls-tree", "-r", "-z", rev, "--", prefix],
        cwd=repo,
        capture_output=True,
        check=True,
    ).stdout
    wanted = []
    for raw in listing.split(b"\0"):
        if not raw:
            continue
        meta, _, name = raw.decode().partition("\t")
        mode, _, rest = meta.partition(" ")
        if mode != "120000" and name.endswith(COUNTED_SUFFIXES):
            wanted.append(rest.split(" ")[1])
    if not wanted:
        return 0
    out = subprocess.run(
        ["git", "cat-file", "--batch"],
        cwd=repo,
        input="".join(f"{sha}\n" for sha in wanted).encode(),
        capture_output=True,
        check=True,
    ).stdout
    total, pos = 0, 0
    while pos < len(out):
        end = out.index(b"\n", pos)
        size = int(out[pos:end].split()[2])
        total += out[end + 1 : end + 1 + size].count(b"\n")
        pos = end + 1 + size + 1
    return total


def _budget_at(repo: Path, rev: str) -> tuple[dict[str, int], dict[str, int]] | None:
    shown = subprocess.run(
        ["git", "show", f"{rev}:{BUDGET_FILE}"], cwd=repo, capture_output=True
    )
    if shown.returncode != 0:
        return None
    try:
        ceilings = json.loads(shown.stdout)["ceilings"]
        counts = {n: count_lines_at(repo, rev, p) for n, p in AREAS.items()}
        return counts, {n: int(ceilings[n]) for n in AREAS}
    except (KeyError, TypeError, ValueError, IndexError, subprocess.CalledProcessError):
        return None  # includes cat-file "missing" lines: caller falls back to absolute


def fork_points(repo: Path, base: str) -> list[str]:
    """Where this lane originally forked, besides the current merge-base ``base``.

    A rebase (``ops/deliver.py``) moves the merge-base to main's tip, which would collapse the
    base headroom to main's remaining room.  The lane's own allowance is the larger of that and
    the room at its original fork: ``KG_COMPLEXITY_FORK_BASE`` if set, else the branch's creation
    commit from its reflog.  A CI merge commit (HEAD = main + PR) contributes the PR's fork point."""

    def git(*args: str) -> str:
        done = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True)
        return done.stdout.strip() if done.returncode == 0 else ""

    found: list[str] = []
    env = os.environ.get("KG_COMPLEXITY_FORK_BASE")
    if env:
        found.append(env)
    else:
        branch = git("branch", "--show-current")
        if branch:
            entries = git(
                "reflog", "show", "--format=%H", f"refs/heads/{branch}"
            ).split()
            if entries:
                origin = git("merge-base", entries[-1], base)
                if origin:
                    found.append(origin)
    parents = git("rev-list", "--parents", "-n", "1", "HEAD").split()[1:]
    if len(parents) == 2 and parents[0] == base:
        merged = git("merge-base", *parents)
        if merged:
            found.append(merged)
    return [rev for rev in dict.fromkeys(found) if rev != base]


def base_snapshot(
    repo: Path, base: str, forks: list[str] | None = None
) -> dict[str, dict[str, int]] | None:
    """Counts and ceilings at ``base`` plus ``headroom``: what the lane may add.  ``forks`` (the lane's
    original fork point, see ``fork_points``) contribute their own headroom, so a sibling merged
    first, or a rebase onto it, does not consume this lane's allowance.  None when the base has no readable budget."""
    at_base = _budget_at(repo, base)
    if at_base is None:
        return None
    counts, ceilings = at_base
    headroom = {n: ceilings[n] - counts[n] for n in AREAS}
    for fork in forks or []:
        at_fork = _budget_at(repo, fork)
        if at_fork:
            for n in AREAS:
                headroom[n] = max(headroom[n], at_fork[1][n] - at_fork[0][n])
    return {"counts": counts, "ceilings": ceilings, "headroom": headroom}


def measure(repo: Path) -> dict[str, int]:
    measured = {name: count_lines(repo, prefix) for name, prefix in AREAS.items()}
    measured["reference"] = count_lines(repo, REFERENCE_AREA)
    return measured


def load_budget(path: Path) -> dict[str, Any]:
    try:
        budget = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise BudgetError(f"cannot read {path}: {exc}") from exc
    if budget.get("schema") != SCHEMA:
        raise BudgetError(f"{path}: schema must be {SCHEMA!r}")
    for key in ("ceilings", "slack"):
        missing = sorted(set(AREAS) - set(budget.get(key, {})))
        if missing:
            raise BudgetError(f"{path}: {key} missing {missing}")
    return budget


def evaluate(
    measured: dict[str, int],
    budget: dict[str, Any],
    base: dict[str, dict[str, int]] | None = None,
) -> list[dict[str, Any]]:
    """Without ``base`` the judgement is absolute (``over`` = count > ceiling).  With ``base``
    (counts and ceilings at the merge-base) a lane is charged only for its own growth: ``over``
    when delta exceeds the base headroom, or, if the lane raised the ceiling, when count exceeds
    the new ceiling.  Absolute overflow the lane is not responsible for is ``warn``."""
    rows = []
    for name in AREAS:
        ceiling = int(budget["ceilings"][name])
        now = measured[name]
        beyond = now > ceiling
        delta = None
        if base is None:
            over = beyond
        else:
            delta = now - base["counts"][name]
            base_ceiling = base["ceilings"][name]
            if ceiling > base_ceiling:  # explicit bump in this lane: judged absolutely
                over = beyond
            else:
                over = delta > max(
                    0,
                    base.get("headroom", {}).get(
                        name, base_ceiling - base["counts"][name]
                    ),
                )
        rows.append(
            {
                "area": name,
                "lines": now,
                "ceiling": ceiling,
                "headroom": ceiling - now,
                "delta": delta,
                "over": over,
                "warn": beyond and not over,
            }
        )
    return rows


def ratcheted(measured: dict[str, int], budget: dict[str, Any]) -> dict[str, int]:
    """New ceilings: the lower of the current one and (measured + slack)."""
    return {
        name: min(
            int(budget["ceilings"][name]), measured[name] + int(budget["slack"][name])
        )
        for name in AREAS
    }


def lift(repo: Path, base: str | None = None) -> dict[str, tuple[int, int, int]]:
    """Rebase resolver: raise each area the lane is over its own room to measured + ``LIFT_MARGIN``.

    The lane is charged against the base headroom alone, never a fork point: the reflog that names
    a fork is local, and CI (``--no-fork-points`` in the merge group) cannot see it.  So an area left
    alone here passes the gate whichever view judges it, and a raised area is absolute at a ceiling
    above measured.  Nothing is raised when HEAD is the base (or no base is readable): there is no
    lane to charge, and a raise there would hide a red trunk.  Returns {area: (old, new, measured)};
    the budget file is written only when something was raised.
    """
    budget_path = repo / BUDGET_FILE
    budget = load_budget(budget_path)
    measured = measure(repo)
    ref = merge_base(repo, base)
    if ref is None or ref == head_sha(repo):
        return {}
    snapshot = base_snapshot(repo, ref, [])
    if snapshot is None:
        return {}
    raised = {}
    for row in evaluate(measured, budget, snapshot):
        if row["over"]:
            name = row["area"]
            new = measured[name] + LIFT_MARGIN
            raised[name] = (int(budget["ceilings"][name]), new, measured[name])
    if raised:
        for name, (_old, new, _now) in raised.items():
            budget["ceilings"][name] = new
        budget_path.write_text(json.dumps(budget, indent=2) + "\n", encoding="utf-8")
    return raised


def ratio(measured: dict[str, int]) -> float | None:
    return (
        round(measured["ops"] / measured["reference"], 2)
        if measured["reference"]
        else None
    )


def render(rows: list[dict[str, Any]], measured: dict[str, int]) -> str:
    lines = []
    for row in rows:
        mark = "OVER" if row["over"] else "warn" if row["warn"] else "ok  "
        note = (
            "  WARNING: main is over budget and needs a rebaseline PR; this lane's own growth fits"
            if row["warn"]
            else ""
        )
        lines.append(
            f"[{mark}] {row['area']:9} {row['lines']:>8,} lines / ceiling {row['ceiling']:>8,}"
            f"  (headroom {row['headroom']:+,}){note}"
        )
    value = ratio(measured)
    if value is not None:
        lines.append(
            f"        ops : ios = {value}  (tooling lines per product line; lower is healthier)"
        )
    return "\n".join(lines)


def main(argv: list[str] | None = None, repo: Path | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("command", choices=["check", "ratchet", "show"])
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--base",
        help="ref to diff against (default: merge-base with origin/main, else main)",
    )
    parser.add_argument(
        "--strict",
        "--absolute",
        dest="strict",
        action="store_true",
        help="judge absolute counts; ignore the base (CI on push to main, doctor)",
    )
    parser.add_argument(
        "--no-fork-points",
        action="store_true",
        help="charge the lane against the base headroom only (merge group: the head already carries "
        "the siblings merged ahead of it, so a PR fork allowance would hide their growth)",
    )
    args = parser.parse_args(argv)
    root = repo or Path(__file__).resolve().parents[1]
    try:
        budget_path = root / BUDGET_FILE
        budget = load_budget(budget_path)
        measured = measure(root)
    except (BudgetError, subprocess.CalledProcessError) as exc:
        print(f"complexity: {exc}", file=sys.stderr)
        return 2
    snapshot = None
    if not args.strict:
        base = merge_base(root, args.base)
        if base is None:
            print(
                "complexity: no merge-base (origin/main or main); judging absolute",
                file=sys.stderr,
            )
        elif args.base is None and base == head_sha(root):
            pass  # on main itself: absolute, so a red trunk stays visible
        else:
            try:
                snapshot = base_snapshot(
                    root, base, [] if args.no_fork_points else fork_points(root, base)
                )
            except subprocess.CalledProcessError as exc:
                print(f"complexity: base read failed ({exc})", file=sys.stderr)
            if snapshot is None:
                print("complexity: base unreadable; judging absolute", file=sys.stderr)
    rows = evaluate(measured, budget, snapshot)

    if args.command == "ratchet":
        new = ratcheted(measured, budget)
        lowered = {
            k: (budget["ceilings"][k], v)
            for k, v in new.items()
            if v < budget["ceilings"][k]
        }
        if lowered:
            budget["ceilings"] = new
            budget_path.write_text(
                json.dumps(budget, indent=2) + "\n", encoding="utf-8"
            )
        for area, (old, now) in lowered.items():
            print(f"ratchet: {area} ceiling {old:,} -> {now:,}")
        print(
            "ratchet: nothing to lower"
            if not lowered
            else "ratchet: wrote " + BUDGET_FILE
        )
        return 0

    if args.json:
        print(
            json.dumps(
                {"schema": SCHEMA, "areas": rows, "ops_to_ios": ratio(measured)},
                indent=2,
            )
        )
    else:
        print(render(rows, measured))
    over = [r["area"] for r in rows if r["over"]]
    warned = [r["area"] for r in rows if r["warn"]]
    if warned:
        print(
            f"complexity: WARNING main is over budget in {', '.join(warned)}; needs a rebaseline PR "
            "(this lane's own growth fits the base headroom)",
            file=sys.stderr,
        )
    if args.command == "check" and over:
        print(
            f"complexity: over budget: {', '.join(over)}. Delete something, or raise the ceiling in "
            f"{BUDGET_FILE} in this PR and say why.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
