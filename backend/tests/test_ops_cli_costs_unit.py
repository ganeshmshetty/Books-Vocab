"""Unit tests for kg.ops_cli_costs — direct function calls."""

from __future__ import annotations

import argparse
import json
import sqlite3
from datetime import UTC, datetime, timedelta
from pathlib import Path

import kg.ops_cli_costs as costs


def _make_args(**kwargs) -> argparse.Namespace:
    defaults = {"uid": "u1", "json": True, "range": "24h"}
    defaults.update(kwargs)
    return argparse.Namespace(**defaults)


def _seed_token_db(tmp_path: Path) -> Path:
    conn = sqlite3.connect(str(tmp_path / "token_usage.db"))
    conn.execute(
        "CREATE TABLE token_usage (id INTEGER PRIMARY KEY, user_id TEXT, "
        "call_type TEXT, input_tokens INTEGER, output_tokens INTEGER, created_at TEXT)"
    )
    now = datetime.now(UTC).isoformat()
    conn.execute(
        "INSERT INTO token_usage (user_id, call_type, input_tokens, output_tokens, created_at) VALUES (?, ?, ?, ?, ?)",
        ("u1", "translate", 100, 50, now),
    )
    conn.commit()
    conn.close()
    return tmp_path


class TestCmdCost:
    def test_empty_db(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        costs.cmd_cost(_make_args(uid="u1"))
        out = capsys.readouterr().out
        assert "u1" in out

    def test_with_data(self, tmp_path, monkeypatch, capsys):
        _seed_token_db(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        costs.cmd_cost(_make_args(uid="u1"))
        out = capsys.readouterr().out
        assert "translate" in out.lower()

    def test_text_output(self, tmp_path, monkeypatch, capsys):
        _seed_token_db(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        costs.cmd_cost(_make_args(uid="u1", json=False))
        out = capsys.readouterr().out
        assert "$" in out


class TestCmdCostOverview:
    def test_empty_db(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        costs.cmd_cost_overview(_make_args())
        out = capsys.readouterr().out
        assert "count" in out.lower() or "users" in out.lower()

    def test_with_data(self, tmp_path, monkeypatch, capsys):
        _seed_token_db(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        costs.cmd_cost_overview(_make_args())
        out = capsys.readouterr().out
        assert "u1" in out

    def test_text_output(self, tmp_path, monkeypatch, capsys):
        _seed_token_db(tmp_path)
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        costs.cmd_cost_overview(_make_args(json=False))
        out = capsys.readouterr().out
        assert "$" in out


class TestCmdFleetOverview:
    def test_offset_aware_month_boundary_uses_utc_instants(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        monkeypatch.setattr(costs, "since_iso", lambda _: "2026-05-01T00:00:00+00:00")
        (tmp_path / "users" / "u1").mkdir(parents=True)

        conn = sqlite3.connect(str(tmp_path / "token_usage.db"))
        conn.execute(
            "CREATE TABLE token_usage (id INTEGER PRIMARY KEY, user_id TEXT, "
            "call_type TEXT, input_tokens INTEGER, output_tokens INTEGER, created_at TEXT)"
        )
        conn.executemany(
            "INSERT INTO token_usage (user_id, call_type, input_tokens, output_tokens, created_at) "
            "VALUES (?, ?, ?, ?, ?)",
            [
                ("u1", "translate", 100, 50, "2026-05-01T00:00:00+01:00"),
                ("u1", "translate", 100, 50, "2026-05-01T00:30:00+00:00"),
            ],
        )
        conn.commit()
        conn.close()

        costs.cmd_fleet_overview(_make_args())
        payload = json.loads(capsys.readouterr().out)

        assert payload["totals"]["month_calls"] == 1

    def test_empty_data_dir(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        costs.cmd_fleet_overview(_make_args())
        out = capsys.readouterr().out
        assert "count" in out.lower() or "users" in out.lower()

    def test_with_user(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        user_dir = tmp_path / "users" / "u1"
        user_dir.mkdir(parents=True)
        (tmp_path / "users.json").write_text('{"u1": {"config": {}}}')

        conn = sqlite3.connect(str(user_dir / "cards.db"))
        conn.execute("CREATE TABLE card (id TEXT PRIMARY KEY, content TEXT, is_deleted INTEGER)")
        conn.execute("INSERT INTO card VALUES ('c1', 'apple', 0)")
        conn.commit()
        conn.close()

        costs.cmd_fleet_overview(_make_args())
        out = capsys.readouterr().out
        assert "u1" in out

    def test_text_output(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        costs.cmd_fleet_overview(_make_args(json=False))
        out = capsys.readouterr().out
        assert "fleet" in out.lower() or "users" in out.lower()


def _seed_token_rows(tmp_path: Path, created_ats: list[str]) -> None:
    conn = sqlite3.connect(str(tmp_path / "token_usage.db"))
    conn.execute(
        "CREATE TABLE token_usage (id INTEGER PRIMARY KEY, user_id TEXT, "
        "call_type TEXT, input_tokens INTEGER, output_tokens INTEGER, created_at TEXT)"
    )
    conn.executemany(
        "INSERT INTO token_usage (user_id, call_type, input_tokens, output_tokens, created_at) VALUES (?, ?, ?, ?, ?)",
        [("u1", "translate", 100, 50, ts) for ts in created_ats],
    )
    conn.commit()
    conn.close()


class TestCmdCostRetentionDisclosure:
    """range=all is lifetime only up to the token_usage prune horizon (#3459)."""

    def test_range_all_json_discloses_retention_window(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        monkeypatch.delenv("TOKEN_USAGE_RETENTION_DAYS", raising=False)
        oldest = (datetime.now(UTC) - timedelta(days=200)).isoformat()
        _seed_token_rows(tmp_path, [oldest, datetime.now(UTC).isoformat()])

        costs.cmd_cost(_make_args(uid="u1", range="all", json=True))
        payload = json.loads(capsys.readouterr().out)

        assert payload["retention_days"] == 90
        assert payload["oldest_retained_at"] == oldest

    def test_range_all_json_honours_env_override(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        monkeypatch.setenv("TOKEN_USAGE_RETENTION_DAYS", "30")
        _seed_token_rows(tmp_path, [datetime.now(UTC).isoformat()])

        costs.cmd_cost(_make_args(uid="u1", range="all", json=True))
        payload = json.loads(capsys.readouterr().out)

        assert payload["retention_days"] == 30

    def test_range_all_empty_db_has_null_oldest(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        costs.cmd_cost(_make_args(uid="u1", range="all", json=True))
        payload = json.loads(capsys.readouterr().out)

        assert payload["retention_days"] == 90
        assert payload["oldest_retained_at"] is None

    def test_range_all_text_shows_retention_line(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        _seed_token_rows(tmp_path, [datetime.now(UTC).isoformat()])

        costs.cmd_cost(_make_args(uid="u1", range="all", json=False))
        out = capsys.readouterr().out

        assert "Retention: 90 days" in out

    def test_bounded_range_omits_retention_fields(self, tmp_path, monkeypatch, capsys):
        monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
        _seed_token_rows(tmp_path, [datetime.now(UTC).isoformat()])

        costs.cmd_cost(_make_args(uid="u1", range="24h", json=True))
        payload = json.loads(capsys.readouterr().out)

        assert "retention_days" not in payload
        assert "oldest_retained_at" not in payload
