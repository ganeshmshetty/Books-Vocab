from __future__ import annotations

import pytest

from conftest import TEST_PRO_PRODUCT_ID
from kg.api import app
from kg.api_models.billing import AppStoreNotificationRequest
from test_app_store_verification import (  # noqa: F401 — fixture + helper reuse
    _sign_jws,
    _transaction_payload,
    signed_app_store_env,
)


def test_apple_camel_case_signed_payload_key_is_read_into_model():
    req = AppStoreNotificationRequest.model_validate({"signedPayload": "a.b.c"})

    assert req.signed_payload == "a.b.c"


def test_snake_case_signed_payload_still_accepted_for_internal_callers():
    assert AppStoreNotificationRequest.model_validate({"signed_payload": "a.b.c"}).signed_payload == "a.b.c"
    assert AppStoreNotificationRequest(signed_payload="a.b.c").signed_payload == "a.b.c"


@pytest.mark.parametrize("payload_key", ["signedPayload", "signed_payload"])
def test_notification_endpoint_accepts_both_payload_keys_and_applies_entitlement(
    signed_app_store_env,  # noqa: F811
    payload_key,
):
    env = signed_app_store_env
    chain = [env.chain["leaf_cert"], env.chain["intermediate_cert"], env.chain["root_cert"]]
    bundle_id = app.state.kg_settings.apple_bundle_id

    sync_response = env.client.post(
        "/api/billing/app-store/sync",
        json={
            "product_id": TEST_PRO_PRODUCT_ID,
            "environment": "sandbox",
            "signed_transaction_info": _sign_jws(
                _transaction_payload(transaction_id="tx-key-1", original_transaction_id="otx-key-1"),
                env.chain["leaf_key"],
                chain,
            ),
        },
        headers=env.headers,
    )
    assert sync_response.status_code == 200, sync_response.text
    assert sync_response.json()["pro"]["is_active"] is True

    signed_payload = _sign_jws(
        {
            "notificationType": "EXPIRED",
            "subtype": None,
            "bundleId": bundle_id,
            "data": {
                "bundleId": bundle_id,
                "signedTransactionInfo": _sign_jws(
                    _transaction_payload(
                        transaction_id="tx-key-2",
                        original_transaction_id="otx-key-1",
                        status="expired",
                    ),
                    env.chain["leaf_key"],
                    chain,
                ),
            },
        },
        env.chain["leaf_key"],
        chain,
    )

    r = env.client.post("/api/billing/app-store/notifications", json={payload_key: signed_payload})

    assert r.status_code == 200, r.text
    body = r.json()
    assert body["updated"] is True
    assert body["user_id"] == env.user_id
    assert body["entitlements"]["pro"]["status"] == "expired"
