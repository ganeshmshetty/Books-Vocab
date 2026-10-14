from __future__ import annotations

import ipaddress
import logging
import re
import uuid as _uuid
from collections.abc import Callable
from contextvars import ContextVar
from dataclasses import dataclass
from typing import Any

import jwt
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from kg.settings import DEFAULT_PUBLIC_WEB_BASE_URL

RateLimiter = Any

logger = logging.getLogger(__name__)


# Inbound X-Request-ID reaches logs and the admin dashboard; accept only a safe charset.
_REQUEST_ID_RE = re.compile(r"[A-Za-z0-9._-]{1,64}")


@dataclass(frozen=True)
class AppMiddlewareRuntime:
    rate_limit_exempt_prefixes: tuple[str, ...]


@dataclass(frozen=True)
class AppMiddlewareDependencies:
    app: FastAPI
    cors_origins: tuple[str, ...]
    rate_limit_trusted_hops: int
    request_id_var: ContextVar[str]
    tag_request_id: Callable[[str | None], None]
    api_limiter: RateLimiter
    translate_limiter: RateLimiter
    login_limiter: RateLimiter | None = None


def _anon_rate_limit_key(xff: str, client_host: str | None, hops: int) -> str:
    """Derive the rate-limit key for an anonymous (no-auth) request.

    `hops` = number of trusted proxy hops in front of the app. The real client
    IP is taken from the `hops`-th-from-end X-Forwarded-For segment.

    Production contract: single-layer bare Caddy on AWS public net appends the
    real client IP to the END of XFF, so hops=1 selects the last segment — this
    is byte-for-byte identical to the legacy `xff.split(",")[-1].strip()`.
    Raise hops to N+1 only when N trusted proxies (CDN/ALB) front Caddy.

    Safe fallbacks: empty XFF -> client_host (or "unknown"); hops exceeding the
    available segment count -> the frontmost segment (never raises IndexError).
    The selected address is passed through `_normalize_client_address`.
    """
    if xff:
        segments = [s.strip() for s in xff.split(",")]
        idx = max(0, len(segments) - max(1, hops))
        return _normalize_client_address(segments[idx])
    return _normalize_client_address(client_host) if client_host else "unknown"


def _normalize_client_address(address: str) -> str:
    """Collapse a client address to the unit a single host is allocated.

    IPv6 aggregates to its /64 network, IPv4-mapped IPv6 resolves to IPv4, and
    IPv4 is returned verbatim. Non-IP strings are returned unchanged.
    """
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return address
    if ip.version == 4:
        return address
    if ip.ipv4_mapped is not None:
        return str(ip.ipv4_mapped)
    return str(ipaddress.ip_network(f"{address}/64", strict=False))


# Generic api/translate limiter buckets are namespaced by trust class so a
# client-influenced value (e.g. an X-Forwarded-For segment when the app is
# reached without the trusted proxy) can never alias a verified user's bucket.
def anonymous_rate_limit_key(client_ip: str) -> str:
    return f"ip:{client_ip}"


def verified_user_rate_limit_key(user_id: str) -> str:
    return f"user:{user_id}"


def _verified_jwt_subject(authorization: str, settings: Any) -> str | None:
    """Return the JWT ``sub`` only when the bearer token's signature and expiry
    verify against the app's own JWT secret; otherwise ``None``.

    This is the rate-limit identity, not authentication: it deliberately skips
    the user-store revocation lookup (disk I/O on every request). A revoked
    but correctly signed token still maps to one bounded per-user bucket and is
    rejected with 401 by the auth dependency; it cannot be minted, so it cannot
    multiply buckets the way the old raw-header tail could (#2056).
    """
    scheme, _, token = authorization.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not token or settings is None:
        return None
    try:
        decoded = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except jwt.InvalidTokenError:
        return None
    subject = decoded.get("sub")
    return subject if isinstance(subject, str) and subject else None


def install_app_middlewares_from_dependencies(
    *,
    dependencies: AppMiddlewareDependencies,
) -> AppMiddlewareRuntime:
    app = dependencies.app
    cors_origins = dependencies.cors_origins
    rate_limit_trusted_hops = dependencies.rate_limit_trusted_hops
    request_id_var = dependencies.request_id_var
    tag_request_id = dependencies.tag_request_id
    api_limiter = dependencies.api_limiter
    translate_limiter = dependencies.translate_limiter
    login_limiter = dependencies.login_limiter

    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(cors_origins),
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
        allow_headers=["Authorization", "Content-Type", "X-KG-API-Key", "X-Request-ID"],
    )

    @app.middleware("http")
    async def request_id_middleware(request: Request, call_next):
        inbound = request.headers.get("X-Request-ID") or ""
        request_id = inbound if _REQUEST_ID_RE.fullmatch(inbound) else _uuid.uuid4().hex[:16]
        request.state.request_id = request_id
        token = request_id_var.set(request_id)
        tag_request_id(request_id)
        try:
            response = await call_next(request)
        finally:
            request_id_var.reset(token)
        response.headers["X-Request-ID"] = request_id
        return response

    max_body_bytes = 10 * 1024 * 1024

    @app.middleware("http")
    async def limit_request_body(request: Request, call_next):
        content_length = request.headers.get("content-length")
        if content_length is not None:
            try:
                declared = int(content_length)
            except ValueError:
                return JSONResponse({"detail": "Invalid Content-Length header"}, status_code=400)
            if declared > max_body_bytes:
                return JSONResponse({"detail": "Request body too large"}, status_code=413)
            return await call_next(request)
        # No Content-Length (e.g. Transfer-Encoding: chunked): the declared-size
        # check above can be bypassed, so stream-count the body and abort once it
        # exceeds the cap. Buffer the consumed bytes back onto the request so
        # downstream handlers can still read it.
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > max_body_bytes:
                return JSONResponse({"detail": "Request body too large"}, status_code=413)
        request._body = bytes(body)
        return await call_next(request)

    rate_limit_exempt_prefixes = (
        "/docs",
        "/openapi.json",
        "/privacy",
        "/support",
        "/terms",
        "/guide",
        # Landing-page assets (css/js/fonts/images): ~10 same-origin requests per
        # page view must not burn the anonymous per-IP API budget (#2824).
        "/static/",
        "/api/billing/app-store/notifications",
        "/api/system/info",
        "/auth/web/google/callback",
        "/auth/web/apple/callback",
        # External API routes have their own per-key limiter. Applying the
        # generic IP limiter as well would make unrelated API keys behind the
        # same NAT share a budget and would hide the external rate-limit
        # headers behind a second 429.
        "/api/v1/cards",
        "/api/v1/enrich",
        "/api/v1/links",
        "/api/v1/notebooks",
        "/api/v1/operations",
    )

    # Exact-match exemptions: a "/" prefix would exempt every path.
    rate_limit_exempt_paths = frozenset({"/"})

    @app.middleware("http")
    async def rate_limit_middleware(request: Request, call_next):
        path = request.url.path
        # Dedicated brute-force lockout for admin password login. Keyed by client
        # IP (login is anonymous, no Authorization header). Checked before the
        # generic budget so it trips at a much lower threshold.
        if login_limiter is not None and request.method == "POST" and path == "/admin/login":
            xff = request.headers.get("x-forwarded-for", "")
            client_host = request.client.host if request.client else None
            login_key = _anon_rate_limit_key(xff, client_host, rate_limit_trusted_hops)
            if not await login_limiter.is_allowed(login_key):
                logger.warning("Admin login rejected: status=429 key=%s", login_key)
                return JSONResponse(
                    {"detail": "Too many login attempts"},
                    status_code=429,
                    headers={"Retry-After": str(login_limiter.window_seconds)},
                )
            response = await call_next(request)
            # Success is the 302 redirect; any other outcome is a rejected attempt.
            if response.status_code != 302:
                logger.warning("Admin login rejected: status=%s key=%s", response.status_code, login_key)
            return response
        if path in rate_limit_exempt_paths or any(path.startswith(prefix) for prefix in rate_limit_exempt_prefixes):
            return await call_next(request)
        # Only a server-signed JWT earns a per-user bucket. Anything else —
        # no header, a non-JWT bearer (admin token), a forged/expired JWT —
        # shares the client-IP bucket, so rotating the header buys nothing.
        # Settings are read per request, like the routers do, so a swapped
        # `app.state.kg_settings` (secret rotation, tests) is honoured.
        subject = _verified_jwt_subject(
            request.headers.get("authorization", ""),
            getattr(request.app.state, "kg_settings", None),
        )
        if subject is not None:
            key = verified_user_rate_limit_key(subject)
        else:
            xff = request.headers.get("x-forwarded-for", "")
            client_host = request.client.host if request.client else None
            key = anonymous_rate_limit_key(_anon_rate_limit_key(xff, client_host, rate_limit_trusted_hops))
        limiter = translate_limiter if "/api/translate" in path else api_limiter
        if not await limiter.is_allowed(key):
            return JSONResponse(
                {"detail": "Too many requests"},
                status_code=429,
                headers={"Retry-After": str(limiter.window_seconds)},
            )
        return await call_next(request)

    @app.middleware("http")
    async def security_headers_middleware(request: Request, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["X-XSS-Protection"] = "0"
        response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
        # TLS terminates at Cloudflare, so request.url.scheme is always http here and browsers
        # ignore HSTS on http responses anyway; gate on the configured public origin instead.
        settings = getattr(request.app.state, "kg_settings", None)
        public_url = getattr(settings, "public_web_base_url", DEFAULT_PUBLIC_WEB_BASE_URL)
        if public_url.startswith("https://"):
            response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        return response

    return AppMiddlewareRuntime(
        rate_limit_exempt_prefixes=rate_limit_exempt_prefixes,
    )
