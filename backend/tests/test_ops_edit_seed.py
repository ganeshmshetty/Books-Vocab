# ruff: noqa: F401, F403, F405, I001
"""test ops edit seed.py test ownership shard."""

from argparse import Namespace


from _ops_edit_support import *  # noqa: F403


class TestSeedReplaceWorkerLock:
    def test_replace_commit_refused_while_worker_lock_held_and_keeps_vocab(self, tmp_path, monkeypatch):
        import fcntl

        from kg import ops_edit_seed_commands as seed_commands
        from kg.worker_guard import WorkerLockHeldError

        uid = _mk_user(tmp_path)
        seed_path = tmp_path / "seed.json"
        seed_path.write_text(json.dumps({"cards": [{"content": "saved", "meaning": "m"}]}))
        seeded = _edit(str(tmp_path), "seed", uid, str(seed_path), "--commit", "--json")
        assert seeded.returncode == 0, seeded.stderr

        # plan 階段的唯讀 SQLite 開檔可能補出 -wal/-shm sidecar(非破壞性);主檔 inode+bytes 不變才代表未被 unlink。
        def vocab_state() -> dict[str, tuple[int, bytes]]:
            return {
                p.name: (p.stat().st_ino, p.read_bytes())
                for p in sorted(_user_dir(tmp_path, uid).iterdir())
                if p.is_file() and not p.name.endswith(("-wal", "-shm"))
            }

        before = vocab_state()
        assert "cards.db" in before
        replace_path = tmp_path / "replace.json"
        replace_path.write_text(json.dumps({"cards": [{"content": "fresh", "meaning": "m"}]}))
        monkeypatch.setattr(seed_commands, "data_dir", lambda: tmp_path)

        # 模擬執行中的 API：持有 <dd>/.worker.lock 的 flock（不同 open file description）。
        with open(tmp_path / ".worker.lock", "a+") as lock_fh:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                with pytest.raises(seed_commands.EditError) as exc:
                    seed_commands.cmd_seed(
                        Namespace(uid=uid, commit=True, json=True, replace=True, spec=str(replace_path))
                    )
            finally:
                fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
        assert isinstance(exc.value.__cause__, WorkerLockHeldError)
        assert vocab_state() == before

    def test_replace_commit_lock_os_error_becomes_edit_error_and_keeps_vocab(self, tmp_path, monkeypatch):
        from kg import ops_edit_seed_commands as seed_commands

        uid = _mk_user(tmp_path)
        seed_path = tmp_path / "seed.json"
        seed_path.write_text(json.dumps({"cards": [{"content": "saved", "meaning": "m"}]}))
        seeded = _edit(str(tmp_path), "seed", uid, str(seed_path), "--commit", "--json")
        assert seeded.returncode == 0, seeded.stderr

        def vocab_state() -> dict[str, tuple[int, bytes]]:
            return {
                p.name: (p.stat().st_ino, p.read_bytes())
                for p in sorted(_user_dir(tmp_path, uid).iterdir())
                if p.is_file() and not p.name.endswith(("-wal", "-shm"))
            }

        before = vocab_state()
        replace_path = tmp_path / "replace.json"
        replace_path.write_text(json.dumps({"cards": [{"content": "fresh", "meaning": "m"}]}))
        monkeypatch.setattr(seed_commands, "data_dir", lambda: tmp_path)

        # .worker.lock 是目錄：鎖路徑開檔失敗(IsADirectoryError)，必須翻成 EditError 而非裸 traceback。
        (tmp_path / ".worker.lock").mkdir()
        with pytest.raises(seed_commands.EditError) as exc:
            seed_commands.cmd_seed(Namespace(uid=uid, commit=True, json=True, replace=True, spec=str(replace_path)))
        assert isinstance(exc.value.__cause__, OSError)
        assert vocab_state() == before


class TestSeedReplace:
    def _seed(self, tmp_path, uid, spec, *extra):
        p = tmp_path / "spec.json"
        p.write_text(json.dumps(spec))
        return _edit(str(tmp_path), "seed", uid, str(p), *extra)

    @pytest.mark.parametrize("collection", ("notebooks", "cards", "links"))
    def test_seed_rejects_non_object_collection_entries_before_planning_or_writes(
        self, tmp_path, monkeypatch, collection
    ):
        from kg import ops_edit_seed_commands as seed_commands

        uid = _mk_user(tmp_path)
        baseline = {"cards": [{"content": "saved", "meaning": "m"}]}
        seeded = self._seed(tmp_path, uid, baseline, "--commit", "--json")
        assert seeded.returncode == 0, seeded.stderr

        def snapshot():
            return {
                path.name: path.read_bytes() for path in sorted(_user_dir(tmp_path, uid).iterdir()) if path.is_file()
            }

        before = snapshot()
        malformed = {"notebooks": [], "cards": [], "links": []}
        malformed[collection] = [None]
        path = tmp_path / "malformed.json"
        path.write_text(json.dumps(malformed))

        planned = []

        def unexpected_plan(*args, **kwargs):
            planned.append((args, kwargs))
            pytest.fail("malformed collection entry reached build_seed_plan")

        monkeypatch.setattr(seed_commands, "data_dir", lambda: tmp_path)
        monkeypatch.setattr(seed_commands, "build_seed_plan", unexpected_plan)
        with pytest.raises(seed_commands.EditError, match=rf"{collection}\[0\].*JSON object"):
            seed_commands.cmd_seed(Namespace(uid=uid, commit=True, json=True, replace=True, spec=str(path)))
        assert planned == []
        assert snapshot() == before

        result = self._seed(tmp_path, uid, malformed, "--replace", "--commit", "--json")
        assert result.returncode == 1
        payload = json.loads(result.stdout)
        assert payload["mode"] == "error"
        assert payload["action"] == "seed"
        assert payload["committed"] is False
        assert f"{collection}[0]" in payload["error"]
        assert "JSON object" in payload["error"]
        assert "AttributeError" not in result.stderr
        assert snapshot() == before

    def test_replace_moves_card_between_notebooks_without_duplicating(self, tmp_path):
        uid = _mk_user(tmp_path)
        spec_a = {"notebooks": [{"name": "A"}], "cards": [{"content": "w", "meaning": "m", "notebook": "A"}]}
        spec_b = {"notebooks": [{"name": "B"}], "cards": [{"content": "w", "meaning": "m", "notebook": "B"}]}
        r0 = self._seed(tmp_path, uid, spec_a, "--commit", "--json")
        assert r0.returncode == 0, r0.stderr
        r1 = self._seed(tmp_path, uid, spec_b, "--replace", "--commit", "--json")
        assert r1.returncode == 0, r1.stdout + r1.stderr

        rows = _card_rows(tmp_path, uid)
        assert len(rows) == 1, rows
        nbs = _notebook_rows(tmp_path, uid)
        # notebooks.db 必須讀得回 B —— 若 wipe 寫在建 nb_store 之後,store 會持有
        # 被刪掉的 inode,寫入落到孤兒檔,這條讀盤斷言就轉紅。
        nb_b = next((n for n in nbs if n["name"] == "B"), None)
        assert nb_b is not None, nbs
        assert rows[0]["notebook_id"] == nb_b["id"]
        # 舊本 A 屬於被取代的舊狀態,replace 後不該還在。
        assert [n for n in nbs if n["name"] == "A"] == []

        # 對照組:不帶 --replace 的同序列必須維持 additive 語意(2 張卡)。
        uid2 = _mk_user(tmp_path, "demo2")
        r2 = self._seed(tmp_path, uid2, spec_a, "--commit", "--json")
        assert r2.returncode == 0, r2.stderr
        r3 = self._seed(tmp_path, uid2, spec_b, "--commit", "--json")
        assert r3.returncode == 0, r3.stdout + r3.stderr
        assert len(_card_rows(tmp_path, uid2)) == 2

    def test_replace_wipes_legacy_and_pending_judge_files(self, tmp_path):
        uid = _mk_user(tmp_path)
        user_dir = _user_dir(tmp_path, uid)
        names = ("graph.json", "candidates.json", "blocked.json", "embeddings.npy", "card_ids.json")
        for name in (*names, "pending_judge_default.json"):
            (user_dir / name).write_text("stale")
        r = self._seed(
            tmp_path, uid, {"cards": [{"content": "fresh", "meaning": "m"}]}, "--replace", "--commit", "--json"
        )
        assert r.returncode == 0, r.stderr
        for name in (*names, "pending_judge_default.json"):
            assert not (user_dir / name).exists(), name

    def test_replace_dry_run_does_not_touch_disk(self, tmp_path):
        import hashlib

        uid = _mk_user(tmp_path)
        r0 = self._seed(tmp_path, uid, {"cards": [{"content": "w", "meaning": "m"}]}, "--commit", "--json")
        assert r0.returncode == 0, r0.stderr

        # 快照整個 user_dir 而非單一 cards.db:plan 期 `_count_active_cards` 以
        # mode=ro 開檔,SQLite 在「有 -wal 無 -shm」時會重建 -shm 旁檔,而它跑在
        # plan["wipe_files"] 之後 —— 只 hash cards.db 看不到這種副作用。
        def _snapshot():
            d = _user_dir(tmp_path, uid)
            return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(d.iterdir()) if p.is_file()}

        before = _snapshot()
        assert "cards.db" in before

        r1 = self._seed(tmp_path, uid, {"cards": [{"content": "other", "meaning": "m2"}]}, "--replace", "--json")
        assert r1.returncode == 0, r1.stdout + r1.stderr
        after = _snapshot()
        # 既有檔一 byte 未變。
        assert {k: v for k, v in after.items() if k in before} == before
        # dry-run 只可能多出 SQLite 讀 WAL 模式 DB 時重建的旁檔,不得多出別的。
        new_files = set(after) - set(before)
        assert all(n.endswith(("-wal", "-shm")) for n in new_files), new_files
        plan = json.loads(r1.stdout)["plan"]
        assert plan["replace"] is True
        assert "cards.db" in plan["wipe_files"], plan
        assert plan["target_active_cards_before"] == 1
        # 那些旁檔一樣會被 wipe 刪掉,所以必須出現在預覽裡 —— 預覽少報等於沒預覽。
        assert new_files <= set(plan["wipe_files"]), (new_files, plan["wipe_files"])

    def test_replace_verify_reports_exact_shape(self, tmp_path):
        uid = _mk_user(tmp_path)
        r = self._seed(
            tmp_path,
            uid,
            {
                "notebooks": [{"name": "A"}],
                "cards": [
                    {"content": "alpha", "meaning": "m1", "notebook": "A"},
                    {"content": "beta", "meaning": "m2", "notebook": "A"},
                ],
            },
            "--replace",
            "--commit",
            "--json",
        )
        assert r.returncode == 0, r.stdout + r.stderr
        verified = json.loads(r.stdout)["verified"]
        assert verified["ok"] is True
        assert verified["extra_cards"] == []
        assert verified["missing_cards"] == []
        assert verified["total_cards"] == 2

    def test_replace_rebuilds_default_notebook(self, tmp_path):
        uid = _mk_user(tmp_path)
        r = self._seed(
            tmp_path, uid, {"cards": [{"content": "plain", "meaning": "m"}]}, "--replace", "--commit", "--json"
        )
        assert r.returncode == 0, r.stdout + r.stderr
        card = _card_by_content(tmp_path, uid, "plain")
        assert card is not None
        assert card["notebook_id"] == "default"
        assert [n for n in _notebook_rows(tmp_path, uid) if n["id"] == "default"]

    def test_seed_shape_diff_detects_extra_and_missing(self, tmp_path):
        # 函式內 import:實作落地前 module 尚無此符號,放檔頭會讓整個 test 檔
        # 收集失敗、連累無關測試。
        from kg.ops_edit_seed_commands import _seed_shape_diff

        expected = [
            {"nb_id": "n1", "content": "Alpha", "meaning": ""},
            {"nb_id": "n2", "content": "beta", "meaning": ""},
        ]
        actual = [("n1", "alpha"), ("n2", "gamma")]
        extra, missing = _seed_shape_diff(expected, actual)
        # Alpha/alpha 經 normalize_nfc_lower 視為同一張 → 不進 extra/missing。
        assert extra == ["gamma@n2"]
        assert missing == ["beta@n2"]

    def test_replace_verdict_rejects_leftover_duplicate(self, tmp_path):
        # 這條判準只有「wipe 沒清乾淨」時才轉紅,而那個狀態走 CLI 產不出來
        # (cards 只住 cards.db,wipe 必清它)。所以直接餵髒狀態給純函式,
        # 否則這道守衛平時無人執行 —— 沒人查的判準等於假的。
        from kg.ops_edit_seed_commands import _seed_replace_verdict

        expected = [{"nb_id": "nbB", "content": "w", "meaning": "m"}]
        # 殘留:舊本 nbA 的 w 沒被清掉,新本 nbB 又建了一張 → 重複卡。
        dirty = _seed_replace_verdict(
            expected, [("nbA", "w"), ("nbB", "w")], link_errors=[], field_mismatches=[], dangling_config=[]
        )
        assert dirty["ok"] is False
        assert dirty["extra_cards"] == ["w@nbA"]
        assert dirty["missing_cards"] == []
        # 卡留在舊本、新本沒建(換分類只做了一半):筆數**對得上**,只有集合差抓得到。
        misplaced = _seed_replace_verdict(
            expected, [("nbA", "w")], link_errors=[], field_mismatches=[], dangling_config=[]
        )
        assert misplaced["ok"] is False
        assert misplaced["extra_cards"] == ["w@nbA"]
        assert misplaced["missing_cards"] == ["w@nbB"]
        # 大小寫變體重複(同本 w + W):正規化後兩者 key 相同,集合差**看不見**它,
        # 只有「筆數要對得上」那一半抓得到。兩個 clause 各抓一種重複形狀,缺一不可。
        case_dupe = _seed_replace_verdict(
            expected, [("nbB", "w"), ("nbB", "W")], link_errors=[], field_mismatches=[], dangling_config=[]
        )
        assert case_dupe["ok"] is False
        assert case_dupe["extra_cards"] == []
        assert case_dupe["missing_cards"] == []
        # 乾淨狀態才給綠 —— 沒有正控的沉默不能當通過。
        clean = _seed_replace_verdict(expected, [("nbB", "w")], link_errors=[], field_mismatches=[], dangling_config=[])
        assert clean["ok"] is True
        assert clean["extra_cards"] == []

    def test_replace_rejects_undeclared_notebook_ref_before_wiping(self, tmp_path):
        # replace 會清掉「既存 notebook」這個合法參照來源,所以引用既存本的 spec
        # 在 replace 下必須**在 wipe 之前**就紅。否則 dry-run 報綠、--commit 清空
        # 整層後才在 _resolve_nb 撞紅,而錯誤輸出還寫著 "committed": false。
        uid = _mk_user(tmp_path)
        r0 = self._seed(
            tmp_path,
            uid,
            {"notebooks": [{"name": "A"}], "cards": [{"content": "w", "meaning": "m", "notebook": "A"}]},
            "--commit",
            "--json",
        )
        assert r0.returncode == 0, r0.stderr
        # spec 未宣告 A,卻用 A 當 card 的 notebook。
        undeclared = {"cards": [{"content": "z", "meaning": "m2", "notebook": "A"}]}
        rd = self._seed(tmp_path, uid, undeclared, "--replace", "--json")
        assert rd.returncode != 0, rd.stdout
        assert "A" in (rd.stdout + rd.stderr)
        rc = self._seed(tmp_path, uid, undeclared, "--replace", "--commit", "--json")
        assert rc.returncode != 0
        # 讀盤,不看工具自述:舊資料必須原封不動(wipe 根本不該發生)。
        rows = _card_rows(tmp_path, uid)
        assert [r["content"] for r in rows] == ["w"], rows
        assert [n["name"] for n in _notebook_rows(tmp_path, uid) if n["name"] == "A"] == ["A"]

    def test_replace_allows_reference_to_default_and_declared(self, tmp_path):
        # 正控:未加這道檢查前上面那條也會綠(它靠 _resolve_nb 事後爆)。這條確保
        # 新檢查沒有把合法的 spec 一起擋掉 —— 沒有正控的沉默不算通過。
        uid = _mk_user(tmp_path)
        r = self._seed(
            tmp_path,
            uid,
            {
                "notebooks": [{"name": "B"}],
                "cards": [
                    {"content": "x", "meaning": "m", "notebook": "B"},
                    {"content": "x2", "meaning": "m", "notebook": "B"},
                    {"content": "y", "meaning": "m", "notebook": "default"},
                    {"content": "q", "meaning": "m"},
                ],
                "links": [
                    {"from": "x", "to": "x2", "kind": "shares_usage", "confidence": 0.5, "reason": "r", "notebook": "B"}
                ],
            },
            "--replace",
            "--commit",
            "--json",
        )
        assert r.returncode == 0, r.stdout + r.stderr
        verified = json.loads(r.stdout)["verified"]
        assert verified["ok"] is True, verified
        assert verified["link_errors"] == []
        assert sorted(c["content"] for c in _card_rows(tmp_path, uid)) == ["q", "x", "x2", "y"]

    def test_replace_reports_dangling_active_notebook(self, tmp_path):
        # --replace 刻意不動 identity/users.json,於是 active notebook 指標會指向
        # 剛被清掉的舊 id。卡的形狀完全正確,只看卡就會報綠 —— 這是同族的第三種
        # 說謊,demo 帳號「新選詞歸哪本」實際上懸空。
        uid = _mk_user(tmp_path)
        r0 = self._seed(
            tmp_path,
            uid,
            {"notebooks": [{"name": "A"}], "cards": [{"content": "w", "meaning": "m", "notebook": "A"}]},
            "--commit",
            "--json",
        )
        assert r0.returncode == 0, r0.stderr
        old_id = next(n["id"] for n in _notebook_rows(tmp_path, uid) if n["name"] == "A")
        rc = _edit(str(tmp_path), "user-config-set", uid, "--active-notebook", "A", "--commit", "--json")
        assert rc.returncode == 0, rc.stderr

        r1 = self._seed(
            tmp_path,
            uid,
            {"notebooks": [{"name": "B"}], "cards": [{"content": "w", "meaning": "m", "notebook": "B"}]},
            "--replace",
            "--commit",
            "--json",
        )
        verified = json.loads(r1.stdout)["verified"]
        # 卡的形狀是對的 —— 正是「只看卡會報綠」的那一半。
        assert verified["extra_cards"] == []
        assert verified["missing_cards"] == []
        # 但整體判準必須紅,而且要指名是誰懸空。
        assert verified["ok"] is False, verified
        assert len(verified["dangling_config"]) == 1, verified
        msg = verified["dangling_config"][0]
        # 指名是誰懸空(那個 id 由上面的 _notebook_rows 讀盤取得,非工具回顯)…
        assert f"vocab_ui.active_notebook_id={old_id}" in msg
        # …並且指路,否則 operator 只知道紅、不知道怎麼修。
        assert "user-config-set" in msg
        assert r1.returncode == 1

    def test_replace_clean_run_has_no_dangling_config(self, tmp_path):
        # 正控:沒設過 active notebook 的帳號不該被這道檢查誤傷。
        uid = _mk_user(tmp_path)
        r = self._seed(
            tmp_path,
            uid,
            {"notebooks": [{"name": "B"}], "cards": [{"content": "w", "meaning": "m", "notebook": "B"}]},
            "--replace",
            "--commit",
            "--json",
        )
        assert r.returncode == 0, r.stdout + r.stderr
        verified = json.loads(r.stdout)["verified"]
        assert verified["dangling_config"] == []
        assert verified["ok"] is True
        assert verified["expected_cards"] == 1

    def test_replace_survives_unreadable_users_json(self, tmp_path):
        # verify_fn 是第一個嚴格讀 users.json 的地方,而它跑在 EditContext 的
        # try/except **之外**、且在破壞性 wipe 已落地之後。裸 traceback 會噴上
        # --json stdout(cmd_seed 自己為 spec 解析捍衛過同一條契約),operator 會
        # 拿到空 stdout 卻已經沒有資料。壞掉必須是**具名的紅**,不是 crash。
        uid = _mk_user(tmp_path)
        spec = {"notebooks": [{"name": "B"}], "cards": [{"content": "w", "meaning": "m", "notebook": "B"}]}
        (tmp_path / "users.json").write_text("{ this is not json")
        r = self._seed(tmp_path, uid, spec, "--replace", "--commit", "--json")
        # stdout 仍是合法 JSON —— 這條斷言碰的字串是 CLI 的 stdout 本身。
        payload = json.loads(r.stdout)
        assert payload["verified"]["ok"] is False
        assert any("users.json" in s for s in payload["verified"]["dangling_config"]), payload
        assert r.returncode == 1

    def test_replace_rejects_non_string_active_notebook(self, tmp_path):
        # isinstance 階梯守住每一層 dict 卻沒守葉子值時,`active_nb in live_nb_ids`
        # 會以 unhashable TypeError 炸在同一個 try 之外。
        uid = _mk_user(tmp_path)
        users = json.loads((tmp_path / "users.json").read_text())
        users[uid].setdefault("config", {})["vocab_ui"] = {"active_notebook_id": {"oops": 1}}
        (tmp_path / "users.json").write_text(json.dumps(users))
        r = self._seed(
            tmp_path,
            uid,
            {"notebooks": [{"name": "B"}], "cards": [{"content": "w", "meaning": "m", "notebook": "B"}]},
            "--replace",
            "--commit",
            "--json",
        )
        payload = json.loads(r.stdout)
        assert payload["verified"]["ok"] is False
        assert any("型別非法" in s for s in payload["verified"]["dangling_config"]), payload
        assert r.returncode == 1


def test_seed_meaning_overwrite_on_dup_card_evicts_vector_and_requeues_judging(tmp_path, monkeypatch):
    """#2957: a dup card whose meaning the seed overwrites must drop its vector and re-queue judging."""
    import kg.ops_edit_seed_commands as seed_mod
    from kg.ops_edit_shared import EditContext

    uid = _mk_user(tmp_path)
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps({"cards": [{"content": "w", "meaning": "旧"}]}))
    r0 = _edit(str(tmp_path), "seed", uid, str(spec_path), "--commit", "--json")
    assert r0.returncode == 0, r0.stderr
    card_id = _card_rows(tmp_path, uid)[0]["id"]

    spec_path.write_text(json.dumps({"cards": [{"content": "w", "meaning": "新"}]}))
    evicted: list[str] = []
    queued: list[str] = []

    class _Emb:
        def remove(self, cid):
            evicted.append(cid)

    class _Graph:
        def add_pending_judge(self, cid):
            queued.append(cid)

    monkeypatch.setattr(seed_mod, "_embedding_store", lambda *_a, **_k: _Emb())
    monkeypatch.setattr(seed_mod, "_graph_store", lambda *_a, **_k: _Graph())
    ctx = EditContext(data_dir=tmp_path, uid=uid, commit=True, json_mode=True)
    seed_mod.apply_seed(seed_mod.load_seed_spec(spec_path), ctx, {}, replace=False)

    assert [r["meaning"] for r in _card_rows(tmp_path, uid)] == ["新"]
    assert evicted == [card_id]
    assert queued == [card_id]
