from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

OPS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OPS))

from delivery_control.adapters.operation_lock import _HELD_LOCKS, OperationLock
from delivery_control.cli import main


def test_operation_lock_allows_nested_context_without_releasing_outer_lease(
    tmp_path: Path,
) -> None:
    with OperationLock(tmp_path, command="sync-main"):
        with OperationLock(tmp_path, command="cleanup-merged"):
            pass
        with OperationLock(tmp_path, command="registry:resolve"):
            pass


def test_operation_lock_rejects_an_external_process(tmp_path: Path) -> None:
    script = """
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[2])
from delivery_control.adapters.operation_lock import OperationLock
with OperationLock(Path(sys.argv[1]), command='child'):
    pass
"""

    with (
        OperationLock(tmp_path, command="sync-main"),
        pytest.raises(subprocess.CalledProcessError),
    ):
        subprocess.run(
            [sys.executable, "-c", script, str(tmp_path), str(OPS)],
            check=True,
            env={**os.environ, "PYTHONPATH": str(OPS)},
            capture_output=True,
            text=True,
        )


def test_operation_lock_releases_after_context_exit(tmp_path: Path) -> None:
    with OperationLock(tmp_path, command="sync-main"):
        pass

    with OperationLock(tmp_path, command="cleanup-merged"):
        pass


def test_cli_reuses_the_outer_lease_for_nested_registry_mutation(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    lock_path = OperationLock(tmp_path, command="probe").path

    class FakeApplication:
        repo = tmp_path

        def __init__(self) -> None:
            self.calls: list[tuple[int, int]] = []

        def record_published_base(self, pull_request_number: int) -> object:
            # record-published-base keeps the whole-command lease: the CLI
            # re-entered the outer lease instead of contending on the flock.
            depth = _HELD_LOCKS[lock_path][1]
            with OperationLock(tmp_path, command="registry:record-published-base"):
                self.calls.append((pull_request_number, depth))
            return {"recorded": True}

    application = FakeApplication()
    with OperationLock(tmp_path, command="sync-main"):
        assert (
            main(
                ["record-published-base", "--pr", "41"],
                application_factory=lambda **_: application,
            )
            == 0
        )

    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is True
    assert application.calls == [(41, 2)]


def test_suite_lock_is_isolated_from_the_real_delivery_lock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A real delivery holding the shared lock must not redden this suite."""
    import fcntl

    from worktree_registry_core.environment import common_anchor

    # The lock registry/orchestrate actually contend on lives at the canonical
    # anchor (common dir parent), not at a linked worktree's own .cache.
    anchor = common_anchor(OPS.parent)
    with monkeypatch.context() as real:
        real.delenv("KG_DELIVERY_LOCK_DIR", raising=False)
        real_lock = OperationLock(anchor, command="probe").path
    real_lock.parent.mkdir(parents=True, exist_ok=True)
    with real_lock.open("a+") as held:
        try:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            # A real delivery already holds it: exactly the contended scenario.
            pass
        assert OperationLock(anchor, command="suite").path != real_lock
        with OperationLock(anchor, command="suite-under-real-delivery"):
            pass


def test_lock_dir_env_override_is_keyed_per_repo(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("KG_DELIVERY_LOCK_DIR", str(tmp_path / "locks"))
    repo_a, repo_b = tmp_path / "a", tmp_path / "b"
    repo_a.mkdir()
    repo_b.mkdir()
    with OperationLock(repo_a, command="a"):
        assert OperationLock(repo_a, command="a").path.parent == tmp_path / "locks"
        with OperationLock(repo_b, command="b"):
            pass
    assert (
        OperationLock(repo_a, command="a").path
        != OperationLock(repo_b, command="b").path
    )


# --- opt-in bounded wait (#2423) -------------------------------------------

_BUSY = (
    "delivery mutation already in progress; "
    "command=waiter; retry after the active operation exits"
)

_HOLDER = """
from pathlib import Path
import sys, time
sys.path.insert(0, sys.argv[2])
from delivery_control.adapters.operation_lock import OperationLock
with OperationLock(Path(sys.argv[1]), command='holder'):
    print('ready', flush=True)
    time.sleep(float(sys.argv[3]))
"""


def _spawn_holder(repo: Path, hold: float) -> subprocess.Popen[str]:
    proc = subprocess.Popen(
        [sys.executable, "-c", _HOLDER, str(repo), str(OPS), str(hold)],
        env={**os.environ, "PYTHONPATH": str(OPS)},
        stdout=subprocess.PIPE,
        text=True,
    )
    assert proc.stdout is not None
    assert proc.stdout.readline().strip() == "ready"
    return proc


def test_wait_env_acquires_after_holder_exits(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("KG_DELIVERY_LOCK_WAIT_SECONDS", "10")
    holder = _spawn_holder(tmp_path, 0.5)
    try:
        with OperationLock(tmp_path, command="waiter"):
            assert holder.poll() is not None or holder.wait(timeout=5) == 0
    finally:
        holder.wait(timeout=10)


def test_wait_env_timeout_yields_identical_busy_message(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from delivery_control.domain.errors import DeliverySourceError

    monkeypatch.setenv("KG_DELIVERY_LOCK_WAIT_SECONDS", "0.3")
    holder = _spawn_holder(tmp_path, 3)
    try:
        started = time.monotonic()
        with pytest.raises(DeliverySourceError) as raised:
            OperationLock(tmp_path, command="waiter").__enter__()
        assert str(raised.value) == _BUSY
        assert time.monotonic() - started >= 0.3
    finally:
        holder.kill()
        holder.wait(timeout=10)


def test_wait_default_is_on_when_env_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    from delivery_control.adapters import operation_lock as module

    monkeypatch.delenv("KG_DELIVERY_LOCK_WAIT_SECONDS", raising=False)
    monkeypatch.delenv(module.LOCK_DIR_ENV, raising=False)
    assert module._wait_seconds() == module.DEFAULT_WAIT_SECONDS > 0
    monkeypatch.setenv(module.LOCK_DIR_ENV, "/tmp/claude-lane-2871/isolated")
    assert module._wait_seconds() == 0  # isolated test suite stays fail-fast


@pytest.mark.parametrize("value", ["0", "-3", "abc", "nan", ""])
def test_wait_env_zero_or_invalid_fails_fast(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, value: str
) -> None:
    from delivery_control.domain.errors import DeliverySourceError

    monkeypatch.setenv("KG_DELIVERY_LOCK_WAIT_SECONDS", value)
    holder = _spawn_holder(tmp_path, 3)
    try:
        started = time.monotonic()
        with pytest.raises(DeliverySourceError) as raised:
            OperationLock(tmp_path, command="waiter").__enter__()
        assert str(raised.value) == _BUSY
        assert time.monotonic() - started < 1.5
    finally:
        holder.kill()
        holder.wait(timeout=10)


def test_wait_env_does_not_delay_reentrant_entry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("KG_DELIVERY_LOCK_WAIT_SECONDS", "5")
    with OperationLock(tmp_path, command="outer"):
        started = time.monotonic()
        with OperationLock(tmp_path, command="inner"):
            pass
        assert time.monotonic() - started < 1.5


def test_wait_env_lets_two_contending_processes_both_succeed(
    tmp_path: Path,
) -> None:
    script = """
from pathlib import Path
import sys, time
sys.path.insert(0, sys.argv[2])
from delivery_control.adapters.operation_lock import OperationLock
with OperationLock(Path(sys.argv[1]), command='contender'):
    print('holding', flush=True)
    time.sleep(0.3)
"""
    env = {
        **os.environ,
        "PYTHONPATH": str(OPS),
        "KG_DELIVERY_LOCK_WAIT_SECONDS": "30",
    }
    cmd = [sys.executable, "-c", script, str(tmp_path), str(OPS)]
    first = subprocess.Popen(
        cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    assert first.stdout is not None
    # The first process must provably hold the lease before the contender starts.
    assert first.stdout.readline().strip() == "holding"
    second = subprocess.Popen(cmd, env=env, stderr=subprocess.PIPE, text=True)
    assert [first.wait(timeout=60), second.wait(timeout=60)] == [0, 0]


def test_wait_seconds_are_capped_and_explicit_override_wins(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from delivery_control.adapters import operation_lock as module

    for raw in ("inf", "1e400", "99999"):
        monkeypatch.setenv("KG_DELIVERY_LOCK_WAIT_SECONDS", raw)
        assert module._wait_seconds() == module.MAX_WAIT_SECONDS
    monkeypatch.setenv("KG_DELIVERY_LOCK_WAIT_SECONDS", "120")
    assert module._wait_seconds(5) == 5
    assert module._wait_seconds(0) == 0
    assert module._wait_seconds(float("inf")) == module.MAX_WAIT_SECONDS
    assert module._wait_seconds(float("nan")) == 0


class _Interrupt(BaseException):
    """Stand-in for KeyboardInterrupt, which pytest itself intercepts."""


def test_interrupt_during_wait_closes_the_handle(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from delivery_control.adapters import operation_lock as module

    holder = _spawn_holder(tmp_path, 5)
    opened: list[object] = []
    real_open = Path.open

    def tracking_open(self: Path, *args: object, **kwargs: object) -> object:
        handle = real_open(self, *args, **kwargs)  # type: ignore[arg-type]
        opened.append(handle)
        return handle

    def interrupted(_seconds: float) -> None:
        raise _Interrupt

    try:
        with monkeypatch.context() as patch:
            patch.setattr(Path, "open", tracking_open)
            patch.setattr(module.time, "sleep", interrupted)
            with pytest.raises(_Interrupt):
                OperationLock(tmp_path, command="waiter", wait_seconds=10).__enter__()
        assert opened and all(handle.closed for handle in opened)  # type: ignore[attr-defined]
    finally:
        holder.kill()
        holder.wait(timeout=10)
