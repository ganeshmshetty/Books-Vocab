"""``_email_index`` holds only provider-authoritative addresses.

* An address is authoritative for Google when it is a consumer address
  (``@gmail.com`` / ``@googlemail.com``) or equals the token's ``hd`` domain;
  for Apple when it belongs to a domain Apple itself provisions or verifies
  (iCloud / relay / Google consumer domains). Everything else, including
  unknown providers and malformed addresses, is not authoritative.
* Only authoritative addresses are written to the index and only authoritative
  addresses are looked up when linking identities.
* Index entries never point at a missing account, and never move between
  accounts when a canonical account signs in with another address.
"""

from __future__ import annotations

import json
from unittest.mock import MagicMock

import pytest

from kg.auth_service import resolve_and_link_user
from kg.user_handlers import delete_user_account_response
from kg.user_store import collect_account_ids_for_deletion


def _make_login(tmp_path, seed=None):
    users_file = tmp_path / "users.json"
    lock_file = tmp_path / "users.json.lock"
    users_file.write_text(json.dumps(seed or {}))

    def load_users():
        return json.loads(users_file.read_text())

    def save_users(users):
        users_file.write_text(json.dumps(users))

    def login(provider_user_id, provider, email, **kwargs):
        return resolve_and_link_user(
            provider_user_id,
            provider,
            users_lock_file=str(lock_file),
            load_users_fn=load_users,
            save_users_fn=save_users,
            email=email,
            **kwargs,
        )

    return login, load_users, save_users


def _index(load) -> dict:
    return load().get("_email_index", {})


# ---------------------------------------------------------------------------
# Authority matrix: which first sign-ins are written to the index
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("provider", "email", "hd", "indexed"),
    [
        ("google", "a@gmail.com", None, True),
        ("google", "a@googlemail.com", None, True),
        ("google", "a@corp.example", "corp.example", True),
        ("google", "a@corp.example", "CORP.example", True),
        ("google", "a@corp.example", None, False),
        ("google", "a@corp.example", "", False),
        ("google", "a@corp.example", "other.example", False),
        ("google", "a@sub.corp.example", "corp.example", False),
        ("apple", "a@icloud.com", None, True),
        ("apple", "a@me.com", None, True),
        ("apple", "a@mac.com", None, True),
        ("apple", "abc123@privaterelay.appleid.com", None, True),
        ("apple", "a@gmail.com", None, True),
        ("apple", "a@googlemail.com", None, True),
        ("apple", "a@corp.example", None, False),
        ("apple", "a@icloud.com.example", None, False),
        ("apple", "a@notgmail.com", None, False),
        ("apple", "a@corp.example", "corp.example", False),
        ("password", "a@gmail.com", None, False),
        ("google", "gmail.com", None, False),
        ("google", "@gmail.com", None, False),
        ("apple", "icloud.com", None, False),
    ],
)
def test_only_authoritative_first_sign_in_is_indexed(tmp_path, provider, email, hd, indexed):
    login, load, _ = _make_login(tmp_path)

    kwargs = {"hd": hd} if hd is not None else {}
    assert login("sub-1", provider, email, **kwargs) == "sub-1"

    assert _index(load) == ({email: "sub-1"} if indexed else {})
    # The profile email is still recorded on the account itself.
    assert load()["sub-1"]["email"] == email


# ---------------------------------------------------------------------------
# Non-authoritative addresses never become link targets
# ---------------------------------------------------------------------------


def test_address_first_seen_without_authority_is_not_a_link_target(tmp_path):
    login, load, _ = _make_login(tmp_path)
    first = login("g-custom", "google", "alice@corp.example")

    later = login("g-workspace", "google", "alice@corp.example", hd="corp.example")

    assert first == "g-custom"
    assert later == "g-workspace"
    users = load()
    assert "_linked_to" not in users["g-workspace"]
    assert users["g-custom"].get("linked_ids", []) == []
    assert _index(load) == {"alice@corp.example": "g-workspace"}


def test_apple_custom_domain_address_is_not_a_link_target(tmp_path):
    login, load, _ = _make_login(tmp_path)
    first = login("apple-1", "apple", "alice@corp.example")

    later = login("g-workspace", "google", "alice@corp.example", hd="corp.example")

    assert (first, later) == ("apple-1", "g-workspace")
    assert _index(load) == {"alice@corp.example": "g-workspace"}


def test_apple_custom_domain_sign_in_does_not_join_authoritative_owner(tmp_path):
    login, load, _ = _make_login(tmp_path)
    owner = login("g-workspace", "google", "alice@corp.example", hd="corp.example")

    other = login("apple-1", "apple", "alice@corp.example")

    assert other == "apple-1" != owner
    users = load()
    assert _index(load) == {"alice@corp.example": owner}
    assert users[owner].get("linked_ids", []) == []
    # The address is not echoed onto an account that does not own the index entry.
    assert users["apple-1"]["email"] is None


@pytest.mark.parametrize(
    ("first_provider", "second_provider", "email"),
    [
        ("apple", "google", "alice@gmail.com"),
        ("google", "apple", "alice@gmail.com"),
        ("apple", "google", "alice@googlemail.com"),
        ("apple", "apple", "alice@me.com"),
        ("apple", "apple", "alice@icloud.com"),
    ],
)
def test_addresses_authoritative_for_both_providers_link(tmp_path, first_provider, second_provider, email):
    login, load, _ = _make_login(tmp_path)
    owner = login("first", first_provider, email)

    assert login("second", second_provider, email) == owner
    assert load()[owner]["linked_ids"] == ["second"]


def test_linking_needs_authority_on_both_sides(tmp_path):
    login, load, _ = _make_login(tmp_path)
    owner = login("apple-owner", "apple", "alice@icloud.com")

    # Google cannot vouch for an iCloud address, so it neither reads nor
    # extends the entry written by Apple.
    assert login("g-sub", "google", "alice@icloud.com") == "g-sub"

    assert _index(load) == {"alice@icloud.com": owner}
    assert load()[owner].get("linked_ids", []) == []


# ---------------------------------------------------------------------------
# Existing links and entries
# ---------------------------------------------------------------------------


def test_linked_identity_with_non_authoritative_address_adds_no_index_entry(tmp_path):
    login, load, _ = _make_login(tmp_path)
    owner = login("apple-owner", "apple", "alice@icloud.com")
    assert login("apple-second", "apple", "alice@icloud.com") == owner

    assert login("apple-second", "apple", "alice@corp.example") == owner

    assert _index(load) == {"alice@icloud.com": owner}


def test_linked_identity_with_other_authoritative_address_adds_alias_and_keeps_old_entry(tmp_path):
    login, load, _ = _make_login(tmp_path)
    owner = login("apple-owner", "apple", "alice@icloud.com")
    assert login("apple-second", "apple", "alice@icloud.com") == owner

    assert login("apple-second", "apple", "alice@me.com") == owner

    assert _index(load) == {"alice@icloud.com": owner, "alice@me.com": owner}
    assert load()[owner]["email"] == "alice@me.com"


def test_address_indexed_to_another_account_is_never_repointed(tmp_path):
    login, load, _ = _make_login(tmp_path)
    first = login("first", "apple", "a@icloud.com")
    second = login("second", "apple", "b@icloud.com")
    assert (first, second) == ("first", "second")

    # `second` (own canonical account with real state) now reports `first`'s address.
    assert login("second", "apple", "a@icloud.com") == "second"

    users = load()
    assert _index(load) == {"a@icloud.com": "first", "b@icloud.com": "second"}
    assert users["first"]["email"] == "a@icloud.com"
    assert users["second"]["email"] == "b@icloud.com"
    assert "_linked_to" not in users["second"]


def test_entry_pointing_at_missing_account_is_replaced_not_followed(tmp_path):
    login, load, _ = _make_login(tmp_path, {"_email_index": {"alice@icloud.com": "gone-account"}})

    assert login("apple-1", "apple", "alice@icloud.com") == "apple-1"

    assert _index(load) == {"alice@icloud.com": "apple-1"}
    assert "gone-account" not in load()


def test_entry_pointing_at_missing_account_is_replaced_for_linked_identity(tmp_path):
    login, load, save = _make_login(tmp_path)
    owner = login("apple-owner", "apple", "alice@icloud.com")
    assert login("apple-second", "apple", "alice@icloud.com") == owner
    users = load()
    users["_email_index"]["alice@me.com"] = "gone-account"
    save(users)

    assert login("apple-second", "apple", "alice@me.com") == owner

    assert _index(load)["alice@me.com"] == owner


def test_entry_pointing_at_link_pointer_resolves_to_its_canonical(tmp_path):
    login, load, save = _make_login(tmp_path)
    owner = login("google-owner", "google", "alice@gmail.com")
    users = load()
    users["apple-pointer"] = {"_linked_to": owner}
    users["_email_index"]["alice@icloud.com"] = "apple-pointer"
    save(users)

    assert login("apple-new", "apple", "alice@icloud.com") == owner

    users = load()
    assert users["apple-new"]["_linked_to"] == owner
    assert users[owner]["linked_ids"] == ["apple-new"]


# ---------------------------------------------------------------------------
# Account deletion removes the account's index entries
# ---------------------------------------------------------------------------


def _delete(tmp_path, user_id, load, save):
    return delete_user_account_response(
        {"id": user_id},
        users_lock_file=tmp_path / "users.json.lock",
        load_users=load,
        save_users=save,
        collect_account_ids_for_deletion=collect_account_ids_for_deletion,
        data_dir=tmp_path,
        logger=MagicMock(),
    )


def test_deleting_linked_account_removes_every_index_entry_it_owns(tmp_path):
    login, load, save = _make_login(tmp_path)
    owner = login("apple-owner", "apple", "alice@icloud.com")
    assert login("apple-linked", "apple", "alice@icloud.com") == owner
    assert login("apple-linked", "apple", "alice@mac.com") == owner
    unrelated_google = login("g-sub", "google", "alice@gmail.com")
    unrelated_apple = login("apple-other", "apple", "bob@icloud.com")
    assert _index(load)["alice@mac.com"] == owner

    _delete(tmp_path, "apple-linked", load, save)

    assert _index(load) == {"alice@gmail.com": unrelated_google, "bob@icloud.com": unrelated_apple}
    assert owner not in load()


def test_address_of_deleted_account_starts_a_fresh_account(tmp_path):
    login, load, save = _make_login(tmp_path)
    owner = login("apple-owner", "apple", "alice@icloud.com")

    _delete(tmp_path, owner, load, save)
    assert "_email_index" not in load()

    fresh = login("apple-new", "apple", "alice@icloud.com")

    assert fresh == "apple-new"
    assert _index(load) == {"alice@icloud.com": "apple-new"}
    assert owner not in load()
