"""Persisting App Store subscription snapshots and raw event logs."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from ..types import StoredUserRecord, UsersPayload
from .index import upsert_subscription_index
from .payloads import ACTIVE_BEARING_STATUSES, default_subscription_payload

_TERMINAL_STATUSES = frozenset({"expired", "revoked", "refunded"})


def _parse_signed_date(value: object) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def should_apply_subscription_snapshot(
    existing: object,
    incoming: dict[str, Any],
) -> bool:
    """Reject stale or duplicate Apple-signed snapshots without losing audit data.

    The watermark is Apple's ``signedDate``: a notification's envelope, or the
    transaction JWS of a verified /sync or /reconcile.
    """
    existing_subscription = existing if isinstance(existing, dict) else {}
    existing_date = _parse_signed_date(existing_subscription.get("last_signed_date"))
    incoming_date = _parse_signed_date(incoming.get("signed_date"))

    # Unsigned/dev snapshots remain supported, but may not erase an ordering
    # watermark established by an Apple-signed notification or transaction.
    if existing_date is not None and incoming_date is None:
        return False
    if incoming_date is None or existing_date is None:
        return True
    if incoming_date != existing_date:
        return incoming_date > existing_date

    existing_terminal = existing_subscription.get("status") in _TERMINAL_STATUSES
    incoming_terminal = incoming.get("status") in _TERMINAL_STATUSES
    incoming_uuid = incoming.get("notification_uuid")
    existing_uuid = existing_subscription.get("last_notification_uuid")
    if isinstance(incoming_uuid, str) and incoming_uuid and incoming_uuid == existing_uuid:
        return False
    if existing_terminal != incoming_terminal:
        # At one signedDate, terminal state wins over an active state even if
        # UUID ordering would otherwise select the active notification.
        return incoming_terminal

    if not isinstance(incoming_uuid, str) or not incoming_uuid:
        return False
    if not isinstance(existing_uuid, str) or not existing_uuid:
        return True
    return incoming_uuid > existing_uuid


def is_superseded_terminal_snapshot(existing: object, incoming: dict[str, Any]) -> bool:
    """A terminal notification for a non-current transaction must not end the current period.

    Apple's ``signedDate`` only orders envelopes; a REFUND/REVOKE for an older
    period's transaction (T1) can carry a later ``signedDate`` than the
    DID_RENEW that started the current transaction (T2). It may apply only when it
    is for the stored current transaction or when it does not end before the
    stored ``expires_at``.
    """
    existing_subscription = existing if isinstance(existing, dict) else {}
    if incoming.get("status") not in _TERMINAL_STATUSES:
        return False
    current_transaction_id = existing_subscription.get("transaction_id")
    if not isinstance(current_transaction_id, str) or not current_transaction_id:
        return False
    if incoming.get("transaction_id") == current_transaction_id:
        return False
    current_expires_at = _parse_signed_date(existing_subscription.get("expires_at"))
    incoming_expires_at = _parse_signed_date(incoming.get("expires_at"))
    if current_expires_at is None or incoming_expires_at is None:
        return False
    return incoming_expires_at < current_expires_at


def append_app_store_event(notifications_file: Path, payload: dict[str, Any]) -> None:
    notifications_file.parent.mkdir(parents=True, exist_ok=True)
    with notifications_file.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, ensure_ascii=False) + "\n")


def write_subscription_snapshot(
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
    record = users.setdefault(user_id, {})
    existing = record.get("subscription")
    if not should_apply_subscription_snapshot(
        existing,
        {"status": status, "signed_date": signed_date, "notification_uuid": notification_uuid},
    ):
        return record

    now_iso = datetime.now(tz=UTC).isoformat()
    subscription = default_subscription_payload()
    if isinstance(existing, dict):
        subscription.update(existing)

    normalized_status = status.strip() or "active"
    subscription.update(
        {
            "is_active": normalized_status in ACTIVE_BEARING_STATUSES,
            "product_id": product_id.strip(),
            "plan_name": "Books & Vocab Pro",
            "price_display": price_display.strip()
            if isinstance(price_display, str) and price_display.strip()
            else subscription.get("price_display"),
            "status": normalized_status,
            "is_trial": is_trial,
            "trial_days": subscription.get("trial_days") or 7,
            "will_renew": will_renew,
            "expires_at": expires_at,
            # Always overwritten so a stale grace deadline cannot outlive grace.
            "grace_period_expires_at": grace_period_expires_at,
            "source": source,
            "last_synced_at": now_iso,
            "transaction_id": transaction_id,
            "original_transaction_id": original_transaction_id,
            "environment": environment,
        }
    )
    if signed_date is not None:
        subscription["last_signed_date"] = signed_date
        subscription["last_notification_uuid"] = notification_uuid
    record["subscription"] = subscription
    upsert_subscription_index(users, user_id, original_transaction_id, transaction_id)
    return record
