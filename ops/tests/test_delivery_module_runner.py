from __future__ import annotations

import math
import subprocess
import sys
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.module_runner import ModuleCommandRunner  # noqa: E402
from delivery_control.adapters.subprocess_runner import SubprocessCommandRunner  # noqa: E402
from lib import executables  # noqa: E402


def _git_repo(path: Path, *, marker: str) -> None:
    path.mkdir()
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(
        ["git", "-C", str(path), "config", "user.email", "tests@example.test"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(path), "config", "user.name", "Delivery Tests"],
        check=True,
    )
    (path / "marker.txt").write_text(marker, encoding="utf-8")
    control_plane = path / "ops"
    control_plane.mkdir()
    (control_plane / "worktree_registry.py").write_text(
        "# registry fixture\n", encoding="utf-8"
    )
    subprocess.run(["git", "-C", str(path), "add", "marker.txt", "ops"], check=True)
    subprocess.run(
        ["git", "-C", str(path), "commit", "-qm", f"fixture {marker}"],
        check=True,
    )


def test_loaded_module_survives_source_executable_removal(tmp_path: Path) -> None:
    executable = tmp_path / "command.py"
    executable.touch()

    def main(argv: list[str] | None) -> int:
        assert argv == ["resolve", "--json"]
        print('{"status":"published"}')
        return 0

    runner = ModuleCommandRunner(executable=executable, main=main)
    executable.unlink()

    result = runner.run((str(executable), "resolve", "--json"))

    assert result.exit_code == 0
    assert result.stdout == '{"status":"published"}\n'
    assert result.stderr == ""


def test_runner_allows_different_product_head_when_control_plane_matches(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source"
    target = tmp_path / "target"
    _git_repo(source, marker="source")
    _git_repo(target, marker="target")
    executable = source / "command.py"
    executable.touch()
    subprocess.run(["git", "-C", str(source), "add", "command.py"], check=True)
    subprocess.run(
        ["git", "-C", str(source), "commit", "-qm", "add command executable"],
        check=True,
    )
    called = False

    def main(argv: list[str] | None) -> int:
        nonlocal called
        called = True
        return 0

    runner = ModuleCommandRunner(
        executable=executable,
        main=main,
        source_root=source,
        target_repo=target,
    )

    result = runner.run((str(executable), "list", "--json"))

    assert result.exit_code == 0
    assert called is True


def test_runner_rejects_control_plane_drift(tmp_path: Path) -> None:
    source = tmp_path / "source"
    target = tmp_path / "target"
    _git_repo(source, marker="same")
    subprocess.run(["git", "clone", "-q", str(source), str(target)], check=True)
    subprocess.run(
        ["git", "-C", str(target), "config", "user.email", "tests@example.test"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(target), "config", "user.name", "Delivery Tests"],
        check=True,
    )
    target_registry = target / "ops" / "worktree_registry.py"
    target_registry.write_text("# drifted registry fixture\n", encoding="utf-8")
    subprocess.run(
        ["git", "-C", str(target), "add", "ops/worktree_registry.py"], check=True
    )
    subprocess.run(
        ["git", "-C", str(target), "commit", "-qm", "drift registry"], check=True
    )
    executable = source / "command.py"
    executable.write_text("# command fixture\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(source), "add", "command.py"], check=True)
    subprocess.run(
        ["git", "-C", str(source), "commit", "-qm", "add command executable"],
        check=True,
    )
    called = False

    def main(_argv: list[str] | None) -> int:
        nonlocal called
        called = True
        return 0

    runner = ModuleCommandRunner(
        executable=executable,
        main=main,
        source_root=source,
        target_repo=target,
    )

    result = runner.run((str(executable), "list", "--json"))

    assert result.exit_code == 78
    assert "source fingerprint differs from target repo" in result.stderr
    assert called is False


def _dirty_runner_result(tmp_path: Path, mutate) -> "object":
    source = tmp_path / "source"
    _git_repo(source, marker="source")
    target = tmp_path / "target"
    subprocess.run(["git", "clone", "-q", str(source), str(target)], check=True)
    executable = source / "command.py"
    executable.touch()
    mutate(source)
    runner = ModuleCommandRunner(
        executable=executable,
        main=lambda _argv: 0,
        source_root=source,
        target_repo=target,
    )
    return runner.run((str(executable), "list", "--json"))


def test_runner_rejects_tracked_modification_and_names_path(tmp_path: Path) -> None:
    def mutate(source: Path) -> None:
        (source / "marker.txt").write_text("changed", encoding="utf-8")

    tracked = tmp_path / "source"
    result = _dirty_runner_result(tmp_path, mutate)

    assert result.exit_code == 78
    assert "source checkout is dirty" in result.stderr
    assert "marker.txt" in result.stderr
    assert f"git -C {tracked}" in result.stderr


def test_runner_rejects_untracked_file_under_ops_and_names_path(
    tmp_path: Path,
) -> None:
    def mutate(source: Path) -> None:
        (source / "ops").mkdir(exist_ok=True)
        (source / "ops" / "stray.py").write_text("x", encoding="utf-8")

    result = _dirty_runner_result(tmp_path, mutate)

    assert result.exit_code == 78
    assert "ops/stray.py" in result.stderr


def test_runner_allows_untracked_root_scratch_file(tmp_path: Path) -> None:
    def mutate(source: Path) -> None:
        (source / "scratchpad_patch.py").write_text("", encoding="utf-8")

    result = _dirty_runner_result(tmp_path, mutate)

    assert result.exit_code == 0, result.stderr


def test_runner_allows_exact_clean_source_and_target_checkouts(tmp_path: Path) -> None:
    source = tmp_path / "source"
    _git_repo(source, marker="source")
    executable = source / "command.py"
    executable.write_text("# executable fixture\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(source), "add", "command.py"], check=True)
    subprocess.run(
        ["git", "-C", str(source), "commit", "-qm", "add command executable"],
        check=True,
    )
    target = tmp_path / "target"
    subprocess.run(["git", "clone", "-q", str(source), str(target)], check=True)

    runner = ModuleCommandRunner(
        executable=executable,
        main=lambda argv: 0 if argv == ["list", "--json"] else 64,
        source_root=source,
        target_repo=target,
    )

    result = runner.run((str(executable), "list", "--json"))

    assert result.exit_code == 0


def test_runner_allows_final_cas_after_validated_source_is_removed(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source"
    target = tmp_path / "target"
    _git_repo(source, marker="same")
    subprocess.run(["git", "clone", "-q", str(source), str(target)], check=True)
    executable = source / "command.py"
    executable.write_text("# command fixture\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(source), "add", "command.py"], check=True)
    subprocess.run(
        ["git", "-C", str(source), "commit", "-qm", "add command executable"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(target), "fetch", "-q", str(source), "HEAD"], check=True
    )
    subprocess.run(
        ["git", "-C", str(target), "reset", "-q", "--hard", "FETCH_HEAD"],
        check=True,
    )
    runner = ModuleCommandRunner(
        executable=executable,
        main=lambda _argv: 0,
        source_root=source,
        target_repo=target,
    )

    first = runner.run((str(executable), "list", "--json"))
    assert first.exit_code == 0
    import shutil

    shutil.rmtree(source)

    second = runner.run((str(executable), "resolve", "--json"))

    assert second.exit_code == 0


def test_subprocess_runner_returns_normal_result() -> None:
    result = SubprocessCommandRunner(timeout_seconds=30).run(
        ("sh", "-c", "printf ready")
    )

    assert result.exit_code == 0
    assert result.stdout == "ready"
    assert result.stderr == ""
    assert result.timed_out is False


@pytest.mark.parametrize("command", ("git", "gh"))
def test_subprocess_runner_uses_fallback_without_ambient_path(
    command: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fallback = tmp_path / f"{command}-fallback"
    fallback.write_text("#!/bin/sh\nprintf '%s' \"$1\"\n", encoding="utf-8")
    fallback.chmod(0o755)
    monkeypatch.setenv("PATH", "")
    monkeypatch.setitem(executables._FALLBACK_EXECUTABLES, command, (str(fallback),))

    result = SubprocessCommandRunner(timeout_seconds=30).run((command, "ready"))

    assert result.exit_code == 0
    assert result.stdout == "ready"
    assert result.argv == (str(fallback), "ready")


def test_module_runner_uses_git_fallback_without_ambient_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "source"
    target = tmp_path / "target"
    _git_repo(source, marker="same")
    subprocess.run(["git", "clone", "-q", str(source), str(target)], check=True)
    executable = source / "command.py"
    executable.write_text("# command fixture\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(source), "add", "command.py"], check=True)
    subprocess.run(
        ["git", "-C", str(source), "commit", "-qm", "add command executable"],
        check=True,
    )
    monkeypatch.setenv("PATH", "")

    runner = ModuleCommandRunner(
        executable=executable,
        main=lambda _argv: 0,
        source_root=source,
        target_repo=target,
    )

    result = runner.run((str(executable), "list", "--json"))

    assert result.exit_code == 0


def test_subprocess_runner_converts_timeout_to_structured_failure() -> None:
    result = SubprocessCommandRunner(timeout_seconds=0.05).run(("sleep", "1"))

    assert result.exit_code == 124
    assert result.timed_out is True
    assert "command timed out after 0.05s" in result.stderr


def test_subprocess_runner_supports_a_tighter_per_command_timeout() -> None:
    result = SubprocessCommandRunner(timeout_seconds=1).run_with_timeout(
        ("sleep", "1"), timeout_seconds=0.05
    )

    assert result.exit_code == 124
    assert result.timed_out is True
    assert "command timed out after 0.05s" in result.stderr


@pytest.mark.parametrize("timeout", (0, -1, math.inf, math.nan))
def test_subprocess_runner_rejects_invalid_timeout(timeout: float) -> None:
    with pytest.raises(ValueError, match="finite and positive"):
        SubprocessCommandRunner(timeout_seconds=timeout)
