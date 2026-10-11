#!/usr/bin/env -S uv run --no-cache --no-project --python 3.13
"""Summarize actionable iOS xcodebuild diagnostics from a raw log.

This is intentionally stdlib-only. It is used by shell ops scripts after
xcodebuild finishes, so the first terminal screen can show warnings/errors
without forcing agents to grep a large build log manually.
"""

from __future__ import annotations

import argparse
import logging
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit

LOGGER = logging.getLogger("ops.ios_diagnostics")
# Checkout that owns this script; xcresult paths under it are reported repo-relative.
REPO_ROOT = Path(__file__).resolve().parents[1]


DIAGNOSTIC_RE = re.compile(
    r"^(?:(?P<file>/.+?):(?P<line>\d+):(?P<column>\d+):\s*)?"
    r"(?P<severity>warning|error):\s*(?P<message>.+)$",
    re.IGNORECASE,
)


def category_for(message: str) -> str:
    lowered = message.lower()
    if (
        "swift 6 language mode" in lowered
        or "main actor-isolated" in lowered
        or "nonisolated" in lowered
    ):
        return "swift6"
    if "storekit configuration" in lowered or ".storekit" in lowered:
        return "storekit"
    if (
        "umbrella header" in lowered
        or "swift package" in lowered
        or "package" in lowered
    ):
        return "spm"
    if (
        "provision" in lowered
        or "codesign" in lowered
        or "signing" in lowered
        or "certificate" in lowered
    ):
        return "signing"
    return "compiler"


def parse_log(text: str, *, limit: int = 80) -> dict[str, Any]:
    diagnostics: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str, str]] = set()
    build_failed = "** BUILD FAILED **" in text or "** TEST FAILED **" in text
    build_succeeded = "** BUILD SUCCEEDED **" in text or "** TEST SUCCEEDED **" in text

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        match = DIAGNOSTIC_RE.match(line)
        if not match:
            continue
        severity = match.group("severity").lower()
        message = match.group("message").strip()
        file_path = match.group("file") or ""
        line_no = match.group("line") or ""
        column = match.group("column") or ""
        key = (severity, file_path, line_no, message)
        if key in seen:
            continue
        seen.add(key)
        diagnostics.append(
            {
                "severity": severity,
                "category": category_for(message),
                "file": file_path or None,
                "line": int(line_no) if line_no else None,
                "column": int(column) if column else None,
                "message": message,
                "raw": line,
            }
        )

    category_rank = {"storekit": 0, "swift6": 1, "signing": 2, "spm": 3, "compiler": 4}
    diagnostics.sort(
        key=lambda item: (
            0 if item["severity"] == "error" else 1,
            category_rank.get(str(item["category"]), 99),
            item["raw"],
        )
    )
    visible = diagnostics[:limit]
    counts = {
        "errors": sum(1 for item in diagnostics if item["severity"] == "error"),
        "warnings": sum(1 for item in diagnostics if item["severity"] == "warning"),
        "swift6": sum(1 for item in diagnostics if item["category"] == "swift6"),
        "storekit": sum(1 for item in diagnostics if item["category"] == "storekit"),
        "spm": sum(1 for item in diagnostics if item["category"] == "spm"),
        "signing": sum(1 for item in diagnostics if item["category"] == "signing"),
    }
    result = (
        "fail"
        if counts["errors"] or build_failed
        else "pass"
        if build_succeeded
        else "unknown"
    )
    return {
        "schema": "kg.ios.diagnostics.v1",
        "source": "raw-log",
        "result": result,
        "counts": counts,
        "diagnostics": visible,
        "truncated": len(diagnostics) > limit,
        "totalDiagnostics": len(diagnostics),
    }


def _message_from_xcresult_issue(item: dict[str, Any]) -> str:
    # The location URL is a locator, never a message.
    return str(
        item.get("message")
        or item.get("issueText")
        or item.get("title")
        or item.get("description")
        or item
    )


def _zero_based_to_one(fragment: dict[str, list[str]], key: str) -> int | None:
    raw = fragment.get(key, [""])[0]
    return int(raw) + 1 if raw.isdigit() else None


def _repo_relative(path: str) -> str:
    try:
        return PurePosixPath(path).relative_to(REPO_ROOT.as_posix()).as_posix()
    except ValueError:
        return path


def _location_from_xcresult_url(url: str) -> tuple[str | None, int | None, int | None]:
    parts = urlsplit(url)
    if parts.scheme != "file" or not parts.path:
        return None, None, None
    # xcresult sourceURL fragments are 0-based: swiftc 3:13 maps to StartingLineNumber=2&StartingColumnNumber=12.
    fragment = parse_qs(parts.fragment)
    return (
        _repo_relative(unquote(parts.path)),
        _zero_based_to_one(fragment, "StartingLineNumber"),
        _zero_based_to_one(fragment, "StartingColumnNumber"),
    )


def _xcresult_issue_location(
    item: dict[str, Any],
) -> tuple[str | None, int | None, int | None]:
    url = item.get("sourceURL") or (
        item.get("documentLocationInCreatingWorkspace") or {}
    ).get("url")
    return _location_from_xcresult_url(str(url)) if url else (None, None, None)


def parse_xcresult_build_results(
    payload: dict[str, Any], *, limit: int = 80
) -> dict[str, Any]:
    diagnostics: list[dict[str, Any]] = []
    error_items = payload.get("errors") or []
    warning_items = payload.get("warnings") or []
    for severity, items in (("error", error_items), ("warning", warning_items)):
        for item in items:
            message = _message_from_xcresult_issue(item)
            file_path, line, column = _xcresult_issue_location(item)
            diagnostics.append(
                {
                    "severity": severity,
                    "category": category_for(message),
                    "file": file_path,
                    "line": line,
                    "column": column,
                    "target": str(item.get("targetName") or "") or None,
                    "message": message,
                    "raw": message,
                }
            )
    status = str(payload.get("status") or "").lower()
    effective_error_count = int(payload.get("errorCount") or len(error_items))
    effective_warning_count = int(payload.get("warningCount") or len(warning_items))
    result = (
        "fail"
        if status in {"failed", "canceled"} or effective_error_count > 0
        else "pass"
        if status == "succeeded"
        else "unknown"
    )
    diagnostics = diagnostics[:limit]
    counts = {
        "errors": effective_error_count,
        "warnings": effective_warning_count,
        "swift6": sum(1 for item in diagnostics if item["category"] == "swift6"),
        "storekit": sum(1 for item in diagnostics if item["category"] == "storekit"),
        "spm": sum(1 for item in diagnostics if item["category"] == "spm"),
        "signing": sum(1 for item in diagnostics if item["category"] == "signing"),
    }
    return {
        "schema": "kg.ios.diagnostics.v1",
        "source": "xcresult-build-results",
        "result": result,
        "counts": counts,
        "diagnostics": diagnostics,
        "truncated": (
            len((payload.get("errors") or [])) + len((payload.get("warnings") or []))
        )
        > limit,
        "totalDiagnostics": len((payload.get("errors") or []))
        + len((payload.get("warnings") or [])),
    }


def _as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def _walk_test_nodes(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    flat: list[dict[str, Any]] = []
    stack = list(nodes)
    while stack:
        node = stack.pop(0)
        flat.append(node)
        children = node.get("children")
        if isinstance(children, list):
            stack[0:0] = [child for child in children if isinstance(child, dict)]
    return flat


def _test_node_messages(node: dict[str, Any]) -> list[str]:
    messages: list[str] = []
    for child in _as_list(node.get("children")):
        if not isinstance(child, dict):
            continue
        if str(child.get("nodeType") or "") != "Failure Message":
            continue
        message = str(child.get("name") or child.get("details") or "").strip()
        if message:
            messages.append(message)
    return messages


def _parse_duration_seconds(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    if not text:
        return None
    if text.endswith("s"):
        text = text[:-1]
    elif text.endswith("秒"):
        text = text[:-1]
    try:
        return float(text)
    except ValueError:
        LOGGER.debug(
            "Failed to parse duration seconds from value %r", value, exc_info=True
        )
        return None


def _summarize_metric_entry(metric: dict[str, Any]) -> dict[str, Any]:
    measurements = [
        float(value)
        for value in (metric.get("measurements") or [])
        if isinstance(value, (int, float))
    ]
    sample_count = len(measurements)
    average = (sum(measurements) / sample_count) if sample_count else None
    return {
        "identifier": metric.get("identifier"),
        "displayName": metric.get("displayName"),
        "unit": metric.get("unitOfMeasurement"),
        "sampleCount": sample_count,
        "average": average,
        "min": min(measurements) if measurements else None,
        "max": max(measurements) if measurements else None,
        "measurements": measurements,
    }


def summarize_performance_metrics(
    metrics_payload: list[dict[str, Any]] | None,
) -> dict[str, Any] | None:
    if not metrics_payload:
        return None
    tests: list[dict[str, Any]] = []
    app_launch_summaries: list[dict[str, Any]] = []
    total_samples = 0
    weighted_sum_ms = 0.0

    for test_entry in metrics_payload:
        if not isinstance(test_entry, dict):
            continue
        test_runs = test_entry.get("testRuns") or []
        metrics: list[dict[str, Any]] = []
        for run in test_runs:
            if not isinstance(run, dict):
                continue
            for metric in run.get("metrics") or []:
                if not isinstance(metric, dict):
                    continue
                summary = _summarize_metric_entry(metric)
                metrics.append(summary)
                identifier = str(summary.get("identifier") or "")
                if (
                    identifier
                    == "com.apple.dt.XCTMetric_ApplicationLaunch-AppLaunch.duration"
                ):
                    sample_count = int(summary["sampleCount"])
                    avg = summary["average"]
                    if sample_count and isinstance(avg, (int, float)):
                        total_samples += sample_count
                        weighted_sum_ms += float(avg) * 1000.0 * sample_count
                        app_launch_summaries.append(summary)
        if metrics:
            tests.append(
                {
                    "testIdentifier": test_entry.get("testIdentifier"),
                    "metrics": metrics,
                }
            )

    if not tests:
        return None

    app_launch = None
    if app_launch_summaries:
        min_ms = min(
            int(round(float(item["min"]) * 1000.0))
            for item in app_launch_summaries
            if item["min"] is not None
        )
        max_ms = max(
            int(round(float(item["max"]) * 1000.0))
            for item in app_launch_summaries
            if item["max"] is not None
        )
        app_launch = {
            "tests": len(app_launch_summaries),
            "samples": total_samples,
            "averageMs": int(round(weighted_sum_ms / total_samples))
            if total_samples
            else None,
            "minMs": min_ms,
            "maxMs": max_ms,
        }

    return {
        "tests": tests,
        "appLaunch": app_launch,
    }


def parse_xcresult_test_results(
    summary_payload: dict[str, Any],
    tests_payload: dict[str, Any] | None = None,
    metrics_payload: list[dict[str, Any]] | None = None,
    *,
    limit: int = 80,
) -> dict[str, Any]:
    total = int(summary_payload.get("totalTestCount") or 0)
    passed = int(summary_payload.get("passedTests") or 0)
    failed = int(summary_payload.get("failedTests") or 0)
    skipped = int(summary_payload.get("skippedTests") or 0)
    expected = int(summary_payload.get("expectedFailures") or 0)
    effective = passed + failed + expected
    result_text = str(summary_payload.get("result") or "").lower()
    integrity_error = total > 0 and effective == 0
    result = (
        "fail"
        if failed or result_text == "failed" or integrity_error
        else "pass"
        if result_text == "passed" and effective > 0
        else "unknown"
    )

    diagnostics: list[dict[str, Any]] = []
    if integrity_error:
        message = (
            "xcresult reported zero effective test executions "
            f"(total={total}, passed={passed}, failed={failed}, skipped={skipped}, expectedFailures={expected}, result={result_text or 'unknown'}); "
            "skipped/unknown tests are not a valid pass"
        )
        diagnostics.append(
            {
                "severity": "error",
                "category": "test-result-integrity",
                "file": None,
                "line": None,
                "column": None,
                "message": message,
                "raw": message,
            }
        )
    for item in _as_list(summary_payload.get("testFailures")):
        if not isinstance(item, dict):
            continue
        name = str(
            item.get("testName") or item.get("testIdentifierString") or "unknown test"
        )
        target = str(item.get("targetName") or "")
        failure = str(item.get("failureText") or item.get("message") or "")
        message = f"{target + ' ' if target else ''}{name}: {failure}".strip()
        diagnostics.append(
            {
                "severity": "error",
                "category": "test",
                "file": None,
                "line": None,
                "column": None,
                "message": message,
                "raw": message,
            }
        )

    all_test_nodes: list[dict[str, Any]] = []
    if tests_payload:
        nodes = (
            tests_payload.get("testNodes") if isinstance(tests_payload, dict) else None
        )
        all_test_nodes = _walk_test_nodes(
            [n for n in (nodes or []) if isinstance(n, dict)]
        )
    if integrity_error and all_test_nodes:
        for node in all_test_nodes:
            if str(node.get("nodeType") or "") != "Test Case":
                continue
            if str(node.get("result") or "").lower() != "skipped":
                continue
            name = str(node.get("nodeIdentifier") or node.get("name") or "skipped test")
            details = "; ".join(_test_node_messages(node))
            message = f"{name}: {details}".strip(": ")
            diagnostics.append(
                {
                    "severity": "error",
                    "category": "test-skipped",
                    "file": None,
                    "line": None,
                    "column": None,
                    "message": message,
                    "raw": message,
                }
            )
    if not diagnostics and all_test_nodes:
        for node in all_test_nodes:
            if str(node.get("result") or "").lower() != "failed":
                continue
            name = str(node.get("nodeIdentifier") or node.get("name") or "failed test")
            details = str(node.get("details") or "")
            message = f"{name}: {details}".strip(": ")
            diagnostics.append(
                {
                    "severity": "error",
                    "category": "test",
                    "file": None,
                    "line": None,
                    "column": None,
                    "message": message,
                    "raw": message,
                }
            )

    visible = diagnostics[:limit]
    body_duration_seconds = 0.0
    for node in all_test_nodes:
        if str(node.get("nodeType") or "") != "Test Case":
            continue
        parsed_duration = _parse_duration_seconds(node.get("duration"))
        if parsed_duration is not None:
            body_duration_seconds += parsed_duration

    session_duration_seconds = None
    start_time = summary_payload.get("startTime")
    finish_time = summary_payload.get("finishTime")
    if start_time is not None and finish_time is not None:
        try:
            session_duration_seconds = max(float(finish_time) - float(start_time), 0.0)
        except (TypeError, ValueError):
            LOGGER.debug(
                "Failed to compute session duration from startTime=%r finishTime=%r",
                start_time,
                finish_time,
            )
            session_duration_seconds = None

    performance_metrics = summarize_performance_metrics(metrics_payload)

    return {
        "schema": "kg.ios.diagnostics.v1",
        "source": "xcresult-test-results",
        "result": result,
        "counts": {
            "errors": failed + (1 if integrity_error else 0),
            "warnings": 0,
            "swift6": 0,
            "storekit": 0,
            "spm": 0,
            "signing": 0,
            "tests": total,
            "effectiveTests": effective,
            "passedTests": passed,
            "failedTests": failed,
            "skippedTests": skipped,
            "expectedFailures": expected,
        },
        "timings": {
            "testBodyMs": int(round(body_duration_seconds * 1000)),
            "xcresultSessionMs": (
                int(round(session_duration_seconds * 1000))
                if session_duration_seconds is not None
                else None
            ),
        },
        "performanceMetrics": performance_metrics,
        "diagnostics": visible,
        "truncated": len(diagnostics) > limit,
        "totalDiagnostics": len(diagnostics),
    }


def read_xcresult_build_results(path: Path) -> dict[str, Any]:
    proc = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "build-results",
            "--path",
            str(path),
            "--compact",
        ],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return json.loads(proc.stdout)


def read_xcresult_test_summary(path: Path) -> dict[str, Any]:
    proc = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(path),
            "--compact",
        ],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return json.loads(proc.stdout)


def read_xcresult_tests(path: Path) -> dict[str, Any]:
    proc = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "tests",
            "--path",
            str(path),
            "--compact",
        ],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return json.loads(proc.stdout)


def read_xcresult_metrics(path: Path) -> list[dict[str, Any]]:
    proc = subprocess.run(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "metrics",
            "--path",
            str(path),
            "--compact",
        ],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    payload = json.loads(proc.stdout)
    return payload if isinstance(payload, list) else []


def apply_result_override(
    summary: dict[str, Any], override: str | None
) -> dict[str, Any]:
    counts = summary.get("counts") if isinstance(summary.get("counts"), dict) else {}
    has_errors = int(counts.get("errors") or 0) > 0
    if override == "fail":
        summary["result"] = "fail"
    elif override == "pass" and summary.get("result") != "fail" and not has_errors:
        summary["result"] = override
    elif override == "unknown" and summary.get("result") not in ("pass", "fail"):
        summary["result"] = "unknown"
    return summary


def format_text(
    summary: dict[str, Any],
    *,
    log_path: str | None = None,
    xcresult_path: str | None = None,
) -> str:
    counts = summary["counts"]
    lines = [
        "[ios][issues] source={source} result={result} errors={errors} warnings={warnings} swift6={swift6} storekit={storekit} spm={spm} signing={signing}".format(
            source=summary.get("source", "unknown"),
            result=summary["result"],
            **counts,
        )
    ]
    if xcresult_path:
        lines.append(f"[ios][issues] xcresult={xcresult_path}")
    if log_path:
        lines.append(f"[ios][issues] log={log_path}")
    if summary.get("source") == "xcresult-test-results":
        lines.append(
            "[ios][tests] tests={tests} passed={passedTests} failed={failedTests} skipped={skippedTests} expectedFailures={expectedFailures}".format(
                **counts
            )
        )
        timings = summary.get("timings") or {}
        if timings:
            lines.append(
                "[ios][test-timing] testBodyMs={testBodyMs} xcresultSessionMs={xcresultSessionMs}".format(
                    testBodyMs=timings.get("testBodyMs", 0),
                    xcresultSessionMs=timings.get("xcresultSessionMs"),
                )
            )
        app_launch = (summary.get("performanceMetrics") or {}).get("appLaunch") or {}
        if app_launch.get("samples"):
            lines.append(
                "[ios][perf] metric=AppLaunch tests={tests} samples={samples} averageMs={averageMs} minMs={minMs} maxMs={maxMs}".format(
                    tests=app_launch.get("tests"),
                    samples=app_launch.get("samples"),
                    averageMs=app_launch.get("averageMs"),
                    minMs=app_launch.get("minMs"),
                    maxMs=app_launch.get("maxMs"),
                )
            )
    for item in summary["diagnostics"]:
        location = ""
        target = ""
        if item.get("file"):
            location = item["file"]
            if item.get("line"):
                location += f":{item['line']}"
            location += " "
            if item.get("target"):
                target = f"target={item['target']} "
        lines.append(
            "[ios][{severity}] category={category} {target}{location}{message}".format(
                severity=item["severity"],
                category=item["category"],
                target=target,
                location=location,
                message=item["message"],
            )
        )
    if summary.get("truncated"):
        lines.append(
            f"[ios][issues] truncated=true total={summary['totalDiagnostics']}"
        )
    if summary.get("source") == "xcresult-test-results" and counts.get(
        "failedTests", 0
    ):
        lines.append(
            "[ios][next] fix the first failing test above; inspect xcresult for attachments and activity logs."
        )
    elif counts["errors"]:
        lines.append("[ios][next] fix the first error above; warnings may be fallout.")
    elif counts["warnings"]:
        lines.append(
            "[ios][next] build passed but warnings should be triaged before release."
        )
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcresult", help="Xcode result bundle path; preferred source")
    parser.add_argument("--log", help="raw xcodebuild log path; fallback source")
    parser.add_argument(
        "--kind",
        choices=("build", "test", "archive"),
        default="build",
        help="xcresult surface to read",
    )
    parser.add_argument(
        "--json", action="store_true", help="emit machine-readable JSON"
    )
    parser.add_argument("--limit", type=int, default=80)
    parser.add_argument(
        "--result",
        choices=("pass", "fail", "unknown"),
        help="override result from caller exit code",
    )
    args = parser.parse_args(argv)

    if not args.xcresult and not args.log:
        parser.error("one of --xcresult or --log is required")
    log_path = Path(args.log) if args.log else None
    xcresult_path = Path(args.xcresult) if args.xcresult else None
    try:
        if xcresult_path:
            if args.kind == "test":
                summary = parse_xcresult_test_results(
                    read_xcresult_test_summary(xcresult_path),
                    read_xcresult_tests(xcresult_path),
                    read_xcresult_metrics(xcresult_path),
                    limit=args.limit,
                )
            else:
                summary = parse_xcresult_build_results(
                    read_xcresult_build_results(xcresult_path), limit=args.limit
                )
        else:
            raise RuntimeError("no xcresult")
    except Exception as exc:
        if not log_path:
            raise SystemExit(
                f"✗ failed to read xcresult and no --log fallback was provided: {exc}"
            ) from exc
        if log_path.exists():
            text = log_path.read_text(encoding="utf-8", errors="replace")
            summary = parse_log(text, limit=args.limit)
        else:
            summary = parse_log("", limit=args.limit)
            summary["source"] = "raw-log-missing"
            summary["result"] = "unknown"
            summary["logError"] = f"log file not found: {log_path}"
        summary["xcresultError"] = str(exc)
    summary = apply_result_override(summary, args.result)
    summary["artifacts"] = {
        **({"xcresult": str(xcresult_path)} if xcresult_path else {}),
        **({"log": str(log_path)} if log_path else {}),
    }
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print(
            format_text(
                summary,
                log_path=str(log_path) if log_path else None,
                xcresult_path=str(xcresult_path) if xcresult_path else None,
            ),
            end="",
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
