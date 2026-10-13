"""Fail-loud guard that the API runs as a single Uvicorn worker.

Three subsystems silently depend on a single-worker deploy because their
state is purely process-local:

  * ``quota_service._reservations`` — in-flight quota reservations. With N
    workers each holds its own copy, so the over-spend ceiling becomes N×.
  * ``translate_service._INFLIGHT`` — singleflight dedup. N workers ⇒ N×
    cache stampede on the same word.
  * ``pipeline_log`` — on startup it marks orphaned ``running`` rows
    ``interrupted``; multi-worker, workers cross-mark each other's runs.

The Dockerfile pins ``--workers 1``, but nothing *enforced* it — a change
to the worker count would silently break all three. This guard turns the
invariant fail-loud: each worker process takes an exclusive ``flock`` on a
shared lock file at startup. The first worker wins; a second worker's
non-blocking ``flock`` fails and we raise, so that worker refuses to boot.
"""

from __future__ import annotations

import fcntl
import os

# Held for the lifetime of the process. Module-level so the fd (and thus
# the flock) is never garbage-collected while the worker runs.
_lock_fd: int | None = None
_lock_pid: int | None = None


WORKER_LOCK_FILENAME = ".worker.lock"


class MultipleWorkersError(RuntimeError):
    """Raised when a second worker process tries to start."""


class WorkerLockHeldError(RuntimeError):
    """Raised when a live worker process holds the lock on a data dir."""


def hold_worker_lock(lock_path: str | os.PathLike) -> int:
    """Take the worker flock for a one-shot offline operation; return its fd.

    Unlike :func:`assert_single_worker` this does not claim the process-wide
    state: the caller owns the returned fd and must ``os.close`` it. While it is
    held, a starting API refuses to boot (its own flock fails), and a live API
    that already holds the lock makes this raise :class:`WorkerLockHeldError`.
    The flock is released by the kernel when the process exits, so a crashed
    operator never leaves a stale hold behind.
    """
    fd = os.open(os.fspath(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        raise WorkerLockHeldError(f"{lock_path} 被執行中的 API worker 持有") from e
    return fd


def assert_single_worker(lock_path: str | os.PathLike) -> None:
    """Acquire the process-exclusive worker lock, or raise.

    Idempotent within a process: once the lock is held, a repeat call is a
    no-op (it does not open a second fd). A second *process* calling this
    against the same lock file raises :class:`MultipleWorkersError`.
    """
    global _lock_fd, _lock_pid
    pid = os.getpid()
    if _lock_fd is not None:
        if _lock_pid != pid:
            raise MultipleWorkersError(
                "forked worker inherited the single-worker lock state; "
                "start a fresh process instead of reusing the parent state"
            )
        return
    path = os.fspath(lock_path)
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        raise MultipleWorkersError(
            f"另一個 worker 已持有 {path} 的鎖。KG API 假設單 worker 部署 — "
            f"quota reservation、translate singleflight、pipeline_log 皆為 "
            f"process-local 狀態，多 worker 會同時破壞三者。請確認 uvicorn "
            f"以 --workers 1 啟動。"
        ) from e
    _lock_fd = fd
    _lock_pid = pid


def release_worker_lock() -> None:
    """Release the worker lock — symmetric with :func:`assert_single_worker`.

    The lifespan shutdown calls this so a process that re-creates the app
    (the test suite does this per case) does not keep a stale lock held.
    Idempotent: a no-op when no lock is held.
    """
    global _lock_fd, _lock_pid
    if _lock_fd is not None:
        os.close(_lock_fd)
        _lock_fd = None
        _lock_pid = None
