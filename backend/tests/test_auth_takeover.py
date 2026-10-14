"""Regression tests for C1 account-takeover vulnerability.

Pre-fix attack: client sends `req.email="victim@x.com"` while authenticating
with their own legitimate Google/Apple account. Server uses client-supplied
email to look up the victim in `_email_index` and silent-links the attacker's
provider sub to the victim's canonical user, granting access to victim data.

Fix: server completely ignores client-supplied `req.email`. Provider-derived
email is only used for `_email_index` lookup when `email_verified == True`.
"""

from __future__ import annotations

import json

import pytest

from kg.api_models import AuthVerifyRequest
from kg.auth_handlers import auth_verify_response
from kg.auth_service import resolve_and_link_user


def _make_store(tmp_path):
    users_file = tmp_path / "users.json"
    lock_file = tmp_path / "users.json.lock"
    users_file.write_text(json.dumps({}))

    def load():
        return json.loads(users_file.read_text())

    def save(users):
        users_file.write_text(json.dumps(users))

    return users_file, str(lock_file), load, save


def _seed_victim(users_file, victim_email: str, victim_id: str = "victim-sub"):
    """Pre-populate users.json with a victim canonical user."""
    users = json.loads(users_file.read_text())
    users[victim_id] = {"provider": "google", "email": victim_email}
    users.setdefault("_email_index", {})[victim_email] = victim_id
    users_file.write_text(json.dumps(users))


def _build_handler_kwargs(tmp_path, *, google_sub, google_email, google_email_verified):
    """Return kwargs for auth_verify_response with mocked verify functions."""
    users_file, lock, load, save = _make_store(tmp_path)

    async def fake_verify_google(token, client_id):
        return (google_sub, google_email, google_email_verified)

    def fake_verify_apple(token, audience):
        raise AssertionError("apple verify should not be called")

    def link(provider_user_id, provider, email=None):
        return resolve_and_link_user(
            provider_user_id,
            provider,
            users_lock_file=lock,
            load_users_fn=load,
            save_users_fn=save,
            email=email,
        )

    def jwt(user_id, provider):
        return f"jwt-for-{user_id}"

    return users_file, dict(
        google_client_id="fake-google-client",
        apple_bundle_id="com.fake",
        jwt_expiry_minutes=15,
        verify_google_token=fake_verify_google,
        verify_apple_token=fake_verify_apple,
        resolve_and_link_user=link,
        create_jwt_token=jwt,
    )


@pytest.mark.asyncio
async def test_client_supplied_email_cannot_link_to_victim(tmp_path):
    """Attacker's verified Google sub MUST NOT silent-link to victim by client-claimed email.

    Even though the client sends `email=victim@x.com` and a victim with that
    email exists, the server must trust ONLY the token-derived email
    (attacker@x.com), creating an independent account for the attacker.
    """
    users_file, kwargs = _build_handler_kwargs(
        tmp_path,
        google_sub="attacker_sub",
        google_email="attacker@gmail.com",
        google_email_verified=True,
    )
    _seed_victim(users_file, "victim@gmail.com", victim_id="victim-sub")

    req = AuthVerifyRequest(provider="google", token="g-token", email="victim@gmail.com")
    resp = await auth_verify_response(req, **kwargs)

    # Attacker gets their own canonical id, NOT the victim's.
    assert resp.user_id == "attacker_sub"

    users = json.loads(users_file.read_text())
    # Victim untouched.
    assert "victim-sub" in users
    assert users["victim-sub"].get("linked_ids", []) == []
    # Email index for victim still points to victim.
    assert users["_email_index"]["victim@gmail.com"] == "victim-sub"
    # Attacker linked under their own token email only.
    assert users["_email_index"].get("attacker@gmail.com") == "attacker_sub"
    # Attacker NOT linked under victim email.
    assert users["attacker_sub"].get("_linked_to") is None


@pytest.mark.asyncio
async def test_unverified_token_email_does_not_link_existing_user(tmp_path):
    """email_verified=False → server treats as no email; never links by email.

    Even when the token's email collides with an existing canonical user's
    email, an unverified email must not be used to merge accounts.
    """
    users_file, kwargs = _build_handler_kwargs(
        tmp_path,
        google_sub="new_sub",
        google_email="existing@gmail.com",
        google_email_verified=False,
    )
    # Pre-existing user with same email (verified earlier some other way).
    _seed_victim(users_file, "existing@gmail.com", victim_id="existing-sub")

    req = AuthVerifyRequest(provider="google", token="g-token", email="existing@gmail.com")
    resp = await auth_verify_response(req, **kwargs)

    # Independent account.
    assert resp.user_id == "new_sub"

    users = json.loads(users_file.read_text())
    assert "existing-sub" in users
    assert users["existing-sub"].get("linked_ids", []) == []
    # Email index for existing user untouched (still points to existing-sub).
    assert users["_email_index"]["existing@gmail.com"] == "existing-sub"
    assert users["new_sub"].get("_linked_to") is None
