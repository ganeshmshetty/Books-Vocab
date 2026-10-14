"""Notebook storage and CRUD operations."""

from __future__ import annotations

import json
import logging
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from fastapi import HTTPException
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlmodel import Field as SQLField
from sqlmodel import Session, SQLModel, select

from .sqlite_utils import ensure_columns, make_sqlite_engine

logger = logging.getLogger(__name__)

DEFAULT_NOTEBOOK_ID = "default"
DEFAULT_NOTEBOOK_NAME = "我的單字本"


def _disambiguate_name(base: str, taken: set[str]) -> str:
    """Return ``base`` if free, else the first ``"base (n)"`` (n >= 2) that is.

    Same suffix scheme as the shared-deck copy path (``_unique_notebook_name``).
    """
    if base not in taken:
        return base
    n = 2
    while f"{base} ({n})" in taken:
        n += 1
    return f"{base} ({n})"


def _utc_instant(value: datetime) -> datetime:
    """Interpret naive stored timestamps as UTC and normalize aware ones."""
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def _parse_stored_timestamp(value: str) -> datetime:
    """Parse SQLite timestamp text without discarding its offset."""
    return _utc_instant(datetime.fromisoformat(value.replace(" ", "T")))


class Notebook(SQLModel, table=True):
    """A vocabulary notebook for grouping cards."""

    id: str = SQLField(default_factory=lambda: uuid.uuid4().hex[:12], primary_key=True)
    name: str
    color: str | None = None
    cover_pattern: str | None = None
    sort_order: int = SQLField(default=0)
    is_default: bool = SQLField(default=False)
    created_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))
    updated_at: datetime = SQLField(default_factory=lambda: datetime.now(UTC))
    is_deleted: bool = SQLField(default=False)
    # Copy-in-progress barrier (Phase 2 shared-deck copy). DISTINCT from
    # is_deleted so a staged copy's reveal (materialize) can never be confused
    # with — or resurrect — a real user soft-delete. Hidden from every
    # visibility query until materialize flips it False (reveal-once).
    is_staged: bool = SQLField(default=False)
    # Provenance (v1 inert): set when this notebook was copied from a shared
    # deck (Phase 2 copy). NULL for organically-created notebooks.
    source_shared_deck_id: str | None = None
    source_version: int | None = None


class NotebookSettings(SQLModel, table=True):
    """Per-notebook review settings stored beside the notebook metadata."""

    __tablename__ = "notebook_settings"

    notebook_id: str = SQLField(primary_key=True)
    review_policy: str | None = None
    review_policy_updated_at: float | None = None
    card_layout: str | None = None
    card_layout_updated_at: float | None = None


_UNSET = object()


class NotebookStore:
    """SQLite-based notebook storage."""

    def __init__(self, path: Path) -> None:
        self.path = path
        # make_sqlite_engine installs a connect listener that applies
        # WAL/synchronous=NORMAL/busy_timeout to every pooled connection (and
        # creates the parent dir). create_all + column migration below run
        # after, so DDL lands on a WAL connection.
        self.engine = make_sqlite_engine(path)
        # SQLAlchemy's checkfirst=True is not atomic across independent
        # engines: two legacy openers can both observe a missing table and
        # then race on CREATE TABLE. Take SQLite's writer lock before the
        # check/create boundary so the second opener rechecks after commit.
        with self.engine.connect() as conn:
            conn.exec_driver_sql("BEGIN IMMEDIATE")
            try:
                Notebook.metadata.create_all(
                    conn,
                    tables=[Notebook.__table__, NotebookSettings.__table__],
                    checkfirst=True,
                )
                conn.commit()
            except Exception:
                conn.rollback()
                raise
        self._migrate_columns()

    def _migrate_columns(self) -> None:
        # SQLModel create_all won't ALTER existing tables → add-if-missing.
        added_cols = {
            "cover_pattern": "TEXT",
            "source_shared_deck_id": "TEXT",
            "source_version": "INTEGER",
            # NOT NULL DEFAULT 0 so every pre-existing row backfills to False
            # (a NULL would slip past `is_staged IS 0` and vanish from queries).
            "is_staged": "INTEGER NOT NULL DEFAULT 0",
        }
        with self.engine.connect() as conn:
            added = ensure_columns(conn, "notebook", added_cols)
            for col in added:
                logger.info("migrated notebook: added %s column", col)
            conn.commit()

    def ensure_default(self) -> Notebook:
        """Ensure the default notebook exists. Returns it."""
        with Session(self.engine) as session:
            existing = session.exec(select(Notebook).where(Notebook.id == DEFAULT_NOTEBOOK_ID)).first()
            if existing:
                return existing
            nb = Notebook(
                id=DEFAULT_NOTEBOOK_ID,
                name=DEFAULT_NOTEBOOK_NAME,
                is_default=True,
            )
            session.add(nb)
            try:
                session.commit()
            except IntegrityError:
                # Another first-use request may have created the singleton
                # between our read and insert. Re-read its committed row;
                # unrelated integrity failures still propagate unchanged.
                session.rollback()
                existing = session.get(Notebook, DEFAULT_NOTEBOOK_ID)
                if existing is None:
                    raise
                return existing
            session.refresh(nb)
            return nb

    @contextmanager
    def _name_guarded_txn(self) -> Iterator[Session]:
        """One SQLite writer transaction for a check-then-write on notebook names.

        ``BEGIN IMMEDIATE`` takes the write lock before the active-name query, so
        a racing create or rename (another thread or process) waits instead of
        reading the same name as free. No UNIQUE index: accounts that already hold
        duplicates from before this guard must still open and migrate.
        """
        with self.engine.connect() as conn:
            conn.exec_driver_sql("BEGIN IMMEDIATE")
            try:
                with Session(bind=conn) as session:
                    yield session
                conn.commit()
            except BaseException:
                conn.rollback()
                raise

    @staticmethod
    def _active_names(session: Session, *, exclude_id: str | None = None) -> set[str]:
        """Names held by active notebooks (not soft-deleted, not copy-staged): the
        set that world-export requires to be duplicate-free (#3889)."""
        rows = session.execute(
            select(Notebook.id, Notebook.name).where(
                Notebook.is_deleted.is_(False),
                Notebook.is_staged.is_(False),
            )
        ).all()
        return {name for nb_id, name in rows if nb_id != exclude_id}

    def create(
        self,
        name: str,
        color: str | None = None,
        cover_pattern: str | None = None,
        *,
        source_shared_deck_id: str | None = None,
        source_version: int | None = None,
        is_staged: bool = False,
    ) -> Notebook:
        """Create a notebook. ``is_default`` is never set here (the model default
        is False), so a shared-deck copy is structurally guaranteed non-default.
        The Phase 2 copy path passes ``is_staged=True`` to stage the notebook
        HIDDEN (the materialization barrier, distinct from a user soft-delete)
        plus the provenance columns, then reveals it via :meth:`materialize` once
        every card has landed. The stored name is disambiguated against active
        names (``"X (2)"``), so the API never yields two same-named active notebooks."""
        with self._name_guarded_txn() as session:
            nb = Notebook(
                name=_disambiguate_name(name, self._active_names(session)),
                color=color,
                cover_pattern=cover_pattern,
                source_shared_deck_id=source_shared_deck_id,
                source_version=source_version,
                is_staged=is_staged,
            )
            session.add(nb)
            session.flush()
            session.refresh(nb)
        return nb

    def materialize(self, notebook_id: str) -> bool:
        """Lift the copy barrier: flip a staged (``is_staged=True``) copy
        notebook visible. Reveal-once — it ONLY ever clears ``is_staged`` and
        NEVER touches ``is_deleted``, so a copy that was materialized and then
        user-soft-deleted is never resurrected by a defensive re-materialize on
        an idempotent-retry replay. Idempotent: a no-op (no write, no
        ``updated_at`` bump) when the notebook is already revealed, user-deleted,
        or absent. Returns True only when a staged row was actually revealed."""
        with Session(self.engine) as session:
            nb = session.get(Notebook, notebook_id)
            if nb is None or not nb.is_staged:
                return False
            nb.is_staged = False
            nb.updated_at = datetime.now(UTC)
            session.add(nb)
            session.commit()
            return True

    def staged_ids(self) -> list[str]:
        """Ids of every staged (copy-in-progress) notebook."""
        with Session(self.engine) as session:
            return [row[0] for row in session.execute(text("SELECT id FROM notebook WHERE is_staged = 1")).all()]

    def staged_older_than(self, cutoff: datetime) -> list[str]:
        """Ids of staged notebooks created before ``cutoff`` (UTC instant)."""
        cutoff = cutoff if cutoff.tzinfo else cutoff.replace(tzinfo=UTC)
        with Session(self.engine) as session:
            rows = session.exec(select(Notebook).where(Notebook.is_staged.is_(True))).all()
        return [
            nb.id
            for nb in rows
            if (nb.created_at if nb.created_at.tzinfo else nb.created_at.replace(tzinfo=UTC)) < cutoff
        ]

    def hard_delete(self, notebook_id: str) -> bool:
        """Physically remove a notebook row. Compensation-only — ordinary
        deletes are soft (:meth:`delete`); this exists so a failed copy leaves no
        trace. Returns True if a row was deleted."""
        with Session(self.engine) as session:
            nb = session.get(Notebook, notebook_id)
            if nb is None:
                return False
            session.delete(nb)
            session.commit()
            return True

    def get(self, notebook_id: str) -> Notebook | None:
        with Session(self.engine) as session:
            return session.get(Notebook, notebook_id)

    def get_settings(self, notebook_id: str) -> NotebookSettings | None:
        with Session(self.engine) as session:
            return session.get(NotebookSettings, notebook_id)

    def update_settings(
        self,
        notebook_id: str,
        *,
        review_policy: tuple[dict | None, float] | object = _UNSET,
        card_layout: tuple[dict | None, float] | object = _UNSET,
    ) -> Notebook | None:
        """Apply independently versioned notebook settings groups.

        A group is only changed when its incoming timestamp is newer than the
        stored timestamp. Reset values remain as timestamped tombstones so an
        older device cannot resurrect a cleared override.
        """
        groups = (
            (review_policy, "review_policy", "review_policy_updated_at"),
            (card_layout, "card_layout", "card_layout_updated_at"),
        )
        with Session(self.engine) as session:
            has_changes = False
            for incoming, value_column, timestamp_column in groups:
                if incoming is _UNSET:
                    continue
                value, updated_at = incoming
                encoded = None if value is None else json.dumps(value, separators=(",", ":"), sort_keys=True)
                result = session.execute(
                    text(
                        f"""
                        INSERT INTO notebook_settings
                            (notebook_id, {value_column}, {timestamp_column})
                        SELECT :notebook_id, :value, :updated_at
                        WHERE EXISTS (
                            SELECT 1 FROM notebook
                            WHERE id = :notebook_id AND is_deleted = 0 AND is_staged = 0
                        )
                        ON CONFLICT(notebook_id) DO UPDATE SET
                            {value_column} = excluded.{value_column},
                            {timestamp_column} = excluded.{timestamp_column}
                        WHERE notebook_settings.{timestamp_column} IS NULL
                           OR excluded.{timestamp_column} > notebook_settings.{timestamp_column}
                        """
                    ),
                    {"notebook_id": notebook_id, "value": encoded, "updated_at": updated_at},
                )
                has_changes = has_changes or result.rowcount > 0

            nb = session.get(Notebook, notebook_id)
            if nb is None or nb.is_deleted or nb.is_staged:
                session.rollback()
                return None
            if has_changes:
                nb.updated_at = datetime.now(UTC)
                session.add(nb)
                session.commit()
                session.refresh(nb)
            return nb

    def all(self, include_deleted: bool = False, *, include_staged: bool = False) -> list[Notebook]:
        """Visible notebooks. Two ORTHOGONAL hide axes, defaulting off:

        * ``include_deleted`` — add soft-delete tombstones (the full sync-down
          list passes this so client deletions propagate). Staged rows stay
          hidden regardless: a half-copied notebook must never reach the client.
        * ``include_staged`` — expose copy-in-progress (``is_staged``) rows.
          Teardown / leak-detection callers ONLY; never feed this to a client or
          an export.

        Conflating the two (a bare ``include_deleted=True`` that also revealed
        staged) leaked copy-in-progress notebooks into the full-sync response."""
        conditions = []
        if not include_deleted:
            conditions.append(Notebook.is_deleted.is_(False))
        if not include_staged:
            conditions.append(Notebook.is_staged.is_(False))
        with Session(self.engine) as session:
            statement = select(Notebook)
            if conditions:
                statement = statement.where(*conditions)
            statement = statement.order_by(Notebook.sort_order, Notebook.created_at, Notebook.id)
            return list(session.exec(statement).all())

    def get_modified_since(self, since: datetime) -> list[Notebook]:
        """Notebooks modified after ``since`` for incremental sync-down. Includes
        soft-deleted rows (so deletions propagate) but EXCLUDES staged copies —
        a half-copied notebook must not surface on the client until materialize
        reveals it (materialize bumps ``updated_at``, so the revealed copy is
        picked up by the next delta)."""
        with Session(self.engine) as session:
            # SQLite stores DATETIME as text, so a direct comparison can order
            # offset-bearing legacy values by wall clock instead of by instant.
            # Read the raw values and apply the same UTC-instant contract as the
            # card incremental-sync path before ordering by the stable id tie-break.
            rows = session.execute(text("SELECT id, updated_at FROM notebook WHERE is_staged = 0")).all()
            since_utc = _utc_instant(since)
            modified_ids = [
                notebook_id
                for notebook_id, _updated_at in sorted(
                    (
                        (notebook_id, _parse_stored_timestamp(updated_at))
                        for notebook_id, updated_at in rows
                        if _parse_stored_timestamp(updated_at) > since_utc
                    ),
                    key=lambda row: (row[1], row[0]),
                )
            ]
            if not modified_ids:
                return []
            notebooks = session.exec(select(Notebook).where(Notebook.id.in_(modified_ids))).all()
            notebooks_by_id = {notebook.id: notebook for notebook in notebooks}
            return [notebooks_by_id[notebook_id] for notebook_id in modified_ids]

    def update(self, notebook_id: str, **kwargs) -> Notebook | None:
        with self._name_guarded_txn() as session:
            nb = session.get(Notebook, notebook_id)
            if nb is None or nb.is_deleted or nb.is_staged:
                return None
            # Only a real rename is checked: re-sending the current name must not
            # self-suffix, and a legacy duplicate left as-is stays as-is.
            if "name" in kwargs and kwargs["name"] != nb.name:
                kwargs["name"] = _disambiguate_name(kwargs["name"], self._active_names(session, exclude_id=nb.id))
            has_changes = False
            for key, value in kwargs.items():
                if hasattr(nb, key) and getattr(nb, key) != value:
                    setattr(nb, key, value)
                    has_changes = True
            if has_changes:
                nb.updated_at = datetime.now(UTC)
                session.add(nb)
                session.flush()
                session.refresh(nb)
            return nb

    def exists(self, notebook_id: str) -> bool:
        """Check if a revealed, non-deleted notebook exists."""
        nb = self.get(notebook_id)
        return nb is not None and not nb.is_deleted and not nb.is_staged

    def delete(self, notebook_id: str) -> bool | None:
        """Soft-delete a notebook. Returns True if deleted, None if already
        deleted (idempotent success), False if not found or is default."""
        with Session(self.engine) as session:
            nb = session.get(Notebook, notebook_id)
            if nb is None or nb.is_default:
                return False
            if nb.is_deleted:
                return None
            nb.is_deleted = True
            nb.updated_at = datetime.now(UTC)
            session.add(nb)
            session.commit()
            return True

    def close(self) -> None:
        """Dispose the SQLAlchemy engine and release connections."""
        if self.engine is not None:
            self.engine.dispose()
            self.engine = None


def validate_notebook_access(notebook_store: NotebookStore, notebook_id: str) -> None:
    """Raise 403 if notebook_id does not belong to this user (not found or deleted).

    The 'default' notebook is auto-created on demand, so it always passes.
    """
    if notebook_id == DEFAULT_NOTEBOOK_ID:
        notebook_store.ensure_default()
        return
    if not notebook_store.exists(notebook_id):
        raise HTTPException(status_code=403, detail="Notebook access denied")
