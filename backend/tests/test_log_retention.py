"""Tests for log_retention module — prune old rows from the 5 log SQLite singletons."""

from __future__ import annotations

import json
import subprocess
import sys
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from kg import judge_log, llm_error_log, log_retention, pipeline_log, token_tracker, translate_log

# ─────────────────────────────────────────────────────────────────────────────
# Fixtures — redirect every log DB into tmp_path and reset singletons.
# ─────────────────────────────────────────────────────────────────────────────


@pytest.fixture()
def isolated_logs(tmp_path, monkeypatch):
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))

    monkeypatch.setattr(pipeline_log, "DATA_DIR", tmp_path)
    monkeypatch.setattr(pipeline_log, "DB_PATH", tmp_path / "pipeline_runs.db")
    monkeypatch.setattr(judge_log, "DATA_DIR", tmp_path)
    monkeypatch.setattr(judge_log, "DB_PATH", tmp_path / "judge_log.db")
    monkeypatch.setattr(token_tracker, "DATA_DIR", tmp_path)
    monkeypatch.setattr(token_tracker, "DB_PATH", tmp_path / "token_usage.db")
    monkeypatch.setattr(llm_error_log, "DATA_DIR", tmp_path)
    monkeypatch.setattr(llm_error_log, "DB_PATH", tmp_path / "llm_errors.db")
    # translate_log resolves path via _db_path() each connect — env var alone is enough.

    pipeline_log._reset()
    judge_log._reset()
    translate_log._reset()
    llm_error_log._reset()
    if token_tracker._conn is not None:
        token_tracker._conn.close()
        token_tracker._conn = None

    yield tmp_path

    pipeline_log._reset()
    judge_log._reset()
    translate_log._reset()
    llm_error_log._reset()
    if token_tracker._conn is not None:
        token_tracker._conn.close()
        token_tracker._conn = None


def _iso(days_ago: float) -> str:
    return (datetime.now(UTC) - timedelta(days=days_ago)).isoformat()


# ─────────────────────────────────────────────────────────────────────────────
# pipeline_log
# ─────────────────────────────────────────────────────────────────────────────


def _insert_pipeline_row(started_at: str, run_id: str | None = None) -> None:
    conn = pipeline_log._get_conn()
    conn.execute(
        "INSERT INTO pipeline_runs (run_id, user_id, notebook_id, trigger, started_at, ended_at, status, steps) "
        "VALUES (?, ?, ?, ?, ?, ?, 'completed', '[]')",
        (run_id or "r_" + uuid.uuid4().hex[:8], "u1", "nb1", "auto", started_at, started_at),
    )
    conn.commit()


def test_prune_pipeline_log_drops_only_old_rows(isolated_logs):
    _insert_pipeline_row(_iso(40))  # old
    _insert_pipeline_row(_iso(31))  # old
    _insert_pipeline_row(_iso(29))  # recent
    _insert_pipeline_row(_iso(1))  # recent

    deleted, remaining = log_retention.prune_pipeline_log(days=30)

    assert deleted == 2
    assert remaining == 2
    count = pipeline_log._get_conn().execute("SELECT COUNT(*) FROM pipeline_runs").fetchone()[0]
    assert count == 2


def test_prune_pipeline_log_noop_when_empty(isolated_logs):
    deleted, remaining = log_retention.prune_pipeline_log(days=30)
    assert deleted == 0
    assert remaining == 0


def test_prune_pipeline_log_preserves_index(isolated_logs):
    _insert_pipeline_row(_iso(40))
    log_retention.prune_pipeline_log(days=30)
    rows = (
        pipeline_log._get_conn()
        .execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='pipeline_runs'")
        .fetchall()
    )
    names = {r[0] for r in rows}
    assert "idx_pr_started" in names


# ─────────────────────────────────────────────────────────────────────────────
# judge_log
# ─────────────────────────────────────────────────────────────────────────────


def _insert_judge_row(created_at: str) -> None:
    conn = judge_log._get_conn()
    conn.execute(
        "INSERT INTO judge_log (user_id, notebook_id, from_id, to_id, similarity, "
        "verdict, confidence, accepted, source, created_at) "
        "VALUES ('u1', 'nb1', 'a', 'b', 0.8, 'related', 0.9, 1, 'auto', ?)",
        (created_at,),
    )
    conn.commit()


def test_prune_judge_log_drops_only_old_rows(isolated_logs):
    _insert_judge_row(_iso(80))  # old
    _insert_judge_row(_iso(61))  # old
    _insert_judge_row(_iso(59))  # recent
    _insert_judge_row(_iso(1))  # recent

    deleted, remaining = log_retention.prune_judge_log(days=60)

    assert deleted == 2
    assert remaining == 2


def test_prune_judge_log_preserves_index(isolated_logs):
    _insert_judge_row(_iso(80))
    log_retention.prune_judge_log(days=60)
    rows = (
        judge_log._get_conn()
        .execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='judge_log'")
        .fetchall()
    )
    names = {r[0] for r in rows}
    assert "idx_jl_created" in names


# ─────────────────────────────────────────────────────────────────────────────
# translate_log
# ─────────────────────────────────────────────────────────────────────────────


def _insert_translate_row(created_at: str) -> None:
    conn = translate_log._get_conn()
    conn.execute(
        "INSERT INTO translate_log (user_id, operation, word, context, context_hash, "
        "source_lang, target_lang, response_raw, latency_ms, created_at) "
        "VALUES ('u1', 'translate', 'word', 'ctx', 'h', 'en', 'zh', '{}', 100, ?)",
        (created_at,),
    )
    conn.commit()


def test_prune_translate_log_drops_only_old_rows(isolated_logs):
    _insert_translate_row(_iso(20))  # old
    _insert_translate_row(_iso(15))  # old
    _insert_translate_row(_iso(13))  # recent
    _insert_translate_row(_iso(1))  # recent

    deleted, remaining = log_retention.prune_translate_log(days=14)

    assert deleted == 2
    assert remaining == 2


def test_prune_translate_log_preserves_index(isolated_logs):
    _insert_translate_row(_iso(30))
    log_retention.prune_translate_log(days=14)
    rows = (
        translate_log._get_conn()
        .execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='translate_log'")
        .fetchall()
    )
    names = {r[0] for r in rows}
    assert "idx_tl_cache" in names
    assert "idx_tl_user" in names


def test_translate_log_has_bare_created_at_index(isolated_logs):
    """Fix A (R8#3): retention DELETE filters bare ``created_at``; without a
    ``(created_at)`` index SQLite full-scans. ``idx_tl_user`` leads with
    user_id so it can't serve a bare-created_at predicate."""
    translate_log._get_conn()  # force schema/index init
    rows = (
        translate_log._get_conn()
        .execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='translate_log'")
        .fetchall()
    )
    names = {r[0] for r in rows}
    assert "idx_tl_created" in names


# ─────────────────────────────────────────────────────────────────────────────
# translate_cache_hits — Fix B (R8#2): was never pruned → monotonic growth.
# ─────────────────────────────────────────────────────────────────────────────


def _insert_cache_hit_row(created_at: str) -> None:
    translate_log.record_cache_hit(
        user_id="u1",
        operation="translate",
        word="word",
        context_hash="h",
        source_lang="en",
        target_lang="zh",
    )
    # record_cache_hit stamps "now"; rewrite created_at to the desired age.
    conn = translate_log._get_conn()
    conn.execute(
        "UPDATE translate_cache_hits SET created_at=? WHERE id=(SELECT MAX(id) FROM translate_cache_hits)",
        (created_at,),
    )
    conn.commit()


def test_prune_translate_cache_hits_drops_only_old_rows(isolated_logs):
    _insert_cache_hit_row(_iso(20))  # old (>14d)
    _insert_cache_hit_row(_iso(15))  # old
    _insert_cache_hit_row(_iso(13))  # recent
    _insert_cache_hit_row(_iso(1))  # recent

    deleted, remaining = log_retention.prune_translate_cache_hits(days=14)

    assert deleted == 2
    assert remaining == 2


def test_prune_translate_cache_hits_reuses_translate_log_retention_env(isolated_logs, monkeypatch):
    """Fix B reuses ``TRANSLATE_LOG_RETENTION_DAYS`` — no new env/knob."""
    monkeypatch.setenv("TRANSLATE_LOG_RETENTION_DAYS", "3")
    _insert_cache_hit_row(_iso(4))  # >3d → pruned
    _insert_cache_hit_row(_iso(2))  # inside 3d → survives

    deleted, remaining = log_retention.prune_translate_cache_hits()  # env default

    assert deleted == 1
    assert remaining == 1


def test_prune_translate_cache_hits_safe_with_no_data(isolated_logs):
    translate_log._get_conn()  # force schema, no rows
    deleted, remaining = log_retention.prune_translate_cache_hits(days=14)
    assert deleted == 0
    assert remaining == 0


def test_prune_translate_cache_hits_preserves_index(isolated_logs):
    _insert_cache_hit_row(_iso(30))
    log_retention.prune_translate_cache_hits(days=14)
    rows = (
        translate_log._get_conn()
        .execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='translate_cache_hits'")
        .fetchall()
    )
    names = {r[0] for r in rows}
    assert "idx_tch_created" in names


# ─────────────────────────────────────────────────────────────────────────────
# token_usage
# ─────────────────────────────────────────────────────────────────────────────


def _insert_token_row(created_at: str) -> None:
    conn = token_tracker._get_conn()
    conn.execute(
        "INSERT INTO token_usage (user_id, call_type, input_tokens, output_tokens, created_at) "
        "VALUES ('u1', 'translate', 100, 50, ?)",
        (created_at,),
    )
    conn.commit()


def test_prune_token_usage_drops_only_old_rows(isolated_logs):
    _insert_token_row(_iso(120))  # old
    _insert_token_row(_iso(91))  # old
    _insert_token_row(_iso(89))  # recent
    _insert_token_row(_iso(1))  # recent

    deleted, remaining = log_retention.prune_token_usage(days=90)

    assert deleted == 2
    assert remaining == 2


def test_prune_token_usage_preserves_index(isolated_logs):
    _insert_token_row(_iso(120))
    log_retention.prune_token_usage(days=90)
    rows = (
        token_tracker._get_conn()
        .execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='token_usage'")
        .fetchall()
    )
    names = {r[0] for r in rows}
    assert "idx_user_created" in names


def test_token_usage_has_bare_created_at_index(isolated_logs):
    """Fix A (R8#3): both composite indexes lead with user_id, so the bare
    ``created_at`` retention DELETE full-scans. Needs a ``(created_at)`` index."""
    token_tracker._get_conn()  # force schema/index init
    rows = (
        token_tracker._get_conn()
        .execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='token_usage'")
        .fetchall()
    )
    names = {r[0] for r in rows}
    assert "idx_tu_created" in names


# ─────────────────────────────────────────────────────────────────────────────
# llm_errors
# ─────────────────────────────────────────────────────────────────────────────


def _insert_llm_error_row(created_at: str) -> None:
    conn = llm_error_log._get_conn()
    conn.execute(
        "INSERT INTO llm_errors (user_id, call_type, provider, model, error_class, status_code, message, created_at) "
        "VALUES ('u1', 'judge', 'gemini', 'm', 'RateLimitError', 429, 'rate limited', ?)",
        (created_at,),
    )
    conn.commit()


def test_prune_llm_errors_drops_only_old_rows(isolated_logs):
    _insert_llm_error_row(_iso(40))  # old
    _insert_llm_error_row(_iso(31))  # old
    _insert_llm_error_row(_iso(29))  # recent
    _insert_llm_error_row(_iso(1))  # recent

    deleted, remaining = log_retention.prune_llm_errors(days=30)

    assert deleted == 2
    assert remaining == 2


def test_prune_llm_errors_preserves_index(isolated_logs):
    _insert_llm_error_row(_iso(40))
    log_retention.prune_llm_errors(days=30)
    rows = (
        llm_error_log._get_conn()
        .execute("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='llm_errors'")
        .fetchall()
    )
    names = {r[0] for r in rows}
    assert "idx_le_created" in names


# ─────────────────────────────────────────────────────────────────────────────
# run_all
# ─────────────────────────────────────────────────────────────────────────────


def test_run_all_invokes_every_pruner(isolated_logs):
    _insert_pipeline_row(_iso(40))
    _insert_judge_row(_iso(80))
    _insert_translate_row(_iso(20))
    _insert_token_row(_iso(120))
    _insert_cache_hit_row(_iso(20))
    _insert_llm_error_row(_iso(40))

    report = log_retention.run_all()

    assert report["pipeline_log"]["deleted"] == 1
    assert report["judge_log"]["deleted"] == 1
    assert report["translate_log"]["deleted"] == 1
    assert report["token_usage"]["deleted"] == 1
    assert report["translate_cache_hits"]["deleted"] == 1
    assert report["llm_errors"]["deleted"] == 1
    # Defaults must match brief.
    assert report["pipeline_log"]["days"] == 30
    assert report["judge_log"]["days"] == 60
    assert report["translate_log"]["days"] == 14
    assert report["token_usage"]["days"] == 90
    # Fix B reuses the translate_log retention window.
    assert report["translate_cache_hits"]["days"] == 14
    assert report["llm_errors"]["days"] == 30


# ─────────────────────────────────────────────────────────────────────────────
# CLI entry
# ─────────────────────────────────────────────────────────────────────────────


def _cli_env(data_dir: Path) -> dict[str, str]:
    """subprocess env that exposes the in-tree ``kg`` package on PYTHONPATH."""
    src_dir = Path(__file__).resolve().parents[1] / "src"
    existing = __import__("os").environ
    extra_paths = [str(src_dir)]
    if existing.get("PYTHONPATH"):
        extra_paths.append(existing["PYTHONPATH"])
    return {
        **existing,
        "PYTHONPATH": ":".join(extra_paths),
        "KG_DATA_DIR": str(data_dir),
    }


def test_cli_all_flag_runs_every_pruner(isolated_logs):
    _insert_pipeline_row(_iso(40))
    _insert_judge_row(_iso(80))
    _insert_translate_row(_iso(20))
    _insert_token_row(_iso(120))
    _insert_llm_error_row(_iso(40))

    pipeline_log._reset()
    judge_log._reset()
    translate_log._reset()
    llm_error_log._reset()
    if token_tracker._conn is not None:
        token_tracker._conn.close()
        token_tracker._conn = None

    result = subprocess.run(
        [sys.executable, "-m", "kg.log_retention", "--all", "--json"],
        capture_output=True,
        text=True,
        env=_cli_env(isolated_logs),
    )
    assert result.returncode == 0, result.stderr
    out = json.loads(result.stdout)
    assert out["pipeline_log"]["deleted"] == 1
    assert out["judge_log"]["deleted"] == 1
    assert out["translate_log"]["deleted"] == 1
    assert out["token_usage"]["deleted"] == 1
    assert out["llm_errors"]["deleted"] == 1


def test_cli_selective_flag(isolated_logs):
    _insert_pipeline_row(_iso(40))
    _insert_judge_row(_iso(80))

    pipeline_log._reset()
    judge_log._reset()

    result = subprocess.run(
        [sys.executable, "-m", "kg.log_retention", "--pipeline", "--days", "30", "--json"],
        capture_output=True,
        text=True,
        env=_cli_env(isolated_logs),
    )
    assert result.returncode == 0, result.stderr
    out = json.loads(result.stdout)
    assert "pipeline_log" in out
    assert out["pipeline_log"]["deleted"] == 1
    # Judge should NOT be touched.
    assert "judge_log" not in out


# ─────────────────────────────────────────────────────────────────────────────
# Admin endpoint
# ─────────────────────────────────────────────────────────────────────────────


ADMIN_TOKEN = "test-admin-token-log-retention"


@pytest.fixture()
def admin_app(admin_app_factory):
    return admin_app_factory(admin_token=ADMIN_TOKEN, setup_log_dbs=True)


def test_admin_endpoint_requires_auth(admin_app):
    resp = admin_app.client.post("/api/admin/log-retention/run")
    assert resp.status_code == 403


def test_admin_endpoint_runs_all_pruners(admin_app):
    _insert_pipeline_row(_iso(40))
    _insert_judge_row(_iso(80))
    _insert_translate_row(_iso(20))
    _insert_token_row(_iso(120))
    _insert_llm_error_row(_iso(40))

    resp = admin_app.client.post(
        "/api/admin/log-retention/run",
        headers={"Authorization": f"Bearer {ADMIN_TOKEN}"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["pipeline_log"]["deleted"] == 1
    assert body["judge_log"]["deleted"] == 1
    assert body["translate_log"]["deleted"] == 1
    assert body["token_usage"]["deleted"] == 1
    assert body["llm_errors"]["deleted"] == 1


# ─────────────────────────────────────────────────────────────────────────────
# Env-driven retention windows + empty-table safety + admin response shape
# ─────────────────────────────────────────────────────────────────────────────


def test_prune_judge_log_respects_retention_days_env(isolated_logs, monkeypatch):
    """``JUDGE_LOG_RETENTION_DAYS`` env var must drive ``prune_judge_log()``
    default window when caller does not pass ``days=``."""
    monkeypatch.setenv("JUDGE_LOG_RETENTION_DAYS", "7")

    for _ in range(5):
        _insert_judge_row(_iso(8))  # 8 days ago → must be pruned under 7d window
    for _ in range(5):
        _insert_judge_row(_iso(0))  # today → must survive

    deleted, remaining = log_retention.prune_judge_log()  # uses env default

    assert deleted == 5
    assert remaining == 5


@pytest.mark.parametrize("raw", ["0", "-1"])
def test_prune_judge_log_non_positive_retention_env_uses_default(isolated_logs, monkeypatch, raw):
    """Non-positive env overrides must not turn retention into immediate pruning."""
    monkeypatch.setenv("JUDGE_LOG_RETENTION_DAYS", raw)
    _insert_judge_row(_iso(1))

    deleted, remaining = log_retention.prune_judge_log()

    assert deleted == 0
    assert remaining == 1


@pytest.mark.parametrize("raw", [None, ""])
def test_env_days_missing_or_empty_uses_fallback(monkeypatch, raw):
    """Missing and empty retention overrides must use the documented fallback."""
    if raw is None:
        monkeypatch.delenv("KG_TEST_RETENTION_DAYS", raising=False)
    else:
        monkeypatch.setenv("KG_TEST_RETENTION_DAYS", raw)

    assert log_retention._env_days("KG_TEST_RETENTION_DAYS", 30) == 30


def test_prune_translate_log_safe_with_no_data(isolated_logs):
    """Pruning an empty translate_log table must not raise and must report 0/0."""
    # Force schema creation without inserting any rows.
    translate_log._get_conn()

    deleted, remaining = log_retention.prune_translate_log(days=14)

    assert deleted == 0
    assert remaining == 0


def test_admin_trigger_prune_endpoint_returns_counts(admin_app):
    """Admin trigger endpoint returns deletion counts under flat keys
    (``judge_deleted`` / ``translate_deleted`` / ``pipeline_deleted``) and 403 without auth."""
    # No auth → 403.
    resp_no_auth = admin_app.client.post("/api/admin/log-retention/run")
    assert resp_no_auth.status_code == 403

    _insert_pipeline_row(_iso(40))
    _insert_judge_row(_iso(80))
    _insert_translate_row(_iso(20))

    resp = admin_app.client.post(
        "/api/admin/log-retention/run",
        headers={"Authorization": f"Bearer {ADMIN_TOKEN}"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["pipeline_deleted"] == 1
    assert body["judge_deleted"] == 1
    assert body["translate_deleted"] == 1


# ─────────────────────────────────────────────────────────────────────────────
# run_all / CLI --all must honour *_RETENTION_DAYS env (not hardcoded defaults)
# ─────────────────────────────────────────────────────────────────────────────


def test_run_all_respects_retention_env(isolated_logs, monkeypatch):
    """run_all() with no args must resolve each *_RETENTION_DAYS env var,
    not silently fall back to the hardcoded DEFAULT_DAYS_*. The admin
    endpoint and CLI --all both route through run_all()."""
    monkeypatch.setenv("PIPELINE_LOG_RETENTION_DAYS", "5")
    monkeypatch.setenv("JUDGE_LOG_RETENTION_DAYS", "7")
    monkeypatch.setenv("TRANSLATE_LOG_RETENTION_DAYS", "3")
    monkeypatch.setenv("TOKEN_USAGE_RETENTION_DAYS", "10")

    # One row just past each env window → must be pruned.
    _insert_pipeline_row(_iso(6))
    _insert_judge_row(_iso(8))
    _insert_translate_row(_iso(4))
    _insert_token_row(_iso(11))
    # One row inside each env window → must survive. (All would also
    # survive the larger DEFAULT windows, so a deleted-count of 1 proves
    # the env window — not DEFAULT — drove the prune.)
    _insert_pipeline_row(_iso(4))
    _insert_judge_row(_iso(6))
    _insert_translate_row(_iso(2))
    _insert_token_row(_iso(9))

    report = log_retention.run_all()

    assert report["pipeline_log"]["deleted"] == 1
    assert report["judge_log"]["deleted"] == 1
    assert report["translate_log"]["deleted"] == 1
    assert report["token_usage"]["deleted"] == 1
    assert report["pipeline_log"]["days"] == 5
    assert report["judge_log"]["days"] == 7
    assert report["translate_log"]["days"] == 3
    assert report["token_usage"]["days"] == 10


def test_run_all_explicit_arg_overrides_env(isolated_logs, monkeypatch):
    """An explicit day-count passed to run_all() still wins over env."""
    monkeypatch.setenv("JUDGE_LOG_RETENTION_DAYS", "7")
    _insert_judge_row(_iso(8))  # past the 7d env window, inside explicit 90d

    report = log_retention.run_all(judge_days=90)

    assert report["judge_log"]["deleted"] == 0
    assert report["judge_log"]["days"] == 90


def test_cli_all_flag_respects_retention_env(isolated_logs):
    """CLI `--all` without `--days` must honour the env vars."""
    _insert_judge_row(_iso(8))  # >7d env window
    _insert_judge_row(_iso(3))  # inside 7d → survives

    judge_log._reset()
    if token_tracker._conn is not None:
        token_tracker._conn.close()
        token_tracker._conn = None

    env = _cli_env(isolated_logs)
    env["JUDGE_LOG_RETENTION_DAYS"] = "7"
    result = subprocess.run(
        [sys.executable, "-m", "kg.log_retention", "--all", "--json"],
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode == 0, result.stderr
    out = json.loads(result.stdout)
    assert out["judge_log"]["deleted"] == 1
    assert out["judge_log"]["days"] == 7


# ─────────────────────────────────────────────────────────────────────────────
# Bounded DELETE batches (#2091)
# ─────────────────────────────────────────────────────────────────────────────


def test_prune_deletes_a_backlog_in_bounded_batches(isolated_logs, monkeypatch):
    """A backlog larger than one batch is removed by several LIMIT-bounded DELETEs.

    One unbounded DELETE would hold the log lock for the whole backlog on the
    first run, which can outlast docker stop's 10s grace period.
    """
    monkeypatch.setattr(log_retention, "DELETE_BATCH_SIZE", 2)
    for _ in range(7):
        _insert_pipeline_row(_iso(40))  # older than the cutoff
    _insert_pipeline_row(_iso(1))  # newer than the cutoff

    conn = pipeline_log._get_conn()
    deletes: list[str] = []
    conn.set_trace_callback(lambda sql: deletes.append(sql) if sql.lstrip().upper().startswith("DELETE") else None)
    try:
        deleted, remaining = log_retention.prune_pipeline_log(days=30)
    finally:
        conn.set_trace_callback(None)

    assert deleted == 7
    assert remaining == 1
    assert len(deletes) > 1, "backlog must be drained by more than one statement"
    assert all("LIMIT" in sql.upper() for sql in deletes), deletes
    survivors = conn.execute("SELECT started_at FROM pipeline_runs").fetchall()
    assert len(survivors) == 1
    assert survivors[0][0] > _iso(30)


def test_prune_stops_at_a_batch_boundary_and_keeps_committed_batches(isolated_logs, monkeypatch):
    """A stop request ends the prune between batches; batches already committed stay deleted."""
    monkeypatch.setattr(log_retention, "DELETE_BATCH_SIZE", 2)
    for _ in range(7):
        _insert_pipeline_row(_iso(40))
    _insert_pipeline_row(_iso(1))

    checks: list[int] = []

    def should_stop() -> bool:
        checks.append(1)
        return len(checks) > 1  # allow the first batch, stop before the second

    with pytest.raises(log_retention.RetentionStopped):
        log_retention.prune_pipeline_log(days=30, should_stop=should_stop)

    count = pipeline_log._get_conn().execute("SELECT COUNT(*) FROM pipeline_runs").fetchone()[0]
    assert count == 8 - 2, "exactly the first batch of 2 old rows was committed"
