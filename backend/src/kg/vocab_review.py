"""Review state sync operations for per-card spaced-repetition fields."""

from __future__ import annotations

import logging
from collections.abc import Collection
from datetime import UTC, datetime, timedelta
from typing import Any

from .api_models import ReviewStateEntry
from .user_store import parse_datetime
from .vocab_shared import _normalize_word

# Client clocks may run slightly ahead; beyond this a timestamp is clamped so a
# skewed device cannot freeze a card's schedule for every other device.
_MAX_CLOCK_SKEW = timedelta(minutes=5)
# Upper bound for a scheduled next review (normal schedules are in the future).
_MAX_NEXT_REVIEW_HORIZON = timedelta(days=3650)
# Columns the merge decision reads; the write is compare-and-set on them.
_CAS_FIELDS = ("last_reviewed_at", "review_count", "lapse_count")
_MAX_MERGE_ATTEMPTS = 3


def _clamp_last_reviewed(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    now = datetime.now(UTC)
    return now if value > now + _MAX_CLOCK_SKEW else value


def _clamp_next_review(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    limit = datetime.now(UTC) + _MAX_NEXT_REVIEW_HORIZON
    return limit if value > limit else value


def _merge_card_review_state(
    entry: ReviewStateEntry,
    card: Any,
    client_last: datetime,
    *,
    logger: logging.Logger,
) -> dict | None:
    """Merge one client entry into one matched card; return batch_update kwargs.

    Returns ``None`` when nothing changed (caller counts it as skipped). Policy:

    - ``entry.override`` → counts are written exactly and ``next_review_at``
      is taken from the client, on either branch (progress reset, #2042).
    - server newer-or-equal → only raise ``review_count`` / ``lapse_count`` to
      the client max (counts are monotonic and conflict-free).
    - client newer → accept the full client schedule.

    The server-newer branch mutates ``card`` in place so a card matched by
    multiple entries in the same batch sees its already-bumped counts.
    """
    server_last = parse_datetime(card.last_reviewed_at)
    if entry.override and server_last and server_last >= client_last:
        patch: dict[str, Any] = dict(
            review_count=entry.review_count,
            lapse_count=entry.lapse_count,
            review_interval_hours=entry.review_interval_hours,
            review_streak=entry.review_streak,
            last_review_feedback=entry.last_review_feedback,
        )
        override_next = _clamp_next_review(parse_datetime(entry.next_review_at))
        if override_next is not None:
            patch["next_review_at"] = override_next
        for name, value in patch.items():
            setattr(card, name, value)
        return patch
    if server_last and server_last >= client_last:
        changed = False
        if entry.review_count > card.review_count:
            card.review_count = entry.review_count
            changed = True
        if entry.lapse_count > card.lapse_count:
            card.lapse_count = entry.lapse_count
            changed = True
        if not changed:
            return None
        return dict(review_count=card.review_count, lapse_count=card.lapse_count)

    # Client is newer — accept all fields.
    parsed_next = client_next = parse_datetime(entry.next_review_at)
    raw_last = parse_datetime(entry.last_reviewed_at)
    if client_next is not None and raw_last is not None and raw_last > client_last:
        # last_reviewed_at was clamped for clock skew; the client derived
        # next_review_at from the same skewed clock, so shift it back by the
        # identical offset to keep the interval intact.
        try:
            client_next -= raw_last - client_last
        except OverflowError:  # absurd skew: the schedule is unrecoverable
            client_next = None
    client_next = _clamp_next_review(client_next)
    # Observability: a present-but-unparseable next_review_at silently resets
    # this card's schedule to None below. Surface it so bad/stale client payloads
    # are diagnosable. Skip whitespace-only / empty values, which mean "not
    # meaningfully sent" rather than malformed.
    if parsed_next is None and str(entry.next_review_at).strip():
        logger.warning(
            "push_review_states: card %s has unparseable next_review_at %r; schedule reset to None",
            card.id,
            entry.next_review_at,
        )
    return dict(
        review_interval_hours=entry.review_interval_hours,
        next_review_at=client_next,
        last_reviewed_at=client_last,
        review_count=entry.review_count if entry.override else max(entry.review_count, card.review_count),
        lapse_count=entry.lapse_count if entry.override else max(entry.lapse_count, card.lapse_count),
        review_streak=entry.review_streak,
        last_review_feedback=entry.last_review_feedback,
    )


def _coalesce_entries(existing: ReviewStateEntry, entry: ReviewStateEntry) -> ReviewStateEntry:
    """Combine two entries for one logical card: newest schedule, max counts.

    A newest ``override`` entry keeps its exact counts: max() would undo the reset.
    """
    entry_last = _clamp_last_reviewed(parse_datetime(entry.last_reviewed_at))
    existing_last = _clamp_last_reviewed(parse_datetime(existing.last_reviewed_at))
    if entry_last is None:
        return existing
    if existing_last is None:
        return entry
    newest = entry if entry_last >= existing_last else existing
    if newest.override:
        return newest
    return newest.model_copy(
        update={
            "review_count": max(entry.review_count, existing.review_count),
            "lapse_count": max(entry.lapse_count, existing.lapse_count),
        }
    )


def push_review_states(
    entries: list[ReviewStateEntry],
    *,
    cards_store: Any,
    logger: logging.Logger,
    notebook_id: str | None = None,
    exclude_notebook_ids: Collection[str] = (),
) -> dict[str, int]:
    """Merge client review states into server cards. Returns {updated, skipped}.

    When an entry carries ``card_id``, only that exact card is matched —
    preventing cross-notebook pollution for same-word cards.
    Entries without ``card_id`` fall back to word-based matching (backward compat).
    """
    excluded = frozenset(exclude_notebook_ids)
    # Build lookup indices lazily: word-index only when needed.
    cards_by_word: dict[str, list[Any]] | None = None

    def _get_cards_by_word() -> dict[str, list[Any]]:
        nonlocal cards_by_word
        if cards_by_word is None:
            cards_by_word = {}
            for card in cards_store.all(notebook_id=notebook_id):
                if card.is_deleted or card.notebook_id in excluded:
                    continue
                cards_by_word.setdefault(_normalize_word(card.content), []).append(card)
        return cards_by_word

    updated = 0
    # Coalesce logical-card entries before merging. The CardStore batch writer
    # also keys updates by card id, so leaving duplicate tuples pending would
    # let their input order decide which schedule survives. Legacy entries
    # without card_id use normalized word identity for the same reason.
    coalesced_entries: list[ReviewStateEntry] = []
    entry_positions: dict[tuple[str, str], int] = {}
    duplicate_entries = 0
    for entry in entries:
        key = ("card_id", entry.card_id) if entry.card_id else ("word", _normalize_word(entry.word))
        position = entry_positions.get(key)
        if position is None:
            entry_positions[key] = len(coalesced_entries)
            coalesced_entries.append(entry)
            continue

        duplicate_entries += 1
        coalesced_entries[position] = _coalesce_entries(coalesced_entries[position], entry)

    skipped = duplicate_entries
    # Pre-fetch all cards with card_id in one batch to avoid N+1
    _card_ids_to_fetch = {e.card_id for e in coalesced_entries if e.card_id}
    _cards_by_id = cards_store.get_batch(_card_ids_to_fetch) if _card_ids_to_fetch else {}
    # Entries of different key spaces (card_id vs word) can resolve to one card;
    # coalesce per card id so the batch writer never sees competing tuples.
    work_by_card: dict[str, tuple[ReviewStateEntry, datetime, Any]] = {}
    for entry in coalesced_entries:
        # Prefer card_id for precise matching; fall back to word matching.
        if entry.card_id:
            card = _cards_by_id.get(entry.card_id)
            eligible = card is not None and not card.is_deleted and card.notebook_id not in excluded
            cards = [card] if eligible else []
        else:
            cards = _get_cards_by_word().get(_normalize_word(entry.word), [])
        if not cards:
            skipped += 1
            continue

        client_last = _clamp_last_reviewed(parse_datetime(entry.last_reviewed_at))
        if client_last is None:
            skipped += 1
            continue
        for card in cards:
            held = work_by_card.get(card.id)
            if held is None:
                work_by_card[card.id] = (entry, client_last, card)
                continue
            skipped += 1
            merged = _coalesce_entries(held[0], entry)
            merged_last = _clamp_last_reviewed(parse_datetime(merged.last_reviewed_at)) or held[1]
            work_by_card[card.id] = (merged, merged_last, card)
    work = list(work_by_card.values())

    # The merge decision is based on a snapshot, so the write is compare-and-set
    # on the fields the decision read; a card changed by a concurrent writer is
    # re-read and re-merged instead of overwritten.
    for attempt in range(_MAX_MERGE_ATTEMPTS):
        if not work:
            break
        pending: list[tuple[str, dict, dict]] = []
        owners: dict[str, list[tuple[ReviewStateEntry, datetime]]] = {}
        guards: dict[str, dict] = {}
        for entry, client_last, card in work:
            guards.setdefault(card.id, {name: getattr(card, name) for name in _CAS_FIELDS})
            update = _merge_card_review_state(entry, card, client_last, logger=logger)
            if update is None:
                skipped += 1
                continue
            pending.append((card.id, update, guards[card.id]))
            owners.setdefault(card.id, []).append((entry, client_last))
        if not pending:
            break
        rejected = set(cards_store.batch_update_if_unchanged(pending))
        updated += len(pending) - sum(1 for item in pending if item[0] in rejected)
        if not rejected:
            break
        fresh = cards_store.get_batch(rejected)
        work = []
        for card_id in rejected:
            card = fresh.get(card_id)
            if card is None or card.is_deleted:
                skipped += len(owners[card_id])
                continue
            work.extend((entry, client_last, card) for entry, client_last in owners[card_id])
        if attempt == _MAX_MERGE_ATTEMPTS - 1 and work:
            logger.warning("push_review_states: %d card update(s) kept conflicting; skipped", len(work))
            skipped += len(work)
    return {"updated": updated, "skipped": skipped}
