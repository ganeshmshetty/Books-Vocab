from __future__ import annotations

import inspect
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi import HTTPException

from kg.api_models import (
    AppStoreSyncRequest,
    EntitlementsResponse,
    SubscriptionStatusResponse,
)
from kg.billing_handlers import sync_app_store_subscription_response

# ── helpers ────────────────────────────────────────────────────────────────────


def _free_entitlements():
    return EntitlementsResponse(pro=SubscriptionStatusResponse(is_active=False, status="inactive"))


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


def _common_deps(tmp_path: Path, entitlements=None):
    users_lock = tmp_path / "users.json.lock"
    users_store = {}

    def load_users():
        return users_store

    def save_users(u):
        users_store.update(u)

    def write_sub(users, uid, **kwargs):
        record = {"subscription": {"status": kwargs["status"], "is_active": True}}
        users[uid] = record
        return record

    return {
        "users_lock_file": users_lock,
        "load_users": load_users,
        "save_users": save_users,
        "write_subscription_snapshot": write_sub,
        "build_entitlements_response": lambda rec: entitlements or _active_entitlements(),
    }


# ── sync handler ───────────────────────────────────────────────────────────────


def test_sync_signed_transaction_verifies_and_writes(tmp_path):
    snapshot = _make_snapshot()
    decode_fn = MagicMock(return_value=snapshot)
    deps = _common_deps(tmp_path)
    deps["decode_signed_transaction_info"] = decode_fn

    req = AppStoreSyncRequest(
        product_id="pro_monthly",
        transaction_id="txn-1",
        original_transaction_id="orig-1",
        signed_transaction_info="signed.jws.token",
    )
    user = {"id": "u1"}

    result = sync_app_store_subscription_response(
        req,
        user,
        allow_unsigned_sync=False,
        **deps,
    )
    decode_fn.assert_called_once_with("signed.jws.token")
    assert isinstance(result, EntitlementsResponse)


def test_sync_transaction_id_mismatch_raises_400(tmp_path):
    snapshot = _make_snapshot(transaction_id="txn-OTHER")
    decode_fn = MagicMock(return_value=snapshot)
    deps = _common_deps(tmp_path)
    deps["decode_signed_transaction_info"] = decode_fn

    req = AppStoreSyncRequest(
        product_id="pro_monthly",
        transaction_id="txn-1",
        signed_transaction_info="signed.jws.token",
    )

    with pytest.raises(HTTPException) as exc_info:
        sync_app_store_subscription_response(req, {"id": "u1"}, allow_unsigned_sync=False, **deps)
    assert exc_info.value.status_code == 400


def test_sync_xcode_env_rejects_unsigned_when_not_debug(tmp_path):
    """Xcode environment bypass must NOT work when allow_unsigned_sync=False (production)."""
    deps = _common_deps(tmp_path)
    deps["decode_signed_transaction_info"] = MagicMock()

    req = AppStoreSyncRequest(
        product_id="pro_monthly",
        transaction_id="txn-xcode",
        environment="xcode",
        status="active",
        is_trial=False,
        will_renew=True,
    )

    with pytest.raises(HTTPException) as exc_info:
        sync_app_store_subscription_response(
            req,
            {"id": "u1"},
            allow_unsigned_sync=False,
            **deps,
        )
    assert exc_info.value.status_code == 400


def test_sync_xcode_env_allows_unsigned_when_enabled(tmp_path):
    """Xcode environment bypass works when allow_unsigned_sync=True (dev/test)."""
    deps = _common_deps(tmp_path)
    deps["decode_signed_transaction_info"] = MagicMock()

    req = AppStoreSyncRequest(
        product_id="pro_monthly",
        transaction_id="txn-xcode",
        environment="xcode",
        status="active",
        is_trial=False,
        will_renew=True,
    )

    result = sync_app_store_subscription_response(
        req,
        {"id": "u1"},
        allow_unsigned_sync=True,
        **deps,
    )
    deps["decode_signed_transaction_info"].assert_not_called()
    assert isinstance(result, EntitlementsResponse)


def test_sync_forged_cert_chain_maps_to_400_not_500(tmp_path, monkeypatch):
    """End-to-end boundary: a JWS whose cert chain has a forged inner link (real
    trusted root at the tail, but the leaf signed by an attacker key) must surface
    as HTTP 400 through ``_map_app_store_errors``, NOT as an unmapped 500.

    cryptography raises ``InvalidSignature`` on the chain signature check; if that
    escapes ``AppStoreVerificationError`` it would never be caught by the handler's
    error mapper and FastAPI would return 500. This proves the real verifier
    collapses it to the domain error so the contract is 400.
    """
    import base64
    from datetime import UTC, datetime, timedelta

    import jwt as pyjwt
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID, ObjectIdentifier

    from kg.app_store import verify_and_decode_signed_jws

    apple_oid = ObjectIdentifier("1.2.840.113635.100.6.11.1")
    now = datetime.now(tz=UTC)

    def _cert(cn, pub_key, issuer_name, signing_key, *, ca, exts=()):
        builder = (
            x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)]))
            .issuer_name(issuer_name)
            .public_key(pub_key)
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(days=1))
            .not_valid_after(now + timedelta(days=30))
            .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
        )
        for ext in exts:
            builder = builder.add_extension(ext, critical=False)
        return builder.sign(private_key=signing_key, algorithm=hashes.SHA256())

    root_key = ec.generate_private_key(ec.SECP256R1())
    root_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Apple Root")])
    root_cert = _cert("Test Apple Root", root_key.public_key(), root_name, root_key, ca=True)

    inter_key = ec.generate_private_key(ec.SECP256R1())
    inter_cert = _cert(
        "Test Apple Intermediate",
        inter_key.public_key(),
        root_cert.subject,
        root_key,
        ca=True,
        exts=[x509.UnrecognizedExtension(ObjectIdentifier("1.2.840.113635.100.6.2.1"), b"\x05\x00")],
    )

    # Forge the leaf: signed by an attacker key, not the genuine intermediate.
    attacker_key = ec.generate_private_key(ec.SECP256R1())
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    leaf_cert = _cert(
        "Test Apple Leaf",
        leaf_key.public_key(),
        inter_cert.subject,
        attacker_key,
        ca=False,
        exts=[x509.UnrecognizedExtension(apple_oid, b"\x05\x00")],
    )

    root_pem = tmp_path / "root.pem"
    root_pem.write_text(root_cert.public_bytes(serialization.Encoding.PEM).decode("utf-8"))
    monkeypatch.setenv("APP_STORE_ROOT_CA_PATH", str(root_pem))
    monkeypatch.delenv("APP_STORE_ROOT_CA_PEM", raising=False)

    x5c = [
        base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode("ascii")
        for c in (leaf_cert, inter_cert, root_cert)
    ]
    payload = {
        "bundleId": "com.Max0228.BooksBrowser",
        "transactionId": "txn-1",
        "exp": int(now.timestamp()) + 3600,
    }
    token = pyjwt.encode(payload, leaf_key, algorithm="ES256", headers={"alg": "ES256", "x5c": x5c})

    def decode_fn(signed: str):
        verify_and_decode_signed_jws(signed, bundle_id="com.Max0228.BooksBrowser")
        return _make_snapshot()  # unreachable — verification must raise first

    deps = _common_deps(tmp_path)
    deps["decode_signed_transaction_info"] = decode_fn

    req = AppStoreSyncRequest(
        product_id="pro_monthly",
        transaction_id="txn-1",
        signed_transaction_info=token,
    )

    with pytest.raises(HTTPException) as exc_info:
        sync_app_store_subscription_response(req, {"id": "u1"}, allow_unsigned_sync=False, **deps)
    assert exc_info.value.status_code == 400


# ── #2253: appAccountToken / index ownership binding ───────────────────────────

import copy  # noqa: E402

from kg.billing import write_subscription_snapshot as _real_write  # noqa: E402
from kg.billing.index import account_token_for_user  # noqa: E402
from kg.billing.notifications import verified_transaction_snapshot  # noqa: E402


def _owned_state():
    return {
        "P": {"subscription": {"is_active": True, "status": "active", "original_transaction_id": "orig-1"}},
        "Q": {"config": {}},
        "_subscription_index": {"orig-1": "P", "txn-1": "P"},
    }


def _sync(tmp_path, users, caller, token):
    snapshot = _make_snapshot()
    if token is not None:
        snapshot["app_account_token"] = token
    saved = MagicMock()
    req = AppStoreSyncRequest(
        product_id="pro_monthly",
        transaction_id="txn-1",
        original_transaction_id="orig-1",
        signed_transaction_info="signed.jws",
    )
    return saved, lambda: sync_app_store_subscription_response(
        req,
        {"id": caller},
        allow_unsigned_sync=False,
        users_lock_file=tmp_path / "lock",
        load_users=lambda: users,
        save_users=saved,
        decode_signed_transaction_info=lambda _s: snapshot,
        write_subscription_snapshot=_real_write,
        build_entitlements_response=lambda rec: _active_entitlements(),
    )


def test_verified_snapshot_carries_app_account_token_but_not_into_stored_fields():
    snap = verified_transaction_snapshot(
        {"productId": "pro_monthly", "transactionId": "t", "originalTransactionId": "o", "appAccountToken": "abc"},
        parse_datetime_fn=lambda v: v,
    )
    assert snap["app_account_token"] == "abc"
    snap = verified_transaction_snapshot({"productId": "pro_monthly"}, parse_datetime_fn=lambda v: v)
    assert snap["app_account_token"] is None


def test_sync_rejects_jws_whose_token_belongs_to_another_user(tmp_path):
    users = _owned_state()
    before = copy.deepcopy(users)
    saved, run = _sync(tmp_path, users, "Q", account_token_for_user("P"))
    with pytest.raises(HTTPException) as exc:
        run()
    assert exc.value.status_code in (403, 409)
    assert users == before
    saved.assert_not_called()


def test_sync_rejects_tokenless_jws_for_index_owned_by_other_user(tmp_path):
    users = _owned_state()
    before = copy.deepcopy(users)
    saved, run = _sync(tmp_path, users, "Q", None)
    with pytest.raises(HTTPException) as exc:
        run()
    assert exc.value.status_code == 409
    assert users["_subscription_index"]["orig-1"] == "P"
    assert users == before
    saved.assert_not_called()


def test_sync_rejects_unparsable_token_as_mismatch(tmp_path):
    users = _owned_state()
    _, run = _sync(tmp_path, users, "Q", "not-a-uuid")
    with pytest.raises(HTTPException):
        run()
    assert users["_subscription_index"]["orig-1"] == "P"


def test_sync_own_token_accepted_case_insensitively_and_claims(tmp_path):
    users = _owned_state()
    _, run = _sync(tmp_path, users, "Q", account_token_for_user("Q").upper())
    run()
    assert users["_subscription_index"]["orig-1"] == "Q"
    assert "subscription" in users["Q"]


def test_sync_first_purchase_without_owner_unchanged(tmp_path):
    users = {"Q": {"config": {}}}
    _, run = _sync(tmp_path, users, "Q", None)
    run()
    assert users["_subscription_index"]["orig-1"] == "Q"


def test_sync_owner_resyncing_own_tokenless_jws_unchanged(tmp_path):
    users = _owned_state()
    _, run = _sync(tmp_path, users, "P", None)
    run()
    assert users["_subscription_index"]["orig-1"] == "P"


# ── #3656: a verified expired-looking /sync must not erase an active grace period ──

from datetime import UTC as _UTC  # noqa: E402
from datetime import datetime as _datetime  # noqa: E402
from datetime import timedelta as _timedelta  # noqa: E402


def _grace_state(grace_delta, original="X"):
    now = _datetime.now(tz=_UTC)
    return {
        "P": {
            "id": "P",
            "subscription": {
                "is_active": True,
                "status": "grace_period",
                "product_id": "pro_monthly",
                "transaction_id": "X-old",
                "original_transaction_id": original,
                "expires_at": (now - _timedelta(days=1)).isoformat(),
                "grace_period_expires_at": (now + grace_delta).isoformat(),
                "last_signed_date": (now - _timedelta(days=1)).isoformat(),
                "last_notification_uuid": "uuid-0",
            },
        },
        "_subscription_index": {"X": "P", "X-old": "P"},
    }


def _grace_sync(tmp_path, users, *, revoked=False, writer=_real_write):
    now = _datetime.now(tz=_UTC)
    snapshot = _make_snapshot(transaction_id="X-new", original_transaction_id="X")
    snapshot["status"] = "expired"
    snapshot["expires_at"] = (now - _timedelta(days=1)).isoformat()
    snapshot["signed_date"] = (now - _timedelta(hours=1)).isoformat()
    snapshot["revoked"] = revoked
    saved = MagicMock()
    req = AppStoreSyncRequest(
        product_id="pro_monthly",
        transaction_id="X-new",
        original_transaction_id="X",
        signed_transaction_info="signed.jws",
    )
    sync_app_store_subscription_response(
        req,
        {"id": "P"},
        allow_unsigned_sync=False,
        users_lock_file=tmp_path / "lock",
        load_users=lambda: users,
        save_users=saved,
        decode_signed_transaction_info=lambda _s: snapshot,
        write_subscription_snapshot=writer,
        build_entitlements_response=lambda rec: _active_entitlements(),
    )
    return users["P"]["subscription"]


def test_sync_expired_without_revocation_keeps_active_grace(tmp_path):
    users = _grace_state(_timedelta(days=5))
    before_deadline = users["P"]["subscription"]["grace_period_expires_at"]
    sub = _grace_sync(tmp_path, users)
    assert sub["status"] == "grace_period"
    assert sub["is_active"] is True
    assert sub["grace_period_expires_at"] == before_deadline


def test_sync_revoked_transaction_expires_even_during_grace(tmp_path):
    users = _grace_state(_timedelta(days=5))
    sub = _grace_sync(tmp_path, users, revoked=True)
    assert sub["status"] == "expired"
    assert sub["is_active"] is False


def test_sync_expired_after_grace_deadline_writes_expired(tmp_path):
    users = _grace_state(-_timedelta(hours=1))
    sub = _grace_sync(tmp_path, users)
    assert sub["status"] == "expired"
    assert sub["is_active"] is False


def test_sync_expired_for_other_original_transaction_writes_expired(tmp_path):
    users = _grace_state(_timedelta(days=5), original="OTHER")
    sub = _grace_sync(tmp_path, users)
    assert sub["status"] == "expired"
    assert sub["is_active"] is False


# ── #3966 review (P0): the writer production injects must accept every kwarg the handlers pass ──


def test_deps_snapshot_writer_accepts_every_billing_writer_kwarg():
    """kg.deps._write_subscription_snapshot is what routers/billing.py injects; a kwarg missing
    from its signature (revoked) raised TypeError on every /sync, /notifications, /reconcile write."""
    from kg.billing import write_subscription_snapshot as billing_writer
    from kg.deps import _write_subscription_snapshot as deps_writer

    missing = set(inspect.signature(billing_writer).parameters) - set(inspect.signature(deps_writer).parameters)
    assert missing == set()


def test_sync_through_deps_writer_persists_revocation(tmp_path):
    from kg.deps import _write_subscription_snapshot as deps_writer

    users = _grace_state(_timedelta(days=5))
    sub = _grace_sync(tmp_path, users, revoked=True, writer=deps_writer)
    assert sub["status"] == "expired"
    assert sub["is_active"] is False


def test_sync_through_deps_writer_keeps_active_grace_without_revocation(tmp_path):
    from kg.deps import _write_subscription_snapshot as deps_writer

    users = _grace_state(_timedelta(days=5))
    before_deadline = users["P"]["subscription"]["grace_period_expires_at"]
    sub = _grace_sync(tmp_path, users, writer=deps_writer)
    assert sub["status"] == "grace_period"
    assert sub["grace_period_expires_at"] == before_deadline
