#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# ///
"""Plan the Linux ops groups one ops-suite run executes (Issue #3467).

--scope full (merge group, push) always selects every Linux group.
--scope targeted (PR gate) selects the groups whose routed tests reference a
changed path, plus the contract groups. A path the planner cannot place fails
safe to the full suite. Stdout is one JSON object; decisions go to stderr.
"""

from __future__ import annotations

import argparse
import glob
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DISPATCHER = ROOT / "ops" / "test_ops.sh"
COVERAGE = ROOT / "ops" / "tests" / "test_ops_ci_coverage.sh"
FULL_SHARD_COUNT = 8
TARGETED_MAX_SHARDS = 2
CONTRACT_GROUPS = ("ops-ci-coverage", "docs-lint")
WORKFLOW_CONTRACT_GROUP = "github-workflows"
SHA = re.compile(r"[0-9a-f]{40}")
ARM_HEADER = re.compile(r"^    ([a-z0-9-]+)\)")
ARM_DEFAULT = re.compile(r"^    \*\)")
TEST_TOKEN = re.compile(
    r"(?:^|[^A-Za-z0-9_.\-])((?:ops|lab|\.claude)/[A-Za-z0-9_./*\-]+)"
)
TEST_FILE_NAME = re.compile(r"test_.*\.(?:py|sh)")
COMMENT = re.compile(r"(?:^|\s)#.*")
GLOB_CHARS = ("*", "?", "[")

# Changing these changes test selection itself, or the planner's own rules.
FULL_PATHS = frozenset(
    {
        "ops/test_ops.sh",
        "ops/tests/test_ops_ci_coverage.sh",
        "ops/ci_scope_router.sh",
        "ops/ci_ops_suite_plan.py",
        ".github/workflows/ops-suite.yml",
        ".github/workflows/pr-gate.yml",
    }
)

# No Linux ops group reads these, unless a routed test references them (checked
# first). docs/ is linted by repo-gate docs-lint on every PR; backend/ by
# backend-quality.
ZERO_PATHS = frozenset({"README.md", "LICENSE", ".github/PULL_REQUEST_TEMPLATE.md"})
ZERO_PREFIXES = ("docs/", "lab/llm_eval/", ".github/ISSUE_TEMPLATE/", "backend/")
# Backend files that ops-suite push.paths lists for the ops tests (Issue #2326).
BACKEND_OPS_PATHS = frozenset(
    {
        "backend/ops_cli.py",
        "backend/ops_edit.py",
        "backend/tests/ops_helpers.py",
        "backend/restart_kg.sh",
        "backend/view_logs.sh",
    }
)
BACKEND_OPS_PREFIXES = ("backend/src/kg/ops_",)
# Directories whose members are loaded as a set: a changed member selects the
# groups whose routed tests name the directory (every ops lane adds a budget fragment).
DIRECTORY_REFERENCES = (("ops/complexity_budget.d/", "complexity_budget.d"),)


class PlanError(Exception):
    """The planner cannot place the change; the caller fails safe to full."""


def linux_groups() -> list[str]:
    result = subprocess.run(
        [str(COVERAGE), "--print-linux-groups"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    groups = [line for line in result.stdout.splitlines() if line]
    if not groups:
        raise PlanError("coverage printed no Linux groups")
    return groups


def declared_groups(dispatcher_text: str) -> set[str]:
    match = re.search(
        r"^DEFAULT_TESTS=\((.*?)^\)", dispatcher_text, re.MULTILINE | re.DOTALL
    )
    if match is None:
        raise PlanError("DEFAULT_TESTS not found in ops/test_ops.sh")
    return {COMMENT.sub("", line).strip() for line in match.group(1).splitlines()} - {
        ""
    }


def run_one_arms(dispatcher_text: str) -> list[tuple[str, str]]:
    """(group, test path or glob) for every test file a run_one() case arm names."""
    lines = dispatcher_text.splitlines()
    try:
        start = lines.index("run_one() {")
    except ValueError as exc:
        raise PlanError("run_one() not found in ops/test_ops.sh") from exc
    group = ""
    arms: list[tuple[str, str]] = []
    for line in lines[start + 1 :]:
        if line.startswith("}"):
            break
        if ARM_DEFAULT.match(line):
            group = ""
            continue
        header = ARM_HEADER.match(line)
        if header:
            group = header.group(1)
            line = line[header.end() :]
        if not group:
            continue
        code = COMMENT.sub("", line)
        for token in TEST_TOKEN.finditer(code):
            path = token.group(1)
            if TEST_FILE_NAME.fullmatch(path.rsplit("/", 1)[-1]):
                arms.append((group, path))
    return arms


def expand(token: str) -> list[str]:
    if any(char in token for char in GLOB_CHARS):
        return sorted(glob.glob(token, root_dir=ROOT))
    return [token] if (ROOT / token).is_file() else []


def module_patterns(path: str) -> list[re.Pattern[str]]:
    """Import forms that load ops/<a>/<b>.py as a module; empty for other paths."""
    if not (path.startswith("ops/") and path.endswith(".py")):
        return []
    module = path[len("ops/") : -len(".py")].replace("/", ".")
    name = re.escape(module)
    patterns = [
        re.compile(
            rf"^[ \t]*(?:import|from)[ \t]+(?:ops\.)?{name}(?![A-Za-z0-9_])",
            re.MULTILINE,
        ),
        re.compile(rf"-m[ \t]+(?:ops\.)?{name}(?![A-Za-z0-9_])", re.MULTILINE),
    ]
    parent, _, leaf = module.rpartition(".")
    if parent:
        # from <package> import <submodule>: any name over-selects siblings, never misses.
        patterns.append(
            re.compile(
                rf"^[ \t]*from[ \t]+(?:ops\.)?{re.escape(parent)}[ \t]+import\b",
                re.MULTILINE,
            )
        )
    else:
        patterns.append(
            re.compile(
                rf"^[ \t]*from[ \t]+ops[ \t]+import\b(?:[^\n]*(?<![A-Za-z0-9_]){re.escape(leaf)}(?![A-Za-z0-9_])|[ \t]*\()",
                re.MULTILINE,
            )
        )
    return patterns


class Routing:
    """Which declared groups run which routed test files, read from ops/test_ops.sh."""

    def __init__(self) -> None:
        dispatcher_text = DISPATCHER.read_text(encoding="utf-8")
        self.declared = declared_groups(dispatcher_text)
        self.file_groups: dict[str, set[str]] = {}
        for group, token in run_one_arms(dispatcher_text):
            if group not in self.declared:
                continue
            for path in expand(token):
                self.file_groups.setdefault(path, set()).add(group)
        self.texts = {
            path: (ROOT / path).read_text(encoding="utf-8", errors="replace")
            for path in self.file_groups
        }

    def referencing_groups(self, path: str) -> set[str]:
        """Groups whose routed tests import (Python), name (other files) or read the directory of the path."""
        directory_token = next(
            (
                token
                for prefix, token in DIRECTORY_REFERENCES
                if path.startswith(prefix)
            ),
            None,
        )
        patterns = module_patterns(path) if path.endswith(".py") else []

        def references(text: str) -> bool:
            if directory_token is not None:
                return directory_token in text
            if path.endswith(".py"):
                return any(pattern.search(text) for pattern in patterns)
            return path in text

        groups: set[str] = set()
        for test_file, test_groups in self.file_groups.items():
            if references(self.texts[test_file]):
                groups |= test_groups
        return groups


def is_zero(path: str) -> bool:
    if path in ZERO_PATHS:
        return True
    if path in BACKEND_OPS_PATHS or path.startswith(BACKEND_OPS_PREFIXES):
        return False
    return path.startswith(ZERO_PREFIXES)


def classify(path: str, routing: Routing) -> tuple[set[str] | None, str]:
    """Groups for one changed path; None means unmapped (fail safe to full)."""
    if path in FULL_PATHS:
        return None, "full-suite trigger"
    if path in routing.file_groups:
        return set(routing.file_groups[path]), "routed test file"
    groups = routing.referencing_groups(path)
    if path.startswith(".github/workflows/"):
        return groups | {WORKFLOW_CONTRACT_GROUP}, "workflow contract"
    if groups:
        return groups, "referenced by routed tests"
    if is_zero(path):
        return set(), "no Linux ops group reads it"
    return None, "unmapped"


def full_plan(linux: list[str], reason: str) -> dict:
    return {
        "mode": "full",
        "reason": reason,
        "groups": linux,
        "group_count": len(linux),
        "shard_count": FULL_SHARD_COUNT,
        "decisions": {},
    }


def targeted_plan(paths: list[str], routing: Routing, linux: list[str]) -> dict:
    decisions: dict[str, list[str]] = {}
    selected: set[str] = set()
    for path in paths:
        groups, reason = classify(path, routing)
        if groups is None:
            return full_plan(linux, f"unmapped path {path} ({reason})")
        undeclared = groups - routing.declared
        if undeclared:
            raise PlanError(f"{path} maps to undeclared groups {sorted(undeclared)}")
        decisions[path] = sorted(groups)
        selected |= groups
        print(f"plan: {path} ({reason}) -> {sorted(groups) or 'none'}", file=sys.stderr)
    # Non-Linux groups (macOS native) run in the unchanged macOS job, not here.
    linux_selected = {group for group in selected if group in linux}
    if linux_selected:
        linux_selected |= set(CONTRACT_GROUPS)
        if any(path.startswith(".github/workflows/") for path in paths):
            linux_selected.add(WORKFLOW_CONTRACT_GROUP)
    ordered = [group for group in linux if group in linux_selected]
    return {
        "mode": "targeted",
        "reason": "targeted by changed paths",
        "groups": ordered,
        "group_count": len(ordered),
        "shard_count": min(TARGETED_MAX_SHARDS, len(ordered)),
        "decisions": decisions,
    }


def git_paths(base: str, head: str) -> list[str]:
    if not (SHA.fullmatch(base) and SHA.fullmatch(head)):
        raise PlanError("base and head must be exact 40-character commit SHAs")
    merge_base = subprocess.run(
        ["git", "merge-base", base, head],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    diff = subprocess.run(
        ["git", "diff", "--name-only", merge_base, head],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [line for line in diff.splitlines() if line]


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--scope", choices=["full", "targeted"], default="full")
    parser.add_argument(
        "--paths-stdin", action="store_true", help="read changed paths from stdin"
    )
    parser.add_argument("--base", default="", help="exact base commit (targeted)")
    parser.add_argument("--head", default="", help="exact head commit (targeted)")
    args = parser.parse_args()

    linux = linux_groups()
    if args.scope == "full":
        result = full_plan(linux, "full scope")
    else:
        try:
            if args.paths_stdin:
                paths = [line.strip() for line in sys.stdin if line.strip()]
            elif args.base and args.head:
                paths = git_paths(args.base, args.head)
            else:
                raise PlanError("targeted scope needs --base/--head or --paths-stdin")
            if not paths:
                raise PlanError("empty change set")
            result = targeted_plan(paths, Routing(), linux)
        except (PlanError, subprocess.CalledProcessError, OSError, ValueError) as exc:
            print(f"plan: fail-safe to full: {exc}", file=sys.stderr)
            result = full_plan(linux, f"fail-safe: {exc}")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
