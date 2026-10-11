"""Structured file ownership declarations for local worktrees.

GitHub owns product work items and delivery state.  A local worktree still needs
an explicit file scope so parallel agents can detect overlap without guessing from
prose or from a diff produced after the fact.
"""

from __future__ import annotations

import difflib
import json
import posixpath
from collections.abc import Iterable
from pathlib import PurePosixPath

SCOPE_SCHEMA = "kg.worktree.scope.v1"
SCOPE_OPERATIONS = ("add", "modify", "delete")
# Exact repo paths every lane tends to touch and whose concurrent edits are
# trivially resolved at rebase.  They are recorded in Scope like any other file
# but never make two lanes conflict at admission.  Everything not listed here
# stays exclusive; no globs.  Each entry needs a justification in
# docs/reference/delivery_model.md (enforced by test_worktree_shared_scope.py):
#   docs/reference/tech_index.md, docs/registry.yml - append-only indexes.
#   ops/complexity_budget.json                      - base ceilings.  A lane's raise is its own
#     exclusive fragment in ops/complexity_budget.d/; only CM fold/ratchet and
#     pre-fragment lanes still edit this line (rebase resolves it, see deliver.py).
#   ops/test_ops.sh, ops/tests/test_ops_ci_coverage.sh - test-group
#     registration: each lane adds or drops one group line in its own case arm
#     or list entry; a true textual conflict is resolved at rebase and the
#     merge queue re-tests the combined tree.
#   ios/BooksAndVocab/*.lproj/Localizable.strings - per-locale key catalogs.
#     Lanes usually add different keys; a same-key or write-skew collision
#     (duplicate key, key deleted while another lane uses it) is re-checked by
#     the merge-group strict i18n lint on the combined tree (CM decision, 2026-10-11).
SHARED_SCOPE_FILES = frozenset(
    {
        "docs/reference/tech_index.md",
        "docs/registry.yml",
        "ops/complexity_budget.json",
        "ops/test_ops.sh",
        "ops/tests/test_ops_ci_coverage.sh",
        "ios/BooksAndVocab/en.lproj/Localizable.strings",
        "ios/BooksAndVocab/ja.lproj/Localizable.strings",
        "ios/BooksAndVocab/ko.lproj/Localizable.strings",
        "ios/BooksAndVocab/zh-Hans.lproj/Localizable.strings",
        "ios/BooksAndVocab/zh-Hant.lproj/Localizable.strings",
    }
)
# Spellings agents reach for naturally; canonicalised on input, never stored.
SCOPE_OPERATION_ALIASES = {"create": "add", "new": "add"}


def exclusive_paths(paths: Iterable[str]) -> set[str]:
    """Return the paths that stay exclusive, i.e. not in SHARED_SCOPE_FILES."""
    return set(paths) - SHARED_SCOPE_FILES


def overlap_paths(left: Iterable[str], right: Iterable[str]) -> set[str]:
    """The one overlap rule: contested paths between two claims or change sets.

    Every gate that decides "do these two lanes collide" (registry admission,
    Issue admission, publish preflight, delivery inspect, reanchor) must go
    through this so the SHARED_SCOPE_FILES exemption applies uniformly.
    """
    return exclusive_paths(set(left) & set(right))


def _normalise_path(value: object) -> tuple[str | None, str | None]:
    if not isinstance(value, str) or not value.strip():
        return None, "path must be a non-empty string"
    path = value.strip()
    if "\x00" in path:
        return None, "path contains NUL"
    if "\\" in path:
        return None, "path must use / separators"
    if path.startswith("/") or PurePosixPath(path).is_absolute():
        return None, "path must be relative to the repository"
    if path.endswith("/"):
        return None, "path must identify a file, not a directory"
    parts = path.split("/")
    if any(part in ("", "..") for part in parts):
        return None, "path must not contain empty or parent components"
    normalised = posixpath.normpath(path)
    if normalised in ("", ".", "..") or normalised.startswith("../"):
        return None, "path must identify a repository file"
    return normalised, None


def scope_problems(value: object) -> list[dict]:
    """Return named validation findings for a structured Scope."""
    if value in (None, ""):
        return []
    if not isinstance(value, dict):
        # Old registry records may contain prose.  They remain readable but do
        # not participate in file-overlap claims until explicitly replaced.
        return []
    problems: list[dict] = []
    schema = value.get("schema")
    if schema not in (None, SCOPE_SCHEMA):
        problems.append({"kind": "scope-unknown-schema", "schema": schema})
    files = value.get("files")
    if not isinstance(files, list) or not files:
        problems.append({"kind": "scope-files-empty"})
        return problems
    seen: set[str] = set()
    for index, item in enumerate(files):
        if not isinstance(item, dict):
            problems.append({"kind": "scope-file-not-object", "index": index})
            continue
        path, path_error = _normalise_path(item.get("path"))
        if path_error:
            problems.append(
                {
                    "kind": "scope-file-bad-path",
                    "index": index,
                    "path": item.get("path"),
                    "reason": path_error,
                }
            )
        elif path in seen:
            problems.append(
                {"kind": "scope-file-duplicate", "index": index, "path": path}
            )
        elif path is not None:
            seen.add(path)
        operation = item.get("operation")
        if operation not in SCOPE_OPERATIONS:
            problem = {
                "kind": "scope-file-bad-operation",
                "index": index,
                "operation": operation,
                "allowed": list(SCOPE_OPERATIONS),
            }
            close = difflib.get_close_matches(
                str(operation), SCOPE_OPERATIONS, n=1, cutoff=0.5
            )
            if close:
                problem["suggestion"] = close[0]
            problems.append(problem)
    return problems


def _canonical_operations(value: object) -> object:
    """Map accepted operation aliases (``create`` -> ``add``) on a copy."""
    if not isinstance(value, dict) or not isinstance(value.get("files"), list):
        return value
    files = [
        {
            **item,
            "operation": SCOPE_OPERATION_ALIASES.get(
                item["operation"], item["operation"]
            ),
        }
        if isinstance(item, dict) and isinstance(item.get("operation"), str)
        else item
        for item in value["files"]
    ]
    return {**value, "files": files}


def normalise_scope(value: object) -> dict:
    """Canonicalise a structured Scope or raise a named ``ValueError``."""
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid scope JSON: {exc.msg}") from exc
    value = _canonical_operations(value)
    problems = scope_problems(value)
    if problems:
        raise ValueError(f"invalid scope: {problems}")
    if not isinstance(value, dict):
        raise ValueError("invalid scope: expected an object with files[]")
    files = []
    for item in value["files"]:
        path, _ = _normalise_path(item["path"])
        files.append({"path": path, "operation": item["operation"]})
    return {"schema": SCOPE_SCHEMA, "files": files}


def coerce_scope(value: object) -> object:
    """Parse JSON-looking CLI values while preserving old prose records."""
    if isinstance(value, dict):
        return normalise_scope(value)
    if isinstance(value, list):
        raise ValueError("invalid scope: expected an object with files[]")
    if not isinstance(value, str):
        return value
    stripped = value.strip()
    if stripped.startswith(("{", "[")):
        return normalise_scope(stripped)
    return value


def scope_status(value: object) -> str:
    return (
        "known" if isinstance(value, dict) and not scope_problems(value) else "unknown"
    )


def scope_files(value: object) -> list[dict]:
    if scope_status(value) != "known":
        return []
    return [dict(item) for item in value["files"]]


_STATUS_OPERATIONS = {"A": "add", "M": "modify", "D": "delete", "T": "modify"}


def scope_from_name_status(text: str) -> dict:
    """`git diff --name-status -z` output -> a structured Scope.

    Input is NUL-delimited (status token, then one path, or two for R/C), so
    non-ASCII paths arrive raw instead of C-quoted. A rename is a delete of the
    old path plus an add of the new one, which is how Scope overlap has to see
    it. Empty tokens (a trailing NUL) are dropped.
    """
    files: list[dict[str, str]] = []
    tokens = [token for token in text.split("\0") if token]
    index = 0
    while index < len(tokens):
        status = tokens[index]
        code = status[0]
        width = 2 if code in "RC" else 1
        paths = tokens[index + 1 : index + 1 + width]
        if code not in "RC" and code not in _STATUS_OPERATIONS:
            raise ValueError(f"unrecognised git status {status!r} for {paths[:1]!r}")
        if len(paths) != width:
            raise ValueError(f"truncated git name-status entry {status!r}")
        index += 1 + width
        if code in "RC":
            if code == "R":
                files.append({"operation": "delete", "path": paths[0]})
            files.append({"operation": "add", "path": paths[1]})
        else:
            files.append({"operation": _STATUS_OPERATIONS[code], "path": paths[0]})
    return {"schema": SCOPE_SCHEMA, "files": files}
