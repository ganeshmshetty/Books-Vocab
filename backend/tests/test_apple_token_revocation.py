"""#3815: Sign in with Apple refresh-token capture and revocation on account deletion.

Config-gated: Apple is contacted only when APPLE_SIWA_TEAM_ID, APPLE_SIWA_KEY_ID
and APPLE_SIWA_PRIVATE_KEY_PATH are all set. Apple traffic is served by
httpx.MockTransport; the autouse guard fails any test that reaches a real socket.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qsl

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

import kg.routers.auth as auth_router
from conftest import TEST_JWT_SECRET, _swap_settings
from kg.api import app
from kg.auth_types import VerifiedIdentity
from kg.settings import load_settings

TEAM_ID = "TEAM3815AB"
KEY_ID = "KEY3815CDE"
CLIENT_ID = "com.Max0228.BooksBrowser"
APPLE_AUDIENCE = "https://appleid.apple.com"
TOKEN_URL = "https://appleid.apple.com/auth/token"
REVOKE_URL = "https://appleid.apple.com/auth/revoke"
APPLE_SUB = "apple-sub-3815"
REFRESH_TOKEN = "refresh-from-apple-3815"
STORED_TOKEN = "stored-refresh-3815"
SIWA_ENV = ("APPLE_SIWA_TEAM_ID", "APPLE_SIWA_KEY_ID", "APPLE_SIWA_PRIVATE_KEY_PATH")


@pytest.fixture(autouse=True)
def _no_real_network(monkeypatch):
    def _refuse(self, request):
        raise AssertionError(f"test attempted a real network call: {request.url}")

    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", _refuse)


@dataclass
class FakeApple:
    token_status: int = 200
    revoke_status: int = 200
    requests: list[httpx.Request] = field(default_factory=list)
    on_request: Callable[[httpx.Request], None] | None = None

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.on_request is not None:
            self.on_request(request)
        if str(request.url) == TOKEN_URL:
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "invalid_grant"})
            return httpx.Response(
                200,
                json={
                    "access_token": "access-3815",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "refresh_token": REFRESH_TOKEN,
                    "id_token": "id-3815",
                },
            )
        if str(request.url) == REVOKE_URL:
            return httpx.Response(self.revoke_status, json={})
        raise AssertionError(f"unexpected Apple endpoint: {request.url}")

    def calls(self, url: str) -> list[dict[str, str]]:
        return [dict(parse_qsl(r.content.decode("utf-8"))) for r in self.requests if str(r.url) == url]


@pytest.fixture(scope="module")
def apple_signing_key(tmp_path_factory):
    key = ec.generate_private_key(ec.SECP256R1())
    path = tmp_path_factory.mktemp("siwa_key") / "AuthKey_3815.p8"
    path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    return path, key.public_key()


def _wire(api, monkeypatch, *, configured: bool, key_path: Path | None = None) -> FakeApple:
    apple = FakeApple()
    monkeypatch.setenv("JWT_SECRET", TEST_JWT_SECRET)
    monkeypatch.setenv("KG_DATA_DIR", str(api.data_dir))
    for name in SIWA_ENV:
        monkeypatch.delenv(name, raising=False)
    if configured:
        monkeypatch.setenv("APPLE_SIWA_TEAM_ID", TEAM_ID)
        monkeypatch.setenv("APPLE_SIWA_KEY_ID", KEY_ID)
        monkeypatch.setenv("APPLE_SIWA_PRIVATE_KEY_PATH", str(key_path))
    _swap_settings(load_settings())
    monkeypatch.setattr(app.state, "apple_http_transport", httpx.MockTransport(apple.handle), raising=False)
    monkeypatch.setattr(
        auth_router,
        "verify_apple_token",
        lambda token, audience: VerifiedIdentity(APPLE_SUB, None, False),
    )
    return apple


@pytest.fixture()
def siwa(isolated_api, apple_signing_key, monkeypatch):
    key_path, public_key = apple_signing_key
    apple = _wire(isolated_api, monkeypatch, configured=True, key_path=key_path)
    return SimpleNamespace(api=isolated_api, apple=apple, public_key=public_key)


def _users_on_disk(api) -> dict:
    return json.loads((api.data_dir / "users.json").read_text())


def _seed_refresh_token(api, token: str) -> None:
    users = app.state.load_users()
    users[api.user_id]["apple_refresh_token"] = token
    app.state.save_users(users)


def _verify_apple(api, code: str | None):
    body = {"provider": "apple", "token": "identity-token-3815"}
    if code is not None:
        body["authorization_code"] = code
    return api.client.post("/auth/verify", json=body)


def _seed_user_data(api) -> tuple[Path, Path]:
    user_dir = api.data_dir / "users" / api.user_id
    user_dir.mkdir(parents=True, exist_ok=True)
    marker = user_dir / "marker.txt"
    marker.write_text("account data")
    return user_dir, marker


def _assert_client_secret(secret: str, public_key) -> None:
    header = jwt.get_unverified_header(secret)
    assert header["alg"] == "ES256"
    assert header["kid"] == KEY_ID
    claims = jwt.decode(
        secret,
        public_key,
        algorithms=["ES256"],
        audience=APPLE_AUDIENCE,
        options={"require": ["iss", "aud", "sub", "iat", "exp"]},
    )
    assert claims["iss"] == TEAM_ID
    assert claims["sub"] == CLIENT_ID
    assert claims["exp"] - claims["iat"] <= 300


def test_sign_in_with_authorization_code_stores_refresh_token(siwa):
    resp = _verify_apple(siwa.api, "code-3815-ok")
    assert resp.status_code == 200, resp.text
    assert resp.json()["user_id"] == APPLE_SUB

    exchanges = siwa.apple.calls(TOKEN_URL)
    assert len(exchanges) == 1
    form = exchanges[0]
    assert form["grant_type"] == "authorization_code"
    assert form["code"] == "code-3815-ok"
    assert form["client_id"] == CLIENT_ID
    _assert_client_secret(form["client_secret"], siwa.public_key)

    assert _users_on_disk(siwa.api)[APPLE_SUB]["apple_refresh_token"] == REFRESH_TOKEN


def test_failed_code_exchange_never_fails_sign_in(siwa, caplog):
    siwa.apple.token_status = 400
    with caplog.at_level(logging.WARNING):
        resp = _verify_apple(siwa.api, "code-3815-bad")
    assert resp.status_code == 200, resp.text
    assert resp.json()["user_id"] == APPLE_SUB
    assert len(siwa.apple.calls(TOKEN_URL)) == 1
    assert "apple_refresh_token" not in _users_on_disk(siwa.api)[APPLE_SUB]
    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert any("Apple" in message for message in warnings)
    assert "code-3815-bad" not in caplog.text


def test_account_deletion_revokes_stored_token_before_erasing_data(siwa):
    _seed_refresh_token(siwa.api, STORED_TOKEN)
    user_dir, marker = _seed_user_data(siwa.api)
    data_present_at_revoke: list[bool] = []
    siwa.apple.on_request = lambda req: (
        data_present_at_revoke.append(marker.exists()) if str(req.url) == REVOKE_URL else None
    )

    resp = siwa.api.client.delete("/api/user/account", headers=siwa.api.headers)
    assert resp.status_code == 200, resp.text

    revokes = siwa.apple.calls(REVOKE_URL)
    assert len(revokes) == 1
    form = revokes[0]
    assert form["token"] == STORED_TOKEN
    assert form["token_type_hint"] == "refresh_token"
    assert form["client_id"] == CLIENT_ID
    _assert_client_secret(form["client_secret"], siwa.public_key)
    assert data_present_at_revoke == [True]
    assert not user_dir.exists()
    assert siwa.api.user_id not in _users_on_disk(siwa.api)


def test_configured_deletion_without_stored_token_skips_revoke(siwa):
    user_dir, _ = _seed_user_data(siwa.api)

    resp = siwa.api.client.delete("/api/user/account", headers=siwa.api.headers)

    assert resp.status_code == 200, resp.text
    assert siwa.apple.calls(REVOKE_URL) == []
    assert not user_dir.exists()


def test_failed_revoke_never_blocks_deletion(siwa, caplog):
    _seed_refresh_token(siwa.api, STORED_TOKEN)
    user_dir, _ = _seed_user_data(siwa.api)
    siwa.apple.revoke_status = 500

    with caplog.at_level(logging.WARNING):
        resp = siwa.api.client.delete("/api/user/account", headers=siwa.api.headers)

    assert resp.status_code == 200, resp.text
    assert len(siwa.apple.calls(REVOKE_URL)) == 1
    assert not user_dir.exists()
    assert siwa.api.user_id not in _users_on_disk(siwa.api)
    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert any("revocation" in message for message in warnings)
    assert STORED_TOKEN not in caplog.text


def test_unconfigured_flow_makes_no_apple_calls(isolated_api, monkeypatch):
    apple = _wire(isolated_api, monkeypatch, configured=False)

    resp = _verify_apple(isolated_api, "code-3815-unconfigured")
    assert resp.status_code == 200, resp.text
    assert "apple_refresh_token" not in _users_on_disk(isolated_api)[APPLE_SUB]

    _seed_refresh_token(isolated_api, STORED_TOKEN)
    resp = isolated_api.client.delete("/api/user/account", headers=isolated_api.headers)
    assert resp.status_code == 200, resp.text

    assert apple.requests == []
    assert isolated_api.user_id not in _users_on_disk(isolated_api)


def test_load_settings_reads_siwa_env(monkeypatch):
    monkeypatch.setenv("JWT_SECRET", TEST_JWT_SECRET)
    monkeypatch.delenv("APPLE_BUNDLE_ID", raising=False)
    monkeypatch.setenv("APPLE_SIWA_TEAM_ID", TEAM_ID)
    monkeypatch.setenv("APPLE_SIWA_KEY_ID", KEY_ID)
    monkeypatch.setenv("APPLE_SIWA_PRIVATE_KEY_PATH", "/secure/AuthKey_3815.p8")

    settings = load_settings()

    assert settings.apple_siwa_team_id == TEAM_ID
    assert settings.apple_siwa_key_id == KEY_ID
    assert settings.apple_siwa_private_key_path == Path("/secure/AuthKey_3815.p8")
    assert settings.apple_bundle_id == CLIENT_ID


def test_load_settings_logs_one_info_line_when_siwa_revocation_disabled(monkeypatch, caplog):
    monkeypatch.setenv("JWT_SECRET", TEST_JWT_SECRET)
    for name in SIWA_ENV:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("APPLE_SIWA_TEAM_ID", TEAM_ID)

    with caplog.at_level(logging.INFO):
        settings = load_settings()

    assert settings.apple_siwa_key_id is None
    lines = [r for r in caplog.records if "SIWA" in r.getMessage()]
    assert len(lines) == 1
    assert lines[0].levelno == logging.INFO
    assert "disabled" in lines[0].getMessage()
    assert TEAM_ID not in lines[0].getMessage()
