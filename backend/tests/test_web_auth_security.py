"""Security boundary tests for web auth & admin session.

Complements ``test_web_auth.py`` (happy path), ``test_web_auth_state.py``
(state mismatch), and ``test_admin_security.py`` (unit-level cookie
tampering). The tests here exercise the **HTTP-level** boundaries that the
existing suites do not cover:

- OAuth state replay after a successful callback consumes the cookie.
- Admin session cookie with tampered signature/payload/nonce rejected via
  a live admin endpoint (defense-in-depth on top of the unit tests).
- Admin session cookie with past expiry rejected via a live admin endpoint.
- OAuth callback issued with the right ``state`` query param but a cookie
  whose value has been mutated by one byte (signature would not collide).

These guard the auth boundary against regressions where a refactor wires
cookie verification through a new code path that skips the existing checks.
"""

from __future__ import annotations

import json
import time
from types import SimpleNamespace
from unittest.mock import patch

import httpx
import pytest
from fastapi.testclient import TestClient

import kg.api as api_mod
import kg.deps as deps_mod
from conftest import TEST_GOOGLE_REDIRECT_URI, TEST_JWT_SECRET, _swap_settings
from kg.admin_handlers import _build_cookie_value, _sign_cookie
from kg.api import app
from kg.settings import KGSettings

ADMIN_TOKEN = "test-admin-token-for-security-suite"


# ── shared fixtures ───────────────────────────────────────────────────────────


@pytest.fixture()
def web_auth_env(tmp_path):
    """Web-auth + admin-token env (separate from test_web_auth_state to keep
    settings tweaks isolated)."""
    data_dir = tmp_path
    (data_dir / "users").mkdir()
    users_file = data_dir / "users.json"
    users_file.write_text(json.dumps({"_meta": {}}))

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
        admin_token=ADMIN_TOKEN,
    )
    _swap_settings(test_settings)

    lifecycle = {"constructed": 0, "entered": 0, "exited": 0}

    class TrackingTestClient(TestClient):
        def __init__(self, *args, **kwargs):
            lifecycle["constructed"] += 1
            super().__init__(*args, **kwargs)

        def __enter__(self):
            lifecycle["entered"] += 1
            return super().__enter__()

        def __exit__(self, *args):
            lifecycle["exited"] += 1
            return super().__exit__(*args)

    try:
        api_mod._USER_LOCKS.clear()
        deps_mod._USER_LOCKS_MUTEX = None
        with TrackingTestClient(app, base_url="https://testserver", raise_server_exceptions=False) as client:
            yield SimpleNamespace(client=client, data_dir=data_dir)
    finally:
        assert lifecycle == {"constructed": 1, "entered": 1, "exited": 1}
        app.state.kg_settings = original_settings
        app.state.load_users = original_load
        app.state.save_users = original_save


def _bootstrap_google_state(client: TestClient) -> str:
    """Hit /auth/web/google/login and return the minted state nonce (also
    deposits the matching oauth_state cookie in the TestClient cookie jar)."""
    resp = client.get("/auth/web/google/login", follow_redirects=False)
    assert resp.status_code == 307
    # state appears in redirect URL ?state=... and as oauth_state cookie
    from urllib.parse import parse_qs, urlparse

    state = parse_qs(urlparse(resp.headers["location"]).query)["state"][0]
    return state


def _patch_google_token_exchange():
    """Context manager — stub Google token exchange + id_token verification."""
    fake_token_resp = httpx.Response(
        200,
        json={"id_token": "fake-id-token"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )

    async def fake_post(self, url, data=None, **kwargs):
        return fake_token_resp

    async def fake_verify(token, client_id):
        return "google-user-replay", "replay@example.com", True

    return patch("httpx.AsyncClient.post", new=fake_post), patch(
        "kg.routers.web_auth.verify_google_token", new=fake_verify
    )


# ── 1. OAuth state replay after consume ──────────────────────────────────────


def test_oauth_state_replay_after_consume_rejected(web_auth_env):
    """A successful callback clears the oauth_state cookie; reusing the same
    ``state`` value on a second callback must fail with 400 because the cookie
    no longer matches (replay defense)."""
    client = web_auth_env.client
    state = _bootstrap_google_state(client)

    post_patch, verify_patch = _patch_google_token_exchange()
    with post_patch, verify_patch:
        first = client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )
    assert first.status_code == 200, first.text
    # _clear_state_cookie sends Max-Age=0; httpx TestClient honours it.
    assert "oauth_state" not in client.cookies

    # Second use of the same state nonce — cookie gone → 400.
    second_post, second_verify = _patch_google_token_exchange()
    with second_post, second_verify:
        second = client.get(
            f"/auth/web/google/callback?code=fake-code&state={state}",
            follow_redirects=False,
        )
    assert second.status_code == 400, second.text


def test_oauth_state_replay_with_attacker_held_cookie_rejected(web_auth_env):
    """#2804: clearing the cookie client-side is not enough — an attacker who keeps
    (or forges) the cookie must not be able to reuse a consumed nonce."""
    client = web_auth_env.client
    state = _bootstrap_google_state(client)

    post_patch, verify_patch = _patch_google_token_exchange()
    with post_patch, verify_patch:
        first = client.get(f"/auth/web/google/callback?code=fake-code&state={state}", follow_redirects=False)
    assert first.status_code == 200, first.text

    client.cookies.set("oauth_state", state, path="/auth/web/")
    calls = []

    async def counting_post(self, url, data=None, **kwargs):
        calls.append(url)
        raise AssertionError("replayed state must not reach Google")

    with patch("httpx.AsyncClient.post", new=counting_post):
        second = client.get(f"/auth/web/google/callback?code=fake-code&state={state}", follow_redirects=False)
    assert second.status_code == 400, second.text
    assert calls == []


def test_oauth_callback_with_unissued_state_never_calls_google(web_auth_env):
    """#2804: equal cookie and state is not enough; the nonce must have been
    issued by /auth/web/google/login, so junk callbacks cost no outbound call."""
    client = web_auth_env.client
    client.cookies.set("oauth_state", "forged-nonce", path="/auth/web/")
    calls = []

    async def counting_post(self, url, data=None, **kwargs):
        calls.append(url)
        raise AssertionError("unissued state must not reach Google")

    with patch("httpx.AsyncClient.post", new=counting_post):
        resp = client.get("/auth/web/google/callback?code=junk&state=forged-nonce", follow_redirects=False)
    assert resp.status_code == 400, resp.text
    assert calls == []


def test_issued_google_states_expire_and_are_bounded():
    from kg.routers import web_auth

    store = web_auth._OAuthStateStore(ttl_seconds=10, max_entries=3)
    store.issue("a", now=0)
    assert store.consume("a", now=5) is True
    assert store.consume("a", now=5) is False
    store.issue("b", now=0)
    assert store.consume("b", now=11) is False
    for i, n in enumerate("cdef"):
        store.issue(n, now=100 + i)
    assert store.consume("c", now=105) is False  # evicted, oldest first
    assert store.consume("f", now=105) is True


def test_issue_prunes_expired_entries():
    from kg.routers import web_auth

    store = web_auth._OAuthStateStore(ttl_seconds=10, max_entries=100)
    store.issue("old1", now=0)
    store.issue("old2", now=1)
    store.issue("fresh", now=50)
    assert list(store._issued) == ["fresh"]
    # Over-pruning guard: a later issue inside the TTL must keep unexpired entries.
    store.issue("later", now=51)
    assert "fresh" in store._issued
    assert store.consume("fresh", now=52) is True


def test_oauth_callback_with_mismatched_state_rejected(web_auth_env):
    """End-to-end CSRF guard: cookie-stored nonce ≠ provider-returned state
    must yield 400 with no session cookie set."""
    client = web_auth_env.client
    _bootstrap_google_state(client)  # plants oauth_state cookie

    resp = client.get(
        "/auth/web/google/callback?code=fake-code&state=attacker-nonce",
        follow_redirects=False,
    )
    assert resp.status_code == 400
    # No JWT/session token emitted on rejection.
    assert "fake-id-token" not in resp.text
    # No admin/session cookie is emitted on failure.
    assert "admin_session=" not in resp.headers.get("set-cookie", "")


# ── 2. Admin session cookie tampering via HTTP ───────────────────────────────


def test_admin_session_cookie_signature_tampered_rejected(web_auth_env):
    """Mutating a single byte of the HMAC signature must cause the admin
    endpoint to refuse the request (HTTP 403)."""
    client = web_auth_env.client
    signed = _sign_cookie(ADMIN_TOKEN)
    expires_at, nonce, sig = signed.split(".")
    # Flip first hex digit of signature (0->1 / a->b etc.).
    flipped = ("1" if sig[0] == "0" else "0") + sig[1:]
    tampered = f"{expires_at}.{nonce}.{flipped}"
    assert tampered != signed

    client.cookies.set("admin_session", tampered)
    resp = client.get("/api/admin/stats")
    assert resp.status_code == 403


def test_admin_session_cookie_nonce_tampered_rejected(web_auth_env):
    """Mutating the nonce while leaving signature intact also fails — the
    signature covers ``expires_at.nonce`` so any byte change invalidates it."""
    client = web_auth_env.client
    signed = _sign_cookie(ADMIN_TOKEN)
    expires_at, nonce, sig = signed.split(".")
    # Flip first hex digit of nonce.
    flipped_nonce = ("1" if nonce[0] == "0" else "0") + nonce[1:]
    tampered = f"{expires_at}.{flipped_nonce}.{sig}"

    client.cookies.set("admin_session", tampered)
    resp = client.get("/api/admin/stats")
    assert resp.status_code == 403


def test_admin_session_cookie_payload_extended_rejected(web_auth_env):
    """Pushing ``expires_at`` into the far future without re-signing must be
    rejected at the HTTP layer (HMAC verification covers expires_at)."""
    client = web_auth_env.client
    signed = _sign_cookie(ADMIN_TOKEN)
    expires_at, nonce, sig = signed.split(".")
    forged = f"{int(expires_at) + 10**9}.{nonce}.{sig}"

    client.cookies.set("admin_session", forged)
    resp = client.get("/api/admin/stats")
    assert resp.status_code == 403


# ── 3. Admin session cookie expired ──────────────────────────────────────────


def test_admin_session_cookie_expired_rejected(web_auth_env):
    """A correctly-signed cookie whose embedded ``expires_at`` is in the past
    must be rejected at the HTTP boundary."""
    client = web_auth_env.client
    expired_at = int(time.time()) - 60  # 1 minute past
    expired = _build_cookie_value(ADMIN_TOKEN, expires_at=expired_at)

    client.cookies.set("admin_session", expired)
    resp = client.get("/api/admin/stats")
    assert resp.status_code == 403


def test_admin_session_cookie_at_boundary_just_expired_rejected(web_auth_env):
    """One-second past expiry is still rejected (off-by-one guard)."""
    client = web_auth_env.client
    expired = _build_cookie_value(ADMIN_TOKEN, expires_at=int(time.time()) - 1)

    client.cookies.set("admin_session", expired)
    resp = client.get("/api/admin/stats")
    assert resp.status_code == 403


def test_admin_session_cookie_valid_future_accepted(web_auth_env):
    """Sanity: a freshly-signed cookie with a future expiry IS accepted —
    proves the rejection tests above aren't always-403 false positives."""
    client = web_auth_env.client
    valid = _sign_cookie(ADMIN_TOKEN)

    client.cookies.set("admin_session", valid)
    resp = client.get("/api/admin/stats")
    # /api/admin/stats returns 200 on auth success (body shape covered elsewhere).
    assert resp.status_code == 200
