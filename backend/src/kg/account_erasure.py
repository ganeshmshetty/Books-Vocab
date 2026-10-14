"""External asset cleanup performed before destructive account erasure."""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any, Protocol

from fastapi import HTTPException
from sqlalchemy import inspect
from sqlmodel import Session, select

from .library.store import LibraryBook, LibraryPendingObjectDelete
from .sqlite_utils import make_sqlite_engine
from .user_store import is_real_user

# S3 DeleteObjects accepts at most 1000 keys per request.
_DELETE_BATCH = 1000


class ObjectStorageClient(Protocol):
    def delete_object(self, *, Bucket: str, Key: str) -> object:  # noqa: N803
        ...


def _asset_object_keys(data_dir: Path, user_ids: Iterable[str]) -> tuple[str, ...]:
    """Read the durable object-key ledger without requiring user metadata.

    Covers keys referenced by any row (including tombstones) and keys recorded
    as superseded or tombstoned in the pending-delete ledger.
    """
    keys: list[str] = []
    for uid in dict.fromkeys(user_ids):
        library_db = data_dir / "users" / uid / "library.db"
        if not library_db.is_file():
            continue
        engine = make_sqlite_engine(library_db)
        try:
            with Session(engine) as session:
                books = session.exec(select(LibraryBook)).all()
                keys.extend(
                    book.asset_object_key for book in books if book.asset_storage == "object" and book.asset_object_key
                )
                # Databases created before the ledger existed have no table yet.
                if inspect(engine).has_table(LibraryPendingObjectDelete.__tablename__):
                    keys.extend(session.exec(select(LibraryPendingObjectDelete.object_key)).all())
        finally:
            engine.dispose()
    return tuple(dict.fromkeys(keys))


def _is_missing_object(exc: Exception, client: ObjectStorageClient) -> bool:
    exception_namespace = getattr(client, "exceptions", None)
    no_such_key = getattr(exception_namespace, "NoSuchKey", None)
    if no_such_key is not None:
        try:
            if isinstance(exc, no_such_key):
                return True
        except TypeError:
            pass

    response = getattr(exc, "response", None)
    if not isinstance(response, dict):
        return False
    error = response.get("Error")
    code = error.get("Code") if isinstance(error, dict) else None
    return str(code) in {"NoSuchKey", "NotFound", "404"}


def delete_account_assets(
    data_dir: Path,
    user_ids: Iterable[str],
    *,
    library_bucket: str | None,
    library_s3_client: ObjectStorageClient | None,
) -> tuple[str, ...]:
    """Delete all recorded remote assets, preserving retryability on failure.

    No local state is modified here. A missing object is already in the desired
    state and therefore succeeds, making the operation safe to re-enter.
    """
    if not library_bucket:
        return ()
    if library_s3_client is None:
        raise HTTPException(status_code=503, detail="Library object storage is unavailable")

    keys = _asset_object_keys(data_dir, user_ids)
    for key in keys:
        try:
            library_s3_client.delete_object(Bucket=library_bucket, Key=key)
        except Exception as exc:
            if _is_missing_object(exc, library_s3_client):
                continue
            raise HTTPException(status_code=502, detail="Failed to delete library asset") from exc
    return keys


def library_prefix(user_id: str) -> str:
    """Key prefix under which every object of ``user_id`` lives (see ``_asset_object_key``)."""
    return f"library/{user_id}/"


def ensure_account_not_erased(users: Mapping[str, Any], user_id: str) -> None:
    """Raise 401 when ``user_id`` was erased and has no live record since (#2702, #3652).

    ``_terminated`` is permanent, so a re-registered account (same provider sub)
    has a live record again and must pass; its pre-erasure tokens are still
    rejected by the revocation watermark.

    Call under the users lock: erasure scans the key ledger and commits its
    tombstone inside one lock hold, so a write that passes this check under the
    lock is either seen by that scan or (after the tombstone) rejected here.
    """
    terminated = users.get("_terminated")
    if isinstance(terminated, list) and user_id in terminated and not is_real_user(user_id, users.get(user_id)):
        raise HTTPException(
            status_code=401,
            detail="Account was deleted. Please sign in again.",
            headers={"WWW-Authenticate": "Bearer"},
        )


def sweep_account_prefixes(
    user_ids: Iterable[str],
    *,
    library_bucket: str | None,
    library_s3_client: Any,
) -> int:
    """Delete every object under ``library/<uid>/`` for each id; return the count.

    The ledger-driven delete cannot see a PUT that lands after it (a presigned
    URL stays valid for up to its TTL), so this runs once more after the
    tombstone. Not retryable by the client (its token is revoked by then), so
    callers treat a failure as best-effort and log it.
    """
    if not library_bucket or library_s3_client is None:
        return 0
    removed = 0
    for uid in dict.fromkeys(user_ids):
        prefix = library_prefix(uid)
        token: str | None = None
        while True:
            kwargs: dict[str, Any] = {"Bucket": library_bucket, "Prefix": prefix}
            if token:
                kwargs["ContinuationToken"] = token
            page = library_s3_client.list_objects_v2(**kwargs)
            keys = [item["Key"] for item in page.get("Contents") or []]
            for start in range(0, len(keys), _DELETE_BATCH):
                batch = keys[start : start + _DELETE_BATCH]
                result = library_s3_client.delete_objects(
                    Bucket=library_bucket,
                    Delete={"Objects": [{"Key": key} for key in batch], "Quiet": True},
                )
                errors = result.get("Errors") if isinstance(result, dict) else None
                if errors:
                    raise RuntimeError(f"failed to delete {len(errors)} object(s) under {prefix}")
                removed += len(batch)
            next_token = page.get("NextContinuationToken")
            if page.get("IsTruncated") is not True or not isinstance(next_token, str):
                break
            token = next_token
    return removed


__all__ = [
    "ObjectStorageClient",
    "delete_account_assets",
    "ensure_account_not_erased",
    "library_prefix",
    "sweep_account_prefixes",
]
