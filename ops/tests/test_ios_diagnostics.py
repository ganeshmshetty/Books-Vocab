from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "ios_diagnostics.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("ios_diagnostics", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_parse_xcode_log_groups_actionable_diagnostics():
    mod = _load_module()
    text = """
warning: StoreKit Configuration file for scheme "BooksAndVocab" can't be found at path "/tmp/missing.storekit"
/repo/ios/BooksAndVocab/Views/VocabHighlightPreferences.swift:47:12: warning: Switch covers known cases, but 'ColorScheme' may have additional unknown values; this is an error in the Swift 6 language mode
/repo/ios/BooksAndVocab/Views/PodcastSelectableSentenceTextView.swift:10:8: warning: umbrella header for module 'GoogleSignIn' does not include header 'GIDAppCheckError'
/repo/ios/BooksAndVocab/Views/Reader/Foo.swift:12:3: error: cannot find 'missingSymbol' in scope
** BUILD FAILED **
"""
    summary = mod.parse_log(text)

    assert summary["counts"] == {
        "errors": 1,
        "warnings": 3,
        "swift6": 1,
        "storekit": 1,
        "spm": 1,
        "signing": 0,
    }
    assert summary["result"] == "fail"
    assert summary["diagnostics"][0]["severity"] == "error"
    assert summary["diagnostics"][0]["file"].endswith("Foo.swift")
    assert summary["diagnostics"][1]["category"] == "storekit"
    assert summary["diagnostics"][2]["category"] == "swift6"


def test_json_output_is_stable(tmp_path, capsys):
    mod = _load_module()
    log = tmp_path / "build.log"
    log.write_text(
        "warning: StoreKit Configuration file missing\n** BUILD SUCCEEDED **\n",
        encoding="utf-8",
    )

    rc = mod.main(["--log", str(log), "--json"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["counts"]["warnings"] == 1
    assert payload["result"] == "pass"


def test_parse_xcresult_build_results_uses_official_counts():
    mod = _load_module()
    payload = {
        "status": "succeeded",
        "errorCount": 0,
        "warningCount": 2,
        "errors": [],
        "warnings": [
            {"message": "StoreKit Configuration file for scheme missing"},
            {
                "message": "Switch covers known cases; this is an error in the Swift 6 language mode"
            },
        ],
    }

    summary = mod.parse_xcresult_build_results(payload)
    assert summary["source"] == "xcresult-build-results"
    assert summary["result"] == "pass"
    assert summary["counts"]["warnings"] == 2
    assert summary["counts"]["storekit"] == 1
    assert summary["counts"]["swift6"] == 1


def test_parse_xcresult_build_results_fails_on_error_diagnostic_after_success():
    mod = _load_module()
    summary = mod.parse_xcresult_build_results(
        {
            "status": "succeeded",
            "errorCount": 0,
            "warningCount": 0,
            "errors": [{"message": "compiler error preserved in xcresult"}],
            "warnings": [],
        }
    )

    assert summary["result"] == "fail"
    assert summary["counts"]["errors"] == 1


def test_parse_xcresult_build_results_fails_on_nonzero_error_count_after_success():
    mod = _load_module()
    summary = mod.parse_xcresult_build_results(
        {
            "status": "succeeded",
            "errorCount": 1,
            "warningCount": 0,
            "errors": [],
            "warnings": [],
        }
    )

    assert summary["result"] == "fail"
    assert summary["counts"]["errors"] == 1


def _xcresult_error_payload(source_url: str) -> dict:
    return {
        "status": "failed",
        "errorCount": 1,
        "warningCount": 0,
        "errors": [
            {
                "message": "Cannot use mutating member on immutable value: '$0' is immutable",
                "sourceURL": source_url,
                "targetName": "BooksAndVocabTests",
            }
        ],
        "warnings": [],
    }


def test_parse_xcresult_build_results_keeps_file_line_column_from_source_url():
    mod = _load_module()
    repo_root = SCRIPT.parents[1]
    source_url = (
        f"file://{repo_root}/ios/BooksAndVocabTests/X.swift"
        "#EndingColumnNumber=40&EndingLineNumber=57&StartingColumnNumber=9&StartingLineNumber=57"
    )

    item = mod.parse_xcresult_build_results(_xcresult_error_payload(source_url))[
        "diagnostics"
    ][0]

    assert item["file"] == "ios/BooksAndVocabTests/X.swift"
    # xcresult fragments are 0-based (verified: swiftc 3:13 -> StartingLineNumber=2&StartingColumnNumber=12)
    assert (item["line"], item["column"]) == (58, 10)
    assert item["target"] == "BooksAndVocabTests"
    assert (
        item["message"]
        == "Cannot use mutating member on immutable value: '$0' is immutable"
    )


def test_format_text_prints_path_and_line_for_xcresult_build_error():
    mod = _load_module()
    repo_root = SCRIPT.parents[1]
    source_url = (
        f"file://{repo_root}/ios/BooksAndVocabTests/X.swift"
        "#EndingColumnNumber=40&EndingLineNumber=57&StartingColumnNumber=9&StartingLineNumber=57"
    )
    summary = mod.parse_xcresult_build_results(_xcresult_error_payload(source_url))

    error_lines = [
        line
        for line in mod.format_text(summary).splitlines()
        if line.startswith("[ios][error]")
    ]

    assert error_lines == [
        "[ios][error] category=compiler target=BooksAndVocabTests ios/BooksAndVocabTests/X.swift:58 "
        "Cannot use mutating member on immutable value: '$0' is immutable"
    ]


def test_parse_xcresult_build_results_reads_legacy_document_location_url():
    mod = _load_module()
    repo_root = SCRIPT.parents[1]
    payload = {
        "status": "failed",
        "errorCount": 1,
        "warningCount": 0,
        "errors": [
            {
                "message": "cannot find 'missingSymbol' in scope",
                "documentLocationInCreatingWorkspace": {
                    "url": f"file://{repo_root}/ios/Foo.swift#StartingColumnNumber=11&StartingLineNumber=4",
                    "concreteTypeName": "DVTTextDocumentLocation",
                },
            }
        ],
        "warnings": [],
    }

    item = mod.parse_xcresult_build_results(payload)["diagnostics"][0]

    assert (item["file"], item["line"], item["column"]) == ("ios/Foo.swift", 5, 12)
    assert item["message"] == "cannot find 'missingSymbol' in scope"


def test_parse_xcresult_build_results_keeps_absolute_path_outside_checkout():
    mod = _load_module()
    payload = _xcresult_error_payload(
        "file:///Users/runner/work/Other%20Repo/X.swift#StartingColumnNumber=0&StartingLineNumber=0"
    )

    item = mod.parse_xcresult_build_results(payload)["diagnostics"][0]

    assert (item["file"], item["line"], item["column"]) == (
        "/Users/runner/work/Other Repo/X.swift",
        1,
        1,
    )


def test_format_text_location_less_xcresult_error_renders_as_before():
    mod = _load_module()
    summary = mod.parse_xcresult_build_results(
        {
            "status": "failed",
            "errorCount": 1,
            "warningCount": 0,
            "errors": [{"message": "compiler error preserved in xcresult"}],
            "warnings": [],
        }
    )

    error_lines = [
        line
        for line in mod.format_text(summary).splitlines()
        if line.startswith("[ios][error]")
    ]

    assert error_lines == [
        "[ios][error] category=compiler compiler error preserved in xcresult"
    ]


def test_result_override_handles_quiet_xcodebuild_logs(tmp_path, capsys):
    mod = _load_module()
    log = tmp_path / "build.log"
    log.write_text("", encoding="utf-8")

    rc = mod.main(["--log", str(log), "--result", "pass", "--json"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["result"] == "pass"


def test_result_override_does_not_hide_xcresult_integrity_failures():
    mod = _load_module()
    summary = {
        "result": "fail",
        "counts": {"errors": 1},
    }

    assert mod.apply_result_override(summary, "pass")["result"] == "fail"


def test_parse_xcresult_test_results_uses_official_summary_and_failures():
    mod = _load_module()
    summary_payload = {
        "result": "Failed",
        "totalTestCount": 7,
        "passedTests": 5,
        "failedTests": 1,
        "skippedTests": 1,
        "expectedFailures": 0,
        "testFailures": [
            {
                "testName": "BooksAndVocabTests.testSyncFails()",
                "targetName": "BooksAndVocabTests",
                "failureText": "XCTAssertEqual failed",
                "testIdentifierString": "BooksAndVocabTests/testSyncFails()",
            }
        ],
    }

    parsed = mod.parse_xcresult_test_results(summary_payload, {"testNodes": []})

    assert parsed["source"] == "xcresult-test-results"
    assert parsed["result"] == "fail"
    assert parsed["counts"]["tests"] == 7
    assert parsed["counts"]["failedTests"] == 1
    assert parsed["timings"]["testBodyMs"] == 0
    assert parsed["timings"]["xcresultSessionMs"] is None
    assert parsed["diagnostics"][0]["category"] == "test"
    assert "testSyncFails" in parsed["diagnostics"][0]["message"]


def test_parse_xcresult_test_results_rejects_skipped_only_unknown_summary():
    mod = _load_module()
    parsed = mod.parse_xcresult_test_results(
        {
            "result": "Unknown",
            "totalTestCount": 1,
            "passedTests": 0,
            "failedTests": 0,
            "skippedTests": 1,
            "expectedFailures": 0,
            "testFailures": [],
        },
        {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "name": "PodcastPlaybackPerfUITests/testProbe()",
                    "result": "Skipped",
                    "children": [
                        {
                            "nodeType": "Failure Message",
                            "name": "Test skipped - player not reached",
                        }
                    ],
                }
            ]
        },
    )

    assert parsed["result"] == "fail"
    assert parsed["counts"]["tests"] == 1
    assert parsed["counts"]["effectiveTests"] == 0
    assert parsed["counts"]["errors"] == 1
    assert parsed["diagnostics"][0]["category"] == "test-result-integrity"
    assert (
        "skipped/unknown tests are not a valid pass"
        in parsed["diagnostics"][0]["message"]
    )
    assert parsed["diagnostics"][1]["category"] == "test-skipped"
    assert "player not reached" in parsed["diagnostics"][1]["message"]


def test_format_text_includes_test_counts():
    mod = _load_module()
    parsed = mod.parse_xcresult_test_results(
        {
            "result": "Passed",
            "totalTestCount": 3,
            "passedTests": 3,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            "testFailures": [],
        },
        {"testNodes": []},
    )

    text = mod.format_text(parsed, xcresult_path="/tmp/Test.xcresult")

    assert "source=xcresult-test-results" in text
    assert "tests=3 passed=3 failed=0 skipped=0" in text
    assert "testBodyMs=0 xcresultSessionMs=None" in text


def test_parse_xcresult_test_results_extracts_case_durations():
    mod = _load_module()
    parsed = mod.parse_xcresult_test_results(
        {
            "result": "Passed",
            "totalTestCount": 2,
            "passedTests": 2,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            "testFailures": [],
            "startTime": 100.0,
            "finishTime": 103.5,
        },
        {
            "testNodes": [
                {
                    "nodeType": "Test Plan",
                    "children": [
                        {
                            "nodeType": "Unit test bundle",
                            "children": [
                                {
                                    "nodeType": "Test Case",
                                    "name": "a()",
                                    "result": "Passed",
                                    "duration": "0.2500s",
                                },
                                {
                                    "nodeType": "Test Case",
                                    "name": "b()",
                                    "result": "Passed",
                                    "duration": "1.5秒",
                                },
                            ],
                        }
                    ],
                }
            ]
        },
    )

    assert parsed["timings"]["testBodyMs"] == 1750
    assert parsed["timings"]["xcresultSessionMs"] == 3500


def test_parse_xcresult_test_results_extracts_app_launch_metric_summary():
    mod = _load_module()
    parsed = mod.parse_xcresult_test_results(
        {
            "result": "Passed",
            "totalTestCount": 1,
            "passedTests": 1,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            "testFailures": [],
        },
        {"testNodes": []},
        [
            {
                "testIdentifier": "BooksAndVocabUITests/testLaunchPerformance()",
                "testRuns": [
                    {
                        "metrics": [
                            {
                                "displayName": "Duration (AppLaunch)",
                                "identifier": "com.apple.dt.XCTMetric_ApplicationLaunch-AppLaunch.duration",
                                "measurements": [1.54, 1.42, 1.50],
                                "unitOfMeasurement": "s",
                            }
                        ]
                    }
                ],
            }
        ],
    )

    app_launch = parsed["performanceMetrics"]["appLaunch"]
    assert app_launch == {
        "tests": 1,
        "samples": 3,
        "averageMs": 1487,
        "minMs": 1420,
        "maxMs": 1540,
    }


def test_format_text_includes_app_launch_perf_summary():
    mod = _load_module()
    parsed = mod.parse_xcresult_test_results(
        {
            "result": "Passed",
            "totalTestCount": 1,
            "passedTests": 1,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            "testFailures": [],
        },
        {"testNodes": []},
        [
            {
                "testIdentifier": "BooksAndVocabUITests/testLaunchPerformance()",
                "testRuns": [
                    {
                        "metrics": [
                            {
                                "displayName": "Duration (AppLaunch)",
                                "identifier": "com.apple.dt.XCTMetric_ApplicationLaunch-AppLaunch.duration",
                                "measurements": [1.4, 1.5],
                                "unitOfMeasurement": "s",
                            }
                        ]
                    }
                ],
            }
        ],
    )

    text = mod.format_text(parsed, xcresult_path="/tmp/Test.xcresult")

    assert "metric=AppLaunch" in text
    assert "samples=2" in text
    assert "averageMs=1450" in text
