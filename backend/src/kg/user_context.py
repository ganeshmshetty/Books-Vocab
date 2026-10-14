from __future__ import annotations

import re
from collections.abc import Callable
from datetime import UTC, datetime

import jwt
from fastapi import HTTPException

from .settings import KGSettings
from .types import UserRecord, UsersPayload

# `user_id` is the JWT `sub`, which is later joined into a filesystem path
# (`data_dir / "users" / user_id`). It MUST be constrained to a path-safe
# allowlist so a crafted `sub` cannot escape the per-user sandbox via `/` or
# `..`. This mirrors the notebook_id allowlist in
# `service_factories._resolve_notebook_paths`, extended with `.` because real
# Apple subs are dotted (`<numeric>.<hex>.<numeric>`); Google subs are numeric.
# `..` is rejected separately since `.` is now an allowed character.
_USER_ID_ALLOWED = re.compile(r"^[a-zA-Z0-9_.-]+$")

# #3813: machine-readable marker on the revoked-account 401 only. Expired or
# invalid-token 401s omit it, so the iOS client can tell "account was deleted"
# (erase is safe) from a plain session failure (must not erase).
ACCOUNT_DELETED_AUTH_HEADER = "X-KG-Auth-Error"
ACCOUNT_DELETED_AUTH_CODE = "account_deleted"


def _account_deleted_401() -> HTTPException:
    return HTTPException(
        status_code=401,
        detail="Account was deleted. Please sign in again.",
        headers={
            "WWW-Authenticate": "Bearer",
            ACCOUNT_DELETED_AUTH_HEADER: ACCOUNT_DELETED_AUTH_CODE,
        },
    )


def resolve_current_user(
    token: str,
    *,
    settings: KGSettings,
    load_users: Callable[[], UsersPayload],
    parse_datetime: Callable[[object], datetime | None],
) -> UserRecord:
    token = token.strip()
    token_iat: datetime | None = None

    if not token:
        raise HTTPException(
            status_code=401,
            detail="Token cannot be empty",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        decoded = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
        user_id = decoded.get("sub")
        if not user_id:
            raise ValueError("No sub in token")
        # `iat` is encoded as an integer Unix timestamp (floored to whole
        # seconds), which is too coarse for the revocation-watermark check:
        # a deletion and a legitimate re-login within the same second would
        # collide. `iat_us` (microsecond-precise ISO string) is preferred when
        # present; older tokens without it fall back to the floored `iat`.
        token_iat = parse_datetime(decoded.get("iat_us")) or parse_datetime(decoded.get("iat")) or datetime.now(tz=UTC)
    except jwt.ExpiredSignatureError as exc:
        raise HTTPException(
            status_code=401,
            detail="Token has expired",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
    except jwt.InvalidTokenError as exc:
        raise HTTPException(
            status_code=401,
            detail="Invalid token",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    if not user_id:
        raise HTTPException(
            status_code=401,
            detail="Invalid token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    # Path-traversal guard (R8#1): reject any `sub` that is not path-safe
    # before it is used for user lookup or directory creation. `..` is
    # rejected explicitly because the allowlist permits the dot for Apple
    # subs. A failed match means a forged/malformed token, so surface the
    # same opaque 401 as other auth failures.
    if ".." in user_id or not _USER_ID_ALLOWED.match(user_id):
        raise HTTPException(
            status_code=401,
            detail="Invalid token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    users = load_users()
    revoked_before = users.get("_revoked_before", {})
    if isinstance(revoked_before, dict):
        revoked_at = parse_datetime(revoked_before.get(user_id))
        if revoked_at and (token_iat is None or token_iat <= revoked_at):
            raise _account_deleted_401()

    record = users.get(user_id, {})
    if isinstance(record, dict):
        linked_to = record.get("_linked_to")
        if linked_to and isinstance(revoked_before, dict):
            revoked_at = parse_datetime(revoked_before.get(linked_to))
            if revoked_at and (token_iat is None or token_iat <= revoked_at):
                raise _account_deleted_401()

    user_dir = settings.data_dir / "users" / user_id
    user_dir.mkdir(parents=True, exist_ok=True)

    return {
        "id": user_id,
        "dir": user_dir,
        "record": record,
        "config": record.get("config", {}) if isinstance(record, dict) else {},
    }
