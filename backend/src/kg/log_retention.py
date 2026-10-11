"""Log-retention pruner for the 5 SQLite log singletons.

Each ``prune_*`` function deletes rows older than ``days`` from a single
log database and returns ``(deleted_count, remaining_count)``. The pruners
go through the existing module-level connection singletons so they respect
the test ``KG_DATA_DIR`` redirection and never bypass schema migrations.

Scheduled pruning runs in the backend process (``log_retention_scheduler``);
the CLI entry point below is for manual operator runs against the same code:

    uv run python -m kg.log_retention --all
    uv run python -m kg.log_retention --pipeline --days 30
    uv run python -m kg.log_retention --judge --translate
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from collections.abc import Callable
from datetime import UTC, datetime, timedelta

from . import judge_log, llm_error_log, pipeline_log, token_tracker, translate_log
from .sentry_init import init_sentry

_logger = logging.getLogger(__name__)

# Default retention windows (days). These match the brief.
DEFAULT_DAYS_PIPELINE = 30
DEFAULT_DAYS_JUDGE = 60
DEFAULT_DAYS_TRANSLATE = 14
DEFAULT_DAYS_TOKEN = 90
DEFAULT_DAYS_LLM_ERRORS = 30

# Rows removed per DELETE statement (see _prune_table). Bounds how long a single
# batch holds the log lock, so the first run on a large backlog stays well inside
# docker stop's 10s grace period.
DELETE_BATCH_SIZE = 5000


class RetentionStopped(RuntimeError):
    """A stop was requested between batches; rows already committed stay deleted."""


def _env_days(var: str, fallback: int) -> int:
    """Read ``<VAR>_RETENTION_DAYS`` env override; fall back to ``fallback``.

    Invalid / non-positive values are ignored (logged via ``ValueError`` only
    when negative — non-int falls through silently to keep production safe).
    """
    raw = os.environ.get(var)
    if not raw:
        return fallback
    try:
        days = int(raw)
    except ValueError:
        _logger.warning("Silently handled exception; using fallback response", exc_info=True)
        return fallback
    if days <= 0:
        return fallback
    return days


# log kind → (env var, hardcoded default)
_RETENTION: dict[str, tuple[str, int]] = {
    "pipeline": ("PIPELINE_LOG_RETENTION_DAYS", DEFAULT_DAYS_PIPELINE),
    "judge": ("JUDGE_LOG_RETENTION_DAYS", DEFAULT_DAYS_JUDGE),
    "translate": ("TRANSLATE_LOG_RETENTION_DAYS", DEFAULT_DAYS_TRANSLATE),
    "token": ("TOKEN_USAGE_RETENTION_DAYS", DEFAULT_DAYS_TOKEN),
    "llm_error": ("LLM_ERROR_LOG_RETENTION_DAYS", DEFAULT_DAYS_LLM_ERRORS),
}


def _effective_days(kind: str, override: int | None) -> int:
    """Resolve the day-count actually applied for a log kind.

    An explicit ``override`` wins; otherwise the kind's ``*_RETENTION_DAYS``
    env var, then its ``DEFAULT_DAYS_*``. Mirrors the resolution each pruner
    does internally for ``days=None`` — used so ``run_all()`` / CLI reports
    show the window that was really applied.
    """
    if override is not None:
        return override
    var, fallback = _RETENTION[kind]
    return _env_days(var, fallback)


def _cutoff(days: int) -> str:
    """Return ISO8601 UTC cutoff timestamp for ``days`` ago.

    All log databases store timestamps as ISO8601 UTC strings, which sort
    lexicographically — so a plain ``WHERE col < cutoff`` is correct.
    """
    if days < 0:
        raise ValueError("days must be >= 0")
    return (datetime.now(UTC) - timedelta(days=days)).isoformat()


def _prune_table(
    log,
    table: str,
    column: str,
    cutoff: str,
    should_stop: Callable[[], bool] | None,
) -> tuple[int, int]:
    """Delete rows older than ``cutoff`` in bounded batches, then count what remains.

    ``log`` is one of the log singletons. Each batch takes its ``_lock``, runs
    one ``DELETE`` of at most ``DELETE_BATCH_SIZE`` rows, commits, and releases
    the lock, so a large first-run backlog never holds the log lock for its
    whole length and writers can interleave between batches. ``should_stop`` is
    checked before every batch: shutdown ends a long backlog at a batch boundary.
    """
    deleted = 0
    while True:
        if should_stop is not None and should_stop():
            raise RetentionStopped(f"{table}: stop requested after {deleted} rows")
        with log._lock:
            conn = log._get_conn()
            cur = conn.execute(
                f"DELETE FROM {table} WHERE rowid IN (SELECT rowid FROM {table} WHERE {column} < ? LIMIT ?)",
                (cutoff, DELETE_BATCH_SIZE),
            )
            batch = cur.rowcount or 0
            conn.commit()
        deleted += batch
        if batch < DELETE_BATCH_SIZE:
            break
    with log._lock:
        remaining = log._get_conn().execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    return deleted, remaining


# ─────────────────────────────────────────────────────────────────────────────
# Per-DB pruners
# ─────────────────────────────────────────────────────────────────────────────


def prune_pipeline_log(days: int | None = None, *, should_stop: Callable[[], bool] | None = None) -> tuple[int, int]:
    """Delete pipeline_runs rows whose ``started_at`` is older than ``days``.

    When ``days`` is ``None``, falls back to ``PIPELINE_LOG_RETENTION_DAYS``
    env var, then ``DEFAULT_DAYS_PIPELINE``.
    """
    if days is None:
        days = _env_days("PIPELINE_LOG_RETENTION_DAYS", DEFAULT_DAYS_PIPELINE)
    cutoff = _cutoff(days)
    return _prune_table(pipeline_log, "pipeline_runs", "started_at", cutoff, should_stop)


def prune_judge_log(days: int | None = None, *, should_stop: Callable[[], bool] | None = None) -> tuple[int, int]:
    """Delete judge_log rows whose ``created_at`` is older than ``days``.

    When ``days`` is ``None``, falls back to ``JUDGE_LOG_RETENTION_DAYS``
    env var, then ``DEFAULT_DAYS_JUDGE``.
    """
    if days is None:
        days = _env_days("JUDGE_LOG_RETENTION_DAYS", DEFAULT_DAYS_JUDGE)
    cutoff = _cutoff(days)
    return _prune_table(judge_log, "judge_log", "created_at", cutoff, should_stop)


def prune_translate_log(days: int | None = None, *, should_stop: Callable[[], bool] | None = None) -> tuple[int, int]:
    """Delete translate_log rows whose ``created_at`` is older than ``days``.

    When ``days`` is ``None``, falls back to ``TRANSLATE_LOG_RETENTION_DAYS``
    env var, then ``DEFAULT_DAYS_TRANSLATE``.
    """
    if days is None:
        days = _env_days("TRANSLATE_LOG_RETENTION_DAYS", DEFAULT_DAYS_TRANSLATE)
    cutoff = _cutoff(days)
    return _prune_table(translate_log, "translate_log", "created_at", cutoff, should_stop)


def prune_translate_cache_hits(
    days: int | None = None, *, should_stop: Callable[[], bool] | None = None
) -> tuple[int, int]:
    """Delete translate_cache_hits rows whose ``created_at`` is older than ``days``.

    Reuses the translate-log retention window: when ``days`` is ``None``,
    falls back to ``TRANSLATE_LOG_RETENTION_DAYS`` env var, then
    ``DEFAULT_DAYS_TRANSLATE``. This table records one row per translate cache
    hit (`translate_log.record_cache_hit`) and is only read by admin
    observability counters, so without this pruner it grows monotonically.
    """
    if days is None:
        days = _env_days("TRANSLATE_LOG_RETENTION_DAYS", DEFAULT_DAYS_TRANSLATE)
    cutoff = _cutoff(days)
    return _prune_table(translate_log, "translate_cache_hits", "created_at", cutoff, should_stop)


def prune_token_usage(days: int | None = None, *, should_stop: Callable[[], bool] | None = None) -> tuple[int, int]:
    """Delete token_usage rows whose ``created_at`` is older than ``days``.

    When ``days`` is ``None``, falls back to ``TOKEN_USAGE_RETENTION_DAYS``
    env var, then ``DEFAULT_DAYS_TOKEN``.
    """
    if days is None:
        days = _env_days("TOKEN_USAGE_RETENTION_DAYS", DEFAULT_DAYS_TOKEN)
    cutoff = _cutoff(days)
    return _prune_table(token_tracker, "token_usage", "created_at", cutoff, should_stop)


def prune_llm_errors(days: int | None = None, *, should_stop: Callable[[], bool] | None = None) -> tuple[int, int]:
    """Delete llm_errors rows whose ``created_at`` is older than ``days``.

    When ``days`` is ``None``, falls back to ``LLM_ERROR_LOG_RETENTION_DAYS``
    env var, then ``DEFAULT_DAYS_LLM_ERRORS``.
    """
    if days is None:
        days = _env_days("LLM_ERROR_LOG_RETENTION_DAYS", DEFAULT_DAYS_LLM_ERRORS)
    cutoff = _cutoff(days)
    return _prune_table(llm_error_log, "llm_errors", "created_at", cutoff, should_stop)


# ─────────────────────────────────────────────────────────────────────────────
# Aggregate
# ─────────────────────────────────────────────────────────────────────────────


def run_all(
    *,
    pipeline_days: int | None = None,
    judge_days: int | None = None,
    translate_days: int | None = None,
    token_days: int | None = None,
    llm_error_days: int | None = None,
    should_stop: Callable[[], bool] | None = None,
) -> dict[str, dict[str, int]]:
    """Run every pruner and return a structured report.

    A ``None`` day-count (the default) lets each pruner resolve its own
    ``*_RETENTION_DAYS`` env override, falling back to ``DEFAULT_DAYS_*``.
    Pass an explicit int to force a window regardless of env. The admin
    endpoint and CLI ``--all`` both route through here, so ``None`` is what
    makes those paths honour the env vars. ``should_stop`` is polled between
    batches; when it returns true the run raises ``RetentionStopped``.
    """
    report: dict[str, dict[str, int]] = {}

    deleted, remaining = prune_pipeline_log(pipeline_days, should_stop=should_stop)
    report["pipeline_log"] = {
        "deleted": deleted,
        "remaining": remaining,
        "days": _effective_days("pipeline", pipeline_days),
    }

    deleted, remaining = prune_judge_log(judge_days, should_stop=should_stop)
    report["judge_log"] = {"deleted": deleted, "remaining": remaining, "days": _effective_days("judge", judge_days)}

    deleted, remaining = prune_translate_log(translate_days, should_stop=should_stop)
    report["translate_log"] = {
        "deleted": deleted,
        "remaining": remaining,
        "days": _effective_days("translate", translate_days),
    }

    # Shares the translate-log retention window (TRANSLATE_LOG_RETENTION_DAYS).
    deleted, remaining = prune_translate_cache_hits(translate_days, should_stop=should_stop)
    report["translate_cache_hits"] = {
        "deleted": deleted,
        "remaining": remaining,
        "days": _effective_days("translate", translate_days),
    }

    deleted, remaining = prune_token_usage(token_days, should_stop=should_stop)
    report["token_usage"] = {"deleted": deleted, "remaining": remaining, "days": _effective_days("token", token_days)}

    deleted, remaining = prune_llm_errors(llm_error_days, should_stop=should_stop)
    report["llm_errors"] = {
        "deleted": deleted,
        "remaining": remaining,
        "days": _effective_days("llm_error", llm_error_days),
    }

    return report


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="kg.log_retention",
        description="Prune old rows from KG log SQLite databases.",
    )
    parser.add_argument(
        "--all", action="store_true", help="Prune every log DB (honours *_RETENTION_DAYS env, else built-in defaults)."
    )
    parser.add_argument("--pipeline", action="store_true", help="Prune pipeline_runs.db.")
    parser.add_argument("--judge", action="store_true", help="Prune judge_log.db.")
    parser.add_argument("--translate", action="store_true", help="Prune translate_log.db.")
    parser.add_argument("--token", action="store_true", help="Prune token_usage.db.")
    parser.add_argument("--llm-error", action="store_true", help="Prune llm_errors.db.")
    parser.add_argument(
        "--days",
        type=int,
        default=None,
        help="Override retention window (days), bypassing *_RETENTION_DAYS env. Applies to every selected target.",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON to stdout.")
    return parser


def _run_from_args(args: argparse.Namespace) -> dict[str, dict[str, int]]:
    report: dict[str, dict[str, int]] = {}

    # args.days is None unless --days was passed. Forwarding None lets each
    # pruner resolve its *_RETENTION_DAYS env var; an explicit --days forces
    # the window. Either way the report shows the window actually applied.
    if args.all:
        return run_all(
            pipeline_days=args.days,
            judge_days=args.days,
            translate_days=args.days,
            token_days=args.days,
            llm_error_days=args.days,
        )

    if args.pipeline:
        d, r = prune_pipeline_log(args.days)
        report["pipeline_log"] = {"deleted": d, "remaining": r, "days": _effective_days("pipeline", args.days)}
    if args.judge:
        d, r = prune_judge_log(args.days)
        report["judge_log"] = {"deleted": d, "remaining": r, "days": _effective_days("judge", args.days)}
    if args.translate:
        d, r = prune_translate_log(args.days)
        report["translate_log"] = {"deleted": d, "remaining": r, "days": _effective_days("translate", args.days)}
        # translate_cache_hits shares the translate window — prune it alongside.
        d, r = prune_translate_cache_hits(args.days)
        report["translate_cache_hits"] = {"deleted": d, "remaining": r, "days": _effective_days("translate", args.days)}
    if args.token:
        d, r = prune_token_usage(args.days)
        report["token_usage"] = {"deleted": d, "remaining": r, "days": _effective_days("token", args.days)}
    if getattr(args, "llm_error", False):
        d, r = prune_llm_errors(args.days)
        report["llm_errors"] = {"deleted": d, "remaining": r, "days": _effective_days("llm_error", args.days)}

    return report


def main(argv: list[str] | None = None) -> int:
    init_sentry(job="log_retention")
    parser = _build_parser()
    args = parser.parse_args(argv)

    targets = (args.all, args.pipeline, args.judge, args.translate, args.token, getattr(args, "llm_error", False))
    if not any(targets):
        parser.print_help(sys.stderr)
        return 2

    report = _run_from_args(args)

    if args.json:
        print(json.dumps(report))
    else:
        for name, info in report.items():
            print(f"{name}: deleted={info['deleted']} remaining={info['remaining']} (>{info['days']}d)")

    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
