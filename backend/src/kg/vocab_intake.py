"""Vocabulary intake: add new entries with inflection derivation."""

from __future__ import annotations

import logging
import re
import unicodedata
from collections.abc import Callable
from typing import Any

from .api_models import VocabAddResponse, VocabEntry
from .exceptions import ValidationError
from .vocab_graph import embed_and_link_new_cards
from .vocab_shared import (
    MAX_BATCH_SIZE,
    _build_content_lookup,
    _clean_content,
    _normalize_word,
)

_BOLD = re.compile(r"\*\*(.+?)\*\*")


def _boundary_pattern(term: str) -> re.Pattern[str]:
    return re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.IGNORECASE)


def _fold(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold().strip().rstrip(".,;:!?")


def _build_example(word: str, context: str, alternatives: list[str] | None = None) -> str:
    if not context:
        return ""
    # Client already highlighted exactly the target word: keep it verbatim.
    spans = _BOLD.findall(context)
    if len(spans) == 1 and _fold(spans[0]) == _fold(word):
        return context
    # Otherwise strip markers (avoid double-wrapping) and search with boundaries.
    context = unicodedata.normalize("NFKC", _BOLD.sub(r"\1", context))
    for term in [word, *(alternatives or [])]:
        match = _boundary_pattern(unicodedata.normalize("NFKC", term)).search(context)
        if match:
            return f"{context[: match.start()]}**{match.group()}**{context[match.end() :]}"
    return context


def _derive_inflections(word: str, root_form: str | None, *, logger: logging.Logger) -> tuple[str | None, list[str]]:
    inflections: list[str] = []
    root = None
    if " " in word:
        return root, inflections

    root = (root_form or "").strip().lower() or None
    if not root:
        return root, inflections

    try:
        from lemminflect import getAllInflections

        infl_map = getAllInflections(root)
        if not infl_map:
            logger.warning("lemminflect found no inflections for root; falling back to word")
            root = word.lower()
            infl_map = getAllInflections(root)
        seen = {word.lower()}
        for forms in infl_map.values():
            for form in forms:
                lowered = form.lower()
                if lowered not in seen:
                    inflections.append(lowered)
                    seen.add(lowered)
    except (ImportError, ValueError, KeyError, TypeError) as exc:
        logger.warning("lemminflect failed: %s", type(exc).__name__)

    return root, inflections


def add_vocab_entries(
    entries: list[VocabEntry],
    *,
    user: dict[str, Any],
    cards: Any,
    embeddings: Any,
    graph: Any,
    logger: logging.Logger,
    notebook_id: str = "default",
    notebook_check: Callable[[], None] | None = None,
) -> VocabAddResponse:
    if len(entries) > MAX_BATCH_SIZE:
        raise ValidationError(f"Batch size {len(entries)} exceeds maximum of {MAX_BATCH_SIZE}")
    cleaned_words = [_clean_content(entry.word) for entry in entries]
    if any(not word for word in cleaned_words):
        raise ValidationError("Word cannot be empty")
    # Build content→card dict once; eliminates per-duplicate find_by_content() DB
    # call. Shares the same normalized lookup as the batch CRUD paths
    # (cards.all() defaults to include_deleted=False, matching _build_content_lookup).
    existing_by_norm = _build_content_lookup(
        cards, (_normalize_word(word) for word in cleaned_words), notebook_id=notebook_id
    )
    existing = set(existing_by_norm.keys())

    created = 0
    skipped = 0
    new_card_ids: list[str] = []
    # Response 對外的 duplicates/cardIds 用 client 送出的『原始』word 當 key,讓 iOS sync
    # 能以 entry.word 字面配對回 pending queue 並出列 —— 後端清洗(_clean_content)會改寫
    # word(strip 尾標點 / 首字小寫),若回傳清洗後的 key,client 拿原始 "chateau," 永遠查
    # 不到 "chateau" → 卡在佇列重送。內部 card_ids 仍以清洗後 word 為 key,供
    # embed_and_link_new_cards 查找(它會自行 _clean_content,見 vocab_graph.py)。
    duplicates: list[str] = []
    card_ids: dict[str, str] = {}  # cleaned word -> id（內部 embed/link 用）
    response_card_ids: dict[str, str] = {}  # 原始 entry.word -> id（對外 response 用）

    for entry, word in zip(entries, cleaned_words, strict=True):
        norm = _normalize_word(word)
        if norm in existing:
            skipped += 1
            duplicates.append(entry.word)
            existing_card = existing_by_norm.get(norm)
            if existing_card:
                card_ids[word] = existing_card.id
                response_card_ids[entry.word] = existing_card.id
            continue

        root, inflections = _derive_inflections(word, entry.root_form, logger=logger)
        alternatives = inflections + ([root] if root else [])
        example = _build_example(word, entry.context, alternatives=alternatives)

        card = cards.add(
            content=word,
            meaning=entry.translation.strip(),
            examples=[example] if example else [],
            root_form=root,
            inflections=inflections,
            notebook_id=notebook_id,
            source=entry.source.model_dump_json() if entry.source else None,
        )
        new_card_ids.append(card.id)
        card_ids[word] = card.id
        response_card_ids[entry.word] = card.id
        existing.add(norm)
        existing_by_norm[norm] = card
        created += 1

    if created > 0 and notebook_check is not None:
        # The notebook may have been deleted after admission (#2268): tombstone
        # what this call created (soft delete, so sync pulls see it) and fail.
        try:
            notebook_check()
        except Exception:
            for card_id in new_card_ids:
                cards.delete(card_id)
            raise

    if created > 0:
        embed_and_link_new_cards(
            cards=cards,
            embeddings=embeddings,
            graph=graph,
            card_ids=card_ids,
            entries=entries,
            logger=logger,
        )

    return VocabAddResponse(
        created=created,
        skipped=skipped,
        duplicates=duplicates,
        cardIds=response_card_ids,
    )
