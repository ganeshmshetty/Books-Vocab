"""Contract tests for book asset endpoints (Architecture PR #7).

POST /api/library/books/{book_id}/asset-upload  -> request an object-storage
upload target OR declare a local-only asset.
GET  /api/library/books/{book_id}/asset         -> download / redirect to the
authorized asset URL.

Storage backend is env-gated exactly like podcast media: when `library_bucket`
is configured, the upload endpoint mints a presigned PUT target and download
redirects (307) to a presigned GET; when unset (dev / local-only), the asset is
declared local-only and download returns 409 (not server-hosted).

All write/read paths run through the SAME per-user LibraryStore (library.db)
that create/list/patch/position/delete use — no bypass store.
"""

from __future__ import annotations

import json
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
        yield SimpleNamespace(
            client=TestClient(app, raise_server_exceptions=False),
            user_id=user_id,
            headers=headers,
            data_dir=data_dir,
        )
    finally:
        app.state.kg_settings = original_settings
        app.state.load_users = original_load
        app.state.save_users = original_save


def _seed_book(api, client_book_id: str = "book-1", title: str = "Pride and Prejudice"):
    resp = api.client.post(
        "/api/library/books",
        json={"client_book_id": client_book_id, "title": title, "format": "epub"},
        headers=api.headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


def _set_fake_object_storage_credentials(monkeypatch) -> None:
    """Keep presign tests independent of a developer or CI AWS session."""
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "kg-test-access-key")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "kg-test-secret-key")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "kg-test-session-token")
    monkeypatch.setenv("AWS_EC2_METADATA_DISABLED", "true")


# ---------------------------------------------------------------------------
# asset-upload
# ---------------------------------------------------------------------------


def test_asset_upload_local_only_when_no_bucket(isolated_api):
    """No bucket configured -> server declares the asset local-only (no URL)."""
    book_id = _seed_book(isolated_api)
    r = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 1024},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["storage"] == "local"
    assert body["upload_url"] is None
    assert body["book_id"] == book_id


def test_asset_upload_respects_explicit_local_only_flag(isolated_api):
    book_id = _seed_book(isolated_api)
    r = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 2048, "local_only": True},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    assert r.json()["storage"] == "local"
    assert r.json()["upload_url"] is None


def test_asset_upload_unknown_book_returns_404(isolated_api):
    r = isolated_api.client.post(
        "/api/library/books/nope/asset-upload",
        json={"format": "epub", "byte_size": 10},
        headers=isolated_api.headers,
    )
    assert r.status_code == 404, r.text


def test_asset_upload_requires_auth(isolated_api):
    book_id = _seed_book(isolated_api)
    r = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 10},
    )
    assert r.status_code == 401, r.text


def test_asset_upload_rejects_oversize_asset(isolated_api):
    """Quota policy: an absurdly large asset is rejected with 400."""
    book_id = _seed_book(isolated_api)
    huge = 5 * 1024 * 1024 * 1024  # 5 GiB, well over any per-asset cap
    r = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": huge},
        headers=isolated_api.headers,
    )
    assert r.status_code == 400, r.text


def test_asset_upload_object_storage_when_bucket_configured(isolated_api, monkeypatch):
    """With a bucket configured, the endpoint mints a presigned PUT target and
    records the object key on the book row."""
    _set_fake_object_storage_credentials(monkeypatch)
    _swap_settings(
        KGSettings(
            data_dir=isolated_api.data_dir,
            jwt_secret=TEST_JWT_SECRET,
            library_bucket="kg-library-test",
        )
    )
    book_id = _seed_book(isolated_api, client_book_id="obj-1")
    r = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 4096},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["storage"] == "object"
    assert isinstance(body["upload_url"], str) and body["upload_url"]
    assert body["object_key"] and book_id in body["object_key"]


# ---------------------------------------------------------------------------
# asset download
# ---------------------------------------------------------------------------


def test_asset_download_local_only_returns_409(isolated_api):
    """A book whose asset is local-only is not server-hosted -> 409."""
    book_id = _seed_book(isolated_api)
    # Declare local-only first.
    isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 10, "local_only": True},
        headers=isolated_api.headers,
    )
    r = isolated_api.client.get(f"/api/library/books/{book_id}/asset", headers=isolated_api.headers)
    assert r.status_code == 409, r.text


def test_asset_download_unknown_book_returns_404(isolated_api):
    r = isolated_api.client.get("/api/library/books/nope/asset", headers=isolated_api.headers)
    assert r.status_code == 404, r.text


def test_asset_download_requires_auth(isolated_api):
    book_id = _seed_book(isolated_api)
    r = isolated_api.client.get(f"/api/library/books/{book_id}/asset")
    assert r.status_code == 401, r.text


def test_asset_download_redirects_to_presigned_url_when_object_stored(isolated_api, monkeypatch):
    """After the object is actually uploaded, download issues a 307 to a
    presigned GET URL."""
    _set_fake_object_storage_credentials(monkeypatch)
    _swap_settings(
        KGSettings(
            data_dir=isolated_api.data_dir,
            jwt_secret=TEST_JWT_SECRET,
            library_bucket="kg-library-test",
        )
    )
    import kg.routers.library as library_router

    class FakeS3Client:
        def generate_presigned_url(self, operation, *, Params, ExpiresIn):
            return "https://storage.test/presigned"

        def head_object(self, *, Bucket, Key):
            return {"ContentLength": 4096}

    monkeypatch.setattr(library_router, "_library_s3_client", lambda settings: FakeS3Client())
    book_id = _seed_book(isolated_api, client_book_id="obj-dl-1")
    up = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 4096},
        headers=isolated_api.headers,
    )
    assert up.status_code == 200, up.text
    r = isolated_api.client.get(
        f"/api/library/books/{book_id}/asset",
        headers=isolated_api.headers,
        follow_redirects=False,
    )
    assert r.status_code == 307, r.text
    assert r.headers["location"]


# ---------------------------------------------------------------------------
# format allow-list at the request boundary (Issue #1187)
# ---------------------------------------------------------------------------

_LEGAL_FORMATS = ["epub", "pdf", "txt", "md"]
_ILLEGAL_FORMATS = ["exe", "EPUB", "docx", ""]


@pytest.mark.parametrize("fmt", _ILLEGAL_FORMATS)
def test_book_create_rejects_unsupported_format(isolated_api, fmt):
    r = isolated_api.client.post(
        "/api/library/books",
        json={"client_book_id": "bad-1", "title": "Bad", "format": fmt},
        headers=isolated_api.headers,
    )
    assert r.status_code == 422, r.text
    listing = isolated_api.client.get("/api/library/books", headers=isolated_api.headers)
    assert listing.status_code == 200, listing.text
    assert "bad-1" not in json.dumps(listing.json())


@pytest.mark.parametrize("fmt", _ILLEGAL_FORMATS)
def test_book_update_rejects_unsupported_format(isolated_api, fmt):
    book_id = _seed_book(isolated_api)
    r = isolated_api.client.patch(
        f"/api/library/books/{book_id}",
        json={"format": fmt},
        headers=isolated_api.headers,
    )
    assert r.status_code == 422, r.text
    listing = isolated_api.client.get("/api/library/books", headers=isolated_api.headers)
    assert [b["format"] for b in listing.json()] == ["epub"]


@pytest.mark.parametrize("fmt", _ILLEGAL_FORMATS)
def test_asset_upload_rejects_unsupported_format_without_metadata(isolated_api, fmt):
    book_id = _seed_book(isolated_api)
    r = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": fmt, "byte_size": 10},
        headers=isolated_api.headers,
    )
    assert r.status_code == 422, r.text
    dl = isolated_api.client.get(f"/api/library/books/{book_id}/asset", headers=isolated_api.headers)
    assert dl.status_code == 409, dl.text  # no asset metadata was recorded


@pytest.mark.parametrize("fmt", _LEGAL_FORMATS)
def test_legal_formats_succeed_on_all_three_models(isolated_api, fmt):
    created = isolated_api.client.post(
        "/api/library/books",
        json={"client_book_id": f"ok-{fmt}", "title": "Ok", "format": fmt},
        headers=isolated_api.headers,
    )
    assert created.status_code == 201, created.text
    book_id = created.json()["id"]
    patched = isolated_api.client.patch(
        f"/api/library/books/{book_id}",
        json={"format": fmt},
        headers=isolated_api.headers,
    )
    assert patched.status_code == 200, patched.text
    up = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": fmt, "byte_size": 10},
        headers=isolated_api.headers,
    )
    assert up.status_code == 200, up.text


class _RecordingS3:
    """Fake S3 client that records presigns and deletes."""

    def __init__(self):
        self.deleted: list[tuple[str, str]] = []

    def generate_presigned_url(self, operation, *, Params, ExpiresIn):
        return f"https://storage.test/{Params['Key']}"

    def delete_object(self, *, Bucket, Key):
        self.deleted.append((Bucket, Key))
        return {}


def _bucket_settings(api):
    _swap_settings(
        KGSettings(
            data_dir=api.data_dir,
            jwt_secret=TEST_JWT_SECRET,
            library_bucket="kg-library-test",
        )
    )


def _upload(api, book_id, fmt, *, local_only=False):
    resp = api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": fmt, "byte_size": 10, "local_only": local_only},
        headers=api.headers,
    )
    assert resp.status_code == 200, resp.text
    return resp


def _pending_keys(api) -> list[str]:
    from kg.library.store import LibraryStore

    store = LibraryStore(api.data_dir / "users" / api.user_id / "library.db")
    try:
        return store.pending_object_keys()
    finally:
        store.close()


class _FailingS3(_RecordingS3):
    """Fake S3 client whose delete always fails, with a botocore-style message that
    embeds the request URL (and so the object key) like a real endpoint error."""

    def delete_object(self, *, Bucket, Key):
        raise RuntimeError(f"Could not connect to the endpoint URL: https://{Bucket}.s3.example/{Key}")


class _MissingObjectS3(_RecordingS3):
    """Fake S3 client whose delete reports the object as already gone."""

    class exceptions:  # noqa: N801 - mirrors boto3 client.exceptions
        class NoSuchKey(Exception):
            pass

    def delete_object(self, *, Bucket, Key):
        raise self.exceptions.NoSuchKey(Key)


def _setup(api, monkeypatch, s3):
    import kg.routers.library as library_router

    monkeypatch.setattr(library_router, "_library_s3_client", lambda settings, **_kw: s3)
    _bucket_settings(api)


def test_soft_delete_deletes_stored_object(isolated_api, monkeypatch):
    s3 = _RecordingS3()
    _setup(isolated_api, monkeypatch, s3)
    book_id = _seed_book(isolated_api, client_book_id="del-1")
    key = _upload(isolated_api, book_id, "epub").json()["object_key"]

    resp = isolated_api.client.delete(f"/api/library/books/{book_id}", headers=isolated_api.headers)

    assert resp.status_code == 200, resp.text
    assert s3.deleted == [("kg-library-test", key)]
    assert _pending_keys(isolated_api) == []


def test_repeated_soft_delete_deletes_object_once(isolated_api, monkeypatch):
    s3 = _RecordingS3()
    _setup(isolated_api, monkeypatch, s3)
    book_id = _seed_book(isolated_api, client_book_id="del-2")
    key = _upload(isolated_api, book_id, "epub").json()["object_key"]

    for _ in range(2):
        resp = isolated_api.client.delete(f"/api/library/books/{book_id}", headers=isolated_api.headers)
        assert resp.status_code == 200, resp.text

    assert s3.deleted == [("kg-library-test", key)]


def test_soft_delete_survives_delete_failure_and_keeps_key_pending(isolated_api, monkeypatch, caplog):
    _setup(isolated_api, monkeypatch, _FailingS3())
    book_id = _seed_book(isolated_api, client_book_id="del-3")
    key = _upload(isolated_api, book_id, "epub").json()["object_key"]

    with caplog.at_level("WARNING"):
        resp = isolated_api.client.delete(f"/api/library/books/{book_id}", headers=isolated_api.headers)

    assert resp.status_code == 200, resp.text
    assert "library object delete failed" in caplog.text
    # The key embeds the user and book ids; neither the message nor any traceback may carry it.
    assert key not in caplog.text
    assert _pending_keys(isolated_api) == [key]


def test_format_change_deletes_previous_key(isolated_api, monkeypatch):
    s3 = _RecordingS3()
    _setup(isolated_api, monkeypatch, s3)
    book_id = _seed_book(isolated_api, client_book_id="fmt-1")
    old_key = _upload(isolated_api, book_id, "epub").json()["object_key"]
    new_key = _upload(isolated_api, book_id, "pdf").json()["object_key"]

    assert new_key != old_key
    assert s3.deleted == [("kg-library-test", old_key)]
    assert _pending_keys(isolated_api) == []


def test_same_key_reupload_deletes_nothing(isolated_api, monkeypatch):
    s3 = _RecordingS3()
    _setup(isolated_api, monkeypatch, s3)
    book_id = _seed_book(isolated_api, client_book_id="same-1")
    _upload(isolated_api, book_id, "epub")
    _upload(isolated_api, book_id, "epub")

    assert s3.deleted == []
    assert _pending_keys(isolated_api) == []


def test_local_only_change_deletes_previous_key(isolated_api, monkeypatch):
    s3 = _RecordingS3()
    _setup(isolated_api, monkeypatch, s3)
    book_id = _seed_book(isolated_api, client_book_id="local-1")
    old_key = _upload(isolated_api, book_id, "epub").json()["object_key"]
    _upload(isolated_api, book_id, "epub", local_only=True)

    assert s3.deleted == [("kg-library-test", old_key)]
    assert _pending_keys(isolated_api) == []


def test_format_change_survives_delete_failure_and_retries_next_request(isolated_api, monkeypatch):
    failing = _FailingS3()
    _setup(isolated_api, monkeypatch, failing)
    book_id = _seed_book(isolated_api, client_book_id="retry-1")
    old_key = _upload(isolated_api, book_id, "epub").json()["object_key"]
    _upload(isolated_api, book_id, "pdf")
    assert _pending_keys(isolated_api) == [old_key]

    s3 = _RecordingS3()
    _setup(isolated_api, monkeypatch, s3)
    _upload(isolated_api, book_id, "pdf")

    assert s3.deleted == [("kg-library-test", old_key)]
    assert _pending_keys(isolated_api) == []


def test_reusing_recorded_key_clears_it_from_ledger(isolated_api, monkeypatch):
    _setup(isolated_api, monkeypatch, _FailingS3())
    book_id = _seed_book(isolated_api, client_book_id="reuse-1")
    _upload(isolated_api, book_id, "epub")
    _upload(isolated_api, book_id, "epub", local_only=True)
    assert len(_pending_keys(isolated_api)) == 1

    s3 = _RecordingS3()
    _setup(isolated_api, monkeypatch, s3)
    _upload(isolated_api, book_id, "epub")

    assert _pending_keys(isolated_api) == []
    assert s3.deleted == []


def test_account_erasure_reclaims_keys_left_pending_by_failed_deletes(isolated_api, monkeypatch):
    from kg.account_erasure import delete_account_assets

    _setup(isolated_api, monkeypatch, _FailingS3())
    book_id = _seed_book(isolated_api, client_book_id="erase-1")
    old_key = _upload(isolated_api, book_id, "epub").json()["object_key"]
    new_key = _upload(isolated_api, book_id, "pdf").json()["object_key"]
    isolated_api.client.delete(f"/api/library/books/{book_id}", headers=isolated_api.headers)

    s3 = _RecordingS3()
    reclaimed = delete_account_assets(
        isolated_api.data_dir,
        [isolated_api.user_id],
        library_bucket="kg-library-test",
        library_s3_client=s3,
    )

    assert set(reclaimed) == {old_key, new_key}
    assert {key for _, key in s3.deleted} == {old_key, new_key}


def test_account_erasure_succeeds_when_object_already_gone(isolated_api, monkeypatch):
    from kg.account_erasure import delete_account_assets

    s3 = _RecordingS3()
    _setup(isolated_api, monkeypatch, s3)
    book_id = _seed_book(isolated_api, client_book_id="erase-2")
    key = _upload(isolated_api, book_id, "epub").json()["object_key"]
    isolated_api.client.delete(f"/api/library/books/{book_id}", headers=isolated_api.headers)
    assert s3.deleted == [("kg-library-test", key)]
    s3 = _MissingObjectS3()

    reclaimed = delete_account_assets(
        isolated_api.data_dir,
        [isolated_api.user_id],
        library_bucket="kg-library-test",
        library_s3_client=s3,
    )

    assert key in reclaimed


def test_reclaim_is_bounded_per_request(isolated_api, monkeypatch):
    import kg.routers.library as library_router

    s3 = _RecordingS3()
    _setup(isolated_api, monkeypatch, _FailingS3())
    book_ids = [_seed_book(isolated_api, client_book_id=f"batch-{i}") for i in range(7)]
    for book_id in book_ids:
        _upload(isolated_api, book_id, "epub")
        _upload(isolated_api, book_id, "pdf")
    assert len(_pending_keys(isolated_api)) == 7

    _setup(isolated_api, monkeypatch, s3)
    _upload(isolated_api, book_ids[0], "pdf")

    assert len(s3.deleted) == library_router._RECLAIM_BATCH == 5
    assert len(_pending_keys(isolated_api)) == 2


def test_client_creation_failure_does_not_fail_request(isolated_api, monkeypatch):
    import kg.routers.library as library_router

    s3 = _RecordingS3()
    _setup(isolated_api, monkeypatch, s3)
    book_id = _seed_book(isolated_api, client_book_id="noclient-1")
    key = _upload(isolated_api, book_id, "epub").json()["object_key"]

    def _boom(settings, **_kw):
        raise RuntimeError("no credentials")

    monkeypatch.setattr(library_router, "_library_s3_client", _boom)
    resp = isolated_api.client.delete(f"/api/library/books/{book_id}", headers=isolated_api.headers)

    assert resp.status_code == 200, resp.text
    assert _pending_keys(isolated_api) == [key]
    # Released, not failed: no attempt counted, and the key is claimable again.
    from sqlmodel import Session

    from kg.library.store import LibraryPendingObjectDelete

    store = library_router._library_store(isolated_api.data_dir / "users" / isolated_api.user_id)
    with Session(store.engine) as session:
        assert session.get(LibraryPendingObjectDelete, key).attempts == 0
    assert [c.object_key for c in store.claim_pending_objects(5)] == [key]


def _store(api):
    from kg.library.store import LibraryStore

    return LibraryStore(api.data_dir / "users" / api.user_id / "library.db")


def test_claim_skips_and_clears_stale_row_for_live_key(isolated_api):
    """A ledger row left behind for a key a live book references (e.g. written from
    a stale snapshot) must be dropped without being claimed for deletion."""
    from sqlmodel import Session

    from kg.library.store import LibraryPendingObjectDelete

    book_id = _seed_book(isolated_api, client_book_id="race-1")
    store = _store(isolated_api)
    try:
        key = "library/u/race-1/asset.epub"
        store.set_asset(book_id, storage="object", object_key=key, byte_size=1, sha256=None)
        with Session(store.engine) as session:
            session.add(LibraryPendingObjectDelete(object_key=key, book_id=book_id))
            session.commit()
        assert store.pending_object_keys() == [key]

        assert store.claim_pending_objects(5) == []
        assert store.pending_object_keys() == []
    finally:
        store.close()


def _superseded_key(store, book_id: str, key: str) -> None:
    store.set_asset(book_id, storage="object", object_key=key, byte_size=1, sha256=None)
    store.set_asset(book_id, storage="local", object_key=None, byte_size=1, sha256=None)


def test_claimed_key_is_leased_and_cannot_be_readopted_until_finished(isolated_api):
    """While a delete is in flight outside the DB lock, the key is leased: a second
    claimer skips it and a re-adoption is refused, so the delete cannot remove
    freshly uploaded bytes."""
    from kg.exceptions import ConflictError

    book_id = _seed_book(isolated_api, client_book_id="race-2")
    store = _store(isolated_api)
    try:
        key = "library/u/race-2/asset.epub"
        _superseded_key(store, book_id, key)

        claims = store.claim_pending_objects(5)
        assert [c.object_key for c in claims] == [key]
        assert store.claim_pending_objects(5) == []
        with pytest.raises(ConflictError):
            store.set_asset(book_id, storage="object", object_key=key, byte_size=1, sha256=None)

        store.finish_pending_object(claims[0], deleted=True)
        assert store.pending_object_keys() == []
        store.set_asset(book_id, storage="object", object_key=key, byte_size=1, sha256=None)
        assert store.get(book_id).asset_object_key == key
    finally:
        store.close()


def test_failed_delete_releases_claim_and_counts_attempt(isolated_api):
    from sqlmodel import Session

    from kg.library.store import LibraryPendingObjectDelete

    book_id = _seed_book(isolated_api, client_book_id="fail-1")
    store = _store(isolated_api)
    try:
        key = "library/u/fail-1/asset.epub"
        _superseded_key(store, book_id, key)

        (claim,) = store.claim_pending_objects(5)
        store.finish_pending_object(claim, deleted=False)

        assert store.pending_object_keys() == [key]
        assert [c.object_key for c in store.claim_pending_objects(5)] == [key]
        with Session(store.engine) as session:
            row = session.get(LibraryPendingObjectDelete, key)
            assert row.attempts == 1
            assert row.last_attempt_at is not None
    finally:
        store.close()


def test_permanently_failing_keys_do_not_starve_untried_keys(isolated_api):
    """Five always-failing keys must not block a sixth: failures rotate to the back."""
    store = _store(isolated_api)
    try:
        keys = []
        for i in range(6):
            book_id = _seed_book(isolated_api, client_book_id=f"starve-{i}")
            key = f"library/u/starve-{i}/asset.epub"
            _superseded_key(store, book_id, key)
            keys.append(key)
        untried = sorted(keys)[-1]

        first = store.claim_pending_objects(5)
        assert untried not in [c.object_key for c in first]
        for claim in first:
            store.finish_pending_object(claim, deleted=False)

        second = store.claim_pending_objects(5)
        assert second[0].object_key == untried
    finally:
        store.close()


def test_stale_claim_cannot_touch_a_newer_lease(isolated_api):
    """A claimer whose lease expired must not clear or delete under a newer claim."""
    from datetime import UTC, datetime, timedelta

    from sqlmodel import Session

    from kg.library.store import LibraryPendingObjectDelete

    book_id = _seed_book(isolated_api, client_book_id="stale-1")
    store = _store(isolated_api)
    try:
        key = "library/u/stale-1/asset.epub"
        _superseded_key(store, book_id, key)
        (stale,) = store.claim_pending_objects(5)

        with Session(store.engine) as session:
            row = session.get(LibraryPendingObjectDelete, key)
            row.claimed_until = datetime.now(UTC) - timedelta(seconds=1)
            session.add(row)
            session.commit()
        (fresh,) = store.claim_pending_objects(5)
        assert fresh.object_key == key and fresh.token != stale.token

        store.finish_pending_object(stale, deleted=True)
        store.finish_pending_object(stale, deleted=False)
        store.release_pending_object(stale)

        assert store.pending_object_keys() == [key]
        assert store.claim_pending_objects(5) == []
    finally:
        store.close()


def test_expired_lease_can_be_readopted(isolated_api):
    """A claim whose holder died must not block re-adoption forever."""
    from datetime import UTC, datetime, timedelta

    from sqlmodel import Session

    from kg.library.store import LibraryPendingObjectDelete

    book_id = _seed_book(isolated_api, client_book_id="expired-1")
    store = _store(isolated_api)
    try:
        key = "library/u/expired-1/asset.epub"
        _superseded_key(store, book_id, key)
        store.claim_pending_objects(5)
        with Session(store.engine) as session:
            row = session.get(LibraryPendingObjectDelete, key)
            row.claimed_until = datetime.now(UTC) - timedelta(seconds=1)
            session.add(row)
            session.commit()

        store.set_asset(book_id, storage="object", object_key=key, byte_size=1, sha256=None)
        assert store.get(book_id).asset_object_key == key
        assert store.pending_object_keys() == []
    finally:
        store.close()


def test_release_returns_claim_without_counting_an_attempt(isolated_api):
    from sqlmodel import Session

    from kg.library.store import LibraryPendingObjectDelete

    book_id = _seed_book(isolated_api, client_book_id="release-1")
    store = _store(isolated_api)
    try:
        key = "library/u/release-1/asset.epub"
        _superseded_key(store, book_id, key)
        (claim,) = store.claim_pending_objects(5)
        store.release_pending_object(claim)

        assert [c.object_key for c in store.claim_pending_objects(5)] == [key]
        with Session(store.engine) as session:
            assert session.get(LibraryPendingObjectDelete, key).attempts == 0
    finally:
        store.close()


def test_set_asset_refuses_a_tombstoned_book(isolated_api):
    book_id = _seed_book(isolated_api, client_book_id="tomb-1")
    store = _store(isolated_api)
    try:
        store.soft_delete(book_id)
        assert (
            store.set_asset(
                book_id, storage="object", object_key="library/u/tomb-1/asset.epub", byte_size=1, sha256=None
            )
            is None
        )
        assert store.pending_object_keys() == []
    finally:
        store.close()


def test_racing_asset_changes_record_every_superseded_key(isolated_api):
    """A->B committing while A->C waits must leave both A and B in the ledger."""
    import threading

    from sqlmodel import Session

    from kg.library.store import LibraryBook

    book_id = _seed_book(isolated_api, client_book_id="race-3")
    store = _store(isolated_api)
    other = _store(isolated_api)
    try:
        key_a, key_b, key_c = (f"library/u/race-3/asset.{ext}" for ext in ("epub", "pdf", "txt"))
        store.set_asset(book_id, storage="object", object_key=key_a, byte_size=1, sha256=None)

        errors: list[BaseException] = []

        def to_c() -> None:
            try:
                other.set_asset(book_id, storage="object", object_key=key_c, byte_size=1, sha256=None)
            except BaseException as exc:  # pragma: no cover - failure path
                errors.append(exc)

        # Hold the write lock the way an in-flight A->B change does, start A->C,
        # then commit A->B.
        with Session(store.engine) as session:
            from kg.library.store import _lock_book, _record_pending_delete

            _lock_book(session, book_id)
            thread = threading.Thread(target=to_c)
            thread.start()
            thread.join(timeout=0.3)
            assert thread.is_alive(), "A->C should wait for the in-flight change"
            book = session.get(LibraryBook, book_id)
            _record_pending_delete(session, book_id, key_a)
            book.asset_object_key = key_b
            session.add(book)
            session.commit()
        thread.join(timeout=10)

        assert errors == []
        assert store.pending_object_keys() == sorted([key_a, key_b])
    finally:
        other.close()
        store.close()


# ---------------------------------------------------------------------------
# Upload target integrity (Issue #2525)
# ---------------------------------------------------------------------------


def _configure_bucket(api) -> None:
    _swap_settings(KGSettings(data_dir=api.data_dir, jwt_secret=TEST_JWT_SECRET, library_bucket="kg-library-test"))


def test_presigned_put_binds_declared_content_length(isolated_api, monkeypatch):
    """The presigned PUT must pin ContentLength to the declared byte_size so the
    quota check cannot be bypassed by uploading a larger body."""
    import kg.routers.library as library_router

    calls = []

    class FakeS3Client:
        def generate_presigned_url(self, operation, *, Params, ExpiresIn):
            calls.append((operation, Params))
            return "https://storage.test/presigned"

    monkeypatch.setattr(library_router, "_library_s3_client", lambda settings: FakeS3Client())
    _configure_bucket(isolated_api)
    book_id = _seed_book(isolated_api, client_book_id="cl-1")
    r = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 4096},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    assert calls[0][0] == "put_object"
    assert calls[0][1]["ContentLength"] == 4096


@pytest.mark.parametrize("sha", ["z" * 64, "abc", "g" * 64, " " * 64])
def test_asset_upload_rejects_non_hex_sha256(isolated_api, sha):
    book_id = _seed_book(isolated_api)
    r = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 10, "sha256": sha},
        headers=isolated_api.headers,
    )
    assert r.status_code == 422, r.text


def test_asset_upload_accepts_hex_sha256(isolated_api):
    book_id = _seed_book(isolated_api)
    r = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 10, "sha256": "aB" * 32},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text


def test_presigned_put_url_signs_content_length_with_real_client(isolated_api, monkeypatch):
    """#2525: the real boto client must emit SigV4 so Content-Length is a signed
    header; with SigV2 query auth a larger body would still be accepted."""
    from urllib.parse import parse_qs, urlparse

    _set_fake_object_storage_credentials(monkeypatch)
    _configure_bucket(isolated_api)
    book_id = _seed_book(isolated_api, client_book_id="cl-real")
    r = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 4096},
        headers=isolated_api.headers,
    )
    assert r.status_code == 200, r.text
    url = urlparse(r.json()["upload_url"])
    query = parse_qs(url.query)
    assert query["X-Amz-Algorithm"] == ["AWS4-HMAC-SHA256"]
    assert "content-length" in query["X-Amz-SignedHeaders"][0].split(";")
    assert url.netloc.startswith("kg-library-test.s3.") and url.netloc != "kg-library-test.s3.amazonaws.com"


def test_asset_upload_into_reclaim_lease_returns_retryable_409(isolated_api, monkeypatch):
    """#2959 item 1: set_asset colliding with an in-flight reclaim lease must surface
    as 409 from POST asset-upload (retryable), and must not re-adopt the leased key."""
    _setup(isolated_api, monkeypatch, _RecordingS3())
    book_id = _seed_book(isolated_api, client_book_id="lease-409")
    key = _upload(isolated_api, book_id, "epub").json()["object_key"]

    store = _store(isolated_api)
    try:
        store.set_asset(book_id, storage="local", object_key=None, byte_size=1, sha256=None)
        claims = store.claim_pending_objects(5)
        assert [c.object_key for c in claims] == [key]

        resp = isolated_api.client.post(
            f"/api/library/books/{book_id}/asset-upload",
            json={"format": "epub", "byte_size": 10},
            headers=isolated_api.headers,
        )
        assert resp.status_code == 409, resp.text
        assert store.get(book_id).asset_object_key is None

        store.finish_pending_object(claims[0], deleted=True)
    finally:
        store.close()


def test_concurrent_claimers_never_both_claim_the_same_key(isolated_api):
    """#2959 item 4: separate connections racing for one pending key on real threads;
    exactly one may win the claim (the earlier double-claim tests were sequential)."""
    import threading

    book_id = _seed_book(isolated_api, client_book_id="race-4")
    seed = _store(isolated_api)
    key = "library/u/race-4/asset.epub"
    try:
        _superseded_key(seed, book_id, key)
    finally:
        seed.close()

    racers = [_store(isolated_api) for _ in range(8)]
    barrier = threading.Barrier(len(racers))
    results: list[list] = [[] for _ in racers]
    errors: list[BaseException] = []

    def claim(index: int) -> None:
        try:
            barrier.wait(timeout=10)
            results[index] = racers[index].claim_pending_objects(1)
        except BaseException as exc:  # pragma: no cover - failure path
            errors.append(exc)

    threads = [threading.Thread(target=claim, args=(i,)) for i in range(len(racers))]
    try:
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)
        assert errors == []
        claimed = [c.object_key for batch in results for c in batch]
        assert claimed == [key]
    finally:
        for store in racers:
            store.close()


def test_sop_states_the_late_put_bound_from_asset_url_ttl():
    """#2929 (1): the account-erasure late-PUT window is documented as one hour,
    pinned to the presigned-URL TTL constant rather than a hand-typed number."""
    from pathlib import Path

    import kg.routers.library as library_router

    assert library_router._ASSET_URL_TTL == 3600
    sop = (Path(__file__).resolve().parents[2] / "docs" / "sop" / "architecture.md").read_text(encoding="utf-8")
    bound_lines = [line for line in sop.splitlines() if "late PUT" in line and "_ASSET_URL_TTL" in line]
    assert bound_lines, "architecture.md must state the late-PUT bound next to _ASSET_URL_TTL"
    assert "3600" in bound_lines[0] and "1 小時" in bound_lines[0]
