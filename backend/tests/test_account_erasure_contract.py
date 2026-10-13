"""Contract tests for account erasure of object-backed library assets."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi import HTTPException
from filelock import FileLock, Timeout
from sqlmodel import Session

import kg.routers.library as library_router
from conftest import TEST_JWT_SECRET, _swap_settings
from kg import podcast_progress
from kg.account_erasure import _asset_object_keys, delete_account_assets
from kg.library.store import LibraryBook, LibraryStore
from kg.settings import KGSettings
from kg.user_handlers import _tombstone_accounts, delete_user_account_response
from kg.user_store import collect_account_ids_for_deletion


class _NoSuchKey(Exception):
    pass


class _FakeObjectClient:
    class exceptions:
        NoSuchKey = _NoSuchKey

    def __init__(self, *, missing: set[str] | None = None, failures: int = 0, data_dir: Path):
        self.missing = missing or set()
        self.failures = failures
        self.data_dir = data_dir
        self.calls: list[str] = []
        self.directory_states: list[dict[str, bool]] = []

    def delete_object(self, *, Bucket: str, Key: str):  # noqa: N803
        self.calls.append(Key)
        self.directory_states.append(
            {uid: (self.data_dir / "users" / uid).exists() for uid in ("canonical", "linked1")}
        )
        if Key in self.missing:
            raise _NoSuchKey(Key)
        if self.failures:
            self.failures -= 1
            raise RuntimeError("object storage unavailable")
        return {}


def _seed_library_asset(
    data_dir: Path,
    uid: str,
    key: str,
    *,
    asset_storage: str | None = "object",
) -> None:
    user_dir = data_dir / "users" / uid
    user_dir.mkdir(parents=True, exist_ok=True)
    store = LibraryStore(user_dir / "library.db")
    try:
        with Session(store.engine) as session:
            session.add(
                LibraryBook(
                    id=f"book-{uid}",
                    title=f"Book for {uid}",
                    asset_storage=asset_storage,
                    asset_object_key=key,
                )
            )
            session.commit()
    finally:
        store.close()


def _call_delete(
    tmp_path: Path,
    users_data: dict,
    client: object | None,
    *,
    bucket: str | None = "library-test",
    user_id: str = "linked1",
):
    users_file = tmp_path / "users.json"
    users_file.write_text(json.dumps(users_data))

    def load_users():
        return json.loads(users_file.read_text())

    def save_users(updated):
        users_file.write_text(json.dumps(updated))

    return delete_user_account_response(
        {"id": user_id},
        users_lock_file=tmp_path / "users.json.lock",
        load_users=load_users,
        save_users=save_users,
        collect_account_ids_for_deletion=collect_account_ids_for_deletion,
        data_dir=tmp_path,
        logger=MagicMock(),
        library_bucket=bucket,
        library_s3_client=client,
    )


def _linked_users() -> dict:
    return {
        "canonical": {"linked_ids": ["linked1"], "config": {}},
        "linked1": {"_linked_to": "canonical", "config": {}},
    }


def test_delete_account_removes_global_podcast_progress_for_canonical_and_linked_users(isolated_api):
    canonical_id = isolated_api.user_id
    linked_id = "linked_progress_user"
    other_id = "other_user"

    users = json.loads(isolated_api.users_file.read_text())
    users[canonical_id]["linked_ids"] = [linked_id]
    users[linked_id] = {"_linked_to": canonical_id, "config": {}}
    isolated_api.users_file.write_text(json.dumps(users))

    # The fixture's cache was not necessarily populated, but make the test
    # independent of that implementation detail before the HTTP request.
    from kg.api import app

    app.state.user_store.invalidate()

    for user_id, series_id in (
        (canonical_id, "canonical-series"),
        (linked_id, "linked-series"),
        (other_id, "other-series"),
    ):
        podcast_progress.upsert(
            user_id=user_id,
            series_id=series_id,
            ep_num=1,
            position_sec=10.0,
            duration_sec=100.0,
            updated_at="2026-09-01T00:00:00+00:00",
        )

    deleted = isolated_api.client.delete("/api/user/account", headers=isolated_api.headers)

    assert deleted.status_code == 200, deleted.text
    assert deleted.json()["deleted_user_id"] == canonical_id
    assert deleted.json()["linked_ids"] == [linked_id]

    with sqlite3.connect(isolated_api.data_dir / "podcast_progress.db") as conn:
        rows = conn.execute(
            "SELECT user_id, COUNT(*) FROM podcast_progress GROUP BY user_id ORDER BY user_id"
        ).fetchall()

    assert rows == [(other_id, 1)]

    # Preserve the existing account-deletion auth semantics on re-entry.
    retry = isolated_api.client.delete("/api/user/account", headers=isolated_api.headers)
    assert retry.status_code == 401


def test_delete_account_removes_global_log_stores_for_canonical_and_linked_users(isolated_api):
    from kg import judge_log, llm_error_log, pipeline_log, token_tracker, translate_log, vocab_add_link_operation
    from kg.api import app
    from kg.deps import _shared_deck_store

    canonical_id = isolated_api.user_id
    linked_id = "linked_log_user"
    other_id = "other_user"

    users = json.loads(isolated_api.users_file.read_text())
    users[canonical_id]["linked_ids"] = [linked_id]
    users[linked_id] = {"_linked_to": canonical_id, "config": {}}
    isolated_api.users_file.write_text(json.dumps(users))
    app.state.user_store.invalidate()

    shared_store = _shared_deck_store(app.state.kg_settings)
    for uid in (canonical_id, linked_id, other_id):
        vocab_add_link_operation.create_operation(
            user_id=uid, notebook_id="nb", idempotency_key=f"k-{uid}", payload={"source": "s", "context": "c"}
        )
        translate_log.record(
            user_id=uid,
            operation="translate",
            word="w",
            context="c",
            context_hash="h",
            source_lang="en",
            target_lang="zh",
            response_raw="r",
            latency_ms=1,
        )
        translate_log.record_cache_hit(
            user_id=uid, operation="translate", word="w", context_hash="h", source_lang="en", target_lang="zh"
        )
        judge_log.record(
            user_id=uid,
            notebook_id="nb",
            from_id="a",
            to_id="b",
            similarity=0.5,
            verdict="related",
            confidence=0.9,
            accepted=True,
        )
        llm_error_log.record(user_id=uid, call_type="judge", error_class="RateLimitError")
        token_tracker.record(uid, "judge", 10, 5)
        pipeline_log.start_run(f"run-{uid}", uid, "nb", "manual")
        assert shared_store.record_copy(uid, f"k-{uid}", "deck", 1, "nb")

    def counts() -> dict[str, dict[str, int]]:
        out: dict[str, dict[str, int]] = {}
        for label, mod, table in (
            ("ops", vocab_add_link_operation, "vocab_add_link_operations"),
            ("tl", translate_log, "translate_log"),
            ("tch", translate_log, "translate_cache_hits"),
            ("judge", judge_log, "judge_log"),
            ("llm", llm_error_log, "llm_errors"),
            ("tokens", token_tracker, "token_usage"),
            ("runs", pipeline_log, "pipeline_runs"),
        ):
            with mod._lock:
                rows = mod._get_conn().execute(f"SELECT user_id, COUNT(*) FROM {table} GROUP BY user_id").fetchall()
            out[label] = dict(rows)
        out["copy"] = {
            uid: int(shared_store.get_copy_log(uid, f"k-{uid}") is not None)
            for uid in (canonical_id, linked_id, other_id)
        }
        return out

    before = counts()
    for label, per_user in before.items():
        assert per_user.get(canonical_id) == 1 and per_user.get(linked_id) == 1, label

    deleted = isolated_api.client.delete("/api/user/account", headers=isolated_api.headers)
    assert deleted.status_code == 200, deleted.text

    after = counts()
    for label, per_user in after.items():
        assert per_user.get(canonical_id, 0) == 0, label
        assert per_user.get(linked_id, 0) == 0, label
        assert per_user.get(other_id) == 1, label


def test_delete_for_users_is_idempotent_and_user_scoped(tmp_path):
    podcast_progress.set_data_dir(tmp_path)

    for user_id in ("deleted", "other"):
        podcast_progress.upsert(
            user_id=user_id,
            series_id=f"{user_id}-series",
            ep_num=1,
            position_sec=10.0,
            duration_sec=100.0,
            updated_at="2026-09-01T00:00:00+00:00",
        )

    assert podcast_progress.delete_for_users(["deleted", "deleted"]) == 1
    assert podcast_progress.delete_for_users(["deleted"]) == 0
    assert podcast_progress.list_for_user(user_id="deleted") == []
    assert [item["series_id"] for item in podcast_progress.list_for_user(user_id="other")] == ["other-series"]


def test_all_primary_and_linked_object_keys_are_deleted_before_local_data(tmp_path):
    _seed_library_asset(tmp_path, "canonical", "library/canonical/book/asset.epub")
    _seed_library_asset(tmp_path, "linked1", "library/linked1/book/asset.epub")
    client = _FakeObjectClient(data_dir=tmp_path)

    response = _call_delete(tmp_path, _linked_users(), client)

    assert response.deleted_user_id == "canonical"
    assert set(client.calls) == {
        "library/canonical/book/asset.epub",
        "library/linked1/book/asset.epub",
    }
    assert all(all(states.values()) for states in client.directory_states)
    assert not (tmp_path / "users" / "canonical").exists()
    assert not (tmp_path / "users" / "linked1").exists()


def test_nosuchkey_is_idempotent_and_reentrant(tmp_path):
    _seed_library_asset(tmp_path, "canonical", "library/canonical/book/asset.epub")
    client = _FakeObjectClient(
        missing={"library/canonical/book/asset.epub"},
        data_dir=tmp_path,
    )

    delete_account_assets(
        tmp_path,
        ["canonical"],
        library_bucket="library-test",
        library_s3_client=client,
    )
    delete_account_assets(
        tmp_path,
        ["canonical"],
        library_bucket="library-test",
        library_s3_client=client,
    )

    assert client.calls == [
        "library/canonical/book/asset.epub",
        "library/canonical/book/asset.epub",
    ]


def test_remote_failure_preserves_identity_and_directory_then_retry_converges(tmp_path):
    _seed_library_asset(tmp_path, "canonical", "library/canonical/book/asset.epub")
    client = _FakeObjectClient(failures=1, data_dir=tmp_path)
    users_data = {"canonical": {"linked_ids": [], "config": {}}}

    with pytest.raises(HTTPException) as exc_info:
        _call_delete(tmp_path, users_data, client, user_id="canonical")
    assert exc_info.value.status_code >= 500
    assert json.loads((tmp_path / "users.json").read_text()) == users_data
    assert (tmp_path / "users" / "canonical").exists()

    # The same request is safe to retry after the transient remote failure.
    _call_delete(tmp_path, users_data, client, user_id="canonical")
    saved = json.loads((tmp_path / "users.json").read_text())
    assert "canonical" not in saved
    assert not (tmp_path / "users" / "canonical").exists()


def test_unconfigured_bucket_does_not_call_remote_client(tmp_path):
    _seed_library_asset(tmp_path, "canonical", "library/canonical/book/asset.epub")
    client = _FakeObjectClient(data_dir=tmp_path)
    users_data = {"canonical": {"linked_ids": [], "config": {}}}

    _call_delete(tmp_path, users_data, client, bucket=None, user_id="canonical")

    assert client.calls == []
    assert not (tmp_path / "users" / "canonical").exists()


def test_local_or_unknown_asset_keys_are_not_deleted_remotely(tmp_path):
    _seed_library_asset(
        tmp_path,
        "local-user",
        "stale/local/key",
        asset_storage="local",
    )
    _seed_library_asset(
        tmp_path,
        "unknown-user",
        "stale/unknown/key",
        asset_storage=None,
    )
    client = _FakeObjectClient(data_dir=tmp_path)

    keys = delete_account_assets(
        tmp_path,
        ["local-user", "unknown-user"],
        library_bucket="library-test",
        library_s3_client=client,
    )

    assert keys == ()
    assert client.calls == []


# ── #2060: remote deletes must not run under the shared users lock ───────────


class _LockProbingObjectClient(_FakeObjectClient):
    """Records every remote delete issued while the users lock was held."""

    def __init__(self, *, lock_path: Path, on_first_delete=None, **kwargs):
        super().__init__(**kwargs)
        self.lock_path = lock_path
        self.on_first_delete = on_first_delete
        self.deleted_under_lock: list[str] = []

    def delete_object(self, *, Bucket: str, Key: str):  # noqa: N803
        probe = FileLock(str(self.lock_path), timeout=0)
        try:
            probe.acquire()
        except Timeout:
            self.deleted_under_lock.append(Key)
        else:
            probe.release()
        if self.on_first_delete is not None:
            hook, self.on_first_delete = self.on_first_delete, None
            hook()
        return super().delete_object(Bucket=Bucket, Key=Key)


def test_remote_asset_deletes_run_without_holding_the_users_lock(tmp_path):
    _seed_library_asset(tmp_path, "canonical", "library/canonical/book/asset.epub")
    _seed_library_asset(tmp_path, "linked1", "library/linked1/book/asset.epub")
    client = _LockProbingObjectClient(lock_path=tmp_path / "users.json.lock", data_dir=tmp_path)

    _call_delete(tmp_path, _linked_users(), client)

    assert len(client.calls) == 2
    assert client.deleted_under_lock == []


def test_identity_linked_during_remote_phase_is_erased_too(tmp_path):
    """Leaving the lock for the remote phase must not let a concurrent link escape."""
    _seed_library_asset(tmp_path, "canonical", "library/canonical/book/asset.epub")
    users_file = tmp_path / "users.json"

    def link_late_identity():
        users = json.loads(users_file.read_text())
        users["canonical"]["linked_ids"].append("late")
        users["late"] = {"_linked_to": "canonical", "config": {}}
        users_file.write_text(json.dumps(users))
        _seed_library_asset(tmp_path, "late", "library/late/book/asset.epub")

    client = _LockProbingObjectClient(
        lock_path=tmp_path / "users.json.lock",
        on_first_delete=link_late_identity,
        data_dir=tmp_path,
    )
    users_data = {"canonical": {"linked_ids": [], "config": {}}}

    response = _call_delete(tmp_path, users_data, client, user_id="canonical")

    assert set(client.calls) == {"library/canonical/book/asset.epub", "library/late/book/asset.epub"}
    assert client.deleted_under_lock == []
    assert response.linked_ids == ["late"]
    saved = json.loads(users_file.read_text())
    assert "canonical" not in saved
    assert "late" not in saved
    assert {"canonical", "late"} <= set(saved["_terminated"])
    assert not (tmp_path / "users" / "late").exists()


def test_self_service_delete_purges_subscription_index_for_canonical_and_linked(tmp_path):
    """#2255: stale transaction→uid mappings would let a later App Store
    notification re-create the erased record; only the other user's entry stays."""
    users_data = {
        "canonical": {
            "linked_ids": ["linked1"],
            "config": {},
            "subscription": {"status": "active", "original_transaction_id": "orig-1", "transaction_id": "txn-1"},
        },
        "linked1": {"_linked_to": "canonical", "config": {}},
        "keeper": {"config": {}},
        "_subscription_index": {
            "orig-1": "canonical",
            "txn-1": "canonical",
            "txn-l": "linked1",
            "txn-keep": "keeper",
        },
    }

    _call_delete(tmp_path, users_data, None, bucket=None, user_id="linked1")

    saved = json.loads((tmp_path / "users.json").read_text())
    assert saved["_subscription_index"] == {"txn-keep": "keeper"}
    assert saved["keeper"] == {"config": {}}


def test_self_service_delete_drops_subscription_index_bucket_when_emptied(tmp_path):
    users_data = {
        "canonical": {"linked_ids": [], "config": {}},
        "_subscription_index": {"orig-1": "canonical", "txn-1": "canonical"},
    }

    _call_delete(tmp_path, users_data, None, bucket=None, user_id="canonical")

    saved = json.loads((tmp_path / "users.json").read_text())
    assert "_subscription_index" not in saved


# ── #2702: an asset registered during the remote phase is erased too ─────────


def _add_library_book(data_dir: Path, uid: str, key: str) -> None:
    store = LibraryStore(data_dir / "users" / uid / "library.db")
    try:
        with Session(store.engine) as session:
            session.add(LibraryBook(id=f"late-{key}", title="late", asset_storage="object", asset_object_key=key))
            session.commit()
    finally:
        store.close()


def test_asset_registered_during_remote_phase_is_deleted_before_tombstone(tmp_path):
    _seed_library_asset(tmp_path, "canonical", "library/canonical/book/asset.epub")
    late_key = "library/canonical/other/asset.epub"
    client = _LockProbingObjectClient(
        lock_path=tmp_path / "users.json.lock",
        on_first_delete=lambda: _add_library_book(tmp_path, "canonical", late_key),
        data_dir=tmp_path,
    )
    users_data = {"canonical": {"linked_ids": [], "config": {}}}

    _call_delete(tmp_path, users_data, client, user_id="canonical")

    assert late_key in client.calls
    assert client.deleted_under_lock == []
    assert not (tmp_path / "users" / "canonical").exists()


# ── #2702 residual: registration after the final scan, PUT after the tombstone ──


class _BucketFake:
    """In-memory bucket: paged listing, batch delete, presigned-URL hook."""

    def __init__(self, *, keys: set[str] | None = None, page_size: int = 2, users_file: Path | None = None):
        self.keys: set[str] = set(keys or ())
        self.page_size = page_size
        self.users_file = users_file
        self.on_presign = None
        self.tombstoned_when_swept: list[bool] = []

    def generate_presigned_url(self, operation, *, Params, ExpiresIn):  # noqa: N803
        if self.on_presign is not None:
            hook, self.on_presign = self.on_presign, None
            hook()
        return "https://storage.test/presigned"

    def delete_object(self, *, Bucket: str, Key: str):  # noqa: N803
        self.keys.discard(Key)
        return {}

    def list_objects_v2(self, *, Bucket: str, Prefix: str, ContinuationToken: str | None = None):  # noqa: N803
        # Like S3, the continuation token is key-based, so deleting listed
        # pages between calls does not shift the remaining ones.
        matching = sorted(
            k for k in self.keys if k.startswith(Prefix) and (not ContinuationToken or k > ContinuationToken)
        )
        page = matching[: self.page_size]
        more = len(matching) > self.page_size
        response = {"Contents": [{"Key": k} for k in page], "IsTruncated": more}
        if more:
            response["NextContinuationToken"] = page[-1]
        return response

    def delete_objects(self, *, Bucket: str, Delete: dict):  # noqa: N803
        if self.users_file is not None:
            saved = json.loads(self.users_file.read_text())
            self.tombstoned_when_swept.append("canonical" in saved.get("_terminated", []))
        for item in Delete["Objects"]:
            self.keys.discard(item["Key"])
        return {}


def test_late_put_after_tombstone_is_removed_by_prefix_sweep(tmp_path):
    """The PUT behind a presigned URL can land after the ledger-driven delete;
    it is not in any key ledger, so only a prefix sweep can remove it."""
    _seed_library_asset(tmp_path, "canonical", "library/canonical/book/asset.epub")
    bucket = _BucketFake(
        keys={
            "library/canonical/book/asset.epub",
            "library/canonical/stray-1/asset.epub",
            "library/canonical/stray-2/asset.pdf",
            "library/canonical/stray-3/asset.bin",
            "library/canonical2/book/asset.epub",
        },
        users_file=tmp_path / "users.json",
    )

    _call_delete(tmp_path, {"canonical": {"linked_ids": [], "config": {}}}, bucket, user_id="canonical")

    assert bucket.keys == {"library/canonical2/book/asset.epub"}
    assert bucket.tombstoned_when_swept and all(bucket.tombstoned_when_swept)


def test_prefix_sweep_covers_every_linked_identity(tmp_path):
    bucket = _BucketFake(
        keys={"library/canonical/x/asset.epub", "library/linked1/y/asset.epub", "library/keeper/z/asset.epub"}
    )

    _call_delete(tmp_path, _linked_users(), bucket)

    assert bucket.keys == {"library/keeper/z/asset.epub"}


def test_prefix_sweep_failure_does_not_fail_a_tombstoned_erasure(tmp_path):
    class _ListingDown(_BucketFake):
        def list_objects_v2(self, **kwargs):
            raise RuntimeError("listing unavailable")

    bucket = _ListingDown(keys={"library/canonical/x/asset.epub"})

    response = _call_delete(tmp_path, {"canonical": {"linked_ids": [], "config": {}}}, bucket, user_id="canonical")

    saved = json.loads((tmp_path / "users.json").read_text())
    assert "canonical" in saved["_terminated"]
    assert response.deleted_user_id == "canonical"


def test_asset_upload_after_tombstone_is_rejected_and_not_recorded(isolated_api, monkeypatch):
    """#2702: a request authenticated before the tombstone must not register an
    asset once erasure has committed (the final key scan is already behind it)."""
    _swap_settings(KGSettings(data_dir=isolated_api.data_dir, jwt_secret=TEST_JWT_SECRET, library_bucket="b"))
    bucket = _BucketFake()
    monkeypatch.setattr(library_router, "_library_s3_client", lambda settings: bucket)
    created = isolated_api.client.post(
        "/api/library/books",
        json={"client_book_id": "erasure-race", "title": "Book", "format": "epub"},
        headers=isolated_api.headers,
    )
    assert created.status_code == 201, created.text
    book_id = created.json()["id"]

    def erase_account_now():
        users = json.loads(isolated_api.users_file.read_text())
        _tombstone_accounts(users, [isolated_api.user_id], purge_external_api_keys=None)
        isolated_api.users_file.write_text(json.dumps(users))

    bucket.on_presign = erase_account_now
    response = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 10},
        headers=isolated_api.headers,
    )

    assert response.status_code == 401, response.text
    assert _asset_object_keys(isolated_api.data_dir, [isolated_api.user_id]) == ()


def test_prefix_sweep_failure_is_reported_to_sentry_with_erasure_context(tmp_path, monkeypatch):
    """A swallowed prefix-sweep failure must reach Sentry, not just the log: the
    client cannot retry after the tombstone, so Sentry is the alert path."""
    import kg.user_handlers as user_handlers

    class _ListingDown(_BucketFake):
        def list_objects_v2(self, **kwargs):
            raise RuntimeError("listing unavailable")

    reported: list[tuple[BaseException, str]] = []
    monkeypatch.setattr(
        user_handlers,
        "capture_handled",
        lambda exc, *, context, tags=None: reported.append((exc, context)) or True,
    )
    bucket = _ListingDown(keys={"library/canonical/x/asset.epub"})

    _call_delete(tmp_path, {"canonical": {"linked_ids": [], "config": {}}}, bucket, user_id="canonical")

    assert [context for _, context in reported] == ["account_erasure.prefix_sweep"]
    assert isinstance(reported[0][0], RuntimeError)


def test_local_only_asset_declaration_after_tombstone_is_rejected(isolated_api, monkeypatch):
    """#2702 applies to the local_only branch too: an erased account must get 401
    and must not flip the book's asset storage.

    Only ``_terminated`` is written (no ``_revoked_before``), so the 401 can only
    come from the local_only registration guard; the CurrentUser revocation check
    would otherwise reject the request first and the guard would go untested."""
    _swap_settings(KGSettings(data_dir=isolated_api.data_dir, jwt_secret=TEST_JWT_SECRET, library_bucket="b"))
    monkeypatch.setattr(library_router, "_library_s3_client", lambda settings: _BucketFake())
    created = isolated_api.client.post(
        "/api/library/books",
        json={"client_book_id": "erasure-local", "title": "Book", "format": "epub"},
        headers=isolated_api.headers,
    )
    assert created.status_code == 201, created.text
    book_id = created.json()["id"]

    users = json.loads(isolated_api.users_file.read_text())
    users["_terminated"] = [isolated_api.user_id]
    isolated_api.users_file.write_text(json.dumps(users))

    response = isolated_api.client.post(
        f"/api/library/books/{book_id}/asset-upload",
        json={"format": "epub", "byte_size": 10, "local_only": True},
        headers=isolated_api.headers,
    )

    assert response.status_code == 401, response.text
    store = LibraryStore(isolated_api.data_dir / "users" / isolated_api.user_id / "library.db")
    try:
        with Session(store.engine) as session:
            book = session.get(LibraryBook, book_id)
            assert book is not None and book.asset_storage is None
    finally:
        store.close()


def test_local_directory_removal_runs_before_prefix_sweep(tmp_path, monkeypatch):
    """#2929 (4b): a stalled S3 sweep must not delay local removal, so the
    user directory is removed before the best-effort prefix sweep starts."""
    import kg.user_handlers as user_handlers

    order: list[str] = []
    real_remove = user_handlers._remove_user_dir

    def _record_sweep(*_args, **_kwargs):
        order.append("sweep")
        return 0

    def _record_remove(data_dir, uid):
        order.append(f"remove:{uid}")
        return real_remove(data_dir, uid)

    monkeypatch.setattr(user_handlers, "sweep_account_prefixes", _record_sweep)
    monkeypatch.setattr(user_handlers, "_remove_user_dir", _record_remove)
    _seed_library_asset(tmp_path, "canonical", "library/canonical/book/asset.epub")

    _call_delete(tmp_path, {"canonical": {"linked_ids": [], "config": {}}}, MagicMock(), user_id="canonical")

    assert order == ["remove:canonical", "sweep"]
