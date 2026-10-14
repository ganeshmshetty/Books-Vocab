"""Admin authentication — cookie signing/verification, login pages, UI responses."""

from __future__ import annotations

import hashlib
import hmac
import logging
import secrets
import time

# Preserve the historical logger name so callers (and tests) that look up
# ``logging.getLogger("kg.admin_handlers")`` keep observing these records.
logger = logging.getLogger("kg.admin_handlers")

from fastapi import HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse

ADMIN_COOKIE_NAME = "admin_session"
ADMIN_COOKIE_TTL_SECONDS = 7 * 24 * 60 * 60  # 7 days


def _secrets_equal(provided: str, expected: str) -> bool:
    """Constant-time equality for admin credentials.

    ``hmac.compare_digest(str, str)`` raises ``TypeError`` on any non-ASCII
    character, which turned a wrong non-ASCII token/password/cookie into a 500
    instead of a 403 (#2062). Compare UTF-8 bytes instead; ``surrogatepass``
    keeps the encoding total and injective for every ``str``.
    """
    return hmac.compare_digest(
        provided.encode("utf-8", "surrogatepass"),
        expected.encode("utf-8", "surrogatepass"),
    )


def _sign_payload(admin_token: str, payload: str) -> str:
    return hmac.new(admin_token.encode(), payload.encode(), "sha256").hexdigest()


def _build_cookie_value(admin_token: str, *, expires_at: int, nonce_hex: str | None = None) -> str:
    """Build an expiry-bound, single-use-noncified admin session cookie.

    Layout: ``"<expires_at>.<nonce_hex>.<sig_hex>"`` where the signature covers
    ``"<expires_at>.<nonce_hex>"``. The nonce makes successive cookies distinct
    so a leaked value cannot be re-derived from the admin token alone.
    """
    nonce = nonce_hex if nonce_hex is not None else secrets.token_hex(16)
    payload = f"{expires_at}.{nonce}"
    sig = _sign_payload(admin_token, payload)
    return f"{payload}.{sig}"


def _sign_cookie(admin_token: str, *, ttl_seconds: int = ADMIN_COOKIE_TTL_SECONDS, nonce_hex: str | None = None) -> str:
    expires_at = int(time.time()) + ttl_seconds
    return _build_cookie_value(admin_token, expires_at=expires_at, nonce_hex=nonce_hex)


def _verify_cookie(cookie_value: str, admin_token: str) -> bool:
    if not admin_token or not cookie_value:
        return False
    parts = cookie_value.split(".")
    if len(parts) != 3:
        return False
    expires_at_str, nonce, sig = parts
    if not expires_at_str.isdigit() or not nonce or not sig:
        return False
    expected_sig = _sign_payload(admin_token, f"{expires_at_str}.{nonce}")
    if not _secrets_equal(sig, expected_sig):
        return False
    return time.time() <= int(expires_at_str)


def _verified_cookie_nonce(cookie_value: str | None, admin_token: str) -> str | None:
    """Session nonce of a valid cookie, else None. The nonce identifies the login session."""
    if not cookie_value or not _verify_cookie(cookie_value, admin_token):
        return None
    return cookie_value.split(".")[1]


def _resolve_admin_token(token: str | None, authorization: str | None) -> str | None:
    if authorization and authorization.startswith("Bearer "):
        return authorization[7:]
    if token:
        logger.warning("Admin token via URL query param is deprecated, use Authorization header")
        return token
    return None


def require_admin(
    token: str | None,
    *,
    admin_token: str,
    authorization: str | None = None,
    cookie_token: str | None = None,
) -> None:
    if not admin_token:
        raise HTTPException(status_code=403, detail="ADMIN_TOKEN not configured")
    resolved = _resolve_admin_token(token, authorization)
    if resolved is not None:
        if not _secrets_equal(resolved, admin_token):
            raise HTTPException(status_code=403, detail="Forbidden")
        return
    if cookie_token and _verify_cookie(cookie_token, admin_token):
        return
    raise HTTPException(403, "Forbidden")


def _set_admin_cookie(response: HTMLResponse, admin_token: str, *, nonce_hex: str | None = None) -> HTMLResponse:
    response.set_cookie(
        key=ADMIN_COOKIE_NAME,
        value=_sign_cookie(admin_token, nonce_hex=nonce_hex),
        httponly=True,
        secure=True,
        samesite="lax",
        path="/",
        max_age=ADMIN_COOKIE_TTL_SECONDS,
    )
    return response


ADMIN_LOGIN_HTML = """<!DOCTYPE html>
<html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Admin Login</title>
<style>
body{{font-family:system-ui,sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:#f5f5f5}}
.card{{background:#fff;padding:2rem;border-radius:8px;box-shadow:0 2px 8px rgba(0,0,0,.1);width:100%;max-width:360px}}
h1{{font-size:1.25rem;margin:0 0 1.5rem;text-align:center;color:#333}}
label{{display:block;margin-bottom:.5rem;font-size:.875rem;color:#555}}
input[type=password]{{width:100%;padding:.5rem;border:1px solid #ccc;border-radius:4px;font-size:1rem;box-sizing:border-box}}
button{{width:100%;padding:.625rem;margin-top:1rem;border:none;border-radius:4px;background:#333;color:#fff;font-size:1rem;cursor:pointer}}
button:hover{{background:#555}}
.error{{color:#c00;font-size:.875rem;margin-top:.75rem;text-align:center}}
.info{{color:#666;font-size:.875rem;margin-top:.75rem;text-align:center}}
</style></head><body>
<div class="card">
<h1>KG Admin</h1>
{content}
</div></body></html>"""


def admin_login_page(error: str = "", password_enabled: bool = True) -> HTMLResponse:
    """Render the admin login page."""
    if not password_enabled:
        content = '<p class="info">密碼登入未啟用，請使用 token 認證。</p>'
    else:
        import html as _html

        error_html = f'<p class="error">{_html.escape(error)}</p>' if error else ""
        content = (
            '<form method="post" action="/admin/login">'
            '<label for="password">管理員密碼</label>'
            '<input type="password" id="password" name="password" autofocus required>'
            '<button type="submit">登入</button>'
            f"{error_html}</form>"
        )
    return HTMLResponse(ADMIN_LOGIN_HTML.format(content=content))


def admin_login_post(password: str, *, admin_password: str, admin_token: str) -> HTMLResponse | RedirectResponse:
    """Verify password and redirect on success, or show error on failure."""
    if not admin_password:
        return HTMLResponse(
            ADMIN_LOGIN_HTML.format(content='<p class="error">密碼登入未啟用。</p>'),
            status_code=403,
        )
    if not _secrets_equal(password, admin_password):
        return admin_login_page(error="密碼錯誤，請重試。")
    resp = RedirectResponse("/admin", status_code=302)
    _set_admin_cookie(resp, admin_token)
    return resp


def admin_actor_fingerprint(
    *,
    token: str | None,
    authorization: str | None,
    cookie_token: str | None,
    admin_token: str,
) -> str:
    """Derive a stable 8-char fingerprint identifying the authenticated admin
    actor from the request's own auth material.

    Precedence: Bearer / token query (raw admin token) → cookie value (signed
    session). We hash with the server-side ``admin_token`` as salt so the
    fingerprint never leaks the raw credential and remains stable across
    requests from the same auth source.

    Always returns a non-empty string. Falls back to ``"admin"`` if no auth
    material is present (which should not happen under the admin auth
    dependency, but keeps audit rows non-NULL).
    """
    if not admin_token:
        return "admin"
    raw = _resolve_admin_token(token, authorization)
    source = "token"
    material: str | None = raw
    if material is None and cookie_token:
        # Use the session nonce, not the whole cookie: every admin page GET re-signs
        # the cookie with the same nonce, so the actor stays stable for the session.
        material = _verified_cookie_nonce(cookie_token, admin_token) or cookie_token
        source = "cookie"
    if not material:
        return "admin"
    digest = hashlib.sha256(f"{source}|{admin_token}|{material}".encode()).hexdigest()
    return digest[:8]


def check_admin_auth(
    *,
    token: str | None,
    authorization: str | None,
    cookie_token: str | None,
    admin_token: str,
) -> bool:
    """Return True if the request carries valid admin credentials, False otherwise."""
    if not admin_token:
        return False
    resolved = _resolve_admin_token(token, authorization)
    if resolved is not None:
        return _secrets_equal(resolved, admin_token)
    if cookie_token and _verify_cookie(cookie_token, admin_token):
        return True
    return False


def admin_ui_response(
    *,
    admin_token: str,
    admin_html: str,
    cookie_token: str | None = None,
) -> HTMLResponse:
    return _set_admin_cookie(
        HTMLResponse(admin_html),
        admin_token,
        nonce_hex=_verified_cookie_nonce(cookie_token, admin_token),
    )
