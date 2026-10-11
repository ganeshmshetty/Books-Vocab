"""Tests for kg.vocab_review — push/pull review states using lightweight fakes.

Complements test_sync_merge.py (CardStore integration). Focuses on branches
that are otherwise easy to regress:
  * card_id-precise match wins over word fallback.
  * deleted card with matching card_id is treated as "not found".
  * get_batch is only called when at least one entry carries a card_id.
  * word-fallback updates *every* card sharing that word.
  * pending_updates is flushed via a single batch_update call.
  * client client_last unparseable -> skipped; no batch_update.
"""

from __future__ import annotations

import logging
from contextlib import closing
from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from sqlalchemy import text as sa_text
from sqlmodel import Session

from kg.api_models import ReviewStateEntry
from kg.cards import CardStore
from kg.vocab_review import push_review_states


# --------------------------------------------------------------------- #
# Fakes
# --------------------------------------------------------------------- #
@dataclass
class _ReviewCard:
    id: str
    content: str
    last_reviewed_at: datetime | None = None
    review_count: int = 0
    lapse_count: int = 0
    review_interval_hours: float = 0.0
    review_streak: int = 0
    last_review_feedback: int = 0
    next_review_at: datetime | None = None
    is_deleted: bool = False
    notebook_id: str = "default"


class _FakeCardsStore:
    def __init__(self, cards: list[_ReviewCard]) -> None:
        self._cards = list(cards)
        self.batch_update_calls: list[list[tuple[str, dict[str, Any]]]] = []
        self.get_batch_calls: list[set[str]] = []
        self.all_calls: list[str | None] = []

    def all(self, notebook_id: str | None = None) -> list[_ReviewCard]:
        self.all_calls.append(notebook_id)
        return [replace(c) for c in self._cards if not c.is_deleted]

    def get_batch(self, ids: set[str]) -> dict[str, _ReviewCard]:
        self.get_batch_calls.append(set(ids))
        # Copies, like a DB read: the store only changes through a write.
        return {c.id: replace(c) for c in self._cards if c.id in ids}

    def batch_update_if_unchanged(self, updates: list[tuple[str, dict[str, Any], dict[str, Any]]]) -> list[str]:
        self.batch_update_calls.append([(cid, patch) for cid, patch, _ in updates])
        by_id = {c.id: c for c in self._cards}
        rejected: list[str] = []
        for cid, patch, expected in updates:
            c = by_id.get(cid)
            if c is None or c.is_deleted or any(getattr(c, k) != v for k, v in expected.items()):
                rejected.append(cid)
                continue
            for k, v in patch.items():
                setattr(c, k, v)
        return rejected


class _FakeStatsStore:
    def __init__(self) -> None:
        self.upserts: list[dict[str, Any]] = []
        self._all: list[Any] = []
        self._since: list[Any] = []

    def upsert(self, *, day_key: str, total: int, remembered: int, forgot: int) -> None:
        self.upserts.append({"day_key": day_key, "total": total, "remembered": remembered, "forgot": forgot})

    def all(self) -> list[Any]:
        return list(self._all)

    def get_since(self, since: str) -> list[Any]:
        return [s for s in self._all if s.day_key >= since]


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def _entry(
    *,
    word: str,
    last_reviewed_at: str,
    card_id: str | None = None,
    review_count: int = 1,
    lapse_count: int = 0,
    review_streak: int = 1,
    review_interval_hours: float = 24.0,
    next_review_at: str | None = None,
    last_review_feedback: int = 1,
    override: bool = False,
) -> ReviewStateEntry:
    return ReviewStateEntry(
        word=word,
        card_id=card_id,
        review_interval_hours=review_interval_hours,
        next_review_at=next_review_at or _iso(datetime.now(UTC) + timedelta(hours=24)),
        last_reviewed_at=last_reviewed_at,
        review_count=review_count,
        lapse_count=lapse_count,
        review_streak=review_streak,
        last_review_feedback=last_review_feedback,
        override=override,
    )


# --------------------------------------------------------------------- #
# push_review_states
# --------------------------------------------------------------------- #
class TestPushReviewStatesFakes:
    def test_out_of_range_timestamp_entry_skipped_valid_entries_applied(self):
        bad = _ReviewCard(id="bad", content="bad")
        good = _ReviewCard(id="good", content="good")
        store = _FakeCardsStore([bad, good])
        entries = [
            _entry(word="bad", card_id="bad", last_reviewed_at="inf"),
            _entry(word="bad", card_id="bad", last_reviewed_at="1e30"),
            _entry(word="good", card_id="good", last_reviewed_at=_iso(datetime.now(UTC)), review_count=3),
        ]

        result = push_review_states(entries, cards_store=store, logger=logging.getLogger())

        assert result["updated"] == 1
        assert good.review_count == 3
        assert bad.review_count == 0

    def test_far_future_last_reviewed_at_is_clamped_to_now(self):
        for future in ("9999-01-01T00:00:00+00:00", _iso(datetime.now(UTC) + timedelta(days=1))):
            card = _ReviewCard(id="c1", content="run")
            store = _FakeCardsStore([card])
            before = datetime.now(UTC)
            push_review_states(
                [_entry(word="run", card_id="c1", last_reviewed_at=future)],
                cards_store=store,
                logger=logging.getLogger(),
            )
            after = datetime.now(UTC)
            assert before <= card.last_reviewed_at <= after

    def test_skewed_client_next_review_shifted_back_by_same_offset(self):
        card = _ReviewCard(id="c1", content="run")
        store = _FakeCardsStore([card])
        skew = timedelta(days=1)
        real_now = datetime.now(UTC)
        push_review_states(
            [
                _entry(
                    word="run",
                    card_id="c1",
                    last_reviewed_at=_iso(real_now + skew),
                    next_review_at=_iso(real_now + skew + timedelta(hours=24)),
                    review_interval_hours=24.0,
                )
            ],
            cards_store=store,
            logger=logging.getLogger(),
        )
        expected = real_now + timedelta(hours=24)
        assert abs(card.next_review_at - expected) < timedelta(seconds=30)

    def test_future_clock_skew_does_not_freeze_later_push(self):
        card = _ReviewCard(id="c1", content="run")
        store = _FakeCardsStore([card])
        log = logging.getLogger()
        push_review_states(
            [_entry(word="run", card_id="c1", last_reviewed_at="9999-01-01T00:00:00+00:00")],
            cards_store=store,
            logger=log,
        )
        later = datetime.now(UTC) + timedelta(seconds=1)
        next_at = later + timedelta(hours=48)
        result = push_review_states(
            [
                _entry(
                    word="run",
                    card_id="c1",
                    last_reviewed_at=_iso(later),
                    next_review_at=_iso(next_at),
                    review_interval_hours=48.0,
                    review_streak=5,
                    last_review_feedback=-1,
                )
            ],
            cards_store=store,
            logger=log,
        )
        assert result["updated"] == 1
        assert card.review_interval_hours == 48.0
        assert card.next_review_at == next_at
        assert card.review_streak == 5
        assert card.last_review_feedback == -1

    def test_last_reviewed_at_within_skew_tolerance_unchanged(self):
        card = _ReviewCard(id="c1", content="run")
        store = _FakeCardsStore([card])
        ts = datetime.now(UTC) + timedelta(minutes=2)
        push_review_states(
            [_entry(word="run", card_id="c1", last_reviewed_at=_iso(ts))],
            cards_store=store,
            logger=logging.getLogger(),
        )
        assert card.last_reviewed_at == ts

    def test_far_future_next_review_at_is_capped(self):
        card = _ReviewCard(id="c1", content="run")
        store = _FakeCardsStore([card])
        push_review_states(
            [
                _entry(
                    word="run",
                    card_id="c1",
                    last_reviewed_at=_iso(datetime.now(UTC)),
                    next_review_at="9999-01-01T00:00:00+00:00",
                )
            ],
            cards_store=store,
            logger=logging.getLogger(),
        )
        assert card.next_review_at < datetime.now(UTC) + timedelta(days=3660)

    def test_normal_future_next_review_at_unchanged(self):
        card = _ReviewCard(id="c1", content="run")
        store = _FakeCardsStore([card])
        nxt = datetime.now(UTC) + timedelta(days=90)
        push_review_states(
            [_entry(word="run", card_id="c1", last_reviewed_at=_iso(datetime.now(UTC)), next_review_at=_iso(nxt))],
            cards_store=store,
            logger=logging.getLogger(),
        )
        assert card.next_review_at == nxt

    def test_card_id_match_wins_over_word_fallback(self):
        # Two cards share the word "run" — entry's card_id must select c2.
        c1 = _ReviewCard(id="c1", content="run")
        c2 = _ReviewCard(id="c2", content="run")
        store = _FakeCardsStore([c1, c2])
        client_time = datetime.now(UTC)
        entry = _entry(word="run", last_reviewed_at=_iso(client_time), card_id="c2", review_count=7)

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())

        assert result == {"updated": 1, "skipped": 0}
        # Only c2 must be touched.
        assert len(store.batch_update_calls) == 1
        flushed = store.batch_update_calls[0]
        assert [cid for cid, _ in flushed] == ["c2"]
        # get_batch was queried; word index was never built.
        assert store.get_batch_calls == [{"c2"}]
        assert store.all_calls == []

    def test_deleted_card_with_matching_card_id_is_skipped(self):
        c1 = _ReviewCard(id="c1", content="cat", is_deleted=True)
        store = _FakeCardsStore([c1])
        entry = _entry(
            word="cat",
            card_id="c1",
            last_reviewed_at=_iso(datetime.now(UTC)),
        )

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        # get_batch returns c1, but the filter `not card.is_deleted` rejects it.
        assert result == {"updated": 0, "skipped": 1}
        assert store.batch_update_calls == []

    def test_no_card_id_entries_skip_get_batch(self):
        c1 = _ReviewCard(id="c1", content="cat")
        store = _FakeCardsStore([c1])
        entry = _entry(word="cat", last_reviewed_at=_iso(datetime.now(UTC)))

        push_review_states([entry], cards_store=store, logger=logging.getLogger())
        # When no entry has a card_id, the pre-fetch is skipped entirely.
        assert store.get_batch_calls == []
        # word lookup did happen.
        assert store.all_calls == [None]

    def test_word_fallback_updates_all_matching_cards(self):
        c1 = _ReviewCard(id="c1", content="run")
        c2 = _ReviewCard(id="c2", content="Run")  # case-insensitive same word
        store = _FakeCardsStore([c1, c2])
        entry = _entry(word="run", last_reviewed_at=_iso(datetime.now(UTC)))

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())

        assert result == {"updated": 2, "skipped": 0}
        flushed_ids = [cid for cid, _ in store.batch_update_calls[0]]
        assert sorted(flushed_ids) == ["c1", "c2"]

    def test_unparseable_last_reviewed_at_is_skipped(self):
        c1 = _ReviewCard(id="c1", content="cat")
        store = _FakeCardsStore([c1])
        # last_reviewed_at is a string the field allows but parse_datetime can't read.
        entry = _entry(word="cat", last_reviewed_at="not-a-timestamp")

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())

        assert result == {"updated": 0, "skipped": 1}
        assert store.batch_update_calls == []

    def test_malformed_next_review_at_warns_but_still_accepts(self, caplog):
        """Client is newer + next_review_at present but unparseable.

        The schedule is silently reset to None today; this must now emit a
        WARNING (with card id + raw value) so the reset is diagnosable — while
        keeping the existing accept/write behaviour unchanged.
        """
        c1 = _ReviewCard(id="c1", content="cat")
        store = _FakeCardsStore([c1])
        client_time = datetime.now(UTC)
        entry = _entry(
            word="cat",
            card_id="c1",
            last_reviewed_at=_iso(client_time),
            next_review_at="garbage-not-a-date",  # present, but parse_datetime -> None
        )

        with caplog.at_level(logging.WARNING):
            result = push_review_states([entry], cards_store=store, logger=logging.getLogger())

        # Behaviour is unchanged: card is still accepted/written, next_review_at=None.
        assert result == {"updated": 1, "skipped": 0}
        flushed = store.batch_update_calls[0][0][1]
        assert flushed["next_review_at"] is None
        assert flushed["last_reviewed_at"] == client_time
        # The silent reset is now visible: a WARNING naming the card + raw value.
        warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
        assert len(warnings) == 1
        msg = warnings[0].getMessage()
        assert "c1" in msg
        assert "garbage-not-a-date" in msg

    def test_valid_next_review_at_does_not_warn(self, caplog):
        """Normal payload (parseable next_review_at) must not emit any warning."""
        c1 = _ReviewCard(id="c1", content="cat")
        store = _FakeCardsStore([c1])
        client_time = datetime.now(UTC)
        entry = _entry(
            word="cat",
            card_id="c1",
            last_reviewed_at=_iso(client_time),
            next_review_at=_iso(client_time + timedelta(hours=24)),
        )

        with caplog.at_level(logging.WARNING):
            result = push_review_states([entry], cards_store=store, logger=logging.getLogger())

        assert result == {"updated": 1, "skipped": 0}
        assert [r for r in caplog.records if r.levelno == logging.WARNING] == []

    def test_empty_next_review_at_does_not_warn(self, caplog):
        """Empty next_review_at == 'not meaningfully sent' -> reset is expected,
        no false-positive warning. Distinguishes 'absent/empty' from 'malformed'."""
        c1 = _ReviewCard(id="c1", content="cat")
        store = _FakeCardsStore([c1])
        client_time = datetime.now(UTC)
        entry = _entry(
            word="cat",
            card_id="c1",
            last_reviewed_at=_iso(client_time),
            next_review_at="   ",  # whitespace-only -> parse None, but not a real value
        )

        with caplog.at_level(logging.WARNING):
            result = push_review_states([entry], cards_store=store, logger=logging.getLogger())

        # Still accepted (behaviour unchanged), but no warning fired.
        assert result == {"updated": 1, "skipped": 0}
        assert store.batch_update_calls[0][0][1]["next_review_at"] is None
        assert [r for r in caplog.records if r.levelno == logging.WARNING] == []

    def test_server_newer_takes_max_counts(self):
        server_time = datetime.now(UTC)
        client_time = server_time - timedelta(hours=1)
        c1 = _ReviewCard(
            id="c1",
            content="cat",
            last_reviewed_at=server_time,
            review_count=3,
            lapse_count=1,
        )
        store = _FakeCardsStore([c1])
        entry = _entry(
            word="cat",
            last_reviewed_at=_iso(client_time),
            review_count=5,
            lapse_count=0,  # only review_count is higher than server
        )

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())

        assert result == {"updated": 1, "skipped": 0}
        flushed = store.batch_update_calls[0][0][1]
        # Server stayed in charge of dates — only counts moved.
        assert "next_review_at" not in flushed
        assert flushed == {"review_count": 5, "lapse_count": 1}

    def test_server_newer_no_count_change_skipped(self):
        server_time = datetime.now(UTC)
        client_time = server_time - timedelta(hours=1)
        c1 = _ReviewCard(
            id="c1",
            content="cat",
            last_reviewed_at=server_time,
            review_count=10,
            lapse_count=2,
        )
        store = _FakeCardsStore([c1])
        entry = _entry(
            word="cat",
            last_reviewed_at=_iso(client_time),
            review_count=5,
            lapse_count=1,
        )

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 0, "skipped": 1}
        assert store.batch_update_calls == []  # nothing flushed

    def test_override_resets_counts_when_server_newer(self):
        """Progress override must persist a reset even though the server copy is newer."""
        server_time = datetime.now(UTC)
        client_time = server_time - timedelta(hours=1)
        c1 = _ReviewCard(
            id="c1",
            content="cat",
            last_reviewed_at=server_time,
            review_count=10,
            lapse_count=3,
        )
        store = _FakeCardsStore([c1])
        reset_at = datetime.now(UTC)
        entry = _entry(
            word="cat",
            last_reviewed_at=_iso(client_time),
            review_count=0,
            lapse_count=0,
            next_review_at=_iso(reset_at),
            override=True,
        )

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())

        assert result == {"updated": 1, "skipped": 0}
        assert c1.review_count == 0
        assert c1.lapse_count == 0
        assert abs(c1.next_review_at - reset_at) < timedelta(seconds=5)
        assert c1.last_reviewed_at == server_time  # history is not rewritten

    def test_override_reset_writes_schedule_fields_when_server_newer(self):
        """Server-newer override must reset interval/streak/feedback like the client-newer branch."""
        server_time = datetime.now(UTC)
        c1 = _ReviewCard(
            id="c1",
            content="cat",
            last_reviewed_at=server_time,
            review_count=10,
            lapse_count=3,
            review_interval_hours=96.0,
            review_streak=5,
            last_review_feedback=1,
        )
        store = _FakeCardsStore([c1])
        entry = _entry(
            word="cat",
            last_reviewed_at=_iso(server_time - timedelta(hours=1)),
            review_count=0,
            lapse_count=0,
            review_interval_hours=12.0,
            review_streak=0,
            last_review_feedback=-1,
            override=True,
        )

        push_review_states([entry], cards_store=store, logger=logging.getLogger())

        assert c1.review_interval_hours == 12.0
        assert c1.review_streak == 0
        assert c1.last_review_feedback == -1

    def test_override_schedule_is_independent_of_clock_order(self):
        """Same override entry must yield the same schedule whichever side of the clock is newer."""
        base = datetime(2026, 9, 1, 9, 0, tzinfo=UTC)
        reset_at = base + timedelta(hours=12)
        kwargs = dict(
            review_count=0,
            lapse_count=0,
            review_interval_hours=12.0,
            review_streak=0,
            last_review_feedback=-1,
            next_review_at=_iso(reset_at),
            override=True,
        )

        def _run(server_last: datetime, client_last: datetime) -> _ReviewCard:
            card = _ReviewCard(
                id="c1",
                content="cat",
                last_reviewed_at=server_last,
                review_count=10,
                lapse_count=3,
                review_interval_hours=96.0,
                review_streak=5,
                last_review_feedback=1,
            )
            push_review_states(
                [_entry(word="cat", last_reviewed_at=_iso(client_last), **kwargs)],
                cards_store=_FakeCardsStore([card]),
                logger=logging.getLogger(),
            )
            return card

        server_newer = _run(base + timedelta(hours=1), base)
        client_newer = _run(base, base + timedelta(hours=1))

        for field in ("review_count", "lapse_count", "review_interval_hours", "review_streak", "last_review_feedback"):
            assert getattr(server_newer, field) == getattr(client_newer, field), field
        assert server_newer.next_review_at == client_newer.next_review_at == reset_at

    @pytest.fixture
    def frozen_clock(self, monkeypatch: pytest.MonkeyPatch) -> datetime:
        """Pin vocab_review's clock so the skew clamp and horizon are deterministic."""
        now = datetime(2026, 10, 12, 9, 0, tzinfo=UTC)

        class _FrozenDatetime(datetime):
            @classmethod
            def now(cls, tz=None):
                return now

        monkeypatch.setattr("kg.vocab_review.datetime", _FrozenDatetime)
        return now

    def test_override_schedule_matches_across_clock_order_with_skew_clamp(self, frozen_clock):
        """Same override must yield one schedule on both branches when the client clock is skewed.

        The client runs 30 min fast: its last_reviewed_at is clamped to now and its next_review_at
        is shifted back by that same offset on the client-newer branch, so the server-newer branch
        must apply the identical correction (#2042 CR P2).
        """
        now = frozen_clock
        skewed_last = now + timedelta(minutes=30)
        kwargs = dict(
            last_reviewed_at=_iso(skewed_last),
            review_count=0,
            lapse_count=0,
            review_interval_hours=12.0,
            review_streak=0,
            last_review_feedback=-1,
            next_review_at=_iso(skewed_last + timedelta(hours=12)),  # derived from the fast clock
            override=True,
        )

        def _run(server_last: datetime) -> _ReviewCard:
            card = _ReviewCard(
                id="c1",
                content="cat",
                last_reviewed_at=server_last,
                review_count=10,
                lapse_count=3,
                review_interval_hours=96.0,
                review_streak=5,
                last_review_feedback=1,
            )
            push_review_states(
                [_entry(word="cat", **kwargs)],
                cards_store=_FakeCardsStore([card]),
                logger=logging.getLogger(),
            )
            return card

        server_newer = _run(now + timedelta(minutes=4))  # inside skew tolerance, stored as-is
        client_newer = _run(now - timedelta(hours=1))

        assert server_newer.next_review_at == client_newer.next_review_at == now + timedelta(hours=12)

    @pytest.mark.parametrize("raw_next", ["", "not-a-date"])
    def test_override_unusable_next_review_resets_schedule_on_both_branches(self, frozen_clock, caplog, raw_next):
        """Missing/unparseable override next_review_at resets the schedule on both branches, like client-newer."""
        now = frozen_clock
        resets: list[datetime | None] = []
        for server_last in (now + timedelta(minutes=4), now - timedelta(hours=1)):
            card = _ReviewCard(
                id="c1",
                content="cat",
                last_reviewed_at=server_last,
                review_count=10,
                lapse_count=3,
                next_review_at=now + timedelta(days=3),
            )
            # _entry() substitutes a default for falsy next_review_at; patch the raw value after validation.
            entry = _entry(
                word="cat", last_reviewed_at=_iso(now), review_count=0, lapse_count=0, override=True
            ).model_copy(update={"next_review_at": raw_next})
            with caplog.at_level(logging.WARNING):
                push_review_states([entry], cards_store=_FakeCardsStore([card]), logger=logging.getLogger())
            resets.append(card.next_review_at)

        assert resets == [None, None]
        warned = [r for r in caplog.records if "unparseable next_review_at" in r.getMessage()]
        assert len(warned) == (2 if raw_next == "not-a-date" else 0)

    def test_override_resets_counts_when_client_newer(self):
        """Override is exact on the client-newer branch too; max() would undo the reset."""
        server_time = datetime.now(UTC) - timedelta(hours=2)
        c1 = _ReviewCard(id="c1", content="cat", last_reviewed_at=server_time, review_count=10, lapse_count=3)
        store = _FakeCardsStore([c1])
        entry = _entry(
            word="cat",
            last_reviewed_at=_iso(datetime.now(UTC)),
            review_count=0,
            lapse_count=0,
            override=True,
        )

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())

        assert result == {"updated": 1, "skipped": 0}
        assert c1.review_count == 0
        assert c1.lapse_count == 0

    def test_override_newest_entry_wins_over_older_regular_counts(self):
        """Coalescing: a newer override keeps its zero counts instead of max() with older entries."""
        base = datetime(2026, 9, 1, 9, 0, tzinfo=UTC)
        store = _FakeCardsStore([_ReviewCard(id="c1", content="review")])
        older_regular = _entry(
            word="review",
            last_reviewed_at=_iso(base),
            review_count=7,
            lapse_count=2,
        )
        newer_override = _entry(
            word="review",
            last_reviewed_at=_iso(base + timedelta(hours=1)),
            review_count=0,
            lapse_count=0,
            override=True,
        )

        push_review_states([older_regular, newer_override], cards_store=store, logger=logging.getLogger())

        assert store._cards[0].review_count == 0
        assert store._cards[0].lapse_count == 0

    def test_single_batch_update_call_for_many_entries(self):
        """N entries must collapse into ONE batch_update call (write-path perf)."""
        cards = [_ReviewCard(id=f"c{i}", content=f"w{i}") for i in range(5)]
        store = _FakeCardsStore(cards)
        client = datetime.now(UTC)
        entries = [_entry(word=f"w{i}", last_reviewed_at=_iso(client)) for i in range(5)]

        push_review_states(entries, cards_store=store, logger=logging.getLogger())

        assert len(store.batch_update_calls) == 1
        assert len(store.batch_update_calls[0]) == 5

    def test_notebook_scope_threaded_into_all(self):
        store = _FakeCardsStore([_ReviewCard(id="c1", content="cat")])
        entry = _entry(word="cat", last_reviewed_at=_iso(datetime.now(UTC)))

        push_review_states([entry], cards_store=store, logger=logging.getLogger(), notebook_id="nb_x")
        assert store.all_calls == ["nb_x"]

    def test_empty_entries_returns_zero(self):
        store = _FakeCardsStore([])
        result = push_review_states([], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 0, "skipped": 0}
        assert store.get_batch_calls == []
        assert store.batch_update_calls == []

    def test_duplicate_word_fallback_coalesces_to_newest_schedule(self):
        """Legacy word-only retries must not roll a card back by input order."""
        older_last = datetime(2026, 9, 1, 9, 0, tzinfo=UTC)
        newer_last = older_last + timedelta(hours=1)
        store = _FakeCardsStore([_ReviewCard(id="c1", content="review")])
        older_entry = _entry(
            word="review",
            last_reviewed_at=_iso(older_last),
            review_interval_hours=12.0,
            next_review_at=_iso(older_last + timedelta(hours=12)),
            review_count=1,
            review_streak=1,
            last_review_feedback=0,
        )
        newer_entry = _entry(
            word="review",
            last_reviewed_at=_iso(newer_last),
            review_interval_hours=48.0,
            next_review_at=_iso(newer_last + timedelta(hours=48)),
            review_count=2,
            review_streak=4,
            last_review_feedback=1,
        )

        result = push_review_states(
            [newer_entry, older_entry],
            cards_store=store,
            logger=logging.getLogger(),
        )

        assert result == {"updated": 1, "skipped": 1}
        assert len(store.batch_update_calls) == 1
        assert len(store.batch_update_calls[0]) == 1
        updated = store._cards[0]
        assert updated.review_interval_hours == 48.0
        assert updated.next_review_at == newer_last + timedelta(hours=48)
        assert updated.review_streak == 4
        assert updated.last_review_feedback == 1
        assert updated.last_reviewed_at == newer_last


class TestPushReviewStatesRealStore:
    """Real CardStore: the CAS guard must not depend on stored timestamp text."""

    @pytest.mark.parametrize(
        "stored",
        ["2026-01-01 00:00:00", "2026-01-01T00:00:00.500000", "2026-01-01 00:00:00.000000+00:00"],
    )
    def test_client_newer_push_lands_for_non_canonical_stored_text(self, tmp_path, stored):
        with closing(CardStore(tmp_path / "cards.db")) as store:
            card = store.add("run", meaning="x")
            with Session(store.engine) as session:
                session.exec(
                    sa_text("UPDATE card SET last_reviewed_at = :v, review_count = 3 WHERE id = :i").bindparams(
                        v=stored, i=card.id
                    )
                )
                session.commit()
            result = push_review_states(
                [
                    _entry(
                        word="run",
                        card_id=card.id,
                        last_reviewed_at=_iso(datetime.now(UTC) - timedelta(minutes=1)),
                        review_count=4,
                    )
                ],
                cards_store=store,
                logger=logging.getLogger(),
            )
            assert result == {"updated": 1, "skipped": 0}
            assert store.get(card.id).review_count == 4

    def test_skew_shift_against_real_store(self, tmp_path):
        with closing(CardStore(tmp_path / "cards.db")) as store:
            card = store.add("run", meaning="x")
            skew = timedelta(days=1)
            now = datetime.now(UTC)
            push_review_states(
                [
                    _entry(
                        word="run",
                        card_id=card.id,
                        last_reviewed_at=_iso(now + skew),
                        next_review_at=_iso(now + skew + timedelta(hours=24)),
                    )
                ],
                cards_store=store,
                logger=logging.getLogger(),
            )
            nxt = store.get(card.id).next_review_at.replace(tzinfo=UTC)
            assert abs(nxt - (now + timedelta(hours=24))) < timedelta(seconds=30)


class TestPushReviewStatesEdgeCases:
    def test_absurd_skew_overflow_sets_next_review_none(self):
        card = _ReviewCard(id="c1", content="run", next_review_at=datetime.now(UTC))
        store = _FakeCardsStore([card])
        push_review_states(
            [
                _entry(
                    word="run",
                    card_id="c1",
                    last_reviewed_at="9999-12-31T00:00:00+00:00",
                    next_review_at="0001-01-02T00:00:00+00:00",
                )
            ],
            cards_store=store,
            logger=logging.getLogger(),
        )
        assert card.next_review_at is None
        assert card.review_count == 1

    def test_conflict_on_every_attempt_skips_and_warns(self, caplog):
        card = _ReviewCard(id="c1", content="run")
        store = _FakeCardsStore([card])
        real = store.batch_update_if_unchanged

        def racing(updates):
            card.review_count += 1  # a concurrent writer wins before every CAS
            return real(updates)

        store.batch_update_if_unchanged = racing
        with caplog.at_level(logging.WARNING):
            result = push_review_states(
                [_entry(word="run", card_id="c1", last_reviewed_at=_iso(datetime.now(UTC)), review_count=1)],
                cards_store=store,
                logger=logging.getLogger("t"),
            )
        assert result == {"updated": 0, "skipped": 1}
        assert "kept conflicting" in caplog.text
