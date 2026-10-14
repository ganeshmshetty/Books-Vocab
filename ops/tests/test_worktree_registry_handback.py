from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))
import worktree_registry as registry  # noqa: E402
from worktree_registry_core import environment  # noqa: E402


def _commit_file(worktree: Path, text: str, message: str) -> str:
    (worktree / "branch.txt").write_text(text, encoding="utf-8")
    for args in (
        ("add", "branch.txt"),
        (
            "-c",
            "user.name=Registry Test",
            "-c",
            "user.email=registry-test@example.invalid",
            "commit",
            "--quiet",
            "-m",
            message,
        ),
    ):
        rc, output = registry._git(list(args), worktree)
        assert rc == 0, output
    rc, head = registry._git(["rev-parse", "HEAD"], worktree)
    assert rc == 0, head
    return head


@pytest.fixture
def handback_lane(tmp_path: Path) -> tuple[Path, Path]:
    worktree = tmp_path / "worktree"
    worktree.mkdir()
    rc, output = registry._git(["init", "--quiet"], worktree)
    assert rc == 0, output
    rc, output = registry._git(["checkout", "--quiet", "-b", "feat/clock"], worktree)
    assert rc == 0, output
    base_sha = _commit_file(worktree, "base\n", "base")

    remote = tmp_path / "origin.git"
    rc, output = registry._git(["init", "--bare", "--quiet", str(remote)], tmp_path)
    assert rc == 0, output
    rc, output = registry._git(["remote", "add", "origin", str(remote)], worktree)
    assert rc == 0, output
    rc, output = registry._git(
        ["push", "--quiet", "origin", f"{base_sha}:refs/heads/main"], worktree
    )
    assert rc == 0, output
    _commit_file(worktree, "base\nchild\n", "branch tip")

    record = {
        "branch": "feat/clock",
        "path": str(worktree),
        "status": registry.STATUS_ACTIVE,
        "external_ids": ["ISSUE-3686"],
        "scope": {
            "schema": "kg.worktree.scope.v1",
            "files": [{"path": "ops/a.py", "operation": "modify"}],
        },
        "base": base_sha,
        "base_sha": base_sha,
        "claim_generation": 0,
        "handed_back_at": None,
        "handed_back_sha": None,
    }
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})
    return worktree, state_path


def test_handback_seal_uses_one_clock_read_across_second_boundary(
    handback_lane: tuple[Path, Path], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    worktree, state_path = handback_lane
    outcomes_path = tmp_path / "outcomes.json"
    outcomes_path.write_text("[]", encoding="utf-8")
    # Two clock reads straddling a whole-second boundary: a seal built from the
    # first read and a record built from the second can never match exactly.
    ticks = [
        dt.datetime(2026, 8, 19, 1, 0, 0, 999999, tzinfo=dt.timezone.utc),
        dt.datetime(2026, 8, 19, 1, 0, 1, 0, tzinfo=dt.timezone.utc),
    ]

    def fake_parse_at(value: str | None = None) -> dt.datetime:
        return ticks.pop(0) if len(ticks) > 1 else ticks[0]

    monkeypatch.setattr(environment, "parse_at", fake_parse_at)

    rc = registry.main(
        [
            "hand-back",
            "--state",
            str(state_path),
            "--branch",
            "feat/clock",
            "--path",
            str(worktree),
            "--outcomes",
            str(outcomes_path),
            "--json",
        ]
    )

    assert rc == registry.EXIT_OK
    stored = registry.load_state(state_path)["records"][0]
    assert stored["handback_seal"]["handed_back_at"] == stored["handed_back_at"]
    assert registry.validate_handback_seal(stored) == []


def test_delegation_change_advances_generation_and_invalidates_handback(
    tmp_path: Path,
) -> None:
    record = {
        "branch": "feat/delegation",
        "path": str(tmp_path / "delegation"),
        "status": "active",
        "external_ids": ["ISSUE-1"],
        "scope": {
            "schema": "kg.worktree.scope.v1",
            "files": [{"path": "ops/a.py", "operation": "modify"}],
        },
        "codex_thread_id": "owner-one",
        "delegated": False,
        "claim_generation": 7,
        "handback_claim_generation": 7,
        "handed_back_at": "2026-08-22T00:00:00Z",
        "handed_back_sha": "a" * 40,
        "handback_seal": {"digest": "old"},
        "handback_outcomes": [{"status": "passed"}],
    }
    state_path = tmp_path / "registry.json"
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": [record]})

    rc = registry.main(
        [
            "owner-bind",
            "--state",
            str(state_path),
            "--branch",
            record["branch"],
            "--codex-thread-id",
            "owner-one",
            "--delegated",
            "--json",
        ]
    )

    assert rc == registry.EXIT_OK
    stored = registry.load_state(state_path)["records"][0]
    assert stored["delegated"] is True
    assert stored["claim_generation"] == 8
    assert stored["handed_back_at"] is None
    assert stored["handed_back_sha"] is None
    assert "handback_claim_generation" not in stored
    assert "handback_seal" not in stored
    assert "handback_outcomes" not in stored
