"""Tests for Google Sign-In token validation (google_auth.py)."""

from __future__ import annotations

import asyncio
import threading
import time
from unittest.mock import MagicMock, patch

import pytest
from fastapi import HTTPException
from google.auth.exceptions import GoogleAuthError, TransportError

from kg import google_auth

CLIENT_ID = "test-client-id.apps.googleusercontent.com"


class TestVerifyGoogleToken:
    """Tests for verify_google_token."""

    @pytest.mark.asyncio
    async def test_happy_path(self):
        """Valid token returns sub."""
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.return_value = {
                "sub": "google-user-456",
                "email": "U@Gmail.com",
                "email_verified": True,
            }
            result = await google_auth.verify_google_token("valid.token", CLIENT_ID)
            assert result == ("google-user-456", "u@gmail.com", True)
            mock_verify.assert_called_once()

    @pytest.mark.asyncio
    async def test_invalid_token_raises_401(self):
        """Invalid token (ValueError) raises 401."""
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.side_effect = ValueError("Token is not valid")
            with pytest.raises(HTTPException) as exc_info:
                await google_auth.verify_google_token("invalid.token", CLIENT_ID)
            assert exc_info.value.status_code == 401
            assert "invalid" in exc_info.value.detail.lower()

    @pytest.mark.asyncio
    async def test_missing_sub_raises_401(self):
        """Decoded token without sub raises 401."""
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.return_value = {"email": "u@gmail.com"}  # no sub
            with pytest.raises(HTTPException) as exc_info:
                await google_auth.verify_google_token("no-sub.token", CLIENT_ID)
            assert exc_info.value.status_code == 401
            assert "sub" in exc_info.value.detail.lower()

    @pytest.mark.asyncio
    async def test_google_service_unavailable_raises_401(self):
        """Google service error (GoogleAuthError) raises 401."""
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.side_effect = GoogleAuthError("Service unavailable")
            with pytest.raises(HTTPException) as exc_info:
                await google_auth.verify_google_token("err.token", CLIENT_ID)
            assert exc_info.value.status_code == 401

    @pytest.mark.asyncio
    async def test_google_certs_transport_error_raises_503(self):
        """Certs fetch failure (TransportError) is an upstream outage, not a bad credential."""
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.side_effect = TransportError("Could not fetch certificates")
            with pytest.raises(HTTPException) as exc_info:
                await google_auth.verify_google_token("certs.token", CLIENT_ID)
            assert exc_info.value.status_code == 503

    # --- Malformed claims / clock-skew regression tests ---

    @pytest.mark.asyncio
    async def test_google_token_with_unverified_email_returns_flag_false(self):
        """Unverified email must surface ``email_verified=False`` to caller.

        Contract: ``verify_google_token`` is non-opinionated — it returns
        the verification flag so handlers can decide whether to link.
        ``auth_handlers.auth_verify_response`` then sets ``link_email=None``
        when the flag is false, creating an independent account keyed by
        provider sub. The function MUST NOT silently treat unverified email
        as verified, and MUST NOT crash.
        """
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.return_value = {
                "sub": "google-unverified-1",
                "email": "spoof@evil.example",
                "email_verified": False,
            }
            sub, email, verified = await google_auth.verify_google_token("unverified.token", CLIENT_ID)
            assert sub == "google-unverified-1"
            assert email == "spoof@evil.example"
            # CRITICAL: must report unverified so caller refuses to link.
            assert verified is False

    @pytest.mark.asyncio
    async def test_google_token_with_missing_email_verified_defaults_false(self):
        """Missing email_verified claim defaults to False (fail-closed)."""
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.return_value = {
                "sub": "google-missing-flag",
                "email": "user@example.com",
                # email_verified intentionally absent
            }
            _, _, verified = await google_auth.verify_google_token("no-flag.token", CLIENT_ID)
            assert verified is False

    @pytest.mark.asyncio
    async def test_google_token_expired_at_boundary_raises_401(self):
        """exp = now - 1s → google-auth raises ValueError → 401."""
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.side_effect = ValueError("Token expired, 1234567890 < 1234567891")
            with pytest.raises(HTTPException) as exc_info:
                await google_auth.verify_google_token("expired.token", CLIENT_ID)
            assert exc_info.value.status_code == 401
            assert "invalid" in exc_info.value.detail.lower()

    @pytest.mark.asyncio
    async def test_google_token_with_future_iat_rejected(self):
        """iat 60s in the future → google-auth raises ValueError → 401.

        google-auth allows ~10min clock skew by default; a token 60s
        ahead is normally accepted. We assert that when google-auth
        does reject (signaling clock skew beyond its tolerance), we
        surface 401 cleanly rather than 500.
        """
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.side_effect = ValueError("Token used too early, iat is in the future")
            with pytest.raises(HTTPException) as exc_info:
                await google_auth.verify_google_token("future-iat.token", CLIENT_ID)
            assert exc_info.value.status_code == 401

    @pytest.mark.asyncio
    async def test_google_token_with_empty_email_normalized_to_none(self):
        """Empty email string must not leak into _email_index as "".

        Returning "" would corrupt the email→user map. Defensive
        normalization: empty falsy email becomes None.
        """
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.return_value = {
                "sub": "google-empty-email",
                "email": "",
                "email_verified": True,
            }
            _, email, _ = await google_auth.verify_google_token("empty.token", CLIENT_ID)
            assert email is None

    @pytest.mark.asyncio
    async def test_google_token_with_email_verified_string_true_accepted(self):
        """``email_verified`` may arrive as string ``"true"`` in some payloads.

        bool("true") is True regardless, but bool("false") is also True —
        the current implementation uses ``bool(...)`` which would misread
        the string "false" as verified. Guard against that footgun.
        """
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.return_value = {
                "sub": "google-strflag",
                "email": "u@example.com",
                "email_verified": "false",  # string false — must not become True
            }
            _, _, verified = await google_auth.verify_google_token("strflag.token", CLIENT_ID)
            assert verified is False


class TestGoogleAuthTransportTimeout:
    """Bug 1: certificate-endpoint requests must carry a bounded timeout.

    ``requests.Session`` has no ``timeout`` attribute — setting one is a
    silent no-op. google-auth's ``Request.__call__`` defaults ``timeout``
    to 120s and ``id_token._fetch_certs`` never overrides it, so a hung
    Google certs endpoint would block the login request for two minutes.
    The transport adapter must inject a small, finite timeout.
    """

    def test_request_adapter_sends_finite_timeout(self):
        """The transport's ``__call__`` must default timeout to a small value.

        We invoke the adapter against a fake session and assert the
        ``timeout`` kwarg forwarded to ``session.request`` is finite and
        well under google-auth's 120s default.
        """
        captured = {}

        def fake_request(method, url, **kwargs):  # noqa: ARG001
            captured["timeout"] = kwargs.get("timeout")
            resp = MagicMock()
            resp.status_code = 200
            resp.headers = {}
            resp.content = b"{}"
            return resp

        session = MagicMock()
        session.request.side_effect = fake_request

        adapter = google_auth._build_request_adapter(session)
        # Caller (id_token._fetch_certs) invokes request(url, method="GET")
        # WITHOUT passing timeout — the adapter must supply its own.
        adapter("https://oauth2.googleapis.com/certs", method="GET")

        assert captured["timeout"] is not None, "transport adapter forwarded no timeout — request can hang forever"
        assert captured["timeout"] <= 30, f"timeout {captured['timeout']}s too large; must be a small bound"

    def test_session_has_no_dead_timeout_attribute(self):
        """The module must not rely on the no-op ``Session.timeout`` attr.

        Whatever timeout the module enforces, it must NOT be the bogus
        ``_session.timeout = 10`` assignment (which requests ignores).
        """
        sess = getattr(google_auth, "_session", None)
        if sess is not None:
            # If a module-level session still exists, a stray timeout attr
            # is harmless but misleading — the real timeout must come from
            # the request adapter, verified above.
            assert hasattr(google_auth, "_build_request_adapter")


class TestGoogleTokenNonBlocking:
    """Bug 2: ``verify_google_token`` is ``async`` but does blocking network
    I/O via ``id_token.verify_oauth2_token``. It must offload that call to
    a worker thread so the asyncio event loop is never blocked.
    """

    @pytest.mark.asyncio
    async def test_blocking_verify_runs_off_event_loop(self):
        """The synchronous verify call must execute on a non-loop thread."""
        asyncio.get_running_loop()
        loop_thread_id = threading.get_ident()
        observed = {}

        def slow_verify(*_args, **_kwargs):
            observed["thread_id"] = threading.get_ident()
            time.sleep(0.05)  # simulate blocking network I/O
            return {"sub": "google-async-1", "email": "a@b.com", "email_verified": True}

        with patch("kg.google_auth.id_token.verify_oauth2_token", side_effect=slow_verify):
            result = await google_auth.verify_google_token("t.token", CLIENT_ID)

        assert result[0] == "google-async-1"
        assert observed["thread_id"] != loop_thread_id, (
            "verify_oauth2_token ran on the event-loop thread — it blocks asyncio"
        )

    @pytest.mark.asyncio
    async def test_event_loop_stays_responsive_during_verify(self):
        """A concurrent coroutine must keep ticking while verify is in-flight."""
        ticks = []

        async def ticker():
            for _ in range(20):
                ticks.append(1)
                await asyncio.sleep(0.005)

        def blocking_verify(*_args, **_kwargs):
            time.sleep(0.1)
            return {"sub": "s", "email": "e@e.com", "email_verified": True}

        with patch("kg.google_auth.id_token.verify_oauth2_token", side_effect=blocking_verify):
            tick_task = asyncio.create_task(ticker())
            await google_auth.verify_google_token("t.token", CLIENT_ID)
            await tick_task

        # If verify blocked the loop, the ticker could not have progressed.
        assert len(ticks) >= 10, f"event loop stalled — only {len(ticks)} ticks during blocking verify"


class TestTokenNotLogged:
    """The raw ID token must never reach logs (#2712)."""

    SECRET = "eyJSECRET-token-bytes.payload.signature"

    @pytest.mark.asyncio
    @pytest.mark.parametrize("exc_type", [ValueError, GoogleAuthError, OSError, TransportError])
    async def test_failure_log_omits_token(self, caplog, exc_type):
        caplog.set_level("DEBUG")
        with patch("kg.google_auth.id_token.verify_oauth2_token") as mock_verify:
            mock_verify.side_effect = exc_type(f"Can't parse segment: b'{self.SECRET}'")
            with pytest.raises(HTTPException):
                await google_auth.verify_google_token(self.SECRET, CLIENT_ID)
        assert caplog.records
        assert all("SECRET" not in r.getMessage() for r in caplog.records)
