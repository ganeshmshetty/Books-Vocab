from __future__ import annotations

import pytest

from kg.graph import GraphStore, LinkKind


@pytest.fixture()
def store(tmp_path):
    return GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )


class TestHiddenStatusBehavior:
    def test_has_link_returns_true_for_hidden(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        assert store.has_link("a", "b") is True

    def test_get_links_for_includes_hidden(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        links = store.get_links_for("a")
        assert len(links) == 1
        assert links[0].status == "hidden"

    def test_add_candidate_skips_hidden_pair(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        store.add_candidate("a", "b", 0.85)
        assert store.candidate_count() == 0

    def test_hide_nonexistent_link_raises(self, store):
        with pytest.raises(KeyError):
            store.hide_link("nonexistent")


class TestFindLinkBetween:
    def test_finds_active_link(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        found = store.find_link_between("a", "b")
        assert found is not None
        assert found.id == lk.id

    def test_finds_link_reverse_direction(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        found = store.find_link_between("b", "a")
        assert found is not None
        assert found.id == lk.id

    def test_finds_hidden_link(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        found = store.find_link_between("a", "b")
        assert found is not None
        assert found.status == "hidden"

    def test_returns_none_when_no_link(self, store):
        assert store.find_link_between("a", "b") is None

    def test_skips_deprecated_link(self, store):
        store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.deprecate_links_for("a")
        found = store.find_link_between("a", "b")
        assert found is None


from unittest.mock import MagicMock

import pytest

from kg.judge import ManualLinkJudge
from kg.vocab_graph_ops import create_manual_link


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
    def __init__(self, cards):
        self._cards = {c.id: c for c in cards}
        self.touched = []

    def get(self, card_id):
        return self._cards.get(card_id)

    def touch(self, card_id):
        self.touched.append(card_id)

    def delete(self, card_id):
        self._cards[card_id].is_deleted = True

    def archive(self, card_id):
        self._cards[card_id].is_archived = True


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


class TestCreateManualLink:
    def test_rejects_self_link_before_judge_or_graph_mutation(self, store):
        cards = FakeCardsStore([FakeCard("a")])
        judge = MagicMock()
        judge.evaluate.return_value = MagicMock(link="shares_usage", reason="r")
        from kg.exceptions import BadRequestError

        with pytest.raises(BadRequestError) as exc:
            create_manual_link(
                from_id="a",
                to_id="a",
                cards_store=cards,
                graph=store,
                judge=judge,
                notebook_id="default",
            )

        assert exc.value.status_code == 400
        assert exc.value.to_detail() == {
            "code": "BadRequestError",
            "detail": "cannot link a card to itself",
        }
        judge.evaluate.assert_not_called()
        assert store.all_links() == []

    def test_creates_link_successfully(self, store):
        cards = FakeCardsStore(
            [
                FakeCard("a", content="apple", meaning="蘋果"),
                FakeCard("b", content="banana", meaning="香蕉"),
            ]
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "都是水果"}')
        result = create_manual_link(
            from_id="a", to_id="b", cards_store=cards, graph=store, judge=judge, notebook_id="default"
        )
        assert result.kind == LinkKind.SHARES_USAGE
        assert result.confidence == 1.0
        assert result.reason == "都是水果"

    def test_touches_both_cards(self, store):
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "r"}')
        create_manual_link(from_id="a", to_id="b", cards_store=cards, graph=store, judge=judge, notebook_id="default")
        assert "a" in cards.touched and "b" in cards.touched

    def test_rejects_missing_card(self, store):
        cards = FakeCardsStore([FakeCard("a")])
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "r"}')
        from kg.exceptions import NotFoundError

        with pytest.raises(NotFoundError) as exc:
            create_manual_link(
                from_id="a", to_id="missing", cards_store=cards, graph=store, judge=judge, notebook_id="default"
            )
        assert exc.value.status_code == 404

    def test_rejects_duplicate_active_link(self, store):
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "existing")
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "r"}')
        from kg.exceptions import ConflictError

        with pytest.raises(ConflictError) as exc:
            create_manual_link(
                from_id="a", to_id="b", cards_store=cards, graph=store, judge=judge, notebook_id="default"
            )
        assert exc.value.status_code == 409

    def test_rejects_cross_notebook_card(self, store):
        # The card store is per-user (not per-notebook), so get() can resolve a
        # card from another notebook. The graph is per-notebook, so an unguarded
        # link would cross the isolation boundary. Card "b" lives in notebook
        # "other"; linking it into notebook "default" must be rejected as 404.
        cards = FakeCardsStore(
            [
                FakeCard("a", notebook_id="default"),
                FakeCard("b", notebook_id="other"),
            ]
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "r"}')
        from kg.exceptions import NotFoundError

        with pytest.raises(NotFoundError) as exc:
            create_manual_link(
                from_id="a", to_id="b", cards_store=cards, graph=store, judge=judge, notebook_id="default"
            )
        assert exc.value.status_code == 404

    def test_rejects_cross_notebook_source(self, store):
        # Symmetric guard: the source card being out-of-notebook is also rejected.
        cards = FakeCardsStore(
            [
                FakeCard("a", notebook_id="other"),
                FakeCard("b", notebook_id="default"),
            ]
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "r"}')
        from kg.exceptions import NotFoundError

        with pytest.raises(NotFoundError):
            create_manual_link(
                from_id="a", to_id="b", cards_store=cards, graph=store, judge=judge, notebook_id="default"
            )

    def test_unhides_hidden_link(self, store):
        cards = FakeCardsStore(
            [
                FakeCard("a", content="apple", meaning="蘋果"),
                FakeCard("b", content="banana", meaning="香蕉"),
            ]
        )
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "old reason")
        store.hide_link(lk.id)
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "新原因"}')
        result = create_manual_link(
            from_id="a", to_id="b", cards_store=cards, graph=store, judge=judge, notebook_id="default"
        )
        assert result.status == "active"
        assert result.kind == LinkKind.CONTRASTS_WITH  # original preserved, LLM skipped
        assert result.reason == "old reason"  # original preserved, LLM skipped
        assert result.id == lk.id  # same link, not new


class TestEndpointLivenessAfterJudge:
    # judge.evaluate is a multi-second LLM call. An endpoint deleted or archived
    # during it must not yield a persisted active link (GET /api/graph/links
    # would expose an edge to a dead card).
    @pytest.mark.parametrize("mutation", ["delete", "archive"])
    def test_endpoint_removed_during_judge_is_refused(self, store, mutation):
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        judge = MagicMock()

        def evaluate(*_args, **_kwargs):
            getattr(cards, mutation)("b")
            return MagicMock(link="shares_usage", reason="r")

        judge.evaluate.side_effect = evaluate
        from kg.exceptions import NotFoundError

        with pytest.raises(NotFoundError) as exc:
            create_manual_link(
                from_id="a", to_id="b", cards_store=cards, graph=store, judge=judge, notebook_id="default"
            )
        assert exc.value.status_code == 404
        assert [lk for lk in store.get_links_for("a") if lk.status == "active"] == []


class TestDeleteGraphLink:
    def test_hard_delete_removes_and_blocks(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        pair = store.hard_delete_link(lk.id)
        assert pair == ("a", "b")
        assert store.get_link(lk.id) is None
        assert store.is_blocked("a", "b") is True

    def test_hard_delete_nonexistent_raises(self, store):
        with pytest.raises(KeyError):
            store.hard_delete_link("nonexistent")

    def test_blocked_pair_prevents_new_candidates(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        store.add_candidate("a", "b", 0.85)
        assert store.candidate_count() == 0


class TestAddLinkPersistFailure:
    def test_failed_persist_rolls_back_in_memory_link(self, store, monkeypatch):
        def boom(*_a, **_k):
            raise OSError("disk full")

        monkeypatch.setattr(store, "_flush_links", boom)
        with pytest.raises(OSError):
            store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        assert store.find_link_between("a", "b") is None
        assert store.has_link("a", "b") is False
