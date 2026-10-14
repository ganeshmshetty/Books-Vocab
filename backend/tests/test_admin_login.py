"""Tests for admin password login flow (/admin/login)."""

from __future__ import annotations

import pytest

from conftest import ADMIN_TOKEN
from kg.admin_handlers import _sign_cookie

ADMIN_PASSWORD = "my-secret-admin-password"


@pytest.fixture()
def admin_app(admin_app_factory):
    return admin_app_factory(admin_token=ADMIN_TOKEN, admin_password=ADMIN_PASSWORD)


@pytest.fixture()
def admin_app_no_password(admin_app_factory):
    """App with admin_password empty (password login disabled)."""
    return admin_app_factory(admin_token=ADMIN_TOKEN, admin_password="")


# ── 1. GET /admin/login returns 200 + HTML ─────────────────────────────────


def test_login_page_returns_html(admin_app):
    resp = admin_app.client.get("/admin/login")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "<form" in resp.text.lower()


# ── 2. POST /admin/login correct password → 302 + Set-Cookie ──────────────


def test_login_correct_password_redirects(admin_app):
    resp = admin_app.client.post(
        "/admin/login",
        data={"password": ADMIN_PASSWORD},
        follow_redirects=False,
    )
    assert resp.status_code == 302
    assert resp.headers["location"] == "/admin"
    cookie_header = resp.headers.get("set-cookie", "")
    # Cookie value is now an expiry-bound token (expires_at.nonce.sig);
    # extract and verify it round-trips through _verify_cookie.
    import re

    from kg.admin_handlers import _verify_cookie

    m = re.search(r"admin_session=([^;]+)", cookie_header)
    assert m is not None
    assert _verify_cookie(m.group(1), ADMIN_TOKEN)


# ── 3. POST /admin/login wrong password → login page + error ──────────────


def test_login_wrong_password_shows_error(admin_app):
    resp = admin_app.client.post(
        "/admin/login",
        data={"password": "wrong-password"},
        follow_redirects=False,
    )
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    # Should contain an error message
    assert "密碼錯誤" in resp.text or "error" in resp.text.lower()


# ── 4. POST /admin/login with empty ADMIN_PASSWORD → 403 ─────────────────


def test_login_post_disabled_returns_403(admin_app_no_password):
    resp = admin_app_no_password.client.post(
        "/admin/login",
        data={"password": "anything"},
        follow_redirects=False,
    )
    assert resp.status_code == 403


# ── 5. GET /admin unauthenticated → 302 redirect to /admin/login ─────────


def test_admin_ui_unauthenticated_redirects_to_login(admin_app):
    resp = admin_app.client.get("/admin", follow_redirects=False)
    assert resp.status_code == 302
    assert "/admin/login" in resp.headers["location"]


# ── 6. GET /api/admin/stats unauthenticated → 403 JSON (not 302) ─────────


def test_api_admin_unauthenticated_returns_403(admin_app):
    resp = admin_app.client.get("/api/admin/stats")
    assert resp.status_code == 403
    assert resp.headers["content-type"].startswith("application/json")


# ── 7. GET /admin with valid token → 200 (existing auth works) ───────────


def test_admin_ui_with_token_returns_200(admin_app):
    resp = admin_app.client.get(
        "/admin",
        params={"token": ADMIN_TOKEN},
        follow_redirects=False,
    )
    assert resp.status_code == 200


# ── 8. GET /admin with valid cookie → 200 (cookie auth works) ────────────


def test_admin_ui_with_cookie_returns_200(admin_app):
    signed = _sign_cookie(ADMIN_TOKEN)
    admin_app.client.cookies.set("admin_session", signed)
    resp = admin_app.client.get("/admin", follow_redirects=False)
    assert resp.status_code == 200


# ── 9. Non-ASCII credentials fail closed as 403 / login error, not 500 (#2062)
# Starlette decodes header bytes as latin-1, so any non-ASCII byte reaches the
# admin auth helpers as a non-ASCII str.

_NON_ASCII_UTF8 = "pässwörd-密碼".encode()


def test_login_non_ascii_password_shows_error_not_500(admin_app):
    resp = admin_app.client.post(
        "/admin/login",
        data={"password": "pässwörd-密碼"},
        follow_redirects=False,
    )
    assert resp.status_code == 200
    assert "密碼錯誤" in resp.text


def test_api_admin_non_ascii_bearer_returns_403_not_500(admin_app):
    resp = admin_app.client.get(
        "/api/admin/stats",
        headers={"Authorization": b"Bearer " + _NON_ASCII_UTF8},
    )
    assert resp.status_code == 403


def test_api_admin_non_ascii_cookie_returns_403_not_500(admin_app):
    expires_at, nonce, _sig = _sign_cookie(ADMIN_TOKEN).split(".")
    cookie = f"admin_session={expires_at}.{nonce}.".encode() + _NON_ASCII_UTF8
    resp = admin_app.client.get("/api/admin/stats", headers={"Cookie": cookie})
    assert resp.status_code == 403


def test_admin_ui_non_ascii_bearer_redirects_to_login_not_500(admin_app):
    resp = admin_app.client.get(
        "/admin",
        headers={"Authorization": b"Bearer " + _NON_ASCII_UTF8},
        follow_redirects=False,
    )
    assert resp.status_code == 302
    assert "/admin/login" in resp.headers["location"]


# ── 10. Session lifecycle: no sliding renewal, logout revokes (#3904) ─────


def _login_cookie() -> str:
    # Direct handler call: the HTTP login route shares a process-wide brute-force
    # limiter that earlier tests in this module already spend.
    import re

    from kg.admin_handlers import admin_login_post

    resp = admin_login_post(ADMIN_PASSWORD, admin_password=ADMIN_PASSWORD, admin_token=ADMIN_TOKEN)
    assert resp.status_code == 302
    m = re.search(r"admin_session=([^;]+)", resp.headers["set-cookie"])
    assert m is not None
    return m.group(1)


def test_admin_ui_does_not_reissue_cookie(admin_app):
    cookie = _login_cookie()
    admin_app.client.cookies.set("admin_session", cookie)
    resp = admin_app.client.get("/admin", follow_redirects=False)
    assert resp.status_code == 200
    assert not any(h.startswith("admin_session=") for h in resp.headers.get_list("set-cookie"))


def test_admin_logout_clears_and_revokes_cookie(admin_app):
    cookie = _login_cookie()
    admin_app.client.cookies.set("admin_session", cookie)
    resp = admin_app.client.post("/admin/logout", follow_redirects=False)
    assert resp.status_code == 302
    assert resp.headers["location"] == "/admin/login"
    cleared = [h.lower() for h in resp.headers.get_list("set-cookie") if h.startswith("admin_session=")]
    assert cleared and "max-age=0" in cleared[0]
    admin_app.client.cookies.set("admin_session", cookie)
    replay = admin_app.client.get("/admin", follow_redirects=False)
    assert replay.status_code == 302
    assert "/admin/login" in replay.headers["location"]


def test_admin_logout_revocation_survives_store_restart(admin_app):
    from kg.admin import session_store

    cookie = _login_cookie()
    admin_app.client.cookies.set("admin_session", cookie)
    admin_app.client.post("/admin/logout", follow_redirects=False)
    session_store.reset()  # simulate process restart: drop every open handle
    admin_app.client.cookies.set("admin_session", cookie)
    replay = admin_app.client.get("/admin", follow_redirects=False)
    assert replay.status_code == 302
    assert "/admin/login" in replay.headers["location"]
