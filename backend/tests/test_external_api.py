from __future__ import annotations

import asyncio
import collections
import json
import math
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest
from fastapi import HTTPException, Response
from fastapi.testclient import TestClient
from pydantic import ValidationError

import kg.routers.external_api as external_router
from conftest import TEST_JWT_SECRET, _swap_settings, make_jwt
from kg.api import app
from kg.api_models.external_api import ExternalCardReviewRequest
from kg.external_api_keys import list_api_keys
from kg.external_api_rate_limit import (
    ExternalRateLimiter,
    auth_failure_limiter,
    enrich_limiter,
    read_limiter,
    user_enrich_limiter,
    user_write_limiter,
    write_limiter,
)
from kg.settings import KGSettings


@pytest.fixture()
def external_api(tmp_path):
    user_id = "u_" + uuid.uuid4().hex[:8]
    users_file = tmp_path / "users.json"
    users_file.write_text(
        json.dumps(
            {
                user_id: {
                    "config": {},
                    "subscription": {
                        "is_active": True,
                        "status": "active",
                        "will_renew": True,
                        "expires_at": None,
                    },
                }
            }
        )
    )
    (tmp_path / "users").mkdir()

    original_settings = app.state.kg_settings
    original_load = app.state.load_users
    original_save = app.state.save_users
    _swap_settings(
        KGSettings(
            data_dir=tmp_path,
            jwt_secret=TEST_JWT_SECRET,
            app_store_allow_unsigned_sync=True,
            app_store_allow_unsigned_notifications=True,
        )
    )
    external_router._OPERATIONS.clear()
    for limiter in (
        read_limiter,
        write_limiter,
        enrich_limiter,
        user_write_limiter,
        user_enrich_limiter,
        auth_failure_limiter,
    ):
        limiter.reset()

    client = TestClient(app, raise_server_exceptions=False)
    jwt_headers = {"Authorization": f"Bearer {make_jwt(user_id)}"}
    try:
        yield SimpleNamespace(
            client=client,
            user_id=user_id,
            jwt_headers=jwt_headers,
            users_file=users_file,
            data_dir=tmp_path,
        )
    finally:
        app.state.kg_settings = original_settings
        app.state.load_users = original_load
        app.state.save_users = original_save


def _create_key(ctx) -> str:
    response = ctx.client.post(
        "/api/v1/api-keys",
        json={"label": "reader automation"},
        headers=ctx.jwt_headers,
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["apiKey"].startswith("kg_")
    return body["apiKey"]


def test_external_api_requires_pro_for_key_creation(external_api):
    users = json.loads(external_api.users_file.read_text())
    free_id = "free_" + uuid.uuid4().hex[:8]
    users[free_id] = {"config": {}}
    external_api.users_file.write_text(json.dumps(users))
    app.state.user_store.invalidate()

    response = external_api.client.post(
        "/api/v1/api-keys",
        json={"label": "free"},
        headers={"Authorization": f"Bearer {make_jwt(free_id)}"},
    )

    assert response.status_code == 403
    assert "Pro" in response.json()["detail"]


def test_external_api_key_is_listed_without_secret_and_can_be_revoked(external_api):
    api_key = _create_key(external_api)
    listed = external_api.client.get("/api/v1/api-keys", headers=external_api.jwt_headers)
    assert listed.status_code == 200
    assert len(listed.json()) == 1
    assert "apiKey" not in listed.json()[0]
    key_id = listed.json()[0]["keyId"]

    revoked = external_api.client.delete(
        f"/api/v1/api-keys/{key_id}",
        headers=external_api.jwt_headers,
    )
    assert revoked.status_code == 200
    assert revoked.json()["revokedAt"]
    rejected = external_api.client.get(
        "/api/v1/cards",
        headers={"X-KG-API-Key": api_key},
    )
    assert rejected.status_code == 401


def test_external_api_key_listing_orders_mixed_offsets_by_utc_and_key_id():
    user_id = "user-1"
    key_a = "a" * 32
    key_b = "b" * 32
    key_c = "c" * 32
    key_d = "d" * 32
    users = {
        user_id: {"config": {}},
        "other-user": {"config": {}},
        "_external_api_keys": {
            key_d: {
                "user_id": user_id,
                "label": "revoked",
                "created_at": "2026-08-29T00:30:00+00:00",
                "revoked_at": "2026-08-29T02:00:00+08:00",
            },
            key_a: {
                "user_id": user_id,
                "label": "tie-a",
                "created_at": "2026-08-29T09:00:00+08:00",
                "revoked_at": None,
            },
            key_c: {
                "user_id": user_id,
                "label": "tie-c",
                "created_at": "2026-08-29T01:00:00Z",
                "revoked_at": None,
            },
            key_b: {
                "user_id": user_id,
                "label": "newest",
                "created_at": "2026-08-29T00:30:00-04:00",
                "revoked_at": None,
            },
            "e" * 32: {
                "user_id": "other-user",
                "label": "filtered",
                "created_at": "2026-08-30T00:00:00Z",
                "revoked_at": None,
            },
        },
    }

    records = list_api_keys(user_id, load_users=lambda: users)

    assert [record["keyId"] for record in records] == [key_b, key_c, key_a, key_d]
    assert [record["label"] for record in records] == ["newest", "tie-c", "tie-a", "revoked"]
    assert records[-1]["createdAt"] == "2026-08-29T00:30:00+00:00"
    assert records[-1]["revokedAt"] == "2026-08-29T02:00:00+08:00"


def test_external_card_ingest_is_idempotent_and_supports_card_operations(external_api):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    payload = {
        "content": "  Invoked! ",
        "context": "The lawyer invoked the law.",
        "clientId": "local-queue-1",
    }

    first = external_api.client.post("/api/v1/cards", json=payload, headers=headers)
    assert first.status_code == 201, first.text
    first_body = first.json()
    assert first_body["created"] is True
    assert first_body["card"]["content"] == "invoked"
    assert first_body["card"]["examples"] == ["The lawyer invoked the law."]
    card_id = first_body["card"]["id"]

    retry = external_api.client.post("/api/v1/cards", json=payload, headers=headers)
    assert retry.status_code == 201, retry.text
    assert retry.json()["created"] is False
    assert retry.json()["card"]["id"] == card_id

    fetched = external_api.client.get(f"/api/v1/cards/{card_id}", headers=headers)
    assert fetched.status_code == 200

    updated = external_api.client.patch(
        f"/api/v1/cards/{card_id}",
        json={"meaning": "引用；援引", "pos": "v", "note": "plain text note"},
        headers=headers,
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["meaning"] == "引用；援引"
    assert updated.json()["pos"] == "v."

    archived = external_api.client.post(
        f"/api/v1/cards/{card_id}/archive",
        json={"archived": True},
        headers=headers,
    )
    assert archived.status_code == 200, archived.text
    assert archived.json()["isArchived"] is True

    deleted = external_api.client.delete(f"/api/v1/cards/{card_id}", headers=headers)
    assert deleted.status_code == 200, deleted.text
    assert deleted.json() == {"cardId": card_id, "deleted": True}


def test_external_card_responses_project_per_card_preferences(external_api):
    headers = {"X-KG-API-Key": _create_key(external_api)}
    created = external_api.client.post(
        "/api/v1/cards", json={"content": "ephemeral", "clientId": "pref-1"}, headers=headers
    )
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]

    prefs = external_api.client.patch(
        "/api/vocab/ephemeral/preferences",
        json={"reader_hidden": True, "review_excluded": True},
        headers=external_api.jwt_headers,
    )
    assert prefs.status_code == 200, prefs.text

    fetched = external_api.client.get(f"/api/v1/cards/{card_id}", headers=headers)
    assert fetched.status_code == 200, fetched.text
    assert fetched.json()["isReaderHidden"] is True
    assert fetched.json()["isReviewExcluded"] is True


@pytest.mark.parametrize("meaning", [" ", "\t", "\n"])
def test_external_card_update_rejects_blank_meaning(external_api, meaning):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    created = external_api.client.post(
        "/api/v1/cards",
        json={"content": "durable", "meaning": "lasting"},
        headers=headers,
    )
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]

    rejected = external_api.client.patch(
        f"/api/v1/cards/{card_id}",
        json={"meaning": meaning},
        headers=headers,
    )

    assert rejected.status_code == 422, rejected.text
    fetched = external_api.client.get(f"/api/v1/cards/{card_id}", headers=headers)
    assert fetched.status_code == 200, fetched.text
    assert fetched.json()["meaning"] == "lasting"


def test_external_card_concurrent_duplicate_requests_are_idempotent(external_api, monkeypatch):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    store = external_router._card_store(external_api.data_dir / "users" / external_api.user_id)
    original_find = type(store).find_by_content
    find_barrier = threading.Barrier(2)
    find_calls_lock = threading.Lock()
    find_calls = 0
    request_barrier = threading.Barrier(2)

    def synchronize_initial_lookup(self, *args, **kwargs):
        nonlocal find_calls
        result = original_find(self, *args, **kwargs)
        with find_calls_lock:
            find_calls += 1
            synchronize = find_calls <= 2
        if synchronize:
            find_barrier.wait(timeout=5)
        return result

    monkeypatch.setattr(type(store), "find_by_content", synchronize_initial_lookup)
    payload = {
        "content": "concurrent single card",
        "meaning": "created exactly once",
        "clientId": "concurrent-single-client",
    }

    def post_card():
        request_barrier.wait(timeout=5)
        return external_api.client.post("/api/v1/cards", json=payload, headers=headers)

    with ThreadPoolExecutor(max_workers=2) as executor:
        responses = list(executor.map(lambda _: post_card(), range(2)))

    assert sorted(response.status_code for response in responses) == [201, 201]
    bodies = [response.json() for response in responses]
    assert sorted(body["created"] for body in bodies) == [False, True]
    assert len({body["card"]["id"] for body in bodies}) == 1

    listed = external_api.client.get("/api/v1/cards", headers=headers)
    assert listed.status_code == 200, listed.text
    assert [item["content"] for item in listed.json()["items"]] == ["concurrent single card"]


def test_external_card_batch_rolls_back_when_later_entry_is_invalid(external_api):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}

    response = external_api.client.post(
        "/api/v1/cards/batch",
        json={
            "items": [
                {
                    "content": "batch atomic survivor",
                    "meaning": "must be rolled back",
                    "clientId": "valid-first",
                },
                {
                    "content": "...",
                    "meaning": "invalid after content cleanup",
                    "clientId": "invalid-second",
                },
            ]
        },
        headers=headers,
    )

    assert response.status_code == 422, response.text
    listed = external_api.client.get("/api/v1/cards", headers=headers)
    assert listed.status_code == 200, listed.text
    assert listed.json()["items"] == []


def test_external_card_batch_rolls_back_when_later_write_fails(external_api, monkeypatch):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    store = external_router._card_store(external_api.data_dir / "users" / external_api.user_id)
    original_add = type(store).add
    add_calls = 0

    def fail_second_add(self, *args, **kwargs):
        nonlocal add_calls
        add_calls += 1
        if add_calls == 2:
            raise OSError("simulated second card write failure")
        return original_add(self, *args, **kwargs)

    monkeypatch.setattr(type(store), "add", fail_second_add)

    response = external_api.client.post(
        "/api/v1/cards/batch",
        json={
            "items": [
                {"content": "batch write first", "clientId": "write-first"},
                {"content": "batch write second", "clientId": "write-second"},
            ]
        },
        headers=headers,
    )

    assert response.status_code == 500, response.text
    listed = external_api.client.get("/api/v1/cards", headers=headers)
    assert listed.status_code == 200, listed.text
    assert listed.json()["items"] == []


def test_external_card_batch_preserves_success_and_duplicate_semantics(external_api):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    existing = external_api.client.post(
        "/api/v1/cards",
        json={"content": "batch duplicate", "meaning": "existing"},
        headers=headers,
    )
    assert existing.status_code == 201, existing.text

    response = external_api.client.post(
        "/api/v1/cards/batch",
        json={
            "items": [
                {
                    "content": "Batch duplicate!",
                    "meaning": "ignored duplicate payload",
                    "clientId": "duplicate-client",
                },
                {
                    "content": "batch newly created",
                    "meaning": "new card",
                    "clientId": "new-client",
                },
                {
                    "content": "Batch newly created!",
                    "meaning": "same-batch duplicate payload",
                    "clientId": "same-batch-duplicate-client",
                },
            ]
        },
        headers=headers,
    )

    assert response.status_code == 201, response.text
    body = response.json()
    assert body["created"] == 1
    assert body["duplicates"] == 2
    assert [item["clientId"] for item in body["items"]] == [
        "duplicate-client",
        "new-client",
        "same-batch-duplicate-client",
    ]
    assert [item["created"] for item in body["items"]] == [False, True, False]
    assert body["items"][0]["card"]["id"] == existing.json()["card"]["id"]
    assert body["items"][1]["card"]["content"] == "batch newly created"
    assert body["items"][2]["card"]["id"] == body["items"][1]["card"]["id"]


def test_external_card_batch_concurrent_duplicate_requests_are_idempotent(external_api, monkeypatch):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    store = external_router._card_store(external_api.data_dir / "users" / external_api.user_id)
    original_add = type(store).add
    add_barrier = threading.Barrier(2)
    add_calls_lock = threading.Lock()
    add_calls = 0
    request_barrier = threading.Barrier(2)

    def synchronize_duplicate_add(self, *args, **kwargs):
        nonlocal add_calls
        with add_calls_lock:
            add_calls += 1
            synchronize = add_calls <= 2
        if synchronize:
            add_barrier.wait(timeout=5)
        return original_add(self, *args, **kwargs)

    monkeypatch.setattr(type(store), "add", synchronize_duplicate_add)
    payload = {
        "items": [
            {
                "content": "concurrent batch duplicate",
                "meaning": "created exactly once",
                "clientId": "concurrent-client",
            }
        ]
    }

    def post_batch():
        request_barrier.wait(timeout=5)
        return external_api.client.post("/api/v1/cards/batch", json=payload, headers=headers)

    with ThreadPoolExecutor(max_workers=2) as executor:
        responses = list(executor.map(lambda _: post_batch(), range(2)))

    assert sorted(response.status_code for response in responses) == [201, 201]
    bodies = [response.json() for response in responses]
    assert sorted(body["created"] for body in bodies) == [0, 1]
    assert sorted(body["duplicates"] for body in bodies) == [0, 1]
    assert sorted(body["items"][0]["created"] for body in bodies) == [False, True]
    assert len({body["items"][0]["card"]["id"] for body in bodies}) == 1

    listed = external_api.client.get("/api/v1/cards", headers=headers)
    assert listed.status_code == 200, listed.text
    assert [item["content"] for item in listed.json()["items"]] == ["concurrent batch duplicate"]


def _review_payload(interval):
    return {
        "reviewIntervalHours": interval,
        "nextReviewAt": "2026-01-02T00:00:00Z",
        "lastReviewedAt": "2026-01-01T00:00:00Z",
        "reviewCount": 1,
        "lapseCount": 0,
        "reviewStreak": 1,
        "lastReviewFeedback": 1,
    }


@pytest.mark.parametrize("value", [math.inf, math.nan])
def test_external_card_review_request_rejects_non_finite_interval(value):
    with pytest.raises(ValidationError):
        ExternalCardReviewRequest(**_review_payload(value))


@pytest.mark.parametrize("raw_interval", ["Infinity", "NaN"])
def test_external_card_review_route_rejects_non_finite_interval_without_write(external_api, raw_interval):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    created = external_api.client.post(
        "/api/v1/cards",
        json={"content": "finite review", "meaning": "有限複習"},
        headers=headers,
    )
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]

    payload = json.dumps(_review_payload(0)).replace("0", raw_interval, 1)
    response = external_api.client.post(
        f"/api/v1/cards/{card_id}/review",
        content=payload,
        headers={**headers, "Content-Type": "application/json"},
    )

    assert response.status_code == 422, response.text
    fetched = external_api.client.get(f"/api/v1/cards/{card_id}", headers=headers)
    assert fetched.status_code == 200, fetched.text
    assert fetched.json()["reviewIntervalHours"] == 12.0


def test_external_card_review_route_preserves_finite_interval(external_api):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    created = external_api.client.post(
        "/api/v1/cards",
        json={"content": "finite review accepted", "meaning": "有限複習通過"},
        headers=headers,
    )
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]

    response = external_api.client.post(
        f"/api/v1/cards/{card_id}/review",
        json=_review_payload(24.5),
        headers=headers,
    )

    assert response.status_code == 200, response.text
    assert response.json()["reviewIntervalHours"] == 24.5


@pytest.mark.parametrize("field", ["reviewCount", "lapseCount", "reviewStreak"])
def test_external_card_review_rejects_boolean_counters_without_write(external_api, field):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    created = external_api.client.post(
        "/api/v1/cards",
        json={"content": "boolean review counter", "meaning": "布林計數器"},
        headers=headers,
    )
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]

    payload = _review_payload(24.5)
    payload[field] = True
    response = external_api.client.post(
        f"/api/v1/cards/{card_id}/review",
        json=payload,
        headers=headers,
    )

    assert response.status_code == 422, response.text
    fetched = external_api.client.get(f"/api/v1/cards/{card_id}", headers=headers)
    assert fetched.status_code == 200, fetched.text
    assert fetched.json()["reviewIntervalHours"] == 12.0
    assert fetched.json()["reviewCount"] == 0
    assert fetched.json()["lapseCount"] == 0
    assert fetched.json()["reviewStreak"] == 0


@pytest.mark.parametrize("field", ["nextReviewAt", "lastReviewedAt"])
def test_external_card_review_rejects_invalid_timestamps_without_write(external_api, field):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    created = external_api.client.post(
        "/api/v1/cards",
        json={"content": "invalid review timestamp", "meaning": "無效時間"},
        headers=headers,
    )
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]

    payload = _review_payload(24.5)
    payload[field] = "not-a-timestamp"
    response = external_api.client.post(
        f"/api/v1/cards/{card_id}/review",
        json=payload,
        headers=headers,
    )

    assert response.status_code == 422, response.text
    fetched = external_api.client.get(f"/api/v1/cards/{card_id}", headers=headers)
    assert fetched.status_code == 200, fetched.text
    assert fetched.json()["reviewIntervalHours"] == 12.0
    assert fetched.json()["reviewCount"] == 0


def test_external_rate_limiter_preserves_active_windows_at_key_cap():
    async def run():
        limiter = ExternalRateLimiter(limit=1, window_seconds=60, max_keys=2)
        decisions = [await limiter.admit(key) for key in ("victim", "noise-a", "noise-b", "victim")]
        return decisions, list(limiter._events)

    decisions, keys = asyncio.run(run())

    assert [decision.allowed for decision in decisions] == [True, True, False, False]
    assert keys == ["noise-a", "victim"]


def test_external_rate_limit_returns_standard_headers(external_api, monkeypatch):
    api_key = _create_key(external_api)
    limiter = ExternalRateLimiter(limit=1, window_seconds=60)
    monkeypatch.setattr(external_router, "write_limiter", limiter)
    headers = {"X-KG-API-Key": api_key}

    first = external_api.client.post(
        "/api/v1/cards",
        json={"content": "first", "meaning": "第一"},
        headers=headers,
    )
    second = external_api.client.post(
        "/api/v1/cards",
        json={"content": "second", "meaning": "第二"},
        headers=headers,
    )

    assert first.status_code == 201
    assert first.headers["X-RateLimit-Limit"] == "1"
    assert first.headers["X-RateLimit-Remaining"] == "0"
    assert second.status_code == 429
    assert second.headers["X-RateLimit-Limit"] == "1"
    assert second.headers["X-RateLimit-Remaining"] == "0"
    assert int(second.headers["Retry-After"]) >= 1


def test_external_rate_limiter_rejects_non_positive_max_keys():
    with pytest.raises(ValueError, match="max_keys must be positive"):
        ExternalRateLimiter(limit=1, window_seconds=60, max_keys=0)

    with pytest.raises(ValueError, match="max_keys must be positive"):
        ExternalRateLimiter(limit=1, window_seconds=60, max_keys=-1)


def test_external_api_is_not_double_limited_by_generic_ip_limiter(external_api):
    api_key = _create_key(external_api)
    from kg.app_middleware import anonymous_rate_limit_key
    from kg.rate_limit import api_limiter

    client_ip = "198.51.100.77"
    now = time.monotonic()
    api_limiter._requests[anonymous_rate_limit_key(client_ip)] = collections.deque([now] * api_limiter.max_requests)

    response = external_api.client.get(
        "/api/v1/cards",
        headers={"X-KG-API-Key": api_key, "X-Forwarded-For": client_ip},
    )

    assert response.status_code == 200, response.text
    # Positive control: the seeded bucket is the one the generic limiter reads,
    # so a non-exempt path from the same IP is limited.
    limited = external_api.client.get("/api/health", headers={"X-Forwarded-For": client_ip})
    assert limited.status_code == 429


def test_external_card_delete_treats_embedding_eviction_as_best_effort(external_api, monkeypatch):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    created = external_api.client.post(
        "/api/v1/cards",
        json={"content": "eviction", "meaning": "驅逐"},
        headers=headers,
    )
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]

    def fail_embedding_eviction(*_args, **_kwargs):
        raise OSError("embedding store unavailable")

    monkeypatch.setattr(external_router, "_embedding_store", fail_embedding_eviction)

    deleted = external_api.client.delete(f"/api/v1/cards/{card_id}", headers=headers)

    assert deleted.status_code == 200, deleted.text
    assert deleted.json() == {"cardId": card_id, "deleted": True}
    assert external_api.client.get(f"/api/v1/cards/{card_id}", headers=headers).status_code == 404


def test_add_word_after_external_card_delete_embeds_new_card(external_api, monkeypatch):
    """#2058: the external delete binds llm=None to the shared store; a later
    POST /api/vocab must still embed its new card instead of 500ing."""
    from unittest.mock import MagicMock

    import numpy as np

    import kg.routers.vocab as vocab_router
    from kg.deps import _embedding_store
    from kg.embeddings import EMBEDDING_DIM
    from kg.service_factories import clear_store_cache

    clear_store_cache()
    try:
        api_key = _create_key(external_api)
        created = external_api.client.post(
            "/api/v1/cards",
            json={"content": "ephemeral", "meaning": "短暫"},
            headers={"X-KG-API-Key": api_key},
        )
        assert created.status_code == 201, created.text
        doomed_id = created.json()["card"]["id"]
        deleted = external_api.client.delete(f"/api/v1/cards/{doomed_id}", headers={"X-KG-API-Key": api_key})
        assert deleted.status_code == 200, deleted.text

        def fake_embeddings_create(*, input, **_kwargs):
            resp = MagicMock()
            resp.usage = MagicMock(prompt_tokens=10, total_tokens=10)
            resp.data = []
            for i in range(len(input)):
                item = MagicMock()
                item.index = i
                item.embedding = np.random.rand(EMBEDDING_DIM).tolist()
                resp.data.append(item)
            return resp

        client = MagicMock()
        client.embeddings.create.side_effect = fake_embeddings_create
        monkeypatch.setattr(vocab_router, "create_client", lambda _provider: client)

        added = external_api.client.post(
            "/api/vocab",
            json=[{"word": "lucid", "translation": "清晰的"}],
            headers=external_api.jwt_headers,
        )

        assert added.status_code == 200, added.text
        assert added.json()["created"] == 1
        new_id = added.json()["cardIds"]["lucid"]
        client.embeddings.create.assert_called()
        user_dir = external_api.data_dir / "users" / external_api.user_id
        assert _embedding_store(user_dir, llm=None).has(new_id)
    finally:
        clear_store_cache()


def test_external_enrich_operation_survives_process_memory_reset(external_api, monkeypatch):
    from kg import pipeline_log

    old_db_path = pipeline_log.DB_PATH
    pipeline_log._reset()
    pipeline_log.DB_PATH = external_api.data_dir / "pipeline_runs.db"
    try:
        api_key = _create_key(external_api)
        monkeypatch.setattr(external_router, "_run_external_pipeline", AsyncMock())
        response = external_api.client.post(
            "/api/v1/enrich",
            json={"notebookId": "default"},
            headers={"X-KG-API-Key": api_key},
        )
        assert response.status_code == 202, response.text
        operation_id = response.json()["operationId"]
        assert response.json()["status"] == "queued"

        pipeline_log.end_run(operation_id, "completed")
        external_router._OPERATIONS.clear()
        status = external_api.client.get(
            f"/api/v1/operations/{operation_id}",
            headers={"X-KG-API-Key": api_key},
        )
    finally:
        pipeline_log._reset()
        pipeline_log.DB_PATH = old_db_path

    assert status.status_code == 200, status.text
    assert status.json()["operationId"] == operation_id
    assert status.json()["status"] == "succeeded"


def test_account_erasure_removes_external_api_keys(external_api):
    api_key = _create_key(external_api)
    response = external_api.client.delete("/api/user/account", headers=external_api.jwt_headers)
    assert response.status_code == 200, response.text
    assert "_external_api_keys" not in json.loads(external_api.users_file.read_text())

    rejected = external_api.client.get(
        "/api/v1/cards",
        headers={"X-KG-API-Key": api_key},
    )
    assert rejected.status_code == 401


# --- #2085: async external routes keep blocking work off the event loop -------

_BLOCK_SECONDS = 1.0
_PROBE_BUDGET_SECONDS = 0.2


class _BlockingStub:
    """Wrap a sync callable so it blocks for ``_BLOCK_SECONDS`` and records when it returned."""

    def __init__(self) -> None:
        self.entered = threading.Event()
        self.returned_at: float | None = None

    def wrap(self, original):
        def blocking(*args, **kwargs):
            self.entered.set()
            time.sleep(_BLOCK_SECONDS)
            self.returned_at = time.monotonic()
            return original(*args, **kwargs)

        return blocking


async def _request_while_probing(stub: _BlockingStub, slow_request) -> httpx.Response:
    """Probe ``GET /api/system/info`` while ``slow_request`` is inside ``stub``.

    ASGITransport runs the app on this test's event loop. When the stub runs on
    that loop, this coroutine cannot observe ``stub.entered`` until the stub has
    returned, so the probe is served after the blocking call instead of during it.
    """
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
        slow = asyncio.create_task(slow_request(client))
        deadline = time.monotonic() + 5.0
        while not stub.entered.is_set():
            if slow.done():
                early = slow.result()
                pytest.fail(f"request finished before its blocking call: {early.status_code} {early.text}")
            assert time.monotonic() < deadline, "request never reached its blocking call"
            await asyncio.sleep(0.005)
        probe_started = time.monotonic()
        probe = await client.get("/api/system/info")
        probe_finished = time.monotonic()
        response = await slow

    assert probe.status_code == 200, probe.text
    assert stub.returned_at is not None
    assert probe_finished < stub.returned_at, "the probe was served only after the blocking call returned"
    probe_elapsed = probe_finished - probe_started
    assert probe_elapsed < _PROBE_BUDGET_SECONDS, f"/api/system/info took {probe_elapsed:.2f}s"
    return response


@pytest.fixture()
def external_pipeline_log(external_api, monkeypatch):
    from kg import pipeline_log

    pipeline_log._reset()
    monkeypatch.setattr(pipeline_log, "DB_PATH", external_api.data_dir / "pipeline_runs.db")
    try:
        yield pipeline_log
    finally:
        pipeline_log._reset()


def _seed_two_cards(ctx, headers) -> tuple[str, str]:
    ids = []
    for content in ("alpha", "beta"):
        created = ctx.client.post("/api/v1/cards", json={"content": content, "meaning": content}, headers=headers)
        assert created.status_code == 201, created.text
        ids.append(created.json()["card"]["id"])
    return ids[0], ids[1]


@pytest.mark.asyncio
async def test_create_link_does_not_block_event_loop(external_api, monkeypatch):
    from kg.judge import ManualLinkJudge
    from kg.judge.models import Judgement

    headers = {"X-KG-API-Key": _create_key(external_api)}
    from_id, to_id = _seed_two_cards(external_api, headers)

    def judge(self, *args, **kwargs):
        return Judgement(link="shares_usage", confidence=0.9, reason="slow judge")

    stub = _BlockingStub()
    monkeypatch.setattr(ManualLinkJudge, "evaluate", stub.wrap(judge))
    monkeypatch.setattr(external_router, "create_client", lambda _provider: SimpleNamespace())

    response = await _request_while_probing(
        stub,
        lambda client: client.post("/api/v1/links", json={"fromId": from_id, "toId": to_id}, headers=headers),
    )

    assert response.status_code == 200, response.text
    assert response.json()["reason"] == "slow judge"
    assert "X-Quota-Fraction" in response.headers


@pytest.mark.asyncio
async def test_card_batch_does_not_block_event_loop(external_api, monkeypatch):
    headers = {"X-KG-API-Key": _create_key(external_api)}
    store_cls = type(external_router._card_store(external_api.data_dir / "users" / external_api.user_id))
    stub = _BlockingStub()
    monkeypatch.setattr(store_cls, "find_by_content", stub.wrap(store_cls.find_by_content))

    response = await _request_while_probing(
        stub,
        lambda client: client.post(
            "/api/v1/cards/batch",
            json={"items": [{"content": "gamma", "meaning": "g", "clientId": "c-1"}]},
            headers=headers,
        ),
    )

    assert response.status_code == 201, response.text
    assert response.json()["created"] == 1
    assert response.json()["items"][0]["clientId"] == "c-1"


@pytest.mark.asyncio
async def test_card_list_does_not_block_event_loop(external_api, monkeypatch):
    headers = {"X-KG-API-Key": _create_key(external_api)}
    stub = _BlockingStub()
    monkeypatch.setattr(external_router, "list_vocab_response", stub.wrap(external_router.list_vocab_response))

    response = await _request_while_probing(stub, lambda client: client.get("/api/v1/cards", headers=headers))

    assert response.status_code == 200, response.text
    assert response.json()["items"] == []
    assert response.headers["X-RateLimit-Limit"]


@pytest.mark.asyncio
async def test_enrich_enqueue_does_not_block_event_loop(external_api, external_pipeline_log, monkeypatch):
    headers = {"X-KG-API-Key": _create_key(external_api)}
    monkeypatch.setattr(external_router, "_run_external_pipeline", AsyncMock())
    stub = _BlockingStub()
    monkeypatch.setattr(external_pipeline_log, "start_run", stub.wrap(external_pipeline_log.start_run))

    response = await _request_while_probing(
        stub, lambda client: client.post("/api/v1/enrich", json={"notebookId": "default"}, headers=headers)
    )

    assert response.status_code == 202, response.text
    assert response.json()["status"] == "queued"
    assert external_pipeline_log.get_run(response.json()["operationId"], external_api.user_id) is not None


@pytest.mark.asyncio
async def test_operation_lookup_does_not_block_event_loop(external_api, external_pipeline_log, monkeypatch):
    headers = {"X-KG-API-Key": _create_key(external_api)}
    external_pipeline_log.start_run("slowlookup", external_api.user_id, "default", "background")
    stub = _BlockingStub()
    monkeypatch.setattr(external_pipeline_log, "get_run", stub.wrap(external_pipeline_log.get_run))

    response = await _request_while_probing(
        stub, lambda client: client.get("/api/v1/operations/slowlookup", headers=headers)
    )

    assert response.status_code == 200, response.text
    assert response.json()["operationId"] == "slowlookup"
    assert response.json()["status"] == "running"


def test_operation_lookup_finds_runs_older_than_the_newest_10000(external_api, external_pipeline_log):
    """#2085: the lookup used to scan get_runs(limit=10_000) and 404 past that depth."""
    headers = {"X-KG-API-Key": _create_key(external_api)}
    user_id = external_api.user_id
    conn = external_pipeline_log._get_conn()
    conn.executemany(
        "INSERT INTO pipeline_runs (run_id, user_id, notebook_id, trigger, started_at, status) "
        "VALUES (?, ?, 'default', 'background', ?, 'completed')",
        [("oldestrun", user_id, "2026-01-01T00:00:00+00:00")]
        + [
            (f"run{i}", user_id, f"2026-02-01T{i // 3600:02d}:{i // 60 % 60:02d}:{i % 60:02d}+00:00")
            for i in range(10_001)
        ]
        + [("othersrun", "someone_else", "2026-03-01T00:00:00+00:00")],
    )
    conn.commit()

    oldest = external_api.client.get("/api/v1/operations/oldestrun", headers=headers)
    other = external_api.client.get("/api/v1/operations/othersrun", headers=headers)

    assert oldest.status_code == 200, oldest.text
    assert oldest.json()["operationId"] == "oldestrun"
    assert oldest.json()["status"] == "succeeded"
    assert other.status_code == 404, other.text


def _create_extra_key(ctx) -> tuple[str, str]:
    response = ctx.client.post("/api/v1/api-keys", json={"label": "extra"}, headers=ctx.jwt_headers)
    assert response.status_code == 201, response.text
    body = response.json()
    return body["apiKey"], body["keyId"]


def test_external_write_budget_is_shared_across_a_users_keys_issue_2805(external_api, monkeypatch):
    """Create-use-revoke cycling must not mint a fresh write budget per key."""
    key_limiter = ExternalRateLimiter(limit=100, window_seconds=60)
    user_limiter = ExternalRateLimiter(limit=3, window_seconds=60)
    monkeypatch.setattr(external_router, "write_limiter", key_limiter)
    monkeypatch.setattr(external_router, "user_write_limiter", user_limiter)

    statuses = []
    for index in range(5):
        api_key, key_id = _create_extra_key(external_api)
        response = external_api.client.post(
            "/api/v1/cards",
            json={"content": f"cycle {index}", "meaning": "循環"},
            headers={"X-KG-API-Key": api_key},
        )
        statuses.append(response.status_code)
        revoked = external_api.client.delete(f"/api/v1/api-keys/{key_id}", headers=external_api.jwt_headers)
        assert revoked.status_code == 200, revoked.text

    assert statuses == [201, 201, 201, 429, 429]


def test_external_enrich_budget_is_shared_across_a_users_keys_issue_2805(external_api, monkeypatch):
    key_limiter = ExternalRateLimiter(limit=100, window_seconds=60)
    user_limiter = ExternalRateLimiter(limit=1, window_seconds=60)
    monkeypatch.setattr(external_router, "enrich_limiter", key_limiter)
    monkeypatch.setattr(external_router, "user_enrich_limiter", user_limiter)

    async def run():
        user = {"id": external_api.user_id, "external_api_key_id": "k1"}
        other = {"id": external_api.user_id, "external_api_key_id": "k2"}
        stranger = {"id": "someone-else", "external_api_key_id": "k3"}
        out = []
        for u in (user, other, stranger):
            try:
                await external_router._admit_external(Response(), u, external_router.enrich_limiter)
                out.append(True)
            except HTTPException as exc:
                assert exc.status_code == 429
                out.append(False)
        return out

    assert asyncio.run(run()) == [True, False, True]


def test_invalid_key_flood_is_throttled_per_ip_issue_2803(external_api, monkeypatch):
    monkeypatch.setattr(external_router, "auth_failure_limiter", ExternalRateLimiter(limit=3, window_seconds=60))
    bogus = "kg_" + "ab" * 16 + ".secret"
    flood_ip = {"X-Forwarded-For": "203.0.113.9"}

    codes = [
        external_api.client.get("/api/v1/cards", headers={"X-KG-API-Key": bogus, **flood_ip}).status_code
        for _ in range(5)
    ]
    assert codes == [401, 401, 401, 429, 429]

    # Other clients and their valid keys keep working.
    api_key = _create_key(external_api)
    ok = external_api.client.get("/api/v1/cards", headers={"X-KG-API-Key": api_key, "X-Forwarded-For": "203.0.113.10"})
    assert ok.status_code == 200, ok.text


def test_valid_key_does_not_consume_auth_failure_budget_issue_2803(external_api, monkeypatch):
    limiter = ExternalRateLimiter(limit=1, window_seconds=60)
    monkeypatch.setattr(external_router, "auth_failure_limiter", limiter)
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key, "X-Forwarded-For": "203.0.113.11"}

    codes = [external_api.client.get("/api/v1/cards", headers=headers).status_code for _ in range(4)]

    assert codes == [200, 200, 200, 200]


def test_external_card_meaning_update_evicts_stale_embedding(external_api, monkeypatch):
    """#2688: a meaning edit must drop the card's vector so the pipeline re-embeds it."""
    import numpy as np

    from kg.deps import _embedding_store
    from kg.embeddings import EMBEDDING_DIM, EmbeddingStore
    from kg.service_factories import clear_store_cache

    monkeypatch.setattr(
        EmbeddingStore,
        "_embed",
        lambda self, texts, *, llm=None: np.ones((len(texts), EMBEDDING_DIM), dtype=np.float32),
    )
    clear_store_cache()
    try:
        headers = {"X-KG-API-Key": _create_key(external_api)}
        created = external_api.client.post("/api/v1/cards", json={"content": "stale", "meaning": "舊"}, headers=headers)
        assert created.status_code == 201, created.text
        card_id = created.json()["card"]["id"]
        store = _embedding_store(external_api.data_dir / "users" / external_api.user_id, llm=None)
        store.add(card_id, "stale: 舊")
        assert store.has(card_id)

        note = external_api.client.patch(f"/api/v1/cards/{card_id}", json={"note": "n"}, headers=headers)
        assert note.status_code == 200, note.text
        assert store.has(card_id)

        edited = external_api.client.patch(f"/api/v1/cards/{card_id}", json={"meaning": "新"}, headers=headers)
        assert edited.status_code == 200, edited.text
        assert not store.has(card_id)
    finally:
        clear_store_cache()


def test_external_card_meaning_update_survives_embedding_eviction_failure(external_api, monkeypatch):
    headers = {"X-KG-API-Key": _create_key(external_api)}
    created = external_api.client.post("/api/v1/cards", json={"content": "robust", "meaning": "舊"}, headers=headers)
    card_id = created.json()["card"]["id"]

    def boom(*_a, **_k):
        raise OSError("embedding store unavailable")

    monkeypatch.setattr(external_router, "_embedding_store", boom)
    edited = external_api.client.patch(f"/api/v1/cards/{card_id}", json={"meaning": "新"}, headers=headers)
    assert edited.status_code == 200, edited.text
    assert edited.json()["meaning"] == "新"


def test_external_card_meaning_update_queues_card_for_judging(external_api, monkeypatch):
    from kg.deps import _graph_store
    from kg.service_factories import clear_store_cache

    clear_store_cache()
    try:
        headers = {"X-KG-API-Key": _create_key(external_api)}
        created = external_api.client.post(
            "/api/v1/cards", json={"content": "queued", "meaning": "舊"}, headers=headers
        )
        assert created.status_code == 201, created.text
        card_id = created.json()["card"]["id"]
        user_dir = external_api.data_dir / "users" / external_api.user_id
        _graph_store(user_dir, notebook_id="default").pop_pending_judge()

        edited = external_api.client.patch(f"/api/v1/cards/{card_id}", json={"meaning": "新"}, headers=headers)
        assert edited.status_code == 200, edited.text
        assert card_id in _graph_store(user_dir, notebook_id="default").pop_pending_judge()
    finally:
        clear_store_cache()


def test_external_card_unchanged_meaning_update_neither_evicts_nor_queues(external_api, monkeypatch):
    import numpy as np

    from kg.deps import _embedding_store, _graph_store
    from kg.embeddings import EMBEDDING_DIM, EmbeddingStore
    from kg.service_factories import clear_store_cache

    monkeypatch.setattr(
        EmbeddingStore,
        "_embed",
        lambda self, texts, *, llm=None: np.ones((len(texts), EMBEDDING_DIM), dtype=np.float32),
    )
    clear_store_cache()
    try:
        headers = {"X-KG-API-Key": _create_key(external_api)}
        created = external_api.client.post("/api/v1/cards", json={"content": "same", "meaning": "同"}, headers=headers)
        assert created.status_code == 201, created.text
        card_id = created.json()["card"]["id"]
        user_dir = external_api.data_dir / "users" / external_api.user_id
        store = _embedding_store(user_dir, llm=None)
        store.add(card_id, "same: 同")
        _graph_store(user_dir, notebook_id="default").pop_pending_judge()

        edited = external_api.client.patch(f"/api/v1/cards/{card_id}", json={"meaning": "同"}, headers=headers)
        assert edited.status_code == 200, edited.text
        assert store.has(card_id)
        assert card_id not in _graph_store(user_dir, notebook_id="default").pop_pending_judge()
    finally:
        clear_store_cache()


def test_external_card_delete_graph_failure_not_masked_by_restore_conflict(external_api, monkeypatch):
    api_key = _create_key(external_api)
    headers = {"X-KG-API-Key": api_key}
    seen_dirs: list = []
    original_card_store = external_router._card_store

    def recording_card_store(user_dir):
        seen_dirs.append(user_dir)
        return original_card_store(user_dir)

    monkeypatch.setattr(external_router, "_card_store", recording_card_store)
    created = external_api.client.post(
        "/api/v1/cards",
        json={"content": "superseded", "meaning": "被取代"},
        headers=headers,
    )
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]
    user = {"id": external_api.user_id, "dir": seen_dirs[-1]}

    def fail_graph_after_concurrent_add(_graph, _card_id):
        # A concurrent add of the same content lands while the delete is in flight.
        original_card_store(user["dir"]).add(content="superseded", meaning="新的", notebook_id="default")
        raise RuntimeError("graph cleanup boom")

    monkeypatch.setattr(external_router, "link_peer_ids", fail_graph_after_concurrent_add)

    with pytest.raises(RuntimeError, match="graph cleanup boom"):
        external_router._delete_external_card(user, card_id, "default")


def _key_store_fns(tmp_path, users):
    lock_file = tmp_path / "users.lock"
    return {
        "users_lock_file": lock_file,
        "load_users": lambda: users,
        "save_users": lambda payload: None,
    }


def _owned_key_records(users, user_id):
    return [record for record in users["_external_api_keys"].values() if record.get("user_id") == user_id]


def test_issue_revoke_cycles_keep_per_user_key_records_bounded(tmp_path):
    from kg.external_api_keys import MAX_KEY_RECORDS_PER_USER, issue_api_key, revoke_api_key

    user_id = "user-1"
    users = {user_id: {"config": {}}}
    fns = _key_store_fns(tmp_path, users)
    for _ in range(MAX_KEY_RECORDS_PER_USER * 3):
        issued = issue_api_key(user_id, label="cycle", **fns)
        revoke_api_key(user_id, issued["keyId"], **fns)

    assert len(_owned_key_records(users, user_id)) <= MAX_KEY_RECORDS_PER_USER


def test_issue_drops_revoked_records_past_retention_window(tmp_path):
    from kg.external_api_keys import issue_api_key

    user_id = "user-1"
    old = "2020-01-01T00:00:00+00:00"
    users = {
        user_id: {"config": {}},
        "_external_api_keys": {
            "f" * 32: {
                "user_id": user_id,
                "label": "ancient",
                "created_at": old,
                "revoked_at": old,
                "secret_hash": "x",
            },
        },
    }
    issue_api_key(user_id, label="fresh", **_key_store_fns(tmp_path, users))

    assert "f" * 32 not in users["_external_api_keys"]


def test_list_api_keys_is_capped_and_keeps_every_active_key(tmp_path):
    from kg.external_api_keys import MAX_KEY_RECORDS_PER_USER, list_api_keys

    user_id = "user-1"
    records = {
        f"{index:032x}": {
            "user_id": user_id,
            "label": "revoked",
            "created_at": f"2026-01-01T00:{index % 60:02d}:00+00:00",
            "revoked_at": f"2026-01-02T00:{index % 60:02d}:00+00:00",
        }
        for index in range(MAX_KEY_RECORDS_PER_USER * 10)
    }
    active_id = "e" * 32
    records[active_id] = {
        "user_id": user_id,
        "label": "active-old",
        "created_at": "2025-06-01T00:00:00+00:00",
        "revoked_at": None,
    }
    users = {user_id: {"config": {}}, "_external_api_keys": records}

    listed = list_api_keys(user_id, load_users=lambda: users)

    assert len(listed) <= MAX_KEY_RECORDS_PER_USER
    assert any(item["keyId"] == active_id for item in listed)


def test_list_api_keys_keeps_newest_revocations_by_revoked_at_not_created_at(tmp_path):
    from datetime import UTC, datetime, timedelta

    from kg.external_api_keys import MAX_KEY_RECORDS_PER_USER, list_api_keys

    user_id = "user-1"
    base = datetime(2026, 1, 1, tzinfo=UTC)
    total = MAX_KEY_RECORDS_PER_USER + 5
    # Index i: created later as i grows, but revoked earlier as i grows, so the
    # newest creations are the oldest revocations. Retention must follow revoked_at.
    records = {
        f"{index:032x}": {
            "user_id": user_id,
            "label": "revoked",
            "created_at": (base + timedelta(minutes=index)).isoformat(),
            "revoked_at": (base + timedelta(days=1) - timedelta(minutes=index)).isoformat(),
        }
        for index in range(total)
    }
    users = {user_id: {"config": {}}, "_external_api_keys": records}

    listed = list_api_keys(user_id, load_users=lambda: users)

    expected = {f"{index:032x}" for index in range(MAX_KEY_RECORDS_PER_USER)}
    assert {item["keyId"] for item in listed} == expected


def test_external_card_delete_graph_store_failure_keeps_card_and_propagates(external_api, monkeypatch):
    headers = {"X-KG-API-Key": _create_key(external_api)}
    created = external_api.client.post("/api/v1/cards", json={"content": "gfail", "meaning": "图"}, headers=headers)
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]
    user = {"id": external_api.user_id, "dir": external_api.data_dir / "users" / external_api.user_id}

    original_graph_store = external_router._graph_store
    broken = {"on": True}

    def flaky_graph(*args, **kwargs):
        if broken["on"]:
            raise RuntimeError("graph store unavailable")
        return original_graph_store(*args, **kwargs)

    monkeypatch.setattr(external_router, "_graph_store", flaky_graph)
    with pytest.raises(RuntimeError, match="graph store unavailable"):
        external_router._delete_external_card(user, card_id, "default")

    broken["on"] = False
    fetched = external_api.client.get(f"/api/v1/cards/{card_id}", headers=headers)
    assert fetched.status_code == 200, fetched.text


def test_external_card_delete_succeeds_when_embedding_store_cannot_open(external_api, monkeypatch):
    headers = {"X-KG-API-Key": _create_key(external_api)}
    created = external_api.client.post("/api/v1/cards", json={"content": "efail", "meaning": "嵌"}, headers=headers)
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]
    user = {"id": external_api.user_id, "dir": external_api.data_dir / "users" / external_api.user_id}

    def broken_embeddings(*_args, **_kwargs):
        raise RuntimeError("embedding store unavailable")

    monkeypatch.setattr(external_router, "_embedding_store", broken_embeddings)
    result = external_router._delete_external_card(user, card_id, "default")

    assert result.deleted is True


def test_external_card_meaning_update_survives_judge_requeue_failure(external_api, monkeypatch):
    """#2957: a failing add_pending_judge must not fail a durable meaning edit."""
    import kg.vocab_crud as vocab_crud

    headers = {"X-KG-API-Key": _create_key(external_api)}
    created = external_api.client.post("/api/v1/cards", json={"content": "requeue", "meaning": "舊"}, headers=headers)
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]

    original_graph_store = external_router._graph_store

    class JudgeQueueFailsGraph:
        def __init__(self, inner):
            self._inner = inner

        def __getattr__(self, name):
            return getattr(self._inner, name)

        def add_pending_judge(self, *_args, **_kwargs):
            raise RuntimeError("judge queue unavailable")

    monkeypatch.setattr(
        external_router,
        "_graph_store",
        lambda *a, **k: JudgeQueueFailsGraph(original_graph_store(*a, **k)),
    )
    captured: list[str] = []
    monkeypatch.setattr(
        vocab_crud,
        "capture_handled",
        lambda exc, *, context: captured.append(context),
    )

    edited = external_api.client.patch(f"/api/v1/cards/{card_id}", json={"meaning": "新"}, headers=headers)
    assert edited.status_code == 200, edited.text
    assert edited.json()["meaning"] == "新"
    assert captured == ["vocab.judge_requeue"]


def test_external_card_meaning_update_graph_open_failure_is_captured_not_raised(external_api, monkeypatch):
    """#2957: a graph store that fails to open is captured and skipped by the meaning-edit side effects."""
    headers = {"X-KG-API-Key": _create_key(external_api)}
    created = external_api.client.post("/api/v1/cards", json={"content": "gopen", "meaning": "舊"}, headers=headers)
    assert created.status_code == 201, created.text
    card_id = created.json()["card"]["id"]
    user = {"id": external_api.user_id, "dir": external_api.data_dir / "users" / external_api.user_id}

    def broken_graph(*_args, **_kwargs):
        raise RuntimeError("graph store unavailable")

    captured: list[str] = []
    monkeypatch.setattr(external_router, "_graph_store", broken_graph)
    monkeypatch.setattr(external_router, "capture_handled", lambda exc, *, context: captured.append(context))

    external_router._reembed_after_meaning_edit(user, card_id, "default")

    assert captured == ["external_api.judge_requeue"]
