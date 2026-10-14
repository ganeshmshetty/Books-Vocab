from __future__ import annotations

from copy import deepcopy
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest

from kg.api_models import (
    AppStoreNotificationRequest,
    AppStoreReconcileRequest,
    AppStoreSyncRequest,
    EntitlementsResponse,
    SubscriptionStatusResponse,
)
from kg.billing.index import resolve_user_id_from_subscription_index
from kg.billing.notifications import (
    decode_notification_payload,
    decode_signed_transaction_info,
    status_from_transaction_payload,
    verified_transaction_snapshot,
)
from kg.billing.snapshots import write_subscription_snapshot
from kg.billing_handlers import (
    app_store_notifications_response,
    reconcile_app_store_subscription_response,
    sync_app_store_subscription_response,
)
from kg.user_store import parse_datetime


def test_future_grace_period_takes_precedence_over_expired_transaction():
    now = datetime.now(tz=UTC)

    def to_ms(value):
        return int(value.timestamp() * 1000)

    status = status_from_transaction_payload(
        {"expiresDate": to_ms(now - timedelta(days=1))},
        parse_datetime,
        {"gracePeriodExpiresDate": to_ms(now + timedelta(days=1))},
    )

    assert status == "grace_period"


def _entitlements(record):
    subscription = record.get("subscription", {})
    return EntitlementsResponse(
        pro=SubscriptionStatusResponse(
            is_active=subscription.get("is_active", False),
            status=subscription.get("status", "inactive"),
        )
    )


def _snapshot(*, status: str, signed_date: str, notification_uuid: str):
    return {
        "product_id": "pro_monthly",
        "transaction_id": f"txn-{notification_uuid}",
        "original_transaction_id": "orig-1",
        "environment": "production",
        "status": status,
        "is_trial": False,
        "expires_at": None,
        "will_renew": status == "active",
        "price_display": None,
        "signed_date": signed_date,
        "notification_uuid": notification_uuid,
    }


def _send_notification(tmp_path: Path, users, events, snapshot, notification_type: str):
    def append_event(event):
        events.append(deepcopy(event))

    return app_store_notifications_response(
        AppStoreNotificationRequest(
            notification_type=notification_type,
            signed_payload=f"signed-{snapshot['notification_uuid']}",
        ),
        users_lock_file=tmp_path / "users.lock",
        load_users=lambda: users,
        save_users=lambda updated: None,
        decode_notification_payload=lambda request: (snapshot, {"notificationType": notification_type}),
        append_app_store_event=append_event,
        resolve_user_id_from_subscription_index=lambda loaded, original, transaction: "u1",
        write_subscription_snapshot=write_subscription_snapshot,
        build_entitlements_response=_entitlements,
    )


def test_newer_refund_cannot_be_reopened_by_older_renew(tmp_path):
    users = {}
    events = []

    _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="expired", signed_date="2026-08-01T00:00:00+00:00", notification_uuid="refund"),
        "REFUND",
    )
    result = _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="active", signed_date="2026-07-31T00:00:00+00:00", notification_uuid="renew-old"),
        "DID_RENEW",
    )

    assert users["u1"]["subscription"]["status"] == "expired"
    assert users["u1"]["subscription"]["is_active"] is False
    assert result["updated"] is False
    assert len(events) == 2


def test_newer_expired_cannot_be_reopened_by_older_active(tmp_path):
    users = {}
    events = []

    _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="expired", signed_date="2026-08-02T00:00:00+00:00", notification_uuid="expired"),
        "EXPIRED",
    )
    result = _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="active", signed_date="2026-08-01T00:00:00+00:00", notification_uuid="renew-old"),
        "DID_RENEW",
    )

    assert users["u1"]["subscription"]["status"] == "expired"
    assert result["updated"] is False


def _transaction_snapshot(*, status: str, signed_date: str, uuid: str, transaction_id: str, expires_at: str):
    return {
        **_snapshot(status=status, signed_date=signed_date, notification_uuid=uuid),
        "transaction_id": transaction_id,
        "expires_at": expires_at,
    }


def test_refund_of_superseded_transaction_cannot_expire_current_period(tmp_path):
    users = {}
    events = []
    _send_notification(
        tmp_path,
        users,
        events,
        _transaction_snapshot(
            status="active",
            signed_date="2026-10-01T00:00:00+00:00",
            uuid="renew-t2",
            transaction_id="txn-T2",
            expires_at="2099-11-01T00:00:00+00:00",
        ),
        "DID_RENEW",
    )
    result = _send_notification(
        tmp_path,
        users,
        events,
        _transaction_snapshot(
            status="expired",
            signed_date="2026-10-10T00:00:00+00:00",
            uuid="refund-t1",
            transaction_id="txn-T1",
            expires_at="2026-10-01T00:00:00+00:00",
        ),
        "REFUND",
    )

    subscription = users["u1"]["subscription"]
    assert subscription["status"] == "active"
    assert subscription["is_active"] is True
    assert subscription["transaction_id"] == "txn-T2"
    assert result["updated"] is False
    assert result["reason"] == "superseded_transaction"
    assert len(events) == 2


def test_refund_of_current_transaction_still_expires_subscription(tmp_path):
    users = {}
    events = []
    _send_notification(
        tmp_path,
        users,
        events,
        _transaction_snapshot(
            status="active",
            signed_date="2026-10-01T00:00:00+00:00",
            uuid="renew-t2",
            transaction_id="txn-T2",
            expires_at="2099-11-01T00:00:00+00:00",
        ),
        "DID_RENEW",
    )
    result = _send_notification(
        tmp_path,
        users,
        events,
        _transaction_snapshot(
            status="expired",
            signed_date="2026-10-10T00:00:00+00:00",
            uuid="refund-t2",
            transaction_id="txn-T2",
            expires_at="2099-11-01T00:00:00+00:00",
        ),
        "REFUND",
    )

    subscription = users["u1"]["subscription"]
    assert subscription["status"] == "expired"
    assert subscription["is_active"] is False
    assert result["updated"] is True


def test_duplicate_notification_uuid_is_audit_only(tmp_path):
    users = {}
    events = []
    first = _snapshot(status="active", signed_date="2026-08-01T00:00:00+00:00", notification_uuid="same")
    duplicate = _snapshot(status="expired", signed_date="2026-08-01T00:00:00+00:00", notification_uuid="same")

    _send_notification(tmp_path, users, events, first, "DID_RENEW")
    result = _send_notification(tmp_path, users, events, duplicate, "REFUND")

    assert users["u1"]["subscription"]["status"] == "active"
    assert result["updated"] is False
    assert len(events) == 2


def test_forward_order_applies_latest_watermark_and_preserves_event_metadata(tmp_path):
    users = {}
    events = []

    _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="active", signed_date="2026-08-01T00:00:00+00:00", notification_uuid="renew"),
        "DID_RENEW",
    )
    result = _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="expired", signed_date="2026-08-02T00:00:00+00:00", notification_uuid="expired"),
        "EXPIRED",
    )

    assert users["u1"]["subscription"]["status"] == "expired"
    assert users["u1"]["subscription"]["last_signed_date"] == "2026-08-02T00:00:00+00:00"
    assert users["u1"]["subscription"]["last_notification_uuid"] == "expired"
    assert result["updated"] is True
    assert [event["notification_uuid"] for event in events] == ["renew", "expired"]
    assert [event["signed_date"] for event in events] == [
        "2026-08-01T00:00:00+00:00",
        "2026-08-02T00:00:00+00:00",
    ]


def test_signed_envelope_metadata_survives_decode():
    signed_date = int(datetime(2026, 8, 1, tzinfo=UTC).timestamp() * 1000)
    payloads = {
        "notification": {
            "notificationType": "DID_RENEW",
            "signedDate": signed_date,
            "notificationUUID": "notification-1",
            "data": {"signedTransactionInfo": "transaction"},
        },
        "transaction": {
            "productId": "pro_monthly",
            "transactionId": "txn-1",
            "originalTransactionId": "orig-1",
            "environment": "Production",
            "expiresDate": 2_000_000_000_000,
        },
    }

    snapshot, envelope = decode_notification_payload(
        AppStoreNotificationRequest(signed_payload="notification"),
        bundle_id="com.example.app",
        allow_unsigned_notifications=False,
        parse_datetime_fn=parse_datetime,
        verify_signed_jws=lambda token, *, bundle_id: SimpleNamespace(payload=payloads[token]),
    )

    assert envelope == payloads["notification"]
    assert snapshot["signed_date"] == "2026-08-01T00:00:00+00:00"
    assert snapshot["notification_uuid"] == "notification-1"


def test_unsigned_snapshot_cannot_override_signed_watermark(tmp_path):
    users = {}
    events = []
    _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="expired", signed_date="2026-08-02T00:00:00+00:00", notification_uuid="expired"),
        "EXPIRED",
    )
    unsigned = {
        **_snapshot(status="active", signed_date="2026-08-01T00:00:00+00:00", notification_uuid="unsigned"),
        "signed_date": None,
        "notification_uuid": None,
    }
    result = _send_notification(tmp_path, users, events, unsigned, "DID_RENEW")

    assert users["u1"]["subscription"]["status"] == "expired"
    assert result["updated"] is False


def test_same_signed_date_uses_deterministic_uuid_tie_break(tmp_path):
    users = {}
    events = []
    _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="active", signed_date="2026-08-01T00:00:00+00:00", notification_uuid="b"),
        "DID_RENEW",
    )
    result = _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="active", signed_date="2026-08-01T00:00:00+00:00", notification_uuid="a"),
        "DID_RENEW",
    )

    assert users["u1"]["subscription"]["last_notification_uuid"] == "b"
    assert result["updated"] is False


# --- Verified /sync and /reconcile against a notification watermark (#2247) ---
#
# These exercise the real decode_signed_transaction_info and the real
# write_subscription_snapshot; only the Apple JWS signature check is stubbed.

_NOT_EXPIRED_MS = 2_000_000_000_000  # 2033 — keeps the transaction "active".


def _ms(iso: str) -> int:
    return int(datetime.fromisoformat(iso).timestamp() * 1000)


def _verified_txn(*, transaction_id: str, signed_date: str | None):
    payload = {
        "productId": "pro_monthly",
        "transactionId": transaction_id,
        "originalTransactionId": "orig-1",
        "environment": "Production",
        "expiresDate": _NOT_EXPIRED_MS,
    }
    if signed_date is not None:
        payload["signedDate"] = _ms(signed_date)

    def decode(signed_transaction_info: str):
        return decode_signed_transaction_info(
            signed_transaction_info,
            bundle_id="com.example.app",
            parse_datetime_fn=parse_datetime,
            verify_signed_jws=lambda token, *, bundle_id: SimpleNamespace(payload=payload),
        )

    return decode


def _sync(tmp_path: Path, users, request: AppStoreSyncRequest, *, decode, allow_unsigned_sync: bool = False):
    return sync_app_store_subscription_response(
        request,
        {"id": "u1"},
        allow_unsigned_sync=allow_unsigned_sync,
        users_lock_file=tmp_path / "users.lock",
        load_users=lambda: users,
        save_users=lambda updated: None,
        decode_signed_transaction_info=decode,
        write_subscription_snapshot=write_subscription_snapshot,
        build_entitlements_response=_entitlements,
    )


def _send_expired(tmp_path: Path, users) -> None:
    _send_notification(
        tmp_path,
        users,
        [],
        _snapshot(status="expired", signed_date="2026-08-02T00:00:00+00:00", notification_uuid="exp"),
        "EXPIRED",
    )


def test_verified_transaction_snapshot_carries_transaction_signed_date():
    signed = _verified_txn(transaction_id="txn-1", signed_date="2026-09-01T00:00:00+00:00")("jws")
    unsigned = _verified_txn(transaction_id="txn-1", signed_date=None)("jws")

    assert signed.get("signed_date") == "2026-09-01T00:00:00+00:00"
    assert unsigned["signed_date"] is None


def test_verified_transaction_snapshot_carries_grace_period_expires_at():
    payload = {"productId": "pro_monthly", "transactionId": "t", "expiresDate": _NOT_EXPIRED_MS}
    ms = _ms("2026-09-10T00:00:00+00:00")
    with_grace = verified_transaction_snapshot(
        payload, parse_datetime_fn=parse_datetime, renewal_payload={"gracePeriodExpiresDate": ms}
    )
    without = verified_transaction_snapshot(payload, parse_datetime_fn=parse_datetime, renewal_payload={})
    assert with_grace["grace_period_expires_at"] == "2026-09-10T00:00:00+00:00"
    assert without["grace_period_expires_at"] is None
    assert verified_transaction_snapshot(payload, parse_datetime_fn=parse_datetime)["grace_period_expires_at"] is None


def _grace_notification_jws(*, notification_type: str, uuid: str, signed_date: str, grace_ms: int | None):
    """Signed-notification stand-in: only the Apple JWS signature check is stubbed."""
    payloads = {
        "notification": {
            "notificationType": notification_type,
            "signedDate": _ms(signed_date),
            "notificationUUID": uuid,
            "data": {"signedTransactionInfo": "transaction"},
        },
        "transaction": {
            "productId": "pro_monthly",
            "transactionId": f"txn-{uuid}",
            "originalTransactionId": "orig-1",
            "environment": "Production",
            "expiresDate": _ms("2020-01-01T00:00:00+00:00"),
        },
    }
    if grace_ms is not None:
        payloads["notification"]["data"]["signedRenewalInfo"] = "renewal"
        payloads["renewal"] = {"gracePeriodExpiresDate": grace_ms, "autoRenewStatus": 1}
    return payloads


def _real_decode_notification(tmp_path: Path, users, *, notification_type: str, **kwargs):
    payloads = _grace_notification_jws(notification_type=notification_type, **kwargs)
    return app_store_notifications_response(
        AppStoreNotificationRequest(notification_type=notification_type, signed_payload="notification"),
        users_lock_file=tmp_path / "users.lock",
        load_users=lambda: users,
        save_users=lambda updated: None,
        decode_notification_payload=lambda request: decode_notification_payload(
            request,
            bundle_id="com.example.app",
            allow_unsigned_notifications=False,
            parse_datetime_fn=parse_datetime,
            verify_signed_jws=lambda token, *, bundle_id: SimpleNamespace(payload=payloads[token]),
        ),
        append_app_store_event=lambda event: None,
        resolve_user_id_from_subscription_index=lambda loaded, original, transaction: "u1",
        write_subscription_snapshot=write_subscription_snapshot,
        build_entitlements_response=_entitlements,
    )


def test_fail_to_renew_notification_persists_grace_deadline_and_later_renew_clears_it(tmp_path):
    users = {}

    _real_decode_notification(
        tmp_path,
        users,
        notification_type="DID_FAIL_TO_RENEW",
        uuid="grace",
        signed_date="2026-08-01T00:00:00+00:00",
        grace_ms=_ms("2099-01-01T00:00:00+00:00"),
    )
    subscription = users["u1"]["subscription"]
    assert subscription["status"] == "grace_period"
    assert subscription["grace_period_expires_at"] == "2099-01-01T00:00:00+00:00"

    _real_decode_notification(
        tmp_path,
        users,
        notification_type="DID_RENEW",
        uuid="renewed",
        signed_date="2026-08-02T00:00:00+00:00",
        grace_ms=None,
    )
    subscription = users["u1"]["subscription"]
    assert subscription["status"] != "grace_period"
    assert subscription["grace_period_expires_at"] is None


def test_notification_envelope_signed_date_wins_over_transaction_signed_date():
    payloads = {
        "notification": {
            "notificationType": "DID_RENEW",
            "signedDate": _ms("2026-08-01T00:00:00+00:00"),
            "notificationUUID": "notification-1",
            "data": {"signedTransactionInfo": "transaction"},
        },
        "transaction": {
            "productId": "pro_monthly",
            "transactionId": "txn-1",
            "originalTransactionId": "orig-1",
            "environment": "Production",
            "expiresDate": _NOT_EXPIRED_MS,
            "signedDate": _ms("2026-07-01T00:00:00+00:00"),
        },
    }

    snapshot, _ = decode_notification_payload(
        AppStoreNotificationRequest(signed_payload="notification"),
        bundle_id="com.example.app",
        allow_unsigned_notifications=False,
        parse_datetime_fn=parse_datetime,
        verify_signed_jws=lambda token, *, bundle_id: SimpleNamespace(payload=payloads[token]),
    )

    assert snapshot["signed_date"] == "2026-08-01T00:00:00+00:00"


def test_verified_sync_after_expired_notification_restores_entitlement(tmp_path):
    users = {}
    events = []
    _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="active", signed_date="2026-08-01T00:00:00+00:00", notification_uuid="sub"),
        "SUBSCRIBED",
    )
    _send_notification(
        tmp_path,
        users,
        events,
        _snapshot(status="expired", signed_date="2026-08-02T00:00:00+00:00", notification_uuid="exp"),
        "EXPIRED",
    )

    result = _sync(
        tmp_path,
        users,
        AppStoreSyncRequest(product_id="pro_monthly", signed_transaction_info="jws"),
        decode=_verified_txn(transaction_id="txn-resub", signed_date="2026-09-01T00:00:00+00:00"),
    )

    subscription = users["u1"]["subscription"]
    assert result.pro.is_active is True
    assert result.pro.status == "active"
    assert subscription["transaction_id"] == "txn-resub"
    assert subscription["last_signed_date"] == "2026-09-01T00:00:00+00:00"


@pytest.mark.asyncio
async def test_verified_reconcile_after_expired_notification_updates_subscription_and_index(tmp_path):
    users = {}
    _send_expired(tmp_path, users)

    async def fetch_transaction_info(transaction_id, *, bundle_id, environment=None):
        assert transaction_id == "txn-reconciled"
        return {"signedTransactionInfo": "jws"}

    result = await reconcile_app_store_subscription_response(
        AppStoreReconcileRequest(transaction_id="txn-reconciled", environment="production"),
        {"id": "u1"},
        apple_bundle_id="com.example.app",
        users_lock_file=tmp_path / "users.lock",
        load_users=lambda: users,
        save_users=lambda updated: None,
        fetch_transaction_info=fetch_transaction_info,
        decode_signed_transaction_info=_verified_txn(
            transaction_id="txn-reconciled", signed_date="2026-09-01T00:00:00+00:00"
        ),
        resolve_user_id_from_subscription_index=resolve_user_id_from_subscription_index,
        write_subscription_snapshot=write_subscription_snapshot,
        build_entitlements_response=_entitlements,
    )

    subscription = users["u1"]["subscription"]
    assert result.pro.status == "active"
    assert subscription["status"] == "active"
    assert subscription["last_signed_date"] == "2026-09-01T00:00:00+00:00"
    assert users["_subscription_index"]["txn-reconciled"] == "u1"


def test_replayed_older_verified_jws_cannot_override_newer_watermark(tmp_path):
    users = {}
    _send_expired(tmp_path, users)

    result = _sync(
        tmp_path,
        users,
        AppStoreSyncRequest(product_id="pro_monthly", signed_transaction_info="jws"),
        decode=_verified_txn(transaction_id="txn-old", signed_date="2026-07-15T00:00:00+00:00"),
    )

    subscription = users["u1"]["subscription"]
    assert result.pro.is_active is False
    assert result.pro.status == "expired"
    assert subscription["last_signed_date"] == "2026-08-02T00:00:00+00:00"
    assert "txn-old" not in users["_subscription_index"]


def test_unsigned_dev_sync_cannot_override_signed_watermark(tmp_path):
    users = {}
    _send_expired(tmp_path, users)

    def must_not_decode(signed_transaction_info: str):
        raise AssertionError("unsigned sync must not decode a JWS")

    result = _sync(
        tmp_path,
        users,
        AppStoreSyncRequest(product_id="pro_monthly", transaction_id="txn-dev", environment="xcode"),
        decode=must_not_decode,
        allow_unsigned_sync=True,
    )

    assert result.pro.status == "expired"
    assert users["u1"]["subscription"]["last_signed_date"] == "2026-08-02T00:00:00+00:00"
    assert "txn-dev" not in users["_subscription_index"]
