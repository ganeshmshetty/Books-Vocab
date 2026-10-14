"""Unit tests for admin grant/revoke entitlement mutations.

Covers the security-critical surface in ``kg.admin.entitlements``:
server-derived actor (anti-spoofing), audit row emission, NotFoundError
guards, and ``admin_user_entitlement_response`` lookup. The handlers are
pure / dependency-injected, so we feed in-memory load/save callables plus a
``tmp_path`` lock file and patch ``record_audit`` to capture calls.
"""

from __future__ import annotations

from typing import Any
from unittest.mock import patch

import pytest

from kg.admin.entitlements import (
    admin_grant_pro_access_response,
    admin_revoke_pro_access_response,
    admin_user_entitlement_response,
)
from kg.api_models.billing import (
    AdminGrantRequest,
    EntitlementsResponse,
    SubscriptionStatusResponse,
)
from kg.exceptions import ConflictError, NotFoundError


def _build_entitlements_response(record: dict[str, Any] | None) -> EntitlementsResponse:
    grant = (record or {}).get("admin_grant", {}) if isinstance(record, dict) else {}
    return EntitlementsResponse(
        pro=SubscriptionStatusResponse(
            is_active=bool(grant.get("is_active", False)),
            status=grant.get("status", "inactive"),
            source="admin",
        )
    )


def _current_admin_grant_record(record: dict[str, Any] | None) -> dict[str, Any]:
    if isinstance(record, dict) and isinstance(record.get("admin_grant"), dict):
        return dict(record["admin_grant"])
    return {"is_active": False, "status": "inactive"}


@pytest.fixture
def store():
    """In-memory users store + injectable load/save callables."""
    users: dict[str, dict[str, Any]] = {
        "u1": {"email": "a@b.c"},
        "_schema": {"version": 1},  # reserved metadata bucket, not a user
    }

    def load_users() -> dict[str, dict[str, Any]]:
        return users

    def save_users(payload: dict[str, dict[str, Any]]) -> None:
        # payload may be the same object load_users returned (the handler
        # mutates in place); merge defensively without clearing first.
        users.update(payload)

    return users, load_users, save_users


def _di(store, lock_file):
    _, load_users, save_users = store
    return {
        "users_lock_file": lock_file,
        "load_users": load_users,
        "save_users": save_users,
        "current_admin_grant_record": _current_admin_grant_record,
        "build_entitlements_response": _build_entitlements_response,
    }


def test_grant_forces_server_actor_and_active_state(store, tmp_path):
    users = store[0]
    # Client tries to spoof a different actor via the request body.
    req = AdminGrantRequest(reason="  vip  ", expires_at="2030-01-01", granted_by="attacker")
    with patch("kg.admin_audit.record_audit") as rec:
        resp = admin_grant_pro_access_response("u1", req, admin_uid="real-admin", **_di(store, tmp_path / "users.lock"))

    grant = users["u1"]["admin_grant"]
    assert grant["is_active"] is True
    assert grant["status"] == "active"
    assert grant["source"] == "admin"
    assert grant["plan_name"] == "Books & Vocab Pro"
    # Spoofed granted_by is ignored; server fingerprint wins.
    assert grant["granted_by"] == "real-admin"
    assert grant["reason"] == "vip"  # trimmed
    assert resp.admin_grant.is_active is True

    rec.assert_called_once()
    kw = rec.call_args.kwargs
    assert kw["action"] == "grant_pro"
    assert kw["target_uid"] == "u1"
    # Audit actor matches the resolved server actor, not the spoofed value.
    assert kw["admin_uid"] == "real-admin"


def test_grant_defaults_actor_to_admin_when_uid_missing(store, tmp_path):
    users = store[0]
    with patch("kg.admin_audit.record_audit"):
        admin_grant_pro_access_response(
            "u1", AdminGrantRequest(), admin_uid=None, **_di(store, tmp_path / "users.lock")
        )
    assert users["u1"]["admin_grant"]["granted_by"] == "admin"


def test_revoke_sets_inactive_and_audits(store, tmp_path):
    users = store[0]
    users["u1"]["admin_grant"] = {"is_active": True, "status": "active"}
    with patch("kg.admin_audit.record_audit") as rec:
        resp = admin_revoke_pro_access_response("u1", admin_uid="real-admin", **_di(store, tmp_path / "users.lock"))
    grant = users["u1"]["admin_grant"]
    assert grant["is_active"] is False
    assert grant["status"] == "inactive"
    assert resp.admin_grant.is_active is False

    rec.assert_called_once()
    kw = rec.call_args.kwargs
    assert kw["action"] == "revoke_pro"
    assert kw["target_uid"] == "u1"


def test_revoke_passes_raw_admin_uid_to_audit_asymmetry(store, tmp_path):
    """Pin the grant/revoke asymmetry: revoke forwards the *raw* admin_uid
    (here ``None``) to record_audit, whereas grant forwards the resolved
    actor. record_audit itself normalises None -> "admin", but the handler
    does not pre-resolve it on the revoke path."""
    with patch("kg.admin_audit.record_audit") as rec:
        admin_revoke_pro_access_response("u1", admin_uid=None, **_di(store, tmp_path / "users.lock"))
    assert rec.call_args.kwargs["admin_uid"] is None


@pytest.mark.parametrize("bad_id", ["ghost", "_schema"])
def test_grant_revoke_raise_not_found(store, tmp_path, bad_id):
    di = _di(store, tmp_path / "users.lock")
    with patch("kg.admin_audit.record_audit") as rec:
        with pytest.raises(NotFoundError):
            admin_grant_pro_access_response(bad_id, AdminGrantRequest(), **di)
        with pytest.raises(NotFoundError):
            admin_revoke_pro_access_response(bad_id, **di)
    # Mutation guard fires before audit on the unknown/reserved path.
    rec.assert_not_called()


def test_user_entitlement_response_for_real_user(store):
    store[0]["u1"]["admin_grant"] = {"is_active": True, "status": "active"}
    resp = admin_user_entitlement_response(
        "u1",
        load_users=store[1],
        build_entitlements_response=_build_entitlements_response,
        current_admin_grant_record=_current_admin_grant_record,
    )
    assert resp.user_id == "u1"
    assert resp.pro.is_active is True
    assert resp.admin_grant.is_active is True


@pytest.fixture
def store_with_pointer(store):
    """Canonical account ``a1`` plus a link pointer ``p1`` -> ``a1`` (login resolves p1 to a1)."""
    users = store[0]
    users["a1"] = {"email": "a1@b.c"}
    users["p1"] = {"_linked_to": "a1"}
    return store


@pytest.mark.parametrize("handler", ["grant", "revoke"])
def test_mutation_on_link_pointer_is_rejected_and_writes_nothing(store_with_pointer, tmp_path, handler):
    users = store_with_pointer[0]
    with patch("kg.admin_audit.record_audit") as rec:
        with pytest.raises(ConflictError):
            if handler == "grant":
                admin_grant_pro_access_response(
                    "p1",
                    AdminGrantRequest(),
                    admin_uid="real-admin",
                    **_di(store_with_pointer, tmp_path / "users.lock"),
                )
            else:
                admin_revoke_pro_access_response(
                    "p1", admin_uid="real-admin", **_di(store_with_pointer, tmp_path / "users.lock")
                )
    assert "admin_grant" not in users["p1"]
    assert "admin_grant" not in users["a1"]
    rec.assert_not_called()


def test_grant_on_canonical_account_is_effective_through_pointer_login(store_with_pointer, tmp_path):
    users = store_with_pointer[0]
    with patch("kg.admin_audit.record_audit"):
        admin_grant_pro_access_response(
            "a1", AdminGrantRequest(), admin_uid="real-admin", **_di(store_with_pointer, tmp_path / "users.lock")
        )
    assert users["a1"]["admin_grant"]["is_active"] is True
    resp = admin_user_entitlement_response(
        "a1",
        load_users=store_with_pointer[1],
        build_entitlements_response=_build_entitlements_response,
        current_admin_grant_record=_current_admin_grant_record,
    )
    assert resp.pro.is_active is True


def test_user_entitlement_response_rejects_link_pointer(store_with_pointer):
    with pytest.raises(NotFoundError):
        admin_user_entitlement_response(
            "p1",
            load_users=store_with_pointer[1],
            build_entitlements_response=_build_entitlements_response,
            current_admin_grant_record=_current_admin_grant_record,
        )


@pytest.mark.parametrize("bad_id", ["ghost", "_schema"])
def test_user_entitlement_response_not_found(store, bad_id):
    with pytest.raises(NotFoundError):
        admin_user_entitlement_response(
            bad_id,
            load_users=store[1],
            build_entitlements_response=_build_entitlements_response,
            current_admin_grant_record=_current_admin_grant_record,
        )
