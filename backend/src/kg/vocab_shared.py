"""Shared helpers and response builders for vocabulary modules."""

from __future__ import annotations

import json
import logging
from datetime import datetime
from typing import Any, Protocol

from pydantic import ValidationError

from .api_models import (
    CardLinkSummaryResponse,
    CardResponse,
    VocabSource,
)
from .api_models.common import MAX_WORD_LENGTH as MAX_WORD_LENGTH
from .text_utils import normalize_nfc_lower

logger = logging.getLogger(__name__)

MAX_BATCH_SIZE = 500


class VocabCard(Protocol):
    id: str
    content: str
    meaning: str | None
    pos: str | None
    difficulty: int | None
    note: str | None
    collocations: list[str]
    examples: list[str]
    mode: str
    is_deleted: bool
    is_archived: bool
    inflections: list[str]
    source: str | None
    updated_at: datetime
    review_interval_hours: int
    next_review_at: datetime | None
    last_reviewed_at: datetime | None
    review_count: int
    lapse_count: int
    review_streak: int
    last_review_feedback: str | None
    notebook_id: str


class VocabGraph(Protocol):
    def get_links_for(self, card_id: str) -> object: ...


class LinkKind(Protocol):
    value: str


class Link(Protocol):
    to_id: str
    from_id: str
    kind: LinkKind
    id: str
    confidence: float | None
    reason: str | None
    status: str


class Tier(Protocol):
    tag: str


class TierGetter(Protocol):
    def __call__(self, word: str) -> Tier: ...


class CardResponseBuilder(Protocol):
    def __call__(self, card: VocabCard, graph: VocabGraph, cards_by_id: dict[str, VocabCard]) -> CardResponse: ...


def _normalize_word(word: str) -> str:
    return normalize_nfc_lower(word)


def _build_content_lookup(cards_store: Any, notebook_id: str | None = None) -> dict[str, VocabCard]:
    """Build a normalized-content → card dict from all active cards. O(N) single pass."""
    lookup: dict[str, VocabCard] = {}
    for card in cards_store.all(include_deleted=False, notebook_id=notebook_id):
        key = _normalize_word(card.content)
        if key not in lookup:  # first match wins (same as find_by_content)
            lookup[key] = card
    return lookup


def _clean_content(word: str) -> str:
    """Clean up word content for storage: strip trailing punctuation, fold a simple capitalized token."""
    word = word.strip().rstrip(".,;:!?")
    # Lowercase the first char only for a simple capitalized single token (rest already
    # lowercase, e.g. "However"). Acronyms ("NASA", "I"), mixed-case words ("PhD",
    # "YouTube", "McCarthy") and phrases ("New York") keep their casing.
    if word and word[0].isupper() and not word.isupper() and word[1:] == word[1:].lower() and " " not in word:
        word = word[0].lower() + word[1:]
    return word


_POS_CANONICAL = {"n": "n.", "v": "v.", "adj": "adj.", "adv": "adv.", "phr": "phr.", "conj": "conj.", "prep": "prep."}


def _normalize_pos(pos: str | None) -> str | None:
    if not pos:
        return pos
    p = pos.strip()
    return _POS_CANONICAL.get(p, p)


def _dt_to_iso(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    s = dt.isoformat()
    # Only naive datetimes need the implicit UTC marker. Negative offsets do
    # not contain "+", so checking the serialized string would produce an
    # invalid value such as "...-05:00Z".
    if not s.endswith("Z") and dt.utcoffset() is None:
        s += "Z"
    return s


def _parse_vocab_source(raw_source: str | None, *, card_id: str) -> VocabSource | None:
    if not raw_source:
        return None
    try:
        payload = json.loads(raw_source)
    except json.JSONDecodeError:
        logger.warning("Ignoring malformed persisted vocab source JSON for card %s", card_id)
        return None
    try:
        return VocabSource(**payload)
    except (TypeError, ValidationError):
        logger.warning("Ignoring invalid persisted vocab source for card %s", card_id)
        return None


def build_links_by_kind(
    card_id: str,
    *,
    graph: VocabGraph,
    cards_by_id: dict[str, VocabCard],
    link_kinds: list[LinkKind],
    link_labels: dict[LinkKind, str],
) -> dict[str, list[CardLinkSummaryResponse]]:
    grouped: dict[str, list[CardLinkSummaryResponse]] = {}

    for link in graph.get_links_for(card_id):
        other_id = link.to_id if link.from_id == card_id else link.from_id
        other_card = cards_by_id.get(other_id)
        if not other_card or other_card.is_deleted or other_card.is_archived:
            continue

        kind_key = link.kind.value
        grouped.setdefault(kind_key, []).append(
            CardLinkSummaryResponse(
                id=link.id,
                cardId=other_card.id,
                word=other_card.content,
                kind=kind_key,
                label=link_labels.get(link.kind, link.kind.value),
                confidence=link.confidence,
                reason=link.reason,
                hidden=(link.status == "hidden"),
            )
        )

    ordered: dict[str, list[CardLinkSummaryResponse]] = {}
    for kind in link_kinds:
        items = grouped.get(kind.value)
        if items:
            ordered[kind.value] = sorted(items, key=lambda item: (_normalize_word(item.word), item.cardId))

    return ordered


def card_response(
    card: VocabCard,
    *,
    graph: VocabGraph,
    cards_by_id: dict[str, VocabCard],
    tier_getter: TierGetter,
    link_kinds: list[LinkKind],
    link_labels: dict[LinkKind, str],
) -> CardResponse:
    tier = tier_getter(card.content)
    links_by_kind = {}
    if not card.is_deleted:
        links_by_kind = build_links_by_kind(
            card.id,
            graph=graph,
            cards_by_id=cards_by_id,
            link_kinds=link_kinds,
            link_labels=link_labels,
        )

    return CardResponse(
        id=card.id,
        content=card.content,
        meaning=card.meaning,
        pos=card.pos,
        difficulty=card.difficulty,
        difficultyTier=tier.tag,
        note=card.note,
        collocations=card.collocations or [],
        examples=card.examples,
        mode=card.mode,
        isDeleted=card.is_deleted,
        isArchived=card.is_archived,
        inflections=card.inflections or [],
        linksByKind=links_by_kind,
        notebookId=getattr(card, "notebook_id", "default"),
        source=_parse_vocab_source(getattr(card, "source", None), card_id=card.id),
        updatedAt=_dt_to_iso(card.updated_at),
        createdAt=_dt_to_iso(getattr(card, "created_at", None)),
        reviewIntervalHours=card.review_interval_hours,
        nextReviewAt=_dt_to_iso(card.next_review_at),
        lastReviewedAt=_dt_to_iso(card.last_reviewed_at),
        reviewCount=card.review_count,
        lapseCount=card.lapse_count,
        reviewStreak=card.review_streak,
        lastReviewFeedback=card.last_review_feedback,
        isReaderHidden=getattr(card, "is_reader_hidden", False),
        isReviewExcluded=getattr(card, "is_review_excluded", False),
    )
