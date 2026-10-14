"""Contract tests for library router.

Covers: GET /api/library/books, POST /api/library/books,
PATCH /api/library/books/{book_id}, PUT /api/library/books/{book_id}/position.
"""

from __future__ import annotations

import json
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event

import kg.api as api_mod
import kg.deps as deps_mod
from conftest import TEST_JWT_SECRET, _swap_settings, make_jwt
from kg.api import app
from kg.api_models.library import BookCreateRequest
from kg.library.store import LibraryStore
from kg.settings import KGSettings


@pytest.fixture()
def isolated_api(tmp_path):
    data_dir = tmp_path
    (data_dir / "users").mkdir()
    user_id = "u_" + uuid.uuid4().hex[:8]
    users_file = data_dir / "users.json"
    users_file.write_text(json.dumps({user_id: {"config": {}}}))

    token = make_jwt(user_id)
    headers = {"Authorization": f"Bearer {token}"}

    original_settings = app.state.kg_settings
    original_load = app.state.load_users
    original_save = app.state.save_users

    test_settings = KGSettings(
        data_dir=data_dir,
        jwt_secret=TEST_JWT_SECRET,
    )
    _swap_settings(test_settings)

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
        app.state.kg_settings = original_settings
        app.state.load_users = original_load
        app.state.save_users = original_save


def _create_book(client, headers, title="Test Book", client_book_id=None):
    payload = {
        "client_book_id": client_book_id or f"cbid-{uuid.uuid4().hex[:8]}",
        "title": title,
        "author": "Test Author",
        "language": "en",
        "format": "epub",
    }
    resp = client.post("/api/library/books", json=payload, headers=headers)
    assert resp.status_code == 201
    return resp.json()


class TestListBooks:
    def test_empty_list(self, isolated_api):
        resp = isolated_api.client.get("/api/library/books", headers=isolated_api.headers)
        assert resp.status_code == 200
        assert resp.json() == []

    def test_list_returns_created_books(self, isolated_api):
        _create_book(isolated_api.client, isolated_api.headers, "Book A")
        _create_book(isolated_api.client, isolated_api.headers, "Book B")
        resp = isolated_api.client.get("/api/library/books", headers=isolated_api.headers)
        assert resp.status_code == 200
        data = resp.json()
        assert len(data) == 2
        titles = {d["title"] for d in data}
        assert titles == {"Book A", "Book B"}

    def test_list_with_since_filter(self, isolated_api):
        b1 = _create_book(isolated_api.client, isolated_api.headers, "Book A")
        since = b1["updated_at"]
        _create_book(isolated_api.client, isolated_api.headers, "Book B")
        resp = isolated_api.client.get("/api/library/books", headers=isolated_api.headers, params={"since": since})
        assert resp.status_code == 200
        data = resp.json()
        # Only Book B has updated_at > since (Book A's updated_at == since)
        assert len(data) >= 1
        assert any(d["title"] == "Book B" for d in data)

    def test_list_with_since_filter_accepts_naive_utc_and_timezone_offsets(self, isolated_api):
        book = _create_book(isolated_api.client, isolated_api.headers, "UTC Since")
        updated_at = datetime.fromisoformat(book["updated_at"].replace("Z", "+00:00"))
        before_update = updated_at - timedelta(seconds=1)
        since_values = (
            before_update.replace(tzinfo=None).isoformat(),
            before_update.astimezone(timezone(timedelta(hours=8))).isoformat(),
        )

        for since in since_values:
            resp = isolated_api.client.get(
                "/api/library/books",
                headers=isolated_api.headers,
                params={"since": since},
            )

            assert resp.status_code == 200, resp.text
            assert book["id"] in {item["id"] for item in resp.json()}

    def test_list_with_invalid_since_returns_bad_request(self, isolated_api):
        resp = isolated_api.client.get(
            "/api/library/books",
            headers=isolated_api.headers,
            params={"since": "not-a-timestamp"},
        )

        assert resp.status_code == 400
        assert resp.json() == {
            "code": "BadRequestError",
            "detail": "Invalid since timestamp",
        }

    def test_list_requires_auth(self, isolated_api):
        resp = isolated_api.client.get("/api/library/books")
        assert resp.status_code == 401


class TestCreateBook:
    def test_create_book(self, isolated_api):
        payload = {
            "client_book_id": "my-book-1",
            "title": "Atomic Habits",
            "author": "James Clear",
            "language": "en",
            "format": "epub",
        }
        resp = isolated_api.client.post("/api/library/books", json=payload, headers=isolated_api.headers)
        assert resp.status_code == 201
        data = resp.json()
        assert data["title"] == "Atomic Habits"
        assert data["author"] == "James Clear"
        assert data["client_book_id"] == "my-book-1"
        assert data["id"]
        assert "is_deleted" in data
        assert data["is_deleted"] is False

    def test_idempotent_via_client_book_id(self, isolated_api):
        payload = {
            "client_book_id": "same-id",
            "title": "First",
            "author": "A",
        }
        r1 = isolated_api.client.post("/api/library/books", json=payload, headers=isolated_api.headers)
        assert r1.status_code == 201
        id1 = r1.json()["id"]

        payload2 = {
            "client_book_id": "same-id",
            "title": "Second",
            "author": "B",
        }
        r2 = isolated_api.client.post("/api/library/books", json=payload2, headers=isolated_api.headers)
        assert r2.status_code == 201
        data2 = r2.json()
        # Should return existing book, not create new
        assert data2["id"] == id1
        assert data2["title"] == "First"  # Original title preserved

    def test_concurrent_create_is_idempotent(self, isolated_api):
        store = LibraryStore(isolated_api.data_dir / "users" / isolated_api.user_id / "library.db")
        request = BookCreateRequest(client_book_id="concurrent-book", title="Concurrent", format="epub")
        parties = 8
        start = threading.Barrier(parties)
        begin_gate = threading.Barrier(parties)
        lookup_gate = threading.Barrier(parties)
        state_lock = threading.Lock()
        state = {"begin_seen": False, "lookup_count": 0}

        def coordinate_create(conn, cursor, statement, parameters, context, executemany):
            normalized = " ".join(statement.lower().split())
            if normalized == "begin immediate":
                with state_lock:
                    state["begin_seen"] = True
                begin_gate.wait(timeout=10)
                return
            if normalized.startswith("select") and "client_book_id" in normalized:
                with state_lock:
                    old_code = not state["begin_seen"] and state["lookup_count"] < parties
                    if old_code:
                        state["lookup_count"] += 1
                if old_code:
                    lookup_gate.wait(timeout=10)

        event.listen(store.engine, "before_cursor_execute", coordinate_create)

        def create_book(_):
            start.wait(timeout=10)
            return store.create(request)

        try:
            with ThreadPoolExecutor(max_workers=parties) as executor:
                responses = list(executor.map(create_book, range(parties)))
            rows = store.all(include_deleted=True)
        finally:
            event.remove(store.engine, "before_cursor_execute", coordinate_create)
            store.close()

        assert len(responses) == parties
        assert len({response.id for response in responses}) == 1
        assert len(rows) == 1
        assert rows[0].client_book_id == "concurrent-book"

    def test_reused_client_book_id_after_delete_returns_live_book(self, isolated_api):
        c, h = isolated_api.client, isolated_api.headers
        old = _create_book(c, h, "Old", client_book_id="reused-id")
        pos_body = {"locator": "loc", "progression": 0.5, "updated_at": "2026-06-13T10:00:00Z"}
        assert c.put(f"/api/library/books/{old['id']}/position", json=pos_body, headers=h).status_code == 200
        assert c.delete(f"/api/library/books/{old['id']}", headers=h).status_code == 200

        new = _create_book(c, h, "New", client_book_id="reused-id")
        assert new["is_deleted"] is False
        assert new["id"] != old["id"]
        assert new["title"] == "New"
        assert new["locator"] is None
        assert new["progression"] is None
        assert c.patch(f"/api/library/books/{new['id']}", json={"title": "Renamed"}, headers=h).status_code == 200
        pos_body2 = {"locator": "loc2", "progression": 0.1, "updated_at": "2026-06-14T10:00:00Z"}
        assert c.put(f"/api/library/books/{new['id']}/position", json=pos_body2, headers=h).status_code == 200

        again = _create_book(c, h, "Again", client_book_id="reused-id")
        assert again["id"] == new["id"]

    def test_client_book_id_is_scoped_per_user(self, isolated_api):
        first_store = LibraryStore(isolated_api.data_dir / "users" / isolated_api.user_id / "library.db")
        second_store = LibraryStore(isolated_api.data_dir / "users" / "other-user" / "library.db")
        request = BookCreateRequest(client_book_id="same-client-id", title="Per user", format="epub")
        try:
            first = first_store.create(request)
            second = second_store.create(request)
        finally:
            first_store.close()
            second_store.close()

        assert first.id != second.id

    def test_create_requires_auth(self, isolated_api):
        resp = isolated_api.client.post("/api/library/books", json={"client_book_id": "x", "title": "X"})
        assert resp.status_code == 401


class TestUpdateBook:
    def test_update_title_and_author(self, isolated_api):
        b = _create_book(isolated_api.client, isolated_api.headers, "Old Title")
        book_id = b["id"]
        resp = isolated_api.client.patch(
            f"/api/library/books/{book_id}",
            json={"title": "New Title", "author": "New Author"},
            headers=isolated_api.headers,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["title"] == "New Title"
        assert data["author"] == "New Author"
        assert data["id"] == book_id

    def test_update_notebook_binding(self, isolated_api):
        b = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = b["id"]
        owned = isolated_api.client.post(
            "/api/notebooks",
            json={"name": "Reading"},
            headers=isolated_api.headers,
        )
        assert owned.status_code == 201
        resp = isolated_api.client.patch(
            f"/api/library/books/{book_id}",
            json={"notebook_id": owned.json()["id"]},
            headers=isolated_api.headers,
        )
        assert resp.status_code == 200
        assert resp.json()["notebook_id"] == owned.json()["id"]

    def test_update_notebook_binding_accepts_default_notebook(self, isolated_api):
        b = _create_book(isolated_api.client, isolated_api.headers, "Book")
        resp = isolated_api.client.patch(
            f"/api/library/books/{b['id']}",
            json={"notebook_id": "default"},
            headers=isolated_api.headers,
        )
        assert resp.status_code == 200
        assert resp.json()["notebook_id"] == "default"

    @pytest.mark.parametrize("notebook_kind", ["unknown", "deleted", "foreign"])
    def test_update_notebook_binding_rejects_invalid_without_persisting(self, isolated_api, notebook_kind):
        b = _create_book(isolated_api.client, isolated_api.headers, "Book")
        if notebook_kind == "unknown":
            notebook_id = "nb-does-not-exist"
        elif notebook_kind == "deleted":
            created = isolated_api.client.post(
                "/api/notebooks",
                json={"name": "Deleted"},
                headers=isolated_api.headers,
            )
            assert created.status_code == 201
            notebook_id = created.json()["id"]
            deleted = isolated_api.client.delete(f"/api/notebooks/{notebook_id}", headers=isolated_api.headers)
            assert deleted.status_code == 200
        else:
            from kg.notebook import NotebookStore

            foreign_dir = isolated_api.data_dir / "users" / "foreign-user"
            foreign = NotebookStore(foreign_dir / "notebooks.db").create("Foreign")
            notebook_id = foreign.id

        resp = isolated_api.client.patch(
            f"/api/library/books/{b['id']}",
            json={"notebook_id": notebook_id},
            headers=isolated_api.headers,
        )
        assert resp.status_code == 403

        unchanged = isolated_api.client.get("/api/library/books", headers=isolated_api.headers)
        assert unchanged.status_code == 200
        assert unchanged.json()[0]["notebook_id"] is None

    def test_update_unknown_book_with_invalid_notebook_preserves_not_found(self, isolated_api):
        resp = isolated_api.client.patch(
            "/api/library/books/nonexistent",
            json={"notebook_id": "nb-does-not-exist"},
            headers=isolated_api.headers,
        )
        assert resp.status_code == 404

    def test_update_no_fields_raises_400(self, isolated_api):
        b = _create_book(isolated_api.client, isolated_api.headers, "Book")
        resp = isolated_api.client.patch(
            f"/api/library/books/{b['id']}",
            json={},
            headers=isolated_api.headers,
        )
        assert resp.status_code == 400

    def test_update_not_found(self, isolated_api):
        resp = isolated_api.client.patch(
            "/api/library/books/nonexistent",
            json={"title": "X"},
            headers=isolated_api.headers,
        )
        assert resp.status_code == 404

    def test_update_rejects_deleted_book_without_mutating_tombstone(self, isolated_api):
        book = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = book["id"]

        deleted = isolated_api.client.delete(
            f"/api/library/books/{book_id}",
            headers=isolated_api.headers,
        )
        assert deleted.status_code == 200
        before_delete_retry = isolated_api.client.get(
            "/api/library/books",
            headers=isolated_api.headers,
        ).json()[0]
        deleted_again = isolated_api.client.delete(
            f"/api/library/books/{book_id}",
            headers=isolated_api.headers,
        )
        assert deleted_again.status_code == 200
        after_delete_retry = isolated_api.client.get(
            "/api/library/books",
            headers=isolated_api.headers,
        ).json()[0]
        assert after_delete_retry == before_delete_retry

        before = after_delete_retry
        mutation = isolated_api.client.patch(
            f"/api/library/books/{book_id}",
            json={"title": "Changed tombstone"},
            headers=isolated_api.headers,
        )

        assert mutation.status_code == 404
        assert mutation.json()["code"] == "NotFoundError"
        after = isolated_api.client.get(
            "/api/library/books",
            headers=isolated_api.headers,
        ).json()[0]
        assert after == before

    def test_update_requires_auth(self, isolated_api):
        resp = isolated_api.client.patch("/api/library/books/abc", json={"title": "X"})
        assert resp.status_code == 401


class TestPutPosition:
    def test_put_position(self, isolated_api):
        b = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = b["id"]
        resp = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={"locator": "epubcfi(/6/2[id4]!/4/1:0)", "progression": 0.42, "updated_at": "2026-06-13T10:00:00Z"},
            headers=isolated_api.headers,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["locator"] == "epubcfi(/6/2[id4]!/4/1:0)"
        assert data["progression"] == 0.42
        assert data["position_updated_at"] == "2026-06-13T10:00:00Z"

    def test_put_position_ignores_stale_timestamp(self, isolated_api):
        b = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = b["id"]

        newer = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "newer-locator",
                "progression": 0.75,
                "updated_at": "2026-06-13T12:00:00Z",
            },
            headers=isolated_api.headers,
        )
        assert newer.status_code == 200

        stale = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "stale-locator",
                "progression": 0.25,
                "updated_at": "2026-06-13T11:00:00Z",
            },
            headers=isolated_api.headers,
        )
        assert stale.status_code == 200
        assert stale.json()["locator"] == "newer-locator"
        assert stale.json()["progression"] == 0.75
        assert stale.json()["position_updated_at"] == "2026-06-13T12:00:00Z"

    def test_put_position_does_not_allow_stale_request_to_overwrite_newer_write(self, isolated_api, monkeypatch):
        b = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = b["id"]
        stale_timestamp = "2026-06-13T11:00:00Z"
        newer_timestamp = "2026-06-13T12:00:00Z"

        stale_read = threading.Event()
        allow_stale = threading.Event()
        from kg.library import store as library_store

        original_parse = library_store._parse_utc_instant

        def pause_stale_request(value):
            parsed = original_parse(value)
            if value == stale_timestamp:
                stale_read.set()
                assert allow_stale.wait(timeout=5)
            return parsed

        monkeypatch.setattr(library_store, "_parse_utc_instant", pause_stale_request)

        stale_payload = {
            "locator": "stale-locator",
            "progression": 0.25,
            "updated_at": stale_timestamp,
        }
        with ThreadPoolExecutor(max_workers=1) as executor:
            stale_future = executor.submit(
                isolated_api.client.put,
                f"/api/library/books/{book_id}/position",
                json=stale_payload,
                headers=isolated_api.headers,
            )
            assert stale_read.wait(timeout=5)

            newer = isolated_api.client.put(
                f"/api/library/books/{book_id}/position",
                json={
                    "locator": "newer-locator",
                    "progression": 0.75,
                    "updated_at": newer_timestamp,
                },
                headers=isolated_api.headers,
            )
            assert newer.status_code == 200
            allow_stale.set()
            stale = stale_future.result(timeout=5)

        assert stale.status_code == 200
        assert stale.json()["locator"] == "newer-locator"
        assert stale.json()["progression"] == 0.75
        assert stale.json()["position_updated_at"] == newer_timestamp

    def test_put_position_treats_equivalent_timezone_offsets_as_equal(self, isolated_api):
        b = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = b["id"]

        first = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "first-locator",
                "progression": 0.5,
                "updated_at": "2026-06-13T13:00:00Z",
            },
            headers=isolated_api.headers,
        )
        assert first.status_code == 200

        equivalent = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "equivalent-locator",
                "progression": 0.6,
                "updated_at": "2026-06-13T14:00:00+02:00",
            },
            headers=isolated_api.headers,
        )
        assert equivalent.status_code == 200
        assert equivalent.json()["locator"] == "first-locator"
        assert equivalent.json()["progression"] == 0.5
        assert equivalent.json()["position_updated_at"] == "2026-06-13T13:00:00Z"

    def test_put_position_applies_newer_instant_across_timezone_offsets(self, isolated_api):
        b = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = b["id"]

        first = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "first-locator",
                "progression": 0.5,
                "updated_at": "2026-06-13T14:00:00+02:00",
            },
            headers=isolated_api.headers,
        )
        assert first.status_code == 200

        newer = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "newer-locator",
                "progression": 0.7,
                "updated_at": "2026-06-13T13:00:00Z",
            },
            headers=isolated_api.headers,
        )
        assert newer.status_code == 200
        assert newer.json()["locator"] == "newer-locator"
        assert newer.json()["progression"] == 0.7
        assert newer.json()["position_updated_at"] == "2026-06-13T13:00:00Z"

    def test_put_position_rejects_older_instant_across_timezone_offsets(self, isolated_api):
        b = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = b["id"]

        first = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "newer-locator",
                "progression": 0.7,
                "updated_at": "2026-06-13T13:00:00Z",
            },
            headers=isolated_api.headers,
        )
        assert first.status_code == 200

        older = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "older-locator",
                "progression": 0.2,
                "updated_at": "2026-06-13T14:00:00+03:00",
            },
            headers=isolated_api.headers,
        )
        assert older.status_code == 200
        assert older.json()["locator"] == "newer-locator"
        assert older.json()["progression"] == 0.7
        assert older.json()["position_updated_at"] == "2026-06-13T13:00:00Z"

    def test_put_position_not_found(self, isolated_api):
        resp = isolated_api.client.put(
            "/api/library/books/nonexistent/position",
            json={"locator": "x", "progression": 0.1, "updated_at": "2026-06-13T10:00:00Z"},
            headers=isolated_api.headers,
        )
        assert resp.status_code == 404

    def test_put_position_rejects_invalid_timestamp_without_mutating_position(self, isolated_api):
        book = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = book["id"]
        initial = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "initial-locator",
                "progression": 0.25,
                "updated_at": "2026-06-13T10:00:00Z",
            },
            headers=isolated_api.headers,
        )
        assert initial.status_code == 200
        before = isolated_api.client.get(
            "/api/library/books",
            headers=isolated_api.headers,
        ).json()[0]

        invalid = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "invalid-locator",
                "progression": 0.75,
                "updated_at": "not-an-iso-timestamp",
            },
            headers=isolated_api.headers,
        )

        assert invalid.status_code == 400
        assert invalid.json() == {
            "code": "BadRequestError",
            "detail": "Invalid updated_at timestamp",
        }
        after = isolated_api.client.get(
            "/api/library/books",
            headers=isolated_api.headers,
        ).json()[0]
        assert after == before

    def test_put_position_rejects_far_future_updated_at_without_pinning(self, isolated_api):
        book = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = book["id"]

        far = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={"locator": "far", "progression": 0.9, "updated_at": "9999-12-31T23:59:59+00:00"},
            headers=isolated_api.headers,
        )
        assert far.status_code == 422

        current = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "current",
                "progression": 0.2,
                "updated_at": datetime.now(UTC).isoformat(),
            },
            headers=isolated_api.headers,
        )
        assert current.status_code == 200
        assert current.json()["locator"] == "current"
        assert current.json()["progression"] == 0.2

    def test_put_position_rejects_deleted_book_without_mutating_tombstone(self, isolated_api):
        book = _create_book(isolated_api.client, isolated_api.headers, "Book")
        book_id = book["id"]
        initial_position = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "before-delete",
                "progression": 0.25,
                "updated_at": "2026-06-13T10:00:00Z",
            },
            headers=isolated_api.headers,
        )
        assert initial_position.status_code == 200

        deleted = isolated_api.client.delete(
            f"/api/library/books/{book_id}",
            headers=isolated_api.headers,
        )
        assert deleted.status_code == 200
        before_delete_retry = isolated_api.client.get(
            "/api/library/books",
            headers=isolated_api.headers,
        ).json()[0]
        deleted_again = isolated_api.client.delete(
            f"/api/library/books/{book_id}",
            headers=isolated_api.headers,
        )
        assert deleted_again.status_code == 200
        after_delete_retry = isolated_api.client.get(
            "/api/library/books",
            headers=isolated_api.headers,
        ).json()[0]
        assert after_delete_retry == before_delete_retry

        before = after_delete_retry
        mutation = isolated_api.client.put(
            f"/api/library/books/{book_id}/position",
            json={
                "locator": "changed-tombstone",
                "progression": 0.75,
                "updated_at": "2026-06-13T11:00:00Z",
            },
            headers=isolated_api.headers,
        )

        assert mutation.status_code == 404
        assert mutation.json()["code"] == "NotFoundError"
        after = isolated_api.client.get(
            "/api/library/books",
            headers=isolated_api.headers,
        ).json()[0]
        assert after == before

    def test_put_position_requires_auth(self, isolated_api):
        resp = isolated_api.client.put(
            "/api/library/books/abc/position",
            json={"locator": "x", "progression": 0.1, "updated_at": "2026-06-13T10:00:00Z"},
        )
        assert resp.status_code == 401
