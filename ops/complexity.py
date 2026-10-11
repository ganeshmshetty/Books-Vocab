#!/usr/bin/env -S uv run --python 3.13 python
"""Complexity budget: the delivery tooling may not quietly outgrow the product.

Line ceilings (authored code and docs only, never data files) for the areas that only ever grow by accretion (`ops/`,
`docs/`, `.github/workflows/`) live in ``ops/complexity_budget.json``.  A lane raises a ceiling by writing its own
fragment, one file in ``ops/complexity_budget.d/``, so two lanes never edit the same line.  An area's effective
ceiling is the base plus the sum of every fragment's raise.

    ./ops/complexity.py check                 # exit 1 when an area is over its effective ceiling
    ./ops/complexity.py raise --note WHY      # write this lane's fragment for the areas it is over (never on main)
    ./ops/complexity.py fold                  # fold all fragments into the base (CM, occasionally)
    ./ops/complexity.py ratchet               # lower ceilings to current + slack; folds when it lowers
    ./ops/complexity.py show                  # numbers, headroom, fragments, and ops : ios ratio

Going over means one of two visible acts in the PR: delete something, or write the raise fragment in the PR so a
reviewer sees the number and the reason.  The ceiling is therefore a decision, not a side effect.  ``ratchet`` only
moves it down, so deletions are banked and cannot be spent again silently.

A lane gate charges a lane only for its own growth.  Per area, delta = lines now minus lines at the
merge-base (``origin/main``, else ``main``), counted by the same ``count_lines`` rule on both sides.
The lane passes when delta <= the headroom the area had at the merge-base (effective ceiling read
*at that base*, fragments included), or when the lane itself raises the ceiling with its fragment
(then the new effective ceiling is judged absolutely).  ``raise`` writes a fragment only for the areas
the lane is over by this same judgement, so a lane that grows nothing never absorbs a red trunk's
overage, and it refuses on main or without a base.  Two sibling lanes that each fit the base headroom therefore both
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
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

SCHEMA = "kg.complexity-budget.v1"
BUDGET_FILE = "ops/complexity_budget.json"
# One raise per lane, as a file beside the base: git never merges two lanes' edits to the same line.
FRAGMENT_SCHEMA = "kg.complexity-budget-raise.v1"
FRAGMENT_DIR = "ops/complexity_budget.d"
FRAGMENT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
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


def _fragments_at(repo: Path, rev: str) -> list[dict[str, Any]]:
    """The fragments that exist in the tree of ``rev`` (same validation as ``load_fragments``)."""
    listing = subprocess.run(
        ["git", "ls-tree", "--name-only", "-z", rev, "--", f"{FRAGMENT_DIR}/"],
        cwd=repo,
        capture_output=True,
        check=True,
    ).stdout
    found = []
    for raw in listing.split(b"\0"):
        name = raw.decode()
        if not name.endswith(".json"):
            continue
        shown = subprocess.run(
            ["git", "show", f"{rev}:{name}"], cwd=repo, capture_output=True, check=True
        )
        found.append(
            {
                "name": Path(name).stem,
                **parse_fragment(shown.stdout.decode("utf-8"), f"{rev}:{name}"),
            }
        )
    return found


def _budget_at(repo: Path, rev: str) -> tuple[dict[str, int], dict[str, int]] | None:
    shown = subprocess.run(
        ["git", "show", f"{rev}:{BUDGET_FILE}"], cwd=repo, capture_output=True
    )
    if shown.returncode != 0:
        return None
    try:
        base = json.loads(shown.stdout)["ceilings"]
        ceilings = effective_ceilings(base, _fragments_at(repo, rev))
        counts = {n: count_lines_at(repo, rev, p) for n, p in AREAS.items()}
        return counts, ceilings
    except (
        KeyError,
        TypeError,
        ValueError,
        IndexError,
        BudgetError,
        subprocess.CalledProcessError,
    ):
        return None  # includes cat-file "missing" lines: caller falls back to absolute


def effective_ceilings_at(repo: Path, rev: str) -> dict[str, int]:
    """The ceilings ``rev`` enforces: its base file plus its fragments."""
    found = _budget_at(repo, rev)
    if found is None:
        raise BudgetError(f"{rev}: no readable complexity budget")
    return found[1]


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


def fragment_dir(budget_path: Path) -> Path:
    """``ops/complexity_budget.d`` beside ``ops/complexity_budget.json``."""
    return budget_path.parent / (budget_path.stem + ".d")


def _is_count(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def parse_fragment(text: str, label: str) -> dict[str, Any]:
    """Validate one raise fragment; every error names ``label`` (the file, or ``rev:path``)."""
    try:
        data = json.loads(text)
    except ValueError as exc:
        raise BudgetError(f"{label}: not JSON ({exc})") from exc
    if not isinstance(data, dict) or data.get("schema") != FRAGMENT_SCHEMA:
        raise BudgetError(f"{label}: schema must be {FRAGMENT_SCHEMA!r}")
    issue = data.get("issue")
    if not _is_count(issue) or issue < 0:
        raise BudgetError(
            f"{label}: issue must be an integer >= 0 (0 = no GitHub Issue)"
        )
    raises = data.get("raise")
    if not isinstance(raises, dict) or not raises:
        raise BudgetError(f"{label}: raise must name at least one area")
    for area, amount in raises.items():
        if area not in AREAS:
            raise BudgetError(
                f"{label}: unknown area {area!r}; expected one of {sorted(AREAS)}"
            )
        if not _is_count(amount) or amount <= 0:
            raise BudgetError(
                f"{label}: raise[{area!r}] must be a positive integer, got {amount!r}"
            )
    note = data.get("note")
    if not isinstance(note, str) or not note.strip():
        raise BudgetError(f"{label}: note must say why the ceiling moves")
    return {"issue": issue, "raise": dict(raises), "note": note}


def load_fragments(directory: Path) -> list[dict[str, Any]]:
    """Every fragment in ``directory``, sorted by name; a malformed one is a BudgetError."""
    if not directory.is_dir():
        return []
    found = []
    for path in sorted(directory.glob("*.json")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise BudgetError(f"cannot read {path}: {exc}") from exc
        found.append({"name": path.stem, **parse_fragment(text, str(path))})
    return found


def effective_ceilings(
    base: dict[str, Any], fragments: list[dict[str, Any]]
) -> dict[str, int]:
    ceilings = {name: int(base[name]) for name in AREAS}
    for fragment in fragments:
        for area, amount in fragment["raise"].items():
            ceilings[area] += amount
    return ceilings


def load_base_budget(path: Path) -> dict[str, Any]:
    """The base file as written: its own ceilings, no fragments applied (writers use this)."""
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


def load_budget(path: Path) -> dict[str, Any]:
    """The budget judged by the gate: ``ceilings`` are effective (base plus fragments);
    ``fragments`` lists the fragments applied, for the report."""
    budget = load_base_budget(path)
    fragments = load_fragments(fragment_dir(path))
    return {
        **budget,
        "ceilings": effective_ceilings(budget["ceilings"], fragments),
        "fragments": fragments,
    }


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


def _current_branch(repo: Path) -> str:
    found = subprocess.run(
        ["git", "branch", "--show-current"], cwd=repo, capture_output=True, text=True
    )
    return found.stdout.strip() if found.returncode == 0 else ""


def lane_name(repo: Path) -> str:
    """This lane's fragment name: its branch, made path-safe (one branch, one file).  A detached HEAD has
    no lane name, and a sha-named fragment would be a new file on every run: the caller must pass one."""
    branch = _current_branch(repo)
    if not branch:
        raise BudgetError(
            "detached HEAD has no lane name; pass --name for this lane's fragment"
        )
    return re.sub(r"[^A-Za-z0-9._-]+", "-", branch).strip("-.")


def lane_issue(repo: Path) -> int:
    """The Issue the lane branch names (``issue-<N>``); 0 for a direct assignment with no Issue."""
    found = re.search(r"issue-(\d+)", _current_branch(repo))
    return int(found.group(1)) if found else 0


def plan_raise(
    measured: dict[str, int],
    ceilings: dict[str, int],
    areas: list[str] | None = None,
) -> dict[str, int]:
    """For each failing area: the amount that lifts its effective ceiling to measured + ``LIFT_MARGIN``.

    Only areas measured above their effective ceiling (and in ``areas``, when given) get an amount.
    """
    return {
        area: measured[area] - ceilings[area] + LIFT_MARGIN
        for area in AREAS
        if measured[area] > ceilings[area] and (areas is None or area in areas)
    }


def write_fragment(
    budget_path: Path, name: str, issue: int, note: str, add: dict[str, int]
) -> Path:
    """Add ``add`` to the fragment ``name`` (created when absent).  Each amount is on top of what that
    fragment already raises, so repeated lifts accumulate and never rewrite a sibling's file."""
    if not FRAGMENT_NAME.fullmatch(name):
        raise BudgetError(f"fragment name {name!r} must be a plain file name")
    if not _is_count(issue) or issue < 0:
        raise BudgetError(f"fragment issue must be an integer >= 0, got {issue!r}")
    directory = fragment_dir(budget_path)
    path = directory / f"{name}.json"
    raises: dict[str, int] = {}
    notes = [note]
    if path.exists():
        existing = parse_fragment(path.read_text(encoding="utf-8"), str(path))
        raises = dict(existing["raise"])
        notes = [existing["note"]] + ([] if note in existing["note"] else [note])
    for area, amount in add.items():
        raises[area] = raises.get(area, 0) + amount
    data = {
        "schema": FRAGMENT_SCHEMA,
        "issue": issue,
        "raise": {area: raises[area] for area in AREAS if area in raises},
        "note": "; ".join(notes),
    }
    directory.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return path


def _drop_fragments(budget_path: Path, fragments: list[dict[str, Any]]) -> None:
    for fragment in fragments:
        (fragment_dir(budget_path) / f"{fragment['name']}.json").unlink()


def _fold_into_base(
    budget_path: Path, ceilings: dict[str, int], fragments: list[dict[str, Any]]
) -> None:
    """Make ``ceilings`` the base and delete the ``fragments`` they absorb.  The base is validated before
    anything is removed.  The fragments go first: a crash between the two writes leaves the base without
    the raises (a lower ceiling, at worst a red check to rerun), never with them counted twice (a
    silently wider ceiling)."""
    base = load_base_budget(budget_path)
    _drop_fragments(budget_path, fragments)
    base["ceilings"] = ceilings
    budget_path.write_text(json.dumps(base, indent=2) + "\n", encoding="utf-8")


def fold(budget_path: Path) -> list[str]:
    """Fold every fragment into the base ceilings and delete the fragments.  Effective ceilings
    are unchanged.  Returns the names folded (empty: nothing to do, nothing written)."""
    fragments = load_fragments(fragment_dir(budget_path))
    if not fragments:
        return []
    base = load_base_budget(budget_path)
    _fold_into_base(
        budget_path, effective_ceilings(base["ceilings"], fragments), fragments
    )
    return [fragment["name"] for fragment in fragments]


def lift(repo: Path, base: str | None = None) -> dict[str, tuple[int, int, int]]:
    """Rebase resolver: raise each area the lane is over its own room to measured + ``LIFT_MARGIN``,
    by writing this lane's fragment (the base file is never touched, so the rebase cannot conflict).

    The lane is charged against the base headroom alone, never a fork point: the reflog that names
    a fork is local, and CI (``--no-fork-points`` in the merge group) cannot see it.  So an area left
    alone here passes the gate whichever view judges it, and a raised area is absolute at a ceiling
    above measured.  Nothing is raised when HEAD is the base (or no base is readable): there is no
    lane to charge, and a raise there would hide a red trunk.  Returns {area: (old, new, measured)},
    where old and new are effective ceilings; a fragment is written only when something was raised.
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
    over = [row["area"] for row in evaluate(measured, budget, snapshot) if row["over"]]
    add = plan_raise(measured, budget["ceilings"], over)
    if not add:
        return {}
    write_fragment(
        budget_path,
        lane_name(repo),
        lane_issue(repo),
        "raised after rebase: lane growth exceeded the base headroom",
        add,
    )
    return {
        area: (
            budget["ceilings"][area],
            budget["ceilings"][area] + amount,
            measured[area],
        )
        for area, amount in add.items()
    }


def raise_lane(
    repo: Path,
    budget_path: Path,
    budget: dict[str, Any],
    measured: dict[str, int],
    snapshot: dict[str, dict[str, int]] | None,
    on_trunk: bool,
    args: argparse.Namespace,
) -> int:
    """``raise``: this lane's fragment for each area the lane is over, by the judgement ``check`` makes.

    Refused on main (a raise there would hide a red trunk) and without a base to charge the lane against.
    An area the lane did not grow past its headroom gets nothing, so a lane never absorbs main's overage.
    """
    if not args.note:
        print("complexity: raise needs --note (why the ceiling moves)", file=sys.stderr)
        return 2
    if on_trunk or snapshot is None:
        print(
            "complexity: raise refused: HEAD is the base; fix the red trunk, do not raise it"
            if on_trunk
            else "complexity: raise refused: no readable base to charge this lane against",
            file=sys.stderr,
        )
        return 2
    over = [row["area"] for row in evaluate(measured, budget, snapshot) if row["over"]]
    add = plan_raise(measured, budget["ceilings"], over)
    if not add:
        print("raise: this lane is within its own headroom; no fragment written")
        return 0
    try:
        path = write_fragment(
            budget_path,
            args.name or lane_name(repo),
            lane_issue(repo) if args.issue is None else args.issue,
            args.note,
            add,
        )
    except BudgetError as exc:
        print(f"complexity: {exc}", file=sys.stderr)
        return 2
    print(
        f"raise: wrote {path.relative_to(repo)}: "
        + ", ".join(f"{area} +{amount}" for area, amount in add.items())
    )
    return 0


def ratio(measured: dict[str, int]) -> float | None:
    return (
        round(measured["ops"] / measured["reference"], 2)
        if measured["reference"]
        else None
    )


def describe_fragment(fragment: dict[str, Any]) -> str:
    raised = ", ".join(
        f"{area} +{amount}" for area, amount in fragment["raise"].items()
    )
    return f"fragment {fragment['name']} (issue {fragment['issue']}): {raised}"


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
    parser.add_argument(
        "command", choices=["check", "ratchet", "show", "raise", "fold"]
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--base",
        help="ref to diff against (default: merge-base with origin/main, else main)",
    )
    parser.add_argument(
        "--issue",
        type=int,
        help="raise: the Issue number (default: issue-<N> in the branch name; 0 = none)",
    )
    parser.add_argument(
        "--name",
        help="raise: fragment name (default: this branch, path-safe)",
    )
    parser.add_argument("--note", help="raise: why the ceiling moves (required)")
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
    if args.command == "fold":
        folded = fold(budget_path)
        print(
            f"fold: folded {len(folded)} fragment(s) into {BUDGET_FILE}: {', '.join(folded)}"
            if folded
            else "fold: no fragments; nothing to do"
        )
        return 0
    snapshot = None
    base = None if args.strict else merge_base(root, args.base)
    on_trunk = base is not None and base == head_sha(root)
    if not args.strict:
        if base is None:
            print(
                "complexity: no merge-base (origin/main or main); judging absolute",
                file=sys.stderr,
            )
        elif args.base is None and on_trunk:
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
    if args.command == "raise":
        return raise_lane(root, budget_path, budget, measured, snapshot, on_trunk, args)
    rows = evaluate(measured, budget, snapshot)

    if args.command == "ratchet":
        new = ratcheted(measured, budget)
        lowered = {
            k: (budget["ceilings"][k], v)
            for k, v in new.items()
            if v < budget["ceilings"][k]
        }
        if lowered:
            # Absolute targets for every area: writing them absorbs the fragments, so drop them too.
            _fold_into_base(budget_path, new, budget["fragments"])
        for area, (old, now) in lowered.items():
            print(f"ratchet: {area} ceiling {old:,} -> {now:,}")
        print(
            "ratchet: nothing to lower"
            if not lowered
            else f"ratchet: wrote {BUDGET_FILE} (folded {len(budget['fragments'])} fragment(s))"
        )
        return 0

    if args.json:
        print(
            json.dumps(
                {
                    "schema": SCHEMA,
                    "areas": rows,
                    "ops_to_ios": ratio(measured),
                    "fragments": budget["fragments"],
                },
                indent=2,
            )
        )
    else:
        for fragment in budget["fragments"]:
            print(describe_fragment(fragment))
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
            f"complexity: over budget: {', '.join(over)}. Delete something, or raise the ceiling for this "
            f"lane: ./ops/complexity.py raise --note '<why>' writes its own fragment in {FRAGMENT_DIR}/.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
