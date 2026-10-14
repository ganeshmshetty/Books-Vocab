from __future__ import annotations

import json

import jwt as pyjwt
import pytest

from conftest import TEST_JWT_SECRET
from kg.auth_service import create_jwt_token, resolve_and_link_user


def test_create_jwt_token_produces_decodable_payload():
    token = create_jwt_token(
        "user-123",
        "google",
        jwt_secret=TEST_JWT_SECRET,
        jwt_algorithm="HS256",
        jwt_expiry_minutes=15,
    )
    payload = pyjwt.decode(token, TEST_JWT_SECRET, algorithms=["HS256"])
    assert payload["sub"] == "user-123"
    assert payload["provider"] == "google"


def test_resolve_and_link_user_merges_by_email(tmp_path):
    users_file = tmp_path / "users.json"
    lock_file = tmp_path / "users.json.lock"
    users_file.write_text(json.dumps({}))

    def load_users():
        return json.loads(users_file.read_text())

    def save_users(users):
        users_file.write_text(json.dumps(users))

    canonical = resolve_and_link_user(
        "google-sub",
        "google",
        users_lock_file=str(lock_file),
        load_users_fn=load_users,
        save_users_fn=save_users,
        email="same@example.com",
    )
    assert canonical == "google-sub"

    linked = resolve_and_link_user(
        "apple-sub",
        "apple",
        users_lock_file=str(lock_file),
        load_users_fn=load_users,
        save_users_fn=save_users,
        email="same@example.com",
    )
    assert linked == "google-sub"

    stored = json.loads(users_file.read_text())
    assert stored["_email_index"]["same@example.com"] == "google-sub"
    assert stored["google-sub"]["linked_ids"] == ["apple-sub"]
    assert stored["apple-sub"]["_linked_to"] == "google-sub"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _make_store(tmp_path):
    """Return (users_file, lock_file, load_fn, save_fn) backed by tmp_path."""
    users_file = tmp_path / "users.json"
    lock_file = tmp_path / "users.json.lock"
    users_file.write_text(json.dumps({}))

    def load():
        return json.loads(users_file.read_text())

    def save(users):
        users_file.write_text(json.dumps(users))

    return users_file, str(lock_file), load, save


# ---------------------------------------------------------------------------
# 1. new user without email — canonical = provider_user_id, no email index
# ---------------------------------------------------------------------------


def test_new_user_no_email_uses_provider_id_as_canonical(tmp_path):
    users_file, lock, load, save = _make_store(tmp_path)

    canonical = resolve_and_link_user(
        "device-abc",
        "anonymous",
        users_lock_file=lock,
        load_users_fn=load,
        save_users_fn=save,
        email=None,
    )
    assert canonical == "device-abc"

    stored = json.loads(users_file.read_text())
    assert "device-abc" in stored
    # email_index must exist but be empty
    assert stored["_email_index"] == {}


# ---------------------------------------------------------------------------
# 2. same user logs in twice — updates last_login, no duplicate
# ---------------------------------------------------------------------------


def test_repeated_login_updates_last_login_without_duplicating(tmp_path):
    users_file, lock, load, save = _make_store(tmp_path)

    resolve_and_link_user(
        "user-1", "google",
        users_lock_file=lock,
        load_users_fn=load,
        save_users_fn=save,
        email="u@example.com",
    )
    first_login = json.loads(users_file.read_text())["user-1"]["last_login"]

    resolve_and_link_user(
        "user-1", "google",
        users_lock_file=lock,
        load_users_fn=load,
        save_users_fn=save,
        email="u@example.com",
    )
    stored = json.loads(users_file.read_text())
    second_login = stored["user-1"]["last_login"]

    assert second_login >= first_login
    # no linked_ids — same user, not a merge
    assert "linked_ids" not in stored["user-1"]
    # email_index still points to the same id
    assert stored["_email_index"]["u@example.com"] == "user-1"


# ---------------------------------------------------------------------------
# 3. three providers, same email — all link to the first
# ---------------------------------------------------------------------------


def test_three_providers_same_email_all_link_to_first(tmp_path):
    users_file, lock, load, save = _make_store(tmp_path)
    email = "shared@example.com"

    first = resolve_and_link_user(
        "google-1", "google",
        users_lock_file=lock, load_users_fn=load, save_users_fn=save,
        email=email,
    )
    second = resolve_and_link_user(
        "apple-1", "apple",
        users_lock_file=lock, load_users_fn=load, save_users_fn=save,
        email=email,
    )
    third = resolve_and_link_user(
        "apple-2", "apple",
        users_lock_file=lock, load_users_fn=load, save_users_fn=save,
        email=email,
    )

    assert first == second == third == "google-1"

    stored = json.loads(users_file.read_text())
    assert set(stored["google-1"]["linked_ids"]) == {"apple-1", "apple-2"}
    assert stored["apple-1"]["_linked_to"] == "google-1"
    assert stored["apple-2"]["_linked_to"] == "google-1"


# ---------------------------------------------------------------------------
# 4. _revoked_before present — cleared after login
# ---------------------------------------------------------------------------


def test_revoked_before_cleared_after_login(tmp_path):
    users_file, lock, load, save = _make_store(tmp_path)

    # seed with _revoked_before for the user
    seed = {
        "_email_index": {},
        "_revoked_before": {"user-x": "2025-01-01T00:00:00"},
    }
    users_file.write_text(json.dumps(seed))

    resolve_and_link_user(
        "user-x", "google",
        users_lock_file=lock,
        load_users_fn=load,
        save_users_fn=save,
        email="x@example.com",
    )

    stored = json.loads(users_file.read_text())
    # _revoked_before should be entirely removed (was the only entry)
    assert "_revoked_before" not in stored


# ---------------------------------------------------------------------------
# 5. email is None — no email_index entry written
# ---------------------------------------------------------------------------


def test_email_none_does_not_write_email_index(tmp_path):
    users_file, lock, load, save = _make_store(tmp_path)

    resolve_and_link_user(
        "anon-1", "anonymous",
        users_lock_file=lock,
        load_users_fn=load,
        save_users_fn=save,
        email=None,
    )

    stored = json.loads(users_file.read_text())
    assert stored["_email_index"] == {}
    assert stored["anon-1"]["email"] is None


# ---------------------------------------------------------------------------
# 6. create_jwt_token with special characters in user_id
# ---------------------------------------------------------------------------


def test_create_jwt_token_special_chars_in_user_id():
    special_id = "user/with spaces+émojis&symbols=yes"
    token = create_jwt_token(
        special_id,
        "google",
        jwt_secret=TEST_JWT_SECRET,
        jwt_algorithm="HS256",
        jwt_expiry_minutes=15,
    )
    payload = pyjwt.decode(token, TEST_JWT_SECRET, algorithms=["HS256"])
    assert payload["sub"] == special_id


# ---------------------------------------------------------------------------
# 7. token expiry 0 — immediately expired
# ---------------------------------------------------------------------------


def test_jwt_token_expiry_zero_is_immediately_expired():
    token = create_jwt_token(
        "user-exp",
        "google",
        jwt_secret=TEST_JWT_SECRET,
        jwt_algorithm="HS256",
        jwt_expiry_minutes=0,
    )
    with pytest.raises(pyjwt.ExpiredSignatureError):
        pyjwt.decode(token, TEST_JWT_SECRET, algorithms=["HS256"])


# ---------------------------------------------------------------------------
# 8. account-deletion watermark is irreversible — a subsequent login (same
#    provider/sub OR same email via another provider) must NOT clear it.
#    A non-deletion revocation (no `_terminated` marker) stays clearable.
# ---------------------------------------------------------------------------


def test_terminated_revocation_survives_relogin_same_sub(tmp_path):
    """Account deletion stamps `_revoked_before` AND marks the id in
    `_terminated`. Re-login with the SAME sub must keep the watermark so old
    JWTs (iat <= watermark) stay dead."""
    users_file, lock, load, save = _make_store(tmp_path)
    seed = {
        "_email_index": {},
        "_revoked_before": {"apple-X": "2025-01-01T00:00:00+00:00"},
        "_terminated": ["apple-X"],
    }
    users_file.write_text(json.dumps(seed))

    resolve_and_link_user(
        "apple-X", "apple",
        users_lock_file=lock,
        load_users_fn=load,
        save_users_fn=save,
        email="a@example.com",
    )

    stored = json.loads(users_file.read_text())
    assert stored["_revoked_before"].get("apple-X") == "2025-01-01T00:00:00+00:00"


def test_terminated_revocation_survives_relogin_other_provider_same_email(tmp_path):
    """User deletes the Apple account, then signs in with Google using the
    SAME email. The deletion watermark for the old canonical id must NOT be
    popped — otherwise old Apple JWTs would be revived."""
    users_file, lock, load, save = _make_store(tmp_path)
    seed = {
        # email_index was already purged by the deletion flow.
        "_email_index": {},
        "_revoked_before": {"apple-X": "2025-01-01T00:00:00+00:00"},
        "_terminated": ["apple-X"],
    }
    users_file.write_text(json.dumps(seed))

    resolve_and_link_user(
        "google-Y", "google",
        users_lock_file=lock,
        load_users_fn=load,
        save_users_fn=save,
        email="a@example.com",
    )

    stored = json.loads(users_file.read_text())
    # Old Apple watermark must remain intact.
    assert stored["_revoked_before"].get("apple-X") == "2025-01-01T00:00:00+00:00"


def test_non_terminated_revocation_still_cleared_after_login(tmp_path):
    """A revocation NOT backed by `_terminated` (e.g. a transient session
    invalidation) keeps the legacy clear-on-login behaviour."""
    users_file, lock, load, save = _make_store(tmp_path)
    seed = {
        "_email_index": {},
        "_revoked_before": {"user-x": "2025-01-01T00:00:00+00:00"},
    }
    users_file.write_text(json.dumps(seed))

    resolve_and_link_user(
        "user-x", "google",
        users_lock_file=lock,
        load_users_fn=load,
        save_users_fn=save,
        email="x@example.com",
    )

    stored = json.loads(users_file.read_text())
    assert "_revoked_before" not in stored
