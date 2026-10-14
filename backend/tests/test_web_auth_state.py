"""Tests for OAuth state CSRF protection in web auth flow."""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

import kg.api as api_mod
import kg.deps as deps_mod
from conftest import TEST_GOOGLE_REDIRECT_URI, TEST_JWT_SECRET, _swap_settings
from kg.api import app
from kg.routers import web_auth
from kg.settings import KGSettings


@pytest.fixture()
def web_auth_env(tmp_path):
    data_dir = tmp_path
    (data_dir / "users").mkdir()
    users_file = data_dir / "users.json"
    users_file.write_text(json.dumps({}))

    original_settings = app.state.kg_settings
    original_load = app.state.load_users
    original_save = app.state.save_users
    test_settings = KGSettings(
        data_dir=data_dir,
        jwt_secret=TEST_JWT_SECRET,
        google_client_id="test-google-client-id",
        google_client_secret="test-google-client-secret",
        google_redirect_uri=TEST_GOOGLE_REDIRECT_URI,
        apple_bundle_id="test.apple.bundle",
    )
    client = None

    try:
        _swap_settings(test_settings)
        api_mod._USER_LOCKS.clear()
        deps_mod._USER_LOCKS_MUTEX = None
        client = TestClient(app, base_url="https://testserver", raise_server_exceptions=False)
        yield SimpleNamespace(client=client, data_dir=data_dir)
    finally:
        try:
            if client is not None:
                client.close()
                assert client.is_closed, "web_auth_env must close its TestClient before restoring app state"
        finally:
            app.state.kg_settings = original_settings
            app.state.load_users = original_load
            app.state.save_users = original_save


def test_web_auth_env_restores_state_when_client_construction_fails(tmp_path, monkeypatch):
    original_settings = app.state.kg_settings
    original_load = app.state.load_users
    original_save = app.state.save_users

    def raising_test_client(*args, **kwargs):
        raise RuntimeError("test client construction failed")

    monkeypatch.setattr("test_web_auth_state.TestClient", raising_test_client)

    with pytest.raises(RuntimeError, match="test client construction failed"):
        next(web_auth_env.__wrapped__(tmp_path))

    assert app.state.kg_settings is original_settings
    assert app.state.load_users is original_load
    assert app.state.save_users is original_save


def _extract_state_from_redirect(location: str) -> str:
    qs = parse_qs(urlparse(location).query)
    return qs["state"][0]


# ---------- Google ----------


def test_google_login_sets_oauth_state_cookie(web_auth_env):
    resp = web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    assert resp.status_code == 307
    set_cookie = resp.headers.get("set-cookie", "")
    assert "oauth_state=" in set_cookie
    assert "HttpOnly" in set_cookie
    assert "SameSite=Lax" in set_cookie or "samesite=lax" in set_cookie.lower()
    # Also redirect URL must contain state
    state = _extract_state_from_redirect(resp.headers["location"])
    assert state and len(state) >= 16


def test_apple_login_state_cookie_is_samesite_none(web_auth_env):
    # Apple sign-in uses response_mode=form_post → the callback is a cross-site
    # top-level POST. Browsers do NOT attach a SameSite=Lax cookie to that, so
    # the Apple-bound state cookie must be SameSite=None; Secure (CSRF is still
    # enforced by the nonce comparison in _verify_state).
    resp = web_auth_env.client.get("/auth/web/apple/login", follow_redirects=False)
    set_cookie = resp.headers.get("set-cookie", "")
    assert "oauth_state=" in set_cookie
    lower = set_cookie.lower()
    assert "samesite=none" in lower
    assert "secure" in lower
    assert "httponly" in lower


def test_google_login_state_in_cookie_matches_redirect(web_auth_env):
    resp = web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    state_in_url = _extract_state_from_redirect(resp.headers["location"])
    # cookie value
    cookie_state = resp.cookies.get("oauth_state")
    assert cookie_state == state_in_url


def test_google_callback_missing_state_rejected(web_auth_env):
    # Set cookie via login first
    web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    # Callback without state query param
    resp = web_auth_env.client.get(
        "/auth/web/google/callback?code=fake-code",
        follow_redirects=False,
    )
    assert resp.status_code == 400


def test_google_callback_state_mismatch_rejected(web_auth_env):
    web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    resp = web_auth_env.client.get(
        "/auth/web/google/callback?code=fake-code&state=attacker-controlled",
        follow_redirects=False,
    )
    assert resp.status_code == 400


def test_google_callback_non_ascii_state_rejected_without_server_error(web_auth_env):
    """A provider-returned non-ASCII state must be a normal CSRF failure."""
    web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    resp = web_auth_env.client.get(
        "/auth/web/google/callback?code=fake-code&state=%C3%A9",
        follow_redirects=False,
    )
    assert resp.status_code == 400


def test_google_callback_missing_cookie_rejected(web_auth_env):
    # No login first → no cookie
    resp = web_auth_env.client.get(
        "/auth/web/google/callback?code=fake-code&state=anything",
        follow_redirects=False,
    )
    assert resp.status_code == 400


def test_google_callback_with_matching_state_proceeds(web_auth_env):
    login_resp = web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    state = _extract_state_from_redirect(login_resp.headers["location"])

    # Mock token exchange + id_token verification
    fake_token_resp = httpx.Response(
        200,
        json={"id_token": "fake-id-token"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )

    async def fake_post(self, url, data=None, **kwargs):
        return fake_token_resp

    async def fake_verify(token, client_id):
        return "google-user-123", "test@example.com", True

    with (
        patch("httpx.AsyncClient.post", new=fake_post),
        patch("kg.routers.web_auth.verify_google_token", new=fake_verify),
    ):
        resp = web_auth_env.client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )
    assert resp.status_code == 200, resp.text
    # Cookie should be cleared on success
    set_cookie = resp.headers.get("set-cookie", "")
    assert "oauth_state=" in set_cookie


def test_google_callback_token_exchange_network_error_returns_502(web_auth_env):
    """If reaching Google's token endpoint fails (DNS/connect/timeout — all
    httpx.HTTPError), the callback must return a semantic 502, not a bare 500.
    """
    login_resp = web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    state = _extract_state_from_redirect(login_resp.headers["location"])

    async def fake_post(self, url, data=None, **kwargs):
        raise httpx.ConnectError(
            "connection refused",
            request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
        )

    with patch("httpx.AsyncClient.post", new=fake_post):
        resp = web_auth_env.client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )
    assert resp.status_code == 502, resp.text


def test_google_callback_retries_transient_token_exchange_error(web_auth_env):
    login_resp = web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    state = _extract_state_from_redirect(login_resp.headers["location"])
    fake_token_resp = httpx.Response(
        200,
        json={"id_token": "fake-id-token"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )
    attempts = []

    async def fake_post(self, url, data=None, **kwargs):
        attempts.append(url)
        if len(attempts) == 1:
            raise httpx.ConnectError(
                "connection reset",
                request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
            )
        return fake_token_resp

    async def fake_verify(token, client_id):
        return "google-user-123", "test@example.com", True

    async def no_sleep(_seconds):
        return None

    with (
        patch("httpx.AsyncClient.post", new=fake_post),
        patch("kg.routers.web_auth.verify_google_token", new=fake_verify),
        patch("kg.routers.web_auth.asyncio.sleep", new=no_sleep),
    ):
        resp = web_auth_env.client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )

    assert resp.status_code == 200, resp.text
    assert len(attempts) == 2


def test_google_callback_pins_token_exchange_payload_and_url(web_auth_env):
    """Pins the server-side proof of code ownership: every token-exchange attempt
    must POST the exact authorization_code payload built from the live settings.
    """
    settings = app.state.kg_settings
    values = {
        settings.google_client_id,
        settings.google_client_secret,
        settings.google_redirect_uri,
    }
    # Distinct non-empty values so a field swap or blanking cannot pass by accident.
    assert all(values) and len(values) == 3

    login_resp = web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    state = _extract_state_from_redirect(login_resp.headers["location"])
    fake_token_resp = httpx.Response(
        200,
        json={"id_token": "fake-id-token"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )
    calls = []

    async def fake_post(self, url, data=None, **kwargs):
        calls.append((url, dict(data)))
        if len(calls) == 1:
            raise httpx.ConnectError(
                "connection reset",
                request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
            )
        return fake_token_resp

    async def fake_verify(token, client_id):
        return "google-user-123", "test@example.com", True

    async def no_sleep(_seconds):
        return None

    with (
        patch("httpx.AsyncClient.post", new=fake_post),
        patch("kg.routers.web_auth.verify_google_token", new=fake_verify),
        patch("kg.routers.web_auth.asyncio.sleep", new=no_sleep),
    ):
        resp = web_auth_env.client.get(
            f"/auth/web/google/callback?code=known-auth-code&state={state}",
            follow_redirects=False,
        )

    expected_payload = {
        "code": "known-auth-code",
        "client_id": settings.google_client_id,
        "client_secret": settings.google_client_secret,
        "redirect_uri": settings.google_redirect_uri,
        "grant_type": "authorization_code",
    }
    assert resp.status_code == 200, resp.text
    assert calls == [
        (web_auth.GOOGLE_TOKEN_URL, expected_payload),
        (web_auth.GOOGLE_TOKEN_URL, expected_payload),
    ]


# ---------- Apple ----------


def test_apple_login_sets_oauth_state_cookie(web_auth_env):
    resp = web_auth_env.client.get("/auth/web/apple/login", follow_redirects=False)
    # Either redirect to Apple or returns state cookie
    assert resp.status_code in (200, 302, 307)
    set_cookie = resp.headers.get("set-cookie", "")
    assert "oauth_state=" in set_cookie


def test_login_page_mints_state_for_apple_form_post(web_auth_env):
    """`/login` is the natural entry. It mints the callback state itself: sets
    the `oauth_state` cookie and renders an Apple form-post carrying the same
    nonce, so the POST callback's `_verify_state` (cookie vs form state) holds.
    """
    resp = web_auth_env.client.get("/login", follow_redirects=False)
    assert resp.status_code == 200
    assert "oauth_state=" in resp.headers.get("set-cookie", "")
    # Routes Apple users straight to authorize with a state nonce in the form.
    assert "appleid.apple.com/auth/authorize" in resp.text
    assert 'name="state"' in resp.text


def test_apple_callback_missing_state_rejected(web_auth_env):
    web_auth_env.client.get("/auth/web/apple/login", follow_redirects=False)
    resp = web_auth_env.client.post(
        "/auth/web/apple/callback",
        data={"id_token": "fake"},
    )
    assert resp.status_code == 400


def test_apple_callback_state_mismatch_rejected(web_auth_env):
    web_auth_env.client.get("/auth/web/apple/login", follow_redirects=False)
    resp = web_auth_env.client.post(
        "/auth/web/apple/callback",
        data={"id_token": "fake", "state": "attacker"},
    )
    assert resp.status_code == 400
