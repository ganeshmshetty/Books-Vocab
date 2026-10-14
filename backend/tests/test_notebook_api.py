"""Integration tests for notebook CRUD HTTP endpoints.

Covers: GET /api/notebooks, POST /api/notebooks, PATCH /api/notebooks/{nb_id},
DELETE /api/notebooks/{nb_id}.
"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
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
    users_file = data_dir / "users.json"
    users_file.write_text(
        json.dumps(
            {
                user_id: {
                    "config": {},
                    "subscription": {
                        "is_active": True,
                        "status": "active",
                        "plan_name": "Books & Vocab Pro",
                        "trial_days": 7,
                        "will_renew": True,
                    },
                },
            }
        )
    )

    token = make_jwt(user_id)
    headers = {"Authorization": f"Bearer {token}"}

    original_settings = app.state.kg_settings
    original_load = app.state.load_users
    original_save = app.state.save_users

    test_settings = KGSettings(
        data_dir=data_dir,
        jwt_secret=TEST_JWT_SECRET,
        app_store_allow_unsigned_sync=True,
        app_store_allow_unsigned_notifications=True,
    )
    _swap_settings(test_settings)

    client = None
    try:
        api_mod._USER_LOCKS.clear()
        deps_mod._USER_LOCKS_MUTEX = None
        client = TestClient(app, raise_server_exceptions=False)
        yield SimpleNamespace(
            client=client,
            user_id=user_id,
            headers=headers,
            data_dir=data_dir,
        )
    finally:
        try:
            if client is not None:
                client.close()
        finally:
            app.state.kg_settings = original_settings
            app.state.load_users = original_load
            app.state.save_users = original_save


def test_isolated_api_closes_owned_client(tmp_path, monkeypatch):
    """The fixture must close the TestClient it creates before teardown."""
    close_calls = 0
    original_close = TestClient.close

    def tracked_close(client):
        nonlocal close_calls
        close_calls += 1
        return original_close(client)

    monkeypatch.setattr(TestClient, "close", tracked_close)
    fixture_generator = isolated_api.__wrapped__(tmp_path)
    next(fixture_generator)
    fixture_generator.close()

    assert close_calls == 1


def test_isolated_api_restores_state_when_client_construction_fails(tmp_path, monkeypatch):
    """A client setup failure must preserve the original exception and state."""
    original_settings = app.state.kg_settings
    original_load = app.state.load_users
    original_save = app.state.save_users

    def fail_client_construction(*args, **kwargs):
        raise RuntimeError("client construction failed")

    monkeypatch.setitem(globals(), "TestClient", fail_client_construction)

    fixture_generator = isolated_api.__wrapped__(tmp_path)
    with pytest.raises(RuntimeError, match="client construction failed"):
        next(fixture_generator)

    assert app.state.kg_settings is original_settings
    assert app.state.load_users is original_load
    assert app.state.save_users is original_save


def test_isolated_api_restores_state_when_client_close_fails(tmp_path, monkeypatch):
    """A client close failure must not prevent app state restoration."""
    original_settings = app.state.kg_settings
    original_load = app.state.load_users
    original_save = app.state.save_users

    def fail_client_close(client):
        raise RuntimeError("client close failed")

    monkeypatch.setattr(TestClient, "close", fail_client_close)

    fixture_generator = isolated_api.__wrapped__(tmp_path)
    next(fixture_generator)
    with pytest.raises(RuntimeError, match="client close failed"):
        fixture_generator.close()

    assert app.state.kg_settings is original_settings
    assert app.state.load_users is original_load
    assert app.state.save_users is original_save


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _nb_ids(body: list[dict]) -> set[str]:
    return {nb["id"] for nb in body}


def _review_policy(mode: str = "custom", initial: float = 12) -> dict:
    return {
        "mode": mode,
        "customInitialIntervalHours": initial,
        "customRememberedMultiplier": 1.9,
        "customForgotMultiplier": 0.45,
        "customMinimumIntervalHours": 6,
        "customMaximumIntervalHours": 1440,
    }


def _card_layout(recognition: str = "compact", production: str = "standard") -> dict:
    return {"recognition": recognition, "production": production}


# ---------------------------------------------------------------------------
# GET /api/notebooks
# ---------------------------------------------------------------------------


def test_list_notebooks_empty_state(isolated_api):
    """Fresh user — only the auto-created default notebook is returned."""
    r = isolated_api.client.get("/api/notebooks", headers=isolated_api.headers)
    assert r.status_code == 200, r.text
    body = r.json()
    assert isinstance(body, list)
    assert len(body) >= 1
    defaults = [nb for nb in body if nb["isDefault"]]
    assert len(defaults) == 1
    assert defaults[0]["settings"] == {
        "reviewPolicy": {"value": None, "updatedAt": None},
        "cardLayout": {"value": None, "updatedAt": None},
    }


def test_list_notebooks_after_create(isolated_api):
    """Notebooks created via POST appear in subsequent GET."""
    client = isolated_api.client
    h = isolated_api.headers

    client.post("/api/notebooks", json={"name": "Alpha", "color": "#ff0000"}, headers=h)
    client.post("/api/notebooks", json={"name": "Beta", "color": "#00ff00"}, headers=h)

    r = client.get("/api/notebooks", headers=h)
    assert r.status_code == 200, r.text
    names = {nb["name"] for nb in r.json()}
    assert {"Alpha", "Beta"}.issubset(names)


def test_list_notebooks_since_naive_timestamp_is_utc(isolated_api, monkeypatch):
    """A naive ISO ``since`` value is a UTC wall-clock timestamp."""
    previous_tz = os.environ.get("TZ")
    monkeypatch.setenv("TZ", "Pacific/Honolulu")
    time.tzset()
    try:
        client = isolated_api.client
        h = isolated_api.headers
        created = client.post("/api/notebooks", json={"name": "UTC Since", "color": "#123456"}, headers=h).json()
        updated_at = datetime.fromisoformat(created["updatedAt"].replace("Z", "+00:00"))
        since = (updated_at - timedelta(seconds=1)).replace(tzinfo=None).isoformat()

        r = client.get("/api/notebooks", params={"since": since}, headers=h)

        assert r.status_code == 200, r.text
        assert created["id"] in _nb_ids(r.json())
    finally:
        if previous_tz is None:
            monkeypatch.delenv("TZ", raising=False)
        else:
            monkeypatch.setenv("TZ", previous_tz)
        time.tzset()


def test_list_notebooks_since_preserves_aware_and_invalid_semantics(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers
    created = client.post("/api/notebooks", json={"name": "Aware Since", "color": "#654321"}, headers=h).json()
    updated_at = datetime.fromisoformat(created["updatedAt"].replace("Z", "+00:00"))

    equal_z = client.get("/api/notebooks", params={"since": created["updatedAt"]}, headers=h)
    before_offset = client.get(
        "/api/notebooks",
        params={"since": (updated_at - timedelta(seconds=1)).astimezone(timezone(timedelta(hours=8))).isoformat()},
        headers=h,
    )
    invalid = client.get("/api/notebooks", params={"since": "not-a-timestamp"}, headers=h)

    assert equal_z.status_code == 200, equal_z.text
    assert created["id"] not in _nb_ids(equal_z.json())
    assert before_offset.status_code == 200, before_offset.text
    assert created["id"] in _nb_ids(before_offset.json())
    assert invalid.status_code == 400, invalid.text
    assert invalid.json()["detail"] == "Invalid since timestamp"


def test_list_notebooks_rejects_explicit_empty_since(isolated_api):
    """An explicit empty incremental cursor must not restart full sync."""
    response = isolated_api.client.get(
        "/api/notebooks",
        params={"since": ""},
        headers=isolated_api.headers,
    )

    assert response.status_code == 400, response.text
    assert response.json()["detail"] == "Invalid since timestamp"


# ---------------------------------------------------------------------------
# POST /api/notebooks
# ---------------------------------------------------------------------------


def test_create_notebook_returns_201(isolated_api):
    r = isolated_api.client.post(
        "/api/notebooks",
        json={"name": "My Notebook", "color": "#abcdef"},
        headers=isolated_api.headers,
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["name"] == "My Notebook"
    assert body["color"] == "#abcdef"
    assert body["isDefault"] is False
    assert "id" in body


def test_create_notebook_appears_in_list(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers

    r_create = client.post("/api/notebooks", json={"name": "NewNB", "color": "#111111"}, headers=h)
    assert r_create.status_code == 201
    nb_id = r_create.json()["id"]

    r_list = client.get("/api/notebooks", headers=h)
    assert nb_id in _nb_ids(r_list.json())


# ---------------------------------------------------------------------------
# PATCH /api/notebooks/{nb_id}
# ---------------------------------------------------------------------------


def test_patch_notebook_sort_order_out_of_range_is_422(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "SO", "color": "#111111"}, headers=h).json()["id"]

    r = client.patch(f"/api/notebooks/{nb_id}", json={"sort_order": 10**20}, headers=h)
    assert r.status_code == 422, r.text


def test_patch_notebook_name(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers

    nb_id = client.post("/api/notebooks", json={"name": "Old Name", "color": "#aabbcc"}, headers=h).json()["id"]

    r = client.patch(f"/api/notebooks/{nb_id}", json={"name": "New Name"}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["name"] == "New Name"


def test_patch_notebook_refuses_staged_notebook_and_preserves_metadata(isolated_api):
    from kg.notebook import NotebookStore

    store = NotebookStore(isolated_api.data_dir / "users" / isolated_api.user_id / "notebooks.db")
    staged = store.create("Staged metadata", is_staged=True)
    try:
        response = isolated_api.client.patch(
            f"/api/notebooks/{staged.id}",
            json={"name": "Should remain hidden"},
            headers=isolated_api.headers,
        )

        assert response.status_code == 404, response.text
        current = store.get(staged.id)
        assert current is not None
        assert current.name == "Staged metadata"
        assert current.is_staged is True
    finally:
        store.close()


def test_patch_notebook_color(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers

    nb_id = client.post("/api/notebooks", json={"name": "ColorTest", "color": "#000000"}, headers=h).json()["id"]

    r = client.patch(f"/api/notebooks/{nb_id}", json={"color": "#ffffff"}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["color"] == "#ffffff"


def test_patch_notebook_color_null_clears_existing_color(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers

    nb_id = client.post(
        "/api/notebooks",
        json={"name": "ClearColor", "color": "#112233"},
        headers=h,
    ).json()["id"]

    r = client.patch(f"/api/notebooks/{nb_id}", json={"color": None}, headers=h)

    assert r.status_code == 200, r.text
    assert r.json()["color"] is None


def test_patch_nonexistent_notebook_returns_404(isolated_api):
    r = isolated_api.client.patch(
        "/api/notebooks/nonexistent-id",
        json={"name": "Ghost"},
        headers=isolated_api.headers,
    )
    assert r.status_code == 404, r.text


def test_patch_no_fields_returns_400(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers

    nb_id = client.post("/api/notebooks", json={"name": "EmptyPatch", "color": "#123456"}, headers=h).json()["id"]

    r = client.patch(f"/api/notebooks/{nb_id}", json={}, headers=h)
    assert r.status_code == 400, r.text


def test_patch_notebook_settings_returns_updated_notebook(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Settings"}, headers=h).json()["id"]

    r = client.patch(
        f"/api/notebooks/{nb_id}/settings",
        json={
            "reviewPolicy": {
                "value": {
                    **_review_policy(),
                },
                "updatedAt": 100.0,
            }
        },
        headers=h,
    )

    assert r.status_code == 200, r.text
    body = r.json()
    assert body["settings"]["reviewPolicy"] == {
        "value": _review_policy(),
        "updatedAt": 100.0,
    }
    assert body["settings"]["cardLayout"] == {"value": None, "updatedAt": None}


def test_patch_notebook_settings_rejects_inverted_review_interval(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Review bounds"}, headers=h).json()["id"]

    valid = _review_policy()
    seeded = client.patch(
        f"/api/notebooks/{nb_id}/settings",
        json={"reviewPolicy": {"value": valid, "updatedAt": 100.0}},
        headers=h,
    )
    assert seeded.status_code == 200, seeded.text

    invalid = {**valid, "customMinimumIntervalHours": 24, "customMaximumIntervalHours": 12}
    rejected = client.patch(
        f"/api/notebooks/{nb_id}/settings",
        json={"reviewPolicy": {"value": invalid, "updatedAt": 200.0}},
        headers=h,
    )
    assert rejected.status_code == 422, rejected.text

    listed = client.get("/api/notebooks", headers=h)
    assert listed.status_code == 200, listed.text
    notebook = next(item for item in listed.json() if item["id"] == nb_id)
    assert notebook["settings"]["reviewPolicy"] == {"value": valid, "updatedAt": 100.0}


@pytest.mark.parametrize(
    "field",
    [
        "customInitialIntervalHours",
        "customRememberedMultiplier",
        "customForgotMultiplier",
        "customMinimumIntervalHours",
        "customMaximumIntervalHours",
    ],
)
@pytest.mark.parametrize("non_finite", ["NaN", "Infinity", "-Infinity"])
def test_patch_notebook_settings_rejects_non_finite_review_policy_values(isolated_api, field, non_finite):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Finite review policy"}, headers=h).json()["id"]

    value = _review_policy()
    body = json.dumps({"reviewPolicy": {"value": value, "updatedAt": 100.0}})
    marker = f'"{field}": {json.dumps(value[field])}'
    body = body.replace(marker, f'"{field}": {non_finite}', 1)
    rejected = client.patch(
        f"/api/notebooks/{nb_id}/settings",
        content=body,
        headers={**h, "Content-Type": "application/json"},
    )

    assert rejected.status_code == 422, rejected.text
    assert any(error["type"] == "finite_number" for error in rejected.json()["detail"])

    listed = client.get("/api/notebooks", headers=h)
    assert listed.status_code == 200, listed.text
    notebook = next(item for item in listed.json() if item["id"] == nb_id)
    assert notebook["settings"]["reviewPolicy"] == {"value": None, "updatedAt": None}


def test_patch_notebook_settings_groups_are_independent_and_listed(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Group isolation"}, headers=h).json()["id"]

    both = client.patch(
        f"/api/notebooks/{nb_id}/settings",
        json={
            "reviewPolicy": {"value": _review_policy(), "updatedAt": 10.0},
            "cardLayout": {"value": _card_layout(), "updatedAt": 20.0},
        },
        headers=h,
    )
    assert both.status_code == 200, both.text

    review_only = client.patch(
        f"/api/notebooks/{nb_id}/settings",
        json={"reviewPolicy": {"value": _review_policy(initial=24), "updatedAt": 30.0}},
        headers=h,
    )
    assert review_only.status_code == 200, review_only.text
    assert review_only.json()["settings"]["reviewPolicy"]["value"]["customInitialIntervalHours"] == 24
    assert review_only.json()["settings"]["cardLayout"]["value"] == _card_layout()

    listed = client.get("/api/notebooks", headers=h)
    assert listed.status_code == 200, listed.text
    listed_nb = next(item for item in listed.json() if item["id"] == nb_id)
    assert listed_nb["settings"] == review_only.json()["settings"]


def test_patch_notebook_settings_reset_is_timestamped_and_rejects_older_value(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Reset"}, headers=h).json()["id"]

    client.patch(
        f"/api/notebooks/{nb_id}/settings",
        json={"reviewPolicy": {"value": _review_policy(), "updatedAt": 100.0}},
        headers=h,
    )
    reset = client.patch(
        f"/api/notebooks/{nb_id}/settings",
        json={"reviewPolicy": {"value": None, "updatedAt": 110.0}},
        headers=h,
    )
    assert reset.status_code == 200, reset.text
    assert reset.json()["settings"]["reviewPolicy"] == {"value": None, "updatedAt": 110.0}

    stale = client.patch(
        f"/api/notebooks/{nb_id}/settings",
        json={"reviewPolicy": {"value": _review_policy(initial=48), "updatedAt": 105.0}},
        headers=h,
    )
    assert stale.status_code == 200, stale.text
    assert stale.json()["settings"]["reviewPolicy"] == {"value": None, "updatedAt": 110.0}


def test_patch_notebook_settings_persists_when_store_reopens(isolated_api):
    from kg.notebook import NotebookStore

    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Persistent"}, headers=h).json()["id"]
    expected = _card_layout("compact", "compact")
    r = client.patch(
        f"/api/notebooks/{nb_id}/settings",
        json={"cardLayout": {"value": expected, "updatedAt": 77.0}},
        headers=h,
    )
    assert r.status_code == 200, r.text

    store = NotebookStore(isolated_api.data_dir / "users" / isolated_api.user_id / "notebooks.db")
    try:
        row = store.get_settings(nb_id)
        assert row is not None
        assert row.card_layout_updated_at == 77.0
        assert json.loads(row.card_layout) == expected
    finally:
        store.close()


def test_patch_notebook_settings_preserves_auth_and_notebook_errors(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Errors"}, headers=h).json()["id"]

    assert client.patch(f"/api/notebooks/{nb_id}/settings", json={}).status_code == 401
    assert (
        client.patch(
            "/api/notebooks/missing/settings", json={"cardLayout": {"value": None, "updatedAt": 1}}, headers=h
        ).status_code
        == 404
    )

    deleted_id = client.post("/api/notebooks", json={"name": "Deleted"}, headers=h).json()["id"]
    assert client.delete(f"/api/notebooks/{deleted_id}", headers=h).status_code == 200
    deleted = client.patch(
        f"/api/notebooks/{deleted_id}/settings",
        json={"cardLayout": {"value": None, "updatedAt": 1}},
        headers=h,
    )
    assert deleted.status_code == 404, deleted.text

    empty = client.patch(f"/api/notebooks/{nb_id}/settings", json={}, headers=h)
    assert empty.status_code == 422, empty.text


def test_notebook_settings_concurrent_lww_never_allows_older_write_to_win(tmp_path):
    from kg.notebook import NotebookStore

    db_path = tmp_path / "users" / "u1" / "notebooks.db"
    seed = NotebookStore(db_path)
    nb = seed.create("Concurrent")
    seed.update_settings(nb.id, review_policy=(_review_policy(initial=12), 100.0))

    older = NotebookStore(db_path)
    newer = NotebookStore(db_path)
    barrier = threading.Barrier(2)

    def write(store, updated_at, initial):
        barrier.wait()
        return store.update_settings(
            nb.id,
            review_policy=(_review_policy(initial=initial), updated_at),
        )

    try:
        with ThreadPoolExecutor(max_workers=2) as executor:
            old_result = executor.submit(write, older, 150.0, 24)
            new_result = executor.submit(write, newer, 200.0, 48)
            old_result.result()
            new_result.result()

        final = seed.get_settings(nb.id)
        assert final is not None
        assert final.review_policy_updated_at == 200.0
        assert json.loads(final.review_policy)["customInitialIntervalHours"] == 48
    finally:
        older.close()
        newer.close()
        seed.close()


@pytest.mark.parametrize("updated_at", ["NaN", "Infinity", "-Infinity"])
def test_patch_notebook_settings_rejects_non_finite_updated_at(isolated_api, updated_at):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Finite"}, headers=h).json()["id"]

    body = f'{{"cardLayout": {{"value": {{"recognition": "compact", "production": "standard"}}, "updatedAt": {updated_at}}}}}'
    r = client.patch(
        f"/api/notebooks/{nb_id}/settings", content=body, headers={**h, "Content-Type": "application/json"}
    )

    assert r.status_code == 422, r.text
    assert any(error["type"] == "finite_number" for error in r.json()["detail"])


def test_patch_notebook_settings_refuses_staged_notebook_and_get_hides_it(isolated_api):
    from kg.notebook import NotebookStore

    store = NotebookStore(isolated_api.data_dir / "users" / isolated_api.user_id / "notebooks.db")
    staged = store.create("Staged", is_staged=True)
    try:
        patch = isolated_api.client.patch(
            f"/api/notebooks/{staged.id}/settings",
            json={"cardLayout": {"value": _card_layout(), "updatedAt": 1.0}},
            headers=isolated_api.headers,
        )
        assert patch.status_code == 404, patch.text

        listed = isolated_api.client.get("/api/notebooks", headers=isolated_api.headers)
        assert listed.status_code == 200, listed.text
        assert staged.id not in _nb_ids(listed.json())
    finally:
        store.close()


def test_vocab_api_rejects_staged_notebook_access(isolated_api):
    from kg.notebook import NotebookStore

    store = NotebookStore(isolated_api.data_dir / "users" / isolated_api.user_id / "notebooks.db")
    staged = store.create("Staged", is_staged=True)
    try:
        response = isolated_api.client.get(
            "/api/vocab",
            params={"notebook_id": staged.id},
            headers=isolated_api.headers,
        )

        assert response.status_code == 403, response.text
        assert response.json()["detail"] == "Notebook access denied"
    finally:
        store.close()


# ---------------------------------------------------------------------------
# DELETE /api/notebooks/{nb_id}
# ---------------------------------------------------------------------------


def test_delete_non_default_notebook(isolated_api):
    """Deleting a notebook should hard-delete its cards, not reassign to default."""
    client = isolated_api.client
    h = isolated_api.headers

    nb_id = client.post("/api/notebooks", json={"name": "ToDelete", "color": "#ff0000"}, headers=h).json()["id"]

    # Add vocab cards to this notebook
    client.post("/api/vocab", json=[{"word": "apple", "translation": "蘋果"}], params={"notebook_id": nb_id}, headers=h)
    client.post(
        "/api/vocab", json=[{"word": "banana", "translation": "香蕉"}], params={"notebook_id": nb_id}, headers=h
    )

    r = client.delete(f"/api/notebooks/{nb_id}", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["deleted"] == nb_id
    assert "cardsDeleted" in body
    assert body["cardsDeleted"] == 2
    # Cards must NOT appear in default notebook
    r_vocab = client.get("/api/vocab", params={"notebook_id": "default"}, headers=h)
    default_words = [c["content"] for c in r_vocab.json()]
    assert "apple" not in default_words
    assert "banana" not in default_words


def test_delete_notebook_removes_all_artifact_kinds(isolated_api):
    """delete_notebook must remove a file for EVERY kind in NOTEBOOK_FILE_SPECS
    (plus its .bak/.tmp siblings). It derives filenames from the ops_shared SoT,
    so adding a new per-notebook artifact kind cannot silently orphan a file."""
    from kg.ops_shared import notebook_files

    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Artifacts"}, headers=h).json()["id"]

    user_dir = isolated_api.data_dir / "users" / isolated_api.user_id
    user_dir.mkdir(parents=True, exist_ok=True)
    created = []
    for path in notebook_files(user_dir, nb_id).values():
        for suffix in ("", ".bak", ".tmp"):
            sibling = path.with_name(path.name + suffix)
            sibling.write_text("x")
            created.append(sibling)
    assert all(f.exists() for f in created)

    r = client.delete(f"/api/notebooks/{nb_id}", headers=h)
    assert r.status_code == 200, r.text

    leftover = [str(f) for f in created if f.exists()]
    assert not leftover, f"orphan artifacts left after delete: {leftover}"


def test_delete_notebook_removes_lock_siblings(isolated_api):
    """path_write_lock leaves ``<file>.lock`` and links leaves
    ``<links>.pair-<digest>.lock``; delete must not leak them (#2809)."""
    from kg.ops_shared import notebook_files

    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Locks"}, headers=h).json()["id"]
    other_id = client.post("/api/notebooks", json={"name": "Keep"}, headers=h).json()["id"]

    user_dir = isolated_api.data_dir / "users" / isolated_api.user_id
    user_dir.mkdir(parents=True, exist_ok=True)
    created = []
    for path in notebook_files(user_dir, nb_id).values():
        lock = path.with_name(path.name + ".lock")
        pair = path.with_name(path.name + ".pair-" + "ab" * 32 + ".lock")
        for f in (lock, pair):
            f.write_text("")
            created.append(f)
    kept = [p.with_name(p.name + ".lock") for p in notebook_files(user_dir, other_id).values()]
    for f in kept:
        f.write_text("")

    r = client.delete(f"/api/notebooks/{nb_id}", headers=h)
    assert r.status_code == 200, r.text

    leftover = [str(f) for f in created if f.exists()]
    assert not leftover, f"orphan lock files left after delete: {leftover}"
    assert all(f.exists() for f in kept), "other notebook's locks must survive"


def test_delete_default_notebook_fails(isolated_api):
    """Deleting the default notebook must return 400."""
    r = isolated_api.client.delete("/api/notebooks/default", headers=isolated_api.headers)
    assert r.status_code == 400, r.text


def test_delete_nonexistent_notebook_fails(isolated_api):
    """Deleting a notebook that never existed returns 400 (not found)."""
    r = isolated_api.client.delete("/api/notebooks/does-not-exist", headers=isolated_api.headers)
    assert r.status_code == 400, r.text


# ---------------------------------------------------------------------------
# cover_pattern
# ---------------------------------------------------------------------------


def test_create_notebook_with_cover_pattern(isolated_api):
    r = isolated_api.client.post(
        "/api/notebooks",
        json={"name": "Patterned", "cover_pattern": "dots"},
        headers=isolated_api.headers,
    )
    assert r.status_code == 201, r.text
    assert r.json()["coverPattern"] == "dots"


def test_create_notebook_invalid_cover_pattern_returns_422(isolated_api):
    r = isolated_api.client.post(
        "/api/notebooks",
        json={"name": "BadPattern", "cover_pattern": "zigzag"},
        headers=isolated_api.headers,
    )
    assert r.status_code == 422, r.text
    assert "detail" in r.json()


def test_update_notebook_cover_pattern(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Pat"}, headers=h).json()["id"]

    r = client.patch(f"/api/notebooks/{nb_id}", json={"cover_pattern": "waves"}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["coverPattern"] == "waves"

    r = client.patch(f"/api/notebooks/{nb_id}", json={"cover_pattern": ""}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["coverPattern"] is None


def test_update_notebook_cover_pattern_preserved_when_not_sent(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Keep", "cover_pattern": "dots"}, headers=h).json()["id"]

    r = client.patch(f"/api/notebooks/{nb_id}", json={"name": "Renamed"}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["coverPattern"] == "dots"


# ---------------------------------------------------------------------------
# Lifecycle: duplicate name / delete-with-cards / rename id stability
# ---------------------------------------------------------------------------


def test_create_notebook_duplicate_name(isolated_api):
    """Two notebooks with the same name for one user.

    Contract: the API does NOT enforce name uniqueness or dedup — each POST
    creates a distinct notebook with its own id. Both appear in the listing.
    """
    client = isolated_api.client
    h = isolated_api.headers

    r1 = client.post("/api/notebooks", json={"name": "Duplicate", "color": "#111111"}, headers=h)
    r2 = client.post("/api/notebooks", json={"name": "Duplicate", "color": "#222222"}, headers=h)
    assert r1.status_code == 201, r1.text
    assert r2.status_code == 201, r2.text

    id1, id2 = r1.json()["id"], r2.json()["id"]
    assert id1 != id2, "duplicate-named notebooks must still get distinct ids"

    r_list = client.get("/api/notebooks", headers=h)
    listed = r_list.json()
    dup_named = [nb for nb in listed if nb["name"] == "Duplicate"]
    assert len(dup_named) == 2
    assert {id1, id2}.issubset(_nb_ids(listed))


def test_delete_notebook_with_cards(isolated_api):
    """Deleting a notebook holding cards cascades a soft-delete to those cards.

    Contract: delete is NOT blocked by card presence; cardsDeleted reflects the
    cascade count and the cards no longer surface under their old notebook.
    """
    client = isolated_api.client
    h = isolated_api.headers

    nb_id = client.post("/api/notebooks", json={"name": "HasCards", "color": "#abcdef"}, headers=h).json()["id"]

    client.post(
        "/api/vocab",
        json=[{"word": "cat", "translation": "貓"}],
        params={"notebook_id": nb_id},
        headers=h,
    )
    client.post(
        "/api/vocab",
        json=[{"word": "dog", "translation": "狗"}],
        params={"notebook_id": nb_id},
        headers=h,
    )

    r_before = client.get("/api/vocab", params={"notebook_id": nb_id}, headers=h)
    assert len(r_before.json()) == 2, "cards should exist before delete"

    r_del = client.delete(f"/api/notebooks/{nb_id}", headers=h)
    assert r_del.status_code == 200, r_del.text
    assert r_del.json()["cardsDeleted"] == 2, "delete must cascade to all cards"

    # Cards are hard-deleted with the notebook, not reassigned to default.
    r_default = client.get("/api/vocab", params={"notebook_id": "default"}, headers=h)
    default_words = [c["content"] for c in r_default.json()]
    assert "cat" not in default_words
    assert "dog" not in default_words


def test_rename_notebook_keeps_id_stable(isolated_api):
    """Renaming a notebook mutates the name in place but keeps its id.

    Contract: the id is the primary key — a rename must not break a client's
    cached activeNotebookId. The renamed notebook still appears in the listing
    under the same id.
    """
    client = isolated_api.client
    h = isolated_api.headers

    r_create = client.post("/api/notebooks", json={"name": "Before", "color": "#0a0a0a"}, headers=h)
    nb_id = r_create.json()["id"]

    r_patch = client.patch(f"/api/notebooks/{nb_id}", json={"name": "After"}, headers=h)
    assert r_patch.status_code == 200, r_patch.text
    assert r_patch.json()["id"] == nb_id, "rename must not change the id"
    assert r_patch.json()["name"] == "After"

    r_list = client.get("/api/notebooks", headers=h)
    matched = [nb for nb in r_list.json() if nb["id"] == nb_id]
    assert len(matched) == 1
    assert matched[0]["name"] == "After"
    assert nb_id in _nb_ids(r_list.json())


def test_delete_idempotent(isolated_api):
    """Second delete on an already-deleted notebook returns 200 with cardsDeleted=0.

    store.delete returns None when notebook is already soft-deleted;
    the router treats None as idempotent success (not False → no 400).
    """
    client = isolated_api.client
    h = isolated_api.headers

    nb_id = client.post("/api/notebooks", json={"name": "Idempotent", "color": "#abc123"}, headers=h).json()["id"]

    r1 = client.delete(f"/api/notebooks/{nb_id}", headers=h)
    assert r1.status_code == 200, r1.text

    r2 = client.delete(f"/api/notebooks/{nb_id}", headers=h)
    assert r2.status_code == 200, r2.text
    assert r2.json()["deleted"] == nb_id
    assert r2.json()["cardsDeleted"] == 0


def test_patch_notebook_settings_rejects_far_future_updated_at_then_accepts_current(isolated_api):
    client = isolated_api.client
    h = isolated_api.headers
    nb_id = client.post("/api/notebooks", json={"name": "Skew"}, headers=h).json()["id"]
    url = f"/api/notebooks/{nb_id}/settings"

    rejected = client.patch(
        url,
        json={"reviewPolicy": {"value": _review_policy(), "updatedAt": 4e9}},
        headers=h,
    )
    assert rejected.status_code == 422, rejected.text

    now = time.time()
    accepted = client.patch(
        url,
        json={"reviewPolicy": {"value": _review_policy(), "updatedAt": now}},
        headers=h,
    )
    assert accepted.status_code == 200, accepted.text
    assert accepted.json()["settings"]["reviewPolicy"]["updatedAt"] == now

    within = client.patch(
        url,
        json={"cardLayout": {"value": _card_layout(), "updatedAt": now + 3600}},
        headers=h,
    )
    assert within.status_code == 200, within.text


def test_list_notebooks_exposes_server_created_at(isolated_api):
    """#3677：server 建立時間隨列表回傳，iOS 才能以它做「手動排序」的 tie-break，跨裝置一致。"""
    client = isolated_api.client
    h = isolated_api.headers

    created = client.post("/api/notebooks", json={"name": "Stamped"}, headers=h).json()
    body = client.get("/api/notebooks", headers=h).json()

    nb = next(nb for nb in body if nb["id"] == created["id"])
    assert isinstance(nb["createdAt"], str)
    assert datetime.fromisoformat(nb["createdAt"]).tzinfo is not None
