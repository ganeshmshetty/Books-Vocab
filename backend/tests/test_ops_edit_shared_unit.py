"""Unit tests for kg.ops_edit_shared — EditContext, backup, audit, emit."""

from __future__ import annotations

import json
import sqlite3
import tarfile
import tempfile
from pathlib import Path

import pytest

import kg.ops_edit_shared as shared

# ── assert_safe_uid ──────────────────────────────────────────────────────


class TestAssertSafeUid:
    def test_valid(self):
        shared.assert_safe_uid("user123")
        shared.assert_safe_uid("user.name")
        shared.assert_safe_uid("user-name")

    def test_empty_raises(self):
        with pytest.raises(shared.EditError):
            shared.assert_safe_uid("")

    def test_dot_raises(self):
        with pytest.raises(shared.EditError):
            shared.assert_safe_uid(".")

    def test_dotdot_raises(self):
        with pytest.raises(shared.EditError):
            shared.assert_safe_uid("..")

    def test_double_dot_raises(self):
        with pytest.raises(shared.EditError):
            shared.assert_safe_uid("a/../b")

    def test_leading_dot_raises(self):
        with pytest.raises(shared.EditError):
            shared.assert_safe_uid(".hidden")

    def test_slash_raises(self):
        with pytest.raises(shared.EditError):
            shared.assert_safe_uid("a/b")

    def test_too_long_raises(self):
        with pytest.raises(shared.EditError):
            shared.assert_safe_uid("x" * 201)


# ── path helpers ─────────────────────────────────────────────────────────


class TestPathHelpers:
    def test_users_file(self, tmp_path):
        assert shared.users_file(tmp_path) == tmp_path / "users.json"

    def test_users_lock_file(self, tmp_path):
        assert shared.users_lock_file(tmp_path) == tmp_path / "users.json.lock"

    def test_user_dir_for(self, tmp_path):
        assert shared.user_dir_for(tmp_path, "u1") == tmp_path / "users" / "u1"


# ── _load_users_json_raw ─────────────────────────────────────────────────


class TestLoadUsersJsonRaw:
    def test_missing(self, tmp_path):
        assert shared._load_users_json_raw(tmp_path / "no.json") == {}

    def test_valid(self, tmp_path):
        p = tmp_path / "users.json"
        p.write_text('{"u1": {}}')
        assert shared._load_users_json_raw(p) == {"u1": {}}

    def test_invalid_json(self, tmp_path):
        p = tmp_path / "users.json"
        p.write_text("not json")
        assert shared._load_users_json_raw(p) == {}

    def test_non_dict(self, tmp_path):
        p = tmp_path / "users.json"
        p.write_text("[1, 2, 3]")
        assert shared._load_users_json_raw(p) == {}


# ── backup_user_dir ──────────────────────────────────────────────────────


class TestBackupUserDir:
    def test_missing_user_dir(self, tmp_path):
        assert shared.backup_user_dir(tmp_path, "u1") is None

    def test_creates_backup(self, tmp_path):
        user_dir = tmp_path / "users" / "u1"
        user_dir.mkdir(parents=True)
        conn = sqlite3.connect(user_dir / "cards.db")
        conn.execute("CREATE TABLE card (content TEXT)")
        conn.commit()
        conn.close()
        (tmp_path / "users.json").write_text('{"u1": {"email": "u1@test.com"}}')

        path = shared.backup_user_dir(tmp_path, "u1")
        assert path is not None
        assert path.exists()
        assert path.name.startswith("u1__")

    def test_collision_avoidance(self, tmp_path):
        user_dir = tmp_path / "users" / "u1"
        user_dir.mkdir(parents=True)
        (tmp_path / "users.json").write_text("{}")

        p1 = shared.backup_user_dir(tmp_path, "u1")
        p2 = shared.backup_user_dir(tmp_path, "u1")
        assert p1 != p2
        assert p1.exists()
        assert p2.exists()

    def test_wal_sidecar_churn_is_not_archived(self, tmp_path, monkeypatch):
        user_dir = tmp_path / "users" / "u1"
        user_dir.mkdir(parents=True)
        (tmp_path / "users.json").write_text('{"u1": {}}')
        db = user_dir / "cards.db"
        conn = sqlite3.connect(db)
        try:
            assert conn.execute("PRAGMA journal_mode=WAL").fetchone()[0].lower() == "wal"
            conn.execute("CREATE TABLE card (content TEXT)")
            conn.execute("INSERT INTO card VALUES ('stable')")
            conn.commit()
            assert (user_dir / "cards.db-wal").exists()
            assert (user_dir / "cards.db-shm").exists()

            original_gettarinfo = tarfile.TarFile.gettarinfo

            def fail_if_sidecar_is_statted(tar, name, arcname=None, fileobj=None):
                if Path(name).name in {"cards.db-wal", "cards.db-shm"}:
                    raise FileNotFoundError(2, "sidecar disappeared", name)
                return original_gettarinfo(tar, name, arcname, fileobj)

            monkeypatch.setattr(tarfile.TarFile, "gettarinfo", fail_if_sidecar_is_statted)
            backup = shared.backup_user_dir(tmp_path, "u1")
        finally:
            conn.close()

        assert backup is not None and backup.exists()
        with tarfile.open(backup) as archive:
            names = archive.getnames()
        assert "u1/cards.db" in names
        assert not any(name.endswith((".db-wal", ".db-shm", ".db-journal")) for name in names)


# ── backup_world ─────────────────────────────────────────────────────────


class TestBackupWorld:
    def test_backup(self, tmp_path):
        (tmp_path / "users.json").write_text("{}")
        path = shared.backup_world(tmp_path)
        assert path.exists()
        assert path.name.startswith("world__")

    def test_label_sanitization(self, tmp_path):
        (tmp_path / "users.json").write_text("{}")
        path = shared.backup_world(tmp_path, label="hello world!!")
        assert "hello-world" in path.name

    def test_manifest_members_exclude_root_sqlite_sidecars(self, tmp_path):
        root_db = tmp_path / "users.db"
        writer = sqlite3.connect(root_db)
        try:
            assert writer.execute("PRAGMA journal_mode=WAL").fetchone()[0].lower() == "wal"
            writer.execute("CREATE TABLE t (x TEXT)")
            writer.commit()
            assert (tmp_path / "users.db-wal").exists()
            archive = shared.backup_world(tmp_path)
        finally:
            writer.close()

        with tarfile.open(archive) as tar:
            names = tar.getnames()
            manifest_member = next(n for n in names if n.endswith("/.ops_meta/backup_manifest.json"))
            manifest = json.loads(tar.extractfile(manifest_member).read())
        assert not any(name.endswith(("-wal", "-shm")) for name in names)
        assert "users.db" in manifest["members"]
        assert not any(member.endswith(("-wal", "-shm")) for member in manifest["members"])

    def test_staging_is_created_under_world_backup_root(self, tmp_path, monkeypatch):
        (tmp_path / "users.json").write_text("{}")
        staging_dirs: list[str] = []
        original_tmpdir = tempfile.TemporaryDirectory

        def recording_tmpdir(*args, **kwargs):
            staging_dirs.append(str(kwargs.get("dir")))
            return original_tmpdir(*args, **kwargs)

        monkeypatch.setattr(tempfile, "TemporaryDirectory", recording_tmpdir)
        shared.backup_world(tmp_path)

        assert len(staging_dirs) == 1
        assert staging_dirs[0] != "None"
        assert Path(staging_dirs[0]).resolve().is_relative_to(shared.world_backup_root(tmp_path).resolve())

    def test_wal_db_snapshot_survives_checkpoint_during_archive(self, tmp_path, monkeypatch):
        user_dir = tmp_path / "users" / "u1"
        user_dir.mkdir(parents=True)
        (tmp_path / "users.json").write_text('{"u1": {}}')
        writer = sqlite3.connect(user_dir / "cards.db")
        try:
            assert writer.execute("PRAGMA journal_mode=WAL").fetchone()[0].lower() == "wal"
            writer.execute("CREATE TABLE card (content TEXT)")
            writer.execute("INSERT INTO card VALUES ('before-backup')")
            writer.commit()
            assert (user_dir / "cards.db-wal").exists()

            original_addfile = tarfile.TarFile.addfile

            def addfile_then_checkpoint(tar, tarinfo, fileobj=None):
                # 模擬 live writer：main .db 已被讀入 archive 後，WAL 才被 checkpoint 並截斷。
                result = original_addfile(tar, tarinfo, fileobj)
                if tarinfo.name.endswith("/cards.db"):
                    writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                return result

            monkeypatch.setattr(tarfile.TarFile, "addfile", addfile_then_checkpoint)
            archive = shared.backup_world(tmp_path)
        finally:
            writer.close()

        with tarfile.open(archive) as tar:
            names = tar.getnames()
            tar.extractall(tmp_path / "restore", filter="data")
        restored = tmp_path / "restore" / "__kg_world__" / "users" / "u1" / "cards.db"
        restored_conn = sqlite3.connect(restored)
        try:
            try:
                rows = restored_conn.execute("SELECT content FROM card").fetchall()
            except sqlite3.OperationalError as exc:
                pytest.fail(f"restored world snapshot lost committed rows: {exc}")
        finally:
            restored_conn.close()
        assert rows == [("before-backup",)]
        assert not any(name.endswith((".db-wal", ".db-shm", ".db-journal")) for name in names)


# ── list_user_backups ────────────────────────────────────────────────────


class TestListUserBackups:
    def test_empty(self, tmp_path):
        assert shared.list_user_backups(tmp_path, "u1") == []

    def test_with_backups(self, tmp_path):
        backup_dir = tmp_path / "_ops_backups"
        backup_dir.mkdir()
        (backup_dir / "u1__20240101T000000Z.tar.gz").write_text("fake")
        (backup_dir / "u2__20240101T000000Z.tar.gz").write_text("fake")
        result = shared.list_user_backups(tmp_path, "u1")
        assert len(result) == 1
        assert result[0]["size"] == 4


# ── append_audit ─────────────────────────────────────────────────────────


class TestAppendAudit:
    def test_appends(self, tmp_path):
        shared.append_audit(tmp_path, {"action": "test"})
        audit_path = tmp_path / "_ops_edit_audit.jsonl"
        assert audit_path.exists()
        lines = audit_path.read_text().strip().split("\n")
        assert len(lines) == 1
        data = json.loads(lines[0])
        assert data["action"] == "test"
        assert "ts" in data

    def test_multiple(self, tmp_path):
        shared.append_audit(tmp_path, {"action": "a"})
        shared.append_audit(tmp_path, {"action": "b"})
        audit_path = tmp_path / "_ops_edit_audit.jsonl"
        lines = audit_path.read_text().strip().split("\n")
        assert len(lines) == 2


# ── emit / _print_human ──────────────────────────────────────────────────


class TestEmit:
    def test_json_mode(self, capsys):
        shared.emit({"key": "value"}, json_mode=True)
        out = capsys.readouterr().out
        data = json.loads(out)
        assert data["key"] == "value"

    def test_human_mode_dry_run(self, capsys):
        shared.emit({"mode": "dry-run", "action": "test", "plan": {"x": 1}}, json_mode=False)
        out = capsys.readouterr().out
        assert "dry-run" in out
        assert "test" in out

    def test_human_mode_error(self, capsys):
        shared.emit({"mode": "error", "action": "test", "error": "boom"}, json_mode=False)
        out = capsys.readouterr().out
        assert "boom" in out

    def test_human_mode_non_dict(self, capsys):
        shared.emit("plain string", json_mode=False)
        out = capsys.readouterr().out
        assert "plain string" in out


# ── EditContext ──────────────────────────────────────────────────────────


class TestEditContext:
    def _setup(self, tmp_path: Path, uid: str = "u1") -> Path:
        data_dir = tmp_path
        (data_dir / "users").mkdir()
        (data_dir / "users.json").write_text(f'{{"{uid}": {{}}}}')
        user_dir = data_dir / "users" / uid
        user_dir.mkdir()
        return data_dir

    def test_dry_run(self, tmp_path, capsys):
        dd = self._setup(tmp_path)
        ctx = shared.EditContext(data_dir=dd, uid="u1", commit=False, json_mode=True)
        rc = ctx.run(action="test", plan={"x": 1}, apply_fn=lambda: {"result": "ok"})
        assert rc == 0
        out = capsys.readouterr().out
        assert "dry-run" in out

    def test_commit_success(self, tmp_path, capsys):
        dd = self._setup(tmp_path)
        ctx = shared.EditContext(data_dir=dd, uid="u1", commit=True, json_mode=True)
        rc = ctx.run(action="test", plan={"x": 1}, apply_fn=lambda: {"result": "ok"})
        assert rc == 0
        out = capsys.readouterr().out
        assert "commit" in out

    def test_commit_verify_fails(self, tmp_path, capsys):
        dd = self._setup(tmp_path)
        ctx = shared.EditContext(data_dir=dd, uid="u1", commit=True, json_mode=True)
        rc = ctx.run(
            action="test",
            plan={"x": 1},
            apply_fn=lambda: {"result": "ok"},
            verify_fn=lambda: {"ok": False},
        )
        assert rc == 1

    def test_commit_apply_raises(self, tmp_path, capsys):
        dd = self._setup(tmp_path)
        ctx = shared.EditContext(data_dir=dd, uid="u1", commit=True, json_mode=True)
        rc = ctx.run(
            action="test",
            plan={"x": 1},
            apply_fn=lambda: (_ for _ in ()).throw(RuntimeError("boom")),
        )
        assert rc == 1
        out = capsys.readouterr().out
        assert "error" in out

    def test_backup_failure_is_structured_and_skips_apply(self, tmp_path, monkeypatch, capsys):
        dd = self._setup(tmp_path)
        monkeypatch.setattr(
            shared,
            "backup_user_dir",
            lambda *_args: (_ for _ in ()).throw(OSError("sidecar snapshot race")),
        )
        applied = False

        def apply_fn():
            nonlocal applied
            applied = True
            return {"unexpected": True}

        ctx = shared.EditContext(data_dir=dd, uid="u1", commit=True, json_mode=True)
        rc = ctx.run(action="test", plan={"x": 1}, apply_fn=apply_fn)

        assert rc == 1
        assert applied is False
        payload = json.loads(capsys.readouterr().out)
        assert payload["mode"] == "error"
        assert payload["committed"] is False
        assert payload["data_mutated"] is False
        assert payload["failure_stage"] == "backup"
        assert payload["verified"]["ok"] is False
        assert payload["verified"]["stage"] == "backup"
        assert "result" not in payload

    def test_destructive_apply_raises_reports_mutation_and_recovery(self, tmp_path, capsys):
        dd = self._setup(tmp_path)
        ctx = shared.EditContext(data_dir=dd, uid="u1", commit=True, json_mode=True)

        def apply_fn():
            ctx.mark_destructive()
            (ctx.user_dir / "already-removed").write_text("partial", encoding="utf-8")
            raise RuntimeError("boom after destructive step")

        rc = ctx.run(action="test", plan={"replace": True}, apply_fn=apply_fn)

        assert rc == 1
        payload = json.loads(capsys.readouterr().out)
        assert payload["committed"] is False
        assert payload["data_mutated"] is True
        assert Path(payload["backup"]).exists()
        assert "restore u1 --backup" in payload["recovery_path"]

    def test_user_not_found(self, tmp_path):
        dd = tmp_path
        (dd / "users").mkdir()
        (dd / "users.json").write_text("{}")
        with pytest.raises(shared.EditError):
            shared.EditContext(data_dir=dd, uid="ghost", commit=False, json_mode=True)

    def test_require_user_false(self, tmp_path):
        dd = tmp_path
        (dd / "users").mkdir()
        (dd / "users.json").write_text("{}")
        ctx = shared.EditContext(data_dir=dd, uid="newuser", commit=False, json_mode=True, require_user=False)
        assert ctx.user_dir == dd / "users" / "newuser"

    def test_backup_created_on_commit(self, tmp_path):
        dd = self._setup(tmp_path)
        ctx = shared.EditContext(data_dir=dd, uid="u1", commit=True, json_mode=True)
        ctx.run(action="test", plan={}, apply_fn=lambda: {"ok": True})
        backup_dir = dd / "_ops_backups"
        assert backup_dir.exists()
        assert any(backup_dir.iterdir())


# ── _world_snapshot_members ──────────────────────────────────────────────


class TestWorldSnapshotMembers:
    def test_excludes(self, tmp_path):
        (tmp_path / "users.json").write_text("{}")
        (tmp_path / "_ops_backups").mkdir()
        (tmp_path / "_ops_world_backups").mkdir()
        (tmp_path / "_ops_edit_audit.jsonl").write_text("")
        (tmp_path / "users.json.lock").write_text("")
        members = shared._world_snapshot_members(tmp_path)
        names = {m.name for m in members}
        assert "_ops_backups" not in names
        assert "_ops_world_backups" not in names
        assert "users.json" in names
