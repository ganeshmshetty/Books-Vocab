"""Vocabulary CRUD operations: list, lookup, archive, delete, batch."""

from __future__ import annotations

import base64
import binascii
import json
import logging
from collections.abc import Callable, Collection
from datetime import UTC, datetime
from typing import Any, NamedTuple, Protocol

from .api_models import CardResponse
from .api_models.vocab import ArchiveWordResponse, DeleteWordResponse
from .exceptions import BadRequestError, NotFoundError, ValidationError
from .sentry_init import capture_handled
from .user_store import parse_datetime
from .vocab_graph_ops import link_peer_ids, touch_peers
from .vocab_shared import (
    MAX_BATCH_SIZE,
    MAX_WORD_LENGTH,
    _build_content_lookup,
    _clean_content,
    _normalize_word,
)

logger = logging.getLogger(__name__)


class VocabCursor:
    """A keyset position plus the request scope that produced it.

    The position remains a two-item sequence for the card query layer and
    compares equal to the historical ``(updated_at, id)`` tuple. ``scope`` is
    ``None`` only for legacy in-process callers; wire cursors emitted by a
    paginated request always carry ``(notebook_id, canonical_since)``.
    """

    __slots__ = ("updated_at", "card_id", "scope")

    def __init__(
        self,
        updated_at: datetime,
        card_id: str,
        scope: tuple[str | None, str | None] | None = None,
    ) -> None:
        self.updated_at = updated_at
        self.card_id = card_id
        self.scope = scope

    def __getitem__(self, index: int) -> datetime | str:
        return (self.updated_at, self.card_id)[index]

    def __iter__(self):
        return iter((self.updated_at, self.card_id))

    def __len__(self) -> int:
        return 2

    def __eq__(self, other: object) -> bool:
        if isinstance(other, VocabCursor):
            return (self.updated_at, self.card_id, self.scope) == (other.updated_at, other.card_id, other.scope)
        if isinstance(other, tuple):
            return (self.updated_at, self.card_id) == other
        return NotImplemented


def _encode_scope(scope: tuple[str | None, str | None]) -> str:
    payload = json.dumps(
        {"v": 1, "notebook": scope[0], "since": scope[1]},
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")


def encode_cursor(cursor: tuple[datetime, str] | VocabCursor | None) -> str | None:
    """Encode a cursor as ``updated_at|id|scope``.

    New response cursors include a URL-safe base64 scope payload. A plain
    two-item tuple is retained for low-level in-process callers and emits the
    historical unscoped representation; an unscoped wire cursor is rejected
    when it is used by :func:`list_vocab_cards`.
    """
    if cursor is None:
        return None
    updated_at, card_id = cursor
    token = f"{updated_at.isoformat()}|{card_id}"
    if isinstance(cursor, VocabCursor) and cursor.scope is not None:
        token += f"|{_encode_scope(cursor.scope)}"
    return token


def decode_cursor(token: str | None) -> VocabCursor | None:
    """Decode an opaque cursor token back to a scoped two-item cursor.

    The timestamp and id remain the keyset position. New tokens add a
    URL-safe base64 scope payload after a second ``|``; old two-part tokens are
    marked unscoped and are rejected by request pagination.

    The timestamp must round-trip to the **naive UTC** value stored in the card
    table verbatim. We parse with ``datetime.fromisoformat`` directly rather than
    ``parse_datetime`` because the latter reinterprets a naive ISO string as
    *local* time before converting to UTC — an 8h-class shift on a UTC+N host
    that would slide the cursor boundary backwards and re-yield the previous
    page. A naive token (the common case, since ``encode_cursor`` emits the
    stored naive value) is kept as-is; a tz-aware token is converted to UTC then
    stripped. Raises :class:`BadRequestError` on any malformed token rather than
    silently restarting pagination from the top.
    """
    if not token:
        return None
    raw_ts, sep, remainder = token.partition("|")
    if not sep or not remainder:
        raise BadRequestError("Invalid cursor")
    card_id, scope_sep, scope_token = remainder.partition("|")
    if not card_id or (scope_sep and not scope_token):
        raise BadRequestError("Invalid cursor")
    try:
        parsed = datetime.fromisoformat(raw_ts.replace("Z", "+00:00"))
    except ValueError as exc:
        raise BadRequestError("Invalid cursor") from exc
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(UTC).replace(tzinfo=None)
    if not scope_sep:
        return VocabCursor(parsed, card_id)
    try:
        padded = scope_token + "=" * (-len(scope_token) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded).decode("utf-8"))
    except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BadRequestError("Invalid cursor") from exc
    if (
        not isinstance(payload, dict)
        or payload.get("v") != 1
        or "notebook" not in payload
        or "since" not in payload
        or not (payload.get("notebook") is None or isinstance(payload.get("notebook"), str))
        or not (payload.get("since") is None or isinstance(payload.get("since"), str))
    ):
        raise BadRequestError("Invalid cursor")
    return VocabCursor(parsed, card_id, (payload["notebook"], payload["since"]))


def _resolve_with_neighbours(
    cards: list[Any],
    graph: Any,
    cards_store: Any,
) -> dict[str, Any]:
    """Build the ``cards_by_id`` map for a page: the page's own cards plus the
    graph neighbours (on other pages / soft-deleted) needed to render links.

    The page itself is a *subset* of the full table, so any neighbour not on the
    page is fetched via ``get_batch`` (one query). ``build_links_by_kind`` still
    tolerates a missing neighbour (``if not other_card``), so a cross-page or
    deleted neighbour that can't be resolved is simply skipped rather than
    dropping the whole link silently.
    """
    seed = getattr(graph, "seed", None)
    if callable(seed):
        seed(cards)
    by_id: dict[str, Any] = {c.id: c for c in cards}
    neighbour_ids: set[str] = set()
    for card in cards:
        if card.is_deleted:
            continue
        for link in graph.get_links_for(card.id):
            other_id = link.to_id if link.from_id == card.id else link.from_id
            if other_id not in by_id:
                neighbour_ids.add(other_id)
    if neighbour_ids:
        neighbours = cards_store.get_batch(neighbour_ids)
        by_id |= neighbours
        if callable(seed):
            seed(neighbours.values())
    return by_id


def _page_cursor(
    cards: list[Any],
    limit: int,
    scope: tuple[str | None, str | None],
) -> VocabCursor | None:
    """Cursor for the next page, or ``None`` when this page drained the source.

    A full page (``len == limit``) means more rows *may* remain, so emit the
    last card's ``(updated_at, id)``. A short page means the source is drained.
    """
    if limit and len(cards) == limit:
        last = cards[-1]
        return VocabCursor(last.updated_at, last.id, scope)
    return None


class VocabCard(Protocol):
    id: str
    content: str
    is_deleted: bool
    is_archived: bool
    notebook_id: str


class VocabGraph(Protocol):
    def get_links_for(self, card_id: str) -> object: ...


class CardResponseBuilder(Protocol):
    def __call__(self, card: VocabCard, graph: VocabGraph, cards_by_id: dict[str, VocabCard]) -> CardResponse: ...


def _parse_since_timestamp(raw: str) -> datetime | None:
    """Parse ``since`` while interpreting naive ISO timestamps as UTC.

    ``parse_datetime`` is retained as the fallback for its existing numeric
    timestamp support and invalid-input behavior. Parsing ISO strings here
    first preserves whether the caller supplied an offset before normalizing
    the comparison instant.
    """
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return parse_datetime(raw)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


class CardMutator(Protocol):
    def __call__(self, card: VocabCard) -> None: ...


def list_vocab_cards(
    *,
    since: str | None,
    cards_store: Any,
    graph: Any,
    card_response_builder: CardResponseBuilder,
    notebook_id: str | None = None,
    limit: int = 5000,
    after: tuple[datetime, str] | VocabCursor | None = None,
    exclude_notebook_ids: Collection[str] = (),
) -> tuple[list[CardResponse], tuple[datetime, str] | None]:
    """List vocab cards as ``(responses, next_cursor)``.

    Both the full-sync (``since=None``) and incremental (``since=...``) paths
    page by the composite cursor ``(updated_at, id)`` with a bounded ``limit``.
    ``after`` is the previous page's cursor; ``next_cursor`` is non-None only
    when a full page was returned (more rows may remain). Cards are returned in
    ascending ``(updated_at, id)`` order so the cursor advances monotonically.
    ``exclude_notebook_ids`` (global pull only) hides cards of those notebooks,
    e.g. staged copy-in-progress notebooks.
    """
    store_filter: dict[str, Any] = {}
    if notebook_id is None and exclude_notebook_ids:
        store_filter["exclude_notebook_ids"] = tuple(exclude_notebook_ids)
    request_scope: tuple[str | None, str | None] = (notebook_id, None)
    if since is not None:
        parsed_since = _parse_since_timestamp(since)
        if parsed_since is None:
            raise BadRequestError("Invalid since timestamp format. Expected ISO 8601.")
        naive_since = parsed_since.replace(tzinfo=None)
        request_scope = (notebook_id, naive_since.isoformat())
    if isinstance(after, VocabCursor):
        if after.scope is None:
            raise BadRequestError("Cursor scope is missing")
        if after.scope != request_scope:
            raise BadRequestError("Cursor scope mismatch")
    after_position = None if after is None else (after[0], after[1])
    if since is not None:
        # Incremental: SQL-bounded page in (updated_at, id) order, same cursor
        # as full-sync so both paths paginate identically.
        cards = cards_store.get_modified_since(
            naive_since, notebook_id=notebook_id, limit=limit, after=after_position, **store_filter
        )
    else:
        # Full sync: DB-bounded page (no full-table materialisation).
        cards = cards_store.page_cards(
            limit=limit,
            after=after_position,
            include_deleted=True,
            notebook_id=notebook_id,
            **store_filter,
        )

    cards_by_id = _resolve_with_neighbours(cards, graph, cards_store)
    responses = [card_response_builder(card, graph, cards_by_id) for card in cards]
    return responses, _page_cursor(cards, limit, request_scope)


def _resolve_card_or_raise(cards_store: Any, word: str, notebook_id: str | None) -> VocabCard:
    if len(word) > MAX_WORD_LENGTH:
        raise ValidationError("Word too long")
    card = cards_store.find_by_content(word, notebook_id=notebook_id)
    if not card:
        raise NotFoundError("Word", word)
    return card


def lookup_vocab_word(
    word: str,
    *,
    cards_store: Any,
    graph: Any,
    card_response_builder: CardResponseBuilder,
    notebook_id: str | None = None,
) -> CardResponse:
    card = _resolve_card_or_raise(cards_store, word, notebook_id)

    # Only fetch the target card + its graph-linked neighbours instead of full table.
    cards_by_id: dict[str, VocabCard] = {card.id: card}
    for link in graph.get_links_for(card.id):
        linked_id = link.from_id if link.to_id == card.id else link.to_id
        if linked_id not in cards_by_id:
            linked_card = cards_store.get(linked_id)
            if linked_card:
                cards_by_id[linked_id] = linked_card

    return card_response_builder(card, graph, cards_by_id)


def archive_vocab_word(
    word: str, *, archived: bool, cards_store: Any, graph: Any = None, notebook_id: str | None = None
) -> ArchiveWordResponse:
    card = _resolve_card_or_raise(cards_store, word, notebook_id)
    prior = bool(card.is_archived)
    if prior == archived:
        # Already in the requested state (idempotent retry): nothing to change.
        return ArchiveWordResponse(word=word, id=card.id, archived=archived)
    cards_store.update(card.id, is_archived=archived)
    if graph is not None:
        try:
            peer_ids = link_peer_ids(graph, card.id) if archived else set()
            if archived:
                graph.cleanup_for_card(card.id, source="manual")
            else:
                graph.restore_links_for(card.id, cards_store, source="manual")
                peer_ids = link_peer_ids(graph, card.id)
        except Exception:
            # Roll the card's archive state back to its original value so a
            # failed graph op never leaves card state and the response out of
            # sync, then re-raise (mirrors delete_vocab_word).
            logger.error("Graph operation failed for card %s", card.id, exc_info=True)
            try:
                cards_store.update(card.id, is_archived=prior)
            except Exception:
                logger.exception("Rollback failed for card %s after graph error", card.id)
            raise
        touch_peers(cards_store, peer_ids, card)
    return ArchiveWordResponse(word=word, id=card.id, archived=archived)


def update_vocab_word_content(
    word: str,
    *,
    meaning: str | None,
    note: str | None,
    explanation: str | None,
    cards_store: Any,
    graph: Any,
    card_response_builder: CardResponseBuilder,
    embeddings: Any = None,
    notebook_id: str | None = None,
) -> CardResponse:
    """Update editorial content (meaning / note) of a single card.

    A changed meaning evicts the card's vector (``embed_text`` embeds it) and
    queues the card for judging, so the pipeline re-embeds it instead of
    ranking on stale text. An unchanged meaning touches neither.

    `explanation` is a write-through alias for the `note` column; an explicit
    `note` takes precedence when both are supplied. Raises BadRequestError when
    no content field is provided (the empty-body case), NotFoundError when the
    word does not resolve in the notebook.
    """
    card = _resolve_card_or_raise(cards_store, word, notebook_id)

    updates: dict[str, Any] = {}
    if meaning is not None:
        updates["meaning"] = meaning
    note_value = note if note is not None else explanation
    if note_value is not None:
        updates["note"] = note_value

    if not updates:
        raise BadRequestError("No content fields to update")

    cards_store.update(card.id, **updates)
    if "meaning" in updates and updates["meaning"] != card.meaning:
        reembed_after_meaning_edit(embeddings, graph, card.id)

    # Re-read the card + its graph neighbours so the response reflects the
    # committed state (mirrors lookup_vocab_word's neighbour resolution).
    return lookup_vocab_word(
        word,
        cards_store=cards_store,
        graph=graph,
        card_response_builder=card_response_builder,
        notebook_id=notebook_id,
    )


def update_vocab_word_preferences(
    word: str,
    *,
    reader_hidden: bool | None,
    review_excluded: bool | None,
    cards_store: Any,
    graph: Any,
    card_response_builder: CardResponseBuilder,
    notebook_id: str | None = None,
    mode: str | None = None,
) -> CardResponse:
    """Update per-card reader/review preferences (incl. review direction) without touching SRS state."""
    card = _resolve_card_or_raise(cards_store, word, notebook_id)

    updates: dict[str, bool | str] = {}
    if reader_hidden is not None:
        updates["is_reader_hidden"] = reader_hidden
    if review_excluded is not None:
        updates["is_review_excluded"] = review_excluded
    if mode is not None:
        updates["mode"] = mode
    if not updates:
        raise BadRequestError("No card preferences to update")

    cards_store.update(card.id, **updates)
    return lookup_vocab_word(
        word,
        cards_store=cards_store,
        graph=graph,
        card_response_builder=card_response_builder,
        notebook_id=notebook_id,
    )


def evict_card_embedding(embeddings: Any, card_id: str) -> None:
    """Drop a card's vector. Best-effort: the card's durable write has already
    committed, so an embedding-store failure must not fail the request. It is
    reported through ``capture_handled`` (same path as external_api) and leaves
    at most a stale row that the next pipeline pass tolerates."""
    if embeddings is None:
        return
    try:
        embeddings.remove(card_id)
    except Exception as exc:
        logger.warning("Failed to evict embedding for card %s", card_id, exc_info=True)
        capture_handled(exc, context="vocab.embedding_evict")


def queue_card_for_judging(graph: Any, card_id: str) -> None:
    """Hand a card back to the judge queue so the pipeline re-embeds it: the
    vector was just evicted, and ``EmbeddingStore`` only embeds ids it does not
    hold. Explicit rather than waiting for a pipeline Phase 1 scan. Best-effort
    for the same reason as :func:`evict_card_embedding`."""
    if graph is None:
        return
    try:
        graph.add_pending_judge(card_id)
    except Exception as exc:
        logger.warning("Failed to queue card %s for judging", card_id, exc_info=True)
        capture_handled(exc, context="vocab.judge_requeue")


def reembed_after_meaning_edit(embeddings: Any, graph: Any, card_id: str) -> None:
    """Shared meaning-edit side effects for every content-update path: evict
    the stale vector, then queue the card. Callers invoke this only when the
    meaning actually changed (``embed_text`` embeds the meaning)."""
    evict_card_embedding(embeddings, card_id)
    queue_card_for_judging(graph, card_id)


def reembed_meaning_edits_best_effort(
    card_ids: Collection[str],
    *,
    open_embeddings: Callable[[], Any],
    open_graph: Callable[[], Any],
) -> None:
    """Re-embed cards whose meaning was already committed. Opening a store is
    lazy and best-effort: the meaning write is durable, so a store that fails
    to open must not fail the caller. Eviction depends only on the embedding
    store (#2957): a graph that fails to open skips just the judge requeue."""
    if not card_ids:
        return
    try:
        embeddings = open_embeddings()
    except Exception as exc:
        logger.warning("re-embed skipped for %d meaning edit(s): store unavailable: %s", len(card_ids), exc)
        capture_handled(exc, context="vocab.reembed_open")
        return
    try:
        graph = open_graph()
    except Exception as exc:
        logger.warning("judge requeue skipped for %d meaning edit(s): graph unavailable: %s", len(card_ids), exc)
        capture_handled(exc, context="vocab.reembed_graph_open")
        graph = None
    for card_id in card_ids:
        reembed_after_meaning_edit(embeddings, graph, card_id)


def delete_vocab_word(
    word: str,
    *,
    cards_store: Any,
    graph: Any = None,
    embeddings: Any = None,
    notebook_id: str | None = None,
) -> DeleteWordResponse:
    card = _resolve_card_or_raise(cards_store, word, notebook_id)
    cards_store.delete(card.id)
    if graph is not None:
        try:
            peer_ids = link_peer_ids(graph, card.id)
            graph.cleanup_for_card(card.id, remove_blocked=True, source="manual")
        except Exception:
            logger.error("Graph operation failed for card %s", card.id, exc_info=True)
            try:
                cards_store.restore(card.id, notebook_id=card.notebook_id)
            except Exception:
                logger.exception("Restore failed for card %s after graph error", card.id)
            raise
        touch_peers(cards_store, peer_ids, card)
    # Card is committed-deleted past this point — drop its embedding so it
    # stops polluting find_similar. Done after the rollback window so a
    # restored card keeps its vector.
    evict_card_embedding(embeddings, card.id)
    return DeleteWordResponse(deleted=word, id=card.id)


class _GraphOpFailed(Exception):
    """Signals that a per-card graph op failed (and was rolled back).

    Routes the word to the ``failed`` bucket without aborting the batch. Only
    *graph* failures use this — a store-mutation failure (e.g. a commit error)
    propagates out of ``_batch_apply`` and aborts the batch, matching the
    pre-refactor contract where the store call sat outside the graph try/except.
    """


class BulkResult(NamedTuple):
    succeeded: list[tuple[str, VocabCard]]
    not_found: list[str]
    failed: list[str]


def _batch_apply(
    words: list[str],
    *,
    cards_store: Any,
    notebook_id: str | None,
    apply: CardMutator,
) -> BulkResult:
    """Shared skeleton for batch vocab mutations.

    Validates the batch size, builds one content lookup, and runs ``apply(card)``
    for each resolved word. ``apply`` performs the card mutation + graph op; on a
    graph failure it must roll its own state back and raise ``_GraphOpFailed``,
    which routes the word to ``failed`` rather than aborting the batch. Any other
    exception propagates and aborts the batch (preserving pre-refactor behaviour
    for store-level failures).

    Returns ``(succeeded, not_found, failed)`` where ``succeeded`` is a list of
    ``(word, card)`` pairs in input order. Callers shape these into the three
    disjoint buckets the client uses to converge (see #720).
    """
    if not words:
        raise ValidationError("No words provided")
    if len(words) > MAX_BATCH_SIZE:
        raise ValidationError(f"Too many words (max {MAX_BATCH_SIZE})")

    succeeded: list[tuple[str, VocabCard]] = []
    not_found: list[str] = []
    failed: list[str] = []

    lookup = _build_content_lookup(cards_store, notebook_id=notebook_id)
    seen_words_by_key: dict[str, set[str]] = {}
    outcome_by_key: dict[str, tuple[str, VocabCard | None]] = {}

    for word in words:
        key = _normalize_word(_clean_content(word))
        seen_words = seen_words_by_key.setdefault(key, set())
        if word in seen_words:
            continue
        seen_words.add(word)
        previous = outcome_by_key.get(key)
        if previous is not None:
            status, card = previous
            if status == "succeeded" and card is not None:
                succeeded.append((word, card))
            elif status == "not_found":
                not_found.append(word)
            elif status == "failed":
                failed.append(word)
            continue
        card = lookup.get(key)
        if not card:
            not_found.append(word)
            outcome_by_key[key] = ("not_found", None)
            continue
        try:
            apply(card)
        except _GraphOpFailed:
            failed.append(word)
            outcome_by_key[key] = ("failed", None)
            continue
        succeeded.append((word, card))
        outcome_by_key[key] = ("succeeded", card)

    return BulkResult(succeeded, not_found, failed)


def batch_delete_vocab_words(
    words: list[str],
    *,
    cards_store: Any,
    graph: Any = None,
    embeddings: Any = None,
    notebook_id: str | None = None,
) -> dict[str, Any]:
    """Delete multiple words in one call. Skips not-found words instead of raising.

    Returns three disjoint buckets so the client can converge correctly:

    - ``deleted_words`` — successfully deleted (card gone, graph cleaned).
    - ``not_found`` — lookup miss only: no such card on the server. The client
      may safely converge/remove these locally.
    - ``failed`` — graph cleanup raised, so the card was restored and **still
      exists on the server**. The client must NOT converge these; the word
      should be retried on the next sync. (Routing graph failures here instead
      of ``not_found`` prevents iOS from permanently dropping a still-present
      card — see #720.)
    """

    def _delete(card: Any) -> None:
        cards_store.delete(card.id)
        if graph is not None:
            try:
                peer_ids = link_peer_ids(graph, card.id)
                graph.cleanup_for_card(card.id, remove_blocked=True, source="manual")
            except Exception as exc:
                logger.error("Graph operation failed for card %s", card.id, exc_info=True)
                try:
                    cards_store.restore(card.id, notebook_id=card.notebook_id)
                except Exception:
                    logger.exception("Restore failed for card %s after graph error", card.id)
                raise _GraphOpFailed from exc
            touch_peers(cards_store, peer_ids, card)

    succeeded, not_found, failed = _batch_apply(words, cards_store=cards_store, notebook_id=notebook_id, apply=_delete)
    deleted_words = [word for word, _ in succeeded]
    deleted_ids = [card.id for _, card in succeeded]

    # Evict embeddings for all committed-deleted cards in one batched save.
    # Best-effort: the cards are already gone, so a store failure must not
    # turn a successful delete into a request error.
    if embeddings is not None and deleted_ids:
        try:
            embeddings.remove_batch(deleted_ids)
        except Exception:
            logger.warning(
                "Failed to evict embeddings for %d deleted cards",
                len(deleted_ids),
                exc_info=True,
            )

    return {
        "deleted": len(deleted_words),
        "deleted_words": deleted_words,
        "not_found": not_found,
        "failed": failed,
    }


def batch_archive_vocab_words(
    words: list[str],
    *,
    archived: bool,
    cards_store: Any,
    graph: Any = None,
    notebook_id: str | None = None,
) -> dict[str, Any]:
    """Archive or unarchive multiple words in one call. Skips not-found words.

    Returns three disjoint buckets so the client can converge correctly:

    - ``updated_words`` — archive state successfully changed (card + graph).
    - ``not_found`` — lookup miss only: no such card on the server. The client
      may safely converge/remove these locally.
    - ``failed`` — graph cleanup/restore raised, so the archive state was rolled
      back and the card **still exists on the server** in its original state.
      The client must NOT converge these; the word should be retried on the next
      sync. (Routing graph failures here instead of ``not_found`` prevents iOS
      from permanently dropping/mislabelling a still-present card — see #720.)
    """

    def _archive(card: Any) -> None:
        prior = bool(card.is_archived)
        if prior == archived:
            return  # already in the requested state: no update, no graph op
        cards_store.update(card.id, is_archived=archived)
        if graph is not None:
            try:
                peer_ids = link_peer_ids(graph, card.id) if archived else set()
                if archived:
                    graph.cleanup_for_card(card.id, source="manual")
                else:
                    graph.restore_links_for(card.id, cards_store, source="manual")
                    peer_ids = link_peer_ids(graph, card.id)
            except Exception as exc:
                # Roll the card's archive state back to its original value so a
                # failed graph op never leaves card state and the response out of
                # sync (mirrors batch_delete_vocab_words).
                logger.error("Graph operation failed for card %s", card.id, exc_info=True)
                try:
                    cards_store.update(card.id, is_archived=prior)
                except Exception:
                    logger.exception("Rollback failed for card %s after graph error", card.id)
                raise _GraphOpFailed from exc
            touch_peers(cards_store, peer_ids, card)

    succeeded, not_found, failed = _batch_apply(words, cards_store=cards_store, notebook_id=notebook_id, apply=_archive)
    updated_words = [word for word, _ in succeeded]

    return {
        "updated": len(updated_words),
        "updated_words": updated_words,
        "not_found": not_found,
        "failed": failed,
    }
