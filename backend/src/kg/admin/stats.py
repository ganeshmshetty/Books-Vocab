"""Admin stats & observability — user stats, host metrics, usage ranges, logs."""

from __future__ import annotations

import logging
import os
import sqlite3
import threading
import time
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Protocol

from fastapi import HTTPException

from ..api_models import EntitlementsResponse
from ..types import AdminGrantRecord, StoredUserRecord, UsersPayload
from .entitlements import is_canonical_account, is_link_pointer

logger = logging.getLogger("kg.admin_handlers")


class MemLogGetter(Protocol):
    def __call__(self, n: int = 200, level: str | None = None) -> list[dict[str, Any]]: ...


def _count_active_cards(user_dir: Path) -> int:
    """Read-only card count; never creates dirs/DB files or touches the hot store cache."""
    db_path = user_dir / "cards.db"
    if not db_path.is_file():
        return 0
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        return int(conn.execute("SELECT COUNT(*) FROM card WHERE is_deleted = 0").fetchone()[0])
    finally:
        conn.close()


def admin_stats_response(
    *,
    load_users: Callable[[], UsersPayload],
    get_all_stats: Callable[[], dict[str, object]],
    build_entitlements_response: Callable[[StoredUserRecord | None], EntitlementsResponse],
    current_admin_grant_record: Callable[[StoredUserRecord | None], AdminGrantRecord],
    data_dir: Path,
) -> dict[str, Any]:
    from ..deps_quota import _is_pro
    from ..quota_service import _daily_limit, get_all_quota_usage

    users_data = load_users()
    token_stats = get_all_stats()
    is_pro_by_user = {
        uid: _is_pro({"record": info}) for uid, info in users_data.items() if is_canonical_account(uid, info)
    }
    quota_usage = get_all_quota_usage(is_pro_by_user=is_pro_by_user)

    result = []
    for uid, info in users_data.items():
        if uid.startswith("_") or is_link_pointer(uid, info):
            continue

        user_dir = data_dir / "users" / uid
        vocab_count = 0
        try:
            vocab_count = _count_active_cards(user_dir)
        except (OSError, sqlite3.Error):
            logger.warning("Failed to load card store for user %s", uid, exc_info=True)

        utoken = token_stats.get(uid, {})
        total_input = sum(d["input_tokens"] for d in utoken.values())
        total_output = sum(d["output_tokens"] for d in utoken.values())

        est_cost = sum(data["cost_usd"] for data in utoken.values())

        entitlements = build_entitlements_response(info if isinstance(info, dict) else None)
        admin_grant = current_admin_grant_record(info if isinstance(info, dict) else None)
        result.append(
            {
                "user_id": uid,
                "email": info.get("email") if isinstance(info, dict) else None,
                "provider": info.get("provider") if isinstance(info, dict) else None,
                "last_login": info.get("last_login") if isinstance(info, dict) else None,
                "vocab_count": vocab_count,
                "tokens": utoken,
                "total_input": total_input,
                "total_output": total_output,
                "est_cost_usd": round(est_cost, 6),
                "pro": entitlements.pro.model_dump(),
                "admin_grant": admin_grant,
                "quota": quota_usage.get(
                    uid,
                    {
                        "used_usd": 0.0,
                        "limit_usd": _daily_limit(is_pro_by_user.get(uid, False)),
                        "fraction_used": 0.0,
                        "calls": {},
                    },
                ),
            }
        )

    result.sort(key=lambda item: item["vocab_count"], reverse=True)

    try:
        from ..judge_log import get_acceptance_stats

        judge_stats = get_acceptance_stats()
    except Exception:
        logger.warning("Failed to load judge acceptance stats", exc_info=True)
        judge_stats = {"total": 0, "accepted": 0, "rejected": 0, "rate": None}

    return {"users": result, "judge": judge_stats}


def _collect_cpu(psutil: Any) -> dict[str, Any]:
    cpu_percent = psutil.cpu_percent(interval=0.1)
    cpu_count = psutil.cpu_count(logical=True) or 1
    load_avg = list(os.getloadavg()) if hasattr(os, "getloadavg") else [0.0, 0.0, 0.0]
    return {
        "percent": cpu_percent,
        "count": cpu_count,
        "load_1": load_avg[0],
        "load_5": load_avg[1],
        "load_15": load_avg[2],
    }


def _collect_memory(psutil: Any) -> dict[str, Any]:
    vm = psutil.virtual_memory()
    return {
        "total": vm.total,
        "available": vm.available,
        "used": vm.used,
        "percent": vm.percent,
    }


def _collect_disks(psutil: Any) -> list[dict[str, Any]]:
    disks: list[dict[str, Any]] = []
    seen_mounts: set[str] = set()
    # Only report the root mount + /app/data mount if distinct.
    for path in ("/", "/app/data"):
        try:
            if not os.path.exists(path):
                continue
            du = psutil.disk_usage(path)
            key = path
            if key in seen_mounts:
                continue
            seen_mounts.add(key)
            disks.append(
                {
                    "path": path,
                    "total": du.total,
                    "used": du.used,
                    "free": du.free,
                    "percent": du.percent,
                }
            )
        except OSError as exc:
            logger.warning("Failed collecting disk usage for %s: %s", path, exc)
            continue
    return disks


_proc: Any = None
_proc_lock = threading.Lock()


def _sample_process_cpu(psutil: Any) -> tuple[Any, float]:
    """Return ``(proc, cpu%)`` from a persistent Process.

    psutil's ``cpu_percent(None)`` reports usage since the previous call on the
    *same* object, so a fresh Process per request would always read 0.0. The
    first sample after boot is a priming 0.0."""
    global _proc
    with _proc_lock:
        if _proc is None:
            _proc = psutil.Process()
            _proc.cpu_percent(None)
        return _proc, _proc.cpu_percent(interval=None)


def _collect_process(psutil: Any) -> tuple[dict[str, Any], float]:
    """Return ``(process_info, now)``; ``now`` is the single wall-clock read used
    for both the process uptime and the response ``timestamp`` field."""
    try:
        proc, p_cpu = _sample_process_cpu(psutil)
        p_rss = proc.memory_info().rss
        p_threads = proc.num_threads()
        try:
            p_fds = proc.num_fds()  # POSIX only
        except (AttributeError, OSError):
            p_fds = None
        p_create = proc.create_time()
    except psutil.Error as exc:
        logger.warning("Failed collecting process metrics for host stats: %s", exc)
        p_rss = p_cpu = p_threads = p_create = 0
        p_fds = None

    now = time.time()
    process_info = {
        "rss": p_rss,
        "cpu_percent": p_cpu,
        "threads": p_threads,
        "fds": p_fds,
        "uptime_seconds": int(now - p_create) if p_create else 0,
    }
    return process_info, now


def admin_host_metrics_response() -> dict[str, Any]:
    """Return real-time host metrics: CPU / memory / disk / load / process.

    Degrades gracefully if psutil is unavailable (returns {"available": False, ...}).
    """
    try:
        import psutil
    except ImportError:
        logger.warning("psutil not installed; host metrics unavailable", exc_info=True)
        return {"available": False, "reason": "psutil not installed"}

    try:
        # Order preserved: CPU first (its interval=0.1 sample dominates), then
        # memory/disks, then process — whose read also stamps ``timestamp``.
        cpu = _collect_cpu(psutil)
        memory = _collect_memory(psutil)
        disks = _collect_disks(psutil)
        process_info, now = _collect_process(psutil)
        return {
            "available": True,
            "timestamp": now,
            "cpu": cpu,
            "memory": memory,
            "disks": disks,
            "process": process_info,
        }
    except Exception as exc:  # pragma: no cover - defensive
        logger.exception("Failed to collect host metrics")
        return {"available": False, "reason": str(exc)}


def admin_user_usage_response(user_id: str, range_: str = "24h") -> dict[str, Any]:
    """Return per-type usage (calls/cost/tokens) for a user, filtered by range.

    range_: "24h" | "7d" | "30d" | "all"
    """
    from ..quota_service import get_user_usage_range

    range_seconds = {
        "24h": 86400,
        "7d": 604800,
        "30d": 2592000,
        "all": None,
    }
    if range_ not in range_seconds:
        raise HTTPException(status_code=400, detail=f"Invalid range: {range_}")

    secs = range_seconds[range_]
    if secs is None:
        since_iso = None
    else:
        cutoff = datetime.now(UTC).timestamp() - secs
        since_iso = datetime.fromtimestamp(cutoff, tz=UTC).isoformat()

    data = get_user_usage_range(user_id, since_iso=since_iso)
    data["range"] = range_
    return data


def admin_logs_response(
    *,
    log_getter: MemLogGetter,
    n: int,
    level: str | None,
) -> dict[str, Any]:
    return {"logs": log_getter(n=n, level=level or None)}
