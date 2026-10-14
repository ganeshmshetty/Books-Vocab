from __future__ import annotations

import time
from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator

from kg.api_models.notebook import MAX_FUTURE_SKEW_SECONDS

LibraryFormat = Literal["epub", "pdf", "txt", "md"]


class BookMetadataResponse(BaseModel):
    """A book in the user's library."""

    id: str
    client_book_id: str | None = None
    title: str
    author: str | None = None
    language: str | None = None
    format: str | None = None  # epub | pdf | txt | md
    notebook_id: str | None = None
    is_deleted: bool = False
    updated_at: str | None = None  # ISO8601
    # Reading position
    locator: str | None = None  # CFI / href / offset
    progression: float | None = None  # 0..1
    position_updated_at: str | None = None  # ISO8601


class BookCreateRequest(BaseModel):
    """Create a book metadata entry (idempotent via client_book_id)."""

    client_book_id: str = Field(min_length=1, max_length=128)
    title: str = Field(min_length=1, max_length=200)
    author: str | None = Field(default=None, max_length=200)
    language: str | None = Field(default=None, max_length=10)
    format: LibraryFormat | None = None


class BookUpdateRequest(BaseModel):
    """Partial update of book metadata or notebook binding."""

    title: str | None = Field(default=None, min_length=1, max_length=200)
    author: str | None = Field(default=None, max_length=200)
    language: str | None = Field(default=None, max_length=10)
    format: LibraryFormat | None = None
    notebook_id: str | None = Field(default=None, max_length=64)


class BookPositionRequest(BaseModel):
    """LWW reading position update."""

    locator: str | None = Field(default=None, max_length=500)
    progression: float | None = Field(default=None, ge=0.0, le=1.0)
    updated_at: str = Field(min_length=1, max_length=50)  # ISO8601 LWW timestamp

    @field_validator("updated_at")
    @classmethod
    def _reject_far_future_updated_at(cls, value: str) -> str:
        # Unparseable values pass through so the router keeps its 400 path.
        # A far-future instant would otherwise pin position_updated_at and drop every later write.
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return value
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        if parsed.timestamp() > time.time() + MAX_FUTURE_SKEW_SECONDS:
            raise ValueError("updated_at is too far in the future")
        return value


class DeleteBookResponse(BaseModel):
    """Result of DELETE /api/library/books/{id} (soft delete)."""

    deleted: str  # the book id that was soft-deleted


class AssetUploadRequest(BaseModel):
    """Request an object-storage upload target or declare a local-only asset.

    Architecture PR #7: book asset (EPUB/PDF/TXT/MD) upload entitlement.
    """

    format: LibraryFormat
    byte_size: int = Field(ge=0)
    sha256: str | None = Field(default=None, pattern=r"^[0-9a-fA-F]{64}$")
    local_only: bool = False


class AssetUploadResponse(BaseModel):
    """Upload target for a book asset.

    storage="local"  -> asset stays client-local (no server URL).
    storage="object" -> upload via presigned PUT to `upload_url` at `object_key`.
    """

    book_id: str
    storage: str  # local | object
    upload_url: str | None = None  # presigned PUT URL (object storage only)
    object_key: str | None = None  # storage key (object storage only)
    expires_in: int | None = None  # presigned URL TTL seconds (object storage only)
