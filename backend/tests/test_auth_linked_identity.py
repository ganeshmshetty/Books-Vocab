from __future__ import annotations

import json

import pytest

from kg.auth_service import resolve_and_link_user
from kg.user_handlers import get_user_profile_response
from kg.user_store import collect_account_ids_for_deletion


def _make_login(tmp_path, seed=None):
    """Return ``(login, load_users)`` backed by a tmp ``users.json``."""
    users_file = tmp_path / "users.json"
    lock_file = tmp_path / "users.json.lock"
    users_file.write_text(json.dumps(seed or {}))

    def load_users():
        return json.loads(users_file.read_text())

    def save_users(users):
        users_file.write_text(json.dumps(users))

    def login(provider_user_id, provider, email):
        return resolve_and_link_user(
            provider_user_id,
            provider,
            users_lock_file=str(lock_file),
            load_users_fn=load_users,
            save_users_fn=save_users,
            email=email,
        )

    return login, load_users


def _canonical_ids(users):
    return sorted(k for k, v in users.items() if not k.startswith("_") and not v.get("_linked_to"))


def test_linked_provider_relogin_without_email_preserves_canonical_identity(tmp_path):
    users_file = tmp_path / "users.json"
    lock_file = tmp_path / "users.json.lock"
    users_file.write_text("{}")

    def load_users():
        return json.loads(users_file.read_text())

    def save_users(users):
        users_file.write_text(json.dumps(users))

    canonical_id = resolve_and_link_user(
        "google-sub",
        "google",
        users_lock_file=str(lock_file),
        load_users_fn=load_users,
        save_users_fn=save_users,
        email="shared@example.com",
    )
    assert (
        resolve_and_link_user(
            "apple-sub",
            "apple",
            users_lock_file=str(lock_file),
            load_users_fn=load_users,
            save_users_fn=save_users,
            email="shared@example.com",
        )
        == canonical_id
    )

    # Apple omits email on subsequent sign-ins. This must not erase the
    # verified email retained on the canonical account.
    assert (
        resolve_and_link_user(
            "apple-sub",
            "apple",
            users_lock_file=str(lock_file),
            load_users_fn=load_users,
            save_users_fn=save_users,
            email=None,
        )
        == canonical_id
    )

    record = load_users()[canonical_id]
    assert record["email"] == "shared@example.com"
    assert record["provider"] == "apple"
    profile = get_user_profile_response({"id": canonical_id, "record": record, "config": {}})
    assert profile.email == "shared@example.com"


def test_linked_identity_email_change_keeps_canonical(tmp_path):
    """#2256: a linked Apple id whose verified email changed (Hide My Email
    re-auth, Apple ID email change) must stay on its linked canonical instead
    of splitting off a new account keyed by the Apple sub."""
    login, load_users = _make_login(tmp_path)

    assert login("G", "google", "e1@example.com") == "G"
    assert login("A", "apple", "e1@example.com") == "G"
    assert login("A", "apple", "r1@privaterelay.appleid.com") == "G"

    users = load_users()
    assert users["_email_index"] == {
        "e1@example.com": "G",
        "r1@privaterelay.appleid.com": "G",
    }
    assert users["A"]["_linked_to"] == "G"
    assert users["G"]["linked_ids"] == ["A"]
    assert users["G"]["provider"] == "apple"
    assert users["G"]["email"] == "r1@privaterelay.appleid.com"
    assert _canonical_ids(users) == ["G"]
    assert collect_account_ids_for_deletion(users, "G") == ("G", ["A", "G"])

    # The follow-up email-less Apple sign-in lands on the same canonical.
    assert login("A", "apple", None) == "G"


def test_linked_identity_email_owned_by_other_canonical_keeps_link(tmp_path):
    """A linked id whose new verified email is already indexed to another
    canonical keeps its link: no silent re-link, no index move, and the other
    canonical's email is never copied onto the linked canonical."""
    login, load_users = _make_login(tmp_path)

    assert login("X", "google", "x@example.com") == "X"
    assert login("G", "google", "e1@example.com") == "G"
    assert login("A", "apple", "e1@example.com") == "G"
    x_before = load_users()["X"]

    assert login("A", "apple", "x@example.com") == "G"

    users = load_users()
    assert users["_email_index"]["x@example.com"] == "X"
    assert users["_email_index"]["e1@example.com"] == "G"
    assert users["A"]["_linked_to"] == "G"
    assert users["G"]["linked_ids"] == ["A"]
    assert users["X"] == x_before
    assert "A" not in users["X"].get("linked_ids", [])
    assert users["G"]["email"] == "e1@example.com"
    assert _canonical_ids(users) == ["G", "X"]


def test_linked_identity_reclaims_email_still_indexed_to_itself(tmp_path):
    """An index entry that still points at the linked provider id itself
    (its own email from before it was merged into G, or a split left behind by
    #2256) is an alias of G: the login resolves to G and the entry moves to G,
    so no other provider can later be routed onto the stale provider id."""
    login, load_users = _make_login(tmp_path)

    assert login("G", "google", "e1@example.com") == "G"
    assert login("A", "apple", "a@example.com") == "A"
    assert login("A", "apple", "e1@example.com") == "G"

    assert login("A", "apple", "a@example.com") == "G"

    users = load_users()
    assert users["_email_index"]["a@example.com"] == "G"
    assert users["A"]["_linked_to"] == "G"
    assert users["G"]["linked_ids"] == ["A"]
    assert login("other", "apple", "a@example.com") == "G"


@pytest.mark.parametrize(
    ("bad_link", "extra_seed"),
    [
        pytest.param(123, {}, id="non-string"),
        pytest.param(None, {}, id="none"),
        pytest.param("A", {}, id="self"),
        pytest.param("missing", {}, id="missing-user"),
        pytest.param("_email_index", {}, id="meta-key"),
        pytest.param("corrupt", {"corrupt": ["not", "a", "record"]}, id="non-dict-record"),
    ],
)
def test_invalid_linked_to_is_ignored(tmp_path, bad_link, extra_seed):
    """An invalid ``_linked_to`` never raises, never redirects the login, and
    is dropped once the provider id resolves as its own canonical, so account
    deletion from that session cannot fan out through the stale pointer."""
    seed = {
        "_email_index": {"o@example.com": "O"},
        "O": {"provider": "google", "email": "o@example.com"},
        "A": {"_linked_to": bad_link},
        **extra_seed,
    }
    login, load_users = _make_login(tmp_path, seed)

    assert login("A", "apple", None) == "A"

    users = load_users()
    assert users["_email_index"] == {"o@example.com": "O"}
    assert "_linked_to" not in users["A"]
    assert users["A"]["provider"] == "apple"
    assert collect_account_ids_for_deletion(users, "A") == ("A", ["A"])

    assert login("A", "apple", "fresh@example.com") == "A"
    assert load_users()["_email_index"] == {
        "o@example.com": "O",
        "fresh@example.com": "A",
    }

    # With the bad pointer gone, the existing verified-email merge applies.
    assert login("A", "apple", "o@example.com") == "O"
    users = load_users()
    assert users["A"]["_linked_to"] == "O"
    assert users["O"]["linked_ids"] == ["A"]
