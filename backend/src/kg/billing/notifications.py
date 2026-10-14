"""App Store Server Notification / signed transaction decoding and status logic."""

from __future__ import annotations

import logging
from datetime import UTC, datetime
from typing import Any, Protocol

from ..api_models import AppStoreNotificationRequest
from ..exceptions import BadRequestError, ValidationError
from .payloads import ACTIVE_BEARING_STATUSES

_logger = logging.getLogger(__name__)


class VerifiedJWS(Protocol):
    payload: dict[str, Any]


class VerifySignedJWS(Protocol):
    def __call__(self, signed_jws: str, *, bundle_id: str) -> VerifiedJWS: ...


class ParseTimestamp(Protocol):
    def __call__(self, value: object) -> datetime | None: ...


# Types that carry no status of their own but whose signed transaction/renewal
# info is authoritative: the snapshot keeps the transaction-derived status
# (so expiry is never resurrected) and only refreshes fields like will_renew.
_TRANSACTION_DERIVED_TYPES = frozenset({"DID_CHANGE_RENEWAL_STATUS"})


def notification_status(notification_type: str | None, subtype: str | None) -> str | None:
    """Map an App Store Server Notification V2 type to a subscription status.

    Returns ``None`` when the notification type does not determine an
    entitlement status — either an unknown/future type, or one (like
    ``REFUND_DECLINED``) that explicitly leaves the subscription untouched.
    Callers MUST treat ``None`` as "do not update the snapshot" and never
    fall back to ``"active"`` (fail-open).
    """
    kind = (notification_type or "").upper()
    sub = (subtype or "").upper()
    if kind in {"SUBSCRIBED", "OFFER_REDEEMED", "DID_RENEW"}:
        return "trial" if sub == "INITIAL_BUY" else "active"
    if kind == "GRACE_PERIOD_EXPIRED":
        return "expired"
    if kind == "DID_FAIL_TO_RENEW":
        return "grace_period"
    if kind in {"EXPIRED", "REVOKE", "REFUND"}:
        # REFUND: Apple has already returned the money — revoke entitlement.
        return "expired"
    if kind == "REFUND_DECLINED":
        # Apple declined the refund — subscription state is unchanged.
        return None
    # Unknown / future notification type: fail-safe, do not touch the snapshot.
    return None


def normalize_ms_timestamp(raw: Any, parse_datetime_fn: ParseTimestamp) -> str | None:
    if raw is None:
        return None
    try:
        timestamp_ms = int(raw)
    except (TypeError, ValueError):
        parsed = parse_datetime_fn(raw)
        _logger.warning("Silently handled exception; using fallback response", exc_info=True)
        return parsed.isoformat() if parsed else None
    return datetime.fromtimestamp(timestamp_ms / 1000, tz=UTC).isoformat()


def bool_from_any(raw: Any, default: bool = False) -> bool:
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, (int, float)):
        return bool(raw)
    if isinstance(raw, str):
        return raw.strip().lower() in {"1", "true", "yes"}
    return default


def status_from_transaction_payload(
    payload: dict[str, Any],
    parse_datetime_fn: ParseTimestamp,
    renewal_payload: dict[str, Any] | None = None,
) -> str:
    if payload.get("revocationDate"):
        return "expired"
    grace = renewal_payload.get("gracePeriodExpiresDate") if isinstance(renewal_payload, dict) else None
    if grace:
        grace_dt = parse_datetime_fn(normalize_ms_timestamp(grace, parse_datetime_fn))
        if grace_dt and grace_dt > datetime.now(tz=UTC):
            return "grace_period"
    expires_at = parse_datetime_fn(normalize_ms_timestamp(payload.get("expiresDate"), parse_datetime_fn))
    if expires_at and expires_at <= datetime.now(tz=UTC):
        return "expired"
    offer_type = payload.get("offerType")
    offer_discount_type = str(payload.get("offerDiscountType") or "").upper()
    if offer_type == 1 or offer_discount_type == "FREE_TRIAL":
        return "trial"
    return "active"


def verified_transaction_snapshot(
    payload: dict[str, Any],
    *,
    parse_datetime_fn: ParseTimestamp,
    renewal_payload: dict[str, Any] | None = None,
    price_display: str | None = None,
) -> dict[str, Any]:
    product_id = payload.get("productId")
    if not isinstance(product_id, str) or not product_id.strip():
        raise ValidationError("Verified App Store transaction is missing productId")

    environment = str(payload.get("environment") or "production").lower()
    transaction_id = payload.get("transactionId")
    original_transaction_id = payload.get("originalTransactionId")
    status = status_from_transaction_payload(payload, parse_datetime_fn, renewal_payload)
    auto_renew_status = None
    grace_period_expires_at = None
    if isinstance(renewal_payload, dict):
        auto_renew_status = renewal_payload.get("autoRenewStatus")
        grace_period_expires_at = normalize_ms_timestamp(
            renewal_payload.get("gracePeriodExpiresDate"), parse_datetime_fn
        )

    return {
        "product_id": product_id.strip(),
        "transaction_id": str(transaction_id) if transaction_id is not None else None,
        "original_transaction_id": str(original_transaction_id) if original_transaction_id is not None else None,
        "environment": environment,
        "status": status,
        "is_trial": status == "trial",
        "expires_at": normalize_ms_timestamp(payload.get("expiresDate"), parse_datetime_fn),
        "grace_period_expires_at": grace_period_expires_at,
        "will_renew": bool_from_any(auto_renew_status, default=status in ACTIVE_BEARING_STATUSES),
        "price_display": price_display,
        # Apple's signing time for this JWS: the ordering key that lets a fresh
        # verified /sync or /reconcile beat an older notification watermark.
        # decode_notification_payload overrides it with the envelope signedDate.
        "signed_date": normalize_ms_timestamp(payload.get("signedDate"), parse_datetime_fn),
        # Account binding for /sync and /reconcile ownership checks; deliberately
        # not in _SNAPSHOT_FIELDS, so it is never persisted.
        "app_account_token": _str_or_none(payload.get("appAccountToken")),
    }


def _str_or_none(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def decode_signed_transaction_info(
    signed_transaction_info: str,
    *,
    bundle_id: str,
    parse_datetime_fn: ParseTimestamp,
    verify_signed_jws: VerifySignedJWS,
) -> dict[str, Any]:
    verified = verify_signed_jws(signed_transaction_info, bundle_id=bundle_id)
    return verified_transaction_snapshot(verified.payload, parse_datetime_fn=parse_datetime_fn)


def decode_notification_payload(
    req: AppStoreNotificationRequest,
    *,
    bundle_id: str,
    allow_unsigned_notifications: bool,
    parse_datetime_fn: ParseTimestamp,
    verify_signed_jws: VerifySignedJWS,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    if not req.signed_payload:
        if allow_unsigned_notifications:
            _logger.warning("Accepting unsigned App Store notification (signature verification skipped)")
            return (
                {
                    "product_id": req.product_id,
                    "transaction_id": req.transaction_id,
                    "original_transaction_id": req.original_transaction_id,
                    "environment": req.environment,
                    "status": req.status or notification_status(req.notification_type, req.subtype),
                    "is_trial": req.is_trial,
                    "expires_at": req.expires_at,
                    "will_renew": req.will_renew if req.will_renew is not None else True,
                    "price_display": None,
                },
                req.raw_payload,
            )
        raise BadRequestError("signed_payload is required for App Store notifications")

    verified_notification = verify_signed_jws(req.signed_payload, bundle_id=bundle_id)
    notification_payload = verified_notification.payload
    # Trust the verified envelope, not the client-supplied req fields, for the
    # type/subtype used in the fail-safe known-type check below.
    notification_type = notification_payload.get("notificationType")
    subtype = notification_payload.get("subtype")
    data = notification_payload.get("data", {})
    if not isinstance(data, dict):
        raise BadRequestError("App Store notification data payload is malformed")

    signed_transaction_info = data.get("signedTransactionInfo")
    signed_renewal_info = data.get("signedRenewalInfo")
    notification_uuid = notification_payload.get("notificationUUID")
    if not isinstance(notification_uuid, str) or not notification_uuid.strip():
        notification_uuid = None
    signed_date = normalize_ms_timestamp(notification_payload.get("signedDate"), parse_datetime_fn)

    if not isinstance(signed_transaction_info, str) or not signed_transaction_info:
        # Apple TEST notifications (and some types) carry no transaction. The envelope is
        # verified, so acknowledge it as an indeterminate no-op: status=None makes the
        # caller audit it and skip every billing write, and a 400 would make Apple retry (#3705).
        return (
            {
                "product_id": None,
                "transaction_id": None,
                "original_transaction_id": None,
                "environment": str(data.get("environment") or "production").lower(),
                "status": None,
                "is_trial": False,
                "expires_at": None,
                "grace_period_expires_at": None,
                "will_renew": False,
                "price_display": None,
                "signed_date": signed_date,
                "notification_uuid": notification_uuid,
            },
            notification_payload,
        )

    transaction_verified = verify_signed_jws(signed_transaction_info, bundle_id=bundle_id)
    renewal_payload = None
    if isinstance(signed_renewal_info, str) and signed_renewal_info:
        renewal_payload = verify_signed_jws(signed_renewal_info, bundle_id=bundle_id).payload

    snapshot = verified_transaction_snapshot(
        transaction_verified.payload,
        parse_datetime_fn=parse_datetime_fn,
        renewal_payload=renewal_payload,
    )
    snapshot = {
        **snapshot,
        "signed_date": signed_date,
        "notification_uuid": notification_uuid,
    }

    # Fail-safe symmetry with the unsigned path: status_from_transaction_payload
    # returns a concrete status ("active"/"trial"/...) for any un-expired
    # transaction, so a signed notification with an unknown/future type (or one
    # like REFUND_DECLINED that leaves state untouched) would otherwise
    # fail-open and grant Pro. notification_status() returns None for exactly
    # those types — when it does, clear the transaction-derived status so the
    # caller's indeterminate_status fail-safe (which only checks the status
    # field) skips the snapshot write. Known types keep their transaction-
    # derived status unchanged.
    if (
        str(notification_type or "").upper() not in _TRANSACTION_DERIVED_TYPES
        and notification_status(notification_type, subtype) is None
    ):
        _logger.warning(
            "Signed App Store notification type %r is unknown/indeterminate; "
            "clearing transaction-derived status to trigger fail-safe",
            notification_type,
        )
        snapshot = {**snapshot, "status": None, "is_trial": False}

    return snapshot, notification_payload
