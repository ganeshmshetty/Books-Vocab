"""Cross-process serialization for delivery-control mutations.

The delivery CLI can be invoked concurrently by a supervisor, an integrator,
or a cleanup retry.  Registry CAS protects the ledger, but Git operations such
as sync, worktree removal, and branch deletion still share the repository's
index and refs.  This lock serializes registry read-modify-write and local
worktree/ref mutation while leaving observation commands concurrent.  Most
mutating commands hold it for their whole run; ``queue``, ``cleanup-merged``
and ``release-published`` take it only around those local sections, so their
GitHub API calls, ``ls-remote`` and ``push`` run outside it (#2236).  The
lease polls every ~0.1s for up to ``DEFAULT_WAIT_SECONDS`` before the busy
refusal (#2423, #2871); ``KG_DELIVERY_LOCK_WAIT_SECONDS=0`` (or a negative or
unparsable value) restores the single fail-fast try.  The kernel
releases the lock when the owning process exits, so a stale lock file is
harmless.
"""

from __future__ import annotations

import errno
import fcntl
import hashlib
import os
import time
from pathlib import Path
from types import TracebackType
from typing import IO, Self

from ..domain.errors import DeliverySourceError

# The delivery CLI owns the process-wide lease while the registry adapter can
# invoke the registry CLI in-process during that same mutation.  Re-entering
# here must share the existing kernel handle; other processes still contend on
# the flock.
_HELD_LOCKS: dict[Path, tuple[IO[str], int]] = {}

# Test isolation hook: when set, the lease lives in this directory (one file
# per canonical repo) instead of ``<repo>/.cache``.  ops/tests/conftest.py points
# it at a per-test tmp dir so a real delivery holding the shared lock cannot
# redden the suite.  TEST-ONLY: processes that disagree on this value stop
# excluding each other, which silently weakens the fail-closed lease, so never
# set it in an operator, launchd, or CI delivery environment.
LOCK_DIR_ENV = "KG_DELIVERY_LOCK_DIR"

# Bounded wait: unset means DEFAULT_WAIT_SECONDS; invalid or <= 0 is fail-fast.
WAIT_SECONDS_ENV = "KG_DELIVERY_LOCK_WAIT_SECONDS"
DEFAULT_WAIT_SECONDS = 30.0
_POLL_INTERVAL = 0.1
# Absurd values (inf, 1e400) must not park a process forever (#2463).
MAX_WAIT_SECONDS = 3600.0


def clamp_wait_seconds(seconds: float) -> float:
    """Normalize a requested wait: NaN/<=0 -> 0, never above MAX_WAIT_SECONDS."""

    # NaN fails the comparison, so it also falls back to 0.
    return min(seconds, MAX_WAIT_SECONDS) if seconds > 0 else 0.0


def _wait_seconds(override: float | None = None) -> float:
    """Explicit ``--lock-timeout`` beats the env var; both are clamped."""

    if override is not None:
        return clamp_wait_seconds(override)
    raw = os.environ.get(WAIT_SECONDS_ENV)
    if raw is None:
        # The test-only lock-dir hook marks an isolated suite; keep its busy
        # refusals immediate instead of stalling every contended test 30s.
        return 0.0 if os.environ.get(LOCK_DIR_ENV) else DEFAULT_WAIT_SECONDS
    try:
        seconds = float(raw)
    except ValueError:
        return 0.0
    return clamp_wait_seconds(seconds)


def _lock_path(repo: Path) -> Path:
    override = os.environ.get(LOCK_DIR_ENV)
    if override:
        digest = hashlib.sha256(str(repo).encode()).hexdigest()[:16]
        return Path(override).expanduser() / f"delivery-control.{digest}.lock"
    return repo / ".cache" / "delivery-control.operation.lock"


class OperationLock:
    """Acquire one non-blocking mutation lease for a canonical repository."""

    def __init__(
        self, repo: Path, *, command: str, wait_seconds: float | None = None
    ) -> None:
        self.wait_seconds = wait_seconds
        self.repo = repo.expanduser().resolve()
        self.command = command
        self.path = _lock_path(self.repo)
        self._handle: IO[str] | None = None

    def __enter__(self) -> Self:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        held = _HELD_LOCKS.get(self.path)
        if held is not None:
            handle, depth = held
            _HELD_LOCKS[self.path] = (handle, depth + 1)
            self._handle = handle
            return self

        handle = self.path.open("a+")
        deadline = time.monotonic() + _wait_seconds(self.wait_seconds)
        try:
            while True:
                try:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as error:
                    if error.errno in {errno.EACCES, errno.EAGAIN}:
                        remaining = deadline - time.monotonic()
                        if remaining > 0:
                            time.sleep(min(_POLL_INTERVAL, remaining))
                            continue
                        raise DeliverySourceError(
                            "delivery mutation already in progress; "
                            f"command={self.command}; "
                            "retry after the active operation exits"
                        ) from error
                    raise
        except BaseException:
            # Includes KeyboardInterrupt during the wait loop: never leak the fd.
            handle.close()
            raise
        _HELD_LOCKS[self.path] = (handle, 1)
        self._handle = handle
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> bool:
        handle = self._handle
        self._handle = None
        if handle is None:
            return False

        held = _HELD_LOCKS.get(self.path)
        if held is None or held[0] is not handle:
            raise RuntimeError("operation lock ownership state is corrupted")
        _, depth = held
        if depth > 1:
            _HELD_LOCKS[self.path] = (handle, depth - 1)
        else:
            del _HELD_LOCKS[self.path]
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            handle.close()
        return False


__all__ = [
    "MAX_WAIT_SECONDS",
    "WAIT_SECONDS_ENV",
    "OperationLock",
    "clamp_wait_seconds",
]
