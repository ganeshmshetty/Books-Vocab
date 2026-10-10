from __future__ import annotations

import sys
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.domain.errors import PolicyViolation
from delivery_control.domain.models import CheckStatus, HandbackReceipt, Scope
from delivery_control.domain.observations import (
    CheckSnapshot,
    InventoryProblem,
    PullRequestSnapshot,
    RegistryInventory,
    RegistrySnapshot,
)
from delivery_control.domain.states import HoldKind
from delivery_control.services.pr_contract import render_pull_request_body
from delivery_control.services.queue import QueueService

BASE = "a" * 40
HEAD = "b" * 40


def _receipt(*, base_sha: str = BASE) -> HandbackReceipt:
    return HandbackReceipt(
        lane_id="DIRECT-1",
        owner_thread_id="thread-1",
        claim_generation=3,
        branch="feat/queue",
        worktree_path="/tmp/queue",
        base_sha=base_sha,
        parent_sha=base_sha,
        head_sha=HEAD,
        origin_main_sha=base_sha,
        content_digest="c" * 64,
        scope=Scope.from_paths(modify=("ops/a.py",)),
    )


def _registry(receipt: HandbackReceipt, **changes: object) -> RegistrySnapshot:
    values: dict[str, object] = {
        "lane_id": receipt.lane_id,
        "branch": receipt.branch,
        "path": Path(receipt.worktree_path),
        "status": "published",
        "scope": receipt.scope,
        "base_sha": receipt.base_sha,
        "claim_generation": receipt.claim_generation,
        "owner_thread_id": receipt.owner_thread_id,
        "handed_back_sha": receipt.head_sha,
        "handback_claim_generation": receipt.claim_generation,
        "handback_valid": True,
        "handback_digest": receipt.content_digest,
        "handback_origin_main_sha": receipt.origin_main_sha,
    }
    values.update(changes)
    return RegistrySnapshot(**values)  # type: ignore[arg-type]


def _pull_request(receipt: HandbackReceipt) -> PullRequestSnapshot:
    return PullRequestSnapshot(
        number=11,
        url="https://example.test/pull/11",
        branch=receipt.branch,
        base_sha=receipt.base_sha,
        head_sha=receipt.head_sha,
        state="OPEN",
        draft=False,
        mergeable=True,
        title="fix: queue",
        body=render_pull_request_body(receipt),
    )


class FakeRegistry:
    def __init__(
        self,
        record: RegistrySnapshot,
        *,
        problems: tuple[InventoryProblem, ...] = (),
    ) -> None:
        self.record = record
        self.problems = problems

    def list_records(self) -> RegistryInventory:
        return RegistryInventory((self.record,), problems=self.problems)

    def get(self, lane_id: str) -> RegistrySnapshot | None:
        return self.record if self.record.lane_id == lane_id else None

    def find_exact_claim(
        self,
        *,
        lane_id: str,
        branch: str,
        path: Path,
        claim_generation: int,
    ) -> RegistrySnapshot | None:
        if (
            self.record.lane_id == lane_id
            and self.record.branch == branch
            and self.record.path == path.resolve()
            and self.record.claim_generation == claim_generation
        ):
            return self.record
        return None


class FakeGit:
    def __init__(self, live_main: str) -> None:
        self.live_main = live_main

    def origin_main_sha(self) -> str:
        return self.live_main


class DriftingGit(FakeGit):
    def __init__(self, *sha_sequence: str) -> None:
        super().__init__(sha_sequence[0])
        self.sha_sequence = list(sha_sequence)

    def origin_main_sha(self) -> str:
        if len(self.sha_sequence) > 1:
            return self.sha_sequence.pop(0)
        return self.sha_sequence[0]


class FakeGitHub:
    def __init__(
        self,
        receipt: HandbackReceipt,
        *,
        pull_request: PullRequestSnapshot | None = None,
        required: CheckStatus = CheckStatus.SUCCESS,
        paths: tuple[str, ...] | None = None,
        merge_queue: bool = True,
        required_contexts: tuple[str, ...] = ("required",),
    ) -> None:
        self.receipt = receipt
        self.pull_request = pull_request or _pull_request(receipt)
        self.required = required
        self.paths = receipt.scope.paths if paths is None else paths
        self.merge_queue = merge_queue
        self.required_contexts = required_contexts
        self.enqueue_calls: list[tuple[int, str, str, str]] = []
        self.required_fresh_flags: list[bool] = []

    def required_status_contexts(self, branch: str) -> tuple[str, ...]:
        assert branch == "main"
        return self.required_contexts

    def get_pull_request(self, number: int) -> PullRequestSnapshot:
        assert number == self.pull_request.number
        return self.pull_request

    def changed_paths(self, number: int) -> tuple[str, ...]:
        return self.paths

    def required_check_snapshot(
        self, number: int, *, fresh: bool = False
    ) -> CheckSnapshot:
        self.required_fresh_flags.append(fresh)
        return CheckSnapshot(
            status=self.required,
            head_sha=self.pull_request.head_sha,
            observed_at=datetime.now(UTC),
            names=("required",),
        )

    def merge_queue_enabled(self, branch: str) -> bool:
        assert branch == "main"
        return self.merge_queue

    def enqueue(
        self,
        *,
        number: int,
        expected_base_sha: str,
        expected_head_sha: str,
        expected_body: str,
    ) -> None:
        self.enqueue_calls.append(
            (number, expected_base_sha, expected_head_sha, expected_body)
        )


def _service(
    receipt: HandbackReceipt,
    *,
    live_main: str | None = None,
    record: RegistrySnapshot | None = None,
    github: FakeGitHub | None = None,
) -> tuple[QueueService, FakeGitHub]:
    fake_github = github or FakeGitHub(receipt)
    return (
        QueueService(
            registry=FakeRegistry(record or _registry(receipt)),
            git=FakeGit(live_main or receipt.base_sha),
            github_query=fake_github,
            github_command=fake_github,
        ),
        fake_github,
    )


def test_exact_required_green_candidate_is_enqueued_once() -> None:
    receipt = _receipt()
    service, github = _service(receipt)

    result = service.enqueue(receipt=receipt, pull_request_number=11)

    assert result.live_main_sha == BASE
    assert github.enqueue_calls == [(11, BASE, HEAD, render_pull_request_body(receipt))]


def test_queue_admission_reads_required_checks_fresh_not_from_a_primed_batch() -> None:
    receipt = _receipt()
    service, github = _service(receipt)

    service.enqueue(receipt=receipt, pull_request_number=11)

    assert github.required_fresh_flags == [True]


def test_exact_claim_isolated_from_unrelated_inventory_problems() -> None:
    receipt = _receipt()
    registry = FakeRegistry(
        _registry(receipt),
        problems=(InventoryProblem("registry", "legacy-record", "malformed"),),
    )
    github = FakeGitHub(receipt)
    service = QueueService(
        registry=registry,
        git=FakeGit(BASE),
        github_query=github,
        github_command=github,
    )

    service.enqueue(receipt=receipt, pull_request_number=11)

    assert github.enqueue_calls


def test_queue_admits_lagging_pr_at_its_recorded_base_when_queue_validates() -> None:
    receipt = _receipt()
    service, github = _service(receipt, live_main="d" * 40)

    result = service.enqueue(receipt=receipt, pull_request_number=11)

    assert result.live_main_sha == "d" * 40
    assert github.enqueue_calls == [(11, BASE, HEAD, render_pull_request_body(receipt))]


@pytest.mark.parametrize(
    ("changes", "contexts", "message"),
    [
        ({"mergeable": False, "conflicting": True}, ("required",), "reanchor_required"),
        ({"head_sha": "e" * 40}, ("required",), "PR head differs"),
        ({}, (), "stale"),
        # A required context other than the gate `required` validates nothing
        # the dogfood relies on, so lag is still refused.
        ({}, ("lint",), "stale"),
    ],
)
def test_queue_refuses_conflict_moved_head_or_unvalidated_lag(
    changes: dict[str, object], contexts: tuple[str, ...], message: str
) -> None:
    receipt = _receipt()
    pull_request = replace(_pull_request(receipt), **changes)
    github = FakeGitHub(receipt, pull_request=pull_request, required_contexts=contexts)
    service, github = _service(receipt, live_main="d" * 40, github=github)

    with pytest.raises(PolicyViolation, match=message):
        service.enqueue(receipt=receipt, pull_request_number=11)
    assert not github.enqueue_calls


PUBLISHED_BASE = "9" * 40


def test_queue_admits_pr_whose_published_registry_base_lags_main() -> None:
    # Production refusal "registry base is stale": the registry's
    # published_base_sha (the PR target at publish time) is behind live main,
    # and so is the hand-back base; the PR is still MERGEABLE and unmoved.
    receipt = _receipt()
    pull_request = replace(_pull_request(receipt), base_sha=PUBLISHED_BASE)
    github = FakeGitHub(receipt, pull_request=pull_request)
    service, github = _service(
        receipt,
        live_main="d" * 40,
        record=_registry(receipt, published_base_sha=PUBLISHED_BASE),
        github=github,
    )

    result = service.enqueue(receipt=receipt, pull_request_number=11)

    assert result.live_main_sha == "d" * 40
    assert github.enqueue_calls == [
        (11, PUBLISHED_BASE, HEAD, render_pull_request_body(receipt))
    ]


@pytest.mark.parametrize(
    ("changes", "contexts", "message"),
    [
        ({"mergeable": False, "conflicting": True}, ("required",), "reanchor_required"),
        ({"head_sha": "e" * 40}, ("required",), "PR head differs"),
        ({}, (), "stale"),
        # The PR target moved away from the registry's published base.
        ({"base_sha": "f" * 40}, ("required",), "published registry base"),
    ],
)
def test_queue_refuses_lagging_registry_base_unless_exact_and_unconflicted(
    changes: dict[str, object], contexts: tuple[str, ...], message: str
) -> None:
    receipt = _receipt()
    pull_request = replace(
        _pull_request(receipt), **{"base_sha": PUBLISHED_BASE, **changes}
    )
    github = FakeGitHub(receipt, pull_request=pull_request, required_contexts=contexts)
    service, github = _service(
        receipt,
        live_main="d" * 40,
        record=_registry(receipt, published_base_sha=PUBLISHED_BASE),
        github=github,
    )

    with pytest.raises(PolicyViolation, match=message):
        service.enqueue(receipt=receipt, pull_request_number=11)
    assert not github.enqueue_calls


def test_unvalidated_queue_rechecks_live_main_before_mutation() -> None:
    receipt = _receipt()
    github = FakeGitHub(receipt, required_contexts=())
    service = QueueService(
        registry=FakeRegistry(_registry(receipt)),
        git=DriftingGit(BASE, "d" * 40),
        github_query=github,
        github_command=github,
    )

    with pytest.raises(PolicyViolation, match="changed during queue admission"):
        service.enqueue(receipt=receipt, pull_request_number=11)
    assert not github.enqueue_calls


@pytest.mark.parametrize(
    ("live_main", "required", "holds", "message"),
    [
        (BASE, CheckStatus.FAILURE, frozenset(), "not successful"),
        (
            BASE,
            CheckStatus.SUCCESS,
            frozenset({HoldKind.SECURITY}),
            "hold",
        ),
    ],
)
def test_queue_blocks_failed_or_held_candidate(
    live_main: str,
    required: CheckStatus,
    holds: frozenset[HoldKind],
    message: str,
) -> None:
    receipt = _receipt()
    github = FakeGitHub(receipt, required=required)
    service, github = _service(receipt, live_main=live_main, github=github)

    with pytest.raises(PolicyViolation, match=message):
        service.enqueue(receipt=receipt, pull_request_number=11, holds=holds)
    assert not github.enqueue_calls


def test_queue_blocks_durable_body_hold_without_caller_supplied_hold() -> None:
    receipt = _receipt()
    pull_request = replace(
        _pull_request(receipt),
        body=render_pull_request_body(receipt, holds=frozenset({HoldKind.SECURITY})),
    )
    github = FakeGitHub(receipt, pull_request=pull_request)
    service, github = _service(receipt, github=github)

    with pytest.raises(PolicyViolation, match="hold"):
        service.enqueue(receipt=receipt, pull_request_number=11)
    assert not github.enqueue_calls


def test_queue_blocks_metadata_or_scope_drift() -> None:
    receipt = _receipt()
    body_drift = FakeGitHub(
        receipt,
        pull_request=replace(_pull_request(receipt), body="## Scope\nwrong"),
    )
    body_service, _ = _service(receipt, github=body_drift)
    with pytest.raises(PolicyViolation, match="body"):
        body_service.enqueue(receipt=receipt, pull_request_number=11)

    path_drift = FakeGitHub(receipt, paths=("ops/other.py",))
    path_service, _ = _service(receipt, github=path_drift)
    with pytest.raises(PolicyViolation, match="paths"):
        path_service.enqueue(receipt=receipt, pull_request_number=11)


def test_queue_allows_pr_paths_subset_of_receipt_scope() -> None:
    receipt = replace(
        _receipt(),
        scope=Scope.from_paths(modify=("ops/a.py", "ops/b.py")),
    )
    github = FakeGitHub(receipt, paths=("ops/a.py",))
    service, github = _service(receipt, github=github)

    service.enqueue(receipt=receipt, pull_request_number=11)

    assert github.enqueue_calls


def test_queue_rejects_empty_pr_paths() -> None:
    receipt = _receipt()
    github = FakeGitHub(receipt, paths=())
    service, github = _service(receipt, github=github)

    with pytest.raises(PolicyViolation, match="paths"):
        service.enqueue(receipt=receipt, pull_request_number=11)
    assert not github.enqueue_calls


@pytest.mark.parametrize(
    "record",
    (
        _registry(_receipt(), status="active"),
        _registry(_receipt(), path=Path("/tmp/not-the-handed-back-worktree")),
        _registry(_receipt(), handback_digest="d" * 64),
    ),
)
def test_queue_requires_exact_published_registry_receipt(
    record: RegistrySnapshot,
) -> None:
    receipt = _receipt()
    service, github = _service(receipt, record=record)

    with pytest.raises(PolicyViolation, match="exact local receipt"):
        service.enqueue(receipt=receipt, pull_request_number=11)
    assert not github.enqueue_calls


def test_queue_refuses_repository_without_native_merge_queue() -> None:
    receipt = _receipt()
    github = FakeGitHub(receipt, merge_queue=False)
    service, github = _service(receipt, live_main="d" * 40, github=github)

    with pytest.raises(PolicyViolation, match="merge queue"):
        service.enqueue(receipt=receipt, pull_request_number=11)
    assert not github.enqueue_calls
