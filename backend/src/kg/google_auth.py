"""Google Sign-In token validation module."""

import asyncio
import logging

import requests as _requests
from fastapi import HTTPException
from google.auth.exceptions import GoogleAuthError
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token

from .auth_types import GoogleIdentity

logger = logging.getLogger(__name__)

# Bounded timeout (seconds) for Google certificate-endpoint requests.
# NOTE: ``requests.Session`` has NO ``timeout`` attribute — assigning one is
# a silent no-op. The only effective timeout is the per-request ``timeout``
# kwarg, which google-auth's ``Request.__call__`` defaults to 120s and
# ``id_token._fetch_certs`` never overrides. We inject our own small bound.
_REQUEST_TIMEOUT_SECONDS = 10

# Shared HTTP session for connection pooling across token verifications.
_session = _requests.Session()


class _TimeoutRequest(google_requests.Request):
    """``google-auth`` transport adapter with a bounded default timeout.

    ``id_token._fetch_certs`` calls ``request(certs_url, method="GET")``
    without a ``timeout``, so the base adapter would fall back to its 120s
    default. We override the default so a hung Google certs endpoint cannot
    block the login request indefinitely. An explicit caller-supplied
    ``timeout`` still wins.
    """

    def __call__(self, url, method="GET", body=None, headers=None, timeout=None, **kwargs):
        if timeout is None:
            timeout = _REQUEST_TIMEOUT_SECONDS
        return super().__call__(url, method=method, body=body, headers=headers, timeout=timeout, **kwargs)


def _build_request_adapter(session: _requests.Session | None = None) -> _TimeoutRequest:
    """Build a timeout-bounded transport adapter for google-auth."""
    return _TimeoutRequest(session=session if session is not None else _session)


def _verify_oauth2_token_sync(token: str, client_id: str) -> dict:
    """Synchronous ID-token verification (blocking network I/O).

    Runs in a worker thread; never call directly from the event loop.
    """
    request_adapter = _build_request_adapter()
    return id_token.verify_oauth2_token(token, request_adapter, client_id)


async def verify_google_token(token: str, client_id: str) -> GoogleIdentity:
    """Validate Google ID Token and return ``(sub, email, email_verified, hd)``.

    Returns the token-derived email, verification flag and Workspace hosted
    domain (``hd``) so callers can safely link accounts by email (only when
    verified and authoritative for the provider). Client-supplied
    emails MUST NOT be trusted — see C1 account-takeover regression.

    ``id_token.verify_oauth2_token`` performs blocking HTTP I/O to fetch
    Google's signing certificates; it is offloaded to a worker thread so
    the asyncio event loop is never blocked.
    """
    try:
        # Verify the token using Google's official validation, off-loop.
        idinfo = await asyncio.to_thread(_verify_oauth2_token_sync, token, client_id)

        # Token is valid, extract user ID
        sub = idinfo.get("sub")
        if not sub:
            raise HTTPException(status_code=401, detail="Token missing subject (sub)")

        email_raw = idinfo.get("email")
        email = str(email_raw).strip().lower() if email_raw else None
        # Some providers (and some google-auth payloads from test/proxy
        # environments) deliver email_verified as a string ("true"/"false")
        # rather than a bool. bool("false") is truthy in Python, so we
        # cannot rely on plain bool() coercion — normalize explicitly.
        raw_verified = idinfo.get("email_verified", False)
        email_verified = raw_verified.strip().lower() == "true" if isinstance(raw_verified, str) else bool(raw_verified)

        hd_raw = idinfo.get("hd")
        hd = hd_raw.strip().lower() if isinstance(hd_raw, str) and hd_raw.strip() else None

        return GoogleIdentity(str(sub), email, email_verified, hd)

    except ValueError as e:
        # Invalid token signature or claims
        # Log the type only: google-auth messages can embed the raw token (#2712).
        logger.warning("Google token validation failed: %s", type(e).__name__)
        raise HTTPException(status_code=401, detail="Invalid token") from e
    except (GoogleAuthError, OSError) as e:
        # Client-side token issue (expired / malformed / network during verify).
        # Mirrors the JWT validation branch above — not a server error.
        logger.warning("Google token verification error: %s", type(e).__name__)
        raise HTTPException(status_code=401, detail="Google authentication failed") from e
