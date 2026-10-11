"""Tests for push_review_states conflict resolution."""

from __future__ import annotations

import logging
from datetime import timedelta

from kg.api_models import ReviewStateEntry
from kg.cards import CardStore
from kg.vocab_review import push_review_states
from test_sync_merge import _entry, _iso, _make_store, _now

# push_review_states — conflict resolution
# ============================================================================


class TestPushReviewStates:
    def test_client_newer_accepts_all_fields(self, tmp_path):
        """When client last_reviewed_at > server, all fields should be accepted."""
        store = _make_store(tmp_path)
        card = store.add("evoke", "喚起")

        server_time = _now() - timedelta(hours=2)
        store.update(card.id, last_reviewed_at=server_time, review_count=3, lapse_count=1)

        client_time = _now()
        entry = _entry(
            "evoke",
            _iso(client_time),
            review_count=5,
            lapse_count=2,
            review_streak=4,
            review_interval_hours=48.0,
            last_review_feedback=1,
        )

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 1, "skipped": 0}

        updated = store.get(card.id)
        assert updated.review_interval_hours == 48.0
        assert updated.review_count == 5  # max(5, 3)
        assert updated.lapse_count == 2  # max(2, 1)
        assert updated.review_streak == 4
        assert updated.last_review_feedback == 1

    def test_server_newer_only_takes_max_counts(self, tmp_path):
        """When server last_reviewed_at >= client, only max counts should be updated."""
        store = _make_store(tmp_path)
        card = store.add("lucid", "清晰的")

        server_time = _now()
        store.update(
            card.id,
            last_reviewed_at=server_time,
            review_count=5,
            lapse_count=3,
            review_streak=10,
            review_interval_hours=72.0,
        )

        client_time = server_time - timedelta(hours=1)
        entry = _entry(
            "lucid",
            _iso(client_time),
            review_count=8,  # higher than server
            lapse_count=1,  # lower than server
            review_streak=2,
            review_interval_hours=24.0,
        )

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 1, "skipped": 0}

        updated = store.get(card.id)
        # Only review_count should change (8 > 5); lapse_count stays (1 < 3)
        assert updated.review_count == 8
        assert updated.lapse_count == 3
        # These must NOT change when server is newer
        assert updated.review_streak == 10
        assert updated.review_interval_hours == 72.0

    def test_server_newer_equal_counts_skips(self, tmp_path):
        """When server is newer and counts are equal or lower, entry is skipped."""
        store = _make_store(tmp_path)
        card = store.add("vivid", "生動的")

        server_time = _now()
        store.update(card.id, last_reviewed_at=server_time, review_count=5, lapse_count=3)

        client_time = server_time - timedelta(hours=1)
        entry = _entry("vivid", _iso(client_time), review_count=4, lapse_count=2)

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 0, "skipped": 1}

    def test_card_not_found_skips(self, tmp_path):
        """Entries for non-existent words should be skipped."""
        store = _make_store(tmp_path)
        store.add("exist", "存在")

        entry = _entry("nonexist", _iso(_now()))
        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 0, "skipped": 1}

    def test_invalid_last_reviewed_at_skips(self, tmp_path):
        """Entries with unparseable last_reviewed_at should be skipped."""
        store = _make_store(tmp_path)
        store.add("apple", "蘋果")

        entry = ReviewStateEntry(
            word="apple",
            review_interval_hours=24.0,
            next_review_at=_iso(_now() + timedelta(hours=24)),
            last_reviewed_at="not-a-date",
            review_count=1,
            lapse_count=0,
            review_streak=1,
            last_review_feedback=1,
        )
        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 0, "skipped": 1}

    def test_case_insensitive_word_match(self, tmp_path):
        """Word matching should be case-insensitive."""
        store = _make_store(tmp_path)
        store.add("Evoke", "喚起")

        entry = _entry("evoke", _iso(_now()), review_count=3)
        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 1, "skipped": 0}

    def test_same_timestamp_server_wins(self, tmp_path):
        """When timestamps are identical (>=), server wins — only max counts taken."""
        store = _make_store(tmp_path)
        card = store.add("precise", "精確的")

        same_time = _now()
        store.update(
            card.id,
            last_reviewed_at=same_time,
            review_count=3,
            review_streak=5,
            review_interval_hours=48.0,
        )

        entry = _entry(
            "precise",
            _iso(same_time),
            review_count=3,  # equal
            review_streak=2,
            review_interval_hours=24.0,
        )

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 0, "skipped": 1}

        updated = store.get(card.id)
        assert updated.review_streak == 5  # unchanged
        assert updated.review_interval_hours == 48.0  # unchanged

    def test_multiple_entries_mixed_outcomes(self, tmp_path):
        """Batch with mixed outcomes: some updated, some skipped."""
        store = _make_store(tmp_path)
        store.add("apple", "蘋果")
        banana = store.add("banana", "香蕉")

        # Set banana's server time to be newer than what client will send
        server_time = _now()
        store.update(banana.id, last_reviewed_at=server_time, review_count=5)

        old_time = server_time - timedelta(hours=5)
        new_time = _now() + timedelta(seconds=1)

        entries = [
            _entry("apple", _iso(new_time), review_count=10),  # client newer (server has None) → update
            _entry("banana", _iso(old_time), review_count=1),  # server newer, counts lower → skip
            _entry("cherry", _iso(new_time)),  # not found → skip
        ]

        result = push_review_states(entries, cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 1, "skipped": 2}

    def test_client_newer_uses_max_for_counts(self, tmp_path):
        """Even when client is newer, counts use max() not blind overwrite."""
        store = _make_store(tmp_path)
        card = store.add("nuance", "細微差別")

        server_time = _now() - timedelta(hours=1)
        store.update(card.id, last_reviewed_at=server_time, review_count=10, lapse_count=5)

        client_time = _now()
        entry = _entry(
            "nuance",
            _iso(client_time),
            review_count=3,  # lower than server
            lapse_count=8,  # higher than server
        )

        push_review_states([entry], cards_store=store, logger=logging.getLogger())
        updated = store.get(card.id)
        assert updated.review_count == 10  # max(3, 10)
        assert updated.lapse_count == 8  # max(8, 5)

    def test_card_id_targets_exact_card_cross_notebook(self, tmp_path):
        """When card_id is provided, only that exact card is updated — not same-word cards in other notebooks."""
        store = _make_store(tmp_path)
        card_a = store.add("run", "跑", notebook_id="notebook-a")
        card_b = store.add("run", "跑", notebook_id="notebook-b")

        client_time = _now()
        entry = _entry("run", _iso(client_time), review_count=5, review_streak=3, card_id=card_a.id)

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 1, "skipped": 0}

        updated_a = store.get(card_a.id)
        updated_b = store.get(card_b.id)
        assert updated_a.review_count == 5
        assert updated_a.review_streak == 3
        # notebook-b's "run" must be untouched
        assert updated_b.review_count == 0
        assert updated_b.review_streak == 0

    def test_card_id_fallback_word_match_without_card_id(self, tmp_path):
        """Without card_id, fallback to word matching — updates all same-word cards (backward compat)."""
        store = _make_store(tmp_path)
        card_a = store.add("evoke", "喚起", notebook_id="notebook-a")
        card_b = store.add("evoke", "喚起", notebook_id="notebook-b")

        client_time = _now()
        entry = _entry("evoke", _iso(client_time), review_count=5, review_streak=3)

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 2, "skipped": 0}

        updated_a = store.get(card_a.id)
        updated_b = store.get(card_b.id)
        assert updated_a.review_count == 5
        assert updated_b.review_count == 5
        assert updated_a.review_streak == 3
        assert updated_b.review_streak == 3

    def test_card_id_not_found_skips(self, tmp_path):
        """Entry with non-existent card_id should be skipped."""
        store = _make_store(tmp_path)
        store.add("run", "跑", notebook_id="default")

        client_time = _now()
        entry = _entry("run", _iso(client_time), review_count=5, card_id="nonexistent-id")

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 0, "skipped": 1}

    def test_duplicate_card_id_coalesces_to_newest_schedule(self, tmp_path):
        """A stale duplicate must not overwrite the newest review schedule."""
        store = _make_store(tmp_path)
        card = store.add("review", "複習")

        older_last = _now() - timedelta(hours=2)
        newer_last = older_last + timedelta(hours=1)
        older_entry = _entry(
            "review",
            _iso(older_last),
            card_id=card.id,
            review_interval_hours=12.0,
            next_review_at=_iso(older_last + timedelta(hours=12)),
            review_count=1,
            review_streak=1,
            last_review_feedback=0,
        )
        newer_entry = _entry(
            "review",
            _iso(newer_last),
            card_id=card.id,
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
        updated = store.get(card.id)
        assert updated.review_interval_hours == 48.0
        assert updated.next_review_at == (newer_last + timedelta(hours=48)).replace(tzinfo=None)
        assert updated.review_streak == 4
        assert updated.last_review_feedback == 1
        assert updated.last_reviewed_at == newer_last.replace(tzinfo=None)


# ============================================================================


class _RacingStore(CardStore):
    """Runs ``race`` once, right after the first ``get_batch`` snapshot is taken."""

    race = None

    def get_batch(self, card_ids):
        snapshot = super().get_batch(card_ids)
        race, self.race = self.race, None
        if race is not None:
            race()
        return snapshot


class TestPushReviewStatesConcurrentWriter:
    def test_concurrent_newer_review_is_not_clobbered(self, tmp_path):
        """A review landing between snapshot and write must survive an older client push (#2798)."""
        store = _RacingStore(tmp_path / "cards.db")
        card = store.add("evoke", "喚起")
        store.update(card.id, last_reviewed_at=_now() - timedelta(hours=3), review_count=3)
        newest = _now()
        store.race = lambda: store.update(card.id, last_reviewed_at=newest, review_count=9, review_streak=7)

        entry = _entry("evoke", _iso(_now() - timedelta(hours=1)), card_id=card.id, review_count=4, review_streak=1)
        push_review_states([entry], cards_store=store, logger=logging.getLogger())

        stored = store.get(card.id)
        assert stored.review_count == 9
        assert stored.review_streak == 7

    def test_concurrent_count_bump_is_not_lowered(self, tmp_path):
        """The counts-only branch must not write a stale max() over a concurrent bump (#2798)."""
        store = _RacingStore(tmp_path / "cards.db")
        card = store.add("lucid", "清晰的")
        server_time = _now()
        store.update(card.id, last_reviewed_at=server_time, review_count=3)
        store.race = lambda: store.update(card.id, review_count=10)

        entry = _entry("lucid", _iso(server_time - timedelta(hours=1)), card_id=card.id, review_count=5)
        push_review_states([entry], cards_store=store, logger=logging.getLogger())

        assert store.get(card.id).review_count == 10


class TestPushReviewCrossKeyAndStaged:
    def test_card_id_and_word_entries_for_same_card_coalesce_to_newest(self, tmp_path):
        """#2692: a card_id entry and a legacy word entry hitting one card must not race on order."""
        store = _make_store(tmp_path)
        card = store.add("merge", "合併")
        older = _now() - timedelta(hours=2)
        newer = older + timedelta(hours=1)
        newer_entry = _entry("merge", _iso(newer), card_id=card.id, review_interval_hours=48.0, review_count=2)
        older_word_entry = _entry("merge", _iso(older), review_interval_hours=12.0, review_count=1)

        for entries in ([newer_entry, older_word_entry], [older_word_entry, newer_entry]):
            fresh = store.get(card.id)
            store.update(card.id, last_reviewed_at=None, review_count=0, review_interval_hours=24.0)
            result = push_review_states(entries, cards_store=store, logger=logging.getLogger())
            assert result == {"updated": 1, "skipped": 1}, fresh
            updated = store.get(card.id)
            assert updated.review_interval_hours == 48.0
            assert updated.last_reviewed_at == newer.replace(tzinfo=None)

    def test_staged_notebook_cards_are_not_updated_by_word_or_card_id(self, tmp_path):
        """#2694: staged notebook cards stay hidden from the push path, like the pull path."""
        store = _make_store(tmp_path)
        visible = store.add("same", "可見", notebook_id="live")
        staged = store.add("same", "暫存", notebook_id="staged-nb")
        at = _iso(_now())

        by_word = push_review_states(
            [_entry("same", at, review_count=4)],
            cards_store=store,
            logger=logging.getLogger(),
            exclude_notebook_ids=["staged-nb"],
        )
        assert by_word == {"updated": 1, "skipped": 0}
        assert store.get(visible.id).review_count == 4
        assert store.get(staged.id).review_count == 0

        by_id = push_review_states(
            [_entry("same", at, card_id=staged.id, review_count=9)],
            cards_store=store,
            logger=logging.getLogger(),
            exclude_notebook_ids=["staged-nb"],
        )
        assert by_id == {"updated": 0, "skipped": 1}
        assert store.get(staged.id).review_count == 0


class TestPushReviewStatesOverrideRoundTrip:
    def test_override_reset_survives_reopen_on_server_newer_card(self, tmp_path):
        """#2042: an override pushed against a newer server card persists across a store reopen."""
        store = _make_store(tmp_path)
        card = store.add("progress", "進度")
        server_time = _now()
        store.update(card.id, last_reviewed_at=server_time, review_count=9, lapse_count=4)

        reset_at = _now()
        entry = _entry(
            "progress",
            _iso(server_time - timedelta(hours=1)),
            card_id=card.id,
            review_count=0,
            lapse_count=0,
            next_review_at=_iso(reset_at),
        ).model_copy(update={"override": True})

        result = push_review_states([entry], cards_store=store, logger=logging.getLogger())
        assert result == {"updated": 1, "skipped": 0}

        reopened = _make_store(tmp_path).get(card.id)
        assert reopened.review_count == 0
        assert reopened.lapse_count == 0
        assert abs(reopened.next_review_at - reset_at.replace(tzinfo=None)) < timedelta(seconds=5)
