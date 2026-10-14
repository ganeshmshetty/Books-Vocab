"""Sign in with Apple refresh-token capture and revocation (#3815).

Apple honours a refresh token only together with a ``client_secret`` signed by
our Sign in with Apple ``.p8`` key, so a stored token is useless on its own.
Everything here is gated on ``AppleSIWAConfig.from_settings`` (all three
``APPLE_SIWA_*`` values set; otherwise no Apple call is made) and is best
effort: failures are logged without token values and never fail sign-in or
account deletion.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

import httpx
import jwt
from starlette.datastructures import State

from .user_store import collect_account_ids_for_deletion
from .users_lock import users_file_lock

if TYPE_CHECKING:
    from .settings import KGSettings

logger = logging.getLogger(__name__)

APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"
APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke"
APPLE_AUDIENCE = "https://appleid.apple.com"
APPLE_HTTP_TIMEOUT_SECONDS = 10.0
# Minted per call with a short lifetime (Apple caps client_secret exp at 5 minutes for this flow).
CLIENT_SECRET_TTL_SECONDS = 300
REFRESH_TOKEN_FIELD = "apple_refresh_token"


@dataclass(frozen=True)
class AppleSIWAConfig:
    team_id: str
    key_id: str
    private_key_path: Path
    # Native app bundle id: the Sign in with Apple client_id for the iOS flow.
    client_id: str

    @classmethod
    def from_settings(cls, settings: KGSettings) -> AppleSIWAConfig | None:
        """Return None unless all three APPLE_SIWA_* values are set."""
        team_id = settings.apple_siwa_team_id
        key_id = settings.apple_siwa_key_id
        key_path = settings.apple_siwa_private_key_path
        if not (team_id and key_id and key_path):
            return None
        return cls(team_id=team_id, key_id=key_id, private_key_path=key_path, client_id=settings.apple_bundle_id)


def make_client_secret(config: AppleSIWAConfig) -> str:
    issued_at = int(time.time())
    claims = {
        "iss": config.team_id,
        "iat": issued_at,
        "exp": issued_at + CLIENT_SECRET_TTL_SECONDS,
        "aud": APPLE_AUDIENCE,
        "sub": config.client_id,
    }
    return jwt.encode(
        claims,
        config.private_key_path.read_bytes(),
        algorithm="ES256",
        headers={"kid": config.key_id},
    )


def _post_form(url: str, data: dict[str, str], transport: httpx.BaseTransport | None) -> httpx.Response:
    with httpx.Client(timeout=APPLE_HTTP_TIMEOUT_SECONDS, transport=transport) as client:
        return client.post(url, data=data)


def exchange_authorization_code(
    config: AppleSIWAConfig,
    authorization_code: str,
    *,
    transport: httpx.BaseTransport | None = None,
) -> str:
    resp = _post_form(
        APPLE_TOKEN_URL,
        {
            "grant_type": "authorization_code",
            "code": authorization_code,
            "client_id": config.client_id,
            "client_secret": make_client_secret(config),
        },
        transport,
    )
    resp.raise_for_status()
    payload: Any = resp.json()
    refresh_token = payload.get("refresh_token") if isinstance(payload, dict) else None
    if not isinstance(refresh_token, str) or not refresh_token:
        raise ValueError("Apple token response has no refresh_token")
    return refresh_token


def revoke_refresh_token(
    config: AppleSIWAConfig,
    refresh_token: str,
    *,
    transport: httpx.BaseTransport | None = None,
) -> None:
    resp = _post_form(
        APPLE_REVOKE_URL,
        {
            "token": refresh_token,
            "token_type_hint": "refresh_token",
            "client_id": config.client_id,
            "client_secret": make_client_secret(config),
        },
        transport,
    )
    resp.raise_for_status()


def _transport(app_state: State) -> httpx.BaseTransport | None:
    """Test seam: tests set ``app.state.apple_http_transport`` to an httpx.MockTransport."""
    return getattr(app_state, "apple_http_transport", None)


def _describe(exc: Exception) -> str:
    """Log-safe failure summary: no URL, form body or token value."""
    if isinstance(exc, httpx.HTTPStatusError):
        return f"HTTP {exc.response.status_code}"
    return type(exc).__name__


def _store_refresh_token(users: dict[str, Any], user_id: str, refresh_token: str) -> bool:
    record = users.get(user_id)
    if not isinstance(record, dict):
        return False
    record[REFRESH_TOKEN_FIELD] = refresh_token
    return True


def _stored_refresh_tokens(users: dict[str, Any], account_ids: Iterable[str]) -> list[str]:
    tokens: list[str] = []
    for uid in account_ids:
        record = users.get(uid)
        token = record.get(REFRESH_TOKEN_FIELD) if isinstance(record, dict) else None
        if isinstance(token, str) and token:
            tokens.append(token)
        else:
            logger.debug("No stored Apple refresh token for a linked account; revocation skipped")
    return tokens


def capture_apple_refresh_token(app_state: State, user_id: str, authorization_code: str) -> None:
    """Sign-in side: exchange the authorization code and keep the refresh token on the canonical record.

    Never raises: sign-in must not fail because Apple or the users lock is unavailable.
    """
    settings = app_state.kg_settings
    config = AppleSIWAConfig.from_settings(settings)
    if config is None:
        return
    try:
        refresh_token = exchange_authorization_code(config, authorization_code, transport=_transport(app_state))
        with users_file_lock(settings.users_lock_file):
            users = app_state.load_users()
            if _store_refresh_token(users, user_id, refresh_token):
                app_state.save_users(users)
    except Exception as exc:  # best effort by contract
        logger.warning("Apple refresh token capture failed; sign-in continues: %s", _describe(exc))


def revoke_apple_tokens_for_account(app_state: State, user_id: str) -> None:
    """Deletion side: revoke the stored refresh tokens of the account's linked ids, before erasure.

    Never raises: a revocation failure is logged and account deletion continues.
    """
    settings = app_state.kg_settings
    config = AppleSIWAConfig.from_settings(settings)
    if config is None:
        return
    try:
        with users_file_lock(settings.users_lock_file):
            users = app_state.load_users()
            _, account_ids = collect_account_ids_for_deletion(users, user_id)
            tokens = _stored_refresh_tokens(users, account_ids)
    except Exception as exc:  # best effort by contract
        logger.warning("Apple refresh token lookup failed; revocation skipped: %s", _describe(exc))
        return
    transport = _transport(app_state)
    for refresh_token in tokens:
        try:
            revoke_refresh_token(config, refresh_token, transport=transport)
        except Exception as exc:  # best effort by contract
            logger.warning("Apple token revocation failed; account deletion continues: %s", _describe(exc))
