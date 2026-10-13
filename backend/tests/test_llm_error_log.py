"""Tests for llm_error_log — real LLM failure recording."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from kg import llm_error_log


@pytest.fixture(autouse=True)
def _reset_and_redirect(tmp_path, monkeypatch):
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
    monkeypatch.setattr(llm_error_log, "DATA_DIR", tmp_path)
    monkeypatch.setattr(llm_error_log, "DB_PATH", tmp_path / "llm_errors.db")
    llm_error_log._reset()
    yield
    llm_error_log._reset()


class TestRecord:
    def test_basic_record(self):
        llm_error_log.record(
            user_id="u1",
            call_type="judge",
            provider="gemini",
            model="gemini-2.5-flash-lite",
            error_class="RateLimitError",
            status_code=429,
            message="rate limited",
        )
        rows = (
            llm_error_log._get_conn()
            .execute("SELECT user_id, call_type, provider, model, error_class, status_code, message FROM llm_errors")
            .fetchall()
        )
        assert len(rows) == 1
        uid, ct, prov, mod, ec, sc, msg = rows[0]
        assert uid == "u1"
        assert ct == "judge"
        assert prov == "gemini"
        assert mod == "gemini-2.5-flash-lite"
        assert ec == "RateLimitError"
        assert sc == 429
        assert msg == "rate limited"

    def test_empty_user_id_skips(self):
        llm_error_log.record(
            user_id="",
            call_type="judge",
            error_class="RuntimeError",
        )
        rows = llm_error_log._get_conn().execute("SELECT COUNT(*) FROM llm_errors").fetchall()
        assert rows[0][0] == 0

    def test_nullable_fields(self):
        """provider, model, status_code, message are all nullable."""
        llm_error_log.record(
            user_id="u1",
            call_type="translate_quick",
            error_class="APITimeoutError",
            status_code=None,
            message=None,
        )
        row = (
            llm_error_log._get_conn().execute("SELECT provider, model, status_code, message FROM llm_errors").fetchone()
        )
        assert row[0] is None
        assert row[1] is None
        assert row[2] is None
        assert row[3] == ""

    def test_message_truncated(self):
        long_msg = "x" * 1000
        llm_error_log.record(
            user_id="u1",
            call_type="judge",
            error_class="Error",
            message=long_msg,
        )
        msg = llm_error_log._get_conn().execute("SELECT message FROM llm_errors").fetchone()[0]
        assert len(msg) == 500
        assert msg == "x" * 500

    def test_message_redacts_secret_like_values(self):
        llm_error_log.record(
            user_id="u1",
            call_type="judge",
            error_class="AuthenticationError",
            message=("Authorization: Bearer sk-prod-secret api_key=AIzaSySecret token=plain-token password=hunter2"),
        )
        msg = llm_error_log._get_conn().execute("SELECT message FROM llm_errors").fetchone()[0]
        for secret in ("sk-prod-secret", "AIzaSySecret", "plain-token", "hunter2"):
            assert secret not in msg
        assert msg.count("[REDACTED]") >= 4

    def test_message_redacts_quoted_dict_secret_values(self):
        llm_error_log.record(
            user_id="u1",
            call_type="judge",
            error_class="AuthenticationError",
            message=(
                '{"api_key": "AIzaSySecret", \'Authorization\': \'Bearer eyJ.secret\', "access_token": "access-secret"}'
            ),
        )
        msg = llm_error_log._get_conn().execute("SELECT message FROM llm_errors").fetchone()[0]
        for secret in ("AIzaSySecret", "eyJ.secret", "access-secret"):
            assert secret not in msg
        assert msg.count("[REDACTED]") >= 3

    def test_message_keeps_non_secret_token_counters(self):
        llm_error_log.record(
            user_id="u1",
            call_type="judge",
            error_class="BadRequestError",
            message="max_tokens=8192 prompt_tokens=123 completion_tokens=456 total_tokens=579",
        )
        msg = llm_error_log._get_conn().execute("SELECT message FROM llm_errors").fetchone()[0]
        assert "max_tokens=8192" in msg
        assert "prompt_tokens=123" in msg
        assert "completion_tokens=456" in msg
        assert "total_tokens=579" in msg
        assert "[REDACTED]" not in msg

    def test_created_at_iso8601(self):
        before = datetime.now(UTC).isoformat()
        llm_error_log.record(
            user_id="u1",
            call_type="judge",
            error_class="RuntimeError",
        )
        after = datetime.now(UTC).isoformat()
        ts = llm_error_log._get_conn().execute("SELECT created_at FROM llm_errors").fetchone()[0]
        assert before <= ts <= after

    def test_count_errors_since_normalizes_offset_timestamps(self, monkeypatch):
        """Compare stored offset timestamps by their UTC instant, not text."""
        fixed_now = datetime(2026, 8, 21, 12, 0, tzinfo=UTC)

        class FixedDatetime(datetime):
            @classmethod
            def now(cls, tz=None):
                return fixed_now

        monkeypatch.setattr(llm_error_log, "datetime", FixedDatetime)
        conn = llm_error_log._get_conn()
        conn.executemany(
            "INSERT INTO llm_errors (user_id, call_type, error_class, created_at) VALUES (?, ?, ?, ?)",
            [
                ("u1", "judge", "Error", "2026-08-21T12:30:00+01:00"),
                ("u1", "judge", "Error", "2026-08-21T12:30:00+02:00"),
            ],
        )
        conn.commit()

        query = "SELECT COUNT(*) FROM llm_errors WHERE datetime(created_at) >= datetime(?)"
        plan = conn.execute(
            f"EXPLAIN QUERY PLAN {query}",
            ("2026-08-21T11:00:00+00:00",),
        ).fetchall()
        assert any("idx_le_created_utc" in row[-1] for row in plan)
        assert llm_error_log.count_errors_since(60) == 1


class TestReset:
    def test_reset_switches_db_path(self, tmp_path, monkeypatch):
        """After _reset(), changing DB_PATH makes the next _get_conn open a fresh DB."""
        llm_error_log.record(user_id="u1", call_type="judge", error_class="E")
        old_path = llm_error_log.DB_PATH
        llm_error_log._reset()
        new_path = tmp_path / "other" / "llm_errors.db"
        new_path.parent.mkdir(parents=True)
        monkeypatch.setattr(llm_error_log, "DB_PATH", new_path)
        llm_error_log._get_conn()
        new_count = llm_error_log._get_conn().execute("SELECT COUNT(*) FROM llm_errors").fetchone()[0]
        assert new_count == 0
        llm_error_log._reset()
        monkeypatch.setattr(llm_error_log, "DB_PATH", old_path)
        old_count = llm_error_log._get_conn().execute("SELECT COUNT(*) FROM llm_errors").fetchone()[0]
        llm_error_log._reset()
        assert old_count == 1


def test_delete_for_users_is_scoped_idempotent_and_handles_empty():
    for uid in ("gone", "linked", "keep"):
        llm_error_log.record(user_id=uid, call_type="judge", error_class="RateLimitError")

    assert llm_error_log.delete_for_users([]) == 0
    assert llm_error_log.delete_for_users(["gone", "linked", "gone"]) == 2
    assert llm_error_log.delete_for_users(["gone"]) == 0
    rows = llm_error_log._get_conn().execute("SELECT user_id FROM llm_errors").fetchall()
    assert [r[0] for r in rows] == ["keep"]


class _CommitFailsOnce:
    """Proxy whose first commit raises; every other call delegates to the real connection."""

    def __init__(self, real):
        self._real = real
        self._armed = True

    def commit(self):
        if self._armed:
            self._armed = False
            import sqlite3

            raise sqlite3.OperationalError("simulated commit failure")
        self._real.commit()

    def __getattr__(self, name):
        return getattr(self._real, name)


def test_delete_for_users_rolls_back_when_commit_fails(monkeypatch):
    """A failed erasure must leave no open transaction on the shared connection."""
    import sqlite3

    llm_error_log.record(user_id="gone", call_type="judge", error_class="RateLimitError")
    real = llm_error_log._get_conn()
    proxy = _CommitFailsOnce(real)
    monkeypatch.setattr(llm_error_log, "_get_conn", lambda *a, **k: proxy)

    with pytest.raises(sqlite3.OperationalError):
        llm_error_log.delete_for_users(["gone"])

    assert real.in_transaction is False
    assert llm_error_log.delete_for_users(["gone"]) == 1
