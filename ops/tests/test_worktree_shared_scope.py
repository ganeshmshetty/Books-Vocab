from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))
import worktree_registry as registry
from lib import worktree_scope
from lib.worktree_scope import SHARED_SCOPE_FILES
from worktree_registry_core import records as records_module


def _register(state: dict, name: str, tmp_path: Path, *paths: str) -> tuple[int, dict]:
    return registry._register_record(
        state,
        branch=f"feat/{name}",
        path=str(tmp_path / name),
        intent=name,
        base="main",
        external_ids=[],
        scope={
            "schema": "kg.worktree.scope.v1",
            "files": [{"path": p, "operation": "modify"} for p in paths],
        },
    )


def test_shared_allowlisted_files_do_not_serialize_lanes(tmp_path: Path) -> None:
    assert "ops/complexity_budget.json" in SHARED_SCOPE_FILES
    state = {"schema": registry.SCHEMA, "records": []}
    first_rc, _ = _register(
        state, "one", tmp_path, "ops/complexity_budget.json", "ops/a.py"
    )
    second_rc, refusal = _register(
        state, "two", tmp_path, "ops/complexity_budget.json", "ops/b.py"
    )

    assert first_rc == registry.EXIT_OK
    assert second_rc == registry.EXIT_OK, refusal
    # Still recorded exactly in Scope; only exempt from exclusivity.
    recorded = state["records"][1]["scope"]["files"]
    assert {"path": "ops/complexity_budget.json", "operation": "modify"} in recorded


def test_shared_file_exemption_does_not_hide_real_overlap(tmp_path: Path) -> None:
    state = {"schema": registry.SCHEMA, "records": []}
    _register(state, "one", tmp_path, "ops/complexity_budget.json", "ops/a.py")
    rc, refusal = _register(
        state, "two", tmp_path, "ops/complexity_budget.json", "ops/a.py"
    )

    assert rc == registry.EXIT_CLAIMED
    assert refusal["owners"][0]["scope_paths"] == ["ops/a.py"]


def test_non_allowlisted_file_stays_exclusive(tmp_path: Path) -> None:
    state = {"schema": registry.SCHEMA, "records": []}
    _register(state, "one", tmp_path, "ops/other.py")
    rc, _ = _register(state, "two", tmp_path, "ops/other.py")
    assert rc == registry.EXIT_CLAIMED


@pytest.mark.parametrize(
    "neighbour",
    ["ops/test_ops.sh.orig", "ops/tests/test_doctor.py", "ops/tests/test_ops.sh"],
)
def test_neighbours_of_registration_files_stay_exclusive(
    tmp_path: Path, neighbour: str
) -> None:
    assert neighbour not in SHARED_SCOPE_FILES
    state = {"schema": registry.SCHEMA, "records": []}
    _register(state, "one", tmp_path, neighbour)
    rc, _ = _register(state, "two", tmp_path, neighbour)
    assert rc == registry.EXIT_CLAIMED


REGISTRATION_FILES = ("ops/test_ops.sh", "ops/tests/test_ops_ci_coverage.sh")


@pytest.mark.parametrize("shared", REGISTRATION_FILES)
def test_group_registration_files_do_not_serialize_lanes(
    tmp_path: Path, shared: str
) -> None:
    # Many queued lanes each add or remove a group-registration line here, in
    # different arms; exclusive Scope would force them into serial cycles.
    assert shared in SHARED_SCOPE_FILES
    state = {"schema": registry.SCHEMA, "records": []}
    first_rc, _ = _register(state, "one", tmp_path, shared, "ops/a.py")
    second_rc, refusal = _register(state, "two", tmp_path, shared, "ops/b.py")
    third_rc, refusal3 = _register(state, "three", tmp_path, shared)

    assert (first_rc, second_rc, third_rc) == (registry.EXIT_OK,) * 3, (
        refusal,
        refusal3,
    )
    for record, other in zip(state["records"], ("ops/a.py", "ops/b.py", None)):
        paths = [item["path"] for item in record["scope"]["files"]]
        assert shared in paths and (other is None or other in paths)


@pytest.mark.parametrize("shared", REGISTRATION_FILES)
def test_group_registration_file_does_not_hide_real_overlap(
    tmp_path: Path, shared: str
) -> None:
    state = {"schema": registry.SCHEMA, "records": []}
    _register(state, "one", tmp_path, shared, "ops/a.py")
    rc, refusal = _register(state, "two", tmp_path, shared, "ops/a.py")

    assert rc == registry.EXIT_CLAIMED
    assert refusal["owners"][0]["scope_paths"] == ["ops/a.py"]


def test_every_shared_file_is_justified_in_the_delivery_model() -> None:
    doc = (OPS.parent / "docs/reference/delivery_model.md").read_text()
    undocumented = sorted(p for p in SHARED_SCOPE_FILES if f"`{p}`" not in doc)
    assert undocumented == []


def test_allowlist_is_exact_existing_canonical_paths() -> None:
    root = OPS.parent
    for path in SHARED_SCOPE_FILES:
        assert worktree_scope._normalise_path(path) == (path, None), path
        assert "*" not in path and "?" not in path and "[" not in path, path
        assert (root / path).is_file(), f"stale allowlist entry: {path}"
    assert SHARED_SCOPE_FILES == {
        "docs/reference/tech_index.md",
        "docs/registry.yml",
        "ops/complexity_budget.json",
        "ops/test_ops.sh",
        "ops/tests/test_ops_ci_coverage.sh",
        *LOCALIZABLE_CATALOGS,
    }


LOCALIZABLE_CATALOGS = (
    "ios/BooksAndVocab/en.lproj/Localizable.strings",
    "ios/BooksAndVocab/ja.lproj/Localizable.strings",
    "ios/BooksAndVocab/ko.lproj/Localizable.strings",
    "ios/BooksAndVocab/zh-Hans.lproj/Localizable.strings",
    "ios/BooksAndVocab/zh-Hant.lproj/Localizable.strings",
)


def test_localizable_catalogs_are_shared_and_other_ios_files_stay_exclusive() -> None:
    for catalog in LOCALIZABLE_CATALOGS:
        assert catalog in SHARED_SCOPE_FILES, catalog
        # Two lanes that only touch catalogs do not collide ...
        assert worktree_scope.overlap_paths({catalog, "ops/a.py"}, {catalog}) == set()
    # ... but a real overlap on any other iOS file still does.
    other = "ios/BooksAndVocab/Views/Home.swift"
    assert other not in SHARED_SCOPE_FILES
    assert worktree_scope.overlap_paths({other}, {other}) == {other}


def test_overlap_paths_subtracts_only_exact_allowlisted_files() -> None:
    shared = "ops/complexity_budget.json"
    assert worktree_scope.overlap_paths({shared, "ops/a.py"}, {shared}) == set()
    assert worktree_scope.overlap_paths({shared, "ops/a.py"}, [shared, "ops/a.py"]) == {
        "ops/a.py"
    }
    # Same directory / look-alike names stay exclusive.
    assert (
        worktree_scope.overlap_paths({"ops/complexity_budget.json.bak"}, {shared})
        == set()
    )
    assert worktree_scope.overlap_paths({"ops/other.json"}, {"ops/other.json"}) == {
        "ops/other.json"
    }


def _scope_arg(*paths: str) -> str:
    return json.dumps(
        {
            "schema": "kg.worktree.scope.v1",
            "files": [{"path": p, "operation": "modify"} for p in paths],
        }
    )


def _scope_set(state_path: Path, tmp_path: Path, name: str, *paths: str) -> int:
    return registry.main(
        [
            "scope-set",
            "--state",
            str(state_path),
            "--branch",
            f"feat/{name}",
            "--path",
            str(tmp_path / name),
            "--scope",
            _scope_arg(*paths),
            "--json",
        ]
    )


def _two_active_lanes(tmp_path: Path) -> Path:
    state_path = tmp_path / "registry.json"
    records = [
        {
            "branch": f"feat/{name}",
            "path": str(tmp_path / name),
            "status": "active",
            "external_ids": [name.upper()],
            "scope": json.loads(_scope_arg(*paths)),
            "claim_generation": 1,
        }
        for name, paths in (
            ("one", ("ops/complexity_budget.json", "ops/a.py")),
            ("two", ("ops/b.py",)),
        )
    ]
    registry.save_state(state_path, {"schema": registry.SCHEMA, "records": records})
    return state_path


def test_scope_set_allows_shared_overlap_and_records_it_exactly(
    tmp_path: Path, capsys
) -> None:
    state_path = _two_active_lanes(tmp_path)

    rc = _scope_set(
        state_path, tmp_path, "two", "ops/complexity_budget.json", "ops/b.py"
    )

    capsys.readouterr()
    assert rc == registry.EXIT_OK
    stored = registry.load_state(state_path)["records"][1]["scope"]["files"]
    assert [item["path"] for item in stored] == [
        "ops/complexity_budget.json",
        "ops/b.py",
    ]


def test_scope_set_still_refuses_exclusive_overlap_beside_shared_file(
    tmp_path: Path, capsys
) -> None:
    state_path = _two_active_lanes(tmp_path)

    rc = _scope_set(
        state_path, tmp_path, "two", "ops/complexity_budget.json", "ops/a.py"
    )

    out = json.loads(capsys.readouterr().out)
    assert rc == registry.EXIT_CLAIMED
    assert out["owners"][0]["scope_paths"] == ["ops/a.py"]


def test_malformed_record_sharing_only_an_allowlisted_file_is_not_a_blocker() -> None:
    shared = "ops/complexity_budget.json"
    state = {
        "records": [
            {
                "branch": "feat/x",
                "path": "/tmp/x",
                "scope": json.loads(_scope_arg(shared)),
            }
        ]
    }
    problem = {"kind": "record-malformed", "index": 0}

    def overlaps(*paths: str) -> bool:
        return records_module._problem_overlaps_target(
            state,
            problem,
            branch="feat/y",
            path="/tmp/y",
            external_ids_value=None,
            scope=json.loads(_scope_arg(*paths)),
        )

    assert overlaps(shared) is False
    assert overlaps(shared, "ops/a.py") is False
    state["records"][0]["scope"] = json.loads(_scope_arg(shared, "ops/a.py"))
    assert overlaps(shared, "ops/a.py") is True


# Written-contract guard: every place that states "one file, one active worktree"
# must name the SHARED_SCOPE_FILES exception, or agents and the registry follow
# two different rules.
_EXCLUSIVITY_RULE = re.compile(
    r"同一檔案不可|同時碰同一檔案|(?:兩個|多個)\s*active worktree"
    r"|two active worktrees?|claimed by two",
    re.IGNORECASE,
)
_RULE_FILES = ("CLAUDE.md", "AGENTS.md", ".claude/skills/worktree-flow/SKILL.md")


def _unqualified_exclusivity_statements(text: str) -> list[str]:
    return [
        line.strip()
        for line in text.splitlines()
        if _EXCLUSIVITY_RULE.search(line)
        and not ("SHARED_SCOPE_FILES" in line and "delivery_model.md" in line)
    ]


def test_exclusivity_detector_flags_an_unqualified_rule() -> None:
    bare = "同一檔案不可被兩個 active worktree 同時認領。"
    assert _unqualified_exclusivity_statements(bare) == [bare]
    qualified = (
        bare + "例外見 `SHARED_SCOPE_FILES`（`docs/reference/delivery_model.md`）。"
    )
    assert _unqualified_exclusivity_statements(qualified) == []


@pytest.mark.parametrize("name", _RULE_FILES)
def test_exclusivity_rule_statements_name_the_shared_scope_allowlist(
    name: str,
) -> None:
    root = OPS.parent
    text = (root / name).read_text()
    assert _EXCLUSIVITY_RULE.search(text), f"{name} no longer states the rule"
    assert _unqualified_exclusivity_statements(text) == []


def test_no_doc_states_exclusivity_without_the_allowlist() -> None:
    root = OPS.parent
    offenders = {}
    for pattern in ("docs/**/*.md", ".claude/**/*.md"):
        for path in sorted(root.glob(pattern)):
            found = _unqualified_exclusivity_statements(path.read_text())
            if found:
                offenders[str(path.relative_to(root))] = found
    assert offenders == {}


# Written-contract guard (#2648): the delegation prompt contract must live in
# both the skill and the delivery model, or dispatchers silently drop a rule.
_DELEGATION_CONTRACT_FILES = (
    ".claude/skills/worktree-flow/SKILL.md",
    "docs/reference/delivery_model.md",
)
_DELEGATION_CONTRACT_TERMS = {
    "shell hygiene": ("Delegation prompt contract", "Write/Edit", "bash <file>"),
    "liveness": ("20 分鐘", "tool_use"),
    "published PR": ("redeliver", "已 publish 或已關閉"),
    "forwarded tasks": ("轉送",),
}


@pytest.mark.parametrize("name", _DELEGATION_CONTRACT_FILES)
@pytest.mark.parametrize("rule", sorted(_DELEGATION_CONTRACT_TERMS))
def test_delegation_prompt_contract_is_written_down(name: str, rule: str) -> None:
    text = (OPS.parent / name).read_text()
    missing = [t for t in _DELEGATION_CONTRACT_TERMS[rule] if t not in text]
    assert missing == [], f"{name} lacks delegation rule {rule!r}: {missing}"
