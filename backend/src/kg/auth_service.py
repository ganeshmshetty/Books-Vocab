from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, datetime, timedelta

import jwt

from .types import UsersPayload
from .users_lock import users_file_lock


def create_jwt_token(
    user_id: str,
    provider: str,
    *,
    jwt_secret: str,
    jwt_algorithm: str,
    jwt_expiry_minutes: int,
) -> str:
    now = datetime.now(tz=UTC)
    expires = now + timedelta(minutes=jwt_expiry_minutes)

    payload = {
        "sub": user_id,
        "provider": provider,
        "iat": now,
        "exp": expires,
        # Standard `iat` is encoded as an integer Unix timestamp (floored to
        # whole seconds), so it cannot tell apart a token issued just before
        # vs. just after an account deletion that landed in the same second.
        # `iat_us` carries the microsecond-precise issuance instant; the
        # revocation-watermark check (user_context.resolve_current_user)
        # prefers it so a fresh post-deletion login JWT is not falsely
        # rejected by a same-second deletion watermark.
        "iat_us": now.isoformat(),
    }
    return jwt.encode(payload, jwt_secret, algorithm=jwt_algorithm)


_GOOGLE_CONSUMER_DOMAINS = frozenset({"gmail.com", "googlemail.com"})


def _email_is_authoritative(provider: str, email: str, hd: str | None) -> bool:
    """Whether ``provider`` is the authority for the (already verified) ``email``.

    Apple verifies every address it reports. Google only owns consumer
    addresses and addresses of a Workspace domain whose ``hd`` claim matches;
    for any other domain ``email_verified`` records a past check, not current
    control of the mailbox.
    """
    if provider == "apple":
        return True
    if provider == "google":
        domain = email.rpartition("@")[2]
        return domain in _GOOGLE_CONSUMER_DOMAINS or (bool(hd) and hd == domain)
    return False


def resolve_and_link_user(
    provider_user_id: str,
    provider: str,
    *,
    users_lock_file: str,
    load_users_fn: Callable[[], UsersPayload],
    save_users_fn: Callable[[UsersPayload], None],
    email: str | None = None,
    hd: str | None = None,
) -> str:
    with users_file_lock(users_lock_file):
        users = load_users_fn()

        if "_email_index" not in users:
            users["_email_index"] = {}

        canonical_id = None
        now = datetime.now(tz=UTC).isoformat()
        existing_user = users.get(provider_user_id)
        linked_canonical_id = existing_user.get("_linked_to") if isinstance(existing_user, dict) else None
        has_valid_link = (
            isinstance(linked_canonical_id, str)
            and linked_canonical_id != provider_user_id
            and not linked_canonical_id.startswith("_")
            and isinstance(users.get(linked_canonical_id), dict)
        )
        # Email written onto the canonical record. None means "keep what is
        # stored", exactly like Apple's email-less follow-up sign-ins.
        profile_email = email

        if has_valid_link:
            # A linked provider id always resolves to its canonical, whatever
            # its token's verified email is now (#1185 omitted email, #2256
            # changed email). Splitting off `provider_user_id` would issue a
            # session whose account deletion reaches the canonical through
            # this `_linked_to` pointer.
            canonical_id = linked_canonical_id
            if email:
                email_owner = users["_email_index"].get(email)
                if email_owner is None or email_owner == provider_user_id:
                    # Unindexed, or still indexed to this linked id (its own
                    # pre-merge email, or a split left by #2256): an alias of
                    # the canonical.
                    users["_email_index"][email] = canonical_id
                elif email_owner != canonical_id:
                    # Owned by a different canonical: never re-link or move the
                    # index silently, and never copy that account's email here.
                    profile_email = None
        elif email and email in users["_email_index"] and not _email_is_authoritative(provider, email, hd):
            # The provider cannot vouch for this address, so it never selects
            # an existing account. The id gets its own canonical account and
            # the index keeps pointing at the address's current owner.
            canonical_id = provider_user_id
            if canonical_id not in users:
                users[canonical_id] = {}
            if users["_email_index"][email] != canonical_id:
                profile_email = None
        elif email and email in users["_email_index"]:
            canonical_id = users["_email_index"][email]

            if canonical_id != provider_user_id:
                if "linked_ids" not in users[canonical_id]:
                    users[canonical_id]["linked_ids"] = []

                if provider_user_id not in users[canonical_id]["linked_ids"]:
                    users[canonical_id]["linked_ids"].append(provider_user_id)

                if provider_user_id not in users:
                    users[provider_user_id] = {}
                users[provider_user_id]["_linked_to"] = canonical_id
        else:
            canonical_id = provider_user_id
            if canonical_id not in users:
                users[canonical_id] = {}
            if email:
                users["_email_index"][email] = canonical_id

        if canonical_id not in users:
            users[canonical_id] = {}

        if canonical_id == provider_user_id:
            # This id is its own canonical, so any `_linked_to` left on it is
            # invalid (has_valid_link was false). Drop it: deletion from this
            # session must not fan out through a pointer login ignored.
            users[canonical_id].pop("_linked_to", None)

        users[canonical_id]["provider"] = provider
        # Apple omits email on follow-up sign-ins. Preserve the verified
        # canonical email instead of erasing it with that expected omission.
        if profile_email is not None or "email" not in users[canonical_id]:
            users[canonical_id]["email"] = profile_email
        users[canonical_id]["last_login"] = now

        # Clear stale revocation watermarks on a fresh login so the dict does
        # not grow unbounded. But account-deletion watermarks are PERMANENT:
        # ids recorded in `_terminated` must never be popped, otherwise a JWT
        # issued before the deletion would be revived by simply logging in
        # again (same sub, or same email via a different provider).
        revoked_before = users.get("_revoked_before")
        if isinstance(revoked_before, dict):
            terminated = users.get("_terminated")
            terminated_ids = set(terminated) if isinstance(terminated, list) else set()
            for uid in (canonical_id, provider_user_id):
                if uid not in terminated_ids:
                    revoked_before.pop(uid, None)
            if not revoked_before:
                users.pop("_revoked_before", None)

        save_users_fn(users)
        return canonical_id
