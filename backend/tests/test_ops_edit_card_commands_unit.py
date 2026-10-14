"""Unit tests for kg.ops_edit_card_commands — direct function calls.

Covers all cmd_* functions with dry-run + commit paths using real CardStore.
"""

from __future__ import annotations

import argparse
import csv
import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

import kg.ops_edit_card_commands as cards_cmd
from kg.cards import CardStore
from kg.notebook import NotebookStore
from kg.ops_edit_support import EditError


def _setup_user(tmp_path: Path, uid: str = "u1") -> Path:
    data_dir = tmp_path
    (data_dir / "users").mkdir()
    (data_dir / "users.json").write_text(f'{{"{uid}": {{"config": {{}}}}}}')
    user_dir = data_dir / "users" / uid
    user_dir.mkdir()
    # Seed stores so _resolve_notebook_id and _card_store work
    CardStore(user_dir / "cards.db").close()
    NotebookStore(user_dir / "notebooks.db").close()
    return data_dir


def _make_args(**kwargs) -> argparse.Namespace:
    defaults = {
        "uid": "u1",
        "commit": False,
        "json": True,
        "notebook": "default",
        "content": "apple",
        "meaning": "蘋果",
        "pos": None,
        "mode": None,
        "example": None,
        "collocation": None,
        "review": None,
        "note": None,
        "difficulty": None,
        "interval": None,
        "card": "c1",
        "set": None,
        "state": "new",
        "csv": None,
        "to_notebook": "default",
    }
    defaults.update(kwargs)
    return argparse.Namespace(**defaults)


# ── cmd_card_add ─────────────────────────────────────────────────────────


class TestCmdCardAdd:
    def test_dry_run(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_add(_make_args(content="hello", meaning="world"))
        assert rc == 0
        out = capsys.readouterr().out
        assert "dry-run" in out

    def test_commit_creates_card(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_add(_make_args(content="hello", meaning="world", commit=True))
        assert rc == 0
        out = capsys.readouterr().out
        assert "commit" in out
        # Verify card exists
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.find_by_content("hello", notebook_id="default")
            assert c is not None
            assert c.meaning == "world"
        finally:
            store.close()

    def test_commit_with_review_new(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_add(
            _make_args(
                content="hello",
                meaning="world",
                commit=True,
                review="new",
                interval=12.0,
            )
        )
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.find_by_content("hello", notebook_id="default")
            assert c is not None
            assert c.review_count == 0
            assert c.next_review_at is None
        finally:
            store.close()

    def test_commit_with_note_and_difficulty(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_add(
            _make_args(
                content="hello",
                meaning="world",
                commit=True,
                note="a note",
                difficulty=3,
            )
        )
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.find_by_content("hello", notebook_id="default")
            assert c is not None
            assert c.note == "a note"
            assert c.difficulty == 3
        finally:
            store.close()


# ── cmd_card_update ──────────────────────────────────────────────────────


class TestCmdCardUpdate:
    def _seed_card(self, tmp_path: Path, uid: str = "u1") -> str:
        store = CardStore(tmp_path / "users" / uid / "cards.db")
        try:
            c = store.add(content="apple", meaning="蘋果", notebook_id="default")
            return c.id
        finally:
            store.close()

    def test_dry_run(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_update(_make_args(card=cid, set=["meaning=updated"]))
        assert rc == 0
        out = capsys.readouterr().out
        assert "dry-run" in out

    def test_commit_updates_meaning(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_update(_make_args(card=cid, set=["meaning=updated"], commit=True))
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.get(cid)
            assert c is not None
            assert c.meaning == "updated"
        finally:
            store.close()

    def test_commit_updates_content(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_update(_make_args(card=cid, set=["content=banana"], commit=True))
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.get(cid)
            assert c is not None
            assert c.content == "banana"
        finally:
            store.close()

    def test_invalid_set_raises(self, tmp_path, monkeypatch):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        from kg.ops_edit_support import EditError

        with pytest.raises(EditError):
            cards_cmd.cmd_card_update(_make_args(card=cid, set=["badfield=1"]))

    def test_empty_set_raises(self, tmp_path, monkeypatch):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        from kg.ops_edit_support import EditError

        with pytest.raises(EditError):
            cards_cmd.cmd_card_update(_make_args(card=cid, set=[]))

    def test_content_clash_returns_1(self, tmp_path, monkeypatch):
        _setup_user(tmp_path)
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c1 = store.add(content="apple", meaning="A", notebook_id="default")
            store.add(content="banana", meaning="B", notebook_id="default")
        finally:
            store.close()
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_update(_make_args(card=c1.id, set=['content="banana"'], commit=True))
        assert rc == 1


# ── cmd_card_set_review ──────────────────────────────────────────────────


class TestCmdCardSetReview:
    def _seed_card(self, tmp_path: Path) -> str:
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.add(content="apple", meaning="蘋果", notebook_id="default")
            return c.id
        finally:
            store.close()

    def test_dry_run(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_set_review(_make_args(card=cid, state="due", interval=12.0))
        assert rc == 0
        out = capsys.readouterr().out
        assert "dry-run" in out

    def test_commit_new(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_set_review(_make_args(card=cid, state="new", interval=12.0, commit=True))
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.get(cid)
            assert c is not None
            assert c.review_count == 0
            assert c.next_review_at is None
        finally:
            store.close()

    def test_commit_due(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_set_review(_make_args(card=cid, state="due", interval=12.0, commit=True))
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.get(cid)
            assert c is not None
            assert c.review_count == 1
            assert c.next_review_at is not None
            assert c.next_review_at.replace(tzinfo=UTC) < datetime.now(UTC)
        finally:
            store.close()

    def test_commit_reviewed(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_set_review(_make_args(card=cid, state="reviewed", interval=24.0, commit=True))
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.get(cid)
            assert c is not None
            assert c.review_count == 2
            assert c.next_review_at is not None
            assert c.next_review_at.replace(tzinfo=UTC) > datetime.now(UTC)
        finally:
            store.close()

    def test_invalid_state_raises(self, tmp_path, monkeypatch):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        from kg.ops_edit_support import EditError

        with pytest.raises(EditError):
            cards_cmd.cmd_card_set_review(_make_args(card=cid, state="bogus"))


# ── cmd_card_delete ──────────────────────────────────────────────────────


class TestCmdCardDelete:
    def _seed_card(self, tmp_path: Path) -> str:
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.add(content="apple", meaning="蘋果", notebook_id="default")
            return c.id
        finally:
            store.close()

    def test_dry_run(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_delete(_make_args(card=cid))
        assert rc == 0
        out = capsys.readouterr().out
        assert "dry-run" in out

    def test_commit_soft_delete(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid = self._seed_card(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_delete(_make_args(card=cid, commit=True))
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.get(cid)
            assert c is None or c.is_deleted
        finally:
            store.close()


# ── cmd_card_import ──────────────────────────────────────────────────────


class TestCmdCardImport:
    def _make_csv(self, tmp_path: Path, rows: list[dict]) -> Path:
        p = tmp_path / "import.csv"
        with open(p, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["content", "meaning", "pos"])
            w.writeheader()
            w.writerows(rows)
        return p

    def test_dry_run(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        p = self._make_csv(tmp_path, [{"content": "hello", "meaning": "world", "pos": ""}])
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_import(_make_args(csv=str(p)))
        assert rc == 0
        out = capsys.readouterr().out
        assert "dry-run" in out

    def test_commit_imports_rows(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        p = self._make_csv(
            tmp_path,
            [
                {"content": "hello", "meaning": "world", "pos": "n"},
                {"content": "goodbye", "meaning": "再見", "pos": "v"},
            ],
        )
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_import(_make_args(csv=str(p), commit=True))
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            assert store.find_by_content("hello", notebook_id="default") is not None
            assert store.find_by_content("goodbye", notebook_id="default") is not None
        finally:
            store.close()

    def test_missing_csv_raises(self, tmp_path, monkeypatch):
        _setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        from kg.ops_edit_support import EditError

        with pytest.raises(EditError):
            cards_cmd.cmd_card_import(_make_args(csv="/nonexistent.csv"))

    def test_blank_meaning_returns_1(self, tmp_path, monkeypatch):
        _setup_user(tmp_path)
        p = self._make_csv(tmp_path, [{"content": "hello", "meaning": "", "pos": ""}])
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_import(_make_args(csv=str(p), commit=True))
        assert rc == 1

    # ── #3909: 重複卡不得覆寫既有複習態 ──

    def _seed_reviewed_card(self, tmp_path: Path, content: str) -> str:
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            card = store.add(content=content, meaning="蘋果", notebook_id="default")
            store.update(card.id, review_count=200, review_streak=50, review_interval_hours=240.0)
            return card.id
        finally:
            store.close()

    def test_duplicate_row_with_review_state_keeps_existing_review_fields(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        self._seed_reviewed_card(tmp_path, "apple")
        p = tmp_path / "import.csv"
        with open(p, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["content", "meaning", "review_state", "review_interval"])
            w.writeheader()
            w.writerow({"content": "apple", "meaning": "蘋果", "review_state": "new", "review_interval": ""})
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_import(_make_args(csv=str(p), commit=True))
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["result"]["skipped_dup"] == 1
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.find_by_content("apple", notebook_id="default")
            assert c is not None
            assert c.review_count == 200
            assert c.review_streak == 50
            assert c.review_interval_hours == 240.0
        finally:
            store.close()

    def test_new_row_with_review_state_still_applies_review_fields(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        p = tmp_path / "import.csv"
        with open(p, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["content", "meaning", "review_state", "review_interval"])
            w.writeheader()
            w.writerow({"content": "pear", "meaning": "梨", "review_state": "due", "review_interval": "12"})
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_import(_make_args(csv=str(p), commit=True))
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.find_by_content("pear", notebook_id="default")
            assert c is not None
            assert c.review_count == 1
            assert c.review_interval_hours == 12.0
        finally:
            store.close()

    def test_dry_run_reports_duplicate_rows_carrying_review_state(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        self._seed_reviewed_card(tmp_path, "apple")
        p = tmp_path / "import.csv"
        with open(p, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["content", "meaning", "review_state"])
            w.writeheader()
            w.writerow({"content": "apple", "meaning": "蘋果", "review_state": "new"})
            w.writerow({"content": "pear", "meaning": "梨", "review_state": "new"})
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_import(_make_args(csv=str(p)))
        assert rc == 0
        out = json.loads(capsys.readouterr().out)
        assert out["plan"]["dup_review_rows"] == 1

    # ── #3910: 寫入前驗證、destructive 標記、dry-run 同步驗證 ──

    def test_card_import_rejects_nonpositive_interval_before_any_write(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        p = tmp_path / "import.csv"
        with open(p, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["content", "meaning", "review_state", "review_interval"])
            w.writeheader()
            w.writerow({"content": "hello", "meaning": "world", "review_state": "new", "review_interval": ""})
            w.writerow({"content": "goodbye", "meaning": "再見", "review_state": "due", "review_interval": "0"})
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_import(_make_args(csv=str(p), commit=True))
        assert rc == 1
        out = json.loads(capsys.readouterr().out)
        assert out["committed"] is False
        assert out["data_mutated"] is False
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            assert store.find_by_content("hello", notebook_id="default") is None
        finally:
            store.close()

    @pytest.mark.parametrize("bad_interval", ["nan", "inf", "-1", "0"])
    def test_card_import_rejects_bad_interval_in_dry_run(self, tmp_path, monkeypatch, bad_interval):
        _setup_user(tmp_path)
        p = tmp_path / "import.csv"
        with open(p, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["content", "meaning", "review_state", "review_interval"])
            w.writeheader()
            w.writerow(
                {"content": "goodbye", "meaning": "再見", "review_state": "due", "review_interval": bad_interval}
            )
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        with pytest.raises(EditError):
            cards_cmd.cmd_card_import(_make_args(csv=str(p)))

    def test_card_import_midloop_failure_reports_data_mutated(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        p = tmp_path / "import.csv"
        with open(p, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["content", "meaning", "review_state", "review_interval"])
            w.writeheader()
            w.writerow({"content": "hello", "meaning": "world", "review_state": "due", "review_interval": "12"})
            w.writerow({"content": "goodbye", "meaning": "再見", "review_state": "due", "review_interval": "12"})
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        calls = {"n": 0}
        real_update = CardStore.update

        def flaky_update(self, *args, **kwargs):
            calls["n"] += 1
            if calls["n"] == 2:
                raise RuntimeError("boom")
            return real_update(self, *args, **kwargs)

        monkeypatch.setattr(CardStore, "update", flaky_update)
        rc = cards_cmd.cmd_card_import(_make_args(csv=str(p), commit=True))
        assert rc == 1
        out = json.loads(capsys.readouterr().out)
        assert out["data_mutated"] is True
        assert out["recovery_path"] is not None


# ── cmd_card_move ────────────────────────────────────────────────────────


class TestCmdCardMove:
    def _seed_card_and_nb(self, tmp_path: Path) -> tuple[str, str]:
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        nb_store = NotebookStore(tmp_path / "users" / "u1" / "notebooks.db")
        try:
            nb = nb_store.create(name="DestNB")
            c = store.add(content="apple", meaning="蘋果", notebook_id="default")
            return c.id, nb.id
        finally:
            store.close()
            nb_store.close()

    def test_dry_run(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid, nbid = self._seed_card_and_nb(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_move(_make_args(card=cid, to_notebook=nbid))
        assert rc == 0
        out = capsys.readouterr().out
        assert "dry-run" in out

    def test_commit_moves_card(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        cid, nbid = self._seed_card_and_nb(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_move(_make_args(card=cid, to_notebook=nbid, commit=True))
        assert rc == 0
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.get(cid)
            assert c is not None
            assert c.notebook_id == nbid
        finally:
            store.close()

    def test_same_notebook_returns_1(self, tmp_path, monkeypatch):
        _setup_user(tmp_path)
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        try:
            c = store.add(content="apple", meaning="蘋果", notebook_id="default")
        finally:
            store.close()
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        rc = cards_cmd.cmd_card_move(_make_args(card=c.id, to_notebook="default", commit=True))
        assert rc == 1


class TestCmdCardMoveDryRunPreview:
    """#2706:dry-run 須預演唯讀驗證與 link purge,不再假綠。"""

    def test_dry_run_rejects_content_clash(self, tmp_path, monkeypatch):
        _setup_user(tmp_path)
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        nb_store = NotebookStore(tmp_path / "users" / "u1" / "notebooks.db")
        try:
            nb = nb_store.create(name="DestNB")
            c = store.add(content="apple", meaning="蘋果", notebook_id="default")
            store.add(content="apple", meaning="x", notebook_id=nb.id)
        finally:
            store.close()
            nb_store.close()
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        with pytest.raises(EditError):
            cards_cmd.cmd_card_move(_make_args(card=c.id, to_notebook=nb.id))

    def test_dry_run_rejects_missing_card(self, tmp_path, monkeypatch):
        _setup_user(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        with pytest.raises(EditError):
            cards_cmd.cmd_card_move(_make_args(card="ghost", to_notebook="default"))

    def test_dry_run_lists_links_to_purge(self, tmp_path, monkeypatch, capsys):
        _setup_user(tmp_path)
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        nb_store = NotebookStore(tmp_path / "users" / "u1" / "notebooks.db")
        try:
            nb = nb_store.create(name="DestNB")
            c = store.add(content="apple", meaning="蘋果", notebook_id="default")
        finally:
            store.close()
            nb_store.close()
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))

        ud = tmp_path / "users" / "u1"

        def row(lid, status="active"):
            return {
                "id": lid,
                "from_id": c.id,
                "to_id": f"peer-{lid}",
                "kind": "shares_usage",
                "confidence": 0.5,
                "reason": "r",
                "status": status,
            }

        (ud / "graph_default.json").write_text(json.dumps([row("l1"), row("gone", "deprecated")]))
        (ud / f"graph_{nb.id}.json").write_text(json.dumps([row("l2"), {**row("x"), "from_id": "a", "to_id": "b"}]))
        capsys.readouterr()
        assert cards_cmd.cmd_card_move(_make_args(card=c.id, to_notebook=nb.id, json=True)) == 0
        plan = json.loads(capsys.readouterr().out)["plan"]
        assert plan["purge_count"] == 2  # default + DestNB 各一條;deprecated 與無關 link 不算
        assert sorted(plan["purge_link_ids"]) == ["l1", "l2"]
        assert plan["card_id"] == c.id


class TestCmdCardMoveDestructiveReporting:
    """#2312:link 硬刪後才失敗必須回報 data_mutated + recovery_path。"""

    def _seed(self, tmp_path: Path) -> tuple[str, str]:
        _setup_user(tmp_path)
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        nb_store = NotebookStore(tmp_path / "users" / "u1" / "notebooks.db")
        try:
            nb = nb_store.create(name="DestNB")
            c = store.add(content="apple", meaning="蘋果", notebook_id="default")
            return c.id, nb.id
        finally:
            store.close()
            nb_store.close()

    def test_failure_after_link_purge_marks_data_mutated(self, tmp_path, monkeypatch, capsys):
        from types import SimpleNamespace

        cid, nbid = self._seed(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))

        class _Graph:
            def get_links_for(self, _cid):
                return [SimpleNamespace(id="l1")]

            def hard_delete_link(self, *_a, **_k):
                return None

            def remove_candidates_for(self, *_a, **_k):
                return 0

            def remove_pending_judge_for(self, *_a, **_k):
                return 0

        monkeypatch.setattr(cards_cmd, "_graph_store", lambda *_a, **_k: _Graph())
        monkeypatch.setattr(CardStore, "update", lambda *_a, **_k: None)
        capsys.readouterr()

        rc = cards_cmd.cmd_card_move(_make_args(card=cid, to_notebook=nbid, commit=True))

        out = json.loads(capsys.readouterr().out)
        assert rc == 1
        assert out["data_mutated"] is True
        assert out["backup"]
        assert "restore u1" in out["recovery_path"]
        assert out["backup"] in out["recovery_path"]

    def test_already_in_notebook_is_not_mutating(self, tmp_path, monkeypatch, capsys):
        cid, _nbid = self._seed(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        capsys.readouterr()

        rc = cards_cmd.cmd_card_move(_make_args(card=cid, to_notebook="default", commit=True))

        out = json.loads(capsys.readouterr().out)
        assert rc == 1
        assert out["data_mutated"] is False
        assert out["recovery_path"] is None


# ── #2532: card-delete / card-move cleanup parity with the API paths ─────


class _CleanupGraph:
    """Records graph cleanup calls; one active link card<->peer."""

    def __init__(self, card_id: str, peer_id: str = "peer") -> None:
        self.card_id = card_id
        self.peer_id = peer_id
        self.calls: list[tuple] = []

    def refresh_if_stale(self):
        return None

    def get_links_for(self, _cid):
        from types import SimpleNamespace

        return [SimpleNamespace(id="l1", from_id=self.card_id, to_id=self.peer_id)]

    def cleanup_for_card(self, cid, **kwargs):
        self.calls.append(("cleanup_for_card", cid, kwargs))
        return {}

    def hard_delete_link(self, lid, **kwargs):
        self.calls.append(("hard_delete_link", lid))

    def remove_candidates_for(self, cid):
        self.calls.append(("remove_candidates_for", cid))
        return 0

    def remove_pending_judge_for(self, cid):
        self.calls.append(("remove_pending_judge_for", cid))
        return 0


class _EvictRecorder:
    def __init__(self, evicted: list[tuple[str, str]], nb: str) -> None:
        self._evicted = evicted
        self._nb = nb

    def remove(self, card_id):
        self._evicted.append((self._nb, card_id))
        return True


class TestCardDeleteMoveCleanup:
    def _seed(self, tmp_path: Path):
        _setup_user(tmp_path)
        store = CardStore(tmp_path / "users" / "u1" / "cards.db")
        nb_store = NotebookStore(tmp_path / "users" / "u1" / "notebooks.db")
        try:
            nb = nb_store.create(name="DestNB")
            c = store.add(content="apple", meaning="蘋果", notebook_id="default")
            return c.id, nb.id
        finally:
            store.close()
            nb_store.close()

    def _patch(self, monkeypatch, tmp_path, cid):
        graphs: dict[str, _CleanupGraph] = {}
        evicted: list[tuple[str, str]] = []
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        monkeypatch.setattr(
            cards_cmd, "_graph_store", lambda _ud, nb="default": graphs.setdefault(nb, _CleanupGraph(cid))
        )
        monkeypatch.setattr(cards_cmd, "_embedding_store", lambda _ud, nb: _EvictRecorder(evicted, nb))
        return graphs, evicted

    def test_delete_cleans_links_pending_and_evicts_vector(self, tmp_path, monkeypatch):
        cid, _nb = self._seed(tmp_path)
        graphs, evicted = self._patch(monkeypatch, tmp_path, cid)

        assert cards_cmd.cmd_card_delete(_make_args(card=cid, commit=True)) == 0

        assert ("cleanup_for_card", cid, {"remove_blocked": True, "source": "manual"}) in graphs["default"].calls
        assert evicted == [("default", cid)]

    def test_move_clears_old_notebook_pending_candidates_and_vector(self, tmp_path, monkeypatch):
        cid, nbid = self._seed(tmp_path)
        graphs, evicted = self._patch(monkeypatch, tmp_path, cid)

        assert cards_cmd.cmd_card_move(_make_args(card=cid, to_notebook=nbid, commit=True)) == 0

        old = graphs["default"].calls
        assert ("remove_pending_judge_for", cid) in old
        assert ("remove_candidates_for", cid) in old
        assert evicted == [("default", cid)]
