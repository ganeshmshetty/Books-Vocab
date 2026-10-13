"""Tests for pipeline_log module."""

from __future__ import annotations

import time

import pytest

from kg import pipeline_log

pytestmark = pytest.mark.usefixtures("isolate_pipeline_db")


def test_start_and_end_run():
    pipeline_log.start_run("r1", "u1", "nb1", "manual")
    runs = pipeline_log.get_runs("u1")
    assert len(runs) == 1
    assert runs[0]["status"] == "running"
    assert runs[0]["ended_at"] is None

    pipeline_log.end_run("r1", "completed")
    runs = pipeline_log.get_runs("u1")
    assert runs[0]["status"] == "completed"
    assert runs[0]["ended_at"] is not None


def test_start_step_and_end_step():
    pipeline_log.start_run("r1", "u1", "nb1", "manual")
    pipeline_log.start_step("r1", "Enrich")
    pipeline_log.end_step("r1", "Enrich", items=42)

    runs = pipeline_log.get_runs("u1")
    steps = runs[0]["steps"]
    assert len(steps) == 1
    assert steps[0]["name"] == "Enrich"
    assert steps[0]["status"] == "ok"
    assert steps[0]["items"] == 42
    assert steps[0]["error"] is None
    assert steps[0]["ended_at"] is not None


def test_multiple_steps():
    pipeline_log.start_run("r1", "u1", "nb1", "auto")
    names = ["Enrich", "EmbedAndJudge", "Difficulty", "ExternalSync"]
    items_map = {"Enrich": 10, "EmbedAndJudge": 20, "Difficulty": 30, "ExternalSync": 5}
    for name in names:
        pipeline_log.start_step("r1", name)
        pipeline_log.end_step("r1", name, items=items_map[name])

    runs = pipeline_log.get_runs("u1")
    steps = runs[0]["steps"]
    assert len(steps) == 4
    for step in steps:
        assert step["status"] == "ok"
        assert step["items"] == items_map[step["name"]]


def test_get_runs_returns_newest_first():
    for i in range(3):
        pipeline_log.start_run(f"r{i}", "u1", "nb1", "manual")
        time.sleep(0.01)  # ensure distinct timestamps

    runs = pipeline_log.get_runs("u1")
    assert len(runs) == 3
    # newest first
    assert runs[0]["run_id"] == "r2"
    assert runs[2]["run_id"] == "r0"


def test_get_runs_filters_by_user():
    pipeline_log.start_run("r1", "user_a", "nb1", "manual")
    pipeline_log.start_run("r2", "user_b", "nb1", "manual")
    pipeline_log.start_run("r3", "user_a", "nb2", "auto")

    assert len(pipeline_log.get_runs("user_a")) == 2
    assert len(pipeline_log.get_runs("user_b")) == 1
    assert len(pipeline_log.get_runs("user_c")) == 0


def test_end_step_with_error():
    pipeline_log.start_run("r1", "u1", "nb1", "manual")
    pipeline_log.start_step("r1", "Enrich")
    pipeline_log.end_step("r1", "Enrich", status="failed", error="timeout after 30s")

    runs = pipeline_log.get_runs("u1")
    step = runs[0]["steps"][0]
    assert step["status"] == "failed"
    assert step["error"] == "timeout after 30s"


def test_duration_computed():
    pipeline_log.start_run("r1", "u1", "nb1", "manual")
    pipeline_log.start_step("r1", "Enrich")
    time.sleep(0.05)
    pipeline_log.end_step("r1", "Enrich", items=1)
    time.sleep(0.05)
    pipeline_log.end_run("r1", "completed")

    runs = pipeline_log.get_runs("u1")
    run = runs[0]
    # Run duration
    assert run["duration_s"] is not None
    assert run["duration_s"] > 0
    # Step duration
    assert run["steps"][0]["duration_s"] is not None
    assert run["steps"][0]["duration_s"] > 0


def test_get_runs_via_handler():
    """The admin handler wraps get_runs correctly."""
    # Start a run, add steps, end it
    pipeline_log.start_run("r1", "user_a", "default", "background")
    pipeline_log.start_step("r1", "Enrich")
    pipeline_log.end_step("r1", "Enrich", status="ok", items=10)
    pipeline_log.end_run("r1", "completed")

    # Verify get_runs returns the expected structure
    runs = pipeline_log.get_runs("user_a")
    assert len(runs) == 1
    run = runs[0]
    assert run["run_id"] == "r1"
    assert run["status"] == "completed"
    assert run["duration_s"] is not None
    assert len(run["steps"]) == 1
    assert run["steps"][0]["name"] == "Enrich"
    assert run["steps"][0]["items"] == 10
    assert run["steps"][0]["duration_s"] is not None


def test_corrupt_steps_read_returns_run_without_parser_exception():
    pipeline_log.start_run("r1", "u1", "nb1", "manual")
    conn = pipeline_log._get_conn()
    conn.execute("UPDATE pipeline_runs SET steps = ? WHERE run_id = ?", ("not-json", "r1"))
    conn.commit()

    runs = pipeline_log.get_runs("u1")

    assert len(runs) == 1
    assert runs[0]["run_id"] == "r1"
    assert runs[0]["steps"] == []


@pytest.mark.parametrize("operation", ["start_step", "end_step"])
def test_corrupt_steps_update_is_a_noop(operation):
    pipeline_log.start_run("r1", "u1", "nb1", "manual")
    conn = pipeline_log._get_conn()
    conn.execute("UPDATE pipeline_runs SET steps = ? WHERE run_id = ?", ("not-json", "r1"))
    conn.commit()

    if operation == "start_step":
        pipeline_log.start_step("r1", "Enrich")
    else:
        pipeline_log.end_step("r1", "Enrich")

    stored_steps = conn.execute("SELECT steps FROM pipeline_runs WHERE run_id = ?", ("r1",)).fetchone()[0]
    assert stored_steps == "not-json"


def test_get_runs_orders_offset_timestamps_before_applying_limit():
    conn = pipeline_log._get_conn()
    conn.executemany(
        "INSERT INTO pipeline_runs (run_id, user_id, notebook_id, trigger, started_at) VALUES (?, ?, ?, ?, ?)",
        [
            ("older-real", "u1", "nb1", "manual", "2026-08-29T03:00:00+00:00"),
            ("newer-real", "u1", "nb1", "manual", "2026-08-29T00:30:00-04:00"),
        ],
    )
    conn.commit()

    runs = pipeline_log.get_runs("u1", limit=1)

    assert [run["run_id"] for run in runs] == ["newer-real"]


def _seed_runs(rows: list[tuple[str, str, str]]) -> None:
    """Bulk-insert (run_id, user_id, started_at) rows without per-row commits."""
    conn = pipeline_log._get_conn()
    conn.executemany(
        "INSERT INTO pipeline_runs (run_id, user_id, notebook_id, trigger, started_at) VALUES (?, ?, 'nb1', 'manual', ?)",
        rows,
    )
    conn.commit()


def test_get_run_scoped_to_user_beyond_the_newest_10000():
    """#2085: a point lookup must not depend on the user's run-history depth."""
    _seed_runs(
        [("oldest", "u1", "2026-01-01T00:00:00+00:00")]
        + [(f"r{i}", "u1", f"2026-02-01T00:{i // 60 % 60:02d}:{i % 60:02d}+00:00") for i in range(10_001)]
        + [("theirs", "u2", "2026-03-01T00:00:00+00:00")]
    )

    run = pipeline_log.get_run("oldest", "u1")

    assert run is not None
    assert run["run_id"] == "oldest"
    assert run["user_id"] == "u1"
    assert run["duration_s"] is None
    assert run["steps"] == []
    assert pipeline_log.get_run("theirs", "u1") is None
    assert pipeline_log.get_run("missing", "u1") is None
    assert pipeline_log.get_run("theirs", "u2")["run_id"] == "theirs"


def test_get_run_matches_get_runs_row_shape():
    pipeline_log.start_run("shape", "u1", "nb1", "manual")
    pipeline_log.start_step("shape", "Enrich")
    pipeline_log.end_step("shape", "Enrich", items=3)
    pipeline_log.end_run("shape", "completed")

    assert pipeline_log.get_run("shape", "u1") == pipeline_log.get_runs("u1")[0]


def test_delete_for_users_is_idempotent_and_user_scoped():
    pipeline_log.start_run("r1", "deleted", "nb1", "manual")
    pipeline_log.start_run("r2", "deleted", "nb2", "auto")
    pipeline_log.start_run("r3", "other", "nb1", "manual")

    assert pipeline_log.delete_for_users(["deleted", "deleted"]) == 2
    assert pipeline_log.delete_for_users(["deleted"]) == 0
    assert pipeline_log.delete_for_users([]) == 0
    assert pipeline_log.get_runs("deleted") == []
    assert len(pipeline_log.get_runs("other")) == 1


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


def test_delete_for_users_rolls_back_when_commit_fails(monkeypatch):
    """A failed erasure must leave no open transaction on the shared connection."""
    import sqlite3

    pipeline_log.start_run("r1", "gone", "nb1", "manual")
    real = pipeline_log._get_conn()
    proxy = _CommitFailsOnce(real)
    monkeypatch.setattr(pipeline_log, "_get_conn", lambda *a, **k: proxy)

    with pytest.raises(sqlite3.OperationalError):
        pipeline_log.delete_for_users(["gone"])

    assert real.in_transaction is False
    assert pipeline_log.delete_for_users(["gone"]) == 1
