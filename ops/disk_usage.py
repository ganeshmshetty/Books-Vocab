#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# ///
"""Bounded attribution of the KG project and every physical Git worktree.

The report deliberately separates logical bytes from allocated bytes.  Linked
worktrees share Git objects, so summing lane directories is not a filesystem
quota; the accounting section makes the shared/unassigned part explicit.
"""

from __future__ import annotations

import argparse
import calendar
import copy
import errno
import hashlib
import json
import math
import os
import plistlib
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from collections import deque
from concurrent.futures import Future, ThreadPoolExecutor
from contextlib import ExitStack
from pathlib import Path
from typing import Any

try:
    import fcntl as _fcntl
except ImportError:  # pragma: no cover - only non-POSIX runtimes
    _fcntl = None

SCHEMA = "kg.disk.lane-usage.v1"
BLOCKED_EXIT = 75
GIB = 1024**3
LIVE_REGISTRY_STATUSES = {"active", "published", "cleanup_pending"}
TERMINAL_REGISTRY_STATUSES = {"merged", "abandoned"}
KNOWN_REGISTRY_STATUSES = LIVE_REGISTRY_STATUSES | TERMINAL_REGISTRY_STATUSES
DEFAULT_TIME_BUDGET_SECONDS = 240.0
MAX_TIME_BUDGET_SECONDS = 240.0
DEFAULT_CODEX_WORKTREE_ROOT = Path.home() / ".codex" / "worktrees"
DEFAULT_XCTEST_DEVICES_ROOT = Path.home() / "Library" / "Developer" / "XCTestDevices"
DEFAULT_XCTEST_DEVICES_BUDGET_GIB = 16
DEFAULT_SIMULATOR_RUNTIME_BUDGET_GIB = 56
SIMULATOR_RUNTIME_ROOT = Path("/Library/Developer/CoreSimulator")
GIT_METADATA_DIRNAME = ".git"
# Directories any checkout can recreate from a lock file or a build, matched by
# exact basename at any depth.  They are the bulk of a lane's bytes and files
# (a backend/.venv alone is ~216 MB), have their own budgets (the guard's
# 16 GiB writer cache and 4 GiB global DerivedData caps) or none at all
# (`uv sync --locked`, `npm ci`), and walking them is what kept the attribution
# scan from finishing.  The scan lists them and, only on request, sizes them
# separately; they never count toward a lane's quota bytes.
REGENERABLE_DIRNAMES = frozenset(
    {
        ".venv",
        "node_modules",
        "DerivedData",
        "ios-build-derived-data",
        "ios-test-derived-data",
        "ios-catalyst-derived-data",
        "ios-release-derived-data",
        "ops-swift-build",
    }
)
# Top-level directories of the canonical checkout that are not lane content:
# `.cache` is governed by the guard's own cache metrics, `backups` is operator
# data.  The canonical entry is measured without them.
UNMEASURED_WORKSPACE_DIRNAMES = (".cache", "backups")
MEASUREMENT_BUDGET_ERROR = "measurement-time-budget-exceeded"
MISSING_PATH_ERROR = "path-missing"
XCTEST_DEVICES_METADATA_ERROR = "xctest-devices-metadata-unavailable"
XCTEST_DEVICES_MEASUREMENT_ERROR = "xctest-devices-measurement-incomplete"
XCTEST_DEVICES_BUDGET_ERROR = "xctest-devices-budget-exceeded"
XCTEST_DEVICES_MANUAL_REVIEW_ERROR = "xctest-devices-manual-review-required"
SIMULATOR_RUNTIME_MEASUREMENT_ERROR = "simulator-runtime-measurement-incomplete"
SIMULATOR_RUNTIME_DISCOVERY_ERROR = "simulator-runtime-discovery-unavailable"
SIMULATOR_RUNTIME_BUDGET_ERROR = "simulator-runtime-budget-exceeded"
SIMULATOR_RUNTIME_MANUAL_REVIEW_ERROR = "simulator-runtime-manual-review-required"
PHYSICAL_EXTENT_UNSUPPORTED = "physical-extents-unsupported"
PHYSICAL_EXTENT_UNMAPPED = "physical-extents-unmapped"
PHYSICAL_EXTENT_WORKERS = 8
PHYSICAL_EXTENT_PENDING = 64
F_LOG2PHYS_EXT = 65
_LOG2PHYS_EXT_FORMAT = "=Iqq"
_XCTEST_UDID_RE = re.compile(r"^[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")


class _MeasurementBudgetExceeded(RuntimeError):
    """A bounded observation reached its caller-owned deadline."""


def _path(value: str | Path) -> Path:
    return Path(value).expanduser().resolve(strict=False)


def _relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _display_relative(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def _allocated_bytes(stat_result: os.stat_result) -> int:
    blocks = getattr(stat_result, "st_blocks", 0)
    return int(blocks) * 512 if blocks else int(stat_result.st_size)


def _supports_physical_extents() -> bool:
    return sys.platform == "darwin" and _fcntl is not None


def _physical_file_extents(
    path: Path,
    stat_result: os.stat_result,
    *,
    deadline: float | None = None,
) -> tuple[list[tuple[int, int, int]], str | None]:
    """Return APFS physical ranges for one file without reading its contents."""

    if not _supports_physical_extents():
        return [], "physical-extents-platform-unavailable"
    if _deadline_expired(deadline):
        return [], MEASUREMENT_BUDGET_ERROR
    size = int(stat_result.st_size)
    if size <= 0:
        return [], None
    try:
        descriptor = os.open(path, os.O_RDONLY)
    except OSError as exc:
        return [], f"physical-open:{exc.__class__.__name__}"

    extents: list[tuple[int, int, int]] = []
    offset = 0
    try:
        while offset < size:
            if _deadline_expired(deadline):
                return extents, MEASUREMENT_BUDGET_ERROR
            request = struct.pack(
                _LOG2PHYS_EXT_FORMAT,
                0,
                size - offset,
                offset,
            )
            try:
                raw = _fcntl.fcntl(descriptor, F_LOG2PHYS_EXT, request)
            except OSError as exc:
                if exc.errno in {
                    errno.ENOTSUP,
                    getattr(errno, "EOPNOTSUPP", errno.ENOTSUP),
                    45,
                }:
                    return [], PHYSICAL_EXTENT_UNSUPPORTED
                return extents, f"physical-query:{exc.__class__.__name__}"
            _, contiguous_bytes, device_offset = struct.unpack(
                _LOG2PHYS_EXT_FORMAT, raw
            )
            if contiguous_bytes <= 0:
                return extents, PHYSICAL_EXTENT_UNMAPPED
            contiguous_bytes = min(contiguous_bytes, size - offset)
            if device_offset < 0:
                # A negative device offset denotes a sparse/unallocated hole;
                # advance through it without inventing physical bytes.
                offset += contiguous_bytes
                continue
            extents.append(
                (
                    int(stat_result.st_dev),
                    int(device_offset),
                    int(device_offset + contiguous_bytes),
                )
            )
            offset += contiguous_bytes
    finally:
        os.close(descriptor)
    return extents, None


def _union_physical_extents(
    extents: list[tuple[int, int, int]],
) -> int:
    total = 0
    current_device: int | None = None
    current_start = 0
    current_end = 0
    for device, start, end in sorted(extents):
        if end <= start:
            continue
        if device != current_device or start > current_end:
            if current_device is not None:
                total += current_end - current_start
            current_device = device
            current_start = start
            current_end = end
        elif end > current_end:
            current_end = end
    if current_device is not None:
        total += current_end - current_start
    return total


def _deadline_expired(deadline: float | None) -> bool:
    return deadline is not None and time.monotonic() >= deadline


def _remaining_timeout(deadline: float | None) -> float | None:
    if deadline is None:
        return None
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise _MeasurementBudgetExceeded
    return max(remaining, 0.001)


def _is_budget_error(error: str | None) -> bool:
    return bool(
        error == MEASUREMENT_BUDGET_ERROR
        or error
        and error.endswith(f":{MEASUREMENT_BUDGET_ERROR}")
    )


def _mark_uninspected(records: list[dict[str, Any]], start: int, *, error: str) -> None:
    for record in records[start:]:
        record.update(
            {
                "inspection_complete": False,
                "inspection_error": error,
                "worktree_state": "unknown",
            }
        )


def _xctest_devices_root(value: str | Path | None) -> Path:
    if value is not None:
        return _path(value)
    configured = os.environ.get("KG_XCTEST_DEVICES_ROOT")
    return _path(configured) if configured else _path(DEFAULT_XCTEST_DEVICES_ROOT)


def _configured_xctest_devices_budget_gib() -> int:
    raw = os.environ.get("KG_XCTEST_DEVICES_BUDGET_GIB")
    try:
        return (
            max(0, int(raw)) if raw is not None else DEFAULT_XCTEST_DEVICES_BUDGET_GIB
        )
    except (TypeError, ValueError):
        return DEFAULT_XCTEST_DEVICES_BUDGET_GIB


def _configured_simulator_runtime_budget_gib() -> int:
    raw = os.environ.get("KG_SIMULATOR_RUNTIME_BUDGET_GIB")
    try:
        return (
            max(0, int(raw))
            if raw is not None
            else DEFAULT_SIMULATOR_RUNTIME_BUDGET_GIB
        )
    except (TypeError, ValueError):
        return DEFAULT_SIMULATOR_RUNTIME_BUDGET_GIB


def _parse_hdiutil_simulator_runtimes(
    output: str,
) -> tuple[list[dict[str, Any]], list[str]]:
    """Extract only mounted CoreSimulator runtime images from ``hdiutil``."""

    records: list[dict[str, str]] = []
    current: dict[str, str] = {}

    def flush() -> None:
        nonlocal current
        if current:
            records.append(current)
            current = {}

    for line in output.splitlines():
        if line.startswith("===="):
            flush()
            continue
        match = re.match(r"^([a-z][a-z0-9-]*)\s*:\s*(.*)$", line)
        if match:
            current[match.group(1)] = match.group(2).strip()
            continue
        mount_match = re.search(r"(/Library/Developer/CoreSimulator/[^\s]+)", line)
        if mount_match:
            current["mount-path"] = mount_match.group(1).rstrip("/")
    flush()

    runtimes: list[dict[str, Any]] = []
    errors: list[str] = []
    seen: set[tuple[str, str]] = set()
    for record in records:
        mount_path = record.get("mount-path")
        if not mount_path:
            continue
        image_path = record.get("image-path", "")
        key = (mount_path, image_path)
        if key in seen:
            continue
        seen.add(key)
        try:
            blockcount = int(record.get("blockcount", ""))
            blocksize = int(record.get("blocksize", ""))
        except (TypeError, ValueError):
            errors.append(f"{mount_path}:missing-image-size")
            continue
        if blockcount < 0 or blocksize <= 0:
            errors.append(f"{mount_path}:invalid-image-size")
            continue
        runtimes.append(
            {
                "mount_path": mount_path,
                "image_path": image_path or None,
                "image_bytes": blockcount * blocksize,
            }
        )
    return sorted(
        runtimes,
        key=lambda item: (
            str(item["mount_path"]),
            str(item.get("image_path") or ""),
        ),
    ), sorted(set(errors))


def _discover_simulator_runtimes(
    *, deadline: float | None = None
) -> tuple[list[dict[str, Any]], list[str]]:
    """Discover mounted Apple Simulator runtime images without mutating state."""

    if sys.platform != "darwin":
        return [], ["platform-unsupported"]
    command = shutil.which("hdiutil")
    if command is None:
        stable_command = Path("/usr/bin/hdiutil")
        if stable_command.is_file() and os.access(stable_command, os.X_OK):
            command = str(stable_command)
    if command is None:
        return [], ["hdiutil-command-unavailable"]
    try:
        timeout = _remaining_timeout(deadline)
        if timeout is None:
            timeout = 5.0
        else:
            timeout = min(timeout, 5.0)
        completed = subprocess.run(
            [command, "info"],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except _MeasurementBudgetExceeded:
        return [], [MEASUREMENT_BUDGET_ERROR]
    except subprocess.TimeoutExpired:
        return [], ["hdiutil-timeout"]
    except OSError as exc:
        return [], [f"hdiutil:{exc.__class__.__name__}"]
    if completed.returncode != 0:
        return [], [f"hdiutil-exit:{completed.returncode}"]
    return _parse_hdiutil_simulator_runtimes(completed.stdout)


def inspect_simulator_runtimes(
    *,
    budget_bytes: int = DEFAULT_SIMULATOR_RUNTIME_BUDGET_GIB * GIB,
    deadline: float | None = None,
    discovered: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Account for mounted Simulator runtimes as shared host platform storage.

    Runtime images are read-only platform assets, not product lanes.  They are
    observed and budgeted, but this guard never unmounts or deletes them.
    """

    budget = max(0, int(budget_bytes))
    base: dict[str, Any] = {
        "root": str(SIMULATOR_RUNTIME_ROOT),
        "exists": False,
        "status": "absent",
        "attribution": "shared-host-platform",
        "logical_bytes": 0,
        "allocated_bytes": 0,
        "runtime_count": 0,
        "measurement_complete": True,
        "measurement_errors": [],
        "allocation_method": "hdiutil-blockcount",
        "budget_bytes": budget,
        "budget_allocated_bytes": 0,
        "budget_exceeded": False,
        "budget_overflow_bytes": 0,
        "runtimes": [],
        "reclaim": {
            "requested": False,
            "status": "not-supported",
            "reason": "shared-runtime-images-never-auto-reclaimed",
            "attempted": 0,
            "succeeded": 0,
            "results": [],
        },
    }
    discovery_errors: list[str] = []
    if discovered is None:
        discovered, discovery_errors = _discover_simulator_runtimes(deadline=deadline)
    if discovery_errors == ["platform-unsupported"] and not discovered:
        base["status"] = "unsupported"
        return base
    if not discovered and discovery_errors:
        base.update(
            {
                "status": "measurement-incomplete",
                "measurement_complete": False,
                "measurement_errors": sorted(set(discovery_errors))[:20],
                "budget_allocated_bytes": None,
                "budget_exceeded": None,
                "budget_overflow_bytes": None,
            }
        )
        return base
    if not discovered:
        return base

    base["exists"] = True
    base["runtime_count"] = len(discovered)
    errors = list(discovery_errors)
    runtimes: list[dict[str, Any]] = []
    logical_bytes = 0
    unique_allocated_bytes = 0
    allocation_keys: set[str] = set()
    measurement_complete = not discovery_errors
    for item in sorted(
        discovered,
        key=lambda value: (
            str(value.get("mount_path", "")),
            str(value.get("image_path") or ""),
        ),
    ):
        mount_path = str(item.get("mount_path", ""))
        image_path = item.get("image_path")
        image_bytes = item.get("image_bytes")
        runtime: dict[str, Any] = {
            "mount_path": mount_path,
            "image_path": image_path,
            "logical_bytes": 0,
            "allocated_bytes": 0,
            "total_bytes": None,
            "used_bytes": None,
            "free_bytes": None,
            "measurement_complete": False,
        }
        try:
            image_size = int(image_bytes)
            if not mount_path or image_size <= 0:
                raise ValueError
        except (TypeError, ValueError):
            error = f"{mount_path or '<missing-mount>'}:invalid-image-size"
            errors.append(error)
            measurement_complete = False
            runtime["measurement_error"] = error.rsplit(":", 1)[-1]
            runtimes.append(runtime)
            continue
        if _deadline_expired(deadline):
            error = f"{mount_path}:{MEASUREMENT_BUDGET_ERROR}"
            errors.append(error)
            measurement_complete = False
            runtime["measurement_error"] = MEASUREMENT_BUDGET_ERROR
            runtimes.append(runtime)
            continue
        try:
            filesystem = shutil.disk_usage(mount_path)
            total_bytes = int(filesystem[0])
            used_bytes = int(filesystem[1])
            free_bytes = int(filesystem[2])
        except (OSError, TypeError, ValueError, IndexError) as exc:
            error = f"{mount_path}:filesystem-usage:{exc.__class__.__name__}"
            errors.append(error)
            measurement_complete = False
            runtime["measurement_error"] = "filesystem-usage"
            runtimes.append(runtime)
            continue
        allocated_bytes = max(image_size, used_bytes)
        allocation_key = str(image_path or mount_path)
        if allocation_key not in allocation_keys:
            allocation_keys.add(allocation_key)
            unique_allocated_bytes += allocated_bytes
        logical_bytes += image_size
        runtime.update(
            {
                "logical_bytes": image_size,
                "allocated_bytes": allocated_bytes,
                "total_bytes": total_bytes,
                "used_bytes": used_bytes,
                "free_bytes": free_bytes,
                "measurement_complete": True,
                "allocation_key": allocation_key,
            }
        )
        runtimes.append(runtime)

    base["logical_bytes"] = logical_bytes
    base["allocated_bytes"] = unique_allocated_bytes
    base["runtimes"] = runtimes
    base["measurement_errors"] = sorted(set(errors))[:20]
    base["measurement_complete"] = measurement_complete
    if not measurement_complete:
        base.update(
            {
                "status": "measurement-incomplete",
                "budget_allocated_bytes": None,
                "budget_exceeded": None,
                "budget_overflow_bytes": None,
            }
        )
        return base
    base["budget_allocated_bytes"] = unique_allocated_bytes
    base["budget_exceeded"] = unique_allocated_bytes > budget
    base["budget_overflow_bytes"] = max(0, unique_allocated_bytes - budget)
    if base["budget_exceeded"]:
        base["status"] = "budget-exceeded"
        base["reclaim"]["status"] = "manual-review"
        base["reclaim"]["reason"] = (
            "shared-runtime-images-require-platform-level-manual-review"
        )
    else:
        base["status"] = "measured"
    return base


def _xctest_state(value: object) -> tuple[bool, bool]:
    """Return (known, active) without treating an unknown state as safe."""

    if isinstance(value, bool):
        return False, False
    if isinstance(value, int):
        # CoreSimulator's plist uses 1 for Shutdown and 2 for Booted.
        return value in {1, 2}, value == 2
    if isinstance(value, str):
        normalized = " ".join(value.casefold().replace("_", " ").split())
        if normalized in {"shutdown", "shut down", "stopped", "deleted"}:
            return True, False
        if normalized in {
            "booted",
            "running",
            "active",
            "launching",
            "creating",
            "shutting down",
        }:
            return True, True
    return False, False


def _read_xctest_device_plist(
    path: Path, udid: str
) -> tuple[dict[str, Any], str | None]:
    try:
        with path.open("rb") as handle:
            payload = plistlib.load(handle)
    except FileNotFoundError:
        return {}, "plist-missing"
    except (OSError, plistlib.InvalidFileException, ValueError, TypeError):
        return {}, "plist-malformed"
    if not isinstance(payload, dict):
        return {}, "plist-malformed"
    required = ("UDID", "isEphemeral", "isDeleted", "state")
    if any(key not in payload for key in required):
        return {}, "plist-missing-required-field"
    if payload.get("UDID") != udid or not isinstance(payload.get("UDID"), str):
        return {}, "plist-identity-mismatch"
    if not isinstance(payload.get("isEphemeral"), bool) or not isinstance(
        payload.get("isDeleted"), bool
    ):
        return {}, "plist-flag-invalid"
    state_known, active = _xctest_state(payload.get("state"))
    if not state_known:
        return {}, "plist-state-unknown"
    return {
        "udid": udid,
        "is_ephemeral": payload["isEphemeral"],
        "is_deleted": payload["isDeleted"],
        "state": payload["state"],
        "state_known": state_known,
        "active": active,
    }, None


def _simctl_has_device(command: str, udid: str) -> bool:
    try:
        completed = subprocess.run(
            [command, "simctl", "list", "devices", "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if completed.returncode != 0:
            return False
        payload = json.loads(completed.stdout)
    except (OSError, subprocess.SubprocessError, TypeError, ValueError):
        return False
    serialized = json.dumps(payload, ensure_ascii=False)
    return udid in serialized


def _reclaim_xctest_device(candidate: dict[str, Any]) -> dict[str, Any]:
    """Use only Apple's supported simctl delete after exact identity proof.

    XCTestDevices normally are not in simctl's inventory.  In that case this
    deliberately returns a manual-review result and never touches the path.
    """

    udid = str(candidate.get("udid", ""))
    if not _XCTEST_UDID_RE.fullmatch(udid):
        return {"status": "manual-review", "reason": "invalid-udid"}
    command = shutil.which("xcrun")
    if not command:
        return {
            "status": "manual-review",
            "reason": "supported-command-unavailable",
        }
    if not _simctl_has_device(command, udid):
        return {
            "status": "manual-review",
            "reason": "device-not-listed-by-simctl",
        }
    try:
        completed = subprocess.run(
            [command, "simctl", "delete", udid],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {
            "status": "manual-review",
            "reason": f"supported-command-failed:{exc.__class__.__name__}",
        }
    if completed.returncode != 0:
        return {"status": "manual-review", "reason": "supported-command-failed"}
    return {"status": "reclaimed", "command": "xcrun simctl delete"}


def _removed_during_scan(entry_path: Path) -> bool:
    # A vanished device no longer occupies storage; any other OSError fails closed.
    try:
        os.stat(entry_path, follow_symlinks=False)
    except OSError as exc:
        return isinstance(exc, (FileNotFoundError, NotADirectoryError))
    return False


def inspect_xctest_devices(
    root: str | Path | None = None,
    *,
    budget_bytes: int = DEFAULT_XCTEST_DEVICES_BUDGET_GIB * GIB,
    deadline: float | None = None,
    auto_reclaim: bool = False,
) -> dict[str, Any]:
    """Bounded accounting for the shared, non-lane XCTestDevices store."""

    normalized_root = _xctest_devices_root(root)
    base: dict[str, Any] = {
        "root": str(normalized_root),
        "exists": False,
        "status": "absent",
        "attribution": "shared-host-platform",
        "logical_bytes": 0,
        "allocated_bytes": 0,
        "files": 0,
        "device_count": 0,
        "measurement_complete": True,
        "metadata_complete": True,
        "measurement_errors": [],
        "physical_measurement_complete": True,
        "physical_measurement_errors": [],
        "physical_measurement_warnings": [],
        "physical_allocated_bytes": 0,
        "physical_fallback_files": 0,
        "physical_fallback_allocated_bytes": 0,
        "allocation_method": (
            "apfs-physical-extents" if _supports_physical_extents() else "st_blocks"
        ),
        "budget_bytes": max(0, int(budget_bytes)),
        "budget_allocated_bytes": 0,
        "budget_exceeded": False,
        "budget_overflow_bytes": 0,
        "devices": [],
        "reclaim": {
            "requested": bool(auto_reclaim),
            "status": "not-requested",
            "candidates": [],
            "attempted": 0,
            "succeeded": 0,
            "results": [],
        },
    }
    if not normalized_root.is_dir():
        return base

    base["exists"] = True
    base["status"] = "measured"
    entries: list[os.DirEntry[str]] = []
    try:
        with os.scandir(normalized_root) as scanner:
            entries = sorted(scanner, key=lambda item: item.name)
    except OSError as exc:
        base.update(
            {
                "status": "measurement-incomplete",
                "measurement_complete": False,
                "measurement_errors": [f"root-scan:{exc.__class__.__name__}"],
            }
        )
        return base

    errors: list[str] = []
    devices: list[dict[str, Any]] = []
    physical_observation: dict[str, Any] = {
        "extents": [],
        "errors": [],
        "warnings": [],
        "fallback_files": 0,
        "fallback_allocated_bytes": 0,
    }
    measurement_complete = True
    processed_entries = 0
    for entry in entries:
        if _deadline_expired(deadline):
            errors.append(MEASUREMENT_BUDGET_ERROR)
            measurement_complete = False
            break
        processed_entries += 1
        entry_path = Path(entry.path)
        try:
            stat_result = entry.stat(follow_symlinks=False)
        except OSError as exc:
            errors.append(f"{entry.name}:stat:{exc.__class__.__name__}")
            measurement_complete = False
            continue
        if not entry.is_dir(follow_symlinks=False):
            base["logical_bytes"] += int(stat_result.st_size)
            base["allocated_bytes"] += _allocated_bytes(stat_result)
            base["files"] += 1
            errors.append(f"unexpected-root-entry:{entry.name}")
            measurement_complete = False
            continue
        observation_before = copy.deepcopy(physical_observation)
        measured = measure_tree(
            entry_path,
            deadline=deadline,
            physical_observation=(
                physical_observation if _supports_physical_extents() else None
            ),
        )
        metadata, metadata_error = _read_xctest_device_plist(
            entry_path / "device.plist", entry.name
        )
        if _removed_during_scan(entry_path):
            physical_observation.update(observation_before)
            continue
        base["device_count"] += 1
        base["logical_bytes"] += int(measured["logical_bytes"])
        base["allocated_bytes"] += int(measured["allocated_bytes"])
        base["files"] += int(measured["files"])
        if not measured["complete"]:
            measurement_complete = False
            errors.extend(
                f"{entry.name}:{error}"
                for error in measured.get("errors", ["measurement-incomplete"])
            )
        if metadata_error:
            errors.append(f"{entry.name}:{metadata_error}")
            base["metadata_complete"] = False
        candidate = bool(
            not metadata_error
            and _XCTEST_UDID_RE.fullmatch(entry.name)
            and metadata["is_ephemeral"]
            and metadata["is_deleted"]
            and metadata["state_known"]
            and not metadata["active"]
        )
        device = {
            "udid": entry.name,
            "path": str(entry_path),
            "logical_bytes": int(measured["logical_bytes"]),
            "allocated_bytes": int(measured["allocated_bytes"]),
            "measurement_complete": bool(measured["complete"]),
            "metadata_complete": metadata_error is None,
            "reclaimable": candidate,
            "active": metadata.get("active") if metadata else None,
            "is_ephemeral": metadata.get("is_ephemeral") if metadata else None,
            "is_deleted": metadata.get("is_deleted") if metadata else None,
            "state": metadata.get("state") if metadata else None,
        }
        if metadata_error:
            device["metadata_error"] = metadata_error
        devices.append(device)
    if processed_entries < len(entries) and MEASUREMENT_BUDGET_ERROR not in errors:
        errors.append(MEASUREMENT_BUDGET_ERROR)
        measurement_complete = False

    base["devices"] = devices
    base["measurement_errors"] = sorted(set(errors))[:20]
    base["measurement_complete"] = measurement_complete
    if not base["measurement_complete"]:
        base["status"] = "measurement-incomplete"
    elif not base["metadata_complete"]:
        base["status"] = "metadata-unavailable"

    if _supports_physical_extents():
        physical_errors = sorted(set(physical_observation["errors"]))
        physical_warnings = sorted(set(physical_observation["warnings"]))
        physical_allocated = _union_physical_extents(physical_observation["extents"])
        fallback_files = int(physical_observation["fallback_files"])
        fallback_allocated = int(physical_observation["fallback_allocated_bytes"])
        base.update(
            {
                "physical_measurement_complete": not physical_errors,
                "physical_measurement_errors": physical_errors[:20],
                "physical_measurement_warnings": physical_warnings[:20],
                "physical_allocated_bytes": physical_allocated,
                "physical_fallback_files": fallback_files,
                "physical_fallback_allocated_bytes": fallback_allocated,
            }
        )
        if physical_errors:
            base["measurement_complete"] = False
            base["status"] = "measurement-incomplete"
            base["measurement_errors"] = sorted(
                set(base["measurement_errors"])
                | {f"physical:{error}" for error in physical_errors}
            )[:20]
            base["allocation_method"] = "apfs-physical-extents-incomplete"
            base["budget_allocated_bytes"] = None
            base["budget_exceeded"] = None
            base["budget_overflow_bytes"] = None
        else:
            base["budget_allocated_bytes"] = physical_allocated + fallback_allocated
            base["allocation_method"] = (
                "apfs-physical-extents+st_blocks-fallback"
                if fallback_files
                else "apfs-physical-extents"
            )
    else:
        base["budget_allocated_bytes"] = base["allocated_bytes"]

    candidates = [device for device in devices if device["reclaimable"]]
    base["reclaim"]["candidates"] = [device["udid"] for device in candidates]
    budget_allocated = base["budget_allocated_bytes"]
    if budget_allocated is not None:
        base["budget_exceeded"] = budget_allocated > base["budget_bytes"]
        base["budget_overflow_bytes"] = max(0, budget_allocated - base["budget_bytes"])
    if base["budget_exceeded"]:
        base["reclaim"]["status"] = "manual-review"
        if (
            auto_reclaim
            and candidates
            and base["measurement_complete"]
            and base["metadata_complete"]
        ):
            results = []
            for candidate in candidates:
                result = _reclaim_xctest_device(candidate)
                results.append({"udid": candidate["udid"], **result})
                base["reclaim"]["attempted"] += 1
                if result.get("status") == "reclaimed":
                    base["reclaim"]["succeeded"] += 1
            base["reclaim"]["results"] = results
            if base["reclaim"]["succeeded"]:
                refreshed = inspect_xctest_devices(
                    normalized_root,
                    budget_bytes=base["budget_bytes"],
                    deadline=deadline,
                    auto_reclaim=False,
                )
                refreshed["reclaim"] = base["reclaim"]
                refreshed["reclaim"]["status"] = "reclaimed"
                return refreshed
    return base


def measure_tree(
    root: Path,
    *,
    excluded: set[Path] | None = None,
    deadline: float | None = None,
    physical_observation: dict[str, Any] | None = None,
    regenerable_names: frozenset[str] = frozenset(),
) -> dict[str, Any]:
    """Measure one bounded tree without following symlinked directories.

    Directories whose basename is in ``regenerable_names`` are not descended
    into: they are returned under ``regenerable_roots`` for the caller to size
    separately, and contribute nothing to the byte totals.
    """

    root = _path(root)
    excluded = {_path(item) for item in (excluded or set())}
    if not root.exists() or not root.is_dir():
        return {
            "logical_bytes": 0,
            "allocated_bytes": 0,
            "files": 0,
            "complete": False,
            "error": MISSING_PATH_ERROR,
        }

    logical = 0
    allocated = 0
    files = 0
    seen_files: set[tuple[int, int]] = set()
    pending = [root]
    complete = True
    errors: list[str] = []
    regenerable_roots: list[Path] = []

    def budget_expired() -> bool:
        return _deadline_expired(deadline)

    def record_budget_expiry() -> None:
        nonlocal complete
        complete = False
        if MEASUREMENT_BUDGET_ERROR not in errors:
            errors.append(MEASUREMENT_BUDGET_ERROR)

    # Keep traversal and evidence on the caller thread. Only the blocking
    # per-file queries run in parallel; a bounded FIFO also caps retained
    # paths, stats and completed-but-uncollected extent lists.
    queries: deque[
        tuple[
            Path, os.stat_result, Future[tuple[list[tuple[int, int, int]], str | None]]
        ]
    ] = deque()

    def collect_query() -> None:
        nonlocal complete
        entry_path, stat_result, future = queries.popleft()
        try:
            extents, physical_error = future.result(
                timeout=_remaining_timeout(deadline)
            )
        except (TimeoutError, _MeasurementBudgetExceeded):
            future.cancel()
            extents, physical_error = [], MEASUREMENT_BUDGET_ERROR
        except Exception as exc:  # noqa: BLE001 - unexpected worker errors fail closed
            extents, physical_error = [], f"physical-worker:{exc.__class__.__name__}"
        # A syscall may return its final extent after the deadline. Even a
        # successful or fallback result then remains an incomplete observation.
        if budget_expired():
            physical_error = MEASUREMENT_BUDGET_ERROR
        physical_observation["extents"].extend(extents)
        if physical_error in {
            PHYSICAL_EXTENT_UNSUPPORTED,
            "physical-open:PermissionError",
        }:
            physical_observation["fallback_files"] += 1
            physical_observation["fallback_allocated_bytes"] += _allocated_bytes(
                stat_result
            )
            physical_observation["warnings"].append(f"{entry_path}: {physical_error}")
        elif physical_error:
            complete = False
            error = f"{entry_path}: {physical_error}"
            errors.append(error)
            physical_observation["errors"].append(error)

    with ExitStack() as stack:
        executor = None
        if physical_observation is not None:
            executor = ThreadPoolExecutor(max_workers=PHYSICAL_EXTENT_WORKERS)
            # Python cannot interrupt an in-flight filesystem syscall. Do not
            # delay partial evidence; the guard's process deadline is the outer
            # backstop. Workers never mutate this report after it is returned.
            stack.callback(executor.shutdown, wait=False, cancel_futures=True)
        while pending:
            if budget_expired():
                record_budget_expiry()
                break
            directory = pending.pop()
            try:
                entries = os.scandir(directory)
            except OSError as exc:
                complete = False
                errors.append(f"{directory}: {exc.__class__.__name__}")
                continue
            try:
                with entries:
                    for entry in entries:
                        if budget_expired():
                            record_budget_expiry()
                            break
                        if entry.name == GIT_METADATA_DIRNAME:
                            continue
                        # scandir already yields absolute paths. Resolving
                        # every entry can consume the entire measurement budget.
                        entry_path = Path(entry.path)
                        if entry_path in excluded:
                            continue
                        try:
                            stat_result = entry.stat(follow_symlinks=False)
                        except OSError as exc:
                            complete = False
                            errors.append(f"{entry_path}: {exc.__class__.__name__}")
                            continue
                        allocated += _allocated_bytes(stat_result)
                        if entry.is_symlink():
                            logical += int(stat_result.st_size)
                            files += 1
                        elif entry.is_dir(follow_symlinks=False):
                            if entry.name in regenerable_names:
                                regenerable_roots.append(entry_path)
                            else:
                                pending.append(entry_path)
                        elif entry.is_file(follow_symlinks=False):
                            identity = (
                                int(stat_result.st_dev),
                                int(stat_result.st_ino),
                            )
                            if identity not in seen_files:
                                seen_files.add(identity)
                                logical += int(stat_result.st_size)
                                files += 1
                            if executor is not None:
                                queries.append(
                                    (
                                        entry_path,
                                        stat_result,
                                        executor.submit(
                                            _physical_file_extents,
                                            entry_path,
                                            stat_result,
                                            deadline=deadline,
                                        ),
                                    )
                                )
                                if len(queries) >= PHYSICAL_EXTENT_PENDING:
                                    collect_query()
            except OSError as exc:
                complete = False
                errors.append(f"{directory}: {exc.__class__.__name__}")
        while queries:
            collect_query()
    result: dict[str, Any] = {
        "logical_bytes": logical,
        "allocated_bytes": allocated,
        "files": files,
        "complete": complete,
    }
    if errors:
        result["errors"] = sorted(errors)[:20]
    if regenerable_roots:
        result["regenerable_roots"] = sorted(regenerable_roots)
    return result


def _measure_regenerable(
    roots: list[Path], *, deadline: float | None = None
) -> dict[str, Any]:
    """Size already-listed regenerable roots; independent of the quota bytes."""

    total = {"logical_bytes": 0, "allocated_bytes": 0, "files": 0, "complete": True}
    for root in roots:
        measured = measure_tree(root, deadline=deadline)
        total["logical_bytes"] += measured["logical_bytes"]
        total["allocated_bytes"] += measured["allocated_bytes"]
        total["files"] += measured["files"]
        total["complete"] = bool(total["complete"] and measured["complete"])
    return total


def _parse_worktrees(
    workspace: Path, *, deadline: float | None = None
) -> tuple[list[dict[str, Any]], str | None]:
    if _deadline_expired(deadline):
        return [], MEASUREMENT_BUDGET_ERROR
    try:
        completed = subprocess.run(
            ["git", "-C", str(workspace), "worktree", "list", "--porcelain"],
            check=False,
            capture_output=True,
            text=True,
            timeout=_remaining_timeout(deadline),
        )
    except (_MeasurementBudgetExceeded, subprocess.TimeoutExpired):
        return [], MEASUREMENT_BUDGET_ERROR
    except OSError as exc:
        return [], f"git-worktree-list:{exc.__class__.__name__}"
    if _deadline_expired(deadline):
        return [], MEASUREMENT_BUDGET_ERROR
    if completed.returncode != 0:
        return [], f"git-worktree-list:exit-{completed.returncode}"

    records: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for line in completed.stdout.splitlines():
        if line.startswith("worktree "):
            if current is not None:
                records.append(current)
            # Lock state is observed only through this listing; records found
            # by the topology scan never carry the key (unknown, not unlocked).
            current = {
                "path": _path(line.removeprefix("worktree ").strip()),
                "locked": False,
            }
        elif current is None:
            continue
        elif line == "locked" or line.startswith("locked "):
            current["locked"] = True
            current["lock_reason"] = line.removeprefix("locked").strip()
        elif line.startswith("HEAD "):
            current["head"] = line.removeprefix("HEAD ").strip()
        elif line.startswith("branch "):
            ref = line.removeprefix("branch ").strip()
            current["branch"] = ref.removeprefix("refs/heads/")
        elif line == "detached":
            current["detached"] = True
    if current is not None:
        records.append(current)

    for index, record in enumerate(records):
        path = record["path"]
        if _deadline_expired(deadline):
            _mark_uninspected(records, index, error=MEASUREMENT_BUDGET_ERROR)
            return records, MEASUREMENT_BUDGET_ERROR
        if not path.is_dir():
            record.update(
                {
                    "inspection_complete": False,
                    "inspection_error": MISSING_PATH_ERROR,
                    "worktree_state": "missing",
                }
            )
            continue
        try:
            status = subprocess.run(
                [
                    "git",
                    "-C",
                    str(path),
                    "status",
                    "--porcelain=v1",
                    "--untracked-files=all",
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=_remaining_timeout(deadline),
            )
        except (_MeasurementBudgetExceeded, subprocess.TimeoutExpired):
            _mark_uninspected(records, index, error=MEASUREMENT_BUDGET_ERROR)
            return records, MEASUREMENT_BUDGET_ERROR
        except OSError as exc:
            record.update(
                {
                    "inspection_complete": False,
                    "inspection_error": f"git-status:{exc.__class__.__name__}",
                    "worktree_state": "unknown",
                }
            )
            continue
        if _deadline_expired(deadline):
            _mark_uninspected(records, index, error=MEASUREMENT_BUDGET_ERROR)
            return records, MEASUREMENT_BUDGET_ERROR
        if status.returncode != 0:
            record.update(
                {
                    "inspection_complete": False,
                    "inspection_error": f"git-status:exit-{status.returncode}",
                    "worktree_state": "unknown",
                }
            )
            continue
        dirty = bool(status.stdout.strip())
        record.update(
            {
                "inspection_complete": True,
                "dirty": dirty,
                "worktree_state": "dirty" if dirty else "clean",
            }
        )
    return records, None


def _topology_roots(workspace: Path) -> list[Path]:
    """Return the bounded worktree roots that this report observes."""

    configured_codex_root = os.environ.get("KG_DISK_USAGE_CODEX_WORKTREE_ROOT")
    roots = [
        workspace / ".claude" / "worktrees",
        _path(configured_codex_root)
        if configured_codex_root
        else _path(DEFAULT_CODEX_WORKTREE_ROOT),
    ]
    unique: list[Path] = []
    for root in roots:
        normalized = _path(root)
        if normalized not in unique:
            unique.append(normalized)
    return unique


def _topology_candidates(
    root: Path, *, deadline: float | None = None, max_depth: int = 2
) -> tuple[list[Path], str | None]:
    """Enumerate only shallow checkout roots; never walk their project files."""

    root = _path(root)
    if not root.is_dir():
        return [], None
    candidates: list[Path] = []
    pending: list[tuple[Path, int]] = [(root, 0)]
    try:
        while pending:
            if _deadline_expired(deadline):
                return candidates, MEASUREMENT_BUDGET_ERROR
            directory, depth = pending.pop()
            entries = []
            with os.scandir(directory) as scanner:
                for entry in scanner:
                    if _deadline_expired(deadline):
                        return candidates, MEASUREMENT_BUDGET_ERROR
                    entries.append(entry)
            entries.sort(key=lambda item: item.name)
            for entry in entries:
                if _deadline_expired(deadline):
                    return candidates, MEASUREMENT_BUDGET_ERROR
                if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                    continue
                entry_path = Path(entry.path)
                if (entry_path / ".git").exists():
                    candidates.append(entry_path)
                elif depth < max_depth:
                    pending.append((entry_path, depth + 1))
    except OSError as exc:
        return candidates, f"topology-scan:{exc.__class__.__name__}"
    return candidates, None


def _git_output(path: Path, *args: str, deadline: float | None = None) -> str | None:
    if _deadline_expired(deadline):
        raise _MeasurementBudgetExceeded
    try:
        completed = subprocess.run(
            ["git", "-C", str(path), *args],
            check=False,
            capture_output=True,
            text=True,
            timeout=_remaining_timeout(deadline),
        )
    except (_MeasurementBudgetExceeded, subprocess.TimeoutExpired) as exc:
        raise _MeasurementBudgetExceeded from exc
    except OSError:
        return None
    if _deadline_expired(deadline):
        raise _MeasurementBudgetExceeded
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    return value or None


def _inspect_topology_worktree(
    path: Path, *, deadline: float | None = None
) -> dict[str, Any] | None:
    """Read identity/status for a topology checkout not returned by git list."""

    head = _git_output(path, "rev-parse", "HEAD", deadline=deadline)
    common_dir = _git_output(path, "rev-parse", "--git-common-dir", deadline=deadline)
    if head is None or common_dir is None:
        return None
    branch = _git_output(
        path, "symbolic-ref", "--quiet", "--short", "HEAD", deadline=deadline
    )
    try:
        status = subprocess.run(
            [
                "git",
                "-C",
                str(path),
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=_remaining_timeout(deadline),
        )
    except (_MeasurementBudgetExceeded, subprocess.TimeoutExpired):
        return {
            "path": path,
            "head": head,
            "branch": branch or "(detached)",
            "inspection_complete": False,
            "inspection_error": MEASUREMENT_BUDGET_ERROR,
            "worktree_state": "unknown",
        }
    except OSError:
        return {
            "path": path,
            "head": head,
            "branch": branch or "(detached)",
            "inspection_complete": False,
            "inspection_error": "git-status:OSError",
            "worktree_state": "unknown",
        }
    if _deadline_expired(deadline):
        return {
            "path": path,
            "head": head,
            "branch": branch or "(detached)",
            "inspection_complete": False,
            "inspection_error": MEASUREMENT_BUDGET_ERROR,
            "worktree_state": "unknown",
        }
    if status.returncode != 0:
        return {
            "path": path,
            "head": head,
            "branch": branch or "(detached)",
            "inspection_complete": False,
            "inspection_error": f"git-status:exit-{status.returncode}",
            "worktree_state": "unknown",
        }
    return {
        "path": path,
        "head": head,
        "branch": branch or "(detached)",
        "inspection_complete": True,
        "dirty": bool(status.stdout.strip()),
        "worktree_state": "dirty" if status.stdout.strip() else "clean",
    }


def _topology_name(path: Path, roots: list[Path]) -> str | None:
    for root in roots:
        if _relative_to(path, root):
            return (
                "codex"
                if root.name == "worktrees" and ".codex" in root.parts
                else "claude"
            )
    return None


def _is_codex_supervision_checkout(path: Path, roots: list[Path]) -> bool:
    """Recognise Codex's fixed ``<session>/kg`` supervision checkout shape.

    These checkouts are orchestration containers, not product delivery lanes.
    They remain fully measured and visible, but their absence from the product
    registry must not be reported as an unregistered product worktree.  The
    shape is deliberately exact so an arbitrary checkout below the Codex root
    still fails closed.
    """

    for root in roots:
        if root.name != "worktrees" or ".codex" not in root.parts:
            continue
        try:
            relative = path.relative_to(root)
        except ValueError:
            continue
        return len(relative.parts) == 2 and relative.parts[1] == "kg"
    return False


AGENT_LOCK_REASON_RE = re.compile(
    r"^claude agent (?P<name>\S+) \(pid (?P<pid>[1-9][0-9]{0,9})"
    r"(?: start (?P<start>[^)]+)| [^)]*)?\)$"
)
# ``ps -o lstart=`` prints ctime layout under LC_ALL=C on macOS and procps alike.
LSTART_FORMAT = "%a %b %d %H:%M:%S %Y"
# lstart has 1 s resolution; the harness and ps may round across a boundary.
PID_START_TOLERANCE_SECONDS = 2
# One ``ps`` probe is capped by this and by the time the report has left.
PS_PROBE_TIMEOUT_SECONDS = 5.0
# Dirnames the harness generates (subagent, Workflow): provenance once unlocked.
AGENT_DIRNAME_RE = re.compile(r"agent-[0-9a-f]{17}|wf_[0-9a-f]{8}-[0-9a-f]{3}-[0-9]+")


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by another user
    except (OSError, OverflowError):
        return False
    return True


def _parse_lstart(text: str) -> float | None:
    """Epoch seconds of an lstart string read as UTC (the harness records its
    lock start in UTC; ``_ps_lstart`` asks ``ps`` for UTC to match)."""

    try:
        return float(
            calendar.timegm(time.strptime(" ".join(text.split()), LSTART_FORMAT))
        )
    except (ValueError, OverflowError):
        return None


def _ps_lstart(pid: int, timeout: float = PS_PROBE_TIMEOUT_SECONDS) -> str | None:
    try:
        completed = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            capture_output=True,
            text=True,
            env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return completed.stdout if completed.returncode == 0 else None


def _harness_pid_state(
    pid: int,
    recorded_start: str | None,
    start_cache: dict[int, str | None] | None = None,
    deadline: float | None = None,
) -> tuple[str, bool]:
    """``(state, start_unchecked)``.  ``live`` only if ``pid`` exists and, when
    the lock recorded a start time, that pid's start matches it (else an
    unrelated process reused the pid: ``reused-pid``).  Missing or unreadable
    start info on either side falls back to the pid-only check, and so does a
    report ``deadline`` that has already passed: no further ``ps`` probe runs
    (``start_unchecked`` is then true) and each probe that does run is capped by
    the time left.  ``start_cache`` shares one ``ps`` probe per pid across the
    lanes of one report (a session's lanes share its pid)."""

    if not _pid_alive(pid):
        return "dead-pid", False
    recorded = _parse_lstart(recorded_start) if recorded_start else None
    if recorded is None:
        return "live", False
    if start_cache is not None and pid in start_cache:
        probed = start_cache[pid]
    else:
        timeout = PS_PROBE_TIMEOUT_SECONDS
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return "live", True
            timeout = min(timeout, remaining)
        probed = _ps_lstart(pid, timeout=timeout)
        if start_cache is not None:
            start_cache[pid] = probed
    actual = _parse_lstart(probed) if probed else None
    if actual is None or abs(actual - recorded) <= PID_START_TOLERANCE_SECONDS:
        return "live", False
    return "reused-pid", False


def _agent_lane_lock(
    path: Path,
    physical: dict[str, Any],
    workspace: Path,
    start_cache: dict[int, str | None] | None = None,
    deadline: float | None = None,
) -> dict[str, Any] | None:
    """Identify a Claude Code harness lane under ``<workspace>/.claude/worktrees``.

    The harness locks each lane with ``claude agent <dirname> (pid <N> ...)``;
    branch is not identity (agents switch branches).  ``live``: that lock with
    a live pid whose start matches the recorded one.  ``dead-pid``: that lock,
    pid gone.  ``reused-pid``: pid alive but started at another time (the
    harness crashed and the pid was recycled).  ``unlocked``: no lock but
    a harness-generated dirname.  ``None`` (caller fails closed): no such
    provenance, not a direct child of the root, or lock state not observed.
    """

    if path.parent != workspace / ".claude" / "worktrees":
        return None
    locked = physical.get("locked")
    if locked is False:
        named = AGENT_DIRNAME_RE.fullmatch(path.name)
        return {"state": "unlocked"} if named else None
    if locked is not True:
        return None
    match = AGENT_LOCK_REASON_RE.match(str(physical.get("lock_reason") or ""))
    if match is None or match.group("name") != path.name:
        return None
    pid = int(match.group("pid"))
    state, start_unchecked = _harness_pid_state(
        pid, match.group("start"), start_cache, deadline
    )
    lock: dict[str, Any] = {"state": state, "pid": pid}
    if start_unchecked:
        # The report deadline passed before this pid's start could be probed:
        # ``live`` is the pid-only answer, not a verified start match.
        lock["start_check"] = "skipped-deadline"
    return lock


def _branch_tip(workspace: Path, branch: str) -> str | None:
    """Return the commit a local branch points at, or None when unreadable."""

    try:
        completed = subprocess.run(
            [
                "git",
                "-C",
                str(workspace),
                "rev-parse",
                "--verify",
                "-q",
                f"refs/heads/{branch}",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return completed.stdout.strip() or None if completed.returncode == 0 else None


def _stale_agent_cleanup_hint(path: Path, lock: dict[str, Any], branch: str) -> str:
    quoted = shlex.quote(str(path))
    unlock = f"git worktree unlock {quoted} && " if lock["state"] != "unlocked" else ""
    kept = f"; branch {branch} is kept, delete it only once merged"
    why = (
        "pid alive but its start time differs from the lock's"
        if lock["state"] == "reused-pid"
        else lock["state"]
    )
    return (
        f"{unlock}git worktree remove {quoted}  # harness no longer holds this lane "
        f"({why}); remove refuses uncommitted work, so salvage it first"
        + ("" if branch == "(detached)" else kept)
    )


def _load_registry(state_path: Path) -> tuple[list[dict[str, Any]], str | None]:
    try:
        payload = json.loads(state_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return [], "registry-missing"
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return [], f"registry-unreadable:{exc.__class__.__name__}"
    if not isinstance(payload, dict) or not isinstance(payload.get("records"), list):
        return [], "registry-records-invalid"
    records = [item for item in payload["records"] if isinstance(item, dict)]
    return records, None


def _scope_paths(record: dict[str, Any]) -> list[str]:
    scope = record.get("scope")
    if not isinstance(scope, dict) or not isinstance(scope.get("files"), list):
        return []
    return sorted(
        {
            str(item.get("path"))
            for item in scope["files"]
            if isinstance(item, dict) and isinstance(item.get("path"), str)
        }
    )


def _lane_key(branch: str, path: Path, index: int | None = None) -> str:
    suffix = "" if index is None else f"\0{index}"
    return hashlib.sha256(f"{branch}\0{path}{suffix}".encode()).hexdigest()[:16]


def _nested_worktree_paths(root: Path, candidates: set[Path]) -> set[Path]:
    normalized_root = _path(root)
    return {
        path
        for path in candidates
        if path != normalized_root and _relative_to(path, normalized_root)
    }


def _nested_worktree_index(known: set[Path]) -> dict[Path, set[Path]]:
    """Map every known path to the known paths nested anywhere below it.

    One pass over each path's ancestors instead of one ``_relative_to`` per
    (lane, candidate) pair: with ~1200 registry records the pairwise form was
    ~1.5M pure-Python comparisons that no measurement deadline interrupts.
    """

    nested: dict[Path, set[Path]] = {}
    for path in known:
        for parent in path.parents:
            if parent in known:
                nested.setdefault(parent, set()).add(path)
    return nested


def _lane_entry(
    *,
    branch: str,
    path: Path,
    lane_kind: str,
    registry: dict[str, Any] | None,
    registry_index: int | None,
    physical: dict[str, Any] | None,
    deadline: float | None = None,
    excluded: bool = False,
    scan_excluded: set[Path] | None = None,
    measured: dict[str, Any] | None = None,
    physical_state_override: str | None = None,
    registry_match_count: int = 1,
    registry_statuses: list[str] | None = None,
    topology: str | None = None,
) -> dict[str, Any]:
    exists = path.is_dir()
    if measured is None:
        if exists:
            measured = measure_tree(
                path,
                excluded=scan_excluded,
                deadline=deadline,
                regenerable_names=REGENERABLE_DIRNAMES,
            )
        else:
            measured = {
                "logical_bytes": 0,
                "allocated_bytes": 0,
                "files": 0,
                "complete": False,
                "error": MISSING_PATH_ERROR,
            }
    if physical is not None:
        head = physical.get("head")
        observed_branch = physical.get("branch")
        physical_state = physical.get("worktree_state", "unknown")
        if not exists:
            physical_state = "missing"
        elif physical_state == "clean":
            physical_state = "present"
        elif physical_state == "dirty":
            physical_state = "dirty"
        else:
            physical_state = "unknown"
    else:
        head = None
        observed_branch = None
        physical_state = "unverified" if exists else "missing"
    if physical_state_override is not None:
        physical_state = physical_state_override
    if excluded and exists:
        physical_state = "excluded"
    ownership = (
        "excluded"
        if excluded
        else "registered"
        if registry is not None
        else "unregistered"
    )
    registry_status = registry.get("status") if registry else None
    if registry_status in TERMINAL_REGISTRY_STATUSES:
        lane_state = "terminal"
    elif registry_status in LIVE_REGISTRY_STATUSES:
        lane_state = "live"
    elif registry is not None:
        lane_state = "unknown"
    elif excluded:
        lane_state = "excluded"
    else:
        lane_state = "physical"
    entry: dict[str, Any] = {
        "lane_key": _lane_key(branch, path, registry_index),
        "lane_kind": lane_kind,
        "branch": branch,
        "path": str(path),
        "exists": exists,
        "physical_state": physical_state,
        "lane_state": lane_state,
        "logical_bytes": measured["logical_bytes"],
        "allocated_bytes": measured["allocated_bytes"],
        "files": measured["files"],
        "measurement_complete": measured["complete"],
        "ownership": ownership,
        "registry_status": registry_status,
        "registry_index": registry_index,
        "registry_match_count": registry_match_count,
        "registry_statuses": sorted(set(registry_statuses or [])),
        "accounted_in_aggregate": bool(lane_kind == "lane" and exists and not excluded),
        "external_ids": sorted(
            str(item) for item in (registry or {}).get("external_ids", []) if str(item)
        ),
        "scope": _scope_paths(registry or {}),
    }
    if topology is not None:
        entry["topology"] = topology
    if measured.get("regenerable_roots"):
        entry["regenerable_roots"] = sorted(
            _display_relative(root, path) for root in measured["regenerable_roots"]
        )
    if physical is not None:
        entry["worktree_state"] = physical.get("worktree_state", "unknown")
        entry["inspection_complete"] = bool(physical.get("inspection_complete", False))
        if physical.get("inspection_error"):
            entry["inspection_error"] = physical["inspection_error"]
        if "dirty" in physical:
            entry["dirty"] = bool(physical["dirty"])
    if head:
        entry["head"] = head
    if observed_branch:
        entry["observed_branch"] = observed_branch
    if "error" in measured:
        entry["measurement_error"] = measured["error"]
    if measured.get("errors"):
        entry["measurement_errors"] = measured["errors"]
        if MEASUREMENT_BUDGET_ERROR in measured["errors"]:
            entry["measurement_error"] = MEASUREMENT_BUDGET_ERROR
    if physical_state_override is not None and exists:
        entry["underlying_physical_state"] = (
            physical.get("worktree_state", "unknown")
            if physical is not None
            else "unverified"
        )
    if excluded:
        entry["excluded"] = True
        entry["exclusion_reason"] = "caller-supplied-supervision-worktree"
    return entry


def build_report(
    workspace: Path,
    state_path: Path,
    *,
    time_budget_seconds: float | None = None,
    supervision_worktree_paths: tuple[str | Path, ...] = (),
    xctest_devices_root: str | Path | None = None,
    xctest_devices_budget_gib: int = DEFAULT_XCTEST_DEVICES_BUDGET_GIB,
    auto_reclaim_xctest_devices: bool = False,
    simulator_runtime_budget_gib: int = DEFAULT_SIMULATOR_RUNTIME_BUDGET_GIB,
    measure_regenerable: bool = False,
) -> dict[str, Any]:
    measurement_started = time.monotonic()
    if time_budget_seconds is None:
        effective_time_budget = None
    elif not math.isfinite(time_budget_seconds):
        effective_time_budget = 0.0
    else:
        effective_time_budget = min(
            MAX_TIME_BUDGET_SECONDS, max(0.0, time_budget_seconds)
        )
    deadline = (
        None
        if effective_time_budget is None
        else measurement_started + effective_time_budget
    )
    workspace = _path(workspace)
    state_path = _path(state_path)
    simulator_runtimes = inspect_simulator_runtimes(
        budget_bytes=max(0, int(simulator_runtime_budget_gib)) * GIB,
        deadline=deadline,
    )
    requested_supervision_paths: list[Path] = []
    for value in supervision_worktree_paths:
        normalized = _path(value)
        if normalized not in requested_supervision_paths:
            requested_supervision_paths.append(normalized)

    registry_records, registry_error = _load_registry(state_path)
    physical_records, git_error = _parse_worktrees(workspace, deadline=deadline)
    topology_roots = _topology_roots(workspace)
    topology_errors: list[str] = []
    workspace_common_dir: str | None = None
    try:
        workspace_common_dir = _git_output(
            workspace, "rev-parse", "--git-common-dir", deadline=deadline
        )
    except _MeasurementBudgetExceeded:
        topology_errors.append(f"{workspace}:{MEASUREMENT_BUDGET_ERROR}")
    if workspace_common_dir is not None:
        workspace_common_dir = str(_path(workspace / workspace_common_dir))
    known_physical_paths = {item["path"] for item in physical_records}
    topology_halted = _is_budget_error(git_error) or bool(
        topology_errors and _is_budget_error(topology_errors[-1])
    )
    for topology_root in topology_roots:
        if topology_halted:
            break
        candidates, topology_error = _topology_candidates(
            topology_root, deadline=deadline
        )
        if topology_error:
            topology_errors.append(f"{topology_root}:{topology_error}")
            if _is_budget_error(topology_error):
                topology_halted = True
        for candidate in candidates:
            if topology_halted:
                break
            if candidate in known_physical_paths:
                continue
            try:
                candidate_common_dir = _git_output(
                    candidate, "rev-parse", "--git-common-dir", deadline=deadline
                )
            except _MeasurementBudgetExceeded:
                topology_errors.append(f"{candidate}:{MEASUREMENT_BUDGET_ERROR}")
                topology_halted = True
                break
            if candidate_common_dir is None:
                continue
            candidate_common_dir = str(_path(candidate / candidate_common_dir))
            if candidate_common_dir != workspace_common_dir:
                continue
            try:
                inspected = _inspect_topology_worktree(candidate, deadline=deadline)
            except _MeasurementBudgetExceeded:
                topology_errors.append(f"{candidate}:{MEASUREMENT_BUDGET_ERROR}")
                topology_halted = True
                break
            if inspected is not None:
                physical_records.append(inspected)
                known_physical_paths.add(candidate)
                if _is_budget_error(inspected.get("inspection_error")):
                    topology_errors.append(
                        f"{candidate}:{inspected['inspection_error']}"
                    )
                    topology_halted = True
    physical_by_path: dict[Path, dict[str, Any]] = {}
    physical_path_counts: dict[Path, int] = {}
    for item in physical_records:
        physical_path = item["path"]
        physical_path_counts[physical_path] = (
            physical_path_counts.get(physical_path, 0) + 1
        )
        physical_by_path.setdefault(physical_path, item)

    registry_by_path: dict[Path, list[tuple[int, dict[str, Any]]]] = {}
    status_counts: dict[str, int] = {}
    malformed_registry_records = 0
    unknown_registry_record_indices: list[int] = []
    for index, record in enumerate(registry_records):
        status_value = record.get("status")
        status = (
            status_value
            if isinstance(status_value, str) and status_value
            else "(missing)"
        )
        status_counts[status] = status_counts.get(status, 0) + 1
        if status not in KNOWN_REGISTRY_STATUSES:
            unknown_registry_record_indices.append(index)
        record_path = record.get("path")
        branch = record.get("branch")
        if (
            not isinstance(record_path, str)
            or not record_path.strip()
            or not isinstance(branch, str)
            or not branch.strip()
        ):
            malformed_registry_records += 1
            continue
        normalized = _path(record_path)
        registry_by_path.setdefault(normalized, []).append((index, record))

    known_worktree_paths = set(physical_by_path) | set(registry_by_path)
    nested_worktrees = _nested_worktree_paths(
        workspace,
        {path for path in known_worktree_paths if path.is_dir()},
    )
    nested_index = _nested_worktree_index(known_worktree_paths)
    unmeasured_workspace_roots = sorted(
        workspace / name
        for name in UNMEASURED_WORKSPACE_DIRNAMES
        if (workspace / name).is_dir()
    )
    workspace_measurement = measure_tree(
        workspace,
        excluded=nested_worktrees | set(unmeasured_workspace_roots),
        deadline=deadline,
        regenerable_names=REGENERABLE_DIRNAMES,
    )

    applied_exclusions: list[Path] = []
    exclusion_rejections: list[dict[str, str]] = []
    for supervision_path in requested_supervision_paths:
        if supervision_path == workspace:
            exclusion_rejections.append(
                {"path": str(supervision_path), "reason": "canonical-worktree"}
            )
        elif supervision_path in registry_by_path:
            exclusion_rejections.append(
                {
                    "path": str(supervision_path),
                    "reason": "registered-worktree",
                }
            )
        elif supervision_path not in physical_by_path:
            exclusion_rejections.append(
                {"path": str(supervision_path), "reason": "physical-worktree-missing"}
            )
        else:
            applied_exclusions.append(supervision_path)

    registry_entries: list[dict[str, Any]] = []
    for normalized, matches in registry_by_path.items():
        live_matches = [
            item for item in matches if item[1].get("status") in LIVE_REGISTRY_STATUSES
        ]
        terminal_matches = [
            item
            for item in matches
            if item[1].get("status") in TERMINAL_REGISTRY_STATUSES
        ]
        unknown_matches = [
            item
            for item in matches
            if item[1].get("status") not in KNOWN_REGISTRY_STATUSES
        ]
        selected_index, selected_record = (
            live_matches[0]
            if live_matches
            else unknown_matches[0]
            if unknown_matches
            else terminal_matches[0]
        )
        branch = str(selected_record["branch"])
        lane_kind = "canonical-main" if normalized == workspace else "lane"
        is_terminal = (
            not live_matches
            and not unknown_matches
            and selected_record.get("status") in TERMINAL_REGISTRY_STATUSES
        )
        entry = _lane_entry(
            branch=branch,
            path=normalized,
            lane_kind=lane_kind,
            registry=selected_record,
            registry_index=selected_index,
            physical=physical_by_path.get(normalized),
            deadline=deadline,
            scan_excluded=nested_index.get(normalized, set()),
            measured=workspace_measurement if normalized == workspace else None,
            physical_state_override=(
                "terminal-residue"
                if is_terminal and normalized in physical_by_path
                else None
            ),
            registry_match_count=len(matches),
            registry_statuses=[
                str(item[1].get("status") or "(missing)") for item in matches
            ],
            topology=_topology_name(normalized, topology_roots),
        )
        entry["registry_indices"] = sorted(item[0] for item in matches)
        entry["external_ids"] = sorted(
            {
                str(external_id)
                for _, item in matches
                for external_id in item.get("external_ids", [])
                if str(external_id)
            }
        )
        registry_entries.append(entry)

    start_cache: dict[int, str | None] = {}
    for physical in physical_records:
        physical_path = physical["path"]
        if physical_path in registry_by_path:
            continue
        branch = str(physical.get("branch") or "(detached)")
        topology = _topology_name(physical_path, topology_roots)
        is_supervision = _is_codex_supervision_checkout(physical_path, topology_roots)
        lane_kind = (
            "canonical-main"
            if physical_path == workspace
            else "supervision"
            if is_supervision
            else "lane"
        )
        is_excluded = physical_path in applied_exclusions
        agent_lock = (
            _agent_lane_lock(physical_path, physical, workspace, start_cache, deadline)
            if lane_kind == "lane" and not is_excluded
            else None
        )
        entry = _lane_entry(
            branch=branch,
            path=physical_path,
            lane_kind=lane_kind,
            registry=None,
            registry_index=None,
            physical=physical,
            deadline=deadline,
            excluded=is_excluded,
            scan_excluded=nested_index.get(physical_path, set()),
            measured=workspace_measurement if physical_path == workspace else None,
            topology=topology,
        )
        if lane_kind == "canonical-main":
            entry["ownership"] = "canonical"
            entry["lane_state"] = "canonical"
        elif lane_kind == "supervision":
            entry["ownership"] = "supervision"
            entry["lane_state"] = "supervision"
        elif agent_lock is not None and agent_lock["state"] == "live":
            entry["ownership"] = "ephemeral-agent"
            entry["lane_state"] = "ephemeral"
            entry["agent_lock"] = agent_lock
        elif agent_lock is not None:
            # No live writer and its bytes stay quota-counted: cleanup debt to
            # report, not a reason for one crashed session to stop every lane.
            entry["ownership"] = "stale-agent"
            entry["lane_state"] = "stale"
            entry["agent_lock"] = agent_lock
            entry["cleanup_hint"] = _stale_agent_cleanup_hint(
                physical_path, agent_lock, branch
            )
        elif not is_excluded and entry["exists"]:
            # Keep the ownership state explicit while exposing dirty/unknown in
            # the separate worktree_state fields populated above.
            entry["physical_state"] = (
                "present-unregistered"
                if physical.get("worktree_state") in {"clean", "dirty"}
                else "unknown-unregistered"
            )
        registry_entries.append(entry)

    if not any(
        item["lane_kind"] == "canonical-main" and item["path"] == str(workspace)
        for item in registry_entries
    ):
        canonical = _lane_entry(
            branch="(canonical)",
            path=workspace,
            lane_kind="canonical-main",
            registry=None,
            registry_index=None,
            physical=physical_by_path.get(workspace),
            deadline=deadline,
            scan_excluded=nested_worktrees,
            measured=workspace_measurement,
            topology=_topology_name(workspace, topology_roots),
        )
        canonical["ownership"] = "canonical"
        canonical["lane_state"] = "canonical"
        registry_entries.append(canonical)

    lanes = sorted(
        registry_entries,
        key=lambda item: (
            item["lane_kind"],
            item["path"],
            item["branch"],
            item["registry_index"] or -1,
        ),
    )
    # The shared XCTestDevices store is measured only after lane attribution.  Its
    # clone-aware physical accounting opens every file (226k files, 52 GB on the
    # felix/oscar hosts) and alone took 150-220 s of the 240 s window; measured
    # first, it left the registry/worktree/lane attribution that decides every
    # writer's admission with no time at all (2026-10-08).  Lane attribution is
    # cheap and decisive, so it goes first; a slow platform walk can only make
    # its own section incomplete.
    xctest_devices = inspect_xctest_devices(
        xctest_devices_root,
        budget_bytes=max(0, int(xctest_devices_budget_gib)) * GIB,
        deadline=deadline,
        auto_reclaim=auto_reclaim_xctest_devices,
    )
    # Regenerable roots were listed, not walked.  Sizing them is opt-in and runs
    # last on whatever budget is left: it can only add evidence beside the quota
    # bytes, so an expired budget here never blocks (partial = reported, not 0).
    regenerable_root_count = 0
    regenerable_totals = {
        "logical_bytes": 0,
        "allocated_bytes": 0,
        "files": 0,
        "complete": True,
    }
    for item in lanes:
        relative_roots = item.get("regenerable_roots") or []
        regenerable_root_count += len(relative_roots)
        if not (measure_regenerable and relative_roots):
            continue
        sized = _measure_regenerable(
            [Path(item["path"]) / relative for relative in relative_roots],
            deadline=deadline,
        )
        item["regenerable_logical_bytes"] = sized["logical_bytes"]
        item["regenerable_allocated_bytes"] = sized["allocated_bytes"]
        item["regenerable_measurement_complete"] = sized["complete"]
        for key in ("logical_bytes", "allocated_bytes", "files"):
            regenerable_totals[key] += sized[key]
        regenerable_totals["complete"] = bool(
            regenerable_totals["complete"] and sized["complete"]
        )
    regenerable_accounting: dict[str, Any] = {
        "names": sorted(REGENERABLE_DIRNAMES),
        "root_count": regenerable_root_count,
        "counted_in_quota": False,
        "measured": bool(measure_regenerable),
    }
    if measure_regenerable:
        regenerable_accounting.update(
            {
                "logical_bytes": regenerable_totals["logical_bytes"],
                "allocated_bytes": regenerable_totals["allocated_bytes"],
                "files": regenerable_totals["files"],
                "measurement_complete": regenerable_totals["complete"],
            }
        )
    physical_lanes_by_path = {
        Path(item["path"]): item
        for item in lanes
        if item["lane_kind"] == "lane" and item["exists"]
    }
    physical_lanes = list(physical_lanes_by_path.values())
    supervision_worktrees = [
        item for item in lanes if item["lane_kind"] == "supervision" and item["exists"]
    ]
    dirty_supervision = sorted(
        str(item["path"])
        for item in supervision_worktrees
        if item.get("worktree_state") == "dirty"
    )
    unknown_supervision = sorted(
        str(item["path"])
        for item in supervision_worktrees
        if (
            not item.get("inspection_complete", True)
            or item.get("worktree_state") == "unknown"
            or item.get("physical_state") == "unknown"
        )
    )
    accounted_lanes = [
        item for item in physical_lanes if item["accounted_in_aggregate"]
    ]
    lane_allocated = sum(int(item["allocated_bytes"]) for item in accounted_lanes)
    lane_logical = sum(int(item["logical_bytes"]) for item in accounted_lanes)
    observed_lane_allocated = sum(
        int(item["allocated_bytes"]) for item in physical_lanes
    )
    observed_lane_logical = sum(int(item["logical_bytes"]) for item in physical_lanes)
    excluded_lanes = [item for item in physical_lanes if item.get("excluded")]
    active_physical_lanes = [
        item
        for item in physical_lanes
        if item.get("registry_status") in LIVE_REGISTRY_STATUSES
    ]
    terminal_physical_lanes = [
        item
        for item in physical_lanes
        if item.get("registry_status") in TERMINAL_REGISTRY_STATUSES
    ]
    missing_active = sorted(
        {
            str(item["path"])
            for item in lanes
            if item["ownership"] == "registered"
            and item["registry_status"] in LIVE_REGISTRY_STATUSES
            and not item["exists"]
        }
    )
    missing_terminal = sorted(
        {
            str(item["path"])
            for item in lanes
            if item["ownership"] == "registered"
            and item["registry_status"] in TERMINAL_REGISTRY_STATUSES
            and not item["exists"]
        }
    )
    unregistered = sorted(
        str(item["path"])
        for item in physical_lanes
        if item["ownership"] == "unregistered"
    )
    ephemeral_agent = sorted(
        str(item["path"])
        for item in physical_lanes
        if item["ownership"] == "ephemeral-agent"
    )
    stale_agent = sorted(
        str(item["path"])
        for item in physical_lanes
        if item["ownership"] == "stale-agent"
    )
    dirty_physical = sorted(
        str(item["path"])
        for item in physical_lanes
        if item.get("worktree_state") == "dirty" and not item.get("excluded")
    )
    active_dirty_implementation = sorted(
        str(item["path"])
        for item in physical_lanes
        if item.get("worktree_state") == "dirty"
        and not item.get("excluded")
        and item.get("ownership") == "registered"
        and item.get("registry_status") == "active"
    )
    blocking_dirty_physical = sorted(
        str(item["path"])
        for item in physical_lanes
        if item.get("worktree_state") == "dirty"
        and not item.get("excluded")
        and item.get("ownership") not in {"ephemeral-agent", "stale-agent"}
        and not (
            item.get("ownership") == "registered"
            and item.get("registry_status") == "active"
        )
    )
    unknown_physical = sorted(
        str(item["path"])
        for item in physical_lanes
        if (
            not item.get("inspection_complete", True)
            and item.get("inspection_error") != MISSING_PATH_ERROR
        )
        or item.get("worktree_state") == "unknown"
        or item.get("physical_state") in {"unverified", "unknown-unregistered"}
    )
    unknown_registry_paths = sorted(
        str(path)
        for path, matches in registry_by_path.items()
        if any(item[1].get("status") not in KNOWN_REGISTRY_STATUSES for item in matches)
    )
    physical_identity_mismatches = sorted(
        str(item["path"])
        for item in physical_lanes
        if item.get("registry_status") in KNOWN_REGISTRY_STATUSES
        and item.get("observed_branch")
        and item.get("observed_branch") != item.get("branch")
    )
    detached_candidates = [
        item
        for item in physical_lanes
        if item.get("registry_status") in KNOWN_REGISTRY_STATUSES
        and item.get("worktree_state") != "dirty"
        and item.get("observed_branch") is None
        and item.get("branch") not in {"(detached)", "(canonical)"}
        and item.get("physical_state") not in {"missing", "excluded"}
    ]
    # A clean lane detached exactly at its branch tip loses nothing: warn,
    # do not block every unrelated lane.
    detached_at_tip = sorted(
        str(item["path"])
        for item in detached_candidates
        if _branch_tip(workspace, str(item.get("branch"))) == item.get("head")
    )
    detached_registered = sorted(
        str(item["path"])
        for item in detached_candidates
        if str(item["path"]) not in detached_at_tip
    )
    branch_by_path = {
        str(item["path"]): str(item.get("branch")) for item in physical_lanes
    }
    physical_identity_repairs = [
        f"git -C {path} switch {branch_by_path[path]}"
        for path in sorted(set(physical_identity_mismatches + detached_registered))
        if branch_by_path.get(path)
    ]
    try:
        per_lane_budget = (
            int(os.environ.get("KG_DISK_GUARD_LANE_BUDGET_GIB", "2")) * GIB
        )
    except ValueError:
        per_lane_budget = 2 * GIB
    try:
        total_lane_budget = (
            int(os.environ.get("KG_DISK_GUARD_LANE_TOTAL_BUDGET_GIB", "8")) * GIB
        )
    except ValueError:
        total_lane_budget = 8 * GIB
    measurement_incomplete_reasons: set[str] = set()
    if git_error:
        measurement_incomplete_reasons.add(
            MEASUREMENT_BUDGET_ERROR
            if _is_budget_error(git_error)
            else "worktree-inspection-incomplete"
        )
    for topology_error in topology_errors:
        measurement_incomplete_reasons.add(
            MEASUREMENT_BUDGET_ERROR
            if _is_budget_error(topology_error)
            else "topology-inspection-incomplete"
        )
    if not workspace_measurement["complete"]:
        measurement_incomplete_reasons.add("workspace-measurement-incomplete")

    lane_measurement_incomplete = False
    for item in lanes:
        if item["lane_kind"] not in {"lane", "supervision"}:
            continue
        if item["exists"] and not item["measurement_complete"]:
            measurement_errors = item.get("measurement_errors", [])
            if _is_budget_error(item.get("measurement_error")) or any(
                _is_budget_error(error) for error in measurement_errors
            ):
                measurement_incomplete_reasons.add(MEASUREMENT_BUDGET_ERROR)
            else:
                measurement_incomplete_reasons.add("lane-measurement-incomplete")
            lane_measurement_incomplete = True
        inspection_error = item.get("inspection_error")
        if inspection_error and inspection_error != MISSING_PATH_ERROR:
            measurement_incomplete_reasons.add(
                MEASUREMENT_BUDGET_ERROR
                if _is_budget_error(inspection_error)
                else "worktree-inspection-incomplete"
            )
    measurement_budget_exhausted = (
        MEASUREMENT_BUDGET_ERROR in measurement_incomplete_reasons
    )
    measurement_incomplete = bool(measurement_incomplete_reasons)

    # A partial scan is evidence for a fail-closed block, not evidence that a
    # lane or aggregate is over quota.  Only complete observations can produce
    # quota reasons.
    over_lane = (
        sorted(
            {
                str(item["path"])
                for item in accounted_lanes
                if int(item["allocated_bytes"]) > per_lane_budget
            }
        )
        if not measurement_incomplete
        else []
    )
    quota_reasons = [f"lane-budget-exceeded:{path}" for path in over_lane]
    if not measurement_incomplete and lane_allocated > total_lane_budget:
        quota_reasons.append("lane-total-budget-exceeded")
    quota_exceeded = bool(quota_reasons)
    blocking_reasons: list[str] = []
    warning_reasons: list[str] = []
    if registry_error:
        blocking_reasons.append(registry_error)
    if git_error:
        blocking_reasons.append(git_error)
    if topology_errors:
        blocking_reasons.extend(topology_errors)
    if malformed_registry_records:
        blocking_reasons.append("registry-records-invalid")
    if missing_active:
        warning_reasons.append("missing-registered-lane")
    if missing_terminal:
        warning_reasons.append("missing-terminal-lane")
    if terminal_physical_lanes:
        warning_reasons.append("terminal-physical-residue")
    if exclusion_rejections:
        warning_reasons.append("supervision-path-not-excluded")
        if any(
            item["reason"] == "registered-worktree" for item in exclusion_rejections
        ):
            blocking_reasons.append("supervision-path-registered")
    if ephemeral_agent:
        warning_reasons.append("ephemeral-agent-lane")
    if stale_agent:
        warning_reasons.append("stale-agent-worktree")
    if unregistered:
        blocking_reasons.append("unregistered-physical-worktree")
    if dirty_supervision:
        blocking_reasons.append("dirty-supervision-worktree")
    if unknown_supervision:
        blocking_reasons.append("unknown-supervision-worktree")
    if blocking_dirty_physical:
        blocking_reasons.append("dirty-physical-worktree")
    if unknown_physical:
        blocking_reasons.append("unknown-physical-worktree")
    if unknown_registry_record_indices:
        blocking_reasons.append("unknown-registry-status")
    if physical_identity_mismatches or detached_registered:
        blocking_reasons.append("physical-identity-mismatch")
    duplicate_physical_paths = sorted(
        str(path) for path, count in physical_path_counts.items() if count > 1
    )
    if duplicate_physical_paths:
        blocking_reasons.append("duplicate-physical-worktree")
    duplicate_live_paths = sorted(
        str(path)
        for path, matches in registry_by_path.items()
        if sum(item[1].get("status") in LIVE_REGISTRY_STATUSES for item in matches) > 1
    )
    if duplicate_live_paths:
        blocking_reasons.append("duplicate-live-registry-claim")
    if not workspace_measurement["complete"]:
        blocking_reasons.append("workspace-measurement-incomplete")
    if lane_measurement_incomplete:
        blocking_reasons.append("lane-measurement-incomplete")
    if measurement_budget_exhausted:
        blocking_reasons.append(MEASUREMENT_BUDGET_ERROR)
    if xctest_devices["exists"]:
        if not xctest_devices["measurement_complete"]:
            blocking_reasons.append(XCTEST_DEVICES_MEASUREMENT_ERROR)
        if not xctest_devices["metadata_complete"]:
            blocking_reasons.append(XCTEST_DEVICES_METADATA_ERROR)
        if xctest_devices["budget_exceeded"]:
            blocking_reasons.append(XCTEST_DEVICES_BUDGET_ERROR)
            if xctest_devices["reclaim"]["status"] != "reclaimed":
                blocking_reasons.append(XCTEST_DEVICES_MANUAL_REVIEW_ERROR)
    if simulator_runtimes["status"] not in {"absent", "unsupported"}:
        if not simulator_runtimes["measurement_complete"]:
            blocking_reasons.append(SIMULATOR_RUNTIME_MEASUREMENT_ERROR)
            blocking_reasons.append(SIMULATOR_RUNTIME_DISCOVERY_ERROR)
        if simulator_runtimes["budget_exceeded"] is True:
            blocking_reasons.append(SIMULATOR_RUNTIME_BUDGET_ERROR)
            if simulator_runtimes["reclaim"]["status"] != "reclaimed":
                blocking_reasons.append(SIMULATOR_RUNTIME_MANUAL_REVIEW_ERROR)
    blocking_reasons.extend(quota_reasons)
    if blocking_reasons:
        verdict = "block"
    elif warning_reasons:
        verdict = "warning"
    else:
        verdict = "pass"
    try:
        filesystem = shutil.disk_usage(workspace)
        filesystem_payload = {
            "total_bytes": int(filesystem.total),
            "used_bytes": int(filesystem.used),
            "free_bytes": int(filesystem.free),
        }
    except OSError as exc:
        filesystem_payload = {"error": f"filesystem-usage:{exc.__class__.__name__}"}
        blocking_reasons.append("filesystem-usage-unknown")
        verdict = "block"

    reasons = sorted({*blocking_reasons, *warning_reasons})
    product_lanes = [item for item in lanes if item["lane_kind"] == "lane"]
    lane_accounting = [
        {
            "lane_key": item["lane_key"],
            "branch": item["branch"],
            "path": item["path"],
            "exists": item["exists"],
            "ownership": item["ownership"],
            "registry_status": item["registry_status"],
            "lane_state": item["lane_state"],
            "physical_state": item["physical_state"],
            "logical_bytes": item["logical_bytes"],
            "allocated_bytes": item["allocated_bytes"],
            "files": item["files"],
            "measurement_complete": item["measurement_complete"],
            "measurement_error": item.get("measurement_error"),
            "measurement_errors": item.get("measurement_errors", []),
            "accounted_in_aggregate": item["accounted_in_aggregate"],
        }
        for item in product_lanes
    ]

    classification_items: dict[str, list[dict[str, Any]]] = {
        "active": [],
        "active_but_missing": [],
        "physical_but_unregistered": [],
        "ephemeral_agent": [],
        "stale_agent": [],
        "terminal_residue": [],
        "unknown": [],
    }
    for item in product_lanes:
        if item["registry_status"] in LIVE_REGISTRY_STATUSES:
            classification = "active" if item["exists"] else "active_but_missing"
        elif item["registry_status"] in TERMINAL_REGISTRY_STATUSES:
            classification = "terminal_residue" if item["exists"] else "unknown"
        elif item["ownership"] == "unregistered":
            classification = "physical_but_unregistered"
        elif item["ownership"] == "ephemeral-agent":
            classification = "ephemeral_agent"
        elif item["ownership"] == "stale-agent":
            classification = "stale_agent"
        else:
            classification = "unknown"
        classification_items[classification].append(item)

    def classification_summary(items: list[dict[str, Any]]) -> dict[str, Any]:
        return {
            "count": len(items),
            "logical_bytes": sum(int(item["logical_bytes"]) for item in items),
            "allocated_bytes": sum(int(item["allocated_bytes"]) for item in items),
            "lane_keys": sorted(str(item["lane_key"]) for item in items),
            "paths": sorted(str(item["path"]) for item in items),
        }

    lane_attribution = {
        "product_lane_count": len(product_lanes),
        "product_lane_logical_bytes": sum(
            int(item["logical_bytes"]) for item in product_lanes
        ),
        "product_lane_allocated_bytes": sum(
            int(item["allocated_bytes"]) for item in product_lanes
        ),
        "product_lane_keys": sorted(str(item["lane_key"]) for item in product_lanes),
        "classifications": {
            name: classification_summary(classification_items[name])
            for name in sorted(classification_items)
        },
        "supervision_worktree_count": len(supervision_worktrees),
        "supervision_worktree_logical_bytes": sum(
            int(item["logical_bytes"]) for item in supervision_worktrees
        ),
        "supervision_worktree_allocated_bytes": sum(
            int(item["allocated_bytes"]) for item in supervision_worktrees
        ),
        "supervision_worktree_paths": sorted(
            str(item["path"]) for item in supervision_worktrees
        ),
    }

    return {
        "schema": SCHEMA,
        "workspace": str(workspace),
        "registry": str(state_path),
        "measurement": {
            "budget_seconds": effective_time_budget,
            "elapsed_seconds": round(time.monotonic() - measurement_started, 3),
            "budget_exhausted": measurement_budget_exhausted,
            "status": "incomplete" if measurement_incomplete else "complete",
            "incomplete_reasons": sorted(measurement_incomplete_reasons),
        },
        "topology": {
            "roots": [str(root) for root in topology_roots],
            "observed_roots": sorted(
                str(root) for root in topology_roots if root.is_dir()
            ),
            "observed_worktree_paths": sorted(
                str(item["path"])
                for item in physical_lanes
                if item.get("topology") in {"claude", "codex"}
            ),
            "codex_worktree_paths": sorted(
                str(item["path"])
                for item in physical_lanes
                if item.get("topology") == "codex"
            ),
            "errors": sorted(topology_errors),
        },
        "lanes": lanes,
        "lane_count": len([item for item in lanes if item["lane_kind"] == "lane"]),
        "lane_attribution": lane_attribution,
        "history": {
            "records": len(registry_records),
            "terminal_records": sum(
                count
                for status, count in status_counts.items()
                if status in TERMINAL_REGISTRY_STATUSES
            ),
            "by_status": dict(sorted(status_counts.items())),
            "malformed_records": malformed_registry_records,
        },
        "accounting": {
            "measurement": "st_blocks",
            "fields": ["logical_bytes", "allocated_bytes"],
            "workspace_unassigned_logical_bytes": workspace_measurement[
                "logical_bytes"
            ],
            "workspace_unassigned_allocated_bytes": workspace_measurement[
                "allocated_bytes"
            ],
            "physical_lane_logical_bytes": lane_logical,
            "physical_lane_allocated_bytes": lane_allocated,
            "physical_lane_observed_logical_bytes": observed_lane_logical,
            "physical_lane_observed_allocated_bytes": observed_lane_allocated,
            "physical_lane_excluded_logical_bytes": sum(
                int(item["logical_bytes"]) for item in excluded_lanes
            ),
            "physical_lane_excluded_allocated_bytes": sum(
                int(item["allocated_bytes"]) for item in excluded_lanes
            ),
            "active_physical_lane_count": len(active_physical_lanes),
            "terminal_physical_lane_count": len(terminal_physical_lanes),
            "excluded_physical_lane_count": len(excluded_lanes),
            "supervision_worktree_count": len(supervision_worktrees),
            "supervision_worktree_logical_bytes": sum(
                int(item["logical_bytes"]) for item in supervision_worktrees
            ),
            "supervision_worktree_allocated_bytes": sum(
                int(item["allocated_bytes"]) for item in supervision_worktrees
            ),
            "lane_accounting": lane_accounting,
            "managed_logical_bytes": workspace_measurement["logical_bytes"]
            + lane_logical,
            "managed_allocated_bytes": workspace_measurement["allocated_bytes"]
            + lane_allocated,
            "nested_worktrees_excluded_from_workspace": sorted(
                str(item) for item in nested_worktrees
            ),
            "workspace_unmeasured_roots": [
                str(item) for item in unmeasured_workspace_roots
            ],
            "regenerable": regenerable_accounting,
            "lane_attribution": lane_attribution,
            "shared_platform_storage": {
                "xctest_devices": xctest_devices,
                "simulator_runtimes": simulator_runtimes,
            },
        },
        "filesystem": filesystem_payload,
        "policy": {
            "verdict": verdict,
            "per_lane_budget_bytes": per_lane_budget,
            "total_lane_budget_bytes": total_lane_budget,
            "reasons": sorted(set(reasons)),
            "blocking_reasons": sorted(set(blocking_reasons)),
            "warning_reasons": sorted(set(warning_reasons)),
            "measurement_incomplete": measurement_incomplete,
            "measurement_incomplete_reasons": sorted(measurement_incomplete_reasons),
            "quota_exceeded": quota_exceeded,
            "quota_reasons": sorted(set(quota_reasons)),
            "missing_active_lanes": missing_active,
            "missing_terminal_lanes": missing_terminal,
            "unregistered_physical_worktrees": unregistered,
            "ephemeral_agent_worktrees": ephemeral_agent,
            "stale_agent_worktrees": stale_agent,
            "dirty_physical_worktrees": dirty_physical,
            "unknown_physical_worktrees": unknown_physical,
            "unknown_registry_paths": unknown_registry_paths,
            "unknown_registry_record_indices": unknown_registry_record_indices,
            "active_dirty_implementation_worktrees": active_dirty_implementation,
            "blocking_dirty_physical_worktrees": blocking_dirty_physical,
            "supervision_physical_worktrees": sorted(
                str(item["path"]) for item in supervision_worktrees
            ),
            "dirty_supervision_worktrees": dirty_supervision,
            "unknown_supervision_worktrees": unknown_supervision,
            "physical_identity_mismatches": sorted(
                set(physical_identity_mismatches + detached_registered)
            ),
            "physical_identity_repairs": physical_identity_repairs,
            "detached_at_tip_warnings": detached_at_tip,
            "terminal_physical_residue": sorted(
                str(item["path"]) for item in terminal_physical_lanes
            ),
            "excluded_physical_worktrees": sorted(
                str(item["path"]) for item in excluded_lanes
            ),
            "lane_budget_exceeded": over_lane,
        },
        "exclusions": {
            "matching": "exact-path-only",
            "supervision_worktree_paths": [
                str(item) for item in requested_supervision_paths
            ],
            "applied_paths": [str(item) for item in applied_exclusions],
            "rejected_paths": [item["path"] for item in exclusion_rejections],
            "rejections": exclusion_rejections,
        },
    }


def _write_atomic(path: Path, report: dict[str, Any]) -> None:
    path = _path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=str(path.parent)
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--state")
    parser.add_argument("--output")
    parser.add_argument(
        "--time-budget-seconds",
        type=float,
        default=DEFAULT_TIME_BUDGET_SECONDS,
        help="maximum recursive measurement time (hard maximum: 240 seconds)",
    )
    parser.add_argument(
        "--supervision-worktree",
        action="append",
        default=[],
        metavar="PATH",
        help="exclude this exact caller-supplied supervision worktree from managed quota",
    )
    parser.add_argument(
        "--xctest-devices-root",
        default=None,
        help="shared XCTestDevices root (default: KG_XCTEST_DEVICES_ROOT or the Apple host path)",
    )
    parser.add_argument(
        "--xctest-devices-budget-gib",
        type=int,
        default=_configured_xctest_devices_budget_gib(),
        help="shared XCTestDevices budget in GiB (default: 16)",
    )
    parser.add_argument(
        "--measure-regenerable",
        action="store_true",
        help="also size regenerable roots (.venv, node_modules, DerivedData) beside the quota bytes, on leftover budget",
    )
    parser.add_argument(
        "--auto-reclaim-xctest-devices",
        action="store_true",
        help="attempt only exact stale/ephemeral devices via supported simctl; otherwise fail closed",
    )
    parser.add_argument(
        "--simulator-runtime-budget-gib",
        type=int,
        default=_configured_simulator_runtime_budget_gib(),
        help="shared mounted Simulator runtime budget in GiB (default: 56; never auto-reclaimed)",
    )
    args = parser.parse_args(argv)
    workspace = _path(args.workspace)
    state = (
        _path(args.state) if args.state else workspace / ".cache/worktree_registry.json"
    )
    report = build_report(
        workspace,
        state,
        time_budget_seconds=args.time_budget_seconds,
        supervision_worktree_paths=tuple(args.supervision_worktree),
        xctest_devices_root=args.xctest_devices_root,
        xctest_devices_budget_gib=args.xctest_devices_budget_gib,
        auto_reclaim_xctest_devices=args.auto_reclaim_xctest_devices,
        simulator_runtime_budget_gib=args.simulator_runtime_budget_gib,
        measure_regenerable=args.measure_regenerable,
    )
    if args.output:
        _write_atomic(_path(args.output), report)
    json.dump(report, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if report["policy"]["verdict"] != "block" else BLOCKED_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
