"""Tests for the web OAuth flow."""

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
    )
    _swap_settings(test_settings)

    try:
        api_mod._USER_LOCKS.clear()
        deps_mod._USER_LOCKS_MUTEX = None
        with TestClient(app, base_url="https://testserver", raise_server_exceptions=False) as client:
            yield SimpleNamespace(client=client, data_dir=data_dir)
    finally:
        app.state.kg_settings = original_settings
        app.state.load_users = original_load
        app.state.save_users = original_save


def test_login_page_returns_200_with_google(web_auth_env):
    resp = web_auth_env.client.get("/login")
    assert resp.status_code == 200
    assert "Google" in resp.text


def test_login_page_returns_200_with_apple(web_auth_env):
    resp = web_auth_env.client.get("/login")
    assert resp.status_code == 200
    assert "Apple" in resp.text


def test_google_login_redirects_to_google(web_auth_env):
    resp = web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    assert resp.status_code == 307
    location = resp.headers["location"]
    assert "accounts.google.com" in location
    assert "client_id=test-google-client-id" in location
    assert "redirect_uri=" in location
    assert "response_type=code" in location
    assert "scope=" in location


def test_web_auth_router_is_registered(web_auth_env):
    """The web_auth router should be included in the app."""
    routes = [r.path for r in app.routes]
    assert "/login" in routes
    assert "/auth/web/google/login" in routes
    assert "/auth/web/google/callback" in routes
    assert "/auth/web/apple/callback" in routes


# ── Google callback token-exchange failure branches ─────────────────────────
# Regression net for the two non-network failure paths in google_callback that
# the sibling suites do not cover (state CSRF lives in test_web_auth_state.py,
# network 502 + retry there too; replay in test_web_auth_security.py).


def _bootstrap_google_state(client: TestClient) -> str:
    resp = client.get("/auth/web/google/login", follow_redirects=False)
    assert resp.status_code == 307
    return parse_qs(urlparse(resp.headers["location"]).query)["state"][0]


def test_google_callback_token_exchange_non_200_returns_401(web_auth_env):
    """Upstream token endpoint replying non-200 (e.g. invalid_grant) → 401,
    not a leaked 500/200."""
    client = web_auth_env.client
    state = _bootstrap_google_state(client)

    fake_resp = httpx.Response(
        400,
        json={"error": "invalid_grant"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )

    async def fake_post(self, url, data=None, **kwargs):
        return fake_resp

    with patch("httpx.AsyncClient.post", new=fake_post):
        resp = client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )
    assert resp.status_code == 401, resp.text


@pytest.mark.parametrize("status_code", [500, 429])
def test_google_callback_exhausted_transient_token_exchange_returns_502(web_auth_env, status_code):
    """Exhausted upstream transient failures stay distinguishable from auth failures."""
    client = web_auth_env.client
    state = _bootstrap_google_state(client)
    attempts = []
    sleeps = []
    fake_resp = httpx.Response(
        status_code,
        json={"error": "temporarily_unavailable"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )

    async def fake_post(self, url, data=None, **kwargs):
        attempts.append(url)
        return fake_resp

    async def fake_sleep(seconds):
        sleeps.append(seconds)

    with (
        patch("httpx.AsyncClient.post", new=fake_post),
        patch("kg.routers.web_auth.asyncio.sleep", new=fake_sleep),
        patch("kg.routers.web_auth.verify_google_token") as verify_mock,
        patch("kg.routers.web_auth._resolve_and_link_user") as resolve_mock,
    ):
        resp = client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )

    assert resp.status_code == 502, resp.text
    assert resp.json() == {"detail": "Failed to reach Google authentication service"}
    assert len(attempts) == 3
    assert sleeps == [0.2, 0.5]
    verify_mock.assert_not_called()
    resolve_mock.assert_not_called()


def test_google_callback_missing_id_token_returns_401(web_auth_env):
    """A 200 token response that omits ``id_token`` → 401 (no OIDC identity to
    verify), guarding against a None slipping into verify_google_token."""
    client = web_auth_env.client
    state = _bootstrap_google_state(client)

    fake_resp = httpx.Response(
        200,
        json={"access_token": "opaque-no-id-token"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )

    async def fake_post(self, url, data=None, **kwargs):
        return fake_resp

    with patch("httpx.AsyncClient.post", new=fake_post):
        resp = client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )
    assert resp.status_code == 401, resp.text


# ── Success page must not be cached (#2092) ─────────────────────────────────
# login_success.html embeds a 7-day bearer JWT. A cacheable copy can be
# replayed via back/forward or the browser cache on a shared machine.


def _assert_success_page_not_cacheable(resp: httpx.Response) -> None:
    assert resp.status_code == 200, resp.text
    assert 'id="token-display"' in resp.text, "expected the JWT-bearing success page"
    cache_directives = [d.strip().lower() for d in resp.headers.get("cache-control", "").split(",")]
    assert "no-store" in cache_directives, resp.headers.get("cache-control")
    assert resp.headers.get("pragma") == "no-cache"


def test_google_callback_success_page_is_not_cacheable(web_auth_env):
    client = web_auth_env.client
    state = _bootstrap_google_state(client)
    fake_resp = httpx.Response(
        200,
        json={"id_token": "fake-id-token"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )

    async def fake_post(self, url, data=None, **kwargs):
        return fake_resp

    async def fake_verify(token, client_id):
        return "google-user-123", "google@example.com", True

    with (
        patch("httpx.AsyncClient.post", new=fake_post),
        patch("kg.routers.web_auth.verify_google_token", new=fake_verify),
    ):
        resp = client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )

    _assert_success_page_not_cacheable(resp)


def test_apple_callback_success_page_is_not_cacheable(web_auth_env):
    client = web_auth_env.client
    login_resp = client.get("/auth/web/apple/login", follow_redirects=False)
    assert login_resp.status_code == 307
    state = parse_qs(urlparse(login_resp.headers["location"]).query)["state"][0]

    with patch(
        "kg.routers.web_auth.verify_apple_token",
        return_value=("apple-user-123", "apple@example.com", True),
    ):
        resp = client.post(
            "/auth/web/apple/callback",
            data={"id_token": "fake-apple-id-token", "state": state},
            follow_redirects=False,
        )

    _assert_success_page_not_cacheable(resp)


# ── Provider error redaction (B1) ────────────────────────────────────────────
# OAuth callbacks must NOT echo the upstream provider's ``error`` string back to
# the client (it can carry provider-internal hints). The client receives a
# generic 400; the raw provider error is logged server-side at WARNING.

_PROVIDER_ERROR_SENTINEL = "access_denied_internal_provider_hint_xyz"


def test_google_callback_provider_error_is_redacted(web_auth_env, caplog):
    """Google callback ``?error=<x>`` → 400 with generic body (no ``<x>``) and a
    server-side WARNING carrying the raw provider error."""
    client = web_auth_env.client
    with caplog.at_level("WARNING", logger="kg.routers.web_auth"):
        resp = client.get(
            f"/auth/web/google/callback?error={_PROVIDER_ERROR_SENTINEL}",
            follow_redirects=False,
        )
    assert resp.status_code == 400, resp.text
    assert _PROVIDER_ERROR_SENTINEL not in resp.text
    assert any(_PROVIDER_ERROR_SENTINEL in record.getMessage() for record in caplog.records), (
        "raw provider error must be logged server-side"
    )


def test_apple_callback_provider_error_is_redacted(web_auth_env, caplog):
    """Apple callback ``error=<x>`` (form POST) → 400 with generic body (no
    ``<x>``) and a server-side WARNING carrying the raw provider error."""
    client = web_auth_env.client
    with caplog.at_level("WARNING", logger="kg.routers.web_auth"):
        resp = client.post(
            "/auth/web/apple/callback",
            data={
                "id_token": "unused-when-error-present",
                "error": _PROVIDER_ERROR_SENTINEL,
            },
            follow_redirects=False,
        )
    assert resp.status_code == 400, resp.text
    assert _PROVIDER_ERROR_SENTINEL not in resp.text
    assert any(_PROVIDER_ERROR_SENTINEL in record.getMessage() for record in caplog.records), (
        "raw provider error must be logged server-side"
    )


def test_apple_callback_provider_error_without_id_token_returns_400(web_auth_env, caplog):
    """Apple error form-posts may omit ``id_token`` and must still reach the
    generic provider-error response instead of FastAPI's validation 422."""
    client = web_auth_env.client
    with caplog.at_level("WARNING", logger="kg.routers.web_auth"):
        resp = client.post(
            "/auth/web/apple/callback",
            data={"error": _PROVIDER_ERROR_SENTINEL},
            follow_redirects=False,
        )
    assert resp.status_code == 400, resp.text
    assert _PROVIDER_ERROR_SENTINEL not in resp.text
    assert any(_PROVIDER_ERROR_SENTINEL in record.getMessage() for record in caplog.records), (
        "raw provider error must be logged server-side"
    )


# ── Cookie security attributes (full assertion) ──────────────────────────────


def test_google_login_state_cookie_security_attributes(web_auth_env):
    """The oauth_state cookie must be HttpOnly + Secure + scoped to
    Path=/auth/web/ so it never leaks to other paths or to JS."""
    resp = web_auth_env.client.get("/auth/web/google/login", follow_redirects=False)
    set_cookie = resp.headers.get("set-cookie", "").lower()
    assert "oauth_state=" in set_cookie
    assert "httponly" in set_cookie
    assert "secure" in set_cookie
    assert "path=/auth/web/" in set_cookie
    assert "samesite=lax" in set_cookie


def test_apple_login_state_cookie_security_attributes(web_auth_env):
    """Apple's state cookie is SameSite=None (cross-site form_post) but must
    still be HttpOnly + Secure + Path=/auth/web/."""
    resp = web_auth_env.client.get("/auth/web/apple/login", follow_redirects=False)
    set_cookie = resp.headers.get("set-cookie", "").lower()
    assert "oauth_state=" in set_cookie
    assert "httponly" in set_cookie
    assert "secure" in set_cookie
    assert "path=/auth/web/" in set_cookie
    assert "samesite=none" in set_cookie


def test_google_callback_provider_error_log_is_length_capped(web_auth_env, caplog):
    """#2303: attacker-controlled ``error`` must be truncated before logging."""
    client = web_auth_env.client
    with caplog.at_level("WARNING", logger="kg.routers.web_auth"):
        resp = client.get(f"/auth/web/google/callback?error={'a' * 5000}", follow_redirects=False)
    assert resp.status_code == 400
    messages = [r.getMessage() for r in caplog.records if r.name == "kg.routers.web_auth"]
    assert messages
    assert all(len(m) < 400 for m in messages)


def test_apple_callback_provider_error_log_is_length_capped(web_auth_env, caplog):
    client = web_auth_env.client
    with caplog.at_level("WARNING", logger="kg.routers.web_auth"):
        resp = client.post("/auth/web/apple/callback", data={"error": "a" * 5000}, follow_redirects=False)
    assert resp.status_code == 400
    messages = [r.getMessage() for r in caplog.records if r.name == "kg.routers.web_auth"]
    assert messages
    assert all(len(m) < 400 for m in messages)


# ── Unverified-email guard on web callbacks (#3730) ─────────────────────────
# The web callbacks must hand _resolve_and_link_user email=None whenever the
# provider reports email_verified=False, so an unverified address can never be
# matched against (and link to) an existing account.


def _google_callback_resolve_mock(client, identity):
    state = _bootstrap_google_state(client)
    fake_resp = httpx.Response(
        200,
        json={"id_token": "fake-id-token"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )

    async def fake_post(self, url, data=None, **kwargs):
        return fake_resp

    async def fake_verify(token, client_id):
        return identity

    with (
        patch("httpx.AsyncClient.post", new=fake_post),
        patch("kg.routers.web_auth.verify_google_token", new=fake_verify),
        patch("kg.routers.web_auth._resolve_and_link_user", return_value="kg-user-1") as resolve_mock,
    ):
        resp = client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )
    assert resp.status_code == 200, resp.text
    resolve_mock.assert_called_once()
    return resolve_mock


@pytest.mark.parametrize(("verified", "expected_email"), [(False, None), (True, "victim@x.com")])
def test_google_callback_passes_email_only_when_verified(web_auth_env, verified, expected_email):
    resolve_mock = _google_callback_resolve_mock(web_auth_env.client, ("attacker-sub", "victim@x.com", verified))
    assert resolve_mock.call_args.kwargs["email"] == expected_email


def _apple_callback_resolve_mock(client, identity):
    login_resp = client.get("/auth/web/apple/login", follow_redirects=False)
    assert login_resp.status_code == 307
    state = parse_qs(urlparse(login_resp.headers["location"]).query)["state"][0]

    with (
        patch("kg.routers.web_auth.verify_apple_token", return_value=identity),
        patch("kg.routers.web_auth._resolve_and_link_user", return_value="kg-user-1") as resolve_mock,
    ):
        resp = client.post(
            "/auth/web/apple/callback",
            data={"id_token": "fake-apple-id-token", "state": state},
            follow_redirects=False,
        )
    assert resp.status_code == 200, resp.text
    resolve_mock.assert_called_once()
    return resolve_mock


@pytest.mark.parametrize(("verified", "expected_email"), [(False, None), (True, "victim@x.com")])
def test_apple_callback_passes_email_only_when_verified(web_auth_env, verified, expected_email):
    resolve_mock = _apple_callback_resolve_mock(web_auth_env.client, ("attacker-sub", "victim@x.com", verified))
    assert resolve_mock.call_args.kwargs["email"] == expected_email


# ── OAuth audience pinning on web success paths (#3731) ──────────────────────
# The id_token must be verified against the *web* audience: the Google web
# client ID and the Apple Services ID, never the Google client secret or the
# native bundle ID. Capture the audience argument to pin it.


def test_google_callback_verifies_id_token_against_web_client_id(web_auth_env):
    client = web_auth_env.client
    settings = app.state.kg_settings
    assert settings.google_client_id != settings.google_client_secret
    state = _bootstrap_google_state(client)
    fake_resp = httpx.Response(
        200,
        json={"id_token": "fake-id-token"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )
    audiences = []

    async def fake_post(self, url, data=None, **kwargs):
        return fake_resp

    async def fake_verify(token, client_id):
        audiences.append(client_id)
        return "google-user-123", "google@example.com", True

    with (
        patch("httpx.AsyncClient.post", new=fake_post),
        patch("kg.routers.web_auth.verify_google_token", new=fake_verify),
    ):
        resp = client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )

    assert resp.status_code == 200, resp.text
    assert audiences == [settings.google_client_id]
    assert audiences != [settings.google_client_secret]


def test_apple_callback_verifies_id_token_against_service_id(web_auth_env):
    client = web_auth_env.client
    settings = app.state.kg_settings
    assert settings.apple_service_id != settings.apple_bundle_id
    login_resp = client.get("/auth/web/apple/login", follow_redirects=False)
    assert login_resp.status_code == 307
    state = parse_qs(urlparse(login_resp.headers["location"]).query)["state"][0]
    audiences = []

    def fake_verify_apple(token, audience):
        audiences.append(audience)
        return "apple-user-123", "apple@example.com", True

    with patch("kg.routers.web_auth.verify_apple_token", new=fake_verify_apple):
        resp = client.post(
            "/auth/web/apple/callback",
            data={"id_token": "fake-apple-id-token", "state": state},
            follow_redirects=False,
        )

    assert resp.status_code == 200, resp.text
    assert audiences == [settings.apple_service_id]
    assert audiences != [settings.apple_bundle_id]


# ── Apple login authorize redirect (#3733) ───────────────────────────────────
# Pin the Location query the browser is sent to Apple with: client_id, the
# code+id_token response type, form_post response mode, and the state nonce
# that must match the oauth_state cookie.


def test_apple_login_redirect_pins_authorize_params(web_auth_env):
    settings = app.state.kg_settings
    resp = web_auth_env.client.get("/auth/web/apple/login", follow_redirects=False)
    assert resp.status_code == 307, resp.text
    location = urlparse(resp.headers["location"])
    assert location.scheme == "https"
    assert location.netloc == "appleid.apple.com"
    assert location.path == "/auth/authorize"

    params = parse_qs(location.query)
    assert params["client_id"] == [settings.apple_service_id]
    assert params["response_type"] == ["code id_token"]
    assert params["response_mode"] == ["form_post"]
    assert params["scope"] == ["email"]
    assert params["redirect_uri"] == [settings.apple_redirect_uri]
    assert params["state"][0]
    assert f"oauth_state={params['state'][0]}" in resp.headers.get("set-cookie", "")
