"""Write/mutation operations for :class:`CardStore`.

Covers create, soft-delete/restore, dedup, touch and update — including
the batched and notebook-scoped variants used by the sync path. Exposed
as a mixin so the storage class can be split across modules without
changing the public API or method semantics.
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta

from sqlalchemy import update as sa_update
from sqlalchemy.exc import IntegrityError
from sqlmodel import Session, select

from ..text_utils import normalize_nfc, normalize_nfc_lower
from .model import Card
from .query import _epoch_microseconds, _stored_timestamp_key

_LOGGER = logging.getLogger(__name__)


class CardMutationMixin:
    """Write-side methods of :class:`CardStore`. Requires ``self.engine``."""

    def add(
        self,
        content: str,
        meaning: str,
        pos: str | None = None,
        examples: list[str] | None = None,
        collocations: list[str] | None = None,
        mode: str = "recognition",
        root_form: str | None = None,
        inflections: list[str] | None = None,
        notebook_id: str = "default",
        source: str | None = None,
    ) -> Card:
        """Create and store a new card.

        SQLite WAL mode with busy_timeout serialises writers, so the
        check-then-insert within a single Session is safe against most
        races.  The UNIQUE partial index on (content, notebook_id) is the
        true safety net — if a duplicate slips through, IntegrityError
        catches it and we return the existing card.
        """
        if not content or not content.strip():
            raise ValueError("content must be non-empty")
        norm = normalize_nfc(content)
        content_key = normalize_nfc_lower(content)
        with Session(self.engine) as session:
            row = (
                session.connection()
                .exec_driver_sql(
                    "SELECT id FROM card WHERE content_nfc_lower = ? AND notebook_id = ? AND is_deleted = 0 LIMIT 1",
                    (content_key, notebook_id),
                )
                .first()
            )
            if row:
                return session.get(Card, row[0])  # type: ignore[return-value]

            card = Card(
                content=norm,
                content_nfc_lower=content_key,
                meaning=meaning,
                pos=pos,
                examples=examples or [],
                collocations=collocations or [],
                mode=mode,
                root_form=root_form,
                inflections=inflections or [],
                notebook_id=notebook_id,
                source=source,
            )
            session.add(card)
            try:
                session.commit()
            except IntegrityError:
                _LOGGER.debug(
                    "add() duplicate detected for content=%r notebook=%s; returning existing row",
                    norm,
                    notebook_id,
                    exc_info=True,
                )
                session.rollback()
                row = (
                    session.connection()
                    .exec_driver_sql(
                        "SELECT id FROM card WHERE content_nfc_lower = ? "
                        "AND notebook_id = ? AND is_deleted = 0 LIMIT 1",
                        (content_key, notebook_id),
                    )
                    .first()
                )
                if row:
                    return session.get(Card, row[0])  # type: ignore[return-value]
                raise
            session.refresh(card)
        return card

    def add_shared_copy(
        self,
        *,
        content: str,
        meaning: str,
        pos: str | None,
        examples: list[str] | None,
        collocations: list[str] | None,
        note: str | None,
        difficulty: float | None,
        mode: str,
        root_form: str | None,
        inflections: list[str] | None,
        notebook_id: str,
        updated_at: datetime,
        source_shared_card_guid: str,
    ) -> tuple[Card, bool]:
        """Insert one card as a copy of a ``shared_deck_card`` (Phase 2 copy).

        Unlike :meth:`add`, this carries the full content plane (``note`` /
        ``difficulty`` too), an explicit strictly-monotonic ``updated_at`` (the
        §4.4 sync-down timestamp-tie defense), and the
        ``source_shared_card_guid`` provenance. SRS columns take their model
        defaults (a fresh review schedule — the author's schedule cannot leak)
        and the id is freshly minted.

        Returns ``(card, created)``. ``created`` is ``False`` when a NOCASE/NFC
        duplicate already occupies ``(content, notebook_id)`` — the copy
        orchestrator treats that collapse as a fail-loud count mismatch rather
        than a silently dropped card.
        """
        if not content or not content.strip():
            raise ValueError("content must be non-empty")
        norm = normalize_nfc(content)
        content_key = normalize_nfc_lower(content)
        with Session(self.engine) as session:
            row = (
                session.connection()
                .exec_driver_sql(
                    "SELECT id FROM card WHERE content_nfc_lower = ? AND notebook_id = ? AND is_deleted = 0 LIMIT 1",
                    (content_key, notebook_id),
                )
                .first()
            )
            if row:
                return session.get(Card, row[0]), False  # type: ignore[return-value]

            card = Card(
                content=norm,
                content_nfc_lower=content_key,
                meaning=meaning,
                pos=pos,
                examples=examples or [],
                collocations=collocations or [],
                note=note or None,
                difficulty=difficulty,
                mode=mode,
                root_form=root_form,
                inflections=inflections or [],
                notebook_id=notebook_id,
                updated_at=updated_at,
                source_shared_card_guid=source_shared_card_guid,
            )
            session.add(card)
            try:
                session.commit()
            except IntegrityError:
                session.rollback()
                row = (
                    session.connection()
                    .exec_driver_sql(
                        "SELECT id FROM card WHERE content_nfc_lower = ? "
                        "AND notebook_id = ? AND is_deleted = 0 LIMIT 1",
                        (content_key, notebook_id),
                    )
                    .first()
                )
                if row:
                    return session.get(Card, row[0]), False  # type: ignore[return-value]
                raise
            session.refresh(card)
        return card, True

    def deduplicate(self, notebook_id: str | None = None) -> int:
        """Remove duplicate active cards (same content, case-insensitive).

        Keeps the card with the most review activity (highest review_count),
        breaking ties by earliest created_at.  The kept card's updated_at
        is bumped so that incremental sync picks it up *after* the
        soft-deleted duplicate, preventing order-dependent client-side
        mis-deletion.  Returns the number of duplicates removed.
        """
        removed = 0
        cards = list(self.all(include_deleted=False, notebook_id=notebook_id))
        seen: dict[tuple[str, str], Card] = {}
        to_delete: list[Card] = []
        deleted_keys: set[tuple[str, str]] = set()

        for card in cards:
            # Scope by notebook: with notebook_id=None the same word in different
            # notebooks is not a duplicate (#2695).
            key = (card.notebook_id, normalize_nfc_lower(card.content))
            if key in seen:
                keeper = seen[key]
                if (card.review_count, -card.created_at.timestamp()) > (
                    keeper.review_count,
                    -keeper.created_at.timestamp(),
                ):
                    to_delete.append(keeper)
                    seen[key] = card
                else:
                    to_delete.append(card)
                deleted_keys.add(key)
            else:
                seen[key] = card

        if to_delete:
            # Keeper per affected key is the final survivor in `seen` (the loop
            # may have swapped which card is kept). Re-derive from deleted_keys.
            keepers_to_bump = [seen[key].id for key in deleted_keys]

            now = datetime.now(UTC)
            with Session(self.engine) as session:
                for card in to_delete:
                    db_card = session.get(Card, card.id)
                    if db_card:
                        db_card.is_deleted = True
                        db_card.updated_at = now
                        removed += 1
                # Bump keepers' updated_at AFTER the deletes so that
                # incremental sync always sees: delete first, then
                # the valid card — ensuring correct convergence.
                bump_time = now + timedelta(milliseconds=1)
                for keeper_id in keepers_to_bump:
                    keeper = session.get(Card, keeper_id)
                    if keeper:
                        keeper.updated_at = bump_time
                session.commit()

        return removed

    def soft_delete_by_notebook(self, notebook_id: str) -> int:
        """Soft-delete all non-deleted cards in a notebook. Returns count."""
        if not notebook_id:
            raise ValueError("notebook_id required")
        now = datetime.now(UTC)
        with Session(self.engine) as session:
            cards = session.exec(
                select(Card).where(
                    Card.notebook_id == notebook_id,
                    Card.is_deleted.is_(False),
                )
            ).all()
            for card in cards:
                card.is_deleted = True
                card.updated_at = now
                session.add(card)
            session.commit()
            return len(cards)

    def restamp_by_notebook(self, notebook_id: str, start: datetime) -> int:
        """Re-stamp ``updated_at`` of a notebook's active cards to
        ``start + i ms`` in their existing ``(updated_at, id)`` order. Used when
        a staged copy is revealed: the cards were hidden from global pulls, so a
        device whose incremental boundary fell inside the copy window would
        otherwise never see them (their old timestamps predate its boundary).
        Returns the number of cards re-stamped."""
        if not notebook_id:
            raise ValueError("notebook_id required")
        with Session(self.engine) as session:
            cards = session.exec(
                select(Card)
                .where(Card.notebook_id == notebook_id, Card.is_deleted.is_(False))
                .order_by(Card.updated_at, Card.id)
            ).all()
            for i, card in enumerate(cards):
                card.updated_at = start + timedelta(milliseconds=i)
                session.add(card)
            session.commit()
            return len(cards)

    def delete(self, card_id: str) -> bool:
        """Soft deletes the card to support incremental sync."""
        with Session(self.engine) as session:
            card = session.get(Card, card_id)
            if card and not card.is_deleted:
                card.is_deleted = True
                card.updated_at = datetime.now(UTC)
                session.add(card)
                session.commit()
                return True
        return False

    def restore(self, card_id: str, *, notebook_id: str | None = None) -> bool:
        """Undo a soft-delete. Returns True if restored, False if card not found or
        superseded by an active card with the same content (never raises for that).

        If `notebook_id` is provided, the card is only restored when it
        actually belongs to that notebook; an id pointing at another
        notebook is left untouched and False is returned. This mirrors
        `batch_touch`'s cross-notebook defense — without it a client in a
        notebook-migration/orphan scenario could resurrect a card into the
        wrong notebook and let its bumped `updated_at` clobber a later
        genuine delete under last-writer-wins sync.
        """
        with Session(self.engine) as session:
            card = session.get(Card, card_id)
            if card and (notebook_id is None or card.notebook_id == notebook_id):
                card.is_deleted = False
                card.updated_at = datetime.now(UTC)
                try:
                    session.commit()
                except IntegrityError:
                    # An active card with the same content was added after the
                    # delete; the partial unique index rejects the revive. The
                    # tombstone is superseded, so report not-restored.
                    session.rollback()
                    _LOGGER.warning("restore of card %s superseded by an active duplicate", card_id)
                    return False
                return True
            return False

    def touch(self, card_id: str) -> bool:
        """Bump updated_at without changing any fields. Returns True if card was touched."""
        with Session(self.engine) as session:
            card = session.get(Card, card_id)
            if card and not card.is_deleted:
                card.updated_at = datetime.now(UTC)
                session.add(card)
                session.commit()
                return True
            return False

    def batch_touch(
        self,
        card_ids: set[str] | list[str],
        *,
        notebook_id: str | None = None,
    ) -> int:
        """Bump updated_at for multiple cards in a single transaction.

        If `notebook_id` is provided, only cards in that notebook are touched;
        ids outside the notebook are silently skipped. This is a defense
        against cross-notebook touch when callers derive ids from links that
        should all belong to the same notebook.
        """
        if not card_ids:
            return 0
        now = datetime.now(UTC)
        conditions = [Card.id.in_(set(card_ids)), Card.is_deleted.is_(False)]
        if notebook_id is not None:
            conditions.append(Card.notebook_id == notebook_id)
        with Session(self.engine) as session:
            cards = session.exec(select(Card).where(*conditions)).all()
            for card in cards:
                card.updated_at = now
                session.add(card)
            session.commit()
            return len(cards)

    def update(self, card_id: str, **kwargs) -> Card | None:
        """Update specific fields of a card. Automatically sets updated_at."""
        with Session(self.engine) as session:
            card = session.get(Card, card_id)
            if not card or card.is_deleted:
                return None
            has_changes = False
            for key, value in kwargs.items():
                if hasattr(card, key) and getattr(card, key) != value:
                    setattr(card, key, value)
                    has_changes = True
            if "content" in kwargs:
                card.content_nfc_lower = normalize_nfc_lower(card.content)

            if has_changes:
                card.updated_at = datetime.now(UTC)
                session.add(card)
                session.commit()
                session.refresh(card)
            return card

    def bump_enrich_attempts(self, card_ids: list[str]) -> int:
        """Increment ``enrich_attempts`` for cards. Deliberately leaves ``updated_at`` alone
        (server-only bookkeeping must not churn incremental sync)."""
        if not card_ids:
            return 0
        with Session(self.engine) as session:
            result = session.execute(
                sa_update(Card)
                .where(Card.id.in_(set(card_ids)))
                .values(enrich_attempts=Card.enrich_attempts + 1)
                .execution_options(synchronize_session=False)
            )
            session.commit()
            return result.rowcount or 0

    def batch_update(self, updates: list[tuple[str, dict]]) -> int:
        """Update multiple cards in a single transaction. Returns count of actually changed cards."""
        if not updates:
            return 0
        changed = 0
        card_ids = {card_id for card_id, _ in updates}
        kwargs_by_id = {card_id: kwargs for card_id, kwargs in updates}
        now = datetime.now(UTC)
        with Session(self.engine) as session:
            # Single WHERE IN query instead of N individual session.get() calls
            cards_by_id = {card.id: card for card in session.exec(select(Card).where(Card.id.in_(card_ids))).all()}
            for card_id, card in cards_by_id.items():
                if card.is_deleted:
                    continue
                kwargs = kwargs_by_id[card_id]
                has_changes = False
                for key, value in kwargs.items():
                    if hasattr(card, key) and getattr(card, key) != value:
                        setattr(card, key, value)
                        has_changes = True
                if "content" in kwargs:
                    # Keep the denormalized search index in sync — mirrors update().
                    # Without this, find_by_content (which matches solely on
                    # content_nfc_lower) silently breaks for any future caller
                    # that mutates content through the batch path.
                    card.content_nfc_lower = normalize_nfc_lower(card.content)
                if has_changes:
                    card.updated_at = now
                    session.add(card)
                    changed += 1
            session.commit()
        return changed

    def batch_update_if_unchanged(self, updates: list[tuple[str, dict, dict]]) -> list[str]:
        """Compare-and-set variant of :meth:`batch_update` for read-merge-write callers.

        Each item is ``(card_id, kwargs, expected)``; ``expected`` maps column
        names to the values the caller's merge decision was based on. The write
        is one ``UPDATE ... WHERE id = ? AND is_deleted = 0 AND <expected>``, so
        a concurrent writer that changed any guarded column makes it a no-op.
        Returns the ids that were not written (conflicted, deleted or missing)
        so the caller can re-read and re-merge instead of clobbering.

        ``updated_at`` (the pull-sync cursor) is always bumped, so callers must
        pass only effective changes.
        """
        if not updates:
            return []
        now = datetime.now(UTC)
        rejected: list[str] = []
        with Session(self.engine) as session:
            for card_id, (kw, expected) in {cid: (kw, ex) for cid, kw, ex in updates}.items():
                conditions = [Card.id == card_id, Card.is_deleted.is_(False)]
                for column, value in expected.items():
                    attr = getattr(Card, column)
                    if value is None:
                        conditions.append(attr.is_(None))
                    elif isinstance(value, datetime):
                        # Compare by UTC instant: stored text may lack microseconds,
                        # use a T separator or carry an offset.
                        conditions.append(_stored_timestamp_key(attr) == _epoch_microseconds(value))
                    else:
                        conditions.append(attr == value)
                result = session.exec(sa_update(Card).where(*conditions).values(**kw, updated_at=now))
                if result.rowcount == 0:
                    rejected.append(card_id)
            session.commit()
        return rejected
