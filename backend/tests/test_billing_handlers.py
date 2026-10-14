from __future__ import annotations

from unittest.mock import MagicMock

import httpx
import pytest
from fastapi import HTTPException

from kg.api_models import (
    AppStoreNotificationRequest,
    AppStoreReconcileRequest,
    AppStoreSyncRequest,
    EntitlementsResponse,
    SubscriptionStatusResponse,
)
from kg.app_store import AppStoreConfigurationError, AppStoreVerificationError
from kg.billing_handlers import (
    app_store_notifications_response,
    reconcile_app_store_subscription_response,
    sync_app_store_subscription_response,
)


def _active_entitlements():
    return EntitlementsResponse(pro=SubscriptionStatusResponse(is_active=True, status="active"))


def _make_snapshot(transaction_id="txn-1", original_transaction_id="orig-1"):
    return {
        "product_id": "pro_monthly",
        "transaction_id": transaction_id,
        "original_transaction_id": original_transaction_id,
        "environment": "sandbox",
        "status": "active",
        "is_trial": False,
        "expires_at": None,
        "will_renew": True,
        "price_display": None,
    }


# ── notification handler ───────────────────────────────────────────────────────


def test_notification_normal_flow_updated(tmp_path):
    snapshot = _make_snapshot()
    decode_fn = MagicMock(return_value=(snapshot, {"notification_type": "DID_RENEW"}))
    append_fn = MagicMock()

    lock = tmp_path / "lock"

    def resolve_fn(users, oti, ti):
        return "u1"

    def write_sub(users, uid, **kwargs):
        record = {"subscription": {"status": "active"}}
        users[uid] = record
        return record

    req = AppStoreNotificationRequest(
        notification_type="DID_RENEW",
        signed_payload="signed.payload",
    )

    result = app_store_notifications_response(
        req,
        users_lock_file=lock,
        load_users=lambda: {},
        save_users=lambda u: None,
        decode_notification_payload=decode_fn,
        append_app_store_event=append_fn,
        resolve_user_id_from_subscription_index=resolve_fn,
        write_subscription_snapshot=write_sub,
        build_entitlements_response=lambda rec: _active_entitlements(),
    )

    append_fn.assert_called_once()
    assert result["status"] == "accepted"
    assert result["updated"] is True


def test_notification_unmapped_transaction_accepted(tmp_path):
    snapshot = _make_snapshot(transaction_id="txn-unknown", original_transaction_id="orig-unknown")
    decode_fn = MagicMock(return_value=(snapshot, None))
    append_fn = MagicMock()

    req = AppStoreNotificationRequest(notification_type="DID_RENEW", signed_payload="s")

    result = app_store_notifications_response(
        req,
        users_lock_file=tmp_path / "lock",
        load_users=lambda: {},
        save_users=lambda u: None,
        decode_notification_payload=decode_fn,
        append_app_store_event=append_fn,
        resolve_user_id_from_subscription_index=lambda *a: None,
        write_subscription_snapshot=MagicMock(),
        build_entitlements_response=lambda rec: _active_entitlements(),
    )

    assert result["status"] == "accepted"
    assert result["updated"] is False
    assert result["reason"] == "unmapped_transaction"


# ── reconcile handler ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_reconcile_apple_api_failure_raises_502(tmp_path):
    import httpx

    async def fetch_fail(*args, **kwargs):
        raise httpx.HTTPStatusError("err", request=MagicMock(), response=MagicMock(status_code=503))

    req = AppStoreReconcileRequest(transaction_id="txn-1", environment="production")

    with pytest.raises(HTTPException) as exc_info:
        await reconcile_app_store_subscription_response(
            req,
            {"id": "u1"},
            apple_bundle_id="com.example.app",
            users_lock_file=tmp_path / "lock",
            load_users=lambda: {},
            save_users=lambda u: None,
            fetch_transaction_info=fetch_fail,
            decode_signed_transaction_info=MagicMock(),
            resolve_user_id_from_subscription_index=lambda *a: None,
            write_subscription_snapshot=MagicMock(),
            build_entitlements_response=lambda rec: _active_entitlements(),
        )
    assert exc_info.value.status_code == 502


@pytest.mark.asyncio
async def test_reconcile_normal_flow_returns_entitlements(tmp_path):
    snapshot = _make_snapshot()
    decode_fn = MagicMock(return_value=snapshot)

    async def fetch_ok(*args, **kwargs):
        return {"signedTransactionInfo": "signed.jws"}

    def write_sub(users, uid, **kwargs):
        record = {"subscription": {"status": "active"}}
        users[uid] = record
        return record

    req = AppStoreReconcileRequest(transaction_id="txn-1", environment="production")

    result = await reconcile_app_store_subscription_response(
        req,
        {"id": "u1"},
        apple_bundle_id="com.example.app",
        users_lock_file=tmp_path / "lock",
        load_users=lambda: {},
        save_users=lambda u: None,
        fetch_transaction_info=fetch_ok,
        decode_signed_transaction_info=decode_fn,
        resolve_user_id_from_subscription_index=lambda *a: None,
        write_subscription_snapshot=write_sub,
        build_entitlements_response=lambda rec: _active_entitlements(),
    )

    decode_fn.assert_called_once_with("signed.jws")
    assert isinstance(result, EntitlementsResponse)


# ── #2253: reconcile must not touch or leak another live user's record ─────────


def _reconcile_with(users, caller, token):
    from kg.billing import resolve_user_id_from_subscription_index as resolve
    from kg.billing import write_subscription_snapshot as real_write

    snapshot = _make_snapshot()
    if token is not None:
        snapshot["app_account_token"] = token
    saved = MagicMock()

    async def fetch_ok(*args, **kwargs):
        return {"signedTransactionInfo": "signed.jws"}

    async def run(tmp_path):
        return await reconcile_app_store_subscription_response(
            AppStoreReconcileRequest(transaction_id="txn-1", environment="production"),
            {"id": caller},
            apple_bundle_id="com.example.app",
            users_lock_file=tmp_path / "lock",
            load_users=lambda: users,
            save_users=saved,
            fetch_transaction_info=fetch_ok,
            decode_signed_transaction_info=lambda _s: snapshot,
            resolve_user_id_from_subscription_index=resolve,
            write_subscription_snapshot=real_write,
            build_entitlements_response=lambda rec: EntitlementsResponse(
                pro=SubscriptionStatusResponse(is_active=True, status="active", product_id="pro_monthly")
            ),
        )

    return saved, run


def _owned_users():
    return {
        "P": {"subscription": {"is_active": True, "status": "active", "original_transaction_id": "orig-1"}},
        "Q": {"config": {}},
        "_subscription_index": {"orig-1": "P", "txn-1": "P"},
    }


@pytest.mark.asyncio
@pytest.mark.parametrize("token_owner", [None, "P"])
async def test_reconcile_other_users_transaction_rejected_and_state_unchanged(tmp_path, token_owner):
    import copy

    from kg.billing.index import account_token_for_user

    users = _owned_users()
    before = copy.deepcopy(users)
    token = account_token_for_user(token_owner) if token_owner else None
    saved, run = _reconcile_with(users, "Q", token)
    with pytest.raises(HTTPException) as exc:
        await run(tmp_path)
    assert exc.value.status_code in (403, 409)
    assert "pro_monthly" not in str(exc.value.detail)
    assert users == before
    saved.assert_not_called()


@pytest.mark.asyncio
async def test_reconcile_own_token_claims_for_caller(tmp_path):
    from kg.billing.index import account_token_for_user

    users = _owned_users()
    saved, run = _reconcile_with(users, "Q", account_token_for_user("Q"))
    await run(tmp_path)
    assert users["_subscription_index"]["orig-1"] == "Q"
    assert "subscription" in users["Q"]
    assert users["P"]["subscription"]["is_active"] is True


@pytest.mark.asyncio
async def test_reconcile_owner_without_token_still_writes_to_self(tmp_path):
    users = _owned_users()
    _, run = _reconcile_with(users, "P", None)
    await run(tmp_path)
    assert users["_subscription_index"]["orig-1"] == "P"


# ── App Store error mapping: configuration vs network (#3729) ──────────────────


def _raise(exc: Exception):
    def _fail(*args, **kwargs):
        raise exc

    return _fail


def _sync_req() -> AppStoreSyncRequest:
    return AppStoreSyncRequest(product_id="pro_monthly", transaction_id="txn-1", signed_transaction_info="j")


def _call_sync(tmp_path, decode):
    return sync_app_store_subscription_response(
        _sync_req(),
        {"id": "u1"},
        allow_unsigned_sync=False,
        users_lock_file=tmp_path / "lock",
        load_users=lambda: {},
        save_users=lambda u: None,
        decode_signed_transaction_info=decode,
        write_subscription_snapshot=MagicMock(),
        build_entitlements_response=lambda rec: _active_entitlements(),
    )


def _call_notification(tmp_path, decode):
    return app_store_notifications_response(
        AppStoreNotificationRequest(notification_type="DID_RENEW", signed_payload="signed.payload"),
        users_lock_file=tmp_path / "lock",
        load_users=lambda: {},
        save_users=lambda u: None,
        decode_notification_payload=decode,
        append_app_store_event=MagicMock(),
        resolve_user_id_from_subscription_index=lambda *a: None,
        write_subscription_snapshot=MagicMock(),
        build_entitlements_response=lambda rec: _active_entitlements(),
    )


async def _call_reconcile(tmp_path, *, fetch, decode):
    return await reconcile_app_store_subscription_response(
        AppStoreReconcileRequest(transaction_id="txn-1", environment="production"),
        {"id": "u1"},
        apple_bundle_id="com.example.app",
        users_lock_file=tmp_path / "lock",
        load_users=lambda: {},
        save_users=lambda u: None,
        fetch_transaction_info=fetch,
        decode_signed_transaction_info=decode,
        resolve_user_id_from_subscription_index=lambda *a: None,
        write_subscription_snapshot=MagicMock(),
        build_entitlements_response=lambda rec: _active_entitlements(),
    )


async def _fetch_ok(*args, **kwargs):
    return {"signedTransactionInfo": "j"}


def test_sync_configuration_error_maps_to_500(tmp_path):
    with pytest.raises(HTTPException) as exc_info:
        _call_sync(tmp_path, _raise(AppStoreConfigurationError("missing root CA")))
    assert exc_info.value.status_code == 500
    assert exc_info.value.detail == "App Store configuration error"


def test_notification_configuration_error_maps_to_500(tmp_path):
    with pytest.raises(HTTPException) as exc_info:
        _call_notification(tmp_path, _raise(AppStoreConfigurationError("missing root CA")))
    assert exc_info.value.status_code == 500
    assert exc_info.value.detail == "App Store configuration error"


@pytest.mark.asyncio
async def test_reconcile_configuration_error_maps_to_500(tmp_path):
    with pytest.raises(HTTPException) as exc_info:
        await _call_reconcile(
            tmp_path,
            fetch=_fetch_ok,
            decode=_raise(AppStoreConfigurationError("missing root CA")),
        )
    assert exc_info.value.status_code == 500
    assert exc_info.value.detail == "App Store configuration error"


@pytest.mark.asyncio
async def test_reconcile_network_error_maps_to_502_service_unavailable(tmp_path):
    async def fetch_unreachable(*args, **kwargs):
        raise httpx.ConnectError("connection refused")

    with pytest.raises(HTTPException) as exc_info:
        await _call_reconcile(tmp_path, fetch=fetch_unreachable, decode=MagicMock())
    assert exc_info.value.status_code == 502
    assert exc_info.value.detail == "App Store service unavailable"


def test_sync_verification_error_stays_400(tmp_path):
    with pytest.raises(HTTPException) as exc_info:
        _call_sync(tmp_path, _raise(AppStoreVerificationError("bad signature")))
    assert exc_info.value.status_code == 400
