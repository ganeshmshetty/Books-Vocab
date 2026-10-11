"""Thin command surface for the deterministic delivery services."""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Mapping, Sequence
from dataclasses import asdict, is_dataclass, replace
from datetime import UTC, datetime, timedelta
from enum import Enum
from pathlib import Path
from typing import Any

from .adapters.operation_lock import WAIT_SECONDS_ENV, OperationLock
from .adapters.runtime import RuntimeStatusMap
from .application import DeliveryApplication, build_application
from .controller.metrics import measure_merge_cadence
from .controller.phase_readiness import (
    DogfoodMode,
    assess_phase_readiness,
    phase_next_actions,
)
from .domain.candidate_issues import CandidateSpec
from .domain.demand_issues import IssueIntakeRequest
from .domain.errors import DeliveryContractError, DeliverySourceError
from .domain.runtime_models import RuntimeReceipt, RuntimeState
from .domain.states import HoldKind
from .domain.unreachable_commits import UNREACHABLE_COMMIT_PATH_LIMIT
from .services.candidate_contract import parse_candidate_body, render_candidate_body
from .services.cleanup import OperationLease
from .services.pr_contract import validate_pull_request_body

COMMAND_SCHEMA = "kg.delivery.command.v1"
MAIN_PRESERVATION_COMMANDS = frozenset(
    {
        "preserve-main",
        "reconcile-main",
        "preserve-main-divergence",
        "reconcile-main-divergence",
    }
)
# Dry-run by default; only an explicit --apply writes (and takes the lock).
APPLY_COMMANDS = frozenset({"dispose-ownerless-claim", "close-terminal-issues"})
MUTATING_COMMANDS = frozenset(
    {
        "admit-candidate",
        "issue-intake",
        "watchdog-claim",
        "runtime-receipt",
        "receipt",
        "publish",
        "record-published-base",
        "release-published",
        "queue",
        "reconcile-holds",
        "repair-pr-metadata",
        "trigger-required",
        "cleanup-merged",
        "drain",
        "abandon-pr",
        "cleanup-abandoned",
        "discard-abandoned-handback",
        "supersede-abandoned-handback",
        "discard-orphan-branch",
        "discard-orphan-remote-branch",
        "discard-unregistered-branch",
        "sync-main",
        *MAIN_PRESERVATION_COMMANDS,
    }
)
# Mutations that take the operation lease only around their own registry and
# local worktree/ref sections (#2236), so GitHub API calls, ls-remote and push
# never hold it.  _run_command_serialized hands them a per-section lease on the
# same lock path.  queue writes only GitHub, guarded there by expected head,
# base and body readback; cleanup sections are resumable from cleanup_pending.
SCOPED_LEASE_COMMANDS = frozenset(
    {"queue", "cleanup-merged", "release-published", "publish", "drain"}
)
# queue holds no lease at all (GitHub-only, guarded by expectedHeadOid), so it
# never refuses on a busy lock.  The other scoped commands start with GitHub
# reads and must refuse at zero GitHub cost when the lease is busy (#2871).
BUSY_PROBE_COMMANDS = SCOPED_LEASE_COMMANDS - {"queue"}


# cleanup-merged is the observed starvation case (#2463): it follows a merge
# and must not be refused just because another delivery briefly holds the lease.
DEFAULT_LOCK_WAIT_SECONDS = {"cleanup-merged": 120.0}


def lock_wait_seconds(args: argparse.Namespace) -> float | None:
    """Flag > env var (resolved by OperationLock) > per-command default."""

    explicit = getattr(args, "lock_timeout", None)
    if explicit is not None:
        return explicit
    if os.environ.get(WAIT_SECONDS_ENV):
        return None
    return DEFAULT_LOCK_WAIT_SECONDS.get(args.command)


def _jsonable(value: object) -> object:
    if is_dataclass(value):
        return _jsonable(asdict(value))
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, Mapping):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (tuple, list, set, frozenset)):
        return [_jsonable(item) for item in value]
    return value


def _watchdog_runtime_status_epilog(command: str) -> str:
    runtime_status_contract = (
        "Required global option: --runtime-status-file PATH; "
        f"place it before the {command} subcommand."
    )
    if command == "watchdog":
        return (
            f"{runtime_status_contract} This is a read-only observation; "
            "verdict=observation, dispatch_authorized=false, exit 2; "
            "it never authorizes wake or dispatch; must not retry or wake."
        )
    return (
        f"{runtime_status_contract} only "
        "verdict=wake-authorized, action=wake, wake_claimed=true, "
        "dispatch_authorized=true may exit 0 "
        "and authorize one session; "
        "noop/escalate/wake_claimed=false/claim conflict are valid no-wake "
        "observations with ok=true, verdict=no-wake, exit 2; "
        "must not retry or wake."
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Deterministic KG delivery control plane"
    )
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--runtime-status-file", type=Path)
    parser.add_argument(
        "--lock-timeout",
        type=float,
        metavar="SECONDS",
        help=(
            "wait up to SECONDS (capped at 3600) for the delivery mutation lease "
            "instead of refusing at once; overrides KG_DELIVERY_LOCK_WAIT_SECONDS "
            "(cleanup-merged waits 120s by default)"
        ),
    )
    commands = parser.add_subparsers(dest="command", required=True)

    inspect = commands.add_parser("inspect", help="classify every known delivery lane")
    inspect.add_argument(
        "--supervision-worktree",
        action="append",
        type=Path,
        default=[],
        help="exact supervision checkout path; repeat once per checkout",
    )
    commands.add_parser(
        "issue-inventory", help="inventory every open GitHub Issue without mutation"
    )
    commands.add_parser(
        "triage-plan", help="derive a deterministic raw Issue triage plan"
    )
    branch_audit = commands.add_parser(
        "branch-audit",
        help="audit every local/remote branch against registry, PR, and worktree facts",
    )
    branch_audit.add_argument(
        "--supervision-worktree",
        action="append",
        type=Path,
        default=[],
        help="exact supervision checkout path; repeat once per checkout",
    )
    branch_inspect = commands.add_parser(
        "branch-inspect",
        help="inspect one local branch's unlanded content without mutation",
    )
    branch_inspect.add_argument("--branch", required=True)
    branch_inspect.add_argument("--expected-head-sha")
    unreachable_inspect = commands.add_parser(
        "unreachable-commit-inspect",
        help="inspect one unreachable commit object without mutation",
    )
    unreachable_inspect.add_argument("--commit", required=True)
    unreachable_inspect.add_argument(
        "--max-paths",
        type=int,
        default=UNREACHABLE_COMMIT_PATH_LIMIT,
        metavar="N",
        help=(
            f"bounded changed-path output (1 <= N <= {UNREACHABLE_COMMIT_PATH_LIMIT})"
        ),
    )
    branch_review_plan = commands.add_parser(
        "branch-review-plan",
        help="page blocked local-orphan content for read-only review",
    )
    branch_review_plan.add_argument(
        "--offset",
        type=int,
        default=0,
        metavar="N",
        help="zero-based page offset (N >= 0)",
    )
    branch_review_plan.add_argument(
        "--limit",
        type=int,
        default=5,
        metavar="N",
        help="page size (1 <= N <= 20)",
    )
    metrics = commands.add_parser("metrics", help="measure current queue reservoirs")
    metrics.add_argument(
        "--supervision-worktree",
        action="append",
        type=Path,
        default=[],
        help="exact supervision checkout path; repeat once per checkout",
    )
    plan = commands.add_parser("plan", help="derive the next capacity actions")
    plan.add_argument(
        "--supervision-worktree",
        action="append",
        type=Path,
        default=[],
        help="exact supervision checkout path; repeat once per checkout",
    )
    dogfood = commands.add_parser(
        "dogfood-preflight", help="verify the four-role canary launch baseline"
    )
    dogfood.add_argument(
        "--supervision-worktree",
        action="append",
        type=Path,
        default=[],
        help="exact supervision checkout path; repeat once per checkout",
    )
    dogfood.add_argument(
        "--mode",
        choices=tuple(mode.value for mode in DogfoodMode),
        default=None,
        help=(
            "explicit phase observation: qualification, pilot, ramp, or steady; "
            "this flag belongs after dogfood-preflight and never grants mutation authority"
        ),
    )
    dogfood.add_argument(
        "--direct-assignment",
        action="store_true",
        help=(
            "observe an already-authorized bounded direct-assignment packet; "
            "this never creates a lane or grants mutation authority"
        ),
    )
    watchdog = commands.add_parser(
        "watchdog",
        help="read liveness and return a non-dispatching wake decision",
        epilog=_watchdog_runtime_status_epilog("watchdog"),
    )
    watchdog.add_argument("--supervisor-thread", required=True)
    watchdog.add_argument("--stale-after-seconds", type=int, default=300)
    watchdog_claim = commands.add_parser(
        "watchdog-claim",
        help="atomically claim one stale wake before external scheduler dispatch",
        epilog=_watchdog_runtime_status_epilog("watchdog-claim"),
    )
    watchdog_claim.add_argument("--supervisor-thread", required=True)
    watchdog_claim.add_argument("--stale-after-seconds", type=int, default=300)

    runtime_receipt = commands.add_parser(
        "runtime-receipt",
        help="atomically publish one caller-owned runtime liveness receipt",
    )
    runtime_receipt.add_argument("--thread-id", required=True)
    runtime_receipt.add_argument(
        "--state", required=True, choices=tuple(item.value for item in RuntimeState)
    )
    runtime_receipt.add_argument("--cycle-id", required=True)
    runtime_receipt.add_argument("--last-action-id")
    runtime_receipt.add_argument("--clear-last-action", action="store_true")
    runtime_receipt.add_argument("--expected-cycle-id")
    runtime_receipt.add_argument("--lease-seconds", type=int)
    runtime_receipt.add_argument("--lease-until")
    runtime_receipt.add_argument("--expected-next-event-at")
    runtime_receipt.add_argument("--last-progress-at")
    runtime_receipt.add_argument("--observed-at")

    validate = commands.add_parser(
        "validate-pr-body", help="validate one durable PR receipt"
    )
    validate.add_argument("--head-sha", required=True)
    validate.add_argument("--body-file", type=Path, default=Path("-"))
    validate.add_argument(
        "--head-ref",
        help="actual PR head branch; an issue-<N> branch must link that Issue",
    )

    render_candidate = commands.add_parser(
        "render-candidate-body",
        help="render one canonical dispatchable candidate Issue body",
    )
    render_candidate.add_argument("--payload-file", type=Path, default=Path("-"))

    validate_candidate = commands.add_parser(
        "validate-candidate-body",
        help="validate one dispatchable candidate Issue body",
    )
    validate_candidate.add_argument("--body-file", type=Path, default=Path("-"))

    admit_candidate = commands.add_parser(
        "admit-candidate",
        help="admit exactly one triaged Issue as a typed candidate",
    )
    admit_candidate.add_argument("--issue", type=int, required=True)
    admit_candidate.add_argument("--expected-updated-at", required=True)
    admit_candidate.add_argument("--expected-body-sha256", required=True)
    admit_candidate.add_argument("--payload-file", type=Path, default=Path("-"))
    admit_candidate.add_argument("--triage-reason", required=True)
    admit_candidate.add_argument("--operator", required=True)

    issue_intake = commands.add_parser(
        "issue-intake",
        help="create exactly one raw GitHub Issue; does not admit a candidate",
    )
    issue_intake.add_argument("--payload-file", type=Path, default=Path("-"))

    receipt = commands.add_parser("receipt", help="normalize one active handback")
    receipt.add_argument("--lane", required=True)

    publish = commands.add_parser("publish", help="publish and release one handback")
    publish.add_argument("--lane", required=True)
    publish.add_argument("--title", required=True)
    publish.add_argument("--closes", type=int, action="append", metavar="N")
    publish.add_argument("--refs", type=int, action="append", metavar="N")
    publish.add_argument(
        "--replaces-pr",
        type=int,
        help="open PR that redeliver closes after this publication; "
        "excluded from the Scope collision check only",
    )

    published_base = commands.add_parser(
        "record-published-base",
        help="persist the exact GitHub PR base for one durable published lane",
    )
    published_base.add_argument("--pr", type=int, required=True)

    release = commands.add_parser(
        "release-published", help="retry local release after durable PR publication"
    )
    release.add_argument("--pr", type=int, required=True)

    queue = commands.add_parser("queue", help="admit one exact PR to merge queue")
    queue.add_argument("--pr", type=int, required=True)
    queue.add_argument(
        "--hold", action="append", choices=tuple(item.value for item in HoldKind)
    )

    reconcile_holds = commands.add_parser(
        "reconcile-holds", help="rewrite typed PR holds after explicit clearance"
    )
    reconcile_holds.add_argument("--pr", type=int, required=True)
    hold_choice = reconcile_holds.add_mutually_exclusive_group(required=True)
    hold_choice.add_argument(
        "--hold", action="append", choices=tuple(item.value for item in HoldKind)
    )
    hold_choice.add_argument("--clear-all", action="store_true")

    repair_metadata = commands.add_parser(
        "repair-pr-metadata",
        help="restore canonical body metadata on one durable PR",
    )
    repair_metadata.add_argument("--pr", type=int, required=True)

    drain = commands.add_parser(
        "drain",
        help="one process: enqueue gate-green published PRs, clean up merged ones",
    )
    drain.add_argument(
        "--once", action="store_true", help="run a single cycle instead of looping"
    )
    drain.add_argument(
        "--dry-run",
        action="store_true",
        help="plan one cycle and execute nothing",
    )
    drain.add_argument(
        "--interval", type=float, default=30.0, help="seconds between cycles"
    )
    drain.add_argument(
        "--timeout", type=float, default=3600.0, help="stop looping after SECONDS"
    )

    commands.add_parser(
        "trigger-required", help="dispatch required checks for one exact published PR"
    ).add_argument("--pr", type=int, required=True)

    cleanup = commands.add_parser(
        "cleanup-merged", help="remove exact merged branch residue"
    )
    cleanup.add_argument("--pr", type=int, required=True)
    abandon = commands.add_parser(
        "abandon-pr",
        help="close and terminalize one exact post-publication PR",
    )
    abandon.add_argument("--pr", type=int, required=True)
    cleanup_abandoned = commands.add_parser(
        "cleanup-abandoned",
        help="remove exact abandoned branch residue with no PR history",
    )
    cleanup_abandoned.add_argument("--branch", required=True)
    discard_handback = commands.add_parser(
        "discard-abandoned-handback",
        help="discard one exact ownerless abandoned handback after CAS preflight",
    )
    discard_handback.add_argument("--branch", required=True)
    discard_handback.add_argument("--expected-head-sha", required=True)
    discard_handback.add_argument("--operator", required=True)
    discard_handback.add_argument("--reason", required=True)
    supersede_handback = commands.add_parser(
        "supersede-abandoned-handback",
        help="terminalize one abandoned handback proven equivalent to one merged PR",
    )
    supersede_handback.add_argument("--branch", required=True)
    supersede_handback.add_argument("--expected-head-sha", required=True)
    supersede_handback.add_argument("--operator", required=True)
    supersede_handback.add_argument("--reason", required=True)
    discard_orphan = commands.add_parser(
        "discard-orphan-branch",
        help="discard one unregistered local branch already contained in main",
    )
    discard_orphan.add_argument("--branch", required=True)
    discard_orphan.add_argument("--expected-head-sha", required=True)
    discard_orphan.add_argument("--operator", required=True)
    discard_orphan.add_argument("--reason", required=True)
    discard_remote_orphan = commands.add_parser(
        "discard-orphan-remote-branch",
        help="discard one unregistered remote branch already contained in main",
    )
    discard_remote_orphan.add_argument("--branch", required=True)
    discard_remote_orphan.add_argument("--expected-head-sha", required=True)
    discard_remote_orphan.add_argument("--operator", required=True)
    discard_remote_orphan.add_argument("--reason", required=True)
    discard_unregistered = commands.add_parser(
        "discard-unregistered-branch",
        help="discard one explicitly reviewed unlanded local-only branch",
    )
    discard_unregistered.add_argument("--branch", required=True)
    discard_unregistered.add_argument("--expected-head-sha", required=True)
    discard_unregistered.add_argument("--expected-content-fingerprint", required=True)
    discard_unregistered.add_argument("--operator", required=True)
    discard_unregistered.add_argument("--reason", required=True)
    discard_unregistered.add_argument(
        "--confirm-unmerged",
        action="store_true",
        help="confirm that unlanded local commits may be discarded",
    )
    preserve_main = commands.add_parser(
        "preserve-main",
        aliases=(
            "reconcile-main",
            "preserve-main-divergence",
            "reconcile-main-divergence",
        ),
        help="preserve one owner-bound local main tip and CAS-park canonical main",
    )
    preserve_main.add_argument(
        "--expected-local-head",
        "--expected-local-sha",
        dest="expected_local_head",
        required=True,
    )
    preserve_main.add_argument(
        "--expected-origin-head",
        "--expected-origin-sha",
        dest="expected_origin_head",
        required=True,
    )
    preserve_main.add_argument("--preservation-branch", required=True)
    preserve_main.add_argument("--preservation-path", type=Path, required=True)
    preserve_main.add_argument(
        "--owner-thread-id",
        "--owner",
        dest="owner_thread_id",
        required=True,
    )
    preserve_main.add_argument("--external-id", required=True)
    preserve_main.add_argument("--operator", required=True)
    preserve_main.add_argument("--reason", required=True)
    dispose_claim = commands.add_parser(
        "dispose-ownerless-claim",
        help=(
            "dry-run by default: terminalize one ownerless active claim that has "
            "no worktree, PR history, handback, remote drift, or hold"
        ),
    )
    dispose_claim.add_argument("--branch", required=True)
    dispose_claim.add_argument(
        "--apply",
        action="store_true",
        help="write; requires the pins from a prior dry-run plus operator/reason",
    )
    dispose_claim.add_argument("--expected-claim-generation", type=int)
    dispose_claim.add_argument("--expected-head-sha")
    dispose_claim.add_argument("--operator")
    dispose_claim.add_argument("--reason")
    close_issues = commands.add_parser(
        "close-terminal-issues",
        help=(
            "dry-run by default: close open Issues whose terminal_history has "
            "merged/duplicate/terminal evidence (IM only)"
        ),
    )
    close_issues.add_argument(
        "--apply",
        action="store_true",
        help="close with --reason completed, an evidence comment, and readback",
    )
    close_issues.add_argument("--operator")
    close_issues.add_argument(
        "--issue",
        action="append",
        type=int,
        default=[],
        dest="issues",
        metavar="N",
        help="limit to this Issue number; repeatable",
    )
    commands.add_parser("sync-main", help="ff-only synchronize canonical main")
    return parser


def run_command(
    args: argparse.Namespace,
    application: DeliveryApplication,
    *,
    operation_lease: OperationLease | None = None,
) -> object:
    if args.command == "inspect":
        return application.inspect(
            supervision_worktree_paths=tuple(args.supervision_worktree)
        )
    if args.command == "issue-inventory":
        inventory = application.issue_inventory()
        return {
            "schema": "kg.delivery.issue-inventory.v1",
            "raw_total": inventory.raw_open_issues,
            "partition_totals": inventory.disposition_counts,
            "unadmitted_open_issues": inventory.unadmitted_open_issues,
            "backlog_drained": inventory.backlog_drained,
            "complete": inventory.complete,
            "source_problems": inventory.problems,
            "source_entries": inventory.source_entries,
            "issues": inventory.records,
        }
    if args.command == "triage-plan":
        return {
            "schema": "kg.delivery.triage-plan.v1",
            "items": application.triage_plan(),
            "source_entries": application.issue_inventory().source_entries,
        }
    if args.command == "branch-audit":
        return application.branch_audit(
            supervision_worktree_paths=tuple(args.supervision_worktree)
        )
    if args.command == "branch-inspect":
        return application.branch_inspect(
            branch=args.branch,
            expected_head_sha=args.expected_head_sha,
        )
    if args.command == "unreachable-commit-inspect":
        return application.unreachable_commit_inspect(
            commit_sha=args.commit,
            max_paths=args.max_paths,
        )
    if args.command == "branch-review-plan":
        return application.branch_review_plan(offset=args.offset, limit=args.limit)
    if args.command == "metrics":
        return application.metrics(
            supervision_worktree_paths=tuple(args.supervision_worktree)
        )
    if args.command == "plan":
        result = application.plan(
            supervision_worktree_paths=tuple(args.supervision_worktree)
        )
        if not isinstance(result, Mapping):
            return result
        metrics = result.get("metrics")
        if metrics is None:
            return result
        classified = (
            None
            if not getattr(metrics, "issue_inventory_complete", False)
            or getattr(metrics, "raw_open_issues", None) is None
            or getattr(metrics, "unadmitted_open_issues", None) is None
            else True
        )
        return {
            **result,
            "backlog_classified": classified,
            "next_actions": phase_next_actions(
                metrics,
                backlog_classified=classified,
            ),
        }
    if args.command == "dogfood-preflight":
        mode = getattr(args, "mode", None)
        observed_at = application.clock() if mode == DogfoodMode.STEADY.value else None
        dogfood_kwargs = {
            "supervision_worktree_paths": tuple(args.supervision_worktree)
        }
        if observed_at is not None:
            dogfood_kwargs["now"] = observed_at
        base_readiness = application.dogfood_preflight(**dogfood_kwargs)
        if mode is None:
            return base_readiness
        selected_mode = DogfoodMode(mode)
        if selected_mode is DogfoodMode.STEADY:
            cadence_now = observed_at or application.clock()
            cadence = measure_merge_cadence(
                application.github.recent_merge_times(),
                now=cadence_now,
                window=timedelta(hours=1),
            )
            base_readiness = replace(base_readiness, cadence=cadence)
        return assess_phase_readiness(
            base_readiness,
            mode=selected_mode,
            direct_assignment_available=bool(getattr(args, "direct_assignment", False)),
        )
    if args.command == "watchdog":
        if args.runtime_status_file is None:
            raise DeliveryContractError("watchdog requires --runtime-status-file")
        return application.watchdog(
            supervisor_thread_id=args.supervisor_thread,
            stale_after_seconds=args.stale_after_seconds,
        )
    if args.command == "watchdog-claim":
        if args.runtime_status_file is None:
            raise DeliveryContractError("watchdog-claim requires --runtime-status-file")
        return application.watchdog_claim(
            supervisor_thread_id=args.supervisor_thread,
            stale_after_seconds=args.stale_after_seconds,
        )
    if args.command == "runtime-receipt":
        if args.clear_last_action and args.last_action_id is not None:
            raise DeliveryContractError(
                "runtime receipt cannot both clear and set last_action_id"
            )
        observed_at = _runtime_timestamp(args.observed_at, "observed_at")
        if observed_at is None:
            observed_at = datetime.now(UTC)
        last_progress_at = (
            _runtime_timestamp(args.last_progress_at, "last_progress_at") or observed_at
        )
        lease_until = _runtime_timestamp(args.lease_until, "lease_until")
        if args.lease_seconds is not None:
            if args.lease_seconds <= 0:
                raise DeliveryContractError("lease_seconds must be positive")
            if lease_until is not None:
                raise DeliveryContractError(
                    "runtime receipt cannot set lease_until and lease_seconds"
                )
            lease_until = observed_at + timedelta(seconds=args.lease_seconds)
        expected_next_event_at = _runtime_timestamp(
            args.expected_next_event_at, "expected_next_event_at"
        )
        last_action_id = args.last_action_id
        if last_action_id is None and not args.clear_last_action:
            current = application.runtime.runtime_receipt(args.thread_id)
            last_action_id = current.last_action_id if current is not None else None
        receipt = RuntimeReceipt(
            thread_id=args.thread_id,
            state=RuntimeState(args.state),
            last_progress_at=last_progress_at,
            observed_at=observed_at,
            lease_until=lease_until,
            expected_next_event_at=expected_next_event_at,
            cycle_id=args.cycle_id,
            last_action_id=last_action_id,
        )
        return application.write_runtime_receipt(
            receipt=receipt,
            expected_cycle_id=args.expected_cycle_id,
        )
    if args.command == "validate-pr-body":
        body = (
            sys.stdin.read()
            if args.body_file == Path("-")
            else args.body_file.read_text(encoding="utf-8")
        )
        return validate_pull_request_body(
            body, expected_head_sha=args.head_sha, head_ref=args.head_ref
        )
    if args.command == "render-candidate-body":
        raw = (
            sys.stdin.read()
            if args.payload_file == Path("-")
            else args.payload_file.read_text(encoding="utf-8")
        )
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise DeliveryContractError("candidate payload is invalid JSON") from error
        if not isinstance(payload, Mapping):
            raise DeliveryContractError("candidate payload must be an object")
        try:
            spec = CandidateSpec.from_payload(payload)
        except ValueError as error:
            raise DeliveryContractError(str(error)) from error
        return {"body": render_candidate_body(spec), "contract": spec}
    if args.command == "validate-candidate-body":
        body = (
            sys.stdin.read()
            if args.body_file == Path("-")
            else args.body_file.read_text(encoding="utf-8")
        )
        return parse_candidate_body(body)
    if args.command == "admit-candidate":
        raw = (
            sys.stdin.read()
            if args.payload_file == Path("-")
            else args.payload_file.read_text(encoding="utf-8")
        )
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise DeliveryContractError("candidate payload is invalid JSON") from error
        if not isinstance(payload, Mapping):
            raise DeliveryContractError("candidate payload must be an object")
        try:
            spec = CandidateSpec.from_payload(payload)
        except (TypeError, ValueError) as error:
            raise DeliveryContractError(str(error)) from error
        expected_updated_at = _runtime_timestamp(
            args.expected_updated_at, "expected_updated_at"
        )
        if expected_updated_at is None:
            raise DeliveryContractError("expected_updated_at is required")
        return application.admit_candidate(
            issue_number=args.issue,
            expected_updated_at=expected_updated_at,
            expected_body_sha256=args.expected_body_sha256,
            spec=spec,
            triage_reason=args.triage_reason,
            operator=args.operator,
        )
    if args.command == "issue-intake":
        raw = (
            sys.stdin.read()
            if args.payload_file == Path("-")
            else args.payload_file.read_text(encoding="utf-8")
        )
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise DeliveryContractError(
                "issue intake payload is invalid JSON"
            ) from error
        try:
            request = IssueIntakeRequest.from_payload(payload)
        except (TypeError, ValueError) as error:
            raise DeliveryContractError(str(error)) from error
        return application.create_issue(request=request)
    if args.command == "receipt":
        return application.receipt(args.lane)
    if args.command == "publish":
        return application.publish(
            lane_id=args.lane,
            title=args.title,
            closes=args.closes,
            refs=args.refs,
            replaced_pr=args.replaces_pr,
            operation_lease=operation_lease,
        )
    if args.command == "record-published-base":
        return application.record_published_base(args.pr)
    if args.command == "release-published":
        return application.release_published(args.pr, operation_lease=operation_lease)
    if args.command == "queue":
        return application.enqueue(
            pull_request_number=args.pr,
            holds=frozenset(HoldKind(item) for item in args.hold or ()),
        )
    if args.command == "drain":
        return application.drain(
            once=args.once,
            dry_run=args.dry_run,
            interval=args.interval,
            timeout=args.timeout,
            operation_lease=operation_lease,
        )
    if args.command == "reconcile-holds":
        return application.reconcile_holds(
            pull_request_number=args.pr,
            holds=frozenset(HoldKind(item) for item in args.hold or ()),
            clear_all=args.clear_all,
        )
    if args.command == "repair-pr-metadata":
        return application.repair_metadata(args.pr)
    if args.command == "trigger-required":
        return application.trigger_required(args.pr)
    if args.command == "cleanup-merged":
        return application.cleanup_merged(args.pr, operation_lease=operation_lease)
    if args.command == "abandon-pr":
        return application.abandon_pr(args.pr)
    if args.command == "cleanup-abandoned":
        return application.cleanup_abandoned(args.branch)
    if args.command == "discard-abandoned-handback":
        return application.discard_abandoned_handback(
            branch=args.branch,
            expected_head_sha=args.expected_head_sha,
            operator=args.operator,
            reason=args.reason,
        )
    if args.command == "supersede-abandoned-handback":
        return application.supersede_abandoned_handback(
            branch=args.branch,
            expected_head_sha=args.expected_head_sha,
            operator=args.operator,
            reason=args.reason,
        )
    if args.command == "discard-orphan-branch":
        return application.discard_orphan_branch(
            branch=args.branch,
            expected_head_sha=args.expected_head_sha,
            operator=args.operator,
            reason=args.reason,
        )
    if args.command == "discard-orphan-remote-branch":
        return application.discard_orphan_remote_branch(
            branch=args.branch,
            expected_head_sha=args.expected_head_sha,
            operator=args.operator,
            reason=args.reason,
        )
    if args.command == "discard-unregistered-branch":
        return application.discard_unregistered_branch(
            branch=args.branch,
            expected_head_sha=args.expected_head_sha,
            expected_content_fingerprint=args.expected_content_fingerprint,
            operator=args.operator,
            reason=args.reason,
            confirm_unmerged=args.confirm_unmerged,
        )
    if args.command == "dispose-ownerless-claim":
        return application.dispose_ownerless_claim(
            branch=args.branch,
            apply=args.apply,
            expected_claim_generation=args.expected_claim_generation,
            expected_head_sha=args.expected_head_sha,
            operator=args.operator,
            reason=args.reason,
            progress=_progress,
        )
    if args.command == "close-terminal-issues":
        return application.close_terminal_issues(
            apply=args.apply,
            issue_numbers=tuple(sorted(set(args.issues))),
            operator=args.operator,
            progress=_progress,
        )
    if args.command == "sync-main":
        return application.sync_main()
    if args.command in MAIN_PRESERVATION_COMMANDS:
        return application.reconcile_main(
            expected_local_head=args.expected_local_head,
            expected_origin_head=args.expected_origin_head,
            preservation_branch=args.preservation_branch,
            preservation_path=args.preservation_path,
            owner_thread_id=args.owner_thread_id,
            external_id=args.external_id,
            operator=args.operator,
            reason=args.reason,
        )
    raise AssertionError(f"unhandled command: {args.command}")


def _progress(message: str) -> None:
    """Operator progress belongs on stderr; stdout stays one JSON document."""

    print(message, file=sys.stderr, flush=True)


def _runtime_timestamp(value: str | None, name: str) -> datetime | None:
    if value is None:
        return None
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise DeliveryContractError(f"{name} must be ISO-8601") from error
    if parsed.utcoffset() is None:
        raise DeliveryContractError(f"{name} must include a timezone")
    return parsed


def _result_exit_code(command: str, result: object) -> int:
    if command == "watchdog":
        return 2
    if command == "watchdog-claim":
        return 0 if _watchdog_dispatch_authorized(result) else 2
    if command == "drain":
        return {"stuck": 1, "timeout": 2}.get(str(_result_field(result, "stopped")), 0)
    if command in APPLY_COMMANDS:
        verdict = _result_field(result, "verdict")
        if verdict == "partial-failure":
            return 1
        return 2 if verdict in {"refused", "blocked"} else 0
    # These commands are read-only evidence surfaces.  An incomplete audit
    # is a valid observation of unresolved source/owner content, not a
    # command transport failure or dispatch authorization.  Callers must use
    # the JSON verdict/result fields to distinguish complete from incomplete;
    # shell exit 0 only says the observation itself was produced.
    if command != "dogfood-preflight":
        return 0
    ready = (
        result.get("ready")
        if isinstance(result, Mapping)
        else getattr(result, "ready", None)
    )
    return 0 if ready is True else 2


def _result_field(result: object, name: str) -> object:
    if isinstance(result, Mapping):
        return result.get(name)
    return getattr(result, name, None)


def _watchdog_dispatch_authorized(result: object) -> bool:
    """Return true only for a claimed wake that may create one turn."""

    if isinstance(result, Mapping):
        action = result.get("action")
        wake_claimed = result.get("wake_claimed")
    else:
        action = getattr(result, "action", None)
        wake_claimed = getattr(result, "wake_claimed", None)
    if isinstance(action, Enum):
        action = action.value
    return action == "wake" and wake_claimed is True


def _run_command_serialized(
    args: argparse.Namespace, application: DeliveryApplication
) -> object:
    writes = args.command in MUTATING_COMMANDS or (
        args.command in APPLY_COMMANDS and getattr(args, "apply", False)
    )
    if not writes:
        return run_command(args, application)
    repo = getattr(application, "repo", None)
    if repo is None:
        # Lightweight application fakes used by unit tests do not own a
        # repository.  Real applications always expose the canonical path.
        return run_command(args, application)
    canonical = Path(repo)
    wait = lock_wait_seconds(args)
    if args.command in BUSY_PROBE_COMMANDS:
        # #2871: a busy lease must refuse before the first GitHub read.  The
        # probe only checks availability; the per-section lease still guards
        # the mutation, so network I/O stays outside it (#2236).
        with OperationLock(canonical, command=args.command, wait_seconds=wait):
            pass
    if args.command in SCOPED_LEASE_COMMANDS:
        return run_command(
            args,
            application,
            operation_lease=lambda section: OperationLock(
                canonical, command=section, wait_seconds=wait
            ),
        )
    with OperationLock(canonical, command=args.command, wait_seconds=wait):
        return run_command(args, application)


def main(
    argv: Sequence[str] | None = None,
    *,
    application_factory: Any = build_application,
) -> int:
    args = _parser().parse_args(argv)
    try:
        application = application_factory(
            repo=args.repo,
            runtime_status_file=args.runtime_status_file,
        )
        result = _run_command_serialized(args, application)
    except (DeliveryContractError, DeliverySourceError, OSError) as error:
        print(
            json.dumps(
                {
                    "schema": COMMAND_SCHEMA,
                    "command": args.command,
                    "ok": False,
                    "error": str(error),
                },
                ensure_ascii=False,
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 1
    payload = {
        "schema": COMMAND_SCHEMA,
        "command": args.command,
        "ok": True,
        "verdict": _command_verdict(args.command, result),
        "result": _jsonable(result),
    }
    if args.command == "watchdog":
        payload["dispatch_authorized"] = False
    elif args.command == "watchdog-claim":
        payload["dispatch_authorized"] = _watchdog_dispatch_authorized(result)
    try:
        print(
            json.dumps(
                payload,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
        )
    except BrokenPipeError:
        # A bounded consumer such as ``head`` closing stdout is a normal
        # transport event; retain the command's domain exit code and avoid a
        # second traceback during interpreter shutdown.
        try:
            # Keep the devnull stream alive through interpreter shutdown.
            sys.stdout = open(os.devnull, "w", encoding="utf-8")  # noqa: SIM115
        except OSError:
            pass
    return _result_exit_code(args.command, result)


def _command_verdict(command: str, result: object) -> str:
    """Expose domain incompleteness separately from command transport success."""

    if command == "watchdog":
        return "observation"
    if command == "watchdog-claim":
        return "wake-authorized" if _watchdog_dispatch_authorized(result) else "no-wake"
    if command in {
        "branch-audit",
        "branch-review-plan",
        "unreachable-commit-inspect",
    }:
        complete = (
            result.get("complete")
            if isinstance(result, Mapping)
            else getattr(result, "complete", None)
        )
        return "complete" if complete is True else "incomplete"
    if command == "dogfood-preflight":
        ready = (
            result.get("ready")
            if isinstance(result, Mapping)
            else getattr(result, "ready", None)
        )
        return "ready" if ready is True else "blocked"
    if command == "drain":
        return str(_result_field(result, "stopped"))
    if command in APPLY_COMMANDS:
        verdict = _result_field(result, "verdict")
        return verdict if isinstance(verdict, str) else "success"
    if command == "abandon-pr":
        malformed = (
            result.get("malformed_published_lane")
            if isinstance(result, Mapping)
            else getattr(result, "malformed_published_lane", None)
        )
        if malformed is True:
            return "terminalized-malformed"
    return "success"


__all__ = [
    "COMMAND_SCHEMA",
    "DeliveryApplication",
    "RuntimeStatusMap",
    "build_application",
    "main",
    "run_command",
]
