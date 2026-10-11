"""Site-wide observability aggregation for admin dashboard.

Aggregates metrics across all users by querying:
  - pipeline_runs.db (pipeline_log)  — failure rate, per-step p95 latency
  - judge_log.db                     — rejection rate
  - translate_log.db                 — cache hit rate
  - token_usage.db (token_tracker)   — daily token spend (7 days)

All aggregations use a 24h window, except daily_token_spend which uses 7 days.
``log_db_health`` additionally reads llm_errors.db and flags tables whose
oldest row shows the daily log-retention prune is not running.
"""

from __future__ import annotations

import json
import math
from datetime import UTC, datetime, timedelta
from typing import Any

_WINDOW_24H = 24
_SPEND_DAYS = 7


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _cutoff_iso(hours: int) -> str:
    return (_utcnow() - timedelta(hours=hours)).isoformat()


def _utc_instant_cutoff_bounds(cutoff_iso: str) -> tuple[str, str]:
    """Return an indexed candidate bound and an exact UTC-instant cutoff.

    SQLite's plain ISO-text comparison is lexical, so a fixed-offset timestamp
    can compare newer while representing an older UTC instant. The previous
    UTC date is conservative for ISO-8601 offsets and keeps the timestamp
    column's indexed lower-bound predicate; ``julianday`` then does the exact
    instant comparison.
    """
    cutoff = datetime.fromisoformat(cutoff_iso)
    candidate_bound = (cutoff.date() - timedelta(days=1)).isoformat()
    return candidate_bound, cutoff_iso


def _utc_instant_predicate(column: str) -> str:
    """Build the internal SQL predicate for an ISO-8601 UTC instant column."""
    return f"{column} >= ? AND julianday({column}) >= julianday(?)"


def _cell(row: Any, idx: int = 0) -> int:
    """Read column ``idx`` of a ``fetchone()`` result as int, NULL/None → 0."""
    return (row[idx] or 0) if row else 0


def _ratio(numerator: int, total: int) -> float | None:
    """Round ``numerator/total`` to 4 dp; ``None`` when ``total`` is 0."""
    return round(numerator / total, 4) if total > 0 else None


def _percentile(values: list[float], pct: float) -> float | None:
    """Nearest-rank percentile (no interpolation) for a list of numbers.

    pct is in [0, 100].  Returns None for empty input.
    """
    if not values:
        return None
    s = sorted(values)
    if pct <= 0:
        return s[0]
    if pct >= 100:
        return s[-1]
    # nearest-rank: rank = ceil(p/100 * N)
    rank = max(1, math.ceil(pct / 100.0 * len(s)))
    return s[rank - 1]


# ---------------------------------------------------------------------------
# pipeline_log aggregations
# ---------------------------------------------------------------------------


def _pipeline_failure_rate_24h() -> dict[str, Any]:
    """Count failed vs total pipeline runs in the last 24h.

    Excludes runs still 'running' (use ended runs only). A run counts in the
    window if its ``started_at`` falls within the 24h cutoff.
    """
    from . import error_signals as es
    from . import pipeline_log as pl

    candidate_bound, cutoff = _utc_instant_cutoff_bounds(_cutoff_iso(_WINDOW_24H))
    with pl._lock:
        conn = pl._get_conn()
        # Count terminal-state runs in window (exclude running/interrupted).
        # 失敗判定走 error_signals SoT —— 站台監控與 admin_trends/ops trends 同義。
        row = conn.execute(
            "SELECT "
            "  COUNT(*) AS total, "
            f"  SUM(CASE WHEN {es.PIPELINE_FAILURE_WHERE} THEN 1 ELSE 0 END) AS failed "
            "FROM pipeline_runs "
            f"WHERE {_utc_instant_predicate('started_at')} "
            f"AND {es.PIPELINE_TERMINAL_WHERE}",
            (candidate_bound, cutoff),
        ).fetchone()
    total = _cell(row, 0)
    failed = _cell(row, 1)
    return {
        "total": total,
        "failed": failed,
        "rate": _ratio(failed, total),
        "window_hours": _WINDOW_24H,
    }


def _pipeline_step_p95_24h() -> dict[str, Any]:
    """Compute per-step p95 (ms) over the last 24h.

    Parses the ``steps`` JSON column from each run started in window. Skips
    steps without both ``started_at`` and ``ended_at``.

    Scale note: Python-side parse, O(N); assumes < 10k runs/24h. 大流量需改
    SQL 物化視圖（pre-aggregated step durations table + scheduled refresh）。
    """
    from . import pipeline_log as pl

    candidate_bound, cutoff = _utc_instant_cutoff_bounds(_cutoff_iso(_WINDOW_24H))
    with pl._lock:
        conn = pl._get_conn()
        rows = conn.execute(
            f"SELECT steps FROM pipeline_runs WHERE {_utc_instant_predicate('started_at')}",
            (candidate_bound, cutoff),
        ).fetchall()

    by_step: dict[str, list[float]] = {}
    for (steps_json,) in rows:
        try:
            steps = json.loads(steps_json or "[]")
        except json.JSONDecodeError:
            continue
        for step in steps:
            name = step.get("name")
            s_at = step.get("started_at")
            e_at = step.get("ended_at")
            if not name or not s_at or not e_at:
                continue
            try:
                s_dt = datetime.fromisoformat(s_at)
                e_dt = datetime.fromisoformat(e_at)
            except (ValueError, TypeError):
                continue
            dur_ms = (e_dt - s_dt).total_seconds() * 1000.0
            if dur_ms < 0:
                continue
            by_step.setdefault(name, []).append(dur_ms)

    steps_out = []
    for name, samples in by_step.items():
        p95 = _percentile(samples, 95.0)
        steps_out.append(
            {
                "name": name,
                "count": len(samples),
                "p95_ms": round(p95, 1) if p95 is not None else None,
                "max_ms": round(max(samples), 1),
            }
        )
    # sort descending by p95 so slowest steps surface first
    steps_out.sort(key=lambda d: d["p95_ms"] or 0, reverse=True)
    return {"steps": steps_out, "window_hours": _WINDOW_24H}


# ---------------------------------------------------------------------------
# judge_log aggregations
# ---------------------------------------------------------------------------


def _judge_rejection_rate_24h() -> dict[str, Any]:
    """Auto-judge rejection rate (source='auto') over the last 24h."""
    from . import error_signals as es
    from . import judge_log as jl

    candidate_bound, cutoff = _utc_instant_cutoff_bounds(_cutoff_iso(_WINDOW_24H))
    with jl._lock:
        conn = jl._get_conn()
        # auto-judge reject 判定走 error_signals SoT 原子謂詞 + judge_log degree_cap。
        row = conn.execute(
            "SELECT COUNT(*) AS total, "
            f"       SUM(CASE WHEN {es.JUDGE_REJECTED_WHERE} THEN 1 ELSE 0 END) AS rejected "
            "FROM judge_log "
            f"WHERE {es.JUDGE_AUTO_SOURCE_WHERE} AND "
            f"{_utc_instant_predicate('created_at')} "
            f"  AND {jl.DEGREE_CAP_EXCLUSION_SQL}",
            (candidate_bound, cutoff),
        ).fetchone()
    total = _cell(row, 0)
    rejected = _cell(row, 1)
    return {
        "total": total,
        "rejected": rejected,
        "rate": _ratio(rejected, total),
        "window_hours": _WINDOW_24H,
    }


# ---------------------------------------------------------------------------
# translate_log aggregations
# ---------------------------------------------------------------------------


def _translate_cache_hit_rate_24h() -> dict[str, Any]:
    """Precise cache hit rate over the last 24h.

    Sources:
      - hits   = COUNT(translate_cache_hits) — incremented on every cache
                 short-circuit by translate_service via record_cache_hit().
      - misses = COUNT(translate_log)        — one row per LLM call (cache miss).

        rate = hits / (hits + misses)

    Both tables share translate_log.db so the read is one connection.
    """
    from . import translate_log as tl

    candidate_bound, cutoff = _utc_instant_cutoff_bounds(_cutoff_iso(_WINDOW_24H))
    with tl._lock:
        conn = tl._get_conn()
        misses_row = conn.execute(
            f"SELECT COUNT(*) FROM translate_log WHERE {_utc_instant_predicate('created_at')}",
            (candidate_bound, cutoff),
        ).fetchone()
        hits_row = conn.execute(
            f"SELECT COUNT(*) FROM translate_cache_hits WHERE {_utc_instant_predicate('created_at')}",
            (candidate_bound, cutoff),
        ).fetchone()
    misses = _cell(misses_row)
    hits = _cell(hits_row)
    total = hits + misses
    return {
        "hits": hits,
        "misses": misses,
        "total": total,
        "rate": _ratio(hits, total),
        "window_hours": _WINDOW_24H,
        "note": "precise counter: hits from translate_cache_hits, misses from translate_log",
    }


# ---------------------------------------------------------------------------
# token spend
# ---------------------------------------------------------------------------


def _daily_token_spend_7d() -> dict[str, Any]:
    """Per-day total tokens (input+output) for the last 7 UTC days.

    Returns 7 buckets aligned to UTC date (oldest first). Empty days are
    included with tokens=0 so charts stay aligned.
    """
    from . import token_tracker as tt

    today_utc = _utcnow().date()
    cutoff_date = today_utc - timedelta(days=_SPEND_DAYS - 1)  # 7 buckets inclusive
    cutoff_iso = datetime.combine(cutoff_date, datetime.min.time(), tzinfo=UTC).isoformat()
    candidate_bound, cutoff_iso = _utc_instant_cutoff_bounds(cutoff_iso)

    with tt._lock:
        conn = tt._get_conn()
        rows = conn.execute(
            "SELECT substr(created_at, 1, 10) AS d, "
            "       SUM(input_tokens) AS ti, "
            "       SUM(output_tokens) AS to_ "
            "FROM token_usage "
            f"WHERE {_utc_instant_predicate('created_at')} "
            "GROUP BY d "
            "ORDER BY d",
            (candidate_bound, cutoff_iso),
        ).fetchall()

    by_day: dict[str, dict[str, int]] = {}
    for d, ti, to_ in rows:
        if not d:
            continue
        by_day[d] = {"input": int(ti or 0), "output": int(to_ or 0)}

    days_out = []
    for i in range(_SPEND_DAYS):
        d = cutoff_date + timedelta(days=i)
        key = d.isoformat()
        entry = by_day.get(key, {"input": 0, "output": 0})
        days_out.append(
            {
                "date": key,
                "input": entry["input"],
                "output": entry["output"],
                "tokens": entry["input"] + entry["output"],
            }
        )
    total = sum(d["tokens"] for d in days_out)
    return {"days": days_out, "total": total}


# ---------------------------------------------------------------------------
# log DB health (row_count + oldest)
# ---------------------------------------------------------------------------


def _table_health(conn, table: str, ts_col: str) -> dict[str, Any]:
    """Return ``{row_count, oldest_created_at}`` for one log table.

    ``COUNT(*)`` is acceptable here: every persistent log table is bounded by
    log_retention pruning (daily job, or ``admin_log_retention_run``) and indexed on its
    timestamp column, so even the busiest table stays small. ``oldest`` uses
    ``MIN(ts_col)`` so an operator can see how far back un-pruned rows reach.
    Table/column names are module-internal literals (never user input).
    """
    try:
        count = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        oldest = conn.execute(f"SELECT MIN({ts_col}) FROM {table}").fetchone()[0]
    except Exception:  # noqa: BLE001 — health probe must never break the panel
        return {"row_count": None, "oldest_created_at": None}
    return {"row_count": int(count or 0), "oldest_created_at": oldest}


# log_db_health table → the log_retention kind whose window prunes it
# (translate_cache_hits shares the translate window, as in ``run_all``).
_RETENTION_KIND = {
    "pipeline_runs": "pipeline",
    "judge_log": "judge",
    "translate_log": "translate",
    "translate_cache_hits": "translate",
    "token_usage": "token",
    "llm_errors": "llm_error",
}

# A daily prune keeps the oldest row within one window (+1 day). A row older
# than this many windows means at least a whole window of runs was missed.
_OVERDUE_WINDOWS = 2


def _retention_status(oldest: str | None, kind: str) -> dict[str, Any]:
    """Return ``{retention_days, overdue}`` for a table's oldest timestamp.

    ``retention_days`` is the window the pruner applies (``*_RETENTION_DAYS``
    env, else its default). The ISO-8601 text comparison is deliberately the
    pruner's own ``WHERE col < cutoff``, so a table flagged overdue is always
    one a retention run would clear.
    """
    from .log_retention import _effective_days

    days = _effective_days(kind, None)
    overdue = oldest is not None and oldest < _cutoff_iso(_OVERDUE_WINDOWS * days * 24)
    return {"retention_days": days, "overdue": overdue}


def _log_db_health() -> dict[str, Any]:
    """Per-table row_count, oldest timestamp and retention status of every log DB.

    Covers every table ``log_retention.run_all`` prunes (scheduled daily
    in-process by ``log_retention_scheduler.LogRetentionScheduler``). ``overdue`` means the oldest row
    is older than ``_OVERDUE_WINDOWS`` × the table's retention window, i.e.
    the scheduled prune is not running.
    Note: pipeline_runs keys its timestamp as ``started_at``; the others use
    ``created_at`` — both surface under ``oldest_created_at`` for a uniform shape.
    """
    from . import judge_log as jl
    from . import llm_error_log as el
    from . import pipeline_log as pl
    from . import token_tracker as tt
    from . import translate_log as tl

    out: dict[str, Any] = {}
    with pl._lock:
        out["pipeline_runs"] = _table_health(pl._get_conn(), "pipeline_runs", "started_at")
    with jl._lock:
        out["judge_log"] = _table_health(jl._get_conn(), "judge_log", "created_at")
    with tl._lock:
        conn = tl._get_conn()
        out["translate_log"] = _table_health(conn, "translate_log", "created_at")
        out["translate_cache_hits"] = _table_health(conn, "translate_cache_hits", "created_at")
    with tt._lock:
        out["token_usage"] = _table_health(tt._get_conn(), "token_usage", "created_at")
    with el._lock:
        out["llm_errors"] = _table_health(el._get_conn(), "llm_errors", "created_at")
    for table, kind in _RETENTION_KIND.items():
        out[table] |= _retention_status(out[table]["oldest_created_at"], kind)
    return out


# ---------------------------------------------------------------------------
# public entrypoint
# ---------------------------------------------------------------------------


def collect_observability() -> dict[str, Any]:
    """Aggregate all observability metrics into a single response payload.

    All timestamps and date buckets are UTC; ``tz`` declares this so downstream
    consumers never reinterpret ``substr(created_at,1,10)`` date cuts as local.
    ``log_retention_overdue`` lists the ``log_db_health`` tables flagged overdue.
    """
    log_db_health = _log_db_health()
    return {
        "translate_cache_hit_rate_24h": _translate_cache_hit_rate_24h(),
        "pipeline_step_p95_24h": _pipeline_step_p95_24h(),
        "pipeline_failure_rate_24h": _pipeline_failure_rate_24h(),
        "judge_rejection_rate_24h": _judge_rejection_rate_24h(),
        "daily_token_spend_7d": _daily_token_spend_7d(),
        "log_db_health": log_db_health,
        "log_retention_overdue": [table for table, health in log_db_health.items() if health["overdue"]],
        "tz": "UTC",
        "generated_at": _utcnow().isoformat(),
    }
