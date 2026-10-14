"""Tests for VocabSource field on VocabEntry, Card, and CardResponse."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

import pytest

from kg.api_models import CardResponse, VocabEntry, VocabSource
from kg.vocab_shared import card_response


def _build_card_response(source: str | None) -> CardResponse:
    card = SimpleNamespace(
        id="c1",
        content="word",
        meaning="m",
        pos=None,
        difficulty=1.0,
        note=None,
        collocations=[],
        examples=[],
        mode="recognition",
        is_deleted=True,
        is_archived=False,
        inflections=[],
        source=source,
        updated_at=None,
        review_interval_hours=12,
        next_review_at=None,
        last_reviewed_at=None,
        review_count=0,
        lapse_count=0,
        review_streak=0,
        last_review_feedback=-1,
        notebook_id="default",
    )
    return card_response(
        card,
        graph=None,
        cards_by_id={},
        tier_getter=lambda _: SimpleNamespace(tag="A1"),
        link_kinds=[],
        link_labels={},
    )


def test_vocab_entry_accepts_source():
    """VocabEntry with source={type:'web', title, url} should parse correctly."""
    entry = VocabEntry(
        word="hello",
        translation="你好",
        source=VocabSource(type="web", title="Example Page", url="https://example.com"),
    )
    assert entry.source is not None
    assert entry.source.type == "web"
    assert entry.source.title == "Example Page"
    assert entry.source.url == "https://example.com"
    assert entry.source.chapter is None


def test_vocab_entry_source_optional():
    """VocabEntry without source should default to None."""
    entry = VocabEntry(word="hello", translation="你好")
    assert entry.source is None


def test_card_model_has_source_column():
    """CardStore.add with source JSON should persist and retrieve correctly."""
    from kg.cards import CardStore

    with TemporaryDirectory() as tmpdir:
        store = CardStore(Path(tmpdir) / "test.db")
        source_data = json.dumps({"type": "web", "title": "Test", "url": "https://test.com"})
        card = store.add(content="hello", meaning="你好", source=source_data)
        assert card.source == source_data

        retrieved = store.get(card.id)
        assert retrieved is not None
        assert retrieved.source == source_data
        parsed = json.loads(retrieved.source)
        assert parsed["type"] == "web"
        assert parsed["url"] == "https://test.com"


def test_card_response_includes_source():
    """CardResponse should accept and expose a VocabSource field."""
    src = VocabSource(type="book", title="My Book", chapter="Ch. 1")
    resp = CardResponse(
        id="abc123",
        content="hello",
        meaning="你好",
        pos=None,
        difficulty=None,
        difficultyTier=None,
        note=None,
        examples=[],
        mode="recognition",
        isDeleted=False,
        source=src,
    )
    assert resp.source is not None
    assert resp.source.type == "book"
    assert resp.source.chapter == "Ch. 1"


def test_card_response_source_none_by_default():
    """CardResponse without source should default to None."""
    resp = CardResponse(
        id="abc123",
        content="hello",
        meaning="你好",
        pos=None,
        difficulty=None,
        difficultyTier=None,
        note=None,
        examples=[],
        mode="recognition",
        isDeleted=False,
    )
    assert resp.source is None


def test_card_response_omits_malformed_persisted_source():
    """Malformed legacy source JSON must not escape card response construction."""
    response = _build_card_response("not-json")

    assert response.source is None


@pytest.mark.parametrize(
    "source",
    [
        pytest.param(
            json.dumps({"type": "web", "url": "javascript:alert(1)"}),
            id="invalid-url",
        ),
        pytest.param(json.dumps({"title": "Missing type"}), id="invalid-object-shape"),
        pytest.param(
            json.dumps({"type": "web", "title": {"nested": "value"}}),
            id="invalid-field-type",
        ),
        pytest.param(json.dumps(["web"]), id="non-object-payload"),
    ],
)
def test_card_response_omits_invalid_persisted_source(source: str):
    """Invalid persisted source payloads must not escape card response construction."""
    response = _build_card_response(source)

    assert response.source is None


def test_card_response_preserves_valid_persisted_source():
    response = _build_card_response(json.dumps({"type": "web", "title": "Example Page", "url": "https://example.com"}))

    assert response.source == VocabSource(type="web", title="Example Page", url="https://example.com")


def test_card_response_preserves_absent_persisted_source():
    response = _build_card_response(None)

    assert response.source is None


def test_card_response_exposes_created_at():
    """CardResponse must carry the card's creation time so iOS can preserve dateAdded (#3801)."""
    created = datetime(2025, 1, 1, tzinfo=UTC)
    card = SimpleNamespace(
        id="c1",
        content="word",
        meaning="m",
        pos=None,
        difficulty=1.0,
        note=None,
        collocations=[],
        examples=[],
        mode="recognition",
        is_deleted=True,
        is_archived=False,
        inflections=[],
        source=None,
        updated_at=None,
        created_at=created,
        review_interval_hours=12,
        next_review_at=None,
        last_reviewed_at=None,
        review_count=0,
        lapse_count=0,
        review_streak=0,
        last_review_feedback=-1,
        notebook_id="default",
    )
    response = card_response(
        card,
        graph=None,
        cards_by_id={},
        tier_getter=lambda _: SimpleNamespace(tag="A1"),
        link_kinds=[],
        link_labels={},
    )

    assert response.createdAt == "2025-01-01T00:00:00+00:00"
