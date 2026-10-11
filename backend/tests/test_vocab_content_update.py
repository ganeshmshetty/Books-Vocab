"""Integration tests for PATCH /api/vocab/{word} content-update.

Distinct from PATCH /api/vocab/{word}/archive (archive state toggle) and
DELETE /api/vocab/{word} (soft delete). This route mutates editorial content:
meaning / note (with `explanation` accepted as a write-through alias for note).
"""

from __future__ import annotations

import json
import re
import uuid
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

import kg.api as api_mod
import kg.deps as deps_mod
from conftest import TEST_JWT_SECRET, _swap_settings, make_jwt
from kg.api import app
from kg.settings import KGSettings


@pytest.fixture()
def isolated_api(tmp_path):
    data_dir = tmp_path
    (data_dir / "users").mkdir()
    user_id = "u_" + uuid.uuid4().hex[:8]
    (data_dir / "users.json").write_text(json.dumps({user_id: {"config": {}}}))

    token = make_jwt(user_id)
    headers = {"Authorization": f"Bearer {token}"}

    original_settings = app.state.kg_settings
    original_load = app.state.load_users
    original_save = app.state.save_users

    _swap_settings(KGSettings(data_dir=data_dir, jwt_secret=TEST_JWT_SECRET))
    try:
        api_mod._USER_LOCKS.clear()
        deps_mod._USER_LOCKS_MUTEX = None
        with TestClient(app, raise_server_exceptions=False) as client:
            yield SimpleNamespace(
                client=client,
                user_id=user_id,
                headers=headers,
                data_dir=data_dir,
            )
    finally:
        app.state.kg_settings = original_settings
        app.state.load_users = original_load
        app.state.save_users = original_save


def _seed_word(api, word="apple", translation="蘋果"):
    # Seed directly via CardStore so we don't trigger the real embedding call
    # the HTTP add path makes (no API key under test). Mirrors test_vocab_service.
    from kg.cards import CardStore

    store = CardStore(api.data_dir / "users" / api.user_id / "cards.db")
    try:
        store.add(content=word, meaning=translation, notebook_id="default")
    finally:
        store.close()
    return word


def test_update_meaning(isolated_api):
    word = _seed_word(isolated_api)
    r = isolated_api.client.patch(f"/api/vocab/{word}", json={"meaning": "a round fruit"}, headers=isolated_api.headers)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["content"] == word
    assert body["meaning"] == "a round fruit"


def test_update_note(isolated_api):
    word = _seed_word(isolated_api)
    r = isolated_api.client.patch(f"/api/vocab/{word}", json={"note": "from Latin malum"}, headers=isolated_api.headers)
    assert r.status_code == 200, r.text
    assert r.json()["note"] == "from Latin malum"


def test_explanation_aliases_note(isolated_api):
    """`explanation` is accepted as a write-through alias for the `note` column."""
    word = _seed_word(isolated_api)
    r = isolated_api.client.patch(
        f"/api/vocab/{word}", json={"explanation": "teacher commentary"}, headers=isolated_api.headers
    )
    assert r.status_code == 200, r.text
    assert r.json()["note"] == "teacher commentary"


def test_explicit_note_wins_over_explanation(isolated_api):
    word = _seed_word(isolated_api)
    r = isolated_api.client.patch(
        f"/api/vocab/{word}",
        json={"note": "real note", "explanation": "ignored"},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    assert r.json()["note"] == "real note"


def test_empty_explanation_clears_note(isolated_api):
    """Explicit "" clears the note; iOS sends it for a cleared note (#2550)."""
    word = _seed_word(isolated_api)
    isolated_api.client.patch(f"/api/vocab/{word}", json={"note": "to clear"}, headers=isolated_api.headers)
    r = isolated_api.client.patch(f"/api/vocab/{word}", json={"explanation": ""}, headers=isolated_api.headers)
    assert r.status_code == 200, r.text
    assert not r.json()["note"]


def test_null_explanation_is_no_change(isolated_api):
    """Explicit null is treated like an omitted key, so iOS must send "" to clear (#2550)."""
    word = _seed_word(isolated_api)
    isolated_api.client.patch(f"/api/vocab/{word}", json={"note": "keep me"}, headers=isolated_api.headers)
    r = isolated_api.client.patch(
        f"/api/vocab/{word}", json={"meaning": "a fruit", "explanation": None}, headers=isolated_api.headers
    )
    assert r.status_code == 200, r.text
    assert r.json()["note"] == "keep me"


def test_omitted_explanation_keeps_note(isolated_api):
    word = _seed_word(isolated_api)
    isolated_api.client.patch(f"/api/vocab/{word}", json={"note": "keep me"}, headers=isolated_api.headers)
    r = isolated_api.client.patch(f"/api/vocab/{word}", json={"meaning": "a fruit"}, headers=isolated_api.headers)
    assert r.status_code == 200, r.text
    assert r.json()["note"] == "keep me"


def test_update_multiple_fields(isolated_api):
    word = _seed_word(isolated_api)
    r = isolated_api.client.patch(
        f"/api/vocab/{word}",
        json={"meaning": "fruit", "note": "n."},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["meaning"] == "fruit"
    assert body["note"] == "n."


def test_empty_body_returns_400(isolated_api):
    word = _seed_word(isolated_api)
    r = isolated_api.client.patch(f"/api/vocab/{word}", json={}, headers=isolated_api.headers)
    assert r.status_code == 400, r.text


def test_update_nonexistent_word_returns_404(isolated_api):
    r = isolated_api.client.patch("/api/vocab/ghostword", json={"meaning": "x"}, headers=isolated_api.headers)
    assert r.status_code == 404, r.text


def test_update_requires_auth(isolated_api):
    r = isolated_api.client.patch("/api/vocab/apple", json={"meaning": "x"})
    assert r.status_code == 401, r.text


def test_update_persists_in_lookup(isolated_api):
    word = _seed_word(isolated_api)
    isolated_api.client.patch(f"/api/vocab/{word}", json={"meaning": "persisted"}, headers=isolated_api.headers)
    r = isolated_api.client.get(f"/api/vocab/{word}", headers=isolated_api.headers)
    assert r.status_code == 200, r.text
    assert r.json()["meaning"] == "persisted"


# --------------------------------------------------------------------- #
# #2254: word-addressed edits for words that equal a static PATCH segment
# --------------------------------------------------------------------- #
# `/api/vocab/review`, `/api/vocab/review-events` and `/api/vocab/batch-archive`
# are registered before `/api/vocab/{word}`, so a saved card whose content is one
# of those segments used to hit the static handler and always get a 422.


def _stored_card(api, word):
    from kg.cards import CardStore

    store = CardStore(api.data_dir / "users" / api.user_id / "cards.db")
    try:
        return store.find_by_content(word, notebook_id="default")
    finally:
        store.close()


def _review_entry(word, **overrides):
    entry = {
        "word": word,
        "review_interval_hours": 24.0,
        "next_review_at": "2026-06-02T10:00:00+00:00",
        "last_reviewed_at": "2026-06-01T10:00:00+00:00",
        "review_count": 1,
        "lapse_count": 0,
        "review_streak": 1,
        "last_review_feedback": 1,
    }
    entry.update(overrides)
    return entry


@pytest.mark.parametrize("word", ["review", "review-events", "batch-archive"])
def test_content_edit_reaches_word_equal_to_static_segment(isolated_api, word):
    _seed_word(isolated_api, word=word, translation="舊")
    r = isolated_api.client.patch(
        f"/api/vocab/{word}",
        params={"notebook_id": "default"},
        json={"meaning": "new meaning", "explanation": "teacher note"},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["content"] == word
    assert body["meaning"] == "new meaning"
    assert body["note"] == "teacher note"
    # GET /api/vocab/{word} is not used: GET /api/vocab/review-events is a
    # separate static route, so read the card store directly.
    stored = _stored_card(isolated_api, word)
    assert stored is not None
    assert (stored.meaning, stored.note) == ("new meaning", "teacher note")


@pytest.mark.parametrize(
    "extra",
    [{}, {"meaning": "ignored"}],
    ids=["entries-only", "entries-wins-over-content-keys"],
)
def test_static_review_push_still_applies_entries(isolated_api, extra):
    word = _seed_word(isolated_api)
    r = isolated_api.client.patch(
        "/api/vocab/review",
        json={"entries": [_review_entry(word)], **extra},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert set(body) == {"updated", "skipped"}
    assert body["updated"] == 1
    stored = _stored_card(isolated_api, word)
    assert stored.review_count == 1
    assert stored.meaning == "蘋果"


@pytest.mark.parametrize(
    ("payload", "loc"),
    [
        ({}, ["body", "entries"]),
        ({"entries": [_review_entry("apple", review_count=-1)]}, ["body", "entries", 0, "review_count"]),
    ],
    ids=["empty-body", "invalid-entry"],
)
def test_static_review_push_malformed_body_still_422(isolated_api, payload, loc):
    _seed_word(isolated_api)
    r = isolated_api.client.patch("/api/vocab/review", json=payload, headers=isolated_api.headers)
    assert r.status_code == 422, r.text
    assert [error["loc"] for error in r.json()["detail"]] == [loc]


def test_static_batch_archive_still_archives(isolated_api):
    word = _seed_word(isolated_api)
    r = isolated_api.client.patch(
        "/api/vocab/batch-archive",
        params={"notebook_id": "default"},
        json={"words": [word]},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["updated_words"] == [word]
    assert body["not_found"] == []


# Guard: every static PATCH route under /api/vocab/<segment> shadows
# PATCH /api/vocab/{word}, so it must forward a content edit for a card whose
# word equals the segment. Enumerated from the router so a new static PATCH
# route fails here until it forwards (or the set below is consciously updated).
# Out of scope by design: POST /api/vocab/batch-delete is static but not PATCH;
# GET /api/vocab/review-events (pull) still captures a card named
# "review-events" because a GET has no body to dispatch on (known gap, #2261).
_STATIC_PATCH_SEGMENT = re.compile(r"^/api/vocab/([^/{}]+)$")


def _static_patch_segments():
    from kg.routers.vocab import router

    return sorted(
        {
            m.group(1)
            for route in router.routes
            if "PATCH" in (getattr(route, "methods", None) or ()) and (m := _STATIC_PATCH_SEGMENT.match(route.path))
        }
    )


def test_static_patch_segments_are_exactly_the_known_set():
    assert _static_patch_segments() == ["batch-archive", "review", "review-events"]


@pytest.mark.parametrize("segment", _static_patch_segments())
def test_every_static_patch_segment_forwards_content_edit(isolated_api, segment):
    _seed_word(isolated_api, word=segment, translation="舊")
    r = isolated_api.client.patch(
        f"/api/vocab/{segment}",
        params={"notebook_id": "default"},
        json={"meaning": "new meaning", "explanation": "teacher note"},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    assert r.json()["content"] == segment
    stored = _stored_card(isolated_api, segment)
    assert stored is not None
    assert (stored.meaning, stored.note) == ("new meaning", "teacher note")


def _seed_embedding(api, word, monkeypatch):
    """Give the seeded card a stored vector (the embed call itself is faked)."""
    import numpy as np

    from kg.deps import _embedding_store
    from kg.embeddings import EMBEDDING_DIM, EmbeddingStore

    monkeypatch.setattr(
        EmbeddingStore,
        "_embed",
        lambda self, texts, *, llm=None: np.ones((len(texts), EMBEDDING_DIM), dtype=np.float32),
    )
    card = _stored_card(api, word)
    user_dir = api.data_dir / "users" / api.user_id
    store = _embedding_store(user_dir, llm=None)
    store.add(card.id, card.embed_text())
    assert store.has(card.id)
    return card.id, store


def test_meaning_edit_evicts_stale_embedding(isolated_api, monkeypatch):
    from kg.service_factories import clear_store_cache

    clear_store_cache()
    try:
        word = _seed_word(isolated_api)
        card_id, store = _seed_embedding(isolated_api, word, monkeypatch)
        r = isolated_api.client.patch(f"/api/vocab/{word}", json={"meaning": "new"}, headers=isolated_api.headers)
        assert r.status_code == 200, r.text
        assert not store.has(card_id)
    finally:
        clear_store_cache()


def test_note_only_edit_keeps_embedding(isolated_api, monkeypatch):
    from kg.service_factories import clear_store_cache

    clear_store_cache()
    try:
        word = _seed_word(isolated_api)
        card_id, store = _seed_embedding(isolated_api, word, monkeypatch)
        r = isolated_api.client.patch(f"/api/vocab/{word}", json={"note": "n"}, headers=isolated_api.headers)
        assert r.status_code == 200, r.text
        assert store.has(card_id)
    finally:
        clear_store_cache()


def test_meaning_edit_survives_embedding_eviction_failure(isolated_api, monkeypatch):
    import kg.routers.vocab as vocab_router

    word = _seed_word(isolated_api)

    def boom(*_a, **_k):
        raise OSError("embedding store unavailable")

    monkeypatch.setattr(vocab_router, "_embedding_store", boom)
    r = isolated_api.client.patch(f"/api/vocab/{word}", json={"meaning": "new"}, headers=isolated_api.headers)
    assert r.status_code == 200, r.text
    assert r.json()["meaning"] == "new"


def test_meaning_edit_queues_card_for_judging(isolated_api, monkeypatch):
    from kg.deps import _graph_store
    from kg.service_factories import clear_store_cache

    clear_store_cache()
    try:
        word = _seed_word(isolated_api)
        card_id, _store = _seed_embedding(isolated_api, word, monkeypatch)
        r = isolated_api.client.patch(f"/api/vocab/{word}", json={"meaning": "new"}, headers=isolated_api.headers)
        assert r.status_code == 200, r.text
        user_dir = isolated_api.data_dir / "users" / isolated_api.user_id
        assert card_id in _graph_store(user_dir, notebook_id="default").pop_pending_judge()
    finally:
        clear_store_cache()


def test_unchanged_meaning_edit_neither_evicts_nor_queues(isolated_api, monkeypatch):
    from kg.deps import _graph_store
    from kg.service_factories import clear_store_cache

    clear_store_cache()
    try:
        word = _seed_word(isolated_api)
        card_id, store = _seed_embedding(isolated_api, word, monkeypatch)
        current = _stored_card(isolated_api, word).meaning
        r = isolated_api.client.patch(f"/api/vocab/{word}", json={"meaning": current}, headers=isolated_api.headers)
        assert r.status_code == 200, r.text
        assert store.has(card_id)
        user_dir = isolated_api.data_dir / "users" / isolated_api.user_id
        assert card_id not in _graph_store(user_dir, notebook_id="default").pop_pending_judge()
    finally:
        clear_store_cache()
