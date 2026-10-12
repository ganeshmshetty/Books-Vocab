"""User-command facade over deterministic delivery services."""

from __future__ import annotations

from collections.abc import Callable, Sequence
from contextlib import nullcontext
from dataclasses import dataclass, replace
from datetime import datetime, timedelta
from pathlib import Path

from .application_ports import (
    DeliveryGitHubPort,
    DeliveryGitPort,
    DeliveryRegistryPort,
    _utc_now,
)
from .controller.capacity import decide_capacity
from .controller.dogfood import (
    DEFAULT_DOGFOOD_PROFILE,
    DogfoodProfile,
    assess_dogfood_readiness,
)
from .controller.metrics import measure_merge_cadence, measure_pipeline
from .controller.runtime_watchdog import evaluate_runtime_watchdog
from .controller.worktree_boundary import partition_worktrees
from .domain import errors, models, observations, states
from .domain.branch_content import (
    BRANCH_REVIEW_PAGE_LIMIT,
    BranchContentEvidence,
    BranchContentReviewItem,
    BranchContentReviewPlan,
)
from .domain.branch_lifecycle import BranchDisposition, BranchSide
from .domain.candidate_issues import CandidateSpec
from .domain.demand_issues import IssueDisposition, IssueIntakeRequest
from .domain.runtime_models import RuntimeReceipt, WatchdogAction
from .domain.unreachable_commits import (
    EMPTY_UNREACHABLE_COMMIT_INVENTORY,
    UNREACHABLE_COMMIT_PATH_LIMIT,
    UnreachableCommitInventory,
    validate_unreachable_commit_path_limit,
)
from .ports.dispositions import DispositionReceiptPort
from .ports.github import GitHubIssueCommandPort, GitHubIssueIntakePort
from .ports.registry import RegistryPublishedClaimQueryPort
from .ports.runtime import (
    AgentRuntimePort,
    RuntimeReceiptPort,
    RuntimeReceiptStorePort,
)
from .ports.telemetry import TelemetryStorePort
from .services import (
    abandon,
    abandoned_handback,
    branch_audit,
    branch_content,
    cleanup,
    drain,
    inspect,
    issue_terminal_close,
    legacy_cleanup,
    metadata,
    orphan_branch,
    ownerless_claim,
    queue,
    required_repair,
    superseded_handback,
    sync_main,
    telemetry_operations,
    unreachable_commit,
    unregistered_branch,
)
from .services import holds as hold_services
from .services.issue_admission import (
    assert_candidate_scope_available,
    assert_issue_intake_available,
)
from .services.issue_triage import build_triage_plan
from .services.pr_contract import IssueLinks, parse_pull_request_body
from .services.publish import PublishService, receipt_from_active_claim
from .services.publish_preflight import PublishPreflightService

_REVIEWABLE_LOCAL_ORPHAN_BLOCKERS = frozenset(
    {
        "orphan branch tip is not an ancestor of live origin/main",
        (
            "orphan branch tip is not an ancestor of live origin/main "
            "and is not patch-equivalent"
        ),
    }
)


def _is_reviewable_local_orphan(action: object) -> bool:
    """Keep owner/remote/source blockers out of the content-review queue."""

    preflight = getattr(action, "orphan_preflight", None)
    blockers = getattr(preflight, "blockers", ()) if preflight is not None else ()
    return (
        getattr(action, "side", None) is BranchSide.LOCAL
        and getattr(action, "category", None) == "local_orphan_blocked"
        and getattr(action, "review_command", None) is not None
        and preflight is not None
        and not preflight.eligible
        and len(blockers) == 1
        and next(iter(blockers)) in _REVIEWABLE_LOCAL_ORPHAN_BLOCKERS
    )


def _receipt_from_current_claim_for_cleanup(
    *,
    previous: models.HandbackReceipt,
    record: observations.RegistrySnapshot,
    pull_request: observations.PullRequestSnapshot,
    merged_head_contains_handback: bool,
    changed_paths: tuple[str, ...],
) -> models.HandbackReceipt:
    """Bridge one older PR body to a later, exact owner claim for cleanup.

    A merged PR may retain the receipt that created it while the same owner
    refreshes its registry claim before terminal cleanup.  The bridge is
    intentionally narrower than a general metadata repair: it requires a
    newer generation, stable lane/owner/branch/path/head identity, the
    current claim's valid handback seal, a merged head equal to or containing
    the handed-back tip (#3323), and observed PR changes within the current
    Scope.
    """

    current_files = set(record.scope.files)
    previous_files = set(previous.scope.files)
    if (
        record.status not in {"active", "published", "cleanup_pending"}
        or record.claim_generation <= previous.claim_generation
        or record.lane_id != previous.lane_id
        or record.branch != previous.branch
        or record.path.resolve() != Path(previous.worktree_path).resolve()
        or record.owner_thread_id != previous.owner_thread_id
        or record.base_sha != previous.base_sha
        or record.handed_back_sha != previous.head_sha
        or record.handback_origin_main_sha != previous.origin_main_sha
        or record.handback_claim_generation != record.claim_generation
        or not record.handback_valid
        or record.handback_digest is None
        or record.handback_origin_main_sha is None
        or not current_files.issubset(previous_files)
        or pull_request.state != "MERGED"
        or pull_request.base_branch != "main"
        or pull_request.base_sha != previous.base_sha
        or pull_request.branch != record.branch
        or not merged_head_contains_handback
        or not record.scope.allows_changed_paths(changed_paths)
    ):
        raise errors.PolicyViolation(
            "current registry claim cannot bridge the previous PR receipt"
        )
    try:
        return models.HandbackReceipt(
            lane_id=record.lane_id,
            owner_thread_id=record.owner_thread_id,
            claim_generation=record.claim_generation,
            branch=record.branch,
            worktree_path=str(record.path),
            base_sha=record.base_sha,
            parent_sha=previous.parent_sha,
            head_sha=record.handed_back_sha,
            origin_main_sha=record.handback_origin_main_sha,
            content_digest=record.handback_digest,
            scope=record.scope,
            validation=record.handback_outcomes,
            initial_holds=record.handback_initial_holds,
        )
    except (TypeError, ValueError) as error:
        raise errors.PolicyViolation(
            "current registry claim handback is malformed"
        ) from error


def _branch_review_next_step(action: object, content: BranchContentEvidence) -> str:
    """Connect reviewed unlanded content to its explicit discard lifecycle.

    The review plan remains read-only: this guidance exposes the exact
    fingerprint and required confirmation inputs, but never authorizes or
    performs deletion.  Keeping the decision here prevents a complete content
    packet from ending in an unbounded "review" state.
    """

    if content.complete and content.unlanded:
        branch = action.branch
        return (
            "review unlanded content; if explicit discard is chosen, invoke "
            "discard-unregistered-branch with "
            f"branch={branch}, expected-head-sha={content.head_sha}, "
            f"expected-content-fingerprint={content.change_fingerprint}; "
            "operator, reason, and --confirm-unmerged are required; "
            "no automatic deletion"
        )
    return str(action.next_step)


@dataclass(frozen=True)
class DeliveryApplication:
    repo: Path
    git: DeliveryGitPort
    github: DeliveryGitHubPort
    registry: DeliveryRegistryPort
    runtime: AgentRuntimePort
    telemetry: TelemetryStorePort
    clock: Callable[[], datetime] = _utc_now
    dispositions: DispositionReceiptPort | None = None

    def inspect(self, *, supervision_worktree_paths: tuple[Path, ...] = ()) -> object:
        return inspect.InspectService(
            registry=self.registry,
            git=self.git,
            github=self.github,
            runtime=self.runtime,
        ).inspect(supervision_worktree_paths=supervision_worktree_paths)

    def issue_inventory(self) -> object:
        """Return the complete raw Issue projection without mutation."""

        return self.inspect().demand_issues

    def branch_audit(
        self,
        *,
        supervision_worktree_paths: tuple[Path, ...] = (),
    ) -> object:
        """Return one deterministic action for every observed branch ref."""

        inventory = self.inspect(supervision_worktree_paths=supervision_worktree_paths)
        orphan_service = orphan_branch.OrphanBranchDiscardService(
            registry=self.registry,
            git_query=self.git,
            git_command=self.git,
            github=self.github,
        )
        orphan_assets = tuple(
            asset
            for asset in inventory.branch_lifecycle.assets
            if asset.disposition
            in {
                BranchDisposition.ORPHAN_LOCAL_RECONCILE,
                BranchDisposition.ORPHAN_REMOTE_RECONCILE,
            }
        )
        local_orphan_assets = tuple(
            asset
            for asset in orphan_assets
            if asset.disposition is BranchDisposition.ORPHAN_LOCAL_RECONCILE
        )
        remote_orphan_assets = tuple(
            asset
            for asset in orphan_assets
            if asset.disposition is BranchDisposition.ORPHAN_REMOTE_RECONCILE
        )
        branch_history_snapshot = None
        list_pull_requests_for_branches = getattr(
            self.github, "list_pull_requests_for_branches", None
        )
        if orphan_assets and callable(list_pull_requests_for_branches):
            try:
                branch_history_snapshot = list_pull_requests_for_branches(
                    tuple(asset.branch for asset in orphan_assets)
                )
            except errors.DeliverySourceError as error:
                branch_history_snapshot = observations.PullRequestInventory(
                    records=(),
                    problems=(
                        observations.InventoryProblem(
                            "github", "branch-history-snapshot", str(error)
                        ),
                    ),
                )
        orphan_preflights = orphan_service.preflight_many(
            branches=tuple((asset.branch, asset.sha) for asset in local_orphan_assets),
            pr_history=branch_history_snapshot,
        )
        remote_orphan_preflights = orphan_service.preflight_remote_many(
            branches=tuple((asset.branch, asset.sha) for asset in remote_orphan_assets),
            pr_history=branch_history_snapshot,
        )
        unreachable_commits = EMPTY_UNREACHABLE_COMMIT_INVENTORY
        unreachable_inventory = getattr(self.git, "unreachable_commit_inventory", None)
        if callable(unreachable_inventory):
            try:
                unreachable_commits = unreachable_inventory()
            except errors.DeliverySourceError as error:
                unreachable_commits = UnreachableCommitInventory(
                    problems=(str(error),),
                    complete=False,
                )
        return branch_audit.build_branch_audit(
            inventory,
            orphan_preflights=orphan_preflights,
            remote_orphan_preflights=remote_orphan_preflights,
            unreachable_commits=unreachable_commits,
        )

    def branch_inspect(
        self,
        *,
        branch: str,
        expected_head_sha: str | None = None,
    ) -> object:
        """Return one bounded content packet for an unlanded local branch."""

        main_sha = self.git.origin_main_sha()
        evidence = branch_content.BranchContentService(git=self.git).inspect(
            branch=branch,
            base_sha=main_sha,
        )
        if (
            expected_head_sha is not None
            and evidence.complete
            and evidence.head_sha != expected_head_sha
        ):
            raise errors.PolicyViolation(
                "branch content HEAD differs from expected inspection SHA"
            )
        return evidence

    def unreachable_commit_inspect(
        self,
        *,
        commit_sha: str,
        max_paths: int = UNREACHABLE_COMMIT_PATH_LIMIT,
    ) -> object:
        """Return bounded evidence without creating a ref or delivery claim."""

        try:
            bounded_max_paths = validate_unreachable_commit_path_limit(max_paths)
        except errors.InvalidReceipt as error:
            raise errors.PolicyViolation(str(error)) from error
        return unreachable_commit.UnreachableCommitService(git=self.git).inspect(
            commit_sha,
            max_paths=bounded_max_paths,
        )

    def branch_review_plan(
        self,
        *,
        offset: int = 0,
        limit: int = BRANCH_REVIEW_PAGE_LIMIT,
    ) -> object:
        """Page blocked local-orphan content for review without mutation."""

        if offset < 0:
            raise errors.PolicyViolation("branch review offset must be non-negative")
        if limit <= 0 or limit > 20:
            raise errors.PolicyViolation("branch review limit must be between 1 and 20")
        audit = self.branch_audit()
        candidates = tuple(
            sorted(
                (
                    action
                    for action in audit.actions
                    if _is_reviewable_local_orphan(action)
                ),
                key=lambda action: (action.branch, action.sha),
            )
        )
        if offset > len(candidates):
            raise errors.PolicyViolation(
                "branch review offset exceeds total candidates; "
                "re-read branch review inventory before retrying"
            )
        selected = (
            candidates[offset : offset + limit]
            if audit.live_main_sha is not None
            else ()
        )
        contents = {}
        if audit.live_main_sha is not None and selected:
            contents = branch_content.BranchContentService(git=self.git).inspect_many(
                branches=tuple(action.branch for action in selected),
                base_sha=audit.live_main_sha,
            )
            contents = {
                branch: branch_content.BranchContentService.compact_for_review(evidence)
                for branch, evidence in contents.items()
            }

        def build_review_item(action: object) -> BranchContentReviewItem:
            content = contents.get(
                action.branch,
                branch_content.BranchContentService._error(
                    branch=action.branch,
                    base_sha=audit.live_main_sha or "0" * 40,
                    error="branch content was not inspected",
                ),
            )
            return BranchContentReviewItem(
                schema="kg.delivery.branch-content-review-item.v1",
                branch=action.branch,
                expected_head_sha=action.sha,
                preflight_eligible=action.orphan_preflight.eligible,
                preflight_blockers=tuple(sorted(action.orphan_preflight.blockers)),
                content=content,
                next_step=_branch_review_next_step(action, content),
            )

        items = tuple(build_review_item(action) for action in selected)
        reviewed_count = offset + len(items)
        remaining_count = max(len(candidates) - reviewed_count, 0)
        reviewable_complete = (
            audit.live_main_sha is not None
            and offset == 0
            and remaining_count == 0
            and all(item.content.complete for item in items)
        )
        return BranchContentReviewPlan(
            schema="kg.delivery.branch-content-review-plan.v1",
            live_main_sha=audit.live_main_sha,
            audit_complete=audit.complete,
            complete=audit.complete and reviewable_complete,
            offset=offset,
            limit=limit,
            total_candidates=len(candidates),
            reviewed_count=reviewed_count,
            remaining_count=remaining_count,
            source_problem_count=len(audit.source_problem_actions),
            items=items,
            reviewable_complete=reviewable_complete,
        )

    def discard_unregistered_branch(
        self,
        *,
        branch: str,
        expected_head_sha: str,
        expected_content_fingerprint: str,
        operator: str,
        reason: str,
        confirm_unmerged: bool,
    ) -> object:
        """Discard only one explicitly reviewed unlanded local-only branch."""

        return unregistered_branch.UnregisteredBranchDiscardService(
            registry=self.registry,
            git_query=self.git,
            git_content=self.git,
            git_command=self.git,
            github=self.github,
        ).discard(
            branch=branch,
            expected_head_sha=expected_head_sha,
            expected_content_fingerprint=expected_content_fingerprint,
            operator=operator,
            reason=reason,
            confirm_unmerged=confirm_unmerged,
        )

    def triage_plan(self) -> object:
        """Return deterministic Issue IDs and next actions without mutation."""

        return build_triage_plan(self.inspect().demand_issues)

    def admit_candidate(
        self,
        *,
        issue_number: int,
        expected_updated_at: datetime,
        expected_body_sha256: str,
        spec: CandidateSpec,
        triage_reason: str,
        operator: str,
    ) -> object:
        """Admit exactly one triaged Issue through the GitHub command port."""

        inventory = self.inspect().demand_issues
        matches = [item for item in inventory.records if item.number == issue_number]
        if len(matches) != 1:
            raise errors.PolicyViolation(
                f"Issue #{issue_number} is not present in the complete raw inventory"
            )
        issue = matches[0]
        exact_existing_candidate = (
            issue.disposition is IssueDisposition.DISPATCHABLE_CANDIDATE
            and issue.candidate_spec == spec
        )
        triageable_dispositions = {
            IssueDisposition.TRIAGE_REQUIRED,
            IssueDisposition.LEGACY_UNMAPPED,
        }
        if (
            issue.disposition not in triageable_dispositions
            and not exact_existing_candidate
        ):
            raise errors.PolicyViolation(
                f"Issue #{issue_number} disposition is {issue.disposition.value}, "
                "not triage_required/legacy_unmapped or an exact existing candidate"
            )
        if issue.disposition is IssueDisposition.LEGACY_UNMAPPED and (
            type(triage_reason) is not str or not triage_reason.strip()
        ):
            raise errors.PolicyViolation(
                "legacy_unmapped admission requires an explicit triage reason"
            )
        assert_candidate_scope_available(
            scope=spec.scope,
            # The target's already-present contract is the admission being
            # retried, not a competing candidate.  Exclude only that Issue;
            # every other typed candidate remains a collision gate.
            demand_issues=tuple(
                item for item in inventory.records if item.number != issue_number
            ),
            registry=self.registry.list_collision_claims(),
            pull_requests=self.github.list_open_pull_requests(),
            changed_paths=self.github.changed_paths,
        )
        if not isinstance(self.github, GitHubIssueCommandPort):
            raise errors.PolicyViolation(
                "GitHub adapter does not expose one-Issue admission capability"
            )
        self.github.admit_candidate(
            issue_number=issue_number,
            expected_updated_at=expected_updated_at,
            expected_body_sha256=expected_body_sha256,
            spec=spec,
            triage_reason=triage_reason,
            operator=operator,
        )
        final_inventory = self.inspect().demand_issues
        if (
            not final_inventory.complete
            or final_inventory.problems
            or final_inventory.source_entries
        ):
            raise errors.DeliverySourceError(
                "candidate admission readback requires a complete Issue inventory"
            )
        final_matches = [
            item for item in final_inventory.records if item.number == issue_number
        ]
        if len(final_matches) != 1:
            raise errors.PolicyViolation(
                f"Issue #{issue_number} admission readback is not uniquely projected"
            )
        final_issue = final_matches[0]
        if (
            final_issue.disposition is not IssueDisposition.DISPATCHABLE_CANDIDATE
            or final_issue.candidate_spec != spec
        ):
            raise errors.PolicyViolation(
                f"Issue #{issue_number} admission projection did not converge to "
                "the exact dispatchable candidate"
            )
        return final_issue

    def create_issue(self, *, request: IssueIntakeRequest) -> object:
        """Create one raw Issue; a separate CAS admission creates candidates."""

        inventory = self.inspect().demand_issues
        if not inventory.complete or inventory.problems or inventory.source_entries:
            raise errors.DeliverySourceError(
                "cannot create an Issue from an incomplete raw inventory"
            )
        assert_issue_intake_available(
            request=request,
            demand_issues=inventory.records,
            registry=self.registry.list_collision_claims(),
            pull_requests=self.github.list_open_pull_requests(),
            changed_paths=self.github.changed_paths,
        )
        if not isinstance(self.github, GitHubIssueIntakePort):
            raise errors.PolicyViolation(
                "GitHub adapter does not expose one-Issue intake capability"
            )
        return self.github.create_issue(request=request)

    def metrics(
        self,
        *,
        now: datetime | None = None,
        supervision_worktree_paths: tuple[Path, ...] = (),
    ) -> object:
        observed_at = now or self.clock()
        telemetry = self._operation_telemetry().rolling(now=observed_at)
        inventory = self.inspect(supervision_worktree_paths=supervision_worktree_paths)
        return measure_pipeline(
            inventory,
            telemetry=telemetry,
            now=observed_at,
            excluded_worktree_paths=supervision_worktree_paths,
        )

    def plan(
        self,
        *,
        now: datetime | None = None,
        supervision_worktree_paths: tuple[Path, ...] = (),
    ) -> object:
        observed_at = now or self.clock()
        metrics = self.metrics(
            now=observed_at,
            supervision_worktree_paths=supervision_worktree_paths,
        )
        cadence = measure_merge_cadence(
            self.github.recent_merge_times(), now=observed_at
        )
        return {
            "metrics": metrics,
            "cadence": cadence,
            "decision": decide_capacity(metrics, cadence),
        }

    def watchdog(
        self,
        *,
        supervisor_thread_id: str,
        now: datetime | None = None,
        stale_after_seconds: int = 300,
    ) -> object:
        """Return a liveness decision; the caller owns Codex thread dispatch."""

        if not isinstance(self.runtime, RuntimeReceiptPort):
            raise errors.PolicyViolation(
                "runtime status source has no structured liveness receipt"
            )
        observed_at = now or self.clock()
        return evaluate_runtime_watchdog(
            self.runtime.runtime_receipt(supervisor_thread_id),
            now=observed_at,
            stale_after_seconds=stale_after_seconds,
        )

    def watchdog_claim(
        self,
        *,
        supervisor_thread_id: str,
        now: datetime | None = None,
        stale_after_seconds: int = 300,
    ) -> object:
        """Reserve one stale wake; an external scheduler still performs dispatch."""

        if not isinstance(self.runtime, RuntimeReceiptStorePort):
            raise errors.PolicyViolation(
                "watchdog wake claims require --runtime-status-file"
            )
        observed_at = now or self.clock()
        receipt = self.runtime.runtime_receipt(supervisor_thread_id)
        decision = evaluate_runtime_watchdog(
            receipt,
            now=observed_at,
            stale_after_seconds=stale_after_seconds,
        )
        if decision.action is not WatchdogAction.WAKE or decision.wake_id is None:
            return decision
        try:
            self.runtime.claim_wake(
                thread_id=supervisor_thread_id,
                wake_id=decision.wake_id,
                now=observed_at,
                expected_cycle_id=receipt.cycle_id if receipt is not None else None,
            )
        except errors.CompareAndSwapConflict:
            current = self.runtime.runtime_receipt(supervisor_thread_id)
            return evaluate_runtime_watchdog(
                current,
                now=observed_at,
                stale_after_seconds=stale_after_seconds,
            )
        return replace(decision, wake_claimed=True)

    def write_runtime_receipt(
        self,
        *,
        receipt: RuntimeReceipt,
        expected_cycle_id: str | None = None,
    ) -> RuntimeReceipt:
        """Write caller-owned liveness evidence, never dispatch an agent."""

        if not isinstance(self.runtime, RuntimeReceiptStorePort):
            raise errors.PolicyViolation(
                "runtime receipt writes require --runtime-status-file"
            )
        return self.runtime.write(
            receipt,
            expected_cycle_id=expected_cycle_id,
        )

    def dogfood_preflight(
        self,
        *,
        now: datetime | None = None,
        profile: DogfoodProfile = DEFAULT_DOGFOOD_PROFILE,
        supervision_worktree_paths: tuple[Path, ...] = (),
    ) -> object:
        observed_at = now or self.clock()
        checkout = self.git.canonical_checkout()
        origin_main_sha = self.git.origin_main_sha()
        physical_worktrees = self.git.list_worktrees()
        worktree_partition = partition_worktrees(
            physical_worktrees,
            canonical_path=self.repo,
            supervision_paths=supervision_worktree_paths,
        )
        main_protected = self.github.branch_is_protected("main")
        required_status_contexts = (
            self.github.required_status_contexts("main") if main_protected else ()
        )
        metrics = self.metrics(
            now=observed_at,
            supervision_worktree_paths=supervision_worktree_paths,
        )
        cadence = measure_merge_cadence(
            self.github.recent_merge_times(),
            now=observed_at,
            window=timedelta(seconds=profile.promotion_observation_seconds),
        )
        return assess_dogfood_readiness(
            local_main_sha=self.git.local_main_sha(),
            origin_main_sha=origin_main_sha,
            canonical_branch=checkout.branch,
            canonical_clean=checkout.clean,
            main_protected=main_protected,
            required_status_contexts=required_status_contexts,
            merge_queue_enabled=self.github.merge_queue_enabled("main"),
            physical_worktree_count=len(worktree_partition.delivery),
            canonical_worktree_present=(worktree_partition.canonical_count == 1),
            metrics=metrics,
            cadence=cadence,
            profile=profile,
            supervision_worktree_count=len(worktree_partition.supervision),
            total_physical_worktree_count=len(physical_worktrees),
        )

    def receipt(self, lane_id: str) -> models.HandbackReceipt:
        receipt, _ = self._receipt_and_record(lane_id)
        return receipt

    def _receipt_and_record(
        self, lane_id: str
    ) -> tuple[models.HandbackReceipt, observations.RegistrySnapshot]:
        record = self.registry.get(lane_id)
        if record is None:
            raise errors.PolicyViolation(
                f"no unique active registry record for {lane_id}"
            )
        snapshot = self.git.inspect_worktree(record.path, record.base_sha)
        return receipt_from_active_claim(record, snapshot), record

    def publish(
        self,
        *,
        lane_id: str,
        title: str,
        closes: Sequence[int] | None = None,
        refs: Sequence[int] | None = None,
        replaced_pr: int | None = None,
        operation_lease: cleanup.OperationLease | None = None,
    ) -> object:
        receipt, record = self._receipt_and_record(lane_id)
        publication = PublishService(
            preflight=PublishPreflightService(
                registry=self.registry,
                git=self.git,
                github=self.github,
            ),
            git=self.git,
            github_query=self.github,
            github_command=self.github,
            github_workflow=self.github,
        ).publish(
            receipt=receipt,
            title=title,
            issues=IssueLinks(tuple(closes or ()), tuple(refs or ()))
            if closes or refs
            else None,
            default_issues=IssueLinks.from_external_ids(
                record.external_ids
            ).merged_with(IssueLinks.from_branch(receipt.branch)),
            replaced_pr=replaced_pr,
        )
        published_base = self.record_published_base(
            publication.pull_request.number, operation_lease=operation_lease
        )
        warnings = self._operation_telemetry().after_publish(
            receipt=receipt,
            record=record,
            publication=publication,
        )
        release = self._cleanup(operation_lease).release_after_publish(
            receipt=receipt,
            pull_request_number=publication.pull_request.number,
        )
        return {
            "receipt": receipt,
            "publication": publication,
            "published_base": published_base,
            "release": release,
            "telemetry_warnings": warnings,
        }

    def record_published_base(
        self,
        pull_request_number: int,
        *,
        operation_lease: cleanup.OperationLease | None = None,
    ) -> object:
        """Persist the exact PR target OID without rewriting handback provenance."""

        before = self.github.get_pull_request(pull_request_number)
        receipt = parse_pull_request_body(before.body)
        record = self.registry.find_exact_claim(
            lane_id=receipt.lane_id,
            branch=receipt.branch,
            path=Path(receipt.worktree_path),
            claim_generation=receipt.claim_generation,
        )
        if record is None:
            raise errors.PolicyViolation(
                "published PR has no exact registry claim for base recording"
            )
        if (
            record.status not in {"active", "cleanup_pending", "published"}
            or record.base_sha != receipt.base_sha
            or record.scope != receipt.scope
            or record.owner_thread_id != receipt.owner_thread_id
            or record.handed_back_sha != receipt.head_sha
            or record.handback_claim_generation != receipt.claim_generation
            or not record.handback_valid
            or record.handback_digest != receipt.content_digest
            or record.handback_origin_main_sha != receipt.origin_main_sha
        ):
            raise errors.PolicyViolation(
                "published PR does not map to one exact typed registry handback"
            )
        branch_inventory = self.github.list_pull_requests_for_branch(receipt.branch)
        current_open = tuple(
            pull_request
            for pull_request in branch_inventory.records
            if pull_request.state == "OPEN"
        )
        if (
            branch_inventory.problems
            or len(current_open) != 1
            or current_open[0].number != before.number
        ):
            raise errors.PolicyViolation(
                "published branch does not map to one unique PR"
            )
        mapped = current_open[0]
        if (
            mapped.number != before.number
            or mapped.state != "OPEN"
            or mapped.draft
            or mapped.base_branch != "main"
            or mapped.branch != receipt.branch
            or mapped.base_sha != before.base_sha
            or mapped.head_sha != receipt.head_sha
            or mapped.body != before.body
            or not receipt.scope.allows_changed_paths(
                self.github.changed_paths(before.number)
            )
        ):
            raise errors.PolicyViolation(
                "published PR tuple changed before base recording"
            )
        # Registry CAS re-validates lane generation, branch and HEAD on
        # re-entry, so only this write needs the cross-process lease (#2463).
        with (
            nullcontext()
            if operation_lease is None
            else operation_lease("publish:record-published-base")
        ):
            self.registry.record_published_base(
                lane_id=receipt.lane_id,
                expected_claim_generation=receipt.claim_generation,
                expected_branch=receipt.branch,
                expected_path=receipt.worktree_path,
                expected_head_sha=receipt.head_sha,
                expected_handback_base_sha=receipt.base_sha,
                published_base_sha=before.base_sha,
            )
        after = self.github.get_pull_request(pull_request_number)
        final_record = self.registry.find_exact_claim(
            lane_id=receipt.lane_id,
            branch=receipt.branch,
            path=Path(receipt.worktree_path),
            claim_generation=receipt.claim_generation,
        )
        if (
            after.base_sha != before.base_sha
            or final_record is None
            or final_record.published_base_sha != before.base_sha
        ):
            raise errors.PolicyViolation(
                "published PR base readback changed during registry recording"
            )
        return {
            "pull_request": after,
            "published_base_sha": final_record.published_base_sha,
            "claim_generation": final_record.claim_generation,
        }

    def drain(
        self,
        *,
        once: bool = False,
        dry_run: bool = False,
        interval: float = drain.DEFAULT_INTERVAL_SECONDS,
        timeout: float = drain.DEFAULT_TIMEOUT_SECONDS,
        operation_lease: cleanup.OperationLease | None = None,
    ) -> object:
        """Pump published lanes to merged and cleaned in this one process (#2646)."""

        return drain.DrainService(
            application=self, operation_lease=operation_lease
        ).run(once=once, dry_run=dry_run, interval=interval, timeout=timeout)

    def release_published(
        self,
        pull_request_number: int,
        *,
        operation_lease: cleanup.OperationLease | None = None,
    ) -> object:
        receipt = self._receipt_from_pr(pull_request_number)
        return self._cleanup(operation_lease).release_after_publish(
            receipt=receipt, pull_request_number=pull_request_number
        )

    def enqueue(
        self,
        *,
        pull_request_number: int,
        holds: frozenset[states.HoldKind] = frozenset(),
    ) -> object:
        receipt = self._receipt_from_pr(pull_request_number)
        record = self._record_for_receipt(receipt)
        result = queue.QueueService(
            registry=self.registry,
            git=self.git,
            github_query=self.github,
            github_command=self.github,
        ).enqueue(
            receipt=receipt,
            pull_request_number=pull_request_number,
            holds=holds,
        )
        warnings = self._operation_telemetry().after_enqueue(
            receipt=receipt,
            record=record,
            result=result,
        )
        return {"queue": result, "telemetry_warnings": warnings}

    def reconcile_holds(
        self,
        *,
        pull_request_number: int,
        holds: frozenset[states.HoldKind],
        clear_all: bool,
    ) -> object:
        return hold_services.HoldService(
            query=self.github, command=self.github
        ).reconcile(
            number=pull_request_number,
            holds=holds,
            clear_all=clear_all,
        )

    def repair_metadata(self, pull_request_number: int) -> object:
        return metadata.MetadataRepairService(
            registry=self.registry,
            query=self.github,
            command=self.github,
        ).repair(pull_request_number)

    def trigger_required(self, pull_request_number: int) -> object:
        return required_repair.RequiredRepairService(
            registry=self.registry,
            query=self.github,
            command=self.github,
        ).trigger(pull_request_number)

    def cleanup_merged(
        self,
        pull_request_number: int,
        *,
        operation_lease: cleanup.OperationLease | None = None,
    ) -> object:
        pull_request = self.github.get_pull_request(pull_request_number)
        if "<!-- kg.delivery.receipt.v1" not in pull_request.body:
            # Migration-only receipt-less PRs keep one lease for the whole run.
            with (
                nullcontext()
                if operation_lease is None
                else operation_lease("cleanup-merged")
            ):
                return self._legacy_cleanup().cleanup_merged_pr(pull_request_number)
        body_receipt = parse_pull_request_body(pull_request.body)
        receipt, record, previous_receipt = self._cleanup_receipt(
            body_receipt, pull_request
        )
        result = self._cleanup(operation_lease).finalize_merged(
            receipt=receipt,
            pull_request_number=pull_request_number,
            body_receipt=previous_receipt,
        )
        warnings = self._operation_telemetry().after_cleanup(
            pull_request=pull_request,
            was_already_terminal=record.status == "merged",
        )
        return {"cleanup": result, "telemetry_warnings": warnings}

    def abandon_pr(self, pull_request_number: int) -> object:
        pull_request = self.github.get_pull_request(pull_request_number)
        if "<!-- kg.delivery.receipt.v1" not in pull_request.body:
            return self._legacy_cleanup().abandon_open_pr(pull_request_number)
        result = abandon.AbandonService(
            registry_query=self.registry,
            registry_command=self.registry,
            git_query=self.git,
            git_command=self.git,
            github_query=self.github,
            github_command=self.github,
        ).abandon(pull_request_number=pull_request_number)
        if not isinstance(result, abandon.TypedAbandonResult):
            raise errors.DeliverySourceError(
                "typed PR abandonment returned an unstructured result"
            )
        return result

    def cleanup_abandoned(self, branch: str) -> object:
        return self._legacy_cleanup().cleanup_abandoned_branch(branch)

    def discard_abandoned_handback(
        self,
        *,
        branch: str,
        expected_head_sha: str,
        operator: str,
        reason: str,
    ) -> object:
        return abandoned_handback.AbandonedHandbackDiscardService(
            registry_query=self.registry,
            registry_command=self.registry,
            git_query=self.git,
            git_command=self.git,
            github=self.github,
        ).discard(
            branch=branch,
            expected_head_sha=expected_head_sha,
            operator=operator,
            reason=reason,
        )

    def supersede_abandoned_handback(
        self,
        *,
        branch: str,
        expected_head_sha: str,
        operator: str,
        reason: str,
    ) -> object:
        return superseded_handback.SupersededHandbackService(
            registry_query=self.registry,
            registry_command=self.registry,
            git_query=self.git,
            git_command=self.git,
            github=self.github,
        ).supersede(
            branch=branch,
            expected_head_sha=expected_head_sha,
            operator=operator,
            reason=reason,
        )

    def discard_orphan_branch(
        self,
        *,
        branch: str,
        expected_head_sha: str,
        operator: str,
        reason: str,
    ) -> object:
        return orphan_branch.OrphanBranchDiscardService(
            registry=self.registry,
            git_query=self.git,
            git_command=self.git,
            github=self.github,
        ).discard(
            branch=branch,
            expected_head_sha=expected_head_sha,
            operator=operator,
            reason=reason,
        )

    def discard_orphan_remote_branch(
        self,
        *,
        branch: str,
        expected_head_sha: str,
        operator: str,
        reason: str,
    ) -> object:
        return orphan_branch.OrphanBranchDiscardService(
            registry=self.registry,
            git_query=self.git,
            git_command=self.git,
            github=self.github,
        ).discard_remote(
            branch=branch,
            expected_head_sha=expected_head_sha,
            operator=operator,
            reason=reason,
        )

    def dispose_ownerless_claim(
        self,
        *,
        branch: str,
        apply: bool,
        expected_claim_generation: int | None = None,
        expected_head_sha: str | None = None,
        operator: str | None = None,
        reason: str | None = None,
        progress: Callable[[str], None] | None = None,
    ) -> object:
        """Dry-run by default; terminalize one ownerless active claim on apply."""

        if self.dispositions is None:
            raise errors.DeliverySourceError(
                "application has no disposition receipt journal configured"
            )
        return ownerless_claim.OwnerlessClaimDisposalService(
            registry=self.registry,
            registry_command=self.registry,
            git_query=self.git,
            github=self.github,
            receipts=self.dispositions,
            clock=self.clock,
        ).dispose(
            branch=branch,
            apply=apply,
            expected_claim_generation=expected_claim_generation,
            expected_head_sha=expected_head_sha,
            operator=operator,
            reason=reason,
            progress=progress,
        )

    def close_terminal_issues(
        self,
        *,
        apply: bool,
        issue_numbers: tuple[int, ...] = (),
        operator: str | None = None,
        progress: Callable[[str], None] | None = None,
    ) -> object:
        """Dry-run by default; close verifiably terminal open Issues on apply.

        This is an IM-side control-plane action, never a Worker action.
        """

        close_issue = getattr(self.github, "close_issue", None)
        if not callable(close_issue):
            raise errors.DeliverySourceError("GitHub adapter cannot close Issues")
        return issue_terminal_close.IssueTerminalCloseService(
            inventory=lambda: self.inspect().demand_issues,
            issues=self.github,  # type: ignore[arg-type]
        ).run(
            apply=apply,
            issue_numbers=issue_numbers,
            operator=operator,
            progress=progress,
        )

    def sync_main(self) -> object:
        result = sync_main.MainSyncService(
            canonical_path=self.repo,
            query=self.git,
            command=self.git,
        ).sync()
        warnings = self._operation_telemetry().after_sync(result)
        return {"sync": result, "telemetry_warnings": warnings}

    def reconcile_main(
        self,
        *,
        expected_local_head: str,
        expected_origin_head: str,
        preservation_branch: str,
        preservation_path: Path,
        owner_thread_id: str,
        external_id: str,
        operator: str,
        reason: str,
    ) -> object:
        """Preserve one owner-bound local tip before a canonical-main CAS park."""

        return sync_main.MainPreservationService(
            canonical_path=self.repo,
            query=self.git,
            command=self.git,
            registry=self.registry,
        ).preserve(
            expected_local_head=expected_local_head,
            expected_origin_head=expected_origin_head,
            preservation_branch=preservation_branch,
            preservation_path=preservation_path,
            owner_thread_id=owner_thread_id,
            external_id=external_id,
            operator=operator,
            reason=reason,
        )

    def _receipt_from_pr(self, number: int) -> models.HandbackReceipt:
        return parse_pull_request_body(self.github.get_pull_request(number).body)

    def _cleanup_receipt(
        self,
        body_receipt: models.HandbackReceipt,
        pull_request: observations.PullRequestSnapshot,
    ) -> tuple[
        models.HandbackReceipt,
        observations.RegistrySnapshot,
        models.HandbackReceipt | None,
    ]:
        """Resolve one current claim while preserving an older PR-body receipt."""

        exact = self.registry.find_exact_claim(
            lane_id=body_receipt.lane_id,
            branch=body_receipt.branch,
            path=Path(body_receipt.worktree_path),
            claim_generation=body_receipt.claim_generation,
        )
        if exact is not None:
            if exact.status in {
                "active",
                "published",
                "cleanup_pending",
                "merged",
            }:
                return body_receipt, exact, None
            if exact.status != "abandoned":
                raise errors.PolicyViolation(
                    "typed receipt has an invalid registry claim"
                )
        if not isinstance(self.registry, RegistryPublishedClaimQueryPort):
            raise errors.PolicyViolation("typed receipt has no exact registry claim")
        current = self.registry.find_published_claim(
            lane_id=body_receipt.lane_id,
            branch=body_receipt.branch,
            path=Path(body_receipt.worktree_path),
            owner_thread_id=body_receipt.owner_thread_id,
            head_sha=body_receipt.head_sha,
            scope=body_receipt.scope,
        )
        if current is None:
            raise errors.PolicyViolation("typed receipt has no exact registry claim")
        return (
            _receipt_from_current_claim_for_cleanup(
                previous=body_receipt,
                record=current,
                pull_request=pull_request,
                merged_head_contains_handback=self._merged_head_contains(
                    current.handed_back_sha, pull_request.head_sha
                ),
                changed_paths=self.github.changed_paths(pull_request.number),
            ),
            current,
            body_receipt,
        )

    def _merged_head_contains(
        self, handed_back_sha: str | None, merged_head_sha: str
    ) -> bool:
        """Whether the merged PR head is the handed-back tip or contains it (#3323)."""

        if handed_back_sha is None:
            return False
        if merged_head_sha == handed_back_sha:
            return True
        return self.git.is_ancestor(handed_back_sha, merged_head_sha)

    def _record_for_receipt(
        self, receipt: models.HandbackReceipt
    ) -> observations.RegistrySnapshot:
        record = self.registry.find_exact_claim(
            lane_id=receipt.lane_id,
            branch=receipt.branch,
            path=Path(receipt.worktree_path),
            claim_generation=receipt.claim_generation,
        )
        if record is None:
            raise errors.PolicyViolation("typed receipt has no exact registry claim")
        return record

    def _operation_telemetry(self) -> telemetry_operations.OperationTelemetry:
        return telemetry_operations.OperationTelemetry(
            store=self.telemetry,
            github=self.github,
            git=self.git,
            clock=self.clock,
        )

    def _cleanup(
        self, operation_lease: cleanup.OperationLease | None = None
    ) -> cleanup.CleanupService:
        return cleanup.CleanupService(
            registry_query=self.registry,
            registry_command=self.registry,
            git_query=self.git,
            git_command=self.git,
            github=self.github,
            lease=operation_lease,
        )

    def _legacy_cleanup(self) -> legacy_cleanup.LegacyTerminalCleanupService:
        return legacy_cleanup.LegacyTerminalCleanupService(
            registry=self.registry,
            git_query=self.git,
            git_command=self.git,
            github_query=self.github,
            github_command=self.github,
        )
