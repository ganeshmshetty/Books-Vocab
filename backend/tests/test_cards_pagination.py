"""E1 — query-layer bounded cursor pagination for CardStore.

`page_cards` returns at most `limit` cards ordered by the composite cursor
``(updated_at, id)`` using a UTC-normalized row-value comparison, so paging is
gap-free and duplicate-free even when many cards share the same ``updated_at``
or use legacy timezone offsets.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import text
from sqlmodel import Session

from kg.cards.store import Card, CardStore
from kg.vocab_crud import decode_cursor, encode_cursor


@pytest.fixture()
def store(tmp_path):
    s = CardStore(tmp_path / "cards.db")
    yield s
    s.close()


def _add(
    store: CardStore, card_id: str, *, updated_at: datetime, notebook_id: str = "default", is_deleted: bool = False
) -> Card:
    # Insert directly so the test controls id + updated_at exactly (store.add
    # generates its own id/timestamps).
    card = Card(
        id=card_id,
        content=f"word-{card_id}",
        meaning="m",
        updated_at=updated_at,
        notebook_id=notebook_id,
        is_deleted=is_deleted,
    )
    with Session(store.engine) as session:
        session.add(card)
        session.commit()
        session.refresh(card)
    return card


def _seed_distinct(store: CardStore, n: int, base: datetime) -> list[str]:
    ids = []
    for i in range(n):
        cid = f"c{i:03d}"
        _add(store, cid, updated_at=base + timedelta(seconds=i))
        ids.append(cid)
    return ids


def test_page_after_cursor_returns_bounded(store):
    base = datetime(2024, 1, 1, 0, 0, 0)
    _seed_distinct(store, 10, base)

    page = store.page_cards(limit=4, after=None, include_deleted=False, notebook_id=None)
    assert len(page) == 4
    # ascending by (updated_at, id)
    assert [c.id for c in page] == ["c000", "c001", "c002", "c003"]


def test_page_cursor_no_gap_no_dup(store):
    base = datetime(2024, 1, 1, 0, 0, 0)
    all_ids = _seed_distinct(store, 7, base)

    collected: list[str] = []
    after = None
    for _ in range(5):  # more than enough iterations to drain
        page = store.page_cards(limit=3, after=after, include_deleted=False, notebook_id=None)
        if not page:
            break
        collected.extend(c.id for c in page)
        last = page[-1]
        after = (last.updated_at, last.id)

    # union over 3 pages == whole table, no duplicates
    assert collected == all_ids
    assert len(collected) == len(set(collected))


def test_page_same_timestamp_tiebreak_by_id(store):
    ts = datetime(2024, 1, 1, 12, 0, 0)
    # All identical updated_at — ordering must fall back to id.
    for cid in ["c_z", "c_a", "c_m", "c_b"]:
        _add(store, cid, updated_at=ts)

    page1 = store.page_cards(limit=2, after=None, include_deleted=False, notebook_id=None)
    assert [c.id for c in page1] == ["c_a", "c_b"]

    last = page1[-1]
    page2 = store.page_cards(limit=2, after=(last.updated_at, last.id), include_deleted=False, notebook_id=None)
    assert [c.id for c in page2] == ["c_m", "c_z"]


def test_page_respects_notebook_id(store):
    base = datetime(2024, 1, 1, 0, 0, 0)
    _add(store, "a1", updated_at=base, notebook_id="nbA")
    _add(store, "b1", updated_at=base + timedelta(seconds=1), notebook_id="nbB")
    _add(store, "a2", updated_at=base + timedelta(seconds=2), notebook_id="nbA")

    page = store.page_cards(limit=10, after=None, include_deleted=False, notebook_id="nbA")
    assert {c.id for c in page} == {"a1", "a2"}


def test_page_include_deleted_flag(store):
    base = datetime(2024, 1, 1, 0, 0, 0)
    _add(store, "live", updated_at=base)
    _add(store, "dead", updated_at=base + timedelta(seconds=1), is_deleted=True)

    excluded = store.page_cards(limit=10, after=None, include_deleted=False, notebook_id=None)
    assert {c.id for c in excluded} == {"live"}

    included = store.page_cards(limit=10, after=None, include_deleted=True, notebook_id=None)
    assert {c.id for c in included} == {"live", "dead"}


def test_page_cursor_does_not_skip_later_offset_timestamp_after_wire_round_trip(store):
    """A UTC-normalized API cursor must advance past a legacy offset row."""
    _add(store, "first", updated_at=datetime(2024, 1, 1))
    _add(store, "second", updated_at=datetime(2024, 1, 1))
    with store.engine.begin() as connection:
        connection.execute(
            text("UPDATE card SET updated_at = :timestamp WHERE id = :card_id"),
            [
                {"timestamp": "2024-01-01 09:00:00-05:00", "card_id": "first"},
                {"timestamp": "2024-01-01 10:00:00-05:00", "card_id": "second"},
            ],
        )

    first_page = store.page_cards(limit=1, after=None, include_deleted=True, notebook_id=None)
    assert [card.id for card in first_page] == ["first"]

    wire_cursor = encode_cursor((first_page[-1].updated_at, first_page[-1].id))
    after = decode_cursor(wire_cursor)
    assert after == (datetime(2024, 1, 1, 14, 0), "first")

    second_page = store.page_cards(limit=1, after=after, include_deleted=True, notebook_id=None)
    assert [card.id for card in second_page] == ["second"]


def test_get_modified_since_compares_mixed_offsets_by_utc_instant(store):
    since = datetime(2024, 1, 1, 12, 0, tzinfo=UTC)
    timestamps = {
        "before": "2024-01-01 13:00:00+02:00",
        "at-boundary": "2024-01-01 13:00:00+01:00",
        "after": "2024-01-01 11:30:00-02:00",
    }
    for card_id, timestamp in timestamps.items():
        _add(store, card_id, updated_at=datetime(2024, 1, 1))
        with store.engine.begin() as connection:
            connection.execute(
                text("UPDATE card SET updated_at = :timestamp WHERE id = :card_id"),
                {"timestamp": timestamp, "card_id": card_id},
            )

    modified = store.get_modified_since(since)

    assert [card.id for card in modified] == ["after"]


def test_index_exists(store):
    from sqlalchemy import text

    with store.engine.connect() as conn:
        rows = conn.execute(text("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='card'")).all()
    names = {r[0] for r in rows}
    # Sync cursor index is an expression index on the same key the queries use (#3828).
    assert "ix_card_updated_key_id" in names
    # Raw-column indexes are superseded and dropped.
    assert "ix_card_updated_at_id" not in names
    assert "ix_card_updated_at" not in names


def test_get_modified_since_is_db_bounded_and_ordered(store):
    from sqlalchemy import event

    base = datetime(2024, 1, 1, 0, 0, 0)
    ids = _seed_distinct(store, 6, base)
    statements: list[str] = []

    @event.listens_for(store.engine, "before_cursor_execute")
    def _capture(_conn, _cursor, statement, _params, _ctx, _many):
        statements.append(statement)

    page = store.get_modified_since(base + timedelta(seconds=0), limit=3)
    event.remove(store.engine, "before_cursor_execute", _capture)

    assert [c.id for c in page] == ids[1:4]
    assert len(statements) == 1
    assert " IN (" not in statements[0]


def test_get_modified_since_after_cursor_and_filters(store):
    base = datetime(2024, 1, 1, 0, 0, 0)
    ids = _seed_distinct(store, 5, base)
    _add(store, "gone", updated_at=base + timedelta(seconds=10), is_deleted=True)
    _add(store, "other", updated_at=base + timedelta(seconds=11), notebook_id="nb2")

    page = store.get_modified_since(base, limit=2, after=(base + timedelta(seconds=2), ids[2]))
    assert [c.id for c in page] == [ids[3], ids[4]]
    everything = store.get_modified_since(base, exclude_notebook_ids=("nb2",))
    assert [c.id for c in everything] == [*ids[1:], "gone"]


def test_get_batch_survives_more_ids_than_sqlite_bind_limit(store):
    # Real SQLite store: one IN clause with >32766 binds raises OperationalError
    # ("too many SQL variables") unless the lookup is chunked.
    base = datetime(2024, 1, 1, 0, 0, 0)
    _add(store, "real-1", updated_at=base)
    _add(store, "real-2", updated_at=base)
    ids = {"real-1", "real-2"} | {f"ghost-{i}" for i in range(33_000)}
    found = store.get_batch(ids)
    assert set(found) == {"real-1", "real-2"}
    assert found["real-1"].id == "real-1"


def test_since_page_resolves_out_of_page_neighbours_beyond_bind_limit(store):
    from types import SimpleNamespace

    from kg.vocab_crud import list_vocab_cards

    base = datetime(2024, 1, 1, 0, 0, 0)
    _add(store, "p0", updated_at=base)

    class _Graph:
        def get_links_for(self, card_id):
            if card_id != "p0":
                return []
            return [SimpleNamespace(from_id="p0", to_id=f"ghost-{i}") for i in range(33_000)]

    responses, _cursor = list_vocab_cards(
        since="2000-01-01T00:00:00Z",
        cards_store=store,
        graph=_Graph(),
        card_response_builder=lambda card, graph, by_id: card.id,
        notebook_id=None,
        limit=5,
    )
    assert responses == ["p0"]


def test_since_pages_over_modified_set_larger_than_bind_limit(store):
    # #2687 done-when: a modified set above SQLite's bind limit pages through
    # the since path with each page bounded by `limit`, no OperationalError.
    from kg.vocab_crud import list_vocab_cards

    class _NoGraph:
        def get_links_for(self, card_id):
            return []

    base = datetime(2024, 1, 1, 0, 0, 0)
    total = 33_000
    with Session(store.engine) as session:
        session.add_all(
            Card(
                id=f"m{i:05d}",
                content=f"word-{i}",
                meaning="m",
                updated_at=base + timedelta(seconds=i),
                notebook_id="default",
                is_deleted=False,
            )
            for i in range(total)
        )
        session.commit()

    def page(after):
        return list_vocab_cards(
            since="2000-01-01T00:00:00Z",
            cards_store=store,
            graph=_NoGraph(),
            card_response_builder=lambda card, graph, by_id: card.id,
            notebook_id=None,
            limit=10_000,
            after=after,
        )

    seen: list[str] = []
    after = None
    for _ in range(4):
        responses, after = page(after)
        assert len(responses) <= 10_000
        seen.extend(responses)
        if after is None:
            break
    assert len(seen) == total
    assert len(set(seen)) == total


def _captured_plan(store: CardStore, run) -> str:
    """Run ``run`` and return SQLite's EXPLAIN QUERY PLAN for the card SELECT it emitted."""
    from sqlalchemy import event

    captured: list[tuple[str, tuple]] = []

    @event.listens_for(store.engine, "before_cursor_execute")
    def _capture(_conn, _cursor, statement, params, _ctx, _many):
        if "FROM card" in statement and statement.lstrip().upper().startswith("SELECT"):
            captured.append((statement, params))

    try:
        run()
    finally:
        event.remove(store.engine, "before_cursor_execute", _capture)

    assert captured, "query did not reach the card table"
    statement, params = captured[-1]
    with store.engine.connect() as conn:
        rows = conn.exec_driver_sql("EXPLAIN QUERY PLAN " + statement, params).all()
    return "\n".join(str(row[-1]) for row in rows)


def test_cursor_and_since_queries_use_index_not_full_scan_plus_sort(store):
    # Regression for #3828: the sync cursor queries order and filter by the
    # computed UTC-microsecond key, so SQLite must be able to walk an index on
    # that same expression. Otherwise every page is SCAN card + temp B-tree sort.
    base = datetime(2024, 1, 1, 0, 0, 0)
    ids = _seed_distinct(store, 20, base)
    cursor = (base + timedelta(seconds=3), ids[3])

    plans = {
        "page_cards(after=None)": _captured_plan(
            store, lambda: store.page_cards(limit=5, after=None, include_deleted=False, notebook_id=None)
        ),
        "page_cards(after=...)": _captured_plan(
            store, lambda: store.page_cards(limit=5, after=cursor, include_deleted=False, notebook_id=None)
        ),
        "get_modified_since(since=...)": _captured_plan(
            store, lambda: store.get_modified_since(base, limit=5, after=cursor)
        ),
    }

    for name, plan in plans.items():
        assert "USE TEMP B-TREE FOR ORDER BY" not in plan, f"{name}: {plan}"
        # A bare "SCAN card" is a table walk; "SCAN card USING INDEX" is the
        # ordered index walk that page_cards(after=None) needs (LIMIT stops it early).
        assert not any(line.startswith("SCAN card") and "USING" not in line for line in plan.splitlines()), name
        assert "USING INDEX" in plan or "USING COVERING INDEX" in plan, f"{name}: {plan}"
    # Cursor and since lookups must seek the index, not walk it from the start.
    for name in ("page_cards(after=...)", "get_modified_since(since=...)"):
        assert "SEARCH card USING INDEX ix_card_updated_key_id" in plans[name], f"{name}: {plans[name]}"
