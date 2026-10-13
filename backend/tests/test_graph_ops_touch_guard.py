"""Touch-failure guards for vocab_graph_ops.

Root cause (#720 Q2): every graph op (create_manual_link, hide/unhide/delete)
mutated the graph first, then called cards_store.touch() with zero protection.
If touch raised, the graph was already changed but the cards' updated_at was
NOT bumped -> iOS get_modified_since permanently misses the change -> silent
graph/card divergence.

These tests pin the failure contract:
  * touch failure must NOT be swallowed -> the op re-raises (no fake success).
  * the failure must be observable -> logger.error is emitted.
  * both endpoints are always attempted (a failure on the first card must not
    skip touching the second -- maximizing the chance the client still sees the
    change on at least one side).
  * reversible ops (hide/unhide) roll the graph back so graph and card state
    stay consistent when the touch barrier fails.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from kg.graph import GraphStore, LinkKind
from kg.judge import ManualLinkJudge
from kg.vocab_graph_ops import (
    create_manual_link,
    delete_graph_link,
    hide_graph_link,
    unhide_graph_link,
)


@pytest.fixture()
def store(tmp_path):
    return GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )


class FakeCard:
    def __init__(
        self, id, content="word", meaning="meaning", is_deleted=False, is_archived=False, notebook_id="default"
    ):
        self.id = id
        self.content = content
        self.meaning = meaning
        self.is_deleted = is_deleted
        self.is_archived = is_archived
        self.notebook_id = notebook_id


class FakeCardsStore:
    """Cards store whose touch() can be made to raise for specific ids.

    `fail_ids` = set of card ids whose touch() raises RuntimeError. Every
    touch() call (success or failure) is recorded in `touched` so tests can
    assert both endpoints were attempted even when the first one fails.
    """

    def __init__(self, cards, fail_ids=None):
        self._cards = {c.id: c for c in cards}
        self.touched: list[str] = []
        self.fail_ids = set(fail_ids or [])

    def get(self, card_id):
        return self._cards.get(card_id)

    def touch(self, card_id):
        self.touched.append(card_id)
        if card_id in self.fail_ids:
            raise RuntimeError(f"simulated touch failure for {card_id}")


def _make_judge(response_json: str):
    client = MagicMock()
    choice = MagicMock()
    choice.message.content = response_json
    resp = MagicMock()
    resp.choices = [choice]
    resp.usage = None
    client.chat.completions.create.return_value = resp
    from kg.tracked_llm import TrackedLLM

    return ManualLinkJudge(TrackedLLM(client, "test_user"))


class TestHideTouchGuard:
    def test_touch_failure_reraises(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"b"})
        with pytest.raises(RuntimeError):
            hide_graph_link(link_id=lk.id, graph=store, cards_store=cards)

    def test_touch_failure_attempts_both_endpoints(self, store):
        """First-endpoint touch failure must NOT skip the second endpoint."""
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"a"})
        with pytest.raises(RuntimeError):
            hide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert "a" in cards.touched and "b" in cards.touched

    def test_touch_failure_rolls_back_graph(self, store):
        """Reversible op: a failed touch barrier restores the link to active."""
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"b"})
        with pytest.raises(RuntimeError):
            hide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        # link must NOT be left hidden
        assert store.get_link(lk.id).status == "active"

    def test_touch_failure_logs_error(self, store, caplog):
        import logging

        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"b"})
        with caplog.at_level(logging.ERROR, logger="kg.vocab_graph_ops"):
            with pytest.raises(RuntimeError):
                hide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert any(rec.levelno == logging.ERROR for rec in caplog.records)


class TestUnhideTouchGuard:
    def test_touch_failure_reraises(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"b"})
        with pytest.raises(RuntimeError):
            unhide_graph_link(link_id=lk.id, graph=store, cards_store=cards)

    def test_touch_failure_rolls_back_graph(self, store):
        """Reversible op: a failed touch restores the link to hidden."""
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"b"})
        with pytest.raises(RuntimeError):
            unhide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert store.get_link(lk.id).status == "hidden"

    def test_touch_failure_attempts_both_endpoints(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"a"})
        with pytest.raises(RuntimeError):
            unhide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert "a" in cards.touched and "b" in cards.touched


class TestDeleteTouchGuard:
    def test_touch_failure_reraises(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"b"})
        with pytest.raises(RuntimeError):
            delete_graph_link(link_id=lk.id, graph=store, cards_store=cards)

    def test_touch_failure_attempts_both_endpoints(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"a"})
        with pytest.raises(RuntimeError):
            delete_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert "a" in cards.touched and "b" in cards.touched

    def test_touch_failure_logs_error(self, store, caplog):
        import logging

        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"b"})
        with caplog.at_level(logging.ERROR, logger="kg.vocab_graph_ops"):
            with pytest.raises(RuntimeError):
                delete_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert any(rec.levelno == logging.ERROR for rec in caplog.records)


class TestCreateManualLinkTouchGuard:
    def test_new_link_touch_failure_reraises(self, store):
        cards = FakeCardsStore(
            [FakeCard("a", content="apple", meaning="蘋果"), FakeCard("b", content="banana", meaning="香蕉")],
            fail_ids={"b"},
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "r"}')
        with pytest.raises(RuntimeError):
            create_manual_link(
                from_id="a", to_id="b", graph=store, cards_store=cards, judge=judge, notebook_id="default"
            )

    def test_new_link_touch_failure_attempts_both_endpoints(self, store):
        cards = FakeCardsStore(
            [FakeCard("a", content="apple", meaning="蘋果"), FakeCard("b", content="banana", meaning="香蕉")],
            fail_ids={"a"},
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "r"}')
        with pytest.raises(RuntimeError):
            create_manual_link(
                from_id="a", to_id="b", graph=store, cards_store=cards, judge=judge, notebook_id="default"
            )
        assert "a" in cards.touched and "b" in cards.touched

    def test_new_link_touch_failure_logs_error(self, store, caplog):
        import logging

        cards = FakeCardsStore(
            [FakeCard("a", content="apple", meaning="蘋果"), FakeCard("b", content="banana", meaning="香蕉")],
            fail_ids={"b"},
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "r"}')
        with caplog.at_level(logging.ERROR, logger="kg.vocab_graph_ops"):
            with pytest.raises(RuntimeError):
                create_manual_link(
                    from_id="a", to_id="b", graph=store, cards_store=cards, judge=judge, notebook_id="default"
                )
        assert any(rec.levelno == logging.ERROR for rec in caplog.records)

    def test_unhide_branch_touch_failure_reraises_and_rolls_back(self, store):
        """create_manual_link on a hidden pair -> unhides; touch failure must
        re-raise AND roll the link back to hidden (reversible path)."""
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "original")
        store.hide_link(lk.id)
        cards = FakeCardsStore(
            [FakeCard("a", content="apple", meaning="蘋果"), FakeCard("b", content="banana", meaning="香蕉")],
            fail_ids={"b"},
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "新"}')
        with pytest.raises(RuntimeError):
            create_manual_link(
                from_id="a", to_id="b", graph=store, cards_store=cards, judge=judge, notebook_id="default"
            )
        assert store.get_link(lk.id).status == "hidden"


class TestSuccessPathUnchanged:
    """Guards must not alter the happy path: both cards still touched, return
    value preserved."""

    def test_hide_success_still_touches_both(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        hide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert "a" in cards.touched and "b" in cards.touched
        assert store.get_link(lk.id).status == "hidden"

    def test_create_success_returns_link_and_touches_both(self, store):
        cards = FakeCardsStore(
            [FakeCard("a", content="apple", meaning="蘋果"), FakeCard("b", content="banana", meaning="香蕉")],
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "r"}')
        link = create_manual_link(
            from_id="a", to_id="b", graph=store, cards_store=cards, judge=judge, notebook_id="default"
        )
        assert link is not None
        assert "a" in cards.touched and "b" in cards.touched


class _RaisingJudge:
    def evaluate(self, *args, **kwargs):
        from kg.exceptions import QuotaExceededError

        raise QuotaExceededError(60)


class TestCreateManualLinkUnblockFailureStillTouches:
    """#3524: unblock_pair raising after add_link persisted must still touch both cards."""

    def test_unblock_failure_still_touches_both_endpoints(self, store, monkeypatch):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        assert store.is_blocked("a", "b")

        def _boom(from_id, to_id):
            raise RuntimeError("simulated unblock failure")

        monkeypatch.setattr(store, "unblock_pair", _boom)
        cards = FakeCardsStore(
            [FakeCard("a", content="apple", meaning="蘋果"), FakeCard("b", content="banana", meaning="香蕉")]
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "r"}')
        with pytest.raises(RuntimeError, match="simulated unblock failure"):
            create_manual_link(
                from_id="a", to_id="b", graph=store, cards_store=cards, judge=judge, notebook_id="default"
            )
        assert "a" in cards.touched and "b" in cards.touched


class TestBlockedPairSurvivesJudgeFailure:
    def test_judge_failure_keeps_pair_blocked(self, store):
        from kg.exceptions import QuotaExceededError

        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        assert store.is_blocked("a", "b")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        with pytest.raises(QuotaExceededError):
            create_manual_link(
                from_id="a",
                to_id="b",
                cards_store=cards,
                graph=store,
                judge=_RaisingJudge(),
                notebook_id="default",
            )
        assert store.is_blocked("a", "b")


class TestToggleStatusGuard:
    def test_toggle_on_deprecated_404_and_unchanged(self, store):
        from kg.exceptions import NotFoundError

        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.get_link(lk.id).status = "deprecated"
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        for fn in (unhide_graph_link, hide_graph_link):
            with pytest.raises(NotFoundError):
                fn(link_id=lk.id, graph=store, cards_store=cards)
        assert store.get_link(lk.id).status == "deprecated"
        assert cards.touched == []

    def test_delete_on_deprecated_404_unchanged_and_not_blocked(self, store):
        from kg.exceptions import NotFoundError

        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.get_link(lk.id).status = "deprecated"
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        with pytest.raises(NotFoundError):
            delete_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert store.get_link(lk.id).status == "deprecated"
        assert not store.is_blocked("a", "b")
        assert cards.touched == []

    def test_delete_on_hidden_still_works(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        delete_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert store.get_link(lk.id) is None
        assert store.is_blocked("a", "b")

    def test_hide_already_hidden_with_failing_touch_stays_hidden(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"b"})
        hide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert store.get_link(lk.id).status == "hidden"
        assert cards.touched == []

    def test_unhide_active_is_noop(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")], fail_ids={"b"})
        unhide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert store.get_link(lk.id).status == "active"
