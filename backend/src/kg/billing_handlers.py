from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable, Iterator
from contextlib import contextmanager
from copy import deepcopy
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Protocol

import httpx
from fastapi import HTTPException

logger = logging.getLogger(__name__)

from .api_models import (
    AppStoreNotificationRequest,
    AppStoreReconcileRequest,
    AppStoreSyncRequest,
    EntitlementsResponse,
)
from .app_store import AppStoreConfigurationError, AppStoreVerificationError
from .billing.index import resolve_claim_owner
from .billing.snapshots import is_superseded_terminal_snapshot
from .types import StoredUserRecord, SubscriptionRecord, UsersPayload
from .users_lock import users_file_lock

type UsersLoader = Callable[[], UsersPayload]
type UsersSaver = Callable[[UsersPayload], None]
type EntitlementsBuilder = Callable[[StoredUserRecord | None], EntitlementsResponse]


class FetchTransactionInfo(Protocol):
    def __call__(
        self, transaction_id: str, *, bundle_id: str, environment: str | None = None
    ) -> Awaitable[dict[str, Any]]: ...


type AppendAppStoreEvent = Callable[[dict[str, object]], None]


class SubscriptionSnapshotWriter(Protocol):
    def __call__(
        self,
        users: UsersPayload,
        user_id: str,
        *,
        product_id: str,
        status: str,
        is_trial: bool,
        expires_at: str | None,
        will_renew: bool,
        environment: str | None,
        transaction_id: str | None,
        original_transaction_id: str | None,
        source: str,
        price_display: str | None = None,
        signed_date: str | None = None,
        notification_uuid: str | None = None,
        grace_period_expires_at: str | None = None,
    ) -> StoredUserRecord: ...


type DecodeNotificationPayload = Callable[
    [AppStoreNotificationRequest],
    tuple[SubscriptionRecord, dict[str, Any] | None],
]

type ResolveUserIdFromSubscriptionIndex = Callable[[UsersPayload, str | None, str | None], str | None]

# Snapshot keys that map 1:1 onto write_subscription_snapshot kwargs across all
# three ingest paths (sync / notification / reconcile). `source` and
# `price_display` differ per path and stay explicit at the call site.
_SNAPSHOT_FIELDS = (
    "product_id",
    "status",
    "is_trial",
    "expires_at",
    "will_renew",
    "environment",
    "transaction_id",
    "original_transaction_id",
)
_ORDERING_FIELDS = ("signed_date", "notification_uuid")


@contextmanager
def _map_app_store_errors(verification_log: str, verification_detail: str) -> Iterator[None]:
    """Map the two App Store decode errors onto the uniform billing HTTP
    contract: configuration -> 500, verification -> 400. The verification log
    line and HTTP detail vary per ingest path and stay explicit."""
    try:
        yield
    except AppStoreConfigurationError as exc:
        logger.error("App Store configuration error: %s", exc, exc_info=True)
        raise HTTPException(status_code=500, detail="App Store configuration error") from exc
    except AppStoreVerificationError as exc:
        logger.warning(verification_log, exc, exc_info=True)
        raise HTTPException(status_code=400, detail=verification_detail) from exc


def _write_snapshot(
    write_subscription_snapshot: SubscriptionSnapshotWriter,
    users: UsersPayload,
    user_id: str,
    snapshot: SubscriptionRecord,
    *,
    source: str,
    price_display: str | None = None,
) -> StoredUserRecord:
    """Persist a decoded App Store snapshot via the injected writer, splatting
    the shared snapshot fields so each ingest path needn't restate all eight."""
    fields = {k: snapshot[k] for k in _SNAPSHOT_FIELDS}
    fields.update({k: snapshot[k] for k in _ORDERING_FIELDS if k in snapshot})
    return write_subscription_snapshot(
        users,
        user_id,
        source=source,
        price_display=price_display,
        grace_period_expires_at=snapshot.get("grace_period_expires_at"),
        **fields,
    )


def sync_app_store_subscription_response(
    req: AppStoreSyncRequest,
    user: StoredUserRecord,
    *,
    allow_unsigned_sync: bool,
    users_lock_file: Path,
    load_users: UsersLoader,
    save_users: UsersSaver,
    decode_signed_transaction_info: Callable[[str], SubscriptionRecord],
    write_subscription_snapshot: SubscriptionSnapshotWriter,
    build_entitlements_response: EntitlementsBuilder,
) -> EntitlementsResponse:
    with _map_app_store_errors(
        "App Store transaction verification failed: %s",
        "Transaction verification failed",
    ):
        if req.signed_transaction_info:
            snapshot = decode_signed_transaction_info(req.signed_transaction_info)
            if req.transaction_id and snapshot["transaction_id"] and req.transaction_id != snapshot["transaction_id"]:
                raise HTTPException(status_code=400, detail="transaction_id does not match signed_transaction_info")
            if (
                req.original_transaction_id
                and snapshot["original_transaction_id"]
                and req.original_transaction_id != snapshot["original_transaction_id"]
            ):
                raise HTTPException(
                    status_code=400, detail="original_transaction_id does not match signed_transaction_info"
                )
        elif not allow_unsigned_sync:
            if req.environment.lower() == "xcode":
                logger.warning(
                    "Rejected unsigned xcode sync for user %s — enable APP_STORE_ALLOW_UNSIGNED_SYNC for dev/test",
                    user.get("id"),
                )
            raise HTTPException(
                status_code=400, detail="signed_transaction_info is required for production App Store sync"
            )
        else:
            snapshot = {
                "product_id": req.product_id,
                "transaction_id": req.transaction_id,
                "original_transaction_id": req.original_transaction_id,
                "environment": req.environment,
                "status": req.status,
                "is_trial": req.is_trial,
                "expires_at": req.expires_at,
                "will_renew": req.will_renew,
                "price_display": req.price_display,
            }

    with users_file_lock(users_lock_file):
        users = load_users()
        if req.signed_transaction_info:
            resolve_claim_owner(users, user["id"], snapshot)
        record = _write_snapshot(
            write_subscription_snapshot,
            users,
            user["id"],
            snapshot,
            source="app_store",
            price_display=snapshot["price_display"],
        )
        save_users(users)

    return build_entitlements_response(record)


def app_store_notifications_response(
    req: AppStoreNotificationRequest,
    *,
    users_lock_file: Path,
    load_users: UsersLoader,
    save_users: UsersSaver,
    decode_notification_payload: DecodeNotificationPayload,
    append_app_store_event: AppendAppStoreEvent,
    resolve_user_id_from_subscription_index: ResolveUserIdFromSubscriptionIndex,
    write_subscription_snapshot: SubscriptionSnapshotWriter,
    build_entitlements_response: EntitlementsBuilder,
) -> dict[str, Any]:
    with _map_app_store_errors(
        "App Store notification verification failed: %s",
        "Transaction verification failed",
    ):
        snapshot, decoded_payload = decode_notification_payload(req)

    event = {
        "received_at": datetime.now(tz=UTC).isoformat(),
        "notification_type": req.notification_type,
        "subtype": req.subtype,
        "product_id": snapshot["product_id"],
        "transaction_id": snapshot["transaction_id"],
        "original_transaction_id": snapshot["original_transaction_id"],
        "environment": snapshot["environment"],
        "status": snapshot["status"],
        "is_trial": snapshot["is_trial"],
        "expires_at": snapshot["expires_at"],
        "will_renew": snapshot["will_renew"],
        "signed_payload": req.signed_payload,
        "raw_payload": decoded_payload or req.raw_payload,
        "signed_date": snapshot.get("signed_date"),
        "notification_uuid": snapshot.get("notification_uuid"),
    }

    with users_file_lock(users_lock_file):
        users = load_users()
        # The append-only audit event is recorded under the same user lock and
        # before any ordering decision, so stale/duplicate deliveries remain
        # observable without being allowed to mutate entitlement state.
        append_app_store_event(event)

        # An unknown / future notification type (or one like REFUND_DECLINED
        # that leaves state unchanged) yields status=None. Fail-safe:
        # acknowledge the delivery but do NOT mutate the subscription — never
        # fail-open to "active".
        if not snapshot.get("status"):
            logger.warning(
                "App Store notification type %r produced no determinate status; skipping snapshot update (fail-safe)",
                req.notification_type,
            )
            return {"status": "accepted", "updated": False, "reason": "indeterminate_status"}

        user_id = resolve_user_id_from_subscription_index(
            users,
            snapshot["original_transaction_id"],
            snapshot["transaction_id"],
        )
        if not user_id:
            return {"status": "accepted", "updated": False, "reason": "unmapped_transaction"}
        current_record = users.get(user_id)
        if is_superseded_terminal_snapshot(current_record.get("subscription") if current_record else None, snapshot):
            logger.info(
                "App Store terminal notification %r for superseded transaction ignored for user %s",
                req.notification_type,
                user_id,
            )
            return {
                "status": "accepted",
                "updated": False,
                "user_id": user_id,
                "entitlements": build_entitlements_response(current_record).model_dump(),
                "reason": "superseded_transaction",
            }
        previous_subscription = deepcopy(users.get(user_id, {}).get("subscription"))
        record = _write_snapshot(
            write_subscription_snapshot,
            users,
            user_id,
            snapshot,
            source="app_store_notification",
        )
        updated = record.get("subscription") != previous_subscription
        if updated:
            save_users(users)

    response = {
        "status": "accepted",
        "updated": updated,
        "user_id": user_id,
        "entitlements": build_entitlements_response(record).model_dump(),
    }
    if not updated:
        response["reason"] = "stale_notification"
    return response


async def reconcile_app_store_subscription_response(
    req: AppStoreReconcileRequest,
    user: StoredUserRecord,
    *,
    apple_bundle_id: str,
    users_lock_file: Path,
    load_users: UsersLoader,
    save_users: UsersSaver,
    fetch_transaction_info: FetchTransactionInfo,
    decode_signed_transaction_info: Callable[[str], SubscriptionRecord],
    resolve_user_id_from_subscription_index: ResolveUserIdFromSubscriptionIndex,
    write_subscription_snapshot: SubscriptionSnapshotWriter,
    build_entitlements_response: EntitlementsBuilder,
) -> EntitlementsResponse:
    try:
        with _map_app_store_errors(
            "App Store transaction decode failed: %s",
            "Invalid transaction response",
        ):
            server_response = await fetch_transaction_info(
                req.transaction_id,
                bundle_id=apple_bundle_id,
                environment=req.environment,
            )
            signed_transaction_info = server_response.get("signedTransactionInfo")
            if not isinstance(signed_transaction_info, str) or not signed_transaction_info:
                raise HTTPException(
                    status_code=502, detail="App Store transaction lookup did not return signedTransactionInfo"
                )
            snapshot = decode_signed_transaction_info(signed_transaction_info)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=502, detail=f"App Store API lookup failed: HTTP {exc.response.status_code}"
        ) from exc
    except httpx.HTTPError as exc:
        logger.warning("App Store API network error: %s", exc)
        raise HTTPException(status_code=502, detail="App Store service unavailable") from exc

    def _persist_snapshot() -> StoredUserRecord:
        with users_file_lock(users_lock_file):
            users = load_users()
            # Never write to (or return) another live user's record.
            resolved_user_id = resolve_claim_owner(users, user["id"], snapshot, resolve_user_id_from_subscription_index)
            record = _write_snapshot(
                write_subscription_snapshot,
                users,
                resolved_user_id,
                snapshot,
                source="app_store_server_api",
            )
            save_users(users)
            return record

    # The users.json FileLock wait + file IO must not run on the event loop.
    record = await asyncio.to_thread(_persist_snapshot)
    return build_entitlements_response(record)
