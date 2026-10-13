"""Unit tests for kg.ops_edit_user_commands — direct function calls."""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path

import pytest

import kg.ops_edit_user_commands as user_cmd
from kg.user_store import load_users_from


def _setup_data_dir(tmp_path: Path) -> Path:
    return tmp_path


def _make_args(**kwargs) -> argparse.Namespace:
    defaults = {
        "uid": "u1",
        "commit": False,
        "json": True,
        "provider": "google",
        "email": "u1@test.com",
        "allow_existing": False,
        "reassign_email": False,
        "translation_source": None,
        "translation_target": None,
        "review_clock": None,
        "paused_at": None,
        "review_mode": None,
        "custom_initial_interval_hours": None,
        "custom_remembered_multiplier": None,
        "custom_forgot_multiplier": None,
        "custom_minimum_interval_hours": None,
        "custom_maximum_interval_hours": None,
        "active_notebook": None,
        "auto_link": None,
        "backup": None,
    }
    defaults.update(kwargs)
    return argparse.Namespace(**defaults)


# ── cmd_user_create ──────────────────────────────────────────────────────


class TestUserCreate:
    def test_dry_run_new_user(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_user_create(_make_args(uid="newuser"))
        assert rc == 0
        out = capsys.readouterr().out
        assert "dry-run" in out

    def test_commit_creates_user(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_user_create(_make_args(uid="newuser", commit=True))
        assert rc == 0
        users = load_users_from(tmp_path / "users.json", lambda x: (x, False))
        assert "newuser" in users
        assert (tmp_path / "users" / "newuser").exists()

    def test_existing_without_allow_existing(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="newuser", commit=True))
        rc = user_cmd.cmd_user_create(_make_args(uid="newuser"))
        assert rc == 1

    def test_allow_existing(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="newuser", commit=True))
        rc = user_cmd.cmd_user_create(_make_args(uid="newuser", allow_existing=True, commit=True))
        assert rc == 0


class TestUserCreateEmailCollision:
    def _seed_owner(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="owner", email="a@x.com", commit=True))

    def _index(self, tmp_path):
        return load_users_from(tmp_path / "users.json", lambda x: (x, False))["_email_index"]

    def test_commit_refuses_email_owned_by_other_uid(self, tmp_path, monkeypatch):
        self._seed_owner(tmp_path, monkeypatch)
        rc = user_cmd.cmd_user_create(_make_args(uid="demo1", email="a@x.com", commit=True))
        assert rc != 0
        assert self._index(tmp_path)["a@x.com"] == "owner"
        assert not (tmp_path / "users" / "demo1").exists()

    def test_dry_run_reports_conflict(self, tmp_path, monkeypatch, capsys):
        self._seed_owner(tmp_path, monkeypatch)
        capsys.readouterr()
        user_cmd.cmd_user_create(_make_args(uid="demo1", email="a@x.com"))
        plan = json.loads(capsys.readouterr().out)["plan"]
        assert plan["email_owner"] == "owner"
        assert plan["email_conflict"] is True

    def test_reassign_flag_allows_override(self, tmp_path, monkeypatch):
        self._seed_owner(tmp_path, monkeypatch)
        rc = user_cmd.cmd_user_create(_make_args(uid="demo1", email="a@x.com", reassign_email=True, commit=True))
        assert rc == 0
        assert self._index(tmp_path)["a@x.com"] == "demo1"

    def test_same_uid_allow_existing_is_not_a_conflict(self, tmp_path, monkeypatch):
        self._seed_owner(tmp_path, monkeypatch)
        rc = user_cmd.cmd_user_create(_make_args(uid="owner", email="a@x.com", allow_existing=True, commit=True))
        assert rc == 0


class TestRestoreEmailCollision:
    def test_restore_does_not_steal_email_from_other_uid(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="a@x.com", commit=True))
        user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))
        user_cmd.cmd_user_create(_make_args(uid="newowner", email="a@x.com", commit=True))

        rc = user_cmd.cmd_restore(_make_args(uid="doomed", commit=True))

        assert rc == 0
        users = load_users_from(tmp_path / "users.json", lambda x: (x, False))
        assert users["_email_index"]["a@x.com"] == "newowner"
        assert "doomed" in users


# ── cmd_user_delete ──────────────────────────────────────────────────────


class TestUserDelete:
    def test_dry_run_keeps_user(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))
        capsys.readouterr()

        rc = user_cmd.cmd_user_delete(_make_args(uid="doomed"))

        assert rc == 0
        assert "dry-run" in capsys.readouterr().out
        assert (tmp_path / "users" / "doomed").exists()

    def test_commit_removes_dir_record_and_email_index(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))

        rc = user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))

        assert rc == 0
        users = load_users_from(tmp_path / "users.json", lambda x: (x, False))
        assert "doomed" not in users
        assert not (tmp_path / "users" / "doomed").exists()
        assert "doomed@test.com" not in users.get("_email_index", {})

    def test_commit_scrubs_subscription_index_and_spares_others(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))
        user_cmd.cmd_user_create(_make_args(uid="keeper", email="keeper@test.com", commit=True))
        users_path = tmp_path / "users.json"
        payload = json.loads(users_path.read_text())
        payload["_subscription_index"] = {
            "txn-doomed": "doomed",
            "txn-keep": "keeper",
        }
        users_path.write_text(json.dumps(payload))

        rc = user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))

        assert rc == 0
        users = json.loads(users_path.read_text())
        assert users["_subscription_index"] == {"txn-keep": "keeper"}
        assert "keeper" in users
        assert (tmp_path / "users" / "keeper").exists()

    def test_commit_revokes_tokens_and_terminates_uid(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))
        user_cmd.cmd_user_create(_make_args(uid="keeper", email="keeper@test.com", commit=True))

        user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))

        users = json.loads((tmp_path / "users.json").read_text())
        assert "doomed" in users["_revoked_before"]
        assert users["_terminated"] == ["doomed"]
        assert "keeper" not in users["_revoked_before"]

    def test_restore_lifts_tombstone(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))
        user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))

        user_cmd.cmd_restore(_make_args(uid="doomed", commit=True))

        users = json.loads((tmp_path / "users.json").read_text())
        assert "doomed" not in users.get("_revoked_before", {})
        assert "doomed" not in users.get("_terminated", [])

    def test_absent_uid_raises(self, tmp_path, monkeypatch):
        from kg.ops_edit_support import EditError

        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))

        with pytest.raises(EditError):
            user_cmd.cmd_user_delete(_make_args(uid="ghost", commit=True))

    def test_delete_then_restore_round_trip(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))
        user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))

        rc = user_cmd.cmd_restore(_make_args(uid="doomed", commit=True))

        assert rc == 0
        assert (tmp_path / "users" / "doomed" / "notebooks.db").exists()
        users = load_users_from(tmp_path / "users.json", lambda x: (x, False))
        assert "doomed" in users

    def test_parser_registers_user_delete(self):
        from kg.ops_edit_parser import build_parser

        ns = build_parser().parse_args(["user-delete", "u1", "--commit"])

        assert ns.func is user_cmd.cmd_user_delete
        assert ns.uid == "u1"
        assert ns.commit is True

    def test_parser_rejects_retired_dictionary_card_flags(self):
        from kg.ops_edit_parser import build_parser

        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args(["user-config-set", "u1", "--include-dictionary-cards"])
        with pytest.raises(SystemExit):
            parser.parse_args(["user-config-set", "u1", "--exclude-dictionary-cards"])


# ── cmd_user_config_set ──────────────────────────────────────────────────


class TestUserConfigSet:
    def _setup_user(self, tmp_path: Path, uid: str = "u1") -> Path:
        data_dir = tmp_path
        (data_dir / "users").mkdir()
        (data_dir / "users.json").write_text(f'{{"{uid}": {{"config": {{}}, "email": "{uid}@test.com"}}}}')
        user_dir = data_dir / "users" / uid
        user_dir.mkdir()
        from kg.notebook import NotebookStore

        NotebookStore(user_dir / "notebooks.db").close()
        return data_dir

    def test_dry_run(self, tmp_path, monkeypatch, capsys):
        self._setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_user_config_set(_make_args(translation_source="en", translation_target="zh-Hant"))
        assert rc == 0
        out = capsys.readouterr().out
        assert "dry-run" in out

    def test_commit_translation(self, tmp_path, monkeypatch, capsys):
        self._setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_user_config_set(
            _make_args(translation_source="en", translation_target="zh-Hant", commit=True)
        )
        assert rc == 0
        users = load_users_from(tmp_path / "users.json", lambda x: (x, False))
        cfg = users["u1"]["config"]
        assert cfg["translation"]["source_lang"] == "en"
        assert cfg["translation"]["target_lang"] == "zh-Hant"

    def test_commit_review_clock_paused(self, tmp_path, monkeypatch, capsys):
        self._setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_user_config_set(_make_args(review_clock="paused", commit=True))
        assert rc == 0
        users = load_users_from(tmp_path / "users.json", lambda x: (x, False))
        assert users["u1"]["config"]["review_clock"]["is_paused"] is True

    def test_commit_review_mode(self, tmp_path, monkeypatch, capsys):
        self._setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_user_config_set(
            _make_args(review_mode="intensive", custom_initial_interval_hours=6, commit=True)
        )
        assert rc == 0
        users = load_users_from(tmp_path / "users.json", lambda x: (x, False))
        rm = users["u1"]["config"]["review_mode"]
        assert rm["mode"] == "intensive"
        assert rm["custom_initial_interval_hours"] == 6

    def test_commit_auto_link_off(self, tmp_path, monkeypatch, capsys):
        self._setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_user_config_set(_make_args(auto_link="off", commit=True))
        assert rc == 0
        users = load_users_from(tmp_path / "users.json", lambda x: (x, False))
        al = users["u1"]["config"]["auto_link"]
        assert al["enabled"] is False
        assert al["updated_at"] is not None

    def test_commit_auto_link_on(self, tmp_path, monkeypatch, capsys):
        self._setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_user_config_set(_make_args(auto_link="on", commit=True))
        assert rc == 0
        users = load_users_from(tmp_path / "users.json", lambda x: (x, False))
        assert users["u1"]["config"]["auto_link"]["enabled"] is True

    def test_no_updates_raises(self, tmp_path, monkeypatch):
        self._setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        from kg.ops_edit_support import EditError

        with pytest.raises(EditError):
            user_cmd.cmd_user_config_set(_make_args())

    def test_paused_at_without_clock_raises(self, tmp_path, monkeypatch):
        self._setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        from kg.ops_edit_support import EditError

        with pytest.raises(EditError):
            user_cmd.cmd_user_config_set(_make_args(paused_at="2024-01-01T00:00:00Z"))


# ── cmd_list_backups ─────────────────────────────────────────────────────


class TestListBackups:
    def test_empty(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_list_backups(_make_args(uid="u1"))
        assert rc == 0
        out = capsys.readouterr().out
        assert "count" in out

    def test_with_backup(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        backup_dir = tmp_path / "_ops_backups"
        backup_dir.mkdir()
        (backup_dir / "u1__20240101T000000Z.tar.gz").write_text("fake")
        rc = user_cmd.cmd_list_backups(_make_args(uid="u1"))
        assert rc == 0
        out = capsys.readouterr().out
        data = json.loads(out)
        assert data["count"] == 1


# ── cmd_restore ──────────────────────────────────────────────────────────


class TestRestore:
    def _create_backup(self, tmp_path: Path, uid: str = "u1") -> Path:
        import tarfile

        backup_dir = tmp_path / "_ops_backups"
        backup_dir.mkdir()
        dest = backup_dir / f"{uid}__20240101T000000Z.tar.gz"
        with tarfile.open(dest, "w:gz") as tar:
            # Add minimal user dir content
            user_dir = tmp_path / "users" / uid
            user_dir.mkdir(parents=True)
            (user_dir / "notebooks.db").write_text("")
            tar.add(user_dir, arcname=uid)
        return dest

    def test_dry_run(self, tmp_path, monkeypatch, capsys):
        self._create_backup(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_restore(_make_args(uid="u1"))
        assert rc == 0
        out = capsys.readouterr().out
        assert "dry-run" in out

    def test_commit_restore(self, tmp_path, monkeypatch, capsys):
        self._create_backup(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = user_cmd.cmd_restore(_make_args(uid="u1", commit=True))
        assert rc == 0
        assert (tmp_path / "users" / "u1" / "notebooks.db").exists()

    def test_no_backup_raises(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        from kg.ops_edit_support import EditError

        with pytest.raises(EditError):
            user_cmd.cmd_restore(_make_args(uid="u1"))


# ── mark_destructive 契約(#2312)────────────────────────────────────────


def _error_payload(capsys) -> dict:
    return json.loads(capsys.readouterr().out)


class TestDestructiveFailureReporting:
    def _create(self, tmp_path, monkeypatch, uid="doomed"):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid=uid, email=f"{uid}@test.com", commit=True))

    def test_user_delete_rmtree_failure_marks_data_mutated(self, tmp_path, monkeypatch, capsys):
        self._create(tmp_path, monkeypatch)
        capsys.readouterr()

        real_rmtree = user_cmd.shutil.rmtree

        def boom(path, *a, **k):
            # shutil 是全域模組:只讓 user_dir 的 rmtree 失敗,備份暫存目錄的清理要放行。
            if Path(path).name == "doomed":
                raise PermissionError("rmtree denied")
            return real_rmtree(path, *a, **k)

        monkeypatch.setattr(user_cmd.shutil, "rmtree", boom)
        rc = user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))

        out = _error_payload(capsys)
        assert rc == 1
        assert out["mode"] == "error"
        assert out["data_mutated"] is True
        assert out["backup"]
        assert "restore doomed" in out["recovery_path"]
        assert out["backup"] in out["recovery_path"]
        users = load_users_from(tmp_path / "users.json", lambda x: (x, False))
        assert "doomed" not in users  # record 已被移除,故必須回報 data_mutated

    def test_user_delete_missing_user_is_not_mutating(self, tmp_path, monkeypatch, capsys):
        from kg.ops_edit_support import EditError

        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        with pytest.raises(EditError):
            user_cmd.cmd_user_delete(_make_args(uid="ghost", commit=True))

    def test_restore_rmtree_failure_marks_data_mutated(self, tmp_path, monkeypatch, capsys):
        self._create(tmp_path, monkeypatch, uid="u1")
        # 先做一次成功 delete 產生備份,再讓 user_dir 重建(restore 前提:現存目錄會被清)
        user_cmd.cmd_user_delete(_make_args(uid="u1", commit=True))
        user_cmd.cmd_restore(_make_args(uid="u1", commit=True))
        capsys.readouterr()

        real_rmtree = user_cmd.shutil.rmtree

        def boom(path, *a, **k):
            # shutil 是全域模組:只讓 user_dir 的 rmtree 失敗,備份暫存目錄的清理要放行。
            if Path(path).name == "u1":
                raise PermissionError("rmtree denied")
            return real_rmtree(path, *a, **k)

        monkeypatch.setattr(user_cmd.shutil, "rmtree", boom)
        rc = user_cmd.cmd_restore(_make_args(uid="u1", commit=True))

        out = _error_payload(capsys)
        assert rc == 1
        assert out["data_mutated"] is True
        assert "restore u1" in out["recovery_path"]
        assert out["backup"] in out["recovery_path"]

    def test_restore_arcname_mismatch_is_not_mutating(self, tmp_path, monkeypatch, capsys):
        import tarfile

        from kg.ops_edit_support import EditError

        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        backup_dir = tmp_path / "_ops_backups"
        backup_dir.mkdir()
        wrong = tmp_path / "src" / "other"
        wrong.mkdir(parents=True)
        (wrong / "notebooks.db").write_text("")
        dest = backup_dir / "u1__20240101T000000Z.tar.gz"
        with tarfile.open(dest, "w:gz") as tar:
            tar.add(wrong, arcname="other")
        with pytest.raises(EditError):
            user_cmd.cmd_restore(_make_args(uid="u1", commit=True))


# ── cmd_user_delete: remote library assets (#3428) ───────────────────────


class _FakeObjectStorage:
    """In-memory stand-in for the S3 calls the erasure path makes."""

    def __init__(self, keys=()):
        self.objects = set(keys)
        self.deleted: list[str] = []

    def delete_object(self, *, Bucket, Key):  # noqa: N803
        self.deleted.append(Key)
        self.objects.discard(Key)
        return {}

    def list_objects_v2(self, *, Bucket, Prefix, **_):  # noqa: N803
        keys = sorted(k for k in self.objects if k.startswith(Prefix))
        return {"Contents": [{"Key": k} for k in keys], "IsTruncated": False}

    def delete_objects(self, *, Bucket, Delete):  # noqa: N803
        for item in Delete["Objects"]:
            self.deleted.append(item["Key"])
            self.objects.discard(item["Key"])
        return {}


def _seed_library_books(data_dir: Path, uid: str, keys: list[str]) -> None:
    from sqlmodel import Session

    from kg.library.store import LibraryBook, LibraryStore

    store = LibraryStore(data_dir / "users" / uid / "library.db")
    try:
        with Session(store.engine) as session:
            for index, key in enumerate(keys):
                session.add(
                    LibraryBook(id=f"book-{index}", title=f"b{index}", asset_storage="object", asset_object_key=key)
                )
            session.commit()
    finally:
        store.close()


class TestUserDeleteRemoteAssets:
    def test_commit_erases_remote_library_assets_before_removing_dir(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        fake = _FakeObjectStorage(["library/doomed/a.epub", "library/doomed/b.epub", "library/keeper/c.epub"])
        monkeypatch.setattr(user_cmd, "_library_object_storage", lambda: ("kg-library", fake), raising=False)
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))
        _seed_library_books(tmp_path, "doomed", ["library/doomed/a.epub", "library/doomed/b.epub"])

        rc = user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))

        assert rc == 0
        assert {"library/doomed/a.epub", "library/doomed/b.epub"} <= set(fake.deleted)
        assert not any(k.startswith("library/doomed/") for k in fake.objects)
        assert "library/keeper/c.epub" in fake.objects
        assert not (tmp_path / "users" / "doomed").exists()


# ── cmd_user_delete: external API keys (#3429) ───────────────────────────


class TestUserDeleteApiKeys:
    def test_commit_purges_external_api_keys_so_recreated_account_cannot_reuse_them(self, tmp_path, monkeypatch):
        from kg.auth_service import resolve_and_link_user
        from kg.external_api_keys import authenticate_api_key, issue_api_key

        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        users_path = tmp_path / "users.json"
        lock = tmp_path / "users.json.lock"

        def load():
            return load_users_from(users_path, lambda x: (x, False))

        def save(payload):
            users_path.write_text(json.dumps(payload))

        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))
        issued = issue_api_key("doomed", label="ci", users_lock_file=lock, load_users=load, save_users=save)
        assert authenticate_api_key(issued["apiKey"], load_users=load) is not None

        assert user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True)) == 0
        resolve_and_link_user(
            "doomed",
            "google",
            users_lock_file=str(lock),
            load_users_fn=load,
            save_users_fn=save,
            email="doomed@test.com",
        )

        assert authenticate_api_key(issued["apiKey"], load_users=load) is None
        index = load().get("_external_api_keys", {})
        assert not any(record.get("user_id") == "doomed" for record in index.values())


# ── cmd_user_delete: partial removal (#3430) ─────────────────────────────


class TestUserDeleteQuarantine:
    def test_commit_partial_removal_failure_leaves_no_live_path(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))
        with sqlite3.connect(tmp_path / "users" / "doomed" / "cards.db") as conn:
            conn.execute("CREATE TABLE cards (id TEXT)")
        capsys.readouterr()

        real_rmtree = user_cmd.shutil.rmtree

        def partial(path, *a, **k):
            # shutil 是全域模組:只對 user 目錄模擬「刪一半後 I/O 失敗」,備份清理放行。
            if Path(path).name == "doomed":
                (Path(path) / "cards.db").unlink()
                raise OSError("I/O error mid-removal")
            return real_rmtree(path, *a, **k)

        monkeypatch.setattr(user_cmd.shutil, "rmtree", partial)
        rc = user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))

        assert rc == 1
        assert not (tmp_path / "users" / "doomed").exists()
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))
        assert not (tmp_path / "users" / "doomed" / "cards.db").exists()


# ── cmd_user_delete: post-tombstone prefix sweep is best-effort (#3466) ──


class TestUserDeletePrefixSweepBestEffort:
    def test_sweep_failure_after_tombstone_does_not_abort_dir_removal(self, tmp_path, monkeypatch):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        fake = _FakeObjectStorage()
        monkeypatch.setattr(user_cmd, "_library_object_storage", lambda: ("kg-library", fake), raising=False)

        def failing_sweep(*_args, **_kwargs):
            raise RuntimeError("s3 list failed")

        monkeypatch.setattr(user_cmd, "sweep_account_prefixes", failing_sweep)
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))

        rc = user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))

        assert rc == 0
        assert not (tmp_path / "users" / "doomed").exists()
        users = json.loads((tmp_path / "users.json").read_text(encoding="utf-8"))
        assert "doomed" in users["_revoked_before"]
        assert "doomed" in users["_terminated"]

    def test_sweep_failure_is_reported_and_marked_incomplete(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        fake = _FakeObjectStorage()
        monkeypatch.setattr(user_cmd, "_library_object_storage", lambda: ("kg-library", fake), raising=False)

        def failing_sweep(*_args, **_kwargs):
            raise RuntimeError("s3 list failed")

        reported: list[tuple[BaseException, str]] = []

        def recorder(exc, *, context, tags=None):
            reported.append((exc, context))
            return True

        monkeypatch.setattr(user_cmd, "sweep_account_prefixes", failing_sweep)
        monkeypatch.setattr(user_cmd, "capture_handled", recorder, raising=False)
        user_cmd.cmd_user_create(_make_args(uid="doomed", email="doomed@test.com", commit=True))
        capsys.readouterr()

        rc = user_cmd.cmd_user_delete(_make_args(uid="doomed", commit=True))

        payload = json.loads(capsys.readouterr().out)
        assert rc == 0
        assert [context for _exc, context in reported] == ["account_erasure.prefix_sweep"]
        assert isinstance(reported[0][0], RuntimeError)
        assert payload["result"]["sweep_incomplete"] is True
        audit_last = json.loads((tmp_path / "_ops_edit_audit.jsonl").read_text(encoding="utf-8").splitlines()[-1])
        assert audit_last["result"]["sweep_incomplete"] is True

    def test_successful_sweep_is_not_reported(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        fake = _FakeObjectStorage()
        monkeypatch.setattr(user_cmd, "_library_object_storage", lambda: ("kg-library", fake), raising=False)
        reported: list[str] = []
        monkeypatch.setattr(
            user_cmd,
            "capture_handled",
            lambda exc, *, context, tags=None: reported.append(context) or True,
            raising=False,
        )
        user_cmd.cmd_user_create(_make_args(uid="clean", email="clean@test.com", commit=True))
        capsys.readouterr()

        rc = user_cmd.cmd_user_delete(_make_args(uid="clean", commit=True))

        payload = json.loads(capsys.readouterr().out)
        assert rc == 0
        assert reported == []
        assert payload["result"]["sweep_incomplete"] is False


# ── _sweep_quarantine: failed leftover removal is reported, not silent (#3574) ──


class TestSweepQuarantineReportsFailure:
    def test_rmtree_failure_is_reported_and_does_not_abort(self, tmp_path, monkeypatch):
        batch = tmp_path / ".deleting" / "stale"
        batch.mkdir(parents=True)
        reported: list[tuple[BaseException, str]] = []

        def recorder(exc, *, context, tags=None):
            reported.append((exc, context))
            return True

        def failing_rmtree(*_args, **_kwargs):
            raise OSError("device busy")

        monkeypatch.setattr(user_cmd.shutil, "rmtree", failing_rmtree)
        monkeypatch.setattr(user_cmd, "capture_handled", recorder, raising=False)

        user_cmd._sweep_quarantine(tmp_path)

        assert [context for _exc, context in reported] == ["account_erasure.quarantine_sweep"]
        assert isinstance(reported[0][0], OSError)
