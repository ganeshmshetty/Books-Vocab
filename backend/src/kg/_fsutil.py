"""Low-level filesystem durability helpers shared across persistence modules.

Centralises the directory-fsync used after an ``os.replace`` so a rename
survives a crash. A bare rename only updates an in-memory directory entry;
without a directory fsync a power loss can lose the rename itself even though
the tmp payload was already durably on disk.
"""

from __future__ import annotations

import fcntl
import os
from pathlib import Path


def fsync_file(fd: int) -> None:
    """Flush ``fd`` to stable storage, bypassing the drive cache where possible.

    On macOS ``os.fsync`` only pushes data to the drive, not through its
    volatile write cache; ``F_FULLFSYNC`` does. The constant exists only on
    Darwin, so other platforms (and an ``F_FULLFSYNC`` failure, e.g. on an
    unsupported filesystem) fall back to plain ``os.fsync``.
    """
    full_fsync = getattr(fcntl, "F_FULLFSYNC", None)
    if full_fsync is not None:
        try:
            fcntl.fcntl(fd, full_fsync)
            return
        except OSError:
            pass
    os.fsync(fd)


def fsync_dir(directory: Path) -> None:
    """Best-effort fsync of a directory so a rename within it is durable.

    Some filesystems disallow directory fsync (notably Windows raises) — that
    is tolerated: the tmp-file fsync already covers data durability, this only
    hardens the rename's directory entry where the platform supports it.
    """
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        # Windows / some filesystems reject fsync on a directory fd.
        pass
    finally:
        os.close(fd)
