from __future__ import annotations

import pytest

from kg.api_models.library import BookCreateRequest, BookMetadataResponse, BookPositionRequest
from kg.exceptions import BadRequestError
from kg.library.store import LibraryStore
from kg.routers import library as library_router


class _FakeLibraryStore:
    def __init__(self, books: list[BookMetadataResponse]) -> None:
        self.books = books

    def all(self, *, include_deleted: bool) -> list[BookMetadataResponse]:
        assert include_deleted is True
        return self.books


def test_since_filter_compares_utc_instants_for_mixed_offsets(monkeypatch):
    books = [
        BookMetadataResponse(
            id="before",
            title="Before",
            updated_at="2026-08-21T11:00:00+02:00",  # 09:00 UTC
        ),
        BookMetadataResponse(
            id="equal",
            title="Equal",
            updated_at="2026-08-21T12:00:00+02:00",  # 10:00 UTC
        ),
        BookMetadataResponse(
            id="after",
            title="After",
            updated_at="2026-08-21T09:30:00-02:00",  # 11:30 UTC
        ),
    ]
    monkeypatch.setattr(
        library_router,
        "_library_store",
        lambda _user_dir: _FakeLibraryStore(books),
    )

    result = library_router.list_books(
        {"dir": "ignored"},
        since="2026-08-21T10:00:00Z",
    )

    assert [book.id for book in result] == ["after"]


def test_empty_since_is_rejected_instead_of_disabling_filter(monkeypatch):
    monkeypatch.setattr(
        library_router,
        "_library_store",
        lambda _user_dir: _FakeLibraryStore([]),
    )

    with pytest.raises(BadRequestError, match="Invalid since timestamp"):
        library_router.list_books({"dir": "ignored"}, since="")


def test_since_year_one_positive_offset_is_bad_request_not_overflow(monkeypatch):
    """#3890: astimezone(UTC) overflows for year-1 offsets; client input must map to 400."""
    monkeypatch.setattr(
        library_router,
        "_library_store",
        lambda _user_dir: _FakeLibraryStore([]),
    )

    with pytest.raises(BadRequestError, match="Invalid since timestamp"):
        library_router.list_books({"dir": "ignored"}, since="0001-01-01T00:00:00+01:00")


def test_put_position_year_one_positive_offset_is_bad_request_not_overflow(tmp_path, monkeypatch):
    """#3890: LWW updated_at with a year-1 positive offset must be a 400, not a 500."""
    store = LibraryStore(tmp_path / "library.db")
    try:
        book = store.create(BookCreateRequest(client_book_id="since-utc-1", title="Book"))
        monkeypatch.setattr(library_router, "_library_store", lambda _user_dir: store)

        with pytest.raises(BadRequestError, match="Invalid updated_at timestamp"):
            library_router.put_position(
                book.id,
                BookPositionRequest(updated_at="0001-01-01T00:00:00+01:00", progression=0.5),
                {"dir": "ignored"},
            )
    finally:
        store.close()


def test_vocab_since_year_one_positive_offset_is_bad_request_not_overflow():
    """#3890: the vocab since parser must reject the same input with BadRequestError."""
    from kg.vocab_crud import list_vocab_cards

    with pytest.raises(BadRequestError, match="Invalid since timestamp"):
        list_vocab_cards(
            since="0001-01-01T00:00:00+01:00",
            cards_store=None,
            graph=None,
            card_response_builder=lambda *_args: None,
        )
