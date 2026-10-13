"""Tests for admin_cost_summary — per-user AI token + USD breakdown.

Covers:
  * empty table → zeroed shape, no IndexError / KeyError
  * rows aggregate correctly into by_service / by_model / by_call_type
    and totals match per-call cost via :mod:`kg.quota_service`
  * range='month' boundary excludes prior-month rows
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest


@pytest.fixture()
def cost_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Isolate token_usage.db under tmp_path. Module caches DB_PATH at
    import time, so monkeypatch the bound attribute too."""
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
    import kg.token_tracker as tt

    monkeypatch.setattr(tt, "DATA_DIR", tmp_path, raising=True)
    monkeypatch.setattr(tt, "DB_PATH", tmp_path / "token_usage.db", raising=True)

    # Drop any pre-existing singleton connection so the patched DB_PATH wins.
    tt._conn = None
    try:
        yield tmp_path
    finally:
        if tt._conn is not None:
            tt._conn.close()
            tt._conn = None


def _record(
    user_id: str,
    call_type: str,
    *,
    t_in: int,
    t_out: int,
    when: datetime,
    provider: str | None = None,
    model: str | None = None,
) -> None:
    """Insert a token_usage row at a specific timestamp (bypasses record())."""
    import kg.token_tracker as tt

    with tt._lock:
        conn = tt._get_conn()
        conn.execute(
            "INSERT INTO token_usage "
            "(user_id, call_type, input_tokens, output_tokens, created_at, provider, model)"
            " VALUES (?,?,?,?,?,?,?)",
            (user_id, call_type, t_in, t_out, when.isoformat(), provider, model),
        )
        conn.commit()


def test_empty_returns_zeroed_shape(cost_env):
    """No rows in the table → every aggregate is empty/zero, no exception."""
    from kg.admin_cost_summary import get_user_cost_summary

    r = get_user_cost_summary("ghost-user", range_="month")
    assert r["user_id"] == "ghost-user"
    assert r["range"] == "month"
    assert r["total_calls"] == 0
    assert r["total_input_tokens"] == 0
    assert r["total_output_tokens"] == 0
    assert r["total_tokens"] == 0
    assert r["total_cost_usd"] == 0.0
    assert r["by_service"] == {}
    assert r["by_model"] == {}
    assert r["by_call_type"] == {}
    # Pricing assumptions are always present so the UI can render them.
    pa = r["pricing_assumptions"]
    assert pa["model_inferred_from_call_type"] is True
    assert "default_model" in pa
    assert "service_map" in pa


def test_aggregates_by_service_model_calltype(cost_env):
    from kg.admin_cost_summary import get_user_cost_summary
    from kg.quota_service import token_cost_usd

    now = datetime.now(UTC)
    # judge family — 3 calls, accumulates to service=judge.
    # Both the legacy manual call_type ("manual_link_judge", still present in
    # historic token_usage rows) and the new one ("judge_manual") must bucket
    # into judge — otherwise historic cost attribution breaks.
    _record("u1", "judge", t_in=1000, t_out=200, when=now - timedelta(minutes=1))
    _record("u1", "manual_link_judge", t_in=500, t_out=100, when=now - timedelta(minutes=2))
    _record("u1", "judge_manual", t_in=200, t_out=40, when=now - timedelta(minutes=2))
    # translate family — 1 call
    _record("u1", "translate_quick", t_in=300, t_out=80, when=now - timedelta(minutes=3))
    # pipeline family — embed (different model + different pricing)
    _record("u1", "embed", t_in=2000, t_out=0, when=now - timedelta(minutes=4))
    _record("u1", "enrich", t_in=400, t_out=120, when=now - timedelta(minutes=5))
    # noise — other user must not leak
    _record("u2", "judge", t_in=9999, t_out=9999, when=now - timedelta(minutes=1))

    r = get_user_cost_summary("u1", range_="month")

    assert r["total_calls"] == 6
    assert r["total_input_tokens"] == 1000 + 500 + 200 + 300 + 2000 + 400
    assert r["total_output_tokens"] == 200 + 100 + 40 + 80 + 0 + 120

    # Service grouping
    assert set(r["by_service"].keys()) == {"judge", "translate", "pipeline"}
    judge = r["by_service"]["judge"]
    assert judge["calls"] == 3
    assert judge["input_tokens"] == 1700
    assert judge["output_tokens"] == 340
    expected_judge_cost = (
        token_cost_usd("judge", 1000, 200)
        + token_cost_usd("manual_link_judge", 500, 100)
        + token_cost_usd("judge_manual", 200, 40)
    )
    assert judge["cost_usd"] == round(expected_judge_cost, 6)

    pipeline = r["by_service"]["pipeline"]
    assert pipeline["calls"] == 2  # embed + enrich
    assert pipeline["input_tokens"] == 2400
    assert pipeline["output_tokens"] == 120

    # Model grouping — embed gets its own model
    assert set(r["by_model"].keys()) == {
        "gemini-2.5-flash-lite",
        "gemini-embedding-2-preview",
    }
    embed_model = r["by_model"]["gemini-embedding-2-preview"]
    assert embed_model["calls"] == 1
    assert embed_model["input_tokens"] == 2000

    # by_call_type round-trip
    assert set(r["by_call_type"].keys()) == {
        "judge",
        "manual_link_judge",
        "judge_manual",
        "translate_quick",
        "embed",
        "enrich",
    }

    # Cross-check: sum of by_call_type cost == total_cost_usd (modulo rounding)
    summed = sum(v["cost_usd"] for v in r["by_call_type"].values())
    assert abs(summed - r["total_cost_usd"]) < 1e-6


def test_month_range_excludes_prior_month(cost_env):
    """range=month must exclude rows from the prior calendar month."""
    from kg.admin_cost_summary import get_user_cost_summary

    now = datetime.now(UTC)
    in_month = now.replace(day=1, hour=12, minute=0, second=0, microsecond=0)
    prior_month = in_month - timedelta(days=2)

    _record("u1", "judge", t_in=100, t_out=50, when=in_month)
    _record("u1", "judge", t_in=999, t_out=999, when=prior_month)

    r = get_user_cost_summary("u1", range_="month")
    assert r["total_input_tokens"] == 100
    assert r["total_output_tokens"] == 50
    # Prior-month row must not leak through any view.
    assert r["by_call_type"]["judge"]["input_tokens"] == 100


def test_since_filters_utc_instants_not_text_order(cost_env):
    """Offset-aware timestamps must be compared as UTC instants."""
    from kg.admin_cost_summary import fold_user_summary, query_cost_rows

    cutoff = "2026-05-14T11:15:00+00:00"
    _record(
        "u1",
        "judge",
        t_in=100,
        t_out=10,
        when=datetime.fromisoformat("2026-05-14T12:00:00+01:00"),
    )
    _record(
        "u1",
        "judge",
        t_in=200,
        t_out=20,
        when=datetime.fromisoformat("2026-05-14T11:30:00+00:00"),
    )

    import kg.token_tracker as tt

    with tt._lock:
        rows = query_cost_rows(tt._get_conn(), user_id="u1", since=cutoff)

    summary = fold_user_summary(rows)
    assert summary["total_calls"] == 1
    assert summary["total_input_tokens"] == 200
    assert summary["total_output_tokens"] == 20


def test_by_model_uses_real_model_column(cost_env):
    """When rows carry a real model, by_model keys on it — not on the
    call_type-inferred default. Same call_type, two providers/models →
    two distinct buckets."""
    from kg.admin_cost_summary import get_user_cost_summary
    from kg.quota_service import token_cost_usd

    now = datetime.now(UTC)
    _record(
        "u1",
        "judge",
        t_in=1_000_000,
        t_out=0,
        when=now - timedelta(minutes=1),
        provider="deepseek",
        model="deepseek-v4-flash",
    )
    _record(
        "u1",
        "judge",
        t_in=1_000_000,
        t_out=0,
        when=now - timedelta(minutes=2),
        provider="gemini",
        model="gemini-2.5-flash-lite",
    )

    r = get_user_cost_summary("u1", range_="month")
    assert set(r["by_model"].keys()) == {"deepseek-v4-flash", "gemini-2.5-flash-lite"}
    assert r["by_model"]["deepseek-v4-flash"]["calls"] == 1
    assert r["by_model"]["gemini-2.5-flash-lite"]["calls"] == 1
    # Each model's cost priced at its own provider's rate.
    assert r["by_model"]["deepseek-v4-flash"]["cost_usd"] == round(
        token_cost_usd("judge", 1_000_000, 0, provider="deepseek"), 6
    )
    assert r["by_model"]["gemini-2.5-flash-lite"]["cost_usd"] == round(
        token_cost_usd("judge", 1_000_000, 0, provider="gemini"), 6
    )


def test_by_model_null_model_falls_back_to_inferred(cost_env):
    """Legacy NULL-model rows still bucket under the call_type-inferred
    model name, so historical data keeps rendering."""
    from kg.admin_cost_summary import get_user_cost_summary

    now = datetime.now(UTC)
    _record("u1", "judge", t_in=1000, t_out=200, when=now - timedelta(minutes=1))
    r = get_user_cost_summary("u1", range_="month")
    assert set(r["by_model"].keys()) == {"gemini-2.5-flash-lite"}


def test_invalid_range_raises(cost_env):
    from kg.admin_cost_summary import get_user_cost_summary

    with pytest.raises(ValueError):
        get_user_cost_summary("u1", range_="forever")


def test_cost_summary_uses_cached_tokens(cost_env):
    import kg.token_tracker as tt
    from kg.admin_cost_summary import get_user_cost_summary

    tt.record("u1", "judge", 1000, 100, cached_input_tokens=800, provider="deepseek")
    r = get_user_cost_summary("u1", range_="all")
    assert r["total_cost_usd"] == pytest.approx((200 * 0.14 + 800 * 0.0028 + 100 * 0.28) / 1e6, abs=1e-6)


def test_range_all_reports_retention_window(cost_env):
    """range='all' must disclose the token_usage retention window: lifetime
    totals are only lifetime up to the prune horizon (#3437)."""
    from kg import log_retention
    from kg.admin_cost_summary import get_user_cost_summary

    now = datetime.now(UTC)
    _record("u1", "judge", t_in=1000, t_out=200, when=now - timedelta(days=200))
    _record("u1", "judge", t_in=1000, t_out=200, when=now - timedelta(days=5))
    log_retention.run_all()

    r = get_user_cost_summary("u1", range_="all")
    assert r["retention_days"] == 90
    assert r["oldest_retained_at"] is not None
    assert r["oldest_retained_at"] >= (now - timedelta(days=6)).isoformat()


def test_range_all_retention_days_honours_env_override(cost_env, monkeypatch: pytest.MonkeyPatch):
    from kg.admin_cost_summary import get_user_cost_summary

    monkeypatch.setenv("TOKEN_USAGE_RETENTION_DAYS", "30")
    _record("u1", "judge", t_in=1, t_out=1, when=datetime.now(UTC) - timedelta(days=1))
    r = get_user_cost_summary("u1", range_="all")
    assert r["retention_days"] == 30
    assert r["oldest_retained_at"] is not None


def test_range_all_empty_table_has_null_oldest(cost_env):
    from kg.admin_cost_summary import get_user_cost_summary

    r = get_user_cost_summary("ghost-user", range_="all")
    assert r["retention_days"] == 90
    assert r["oldest_retained_at"] is None
