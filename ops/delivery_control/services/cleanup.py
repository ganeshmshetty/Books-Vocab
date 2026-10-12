"""Idempotent local-asset release and terminal branch cleanup."""

from __future__ import annotations

from collections.abc import Callable
from contextlib import AbstractContextManager, nullcontext
from dataclasses import dataclass
from pathlib import Path

from ..domain.errors import PolicyViolation
from ..domain.models import HandbackReceipt, MergedPullRequestProof
from ..domain.observations import (
    PhysicalWorktree,
    PullRequestSnapshot,
    RegistrySnapshot,
)
from ..ports.git import GitCommandPort, GitQueryPort
from ..ports.github import GitHubQueryPort
from ..ports.registry import RegistryCleanupQueryPort, RegistryCommandPort
from .pr_contract import parse_pull_request_body, pull_request_holds

# One cross-process delivery mutation lease, keyed by a short section label
# that a busy refusal reports.  The CLI supplies OperationLock; None means
# the caller already holds the whole-command lease (publish) or is a fake.
OperationLease = Callable[[str], AbstractContextManager[object]]


def _unleased(label: str) -> AbstractContextManager[object]:
    del label
    return nullcontext()


@dataclass(frozen=True)
class CleanupResult:
    disposition: str
    worktree_absent: bool
    local_branch_absent: bool
    remote_branch_absent: bool


class CleanupService:
    def __init__(
        self,
        *,
        registry_query: RegistryCleanupQueryPort,
        registry_command: RegistryCommandPort,
        git_query: GitQueryPort,
        git_command: GitCommandPort,
        github: GitHubQueryPort,
        lease: OperationLease | None = None,
    ) -> None:
        self.registry_query = registry_query
        self.registry_command = registry_command
        self.git_query = git_query
        self.git_command = git_command
        self.github = github
        self.lease = _unleased if lease is None else lease

    def _require_canonical_main(self) -> None:
        """Protect local cleanup from removing the checkout running the command."""

        checkout = self.git_query.canonical_checkout()
        if checkout.branch != "main":
            raise PolicyViolation("canonical checkout must be on main before cleanup")
        if not checkout.clean:
            raise PolicyViolation("canonical checkout is dirty before cleanup")

    def _record(self, receipt: HandbackReceipt) -> RegistrySnapshot:
        record = self.registry_query.find_exact_claim(
            lane_id=receipt.lane_id,
            branch=receipt.branch,
            path=Path(receipt.worktree_path),
            claim_generation=receipt.claim_generation,
        )
        if record is None or (
            record.handed_back_sha != receipt.head_sha
            or record.status not in {"active", "cleanup_pending", "published", "merged"}
        ):
            raise PolicyViolation("local claim does not resolve to one exact handback")
        if (
            record.base_sha != receipt.base_sha
            or record.scope != receipt.scope
            or record.owner_thread_id != receipt.owner_thread_id
            or not record.handback_valid
            or record.handback_digest != receipt.content_digest
            or record.handback_origin_main_sha != receipt.origin_main_sha
        ):
            raise PolicyViolation("local claim differs from typed handback")
        return record

    def _acquire_cleanup_lease(self, receipt: HandbackReceipt) -> RegistrySnapshot:
        # Re-read under the operation lease: the caller's snapshot was taken
        # before network checks that run unleased.
        with self.lease("cleanup:registry-lease"):
            record = self._record(receipt)
            if record.status == "merged":
                raise PolicyViolation(
                    "merged lane cannot acquire a local cleanup lease"
                )
            if record.status != "cleanup_pending":
                self.registry_command.resolve(
                    receipt.lane_id,
                    "cleanup_pending",
                    expected_claim_generation=receipt.claim_generation,
                    expected_branch=receipt.branch,
                    expected_path=receipt.worktree_path,
                    expected_head_sha=receipt.head_sha,
                )
            leased = self._record(receipt)
        if leased.status != "cleanup_pending":
            raise PolicyViolation("registry cleanup lease did not read back exactly")
        return leased

    def _complete_cleanup_lease(
        self,
        receipt: HandbackReceipt,
        disposition: str,
        *,
        pull_request_number: int,
        expected_pr_state: str,
        body_receipt: HandbackReceipt | None = None,
    ) -> None:
        pull_request = self._pull_request(
            receipt,
            pull_request_number,
            expected_state=expected_pr_state,
            body_receipt=body_receipt,
        )
        terminal_proof = None
        if disposition == "merged":
            # The registry terminalizes the lane tip; a merged head that moved
            # past it is recorded beside it, never in place of it.
            terminal_proof = MergedPullRequestProof(
                lane_id=receipt.lane_id,
                pr_number=pull_request.number,
                branch=pull_request.branch,
                head_sha=receipt.head_sha,
                base_branch=pull_request.base_branch,
                pr_state=pull_request.state,
                merged_head_sha=(
                    None
                    if pull_request.head_sha == receipt.head_sha
                    else pull_request.head_sha
                ),
            )
        with self.lease("cleanup:registry-terminal"):
            self.registry_command.resolve(
                receipt.lane_id,
                disposition,
                expected_claim_generation=receipt.claim_generation,
                expected_branch=receipt.branch,
                expected_path=receipt.worktree_path,
                expected_head_sha=receipt.head_sha,
                terminal_proof=terminal_proof,
            )

    def _pull_request(
        self,
        receipt: HandbackReceipt,
        number: int,
        *,
        expected_state: str,
        body_receipt: HandbackReceipt | None = None,
    ) -> PullRequestSnapshot:
        pull_request = self.github.get_pull_request(number)
        parsed_receipt = parse_pull_request_body(pull_request.body)
        expected_body_receipt = receipt if body_receipt is None else body_receipt
        # Holds are part of the durable machine contract, but may originate
        # from typed body metadata, labels, or a legacy PUBLISH ONLY marker.
        # Reading them here prevents cleanup from erasing or bypassing a hold;
        # a hold gates queue admission, not release of already-durable assets.
        pull_request_holds(pull_request)
        if (
            pull_request.state != expected_state
            or pull_request.base_branch != "main"
            or pull_request.branch != receipt.branch
            or not self._head_matches(
                receipt, pull_request, expected_state=expected_state
            )
            or parsed_receipt != expected_body_receipt
            or not receipt.scope.allows_changed_paths(self.github.changed_paths(number))
            or (
                body_receipt is not None
                and not self._compatible_previous_receipt(
                    current=receipt, previous=body_receipt
                )
            )
        ):
            raise PolicyViolation("PR does not prove the exact handback disposition")
        return pull_request

    def _head_matches(
        self,
        receipt: HandbackReceipt,
        pull_request: PullRequestSnapshot,
        *,
        expected_state: str,
    ) -> bool:
        """Exact lane head; for a MERGED PR, a head that contains the lane tip.

        GitHub "Update branch" (or a rebase pushed after publish) moves the PR
        head past the handback tip.  The merged history then still holds every
        local commit, so cleanup stays safe (#3323).  OPEN PRs stay strict: they
        are published exactly as handed back.
        """

        if pull_request.head_sha == receipt.head_sha:
            return True
        return expected_state == "MERGED" and self.git_query.is_ancestor(
            receipt.head_sha, pull_request.head_sha
        )

    @staticmethod
    def _compatible_previous_receipt(
        *, current: HandbackReceipt, previous: HandbackReceipt
    ) -> bool:
        """Accept only an older receipt for the same narrowed owner patch."""

        return (
            previous.claim_generation < current.claim_generation
            and previous.lane_id == current.lane_id
            and previous.owner_thread_id == current.owner_thread_id
            and previous.branch == current.branch
            and Path(previous.worktree_path).resolve()
            == Path(current.worktree_path).resolve()
            and previous.base_sha == current.base_sha
            and previous.head_sha == current.head_sha
            and previous.origin_main_sha == current.origin_main_sha
            and set(current.scope.files).issubset(previous.scope.files)
        )

    def _remove_local_assets(
        self,
        receipt: HandbackReceipt,
        *,
        pull_request_number: int,
        expected_pr_state: str,
        body_receipt: HandbackReceipt | None = None,
        allow_terminal_residue: bool = False,
    ) -> None:
        physical = self._sealed_worktree(receipt)
        if physical is not None:
            snapshot = self.git_query.inspect_worktree(physical.path, receipt.base_sha)
            if (
                not snapshot.clean
                or snapshot.head_sha != receipt.head_sha
                or snapshot.branch != receipt.branch
                or not receipt.scope.allows_changed_paths(snapshot.changed_paths)
            ):
                raise PolicyViolation("worktree changed after typed handback")
        local_sha = self.git_query.local_branch_sha(receipt.branch)
        if local_sha is not None and local_sha != receipt.head_sha:
            raise PolicyViolation("local branch changed after typed handback")

        terminal_residue = (
            allow_terminal_residue
            and physical is None
            and Path(receipt.worktree_path).exists()
        )
        checked_pull_request = False
        if physical is not None or terminal_residue:
            self._pull_request(
                receipt,
                pull_request_number,
                expected_state=expected_pr_state,
                body_receipt=body_receipt,
            )
            checked_pull_request = True
            # The adapter re-validates HEAD and cleanliness under the lease.
            with self.lease("cleanup:remove-worktree"):
                self.git_command.remove_worktree(
                    physical.path
                    if physical is not None
                    else Path(receipt.worktree_path),
                    expected_head_sha=receipt.head_sha,
                )
        if local_sha is not None:
            self._pull_request(
                receipt,
                pull_request_number,
                expected_state=expected_pr_state,
                body_receipt=body_receipt,
            )
            checked_pull_request = True
            with self.lease("cleanup:delete-local-branch"):
                self.git_command.delete_local_branch(
                    receipt.branch, expected_head_sha=receipt.head_sha
                )
        if not checked_pull_request:
            self._pull_request(
                receipt,
                pull_request_number,
                expected_state=expected_pr_state,
                body_receipt=body_receipt,
            )

    def release_after_publish(
        self, *, receipt: HandbackReceipt, pull_request_number: int
    ) -> CleanupResult:
        with self.lease("cleanup:canonical-main"):
            self._require_canonical_main()
        record = self._record(receipt)
        if record.status == "merged":
            raise PolicyViolation("merged lane requires terminal cleanup")
        self._pull_request(receipt, pull_request_number, expected_state="OPEN")
        self._require_remote_head(receipt)
        self._validate_local_assets(receipt)
        if record.status == "published":
            existing = self._result(receipt, "published")
            if existing.worktree_absent and existing.local_branch_absent:
                return existing
        self._acquire_cleanup_lease(receipt)
        self._remove_local_assets(
            receipt,
            pull_request_number=pull_request_number,
            expected_pr_state="OPEN",
        )
        self._require_remote_head(receipt)
        self._complete_cleanup_lease(
            receipt,
            "published",
            pull_request_number=pull_request_number,
            expected_pr_state="OPEN",
        )
        return self._result(receipt, "published")

    def _require_remote_head(self, receipt: HandbackReceipt) -> None:
        if self.git_query.remote_branch_sha(receipt.branch) != receipt.head_sha:
            raise PolicyViolation("remote branch does not preserve published HEAD")

    def _validate_local_assets(self, receipt: HandbackReceipt) -> None:
        physical = self._sealed_worktree(receipt)
        if physical is not None:
            snapshot = self.git_query.inspect_worktree(physical.path, receipt.base_sha)
            if (
                not snapshot.clean
                or snapshot.head_sha != receipt.head_sha
                or snapshot.branch != receipt.branch
                or not receipt.scope.allows_changed_paths(snapshot.changed_paths)
            ):
                raise PolicyViolation("worktree changed after typed handback")
        local_sha = self.git_query.local_branch_sha(receipt.branch)
        if local_sha is not None and local_sha != receipt.head_sha:
            raise PolicyViolation("local branch changed after typed handback")

    def _sealed_worktree(self, receipt: HandbackReceipt) -> PhysicalWorktree | None:
        inventory = self.git_query.list_worktrees()
        sealed_path = Path(receipt.worktree_path).resolve()
        path_matches = tuple(
            item for item in inventory if item.path.resolve() == sealed_path
        )
        branch_matches = tuple(
            item for item in inventory if item.branch == receipt.branch
        )
        if not path_matches and not branch_matches:
            return None
        if (
            len(path_matches) != 1
            or len(branch_matches) != 1
            or path_matches[0] is not branch_matches[0]
        ):
            raise PolicyViolation(
                "sealed worktree path and branch do not match uniquely"
            )
        return path_matches[0]

    def finalize_merged(
        self,
        *,
        receipt: HandbackReceipt,
        pull_request_number: int,
        body_receipt: HandbackReceipt | None = None,
    ) -> CleanupResult:
        with self.lease("cleanup:canonical-main"):
            self._require_canonical_main()
        record = self._record(receipt)
        self._pull_request(
            receipt,
            pull_request_number,
            expected_state="MERGED",
            body_receipt=body_receipt,
        )
        if record.status == "merged":
            result = self._result(receipt, "merged")
            if not (result.local_branch_absent and result.remote_branch_absent):
                raise PolicyViolation("merged registry record has unreconciled assets")
            if not result.worktree_absent:
                raise PolicyViolation("merged registry record has unreconciled assets")
            if not Path(receipt.worktree_path).exists():
                return result
            self._remove_local_assets(
                receipt,
                pull_request_number=pull_request_number,
                expected_pr_state="MERGED",
                body_receipt=body_receipt,
                allow_terminal_residue=True,
            )
            result = self._result(receipt, "merged")
            if not result.worktree_absent:
                raise PolicyViolation("merged registry record has unreconciled assets")
            return result
        self._acquire_cleanup_lease(receipt)
        self._remove_local_assets(
            receipt,
            pull_request_number=pull_request_number,
            expected_pr_state="MERGED",
            body_receipt=body_receipt,
            allow_terminal_residue=True,
        )
        remote_sha = self.git_query.remote_branch_sha(receipt.branch)
        if remote_sha is not None:
            # The remote must still be the exact merged PR head, which may sit
            # past the lane tip after "Update branch"; re-read it right before
            # the delete and delete exactly that observed head.
            merged = self._pull_request(
                receipt,
                pull_request_number,
                expected_state="MERGED",
                body_receipt=body_receipt,
            )
            if remote_sha != merged.head_sha:
                raise PolicyViolation("remote branch changed after merged HEAD")
            self.git_command.delete_remote_branch(
                receipt.branch, expected_head_sha=remote_sha
            )
        self._complete_cleanup_lease(
            receipt,
            "merged",
            pull_request_number=pull_request_number,
            expected_pr_state="MERGED",
            body_receipt=body_receipt,
        )
        return self._result(receipt, "merged")

    def _result(self, receipt: HandbackReceipt, disposition: str) -> CleanupResult:
        sealed_worktree = self._sealed_worktree(receipt)
        return CleanupResult(
            disposition=disposition,
            worktree_absent=sealed_worktree is None,
            local_branch_absent=self.git_query.local_branch_sha(receipt.branch) is None,
            remote_branch_absent=self.git_query.remote_branch_sha(receipt.branch)
            is None,
        )
