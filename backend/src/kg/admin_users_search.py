"""Admin users search — uid prefix / email substring / displayName substring.

Pure function so it's trivially testable; the HTTP wrapper lives in admin_wiring.
"""

from __future__ import annotations

from typing import Any

from .admin.entitlements import is_canonical_account

DEFAULT_LIMIT = 50
MAX_LIMIT = 500


def _display_name(info: dict[str, Any]) -> str | None:
    """Pick the first non-empty display name field (supports both naming conventions)."""
    for key in ("display_name", "displayName", "name"):
        value = info.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def search_users(
    users_data: dict[str, dict[str, Any]],
    *,
    q: str = "",
    limit: int = DEFAULT_LIMIT,
) -> dict[str, Any]:
    """Filter users by uid prefix / email substring / displayName substring.

    Args:
        users_data: raw users dict from ``load_users()``.
        q: query string. Empty → return all (capped by limit).
        limit: max rows to return. Clamped to ``[1, MAX_LIMIT]``.

    Returns:
        ``{"users": [...], "total": <real_user_count>, "q": q, "limit": effective_limit}``
        where each row is ``{"user_id", "email", "display_name", "provider", "last_login"}``.
    """
    if limit < 1:
        limit = 1
    elif limit > MAX_LIMIT:
        limit = MAX_LIMIT

    # Exclude meta + underscore-prefixed keys and link pointers (not accounts).
    real: list[tuple[str, dict[str, Any]]] = [
        (uid, info) for uid, info in users_data.items() if is_canonical_account(uid, info)
    ]
    total = len(real)

    needle = (q or "").strip().lower()

    def matches(uid: str, info: dict[str, Any]) -> bool:
        if not needle:
            return True
        if uid.lower().startswith(needle):
            return True
        email = info.get("email")
        if isinstance(email, str) and needle in email.lower():
            return True
        display = _display_name(info)
        if display and needle in display.lower():
            return True
        return False

    matched = [(uid, info) for uid, info in real if matches(uid, info)]

    rows = [
        {
            "user_id": uid,
            "email": info.get("email"),
            "display_name": _display_name(info),
            "provider": info.get("provider"),
            "last_login": info.get("last_login"),
        }
        for uid, info in matched[:limit]
    ]

    return {"users": rows, "total": total, "q": q, "limit": limit}
