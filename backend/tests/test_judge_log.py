"""Tests for judge_log module."""

from __future__ import annotations

import pytest


def test_record_and_retrieve(tmp_path, monkeypatch):
    """Insert accepted decision, verify all fields round-trip."""
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))

    # Force reimport with fresh env
    import importlib

    from kg import judge_log

    importlib.reload(judge_log)
    judge_log._reset()

    judge_log.record(
        user_id="u1",
        notebook_id="nb1",
        from_id="card_a",
        to_id="card_b",
        similarity=0.85,
        verdict="shares_usage",
        confidence=0.92,
        accepted=True,
        reject_reason=None,
        reason="兩詞都描述光澤",
        source="auto",
    )

    rows = judge_log.get_log("u1")
    assert len(rows) == 1
    r = rows[0]
    assert r["user_id"] == "u1"
    assert r["notebook_id"] == "nb1"
    assert r["from_id"] == "card_a"
    assert r["to_id"] == "card_b"
    assert abs(r["similarity"] - 0.85) < 1e-6
    assert r["verdict"] == "shares_usage"
    assert abs(r["confidence"] - 0.92) < 1e-6
    assert r["accepted"] is True
    assert r["reject_reason"] is None
    assert r["reason"] == "兩詞都描述光澤"
    assert r["source"] == "auto"
    assert r["created_at"]  # non-empty timestamp

    judge_log._reset()


def test_record_rejection(tmp_path, monkeypatch):
    """Insert rejected decision, verify reject_reason stored."""
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))

    import importlib

    from kg import judge_log

    importlib.reload(judge_log)
    judge_log._reset()

    judge_log.record(
        user_id="u1",
        notebook_id="nb1",
        from_id="card_a",
        to_id="card_c",
        similarity=0.72,
        verdict="not_applicable",
        confidence=0.3,
        accepted=False,
        reject_reason="low_confidence",
        reason="無明顯關聯",
        source="auto",
    )

    rows = judge_log.get_log("u1")
    assert len(rows) == 1
    r = rows[0]
    assert r["accepted"] is False
    assert r["reject_reason"] == "low_confidence"
    assert r["verdict"] == "not_applicable"

    # Test notebook filter
    rows2 = judge_log.get_log("u1", notebook_id="nb1")
    assert len(rows2) == 1
    rows3 = judge_log.get_log("u1", notebook_id="other")
    assert len(rows3) == 0

    judge_log._reset()


def test_get_log_normalizes_legacy_text_boolean_values(tmp_path, monkeypatch):
    """Legacy SQLite text booleans must not turn false rows into accepts."""
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))

    import importlib

    from kg import judge_log

    importlib.reload(judge_log)
    judge_log._reset()

    for to_id, accepted, reject_reason, source in [
        ("native_true", True, None, "auto"),
        ("native_false", False, "low_confidence", "auto"),
        ("degree_cap", False, "degree_cap", "auto"),
        ("legacy_true", True, None, "manual"),
        ("legacy_false", False, "low_confidence", "manual"),
    ]:
        judge_log.record(
            user_id="u1",
            notebook_id="nb1",
            from_id="a",
            to_id=to_id,
            similarity=0.8,
            verdict="shares_usage",
            confidence=0.9,
            accepted=accepted,
            reject_reason=reject_reason,
            source=source,
        )

    conn = judge_log._get_conn()
    conn.execute("UPDATE judge_log SET accepted = ? WHERE to_id = ?", ("true", "legacy_true"))
    conn.execute("UPDATE judge_log SET accepted = ? WHERE to_id = ?", ("false", "legacy_false"))
    conn.commit()

    rows = {row["to_id"]: row for row in judge_log.get_log("u1")}
    assert rows["native_true"]["accepted"] is True
    assert rows["native_false"]["accepted"] is False
    assert rows["legacy_true"]["accepted"] is True
    assert rows["legacy_false"]["accepted"] is False

    # Native auto rows keep the existing aggregate and degree-cap semantics.
    assert judge_log.get_acceptance_stats() == {
        "total": 2,
        "accepted": 1,
        "rejected": 1,
        "rate": 0.5,
    }

    judge_log._reset()


def test_acceptance_stats(tmp_path, monkeypatch):
    """get_acceptance_stats returns correct rate from auto judge decisions."""
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))

    import importlib

    from kg import judge_log

    importlib.reload(judge_log)
    judge_log._reset()

    # Empty DB
    stats = judge_log.get_acceptance_stats()
    assert stats["total"] == 0
    assert stats["rate"] is None

    # 2 accepted, 1 rejected
    for accepted, verdict in [(True, "shares_usage"), (True, "contrasts_with"), (False, "not_applicable")]:
        judge_log.record(
            user_id="u1",
            notebook_id="nb1",
            from_id="a",
            to_id="b",
            similarity=0.8,
            verdict=verdict,
            confidence=0.9,
            accepted=accepted,
            source="auto",
        )

    # 1 manual (should be excluded from stats)
    judge_log.record(
        user_id="u1",
        notebook_id="nb1",
        from_id="a",
        to_id="c",
        similarity=None,
        verdict="shares_usage",
        confidence=1.0,
        accepted=True,
        source="manual",
    )

    stats = judge_log.get_acceptance_stats()
    assert stats["total"] == 3
    assert stats["accepted"] == 2
    assert stats["rejected"] == 1
    assert abs(stats["rate"] - 0.6667) < 0.001

    judge_log._reset()


def test_acceptance_stats_per_user(tmp_path, monkeypatch):
    """get_acceptance_stats with user_id filters to that user only."""
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))

    import importlib

    from kg import judge_log

    importlib.reload(judge_log)
    judge_log._reset()

    # u1: 2 accepted, 1 rejected
    for accepted, verdict in [(True, "shares_usage"), (True, "contrasts_with"), (False, "not_applicable")]:
        judge_log.record(
            user_id="u1",
            notebook_id="nb1",
            from_id="a",
            to_id="b",
            similarity=0.8,
            verdict=verdict,
            confidence=0.9,
            accepted=accepted,
            source="auto",
        )
    # u2: 1 accepted
    judge_log.record(
        user_id="u2",
        notebook_id="nb1",
        from_id="x",
        to_id="y",
        similarity=0.7,
        verdict="shares_usage",
        confidence=0.85,
        accepted=True,
        source="auto",
    )

    s1 = judge_log.get_acceptance_stats(user_id="u1")
    assert s1["total"] == 3
    assert s1["accepted"] == 2
    assert abs(s1["rate"] - 0.6667) < 0.001

    s2 = judge_log.get_acceptance_stats(user_id="u2")
    assert s2["total"] == 1
    assert s2["accepted"] == 1
    assert s2["rate"] == 1.0

    sg = judge_log.get_acceptance_stats()
    assert sg["total"] == 4

    s3 = judge_log.get_acceptance_stats(user_id="u_nobody")
    assert s3["total"] == 0
    assert s3["rate"] is None

    judge_log._reset()


def test_delete_for_users_is_scoped_idempotent_and_handles_empty(tmp_path, monkeypatch):
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
    from kg import judge_log

    judge_log._reset()
    for uid in ("gone", "linked", "keep"):
        judge_log.record(
            user_id=uid,
            notebook_id="nb",
            from_id="a",
            to_id="b",
            similarity=0.5,
            verdict="shares_usage",
            confidence=0.9,
            accepted=True,
        )

    assert judge_log.delete_for_users([]) == 0
    assert judge_log.delete_for_users(["gone", "linked", "gone"]) == 2
    assert judge_log.delete_for_users(["gone"]) == 0
    assert judge_log.get_log("gone") == [] and judge_log.get_log("linked") == []
    assert len(judge_log.get_log("keep")) == 1
    judge_log._reset()


class _CommitFailsOnce:
    """Proxy whose first commit raises; every other call delegates to the real connection."""

    def __init__(self, real):
        self._real = real
        self._armed = True

    def commit(self):
        if self._armed:
            self._armed = False
            import sqlite3

            raise sqlite3.OperationalError("simulated commit failure")
        self._real.commit()

    def __getattr__(self, name):
        return getattr(self._real, name)


def test_delete_for_users_rolls_back_when_commit_fails(tmp_path, monkeypatch):
    """A failed erasure must leave no open transaction on the shared connection."""
    import sqlite3

    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
    from kg import judge_log

    judge_log._reset()
    judge_log.record(
        user_id="gone",
        notebook_id="nb",
        from_id="a",
        to_id="b",
        similarity=0.5,
        verdict="shares_usage",
        confidence=0.9,
        accepted=True,
    )
    real = judge_log._get_conn()
    proxy = _CommitFailsOnce(real)
    monkeypatch.setattr(judge_log, "_get_conn", lambda *a, **k: proxy)

    with pytest.raises(sqlite3.OperationalError):
        judge_log.delete_for_users(["gone"])

    assert real.in_transaction is False
    assert judge_log.delete_for_users(["gone"]) == 1
