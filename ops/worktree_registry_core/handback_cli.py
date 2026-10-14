"""Physical Git verification and typed handback command."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from .claims import claim_generation
from .constants import (
    COMMIT_SHA_RE,
    EXIT_OK,
    EXIT_PARTIAL,
    EXIT_USAGE,
    ORIGIN_MAIN_REF,
)
from .environment import git, load_state, resolve_now, state_path
from .handback import (
    GREEN_ACCEPTANCE_STATUSES,
    acceptance_status,
    has_valid_stored_handback,
    seal_body,
    seal_with_digest,
)
from .handback import (
    validate_handback_seal as validate_core_seal,
)
from .inspection import record_view
from .records import (
    SCHEMA,
    active_records,
    mutation_blockers_for_target,
    record_matches,
)
from .storage import ledger_lock, save_state


def load_outcomes(path: Path) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(payload, dict):
        payload = payload.get("outcomes")
    if not isinstance(payload, list) or any(
        not isinstance(item, dict) for item in payload
    ):
        raise ValueError("outcomes must be a JSON list of objects")
    return [dict(item) for item in payload]


def is_commit_sha(value: object) -> bool:
    return isinstance(value, str) and COMMIT_SHA_RE.fullmatch(value) is not None


def validate_handback_seal(
    record: dict[str, Any],
    *,
    repo: Path | None = None,
    require_green: bool = True,
) -> list[dict[str, Any]]:
    del repo
    problems = validate_core_seal(record, require_green=require_green)
    seal = record.get("handback_seal")
    if not isinstance(seal, dict):
        return problems
    body = {key: value for key, value in seal.items() if key != "digest"}
    origin_main_sha = body.get("origin_main_sha")
    if origin_main_sha is not None and not is_commit_sha(origin_main_sha):
        problems.append({"kind": "handback-origin-main-sha-invalid"})
    return problems


def has_valid_stored(record: dict[str, Any]) -> bool:
    return has_valid_stored_handback(record, is_commit_sha=is_commit_sha)


def has_valid_physical(record: dict[str, Any]) -> bool:
    if not has_valid_stored(record):
        return False
    branch = str(record["branch"])
    handed_back_sha = str(record["handed_back_sha"])
    worktree = Path(str(record["path"]))
    if not worktree.is_dir():
        return False
    branch_rc, current_branch = git(["branch", "--show-current"], worktree)
    if branch_rc != 0 or current_branch != branch:
        return False
    dirty_rc, dirty = git(["status", "--porcelain=v1"], worktree)
    if dirty_rc != 0 or dirty:
        return False
    head_rc, current_head = git(["rev-parse", "--verify", "HEAD^{commit}"], worktree)
    return head_rc == 0 and current_head == handed_back_sha


def live_origin_main_sha(worktree: Path) -> str | None:
    rc, output = git(["ls-remote", "origin", ORIGIN_MAIN_REF], worktree)
    if rc != 0:
        return None
    rows = [line.split() for line in output.splitlines() if line.strip()]
    if len(rows) != 1:
        return None
    fields = rows[0]
    if len(fields) != 2 or fields[1] != ORIGIN_MAIN_REF or not is_commit_sha(fields[0]):
        return None
    return fields[0]


def declared_base_sha(record: dict[str, Any], worktree: Path) -> str | None:
    base_sha = record.get("base_sha")
    if base_sha is not None:
        return base_sha if is_commit_sha(base_sha) else None
    base_ref = record.get("base", "main")
    if not isinstance(base_ref, str) or not base_ref.strip():
        return None
    rc, resolved = git(["rev-parse", f"{base_ref}^{{commit}}"], worktree)
    return resolved if rc == 0 and is_commit_sha(resolved) else None


def is_ancestor(worktree: Path, ancestor: str, descendant: str) -> bool:
    rc, _ = git(["merge-base", "--is-ancestor", ancestor, descendant], worktree)
    return rc == 0


def ensure_commit_available(worktree: Path, sha: str) -> bool:
    rc, _ = git(["cat-file", "-e", f"{sha}^{{commit}}"], worktree)
    if rc == 0:
        return True
    fetch_rc, _ = git(["fetch", "--quiet", "--no-tags", "origin", sha], worktree)
    if fetch_rc != 0:
        return False
    verify_rc, _ = git(["cat-file", "-e", f"{sha}^{{commit}}"], worktree)
    return verify_rc == 0


def cmd_hand_back(args: argparse.Namespace) -> int:
    target = state_path(args)
    with ledger_lock(target):
        state = load_state(target)
        matches = [
            record
            for record in active_records(state)
            if record_matches(record, branch=args.branch, path=args.path)
        ]
        if len(matches) != 1:
            print(
                json.dumps(
                    {
                        "schema": SCHEMA,
                        "action": "refused",
                        "reason": "hand-back selector must match exactly one active worktree",
                    },
                    ensure_ascii=False,
                )
            )
            return EXIT_USAGE
        record = matches[0]
        blockers = mutation_blockers_for_target(
            state,
            branch=record.get("branch"),
            path=record.get("path"),
            external_ids_value=record.get("external_ids"),
            scope=record.get("scope"),
        )
        if blockers:
            print(
                "✗ malformed ownership facts block registry mutation",
                file=sys.stderr,
            )
            return EXIT_PARTIAL
        worktree = Path(record["path"])
        if not worktree.is_dir():
            print(f"✗ registered worktree is missing: {worktree}", file=sys.stderr)
            return EXIT_PARTIAL
        rc, branch = git(["branch", "--show-current"], worktree)
        if rc != 0 or branch != record.get("branch"):
            print("✗ worktree branch does not match registry", file=sys.stderr)
            return EXIT_PARTIAL
        rc, tip_sha = git(["rev-parse", "--verify", "HEAD^{commit}"], worktree)
        if rc != 0 or not tip_sha:
            print("✗ cannot read worktree HEAD", file=sys.stderr)
            return EXIT_PARTIAL
        # One clock read for the whole hand-back: the seal and the record must
        # carry the identical timestamp or handback validation fails on a
        # whole-second boundary between two reads.
        _, now_iso = resolve_now(args.at)
        if args.outcomes:
            try:
                outcomes = load_outcomes(Path(args.outcomes).expanduser())
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                print(f"✗ outcomes unreadable: {exc}", file=sys.stderr)
                return EXIT_PARTIAL
            dirty_rc, dirty = git(["status", "--porcelain=v1"], worktree)
            if dirty_rc != 0 or dirty:
                print("✗ hand-back outcomes require a clean worktree", file=sys.stderr)
                return EXIT_PARTIAL
            base_sha = declared_base_sha(record, worktree)
            if not base_sha:
                print("✗ cannot determine the recorded base commit", file=sys.stderr)
                return EXIT_PARTIAL
            origin_main_sha = live_origin_main_sha(worktree)
            if not origin_main_sha:
                print("✗ cannot read live origin/main", file=sys.stderr)
                return EXIT_PARTIAL
            if not ensure_commit_available(worktree, origin_main_sha):
                print("✗ cannot fetch live origin/main commit", file=sys.stderr)
                return EXIT_PARTIAL
            if not is_ancestor(worktree, base_sha, origin_main_sha):
                print(
                    "✗ declared base is not an ancestor of live origin/main",
                    file=sys.stderr,
                )
                return EXIT_PARTIAL
            if not is_ancestor(worktree, base_sha, tip_sha):
                print(
                    "✗ declared base is not an ancestor of worktree HEAD",
                    file=sys.stderr,
                )
                return EXIT_PARTIAL
            normalized: list[dict[str, Any]] = []
            for item in outcomes:
                status = acceptance_status(item.get("status") or item.get("outcome"))
                if status not in GREEN_ACCEPTANCE_STATUSES:
                    print("✗ every hand-back outcome must be green", file=sys.stderr)
                    return EXIT_PARTIAL
                normalized.append(item)
            record["handback_seal"] = seal_with_digest(
                seal_body(
                    record,
                    base_sha=base_sha,
                    tip_sha=tip_sha,
                    outcomes=normalized,
                    handed_back_at=now_iso,
                    origin_main_sha=origin_main_sha,
                    initial_holds=list(args.hold or ()),
                )
            )
            record["handback_outcomes"] = normalized
        record["handed_back_at"] = now_iso
        record["handed_back_sha"] = tip_sha
        generation = claim_generation(record, "claim_generation")
        record["claim_generation"] = generation if generation is not None else 0
        record["handback_claim_generation"] = record["claim_generation"]
        save_state(target, state)
    payload = {"schema": SCHEMA, "action": "hand-back", "record": record_view(record)}
    print(
        json.dumps(payload, indent=2, ensure_ascii=False)
        if args.json
        else f"✓ handed back [{record.get('branch')}] @ {tip_sha[:12]}"
    )
    return EXIT_OK
