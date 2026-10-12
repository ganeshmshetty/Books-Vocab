"""Registry record normalization and status classification.

This module deliberately has no Git or CLI dependencies.  It preserves malformed
input as named problems so the delivery controller can fail closed instead of
silently planning from an incomplete inventory.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

from delivery_control.domain.superseded_handback import (
    SUPERSEDED_PROOF_DISPOSITION,
    SUPERSEDED_PROOF_SCHEMA,
    superseded_proof_body,
    validate_superseded_proof_shape,
)
from delivery_control.domain.superseded_handback import (
    superseded_proof_with_digest as _superseded_proof_with_digest,
)
from lib.worktree_scope import SCOPE_SCHEMA, overlap_paths, scope_files, scope_problems

from .constants import COMMIT_SHA_RE

SCHEMA = "kg.worktree.registry.v2"
STATUS_ACTIVE = "active"
STATUS_CLEANUP_PENDING = "cleanup_pending"
STATUS_PUBLISHED = "published"
STATUS_MERGED = "merged"
STATUS_ABANDONED = "abandoned"
NON_TERMINAL_STATUSES = frozenset(
    {STATUS_ACTIVE, STATUS_CLEANUP_PENDING, STATUS_PUBLISHED}
)
TERMINAL_STATUSES = frozenset({STATUS_MERGED, STATUS_ABANDONED})
KNOWN_STATUSES = NON_TERMINAL_STATUSES | TERMINAL_STATUSES
GLOBAL_MUTATION_PROBLEM_KINDS = frozenset(
    {
        "registry-record-not-object",
        "registry-status-unknown",
    }
)
TERMINAL_PROOF_SCHEMA = "kg.worktree.terminal-proof.v1"
DISCARD_PROOF_SCHEMA = "kg.worktree.discard-proof.v1"
DISCARD_PROOF_DISPOSITION = "abandoned_handback_discarded"

CURRENT_RECORD_FIELDS = (
    "branch",
    "path",
    "intent",
    "base",
    "status",
    "external_ids",
    "scope",
    "codex_thread_id",
    "delegated",
    "created_at",
    "claimed_at",
    "resolved_at",
    "claim_generation",
    "base_sha",
    "published_base_sha",
    "published_base_recorded_at",
    "handed_back_at",
    "handed_back_sha",
    "handback_claim_generation",
    "handback_seal",
    "handback_outcomes",
    "terminal_proof",
    "discard_proof",
    "superseded_proof",
)

_SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def _scope_record_problem(record: dict[str, Any]) -> tuple[str, str] | None:
    """Return the stable Scope fact shared by registry and delivery parsers."""

    materialized = any(
        field in record
        for field in ("created_at", "claimed_at", "resolved_at", "base", "base_sha")
    )
    if "scope" not in record and not materialized:
        # A few pre-materialization legacy claims contain only the branch/path
        # identity.  Preserve their transition compatibility; once a concrete
        # base/lifecycle fact exists, missing Scope is an explicit observation.
        return None
    if "scope" not in record:
        return (
            "registry-record-missing-field",
            "registry record is missing required field: scope",
        )
    scope = record.get("scope")
    if not isinstance(scope, dict):
        return "registry-scope-invalid", "Scope must be an object"
    if scope.get("schema") != SCOPE_SCHEMA:
        return "registry-scope-invalid", f"Scope schema must be {SCOPE_SCHEMA}"
    scope_findings = scope_problems(scope)
    if not scope_findings:
        return None
    if not isinstance(scope.get("files"), list):
        return "registry-scope-invalid", "Scope files must be a list"
    if not scope["files"]:
        return "registry-scope-invalid", "Scope must contain a non-empty tuple of files"
    return "registry-scope-invalid", "Scope files contain malformed entries"


def _record_base_sha(record: dict[str, Any]) -> str | None:
    if "base_sha" not in record and record.get("status") not in TERMINAL_STATUSES:
        # ``base`` is a legacy symbolic ref during pre-materialization claim
        # creation.  The concrete base contract begins at base_sha/handback.
        return None
    value = record.get("base_sha") or record.get("base")
    if record.get("status") in TERMINAL_STATUSES and not _SHA_RE.fullmatch(
        str(value or "")
    ):
        seal = record.get("handback_seal")
        sealed_base = seal.get("base_sha") if isinstance(seal, dict) else None
        if isinstance(sealed_base, str) and _SHA_RE.fullmatch(sealed_base):
            return sealed_base
    return str(value or "")


def norm_path(path: str) -> str:
    return str(Path(path).expanduser().resolve())


def external_ids(value: object) -> list[str]:
    if value is None:
        return []
    raw = [value] if isinstance(value, str) else value
    if not isinstance(raw, list):
        raise TypeError("external ids must be a list of strings")
    result: list[str] = []
    for item in raw:
        if not isinstance(item, str) or not item.strip():
            raise ValueError("external ids must contain non-empty strings")
        normalized = item.strip()
        if normalized not in result:
            result.append(normalized)
    return result


def legacy_external_ids(record: dict[str, Any]) -> list[str]:
    value = record.get("external_ids")
    if value is None:
        value = record.get("backlog")
    return external_ids(value)


def terminal_proof_with_digest(body: dict[str, Any]) -> dict[str, Any]:
    proof = dict(body)
    encoded = json.dumps(
        body, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    proof["digest"] = hashlib.sha256(encoded).hexdigest()
    return proof


def discard_proof_with_digest(body: dict[str, Any]) -> dict[str, Any]:
    """Attach an immutable digest to an explicit abandoned-handback discard."""

    proof = dict(body)
    encoded = json.dumps(
        body, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    proof["digest"] = hashlib.sha256(encoded).hexdigest()
    return proof


def superseded_proof_with_digest(body: dict[str, Any]) -> dict[str, Any]:
    """Attach an immutable superseded-by-merged-PR proof digest."""

    return _superseded_proof_with_digest(body)


def terminal_proof_problem(
    proof: object,
    *,
    branch: object,
    head_sha: object,
    record_external_ids: object,
) -> str | None:
    if not isinstance(proof, dict):
        return "terminal proof must be an object"
    digest = proof.get("digest")
    body = {key: value for key, value in proof.items() if key != "digest"}
    encoded = json.dumps(
        body, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    if digest != hashlib.sha256(encoded).hexdigest():
        return "terminal proof digest is invalid"
    if not isinstance(record_external_ids, list):
        return "terminal proof record has invalid external ids"
    expected = {
        "schema": TERMINAL_PROOF_SCHEMA,
        "pr_state": "MERGED",
        "base_branch": "main",
        "branch": branch,
        "head_sha": head_sha,
    }
    for key, value in expected.items():
        if body.get(key) != value:
            return f"terminal proof {key} does not match exact merged PR"
    if "merged_head_sha" in body:
        # Optional: "Update branch" moved the merged PR head past the lane tip.
        # Cleanup proves that containment in git before writing the proof; the
        # registry keeps the merged head beside the lane head it terminalizes.
        merged_head = body["merged_head_sha"]
        if (
            not isinstance(merged_head, str)
            or COMMIT_SHA_RE.fullmatch(merged_head) is None
            or merged_head == body.get("head_sha")
        ):
            return "terminal proof merged head is invalid"
    if type(body.get("pr_number")) is not int or body["pr_number"] <= 0:
        return "terminal proof PR number is invalid"
    lane_id = body.get("lane_id")
    # Direct assignments intentionally have no Issue/PR external ID.  The
    # registry parser uses the branch as their canonical lane identity, so
    # terminal proof validation must use the same fallback instead of making
    # an empty external-id list an impossible cleanup claim.
    allowed_lane_ids = record_external_ids or [branch]
    if type(lane_id) is not str or lane_id not in allowed_lane_ids:
        return "terminal proof lane does not match the registry claim"
    return None


def stored_terminal_proof_problem(record: dict[str, Any]) -> str | None:
    if "terminal_proof" not in record:
        return None
    if record.get("status") != STATUS_MERGED:
        return "terminal proof is only valid for merged disposition"
    proof = record["terminal_proof"]
    stored_head = record.get("handed_back_sha")
    if stored_head is None and isinstance(proof, dict):
        # Older exact terminal transitions may not have a hand-back receipt.
        # Their validated head remains durable inside the immutable proof.
        stored_head = proof.get("head_sha")
    return terminal_proof_problem(
        proof,
        branch=record.get("branch"),
        head_sha=stored_head,
        record_external_ids=record.get("external_ids"),
    )


def discard_proof_problem(record: dict[str, Any]) -> str | None:
    """Validate the optional proof that an abandoned handback was discarded."""

    proof = record.get("discard_proof")
    if proof is None:
        return None
    if record.get("status") != STATUS_ABANDONED:
        return "discard proof is only valid for abandoned disposition"
    if not isinstance(proof, dict):
        return "discard proof must be an object"
    digest = proof.get("digest")
    body = {key: value for key, value in proof.items() if key != "digest"}
    encoded = json.dumps(
        body, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    if digest != hashlib.sha256(encoded).hexdigest():
        return "discard proof digest is invalid"
    expected = {
        "schema": DISCARD_PROOF_SCHEMA,
        "disposition": DISCARD_PROOF_DISPOSITION,
        "branch": record.get("branch"),
        "head_sha": record.get("handed_back_sha"),
        "claim_generation": record.get("claim_generation"),
        "base_sha": record.get("base_sha"),
    }
    for key, value in expected.items():
        if body.get(key) != value:
            return f"discard proof {key} does not match abandoned handback"
    lane_id = body.get("lane_id")
    allowed_lane_ids = record.get("external_ids") or [record.get("branch")]
    if type(lane_id) is not str or lane_id not in allowed_lane_ids:
        return "discard proof lane does not match the registry claim"
    for key in ("operator", "reason"):
        value = body.get(key)
        if type(value) is not str or not value.strip():
            return f"discard proof {key} must be non-empty text"
    seal = record.get("handback_seal")
    if isinstance(seal, dict) and isinstance(seal.get("digest"), str):
        if body.get("handback_digest") != seal["digest"]:
            return "discard proof handback digest does not match the stored seal"
    return None


def superseded_proof_problem(record: dict[str, Any]) -> str | None:
    """Validate an abandoned handback superseded by one exact merged PR."""

    proof = record.get("superseded_proof")
    if proof is None:
        return None
    if record.get("status") != STATUS_ABANDONED:
        return "superseded proof is only valid for abandoned disposition"
    if (problem := validate_superseded_proof_shape(proof)) is not None:
        return problem
    assert isinstance(proof, dict)
    digest = proof.get("digest")
    body = superseded_proof_body(proof)
    encoded = json.dumps(
        body, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    if digest != hashlib.sha256(encoded).hexdigest():
        return "superseded proof digest is invalid"
    canonical_base_sha = _record_base_sha(record)
    seal = record.get("handback_seal")
    sealed_base_sha = seal.get("base_sha") if isinstance(seal, dict) else None
    if (
        not isinstance(canonical_base_sha, str)
        or not _SHA_RE.fullmatch(canonical_base_sha)
        or not isinstance(sealed_base_sha, str)
        or not _SHA_RE.fullmatch(sealed_base_sha)
        or sealed_base_sha != canonical_base_sha
    ):
        return "superseded proof base_sha does not match abandoned handback"
    expected = {
        "schema": SUPERSEDED_PROOF_SCHEMA,
        "disposition": SUPERSEDED_PROOF_DISPOSITION,
        "branch": record.get("branch"),
        "handback_sha": record.get("handed_back_sha"),
        "claim_generation": record.get("claim_generation"),
        "base_sha": canonical_base_sha,
        "handback_digest": (
            record.get("handback_seal", {}).get("digest")
            if isinstance(record.get("handback_seal"), dict)
            else None
        ),
        "merged_pr_branch": record.get("branch"),
    }
    for key, value in expected.items():
        if body.get(key) != value:
            return f"superseded proof {key} does not match abandoned handback"
    allowed_lane_ids = record.get("external_ids") or [record.get("branch")]
    if body.get("lane_id") not in allowed_lane_ids:
        return "superseded proof lane does not match the registry claim"
    expected_paths = tuple(
        sorted(item.get("path") for item in scope_files(record.get("scope")))
    )
    if tuple(body.get("scope_paths", ())) != expected_paths:
        return "superseded proof Scope does not match the registry claim"
    return None


def normalize_record(
    value: object, *, index: int
) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    if not isinstance(value, dict):
        return None, [{"kind": "registry-record-not-object", "index": index}]
    record = dict(value)
    problems: list[dict[str, Any]] = []
    try:
        record["external_ids"] = legacy_external_ids(record)
    except (TypeError, ValueError) as exc:
        problems.append(
            {
                "kind": "registry-external-ids-invalid",
                "index": index,
                "branch": record.get("branch"),
                "status": record.get("status"),
                "reason": str(exc),
            }
        )
    else:
        record.pop("backlog", None)
    status = record.get("status")
    claim_generation = record.get("claim_generation")
    has_claim_lifecycle = any(
        record.get(field) is not None
        for field in ("created_at", "claimed_at", "resolved_at")
    )
    if ("claim_generation" in record or has_claim_lifecycle) and (
        type(claim_generation) is not int or claim_generation < 0
    ):
        problems.append(
            {
                "kind": "registry-claim-generation-invalid",
                "index": index,
                "branch": record.get("branch"),
                "status": status,
                "reason": "claim_generation must be a non-negative integer",
            }
        )
    if status not in KNOWN_STATUSES:
        problems.append(
            {
                "kind": "registry-status-unknown",
                "index": index,
                "branch": record.get("branch"),
                "status": status,
            }
        )
    scope_problem = _scope_record_problem(record)
    if scope_problem:
        kind, reason = scope_problem
        problems.append(
            {
                "kind": kind,
                "index": index,
                "branch": record.get("branch"),
                "status": status,
                "reason": reason,
                **(
                    {"field": "scope"}
                    if kind == "registry-record-missing-field"
                    else {}
                ),
            }
        )
    base_sha = _record_base_sha(record)
    if base_sha is not None and not _SHA_RE.fullmatch(base_sha):
        problems.append(
            {
                "kind": "registry-base-invalid",
                "index": index,
                "branch": record.get("branch"),
                "status": status,
                "reason": "registry base must be an exact commit SHA",
            }
        )
    proof_problem = stored_terminal_proof_problem(record)
    if proof_problem:
        problems.append(
            {
                "kind": "registry-terminal-proof-invalid",
                "index": index,
                "branch": record.get("branch"),
                "status": status,
                "reason": proof_problem,
            }
        )
    discard_problem = discard_proof_problem(record)
    if discard_problem:
        problems.append(
            {
                "kind": "registry-discard-proof-invalid",
                "index": index,
                "branch": record.get("branch"),
                "status": status,
                "reason": discard_problem,
            }
        )
    superseded_problem = superseded_proof_problem(record)
    if superseded_problem:
        problems.append(
            {
                "kind": "registry-superseded-proof-invalid",
                "index": index,
                "branch": record.get("branch"),
                "status": status,
                "reason": superseded_problem,
            }
        )
    return record, problems


def compact_record(record: dict[str, Any]) -> dict[str, Any]:
    compacted = {key: record[key] for key in CURRENT_RECORD_FIELDS if key in record}
    try:
        compacted["external_ids"] = legacy_external_ids(record)
    except (TypeError, ValueError):
        if "external_ids" in record:
            compacted["external_ids"] = record["external_ids"]
        elif "backlog" in record:
            compacted["backlog"] = record["backlog"]
    else:
        compacted.pop("backlog", None)
    return compacted


def record_matches(
    record: dict[str, Any], *, branch: str | None = None, path: str | None = None
) -> bool:
    return (branch is None or record.get("branch") == branch) and (
        path is None or norm_path(str(record.get("path") or "")) == norm_path(path)
    )


def records_with_status(
    state: dict[str, Any], statuses: frozenset[str] | set[str]
) -> list[dict[str, Any]]:
    return [
        record
        for record in state.get("records", [])
        if isinstance(record, dict) and record.get("status") in statuses
    ]


def active_records(state: dict[str, Any]) -> list[dict[str, Any]]:
    return records_with_status(state, {STATUS_ACTIVE})


def retained_records(state: dict[str, Any]) -> list[dict[str, Any]]:
    """Return every record retained by lossless registry compaction."""
    return [record for record in state.get("records", []) if isinstance(record, dict)]


def mutation_blockers(state: dict[str, Any]) -> list[dict[str, Any]]:
    """Return malformed ownership facts that make a ledger mutation unsafe."""
    return [
        problem
        for problem in state.get("problems", [])
        if isinstance(problem, dict) and problem.get("status") not in TERMINAL_STATUSES
    ]


def _problem_record(
    state: dict[str, Any], problem: dict[str, Any]
) -> dict[str, Any] | None:
    index = problem.get("index")
    if type(index) is not int:
        return None
    records = state.get("records", [])
    if index < 0 or index >= len(records):
        return None
    record = records[index]
    return record if isinstance(record, dict) else None


def _scope_paths(value: object) -> set[str] | None:
    if value is None:
        return set()
    if scope_problems(value):
        return None
    try:
        return {item["path"] for item in scope_files(value)}
    except (KeyError, TypeError, ValueError):
        return None


def _problem_overlaps_target(
    state: dict[str, Any],
    problem: dict[str, Any],
    *,
    branch: str | None,
    path: str | None,
    external_ids_value: object,
    scope: object,
) -> bool:
    """Return whether a malformed fact can affect one requested mutation.

    A malformed record remains fail-closed when its identity overlaps the
    requested branch/path/external ID/Scope, or when a supplied ownership fact
    cannot be compared safely.  A fully disjoint, structurally known record is
    intentionally not a global blocker.
    """

    record = _problem_record(state, problem)
    if record is None:
        return True
    if problem.get("kind") in GLOBAL_MUTATION_PROBLEM_KINDS:
        return True
    if branch is not None and record.get("branch") == branch:
        return True
    if path is not None and norm_path(str(record.get("path") or "")) == norm_path(path):
        return True

    if external_ids_value is not None:
        try:
            wanted_ids = set(external_ids(external_ids_value))
            record_ids = set(legacy_external_ids(record))
        except (TypeError, ValueError):
            return bool(wanted_ids if "wanted_ids" in locals() else external_ids_value)
        if wanted_ids.intersection(record_ids):
            return True

    if scope is not None:
        wanted_scope = _scope_paths(scope)
        record_scope = _scope_paths(record.get("scope"))
        if wanted_scope is None or record_scope is None:
            return True
        if overlap_paths(wanted_scope, record_scope):
            return True
    return False


def mutation_blockers_for_target(
    state: dict[str, Any],
    *,
    branch: str | None = None,
    path: str | None = None,
    external_ids_value: object = None,
    scope: object = None,
) -> list[dict[str, Any]]:
    """Return malformed facts that can affect one scoped mutation.

    With no target selectors this deliberately retains the original global
    fail-closed semantics.  Callers that operate on a known claim or proposed
    exact Scope must provide the selectors explicitly.
    """

    if branch is None and path is None and external_ids_value is None and scope is None:
        return mutation_blockers(state)
    return [
        problem
        for problem in mutation_blockers(state)
        if _problem_overlaps_target(
            state,
            problem,
            branch=branch,
            path=path,
            external_ids_value=external_ids_value,
            scope=scope,
        )
    ]
