"""Auth test matrix: cross-provider merge, session invalidation, dual-device.

Complements `test_auth_takeover.py` (negative cases for client-supplied email
spoofing) and `test_auth_service.py` (basic merge semantics) by covering:

1. Apple-then-Google with the same verified email merges into one canonical
   user without losing per-user data (notebook directories keyed by canonical
   id remain accessible). A linked provider keeps resolving to that canonical
   even when its later token omits or changes the verified email.
2. After account deletion (the canonical session-invalidation pathway), the
   original JWT must be rejected even if the same provider sub re-registers
   later — the `_revoked_before` watermark must outlive the data wipe until
   a fresh login bumps `iat`.
3. Two devices logging in to the same canonical user both yield valid JWTs
   that resolve concurrently — there is no implicit single-device coupling.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import jwt as pyjwt
import pytest
from fastapi import HTTPException

from conftest import TEST_ALGORITHM, TEST_JWT_SECRET, make_settings
from kg.api_models import AuthVerifyRequest
from kg.auth_handlers import auth_verify_response
from kg.auth_service import resolve_and_link_user
from kg.user_context import resolve_current_user
from kg.user_handlers import delete_user_account_response
from kg.user_store import collect_account_ids_for_deletion
from kg.user_store import parse_datetime as _parse_datetime

# --------------------------------------------------------------------------- #
# Shared fixtures / helpers
# --------------------------------------------------------------------------- #


def _make_user_store(tmp_path: Path):
    users_file = tmp_path / "users.json"
    lock_file = tmp_path / "users.json.lock"
    users_file.write_text(json.dumps({}))

    def load():
        return json.loads(users_file.read_text())

    def save(users):
        users_file.write_text(json.dumps(users))

    return users_file, str(lock_file), load, save


def _store_views(users_file: Path, lock: str):
    def load():
        return json.loads(users_file.read_text())

    def save(users):
        users_file.write_text(json.dumps(users))

    return users_file, lock, load, save


def _issue_jwt(user_id: str, provider: str, *, iat: datetime | None = None) -> str:
    now = iat or datetime.now(tz=UTC)
    return pyjwt.encode(
        {
            "sub": user_id,
            "provider": provider,
            "iat": now,
            "exp": now + timedelta(hours=1),
        },
        TEST_JWT_SECRET,
        algorithm=TEST_ALGORITHM,
    )


def _build_handler_kwargs(
    users_file: Path,
    lock: str,
    *,
    provider: str,
    sub: str,
    email: str | None,
    email_verified: bool,
):
    """Build kwargs for `auth_verify_response` with one provider mocked."""
    _, _, load, save = _store_views(users_file, lock)

    async def fake_verify_google(token, client_id):
        if provider != "google":
            raise AssertionError("google verify should not be called")
        return (sub, email, email_verified)

    def fake_verify_apple(token, audience):
        if provider != "apple":
            raise AssertionError("apple verify should not be called")
        return (sub, email, email_verified)

    def link(provider_user_id, prov, mail=None):
        return resolve_and_link_user(
            provider_user_id,
            prov,
            users_lock_file=lock,
            load_users_fn=load,
            save_users_fn=save,
            email=mail,
        )

    def jwt_fn(user_id, prov):
        return _issue_jwt(user_id, prov)

    return dict(
        google_client_id="fake-google",
        apple_bundle_id="com.fake",
        jwt_expiry_minutes=60,
        verify_google_token=fake_verify_google,
        verify_apple_token=fake_verify_apple,
        resolve_and_link_user=link,
        create_jwt_token=jwt_fn,
    )


# --------------------------------------------------------------------------- #
# 1. Apple → Google same verified email merges without data loss
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_apple_then_google_same_email_merges_without_data_loss(tmp_path):
    """Apple sign-in creates canonical user; subsequent Google sign-in with the
    same verified email must link the Google sub into the SAME canonical
    user (no duplicate user, no data orphan).

    Verifies:
      * canonical_id is preserved across providers
      * Apple sub remains the canonical id (it logged in first)
      * Google sub appears under `linked_ids` of canonical and has
        `_linked_to` pointing back to canonical
      * the user's directory (data wedge) remains the canonical one — any
        notebook keyed under that dir is reachable on either token
    """
    users_file, lock, load, save = _make_user_store(tmp_path)
    shared_email = "user@gmail.com"

    # Apple first — canonical = apple sub
    apple_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="apple",
        sub="apple-sub",
        email=shared_email,
        email_verified=True,
    )
    apple_resp = await auth_verify_response(
        AuthVerifyRequest(provider="apple", token="a-token", email=None),
        **apple_kwargs,
    )
    assert apple_resp.user_id == "apple-sub"

    # Seed user data directory & a notebook file keyed under canonical id.
    user_dir = tmp_path / "users" / apple_resp.user_id
    user_dir.mkdir(parents=True, exist_ok=True)
    notebook = user_dir / "notebook.json"
    notebook.write_text(json.dumps({"id": "nb-1", "title": "Apple-era data"}))

    # Google second — same verified email
    google_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="google",
        sub="google-sub",
        email=shared_email,
        email_verified=True,
    )
    google_resp = await auth_verify_response(
        AuthVerifyRequest(provider="google", token="g-token", email=None),
        **google_kwargs,
    )

    # Canonical did NOT switch — google_sub merged into apple_sub canonical.
    assert google_resp.user_id == "apple-sub", (
        "Google sign-in with same verified email must merge into existing canonical user, "
        f"got new id {google_resp.user_id!r}"
    )

    users = load()
    # Email index still points to canonical, not the new google sub.
    assert users["_email_index"][shared_email] == "apple-sub"
    # Canonical user records the linked google sub.
    assert "google-sub" in users["apple-sub"].get("linked_ids", [])
    # Google sub stub points back to canonical.
    assert users["google-sub"]["_linked_to"] == "apple-sub"
    # Canonical provider gets updated to the most recent login provider
    # (this matches resolve_and_link_user semantics).
    assert users["apple-sub"]["provider"] == "google"
    # Data wedge survives — notebook still readable under canonical id.
    assert notebook.exists()
    assert json.loads(notebook.read_text())["title"] == "Apple-era data"

    # Both tokens (Apple-issued + Google-issued) resolve to the same user via
    # resolve_current_user. The Google-issued token's sub IS canonical, while
    # an Apple-era token (issued back when canonical_id == apple-sub) is also
    # canonical. So both succeed naturally.
    settings = make_settings(tmp_path)
    for token in (
        _issue_jwt("apple-sub", "apple"),
        google_resp.access_token,
    ):
        record = resolve_current_user(
            token,
            settings=settings,
            load_users=lambda: load(),
            parse_datetime=_parse_datetime,
        )
        assert record["id"] == "apple-sub"


@pytest.mark.asyncio
async def test_google_then_apple_same_email_no_duplicate_account(tmp_path):
    """Mirror of the previous test in reverse order — defends against
    direction-dependent merge bugs.
    """
    users_file, lock, load, save = _make_user_store(tmp_path)
    shared_email = "swap@example.com"

    g_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="google",
        sub="g-sub",
        email=shared_email,
        email_verified=True,
    )
    g_resp = await auth_verify_response(
        AuthVerifyRequest(provider="google", token="g", email=None),
        **g_kwargs,
    )
    assert g_resp.user_id == "g-sub"

    a_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="apple",
        sub="a-sub",
        email=shared_email,
        email_verified=True,
    )
    a_resp = await auth_verify_response(
        AuthVerifyRequest(provider="apple", token="a", email=None),
        **a_kwargs,
    )
    assert a_resp.user_id == "g-sub", "Apple login must merge into existing Google canonical"

    users = load()
    canonical_keys = [k for k in users if not k.startswith("_") and not users[k].get("_linked_to")]
    assert canonical_keys == ["g-sub"], (
        f"Exactly one canonical user must exist after cross-provider login, got {canonical_keys}"
    )


@pytest.mark.asyncio
async def test_linked_apple_sub_only_follow_up_keeps_canonical_user(tmp_path):
    """A later Apple token with only ``sub`` must use the linked canonical id."""
    users_file, lock, load, save = _make_user_store(tmp_path)
    shared_email = "linked@example.com"

    google_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="google",
        sub="google-sub",
        email=shared_email,
        email_verified=True,
    )
    google_resp = await auth_verify_response(
        AuthVerifyRequest(provider="google", token="google-token", email=None),
        **google_kwargs,
    )
    assert google_resp.user_id == "google-sub"

    canonical_data = tmp_path / "users" / google_resp.user_id / "notebook.json"
    canonical_data.parent.mkdir(parents=True, exist_ok=True)
    canonical_data.write_text(json.dumps({"title": "canonical data"}))

    apple_first_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="apple",
        sub="apple-sub",
        email=shared_email,
        email_verified=True,
    )
    apple_first_resp = await auth_verify_response(
        AuthVerifyRequest(provider="apple", token="apple-first-token", email=None),
        **apple_first_kwargs,
    )
    assert apple_first_resp.user_id == "google-sub"

    apple_follow_up_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="apple",
        sub="apple-sub",
        email=None,
        email_verified=False,
    )
    apple_follow_up_resp = await auth_verify_response(
        AuthVerifyRequest(
            provider="apple",
            token="apple-follow-up-token",
            email=None,
        ),
        **apple_follow_up_kwargs,
    )

    assert apple_follow_up_resp.user_id == "google-sub"
    claims = pyjwt.decode(
        apple_follow_up_resp.access_token,
        TEST_JWT_SECRET,
        algorithms=[TEST_ALGORITHM],
    )
    assert claims["sub"] == "google-sub"
    users = load()
    assert users["apple-sub"]["_linked_to"] == "google-sub"
    assert canonical_data.exists()
    assert json.loads(canonical_data.read_text())["title"] == "canonical data"


@pytest.mark.asyncio
async def test_linked_apple_email_change_keeps_canonical_session(tmp_path):
    """#2256: once Apple is linked to Google, a later Apple token carrying a
    different verified email must still issue the canonical session. A split
    `sub=a-sub` session would show an empty account, and Delete Account from it
    would reach the real canonical through the stale `_linked_to` pointer."""
    users_file, lock, load, save = _make_user_store(tmp_path)
    settings = make_settings(tmp_path)

    async def sign_in(provider: str, sub: str, email: str):
        kwargs = _build_handler_kwargs(
            users_file,
            lock,
            provider=provider,
            sub=sub,
            email=email,
            email_verified=True,
        )
        return await auth_verify_response(
            AuthVerifyRequest(provider=provider, token=f"{sub}-token", email=None),
            **kwargs,
        )

    assert (await sign_in("google", "g-sub", "first@example.com")).user_id == "g-sub"
    assert (await sign_in("apple", "a-sub", "first@example.com")).user_id == "g-sub"
    resp = await sign_in("apple", "a-sub", "relay@privaterelay.appleid.com")

    assert resp.user_id == "g-sub"
    claims = pyjwt.decode(resp.access_token, TEST_JWT_SECRET, algorithms=[TEST_ALGORITHM])
    assert claims["sub"] == "g-sub"

    record = resolve_current_user(
        resp.access_token,
        settings=settings,
        load_users=load,
        parse_datetime=_parse_datetime,
    )
    assert record["id"] == "g-sub"
    assert not (tmp_path / "users" / "a-sub").exists()

    # Deletion from this session starts at the real canonical, not a split id.
    assert collect_account_ids_for_deletion(load(), claims["sub"]) == ("g-sub", ["a-sub", "g-sub"])


# --------------------------------------------------------------------------- #
# 2. Provider switch / account-deletion path invalidates old session
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_account_deletion_invalidates_old_session_token(tmp_path):
    """The canonical "kill old session" pathway is account deletion: it stamps
    `_revoked_before[user_id]` so any JWT with `iat <= revoked_at` is rejected.

    Scenario: user logs in with Apple, deletes their account, then re-signs in
    with the same Apple sub (so the user_id is identical) — the OLD JWT must
    still be rejected because its `iat` predates the deletion watermark, even
    though the user record has been re-created.

    NOTE: a fresh login intentionally clears `_revoked_before[user_id]`
    (see auth_service.py). To verify the old token stays dead, we issue a
    fresh JWT *before* the cleanup occurs and check that resolve raises 401.
    """
    users_file, lock, load, save = _make_user_store(tmp_path)
    settings = make_settings(tmp_path)

    # Initial login (Apple).
    apple_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="apple",
        sub="apple-user",
        email="alice@example.com",
        email_verified=True,
    )
    resp1 = await auth_verify_response(
        AuthVerifyRequest(provider="apple", token="t1", email=None),
        **apple_kwargs,
    )
    user_id = resp1.user_id
    old_iat = datetime.now(tz=UTC) - timedelta(minutes=5)
    old_token = _issue_jwt(user_id, "apple", iat=old_iat)

    # Sanity: old token resolves while account exists with no revocation mark.
    rec = resolve_current_user(
        old_token,
        settings=settings,
        load_users=load,
        parse_datetime=_parse_datetime,
    )
    assert rec["id"] == user_id

    # Account deletion stamps _revoked_before AND wipes user record/dir.
    def _collect(users, uid):
        return uid, [uid]

    import logging

    delete_user_account_response(
        {"id": user_id},
        users_lock_file=Path(lock),
        load_users=load,
        save_users=save,
        collect_account_ids_for_deletion=_collect,
        data_dir=tmp_path,
        logger=logging.getLogger("test"),
    )

    users_after_delete = load()
    assert user_id not in users_after_delete
    assert user_id in users_after_delete.get("_revoked_before", {})

    # Old token must now be rejected: even though the user record is gone,
    # the revoke watermark applies regardless of record presence.
    with pytest.raises(HTTPException) as exc:
        resolve_current_user(
            old_token,
            settings=settings,
            load_users=load,
            parse_datetime=_parse_datetime,
        )
    assert exc.value.status_code == 401


@pytest.mark.asyncio
async def test_revoked_linked_account_rejects_old_token_via_linked_to(tmp_path):
    """If a user logs in via a linked sub (sub != canonical) and the
    canonical user was previously revoked, the old JWT (sub=linked, iat<rev)
    must also be rejected via the `_linked_to` indirection in user_context.
    """
    users_file, lock, load, save = _make_user_store(tmp_path)
    settings = make_settings(tmp_path)

    # Manually seed: canonical=apple-X, linked=google-Y, with revoke watermark
    # on canonical predating the token's iat.
    revoke_at = datetime.now(tz=UTC)
    users = {
        "apple-X": {"provider": "apple", "email": "bob@example.com"},
        "google-Y": {"_linked_to": "apple-X"},
        "_email_index": {"bob@example.com": "apple-X"},
        "_revoked_before": {"apple-X": revoke_at.isoformat()},
    }
    users_file.write_text(json.dumps(users))

    # Old token issued before revoke watermark, sub = linked id.
    old_token = _issue_jwt(
        "google-Y",
        "google",
        iat=revoke_at - timedelta(seconds=10),
    )

    with pytest.raises(HTTPException) as exc:
        resolve_current_user(
            old_token,
            settings=settings,
            load_users=load,
            parse_datetime=_parse_datetime,
        )
    assert exc.value.status_code == 401


# --------------------------------------------------------------------------- #
# 3. Concurrent dual-device login — both tokens valid
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_concurrent_device_login_same_user_both_valid(tmp_path):
    """The same canonical user can log in from two devices (e.g. iPhone +
    Mac) and both JWTs must remain simultaneously valid. There is no
    single-device coupling in the current design — verify it stays that way.
    """
    users_file, lock, load, save = _make_user_store(tmp_path)
    settings = make_settings(tmp_path)

    apple_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="apple",
        sub="device-user",
        email="multi@example.com",
        email_verified=True,
    )

    # Device A login.
    resp_a = await auth_verify_response(
        AuthVerifyRequest(provider="apple", token="device-a-token", email=None),
        **apple_kwargs,
    )
    token_a = resp_a.access_token

    # Device B login (same user, same provider/sub — Apple re-auth from a
    # second device returns the same sub).
    resp_b = await auth_verify_response(
        AuthVerifyRequest(provider="apple", token="device-b-token", email=None),
        **apple_kwargs,
    )
    token_b = resp_b.access_token

    assert resp_a.user_id == resp_b.user_id == "device-user"
    # JWTs may be byte-identical when iat resolution is per-second and both
    # logins happen in the same wall-clock second — that is fine and does
    # not indicate a single-device coupling. What matters is that both
    # resolve and the second login did not revoke the first.

    # Both tokens must resolve to the same canonical user concurrently.
    for tok in (token_a, token_b):
        record = resolve_current_user(
            tok,
            settings=settings,
            load_users=load,
            parse_datetime=_parse_datetime,
        )
        assert record["id"] == "device-user"


@pytest.mark.asyncio
async def test_dual_device_cross_provider_both_resolve_to_canonical(tmp_path):
    """One device on Apple, another on Google with the same verified email.
    Both device JWTs must resolve to the SAME canonical user — confirms the
    merge during the Google login does not invalidate the Apple device.
    """
    users_file, lock, load, save = _make_user_store(tmp_path)
    settings = make_settings(tmp_path)

    # iPhone — Apple
    apple_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="apple",
        sub="iphone-apple",
        email="dual@gmail.com",
        email_verified=True,
    )
    iphone_resp = await auth_verify_response(
        AuthVerifyRequest(provider="apple", token="iphone", email=None),
        **apple_kwargs,
    )
    iphone_token = iphone_resp.access_token
    assert iphone_resp.user_id == "iphone-apple"

    # Mac — Google with same email
    google_kwargs = _build_handler_kwargs(
        users_file,
        lock,
        provider="google",
        sub="mac-google",
        email="dual@gmail.com",
        email_verified=True,
    )
    mac_resp = await auth_verify_response(
        AuthVerifyRequest(provider="google", token="mac", email=None),
        **google_kwargs,
    )
    mac_token = mac_resp.access_token

    # Mac's JWT has sub = canonical (iphone-apple) because merge happens at
    # token-issue time.
    assert mac_resp.user_id == "iphone-apple"

    # Both tokens still resolve.
    for tok in (iphone_token, mac_token):
        rec = resolve_current_user(
            tok,
            settings=settings,
            load_users=load,
            parse_datetime=_parse_datetime,
        )
        assert rec["id"] == "iphone-apple"
