from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

import disk_usage
from disk_usage import BLOCKED_EXIT, main


@pytest.fixture(autouse=True)
def isolate_host_xctest_devices(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Never let unit tests inspect the operator's real XCTestDevices store."""

    monkeypatch.setenv("KG_XCTEST_DEVICES_ROOT", str(tmp_path / "XCTestDevices"))
    monkeypatch.setattr(
        disk_usage,
        "_discover_simulator_runtimes",
        lambda **_: ([], []),
        raising=False,
    )


def _run_git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=cwd, check=True, stdout=subprocess.DEVNULL)


def _repo_with_worktree(tmp_path: Path) -> tuple[Path, Path]:
    repo = tmp_path / "repo"
    repo.mkdir()
    _run_git(repo, "init", "-b", "main")
    _run_git(repo, "config", "user.email", "test@example.com")
    _run_git(repo, "config", "user.name", "Disk Test")
    (repo / "tracked.txt").write_text("main\n", encoding="utf-8")
    _run_git(repo, "add", "tracked.txt")
    _run_git(repo, "commit", "-m", "initial")
    worktree = tmp_path / "lane-one"
    _run_git(repo, "worktree", "add", "-b", "lane-one", str(worktree), "main")
    (worktree / "lane.txt").write_bytes(b"lane\n" * 128)
    _run_git(worktree, "add", "lane.txt")
    _run_git(worktree, "commit", "-m", "lane fixture")
    return repo, worktree


def _write_registry(path: Path, records: list[dict[str, object]]) -> None:
    path.write_text(
        json.dumps({"schema": "kg.worktree.registry.v2", "records": records}),
        encoding="utf-8",
    )


def test_measure_tree_does_not_resolve_each_entry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = tmp_path / "tree"
    root.mkdir()
    for index in range(20):
        (root / f"file-{index}").write_bytes(b"x")

    original = disk_usage._path
    calls: list[str | Path] = []

    def tracking(value: str | Path) -> Path:
        calls.append(value)
        return original(value)

    monkeypatch.setattr(disk_usage, "_path", tracking)

    report = disk_usage.measure_tree(root)

    assert report["complete"] is True
    assert report["files"] == 20
    assert len(calls) <= 1


def test_measure_tree_skips_git_metadata_by_default(tmp_path: Path) -> None:
    root = tmp_path / "tree"
    root.mkdir()
    project_file = root / "project.txt"
    project_file.write_bytes(b"project\n")
    git_objects = root / ".git" / "objects" / "pack"
    git_objects.mkdir(parents=True)
    (git_objects / "large.pack").write_bytes(b"git-object\n" * 4096)

    report = disk_usage.measure_tree(root)

    assert report["complete"] is True
    assert report["files"] == 1
    assert report["logical_bytes"] == project_file.stat().st_size
    assert report["allocated_bytes"] == disk_usage._allocated_bytes(project_file.stat())


def test_lane_measurement_excludes_nested_registered_worktree(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    nested = worktree / "nested-lane"
    nested.mkdir()
    (nested / "nested.txt").write_bytes(b"nested\n")
    state = tmp_path / "registry.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
            },
            {
                "branch": "nested-lane",
                "path": str(nested),
                "status": "active",
                "claim_generation": 0,
            },
        ],
    )
    original_measure_tree = disk_usage.measure_tree
    exclusions: dict[str, set[Path]] = {}

    def tracking_measure_tree(root: Path, **kwargs: object) -> dict[str, object]:
        exclusions[str(root)] = set(kwargs.get("excluded", set()))
        return original_measure_tree(root, **kwargs)

    monkeypatch.setattr(disk_usage, "measure_tree", tracking_measure_tree)

    disk_usage.build_report(repo, state, time_budget_seconds=5)

    assert nested in exclusions[str(worktree)]


def test_report_attributes_registered_lanes_and_canonical_main(tmp_path: Path) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-TEST"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 0
    )

    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["schema"] == "kg.disk.lane-usage.v1"
    by_path = {item["path"]: item for item in report["lanes"]}
    assert by_path[str(worktree)]["registry_status"] == "active"
    assert by_path[str(worktree)]["ownership"] == "registered"
    assert by_path[str(worktree)]["allocated_bytes"] > 0
    assert by_path[str(repo)]["lane_kind"] == "canonical-main"
    assert report["accounting"]["workspace_unassigned_allocated_bytes"] > 0
    assert (
        report["accounting"]["physical_lane_allocated_bytes"]
        >= by_path[str(worktree)]["allocated_bytes"]
    )
    assert report["policy"]["verdict"] == "pass"


MIB = 1024 * 1024


def _regenerable_lane(tmp_path: Path) -> tuple[Path, Path, Path]:
    """A registered lane carrying a 1 MiB .venv and a 1 MiB node_modules."""

    repo, worktree = _repo_with_worktree(tmp_path)
    venv = worktree / "backend" / ".venv" / "lib"
    venv.mkdir(parents=True)
    (venv / "site.bin").write_bytes(b"v" * MIB)
    modules = worktree / "node_modules" / "left-pad"
    modules.mkdir(parents=True)
    (modules / "index.bin").write_bytes(b"n" * MIB)
    state = tmp_path / "registry.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-REGENERABLE"],
            }
        ],
    )
    return repo, worktree, state


def test_regenerable_dirs_are_listed_and_never_counted_in_lane_quota(
    tmp_path: Path,
) -> None:
    repo, worktree, state = _regenerable_lane(tmp_path)

    report = disk_usage.build_report(repo, state, time_budget_seconds=30)

    entry = next(item for item in report["lanes"] if item["path"] == str(worktree))
    assert entry["regenerable_roots"] == ["backend/.venv", "node_modules"]
    assert entry["allocated_bytes"] < MIB // 2
    assert report["accounting"]["physical_lane_allocated_bytes"] < MIB // 2
    regenerable = report["accounting"]["regenerable"]
    assert regenerable["root_count"] == 2
    assert regenerable["counted_in_quota"] is False
    assert regenerable["measured"] is False
    assert "allocated_bytes" not in regenerable
    assert ".venv" in regenerable["names"]
    assert "regenerable_allocated_bytes" not in entry


def test_regenerable_bytes_cannot_trip_the_lane_quota(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Shrink "1 GiB" to 64 KiB so a 2 MiB .venv + node_modules would blow the
    # 2-unit per-lane and 8-unit total quotas if they were counted.
    monkeypatch.setattr(disk_usage, "GIB", 64 * 1024)
    repo, worktree, state = _regenerable_lane(tmp_path)

    report = disk_usage.build_report(repo, state, time_budget_seconds=30)
    sized = disk_usage.build_report(
        repo, state, time_budget_seconds=30, measure_regenerable=True
    )

    assert report["policy"]["quota_exceeded"] is False
    assert report["policy"]["lane_budget_exceeded"] == []
    assert "lane-total-budget-exceeded" not in report["policy"]["blocking_reasons"]
    assert report["policy"]["verdict"] in {"pass", "warning"}
    # Positive control: the lane is accounted, and the skipped bytes alone are
    # over both quotas, so counting them would have blocked it.
    entry = next(item for item in report["lanes"] if item["path"] == str(worktree))
    assert entry["accounted_in_aggregate"] is True
    sized_entry = next(i for i in sized["lanes"] if i["path"] == str(worktree))
    assert (
        sized_entry["regenerable_allocated_bytes"]
        > report["policy"]["total_lane_budget_bytes"]
    )
    assert (
        sized_entry["regenerable_allocated_bytes"]
        > report["policy"]["per_lane_budget_bytes"]
    )


def test_measure_regenerable_sizes_roots_beside_the_quota_bytes(
    tmp_path: Path,
) -> None:
    repo, worktree, state = _regenerable_lane(tmp_path)

    default = disk_usage.build_report(repo, state, time_budget_seconds=30)
    sized = disk_usage.build_report(
        repo, state, time_budget_seconds=30, measure_regenerable=True
    )

    default_entry = next(i for i in default["lanes"] if i["path"] == str(worktree))
    sized_entry = next(i for i in sized["lanes"] if i["path"] == str(worktree))
    assert sized_entry["allocated_bytes"] == default_entry["allocated_bytes"]
    assert sized_entry["regenerable_allocated_bytes"] >= 2 * MIB
    assert sized_entry["regenerable_measurement_complete"] is True
    regenerable = sized["accounting"]["regenerable"]
    assert regenerable["measured"] is True
    assert regenerable["allocated_bytes"] >= 2 * MIB
    assert regenerable["measurement_complete"] is True
    assert (
        sized["accounting"]["physical_lane_allocated_bytes"]
        == default["accounting"]["physical_lane_allocated_bytes"]
    )


def test_measure_regenerable_overrun_is_partial_evidence_not_a_block(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, worktree, state = _regenerable_lane(tmp_path)
    original = disk_usage._measure_regenerable

    def expired(
        roots: list[Path], *, deadline: float | None = None
    ) -> dict[str, object]:
        return original(roots, deadline=time.monotonic() - 1)

    monkeypatch.setattr(disk_usage, "_measure_regenerable", expired)

    report = disk_usage.build_report(
        repo, state, time_budget_seconds=30, measure_regenerable=True
    )

    entry = next(item for item in report["lanes"] if item["path"] == str(worktree))
    assert entry["regenerable_measurement_complete"] is False
    assert report["accounting"]["regenerable"]["measurement_complete"] is False
    assert report["measurement"]["status"] == "complete"
    assert (
        "measurement-time-budget-exceeded" not in report["policy"]["blocking_reasons"]
    )


def test_canonical_cache_and_backups_are_not_walked(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, _ = _repo_with_worktree(tmp_path)
    (repo / ".cache" / "ios-test-derived-data").mkdir(parents=True)
    (repo / ".cache" / "ios-test-derived-data" / "blob.bin").write_bytes(b"c" * MIB)
    (repo / "backups").mkdir()
    (repo / "backups" / "dump.bin").write_bytes(b"b" * MIB)
    (repo / "node_modules" / "pkg").mkdir(parents=True)
    (repo / "node_modules" / "pkg" / "index.bin").write_bytes(b"n" * MIB)
    state = tmp_path / "registry.json"
    _write_registry(state, [])
    scanned: list[str] = []
    real_scandir = os.scandir

    def spying_scandir(path: object = ".") -> object:
        scanned.append(str(path))
        return real_scandir(path)

    monkeypatch.setattr(os, "scandir", spying_scandir)

    report = disk_usage.build_report(repo, state, time_budget_seconds=30)

    inside = [p for p in scanned if p.startswith(str(repo))]
    assert not [
        p for p in inside if "/.cache" in p or "/backups" in p or "node_modules" in p
    ]
    assert str(repo) in inside, "positive control: the canonical walk ran"
    accounting = report["accounting"]
    assert accounting["workspace_unassigned_allocated_bytes"] < MIB // 2
    assert accounting["workspace_unmeasured_roots"] == [
        str(repo / ".cache"),
        str(repo / "backups"),
    ]
    canonical = next(i for i in report["lanes"] if i["path"] == str(repo))
    assert canonical["regenerable_roots"] == ["node_modules"]
    assert report["measurement"]["status"] == "complete"


def test_slow_xctest_devices_walk_cannot_starve_lane_attribution(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Regression (2026-10-08): the XCTestDevices physical-extent walk (226k files)
    # ran first and took 150-220 s of the 240 s window, so the lane attribution
    # that gates every writer never got to run.  A platform walk that burns its
    # whole budget may only make its own section incomplete.
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-STARVATION"],
            }
        ],
    )
    original = disk_usage.inspect_xctest_devices
    observed: dict[str, object] = {}

    def burns_the_budget(
        *args: object, deadline: float | None = None, **kwargs: object
    ):
        assert deadline is not None
        while time.monotonic() < deadline:
            time.sleep(0.01)
        observed["burned"] = True
        return original(*args, deadline=deadline, **kwargs)

    monkeypatch.setattr(disk_usage, "inspect_xctest_devices", burns_the_budget)

    report = disk_usage.build_report(repo, state, time_budget_seconds=3)

    assert observed.get("burned") is True, (
        "positive control: the walk ran and burned the budget"
    )
    entry = next(item for item in report["lanes"] if item["path"] == str(worktree))
    assert entry["measurement_complete"] is True
    assert entry["allocated_bytes"] > 0
    assert entry["worktree_state"] in {"clean", "dirty"}
    assert report["policy"]["measurement_incomplete_reasons"] == []
    assert report["policy"]["unregistered_physical_worktrees"] == []


def test_nested_worktree_index_maps_every_ancestor_in_one_pass() -> None:
    root = Path("/w/lanes")
    mid = root / "a"
    leaf = mid / "inner" / "b"
    sibling = Path("/w/other")
    index = disk_usage._nested_worktree_index({root, mid, leaf, sibling})

    assert index[root] == {mid, leaf}
    assert index[mid] == {leaf}
    assert leaf not in index and sibling not in index


def test_scan_cost_is_linear_in_registry_records(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Regression (2026-10-08): ~1200 registry records made the post-deadline
    # tail ~1.5M pure-Python path comparisons that no deadline interrupts.
    repo, _ = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    records = [
        {
            "branch": f"merged-{index}",
            "path": str(tmp_path / "gone" / f"lane-{index}"),
            "status": "merged",
            "claim_generation": 0,
        }
        for index in range(300)
    ]
    _write_registry(state, records)
    original = disk_usage._relative_to
    calls = 0

    def counting(path: Path, root: Path) -> bool:
        nonlocal calls
        calls += 1
        return original(path, root)

    monkeypatch.setattr(disk_usage, "_relative_to", counting)

    report = disk_usage.build_report(repo, state, time_budget_seconds=30)

    assert report["history"]["records"] == 300
    assert calls < 2000, f"{calls} _relative_to calls for 300 records is quadratic"


def test_missing_active_registered_lane_is_visible_and_warning_only(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _run_git(repo, "init", "-b", "main")
    _run_git(repo, "config", "user.email", "test@example.com")
    _run_git(repo, "config", "user.name", "Disk Test")
    (repo / "tracked.txt").write_text("main\n", encoding="utf-8")
    _run_git(repo, "add", "tracked.txt")
    _run_git(repo, "commit", "-m", "initial")
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    missing = tmp_path / "missing-lane"
    _write_registry(
        state,
        [
            {
                "branch": "missing-lane",
                "path": str(missing),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-MISSING"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 0
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    entry = next(item for item in report["lanes"] if item["path"] == str(missing))
    assert entry["ownership"] == "registered"
    assert entry["exists"] is False
    assert entry["physical_state"] == "missing"
    assert report["policy"]["verdict"] == "warning"
    assert "missing-registered-lane" in report["policy"]["reasons"]


def test_accounting_keeps_missing_active_lane_as_explicit_row(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _run_git(repo, "init", "-b", "main")
    _run_git(repo, "config", "user.email", "test@example.com")
    _run_git(repo, "config", "user.name", "Disk Test")
    (repo / "tracked.txt").write_text("main\n", encoding="utf-8")
    _run_git(repo, "add", "tracked.txt")
    _run_git(repo, "commit", "-m", "initial")
    missing = tmp_path / "missing-lane"
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "missing-lane",
                "path": str(missing),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-MISSING-ACCOUNTING"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 0
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    row = next(
        item
        for item in report["accounting"]["lane_accounting"]
        if item["path"] == str(missing)
    )
    assert row["registry_status"] == "active"
    assert row["exists"] is False
    assert row["physical_state"] == "missing"
    assert row["measurement_error"] == "path-missing"
    assert row["accounted_in_aggregate"] is False


def test_explicit_supervision_worktree_is_excluded_with_evidence(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    supervision = tmp_path / "supervision"
    _run_git(repo, "worktree", "add", "-b", "supervision", str(supervision), "main")
    (supervision / "supervision.txt").write_bytes(b"supervision\n" * 128)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-TEST"],
            }
        ],
    )

    assert (
        main(
            [
                "--workspace",
                str(repo),
                "--state",
                str(state),
                "--output",
                str(output),
                "--supervision-worktree",
                str(supervision),
            ]
        )
        == 0
    )

    report = json.loads(output.read_text(encoding="utf-8"))
    entry = next(item for item in report["lanes"] if item["path"] == str(supervision))
    assert entry["ownership"] == "excluded"
    assert entry["physical_state"] == "excluded"
    assert entry["allocated_bytes"] > 0
    assert report["exclusions"]["supervision_worktree_paths"] == [str(supervision)]
    assert report["policy"]["unregistered_physical_worktrees"] == []


def test_codex_supervision_checkout_is_observed_without_product_lane_block(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    codex_root = tmp_path / ".codex" / "worktrees"
    supervision = codex_root / "abcd" / "kg"
    supervision.parent.mkdir(parents=True)
    _run_git(repo, "worktree", "add", "-b", "supervision", str(supervision), "main")
    (supervision / "supervision.txt").write_bytes(b"supervision\n" * 128)
    _run_git(supervision, "add", "supervision.txt")
    _run_git(supervision, "commit", "-m", "supervision fixture")
    monkeypatch.setenv("KG_DISK_USAGE_CODEX_WORKTREE_ROOT", str(codex_root))
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-TEST"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 0
    )

    report = json.loads(output.read_text(encoding="utf-8"))
    entry = next(item for item in report["lanes"] if item["path"] == str(supervision))
    assert entry["lane_kind"] == "supervision"
    assert entry["ownership"] == "supervision"
    assert entry["accounted_in_aggregate"] is False
    assert entry["allocated_bytes"] > 0
    assert report["policy"]["unregistered_physical_worktrees"] == []
    assert report["policy"]["supervision_physical_worktrees"] == [str(supervision)]
    assert (
        report["accounting"]["supervision_worktree_allocated_bytes"]
        >= entry["allocated_bytes"]
    )


def test_codex_non_supervision_checkout_remains_unregistered_block(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    codex_root = tmp_path / ".codex" / "worktrees"
    unregistered = codex_root / "abcd" / "other"
    unregistered.parent.mkdir(parents=True)
    _run_git(repo, "worktree", "add", "-b", "unregistered", str(unregistered), "main")
    monkeypatch.setenv("KG_DISK_USAGE_CODEX_WORKTREE_ROOT", str(codex_root))
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-TEST"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == BLOCKED_EXIT
    )

    report = json.loads(output.read_text(encoding="utf-8"))
    entry = next(item for item in report["lanes"] if item["path"] == str(unregistered))
    assert entry["ownership"] == "unregistered"
    assert report["policy"]["unregistered_physical_worktrees"] == [str(unregistered)]


def test_active_registered_dirty_worktree_is_attributed_without_blocking(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    (worktree / "dirty.txt").write_text("dirty\n", encoding="utf-8")
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-DIRTY"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 0
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    entry = next(item for item in report["lanes"] if item["path"] == str(worktree))
    assert entry["physical_state"] == "dirty"
    assert entry["worktree_state"] == "dirty"
    assert report["policy"]["verdict"] in {"pass", "warning"}
    assert str(worktree) in report["policy"]["active_dirty_implementation_worktrees"]
    assert str(worktree) not in report["policy"]["blocking_dirty_physical_worktrees"]
    assert entry["allocated_bytes"] > 0
    assert (
        report["accounting"]["physical_lane_allocated_bytes"]
        >= entry["allocated_bytes"]
    )


@pytest.mark.parametrize("status", ["published", "cleanup_pending", "abandoned"])
def test_non_active_registered_dirty_worktree_remains_a_hard_block(
    status: str, tmp_path: Path
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    (worktree / "dirty.txt").write_text("dirty\n", encoding="utf-8")
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": status,
                "claim_generation": 0,
                "external_ids": [f"DIRECT-DELIVERY-DIRTY-{status.upper()}"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 75
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["policy"]["verdict"] == "block"
    assert "dirty-physical-worktree" in report["policy"]["blocking_reasons"]
    assert str(worktree) in report["policy"]["blocking_dirty_physical_worktrees"]


def test_active_registered_dirty_worktree_still_enforces_lane_budget(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    (worktree / "dirty.txt").write_bytes(b"dirty\n" * 128)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-DIRTY-BUDGET"],
            }
        ],
    )
    monkeypatch.setenv("KG_DISK_GUARD_LANE_BUDGET_GIB", "0")
    monkeypatch.setenv("KG_DISK_GUARD_LANE_TOTAL_BUDGET_GIB", "0")

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 75
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    entry = next(item for item in report["lanes"] if item["path"] == str(worktree))
    assert entry["allocated_bytes"] > 0
    assert (
        report["accounting"]["physical_lane_allocated_bytes"]
        >= entry["allocated_bytes"]
    )
    assert str(worktree) in report["policy"]["lane_budget_exceeded"]
    assert report["policy"]["measurement_incomplete"] is False
    assert report["policy"]["quota_exceeded"] is True
    assert f"lane-budget-exceeded:{worktree}" in report["policy"]["quota_reasons"]
    assert "dirty-physical-worktree" not in report["policy"]["blocking_reasons"]


def test_unknown_registry_status_is_a_hard_block(tmp_path: Path) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "paused",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-UNKNOWN-STATUS"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 75
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    entry = next(item for item in report["lanes"] if item["path"] == str(worktree))
    assert entry["registry_status"] == "paused"
    assert entry["ownership"] == "registered"
    assert report["policy"]["verdict"] == "block"
    assert "unknown-registry-status" in report["policy"]["blocking_reasons"]


def test_malformed_registry_record_is_a_hard_block(tmp_path: Path) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-MALFORMED"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 75
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["policy"]["verdict"] == "block"
    assert "registry-records-invalid" in report["policy"]["blocking_reasons"]


def test_registered_worktree_branch_identity_mismatch_is_a_hard_block(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "different-branch",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-MISMATCH"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 75
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["policy"]["verdict"] == "block"
    assert str(worktree) in report["policy"]["physical_identity_mismatches"]


def test_unregistered_physical_worktree_is_a_hard_block(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    unregistered = tmp_path / "unregistered"
    _run_git(repo, "worktree", "add", "-b", "unregistered", str(unregistered), "main")
    (unregistered / "unregistered.txt").write_bytes(b"unregistered\n" * 128)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-TEST"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 75
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    entry = next(item for item in report["lanes"] if item["path"] == str(unregistered))
    assert entry["ownership"] == "unregistered"
    assert entry["physical_state"] == "present-unregistered"
    assert report["policy"]["verdict"] == "block"
    assert "unregistered-physical-worktree" in report["policy"]["reasons"]


def test_terminal_registered_residue_is_visible_but_not_active(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "merged",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-HISTORY"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 0
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    entry = next(item for item in report["lanes"] if item["path"] == str(worktree))
    assert entry["ownership"] == "registered"
    assert entry["registry_status"] == "merged"
    assert entry["physical_state"] == "terminal-residue"
    assert report["policy"]["unregistered_physical_worktrees"] == []
    assert (
        report["accounting"]["physical_lane_allocated_bytes"]
        >= entry["allocated_bytes"]
    )


@pytest.mark.parametrize("mode", ["logical_bytes", "allocated_bytes"])
def test_report_has_explicit_accounting_mode(mode: str, tmp_path: Path) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-ACCOUNTING"],
            }
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 0
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["accounting"]["measurement"] in {"st_blocks", "st_size"}
    assert mode in report["accounting"]["fields"]
    assert report["accounting"]["physical_lane_allocated_bytes"] >= 0
    assert worktree.exists()


def test_terminal_registry_history_is_summarized_not_counted_as_live_lane(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "merged",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-HISTORY"],
            },
        ],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 0
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    entry = next(item for item in report["lanes"] if item["path"] == str(worktree))
    assert entry["registry_status"] == "merged"
    assert entry["physical_state"] == "terminal-residue"
    assert report["history"]["records"] == 1
    assert report["history"]["terminal_records"] == 1
    assert report["history"]["by_status"] == {"merged": 1}
    assert report["lane_count"] == 1
    assert len(json.dumps(report)) < 20_000


def test_measurement_time_budget_fails_closed_with_structured_evidence(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )

    assert (
        main(
            [
                "--workspace",
                str(repo),
                "--state",
                str(state),
                "--output",
                str(output),
                "--time-budget-seconds",
                "0",
            ]
        )
        == 75
    )

    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["measurement"]["budget_seconds"] == 0.0
    assert report["measurement"]["budget_exhausted"] is True
    assert "measurement-time-budget-exceeded" in report["policy"]["reasons"]


def test_measurement_time_budget_has_a_fixed_upper_bound(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )

    assert (
        main(
            [
                "--workspace",
                str(repo),
                "--state",
                str(state),
                "--output",
                str(output),
                "--time-budget-seconds",
                "9999",
            ]
        )
        == 0
    )

    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["measurement"]["budget_seconds"] == 240.0


def test_git_status_timeout_is_structured_as_incomplete_not_quota_excess(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
            }
        ],
    )
    original_run = disk_usage.subprocess.run

    def timeout_git_status(command: list[str], **kwargs: object) -> object:
        if command[:3] == ["git", "-C", str(worktree)] and "status" in command:
            timeout = kwargs.get("timeout")
            assert isinstance(timeout, (int, float)) and 0 < timeout <= 5
            raise subprocess.TimeoutExpired(command, kwargs.get("timeout"))
        return original_run(command, **kwargs)

    monkeypatch.setattr(disk_usage.subprocess, "run", timeout_git_status)

    report = disk_usage.build_report(repo, state, time_budget_seconds=5)

    assert report["measurement"]["status"] == "incomplete"
    assert report["measurement"]["incomplete_reasons"] == [
        "measurement-time-budget-exceeded"
    ]
    assert report["policy"]["verdict"] == "block"
    assert report["policy"]["measurement_incomplete"] is True
    assert report["policy"]["quota_exceeded"] is False


def test_historical_missing_lanes_keep_audit_identity_without_global_measurement_block(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    missing_records = [
        {
            "branch": f"history-{index}",
            "path": str(tmp_path / "history" / str(index)),
            "status": "merged",
            "claim_generation": 0,
            "external_ids": [f"MERGED-HISTORY-{index}"],
        }
        for index in range(1000)
    ]
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-ACTIVE"],
            },
            *missing_records,
        ],
    )

    report = disk_usage.build_report(repo, state, time_budget_seconds=5)

    assert report["measurement"]["status"] == "complete"
    assert report["policy"]["verdict"] == "warning"
    assert report["policy"]["measurement_incomplete"] is False
    assert report["policy"]["quota_exceeded"] is False
    assert len(report["policy"]["missing_terminal_lanes"]) == 1000
    history_row = next(
        item
        for item in report["accounting"]["lane_accounting"]
        if item["path"] == str(tmp_path / "history" / "999")
    )
    history_lane = next(
        item
        for item in report["lanes"]
        if item["path"] == str(tmp_path / "history" / "999")
    )
    assert history_row["registry_status"] == "merged"
    assert history_row["measurement_error"] == "path-missing"
    assert history_lane["external_ids"] == ["MERGED-HISTORY-999"]
    assert history_lane["lane_key"]


def test_codex_topology_and_lane_classifications_are_separate(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, active = _repo_with_worktree(tmp_path)
    terminal = repo / ".claude" / "worktrees" / "terminal"
    unknown = repo / ".claude" / "worktrees" / "unknown"
    codex_root = tmp_path / ".codex" / "worktrees"
    unregistered = codex_root / "unregistered"
    _run_git(repo, "worktree", "add", "-b", "terminal", str(terminal), "main")
    _run_git(repo, "worktree", "add", "-b", "unknown", str(unknown), "main")
    _run_git(repo, "worktree", "add", "-b", "unregistered", str(unregistered), "main")
    monkeypatch.setenv("KG_DISK_USAGE_CODEX_WORKTREE_ROOT", str(codex_root))

    missing = tmp_path / ".codex" / "worktrees" / "missing"
    state = tmp_path / "registry.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(active),
                "status": "active",
                "claim_generation": 0,
            },
            {
                "branch": "missing",
                "path": str(missing),
                "status": "active",
                "claim_generation": 0,
            },
            {
                "branch": "terminal",
                "path": str(terminal),
                "status": "merged",
                "claim_generation": 0,
            },
            {
                "branch": "unknown",
                "path": str(unknown),
                "status": "paused",
                "claim_generation": 0,
            },
        ],
    )

    report = disk_usage.build_report(repo, state)
    classifications = report["lane_attribution"]["classifications"]

    assert report["topology"]["observed_roots"] == sorted(
        [str(repo / ".claude" / "worktrees"), str(codex_root)]
    )
    assert classifications["active"]["count"] == 1
    assert classifications["active_but_missing"]["count"] == 1
    assert classifications["physical_but_unregistered"]["count"] == 1
    assert classifications["terminal_residue"]["count"] == 1
    assert classifications["unknown"]["count"] == 1
    assert classifications["active_but_missing"]["allocated_bytes"] == 0
    assert classifications["active_but_missing"]["lane_keys"]
    assert classifications["physical_but_unregistered"]["allocated_bytes"] > 0
    assert classifications["terminal_residue"]["allocated_bytes"] > 0
    assert (
        len(report["lane_attribution"]["product_lane_keys"])
        == report["lane_attribution"]["product_lane_count"]
    )
    assert report["policy"]["missing_active_lanes"] == [str(missing)]
    assert report["policy"]["terminal_physical_residue"] == [str(terminal)]
    assert report["policy"]["unregistered_physical_worktrees"] == [str(unregistered)]


def test_codex_active_and_terminal_cache_residue_is_observed_not_evicted(
    tmp_path: Path,
) -> None:
    """The shell guard must never own worktree lifecycle cleanup."""

    script = Path(__file__).resolve().parents[1] / "kg_disk_guard.sh"
    root = tmp_path / "guard"
    registry = root / "registry.json"
    state = root / "state.json"
    cache = root / ".codex" / "worktrees" / "lane" / ".cache" / "ios-test-derived-data"
    for key in ("a", "b", "c", "d"):
        (cache / key / "Build").mkdir(parents=True)
        (cache / key / "Build" / "blob").write_text("x", encoding="utf-8")
    registry.parent.mkdir(parents=True, exist_ok=True)
    _write_registry(
        registry,
        [
            {
                "branch": "lane",
                "path": str(root / ".codex" / "worktrees" / "lane"),
                "status": "merged",
                "claim_generation": 0,
            }
        ],
    )
    env = {
        "KG_DISK_GUARD_WORKSPACE": str(root),
        "KG_DISK_GUARD_STATE": str(state),
        "KG_DISK_GUARD_REGISTRY_STATE": str(registry),
        "KG_DISK_GUARD_CODEX_WORKTREE_ROOT": str(root / ".codex" / "worktrees"),
        "KG_DISK_GUARD_LANE_USAGE_STATE": str(root / "lane.json"),
        "KG_DISK_GUARD_FREE_BYTES": str(30 * 1073741824),
        "KG_DISK_GUARD_ACTIVE_BUILD": "0",
        "KG_DISK_GUARD_GUARD_LOCK_HELD": "1",
        "KG_DISK_GUARD_BUILD_LOCK_HELD": "1",
        "KG_DISK_GUARD_WORKTREE_CACHE_KEEP": "0",
        "KG_DISK_GUARD_WORKTREE_CACHE_MIN_AGE_HOURS": "0",
    }
    completed = subprocess.run(
        ["bash", str(script)], env={**dict(os.environ), **env}, check=False
    )
    assert completed.returncode == 0
    assert all((cache / key).is_dir() for key in ("a", "b", "c", "d"))


def _write_xctest_device(
    root: Path,
    udid: str,
    *,
    is_ephemeral: bool = False,
    is_deleted: bool = False,
    state: str = "Shutdown",
    plist_text: str | None = None,
) -> Path:
    device = root / udid
    (device / "data").mkdir(parents=True)
    plist = device / "device.plist"
    if plist_text is None:
        plist.write_bytes(
            __import__("plistlib").dumps(
                {
                    "UDID": udid,
                    "isEphemeral": is_ephemeral,
                    "isDeleted": is_deleted,
                    "state": state,
                }
            )
        )
    else:
        plist.write_text(plist_text, encoding="utf-8")
    (device / "data" / "payload").write_bytes(b"x" * 4096)
    return device


def test_xctest_devices_absent_root_is_explicit_and_non_blocking(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )
    absent = tmp_path / "missing-xctest-devices"

    assert (
        main(
            [
                "--workspace",
                str(repo),
                "--state",
                str(state),
                "--output",
                str(output),
                "--xctest-devices-root",
                str(absent),
            ]
        )
        == 0
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    shared = report["accounting"]["shared_platform_storage"]["xctest_devices"]
    assert shared["exists"] is False
    assert shared["status"] == "absent"
    assert shared["attribution"] == "shared-host-platform"
    assert report["policy"]["verdict"] == "pass"


def test_xctest_devices_measured_root_is_shared_not_a_product_lane(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    xctest_root = tmp_path / "XCTestDevices"
    _write_xctest_device(
        xctest_root,
        "11111111-1111-4111-8111-111111111111",
        is_ephemeral=False,
    )
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )

    assert (
        main(
            [
                "--workspace",
                str(repo),
                "--state",
                str(state),
                "--output",
                str(output),
                "--xctest-devices-root",
                str(xctest_root),
                "--xctest-devices-budget-gib",
                "1",
            ]
        )
        == 0
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    shared = report["accounting"]["shared_platform_storage"]["xctest_devices"]
    assert shared["exists"] is True
    assert shared["status"] == "measured"
    assert shared["device_count"] == 1
    assert shared["allocated_bytes"] > 0
    assert shared["budget_exceeded"] is False
    assert shared["attribution"] == "shared-host-platform"
    assert all(
        str(xctest_root) not in item["path"]
        for item in report["accounting"]["lane_accounting"]
    )
    assert report["policy"]["verdict"] == "pass"


@pytest.mark.parametrize("kind", ["missing", "malformed"])
def test_xctest_devices_metadata_failure_blocks_without_reclaim(
    kind: str, tmp_path: Path
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    xctest_root = tmp_path / "XCTestDevices"
    udid = "22222222-2222-4222-8222-222222222222"
    device = _write_xctest_device(xctest_root, udid)
    if kind == "missing":
        (device / "device.plist").unlink()
    else:
        (device / "device.plist").write_text("not a plist", encoding="utf-8")
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )

    assert (
        main(
            [
                "--workspace",
                str(repo),
                "--state",
                str(state),
                "--output",
                str(output),
                "--xctest-devices-root",
                str(xctest_root),
            ]
        )
        == 75
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    shared = report["accounting"]["shared_platform_storage"]["xctest_devices"]
    assert shared["measurement_complete"] is True
    assert shared["metadata_complete"] is False
    assert report["policy"]["verdict"] == "block"
    assert "xctest-devices-metadata-unavailable" in report["policy"]["blocking_reasons"]


def test_xctest_devices_active_and_non_ephemeral_are_never_reclaim_candidates(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    xctest_root = tmp_path / "XCTestDevices"
    _write_xctest_device(
        xctest_root,
        "33333333-3333-4333-8333-333333333333",
        is_ephemeral=False,
        is_deleted=True,
        state="Booted",
    )
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )

    def should_not_run(_: dict[str, object]) -> dict[str, object]:
        raise AssertionError("unsafe XCTestDevices candidate was reclaimed")

    monkeypatch.setattr(disk_usage, "_reclaim_xctest_device", should_not_run)
    assert (
        main(
            [
                "--workspace",
                str(repo),
                "--state",
                str(state),
                "--output",
                str(output),
                "--xctest-devices-root",
                str(xctest_root),
                "--xctest-devices-budget-gib",
                "0",
                "--auto-reclaim-xctest-devices",
            ]
        )
        == 75
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    shared = report["accounting"]["shared_platform_storage"]["xctest_devices"]
    assert shared["reclaim"]["candidates"] == []
    assert shared["reclaim"]["status"] == "manual-review"
    assert (xctest_root / "33333333-3333-4333-8333-333333333333").exists()


def test_xctest_devices_supported_ephemeral_stale_reclaim_is_narrow_and_remeasured(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    xctest_root = tmp_path / "XCTestDevices"
    udid = "44444444-4444-4444-8444-444444444444"
    device = _write_xctest_device(
        xctest_root,
        udid,
        is_ephemeral=True,
        is_deleted=True,
        state="Shutdown",
    )
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )
    calls: list[str] = []

    def supported_reclaim(candidate: dict[str, object]) -> dict[str, object]:
        calls.append(str(candidate["udid"]))
        assert candidate["is_ephemeral"] is True
        assert candidate["is_deleted"] is True
        assert candidate["active"] is False
        for child in sorted(device.iterdir(), reverse=True):
            if child.is_dir():
                for nested in sorted(child.rglob("*"), reverse=True):
                    if nested.is_file() or nested.is_symlink():
                        nested.unlink()
                child.rmdir()
            else:
                child.unlink()
        device.rmdir()
        return {"status": "reclaimed", "command": "supported-test-command"}

    monkeypatch.setattr(disk_usage, "_reclaim_xctest_device", supported_reclaim)
    assert (
        main(
            [
                "--workspace",
                str(repo),
                "--state",
                str(state),
                "--output",
                str(output),
                "--xctest-devices-root",
                str(xctest_root),
                "--xctest-devices-budget-gib",
                "0",
                "--auto-reclaim-xctest-devices",
            ]
        )
        == 0
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    shared = report["accounting"]["shared_platform_storage"]["xctest_devices"]
    assert calls == [udid]
    assert shared["reclaim"]["status"] == "reclaimed"
    assert shared["reclaim"]["succeeded"] == 1
    assert shared["allocated_bytes"] == 0
    assert shared["budget_exceeded"] is False


def test_xctest_devices_fields_are_additive_to_existing_report_schema(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )

    assert (
        main(["--workspace", str(repo), "--state", str(state), "--output", str(output)])
        == 0
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["schema"] == "kg.disk.lane-usage.v1"
    assert {"workspace", "registry", "lanes", "accounting", "policy"} <= report.keys()
    assert "shared_platform_storage" in report["accounting"]
    assert "xctest_devices" in report["accounting"]["shared_platform_storage"]


def test_simulator_runtime_inventory_is_additive_and_shared(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    runtime = tmp_path / "iOS-runtime"
    runtime.mkdir()
    discovered = [
        {
            "mount_path": str(runtime),
            "image_path": str(tmp_path / "iOS-runtime.dmg"),
            "image_bytes": 8 * disk_usage.GIB,
        }
    ]

    monkeypatch.setattr(
        disk_usage,
        "_discover_simulator_runtimes",
        lambda **_: (discovered, []),
    )
    monkeypatch.setattr(
        disk_usage.shutil,
        "disk_usage",
        lambda _: (10 * disk_usage.GIB, 6 * disk_usage.GIB, 4 * disk_usage.GIB),
    )

    observed = disk_usage.inspect_simulator_runtimes(budget_bytes=10 * disk_usage.GIB)

    assert observed["status"] == "measured"
    assert observed["attribution"] == "shared-host-platform"
    assert observed["runtime_count"] == 1
    assert observed["logical_bytes"] == 8 * disk_usage.GIB
    assert observed["allocated_bytes"] == 8 * disk_usage.GIB
    assert observed["budget_allocated_bytes"] == 8 * disk_usage.GIB
    assert observed["budget_exceeded"] is False
    assert observed["runtimes"][0]["mount_path"] == str(runtime)
    assert observed["runtimes"][0]["used_bytes"] == 6 * disk_usage.GIB


def test_simulator_runtime_budget_is_fail_closed_without_reclaim(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    runtime = tmp_path / "iOS-runtime"
    runtime.mkdir()
    monkeypatch.setattr(
        disk_usage,
        "_discover_simulator_runtimes",
        lambda **_: (
            [
                {
                    "mount_path": str(runtime),
                    "image_path": str(tmp_path / "iOS-runtime.dmg"),
                    "image_bytes": 8 * disk_usage.GIB,
                }
            ],
            [],
        ),
    )
    monkeypatch.setattr(
        disk_usage.shutil,
        "disk_usage",
        lambda _: (10 * disk_usage.GIB, 6 * disk_usage.GIB, 4 * disk_usage.GIB),
    )

    observed = disk_usage.inspect_simulator_runtimes(budget_bytes=5 * disk_usage.GIB)

    assert observed["budget_exceeded"] is True
    assert observed["budget_overflow_bytes"] == 3 * disk_usage.GIB
    assert observed["reclaim"]["status"] == "manual-review"
    assert observed["reclaim"]["attempted"] == 0


def test_simulator_runtime_measurement_failure_is_explicit(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    runtime = tmp_path / "iOS-runtime"
    runtime.mkdir()
    monkeypatch.setattr(
        disk_usage,
        "_discover_simulator_runtimes",
        lambda **_: (
            [
                {
                    "mount_path": str(runtime),
                    "image_path": str(tmp_path / "iOS-runtime.dmg"),
                    "image_bytes": 8 * disk_usage.GIB,
                }
            ],
            [],
        ),
    )

    def unavailable(_: object) -> object:
        raise OSError("runtime unavailable")

    monkeypatch.setattr(disk_usage.shutil, "disk_usage", unavailable)

    observed = disk_usage.inspect_simulator_runtimes(budget_bytes=10 * disk_usage.GIB)

    assert observed["status"] == "measurement-incomplete"
    assert observed["measurement_complete"] is False
    assert observed["measurement_errors"] == [f"{runtime}:filesystem-usage:OSError"]
    assert observed["budget_exceeded"] is None


def test_hdiutil_parser_ignores_non_simulator_mounts_and_is_deterministic() -> None:
    output = """
================================================
image-path      : /Users/test/other.dmg
blockcount      : 10
blocksize       : 512
/dev/disk1s1    APFS    /Volumes/Other
================================================
image-path      : /System/Library/AssetsV2/runtime-a.dmg
blockcount      : 20
blocksize       : 512
/dev/disk2s1    APFS    /Library/Developer/CoreSimulator/Volumes/iOS_A
================================================
image-path      : /System/Library/AssetsV2/runtime-b.dmg
blockcount      : 30
blocksize       : 512
/dev/disk3s1    APFS    /Library/Developer/CoreSimulator/Volumes/iOS_B
"""

    runtimes, errors = disk_usage._parse_hdiutil_simulator_runtimes(output)

    assert errors == []
    assert runtimes == [
        {
            "mount_path": "/Library/Developer/CoreSimulator/Volumes/iOS_A",
            "image_path": "/System/Library/AssetsV2/runtime-a.dmg",
            "image_bytes": 20 * 512,
        },
        {
            "mount_path": "/Library/Developer/CoreSimulator/Volumes/iOS_B",
            "image_path": "/System/Library/AssetsV2/runtime-b.dmg",
            "image_bytes": 30 * 512,
        },
    ]


def test_simulator_runtime_budget_block_is_reported_without_reclaim(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    runtime_report = {
        "status": "budget-exceeded",
        "attribution": "shared-host-platform",
        "runtime_count": 2,
        "logical_bytes": 12 * disk_usage.GIB,
        "allocated_bytes": 12 * disk_usage.GIB,
        "budget_allocated_bytes": 12 * disk_usage.GIB,
        "budget_exceeded": True,
        "budget_overflow_bytes": 2 * disk_usage.GIB,
        "measurement_complete": True,
        "metadata_complete": True,
        "measurement_errors": [],
        "runtimes": [],
        "reclaim": {"status": "manual-review"},
    }
    monkeypatch.setattr(
        disk_usage,
        "inspect_simulator_runtimes",
        lambda *args, **kwargs: runtime_report,
    )
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )

    report = disk_usage.build_report(repo, state, time_budget_seconds=30)

    assert report["policy"]["verdict"] == "block"
    assert "simulator-runtime-budget-exceeded" in report["policy"]["reasons"]
    assert "simulator-runtime-manual-review-required" in report["policy"]["reasons"]


def test_simulator_runtime_is_unsupported_without_blocking(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(disk_usage.sys, "platform", "linux")
    monkeypatch.setattr(
        disk_usage,
        "_discover_simulator_runtimes",
        lambda **_: ([], ["platform-unsupported"]),
    )

    observed = disk_usage.inspect_simulator_runtimes()

    assert observed["status"] == "unsupported"
    assert observed["measurement_complete"] is True
    assert observed["budget_exceeded"] is False


def test_build_report_exposes_simulator_runtime_bucket(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    state = tmp_path / "registry.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )
    runtime_report = {
        "status": "measured",
        "attribution": "shared-host-platform",
        "runtime_count": 1,
        "logical_bytes": 8 * disk_usage.GIB,
        "allocated_bytes": 8 * disk_usage.GIB,
        "budget_allocated_bytes": 8 * disk_usage.GIB,
        "budget_exceeded": False,
        "budget_overflow_bytes": 0,
        "measurement_complete": True,
        "metadata_complete": True,
        "measurement_errors": [],
        "runtimes": [],
        "reclaim": {"status": "not-requested"},
    }
    monkeypatch.setattr(
        disk_usage,
        "inspect_simulator_runtimes",
        lambda *args, **kwargs: runtime_report,
        raising=False,
    )

    report = disk_usage.build_report(repo, state, time_budget_seconds=30)

    shared = report["accounting"]["shared_platform_storage"]
    assert shared["simulator_runtimes"] is runtime_report
    assert report["policy"]["verdict"] == "pass"


def test_xctest_devices_propagates_non_timeout_tree_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    xctest_root = tmp_path / "XCTestDevices"
    udid = "66666666-6666-4666-8666-666666666666"
    _write_xctest_device(xctest_root, udid)

    def incomplete_tree(*args: object, **kwargs: object) -> dict[str, object]:
        return {
            "logical_bytes": 4096,
            "allocated_bytes": 4096,
            "files": 1,
            "complete": False,
            "errors": ["permission-denied"],
        }

    monkeypatch.setattr(disk_usage, "measure_tree", incomplete_tree)

    observed = disk_usage.inspect_xctest_devices(xctest_root)

    assert observed["measurement_complete"] is False
    assert observed["status"] == "measurement-incomplete"
    assert f"{udid}:permission-denied" in observed["measurement_errors"]


def test_xctest_devices_device_removed_mid_scan_is_skipped_not_incomplete(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    import shutil

    xctest_root = tmp_path / "XCTestDevices"
    vanished = "11111111-1111-4111-8111-111111111111"
    kept = "22222222-2222-4222-8222-222222222222"
    _write_xctest_device(xctest_root, vanished)
    _write_xctest_device(xctest_root, kept)
    real_measure_tree = disk_usage.measure_tree

    def vanish_after_scandir(path: Path, **kwargs: object) -> dict[str, object]:
        if path.name == vanished:
            shutil.rmtree(path)
        return real_measure_tree(path, **kwargs)

    monkeypatch.setattr(disk_usage, "measure_tree", vanish_after_scandir)

    observed = disk_usage.inspect_xctest_devices(xctest_root)

    assert observed["measurement_complete"] is True
    assert observed["status"] == "measured"
    assert observed["measurement_errors"] == []
    assert [device["udid"] for device in observed["devices"]] == [kept]


def test_xctest_devices_removed_mid_walk_is_skipped_and_rolls_back_extents(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    xctest_root = tmp_path / "XCTestDevices"
    vanished = "11111111-1111-4111-8111-111111111111"
    kept = "22222222-2222-4222-8222-222222222222"
    _write_xctest_device(xctest_root, vanished)
    _write_xctest_device(xctest_root, kept)
    real_scandir = os.scandir

    def vanish_before_child_walk(path: object = ".", *args: object, **kwargs: object):
        if Path(str(path)) == xctest_root / vanished / "data":
            shutil.rmtree(xctest_root / vanished)
        return real_scandir(path, *args, **kwargs)

    def extents(path: Path, *args: object, **kwargs: object):
        found = [(7, 0, 8192)] if vanished in str(path) else [(9, 4096, 8192)]
        return found, None

    monkeypatch.setattr(os, "scandir", vanish_before_child_walk)
    monkeypatch.setattr(disk_usage, "_supports_physical_extents", lambda: True)
    monkeypatch.setattr(disk_usage, "_physical_file_extents", extents)

    observed = disk_usage.inspect_xctest_devices(xctest_root, budget_bytes=1024 * 1024)

    assert observed["status"] == "measured"
    assert observed["measurement_errors"] == []
    assert [device["udid"] for device in observed["devices"]] == [kept]
    assert observed["device_count"] == 1
    assert observed["budget_allocated_bytes"] == 4096


def test_xctest_devices_removed_before_plist_read_is_skipped(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    xctest_root = tmp_path / "XCTestDevices"
    vanished = "33333333-3333-4333-8333-333333333333"
    kept = "44444444-4444-4444-8444-444444444444"
    _write_xctest_device(xctest_root, vanished)
    _write_xctest_device(xctest_root, kept)
    real_read = disk_usage._read_xctest_device_plist

    def vanish_before_read(plist_path: Path, name: str) -> object:
        if name == vanished:
            shutil.rmtree(xctest_root / vanished)
        return real_read(plist_path, name)

    monkeypatch.setattr(disk_usage, "_read_xctest_device_plist", vanish_before_read)

    observed = disk_usage.inspect_xctest_devices(xctest_root)

    assert observed["status"] == "measured"
    assert observed["metadata_complete"] is True
    assert observed["measurement_errors"] == []
    assert [device["udid"] for device in observed["devices"]] == [kept]


def test_xctest_devices_budget_uses_unique_physical_extents(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    xctest_root = tmp_path / "XCTestDevices"
    udid = "77777777-7777-4777-8777-777777777777"
    _write_xctest_device(xctest_root, udid)

    monkeypatch.setattr(disk_usage, "_supports_physical_extents", lambda: True)

    def shared_extent(
        *args: object, **kwargs: object
    ) -> tuple[list[tuple[int, int, int]], None]:
        return [(9, 4096, 8192)], None

    monkeypatch.setattr(disk_usage, "_physical_file_extents", shared_extent)

    observed = disk_usage.inspect_xctest_devices(xctest_root, budget_bytes=1024 * 1024)

    assert observed["allocation_method"] == "apfs-physical-extents"
    assert observed["physical_allocated_bytes"] == 4096
    assert observed["budget_allocated_bytes"] == 4096
    assert observed["allocated_bytes"] > observed["budget_allocated_bytes"]
    assert observed["measurement_complete"] is True


def test_xctest_devices_queries_physical_extents_concurrently(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    xctest_root = tmp_path / "XCTestDevices"
    udid = "99999999-9999-4999-8999-999999999999"
    _write_xctest_device(xctest_root, udid)

    monkeypatch.setattr(disk_usage, "_supports_physical_extents", lambda: True)
    two_queries_started = threading.Event()
    release_queries = threading.Event()
    calls_started = 0
    calls_lock = threading.Lock()

    def blocking_extent_query(
        *args: object, **kwargs: object
    ) -> tuple[list[tuple[int, int, int]], None]:
        nonlocal calls_started
        with calls_lock:
            calls_started += 1
            query_index = calls_started
            if calls_started >= 2:
                two_queries_started.set()
        release_queries.wait(timeout=2)
        return [(9, query_index * 4096, (query_index + 1) * 4096)], None

    monkeypatch.setattr(disk_usage, "_physical_file_extents", blocking_extent_query)
    result: dict[str, object] = {}

    def inspect() -> None:
        result.update(disk_usage.inspect_xctest_devices(xctest_root))

    inspector = threading.Thread(target=inspect)
    inspector.start()
    try:
        assert two_queries_started.wait(timeout=0.5)
    finally:
        release_queries.set()
        inspector.join(timeout=2)

    assert not inspector.is_alive()
    assert result["measurement_complete"] is True


def test_xctest_extent_concurrency_bounds_workers_and_pending_results(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    root = tmp_path / "XCTestDevices"
    udid = "99999999-9999-4999-8999-999999999999"
    _write_xctest_device(root, udid)
    for index in range(128):
        (root / udid / f"file-{index}").write_bytes(b"x")
    monkeypatch.setattr(disk_usage, "_supports_physical_extents", lambda: True)
    release = threading.Event()
    queue_full = threading.Event()
    all_workers_started = threading.Event()
    lock = threading.Lock()
    submitted = active = peak = 0

    class TrackingExecutor(disk_usage.ThreadPoolExecutor):
        def submit(self, *args, **kwargs):
            nonlocal submitted
            submitted += 1
            result = super().submit(*args, **kwargs)
            if submitted == disk_usage.PHYSICAL_EXTENT_PENDING:
                queue_full.set()
            return result

    def query(*args, **kwargs):
        nonlocal active, peak
        with lock:
            active += 1
            peak = max(peak, active)
            if active == disk_usage.PHYSICAL_EXTENT_WORKERS:
                all_workers_started.set()
        try:
            assert release.wait(timeout=5)
            return [(9, 0, 4096)], None
        finally:
            with lock:
                active -= 1

    monkeypatch.setattr(disk_usage, "ThreadPoolExecutor", TrackingExecutor)
    monkeypatch.setattr(disk_usage, "_physical_file_extents", query)
    result = {}
    inspector = threading.Thread(
        target=lambda: result.update(disk_usage.inspect_xctest_devices(root))
    )
    inspector.start()
    try:
        assert all_workers_started.wait(timeout=2)
        assert queue_full.wait(timeout=2)
        assert submitted == disk_usage.PHYSICAL_EXTENT_PENDING == 64
        assert peak == disk_usage.PHYSICAL_EXTENT_WORKERS == 8
    finally:
        release.set()
        inspector.join(timeout=5)
    assert not inspector.is_alive()
    assert result["measurement_complete"] is True
    assert submitted == 130
    assert active == 0
    assert peak <= 8
    assert result["physical_allocated_bytes"] == 4096


def test_xctest_extent_evidence_is_independent_of_completion_order(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    root = tmp_path / "XCTestDevices"
    for number in (1, 2, 3):
        _write_xctest_device(root, f"{number:08d}-9999-4999-8999-999999999999")
    monkeypatch.setattr(disk_usage, "_supports_physical_extents", lambda: True)

    def query(path, *args, **kwargs):
        if path.name == "device.plist":
            return [], disk_usage.PHYSICAL_EXTENT_UNSUPPORTED
        return [(9, 0, 8192), (9, 4096, 12288), (10, 0, 4096)], None

    monkeypatch.setattr(disk_usage, "PHYSICAL_EXTENT_WORKERS", 1)
    monkeypatch.setattr(disk_usage, "_physical_file_extents", query)
    serial = disk_usage.inspect_xctest_devices(root)
    assert serial["physical_allocated_bytes"] == 16384
    assert serial["physical_fallback_files"] == 3
    monkeypatch.setattr(disk_usage, "PHYSICAL_EXTENT_WORKERS", 8)
    first_started = threading.Event()
    second_finished = threading.Event()
    lock = threading.Lock()
    calls = 0

    def reordered_query(*args, **kwargs):
        nonlocal calls
        with lock:
            calls += 1
            index = calls
        if index == 1:
            first_started.set()
            assert second_finished.wait(timeout=2)
        elif index == 2:
            assert first_started.wait(timeout=2)
            second_finished.set()
        return query(*args, **kwargs)

    monkeypatch.setattr(disk_usage, "_physical_file_extents", reordered_query)
    assert disk_usage.inspect_xctest_devices(root) == serial


def test_xctest_extent_timeout_returns_partial_evidence_without_late_mutation(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    root = tmp_path / "XCTestDevices"
    _write_xctest_device(root, "99999999-9999-4999-8999-999999999999")
    monkeypatch.setattr(disk_usage, "_supports_physical_extents", lambda: True)
    release = threading.Event()
    started = threading.Event()
    executors = []

    class TrackingExecutor(disk_usage.ThreadPoolExecutor):
        def __init__(self, **kwargs):
            super().__init__(**kwargs)
            executors.append(self)

    def query(*args, **kwargs):
        started.set()
        assert release.wait(timeout=5)
        return [(9, 0, 4096)], None

    monkeypatch.setattr(disk_usage, "ThreadPoolExecutor", TrackingExecutor)
    monkeypatch.setattr(disk_usage, "_physical_file_extents", query)
    observed = {}
    inspector = threading.Thread(
        target=lambda: observed.update(
            disk_usage.inspect_xctest_devices(
                root, deadline=time.monotonic() + 0.2, auto_reclaim=True, budget_bytes=1
            )
        )
    )
    inspector.start()
    try:
        assert started.wait(timeout=2)
        inspector.join(timeout=1)
        assert not inspector.is_alive()
        assert observed["measurement_complete"] is False
        assert observed["physical_measurement_complete"] is False
        assert observed["budget_allocated_bytes"] is None
        assert observed["budget_exceeded"] is None
        assert observed["allocated_bytes"] > 0
        assert observed["reclaim"]["attempted"] == 0
        assert any(
            disk_usage.MEASUREMENT_BUDGET_ERROR in item
            for item in observed["physical_measurement_errors"]
        )
        frozen = json.dumps(observed, sort_keys=True)
    finally:
        release.set()
        inspector.join(timeout=5)
        for executor in executors:
            executor.shutdown(wait=True)
    assert json.dumps(observed, sort_keys=True) == frozen


def test_xctest_extent_worker_failure_is_incomplete_not_fallback(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    root = tmp_path / "XCTestDevices"
    _write_xctest_device(root, "99999999-9999-4999-8999-999999999999")
    monkeypatch.setattr(disk_usage, "_supports_physical_extents", lambda: True)

    def query(*args, **kwargs):
        raise RuntimeError("unexpected worker failure")

    monkeypatch.setattr(disk_usage, "_physical_file_extents", query)
    observed = disk_usage.inspect_xctest_devices(root)
    assert observed["measurement_complete"] is False
    assert observed["budget_allocated_bytes"] is None
    assert observed["physical_fallback_files"] == 0
    assert all(
        "physical-worker:RuntimeError" in item
        for item in observed["physical_measurement_errors"]
    )


def test_expired_extent_query_does_not_open_file(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    path = tmp_path / "file"
    path.write_bytes(b"x")
    stat_result = path.stat()
    monkeypatch.setattr(disk_usage, "_supports_physical_extents", lambda: True)
    monkeypatch.setattr(
        disk_usage.os, "open", lambda *args: pytest.fail("expired query opened a file")
    )
    assert disk_usage._physical_file_extents(
        path, stat_result, deadline=time.monotonic() - 1
    ) == ([], disk_usage.MEASUREMENT_BUDGET_ERROR)


def test_xctest_st_blocks_path_does_not_start_extent_workers(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    root = tmp_path / "XCTestDevices"
    _write_xctest_device(root, "99999999-9999-4999-8999-999999999999")
    monkeypatch.setattr(disk_usage, "_supports_physical_extents", lambda: False)
    monkeypatch.setattr(
        disk_usage,
        "ThreadPoolExecutor",
        lambda **kwargs: pytest.fail("fallback started workers"),
    )
    observed = disk_usage.inspect_xctest_devices(root)
    assert observed["measurement_complete"] is True
    assert observed["allocation_method"] == "st_blocks"
    assert observed["budget_allocated_bytes"] == observed["allocated_bytes"]


def test_xctest_devices_physical_open_fallback_is_explicit_and_conservative(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    xctest_root = tmp_path / "XCTestDevices"
    udid = "88888888-8888-4888-8888-888888888888"
    _write_xctest_device(xctest_root, udid)

    monkeypatch.setattr(disk_usage, "_supports_physical_extents", lambda: True)
    monkeypatch.setattr(
        disk_usage,
        "_physical_file_extents",
        lambda *args, **kwargs: ([], "physical-open:PermissionError"),
    )

    observed = disk_usage.inspect_xctest_devices(xctest_root, budget_bytes=1)

    assert observed["allocation_method"] == "apfs-physical-extents+st_blocks-fallback"
    assert observed["physical_measurement_complete"] is True
    assert observed["physical_fallback_files"] == 2
    assert (
        observed["budget_allocated_bytes"]
        == observed["physical_fallback_allocated_bytes"]
    )
    assert observed["budget_exceeded"] is True
    assert observed["physical_measurement_warnings"]


_LIVE = object()


# A start time no live process in the test run can have.
_FOREIGN_START = "Mon Jan  1 00:00:00 2001"


def _ps_lstart(pid: int) -> str | None:
    """Independent of the module under test: what ``ps`` reports for ``pid``,
    in UTC, the zone the harness writes into its lock reason (verified on a
    real lock: ``start Wed Oct  7 11:50:17 2026`` for a process ``ps`` shows
    as 19:50:17 on a UTC+8 host)."""

    completed = subprocess.run(
        ["ps", "-o", "lstart=", "-p", str(pid)],
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
        check=False,
    )
    return completed.stdout.strip() or None


def _harness_lock_reason(name: str, pid: int, start: str | None = None) -> str:
    """The exact reason Claude Code writes when it locks an agent worktree:
    the pid plus that process's start time (``ps`` lstart format, UTC)."""

    start = start or _ps_lstart(pid) or _FOREIGN_START
    return f"claude agent {name} (pid {pid} start {start})"


def _dead_pid() -> int:
    """A pid that existed moments ago and is now reaped (not alive)."""

    for _ in range(5):
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        child.wait()
        try:
            os.kill(child.pid, 0)
        except ProcessLookupError:
            return child.pid
    pytest.fail("could not obtain a dead pid")


def _agent_worktree(
    repo: Path,
    name: str = "agent-a1b2c3d4e5f6",
    branch: str | None = None,
    *,
    lock: object = _LIVE,
    root: Path | None = None,
) -> Path:
    """Create a worktree the way the harness does; ``lock`` is ``_LIVE``, a
    pid for a harness lock naming this dir, any other reason (``""`` = none),
    or ``None`` for unlocked."""

    path = (root or repo / ".claude" / "worktrees") / name
    path.parent.mkdir(parents=True, exist_ok=True)
    _run_git(
        repo, "worktree", "add", "-b", branch or f"worktree-{name}", str(path), "main"
    )
    if lock is _LIVE:
        lock = os.getpid()
    if isinstance(lock, int):
        lock = _harness_lock_reason(name, lock)
    if lock == "":
        _run_git(repo, "worktree", "lock", str(path))
    elif isinstance(lock, str):
        _run_git(repo, "worktree", "lock", "--reason", lock, str(path))
    return path


def _agent_root_report(tmp_path: Path, repo: Path, worktree: Path) -> tuple[int, dict]:
    state = tmp_path / "registry.json"
    _write_registry(
        state,
        [{"branch": "lane-one", "path": str(worktree), "status": "active"}],
    )
    output = tmp_path / "lane-usage.json"
    code = main(
        ["--workspace", str(repo), "--state", str(state), "--output", str(output)]
    )
    return code, json.loads(output.read_text(encoding="utf-8"))


# ownership -> (policy list, lane_attribution classification, policy reason)
_AGENT_ROOT_IDENTITY = {
    "ephemeral-agent": (
        "ephemeral_agent_worktrees",
        "ephemeral_agent",
        "ephemeral-agent-lane",
    ),
    "stale-agent": ("stale_agent_worktrees", "stale_agent", "stale-agent-worktree"),
    "unregistered": (
        "unregistered_physical_worktrees",
        "physical_but_unregistered",
        "unregistered-physical-worktree",
    ),
}


@pytest.mark.parametrize(
    "name,branch,lock,ownership",
    [
        # A live harness lock is identity whatever the branch or naming scheme.
        ("agent-a1b2c3d4e5f6", None, _LIVE, "ephemeral-agent"),
        ("agent-a1831cf3132224ea6", "verify-2025", _LIVE, "ephemeral-agent"),
        ("wf_e7e67718-c0d-3", None, _LIVE, "ephemeral-agent"),
        ("wf_e7e67718-c0d-4", "fix-p1-review", _LIVE, "ephemeral-agent"),
        # The harness no longer holds it: its own lock names a dead pid, or the
        # lock is gone and the dir carries a harness-generated name.
        ("agent-a1b2c3d4e5f6", None, "dead-pid", "stale-agent"),
        # The recorded pid was reused: it is alive but started at another time.
        ("agent-a1b2c3d4e5f6", None, "reused-pid", "stale-agent"),
        ("agent-a528d0e76f72e9dd3", None, None, "stale-agent"),
        ("wf_e7e67718-c0d-10", "fix-p1-review", None, "stale-agent"),
        # No provenance: an unlocked hand-made checkout (the review repro is
        # scratch), a near-miss name, or a lock this lane's harness did not hold.
        ("scratch", None, None, "unregistered"),
        ("lane-foo", None, None, "unregistered"),
        ("agent-a1b2c3d4e5f6", None, None, "unregistered"),  # 12 hex, not 17
        ("wf_scratch-1", None, None, "unregistered"),
        ("agent-a1b2c3d4e5f6", None, "kept by operator", "unregistered"),
        ("agent-a1b2c3d4e5f6", None, "", "unregistered"),
        (
            "agent-a1b2c3d4e5f6",
            None,
            _harness_lock_reason("agent-ffffffffffff", os.getpid()),
            "unregistered",
        ),
    ],
)
def test_claude_root_lane_identity_needs_harness_provenance(
    tmp_path: Path, name: str, branch: str | None, lock: object, ownership: str
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    dead = _dead_pid() if lock == "dead-pid" else None
    if lock == "reused-pid":
        recorded: object = _harness_lock_reason(name, os.getpid(), _FOREIGN_START)
    else:
        recorded = dead or lock
    lane = _agent_worktree(repo, name=name, branch=branch, lock=recorded)
    # Agent lanes are normally dirty, so dirt must not decide identity.
    (lane / "wip.txt").write_bytes(b"wip\n" * 128)

    code, report = _agent_root_report(tmp_path, repo, worktree)

    policy = report["policy"]
    entry = next(item for item in report["lanes"] if item["path"] == str(lane))
    assert entry["ownership"] == ownership
    assert entry["allocated_bytes"] > 0
    assert entry["accounted_in_aggregate"] is True
    listed, classified, reason = _AGENT_ROOT_IDENTITY[ownership]
    for key, _, _ in _AGENT_ROOT_IDENTITY.values():
        assert policy[key] == ([str(lane)] if key == listed else [])
    classifications = report["lane_attribution"]["classifications"]
    assert classifications[classified]["paths"] == [str(lane)]
    assert reason in policy["reasons"]
    if ownership == "unregistered":
        assert code == BLOCKED_EXIT
        assert "dirty-physical-worktree" in policy["blocking_reasons"]
        assert "agent_lock" not in entry
        return
    assert code == 0
    assert policy["blocking_reasons"] == []
    if lock is _LIVE:
        assert entry["lane_state"] == "ephemeral"
        assert entry["agent_lock"] == {"state": "live", "pid": os.getpid()}
        return
    assert entry["lane_state"] == "stale"
    if lock == "reused-pid":
        expected = {"state": "reused-pid", "pid": os.getpid()}
    elif dead:
        expected = {"state": "dead-pid", "pid": dead}
    else:
        expected = {"state": "unlocked"}
    assert entry["agent_lock"] == expected
    hint = entry["cleanup_hint"]
    assert f"git worktree remove {lane}" in hint
    assert (f"git worktree unlock {lane}" in hint) is (lock is not None)


@pytest.mark.parametrize(
    "reason_tail,probe,state",
    [
        # Matching start (within lstart's 1 s resolution plus skew) -> live.
        (" start Wed Oct  7 11:50:17 2026", "Wed Oct  7 11:50:18 2026", "live"),
        # Same pid, other start: an unrelated process reused it.
        (" start Wed Oct  7 11:50:17 2026", "Wed Oct  7 11:59:17 2026", "reused-pid"),
        # Missing / unparseable start info -> pid-only fallback.
        ("", "Wed Oct  7 11:59:17 2026", "live"),
        (" start yesterday", "Wed Oct  7 11:59:17 2026", "live"),
        (" start Wed Oct  7 11:50:17 2026", None, "live"),
    ],
)
def test_agent_lock_liveness_checks_recorded_start_time(
    monkeypatch: pytest.MonkeyPatch, reason_tail: str, probe: str | None, state: str
) -> None:
    """Live = pid exists AND its start matches the lock's recorded start.  The
    probe is injected as raw ``ps -o lstart=`` text (padded like macOS and
    procps print it) so the real parser is exercised on any CI host."""

    probed: list[int] = []

    def fake_lstart(pid: int, timeout: float = 5.0) -> str | None:
        probed.append(pid)
        return None if probe is None else f"{probe}    \n"

    monkeypatch.setattr(disk_usage, "_ps_lstart", fake_lstart)
    workspace = Path("/nonexistent-ws")
    lane = workspace / ".claude" / "worktrees" / "agent-a1b2c3d4e5f6"
    pid = os.getpid()
    reason = f"claude agent {lane.name} (pid {pid}{reason_tail})"
    physical = {"locked": True, "lock_reason": reason}

    assert disk_usage._agent_lane_lock(lane, physical, workspace) == {
        "state": state,
        "pid": pid,
    }
    assert probed == ([pid] if reason_tail.startswith(" start Wed") else [])


def test_ps_probes_stop_at_the_report_deadline(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A stalled ``ps`` must not stretch the report past ``--time-budget-seconds``:
    each probe is capped by the time left, and once the deadline passed the
    remaining lanes fall back to the pid-only check, marked in their record.
    The clock is faked so the stalls cost no wall time."""

    repo, worktree = _repo_with_worktree(tmp_path)
    lanes = [
        _agent_worktree(
            repo,
            name=f"agent-{index:017x}",
            lock=_harness_lock_reason(
                f"agent-{index:017x}", 900001 + index, _FOREIGN_START
            ),
        )
        for index in range(6)
    ]
    elapsed = [0.0]
    real_monotonic = time.monotonic
    monkeypatch.setattr(time, "monotonic", lambda: real_monotonic() + elapsed[0])
    monkeypatch.setattr(disk_usage, "_pid_alive", lambda pid: True)
    timeouts: list[float] = []

    def stalled_ps(pid: int, timeout: float = 5.0) -> str | None:
        timeouts.append(timeout)
        elapsed[0] += timeout  # ps hangs until its timeout kills it
        return None

    monkeypatch.setattr(disk_usage, "_ps_lstart", stalled_ps)
    state = tmp_path / "registry.json"
    _write_registry(
        state, [{"branch": "lane-one", "path": str(worktree), "status": "active"}]
    )
    output = tmp_path / "lane-usage.json"
    budget = 12

    main(
        [
            "--workspace",
            str(repo),
            "--state",
            str(state),
            "--output",
            str(output),
            "--time-budget-seconds",
            str(budget),
        ]
    )

    assert sum(timeouts) <= budget + 0.5, timeouts
    assert timeouts and all(0 < timeout <= 5 for timeout in timeouts)
    assert len(timeouts) < len(lanes)
    report = json.loads(output.read_text(encoding="utf-8"))
    by_path = {item["path"]: item for item in report["lanes"]}
    locks = [by_path[str(lane)]["agent_lock"] for lane in lanes]
    assert [lock["state"] for lock in locks] == ["live"] * len(lanes)
    skipped = [lock for lock in locks if lock.get("start_check") == "skipped-deadline"]
    assert len(skipped) == len(lanes) - len(timeouts)
    assert all("start_check" not in lock for lock in locks[: len(timeouts)])


@pytest.fixture
def host_timezone(
    request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch
) -> Iterator[str]:
    """Run the test as if the host clock zone were ``request.param``."""

    monkeypatch.setenv("TZ", request.param)
    time.tzset()
    yield request.param
    monkeypatch.undo()
    time.tzset()


@pytest.mark.parametrize(
    "host_timezone",
    ["UTC", "Asia/Taipei", "America/Los_Angeles"],
    indirect=True,
)
def test_real_ps_start_of_live_pid_matches_its_lock(host_timezone: str) -> None:
    """Positive control against the real ``ps`` (macOS here, procps on CI) in
    every host zone: the lock records UTC, so a non-UTC host (UTC+8 here)
    must still see its own live pid as ``live``, not ``reused-pid``."""

    workspace = Path("/nonexistent-ws")
    lane = workspace / ".claude" / "worktrees" / "agent-a1b2c3d4e5f6"
    reason = _harness_lock_reason(lane.name, os.getpid())
    assert _FOREIGN_START not in reason, "ps lstart unavailable for a live pid"
    physical = {"locked": True, "lock_reason": reason}

    assert disk_usage._agent_lane_lock(lane, physical, workspace) == {
        "state": "live",
        "pid": os.getpid(),
    }


@pytest.mark.parametrize("host_timezone", ["UTC", "Asia/Taipei"], indirect=True)
def test_ps_probe_is_pinned_to_utc_and_compared_as_utc(
    monkeypatch: pytest.MonkeyPatch, host_timezone: str
) -> None:
    """The recorded start is UTC, so the probe must ask ``ps`` for UTC whatever
    the host zone, and both strings are compared as UTC (no local mktime)."""

    recorded = _ps_lstart(os.getpid())
    seen_env: list[dict[str, str]] = []
    real_run = subprocess.run

    def spy(*args: object, **kwargs: object) -> object:
        seen_env.append(dict(kwargs.get("env") or {}))  # type: ignore[call-overload]
        return real_run(*args, **kwargs)  # type: ignore[call-overload]

    monkeypatch.setattr(disk_usage.subprocess, "run", spy)
    assert disk_usage._harness_pid_state(os.getpid(), recorded) == ("live", False)
    assert [env.get("TZ") for env in seen_env] == ["UTC"]
    # Same wall-clock text read as UTC on both sides: an hour-offset text is a
    # different instant, however the host zone interprets it.
    assert disk_usage._parse_lstart("Wed Oct  7 11:50:17 2026") == 1791373817.0
    assert (
        disk_usage._parse_lstart("Wed Oct  7 19:50:17 2026") == 1791373817.0 + 8 * 3600
    )


def test_ps_probe_runs_once_per_pid_per_cache(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """All lanes of one harness session share a pid; one probe serves them."""

    calls: list[int] = []

    def counting(pid: int, timeout: float = 5.0) -> str | None:
        calls.append(pid)
        return _ps_lstart(pid)

    recorded = _ps_lstart(os.getpid())
    cache: dict[int, str | None] = {}
    monkeypatch.setattr(disk_usage, "_ps_lstart", counting)
    states = [
        disk_usage._harness_pid_state(os.getpid(), recorded, cache) for _ in range(3)
    ]
    assert states == [("live", False)] * 3
    assert calls == [os.getpid()]


def test_ps_probe_timeout_is_capped_by_the_time_left(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No deadline keeps the 5 s probe cap; a nearer deadline shrinks it, and a
    passed one skips the probe (pid-only ``live``, flagged unchecked) while a
    cached answer is still used."""

    now = [100.0]
    monkeypatch.setattr(time, "monotonic", lambda: now[0])
    timeouts: list[float] = []

    def fake(pid: int, timeout: float = 5.0) -> str | None:
        timeouts.append(timeout)
        return None

    monkeypatch.setattr(disk_usage, "_ps_lstart", fake)
    monkeypatch.setattr(disk_usage, "_pid_alive", lambda pid: True)
    start = "Wed Oct  7 11:50:17 2026"

    def state(pid: int, deadline: float | None, cache: dict | None = None) -> tuple:
        return disk_usage._harness_pid_state(pid, start, cache, deadline)

    assert state(1, None) == ("live", False)
    assert state(2, 160.0) == ("live", False)  # 60 s left: the 5 s cap holds
    assert state(3, 102.5) == ("live", False)  # 2.5 s left
    assert timeouts == [5.0, 5.0, 2.5]
    assert state(4, 100.0) == ("live", True)  # deadline reached: no probe
    assert state(5, 99.0) == ("live", True)
    assert timeouts == [5.0, 5.0, 2.5]
    cache: dict[int, str | None] = {6: "Wed Oct  7 11:59:17 2026"}
    assert state(6, 99.0, cache) == ("reused-pid", False)  # cached evidence wins


@pytest.mark.parametrize("lock", [_LIVE, None])
def test_harness_lane_outside_claude_root_still_blocks(
    tmp_path: Path, lock: object
) -> None:
    """Positive control: identity is only granted directly under the root (the
    names are harness-shaped so the unlocked case fails on location alone)."""

    repo, worktree = _repo_with_worktree(tmp_path)
    elsewhere = _agent_worktree(
        repo, name="agent-a528d0e76f72e9dd3", lock=lock, root=tmp_path
    )
    nested = _agent_worktree(
        repo,
        name="agent-0123456789abcdef0",
        lock=lock,
        root=repo / ".claude" / "worktrees" / "nested",
    )

    code, report = _agent_root_report(tmp_path, repo, worktree)

    assert code == BLOCKED_EXIT
    assert report["policy"]["unregistered_physical_worktrees"] == sorted(
        [str(elsewhere), str(nested)]
    )
    assert report["policy"]["ephemeral_agent_worktrees"] == []
    assert report["policy"]["stale_agent_worktrees"] == []
    assert "unregistered-physical-worktree" in report["policy"]["blocking_reasons"]


def test_agent_lanes_live_and_stale_still_count_toward_lane_quota(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    live = _agent_worktree(repo, name="agent-aaaaaaaaaaaa")
    stale = _agent_worktree(repo, name="agent-bbbbbbbbbbbb", lock=_dead_pid())
    monkeypatch.setenv("KG_DISK_GUARD_LANE_BUDGET_GIB", "0")

    code, report = _agent_root_report(tmp_path, repo, worktree)

    assert code == BLOCKED_EXIT
    blocking = report["policy"]["blocking_reasons"]
    assert f"lane-budget-exceeded:{live}" in blocking
    assert f"lane-budget-exceeded:{stale}" in blocking
    assert "unregistered-physical-worktree" not in blocking


def test_sibling_agent_lanes_neither_block_each_other_nor_mask_an_orphan(
    tmp_path: Path,
) -> None:
    repo, worktree = _repo_with_worktree(tmp_path)
    agents = [_agent_worktree(repo, name=f"agent-{i:012x}") for i in (1, 2, 3)]
    (agents[1] / "wip.txt").write_bytes(b"wip\n" * 64)
    orphan = tmp_path / "orphan"
    _run_git(repo, "worktree", "add", "-b", "orphan", str(orphan), "main")

    code, report = _agent_root_report(tmp_path, repo, worktree)

    assert code == BLOCKED_EXIT
    policy = report["policy"]
    assert policy["ephemeral_agent_worktrees"] == sorted(str(a) for a in agents)
    assert policy["unregistered_physical_worktrees"] == [str(orphan)]
    # The clean orphan is the only blocker: the dirty sibling adds none.
    assert policy["blocking_reasons"] == ["unregistered-physical-worktree"]


def _detached_lane_report(
    tmp_path: Path, *, advance_branch: bool
) -> tuple[int, dict, Path]:
    repo, worktree = _repo_with_worktree(tmp_path)
    if advance_branch:
        (worktree / "more.txt").write_text("more\n", encoding="utf-8")
        _run_git(worktree, "add", "more.txt")
        _run_git(worktree, "commit", "-m", "advance lane")
        _run_git(worktree, "checkout", "--detach", "HEAD~1")
    else:
        _run_git(worktree, "checkout", "--detach", "HEAD")
    state = tmp_path / "registry.json"
    output = tmp_path / "lane-usage.json"
    _write_registry(
        state,
        [
            {
                "branch": "lane-one",
                "path": str(worktree),
                "status": "active",
                "claim_generation": 0,
                "external_ids": ["DIRECT-DELIVERY-DETACHED"],
            }
        ],
    )
    code = main(
        ["--workspace", str(repo), "--state", str(state), "--output", str(output)]
    )
    return code, json.loads(output.read_text(encoding="utf-8")), worktree


def test_clean_detached_lane_at_branch_tip_is_a_warning_not_a_block(
    tmp_path: Path,
) -> None:
    _, report, worktree = _detached_lane_report(tmp_path, advance_branch=False)

    policy = report["policy"]
    assert "physical-identity-mismatch" not in policy["blocking_reasons"]
    assert str(worktree) in policy["detached_at_tip_warnings"]
    assert str(worktree) not in policy["physical_identity_mismatches"]


def test_detached_lane_behind_branch_tip_blocks_and_names_repair(
    tmp_path: Path,
) -> None:
    _, report, worktree = _detached_lane_report(tmp_path, advance_branch=True)

    policy = report["policy"]
    assert "physical-identity-mismatch" in policy["blocking_reasons"]
    assert str(worktree) in policy["physical_identity_mismatches"]
    assert f"git -C {worktree} switch lane-one" in policy["physical_identity_repairs"]
