"""Phase 5 — manual link creation routes through the LLM provider registry."""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from kg.api_models import ManualLinkRequest
from kg.vocab_handlers.graph import create_manual_link_response

_JUDGE_JSON = '{"link": "shares_usage", "confidence": 0.9, "reason": "相關"}'
_USER = {"id": "u_ml", "dir": "/tmp/u_ml"}


@pytest.fixture(autouse=True)
def _clean_env(clean_routing_env):
    yield


def _mock_client(content):
    client = MagicMock()
    resp = MagicMock()
    resp.choices = [MagicMock()]
    resp.choices[0].message.content = content
    resp.usage = None
    client.chat.completions.create.return_value = resp
    return client


def _recorder(content):
    seen: list[str] = []
    clients: list = []

    def factory(provider):
        seen.append(provider.name)
        c = _mock_client(content)
        clients.append(c)
        return c

    return factory, seen, clients


def _card(cid, content):
    return SimpleNamespace(
        id=cid, content=content, meaning=f"m-{content}", is_deleted=False, is_archived=False, notebook_id="default"
    )


class _Cards:
    def __init__(self):
        self._c = {"a": _card("a", "alpha"), "b": _card("b", "beta")}

    def get(self, cid):
        return self._c.get(cid)

    def touch(self, cid):
        pass


class _Link:
    def __init__(self, kind, reason):
        self.id, self.from_id, self.to_id = "L1", "a", "b"
        self.kind, self.confidence, self.reason = kind, 1.0, reason


class _Graph:
    def find_link_between(self, a, b):
        return None

    def is_blocked(self, a, b):
        return False

    def add_link(self, fr, to, kind, confidence, reason, *, source="auto", require_live=None):
        return _Link(kind, reason)


def _run(client_factory):
    return create_manual_link_response(
        ManualLinkRequest(from_id="a", to_id="b"),
        _USER,
        card_store_factory=lambda d: _Cards(),
        graph_store_factory=lambda d, notebook_id="default": _Graph(),
        client_factory=client_factory,
        notebook_id="default",
    )


def test_manual_link_routes_to_gemini_by_default():
    factory, seen, clients = _recorder(_JUDGE_JSON)
    _run(factory)
    assert seen == ["gemini"]
    call = clients[0].chat.completions.create.call_args.kwargs
    assert call["model"] == "gemini-2.5-flash-lite"
    assert "extra_body" not in call


def test_manual_link_routes_to_deepseek_via_judge_group_env(monkeypatch):
    """LLM_PROVIDER_JUDGE covers manual link judging (call_type group JUDGE),
    so the one knob flips both auto and manual judge together."""
    monkeypatch.setenv("LLM_PROVIDER_JUDGE", "deepseek")
    factory, seen, clients = _recorder(_JUDGE_JSON)
    _run(factory)
    assert seen == ["deepseek"]
    call = clients[0].chat.completions.create.call_args.kwargs
    assert call["model"] == "deepseek-v4-flash"
    assert call["extra_body"] == {"thinking": {"type": "disabled"}}


def test_manual_link_exact_call_type_env_override(monkeypatch):
    """The exact call_type env (LLM_PROVIDER_JUDGE_MANUAL) still wins for
    operators who want manual judge on a different provider than auto."""
    monkeypatch.setenv("LLM_PROVIDER_JUDGE_MANUAL", "deepseek")
    factory, seen, _ = _recorder(_JUDGE_JSON)
    _run(factory)
    assert seen == ["deepseek"]


# ---------------------------------------------------------------------------
# E3 — GET /api/vocab cursor pagination wiring (limit param + X-Next-Cursor)
#
# Body stays response_model=list[CardResponse] (iOS parsing unchanged); the
# opaque next-page cursor rides the X-Next-Cursor response header. Default limit
# is large enough to drain a normal account in one page (no header). A malformed
# cursor token -> 400 BadRequestError.
# ---------------------------------------------------------------------------

import json
import sqlite3
import uuid

from fastapi.testclient import TestClient

import kg.api as api_mod
import kg.deps as deps_mod
from conftest import TEST_JWT_SECRET, _swap_settings, make_jwt
from kg.api import app
from kg.settings import KGSettings


@pytest.fixture()
def vocab_api(tmp_path):
    data_dir = tmp_path
    (data_dir / "users").mkdir()
    user_id = "u_" + uuid.uuid4().hex[:8]
    (data_dir / "users.json").write_text(json.dumps({user_id: {"config": {}}}))

    headers = {"Authorization": f"Bearer {make_jwt(user_id)}"}
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


def _seed_cards(api, n: int) -> None:
    from kg.cards import CardStore

    store = CardStore(api.data_dir / "users" / api.user_id / "cards.db")
    try:
        for i in range(n):
            store.add(content=f"word{i:03d}", meaning=f"m{i}", notebook_id="default")
    finally:
        store.close()


def _get_vocab(api, **params):
    return api.client.get("/api/vocab", params=params, headers=api.headers)


def test_limit_param(vocab_api):
    """?limit=2 returns exactly 2 cards and a next-page cursor header when
    more rows remain."""
    _seed_cards(vocab_api, 5)
    r = _get_vocab(vocab_api, limit=2)
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body) == 2
    assert r.headers.get("X-Next-Cursor")  # present + non-empty -> more pages


def test_cursor_follow(vocab_api):
    """Following X-Next-Cursor yields the next page with no overlap; the union
    across pages covers every card exactly once."""
    _seed_cards(vocab_api, 5)

    seen_ids: list[str] = []
    cursor = None
    pages = 0
    while True:
        params = {"limit": 2}
        if cursor is not None:
            params["cursor"] = cursor
        r = _get_vocab(vocab_api, **params)
        assert r.status_code == 200, r.text
        ids = [c["id"] for c in r.json()]
        # no overlap with anything seen so far
        assert not (set(ids) & set(seen_ids)), f"page {pages} overlaps prior pages"
        seen_ids.extend(ids)
        cursor = r.headers.get("X-Next-Cursor")
        pages += 1
        if cursor is None:
            break
        assert pages < 10  # guard against an unterminated loop

    assert len(seen_ids) == 5
    assert len(set(seen_ids)) == 5  # gap-free + dup-free


def _seed_mixed_timestamp_cards(api) -> None:
    from kg.cards import CardStore

    seed = [
        ("a", "canonical-tie", "2024-01-01 10:00:00"),
        ("b", "legacy-tie", "2024-01-01 12:00:00+02:00"),
        ("c", "legacy-late", "2024-01-01 13:00:00+02:00"),
        ("d", "canonical-latest", "2024-01-01 12:00:00"),
    ]
    db_path = api.data_dir / "users" / api.user_id / "cards.db"
    store = CardStore(db_path)
    try:
        created = [store.add(content=content, meaning=content) for _, content, _ in seed]
    finally:
        store.close()

    with sqlite3.connect(db_path) as connection:
        connection.executemany(
            "UPDATE card SET id = ?, updated_at = ? WHERE id = ?",
            [(new_id, timestamp, card.id) for (new_id, _, timestamp), card in zip(seed, created, strict=True)],
        )


def test_incremental_vocab_paging_normalizes_mixed_timestamps_to_utc(vocab_api):
    """Mixed legacy offsets keep incremental paging ordered and gap-free."""
    _seed_mixed_timestamp_cards(vocab_api)

    seen_ids: list[str] = []
    cursor = None
    pages = 0
    while True:
        params = {"since": "2023-12-31T00:00:00Z", "limit": 2}
        if cursor is not None:
            params["cursor"] = cursor
        response = _get_vocab(vocab_api, **params)

        assert response.status_code == 200, response.text
        page_ids = [card["id"] for card in response.json()]
        assert not (set(page_ids) & set(seen_ids))
        seen_ids.extend(page_ids)
        pages += 1
        next_cursor = response.headers.get("X-Next-Cursor")
        if next_cursor is None:
            break
        assert next_cursor != cursor
        cursor = next_cursor
        assert pages < 4

    assert seen_ids == ["a", "b", "c", "d"]
    assert len(set(seen_ids)) == 4


def test_last_page_no_header(vocab_api):
    """The final (drained) page carries no X-Next-Cursor header."""
    _seed_cards(vocab_api, 3)
    # limit >= total -> single drained page
    r = _get_vocab(vocab_api, limit=10)
    assert r.status_code == 200, r.text
    assert len(r.json()) == 3
    assert "X-Next-Cursor" not in r.headers


def test_default_limit(vocab_api):
    """Without an explicit limit the default page is large enough to drain a
    normal account in one shot (no cursor header)."""
    _seed_cards(vocab_api, 4)
    r = _get_vocab(vocab_api)
    assert r.status_code == 200, r.text
    assert len(r.json()) == 4
    assert "X-Next-Cursor" not in r.headers


def test_malformed_cursor_returns_400(vocab_api):
    """A cursor token that does not decode to (updated_at, id) is rejected with
    400 rather than silently restarting pagination from the top."""
    _seed_cards(vocab_api, 2)
    r = _get_vocab(vocab_api, cursor="not-a-valid-cursor")
    assert r.status_code == 400, r.text


def test_slash_word_crud_and_preferences_routes(vocab_api):
    """A slash-containing word remains one vocabulary identity in every CRUD route."""
    from kg.cards import CardStore

    word = "and/or"
    store = CardStore(vocab_api.data_dir / "users" / vocab_api.user_id / "cards.db")
    try:
        card = store.add(content=word, meaning="choice")
    finally:
        store.close()

    client = vocab_api.client
    headers = vocab_api.headers

    lookup = client.get(f"/api/vocab/{word}", headers=headers)
    assert lookup.status_code == 200, lookup.text
    assert lookup.json()["id"] == card.id

    content = client.patch(f"/api/vocab/{word}", json={"meaning": "either option"}, headers=headers)
    assert content.status_code == 200, content.text
    assert content.json()["meaning"] == "either option"

    preferences = client.patch(f"/api/vocab/{word}/preferences", json={"reader_hidden": True}, headers=headers)
    assert preferences.status_code == 200, preferences.text
    assert preferences.json()["isReaderHidden"] is True

    archive = client.patch(f"/api/vocab/{word}/archive", json={"archived": True}, headers=headers)
    assert archive.status_code == 200, archive.text
    assert archive.json() == {"word": word, "id": card.id, "archived": True}

    deleted = client.delete(f"/api/vocab/{word}", headers=headers)
    assert deleted.status_code == 200, deleted.text
    assert deleted.json() == {"deleted": word, "id": card.id}


def _staged_and_live_cards(api):
    from kg.cards import CardStore
    from kg.notebook import NotebookStore

    user_dir = api.data_dir / "users" / api.user_id
    nbs = NotebookStore(user_dir / "notebooks.db")
    staged = nbs.create(name="Staged", is_staged=True)
    cards = CardStore(user_dir / "cards.db")
    try:
        live = cards.add(content="shared", meaning="live", notebook_id="default")
        hidden = cards.add(content="shared", meaning="hidden", notebook_id=staged.id)
    finally:
        cards.close()
    return live.id, hidden.id


def test_review_push_skips_staged_notebook_cards(vocab_api):
    """#2694: PATCH /api/vocab/review must not write review state into staged notebook cards."""
    from kg.cards import CardStore

    live_id, hidden_id = _staged_and_live_cards(vocab_api)
    entry = {
        "word": "shared",
        "review_interval_hours": 24.0,
        "next_review_at": "2099-01-01T00:00:00Z",
        "last_reviewed_at": "2026-01-01T00:00:00Z",
        "review_count": 3,
        "lapse_count": 0,
        "review_streak": 1,
        "last_review_feedback": 1,
    }
    by_word = vocab_api.client.patch("/api/vocab/review", json={"entries": [entry]}, headers=vocab_api.headers)
    by_id = vocab_api.client.patch(
        "/api/vocab/review", json={"entries": [{**entry, "card_id": hidden_id}]}, headers=vocab_api.headers
    )
    assert by_word.json() == {"updated": 1, "skipped": 0}, by_word.text
    assert by_id.json() == {"updated": 0, "skipped": 1}, by_id.text

    store = CardStore(vocab_api.data_dir / "users" / vocab_api.user_id / "cards.db")
    try:
        assert store.get(live_id).review_count == 3
        assert store.get(hidden_id).review_count == 0
    finally:
        store.close()


def test_add_link_replay_survives_archived_source_and_changed_body_conflicts(vocab_api, tmp_path, monkeypatch):
    """#2686: a same-key replay returns the stored operation even after the source is archived."""
    import kg.routers.vocab as vocab_router
    import kg.vocab_add_link_operation as operations
    from kg.cards import CardStore

    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
    operations.reset()
    monkeypatch.setattr(vocab_router, "run_add_link_operation", lambda *a, **k: None)
    store = CardStore(vocab_api.data_dir / "users" / vocab_api.user_id / "cards.db")
    try:
        source = store.add(content="source", meaning="src", notebook_id="default")
        body = {"from_id": source.id, "target_word": "target", "source_lang": "en", "target_lang": "zh-Hant"}
        headers = {**vocab_api.headers, "Idempotency-Key": "k-1"}
        url = "/api/graph/links/ensure-target"

        first = vocab_api.client.post(url, json=body, headers=headers)
        assert first.status_code == 202, first.text
        store.update(source.id, is_archived=True)

        replay = vocab_api.client.post(url, json=body, headers=headers)
        assert replay.status_code == 202, replay.text
        assert replay.json()["operationId"] == first.json()["operationId"]

        changed = vocab_api.client.post(url, json={**body, "target_word": "other"}, headers=headers)
        assert changed.status_code == 409, changed.text

        fresh = vocab_api.client.post(url, json=body, headers={**vocab_api.headers, "Idempotency-Key": "k-2"})
        assert fresh.status_code == 404, fresh.text
    finally:
        store.close()
        operations.reset()
