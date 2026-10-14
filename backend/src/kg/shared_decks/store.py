"""SQLite-backed :class:`SharedDeckStore` — the global shared-decks catalog.

Unlike the per-user stores (cards/notebook/library), this store is a **single
global** SQLite file at ``data_dir/shared_decks.db``. A shared deck's owner is
the ``owner_id`` *column* (``NULL`` for official decks), never encoded in the
path — the same cross-user shape as ``translate_log``. It is therefore OUTSIDE
the per-user backup/erasure scope and needs its own hooks (Phase 1b / §3.5);
``delete_copy_logs_for`` is the account-erasure hook for ``shared_deck_copy_log``.

Six tables (all six ``table=True`` class names are **globally unique** so
SQLModel's shared metadata registry never trips ``InvalidRequestError``, the
failure ``library/store.py`` documents):

* ``shared_deck``        — metadata / index / moderation plane
* ``shared_deck_version``— immutable versioned payload pointer
* ``shared_deck_card``   — **content plane ONLY** (structurally zero SRS columns)
* ``shared_deck_rating`` — one-vote-per-user authority (Phase 3 write path)
* ``shared_deck_report`` — reactive moderation (Phase 3 write path)
* ``shared_deck_copy_log``— copy idempotency + rating-eligibility gate

The rating/report/copy_log tables carry their forward-compat columns from
day one so opening the community-UGC write path later needs no migration.
"""

from __future__ import annotations

import hashlib
import json
import secrets
import uuid
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import JSON, Column, String, UniqueConstraint, cast, delete, event, exists, func, or_, tuple_
from sqlalchemy.exc import IntegrityError
from sqlmodel import Field as SQLField
from sqlmodel import Session, SQLModel, select

from ..sqlite_utils import ensure_columns, make_sqlite_engine
from ..text_utils import normalize_nfc_lower

# Discovery WHERE (browse + detail): a deck is publicly reachable only when all
# three orthogonal axes clear. Official decks carry visibility='official'.
_DISCOVERABLE_VISIBILITY = ("public", "official")

# Deterministic namespace for shared-deck card identity. ``content_guid`` covers
# (content, pos, mode, meaning) so homographs (``lead`` the metal vs the verb)
# never collapse into a single card under uq_shared_deck_card_guid (§2.1).
_CARD_GUID_NAMESPACE = uuid.UUID("7d1f4e2a-9c3b-5a86-b0d4-2f6e8c1a4b90")


def card_content_guid(content: str, pos: str | None, mode: str, meaning: str) -> str:
    """Stable per-card identity over the discriminating axes. Case/diacritic
    folded on content+meaning; pos+mode kept verbatim so a homograph pair with
    different part-of-speech resolves to two distinct guids."""
    key = "|".join(
        (
            normalize_nfc_lower(content),
            pos or "",
            mode or "recognition",
            normalize_nfc_lower(meaning),
        )
    )
    return str(uuid.uuid5(_CARD_GUID_NAMESPACE, key))


def canonical_card(card: dict) -> dict:
    """Normalize a content-plane card dict (snake_case) into a deterministic
    shape used for hashing, insertion and round-trip projection. Carries the
    derived ``content_guid`` so callers never recompute it inconsistently."""
    content = str(card.get("content") or "")
    meaning = str(card.get("meaning") or "")
    pos = card.get("pos") or None
    mode = card.get("mode") or "recognition"
    return {
        "content_guid": card_content_guid(content, pos, mode, meaning),
        "content": content,
        "pos": pos,
        "meaning": meaning,
        "examples": list(card.get("examples") or []),
        "collocations": list(card.get("collocations") or []),
        "note": card.get("note") or None,
        "difficulty": card.get("difficulty"),
        "mode": mode,
        "root_form": card.get("root_form") or None,
        "inflections": list(card.get("inflections") or []),
    }


def deck_content_hash(cards: list[dict]) -> str:
    """SHA-256 over the content plane with deterministic ordering, excluding all
    timestamps (§2.3). Same content → same hash → idempotent re-emit; a content
    change flips the hash → new version. Input cards are snake_case dicts.

    Dedups by ``content_guid`` (first wins) BEFORE hashing so the hash matches
    what ``publish_official`` actually stores — a spec with colliding cards
    yields the same hash as its deduped form, keeping dry-run/commit consistent.
    """
    deduped: dict[str, dict] = {}
    for c in cards:
        cc = canonical_card(c)
        deduped.setdefault(cc["content_guid"], cc)
    canonical = sorted(deduped.values(), key=lambda c: c["content_guid"])
    blob = json.dumps(canonical, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _mint_deck_id() -> str:
    """Server-minted deck id matching ``^[A-Za-z0-9_-]{1,64}$`` (= deep-link
    identifier). ``token_urlsafe`` yields exactly that alphabet."""
    return secrets.token_urlsafe(12)


class SharedDeck(SQLModel, table=True):
    """Metadata / index / moderation plane for a shared deck.

    Three orthogonal deletion axes (never overwrite each other):
    ``visibility`` (exposure) × ``status`` (moderation) × ``is_deleted``
    (existence). Browse discovery hard-filters ``is_deleted=0 AND
    status='active' AND visibility='public'``.
    """

    __tablename__ = "shared_deck"
    __table_args__ = (
        # Republish idempotency: an (owner, source notebook) pair upserts in
        # place. NULLs are distinct in SQLite UNIQUE, so official decks
        # (owner_id=NULL) are intentionally unconstrained here.
        UniqueConstraint("owner_id", "source_notebook_id", name="uq_shared_deck_owner_source"),
    )

    id: str = SQLField(default_factory=_mint_deck_id, primary_key=True)
    owner_id: str | None = SQLField(default=None, index=True)  # NULL = official
    source_notebook_id: str | None = SQLField(default=None)  # author-side republish key
    title: str = SQLField(default="")
    description: str | None = SQLField(default=None)
    # Coarse filter enum: 'language'|'exam'|'phrase'|'custom'
    category: str | None = SQLField(default=None)
    tags: list[str] = SQLField(default_factory=list, sa_column=Column(JSON))
    language_pair: str | None = SQLField(default=None)  # e.g. 'en-zh'
    # server-authoritative: 'official'|'community' — NEVER read from request body
    source: str = SQLField(default="community")
    publisher_display_name: str | None = SQLField(default=None)  # snapshot at publish
    # exposure axis: 'private'|'unlisted'|'public'|'official'
    visibility: str = SQLField(default="private")
    share_token: str | None = SQLField(default=None, unique=True)  # unlisted access
    # moderation axis: 'active'|'under_review'|'removed'
    status: str = SQLField(default="active")
    is_deleted: bool = SQLField(default=False)  # existence axis (owner soft-unpublish)
    current_version: int = SQLField(default=0)  # atomically flipped pointer
    card_count: int = SQLField(default=0)
    color: str | None = SQLField(default=None)
    cover_pattern: str | None = SQLField(default=None)  # procedural cover; no image v1
    title_nfc_lower: str = SQLField(default="", index=True)  # search key
    download_count: int = SQLField(default=0)
    rating_sum: int = SQLField(default=0)  # denormalized cache (authority=rating table)
    rating_count: int = SQLField(default=0)
    report_count: int = SQLField(default=0)
    created_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))
    updated_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))


class SharedDeckVersion(SQLModel, table=True):
    """Immutable payload pointer. Republish mints a new (deck, version) row;
    ``SharedDeck.current_version`` flips to it atomically. The composite PK is
    what catches concurrent-republish races via ``IntegrityError`` — not a
    ``threading.Lock``.
    """

    __tablename__ = "shared_deck_version"

    shared_deck_id: str = SQLField(primary_key=True)
    version: int = SQLField(primary_key=True)
    content_hash: str = SQLField(default="")  # over content plane, excl. timestamps
    payload_schema_version: int = SQLField(default=1)  # tolerate replaying old payloads
    created_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))


class SharedDeckCard(SQLModel, table=True):
    """Content plane ONLY — structurally zero SRS columns.

    A publish path cannot leak the 7 review columns because they do not exist
    here. ``content_guid`` covers (content, pos, mode, meaning) so homographs
    (``lead`` metal vs verb) do not collide into one guid.
    """

    __tablename__ = "shared_deck_card"
    __table_args__ = (UniqueConstraint("shared_deck_id", "version", "content_guid", name="uq_shared_deck_card_guid"),)

    id: str = SQLField(default_factory=lambda: secrets.token_urlsafe(9), primary_key=True)
    shared_deck_id: str = SQLField(index=True)
    version: int = SQLField(default=0)
    content_guid: str = SQLField(default="")
    content: str = SQLField(default="")
    pos: str | None = SQLField(default=None)
    meaning: str = SQLField(default="")
    examples: list[str] = SQLField(default_factory=list, sa_column=Column(JSON))
    collocations: list[str] = SQLField(default_factory=list, sa_column=Column(JSON))
    note: str | None = SQLField(default=None)
    difficulty: float | None = SQLField(default=None)
    mode: str = SQLField(default="recognition")
    root_form: str | None = SQLField(default=None)
    inflections: list[str] = SQLField(default_factory=list, sa_column=Column(JSON))


class SharedDeckRating(SQLModel, table=True):
    """One-vote-per-user authority (Phase 3 write path). ``rating_sum`` /
    ``rating_count`` on ``shared_deck`` are a denormalized cache of this table."""

    __tablename__ = "shared_deck_rating"

    shared_deck_id: str = SQLField(primary_key=True)
    user_id: str = SQLField(primary_key=True)
    stars: int = SQLField(default=0)  # 1-5
    updated_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))


class SharedDeckReport(SQLModel, table=True):
    """Reactive moderation (Phase 3 write path). One report per reporter
    (composite PK) blocks Sybil report-stuffing."""

    __tablename__ = "shared_deck_report"

    shared_deck_id: str = SQLField(primary_key=True)
    reporter_id: str = SQLField(primary_key=True)
    # reason ∈ {'spam','offensive','copyright','pii','other'}
    reason: str = SQLField(default="other")
    created_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))


class SharedDeckCopyLog(SQLModel, table=True):
    """Copy idempotency store + exactly-once download finalizer."""

    __tablename__ = "shared_deck_copy_log"

    copier_id: str = SQLField(primary_key=True)
    idempotency_key: str = SQLField(primary_key=True)
    source_shared_deck_id: str = SQLField(default="")
    source_version: int = SQLField(default=0)
    result_notebook_id: str = SQLField(default="")
    # The marker and shared-deck counter are committed in one transaction so a
    # retry can distinguish a committed count from a crash before finalization.
    download_counted: bool = SQLField(default=False)
    created_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))


_SHARED_DECK_TABLES = [
    SharedDeck.__table__,
    SharedDeckVersion.__table__,
    SharedDeckCard.__table__,
    SharedDeckRating.__table__,
    SharedDeckReport.__table__,
    SharedDeckCopyLog.__table__,
]


class SharedDeckStore:
    """SQLite-based global shared-decks catalog. One engine per process (cached
    under a user-independent key by ``deps``), not per request."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.engine = make_sqlite_engine(self.path)

        # SQLite's builtin lower() folds ASCII only, so 'École' would never match
        # 'école'; search uses this Unicode-aware function for publisher/tags.
        @event.listens_for(self.engine, "connect")
        def _register_unicode_lower(dbapi_conn, _record) -> None:
            dbapi_conn.create_function(
                "kg_lower", 1, lambda v: None if v is None else normalize_nfc_lower(str(v)), deterministic=True
            )

        # Explicit table list (not a bare ``metadata.create_all``): the shared
        # SQLModel registry also holds Card/Notebook/... — only ours here.
        SQLModel.metadata.create_all(self.engine, tables=_SHARED_DECK_TABLES, checkfirst=True)
        self._migrate_copy_log()

    def _migrate_copy_log(self) -> None:
        """Add the exactly-once counter marker to pre-existing copy logs.

        A legacy row came from the old copy path, whose finalizer counted the
        download before returning. Treating those rows as already finalized
        preserves historical counts when the new replay path is deployed.
        """
        with self.engine.connect() as conn:
            ensure_columns(
                conn,
                SharedDeckCopyLog.__tablename__,
                {"download_counted": "INTEGER NOT NULL DEFAULT 1"},
            )
            conn.commit()

    def close(self) -> None:
        """Dispose the engine (required for LRU eviction — see LibraryStore)."""
        if self.engine is not None:
            self.engine.dispose()
            self.engine = None

    # ── read side (Phase 1b browse) ────────────────────────────────

    def get(self, deck_id: str) -> SharedDeck | None:
        """Return a deck only if it is publicly discoverable; else ``None``
        (the router maps that to 404, not leaking existence of hidden decks)."""
        with Session(self.engine) as session:
            deck = session.get(SharedDeck, deck_id)
            if (
                deck is None
                or deck.is_deleted
                or deck.status != "active"
                or deck.visibility not in _DISCOVERABLE_VISIBILITY
            ):
                return None
            return deck

    def get_any(self, deck_id: str) -> SharedDeck | None:
        """Return a deck row regardless of discoverability. Internal only: copy
        replay and the reveal sweep settle copies of decks that may since have
        been hidden or unpublished (#3898). Never expose through browse or get."""
        with Session(self.engine) as session:
            return session.get(SharedDeck, deck_id)

    def browse(
        self,
        *,
        limit: int,
        sort: str = "recency",
        after: tuple[object, str] | None = None,
        q: str | None = None,
        category: str | None = None,
        language_pair: str | None = None,
        official: bool | None = None,
    ) -> list[SharedDeck]:
        """Keyset page of discoverable decks. ``after`` = ``(sort_value, id)`` of
        the previous page's last row. ``sort`` ∈ {recency, alpha} — Phase 1 only
        (popularity/rating have no data yet, so those sorts are withheld)."""
        with Session(self.engine) as session:
            stmt = select(SharedDeck).where(
                SharedDeck.is_deleted == False,  # noqa: E712
                SharedDeck.status == "active",
                SharedDeck.visibility.in_(_DISCOVERABLE_VISIBILITY),
            )
            if q:
                needle = normalize_nfc_lower(q).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                pattern = f"%{needle}%"
                tag_values = func.json_each(SharedDeck.tags).table_valued("value").alias("shared_deck_tags")
                stmt = stmt.where(
                    or_(
                        SharedDeck.title_nfc_lower.like(pattern, escape="\\"),
                        func.kg_lower(cast(SharedDeck.publisher_display_name, String)).like(pattern, escape="\\"),
                        exists(
                            select(1)
                            .select_from(tag_values)
                            .where(func.kg_lower(cast(tag_values.c.value, String)).like(pattern, escape="\\"))
                        ),
                    )
                )
            if category:
                stmt = stmt.where(SharedDeck.category == category)
            if language_pair:
                stmt = stmt.where(SharedDeck.language_pair == language_pair)
            if official is True:
                stmt = stmt.where(SharedDeck.source == "official")
            elif official is False:
                stmt = stmt.where(SharedDeck.source == "community")

            if sort == "alpha":
                key = tuple_(SharedDeck.title_nfc_lower, SharedDeck.id)
                if after is not None:
                    stmt = stmt.where(key > tuple_(after[0], after[1]))
                stmt = stmt.order_by(SharedDeck.title_nfc_lower, SharedDeck.id)
            else:  # recency (default): newest first, id as a total-order tiebreak
                # SQLite stores SQLModel datetimes as text.  Comparing the raw
                # values makes ``+09:00`` sort after the equivalent UTC value
                # instead of comparing their actual instants.  julianday()
                # parses both forms and yields one UTC-normalized numeric key.
                updated_at_utc = func.julianday(cast(SharedDeck.updated_at, String))
                key = tuple_(updated_at_utc, SharedDeck.id)
                if after is not None:
                    after_at = after[0]
                    if isinstance(after_at, datetime):
                        after_at = after_at.isoformat(sep=" ")
                    stmt = stmt.where(key < tuple_(func.julianday(after_at), after[1]))
                stmt = stmt.order_by(updated_at_utc.desc(), SharedDeck.id.desc())
            return list(session.exec(stmt.limit(limit)).all())

    def page_cards(self, deck_id: str, *, version: int, limit: int, after: str | None = None) -> list[SharedDeckCard]:
        """Keyset page of a deck version's cards, ordered by immutable card id."""
        with Session(self.engine) as session:
            stmt = select(SharedDeckCard).where(
                SharedDeckCard.shared_deck_id == deck_id,
                SharedDeckCard.version == version,
            )
            if after is not None:
                stmt = stmt.where(SharedDeckCard.id > after)
            stmt = stmt.order_by(SharedDeckCard.id).limit(limit)
            return list(session.exec(stmt).all())

    def all_cards(self, deck_id: str, *, version: int) -> list[SharedDeckCard]:
        """Full immutable snapshot of a deck version's cards (deterministic id
        order). The copy path takes this snapshot once so ``len()`` is the
        source-of-truth count for the count-equality assertion."""
        with Session(self.engine) as session:
            stmt = (
                select(SharedDeckCard)
                .where(
                    SharedDeckCard.shared_deck_id == deck_id,
                    SharedDeckCard.version == version,
                )
                .order_by(SharedDeckCard.id)
            )
            return list(session.exec(stmt).all())

    # ── copy support (Phase 2) ─────────────────────────────────────

    def get_copy_log(self, copier_id: str, idempotency_key: str) -> SharedDeckCopyLog | None:
        """Look up a prior copy by its idempotency key (transport-retry replay)."""
        with Session(self.engine) as session:
            return session.get(SharedDeckCopyLog, (copier_id, idempotency_key))

    def list_uncounted_copies(self) -> list[SharedDeckCopyLog]:
        """Copy-log rows whose reveal marker is unset: committed copies whose
        reveal did not finish. Input to the reveal sweep (#3897)."""
        with Session(self.engine) as session:
            return list(
                session.exec(select(SharedDeckCopyLog).where(SharedDeckCopyLog.download_counted.is_(False))).all()
            )

    def has_copy_log_for_notebook(self, notebook_id: str) -> bool:
        """True when a copy_log row points at ``notebook_id`` (copy is committed)."""
        with Session(self.engine) as session:
            return (
                session.exec(
                    select(SharedDeckCopyLog.copier_id).where(SharedDeckCopyLog.result_notebook_id == notebook_id)
                ).first()
                is not None
            )

    def record_copy(
        self,
        copier_id: str,
        idempotency_key: str,
        source_shared_deck_id: str,
        source_version: int,
        result_notebook_id: str,
    ) -> bool:
        """Insert the idempotency log row. Returns ``True`` when recorded;
        ``False`` when the ``(copier_id, idempotency_key)`` PK already exists —
        a concurrent/duplicate copy won the race, so the caller replays to the
        already-logged result instead of minting a second notebook."""
        with Session(self.engine) as session:
            session.add(
                SharedDeckCopyLog(
                    copier_id=copier_id,
                    idempotency_key=idempotency_key,
                    source_shared_deck_id=source_shared_deck_id,
                    source_version=source_version,
                    result_notebook_id=result_notebook_id,
                )
            )
            try:
                session.commit()
            except IntegrityError:
                session.rollback()
                return False
            return True

    def delete_copy_logs_for(self, copier_ids: Iterable[str]) -> int:
        """Account-erasure hook: delete every copy-log row of the given copiers.

        Idempotent; rows of unrelated copiers are untouched. Returns the number
        of rows removed.
        """
        ids = list(dict.fromkeys(copier_ids))
        if not ids:
            return 0
        with Session(self.engine) as session:
            result = session.execute(delete(SharedDeckCopyLog).where(SharedDeckCopyLog.copier_id.in_(ids)))
            session.commit()
            return int(result.rowcount or 0)

    def finalize_copy_download(self, copier_id: str, idempotency_key: str, deck_id: str) -> bool:
        """Count one committed copy exactly once.

        The copy log marker and the catalog counter share one transaction. A
        process crash before commit leaves the marker false for the next retry;
        a committed transaction makes later retries a no-op.
        """
        with Session(self.engine) as session:
            connection = session.connection()
            marked = connection.exec_driver_sql(
                """
                UPDATE shared_deck_copy_log
                   SET download_counted = 1
                 WHERE copier_id = ?
                   AND idempotency_key = ?
                   AND source_shared_deck_id = ?
                   AND download_counted = 0
                """,
                (copier_id, idempotency_key, deck_id),
            )
            if marked.rowcount != 1:
                session.rollback()
                return False

            counted = connection.exec_driver_sql(
                "UPDATE shared_deck SET download_count = download_count + 1 WHERE id = ?",
                (deck_id,),
            )
            if counted.rowcount != 1:
                session.rollback()
                raise RuntimeError(f"shared deck missing during copy finalization: {deck_id}")
            session.commit()
            return True

    # ── write side (official governance, Phase 1b-ii) ──────────────

    def publish_official(
        self,
        *,
        deck_id: str,
        title: str,
        cards: list[dict],
        description: str | None = None,
        category: str | None = None,
        language_pair: str | None = None,
        tags: list[str] | None = None,
        color: str | None = None,
        cover_pattern: str | None = None,
        publisher_display_name: str | None = None,
    ) -> dict:
        """Idempotent upsert of one official deck.

        ``source`` / ``owner_id`` / ``visibility`` / ``status`` are
        **server-authoritative** — hard-coded here, never parameters — so a
        curator spec cannot forge a verified badge (§3.3/§5.2). Re-emitting
        identical content is a no-op (content_hash unchanged → no version bump,
        no card proliferation); a content change mints a new version and
        atomically flips ``current_version`` while the prior version's card rows
        stay immutable (§2.3). Homograph-identical cards are deduped by
        ``content_guid`` so the guid UNIQUE is never violated.
        """
        tags = list(tags or [])
        canonical: dict[str, dict] = {}
        for card in cards:
            cc = canonical_card(card)
            canonical.setdefault(cc["content_guid"], cc)  # first wins, deterministic
        canonical_cards = list(canonical.values())
        new_hash = deck_content_hash(canonical_cards)
        now = datetime.now(UTC)

        with Session(self.engine) as session:
            deck = session.get(SharedDeck, deck_id)
            if deck is None:
                version = 1
                deck = SharedDeck(id=deck_id)
                session.add(deck)
                self._write_version(session, deck_id, version, new_hash, canonical_cards)
                action = "created"
            else:
                cur = session.get(SharedDeckVersion, (deck_id, deck.current_version))
                if cur is not None and cur.content_hash == new_hash:
                    version = deck.current_version
                    action = (
                        "metadata"
                        if self._metadata_differs(
                            deck,
                            title=title,
                            description=description,
                            category=category,
                            language_pair=language_pair,
                            tags=tags,
                            color=color,
                            cover_pattern=cover_pattern,
                            publisher_display_name=publisher_display_name,
                            card_count=len(canonical_cards),
                        )
                        else "noop"
                    )
                else:
                    version = deck.current_version + 1
                    self._write_version(session, deck_id, version, new_hash, canonical_cards)
                    action = "versioned"

            if action == "noop":
                # A true no-op: nothing added/mutated, updated_at untouched.
                return {
                    "action": "noop",
                    "deckId": deck_id,
                    "version": version,
                    "contentHash": new_hash,
                    "cardCount": deck.card_count,
                }

            # Apply deck-level metadata and re-assert the server-authoritative
            # axes (defensive: an official deck is always discoverable + trusted).
            deck.title = title
            deck.title_nfc_lower = normalize_nfc_lower(title)
            deck.description = description
            deck.category = category
            deck.language_pair = language_pair
            deck.tags = tags
            deck.color = color
            deck.cover_pattern = cover_pattern
            deck.publisher_display_name = publisher_display_name
            deck.source = "official"
            deck.owner_id = None
            deck.visibility = "official"
            deck.status = "active"
            deck.is_deleted = False
            deck.current_version = version
            deck.card_count = len(canonical_cards)
            deck.updated_at = now
            session.add(deck)
            session.commit()
            return {
                "action": action,
                "deckId": deck_id,
                "version": version,
                "contentHash": new_hash,
                "cardCount": len(canonical_cards),
            }

    @staticmethod
    def _write_version(
        session: Session,
        deck_id: str,
        version: int,
        content_hash: str,
        canonical_cards: list[dict],
    ) -> None:
        session.add(SharedDeckVersion(shared_deck_id=deck_id, version=version, content_hash=content_hash))
        for cc in canonical_cards:
            session.add(
                SharedDeckCard(
                    shared_deck_id=deck_id,
                    version=version,
                    content_guid=cc["content_guid"],
                    content=cc["content"],
                    pos=cc["pos"],
                    meaning=cc["meaning"],
                    examples=cc["examples"],
                    collocations=cc["collocations"],
                    note=cc["note"],
                    difficulty=cc["difficulty"],
                    mode=cc["mode"],
                    root_form=cc["root_form"],
                    inflections=cc["inflections"],
                )
            )

    @staticmethod
    def _metadata_differs(
        deck: SharedDeck,
        *,
        title,
        description,
        category,
        language_pair,
        tags,
        color,
        cover_pattern,
        publisher_display_name,
        card_count,
    ) -> bool:
        return (
            deck.title != title
            or deck.description != description
            or deck.category != category
            or deck.language_pair != language_pair
            or list(deck.tags or []) != list(tags or [])
            or deck.color != color
            or deck.cover_pattern != cover_pattern
            or deck.publisher_display_name != publisher_display_name
            or deck.card_count != card_count
            or deck.source != "official"
            or deck.owner_id is not None
            or deck.visibility != "official"
            or deck.status != "active"
            or deck.is_deleted
        )


__all__ = [
    "SharedDeck",
    "SharedDeckVersion",
    "SharedDeckCard",
    "SharedDeckRating",
    "SharedDeckReport",
    "SharedDeckCopyLog",
    "SharedDeckStore",
    "card_content_guid",
    "canonical_card",
    "deck_content_hash",
]
