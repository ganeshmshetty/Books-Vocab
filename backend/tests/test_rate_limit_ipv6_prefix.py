"""Anonymous rate-limit keys aggregate IPv6 clients by their /64 network.

A single host is typically allocated a whole /64, so per-address keys would
give that host an unbounded number of buckets. IPv4 keys stay exact, and
IPv4-mapped IPv6 addresses resolve to their IPv4 form.
"""

from __future__ import annotations

import logging

import pytest

from conftest import ADMIN_TOKEN

ADMIN_PASSWORD = "lane-test-admin-password"
WRONG_PASSWORD = "lane-test-wrong-password"


@pytest.fixture()
def admin_app(admin_app_factory):
    from kg.rate_limit import login_limiter

    login_limiter.reset()
    try:
        yield admin_app_factory(admin_token=ADMIN_TOKEN, admin_password=ADMIN_PASSWORD)
    finally:
        login_limiter.reset()


def _key(xff: str) -> str:
    from kg.api import _anon_rate_limit_key

    return _anon_rate_limit_key(xff, None, 1)


def _post_login(client, xff: str, password: str):
    return client.post(
        "/admin/login",
        data={"password": password},
        headers={"X-Forwarded-For": xff},
        follow_redirects=False,
    )


def test_ipv6_addresses_in_same_slash64_share_key():
    assert _key("2001:db8:1:2::1") == _key("2001:db8:1:2:ffff:ffff:ffff:ffff")


def test_ipv6_key_is_the_containing_slash64_network():
    assert _key("2001:db8:1:2::1") == "2001:db8:1:2::/64"


def test_ipv6_addresses_in_different_slash64_get_distinct_keys():
    assert _key("2001:db8:1:2::1") != _key("2001:db8:1:3::1")


def test_ipv4_key_is_unchanged():
    assert _key("203.0.113.7") == "203.0.113.7"


def test_ipv4_mapped_ipv6_maps_to_ipv4_key():
    assert _key("::ffff:203.0.113.7") == "203.0.113.7"


def test_addresses_in_one_slash64_share_one_login_budget(admin_app):
    from kg.rate_limit import login_limiter

    addresses = [f"2001:db8:1:2::{i:x}" for i in range(1, 51)]
    statuses = [_post_login(admin_app.client, a, WRONG_PASSWORD).status_code for a in addresses]

    assert sum(status != 429 for status in statuses) == login_limiter.max_requests


def test_distinct_slash64_prefixes_have_separate_login_budgets(admin_app):
    exhausted = [_post_login(admin_app.client, f"2001:db8:1:2::{i:x}", WRONG_PASSWORD) for i in range(1, 11)]
    assert 429 in [resp.status_code for resp in exhausted]

    other_prefix = _post_login(admin_app.client, "2001:db8:1:3::1", WRONG_PASSWORD)
    assert other_prefix.status_code != 429


def test_failed_admin_login_logs_warning_with_key_and_no_password(admin_app, caplog):
    caplog.set_level(logging.WARNING)

    resp = _post_login(admin_app.client, "2001:db8:1:2::1", WRONG_PASSWORD)

    assert resp.status_code == 200
    messages = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    rejected = [m for m in messages if m.startswith("Admin login rejected")]
    assert len(rejected) == 1
    assert "2001:db8:1:2::/64" in rejected[0]
    assert WRONG_PASSWORD not in rejected[0]


def test_successful_admin_login_logs_no_rejection(admin_app, caplog):
    caplog.set_level(logging.WARNING)

    resp = _post_login(admin_app.client, "203.0.113.9", ADMIN_PASSWORD)

    assert resp.status_code == 302
    assert not [r for r in caplog.records if r.getMessage().startswith("Admin login rejected")]
