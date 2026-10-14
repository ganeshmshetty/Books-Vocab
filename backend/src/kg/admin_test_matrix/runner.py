from __future__ import annotations

import logging
import os
import re
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, NamedTuple

from .catalog import UnknownTestMatrixItemError, selected_nodeids
from .results import bucket_status, item_results

CASE_LINE_RE = re.compile(r"^(?P<case>tests/\S+::\S+)\s+(?P<status>PASSED|FAILED|ERROR|SKIPPED|XFAILED|XPASSED)\b")

_LOGGER = logging.getLogger(__name__)


def _error_run(
    run_id: str,
    started: datetime,
    selected_items: list[str],
    *,
    stderr_tail: list[str],
    return_code: int = 127,
) -> dict[str, Any]:
    """Build a uniform failed-run payload for pre-pytest errors (missing tests
    dir, spawn failure, invalid selection), one synthetic error, empty matrix."""
    finished = datetime.now(tz=UTC)
    return {
        "runId": run_id,
        "startedAt": started.isoformat(),
        "finishedAt": finished.isoformat(),
        "durationSeconds": round((finished - started).total_seconds(), 3),
        "returnCode": return_code,
        "outcome": "failed",
        "totals": {"passed": 0, "failed": 0, "errors": 1, "skipped": 0, "total": 1},
        "matrix": [],
        "cases": [],
        "selectedItems": selected_items,
        "itemResults": item_results([]),
        "stdoutTail": [],
        "stderrTail": stderr_tail,
    }


def _decode_output(data: bytes | str | None) -> str:
    """TimeoutExpired.stdout/stderr may be raw bytes, str, or None depending on
    how the child was spawned and flushed; normalize to str."""
    if data is None:
        return ""
    if isinstance(data, bytes):
        return data.decode("utf-8", errors="replace")
    return data


class MatrixReport(NamedTuple):
    cases: list[dict[str, str]]
    matrix_rows: list[dict[str, Any]]
    totals: dict[str, int]


def _parse_matrix(stdout: str, stderr: str) -> MatrixReport:
    """Parse pytest -vv output into (cases, matrix_rows, totals).

    Scans each line for a ``tests/...::case STATUS`` match, buckets per module,
    and aggregates totals. Lines that don't match (headers, tracebacks) skip.
    """
    cases: list[dict[str, str]] = []
    matrix: dict[str, dict[str, Any]] = {}
    for line in (stdout + "\n" + stderr).splitlines():
        match = CASE_LINE_RE.match(line.strip())
        if not match:
            continue
        case_id = match.group("case")
        status = match.group("status")
        module = case_id.split("::", 1)[0]
        bucket = bucket_status(status)
        cases.append(
            {
                "id": case_id,
                "module": module,
                "status": status,
                "bucket": bucket,
            }
        )
        if module not in matrix:
            matrix[module] = {
                "module": module,
                "passed": 0,
                "failed": 0,
                "errors": 0,
                "skipped": 0,
                "total": 0,
            }
        matrix[module][bucket] += 1
        matrix[module]["total"] += 1

    matrix_rows = sorted(matrix.values(), key=lambda row: row["module"])
    totals = {
        "passed": sum(row["passed"] for row in matrix_rows),
        "failed": sum(row["failed"] for row in matrix_rows),
        "errors": sum(row["errors"] for row in matrix_rows),
        "skipped": sum(row["skipped"] for row in matrix_rows),
    }
    totals["total"] = totals["passed"] + totals["failed"] + totals["errors"] + totals["skipped"]
    return MatrixReport(cases, matrix_rows, totals)


def run_pytest_matrix(selected_items: list[str] | None = None) -> dict[str, Any]:
    """Run pytest and build matrix data grouped by test module."""
    project_root = Path(__file__).resolve().parent.parent.parent.parent
    started = datetime.now(tz=UTC)
    run_id = started.strftime("%Y%m%d%H%M%S")
    tests_dir = project_root / "tests"
    selected_items = selected_items or []
    try:
        nodeids = selected_nodeids(selected_items)
    except UnknownTestMatrixItemError as exc:
        return _error_run(
            run_id,
            started,
            selected_items,
            stderr_tail=[str(exc)],
            return_code=2,
        )

    if not tests_dir.exists():
        return _error_run(
            run_id,
            started,
            selected_items,
            stderr_tail=[f"tests directory not found at {tests_dir}"],
        )

    cmd = [sys.executable, "-m", "pytest", "-vv", "--maxfail=0", "--disable-warnings"]
    if nodeids:
        cmd.extend(nodeids)
    else:
        cmd.append("tests")

    try:
        proc = subprocess.run(
            cmd,
            cwd=project_root,
            capture_output=True,
            text=True,
            timeout=600,
            env={**os.environ, "PY_COLORS": "0"},
        )
        stdout = proc.stdout or ""
        stderr = proc.stderr or ""
        return_code = proc.returncode
    except subprocess.TimeoutExpired as exc:
        stdout = _decode_output(exc.stdout)
        stderr = _decode_output(exc.stderr)
        timeout_note = f"pytest timed out after {exc.timeout} seconds"
        stderr = f"{stderr}\n{timeout_note}" if stderr else timeout_note
        return_code = 124
        _LOGGER.warning(
            "admin test matrix timed out (run_id=%s, return_code=%s)",
            run_id,
            return_code,
            exc_info=True,
        )
    except OSError as exc:
        return _error_run(
            run_id,
            started,
            selected_items,
            stderr_tail=[f"{type(exc).__name__}: {exc}"],
        )

    finished = datetime.now(tz=UTC)
    duration = round((finished - started).total_seconds(), 3)

    cases, matrix_rows, totals = _parse_matrix(stdout, stderr)

    outcome = "passed" if return_code == 0 else "failed"
    return {
        "runId": run_id,
        "startedAt": started.isoformat(),
        "finishedAt": finished.isoformat(),
        "durationSeconds": duration,
        "returnCode": return_code,
        "outcome": outcome,
        "totals": totals,
        "selectedItems": selected_items,
        "matrix": matrix_rows,
        "cases": cases,
        "itemResults": item_results(cases),
        "stdoutTail": (stdout.splitlines()[-60:] if stdout else []),
        "stderrTail": (stderr.splitlines()[-60:] if stderr else []),
    }
