from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

import release_train as rt


def proc(
    code: int = 0, out: str = "", err: str = ""
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess([], code, out, err)


# ---- prod-ff ---------------------------------------------------------------


def test_a_fast_forwardable_prod_is_ok() -> None:
    assert rt.evaluate_prod_ff(True, 12).level == "ok"


def test_a_diverged_prod_blocks_because_the_reconciler_pulls_ff_only() -> None:
    finding = rt.evaluate_prod_ff(False, 12)
    assert finding.level == "block"
    assert "ff-only" in finding.detail[0]


# ---- format drift ------------------------------------------------------------


def test_clean_files_pass_and_each_unformatted_file_blocks_by_name() -> None:
    assert rt.evaluate_format({"backend/src/kg/api.py": False}).level == "ok"
    finding = rt.evaluate_format({"a.py": True, "b.py": False, "c.py": True})
    assert finding.level == "block"
    assert [d.split(":")[0] for d in finding.detail] == ["a.py", "c.py"]


def test_collect_format_feeds_main_s_blob_to_ruff_on_stdin_and_reads_the_exit_code() -> (
    None
):
    seen: list[dict[str, Any]] = []

    def run(
        cmd: list[str], cwd: Path | None = None, stdin: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        seen.append({"cmd": cmd, "stdin": stdin})
        if cmd[0] == "git":
            return proc(out="print( 1 )")
        return proc(1 if "print( 1 )" in (stdin or "") else 0)

    drift = rt.collect_format(Path("."), run=run)
    assert drift == {"backend/src/kg/api.py": True}
    ruff = seen[-1]["cmd"]
    assert "--stdin-filename" in ruff
    assert "ruff==0.16.3" in ruff  # the same pin the PR gate uses


# ---- felix production clone --------------------------------------------------


@pytest.mark.parametrize(
    ("facts", "level"),
    [
        ({"ahead": 0, "behind": 0, "dirty": False, "version": "x"}, "ok"),
        ({"ahead": 0, "behind": 3, "dirty": False, "version": "x"}, "block"),
        ({"ahead": 2, "behind": 0, "dirty": False, "version": "x"}, "block"),
        ({"ahead": 0, "behind": 0, "dirty": True, "version": "x"}, "block"),
        (None, "warn"),
    ],
)
def test_the_production_clone_must_be_exactly_origin_prod(
    facts: Any, level: str
) -> None:
    assert rt.evaluate_prod_clone(facts).level == level


def test_a_diverged_clone_names_the_known_remedy() -> None:
    finding = rt.evaluate_prod_clone(
        {"ahead": 4829, "behind": 4829, "dirty": False, "version": "x"}
    )
    assert "reset --keep origin/prod" in finding.detail[0]


def test_collect_prod_clone_parses_the_remote_report() -> None:
    def run(cmd: list[str], **_: Any) -> subprocess.CompletedProcess[str]:
        return proc(out="4829\t4829\n0\n3b5437ff\n")

    assert rt.collect_prod_clone(run) == {
        "ahead": 4829,
        "behind": 4829,
        "dirty": False,
        "version": "3b5437ff",
    }


def test_an_unreachable_felix_yields_no_facts_not_a_crash() -> None:
    assert rt.collect_prod_clone(lambda cmd, **_: proc(255)) is None
    assert rt.collect_reconciler(lambda cmd, **_: proc(255)) == (None, False)


# ---- reconciler --------------------------------------------------------------


@pytest.mark.parametrize(
    ("verdict", "loaded", "level"),
    [
        ({"verdict": "noop"}, True, "ok"),
        ({"verdict": "dry-run"}, True, "ok"),
        ({"verdict": "poisoned-skip"}, True, "block"),
        ({"verdict": "rollback-failed"}, True, "block"),
        ({"verdict": "locked"}, True, "warn"),
        ({"verdict": "noop"}, False, "block"),
        (None, True, "block"),
    ],
)
def test_reconciler_states(verdict: Any, loaded: bool, level: str) -> None:
    assert rt.evaluate_reconciler(verdict, loaded).level == level


def test_collect_reconciler_reads_the_last_json_line_and_the_launchd_count() -> None:
    out = 'noise\n{"verdict":"noop","deployed_sha":"a"}\n---\n1\n'
    verdict, loaded = rt.collect_reconciler(lambda cmd, **_: proc(out=out))
    assert verdict == {"verdict": "noop", "deployed_sha": "a"}
    assert loaded is True


# ---- alignment ---------------------------------------------------------------


def test_alignment_requires_live_to_be_on_origin_prod_and_the_clone_version() -> None:
    assert (
        rt.evaluate_alignment("91dc4d4ea", "91dc4d4ea70cbd8", "91dc4d4ea").level == "ok"
    )
    behind = rt.evaluate_alignment("3b5437ff", "91dc4d4ea70cbd8", "3b5437ff")
    assert behind.level == "warn"
    assert "unresolved" in behind.detail[0]
    assert (
        rt.evaluate_alignment("91dc4d4ea", "91dc4d4ea70cbd8", "deadbeef").level
        == "warn"
    )
    assert rt.evaluate_alignment(None, "91dc4d4", None).level == "warn"


# ---- backup ------------------------------------------------------------------


@pytest.mark.parametrize(
    ("age", "level"), [(None, "block"), (1.0, "ok"), (24.0, "ok"), (24.5, "block")]
)
def test_a_backup_must_exist_and_be_fresh(age: float | None, level: str) -> None:
    assert rt.evaluate_backup(age).level == level


def test_collect_backup_age_uses_the_newest_archive(tmp_path: Path) -> None:
    assert rt.collect_backup_age(tmp_path) is None
    (tmp_path / "backups").mkdir()
    old, new = tmp_path / "backups/data_1.tar.gz", tmp_path / "backups/data_2.tar.gz"
    old.write_text("x")
    new.write_text("x")
    import os

    os.utime(old, (1_000_000, 1_000_000))
    os.utime(new, (1_000_000 + 3600 * 5, 1_000_000 + 3600 * 5))
    assert rt.collect_backup_age(tmp_path, now=1_000_000 + 3600 * 7) == pytest.approx(
        2.0
    )


# ---- env ---------------------------------------------------------------------


def test_env_check_marks_are_read_as_missing_vars() -> None:
    assert rt.evaluate_env("✓ JWT_SECRET\n✓ GEMINI_API_KEY\n").level == "ok"
    finding = rt.evaluate_env("✓ JWT_SECRET\n✗ ADMIN_TOKEN\n")
    assert finding.level == "block"
    assert finding.detail == ["✗ ADMIN_TOKEN"]
    rule = rt.evaluate_env("✓ JWT_SECRET\n✗ [jwt-min-length] JWT_SECRET 長度 31\n")
    assert rule.level == "block"
    assert "backend startup rule" in rule.summary
    assert "missing var" in rule.summary
    assert rt.evaluate_env(None).level == "warn"


# ---- hot path ----------------------------------------------------------------


def test_hot_path_files_raise_a_warning_that_lists_them() -> None:
    changed = [
        "backend/src/kg/auth_service.py",
        "backend/src/kg/billing/payloads.py",
        "backend/src/kg/vocab_handlers/crud.py",
        "backend/src/kg/cards/schema.py",
    ]
    finding = rt.evaluate_hot_path(changed)
    assert finding.level == "warn"
    assert "3" in finding.summary
    assert "backend/src/kg/cards/schema.py" not in finding.detail


def test_a_release_without_hot_path_files_is_quiet() -> None:
    assert (
        rt.evaluate_hot_path(
            ["backend/src/kg/cards/schema.py", "backend/pyproject.toml"]
        ).level
        == "ok"
    )


def test_long_hot_path_lists_are_truncated_with_a_count() -> None:
    changed = [f"backend/src/kg/auth_{i}.py" for i in range(20)]
    detail = rt.evaluate_hot_path(changed).detail
    assert len(detail) == 13
    assert detail[-1] == "... and 8 more"


# ---- cli ---------------------------------------------------------------------


def test_exit_code_follows_the_worst_finding(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(
        rt,
        "build_findings",
        lambda repo, remote: [
            rt.Finding("a", "ok", "fine"),
            rt.Finding("b", "block", "no"),
        ],
    )
    assert rt.main(["--json", "--skip-remote"]) == 2
    assert json.loads(capsys.readouterr().out)["worst"] == "block"


# ---- CI must never read as healthy when its history is unreadable -------------


def test_a_workflow_whose_runs_cannot_be_listed_is_not_reported_as_ok(
    tmp_path: Path,
) -> None:
    def fake(cmd: list[str], cwd: Path, timeout: int = 60) -> Any:
        if cmd[:3] == ["gh", "workflow", "list"]:
            return proc(
                out=json.dumps(
                    [
                        {"name": "ops-suite", "state": "active"},
                        {"name": "agent-review", "state": "active"},
                    ]
                )
            )
        name = cmd[cmd.index("--workflow") + 1]
        if name == "agent-review":
            return proc(code=1)
        return proc(
            out=json.dumps(
                [
                    {
                        "workflowName": name,
                        "conclusion": "success",
                        "status": "completed",
                        "createdAt": "2026-10-13T00:00:00Z",
                        "url": "",
                    }
                ]
            )
        )

    findings = rt.ci_findings(rt.doctor.collect_ci(tmp_path, run=fake))
    assert not [f for f in findings if f.level == "ok"]
    assert [f.level for f in findings] == ["warn"]
    assert "agent-review" in findings[0].summary


def test_an_unreadable_workflow_list_is_unknown_not_healthy(tmp_path: Path) -> None:
    findings = rt.ci_findings(
        rt.doctor.collect_ci(tmp_path, run=lambda *a, **k: proc(code=1))
    )
    assert [f.level for f in findings] == ["warn"]
    assert "unknown" in findings[0].summary


# ---- doctor integration --------------------------------------------------------


def test_build_findings_drives_the_real_doctor_release_gap_offline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # No stub of doctor.collect_release_gap: its real signature must accept what
    # release_train passes. --skip-remote must stay offline, so a network probe fails.
    repo = OPS.parent
    for ref in ("origin/prod", "origin/main"):
        known = subprocess.run(
            ["git", "rev-parse", "--verify", "-q", ref],
            cwd=repo,
            capture_output=True,
            check=False,
        )
        if known.returncode:
            pytest.skip(f"{ref} is required")

    def no_network(*_a: Any, **_k: Any) -> Any:
        raise AssertionError("--skip-remote must not touch the network")

    monkeypatch.setattr(rt.doctor.urllib.request, "urlopen", no_network)
    findings = rt.build_findings(repo, remote=False)
    alignment = next(f for f in findings if f.section == "alignment")
    assert alignment.level == "warn"
    assert alignment.summary == "live version unavailable"
