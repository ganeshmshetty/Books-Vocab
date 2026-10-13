"""ops_edit clone-demo 整合測試 — 高保真複製真帳號 vocab 層 + 合成 review history。

clone-demo 把來源帳號的 cards/notebooks/graph/embeddings/candidates 整套 byte-clone
到目標 demo 帳號,並由 cards.db 的複習聚合合成 review_events.db(餵 iOS heatmap)。
全程 tmp_path 沙盒(KG_DATA_DIR 注入),subprocess 跑真 CLI,斷言直接讀盤看磁碟真相:
identity(users.json)不被碰、來源私有檔(sync_state/mochi/pending_judge/.bak)不外洩、
目標舊筆記本 graph 不留孤兒、重跑冪等。
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from kg.review_events import ReviewEventStore, pull_review_events
from ops_helpers import run_ops_edit as _edit

# 生產 cards.db / notebooks.db 的權威 schema(含 runtime migration 加上的欄位:
# pronunciation / root_form / notebook_id …)。clone 全程 raw sqlite + 檔案複製,
# 不經 CardStore,故測試直接用生產 DDL 建表,比 init_schema 基礎表更貼真。
_CARD_DDL = """
CREATE TABLE card (
    id VARCHAR NOT NULL, content VARCHAR NOT NULL, pos VARCHAR, meaning VARCHAR NOT NULL,
    examples JSON, collocations JSON, note VARCHAR, difficulty FLOAT, mode VARCHAR NOT NULL,
    created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, is_deleted BOOLEAN NOT NULL,
    root_form TEXT, inflections TEXT DEFAULT '[]', review_interval_hours REAL DEFAULT 12.0,
    next_review_at TIMESTAMP, last_reviewed_at TIMESTAMP, review_count INTEGER DEFAULT 0,
    lapse_count INTEGER DEFAULT 0, review_streak INTEGER DEFAULT 0,
    last_review_feedback INTEGER DEFAULT -1, pronunciation TEXT, is_archived INTEGER DEFAULT 0,
    notebook_id TEXT DEFAULT 'default', source TEXT, content_nfc_lower TEXT DEFAULT '',
    PRIMARY KEY (id)
)
"""
_NOTEBOOK_DDL = """
CREATE TABLE notebook (
    id VARCHAR NOT NULL, name VARCHAR NOT NULL, color VARCHAR, sort_order INTEGER NOT NULL,
    is_default BOOLEAN NOT NULL, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL,
    is_deleted BOOLEAN NOT NULL, cover_pattern TEXT, PRIMARY KEY (id)
)
"""

SRC = "000287.04e254024c2f4341849278a933743257.0228"  # 仿真 Apple uid(帶點)
TGT = "113011687278246580678"  # 仿真 Google uid

# (id, content, review_count, lapse, streak, feedback, last_reviewed, created, interval, is_deleted)
_SOURCE_CARDS = [
    ("c1", "serendipity", 5, 1, 2, 1, "2026-05-20 10:00:00.000000", "2026-03-01 08:00:00.000000", 200.0, 0),
    ("c2", "ephemeral", 3, 0, 3, 1, "2026-05-25 12:00:00.000000", "2026-03-10 09:00:00.000000", 96.0, 0),
    ("c3", "petrichor", 1, 0, 1, 1, "2026-05-30 14:00:00.000000", "2026-05-29 09:00:00.000000", 48.0, 0),
    ("c4", "nascent", 0, 0, 0, -1, None, "2026-05-31 09:00:00.000000", 12.0, 0),
    ("c5", "obsolete", 2, 0, 2, 1, "2026-04-15 10:00:00.000000", "2026-03-05 08:00:00.000000", 120.0, 1),
]
_EXPECTED_EVENTS = 5 + 3 + 1 + 2  # review_count>0 的卡(含已刪 c5)= 11
_EXPECTED_ACTIVE_CARDS = 4  # c1..c4(c5 已刪)


def _udir(data_dir: Path, uid: str) -> Path:
    return data_dir / "users" / uid


def _insert_card(conn: sqlite3.Connection, row: tuple) -> None:
    cid, content, rc, lapse, streak, fb, last_rev, created, interval, deleted = row
    conn.execute(
        "INSERT INTO card (id, content, pos, meaning, examples, collocations, note, "
        "difficulty, mode, created_at, updated_at, is_deleted, root_form, inflections, "
        "review_interval_hours, next_review_at, last_reviewed_at, review_count, lapse_count, "
        "review_streak, last_review_feedback, pronunciation, is_archived, notebook_id, source, "
        "content_nfc_lower) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            cid,
            content,
            "noun",
            f"def of {content}",
            "[]",
            "[]",
            None,
            0.5,
            "recognition",
            created,
            created,
            deleted,
            None,
            "[]",
            interval,
            None,
            last_rev,
            rc,
            lapse,
            streak,
            fb,
            None,
            0,
            "default",
            None,
            content.lower(),
        ),
    )


def _make_cards_db(path: Path, rows: list[tuple]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.execute(_CARD_DDL)
    for row in rows:
        _insert_card(conn, row)
    conn.commit()
    conn.close()


def _make_notebooks_db(path: Path) -> None:
    conn = sqlite3.connect(str(path))
    conn.execute(_NOTEBOOK_DDL)
    conn.execute(
        "INSERT INTO notebook (id, name, color, sort_order, is_default, created_at, "
        "updated_at, is_deleted, cover_pattern) VALUES "
        "('default','預設',NULL,0,1,'2026-01-01 00:00:00','2026-01-01 00:00:00',0,NULL)"
    )
    conn.commit()
    conn.close()


def _seed_source(data_dir: Path) -> None:
    ud = _udir(data_dir, SRC)
    _make_cards_db(ud / "cards.db", _SOURCE_CARDS)
    _make_notebooks_db(ud / "notebooks.db")
    # graph(2 條 active link)+ 衍生檔
    (ud / "graph_default.json").write_text(
        json.dumps(
            [
                {
                    "id": "l1",
                    "from_id": "c1",
                    "to_id": "c2",
                    "kind": "contrasts_with",
                    "confidence": 0.8,
                    "reason": "r1",
                    "created_at": "2026-03-01T00:00:00Z",
                    "status": "active",
                },
                {
                    "id": "l2",
                    "from_id": "c2",
                    "to_id": "c3",
                    "kind": "shares_usage",
                    "confidence": 0.7,
                    "reason": "r2",
                    "created_at": "2026-03-02T00:00:00Z",
                    "status": "active",
                },
            ]
        ),
        encoding="utf-8",
    )
    (ud / "embeddings_default.npy").write_bytes(b"\x93NUMPY-fake-bytes")
    (ud / "embeddings_meta_default.json").write_text('{"dim":8}', encoding="utf-8")
    (ud / "candidates_default.json").write_text("[]", encoding="utf-8")
    (ud / "card_ids_default.json").write_text('["c1","c2","c3"]', encoding="utf-8")
    (ud / "blocked_default.json").write_text("[]", encoding="utf-8")
    # 來源私有/暫態檔:clone 必須**排除**
    (ud / "sync_state.json").write_text('{"watermark":"x"}', encoding="utf-8")
    (ud / "mochi_map.json").write_text("{}", encoding="utf-8")
    (ud / "pending_judge_default.json").write_text("[]", encoding="utf-8")
    (ud / "cards.db.bak").write_bytes(b"old-backup")


def _seed_target(data_dir: Path) -> None:
    ud = _udir(data_dir, TGT)
    _make_cards_db(
        ud / "cards.db",
        [("t1", "existing", 0, 0, 0, -1, None, "2026-06-01 09:00:00.000000", 12.0, 0)],
    )
    _make_notebooks_db(ud / "notebooks.db")
    # 目標既有筆記本的 graph(不同 notebook id)→ clone 後必須被清,不留孤兒
    (ud / "graph_4638d54cba28.json").write_text("[]", encoding="utf-8")


def _write_users_json(data_dir: Path) -> None:
    (data_dir / "users.json").write_text(
        json.dumps(
            {
                SRC: {"provider": "apple", "email": "max970228@gmail.com", "config": {}},
                TGT: {"provider": "google", "email": "booksvocabtest@gmail.com", "subscription": {"plan": "free"}},
                "_email_index": {"max970228@gmail.com": SRC, "booksvocabtest@gmail.com": TGT},
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )


def _full_fixture(tmp_path: Path) -> Path:
    _seed_source(tmp_path)
    _seed_target(tmp_path)
    _write_users_json(tmp_path)
    return tmp_path


def _active_card_count(data_dir: Path, uid: str) -> int:
    db = _udir(data_dir, uid) / "cards.db"
    conn = sqlite3.connect(str(db))
    n = conn.execute("SELECT COUNT(*) FROM card WHERE is_deleted = 0").fetchone()[0]
    conn.close()
    return n


def _event_count(data_dir: Path, uid: str) -> int:
    db = _udir(data_dir, uid) / "review_events.db"
    if not db.exists():
        return 0
    store = ReviewEventStore(db)
    pulled, _cursor = pull_review_events(since=None, event_store=store)
    store.close()
    return len(pulled)


# ── tests ──────────────────────────────────────────────────


def test_clone_dry_run_writes_nothing(tmp_path):
    _full_fixture(tmp_path)
    r = _edit(str(tmp_path), "clone-demo", SRC, TGT, "--json")
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["mode"] == "dry-run" and out["committed"] is False
    # 目標未被改:仍只有原本 1 張卡、無 review_events、舊 graph 還在
    assert _active_card_count(tmp_path, TGT) == 1
    assert _event_count(tmp_path, TGT) == 0
    assert (_udir(tmp_path, TGT) / "graph_4638d54cba28.json").exists()
    # plan 應揭露來源規模
    assert out["plan"]["source_active_cards"] == 4
    assert out["plan"]["synthesized_events"] == _EXPECTED_EVENTS


def test_clone_commit_mirrors_source_vocab(tmp_path):
    _full_fixture(tmp_path)
    r = _edit(str(tmp_path), "clone-demo", SRC, TGT, "--commit", "--json")
    assert r.returncode == 0, r.stderr
    ud = _udir(tmp_path, TGT)
    assert _active_card_count(tmp_path, TGT) == _EXPECTED_ACTIVE_CARDS
    links = json.loads((ud / "graph_default.json").read_text())
    assert len(links) == 2
    assert (ud / "embeddings_default.npy").read_bytes() == b"\x93NUMPY-fake-bytes"
    assert (ud / "candidates_default.json").exists()
    assert (ud / "card_ids_default.json").exists()
    # 舊筆記本 graph 不留孤兒
    assert not (ud / "graph_4638d54cba28.json").exists()


def test_clone_synthesizes_review_events(tmp_path):
    _full_fixture(tmp_path)
    r = _edit(str(tmp_path), "clone-demo", SRC, TGT, "--commit", "--json")
    assert r.returncode == 0, r.stderr
    assert _event_count(tmp_path, TGT) == _EXPECTED_EVENTS
    out = json.loads(r.stdout)
    assert out["verified"]["ok"] is True
    assert out["verified"]["files_ok"] is True  # 衍生檔大小逐一比對通過


def test_clone_preserves_target_identity(tmp_path):
    _full_fixture(tmp_path)
    _edit(str(tmp_path), "clone-demo", SRC, TGT, "--commit", "--json")
    users = json.loads((tmp_path / "users.json").read_text())
    assert users[TGT]["provider"] == "google"
    assert users[TGT]["email"] == "booksvocabtest@gmail.com"
    assert users[TGT]["subscription"] == {"plan": "free"}
    assert users[SRC]["email"] == "max970228@gmail.com"  # 來源身份亦不動


def test_clone_excludes_source_private_files(tmp_path):
    _full_fixture(tmp_path)
    _edit(str(tmp_path), "clone-demo", SRC, TGT, "--commit", "--json")
    ud = _udir(tmp_path, TGT)
    for name in ("sync_state.json", "mochi_map.json", "pending_judge_default.json", "cards.db.bak"):
        assert not (ud / name).exists(), f"{name} 不該被 clone 進來"


def test_clone_is_idempotent(tmp_path):
    _full_fixture(tmp_path)
    _edit(str(tmp_path), "clone-demo", SRC, TGT, "--commit", "--json")
    first_cards = _active_card_count(tmp_path, TGT)
    first_events = _event_count(tmp_path, TGT)
    r2 = _edit(str(tmp_path), "clone-demo", SRC, TGT, "--commit", "--json")
    assert r2.returncode == 0, r2.stderr
    assert _active_card_count(tmp_path, TGT) == first_cards
    assert _event_count(tmp_path, TGT) == first_events == _EXPECTED_EVENTS


def test_clone_emits_source_fingerprint_and_can_pin_it(tmp_path):
    _full_fixture(tmp_path)
    first = _edit(str(tmp_path), "clone-demo", SRC, TGT, "--commit", "--json")
    assert first.returncode == 0, first.stderr
    fingerprint = json.loads(first.stdout)["result"]["source_fingerprint"]
    assert fingerprint
    pinned = _edit(
        str(tmp_path),
        "clone-demo",
        SRC,
        TGT,
        "--expect-source-fingerprint",
        fingerprint,
        "--commit",
        "--json",
    )
    assert pinned.returncode == 0, pinned.stderr
    mismatch = _edit(
        str(tmp_path),
        "clone-demo",
        SRC,
        TGT,
        "--expect-source-fingerprint",
        "deadbeef",
        "--commit",
        "--json",
    )
    assert mismatch.returncode == 1
    assert "fingerprint" in (mismatch.stdout + mismatch.stderr).lower()


def test_clone_creates_restorable_backup(tmp_path):
    _full_fixture(tmp_path)
    _edit(str(tmp_path), "clone-demo", SRC, TGT, "--commit", "--json")
    r = _edit(str(tmp_path), "list-backups", TGT, "--json")
    out = json.loads(r.stdout)
    assert out["count"] >= 1 and len(out["backups"]) >= 1


def test_clone_rejects_missing_source(tmp_path):
    _seed_target(tmp_path)
    _write_users_json(tmp_path)
    r = _edit(str(tmp_path), "clone-demo", "no-such-uid", TGT, "--commit", "--json")
    assert r.returncode == 1
    assert "source" in (r.stdout + r.stderr).lower()


def test_clone_rejects_unsafe_source_uid(tmp_path):
    _full_fixture(tmp_path)
    r = _edit(str(tmp_path), "clone-demo", "../evil", TGT, "--commit", "--json")
    assert r.returncode == 1


def _run_clone_in_process(data_dir: Path, monkeypatch, capsys, *, fail: bool) -> dict:
    import argparse

    import kg.ops_edit_seed_commands as seed_cmd

    monkeypatch.setenv("KG_DATA_DIR", str(data_dir))
    if fail:
        real_replace = Path.replace

        def boom(self, *a, **k):
            # 只讓 clone 的 .clone-tmp 換入失敗;EditContext 備份自己的 replace 要放行。
            if self.name.endswith(seed_cmd._CLONE_TMP_SUFFIX):
                raise OSError("replace failed")
            return real_replace(self, *a, **k)

        monkeypatch.setattr(Path, "replace", boom)
    args = argparse.Namespace(
        source_uid=SRC,
        target_uid=TGT,
        commit=True,
        json=True,
        expect_source_fingerprint=None,
    )
    capsys.readouterr()
    rc = seed_cmd.cmd_clone_demo(args)
    out = json.loads(capsys.readouterr().out)
    out["_rc"] = rc
    return out


def test_clone_commit_refused_while_worker_lock_held_and_keeps_target_vocab(tmp_path, monkeypatch):
    import fcntl
    from argparse import Namespace

    import pytest

    import kg.ops_edit_seed_commands as seed_cmd
    from kg.worker_guard import WorkerLockHeldError

    _full_fixture(tmp_path)
    ud = _udir(tmp_path, TGT)

    def vocab_bytes() -> dict[str, bytes]:
        return {p.name: p.read_bytes() for p in sorted(ud.iterdir()) if p.is_file()}

    before = vocab_bytes()
    assert "cards.db" in before and any(n.startswith("graph_") for n in before)
    monkeypatch.setattr(seed_cmd, "data_dir", lambda: tmp_path)

    # 模擬執行中的 API：持有 <dd>/.worker.lock 的 flock。
    with open(tmp_path / ".worker.lock", "a+") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            with pytest.raises(seed_cmd.EditError) as exc:
                seed_cmd.cmd_clone_demo(
                    Namespace(source_uid=SRC, target_uid=TGT, commit=True, json=True, expect_source_fingerprint=None)
                )
        finally:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
    assert isinstance(exc.value.__cause__, WorkerLockHeldError)
    assert vocab_bytes() == before


def test_clone_failure_after_unlink_reports_data_mutated(tmp_path, monkeypatch, capsys):
    _full_fixture(tmp_path)
    out = _run_clone_in_process(tmp_path, monkeypatch, capsys, fail=True)
    assert out["_rc"] == 1
    assert out["data_mutated"] is True
    assert out["backup"]
    assert f"restore {TGT}" in out["recovery_path"]
    assert out["backup"] in out["recovery_path"]


def test_clone_staging_failure_is_not_mutating(tmp_path, monkeypatch, capsys):
    import kg.ops_edit_seed_commands as seed_cmd

    _full_fixture(tmp_path)

    def boom(*_a, **_k):
        raise OSError("copy failed")

    monkeypatch.setattr(seed_cmd, "_sqlite_online_backup", boom)
    out = _run_clone_in_process(tmp_path, monkeypatch, capsys, fail=False)
    assert out["_rc"] == 1
    assert out["data_mutated"] is False
    assert out["recovery_path"] is None
