"""Shared dependencies for all routers.

Contains auth infrastructure, factory wrappers, and common helpers.
Routers import from here; api.py re-exports for backward compatibility.
"""

from __future__ import annotations

import asyncio
import collections
import logging
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import Annotated, Any

from fastapi import Cookie, Depends, Header, HTTPException, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .api_models import EntitlementsResponse
from .billing import (
    build_entitlements_response,
    current_admin_grant_record,
    current_subscription_record,
    default_subscription_payload,
    notification_status,
    resolve_user_id_from_subscription_index,
    write_subscription_snapshot,
)
from .difficulty import get_tier
from .graph import LINK_LABELS, GraphStore, LinkKind
from .sentry_init import bind_user
from .service_factories import (
    create_card_store,
    create_embedding_store,
    create_graph_store,
    create_library_store,
    create_notebook_store,
    create_review_event_store,
    create_shared_deck_store,
)
from .settings import KGSettings
from .types import AdminGrantRecord, CardsById, StoredUserRecord, SubscriptionRecord, UserRecord, UsersPayload
from .user_context import resolve_current_user
from .user_store import collect_account_ids_for_deletion, parse_datetime
from .vocab_shared import card_response

logger = logging.getLogger("kg.api")

# ---------------------------------------------------------------------------
# Auth infrastructure
# ---------------------------------------------------------------------------


def _get_settings(request: Request) -> KGSettings:
    return request.app.state.kg_settings


security = HTTPBearer()
security_optional = HTTPBearer(auto_error=False)

_USER_LOCKS: collections.OrderedDict[str, asyncio.Lock] = collections.OrderedDict()
_MAX_USER_LOCKS = 500
_USER_LOCKS_MUTEX: asyncio.Lock | None = None


def _get_locks_mutex() -> asyncio.Lock:
    """Lazy-init the mutex. Safe because asyncio is single-threaded:
    no await between the None check and assignment, so no interleaving."""
    global _USER_LOCKS_MUTEX
    if _USER_LOCKS_MUTEX is None:
        _USER_LOCKS_MUTEX = asyncio.Lock()
    return _USER_LOCKS_MUTEX


def _user_lock_is_active(lock: asyncio.Lock) -> bool:
    """Keep held or queued locks alive until their callers finish."""
    return lock.locked() or bool(getattr(lock, "_waiters", None))


async def get_user_lock(user_id: str) -> asyncio.Lock:
    async with _get_locks_mutex():
        if user_id in _USER_LOCKS:
            _USER_LOCKS.move_to_end(user_id)
            return _USER_LOCKS[user_id]
        lock = asyncio.Lock()
        while len(_USER_LOCKS) >= _MAX_USER_LOCKS:
            for candidate_id, candidate_lock in _USER_LOCKS.items():
                if not _user_lock_is_active(candidate_lock):
                    del _USER_LOCKS[candidate_id]
                    break
            else:
                # Contended locks may temporarily take the cache over its cap;
                # evicting one would create a second lock for that user.
                break
        _USER_LOCKS[user_id] = lock
        return lock


def _parse_datetime(raw: Any) -> datetime | None:
    return parse_datetime(raw)


def _resolve_request_user(request: Request, token: str) -> UserRecord:
    settings = request.app.state.kg_settings
    load_users_fn = request.app.state.load_users
    user = resolve_current_user(
        token,
        settings=settings,
        load_users=load_users_fn,
        parse_datetime=_parse_datetime,
    )
    # Tag Sentry scope with uid so error groups + traces cluster per-user.
    # No-op when Sentry isn't initialized; id-only so no PII leaks.
    bind_user(user.get("id"))
    return user


def get_current_user(
    request: Request,
    credentials: HTTPAuthorizationCredentials = Depends(security),
) -> UserRecord:
    return _resolve_request_user(request, credentials.credentials)


def get_current_user_optional(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(security_optional),
    authorization: str | None = Header(default=None),
) -> UserRecord | None:
    """Auth dependency for *browse* endpoints that admit anonymous callers.

    Contract:

    * **No** ``Authorization`` header → ``None`` (guest). The endpoint decides
      what a guest may see.
    * Header **present** → validated strictly via :func:`resolve_current_user`,
      which raises ``401`` on an expired/forged token. A present-but-invalid
      token means the client *believes* it is signed in; downgrading it to a
      silent guest would mask a real auth bug, so we fail loud — identical to
      :func:`get_current_user`.
    """
    if credentials is None:
        if authorization is not None:
            raise HTTPException(
                status_code=401,
                detail="Invalid authentication credentials",
                headers={"WWW-Authenticate": "Bearer"},
            )
        return None
    return _resolve_request_user(request, credentials.credentials)


# Router-facing auth contracts: one named alias captures both the dependency
# wiring and the resolved type, so endpoint signatures no longer drift back to
# bare ``dict = Depends(...)`` annotations.
type CurrentUser = Annotated[UserRecord, Depends(get_current_user)]
type OptionalCurrentUser = Annotated[UserRecord | None, Depends(get_current_user_optional)]


# ---------------------------------------------------------------------------
# Factory wrappers
# ---------------------------------------------------------------------------


def _card_store(user_dir: Path):
    return create_card_store(user_dir)


def _review_event_store(user_dir: Path):
    return create_review_event_store(user_dir)


def _graph_store(user_dir: Path, notebook_id: str = "default") -> GraphStore:
    return create_graph_store(user_dir, notebook_id=notebook_id)


def _notebook_store(user_dir: Path):
    return create_notebook_store(user_dir)


def _library_store(user_dir: Path):
    return create_library_store(user_dir)


def _shared_deck_store(settings: KGSettings):
    # Global catalog (not per-user): resolves the single db path from settings.
    return create_shared_deck_store(settings.shared_decks_path)


def _embedding_store(user_dir: Path, *, llm, notebook_id: str = "default"):
    return create_embedding_store(user_dir, llm=llm, notebook_id=notebook_id)


def _card_response(card, graph: GraphStore, cards_by_id: CardsById):
    return card_response(
        card,
        graph=graph,
        cards_by_id=cards_by_id,
        tier_getter=get_tier,
        link_kinds=list(LinkKind),
        link_labels=LINK_LABELS,
    )


def _collect_account_ids_for_deletion(users: UsersPayload, user_id: str) -> tuple[str, list[str]]:
    return collect_account_ids_for_deletion(users, user_id)


def _default_subscription_payload() -> SubscriptionRecord:
    return default_subscription_payload()


def _build_entitlements_response(user_record: StoredUserRecord | None) -> EntitlementsResponse:
    return build_entitlements_response(user_record)


def _current_admin_grant_record(user_record: StoredUserRecord | None) -> AdminGrantRecord:
    return current_admin_grant_record(user_record)


def _current_subscription_record(user_record: StoredUserRecord | None) -> SubscriptionRecord:
    return current_subscription_record(user_record)


def _resolve_user_id_from_subscription_index(
    users: UsersPayload,
    original_transaction_id: str | None,
    transaction_id: str | None,
) -> str | None:
    return resolve_user_id_from_subscription_index(users, original_transaction_id, transaction_id)


def _write_subscription_snapshot(
    users: UsersPayload,
    user_id: str,
    *,
    product_id: str,
    status: str,
    is_trial: bool,
    expires_at: str | None,
    will_renew: bool,
    environment: str,
    transaction_id: str | None,
    original_transaction_id: str | None,
    price_display: str | None,
    source: str,
    signed_date: str | None = None,
    notification_uuid: str | None = None,
    grace_period_expires_at: str | None = None,
) -> StoredUserRecord:
    return write_subscription_snapshot(
        users,
        user_id,
        product_id=product_id,
        status=status,
        is_trial=is_trial,
        expires_at=expires_at,
        will_renew=will_renew,
        environment=environment,
        transaction_id=transaction_id,
        original_transaction_id=original_transaction_id,
        price_display=price_display,
        source=source,
        signed_date=signed_date,
        notification_uuid=notification_uuid,
        grace_period_expires_at=grace_period_expires_at,
    )


def _notification_status(notification_type: str | None, subtype: str | None) -> str | None:
    return notification_status(notification_type, subtype)


# ---------------------------------------------------------------------------
# Auth helpers (used by auth router)
# ---------------------------------------------------------------------------
from .auth_service import create_jwt_token, resolve_and_link_user
from .deps_quota import _apply_quota_headers, _check_quota, _is_pro, _with_quota_check  # noqa: F401


def _create_jwt_token(user_id: str, provider: str, *, settings: KGSettings) -> str:
    return create_jwt_token(
        user_id,
        provider,
        jwt_secret=settings.jwt_secret,
        jwt_algorithm=settings.jwt_algorithm,
        jwt_expiry_minutes=settings.jwt_expiry_minutes,
    )


def _resolve_and_link_user(
    provider_user_id: str,
    provider: str,
    email: str | None = None,
    *,
    hd: str | None = None,
    settings: KGSettings,
    load_users_fn: Callable,
    save_users_fn: Callable,
) -> str:
    return resolve_and_link_user(
        provider_user_id,
        provider,
        users_lock_file=str(settings.users_lock_file),
        load_users_fn=load_users_fn,
        save_users_fn=save_users_fn,
        email=email,
        hd=hd,
    )


# ---------------------------------------------------------------------------
# Admin auth dependency
# ---------------------------------------------------------------------------


async def get_admin_user(
    request: Request,
    token: str | None = Query(None),
    authorization: str | None = Header(None),
    admin_session: str | None = Cookie(None),
):
    """Router-level dependency that gates admin access."""
    from .admin_handlers import require_admin

    admin_token = request.app.state.kg_settings.admin_token
    try:
        require_admin(token, admin_token=admin_token, authorization=authorization, cookie_token=admin_session)
    except HTTPException as exc:
        from .exceptions import ForbiddenError

        raise ForbiddenError(exc.detail or "Admin authentication required") from exc
