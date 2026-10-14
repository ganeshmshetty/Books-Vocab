"""Read-only query operations for :class:`CardStore`.

Exposed as a mixin so the storage class can be split across modules
without changing the public API or method semantics.
"""

from __future__ import annotations

from collections.abc import Collection, Iterator
from datetime import UTC, datetime

from sqlalchemy import BigInteger, String, case, cast, func, literal_column, tuple_
from sqlalchemy import column as sql_column
from sqlalchemy.dialects import sqlite
from sqlmodel import Session, select

from ..text_utils import normalize_nfc_lower
from .model import Card

# Ids per IN clause in get_batch; keeps bound parameters well under SQLite's cap.
_GET_BATCH_CHUNK = 500


def _utc_instant(value: datetime) -> datetime:
    """Interpret naive database timestamps as UTC and normalize aware ones."""
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def _epoch_microseconds(value: datetime) -> int:
    """Return an exact UTC epoch key for a cursor timestamp."""
    instant = _utc_instant(value)
    epoch = datetime(1970, 1, 1, tzinfo=UTC)
    delta = instant - epoch
    return (delta.days * 86_400 + delta.seconds) * 1_000_000 + delta.microseconds


def _sql_int(value: int):
    """Inline an integer constant as SQL text (not a bind parameter).

    SQLite only matches a query expression against an expression index when
    the trees are identical, and a bound ``?`` never equals a literal. Inlining
    every constant lets the query and the index DDL compile to the same text.
    """
    return literal_column(str(int(value)))


def _sql_str(value: str):
    """Inline a string constant as SQL text (see :func:`_sql_int`)."""
    return literal_column("'" + value.replace("'", "''") + "'", String)


def _is_ascii_digit(value, position: int):
    """Build a SQLite expression that checks one timestamp character."""
    return func.substr(value, _sql_int(position), _sql_int(1)).op("GLOB")(_sql_str("[0-9]"))


def _fractional_microseconds(value):
    """Build an exact six-digit fractional-second expression for SQLite text."""

    def _prefix(length: int):
        return cast(func.substr(value, _sql_int(21), _sql_int(length)), BigInteger)

    return case(
        (func.substr(value, _sql_int(20), _sql_int(1)) != _sql_str("."), _sql_int(0)),
        (~_is_ascii_digit(value, 21), _sql_int(0)),
        (~_is_ascii_digit(value, 22), _prefix(1) * _sql_int(100_000)),
        (~_is_ascii_digit(value, 23), _prefix(2) * _sql_int(10_000)),
        (~_is_ascii_digit(value, 24), _prefix(3) * _sql_int(1_000)),
        (~_is_ascii_digit(value, 25), _prefix(4) * _sql_int(100)),
        (~_is_ascii_digit(value, 26), _prefix(5) * _sql_int(10)),
        else_=_prefix(6),
    )


def _stored_timestamp_key(column):
    """Build a UTC-microsecond key from an ISO timestamp stored in SQLite."""
    value = cast(column, String)
    seconds = cast(func.strftime(_sql_str("%s"), value), BigInteger)
    return seconds * _sql_int(1_000_000) + _fractional_microseconds(value)


def _cursor_filter(updated_at_key, after: tuple[datetime, str]):
    """Return the WHERE terms for the strict ``(updated_at, id) > after`` cursor.

    SQLite cannot seek an expression index with a row-value comparison alone
    (it falls back to a full ordered index scan), so the cheap ``key >= cursor``
    bound is added to drive the seek. The row-value term keeps the exact
    tie-break semantics: the bound is implied by it and only trims the walk.
    """
    cursor_key = _epoch_microseconds(after[0])
    return (
        updated_at_key >= cursor_key,
        tuple_(updated_at_key, Card.id) > tuple_(cursor_key, after[1]),
    )


def updated_at_key_index_sql() -> str:
    """Return the ``card`` column list of the expression index on the sync key.

    Generated from the same :func:`_stored_timestamp_key` the cursor queries
    use, so the index DDL and the query expression cannot drift apart.
    """
    expression = _stored_timestamp_key(sql_column("updated_at"))
    return str(expression.compile(dialect=sqlite.dialect(), compile_kwargs={"literal_binds": True}))


class CardQueryMixin:
    """Read-side methods of :class:`CardStore`. Requires ``self.engine``."""

    def get(self, card_id: str) -> Card | None:
        with Session(self.engine) as session:
            return session.get(Card, card_id)

    def find_by_content(self, content: str, notebook_id: str | None = None) -> Card | None:
        """Indexed case- and Unicode-insensitive lookup via `content_nfc_lower`.

        A single query against `ix_card_content_nfc_lower`; subsumes both
        case-insensitive and decomposed-Unicode (e.g. café) matching.
        """
        if not content:
            return None
        key = normalize_nfc_lower(content)
        with Session(self.engine) as session:
            stmt = select(Card).where(
                Card.content_nfc_lower == key,
                Card.is_deleted.is_(False),
            )
            if notebook_id is not None:
                stmt = stmt.where(Card.notebook_id == notebook_id)
            return session.exec(stmt).first()

    def find_by_contents(self, keys: Collection[str], notebook_id: str | None = None) -> dict[str, Card]:
        """Batch form of :meth:`find_by_content` for a request's own keys (#3830).

        ``keys`` must already be ``normalize_nfc_lower``-ed (the same key the
        ``content_nfc_lower`` index stores). Returns ``{key: card}`` for active
        cards only; the first match per key wins. Queries run in chunks of
        ``_GET_BATCH_CHUNK`` to stay under SQLite's bound-parameter cap, so the
        cost is O(keys) instead of O(notebook).
        """
        unique_keys = sorted({key for key in keys if key})
        found: dict[str, Card] = {}
        if not unique_keys:
            return found
        with Session(self.engine) as session:
            for start in range(0, len(unique_keys), _GET_BATCH_CHUNK):
                chunk = unique_keys[start : start + _GET_BATCH_CHUNK]
                stmt = select(Card).where(
                    Card.content_nfc_lower.in_(chunk),
                    Card.is_deleted.is_(False),
                )
                if notebook_id is not None:
                    stmt = stmt.where(Card.notebook_id == notebook_id)
                for card in session.exec(stmt):
                    found.setdefault(card.content_nfc_lower, card)
        return found

    def all(self, include_deleted: bool = False, notebook_id: str | None = None) -> Iterator[Card]:
        with Session(self.engine) as session:
            statement = select(Card)
            if not include_deleted:
                statement = statement.where(Card.is_deleted.is_(False))
            if notebook_id is not None:
                statement = statement.where(Card.notebook_id == notebook_id)
            results = session.exec(statement).all()
            yield from results

    def all_as_dict(self, include_deleted: bool = False, notebook_id: str | None = None) -> dict[str, Card]:
        with Session(self.engine) as session:
            statement = select(Card)
            if not include_deleted:
                statement = statement.where(Card.is_deleted.is_(False))
            if notebook_id is not None:
                statement = statement.where(Card.notebook_id == notebook_id)
            return {card.id: card for card in session.exec(statement).all()}

    def get_batch(self, card_ids: set[str]) -> dict[str, Card]:
        """Fetch multiple cards by ID in a single query.

        Intentionally notebook-agnostic — unlike the content/word-based query
        methods (find_by_content / all / count …), this is a low-level id→Card
        primitive. Card ids are already unique within a user's store, and id is
        the caller's chosen scope. Two deliberate callers rely on this: graph
        neighbour expansion (vocab_crud), whose ids come from the per-notebook
        graph and are thus already same-notebook; and cross-notebook review-state
        sync (vocab_review, notebook_id=None by design), which must reach the
        user's cards across all notebooks. Adding a notebook filter here would
        break the latter — callers needing a scoped fetch must filter the result.
        """
        if not card_ids:
            return {}
        # SQLite caps bound parameters (SQLITE_MAX_VARIABLE_NUMBER, 32766 on
        # modern builds); a large neighbour set in one IN clause raises
        # OperationalError. Chunk so the bind count stays far below the cap.
        ids = list(card_ids)
        found: dict[str, Card] = {}
        with Session(self.engine) as session:
            for start in range(0, len(ids), _GET_BATCH_CHUNK):
                statement = select(Card).where(Card.id.in_(ids[start : start + _GET_BATCH_CHUNK]))
                for card in session.exec(statement).all():
                    found[card.id] = card
        return found

    def page_cards(
        self,
        *,
        limit: int,
        after: tuple[datetime, str] | None,
        include_deleted: bool,
        notebook_id: str | None,
        exclude_notebook_ids: Collection[str] = (),
    ) -> list[Card]:
        """Return at most ``limit`` cards ordered by the composite cursor
        ``(updated_at, id)`` using a UTC-normalized row-value comparison.

        Bounded by ``.limit`` — does NOT materialise the whole table or build a
        dict. ``after`` is the ``(updated_at, id)`` of the last card of the
        previous page; ``None`` starts from the first page. Paging is gap-free
        and duplicate-free even when many cards share an ``updated_at`` because
        ``id`` breaks ties. SQLite's text timestamps are converted to exact
        UTC-microsecond keys so legacy offset-bearing rows cannot corrupt the
        cursor boundary.

        The normalized expression preserves the existing wire cursor and handles
        both canonical UTC rows and legacy ISO timestamps with offsets.
        """
        with Session(self.engine) as session:
            statement = select(Card)
            if not include_deleted:
                statement = statement.where(Card.is_deleted.is_(False))
            if notebook_id is not None:
                statement = statement.where(Card.notebook_id == notebook_id)
            elif exclude_notebook_ids:
                # Global pull: hide e.g. staged (copy-in-progress) notebooks.
                statement = statement.where(Card.notebook_id.not_in(list(exclude_notebook_ids)))
            updated_at_key = _stored_timestamp_key(Card.updated_at)
            if after is not None:
                statement = statement.where(*_cursor_filter(updated_at_key, after))
            statement = statement.order_by(updated_at_key, Card.id).limit(limit)
            return list(session.exec(statement).all())

    def get_modified_since(
        self,
        since: datetime,
        notebook_id: str | None = None,
        exclude_notebook_ids: Collection[str] = (),
        *,
        limit: int | None = None,
        after: tuple[datetime, str] | None = None,
    ) -> list[Card]:
        """Fetch cards modified after ``since`` as a UTC-instant comparison.

        The comparison runs in SQL on the same UTC-microsecond key as
        :meth:`page_cards` (SQLite stores timestamps as text, so a raw column
        compare would order mixed offsets lexicographically). Rows come back in
        ascending ``(updated_at, id)`` order in one query, with an optional
        ``after`` cursor and ``limit`` so callers can page without
        materialising the whole modified set. The boundary is exclusive and
        soft-deleted cards are included.
        """
        with Session(self.engine) as session:
            updated_at_key = _stored_timestamp_key(Card.updated_at)
            statement = select(Card).where(updated_at_key > _epoch_microseconds(since))
            if notebook_id is not None:
                statement = statement.where(Card.notebook_id == notebook_id)
            elif exclude_notebook_ids:
                statement = statement.where(Card.notebook_id.not_in(list(exclude_notebook_ids)))
            if after is not None:
                statement = statement.where(*_cursor_filter(updated_at_key, after))
            statement = statement.order_by(updated_at_key, Card.id)
            if limit is not None:
                statement = statement.limit(limit)
            return list(session.exec(statement).all())

    def count(self, notebook_id: str | None = None) -> int:
        with Session(self.engine) as session:
            statement = select(func.count()).select_from(Card).where(Card.is_deleted.is_(False))
            if notebook_id is not None:
                statement = statement.where(Card.notebook_id == notebook_id)
            return session.scalar(statement) or 0

    def count_by_notebook(self) -> dict[str, int]:
        """Single GROUP BY query returning {notebook_id: count}."""
        with Session(self.engine) as session:
            rows = session.exec(
                select(Card.notebook_id, func.count()).where(Card.is_deleted.is_(False)).group_by(Card.notebook_id)
            ).all()
            return {nb_id: cnt for nb_id, cnt in rows}
