"""Tests for TrackedLLM — unified LLM wrapper with auto token tracking."""

from __future__ import annotations

import sqlite3
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from kg.tracked_llm import TrackedLLM


def _mock_client(prompt_tokens=10, completion_tokens=20):
    client = MagicMock()
    usage = SimpleNamespace(prompt_tokens=prompt_tokens, completion_tokens=completion_tokens, total_tokens=30)
    choice = SimpleNamespace(message=SimpleNamespace(content='{"ok": true}'))
    resp = SimpleNamespace(choices=[choice], usage=usage)
    client.chat.completions.create.return_value = resp
    return client, resp


def _mock_embed_client(prompt_tokens=5, total_tokens=5):
    client = MagicMock()
    usage = SimpleNamespace(prompt_tokens=prompt_tokens, total_tokens=total_tokens)
    data = [SimpleNamespace(embedding=[0.1, 0.2], index=0)]
    resp = SimpleNamespace(data=data, usage=usage)
    client.embeddings.create.return_value = resp
    return client, resp


class TestTrackedLLMChat:
    @patch("kg.tracked_llm.record")
    def test_chat_records_token_usage(self, mock_record):
        client, _ = _mock_client(prompt_tokens=15, completion_tokens=25)
        llm = TrackedLLM(client, user_id="u1")
        resp = llm.chat("judge", model="m", messages=[])
        mock_record.assert_called_once_with("u1", "judge", 15, 25, cached_input_tokens=0, provider=None, model="m")
        assert resp.choices[0].message.content == '{"ok": true}'

    @patch("kg.tracked_llm.logger")
    @patch("kg.tracked_llm.record")
    def test_chat_no_usage_skips_record(self, mock_record, mock_logger):
        client = MagicMock()
        resp = SimpleNamespace(choices=[], usage=None)
        client.chat.completions.create.return_value = resp
        llm = TrackedLLM(client, user_id="u1")
        llm.chat("judge", model="m", messages=[])
        # Billing behavior unchanged: a usage-less response is never billed.
        mock_record.assert_not_called()
        # New observability: the silent skip must leave a warning trace so the
        # token leak is visible to billing/quota auditing.
        mock_logger.warning.assert_called_once()

    @patch("kg.tracked_llm.record")
    def test_multiple_calls_each_recorded(self, mock_record):
        client, _ = _mock_client()
        llm = TrackedLLM(client, user_id="u1")
        llm.chat("judge", model="m", messages=[])
        llm.chat("judge", model="m", messages=[])
        assert mock_record.call_count == 2

    @patch("kg.tracked_llm.logger")
    @patch("kg.tracked_llm.record")
    def test_chat_no_usage_warning_carries_context(self, mock_record, mock_logger):
        from kg.llm.providers import REGISTRY

        client = MagicMock()
        resp = SimpleNamespace(choices=[], usage=None)
        client.chat.completions.create.return_value = resp
        llm = TrackedLLM(client, user_id="u1", provider=REGISTRY["deepseek"])
        llm.chat("judge", model="deepseek-v4-flash", messages=[])
        mock_record.assert_not_called()
        mock_logger.warning.assert_called_once()
        # context dict (extra=) must carry provider/model/user_id/call_type so
        # the leak is traceable, not just a bare message.
        ctx = str(mock_logger.warning.call_args)
        for token in ("deepseek", "deepseek-v4-flash", "u1", "judge"):
            assert token in ctx


class TestTrackedLLMEmbed:
    @patch("kg.tracked_llm.record")
    def test_embed_records_prompt_tokens(self, mock_record):
        client, _ = _mock_embed_client(prompt_tokens=5, total_tokens=5)
        llm = TrackedLLM(client, user_id="u1")
        llm.embed("embed", input=["hello"], model="m")
        mock_record.assert_called_once_with("u1", "embed", 5, 0, provider=None, model="m")

    @patch("kg.tracked_llm.record")
    def test_embed_falls_back_to_total_tokens(self, mock_record):
        client = MagicMock()
        usage = SimpleNamespace(prompt_tokens=0, total_tokens=8)
        resp = SimpleNamespace(data=[], usage=usage)
        client.embeddings.create.return_value = resp
        llm = TrackedLLM(client, user_id="u1")
        llm.embed("embed", input=["hi"], model="m")
        mock_record.assert_called_once_with("u1", "embed", 8, 0, provider=None, model="m")

    @patch("kg.tracked_llm.logger")
    @patch("kg.tracked_llm.record")
    def test_embed_no_usage_skips_record_and_warns(self, mock_record, mock_logger):
        client = MagicMock()
        resp = SimpleNamespace(data=[], usage=None)
        client.embeddings.create.return_value = resp
        llm = TrackedLLM(client, user_id="u1")
        llm.embed("embed", input=["hi"], model="m")
        mock_record.assert_not_called()
        mock_logger.warning.assert_called_once()


class TestTrackedLLMChatAsync:
    @pytest.mark.asyncio
    @patch("kg.tracked_llm.record")
    async def test_chat_async_records_usage(self, mock_record):
        client = MagicMock()
        usage = SimpleNamespace(prompt_tokens=10, completion_tokens=20)
        choice = SimpleNamespace(message=SimpleNamespace(content="{}"))
        resp = SimpleNamespace(choices=[choice], usage=usage)

        async def mock_create(**kwargs):
            return resp

        client.chat.completions.create = mock_create

        llm = TrackedLLM(client, user_id="u1")
        await llm.chat_async("translate_quick", model="m", messages=[])
        mock_record.assert_called_once_with(
            "u1", "translate_quick", 10, 20, cached_input_tokens=0, provider=None, model="m"
        )


class TestTrackedLLMRecordFailureIsolation:
    """A billed provider call that succeeded must still return its response
    even when usage recording fails (#3433): the response is never discarded
    because the token ledger write raised."""

    @patch("kg.tracked_llm.logger")
    @patch("kg.tracked_llm.record")
    def test_chat_returns_response_when_record_raises(self, mock_record, mock_logger):
        mock_record.side_effect = sqlite3.OperationalError("disk full")
        client, resp = _mock_client()
        llm = TrackedLLM(client, user_id="u1")
        out = llm.chat("judge", model="m", messages=[])
        assert out is resp
        mock_logger.warning.assert_called_once()

    @pytest.mark.asyncio
    @patch("kg.tracked_llm.logger")
    @patch("kg.tracked_llm.record")
    async def test_chat_async_returns_response_when_record_raises(self, mock_record, mock_logger):
        mock_record.side_effect = sqlite3.OperationalError("disk full")
        resp = SimpleNamespace(choices=[], usage=SimpleNamespace(prompt_tokens=1, completion_tokens=1))

        async def mock_create(**kwargs):
            return resp

        client = MagicMock()
        client.chat.completions.create = mock_create
        llm = TrackedLLM(client, user_id="u1")
        out = await llm.chat_async("translate_quick", model="m", messages=[])
        assert out is resp
        mock_logger.warning.assert_called_once()

    @patch("kg.tracked_llm.logger")
    @patch("kg.tracked_llm.record")
    def test_embed_returns_response_when_record_raises(self, mock_record, mock_logger):
        mock_record.side_effect = sqlite3.OperationalError("disk full")
        client, resp = _mock_embed_client()
        llm = TrackedLLM(client, user_id="u1")
        out = llm.embed("embed", input=["hello"], model="m")
        assert out is resp
        mock_logger.warning.assert_called_once()


class TestTrackedLLMProviderBinding:
    """When a provider is bound, every recorded row carries provider name +
    model so cost can later be priced from the row itself."""

    @patch("kg.tracked_llm.record")
    def test_chat_records_bound_provider_and_model(self, mock_record):
        from kg.llm.providers import REGISTRY

        client, _ = _mock_client(prompt_tokens=11, completion_tokens=22)
        llm = TrackedLLM(client, user_id="u1", provider=REGISTRY["deepseek"])
        llm.chat("judge", model="deepseek-v4-flash", messages=[])
        mock_record.assert_called_once_with(
            "u1", "judge", 11, 22, cached_input_tokens=0, provider="deepseek", model="deepseek-v4-flash"
        )

    @patch("kg.tracked_llm.record")
    def test_chat_model_falls_back_to_provider_chat_model(self, mock_record):
        from kg.llm.providers import REGISTRY

        client, _ = _mock_client()
        llm = TrackedLLM(client, user_id="u1", provider=REGISTRY["gemini"])
        llm.chat("judge", messages=[])  # no model kwarg
        mock_record.assert_called_once_with(
            "u1", "judge", 10, 20, cached_input_tokens=0, provider="gemini", model="gemini-2.5-flash-lite"
        )


class TestTrackedLLMFailureRecording:
    """Real LLM failures (429/5xx/timeout) must be captured before the exception
    propagates, but the exception itself must be re-raised unchanged."""

    @patch("kg.llm_error_log.record")
    @patch("kg.tracked_llm.record")
    def test_chat_failure_recorded_and_reraised(self, mock_record, mock_err):
        client = MagicMock()
        client.chat.completions.create.side_effect = RuntimeError("boom")
        llm = TrackedLLM(client, user_id="u1")
        with pytest.raises(RuntimeError, match="boom"):
            llm.chat("judge", model="m", messages=[])
        # token record is skipped because the call never succeeded.
        mock_record.assert_not_called()
        # failure record lands.
        mock_err.assert_called_once()
        _, kwargs = mock_err.call_args
        assert kwargs["user_id"] == "u1"
        assert kwargs["call_type"] == "judge"
        assert kwargs["error_class"] == "RuntimeError"
        assert kwargs["model"] == "m"

    @pytest.mark.asyncio
    @patch("kg.llm_error_log.record")
    @patch("kg.tracked_llm.record")
    async def test_chat_async_failure_recorded_and_reraised(self, mock_record, mock_err):
        client = MagicMock()

        async def boom(**kwargs):
            raise RuntimeError("async boom")

        client.chat.completions.create = boom

        llm = TrackedLLM(client, user_id="u1")
        with pytest.raises(RuntimeError, match="async boom"):
            await llm.chat_async("translate_quick", model="m", messages=[])
        mock_record.assert_not_called()
        mock_err.assert_called_once()
        assert mock_err.call_args.kwargs["error_class"] == "RuntimeError"

    @patch("kg.llm_error_log.record")
    @patch("kg.tracked_llm.record")
    def test_embed_failure_recorded_and_reraised(self, mock_record, mock_err):
        client = MagicMock()
        client.embeddings.create.side_effect = RuntimeError("embed boom")
        llm = TrackedLLM(client, user_id="u1")
        with pytest.raises(RuntimeError, match="embed boom"):
            llm.embed("embed", input=["hello"], model="m")
        mock_record.assert_not_called()
        mock_err.assert_called_once()
        assert mock_err.call_args.kwargs["error_class"] == "RuntimeError"

    @patch("kg.llm_error_log.record")
    @patch("kg.tracked_llm.record")
    def test_failure_status_code_extracted(self, mock_record, mock_err):
        """Exceptions with a ``status_code`` attribute (OpenAI SDK errors)
        must have that code recorded; timeouts/connection errors record None."""
        client = MagicMock()

        class Fake429(Exception):
            status_code = 429

        client.chat.completions.create.side_effect = Fake429("rate limited")

        llm = TrackedLLM(client, user_id="u1")
        with pytest.raises(Fake429):
            llm.chat("judge", model="m", messages=[])
        assert mock_err.call_args.kwargs["status_code"] == 429

    @patch("kg.llm_error_log.record")
    @patch("kg.tracked_llm.record")
    def test_failure_message_redacted_before_record(self, mock_record, mock_err):
        client = MagicMock()
        client.chat.completions.create.side_effect = RuntimeError(
            "Authorization: Bearer sk-prod-secret api_key=AIzaSySecret"
        )
        llm = TrackedLLM(client, user_id="u1")
        with pytest.raises(RuntimeError):
            llm.chat("judge", model="m", messages=[])
        message = mock_err.call_args.kwargs["message"]
        assert "sk-prod-secret" not in message
        assert "AIzaSySecret" not in message
        assert message.count("[REDACTED]") >= 2

    @patch("kg.llm_error_log.record")
    @patch("kg.tracked_llm.record")
    def test_failure_no_status_code_records_none(self, mock_record, mock_err):
        """Timeout/connection errors have no status_code → recorded as None."""
        client = MagicMock()
        client.chat.completions.create.side_effect = TimeoutError("timed out")
        llm = TrackedLLM(client, user_id="u1")
        with pytest.raises(TimeoutError):
            llm.chat("judge", model="m", messages=[])
        assert mock_err.call_args.kwargs["status_code"] is None

    @patch("kg.tracked_llm.logger")
    @patch("kg.llm_error_log.record")
    @patch("kg.tracked_llm.record")
    def test_failure_record_itself_fails_original_still_reraised(self, mock_record, mock_err, mock_logger):
        """Best-effort: if the error logger itself crashes, the original LLM
        exception must still propagate — we must never mask a production failure."""
        mock_err.side_effect = RuntimeError("logger broken")
        client = MagicMock()
        client.chat.completions.create.side_effect = ValueError("real failure")
        llm = TrackedLLM(client, user_id="u1")
        with pytest.raises(ValueError, match="real failure"):
            llm.chat("judge", model="m", messages=[])
        # recording failure should emit a warning, not raise.
        mock_logger.warning.assert_called_once()


# ── cache-aware cost (#2272) ──────────────────────────────────────


@pytest.fixture()
def tracker_db(tmp_path, monkeypatch):
    import kg.token_tracker as tt

    monkeypatch.setattr(tt, "DB_PATH", tmp_path / "token_usage.db", raising=True)
    tt._conn = None
    try:
        yield tt
    finally:
        if tt._conn is not None:
            tt._conn.close()
            tt._conn = None


def _chat_with_usage(usage):
    from kg.llm.providers import REGISTRY

    client = MagicMock()
    client.chat.completions.create.return_value = SimpleNamespace(choices=[], usage=usage)
    llm = TrackedLLM(client, user_id="u1", provider=REGISTRY["deepseek"])
    llm.chat("judge", model="deepseek-v4-flash", messages=[])


def _stored_cached_and_cost(tt):
    from kg.quota_service import token_cost_usd

    with tt._lock:
        cached, t_in, t_out = (
            tt._get_conn()
            .execute("SELECT SUM(cached_input_tokens), SUM(input_tokens), SUM(output_tokens) FROM token_usage")
            .fetchone()
        )
    return cached, token_cost_usd("judge", t_in, t_out, provider="deepseek", cached_tokens=cached)


class TestCacheAwareChatCost:
    EXPECTED = (200 * 0.14 + 800 * 0.0028 + 100 * 0.28) / 1e6

    def test_deepseek_style_usage(self, tracker_db):
        _chat_with_usage(SimpleNamespace(prompt_tokens=1000, prompt_cache_hit_tokens=800, completion_tokens=100))
        cached, cost = _stored_cached_and_cost(tracker_db)
        assert cached == 800
        assert cost == pytest.approx(self.EXPECTED)

    def test_openai_style_usage(self, tracker_db):
        details = SimpleNamespace(cached_tokens=800)
        _chat_with_usage(SimpleNamespace(prompt_tokens=1000, prompt_tokens_details=details, completion_tokens=100))
        cached, cost = _stored_cached_and_cost(tracker_db)
        assert cached == 800
        assert cost == pytest.approx(self.EXPECTED)

    def test_openai_style_dict_details(self, tracker_db):
        _chat_with_usage(
            SimpleNamespace(prompt_tokens=1000, prompt_tokens_details={"cached_tokens": 800}, completion_tokens=100)
        )
        assert _stored_cached_and_cost(tracker_db)[0] == 800

    def test_no_cache_fields_matches_legacy_formula(self, tracker_db):
        _chat_with_usage(SimpleNamespace(prompt_tokens=1000, completion_tokens=100))
        cached, cost = _stored_cached_and_cost(tracker_db)
        assert cached == 0
        assert cost == pytest.approx((1000 * 0.14 + 100 * 0.28) / 1e6)

    def test_cached_over_input_is_clamped(self, tracker_db):
        _chat_with_usage(SimpleNamespace(prompt_tokens=100, prompt_cache_hit_tokens=500, completion_tokens=0))
        _, cost = _stored_cached_and_cost(tracker_db)
        assert cost >= 0
        assert cost == pytest.approx(100 * 0.0028 / 1e6)


def test_legacy_db_gains_cached_column_with_zero_default(tmp_path, monkeypatch):
    import sqlite3

    import kg.token_tracker as tt

    db = tmp_path / "token_usage.db"
    conn = sqlite3.connect(db)
    conn.execute(
        "CREATE TABLE token_usage (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,"
        " call_type TEXT NOT NULL, input_tokens INTEGER NOT NULL DEFAULT 0,"
        " output_tokens INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, provider TEXT, model TEXT)"
    )
    conn.execute("INSERT INTO token_usage VALUES (1,'u1','judge',10,5,'2026-01-01T00:00:00+00:00',NULL,NULL)")
    conn.commit()
    conn.close()
    monkeypatch.setattr(tt, "DB_PATH", db, raising=True)
    tt._conn = None
    try:
        with tt._lock:
            assert tt._get_conn().execute("SELECT cached_input_tokens FROM token_usage").fetchall() == [(0,)]
    finally:
        if tt._conn is not None:
            tt._conn.close()
            tt._conn = None
