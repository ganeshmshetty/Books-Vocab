"""Mutation commands for the worktree-registry adapter."""

from __future__ import annotations

import json
from collections.abc import Mapping

from worktree_registry_core.lifecycle import (
    TERMINAL_PROOF_SCHEMA,
    terminal_proof_with_digest,
)

from ..domain.errors import CompareAndSwapConflict
from ..domain.models import MergedPullRequestProof
from ..ports.process import CommandRunnerPort
from .errors import AdapterPayloadError


def resolve_registry(
    *,
    runner: CommandRunnerPort,
    argv: tuple[str, ...],
    lane_id: str,
    disposition: str,
    terminal_proof: MergedPullRequestProof | None,
) -> None:
    if terminal_proof is not None:
        body: dict[str, object] = {
            "schema": TERMINAL_PROOF_SCHEMA,
            "lane_id": terminal_proof.lane_id,
            "pr_number": terminal_proof.pr_number,
            "pr_state": terminal_proof.pr_state,
            "base_branch": terminal_proof.base_branch,
            "branch": terminal_proof.branch,
            "head_sha": terminal_proof.head_sha,
        }
        if terminal_proof.merged_head_sha is not None:
            body["merged_head_sha"] = terminal_proof.merged_head_sha
        proof_payload = terminal_proof_with_digest(body)
        argv = (
            *argv,
            "--terminal-proof",
            json.dumps(proof_payload, sort_keys=True),
        )
    result = runner.run(argv)
    if result.exit_code != 0:
        raise CompareAndSwapConflict(
            f"registry transition failed for {lane_id}: {result.stderr or result.stdout}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AdapterPayloadError("registry resolve returned invalid JSON") from error
    if (
        not isinstance(payload, Mapping)
        or payload.get("status") != disposition
        or not isinstance(payload.get("records"), list)
        or len(payload["records"]) != 1
    ):
        raise AdapterPayloadError("registry resolve readback is not exact")


def record_published_base(
    *,
    runner: CommandRunnerPort,
    argv: tuple[str, ...],
    lane_id: str,
) -> None:
    """Persist one exact PR-base observation with registry CAS guards."""

    result = runner.run(argv)
    if result.exit_code != 0:
        raise CompareAndSwapConflict(
            f"published-base recording failed for {lane_id}: "
            f"{result.stderr or result.stdout}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AdapterPayloadError(
            "registry published-base recording returned invalid JSON"
        ) from error
    if (
        not isinstance(payload, Mapping)
        or payload.get("status") != "published-base-recorded"
        or not isinstance(payload.get("records"), list)
        or len(payload["records"]) != 1
    ):
        raise AdapterPayloadError("registry published-base readback is not exact")


def discard_registry(
    *,
    runner: CommandRunnerPort,
    argv: tuple[str, ...],
    lane_id: str,
) -> None:
    """Persist and read back one explicit abandoned-handback discard proof."""

    result = runner.run(argv)
    if result.exit_code != 0:
        raise CompareAndSwapConflict(
            f"discard proof recording failed for {lane_id}: "
            f"{result.stderr or result.stdout}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AdapterPayloadError("registry discard returned invalid JSON") from error
    if (
        not isinstance(payload, Mapping)
        or payload.get("action") != "discard"
        or payload.get("status") != "abandoned"
        or not isinstance(payload.get("records"), list)
        or len(payload["records"]) != 1
        or not isinstance(payload["records"][0], Mapping)
        or not isinstance(payload["records"][0].get("discard_proof"), Mapping)
    ):
        raise AdapterPayloadError("registry discard readback is not exact")


def supersede_registry(
    *,
    runner: CommandRunnerPort,
    argv: tuple[str, ...],
    lane_id: str,
) -> None:
    """Persist and read back one superseded-handback proof."""

    result = runner.run(argv)
    if result.exit_code != 0:
        raise CompareAndSwapConflict(
            f"superseded proof recording failed for {lane_id}: "
            f"{result.stderr or result.stdout}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AdapterPayloadError("registry supersede returned invalid JSON") from error
    if (
        not isinstance(payload, Mapping)
        or payload.get("action") != "supersede"
        or payload.get("status") != "abandoned"
        or not isinstance(payload.get("records"), list)
        or len(payload["records"]) != 1
        or not isinstance(payload["records"][0], Mapping)
        or not isinstance(payload["records"][0].get("superseded_proof"), Mapping)
    ):
        raise AdapterPayloadError("registry supersede readback is not exact")
