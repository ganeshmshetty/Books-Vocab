"""HTTP-level pin for the App Store unsigned-ingest gates (#3726).

``routers/billing.py`` forwards ``app_store_allow_unsigned_sync`` and
``app_store_allow_unsigned_notifications`` from settings into the handlers.
With both flags False, unsigned bodies must be rejected at the HTTP boundary
and leave the subscription untouched. With both True, the same bodies are
accepted. Handler-level tests cannot catch a mis-wired router flag, so these
go through the real FastAPI app.
"""

from __future__ import annotations

import json
import uuid
from contextlib import contextmanager
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

import kg.api as api_mod
import kg.deps as deps_mod
from conftest import TEST_JWT_SECRET, TEST_PRO_PRODUCT_ID, _swap_settings, make_jwt
from kg.api import app
from kg.settings import KGSettings

_UNSIGNED_SYNC_BODY = {
    "product_id": TEST_PRO_PRODUCT_ID,
    "status": "active",
    "environment": "Production",
    "transaction_id": "txn-1",
    "original_transaction_id": "orig-1",
    "expires_at": "2099-01-01T00:00:00+00:00",
}

_UNSIGNED_NOTIFICATION_BODY = {
    "notification_type": "DID_RENEW",
    "product_id": TEST_PRO_PRODUCT_ID,
    "status": "active",
    "environment": "Production",
    "transaction_id": "txn-1",
    "original_transaction_id": "orig-1",
    "expires_at": "2099-01-01T00:00:00+00:00",
}


# A live entitlement seeded before the rejected request. A rejected unsigned
# write that still mutates the record (e.g. flipping it to inactive) must show
# up here, which an already-inactive seed cannot reveal.
_PRIOR_ACTIVE_SUBSCRIPTION = {
    "product_id": TEST_PRO_PRODUCT_ID,
    "transaction_id": "txn-prior",
    "original_transaction_id": "orig-1",
    "environment": "Production",
    "status": "active",
    "is_trial": False,
    "expires_at": "2099-01-01T00:00:00+00:00",
    "is_active": True,
    "will_renew": True,
}


@contextmanager
def _billing_api(tmp_path, *, allow_unsigned: bool, prior_subscription: dict | None = None):
    data_dir = tmp_path
    (data_dir / "users").mkdir()
    user_id = "u_" + uuid.uuid4().hex[:8]
    users_file = data_dir / "users.json"
    user_record = {"config": {}}
    if prior_subscription is not None:
        user_record["subscription"] = dict(prior_subscription)
    # The subscription index maps the body's transaction ids to this user, so
    # a gate that wrongly opens would visibly flip this user's entitlement.
    users_file.write_text(
        json.dumps(
            {
                user_id: user_record,
                "_subscription_index": {"orig-1": user_id, "txn-1": user_id},
            }
        )
    )
    token = make_jwt(user_id)
    headers = {"Authorization": f"Bearer {token}"}

    original_settings = app.state.kg_settings
    original_load = app.state.load_users
    original_save = app.state.save_users
    _swap_settings(
        KGSettings(
            data_dir=data_dir,
            jwt_secret=TEST_JWT_SECRET,
            app_store_allow_unsigned_sync=allow_unsigned,
            app_store_allow_unsigned_notifications=allow_unsigned,
        )
    )

    client = None
    try:
        api_mod._USER_LOCKS.clear()
        deps_mod._USER_LOCKS_MUTEX = None
        client = TestClient(app, raise_server_exceptions=False)
        yield SimpleNamespace(client=client, user_id=user_id, headers=headers, users_file=users_file)
    finally:
        if client is not None:
            client.close()
        app.state.kg_settings = original_settings
        app.state.load_users = original_load
        app.state.save_users = original_save


def _subscription_is_active(env) -> bool:
    users = json.loads(env.users_file.read_text())
    return bool(users[env.user_id].get("subscription", {}).get("is_active"))


def _stored_subscription(env) -> dict:
    users = json.loads(env.users_file.read_text())
    return users[env.user_id].get("subscription", {})


def test_unsigned_sync_rejected_when_gate_closed(tmp_path):
    with _billing_api(tmp_path, allow_unsigned=False, prior_subscription=_PRIOR_ACTIVE_SUBSCRIPTION) as env:
        r = env.client.post("/api/billing/app-store/sync", json=_UNSIGNED_SYNC_BODY, headers=env.headers)

        assert r.status_code == 400
        assert r.json()["detail"] == "signed_transaction_info is required for production App Store sync"
        assert _subscription_is_active(env) is True
        assert _stored_subscription(env) == _PRIOR_ACTIVE_SUBSCRIPTION


def test_unsigned_notification_rejected_when_gate_closed(tmp_path):
    with _billing_api(tmp_path, allow_unsigned=False, prior_subscription=_PRIOR_ACTIVE_SUBSCRIPTION) as env:
        r = env.client.post("/api/billing/app-store/notifications", json=_UNSIGNED_NOTIFICATION_BODY)

        assert r.status_code == 400
        # Distinct from the signed_payload vs signedPayload field bug (#3653):
        # pin the exact gate error so a different 400 cannot satisfy this test.
        assert r.json()["detail"] == "signed_payload is required for App Store notifications"
        assert _subscription_is_active(env) is True
        assert _stored_subscription(env) == _PRIOR_ACTIVE_SUBSCRIPTION


@pytest.mark.parametrize("endpoint", ["sync", "notifications"])
def test_unsigned_body_accepted_when_gates_open(tmp_path, endpoint):
    with _billing_api(tmp_path, allow_unsigned=True) as env:
        if endpoint == "sync":
            r = env.client.post("/api/billing/app-store/sync", json=_UNSIGNED_SYNC_BODY, headers=env.headers)
            assert r.status_code == 200
            assert r.json()["pro"]["is_active"] is True
        else:
            r = env.client.post("/api/billing/app-store/notifications", json=_UNSIGNED_NOTIFICATION_BODY)
            assert r.status_code == 200
            assert r.json()["updated"] is True
        assert _subscription_is_active(env) is True
