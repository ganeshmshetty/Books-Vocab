from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import jwt as pyjwt
import pytest
from fastapi import HTTPException

from conftest import TEST_ALGORITHM, TEST_JWT_SECRET, make_jwt, make_settings
from kg.auth_service import create_jwt_token
from kg.user_context import resolve_current_user
from kg.user_store import parse_datetime as real_parse_datetime


def _load_users_fn(users_file: Path):
    def _load():
        return json.loads(users_file.read_text())

    return _load


def _parse_datetime(value):
    if value is None:
        return None
    if isinstance(value, datetime):
        return value
    try:
        return datetime.fromisoformat(str(value))
    except (ValueError, TypeError):
        return None


def test_valid_jwt_resolves_user(tmp_path):
    users_file = tmp_path / "users.json"
    user_id = "user-abc"
    users_file.write_text(json.dumps({user_id: {"config": {}}}))

    token = make_jwt(user_id)
    settings = make_settings(tmp_path)

    result = resolve_current_user(
        token,
        settings=settings,
        load_users=_load_users_fn(users_file),
        parse_datetime=_parse_datetime,
    )
    assert result["id"] == user_id


def test_invalid_token_raises_401(tmp_path):
    users_file = tmp_path / "users.json"
    users_file.write_text(json.dumps({}))

    settings = make_settings(tmp_path)

    with pytest.raises(HTTPException) as exc_info:
        resolve_current_user(
            "not-a-jwt-token",
            settings=settings,
            load_users=_load_users_fn(users_file),
            parse_datetime=_parse_datetime,
        )

    assert exc_info.value.status_code == 401


def test_random_string_token_raises_401_not_used_as_user_id(tmp_path):
    users_file = tmp_path / "users.json"
    arbitrary_id = "some-arbitrary-user-id"
    users_file.write_text(json.dumps({arbitrary_id: {"config": {}}}))

    settings = make_settings(tmp_path)

    with pytest.raises(HTTPException) as exc_info:
        resolve_current_user(
            arbitrary_id,
            settings=settings,
            load_users=_load_users_fn(users_file),
            parse_datetime=_parse_datetime,
        )

    assert exc_info.value.status_code == 401


# ============================================================================
# Path-traversal hardening (R8#1) — `sub` flows into
# `data_dir / "users" / user_id`. A `sub` carrying `/` or `..` must be
# rejected with 401 BEFORE any directory is created, so it can never escape
# the per-user sandbox. Mirror the notebook_id allowlist
# (service_factories._resolve_notebook_paths), extended to permit the dot in
# real Apple subs (`<numeric>.<hex>.<numeric>`) while still blocking `..`.
# ============================================================================


@pytest.mark.parametrize(
    "malicious_sub",
    [
        "../etc",
        "../../etc/passwd",
        "..",
        "foo/bar",
        "/abs/path",
        "users/../../escape",
        "a/../b",
        "..\\windows",
        "with space",
        "semi;colon",
        "null\x00byte",
        "..",
    ],
)
def test_traversal_sub_rejected_and_no_dir_escapes(tmp_path, malicious_sub):
    """A JWT whose `sub` contains path-traversal characters must raise 401
    and MUST NOT create any directory outside ``data_dir/users``.
    """
    users_file = tmp_path / "users.json"
    users_file.write_text(json.dumps({malicious_sub: {"config": {}}}))
    settings = make_settings(tmp_path)

    token = make_jwt(malicious_sub)

    with pytest.raises(HTTPException) as exc_info:
        resolve_current_user(
            token,
            settings=settings,
            load_users=_load_users_fn(users_file),
            parse_datetime=_parse_datetime,
        )

    assert exc_info.value.status_code == 401
    # No directory may have escaped the sandbox: data_dir must contain only
    # the users.json we wrote plus (at most) an empty users/ dir.
    escaped = [p for p in tmp_path.rglob("*") if p.is_dir() and "users" not in p.relative_to(tmp_path).parts[:1]]
    assert not escaped, f"traversal created stray dirs: {escaped}"


@pytest.mark.parametrize(
    "legit_sub",
    [
        "001234.fedcba9876543210abcdef0123456789.1234",  # Apple opaque sub
        "117209385123456789012",  # Google numeric sub
        "user-abc",
        "user_abc",
        "ABC123",
    ],
)
def test_legitimate_provider_subs_still_resolve(tmp_path, legit_sub):
    """Real Apple (dotted) and Google (numeric) subs must continue to resolve
    so the path guard never locks out legitimate users.
    """
    users_file = tmp_path / "users.json"
    users_file.write_text(json.dumps({legit_sub: {"config": {}}}))
    settings = make_settings(tmp_path)

    token = make_jwt(legit_sub)
    result = resolve_current_user(
        token,
        settings=settings,
        load_users=_load_users_fn(users_file),
        parse_datetime=_parse_datetime,
    )
    assert result["id"] == legit_sub
    assert result["dir"] == tmp_path / "users" / legit_sub


def test_expired_jwt_raises_401(tmp_path):
    users_file = tmp_path / "users.json"
    user_id = "user-expired"
    users_file.write_text(json.dumps({user_id: {"config": {}}}))

    token = make_jwt(user_id, expires_in=timedelta(seconds=-1))
    settings = make_settings(tmp_path)

    with pytest.raises(HTTPException) as exc_info:
        resolve_current_user(
            token,
            settings=settings,
            load_users=_load_users_fn(users_file),
            parse_datetime=_parse_datetime,
        )

    assert exc_info.value.status_code == 401


def test_jwt_signed_with_wrong_secret_raises_401(tmp_path):
    users_file = tmp_path / "users.json"
    user_id = "user-forged"
    users_file.write_text(json.dumps({user_id: {"config": {}}}))

    forged_token = pyjwt.encode(
        {"sub": user_id, "exp": datetime.now(tz=UTC) + timedelta(hours=1)},
        "wrong-secret-key-totally-different",
        algorithm=TEST_ALGORITHM,
    )
    settings = make_settings(tmp_path)

    with pytest.raises(HTTPException) as exc_info:
        resolve_current_user(
            forged_token,
            settings=settings,
            load_users=_load_users_fn(users_file),
            parse_datetime=_parse_datetime,
        )

    assert exc_info.value.status_code == 401


# ============================================================================
# Revocation watermark — sub-second precision (PR #539 regression / fix)
#
# JWT `iat` is encoded as an integer Unix timestamp (floored to whole seconds).
# `_revoked_before[uid]` is stored with microsecond precision. When deletion +
# re-login happen in the SAME wall-clock second, the brand-new login JWT must
# still be admitted, while any token issued BEFORE the deletion must remain
# rejected. `iat` alone cannot distinguish them (both floor to the same
# second), so `create_jwt_token` carries a microsecond-precision claim.
# ============================================================================


def _issue_token_at(user_id: str, moment: datetime, monkeypatch) -> str:
    """Issue a JWT through the real `create_jwt_token` path with `now` pinned
    to `moment`, so `iat` (and any sub-second claim) is deterministic.
    """

    class _FrozenDatetime(datetime):
        @classmethod
        def now(cls, tz=None):
            return moment if tz else moment.replace(tzinfo=None)

    monkeypatch.setattr("kg.auth_service.datetime", _FrozenDatetime)
    return create_jwt_token(
        user_id,
        "google",
        jwt_secret=TEST_JWT_SECRET,
        jwt_algorithm=TEST_ALGORITHM,
        jwt_expiry_minutes=60,
    )


def test_same_second_delete_then_relogin_token_is_admitted(tmp_path, monkeypatch):
    """Account deleted at t=X.230115; new login JWT issued at t=X.800000.

    Both fall in the same wall-clock second, so the JWT `iat` floors to
    X.000000. The brand-new session is legitimate and must be admitted.

    The base second tracks real `now` (so `exp`/`iat` stay valid against the
    decoder's wall clock) while the microseconds are pinned, which is all the
    floor/precision behaviour under test depends on.
    """
    user_id = "user-relogin"
    users_file = tmp_path / "users.json"
    settings = make_settings(tmp_path)

    base = datetime.now(tz=UTC).replace(microsecond=0)

    # Watermark written at deletion time t=X.230115 (microsecond precision).
    deleted_at = base.replace(microsecond=230115)
    users_file.write_text(
        json.dumps(
            {
                user_id: {"config": {}},
                "_revoked_before": {user_id: deleted_at.isoformat()},
            }
        )
    )

    # Brand-new login JWT issued at t=X.800000 — 0.57s AFTER deletion but in
    # the SAME wall-clock second. create_jwt_token is the single issuance path.
    new_token = _issue_token_at(user_id, base.replace(microsecond=800000), monkeypatch)

    # The freshly minted, legitimate token must be admitted.
    result = resolve_current_user(
        new_token,
        settings=settings,
        load_users=_load_users_fn(users_file),
        parse_datetime=real_parse_datetime,
    )
    assert result["id"] == user_id


def test_token_issued_before_deletion_same_second_is_rejected(tmp_path, monkeypatch):
    """Invariant guard: a token issued BEFORE the deletion, even in the same
    wall-clock second as the deletion, must still be rejected.
    """
    user_id = "user-stale"
    users_file = tmp_path / "users.json"
    settings = make_settings(tmp_path)

    base = datetime.now(tz=UTC).replace(microsecond=0)

    # Old token issued first at t=X.100000.
    old_token = _issue_token_at(user_id, base.replace(microsecond=100000), monkeypatch)

    # Deletion happens AFTER issuance at t=X.600000, still in the same second.
    deleted_at = base.replace(microsecond=600000)
    users_file.write_text(
        json.dumps(
            {
                user_id: {"config": {}},
                "_revoked_before": {user_id: deleted_at.isoformat()},
            }
        )
    )

    with pytest.raises(HTTPException) as exc_info:
        resolve_current_user(
            old_token,
            settings=settings,
            load_users=_load_users_fn(users_file),
            parse_datetime=real_parse_datetime,
        )
    assert exc_info.value.status_code == 401
    assert "deleted" in str(exc_info.value.detail).lower()


def test_operator_deleted_user_old_token_rejected_and_dir_not_recreated(tmp_path, monkeypatch):
    """#2709: ops-edit user-delete must revoke outstanding JWTs, not just drop the record."""
    import argparse

    import kg.ops_edit_user_commands as user_cmd

    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
    settings = make_settings(tmp_path)
    ns = dict(
        uid="doomed",
        commit=True,
        json=True,
        provider="google",
        email="d@x.com",
        allow_existing=False,
        reassign_email=False,
    )
    user_cmd.cmd_user_create(argparse.Namespace(**ns))
    token = create_jwt_token(
        "doomed", "google", jwt_secret=TEST_JWT_SECRET, jwt_algorithm=TEST_ALGORITHM, jwt_expiry_minutes=60
    )
    user_cmd.cmd_user_delete(argparse.Namespace(**ns))

    with pytest.raises(HTTPException) as exc:
        resolve_current_user(
            token,
            settings=settings,
            load_users=_load_users_fn(tmp_path / "users.json"),
            parse_datetime=real_parse_datetime,
        )
    assert exc.value.status_code == 401
    assert not (tmp_path / "users" / "doomed").exists()


# ============================================================================
# #3813: the client must tell a deleted-account 401 apart from an expired or
# invalid-token 401. Only the revoked-account 401 carries the machine-readable
# `X-KG-Auth-Error: account_deleted` header; the iOS DELETE handler treats that
# code (and only that code) as delete success.
# ============================================================================


def test_expired_token_401_has_no_account_deleted_code(tmp_path):
    users_file = tmp_path / "users.json"
    user_id = "user-expired-3813"
    users_file.write_text(json.dumps({user_id: {"config": {}}}))
    token = make_jwt(user_id, expires_in=timedelta(seconds=-1))

    with pytest.raises(HTTPException) as exc_info:
        resolve_current_user(
            token,
            settings=make_settings(tmp_path),
            load_users=_load_users_fn(users_file),
            parse_datetime=_parse_datetime,
        )

    assert exc_info.value.status_code == 401
    assert exc_info.value.detail == "Token has expired"
    assert "X-KG-Auth-Error" not in (exc_info.value.headers or {})


def test_revoked_account_401_carries_account_deleted_code(tmp_path):
    users_file = tmp_path / "users.json"
    user_id = "user-revoked-3813"
    revoked_at = datetime.now(tz=UTC) + timedelta(hours=1)
    users_file.write_text(
        json.dumps(
            {
                "_revoked_before": {user_id: revoked_at.isoformat()},
                user_id: {"config": {}},
            }
        )
    )
    token = make_jwt(user_id)

    with pytest.raises(HTTPException) as exc_info:
        resolve_current_user(
            token,
            settings=make_settings(tmp_path),
            load_users=_load_users_fn(users_file),
            parse_datetime=_parse_datetime,
        )

    assert exc_info.value.status_code == 401
    assert exc_info.value.detail == "Account was deleted. Please sign in again."
    assert exc_info.value.headers["X-KG-Auth-Error"] == "account_deleted"
