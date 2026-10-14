"""Tests for hide-link feature: blocked pairs and hidden status."""

from __future__ import annotations

import json

import pytest

from kg.graph import GraphStore, LinkKind


@pytest.fixture()
def store(tmp_path):
    return GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )


class TestBlockedPairs:
    """Task 1: _blocked_pairs persistence."""

    def test_hard_delete_removes_link(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        assert store.get_link(lk.id) is None

    def test_hard_delete_returns_pair(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        pair = store.hard_delete_link(lk.id)
        assert pair == ("a", "b")

    def test_hard_delete_adds_to_blocked(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        assert store.is_blocked("a", "b") is True

    def test_is_blocked_bidirectional(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        assert store.is_blocked("b", "a") is True

    def test_has_link_returns_true_for_blocked(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        assert store.has_link("a", "b") is True

    def test_add_candidate_skips_blocked_pair(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        store.add_candidate("a", "b", 0.85)
        assert store.candidate_count() == 0

    def test_batch_add_links_skips_blocked_pair(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        created = store.batch_add_links([("b", "a", LinkKind.SHARES_USAGE, 0.8, "again")])
        assert created == []
        assert store.find_link_between("a", "b") is None
        assert store.is_blocked("a", "b") is True

    def test_blocked_persists_across_reload(self, store, tmp_path):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        reloaded = GraphStore(
            links_path=tmp_path / "links.json",
            candidates_path=tmp_path / "candidates.json",
            blocked_path=tmp_path / "blocked.json",
        )
        assert reloaded.is_blocked("a", "b") is True

    def test_remove_blocked_pairs_for(self, store):
        lk1 = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        lk2 = store.add_link("a", "c", LinkKind.SHARES_USAGE, 0.8, "r")
        store.hard_delete_link(lk1.id)
        store.hard_delete_link(lk2.id)
        store.remove_blocked_pairs_for("a")
        assert store.is_blocked("a", "b") is False
        assert store.is_blocked("a", "c") is False

    def test_unblock_pair(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        store.unblock_pair("a", "b")
        assert store.is_blocked("a", "b") is False


class TestHiddenStatus:
    """Task 2: hidden status behavior."""

    def test_hide_link_sets_status(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        assert store.get_link(lk.id).status == "hidden"

    def test_unhide_link_sets_active(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        store.unhide_link(lk.id)
        assert store.get_link(lk.id).status == "active"

    def test_get_links_for_includes_hidden(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        links = store.get_links_for("a")
        assert len(links) == 1
        assert links[0].status == "hidden"

    def test_has_link_true_for_hidden(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        assert store.has_link("a", "b") is True

    def test_find_link_between_finds_hidden(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        found = store.find_link_between("a", "b")
        assert found is not None
        assert found.status == "hidden"

    def test_link_count_excludes_hidden(self, store):
        store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r1")
        lk2 = store.add_link("c", "d", LinkKind.SHARES_USAGE, 0.8, "r2")
        store.hide_link(lk2.id)
        assert store.link_count() == 1

    def test_add_candidate_skips_hidden_pair(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        store.add_candidate("a", "b", 0.85)
        assert store.candidate_count() == 0

    def test_hide_nonexistent_raises(self, store):
        with pytest.raises(KeyError):
            store.hide_link("nonexistent")


class TestRejectedMigration:
    """Task 2: rejected links migrate to blocked on load."""

    def test_rejected_links_become_blocked_on_load(self, tmp_path):
        # Write a links file with a rejected link directly
        links_data = [
            {
                "id": "lk1",
                "from_id": "a",
                "to_id": "b",
                "kind": "contrasts_with",
                "confidence": 0.9,
                "reason": "old",
                "created_at": "2026-01-01T00:00:00Z",
                "status": "rejected",
            },
            {
                "id": "lk2",
                "from_id": "c",
                "to_id": "d",
                "kind": "shares_usage",
                "confidence": 0.8,
                "reason": "active one",
                "created_at": "2026-01-01T00:00:00Z",
                "status": "active",
            },
        ]
        links_path = tmp_path / "links.json"
        links_path.write_text(json.dumps(links_data))

        store = GraphStore(
            links_path=links_path,
            candidates_path=tmp_path / "candidates.json",
            blocked_path=tmp_path / "blocked.json",
        )
        # rejected link should be migrated to blocked, not loaded as link
        assert store.get_link("lk1") is None
        assert store.is_blocked("a", "b") is True
        # active link should still be there
        assert store.get_link("lk2") is not None
        assert store.link_count() == 1


# --- Task 3: Service-layer tests ---

from unittest.mock import MagicMock

from kg.judge import ManualLinkJudge
from kg.vocab_graph_ops import (
    create_manual_link,
    delete_graph_link,
    hide_graph_link,
    unhide_graph_link,
)
from kg.vocab_shared import build_links_by_kind


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


class TestHideGraphLinkService:
    def test_hide_sets_status_hidden(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        hide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        found = store.find_link_between("a", "b")
        assert found.status == "hidden"

    def test_hide_touches_both_cards(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        hide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert "a" in cards.touched and "b" in cards.touched

    def test_hide_nonexistent_raises_not_found(self, store):
        cards = FakeCardsStore([FakeCard("a")])
        from kg.exceptions import NotFoundError

        with pytest.raises(NotFoundError):
            hide_graph_link(link_id="nonexistent", graph=store, cards_store=cards)

    def test_unhide_sets_status_active(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        unhide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        found = store.find_link_between("a", "b")
        assert found.status == "active"

    def test_unhide_touches_both_cards(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        unhide_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert "a" in cards.touched and "b" in cards.touched

    def test_delete_hard_deletes_and_blocks(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        delete_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert store.find_link_between("a", "b") is None
        assert store.is_blocked("a", "b") is True

    def test_delete_touches_both_cards(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards = FakeCardsStore([FakeCard("a"), FakeCard("b")])
        delete_graph_link(link_id=lk.id, graph=store, cards_store=cards)
        assert "a" in cards.touched and "b" in cards.touched


class TestCreateManualLinkHiddenBranch:
    def test_create_manual_link_unhides_hidden(self, store):
        """Hidden link exists -> unhide directly, skip LLM, preserve original kind/reason."""
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "original reason")
        store.hide_link(lk.id)
        cards = FakeCardsStore(
            [
                FakeCard("a", content="apple", meaning="蘋果"),
                FakeCard("b", content="banana", meaning="香蕉"),
            ]
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "新原因"}')
        result = create_manual_link(
            from_id="a", to_id="b", graph=store, cards_store=cards, judge=judge, notebook_id="default"
        )
        assert result.status == "active"
        assert result.id == lk.id  # same link object
        assert result.reason == "original reason"  # LLM was NOT called
        assert result.kind == LinkKind.CONTRASTS_WITH  # original kind preserved

    def test_create_manual_link_unblocks_and_creates(self, store):
        """Blocked pair -> unblock, call LLM, create new link."""
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        assert store.is_blocked("a", "b") is True
        cards = FakeCardsStore(
            [
                FakeCard("a", content="apple", meaning="蘋果"),
                FakeCard("b", content="banana", meaning="香蕉"),
            ]
        )
        judge = _make_judge('{"link": "shares_usage", "confidence": 0.9, "reason": "新原因"}')
        result = create_manual_link(
            from_id="a", to_id="b", graph=store, cards_store=cards, judge=judge, notebook_id="default"
        )
        assert result is not None
        assert store.is_blocked("a", "b") is False


class TestBuildLinksIncludesHidden:
    def test_hidden_links_have_hidden_flag(self, store):
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        cards_by_id = {"a": FakeCard("a", content="word_a"), "b": FakeCard("b", content="word_b")}
        result = build_links_by_kind(
            "a",
            graph=store,
            cards_by_id=cards_by_id,
            link_kinds=list(LinkKind),
            link_labels={LinkKind.CONTRASTS_WITH: "對比", LinkKind.SHARES_USAGE: "相關"},
        )
        all_links = [link for group in result.values() for link in group]
        assert len(all_links) == 1
        assert all_links[0].hidden is True

    def test_active_links_have_hidden_false(self, store):
        store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        cards_by_id = {"a": FakeCard("a", content="word_a"), "b": FakeCard("b", content="word_b")}
        result = build_links_by_kind(
            "a",
            graph=store,
            cards_by_id=cards_by_id,
            link_kinds=list(LinkKind),
            link_labels={LinkKind.CONTRASTS_WITH: "對比", LinkKind.SHARES_USAGE: "相關"},
        )
        all_links = [link for group in result.values() for link in group]
        assert len(all_links) == 1
        assert all_links[0].hidden is False

    def test_equal_normalized_words_are_tied_by_linked_card_id(self, store):
        link_z = store.add_link("source", "card-z", LinkKind.CONTRASTS_WITH, 0.9, "z")
        link_a = store.add_link("source", "card-a", LinkKind.CONTRASTS_WITH, 0.8, "a")

        class OrderedGraph:
            def get_links_for(self, card_id):
                assert card_id == "source"
                return [link_z, link_a]

        cards_by_id = {
            "card-z": FakeCard("card-z", content="Word"),
            "card-a": FakeCard("card-a", content="word"),
        }
        result = build_links_by_kind(
            "source",
            graph=OrderedGraph(),
            cards_by_id=cards_by_id,
            link_kinds=list(LinkKind),
            link_labels={LinkKind.CONTRASTS_WITH: "對比", LinkKind.SHARES_USAGE: "相關"},
        )

        assert [link.cardId for link in result["contrasts_with"]] == ["card-a", "card-z"]


# --- blocked pairs ---


class TestDeleteWordClearsBlockedPairs:
    def test_remove_blocked_pairs_for_card(self, store):
        lk1 = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r1")
        lk2 = store.add_link("a", "c", LinkKind.SHARES_USAGE, 0.8, "r2")
        store.hard_delete_link(lk1.id)
        store.hard_delete_link(lk2.id)
        assert store.is_blocked("a", "b") and store.is_blocked("a", "c")
        store.remove_blocked_pairs_for("a")
        assert not store.is_blocked("a", "b") and not store.is_blocked("a", "c")

    def test_remove_blocked_pairs_preserves_unrelated(self, store):
        lk1 = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r1")
        lk2 = store.add_link("c", "d", LinkKind.SHARES_USAGE, 0.8, "r2")
        store.hard_delete_link(lk1.id)
        store.hard_delete_link(lk2.id)
        store.remove_blocked_pairs_for("a")
        assert store.is_blocked("c", "d") is True


# --- Task 4: HTTP endpoint regression tests ---


class TestBilateralSyncEdges:
    """Bilateral hide/unhide visibility + blocked pair persistence across pipeline.

    Background: links are stored as directed (from_id → to_id) tuples, but
    query/visibility APIs (`get_links_for`, `find_link_between`, `has_link`,
    `is_blocked`) must be symmetric so the user perceives the graph as
    undirected.  These tests pin the bilateral contract for hide/unhide and
    confirm blocked pairs survive a fresh candidate-rebuild (the pipeline's
    write path)."""

    def test_hide_link_propagates_bidirectionally(self, store):
        """hide A→B → reverse-perspective query (B→A) also sees it as hidden."""
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)

        # from B's perspective: get_links_for("b") must include the link
        b_links = store.get_links_for("b")
        assert len(b_links) == 1
        assert b_links[0].id == lk.id
        assert b_links[0].status == "hidden"

        # find_link_between is symmetric
        forward = store.find_link_between("a", "b")
        reverse = store.find_link_between("b", "a")
        assert forward is not None and reverse is not None
        assert forward.id == reverse.id == lk.id
        assert forward.status == reverse.status == "hidden"

        # has_link is symmetric
        assert store.has_link("a", "b") is True
        assert store.has_link("b", "a") is True

    def test_unhide_after_hide_restores_both_directions(self, store):
        """hide → unhide returns the link to active when queried from either side."""
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hide_link(lk.id)
        store.unhide_link(lk.id)

        forward = store.find_link_between("a", "b")
        reverse = store.find_link_between("b", "a")
        assert forward is not None and reverse is not None
        assert forward.id == reverse.id == lk.id
        assert forward.status == "active"
        assert reverse.status == "active"

        # link_count counts active links only — must be 1
        assert store.link_count() == 1

        # And both index buckets resolve to the same single link
        assert {link.id for link in store.get_links_for("a")} == {lk.id}
        assert {link.id for link in store.get_links_for("b")} == {lk.id}

    def test_blocked_pair_persists_across_pipeline_run(self, store):
        """blocked (a,b) → pipeline-style candidate batch must not re-create the link.

        Pipeline write path: `batch_add_candidates` is the chokepoint where
        embedding-similar pairs enter the graph (later judged → linked). It
        must reject any pair whose normalized form is in `_blocked_pairs`,
        regardless of orientation."""
        lk = store.add_link("a", "b", LinkKind.CONTRASTS_WITH, 0.9, "r")
        store.hard_delete_link(lk.id)
        assert store.is_blocked("a", "b") is True

        # Simulate a pipeline pass: embeddings think (a,b) and (b,a) and an
        # unrelated (a,c) are all similar enough to enqueue as candidates.
        added = store.batch_add_candidates(
            [
                ("a", "b", 0.95),  # blocked → must be rejected
                ("b", "a", 0.95),  # blocked (reverse orientation) → must be rejected
                ("a", "c", 0.90),  # unrelated → must pass
            ]
        )

        # Only the unrelated pair was accepted as a candidate.
        assert added == 1
        assert store.candidate_count() == 1

        # blocked pair survives unchanged in either orientation
        assert store.is_blocked("a", "b") is True
        assert store.is_blocked("b", "a") is True

        # No link was reconstructed for (a, b).
        assert store.find_link_between("a", "b") is None
        assert store.find_link_between("b", "a") is None

        # A second pipeline pass keeps the invariant.
        added2 = store.batch_add_candidates([("a", "b", 0.99)])
        assert added2 == 0
        assert store.is_blocked("a", "b") is True


class TestHideUnhideEndpointHTTP:
    """Regression: _require_pro_access was deleted in #269 but re-referenced in #270."""

    def test_hide_endpoint_returns_404_not_500(self, isolated_api):
        # A non-existent link_id should return 404 (NotFoundError),
        # NOT 500 (NameError from undefined _require_pro_access).
        r = isolated_api.client.patch(
            "/api/graph/links/nonexistent-link-id/hide",
            params={"notebook_id": "default"},
            headers=isolated_api.headers,
        )
        assert r.status_code == 404, f"Expected 404, got {r.status_code}: {r.text}"

    def test_unhide_endpoint_returns_404_not_500(self, isolated_api):
        r = isolated_api.client.patch(
            "/api/graph/links/nonexistent-link-id/unhide",
            params={"notebook_id": "default"},
            headers=isolated_api.headers,
        )
        assert r.status_code == 404, f"Expected 404, got {r.status_code}: {r.text}"
