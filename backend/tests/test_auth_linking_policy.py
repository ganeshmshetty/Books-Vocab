"""Account-linking policy for first-seen provider identities.

* A new provider identity joins an existing account by email only when the
  email is authoritative for that provider (Apple verified email; Google
  ``@gmail.com`` / ``@googlemail.com`` or a Workspace ``hd`` equal to the
  email domain). Otherwise it gets its own canonical account.
* An id that already is an independent canonical account is never re-linked
  under another account by email.
* Apple web sign-in ``state`` is recorded server-side and single-use, like the
  Google flow (#2804).
"""

from __future__ import annotations

import json
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

import httpx
import pytest

from kg import google_auth
from kg.api_models import AuthVerifyRequest
from kg.auth_handlers import auth_verify_response
from kg.auth_service import resolve_and_link_user
from kg.auth_types import GoogleIdentity, VerifiedIdentity
from test_web_auth_state import web_auth_env  # noqa: F401  (shared fixture)

CLIENT_ID = "test-client-id.apps.googleusercontent.com"


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

    return login, load_users


# ---------------------------------------------------------------------------
# Email authority
# ---------------------------------------------------------------------------


def test_google_custom_domain_email_without_hd_gets_own_account(tmp_path):
    login, load = _make_login(tmp_path)
    owner = login("000111.apple-owner.0001", "apple", "alice@custom-domain.example")

    other = login("google-sub", "google", "alice@custom-domain.example")

    assert other == "google-sub"
    assert other != owner
    users = load()
    assert users["_email_index"]["alice@custom-domain.example"] == owner
    assert "_linked_to" not in users["google-sub"]
    assert "google-sub" not in users[owner].get("linked_ids", [])
    # The existing account's profile is untouched by the other sign-in.
    assert users[owner]["provider"] == "apple"
    assert users[owner]["email"] == "alice@custom-domain.example"


def test_non_authoritative_relogin_keeps_resolving_to_own_account(tmp_path):
    login, _ = _make_login(tmp_path)
    login("apple-owner", "apple", "alice@custom-domain.example")
    first = login("google-sub", "google", "alice@custom-domain.example")

    assert login("google-sub", "google", "alice@custom-domain.example") == first == "google-sub"


@pytest.mark.parametrize("email", ["alice@gmail.com", "alice@googlemail.com"])
def test_google_consumer_email_links_to_existing_account(tmp_path, email):
    login, load = _make_login(tmp_path)
    owner = login("apple-owner", "apple", email)

    assert login("google-sub", "google", email) == owner
    assert load()[owner]["linked_ids"] == ["google-sub"]


def test_google_workspace_hd_matching_email_domain_links(tmp_path):
    login, _ = _make_login(tmp_path)
    owner = login("apple-owner", "apple", "alice@corp.example")

    assert login("google-sub", "google", "alice@corp.example", hd="corp.example") == owner


@pytest.mark.parametrize("hd", [None, "", "other.example"])
def test_google_hd_not_matching_email_domain_does_not_link(tmp_path, hd):
    login, _ = _make_login(tmp_path)
    owner = login("apple-owner", "apple", "alice@corp.example")

    assert login("google-sub", "google", "alice@corp.example", hd=hd) == "google-sub"
    assert owner == "apple-owner"


@pytest.mark.parametrize("email", ["alice@icloud.com", "relay@privaterelay.appleid.com", "alice@custom.example"])
def test_apple_verified_email_links_to_existing_account(tmp_path, email):
    login, _ = _make_login(tmp_path)
    owner = login("google-owner", "google", email, hd=email.split("@")[1])

    assert login("apple-sub", "apple", email) == owner


def test_linked_identity_keeps_resolving_to_canonical_without_authority(tmp_path):
    login, load = _make_login(tmp_path)
    owner = login("apple-owner", "apple", "alice@gmail.com")
    assert login("google-sub", "google", "alice@gmail.com") == owner

    # Existing links stay valid even when the token email no longer qualifies.
    assert login("google-sub", "google", "alice@custom-domain.example") == owner
    assert load()["google-sub"]["_linked_to"] == owner


# ---------------------------------------------------------------------------
# Token claims
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("claims", "expected_hd"),
    [({"hd": "Corp.Example"}, "corp.example"), ({}, None), ({"hd": ""}, None)],
)
async def test_verify_google_token_returns_hosted_domain(claims, expected_hd):
    payload = {"sub": "g-1", "email": "A@Corp.Example", "email_verified": True, **claims}
    with patch("kg.google_auth.id_token.verify_oauth2_token", return_value=payload):
        identity = await google_auth.verify_google_token("tok", CLIENT_ID)

    assert identity.sub == "g-1"
    assert identity.hd == expected_hd


@pytest.mark.asyncio
async def test_auth_verify_passes_hosted_domain_to_linking():
    seen: dict = {}

    async def verify_google(token, client_id):
        return GoogleIdentity("g-1", "a@corp.example", True, "corp.example")

    def link(provider_user_id, provider, email, **kwargs):
        seen.update(kwargs)
        return provider_user_id

    await auth_verify_response(
        AuthVerifyRequest(provider="google", token="t"),
        google_client_id="cid",
        apple_bundle_id="com.example",
        jwt_expiry_minutes=5,
        verify_google_token=verify_google,
        verify_apple_token=lambda token, audience: pytest.fail("unexpected"),
        resolve_and_link_user=link,
        create_jwt_token=lambda uid, provider: "jwt",
    )

    assert seen == {"hd": "corp.example"}


def test_google_web_callback_passes_hosted_domain_to_linking(web_auth_env):  # noqa: F811
    client = web_auth_env.client
    login = client.get("/auth/web/google/login", follow_redirects=False)
    state = login.headers["location"].split("state=")[1].split("&")[0]
    token_resp = httpx.Response(
        200,
        json={"id_token": "fake-id-token"},
        request=httpx.Request("POST", "https://oauth2.googleapis.com/token"),
    )

    async def fake_post(self, url, data=None, **kwargs):
        return token_resp

    async def fake_verify(token, client_id):
        return GoogleIdentity("g-1", "a@corp.example", True, "corp.example")

    with (
        patch("httpx.AsyncClient.post", new=fake_post),
        patch("kg.routers.web_auth.verify_google_token", new=fake_verify),
        patch("kg.routers.web_auth._resolve_and_link_user", return_value="g-1") as resolve_mock,
    ):
        resp = client.get(f"/auth/web/google/callback?code=c&state={state}", follow_redirects=False)

    assert resp.status_code == 200, resp.text
    assert resolve_mock.call_args.kwargs["hd"] == "corp.example"


# ---------------------------------------------------------------------------
# Independent canonical accounts are never re-linked
# ---------------------------------------------------------------------------


def test_independent_account_is_not_relinked_by_email(tmp_path):
    login, load = _make_login(tmp_path, {"p": {"subscription": {"tier": "pro"}, "provider": "google"}})
    assert login("c", "apple", "e@x.com") == "c"
    owner_before = dict(load()["c"])

    assert login("p", "apple", "e@x.com") == "p"

    users = load()
    assert "_linked_to" not in users["p"]
    assert "p" not in users["c"].get("linked_ids", [])
    assert users["_email_index"]["e@x.com"] == "c"
    assert users["c"]["provider"] == owner_before["provider"]
    assert users["p"]["subscription"] == {"tier": "pro"}
    assert users["p"].get("email") is None


def test_fresh_provider_id_still_links_by_authoritative_email(tmp_path):
    login, load = _make_login(tmp_path)
    assert login("c", "apple", "e@x.com") == "c"

    assert login("fresh", "apple", "e@x.com") == "c"
    assert load()["c"]["linked_ids"] == ["fresh"]


# ---------------------------------------------------------------------------
# Apple web sign-in state
# ---------------------------------------------------------------------------

_FORGED = "forged-equal-state-value"


def _state_from_login(resp) -> str:
    return parse_qs(urlparse(resp.headers["location"]).query)["state"][0]


def test_apple_callback_rejects_state_never_issued(web_auth_env):  # noqa: F811
    with (
        patch("kg.routers.web_auth.verify_apple_token") as verify_mock,
        patch("kg.routers.web_auth._resolve_and_link_user") as resolve_mock,
    ):
        resp = web_auth_env.client.post(
            "/auth/web/apple/callback",
            data={"id_token": "tok", "state": _FORGED},
            headers={"cookie": f"oauth_state={_FORGED}"},
        )

    assert resp.status_code == 400
    verify_mock.assert_not_called()
    resolve_mock.assert_not_called()


def test_apple_callback_state_is_single_use(web_auth_env):  # noqa: F811
    client = web_auth_env.client
    state = _state_from_login(client.get("/auth/web/apple/login", follow_redirects=False))
    form = {"id_token": "tok", "state": state}
    cookie = {"cookie": f"oauth_state={state}"}

    with patch(
        "kg.routers.web_auth.verify_apple_token",
        return_value=VerifiedIdentity("apple-user-1", None, False),
    ) as verify_mock:
        first = client.post("/auth/web/apple/callback", data=form, headers=cookie)
        replay = client.post("/auth/web/apple/callback", data=form, headers=cookie)

    assert first.status_code == 200, first.text
    assert replay.status_code == 400
    assert verify_mock.call_count == 1


def test_apple_callback_accepts_state_minted_by_login_page(web_auth_env):  # noqa: F811
    client = web_auth_env.client
    page = client.get("/login")
    state = page.cookies.get("oauth_state")
    assert state

    with patch(
        "kg.routers.web_auth.verify_apple_token",
        return_value=VerifiedIdentity("apple-user-2", None, False),
    ):
        resp = client.post(
            "/auth/web/apple/callback",
            data={"id_token": "tok", "state": state},
            headers={"cookie": f"oauth_state={state}"},
        )

    assert resp.status_code == 200, resp.text
