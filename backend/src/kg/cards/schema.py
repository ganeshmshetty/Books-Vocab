"""Schema setup, index creation and migrations for the card table."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy.engine import Connection, Engine
from sqlalchemy.exc import IntegrityError

from ..sqlite_utils import ensure_columns
from ..text_utils import normalize_nfc_lower
from .model import Card
from .query import updated_at_key_index_sql

_RETIRED_DICTIONARY_CARD_COLUMNS = (
    "card_role",
    "review_eligible",
    "reader_hidden",
    "promotion_state",
    "promoted_at",
)
_RETIRED_DICTIONARY_CARD_TABLES = (
    "dictionary_entry",
    "lexical_operations",
    "dictionary_promotion_jobs",
    "dictionary_lifecycle_state",
    "dictionary_archive_link_cause",
)


def init_schema(engine: Engine) -> None:
    """Create the card table, run migrations and ensure all indexes exist."""
    Card.metadata.create_all(engine, tables=[Card.__table__], checkfirst=True)
    _retire_dictionary_card_schema(engine)
    _migrate_review_columns(engine)
    _migrate_content_nfc_lower(engine)
    _create_indexes(engine)


def _create_indexes(engine: Engine) -> None:
    """Ensure all secondary indexes on the card table exist."""
    with engine.connect() as conn:
        # Sync cursor queries (page_cards, get_modified_since) filter and order by
        # the UTC-microsecond key expression, not the raw column, so SQLite can
        # only use an index whose expression is that same key. Generated from the
        # query's own expression to keep the two identical.
        conn.exec_driver_sql(
            f"CREATE INDEX IF NOT EXISTS ix_card_updated_key_id ON card ({updated_at_key_index_sql()}, id)"
        )
        # Raw-column indexes superseded by the expression index above; no query
        # filters or orders by raw updated_at any more.
        conn.exec_driver_sql("DROP INDEX IF EXISTS ix_card_updated_at")
        conn.exec_driver_sql("DROP INDEX IF EXISTS ix_card_updated_at_id")
        conn.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_card_content ON card (content)")
        conn.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_card_content_nocase ON card (content COLLATE NOCASE)")
        conn.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_card_content_nfc_lower ON card (content_nfc_lower)")
        conn.exec_driver_sql("CREATE INDEX IF NOT EXISTS ix_card_notebook_id ON card (notebook_id)")
        # Unique constraint to prevent duplicate active cards.
        # Uses partial index (is_deleted=0) so soft-deleted duplicates
        # don't block re-creation.
        try:
            conn.exec_driver_sql(_CREATE_UNIQUE_CONTENT_INDEX)
        except IntegrityError:
            # Legacy DB predating the index holds active case-variant
            # duplicates: soft-delete the losers, then retry once.
            conn.rollback()
            _soft_delete_legacy_duplicates(conn)
            conn.exec_driver_sql(_CREATE_UNIQUE_CONTENT_INDEX)
        conn.commit()


_SQLITE_TS = "%Y-%m-%d %H:%M:%S.%f"  # SQLAlchemy DateTime storage format
_CREATE_UNIQUE_CONTENT_INDEX = (
    "CREATE UNIQUE INDEX IF NOT EXISTS uq_card_content_notebook "
    "ON card (content COLLATE NOCASE, notebook_id) WHERE is_deleted = 0"
)


def _soft_delete_legacy_duplicates(conn: Connection) -> None:
    """Soft-delete active duplicates under the unique index's own key.

    Key is (content COLLATE NOCASE, notebook_id), so duplicates are never
    collapsed across notebooks. Keeper = highest review_count, then earliest
    created_at, then lowest id; the keeper's updated_at is bumped after the
    deletes so incremental sync converges (same contract as `deduplicate`).
    """
    rows = conn.exec_driver_sql(
        "SELECT id, content, notebook_id, review_count, created_at FROM card "
        "WHERE is_deleted = 0 AND (content COLLATE NOCASE, notebook_id) IN ("
        "SELECT content COLLATE NOCASE, notebook_id FROM card WHERE is_deleted = 0 "
        "GROUP BY content COLLATE NOCASE, notebook_id HAVING COUNT(*) > 1)"
    ).fetchall()
    groups: dict[tuple[str, str], list[tuple]] = {}
    for row in rows:
        key = (str(row[1]).lower(), row[2])
        groups.setdefault(key, []).append(row)
    now = datetime.now(UTC).strftime(_SQLITE_TS)
    bump = (datetime.now(UTC) + timedelta(milliseconds=1)).strftime(_SQLITE_TS)
    for members in groups.values():
        # NOCASE folds ASCII only; Python lower() can over-group, so re-split
        # on the exact SQLite key by lowering ASCII alone.
        by_sql_key: dict[str, list[tuple]] = {}
        for m in members:
            ascii_key = "".join(c.lower() if c < "\x80" else c for c in m[1])
            by_sql_key.setdefault(ascii_key, []).append(m)
        for dupes in by_sql_key.values():
            if len(dupes) < 2:
                continue
            dupes.sort(key=lambda r: (-(r[3] or 0), str(r[4]), r[0]))
            for loser in dupes[1:]:
                conn.exec_driver_sql(
                    "UPDATE card SET is_deleted = 1, updated_at = ? WHERE id = ?",
                    (now, loser[0]),
                )
            conn.exec_driver_sql("UPDATE card SET updated_at = ? WHERE id = ?", (bump, dupes[0][0]))


def _retire_dictionary_card_schema(engine: Engine) -> None:
    """Remove the retired card subtype while preserving ordinary card rows."""
    with engine.connect() as conn:
        # Serialize the inspect/drop boundary across independent CardStore
        # instances. SQLite has no DROP COLUMN IF EXISTS, so a deferred
        # transaction would allow two workers to observe the same old column.
        conn.exec_driver_sql("BEGIN IMMEDIATE")
        for table in _RETIRED_DICTIONARY_CARD_TABLES:
            conn.exec_driver_sql(f'DROP TABLE IF EXISTS "{table}"')

        existing_columns = {row[1] for row in conn.exec_driver_sql("PRAGMA table_info(card)").fetchall()}
        for column in _RETIRED_DICTIONARY_CARD_COLUMNS:
            if column in existing_columns:
                conn.exec_driver_sql(f'ALTER TABLE card DROP COLUMN "{column}"')
        conn.commit()


def _migrate_review_columns(engine: Engine) -> None:
    """Add review state columns to existing card tables (SQLModel create_all won't ALTER)."""
    review_columns = {
        "notebook_id": "TEXT DEFAULT 'default'",
        "is_archived": "INTEGER DEFAULT 0",
        "is_reader_hidden": "INTEGER DEFAULT 0",
        "is_review_excluded": "INTEGER DEFAULT 0",
        "source": "TEXT",
        "review_interval_hours": "REAL DEFAULT 12.0",
        "next_review_at": "TIMESTAMP",
        "last_reviewed_at": "TIMESTAMP",
        "review_count": "INTEGER DEFAULT 0",
        "lapse_count": "INTEGER DEFAULT 0",
        "review_streak": "INTEGER DEFAULT 0",
        "last_review_feedback": "INTEGER DEFAULT -1",
        "source_shared_card_guid": "TEXT",
        "enrich_attempts": "INTEGER DEFAULT 0",
    }
    with engine.connect() as conn:
        ensure_columns(conn, "card", review_columns)
        conn.commit()


def _migrate_content_nfc_lower(engine: Engine) -> None:
    """Add and backfill `content_nfc_lower` for legacy DBs."""
    with engine.connect() as conn:
        ensure_columns(conn, "card", {"content_nfc_lower": "TEXT DEFAULT ''"})
        # Backfill any rows where the column is empty/null but content isn't.
        rows = conn.exec_driver_sql(
            "SELECT id, content FROM card WHERE content_nfc_lower IS NULL OR content_nfc_lower = ''"
        ).fetchall()
        for card_id, content in rows:
            if content:
                conn.exec_driver_sql(
                    "UPDATE card SET content_nfc_lower = ? WHERE id = ?",
                    (normalize_nfc_lower(content), card_id),
                )
        conn.commit()
