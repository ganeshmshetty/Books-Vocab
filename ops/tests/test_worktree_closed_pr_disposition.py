"""Regression for #2979: a cleanup_pending lease whose PR is CLOSED unmerged.

The orchestrator's ``resolve --status abandoned`` refuses this shape and points
at a closed-PR disposition flow; ``dispose-closed-pr`` is that flow.  It must
release the lease's Scope only for the exact claimed HEAD and keep every other
PR shape (OPEN, MERGED, moved HEAD, no PR history) refused.
"""

from __future__ import annotations

import json
import sys
from argparse import Namespace
from pathlib import Path
from typing import Any

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

import worktree_orchestrate as coordinator
from worktree_registry_core.admission import ownership_conflicts

BRANCH = "debug/issue-2979-closed"
NEW_BRANCH = "debug/issue-2979-reopen"
HEAD = "a" * 40
SCOPE = {
    "schema": "kg.worktree.scope.v1",
    "files": [{"path": "ops/example.py", "operation": "modify"}],
}


def _state(tmp_path: Path) -> Path:
    state_path = tmp_path / "registry.json"
    state_path.write_text(
        json.dumps(
            {
                "schema": "kg.worktree.registry.v1",
                "records": [
                    {
                        "branch": BRANCH,
                        "path": str(tmp_path / "gone"),
                        "status": "cleanup_pending",
                        "external_ids": ["2979"],
                        "claim_generation": 0,
                        "handed_back_sha": HEAD,
                        "scope": SCOPE,
                    }
                ],
            }
        )
    )
    return state_path


def _records(state_path: Path) -> list[dict[str, Any]]:
    state = json.loads(state_path.read_text())
    return state["records"]


def _scope_owners(state_path: Path, tmp_path: Path) -> list[dict[str, Any]]:
    state = json.loads(state_path.read_text())
    return ownership_conflicts(
        state,
        branch=NEW_BRANCH,
        path=str(tmp_path / "reopen"),
        external_ids=[],
        scope=SCOPE,
    )


def _pr(number: int, state: str, head: str) -> Namespace:
    return Namespace(number=number, branch=BRANCH, head_sha=head, state=state)


def _fake_pulls(monkeypatch: pytest.MonkeyPatch, pulls: list[tuple[str, str]]) -> None:
    monkeypatch.setattr(
        coordinator,
        "_branch_pull_request_snapshots",
        lambda repo, name: tuple(
            _pr(index + 1, state, head) for index, (state, head) in enumerate(pulls)
        ),
    )


def _dispose_argv(
    state_path: Path, *, generation: int = 0, head: str = HEAD
) -> list[str]:
    return [
        "dispose-closed-pr",
        "--branch",
        BRANCH,
        "--expected-generation",
        str(generation),
        "--expected-head-sha",
        head,
        "--state",
        str(state_path),
        "--json",
    ]


def test_dispose_closed_pr_releases_scope_for_closed_unmerged_lease(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    state_path = _state(tmp_path)
    _fake_pulls(monkeypatch, [("CLOSED", HEAD)])
    # Reproduces #2979: the cleanup_pending lease blocks Scope admission.
    assert _scope_owners(state_path, tmp_path)

    rc = coordinator.main(_dispose_argv(state_path))

    assert rc == coordinator.EXIT_OK
    assert capsys.readouterr().err == ""
    (record,) = _records(state_path)
    assert record["status"] == "abandoned"
    # The handback proof is preserved; only the lifecycle status moves.
    assert record["handed_back_sha"] == HEAD
    assert record["scope"] == SCOPE
    assert _scope_owners(state_path, tmp_path) == []


@pytest.mark.parametrize(
    ("pulls", "head"),
    [
        # OPEN PR keeps the lease
        ([("OPEN", HEAD)], HEAD),
        # MERGED PR belongs to resolve's merged path, never this one
        ([("MERGED", HEAD)], HEAD),
        # CLOSED at a moved HEAD proves nothing about the claimed HEAD
        ([("CLOSED", "9" * 40)], HEAD),
        # no PR history at all: the remote-branch rules still decide
        ([], HEAD),
        # any OPEN PR among the history keeps the lease
        ([("CLOSED", HEAD), ("OPEN", "8" * 40)], HEAD),
        # any MERGED or other-HEAD PR in the history keeps the lease
        ([("CLOSED", HEAD), ("MERGED", "9" * 40)], HEAD),
        # claimed HEAD argument that does not match the closed PR
        ([("CLOSED", HEAD)], "b" * 40),
    ],
)
def test_dispose_closed_pr_keeps_lease_for_every_other_pr_shape(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    pulls: list[tuple[str, str]],
    head: str,
) -> None:
    state_path = _state(tmp_path)
    _fake_pulls(monkeypatch, pulls)

    rc = coordinator.main(_dispose_argv(state_path, head=head))

    assert rc == coordinator.EXIT_BLOCK
    (record,) = _records(state_path)
    assert record["status"] == "cleanup_pending"
    assert _scope_owners(state_path, tmp_path)


def test_dispose_closed_pr_refuses_stale_generation_cas(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state_path = _state(tmp_path)
    _fake_pulls(monkeypatch, [("CLOSED", HEAD)])

    rc = coordinator.main(_dispose_argv(state_path, generation=1))

    assert rc != coordinator.EXIT_OK
    (record,) = _records(state_path)
    assert record["status"] == "cleanup_pending"


def test_resolve_abandoned_names_the_real_closed_pr_command(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    state_path = _state(tmp_path)
    _fake_pulls(monkeypatch, [("CLOSED", HEAD)])

    rc = coordinator.cmd_resolve(
        Namespace(
            status="abandoned",
            branch=BRANCH,
            path=None,
            state=str(state_path),
            json=True,
            expected_generation=0,
            expected_head_sha=HEAD,
            remove=False,
        )
    )

    assert rc == coordinator.EXIT_BLOCK
    err = capsys.readouterr().err
    assert "dispose-closed-pr" in err
    assert "closed-PR disposition flow" not in err
    (record,) = _records(state_path)
    assert record["status"] == "cleanup_pending"
