from __future__ import annotations

import logging
from collections.abc import Iterator
from contextlib import contextmanager

from fastapi import APIRouter, Request
from fastapi.responses import RedirectResponse

from ..account_erasure import ensure_account_not_erased
from ..api_models.library import (
    AssetUploadRequest,
    AssetUploadResponse,
    BookCreateRequest,
    BookMetadataResponse,
    BookPositionRequest,
    BookUpdateRequest,
    DeleteBookResponse,
)
from ..deps import CurrentUser, _library_store, _notebook_store
from ..exceptions import BadRequestError, ConflictError, NotFoundError
from ..library.store import ASSET_URL_TTL_SECONDS
from ..notebook import validate_notebook_access
from ..settings import KGSettings
from ..users_lock import users_file_lock
from ..utc_instant import parse_utc_instant

# Presigned URL TTL (seconds) for asset upload/download targets.
_ASSET_URL_TTL = ASSET_URL_TTL_SECONDS
logger = logging.getLogger(__name__)

router = APIRouter(tags=["library"])


@router.get("/api/library/books", response_model=list[BookMetadataResponse])
def list_books(user: CurrentUser, since: str | None = None):
    store = _library_store(user["dir"])
    books = store.all(include_deleted=True)
    if since is not None:
        try:
            since_instant = parse_utc_instant(since)
        except ValueError:
            raise BadRequestError("Invalid since timestamp") from None
        books = [b for b in books if b.updated_at and parse_utc_instant(b.updated_at) > since_instant]
    return books


@router.post("/api/library/books", response_model=BookMetadataResponse, status_code=201)
def create_book(req: BookCreateRequest, user: CurrentUser):
    store = _library_store(user["dir"])
    return store.create(req)


@router.patch("/api/library/books/{book_id}", response_model=BookMetadataResponse)
def update_book(book_id: str, req: BookUpdateRequest, user: CurrentUser):
    store = _library_store(user["dir"])
    kwargs = {}
    if req.title is not None:
        kwargs["title"] = req.title
    if req.author is not None:
        kwargs["author"] = req.author
    if req.language is not None:
        kwargs["language"] = req.language
    if req.format is not None:
        kwargs["format"] = req.format
    if req.notebook_id is not None:
        kwargs["notebook_id"] = req.notebook_id
    if not kwargs:
        raise BadRequestError("No fields to update")
    book = store.get(book_id)
    if book is None or book.is_deleted:
        raise NotFoundError("Book", book_id)
    if req.notebook_id is not None:
        validate_notebook_access(_notebook_store(user["dir"]), req.notebook_id)
    book = store.update(book_id, req)
    if book is None:
        raise NotFoundError("Book", book_id)
    return store._to_response(book)


@router.put("/api/library/books/{book_id}/position", response_model=BookMetadataResponse)
def put_position(book_id: str, req: BookPositionRequest, user: CurrentUser):
    store = _library_store(user["dir"])
    try:
        book = store.update_position(book_id, req)
    except ValueError:
        raise BadRequestError("Invalid updated_at timestamp") from None
    if book is None:
        raise NotFoundError("Book", book_id)
    return store._to_response(book)


@router.delete("/api/library/books/{book_id}", response_model=DeleteBookResponse)
def delete_book(book_id: str, user: CurrentUser, request: Request):
    """Soft-delete a library book (set ``is_deleted``).

    Idempotent: a second delete of an already-deleted book still returns 200.
    Unknown ids raise 404. The stored asset object is deleted best-effort after
    the tombstone commits; a failed delete is logged and retried later.
    """
    store = _library_store(user["dir"])
    if store.soft_delete(book_id) is None:
        raise NotFoundError("Book", book_id)
    _reclaim_pending_objects(store, _settings(request))
    return DeleteBookResponse(deleted=book_id)


# ---------------------------------------------------------------------------
# Book asset storage (Architecture PR #7)
# ---------------------------------------------------------------------------


def _settings(request: Request) -> KGSettings:
    return request.app.state.kg_settings


def _library_s3_client(settings: KGSettings, *, fast: bool = False):
    import boto3
    from botocore.config import Config

    # botocore defaults (60s connect + 60s read, legacy retries) let one slow
    # object store stall a request for minutes; account deletion issues one
    # delete per book. ``fast`` is for best-effort work on the request path:
    # short timeouts and no retries (failures stay in the ledger anyway).
    # SigV4 is required: SigV2 query auth does not sign Content-Length, so the
    # presigned PUT could not pin the declared byte_size (#2525). Regional
    # virtual-hosted addressing avoids the global host's 307 for non-us-east-1
    # buckets; custom endpoints (MinIO, localstack) keep botocore's default.
    common = {
        "signature_version": "s3v4",
        "s3": {"addressing_style": "virtual"} if settings.library_bucket_endpoint_url is None else None,
    }
    if fast:
        config = Config(connect_timeout=2, read_timeout=2, retries={"total_max_attempts": 1}, **common)
    else:
        config = Config(
            connect_timeout=5, read_timeout=10, retries={"total_max_attempts": 3, "mode": "standard"}, **common
        )
    return boto3.client(
        "s3",
        region_name=settings.library_bucket_region,
        endpoint_url=settings.library_bucket_endpoint_url,
        config=config,
    )


# Upper bound of ledger keys attempted per request, so an object-store outage
# costs a request at most N short timeouts instead of the whole backlog.
_RECLAIM_BATCH = 5


def _reclaim_pending_objects(store, settings: KGSettings) -> None:
    """Best-effort delete of objects the library no longer references.

    Runs after the DB commit; nothing here (including client creation) fails the
    request. The store claims at most ``_RECLAIM_BATCH`` keys under its write
    lock; the S3 deletes run outside that lock, and each outcome is recorded
    afterwards. Failed keys stay in the ledger and rotate to the back of the queue.
    """
    if not settings.library_bucket:
        return
    try:
        claims = store.claim_pending_objects(_RECLAIM_BATCH)
    except Exception as exc:
        _log_reclaim_failure("library object reclaim skipped", exc)
        return
    if not claims:
        return
    try:
        client = _library_s3_client(settings, fast=True)
    except Exception as exc:
        _log_reclaim_failure("library object reclaim skipped", exc)
        for claim in claims:
            _settle_reclaim(store.release_pending_object, claim)
        return

    for index, claim in enumerate(claims):
        try:
            _delete_reclaimed(client, settings.library_bucket, claim.object_key)
        except Exception as exc:
            _log_reclaim_failure("library object delete failed; will retry", exc)
            _settle_reclaim(store.finish_pending_object, claim, deleted=False)
            # One failed call means the object store is unreachable or refusing;
            # the rest would only add timeouts to this request. Give them back
            # without counting an attempt.
            for pending in claims[index + 1 :]:
                _settle_reclaim(store.release_pending_object, pending)
            return
        _settle_reclaim(store.finish_pending_object, claim, deleted=True)


def _delete_reclaimed(client, bucket: str, key: str) -> None:
    try:
        client.delete_object(Bucket=bucket, Key=key)
    except Exception as exc:
        # Already gone is the desired end state, same as account erasure.
        if not _object_missing(exc):
            raise


def _settle_reclaim(action, claim, **outcome) -> None:
    try:
        action(claim, **outcome)
    except Exception as exc:
        # The claim lease expires on its own, so the key is retried later.
        _log_reclaim_failure("library object reclaim bookkeeping failed", exc)


def _log_reclaim_failure(message: str, exc: BaseException) -> None:
    # Type name only, no traceback: botocore and SQLAlchemy messages embed the
    # request URL or statement, and the object key carries the user and book ids.
    logger.warning("%s (%s)", message, type(exc).__name__)


def _object_missing(exc: Exception) -> bool:
    response = getattr(exc, "response", None)
    error = response.get("Error") if isinstance(response, dict) else None
    code = error.get("Code") if isinstance(error, dict) else None
    return str(code) in {"NoSuchKey", "NotFound", "404"}


def _asset_object_key(user_id: str, book_id: str, fmt: str) -> str:
    safe_fmt = "".join(c for c in fmt.lower() if c.isalnum()) or "bin"
    return f"library/{user_id}/{book_id}/asset.{safe_fmt}"


@contextmanager
def _registration_allowed(request: Request, settings: KGSettings, user_id: str) -> Iterator[None]:
    """Serialise asset registration with account erasure (#2702).

    Erasure re-scans the key ledger and commits its tombstone inside one
    users-lock hold. Registering under the same lock means a key is either
    visible to that scan or written after the tombstone, where it is rejected.
    Only the local write runs under the lock; S3 calls stay outside it.
    """
    with users_file_lock(settings.users_lock_file):
        ensure_account_not_erased(request.app.state.load_users(), user_id)
        yield


@router.post(
    "/api/library/books/{book_id}/asset-upload",
    response_model=AssetUploadResponse,
)
def request_asset_upload(
    book_id: str,
    req: AssetUploadRequest,
    user: CurrentUser,
    request: Request,
):
    """Request an object-storage upload target or declare a local-only asset.

    When no ``library_bucket`` is configured (dev / privacy-default) or the
    client declares ``local_only``, the asset stays client-side and no upload
    URL is minted. Otherwise a presigned PUT URL is returned and the resulting
    object key is recorded on the book row for later download.

    A previous object key that this call stops referencing (format change or
    local-only) is deleted best-effort after the row is updated; a failed delete
    is logged and retried later.
    """
    settings = _settings(request)
    store = _library_store(user["dir"])
    book = store.get(book_id)
    if book is None:
        raise NotFoundError("Book", book_id)
    if book.is_deleted:
        raise NotFoundError("Book", book_id)

    # Quota policy: reject obviously oversize assets before minting a target.
    if req.byte_size > settings.library_asset_max_bytes:
        raise BadRequestError(f"asset too large ({req.byte_size} bytes); max {settings.library_asset_max_bytes}")

    local_only = req.local_only or not settings.library_bucket
    if local_only:
        with _registration_allowed(request, settings, user["id"]):
            updated = store.set_asset(
                book_id,
                storage="local",
                object_key=None,
                byte_size=req.byte_size,
                sha256=req.sha256,
            )
        if updated is None:
            raise NotFoundError("Book", book_id)
        _reclaim_pending_objects(store, settings)
        return AssetUploadResponse(book_id=book_id, storage="local")

    object_key = _asset_object_key(user["id"], book_id, req.format)
    client = _library_s3_client(settings)
    upload_url = client.generate_presigned_url(
        "put_object",
        Params={"Bucket": settings.library_bucket, "Key": object_key, "ContentLength": req.byte_size},
        ExpiresIn=_ASSET_URL_TTL,
    )
    with _registration_allowed(request, settings, user["id"]):
        updated = store.set_asset(
            book_id,
            storage="object",
            object_key=object_key,
            byte_size=req.byte_size,
            sha256=req.sha256,
        )
    if updated is None:
        raise NotFoundError("Book", book_id)
    _reclaim_pending_objects(store, settings)
    return AssetUploadResponse(
        book_id=book_id,
        storage="object",
        upload_url=upload_url,
        object_key=object_key,
        expires_in=_ASSET_URL_TTL,
    )


@router.get("/api/library/books/{book_id}/asset")
def download_asset(book_id: str, user: CurrentUser, request: Request):
    """Redirect to an authorized object-storage URL for the book asset.

    404 unknown book; 409 when the asset is local-only (not server-hosted) or
    has never been registered.
    """
    settings = _settings(request)
    store = _library_store(user["dir"])
    book = store.get(book_id)
    if book is None:
        raise NotFoundError("Book", book_id)
    if book.is_deleted:
        raise NotFoundError("Book", book_id)

    if book.asset_storage != "object" or not book.asset_object_key:
        raise ConflictError("Book asset is not server-hosted (local-only)")

    client = _library_s3_client(settings)
    # The key is recorded when the upload URL is minted, before any bytes
    # exist; only redirect once the object is really there.
    try:
        head = client.head_object(Bucket=settings.library_bucket, Key=book.asset_object_key)
    except Exception as exc:
        if _object_missing(exc):
            raise ConflictError("Book asset has not been uploaded yet") from exc
        raise
    # A same-format re-upload reuses the key; if its bytes never landed the old
    # body is still there, so the recorded size no longer matches (#2527).
    stored_size = head.get("ContentLength")
    if stored_size is not None and book.asset_byte_size is not None and stored_size != book.asset_byte_size:
        raise ConflictError("Book asset upload is incomplete")
    download_url = client.generate_presigned_url(
        "get_object",
        Params={"Bucket": settings.library_bucket, "Key": book.asset_object_key},
        ExpiresIn=_ASSET_URL_TTL,
    )
    return RedirectResponse(url=download_url, status_code=307)
