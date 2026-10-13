from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

import doctor

NOW = datetime(2026, 10, 7, 12, 0, tzinfo=timezone.utc)


def _run(conclusion: str, days_ago: float, workflow: str = "ops-suite") -> dict:
    created = NOW - timedelta(days=days_ago)
    return {
        "workflowName": workflow,
        "conclusion": conclusion,
        "status": "completed",
        "createdAt": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


# ---- known-red CI ---------------------------------------------------------


def test_a_fresh_failure_streak_is_not_known_red_yet() -> None:
    runs = [
        _run("failure", 0.1),
        _run("failure", 0.5),
        _run("failure", 1.0),
        _run("success", 2.0),
    ]
    [finding] = doctor.evaluate_ci(runs, NOW)
    assert finding.level == "ok"


def test_three_failures_older_than_three_days_are_known_red() -> None:
    runs = [
        _run("failure", 1),
        _run("failure", 4),
        _run("failure", 9),
        _run("success", 12),
    ]
    [finding] = doctor.evaluate_ci(runs, NOW)
    assert finding.level == "block"
    assert "ops-suite" in finding.summary and "3" in finding.summary


def test_streak_stops_at_the_newest_success() -> None:
    runs = [
        _run("success", 0.2),
        _run("failure", 5),
        _run("failure", 9),
        _run("failure", 12),
    ]
    [finding] = doctor.evaluate_ci(runs, NOW)
    assert finding.level == "ok"


@pytest.mark.parametrize("neutral", ["skipped", "cancelled", "neutral", ""])
def test_skipped_cancelled_and_unfinished_runs_do_not_count(neutral: str) -> None:
    runs = [
        _run(neutral, 0.1),
        _run("failure", 4),
        _run(neutral, 5),
        _run("failure", 8),
        _run("failure", 10),
    ]
    [finding] = doctor.evaluate_ci(runs, NOW)
    assert finding.level == "block"  # three real failures remain


def test_each_workflow_is_judged_separately() -> None:
    runs = [
        _run("failure", 5, "ops-suite"),
        _run("failure", 6, "ops-suite"),
        _run("failure", 9, "ops-suite"),
        _run("success", 1, "backend-quality"),
    ]
    findings = {f.summary.split()[0]: f for f in doctor.evaluate_ci(runs, NOW)}
    assert findings["ops-suite"].level == "block"
    assert findings["backend-quality"].level == "ok"


# ---- production release gap ----------------------------------------------


@pytest.mark.parametrize(
    ("behind", "age_days", "level"),
    [
        (0, 0, "ok"),
        (150, 10, "ok"),
        (250, 10, "warn"),
        (50, 20, "warn"),
        (1500, 10, "block"),
        (50, 60, "block"),
    ],
)
def test_release_gap_levels(behind: int, age_days: int, level: str) -> None:
    finding = doctor.evaluate_release_gap("abc1234", behind, age_days)
    assert finding.level == level


def test_unknown_production_version_is_a_warning_not_a_pass() -> None:
    assert doctor.evaluate_release_gap(None, None, None).level == "warn"


# ---- registry claims ------------------------------------------------------


def test_ghost_and_ownerless_claims_are_reported(tmp_path: Path) -> None:
    alive = tmp_path / "alive"
    alive.mkdir()
    records = [
        {
            "status": "active",
            "path": str(alive),
            "codex_thread_id": "t1",
            "branch": "a",
            "external_ids": ["A"],
        },
        {
            "status": "active",
            "path": str(tmp_path / "gone"),
            "codex_thread_id": "t2",
            "branch": "b",
            "external_ids": ["B"],
        },
        {
            "status": "active",
            "path": str(alive),
            "codex_thread_id": None,
            "branch": "c",
            "external_ids": ["C"],
        },
        {
            "status": "abandoned",
            "path": str(tmp_path / "x"),
            "codex_thread_id": None,
            "branch": "d",
            "external_ids": ["D"],
        },
    ]
    finding = doctor.evaluate_registry(records)
    assert finding.level == "warn"
    text = "\n".join(finding.detail)
    assert "ghost" in text and "b" in text
    assert "ownerless" in text and "c" in text
    assert "abandoned" not in text  # terminal records are not live claims


def test_a_clean_registry_is_ok() -> None:
    assert doctor.evaluate_registry([]).level == "ok"


# ---- git ------------------------------------------------------------------


def test_git_findings() -> None:
    assert (
        doctor.evaluate_git(
            {"branch": "main", "dirty": 0, "local": "a", "origin": "a"}
        ).level
        == "ok"
    )
    assert (
        doctor.evaluate_git(
            {"branch": "main", "dirty": 0, "local": "a", "origin": "b"}
        ).level
        == "warn"
    )
    assert (
        doctor.evaluate_git(
            {"branch": "feat/x", "dirty": 0, "local": "a", "origin": "a"}
        ).level
        == "warn"
    )
    assert (
        doctor.evaluate_git(
            {"branch": "main", "dirty": 3, "local": "a", "origin": "a"}
        ).level
        == "warn"
    )


# ---- disk guard -----------------------------------------------------------


def test_disk_guard_levels() -> None:
    assert (
        doctor.evaluate_disk({"verdict": "ok", "reason": "within-bounds"}).level == "ok"
    )
    assert doctor.evaluate_disk({"verdict": "warning", "reason": "x"}).level == "warn"
    assert doctor.evaluate_disk({"verdict": "block", "reason": "y"}).level == "block"
    assert (
        doctor.evaluate_disk(
            {"verdict": "critical", "reason": "free-below-critical"}
        ).level
        == "block"
    )
    assert doctor.evaluate_disk(None).level == "ok"  # no guard on this machine


# ---- issue acceptance -----------------------------------------------------

BODY = """## Problem
x

## Acceptance
Pass when it works.

```sh
test -f ops/doctor.py && echo ok
```

```bash
./ops/doctor.py --json | jq -e '.ok'
```

## Delivery plan
```sh
echo not-acceptance
```
"""


def test_only_commands_inside_the_acceptance_section_are_extracted() -> None:
    assert doctor.parse_acceptance(BODY) == [
        "test -f ops/doctor.py && echo ok",
        "./ops/doctor.py --json | jq -e '.ok'",
    ]


def test_issue_without_an_acceptance_command_is_reported_as_unverifiable() -> None:
    issues = [
        {"number": 1, "title": "a", "body": BODY, "authorAssociation": "OWNER"},
        {
            "number": 2,
            "title": "b",
            "body": "## Acceptance\nprose only",
            "authorAssociation": "OWNER",
        },
    ]
    finding = doctor.evaluate_issues(issues)
    assert finding.level == "warn"
    assert any("#2" in line for line in finding.detail)


def test_acceptance_runs_only_for_trusted_associations() -> None:
    issues = [
        {"number": 1, "body": BODY, "authorAssociation": "OWNER"},
        {"number": 2, "body": BODY, "authorAssociation": "NONE"},
        {"number": 3, "body": BODY, "authorAssociation": "CONTRIBUTOR"},
        {"number": 4, "body": BODY, "authorAssociation": "MEMBER"},
        {"number": 5, "body": "## Acceptance\nprose", "authorAssociation": "MEMBER"},
    ]
    assert [i["number"] for i in doctor.runnable_issues(issues)] == [1, 4]


def test_parse_acceptance_accepts_h3_criteria_and_stops_at_next_heading() -> None:
    body = (
        "### Acceptance criteria\n```sh\necho a\n```\n### Notes\n```sh\necho no\n```\n"
    )
    assert doctor.parse_acceptance(body) == ["echo a"]
    body = "## Acceptance\n```bash\necho b\n```\n### Later\n```sh\necho no\n```\n"
    assert doctor.parse_acceptance(body) == ["echo b"]


def test_issue_detector_follows_the_shapes_the_project_writes() -> None:
    # Real issue bodies (#2091/#2042/#3113) fence runnable commands under a
    # verification heading; epics are containers, not solver work.
    packet = (
        "## Solver Packet\n### Verification\nprose\n"
        "### Verification commands\n```bash\necho p\n```\n"
    )
    issues = [
        {"number": 1, "body": packet},
        {
            "number": 2,
            "body": "## 驗收\n- [ ] x\n### 驗證指令\n```bash\necho zh\n```\n",
        },
        {"number": 3, "body": "## Done when\n```sh\necho d\n```\n"},
        {"number": 4, "body": "## Problem\nno command", "labels": [{"name": "bug"}]},
        {"number": 5, "body": "## Problem\nparent", "labels": [{"name": "epic"}]},
    ]
    finding = doctor.evaluate_issues(issues)
    assert finding.detail == ["#4 has no machine acceptance command"]


def _gh_api(stdout: str, returncode: int = 0, stderr: str = ""):
    class Done:
        pass

    done = Done()
    done.stdout, done.returncode, done.stderr = stdout, returncode, stderr
    return lambda cmd, cwd, timeout=60: done


def test_collect_issues_drops_prs_maps_association_and_joins_pages(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    page1 = [
        {"number": 1, "body": "", "author_association": "OWNER", "labels": []},
        {"number": 2, "pull_request": {}, "author_association": "OWNER", "labels": []},
    ]
    page2 = [
        {
            "number": 3,
            "author_association": "MEMBER",
            "labels": [{"name": doctor.HEALTH_LABEL}],
        },
        {"number": 4, "author_association": "NONE", "labels": []},
    ]
    monkeypatch.setattr(doctor, "_run", _gh_api(json.dumps(page1) + json.dumps(page2)))
    issues = doctor.collect_issues(OPS.parent)
    assert [i["number"] for i in issues] == [1, 4]
    assert [i["authorAssociation"] for i in issues] == ["OWNER", "NONE"]


def test_collect_issues_failure_raises_with_stderr(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(doctor, "_run", _gh_api("", 1, "HTTP 502 boom"))
    with pytest.raises(doctor.IssueFetchError, match="HTTP 502 boom"):
        doctor.collect_issues(OPS.parent)


def test_main_reports_warn_not_ok_when_issue_fetch_fails(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def boom(repo: Path) -> list[dict]:
        raise doctor.IssueFetchError("HTTP 502 boom")

    monkeypatch.setattr(doctor, "collect_issues", boom)
    monkeypatch.setattr(doctor, "collect_ci", lambda repo: [])
    monkeypatch.setattr(doctor, "collect_complexity", lambda repo: (None, None))
    monkeypatch.setattr(doctor, "collect_delivery", lambda repo: None)
    monkeypatch.setattr(doctor, "collect_prod_info", lambda: None)
    monkeypatch.setattr(
        doctor, "collect_release_gap", lambda repo, now, info: (FULL, 1, 1.0)
    )
    monkeypatch.setattr(doctor, "collect_sentry_local", lambda repo: None)
    doctor.main(["--json", "--ci"])
    report = json.loads(capsys.readouterr().out)
    issues = [f for f in report["findings"] if f["section"] == "issues"]
    assert len(issues) == 1 and issues[0]["level"] == "warn"
    assert "HTTP 502 boom" in json.dumps(issues[0])


def test_running_acceptance_is_opt_in(monkeypatch: pytest.MonkeyPatch) -> None:
    args = doctor.build_parser().parse_args([])
    assert args.run_acceptance is False


def test_run_acceptance_reports_pass_and_fail(tmp_path: Path) -> None:
    issues = [
        {
            "number": 7,
            "title": "ok",
            "body": "## Acceptance\n```sh\ntrue\n```\n",
            "authorAssociation": "OWNER",
        },
        {
            "number": 8,
            "title": "bad",
            "body": "## Acceptance\n```sh\nfalse\n```\n",
            "authorAssociation": "OWNER",
        },
    ]
    results = doctor.run_acceptance(issues, cwd=tmp_path, timeout=30)
    assert results[7]["passed"] is True
    assert results[8]["passed"] is False


# ---- aggregation / exit code ----------------------------------------------


def test_exit_code_is_the_worst_level() -> None:
    mk = doctor.Finding
    assert doctor.exit_code([mk("a", "ok", "x"), mk("b", "ok", "y")]) == 0
    assert doctor.exit_code([mk("a", "ok", "x"), mk("b", "warn", "y")]) == 1
    assert doctor.exit_code([mk("a", "warn", "x"), mk("b", "block", "y")]) == 2


def test_report_is_machine_readable() -> None:
    report = doctor.render_json([doctor.Finding("git", "ok", "fine", ["d"])], now=NOW)
    data = json.loads(report)
    assert data["schema"] == "kg.doctor.v1"
    assert data["worst"] == "ok"
    assert data["findings"][0] == {
        "section": "git",
        "level": "ok",
        "summary": "fine",
        "detail": ["d"],
    }


# ---- collectors -----------------------------------------------------------


class _Done:
    def __init__(self, stdout: str, returncode: int = 0) -> None:
        self.stdout = stdout
        self.returncode = returncode


def test_ci_history_is_fetched_per_workflow_so_noise_cannot_crowd_it_out(
    tmp_path: Path,
) -> None:
    calls: list[list[str]] = []

    def fake(cmd: list[str], cwd: Path, timeout: int = 60) -> _Done:
        calls.append(cmd)
        if cmd[:3] == ["gh", "workflow", "list"]:
            return _Done(
                json.dumps(
                    [
                        {"name": "ops-suite", "state": "active"},
                        {"name": "agent-review", "state": "active"},
                        {"name": "retired", "state": "disabled_manually"},
                    ]
                )
            )
        name = cmd[cmd.index("--workflow") + 1]
        return _Done(
            json.dumps(
                [
                    _run("failure", 5, name),
                    _run("failure", 6, name),
                    _run("failure", 8, name),
                ]
            )
        )

    runs = doctor.collect_ci(tmp_path, run=fake)
    asked = [c[c.index("--workflow") + 1] for c in calls if "--workflow" in c]
    assert asked == ["ops-suite", "agent-review"]  # disabled workflows are skipped
    assert all(
        "--branch" in c and c[c.index("--branch") + 1] == "main"
        for c in calls
        if "--workflow" in c
    )
    assert {r["workflowName"] for r in runs} == {"ops-suite", "agent-review"}
    # and a three-day streak is now visible for each of them
    assert [f.level for f in doctor.evaluate_ci(runs, NOW)] == ["block", "block"]


def test_ci_collector_degrades_to_nothing_when_gh_is_unavailable(
    tmp_path: Path,
) -> None:
    assert doctor.collect_ci(tmp_path, run=lambda *a, **k: _Done("", 1)) == []


def test_production_probe_sends_a_user_agent_the_edge_accepts() -> None:
    request = doctor.prod_request()
    assert request.full_url.startswith("https://")
    assert request.get_header("User-agent") == "kg-doctor/1"


def test_known_red_names_the_runs_that_prove_it() -> None:
    runs = [
        {**_run("failure", 0.2), "url": "https://example/run/9"},
        {**_run("failure", 1.0), "url": "https://example/run/8"},
        {**_run("failure", 4.0), "url": "https://example/run/7"},
        _run("success", 6.0),
    ]
    [finding] = doctor.evaluate_ci(runs, NOW)
    assert finding.level == "block"
    assert any("https://example/run/9" in line for line in finding.detail)
    assert any("https://example/run/7" in line for line in finding.detail)


def test_known_red_evidence_tolerates_runs_without_a_url() -> None:
    runs = [_run("failure", 0.2), _run("failure", 1.0), _run("failure", 4.0)]
    [finding] = doctor.evaluate_ci(runs, NOW)
    assert finding.level == "block"
    assert any("(no url)" in line for line in finding.detail)


# ---- Sentry release integration (#2078) ------------------------------------

FULL = "0123456789abcdef0123456789abcdef01234567"
ALL_KEYS = {
    "SENTRY_AUTH_TOKEN": True,
    "SENTRY_ORG": True,
    "SENTRY_PROJECT_BACKEND": True,
    "SENTRY_PROJECT_IOS": True,
    "SENTRY_API_URL": False,
}


def _local(**overrides: object) -> dict:
    keys = dict(ALL_KEYS)
    keys.update({k: v for k, v in overrides.items() if k.startswith("SENTRY_")})
    return {
        "schema": "kg.sentry.release.check.v1",
        "env_file": "present",
        "keys": keys,
        "api_url": overrides.get("api_url", "valid"),
        "uploader": overrides.get("uploader", "uvx"),
        "sentry_cli": "3.8.0",
    }


def test_production_sentry_off_is_flagged_with_the_concrete_fix() -> None:
    finding = doctor.evaluate_sentry({"version": FULL, "sentry": False}, _local())
    assert finding.section == "sentry"
    assert finding.level == "warn"
    text = " ".join(finding.detail)
    assert "SENTRY_DSN" in text
    assert "~/kg-prod/backend/.env" in text
    assert "--force-recreate" in text


def test_sentry_unknown_when_offline_is_a_warning_not_a_crash_or_a_pass() -> None:
    finding = doctor.evaluate_sentry(None, _local())
    assert finding.level == "warn"
    assert "unknown" in " ".join(finding.detail)


def test_short_production_version_is_a_release_name_gap() -> None:
    finding = doctor.evaluate_sentry({"version": "33e98c429", "sentry": True}, _local())
    assert finding.level == "warn"
    text = " ".join(finding.detail)
    assert "kg-backend@" in text
    assert "full sha" in text


def test_fully_wired_sentry_is_ok() -> None:
    finding = doctor.evaluate_sentry({"version": FULL, "sentry": True}, _local())
    assert finding.level == "ok"
    assert f"kg-backend@{FULL[:9]}" in finding.summary


def test_ci_mode_judges_production_only() -> None:
    finding = doctor.evaluate_sentry(
        {"version": FULL, "sentry": True}, None, check_local=False
    )
    assert finding.level == "ok"


@pytest.mark.parametrize(
    ("missing", "consequence"),
    [
        ("SENTRY_PROJECT_BACKEND", "Sentry release"),
        ("SENTRY_PROJECT_IOS", "dSYM"),
    ],
)
def test_missing_local_release_config_names_key_consequence_and_file(
    missing: str, consequence: str
) -> None:
    finding = doctor.evaluate_sentry(
        {"version": FULL, "sentry": True}, _local(**{missing: False})
    )
    assert finding.level == "warn"
    text = " ".join(finding.detail)
    assert missing in text
    assert consequence in text
    assert "~/.secrets/sentry.env" in text


def test_missing_uploader_and_bad_api_url_are_gaps() -> None:
    finding = doctor.evaluate_sentry(
        {"version": FULL, "sentry": True}, _local(uploader="missing", api_url="invalid")
    )
    text = " ".join(finding.detail)
    assert "uvx" in text
    assert "SENTRY_API_URL" in text


def test_unreadable_local_check_is_a_gap_not_a_pass() -> None:
    finding = doctor.evaluate_sentry({"version": FULL, "sentry": True}, None)
    assert finding.level == "warn"
    assert "sentry_release.sh check" in " ".join(finding.detail)


def test_prod_info_collector_degrades_to_none_offline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def offline(*_a: object, **_k: object) -> None:
        raise OSError("network unreachable")

    monkeypatch.setattr(doctor.urllib.request, "urlopen", offline)
    assert doctor.collect_prod_info() is None


def test_release_gap_reuses_the_single_production_probe(tmp_path: Path) -> None:
    # No version in the probe → unknown, without a second network round-trip.
    assert doctor.collect_release_gap(tmp_path, NOW, None) == (None, None, None)
    assert doctor.collect_release_gap(tmp_path, NOW, {"sentry": True}) == (
        None,
        None,
        None,
    )


def test_local_sentry_check_runs_the_helper_without_leaking_values(
    tmp_path: Path,
) -> None:
    secret = "sntrys_DOCTORfakeTOKEN123456"
    env_file = tmp_path / "sentry.env"
    env_file.write_text(f"SENTRY_AUTH_TOKEN={secret}\nSENTRY_ORG=kg\n")
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(tmp_path),
        "SENTRY_ENV_FILE": str(env_file),
    }
    local = doctor.collect_sentry_local(OPS.parent, env=env)
    assert local is not None
    assert local["keys"]["SENTRY_AUTH_TOKEN"] is True
    assert local["keys"]["SENTRY_PROJECT_IOS"] is False
    assert secret not in json.dumps(local)


def test_main_reports_the_sentry_section(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    git = {"branch": "main", "dirty": 0, "local": "a", "origin": "a"}
    monkeypatch.setattr(doctor, "collect_git", lambda repo: git)
    monkeypatch.setattr(doctor, "collect_issues", lambda repo: [])
    monkeypatch.setattr(doctor, "collect_ci", lambda repo: [])
    monkeypatch.setattr(doctor, "collect_registry", lambda repo: [])
    monkeypatch.setattr(doctor, "collect_disk", lambda: None)
    monkeypatch.setattr(doctor, "collect_complexity", lambda repo: (None, None))
    monkeypatch.setattr(doctor, "collect_delivery", lambda repo: None)
    monkeypatch.setattr(
        doctor, "collect_prod_info", lambda: {"version": FULL, "sentry": False}
    )
    monkeypatch.setattr(
        doctor, "collect_release_gap", lambda repo, now, info: (FULL, 1, 1.0)
    )
    monkeypatch.setattr(doctor, "collect_sentry_local", lambda repo: _local())
    for argv in (["--json"], ["--json", "--ci"]):
        doctor.main(argv)
        report = json.loads(capsys.readouterr().out)
        sentry = [f for f in report["findings"] if f["section"] == "sentry"]
        assert len(sentry) == 1 and sentry[0]["level"] == "warn", argv


_REAL_COLLECT_REVIEW_QUOTA = doctor.collect_review_quota


@pytest.fixture(autouse=True)
def _no_live_review_quota(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(doctor, "collect_review_quota", lambda repo, now: None)


def test_review_quota_is_ok_and_visible_when_the_bot_never_hit_its_limit() -> None:
    finding = doctor.evaluate_review_quota({"month": 0, "recent": 0})
    assert (finding.section, finding.level) == ("review", "ok")
    assert "0 PR(s)" in finding.summary


def test_review_quota_warns_when_the_bot_hit_its_limit_recently() -> None:
    finding = doctor.evaluate_review_quota({"month": 9, "recent": 2})
    assert finding.level == "warn"
    assert "9 PR(s)" in finding.summary and "2 in the last" in finding.summary
    assert any("review_discipline.md" in line for line in finding.detail)


def test_review_quota_old_hits_stay_ok_but_visible() -> None:
    finding = doctor.evaluate_review_quota({"month": 4, "recent": 0})
    assert finding.level == "ok" and "4 PR(s)" in finding.summary


def test_review_quota_unavailable_reads_as_warn_not_zero() -> None:
    assert doctor.evaluate_review_quota(None).level == "warn"


def test_review_quota_is_informational_under_the_documented_fallback() -> None:
    data = {"month": 442, "recent": 83}
    finding = doctor.evaluate_review_quota(data, fallback_documented=True)
    assert finding.level == "ok" and "83 in the last 3d" in finding.summary


def test_the_sop_heading_behind_the_review_check_is_pinned() -> None:
    assert doctor.collect_review_fallback_documented(OPS.parent) is True
    assert doctor.collect_review_fallback_documented(OPS) is False


def test_collect_review_quota_counts_prs_for_both_windows() -> None:
    seen: list[list[str]] = []

    def run(cmd: list[str], cwd: Path, timeout: int = 60):
        del cwd, timeout
        seen.append(cmd)
        out = "[{}, {}, {}]" if "updated:>=2026-09-09" in " ".join(cmd) else "[{}]"
        return subprocess.CompletedProcess(cmd, 0, out, "")

    now = datetime(2026, 10, 9, tzinfo=timezone.utc)
    data = _REAL_COLLECT_REVIEW_QUOTA(OPS.parent, now, run)
    assert data == {"month": 3, "recent": 1}
    assert all(cmd[:3] == ["gh", "pr", "list"] for cmd in seen)


def test_collect_review_quota_failure_is_none() -> None:
    def run(cmd: list[str], cwd: Path, timeout: int = 60):
        del cwd, timeout
        return subprocess.CompletedProcess(cmd, 1, "", "boom")

    now = datetime(2026, 10, 9, tzinfo=timezone.utc)
    assert _REAL_COLLECT_REVIEW_QUOTA(OPS.parent, now, run) is None


def test_main_reports_the_review_quota_section(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(doctor, "collect_issues", lambda repo: [])
    monkeypatch.setattr(doctor, "collect_ci", lambda repo: [])
    monkeypatch.setattr(doctor, "collect_complexity", lambda repo: (None, None))
    monkeypatch.setattr(doctor, "collect_delivery", lambda repo: None)
    monkeypatch.setattr(doctor, "collect_prod_info", lambda: None)
    monkeypatch.setattr(
        doctor, "collect_release_gap", lambda repo, now, info: (FULL, 1, 1.0)
    )
    monkeypatch.setattr(doctor, "collect_sentry_local", lambda repo: None)
    monkeypatch.setattr(
        doctor, "collect_review_quota", lambda repo, now: {"month": 5, "recent": 1}
    )
    doctor.main(["--json", "--ci"])
    report = json.loads(capsys.readouterr().out)
    [review] = [f for f in report["findings"] if f["section"] == "review"]
    assert review["level"] == "ok" and "5 PR(s)" in review["summary"]
