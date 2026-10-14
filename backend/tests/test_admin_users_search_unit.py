"""Unit tests for kg.admin_users_search.search_users (pure function).

The HTTP wrapper is covered in test_admin_users_search.py; this file pins
the pure-function contract so refactors can run without spinning the app.
"""

from __future__ import annotations

from kg.admin_users_search import DEFAULT_LIMIT, MAX_LIMIT, search_users


def _users():
    return {
        "_meta": {"schema_version": 3},
        "uid-alice-001": {"email": "alice@example.com", "display_name": "Alice"},
        "uid-alex-002": {"email": "alex@other.org", "displayName": "Alex"},
        "uid-bob-003": {"email": "BOB@workmail.org", "name": "Bobby"},
        "uid-carol-004": {"email": None, "display_name": None},
        # underscore-prefixed should be excluded as non-real user record
        "_internal": {"email": "system@example.com"},
        # non-dict value also excluded by the real-user filter
        "uid-broken-005": "not-a-dict",
    }


def test_empty_query_returns_all_real_users():
    res = search_users(_users(), q="")
    # _meta, _internal, and the broken non-dict row are excluded
    uids = {u["user_id"] for u in res["users"]}
    assert uids == {"uid-alice-001", "uid-alex-002", "uid-bob-003", "uid-carol-004"}
    assert res["total"] == 4
    assert res["limit"] == DEFAULT_LIMIT


def test_uid_prefix_match():
    res = search_users(_users(), q="uid-ali")
    uids = [u["user_id"] for u in res["users"]]
    assert uids == ["uid-alice-001"]


def test_email_substring_case_insensitive():
    res = search_users(_users(), q="WORKMAIL")
    uids = [u["user_id"] for u in res["users"]]
    assert uids == ["uid-bob-003"]


def test_meta_and_underscore_keys_excluded():
    # querying the literal meta key returns nothing
    res = search_users(_users(), q="_meta")
    assert res["users"] == []
    res2 = search_users(_users(), q="_internal")
    assert res2["users"] == []


def test_limit_clamped_low():
    res = search_users(_users(), q="", limit=0)
    assert res["limit"] == 1
    assert len(res["users"]) == 1


def test_limit_clamped_high():
    res = search_users(_users(), q="", limit=MAX_LIMIT + 1000)
    assert res["limit"] == MAX_LIMIT


def test_display_name_field_fallback():
    # 3 different fields populated → all should resolve via _display_name
    data = {
        "uid-1": {"display_name": "From snake"},
        "uid-2": {"displayName": "From camel"},
        "uid-3": {"name": "From name"},
        "uid-4": {},  # no display fields → None
    }
    rows = {u["user_id"]: u["display_name"] for u in search_users(data, q="")["users"]}
    assert rows["uid-1"] == "From snake"
    assert rows["uid-2"] == "From camel"
    assert rows["uid-3"] == "From name"
    assert rows["uid-4"] is None


def test_link_pointer_rows_excluded_from_search():
    # A bare ``{"_linked_to": canonical}`` pointer is not an account; listing it
    # shows a row with no email/provider and double-counts the user.
    data = {
        "uid-a": {"email": "a@x.com"},
        "uid-p": {"_linked_to": "uid-a"},
    }
    res = search_users(data, q="")
    assert [u["user_id"] for u in res["users"]] == ["uid-a"]
    assert res["total"] == 1


def test_display_name_priority_order():
    # When multiple keys present, snake-case wins (first in the tuple).
    data = {"uid-x": {"display_name": "snake", "displayName": "camel", "name": "name"}}
    res = search_users(data, q="")
    assert res["users"][0]["display_name"] == "snake"
