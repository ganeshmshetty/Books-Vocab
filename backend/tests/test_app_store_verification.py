from __future__ import annotations

import base64
import json
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import jwt as pyjwt
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from fastapi.testclient import TestClient

import kg.api as api_mod
import kg.deps as deps_mod
import kg.routers.billing as billing_router_mod
from conftest import TEST_JWT_SECRET, TEST_PRO_PRODUCT_ID, _swap_settings, make_jwt
from kg.api import app
from kg.settings import KGSettings

APPLE_APP_STORE_OID = "1.2.840.113635.100.6.11.1"
APPLE_INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1"


def _build_certificate(
    subject_cn: str, issuer_cert=None, issuer_key=None, *, app_store_oid=False, intermediate_oid=False
):
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject_cn)])
    issuer = issuer_cert.subject if issuer_cert else subject
    signer_key = issuer_key or key
    now = datetime.now(tz=UTC)
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=30))
        .add_extension(
            x509.BasicConstraints(ca=issuer_cert is None or issuer_key is not None, path_length=None), critical=True
        )
    )
    if app_store_oid:
        # Real App Store signing leaves carry this marker extension; pin it so the
        # fixture chain matches what production verification now requires.
        builder = builder.add_extension(
            x509.UnrecognizedExtension(x509.ObjectIdentifier(APPLE_APP_STORE_OID), b"\x05\x00"),
            critical=False,
        )
    if intermediate_oid:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(x509.ObjectIdentifier(APPLE_INTERMEDIATE_OID), b"\x05\x00"),
            critical=False,
        )
    cert = builder.sign(private_key=signer_key, algorithm=hashes.SHA256())
    return key, cert


def _certificate_chain():
    root_key, root_cert = _build_certificate("Test Apple Root")
    intermediate_key, intermediate_cert = _build_certificate(
        "Test Apple Intermediate",
        issuer_cert=root_cert,
        issuer_key=root_key,
        intermediate_oid=True,
    )
    leaf_key, leaf_cert = _build_certificate(
        "Test Apple Leaf",
        issuer_cert=intermediate_cert,
        issuer_key=intermediate_key,
        app_store_oid=True,
    )
    return {
        "root_key": root_key,
        "root_cert": root_cert,
        "intermediate_key": intermediate_key,
        "intermediate_cert": intermediate_cert,
        "leaf_key": leaf_key,
        "leaf_cert": leaf_cert,
    }


def _sign_jws(payload: dict, leaf_key, chain: list[x509.Certificate]) -> str:
    x5c = [base64.b64encode(cert.public_bytes(serialization.Encoding.DER)).decode("ascii") for cert in chain]
    return pyjwt.encode(payload, leaf_key, algorithm="ES256", headers={"alg": "ES256", "x5c": x5c})


@pytest.fixture()
def signed_app_store_env(tmp_path, monkeypatch):
    data_dir = tmp_path
    (data_dir / "users").mkdir()
    user_id = "u_" + uuid.uuid4().hex[:8]
    users_file = data_dir / "users.json"
    users_file.write_text(json.dumps({user_id: {"config": {}}}))

    chain = _certificate_chain()
    root_pem_path = data_dir / "apple_root.pem"
    root_pem_path.write_text(
        chain["root_cert"].public_bytes(serialization.Encoding.PEM).decode("utf-8"),
        encoding="utf-8",
    )

    monkeypatch.setenv("APP_STORE_ROOT_CA_PATH", str(root_pem_path))
    monkeypatch.delenv("APP_STORE_ROOT_CA_PEM", raising=False)

    token = make_jwt(user_id)
    headers = {"Authorization": f"Bearer {token}"}

    original_settings = app.state.kg_settings
    original_load = app.state.load_users
    original_save = app.state.save_users
    test_settings = KGSettings(
        data_dir=data_dir,
        jwt_secret=TEST_JWT_SECRET,
        app_store_allow_unsigned_sync=False,
        app_store_allow_unsigned_notifications=False,
    )
    _swap_settings(test_settings)

    lifecycle = {"constructed": 0, "entered": 0, "exited": 0}

    class TrackingTestClient(TestClient):
        def __init__(self, *args, **kwargs):
            lifecycle["constructed"] += 1
            super().__init__(*args, **kwargs)

        def __enter__(self):
            lifecycle["entered"] += 1
            return super().__enter__()

        def __exit__(self, *args):
            lifecycle["exited"] += 1
            return super().__exit__(*args)

    try:
        api_mod._USER_LOCKS.clear()
        deps_mod._USER_LOCKS_MUTEX = None
        with TrackingTestClient(app, raise_server_exceptions=False) as client:
            yield SimpleNamespace(
                client=client,
                user_id=user_id,
                headers=headers,
                data_dir=data_dir,
                users_file=users_file,
                chain=chain,
            )
    finally:
        try:
            assert lifecycle == {"constructed": 1, "entered": 1, "exited": 1}
        finally:
            app.state.kg_settings = original_settings
            app.state.load_users = original_load
            app.state.save_users = original_save


def _transaction_payload(
    *,
    transaction_id: str,
    original_transaction_id: str,
    status: str = "active",
    environment: str = "Production",
) -> dict:
    now_ms = int(datetime.now(tz=UTC).timestamp() * 1000)
    expires_at = now_ms + (7 * 24 * 60 * 60 * 1000)
    if status == "expired":
        expires_at = now_ms - 1000
    payload = {
        "bundleId": app.state.kg_settings.apple_bundle_id,
        "productId": TEST_PRO_PRODUCT_ID,
        "transactionId": transaction_id,
        "originalTransactionId": original_transaction_id,
        "environment": environment,
        "expiresDate": expires_at,
    }
    if status == "trial":
        payload["offerType"] = 1
    return payload


def test_signed_sync_verifies_jws_and_persists_subscription(signed_app_store_env):
    env = signed_app_store_env
    signed_transaction = _sign_jws(
        _transaction_payload(transaction_id="tx-signed-1", original_transaction_id="otx-signed-1", status="trial"),
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )

    r = env.client.post(
        "/api/billing/app-store/sync",
        json={
            "product_id": TEST_PRO_PRODUCT_ID,
            "environment": "sandbox",
            "price_display": "$1.00/month",
            "signed_transaction_info": signed_transaction,
        },
        headers=env.headers,
    )
    assert r.status_code == 200, r.text
    body = r.json()["pro"]
    assert body["is_active"] is True
    assert body["status"] == "trial"
    assert body["product_id"] == TEST_PRO_PRODUCT_ID

    saved = json.loads(Path(env.users_file).read_text())
    assert saved[env.user_id]["subscription"]["transaction_id"] == "tx-signed-1"
    assert saved["_subscription_index"]["otx-signed-1"] == env.user_id


def test_signed_notification_verifies_nested_jws_and_updates_subscription(signed_app_store_env):
    env = signed_app_store_env
    sync_signed_transaction = _sign_jws(
        _transaction_payload(transaction_id="tx-signed-2", original_transaction_id="otx-signed-2"),
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )
    sync_response = env.client.post(
        "/api/billing/app-store/sync",
        json={
            "product_id": TEST_PRO_PRODUCT_ID,
            "environment": "sandbox",
            "signed_transaction_info": sync_signed_transaction,
        },
        headers=env.headers,
    )
    assert sync_response.status_code == 200, sync_response.text

    signed_transaction_info = _sign_jws(
        _transaction_payload(transaction_id="tx-signed-3", original_transaction_id="otx-signed-2", status="expired"),
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )
    signed_renewal_info = _sign_jws(
        {
            "bundleId": app.state.kg_settings.apple_bundle_id,
            "productId": TEST_PRO_PRODUCT_ID,
            "originalTransactionId": "otx-signed-2",
            "autoRenewStatus": 0,
        },
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )
    signed_payload = _sign_jws(
        {
            "notificationType": "EXPIRED",
            "subtype": None,
            "bundleId": app.state.kg_settings.apple_bundle_id,
            "data": {
                "bundleId": app.state.kg_settings.apple_bundle_id,
                "signedTransactionInfo": signed_transaction_info,
                "signedRenewalInfo": signed_renewal_info,
            },
        },
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )

    r = env.client.post(
        "/api/billing/app-store/notifications",
        json={"signed_payload": signed_payload},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["updated"] is True
    assert body["user_id"] == env.user_id
    assert body["entitlements"]["pro"]["status"] == "expired"


def test_reconcile_uses_app_store_server_lookup_and_updates_subscription(signed_app_store_env):
    env = signed_app_store_env
    signed_transaction = _sign_jws(
        _transaction_payload(transaction_id="tx-reconcile-1", original_transaction_id="otx-reconcile-1"),
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )

    with patch.object(
        billing_router_mod,
        "fetch_transaction_info",
        new=AsyncMock(return_value={"signedTransactionInfo": signed_transaction}),
    ):
        r = env.client.post(
            "/api/billing/app-store/reconcile",
            json={"transaction_id": "tx-reconcile-1", "environment": "sandbox"},
            headers=env.headers,
        )

    assert r.status_code == 200, r.text
    body = r.json()["pro"]
    assert body["is_active"] is True
    assert body["product_id"] == TEST_PRO_PRODUCT_ID


def test_signed_sync_rejects_bundle_id_mismatch(signed_app_store_env):
    env = signed_app_store_env
    signed_transaction = _sign_jws(
        {
            **_transaction_payload(transaction_id="tx-bad-1", original_transaction_id="otx-bad-1"),
            "bundleId": "com.other.bundle",
        },
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )

    r = env.client.post(
        "/api/billing/app-store/sync",
        json={
            "product_id": TEST_PRO_PRODUCT_ID,
            "environment": "sandbox",
            "signed_transaction_info": signed_transaction,
        },
        headers=env.headers,
    )
    assert r.status_code == 400, r.text
    assert r.json()["detail"] == "Transaction verification failed"


def test_expired_receipt_rejected(signed_app_store_env):
    """A transaction whose expiresDate is in the past must yield an inactive (expired) entitlement."""
    env = signed_app_store_env
    signed_transaction = _sign_jws(
        _transaction_payload(
            transaction_id="tx-expired-1",
            original_transaction_id="otx-expired-1",
            status="expired",
        ),
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )

    r = env.client.post(
        "/api/billing/app-store/sync",
        json={
            "product_id": TEST_PRO_PRODUCT_ID,
            "environment": "sandbox",
            "signed_transaction_info": signed_transaction,
        },
        headers=env.headers,
    )
    assert r.status_code == 200, r.text
    body = r.json()["pro"]
    assert body["is_active"] is False
    assert body["status"] == "expired"


def test_refund_event_invalidates_entitlement(signed_app_store_env):
    """A REFUND notification carrying a revocationDate must expire the user's entitlement."""
    env = signed_app_store_env
    # First establish an active subscription so the transaction is mapped to the user.
    active_signed = _sign_jws(
        _transaction_payload(transaction_id="tx-refund-1", original_transaction_id="otx-refund-1"),
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )
    sync_resp = env.client.post(
        "/api/billing/app-store/sync",
        json={
            "product_id": TEST_PRO_PRODUCT_ID,
            "environment": "sandbox",
            "signed_transaction_info": active_signed,
        },
        headers=env.headers,
    )
    assert sync_resp.status_code == 200, sync_resp.text
    assert sync_resp.json()["pro"]["is_active"] is True

    # REFUND notification: Apple includes a revocationDate on the signed transaction info.
    refunded_payload = _transaction_payload(transaction_id="tx-refund-2", original_transaction_id="otx-refund-1")
    refunded_payload["revocationDate"] = int(datetime.now(tz=UTC).timestamp() * 1000)
    refunded_payload["revocationReason"] = 1
    signed_transaction_info = _sign_jws(
        refunded_payload,
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )
    signed_payload = _sign_jws(
        {
            "notificationType": "REFUND",
            "subtype": None,
            "bundleId": app.state.kg_settings.apple_bundle_id,
            "data": {
                "bundleId": app.state.kg_settings.apple_bundle_id,
                "signedTransactionInfo": signed_transaction_info,
            },
        },
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )

    r = env.client.post(
        "/api/billing/app-store/notifications",
        json={"signed_payload": signed_payload},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["updated"] is True
    assert body["user_id"] == env.user_id
    assert body["entitlements"]["pro"]["status"] == "expired"
    assert body["entitlements"]["pro"]["is_active"] is False


def test_sandbox_environment_routes_reconcile_to_sandbox_endpoint(signed_app_store_env):
    """Reconcile with environment='sandbox' must hit the sandbox StoreKit base URL.

    The StoreKit Server API selects sandbox vs production by base URL rather than the
    legacy verifyReceipt 21007 status code, so a sandbox transaction must never be
    looked up against the production host.
    """
    from kg.app_store import (
        PRODUCTION_API_BASE_URL,
        SANDBOX_API_BASE_URL,
        _base_url_for_environment,
    )

    assert _base_url_for_environment("sandbox") == SANDBOX_API_BASE_URL
    assert _base_url_for_environment("Sandbox") == SANDBOX_API_BASE_URL
    assert _base_url_for_environment("production") == PRODUCTION_API_BASE_URL
    assert _base_url_for_environment(None) == PRODUCTION_API_BASE_URL

    env = signed_app_store_env
    signed_transaction = _sign_jws(
        _transaction_payload(
            transaction_id="tx-sandbox-1",
            original_transaction_id="otx-sandbox-1",
            environment="Sandbox",
        ),
        env.chain["leaf_key"],
        [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]],
    )

    captured: dict[str, str] = {}

    async def _fake_fetch(transaction_id, *, bundle_id, environment=None):
        captured["transaction_id"] = transaction_id
        captured["environment"] = environment or ""
        captured["base_url"] = _base_url_for_environment(environment)
        return {"signedTransactionInfo": signed_transaction}

    with patch.object(billing_router_mod, "fetch_transaction_info", new=_fake_fetch):
        r = env.client.post(
            "/api/billing/app-store/reconcile",
            json={"transaction_id": "tx-sandbox-1", "environment": "sandbox"},
            headers=env.headers,
        )

    assert r.status_code == 200, r.text
    assert captured["environment"] == "sandbox"
    assert captured["base_url"] == SANDBOX_API_BASE_URL
    # Security gate: a verified sandbox transaction (environment="Sandbox" in the
    # signed JWS payload) must NOT yield a real Pro entitlement on a production
    # deployment. The snapshot is still persisted for diagnostics.
    assert r.json()["pro"]["is_active"] is False


def test_signed_notification_after_self_service_delete_does_not_resurrect_user(signed_app_store_env):
    """#2255: an Apple notification arriving after self-service account deletion
    must not re-create the erased users.json record through a stale index entry."""
    env = signed_app_store_env
    chain = [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]]
    bundle_id = app.state.kg_settings.apple_bundle_id

    sync_response = env.client.post(
        "/api/billing/app-store/sync",
        json={
            "product_id": TEST_PRO_PRODUCT_ID,
            "environment": "sandbox",
            "signed_transaction_info": _sign_jws(
                _transaction_payload(transaction_id="tx-del-1", original_transaction_id="otx-del-1"),
                env.chain["leaf_key"],
                chain,
            ),
        },
        headers=env.headers,
    )
    assert sync_response.status_code == 200, sync_response.text
    assert json.loads(env.users_file.read_text())["_subscription_index"]["otx-del-1"] == env.user_id

    deleted = env.client.delete("/api/user/account", headers=env.headers)
    assert deleted.status_code == 200, deleted.text
    after_delete = json.loads(env.users_file.read_text())
    assert env.user_id not in after_delete.get("_subscription_index", {}).values()

    signed_payload = _sign_jws(
        {
            "notificationType": "DID_RENEW",
            "subtype": None,
            "bundleId": bundle_id,
            "data": {
                "bundleId": bundle_id,
                "signedTransactionInfo": _sign_jws(
                    _transaction_payload(transaction_id="tx-del-2", original_transaction_id="otx-del-1"),
                    env.chain["leaf_key"],
                    chain,
                ),
                "signedRenewalInfo": _sign_jws(
                    {
                        "bundleId": bundle_id,
                        "productId": TEST_PRO_PRODUCT_ID,
                        "originalTransactionId": "otx-del-1",
                        "autoRenewStatus": 1,
                    },
                    env.chain["leaf_key"],
                    chain,
                ),
            },
        },
        env.chain["leaf_key"],
        chain,
    )
    r = env.client.post("/api/billing/app-store/notifications", json={"signed_payload": signed_payload})

    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "accepted"
    assert body["updated"] is False
    assert body["reason"] == "unmapped_transaction"
    assert body["user_id"] is None
    assert env.user_id not in json.loads(env.users_file.read_text())
