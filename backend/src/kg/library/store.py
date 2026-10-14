"""SQLite-backed :class:`LibraryStore` — per-user book metadata mirror.

Extracted out of ``routers/library.py`` so the store can live in the shared
LRU cache (one engine per user, not a fresh engine per request). The
``LibraryBook`` SQLModel ``table=True`` definition lives here as the *single*
source of truth — a duplicate same-named ``table=True`` class elsewhere would
trip SQLModel's metadata registry with ``InvalidRequestError``.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import NamedTuple

from sqlalchemy import update
from sqlmodel import Field as SQLField
from sqlmodel import Session, SQLModel, select

from ..api_models.library import (
    BookCreateRequest,
    BookMetadataResponse,
    BookPositionRequest,
    BookUpdateRequest,
)
from ..exceptions import ConflictError
from ..sqlite_utils import make_sqlite_engine
from ..utc_instant import parse_utc_instant
from ..vocab_shared import _dt_to_iso

# A claimed key is held for this long while its S3 delete runs outside the DB
# write lock. It must outlive the worst case of one reclaim batch (fast client:
# 2s connect + 2s read per key, batch of 5), so a slow delete cannot outlive its
# lease and race a re-adoption of the same key.
RECLAIM_LEASE = timedelta(seconds=120)


class PendingClaim(NamedTuple):
    """A ledger key claimed for deletion, plus the token proving the claim."""

    object_key: str
    token: str


def _parse_utc_instant(value: str) -> datetime:
    """Parse an ISO timestamp as an absolute UTC instant; invalid client input raises ValueError (#3890)."""
    return parse_utc_instant(value)


class LibraryBook(SQLModel, table=True):
    """Per-user book metadata (no raw file storage)."""

    id: str = SQLField(default_factory=lambda: uuid.uuid4().hex[:12], primary_key=True)
    client_book_id: str | None = SQLField(default=None, index=True)
    title: str
    author: str | None = SQLField(default=None)
    language: str | None = SQLField(default=None)
    format: str | None = SQLField(default=None)
    notebook_id: str | None = SQLField(default=None)
    is_deleted: bool = SQLField(default=False)
    created_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))
    updated_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))
    # Reading position (LWW)
    locator: str | None = SQLField(default=None)
    progression: float | None = SQLField(default=None)
    position_updated_at: str | None = SQLField(default=None)
    # Asset storage (Architecture PR #7): where the raw book file lives.
    # asset_storage in {None (unknown), "local", "object"}.
    asset_storage: str | None = SQLField(default=None)
    asset_object_key: str | None = SQLField(default=None)
    asset_byte_size: int | None = SQLField(default=None)
    asset_sha256: str | None = SQLField(default=None)


class LibraryPendingObjectDelete(SQLModel, table=True):
    """Object key no longer referenced by a book row (tombstoned or superseded).

    Recorded in the same transaction that drops the reference. The request path
    claims a batch under the write lock, deletes outside it, then records the
    result: success clears the entry, failure stamps ``last_attempt_at`` so the
    key rotates to the back of the queue. Keys whose delete failed stay here to
    be retried on a later library write and to be reclaimed by account erasure.
    """

    object_key: str = SQLField(primary_key=True)
    book_id: str = SQLField(index=True)
    recorded_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))
    # Lease while an in-flight delete owns the key; None when unclaimed. The token
    # identifies the claimer, so a stale claimer whose lease expired cannot clear
    # a newer claimer's lease when it reports back.
    claimed_until: datetime | None = SQLField(default=None)
    claim_token: str | None = SQLField(default=None)
    attempts: int = SQLField(default=0)
    last_attempt_at: datetime | None = SQLField(default=None)


class LibraryStore:
    """SQLite-based library storage."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.engine = make_sqlite_engine(path)
        LibraryBook.metadata.create_all(
            self.engine,
            tables=[LibraryBook.__table__, LibraryPendingObjectDelete.__table__],
            checkfirst=True,
        )

    def close(self) -> None:
        """Dispose the SQLAlchemy engine and release connections.

        Required for LRU eviction: ``service_factories._close_store`` only
        disposes stores exposing ``close()``; without it the cached engine and
        its pooled connections leak when the store is evicted.
        """
        if self.engine is not None:
            self.engine.dispose()
            self.engine = None

    def _to_response(self, book: LibraryBook) -> BookMetadataResponse:
        return BookMetadataResponse(
            id=book.id,
            client_book_id=book.client_book_id,
            title=book.title,
            author=book.author,
            language=book.language,
            format=book.format,
            notebook_id=book.notebook_id,
            is_deleted=book.is_deleted,
            updated_at=_dt_to_iso(book.updated_at),
            locator=book.locator,
            progression=book.progression,
            position_updated_at=book.position_updated_at,
        )

    def all(self, include_deleted: bool = False) -> list[BookMetadataResponse]:
        with Session(self.engine) as session:
            stmt = select(LibraryBook)
            if not include_deleted:
                stmt = stmt.where(LibraryBook.is_deleted == False)  # noqa: E712
            results = session.exec(stmt).all()
            return [self._to_response(r) for r in results]

    def get(self, book_id: str) -> LibraryBook | None:
        with Session(self.engine) as session:
            return session.get(LibraryBook, book_id)

    def create(self, req: BookCreateRequest) -> BookMetadataResponse:
        with Session(self.engine) as session:
            # Serialize the idempotency check with the insert across workers.
            # SQLite's default deferred transaction lets concurrent callers all
            # observe the same missing client_book_id before either commits.
            session.connection().exec_driver_sql("BEGIN IMMEDIATE")
            # Idempotency: return the live row for client_book_id; tombstones never match, so a reused id gets a fresh row
            if req.client_book_id:
                existing = session.exec(
                    select(LibraryBook).where(
                        LibraryBook.client_book_id == req.client_book_id,
                        LibraryBook.is_deleted == False,  # noqa: E712
                    )
                ).first()
                if existing:
                    return self._to_response(existing)
            now = datetime.now(UTC)
            book = LibraryBook(
                id=uuid.uuid4().hex[:12],
                client_book_id=req.client_book_id,
                title=req.title,
                author=req.author,
                language=req.language,
                format=req.format,
                updated_at=now,
                created_at=now,
            )
            session.add(book)
            session.commit()
            session.refresh(book)
            return self._to_response(book)

    def update(self, book_id: str, req: BookUpdateRequest) -> LibraryBook | None:
        with Session(self.engine) as session:
            book = session.get(LibraryBook, book_id)
            if book is None or book.is_deleted:
                return None
            if req.title is not None:
                book.title = req.title
            if req.author is not None:
                book.author = req.author
            if req.language is not None:
                book.language = req.language
            if req.format is not None:
                book.format = req.format
            if req.notebook_id is not None:
                book.notebook_id = req.notebook_id
            book.updated_at = datetime.now(UTC)
            session.add(book)
            session.commit()
            session.refresh(book)
            return book

    def update_position(self, book_id: str, req: BookPositionRequest) -> LibraryBook | None:
        with Session(self.engine) as session:
            book = session.get(LibraryBook, book_id)
            if book is None or book.is_deleted:
                return None
            incoming_updated_at = _parse_utc_instant(req.updated_at)
            while True:
                expected_position_updated_at = book.position_updated_at
                current_updated_at = (
                    None if expected_position_updated_at is None else _parse_utc_instant(expected_position_updated_at)
                )
                if current_updated_at is not None and incoming_updated_at <= current_updated_at:
                    return book

                # End the read transaction before the compare-and-swap write so
                # a concurrent writer can commit without this session holding a
                # stale SQLite snapshot.
                session.rollback()
                stmt = (
                    update(LibraryBook)
                    .where(LibraryBook.id == book_id)
                    .where(LibraryBook.is_deleted == False)  # noqa: E712
                    .where(
                        LibraryBook.position_updated_at.is_(None)
                        if expected_position_updated_at is None
                        else LibraryBook.position_updated_at == expected_position_updated_at
                    )
                    .values(
                        locator=req.locator,
                        progression=req.progression,
                        position_updated_at=req.updated_at,
                        updated_at=datetime.now(UTC),
                    )
                )
                result = session.exec(stmt)
                session.commit()
                if result.rowcount:
                    return session.get(LibraryBook, book_id)

                # Another writer won the CAS. Reload its position and compare
                # again rather than allowing request arrival order to win.
                session.rollback()
                book = session.get(LibraryBook, book_id)
                if book is None or book.is_deleted:
                    return None

    def soft_delete(self, book_id: str) -> LibraryBook | None:
        """Soft-delete a book by flipping ``is_deleted`` and bumping
        ``updated_at``. Returns the book (idempotent: an already-deleted book
        still returns it), or ``None`` if the id is unknown.
        """
        with Session(self.engine) as session:
            _lock_book(session, book_id)
            book = session.get(LibraryBook, book_id)
            if book is None:
                return None
            if not book.is_deleted:
                book.is_deleted = True
                book.updated_at = datetime.now(UTC)
                session.add(book)
                if book.asset_storage == "object" and book.asset_object_key:
                    _record_pending_delete(session, book.id, book.asset_object_key)
            session.commit()
            session.refresh(book)
            return book

    def pending_object_keys(self) -> list[str]:
        """Object keys recorded for reclamation, in key order."""
        with Session(self.engine) as session:
            return list(
                session.exec(
                    select(LibraryPendingObjectDelete.object_key).order_by(LibraryPendingObjectDelete.object_key)
                ).all()
            )

    def claim_pending_objects(self, limit: int) -> list[PendingClaim]:
        """Claim up to ``limit`` ledger keys for deletion, under one write lock.

        Keys a live book references are stale and dropped without a claim. Each
        claimed key gets a ``RECLAIM_LEASE`` and a fresh token; the caller deletes
        outside the DB lock and then reports each result with the same claim via
        :meth:`finish_pending_object` or :meth:`release_pending_object`. Keys are
        rotated by ``last_attempt_at`` (never-tried first, then oldest failure), so
        a permanently failing key cannot starve the rest.
        """
        now = datetime.now(UTC)
        with Session(self.engine) as session:
            _begin_write(session)
            rows = sorted(
                session.exec(select(LibraryPendingObjectDelete)).all(),
                key=_claim_order,
            )
            claimed: list[PendingClaim] = []
            for row in rows:
                if len(claimed) == limit:
                    break
                if row.claimed_until is not None and _utc(row.claimed_until) > now:
                    continue
                live = session.exec(
                    select(LibraryBook.id).where(
                        LibraryBook.asset_storage == "object",
                        LibraryBook.asset_object_key == row.object_key,
                        LibraryBook.is_deleted == False,  # noqa: E712
                    )
                ).first()
                if live is not None:
                    session.delete(row)
                    continue
                row.claimed_until = now + RECLAIM_LEASE
                row.claim_token = uuid.uuid4().hex
                session.add(row)
                claimed.append(PendingClaim(row.object_key, row.claim_token))
            session.commit()
            return claimed

    def finish_pending_object(self, claim: PendingClaim, *, deleted: bool) -> None:
        """Record the outcome of a delete attempt made under ``claim``.

        ``deleted=True`` clears the entry. ``False`` releases the claim and counts
        the attempt, so the key stays pending and moves to the back of the queue.
        A claim whose token no longer matches (lease expired and re-claimed or
        adopted) is a no-op: it must not touch a newer claimer's state.
        """
        now = datetime.now(UTC)
        with Session(self.engine) as session:
            _begin_write(session)
            row = _owned_claim(session, claim)
            if row is not None:
                if deleted:
                    session.delete(row)
                else:
                    row.attempts += 1
                    row.last_attempt_at = now
                    _clear_claim(row)
                    session.add(row)
            session.commit()

    def release_pending_object(self, claim: PendingClaim) -> None:
        """Give back a claim without an attempt (nothing was sent to the store)."""
        with Session(self.engine) as session:
            _begin_write(session)
            row = _owned_claim(session, claim)
            if row is not None:
                _clear_claim(row)
                session.add(row)
            session.commit()

    def set_asset(
        self,
        book_id: str,
        *,
        storage: str,
        object_key: str | None,
        byte_size: int | None,
        sha256: str | None,
    ) -> LibraryBook | None:
        """Record where a book's raw asset lives (local-only or object key).

        A previous object key that the row stops referencing is recorded in the
        pending-delete ledger in the same transaction; a key the row starts
        referencing is removed from it.

        Returns the updated book, or ``None`` if the id is unknown or deleted.
        """
        with Session(self.engine) as session:
            # Take the write lock before reading the previous key: two racing
            # changes (A->B, A->C) must serialize, otherwise both read A and B
            # is never recorded for reclamation.
            _lock_book(session, book_id)
            book = session.get(LibraryBook, book_id)
            # A tombstone takes no new asset: its key would never be reclaimed.
            if book is None or book.is_deleted:
                return None
            previous_key = book.asset_object_key if book.asset_storage == "object" else None
            if previous_key and previous_key != object_key:
                _record_pending_delete(session, book.id, previous_key)
            if object_key:
                _adopt_object_key(session, object_key)
            book.asset_storage = storage
            book.asset_object_key = object_key
            book.asset_byte_size = byte_size
            book.asset_sha256 = sha256
            book.updated_at = datetime.now(UTC)
            session.add(book)
            session.commit()
            session.refresh(book)
            return book


def _begin_write(session: Session) -> None:
    """Start a write transaction now, so SQLite's write lock is taken before any read."""
    session.connection().exec_driver_sql("BEGIN IMMEDIATE")


def _lock_book(session: Session, book_id: str) -> None:
    """No-op write that acquires SQLite's write lock before a read-modify-write."""
    session.exec(update(LibraryBook).where(LibraryBook.id == book_id).values(id=book_id))


def _record_pending_delete(session: Session, book_id: str, object_key: str) -> None:
    if session.get(LibraryPendingObjectDelete, object_key) is None:
        session.add(LibraryPendingObjectDelete(object_key=object_key, book_id=book_id))


def _adopt_object_key(session: Session, object_key: str) -> None:
    """Drop the ledger entry for a key a row is about to reference.

    A key whose delete is in flight cannot be adopted: the delete may land after
    the new bytes do, so the caller must retry once the reclaim finishes.
    """
    pending = session.get(LibraryPendingObjectDelete, object_key)
    if pending is None:
        return
    if pending.claimed_until is not None and _utc(pending.claimed_until) > datetime.now(UTC):
        raise ConflictError("Library object is being reclaimed; retry the request")
    session.delete(pending)


def _owned_claim(session: Session, claim: PendingClaim) -> LibraryPendingObjectDelete | None:
    row = session.get(LibraryPendingObjectDelete, claim.object_key)
    if row is None or row.claim_token != claim.token:
        return None
    return row


def _clear_claim(row: LibraryPendingObjectDelete) -> None:
    row.claimed_until = None
    row.claim_token = None


def _utc(value: datetime) -> datetime:
    """SQLite returns naive datetimes; ledger timestamps are always UTC."""
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value


def _claim_order(row: LibraryPendingObjectDelete) -> tuple[bool, datetime, str]:
    """Never-tried keys first, then oldest failed attempt, then key for stability."""
    if row.last_attempt_at is None:
        return (False, datetime.min.replace(tzinfo=UTC), row.object_key)
    return (True, _utc(row.last_attempt_at), row.object_key)


__all__ = ["LibraryBook", "LibraryPendingObjectDelete", "LibraryStore"]
