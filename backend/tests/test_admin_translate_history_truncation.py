"""Admin translate history reports the real match total and truncation (#3903).

The handler caps rows at ``limit``; without ``total``/``truncated`` the admin
detail page shows the page length as if it were the user's full history.
"""

from __future__ import annotations

import pytest

from kg.admin_wiring import AdminHandlerDependencies, create_admin_handlers_from_dependencies


def _noop(*_a, **_k):  # pragma: no cover - placeholder dep
    raise AssertionError("unexpected dependency call")


@pytest.fixture()
def handlers():
    return create_admin_handlers_from_dependencies(
        dependencies=AdminHandlerDependencies(
            runtime_settings_fn=_noop,
            runtime_users_lock_file_fn=_noop,
            load_users_fn=_noop,
            save_users_fn=_noop,
            mem_log_getter=_noop,
            card_store_factory=_noop,
            build_entitlements_response_fn=_noop,
            current_admin_grant_record_fn=_noop,
        )
    )


@pytest.fixture()
def seeded_translate_log(tmp_path, monkeypatch):
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
    from kg import translate_log

    translate_log._reset()
    for i in range(5):
        translate_log.record(
            user_id="u1",
            operation="translate_quick",
            word=f"w{i}",
            context="",
            context_hash=f"h{i}",
            source_lang="en",
            target_lang="zh-Hant",
            response_raw='{"t":"x"}',
            latency_ms=1,
        )
    try:
        yield translate_log
    finally:
        translate_log._reset()


def test_count_log_counts_all_matches_ignoring_limit(seeded_translate_log):
    assert seeded_translate_log.count_log("u1") == 5
    assert seeded_translate_log.count_log("u1", q="w1") == 1
    assert seeded_translate_log.count_log("u1", op="translate_explain") == 0


def test_translate_history_reports_total_and_truncated_when_capped(handlers, seeded_translate_log):
    out = handlers.admin_translate_history("u1", limit=2)
    assert len(out["history"]) == 2
    assert out["total"] == 5
    assert out["truncated"] is True


def test_translate_history_not_truncated_when_page_holds_all(handlers, seeded_translate_log):
    out = handlers.admin_translate_history("u1", limit=10)
    assert len(out["history"]) == 5
    assert out["total"] == 5
    assert out["truncated"] is False


def test_translate_history_total_respects_filter(handlers, seeded_translate_log):
    out = handlers.admin_translate_history("u1", limit=10, q="w2")
    assert out["total"] == 1
    assert out["truncated"] is False
