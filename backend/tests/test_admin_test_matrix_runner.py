"""Unit tests for the pure helpers extracted from run_pytest_matrix.

`_parse_matrix` (pytest -vv output → cases/matrix/totals) and `_error_run`
(uniform pre-pytest failure payload) became independently testable once split
out of the 123-line orchestrator. These tests pin their contracts directly,
without spawning a real pytest subprocess.
"""

from __future__ import annotations

import subprocess
from datetime import UTC, datetime

from kg.admin_test_matrix import runner
from kg.admin_test_matrix.runner import _error_run, _parse_matrix

_PAYLOAD_KEYS = {
    "runId", "startedAt", "finishedAt", "durationSeconds", "returnCode",
    "outcome", "totals", "matrix", "cases", "selectedItems", "itemResults",
    "stdoutTail", "stderrTail",
}


def test_parse_matrix_buckets_per_module_and_aggregates_totals():
    stdout = (
        "tests/test_a.py::test_one PASSED\n"
        "tests/test_a.py::test_two FAILED\n"
        "tests/test_b.py::test_three SKIPPED\n"
        "============ short test summary ============\n"  # non-matching noise
    )
    cases, rows, totals = _parse_matrix(stdout, "")

    assert [c["id"] for c in cases] == [
        "tests/test_a.py::test_one",
        "tests/test_a.py::test_two",
        "tests/test_b.py::test_three",
    ]
    # rows sorted by module name
    assert [r["module"] for r in rows] == ["tests/test_a.py", "tests/test_b.py"]
    a, b = rows
    assert (a["passed"], a["failed"], a["skipped"], a["total"]) == (1, 1, 0, 2)
    assert (b["passed"], b["failed"], b["skipped"], b["total"]) == (0, 0, 1, 1)
    assert totals == {"passed": 1, "failed": 1, "errors": 0, "skipped": 1, "total": 3}


def test_parse_matrix_reads_both_streams_and_error_status():
    # ERROR-status lines arrive on stderr; both streams are scanned.
    cases, rows, totals = _parse_matrix("", "tests/test_c.py::test_x ERROR\n")
    assert totals["errors"] == 1
    assert totals["total"] == 1
    assert cases[0]["bucket"] == "errors"


def test_parse_matrix_empty_output_is_empty_matrix():
    cases, rows, totals = _parse_matrix("", "")
    assert cases == []
    assert rows == []
    assert totals == {"passed": 0, "failed": 0, "errors": 0, "skipped": 0, "total": 0}


def test_error_run_shape_and_synthetic_error():
    started = datetime(2026, 1, 1, tzinfo=UTC)
    payload = _error_run("rid-1", started, ["tests/test_a.py"], stderr_tail=["boom"])

    assert set(payload.keys()) == _PAYLOAD_KEYS
    assert payload["runId"] == "rid-1"
    assert payload["returnCode"] == 127
    assert payload["outcome"] == "failed"
    assert payload["totals"] == {
        "passed": 0, "failed": 0, "errors": 1, "skipped": 0, "total": 1,
    }
    assert payload["matrix"] == []
    assert payload["cases"] == []
    assert payload["selectedItems"] == ["tests/test_a.py"]
    assert payload["stderrTail"] == ["boom"]
    assert payload["durationSeconds"] >= 0.0


def test_unknown_item_id_fails_closed_without_running_full_suite(monkeypatch):
    calls = []

    def unexpected_run(*args, **kwargs):
        calls.append((args, kwargs))
        raise AssertionError("pytest must not run for an unknown item ID")

    monkeypatch.setattr(runner.subprocess, "run", unexpected_run)

    payload = runner.run_pytest_matrix(["bogus"])

    assert calls == []
    assert payload["returnCode"] == 2
    assert payload["outcome"] == "failed"
    assert payload["selectedItems"] == ["bogus"]
    assert payload["matrix"] == []
    assert payload["stderrTail"] == ["unknown test matrix item id(s): bogus"]


def test_valid_item_id_runs_only_its_mapped_nodeids(monkeypatch):
    calls = []
    nodeid = "tests/test_robustness.py::TestBatchD_UserLockAtomic"

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        return subprocess.CompletedProcess(
            command, 0, stdout=f"{nodeid} PASSED\n", stderr=""
        )

    monkeypatch.setattr(runner.subprocess, "run", fake_run)

    payload = runner.run_pytest_matrix(["pipeline_locking"])

    assert calls[0][0][-1] == nodeid
    assert payload["returnCode"] == 0
    assert payload["outcome"] == "passed"
    assert payload["selectedItems"] == ["pipeline_locking"]
    assert payload["cases"][0]["id"] == nodeid


def test_no_selection_still_runs_the_full_tests_suite(monkeypatch):
    calls = []

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    monkeypatch.setattr(runner.subprocess, "run", fake_run)

    payload = runner.run_pytest_matrix([])

    assert calls[0][0][-1] == "tests"
    assert payload["returnCode"] == 0
    assert payload["outcome"] == "passed"
    assert payload["selectedItems"] == []


def test_timeout_with_bytes_output_returns_failed_record(monkeypatch):
    # subprocess.TimeoutExpired carries raw bytes (or None) on POSIX; the
    # timeout branch must decode them instead of crashing in _parse_matrix.
    def timeout_run(command, **kwargs):
        raise subprocess.TimeoutExpired(
            command, 600, output=b"tests/a.py::t PASSED\n", stderr=b""
        )

    monkeypatch.setattr(runner.subprocess, "run", timeout_run)

    payload = runner.run_pytest_matrix([])

    assert payload["returnCode"] == 124
    assert payload["outcome"] == "failed"
    assert payload["cases"][0]["id"] == "tests/a.py::t"
    assert any("timed out" in line for line in payload["stderrTail"])
