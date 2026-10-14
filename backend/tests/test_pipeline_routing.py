"""Phase 4 — pipeline steps route enrich/judge/embed through the provider registry.

The critical invariant: `embed` resolves independently of the chat default,
so flipping LLM_PROVIDER_DEFAULT to a provider with no embeddings endpoint
(DeepSeek) never breaks the graph-link pipeline.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from kg.pipeline_service.steps import _step_embed_and_judge, _step_enrich

_JUDGE_JSON = json.dumps([{"word": "candidate", "link": "shares_usage", "confidence": 0.9, "reason": "ok"}])
_ENRICH_JSON = json.dumps([{"word": "evoke", "pos": "v.", "note": "n", "collocations": [], "meaning_fix": None}])


@pytest.fixture(autouse=True)
def _clean_routing_env(clean_routing_env):
    try:
        yield
    finally:
        from kg import judge_log, token_tracker

        judge_log.reset()
        token_tracker.reset()


class _Logger:
    def info(self, *a, **k):
        pass

    def warning(self, *a, **k):
        pass

    def error(self, *a, **k):
        pass


def _mock_client(content: str) -> MagicMock:
    client = MagicMock()
    resp = MagicMock()
    resp.choices = [MagicMock()]
    resp.choices[0].message.content = content
    resp.usage = None
    client.chat.completions.create.return_value = resp
    return client


def _recorder(content: str):
    """A client_factory recording the provider name of every call."""
    seen: list[str] = []

    def factory(provider):
        seen.append(provider.name)
        return _mock_client(content)

    return factory, seen


def _card(cid, content, *, pos="v.", note="note"):
    return SimpleNamespace(
        id=cid,
        content=content,
        meaning=f"meaning-{content}",
        pos=pos,
        note=note,
        enrich_attempts=0,
        difficulty=None,
        examples=[],
        is_deleted=False,
        is_archived=False,
        notebook_id="default",
        embed_text=lambda: content,
    )


# ── enrich routing ───────────────────────────────────────────────


class _EnrichCards:
    def __init__(self, cards):
        self._cards = cards

    def all(self, include_deleted=False, notebook_id=None):
        return list(self._cards)

    def batch_update_if_unchanged(self, updates):
        self.batch_update([(card_id, kwargs) for card_id, kwargs, _expected in updates])
        return []

    def batch_update(self, updates):
        return len(updates)

    def bump_enrich_attempts(self, card_ids):
        return len(card_ids)


def _run_enrich(client_factory):
    cards = _EnrichCards([_card("c1", "evoke", pos=None)])  # pos=None → needs enrich
    user = {"id": "u_enrich", "dir": Path("/tmp/u_enrich"), "config": {}}
    asyncio.run(
        _step_enrich(
            "u_enrich",
            user,
            card_store_factory=lambda d: cards,
            client_factory=client_factory,
            logger=_Logger(),
        )
    )


def test_step_enrich_routes_to_gemini_by_default():
    factory, seen = _recorder(_ENRICH_JSON)
    _run_enrich(factory)
    assert seen == ["gemini"]


def test_step_enrich_routes_to_deepseek_via_env(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER_ENRICH", "deepseek")
    factory, seen = _recorder(_ENRICH_JSON)
    _run_enrich(factory)
    assert seen == ["deepseek"]


# ── embed + judge routing ────────────────────────────────────────


class _EJCards:
    def __init__(self, cards):
        self._c = {c.id: c for c in cards}

    def all(self, include_deleted=False, notebook_id=None):
        return list(self._c.values())

    def get_batch(self, ids):
        return {i: self._c[i] for i in ids if i in self._c}

    def batch_touch(self, ids, notebook_id=None):
        pass


class _EJGraph:
    def __init__(self, pending):
        self._pending = list(pending)
        self.created: list = []

    def pop_pending_judge(self):
        p, self._pending = self._pending, []
        return p

    def ack_pending_judge(self, ids):
        pass

    def add_pending_judge(self, ids):
        self._pending.extend(ids)

    def get_links_for(self, cid):
        return []

    def has_link(self, a, b):
        return False

    def batch_add_links(self, links):
        self.created.extend(links)
        return list(links)


class _EJEmbeddings:
    def __init__(self, similar):
        self._similar = similar

    def has(self, cid):
        return True

    def find_similar(self, cid, k=12):
        return self._similar.get(cid, [])

    def add_batch(self, items):
        pass


def _run_embed_and_judge(client_factory):
    cards = _EJCards([_card("c1", "target"), _card("c2", "candidate")])
    graph = _EJGraph(pending=["c1"])
    embeddings = _EJEmbeddings({"c1": [("c2", 0.9)]})
    user = {"id": "u_ej", "dir": Path("/tmp/u_ej"), "config": {}}
    asyncio.run(
        _step_embed_and_judge(
            "u_ej",
            user,
            card_store_factory=lambda d: cards,
            graph_store_factory=lambda d, notebook_id="default": graph,
            embedding_store_factory=lambda d, llm=None, notebook_id="default": embeddings,
            client_factory=client_factory,
            logger=_Logger(),
            link_kind_enum=lambda v: v,
        )
    )


def test_embed_and_judge_routes_to_gemini_by_default():
    factory, seen = _recorder(_JUDGE_JSON)
    _run_embed_and_judge(factory)
    # embed client built first, then judge client.
    assert seen == ["gemini", "gemini"]


def test_embed_provider_independent_of_chat_default(monkeypatch):
    """Flipping the chat default to DeepSeek must NOT drag embed along —
    DeepSeek has no embeddings endpoint."""
    monkeypatch.setenv("LLM_PROVIDER_DEFAULT", "deepseek")
    factory, seen = _recorder(_JUDGE_JSON)
    _run_embed_and_judge(factory)
    assert seen == ["gemini", "deepseek"]  # embed stays gemini, judge follows default


def test_routing_sqlite_singletons_are_closed_after_each_test():
    from kg import judge_log, token_tracker

    assert judge_log._conn is None
    assert token_tracker._conn is None
