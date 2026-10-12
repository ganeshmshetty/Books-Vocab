from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))
import worktree_registry as registry


def _published_record(tmp_path: Path) -> dict:
    return {
        "branch": "feat/merged-proof",
        "path": str(tmp_path / "merged-proof"),
        "status": "published",
        "external_ids": ["ISSUE-1"],
        "claim_generation": 3,
        "handed_back_sha": "b" * 40,
    }


def _proof(
    record: dict,
    *,
    lane_id: str = "ISSUE-1",
    merged_head_sha: str | None = None,
) -> dict:
    body = {
        "schema": registry.TERMINAL_PROOF_SCHEMA,
        "lane_id": lane_id,
        "pr_number": 42,
        "pr_state": "MERGED",
        "base_branch": "main",
        "branch": record["branch"],
        "head_sha": record["handed_back_sha"],
    }
    if merged_head_sha is not None:
        body["merged_head_sha"] = merged_head_sha
    return registry.terminal_proof_with_digest(body)


def _resolve_args(state_path: Path, record: dict) -> list[str]:
    return [
        "resolve",
        "--state",
        str(state_path),
        "--branch",
        record["branch"],
        "--path",
        record["path"],
        "--status",
        "merged",
        "--expected-generation",
        "3",
        "--expected-head-sha",
        record["handed_back_sha"],
        "--json",
    ]


def test_merged_transition_requires_typed_exact_pr_proof(tmp_path: Path) -> None:
    record = _published_record(tmp_path)
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})

    missing = registry.main(_resolve_args(state_path, record))
    tampered_proof = _proof(record)
    tampered_proof["base_branch"] = "release"
    tampered = registry.main(
        _resolve_args(state_path, record)
        + ["--terminal-proof", json.dumps(tampered_proof)]
    )
    exact_proof = _proof(record)
    exact = registry.main(
        _resolve_args(state_path, record)
        + ["--terminal-proof", json.dumps(exact_proof)]
    )

    assert missing == registry.EXIT_CLAIMED
    assert tampered == registry.EXIT_CLAIMED
    assert exact == registry.EXIT_OK
    resolved = registry.load_state(state_path)["records"][0]
    assert resolved["status"] == "merged"
    assert resolved["terminal_proof"] == exact_proof


def test_merged_transition_records_a_merged_head_beyond_the_lane_head(
    tmp_path: Path,
) -> None:
    # #3323: "Update branch" leaves the merged PR head past the lane tip; the
    # proof keeps the lane head and carries the merged head beside it.
    record = _published_record(tmp_path)
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})
    proof = _proof(record, merged_head_sha="c" * 40)

    result = registry.main(
        _resolve_args(state_path, record) + ["--terminal-proof", json.dumps(proof)]
    )

    assert result == registry.EXIT_OK
    resolved = registry.load_state(state_path)["records"][0]
    assert resolved["terminal_proof"] == proof
    assert resolved["terminal_proof"]["merged_head_sha"] == "c" * 40


def test_merged_transition_refuses_malformed_equal_or_tampered_merged_head(
    tmp_path: Path,
) -> None:
    record = _published_record(tmp_path)
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})
    tampered = _proof(record, merged_head_sha="c" * 40)
    tampered["merged_head_sha"] = "e" * 40
    refused = [
        _proof(record, merged_head_sha="not-a-sha"),
        _proof(record, merged_head_sha=record["handed_back_sha"]),
        tampered,
    ]

    for proof in refused:
        result = registry.main(
            _resolve_args(state_path, record) + ["--terminal-proof", json.dumps(proof)]
        )
        assert result == registry.EXIT_CLAIMED

    assert registry.load_state(state_path)["records"][0]["status"] == "published"


def test_direct_assignment_merged_transition_uses_branch_as_lane_identity(
    tmp_path: Path,
) -> None:
    record = _published_record(tmp_path)
    record["external_ids"] = []
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})

    proof = _proof(record, lane_id=record["branch"])
    result = registry.main(
        _resolve_args(state_path, record) + ["--terminal-proof", json.dumps(proof)]
    )

    assert result == registry.EXIT_OK
    resolved = registry.load_state(state_path)["records"][0]
    assert resolved["status"] == "merged"
    assert resolved["terminal_proof"] == proof


def test_abandoned_handback_discard_requires_exact_head_and_is_idempotent(
    tmp_path: Path,
) -> None:
    record = {
        "branch": "feat/abandoned-handback",
        "path": str(tmp_path / "abandoned-handback"),
        "status": "abandoned",
        "external_ids": ["DIRECT-1"],
        "claim_generation": 4,
        "base_sha": "a" * 40,
        "handed_back_sha": "b" * 40,
    }
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})
    args = [
        "discard",
        "--state",
        str(state_path),
        "--branch",
        record["branch"],
        "--path",
        record["path"],
        "--expected-generation",
        "4",
        "--expected-head-sha",
        record["handed_back_sha"],
        "--operator",
        "supervisor",
        "--reason",
        "ownerless clean handback explicitly discarded",
        "--json",
    ]

    wrong_head = registry.main(
        [
            *args[: args.index("--expected-head-sha") + 1],
            "c" * 40,
            *args[args.index("--operator") :],
        ]
    )
    first = registry.main(args)
    second = registry.main(args)
    different_reason = registry.main(
        [
            *args[: args.index("--reason") + 1],
            "different reason",
            "--json",
        ]
    )

    assert wrong_head == registry.EXIT_CLAIMED
    assert first == registry.EXIT_OK
    assert second == registry.EXIT_OK
    assert different_reason == registry.EXIT_CLAIMED
    persisted = registry.load_state(state_path)["records"][0]
    assert persisted["status"] == "abandoned"
    assert persisted["discard_proof"]["schema"] == "kg.worktree.discard-proof.v1"
    assert persisted["discard_proof"]["head_sha"] == record["handed_back_sha"]


def test_branchless_active_claim_is_abandoned_against_its_exact_base(
    tmp_path: Path,
) -> None:
    """A claim with no handback and no local branch has its base as its head.

    Fresh claims store the commit under ``base`` (not ``base_sha``); without
    that fallback no exact head exists and an ownerless ghost claim could never
    be terminalized.
    """

    base = "a" * 40
    record = {
        "branch": "feat/no-such-local-branch-for-ghost-claim",
        "path": str(tmp_path / "ghost"),
        "status": "active",
        "external_ids": ["DIRECT-GHOST"],
        "base": base,
        "scope": {
            "schema": "kg.worktree.scope.v1",
            "files": [{"operation": "modify", "path": "ops/a.py"}],
        },
        "claim_generation": 2,
    }
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})

    def resolve(head: str) -> int:
        return registry.main(
            [
                "resolve",
                "--state",
                str(state_path),
                "--branch",
                record["branch"],
                "--path",
                record["path"],
                "--status",
                "abandoned",
                "--expected-generation",
                "2",
                "--expected-head-sha",
                head,
                "--json",
            ]
        )

    assert resolve("b" * 40) == registry.EXIT_CLAIMED
    assert registry.load_state(state_path)["records"][0]["status"] == "active"
    assert resolve(base) == registry.EXIT_OK
    assert registry.load_state(state_path)["records"][0]["status"] == "abandoned"


def _cleanup_pending_record(tmp_path: Path) -> dict:
    record = _published_record(tmp_path)
    record["status"] = "cleanup_pending"
    record["claim_generation"] = 0
    return record


def _abandon_args(
    state_path: Path, record: dict, *extra: str, status: str = "abandoned"
) -> list[str]:
    return [
        "resolve",
        "--state",
        str(state_path),
        "--branch",
        record["branch"],
        "--status",
        status,
        "--expected-generation",
        "0",
        "--expected-head-sha",
        record["handed_back_sha"],
        *extra,
    ]


def test_cleanup_pending_evidence_is_not_a_command_line_capability(
    tmp_path: Path, capsys
) -> None:
    record = _cleanup_pending_record(tmp_path)
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})

    with pytest.raises(SystemExit) as raised:
        registry.main(
            _abandon_args(state_path, record, "--cleanup-pending-evidence", "anything")
        )

    assert raised.value.code == 2
    assert "--cleanup-pending-evidence" in capsys.readouterr().err
    assert registry.load_state(state_path)["records"][0]["status"] == "cleanup_pending"


def test_cleanup_pending_lease_is_abandoned_only_with_cleanup_evidence(
    tmp_path: Path, capsys
) -> None:
    record = _cleanup_pending_record(tmp_path)
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})

    bare = registry.main(_abandon_args(state_path, record))
    refusal = capsys.readouterr().err
    blank = registry.main(
        _abandon_args(state_path, record), cleanup_pending_evidence=" "
    )
    wrong_target = registry.main(
        _abandon_args(state_path, record, status="published"),
        cleanup_pending_evidence="PR #7 MERGED",
    )

    assert bare == registry.EXIT_CLAIMED
    assert "status: actual 'cleanup_pending'" in refusal
    assert blank == registry.EXIT_USAGE
    assert wrong_target == registry.EXIT_USAGE
    assert registry.load_state(state_path)["records"][0]["status"] == "cleanup_pending"

    ok = registry.main(
        _abandon_args(state_path, record), cleanup_pending_evidence="PR #7 MERGED"
    )

    assert ok == registry.EXIT_OK
    assert registry.load_state(state_path)["records"][0]["status"] == "abandoned"


def test_transition_refusal_names_each_mismatched_field(tmp_path: Path, capsys) -> None:
    record = _cleanup_pending_record(tmp_path)
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})
    args = _abandon_args(state_path, record)
    args[args.index("--expected-head-sha") + 1] = "c" * 40

    assert registry.main(args) == registry.EXIT_CLAIMED
    err = capsys.readouterr().err
    assert f"head: expected {'c' * 40}, actual {'b' * 40}" in err
    assert "status: actual 'cleanup_pending'" in err

    args[args.index("--branch") + 1] = "no/such-branch"
    assert registry.main(args) == registry.EXIT_CLAIMED
    assert "no registry record for branch/path 'no/such-branch'" in (
        capsys.readouterr().err
    )
