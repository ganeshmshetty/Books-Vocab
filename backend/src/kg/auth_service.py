from __future__ import annotations

import logging
from collections.abc import Callable
from datetime import UTC, datetime, timedelta

import jwt

from .types import UsersPayload
from .users_lock import users_file_lock

logger = logging.getLogger(__name__)


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
# Domains whose mailboxes Apple provisions itself (iCloud Mail, the private
# relay) plus the consumer domains it also checks against the issuing provider.
_APPLE_AUTHORITATIVE_DOMAINS = frozenset(
    {"icloud.com", "me.com", "mac.com", "privaterelay.appleid.com"} | _GOOGLE_CONSUMER_DOMAINS
)


def _email_is_authoritative(provider: str, email: str, hd: str | None) -> bool:
    """Whether ``provider`` is the authority for the (already verified) ``email``.

    Only authoritative addresses are written to or looked up in
    ``_email_index``; a provider's ``email_verified`` flag elsewhere records a
    past check, not current control of the mailbox. Google owns consumer
    addresses and addresses of a Workspace domain whose ``hd`` claim matches;
    Apple owns its own domains. Unknown providers and malformed addresses are
    never authoritative.
    """
    local, _, domain = email.rpartition("@")
    domain = domain.lower()
    if not local or not domain:
        return False
    if provider == "apple":
        return domain in _APPLE_AUTHORITATIVE_DOMAINS
    if provider == "google":
        return domain in _GOOGLE_CONSUMER_DOMAINS or (bool(hd) and hd.lower() == domain)
    return False


def _is_independent_account(record: object) -> bool:
    """A user record holding real account state (anything beyond a bare link pointer)."""
    return isinstance(record, dict) and any(key != "_linked_to" for key in record)


def _indexed_owner(users: UsersPayload, email: str | None) -> str | None:
    """Account an address is indexed to, ignoring entries whose account no longer exists."""
    owner = users["_email_index"].get(email) if email else None
    if isinstance(owner, str) and not owner.startswith("_") and isinstance(users.get(owner), dict):
        return owner
    return None


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
        # Only an address this provider is the authority for takes part in
        # linking: it is the only kind that is indexed or looked up.
        link_email = email if email and _email_is_authoritative(provider, email, hd) else None
        email_owner = _indexed_owner(users, link_email)

        if has_valid_link:
            # A linked provider id always resolves to its canonical, whatever
            # its token's verified email is now (#1185 omitted email, #2256
            # changed email). Splitting off `provider_user_id` would issue a
            # session whose account deletion reaches the canonical through
            # this `_linked_to` pointer.
            canonical_id = linked_canonical_id
            if link_email and (email_owner is None or email_owner == provider_user_id):
                # Unindexed, or still indexed to this linked id (its own
                # pre-merge email, or a split left by #2256): an alias of the
                # canonical. An address owned by a different canonical is
                # never re-pointed, and earlier entries are left as they are.
                users["_email_index"][link_email] = canonical_id
        elif (
            link_email
            and email_owner is not None
            and email_owner != provider_user_id
            and _is_independent_account(existing_user)
        ):
            # This id already is an independent account with its own data and
            # subscription: it is not re-pointed at the address's owner, it
            # keeps resolving to itself and the index keeps its owner.
            canonical_id = provider_user_id
            logger.warning(
                "auth: existing account %s signed in with an email indexed to %s; not linking (merge manually)",
                provider_user_id,
                email_owner,
            )
        elif link_email and email_owner is not None:
            canonical_id = email_owner

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
            if link_email:
                users["_email_index"][link_email] = canonical_id

        if canonical_id not in users:
            users[canonical_id] = {}

        if canonical_id == provider_user_id:
            # This id is its own canonical, so any `_linked_to` left on it is
            # invalid (has_valid_link was false). Drop it: deletion from this
            # session must not fan out through a pointer login ignored.
            users[canonical_id].pop("_linked_to", None)

        # Never copy an address indexed to another account onto this record.
        if profile_email and _indexed_owner(users, profile_email) not in (None, canonical_id, provider_user_id):
            profile_email = None

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
