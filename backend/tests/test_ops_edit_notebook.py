# ruff: noqa: F401, F403, F405, I001
"""test ops edit notebook.py test ownership shard."""

import fcntl

from _ops_edit_support import *  # noqa: F403



class TestNotebookResolver:
    def test_card_add_resolves_notebook_name(self, tmp_path):
        uid = _mk_user(tmp_path)
        nb_id = _mk_notebook(tmp_path, uid, "Classic Literature")
        r = _edit(str(tmp_path), "card-add", uid, "wince", "--meaning", "畏縮",
                  "--notebook", "Classic Literature", "--commit", "--json")
        assert r.returncode == 0, r.stderr
        card = _card_by_content(tmp_path, uid, "wince")
        # 關鍵：notebook_id 必須是 hex id，而非把 name 字串直存（孤兒卡）。
        assert card["notebook_id"] == nb_id
        assert card["notebook_id"] != "Classic Literature"

    def test_card_add_rejects_unknown_notebook(self, tmp_path):
        uid = _mk_user(tmp_path)
        r = _edit(str(tmp_path), "card-add", uid, "ghost", "--meaning", "鬼",
                  "--notebook", "Nonexistent", "--commit", "--json")
        assert r.returncode != 0
        assert "notebook" in (r.stdout + r.stderr).lower()
        assert _card_by_content(tmp_path, uid, "ghost") is None

    def test_card_add_default_still_works(self, tmp_path):
        uid = _mk_user(tmp_path)
        r = _edit(str(tmp_path), "card-add", uid, "plain", "--meaning", "平",
                  "--commit", "--json")
        assert r.returncode == 0, r.stderr
        assert _card_by_content(tmp_path, uid, "plain")["notebook_id"] == "default"

    def test_card_add_accepts_raw_id(self, tmp_path):
        uid = _mk_user(tmp_path)
        nb_id = _mk_notebook(tmp_path, uid, "ById")
        r = _edit(str(tmp_path), "card-add", uid, "byid", "--meaning", "m",
                  "--notebook", nb_id, "--commit", "--json")
        assert r.returncode == 0, r.stderr
        assert _card_by_content(tmp_path, uid, "byid")["notebook_id"] == nb_id

    def test_link_add_resolves_notebook_name(self, tmp_path):
        uid = _mk_user(tmp_path)
        _mk_notebook(tmp_path, uid, "Lit")
        for w, m in [("quill", "羽毛筆"), ("plush", "豪華的")]:
            assert _edit(str(tmp_path), "card-add", uid, w, "--meaning", m,
                         "--notebook", "Lit", "--commit").returncode == 0
        r = _edit(str(tmp_path), "link-add", uid, "quill", "plush",
                  "--kind", "shares_usage", "--confidence", "0.8",
                  "--reason", "both literary", "--notebook", "Lit", "--commit", "--json")
        assert r.returncode == 0, r.stderr

    def test_card_import_resolves_notebook_name(self, tmp_path):
        uid = _mk_user(tmp_path)
        nb_id = _mk_notebook(tmp_path, uid, "Imported")
        csv = tmp_path / "cards.csv"
        csv.write_text("content,meaning\ndecorum,禮節\ndeft,靈巧的\n")
        r = _edit(str(tmp_path), "card-import", uid, str(csv),
                  "--notebook", "Imported", "--commit", "--json")
        assert r.returncode == 0, r.stderr
        assert _card_by_content(tmp_path, uid, "decorum")["notebook_id"] == nb_id

class TestRestoreSafety:
    def test_restore_rejects_foreign_backup(self, tmp_path):
        """指向他人 uid 的備份應在 rmtree 前被擋，victim 目錄完好。"""
        _mk_user(tmp_path, "victim")
        assert _edit(str(tmp_path), "card-add", "victim", "precious",
                     "--meaning", "珍貴", "--commit").returncode == 0
        _mk_user(tmp_path, "attacker")
        assert _edit(str(tmp_path), "card-add", "attacker", "evil",
                     "--meaning", "惡", "--commit").returncode == 0
        foreign = sorted((tmp_path / "_ops_backups").glob("attacker__*.tar.gz"))[-1]
        r = _edit(str(tmp_path), "restore", "victim", "--backup", str(foreign),
                  "--commit", "--json")
        assert r.returncode != 0
        # victim 的資料未被消滅。
        assert _card_by_content(tmp_path, "victim", "precious") is not None

    def test_restore_early_snapshot_ok(self, tmp_path):
        """還原到只含 notebooks.db 的早期快照應視為成功（非 cards.db 缺失=失敗）。"""
        uid = _mk_user(tmp_path)
        # 第一次 card-add 寫前會備份「當前 user_dir」= 只有 notebooks.db。
        assert _edit(str(tmp_path), "card-add", uid, "w1", "--meaning", "m",
                     "--commit").returncode == 0
        early = sorted((tmp_path / "_ops_backups").glob(f"{uid}__*.tar.gz"))[0]
        r = _edit(str(tmp_path), "restore", uid, "--backup", str(early),
                  "--commit", "--json")
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout)["verified"]["ok"] is True

    def test_restore_restores_users_json_config_snapshot(self, tmp_path):
        uid = _mk_user(tmp_path)
        nb_id = _mk_notebook(tmp_path, uid, "Pinned")
        first = _edit(
            str(tmp_path), "user-config-set", uid,
            "--review-clock", "paused",
            "--active-notebook", "Pinned",
            "--commit", "--json",
        )
        assert first.returncode == 0, first.stderr
        second = _edit(
            str(tmp_path), "user-config-set", uid,
            "--review-clock", "running",
            "--commit", "--json",
        )
        assert second.returncode == 0, second.stderr
        latest = json.loads(_edit(str(tmp_path), "list-backups", uid, "--json").stdout)["backups"][0]["path"]
        restored = _edit(str(tmp_path), "restore", uid, "--backup", latest, "--commit", "--json")
        assert restored.returncode == 0, restored.stderr
        users = json.loads((tmp_path / "users.json").read_text())
        cfg = users[uid]["config"]
        assert cfg["review_clock"]["is_paused"] is True
        assert cfg["vocab_ui"]["active_notebook_id"] == nb_id

class TestWorldSnapshots:
    def test_world_snapshot_and_restore_roundtrip(self, tmp_path):
        uid = _mk_user(tmp_path)
        assert _edit(str(tmp_path), "card-add", uid, "baseline", "--meaning", "m", "--commit").returncode == 0
        snap = _edit(str(tmp_path), "world-snapshot", "--label", "baseline", "--commit", "--json")
        assert snap.returncode == 0, snap.stderr
        snapshot_path = json.loads(snap.stdout)["result"]["snapshot"]

        assert _edit(str(tmp_path), "card-add", uid, "after", "--meaning", "m", "--commit").returncode == 0
        assert _mk_user(tmp_path, "other") == "other"
        restore = _edit(str(tmp_path), "world-restore", "--snapshot", snapshot_path, "--commit", "--json")
        assert restore.returncode == 0, restore.stderr
        assert _card_by_content(tmp_path, uid, "baseline") is not None
        assert _card_by_content(tmp_path, uid, "after") is None
        assert not (tmp_path / "users" / "other").exists()

    def test_world_restore_refused_while_worker_lock_held(self, tmp_path):
        uid = _mk_user(tmp_path)
        assert _edit(str(tmp_path), "card-add", uid, "baseline", "--meaning", "m", "--commit").returncode == 0
        snap = _edit(str(tmp_path), "world-snapshot", "--label", "baseline", "--commit", "--json")
        assert snap.returncode == 0, snap.stderr
        snapshot_path = json.loads(snap.stdout)["result"]["snapshot"]
        assert _edit(str(tmp_path), "card-add", uid, "after", "--meaning", "m", "--commit").returncode == 0

        def data_bytes() -> dict[str, bytes]:
            return {
                str(p.relative_to(tmp_path)): p.read_bytes()
                for p in tmp_path.rglob("*")
                if p.is_file() and not any(part.startswith("_ops_") for part in p.relative_to(tmp_path).parts)
            }

        # 模擬執行中的 API：啟動時已建立 .worker.lock 並持有其 flock（同一 inode）。
        (tmp_path / ".worker.lock").touch()
        before = data_bytes()
        with open(tmp_path / ".worker.lock", "a+") as lock_fh:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                restore = _edit(str(tmp_path), "world-restore", "--snapshot", snapshot_path, "--commit", "--json")
            finally:
                fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
        assert restore.returncode != 0
        assert data_bytes() == before
        assert _card_by_content(tmp_path, uid, "after") is not None

class TestImportAtomicity:
    def test_invalid_interval_no_partial_write(self, tmp_path):
        uid = _mk_user(tmp_path)
        csv = tmp_path / "bad.csv"
        csv.write_text(
            "content,meaning,review_state,review_interval\n"
            "good1,m1,due,12\n"
            "bad,m2,due,NOTANUMBER\n"
            "good2,m3,new,\n"
        )
        r = _edit(str(tmp_path), "card-import", uid, str(csv), "--commit", "--json")
        assert r.returncode != 0
        # 預驗應在任何寫入前攔截 → 0 卡落地。
        assert _card_rows(tmp_path, uid) == []

class TestSeedValidation:
    def _seed(self, tmp_path, uid, spec, *extra):
        p = tmp_path / "spec.json"
        p.write_text(json.dumps(spec))
        return _edit(str(tmp_path), "seed", uid, str(p), *extra)

    def test_invalid_json_is_structured_error(self, tmp_path):
        uid = _mk_user(tmp_path)
        p = tmp_path / "notjson.txt"
        p.write_text("{ this is not json")
        r = _edit(str(tmp_path), "seed", uid, str(p), "--commit", "--json")
        assert r.returncode != 0
        # 必須是結構化 error JSON，而非 raw traceback。
        assert "error" in json.loads(r.stdout)

    def test_rejects_blank_meaning(self, tmp_path):
        uid = _mk_user(tmp_path)
        r = self._seed(tmp_path, uid,
                       {"cards": [{"content": "orphan"}]}, "--commit", "--json")
        assert r.returncode != 0
        assert _card_rows(tmp_path, uid) == []

    def test_rejects_invalid_review_state(self, tmp_path):
        uid = _mk_user(tmp_path)
        r = self._seed(tmp_path, uid,
                       {"cards": [{"content": "w", "meaning": "m",
                                   "review": {"state": "bogus"}}]},
                       "--commit", "--json")
        assert r.returncode != 0
        assert _card_rows(tmp_path, uid) == []

    def test_replace_rejects_malformed_typed_fields_before_wipe(self, tmp_path):
        uid = _mk_user(tmp_path)
        assert _edit(str(tmp_path), "card-add", uid, "survivor", "--meaning", "m",
                     "--commit").returncode == 0

        malformed_specs = [
            {"notebooks": [{"name": "N", "color": 123}]},
            {"notebooks": [{"name": "N", "cover_pattern": []}]},
            {"notebooks": [{"name": "N", "source_version": "one"}]},
            {"cards": [{"content": "w", "meaning": "m", "difficulty": "hard"}]},
            {"cards": [{"content": "w", "meaning": "m", "note": []}]},
            {"cards": [{"content": "w", "meaning": "m", "pos": {}}]},
        ]
        for spec in malformed_specs:
            result = self._seed(tmp_path, uid, spec, "--replace", "--commit", "--json")
            assert result.returncode != 0, spec
            assert _card_by_content(tmp_path, uid, "survivor") is not None, spec

    def test_rejects_duplicate_notebook_name(self, tmp_path):
        uid = _mk_user(tmp_path)
        r = self._seed(tmp_path, uid,
                       {"notebooks": [{"name": "Dup"}, {"name": "Dup"}]},
                       "--commit", "--json")
        assert r.returncode != 0

    def test_idempotent_notebooks_and_counts(self, tmp_path):
        uid = _mk_user(tmp_path)
        spec = {
            "notebooks": [{"name": "Novel"}],
            "cards": [
                {"content": "ephemeral", "meaning": "短暫的", "notebook": "Novel"},
                {"content": "serendipity", "meaning": "意外之喜", "notebook": "Novel"},
            ],
        }
        r1 = self._seed(tmp_path, uid, spec, "--commit", "--json")
        assert r1.returncode == 0, r1.stderr
        d1 = json.loads(r1.stdout)["result"]
        assert d1["cards_added"] == 2

        r2 = self._seed(tmp_path, uid, spec, "--commit", "--json")
        assert r2.returncode == 0, r2.stderr
        d2 = json.loads(r2.stdout)["result"]
        # 第二次：notebook 不增殖、卡全為 dup。
        assert d2["cards_added"] == 0
        assert d2.get("skipped_dup") == 2
        names = [n["name"] for n in _notebook_rows(tmp_path, uid)]
        assert names.count("Novel") == 1

    def test_dup_card_upserts_meaning(self, tmp_path):
        uid = _mk_user(tmp_path)
        assert _edit(str(tmp_path), "card-add", uid, "ephemeral",
                     "--meaning", "舊義", "--commit").returncode == 0
        r = self._seed(tmp_path, uid,
                       {"cards": [{"content": "ephemeral", "meaning": "新義"}]},
                       "--commit", "--json")
        assert r.returncode == 0, r.stderr
        # dup 卡的核心欄位應被 upsert，而非靜默保留舊值。
        assert _card_by_content(tmp_path, uid, "ephemeral")["meaning"] == "新義"

    def test_link_cross_notebook_card_resolves(self, tmp_path):
        """seed 內 link 應能解析到本次建立的卡（不因 notebook 過濾而 false 失敗）。"""
        uid = _mk_user(tmp_path)
        spec = {
            "notebooks": [{"name": "NB"}],
            "cards": [
                {"content": "alpha", "meaning": "a", "notebook": "NB"},
                {"content": "beta", "meaning": "b", "notebook": "NB"},
            ],
            "links": [{"from": "alpha", "to": "beta", "kind": "shares_usage",
                       "confidence": 0.7, "reason": "r", "notebook": "NB"}],
        }
        r = self._seed(tmp_path, uid, spec, "--commit", "--json")
        assert r.returncode == 0, r.stderr
        d = json.loads(r.stdout)["result"]
        assert d["links_added"] == 1
        assert d["link_errors"] == []

class TestInputHygiene:
    def test_notebook_create_rejects_path_chars(self, tmp_path):
        uid = _mk_user(tmp_path)
        r = _edit(str(tmp_path), "notebook-create", uid, "../../escape",
                  "--commit", "--json")
        assert r.returncode != 0

    def test_user_create_rejects_dot_prefix(self, tmp_path):
        r = _edit(str(tmp_path), "user-create", ".hidden", "--commit", "--json")
        assert r.returncode != 0


class TestNotebookDeleteVerify:
    @pytest.mark.parametrize("cascade", [False, True], ids=["plain", "cascade"])
    def test_active_notebook_delete_reports_dangling_config(self, tmp_path, cascade):
        uid = _mk_user(tmp_path)
        nb_id = _mk_notebook(tmp_path, uid, "ActiveToDelete")
        if cascade:
            assert _edit(
                str(tmp_path), "card-add", uid, "c1", "--meaning", "m",
                "--notebook", nb_id, "--commit",
            ).returncode == 0
        assert _edit(
            str(tmp_path), "user-config-set", uid, "--active-notebook", nb_id,
            "--commit",
        ).returncode == 0

        command = ["notebook-delete", uid, nb_id]
        if cascade:
            command.append("--cascade")
        result = _edit(str(tmp_path), *command, "--commit", "--json")

        assert result.returncode == 1, result.stderr
        payload = json.loads(result.stdout)
        verified = payload["verified"]
        assert verified["ok"] is False
        assert any(
            f"vocab_ui.active_notebook_id={nb_id}" in message
            for message in verified["dangling_config"]
        )
        assert "user-config-set" in verified["dangling_config"][0]
        assert nb_id not in {row["id"] for row in _notebook_rows(tmp_path, uid)}
        # verify only reports the dangling identity config; it must not reset users.json.
        users = json.loads((tmp_path / "users.json").read_text())
        assert users[uid]["config"]["vocab_ui"]["active_notebook_id"] == nb_id
        if cascade:
            assert _card_rows(tmp_path, uid) == []

    def test_non_active_delete_stays_green_and_preserves_active_config(self, tmp_path):
        uid = _mk_user(tmp_path)
        active_id = _mk_notebook(tmp_path, uid, "KeepActive")
        delete_id = _mk_notebook(tmp_path, uid, "DeleteMe")
        assert _edit(
            str(tmp_path), "user-config-set", uid, "--active-notebook", active_id,
            "--commit",
        ).returncode == 0

        result = _edit(
            str(tmp_path), "notebook-delete", uid, delete_id, "--commit", "--json",
        )

        assert result.returncode == 0, result.stderr
        verified = json.loads(result.stdout)["verified"]
        assert verified["ok"] is True
        assert verified["dangling_config"] == []
        users = json.loads((tmp_path / "users.json").read_text())
        assert users[uid]["config"]["vocab_ui"]["active_notebook_id"] == active_id
        assert delete_id not in {row["id"] for row in _notebook_rows(tmp_path, uid)}

class TestCardUpdateContentConflict:
    def test_rejects_content_collision_same_notebook(self, tmp_path):
        uid = _mk_user(tmp_path)
        for w in ("alpha", "beta"):
            assert _edit(str(tmp_path), "card-add", uid, w, "--meaning", "m",
                         "--commit").returncode == 0
        # 把 alpha 的 content 改成 beta（同 default notebook 已存在）→ 應擋。
        r = _edit(str(tmp_path), "card-update", uid, "alpha",
                  "--set", "content=beta", "--commit", "--json")
        assert r.returncode != 0
        # alpha 內容未被改動。
        assert _card_by_content(tmp_path, uid, "alpha") is not None

class TestReviewState:
    def test_due_time_invariant_on_disk(self, tmp_path):
        uid = _mk_user(tmp_path)
        assert _edit(str(tmp_path), "card-add", uid, "due_word", "--meaning", "m",
                     "--commit").returncode == 0
        r = _edit(str(tmp_path), "card-set-review", uid, "due_word",
                  "--state", "due", "--commit", "--json")
        assert r.returncode == 0, r.stderr
        assert json.loads(r.stdout)["verified"]["ok"] is True
        card = _card_by_content(tmp_path, uid, "due_word")
        nxt = datetime.fromisoformat(card["next_review_at"])
        # SQLite 存無時區、讀回 naive；補 UTC 後才能與 aware now 比較（同工具 _as_utc）。
        if nxt.tzinfo is None:
            nxt = nxt.replace(tzinfo=UTC)
        # due 卡的 next_review_at 必須在過去（TodayReview 撈得到）。
        assert nxt < datetime.now(UTC)

    def test_new_state_clears_next_review(self, tmp_path):
        uid = _mk_user(tmp_path)
        assert _edit(str(tmp_path), "card-add", uid, "nw", "--meaning", "m",
                     "--review", "due", "--commit").returncode == 0
        # 從 due 改回 new → next_review_at 應清空。
        r = _edit(str(tmp_path), "card-set-review", uid, "nw",
                  "--state", "new", "--commit", "--json")
        assert r.returncode == 0, r.stderr
        assert _card_by_content(tmp_path, uid, "nw")["next_review_at"] is None
