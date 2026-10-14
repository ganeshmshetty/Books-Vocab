"""Shared types for OAuth/JWT token verification."""

from typing import NamedTuple


class VerifiedIdentity(NamedTuple):
    sub: str
    email: str | None
    email_verified: bool


class GoogleIdentity(VerifiedIdentity):
    """``VerifiedIdentity`` plus the Google Workspace hosted-domain claim.

    Still a plain ``(sub, email, email_verified)`` tuple for callers that only
    unpack those three; ``hd`` rides along as an attribute.
    """

    hd: str | None

    def __new__(cls, sub: str, email: str | None, email_verified: bool, hd: str | None = None):
        self = super().__new__(cls, sub, email, email_verified)
        self.hd = hd
        return self


def hosted_domain(identity: VerifiedIdentity | GoogleIdentity) -> str | None:
    """Workspace hosted domain of ``identity``; None for providers without one."""
    return getattr(identity, "hd", None)
