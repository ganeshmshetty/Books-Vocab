"""Concurrent accounting correctness for `kg.token_tracker`.

`test_sqlite_concurrency.test_token_tracker_concurrent_writes_no_locked` already
proves the writer does not crash with ``database is locked``. These tests cover
the *ledger* — the SUMs and per-user isolation that downstream billing/quota
trusts — under contended writes, plus a read-during-write snapshot probe.

Three regressions guarded here:

1. lost-update: concurrent INSERTs from N threads against one user must not
   drop rows. `SUM(input_tokens)` and `SUM(output_tokens)` must equal the
   total quantity written.
2. user isolation: parallel writers targeting *different* user_ids must not
   bleed rows across users (one user's sum staying intact while another is
   hammered).
3. snapshot consistency: a reader calling `get_all_stats()` while writers
   pound the same table must (a) never raise, and (b) only ever observe a
   monotonically-growing prefix — never a partial / corrupted row.
"""

from __future__ import annotations

import sqlite3
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

import pytest


def _reset_token_tracker(tmp_path, monkeypatch):
    """Point token_tracker at a fresh DB under tmp_path and clear singleton."""
    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
    import kg.token_tracker as tt

    # token_tracker has no _reset() — close + None the cached connection so
    # the next _get_conn() rebuilds against the patched DB_PATH.
    if tt._conn is not None:
        tt._conn.close()
        tt._conn = None
    monkeypatch.setattr(tt, "DB_PATH", tmp_path / "token_usage.db")
    return tt


def _teardown(tt) -> None:
    if tt._conn is not None:
        tt._conn.close()
        tt._conn = None


def test_concurrent_token_writes_no_lost_updates(tmp_path, monkeypatch):
    """20 threads each insert one row for the same user — SUMs must be exact.

    A `threading.Lock` + `conn.commit()` per INSERT is what serialises writers
    today. If that invariant ever drifts (e.g. someone removes the lock or
    batches commits unsafely), this test will surface a deficit in the sum.
    """
    tt = _reset_token_tracker(tmp_path, monkeypatch)

    n_threads = 20
    input_each = 100
    output_each = 50
    user_id = "u_acct"

    errors: list[BaseException] = []
    err_lock = threading.Lock()

    def worker(_i: int) -> None:
        try:
            tt.record(user_id, "translate", input_each, output_each)
        except BaseException as e:  # noqa: BLE001
            with err_lock:
                errors.append(e)
            raise

    with ThreadPoolExecutor(max_workers=n_threads) as ex:
        futures = [ex.submit(worker, i) for i in range(n_threads)]
        for f in as_completed(futures):
            try:
                f.result()
            except BaseException:
                pass

    assert not errors, f"writer raised: {errors!r}"

    stats = tt.get_all_stats()
    _teardown(tt)

    assert user_id in stats, f"user row missing entirely: {stats!r}"
    bucket = stats[user_id]["translate"]
    assert bucket["calls"] == n_threads, f"lost rows: expected {n_threads} INSERTs, found {bucket['calls']}"
    assert bucket["input_tokens"] == n_threads * input_each, (
        f"input_tokens drift: expected {n_threads * input_each}, got {bucket['input_tokens']}"
    )
    assert bucket["output_tokens"] == n_threads * output_each, (
        f"output_tokens drift: expected {n_threads * output_each}, got {bucket['output_tokens']}"
    )


def test_concurrent_writes_different_users_isolated(tmp_path, monkeypatch):
    """10 users, 5 writes each in parallel — every user's ledger must be exact.

    Catches the (hypothetical) regression where the shared connection mixes
    user_ids inside an INSERT, e.g. a parameter-binding bug or a stray
    module-level mutable.
    """
    tt = _reset_token_tracker(tmp_path, monkeypatch)

    n_users = 10
    writes_per_user = 5
    input_each = 33
    output_each = 17

    errors: list[BaseException] = []
    err_lock = threading.Lock()

    def worker(payload: tuple[str, int]) -> None:
        user_id, _ = payload
        try:
            tt.record(user_id, "explain", input_each, output_each)
        except BaseException as e:  # noqa: BLE001
            with err_lock:
                errors.append(e)
            raise

    jobs = [(f"u_{u}", k) for u in range(n_users) for k in range(writes_per_user)]
    with ThreadPoolExecutor(max_workers=16) as ex:
        futures = [ex.submit(worker, j) for j in jobs]
        for f in as_completed(futures):
            try:
                f.result()
            except BaseException:
                pass

    assert not errors, f"writer raised: {errors!r}"

    stats = tt.get_all_stats()
    _teardown(tt)

    assert len(stats) == n_users, f"user count drift: expected {n_users}, got {len(stats)} — keys={list(stats)!r}"
    for u in range(n_users):
        user_id = f"u_{u}"
        assert user_id in stats, f"missing user {user_id}: {stats!r}"
        bucket = stats[user_id]["explain"]
        assert bucket["calls"] == writes_per_user, f"{user_id}: expected {writes_per_user} rows, got {bucket['calls']}"
        assert bucket["input_tokens"] == writes_per_user * input_each
        assert bucket["output_tokens"] == writes_per_user * output_each


def test_token_usage_query_during_concurrent_write_returns_consistent_snapshot(tmp_path, monkeypatch):
    """Reader calls `get_all_stats()` while 8 writers pound the same table.

    Validates two properties simultaneously:
      (a) reader never raises (no `database is locked`, no malformed row).
      (b) every snapshot the reader observes is consistent with itself —
          i.e. `total_input == calls * input_each` and
               `total_output == calls * output_each`.
          A torn read (partial INSERT visible to SELECT) would break this
          identity because input/output/row-count are written atomically by
          the same statement.
    """
    tt = _reset_token_tracker(tmp_path, monkeypatch)

    user_id = "u_snap"
    input_each = 7
    output_each = 3
    n_writers = 8
    writes_per_writer = 25
    total_writes = n_writers * writes_per_writer

    stop = threading.Event()
    writer_errors: list[BaseException] = []
    reader_errors: list[BaseException] = []
    err_lock = threading.Lock()
    snapshots_seen = 0
    observed_partial_calls: set[int] = set()  # distinct `calls` values seen
    snapshots_lock = threading.Lock()

    def writer(_i: int) -> None:
        try:
            for _ in range(writes_per_writer):
                tt.record(user_id, "judge", input_each, output_each)
        except BaseException as e:  # noqa: BLE001
            with err_lock:
                writer_errors.append(e)
            raise

    def reader() -> None:
        nonlocal snapshots_seen
        try:
            while not stop.is_set():
                snap = tt.get_all_stats()
                # No bleed from other users.
                assert set(snap.keys()) <= {user_id}, f"unexpected user in snapshot: {set(snap.keys())!r}"
                if user_id in snap and "judge" in snap[user_id]:
                    b = snap[user_id]["judge"]
                    calls = b["calls"]
                    # Self-consistency of the aggregate row.
                    assert b["input_tokens"] == calls * input_each, (
                        f"torn read: input_tokens={b['input_tokens']} not = {calls}*{input_each}"
                    )
                    assert b["output_tokens"] == calls * output_each, (
                        f"torn read: output_tokens={b['output_tokens']} not = {calls}*{output_each}"
                    )
                    # SUMs may only grow monotonically while writers run.
                    assert 0 <= calls <= total_writes, f"calls out of bounds: {calls}"
                with snapshots_lock:
                    snapshots_seen += 1
                    if user_id in snap and "judge" in snap[user_id]:
                        observed_partial_calls.add(snap[user_id]["judge"]["calls"])
        except BaseException as e:  # noqa: BLE001
            with err_lock:
                reader_errors.append(e)
            raise

    with ThreadPoolExecutor(max_workers=n_writers + 1) as ex:
        reader_future = ex.submit(reader)
        writer_futures = [ex.submit(writer, i) for i in range(n_writers)]
        for f in as_completed(writer_futures):
            try:
                f.result()
            except BaseException:
                pass
        stop.set()
        try:
            reader_future.result(timeout=5)
        except BaseException:
            pass

    # Final state must match the full write count.
    final = tt.get_all_stats()
    _teardown(tt)

    assert not writer_errors, f"writers raised: {writer_errors!r}"
    assert not reader_errors, f"reader raised (likely torn read): {reader_errors!r}"
    assert not any(isinstance(e, sqlite3.OperationalError) for e in writer_errors + reader_errors)
    assert snapshots_seen > 0, "reader thread never produced a snapshot"
    # Reader must have actually observed at least one in-progress state — i.e.
    # a `calls` value strictly less than the final total. If the reader only
    # ever saw 0 or `total_writes`, the test is degenerate (no real overlap).
    in_progress = {c for c in observed_partial_calls if 0 < c < total_writes}
    assert in_progress, f"reader never observed mid-flight state; observed_calls={sorted(observed_partial_calls)}"

    bucket = final[user_id]["judge"]
    assert bucket["calls"] == total_writes
    assert bucket["input_tokens"] == total_writes * input_each
    assert bucket["output_tokens"] == total_writes * output_each


def test_failed_insert_rolls_back_and_does_not_block_other_writers(tmp_path, monkeypatch):
    """A failing INSERT must not leave the shared connection in an open transaction.

    ``call_type=None`` trips the NOT NULL constraint. Without rollback the
    implicit transaction stays open, holds the write lock, and a second
    writer on the same DB fails with ``database is locked``.
    """
    tt = _reset_token_tracker(tmp_path, monkeypatch)

    with pytest.raises(sqlite3.IntegrityError):
        tt.record("u_fail", None, 1, 1)  # type: ignore[arg-type]

    assert tt._conn is not None
    assert not tt._conn.in_transaction, "failed INSERT left an open transaction on shared _conn"

    other = sqlite3.connect(tmp_path / "token_usage.db", timeout=0.5)
    try:
        other.execute(
            "INSERT INTO token_usage (user_id, call_type, input_tokens, output_tokens, created_at) "
            "VALUES ('u_other', 'translate', 1, 1, '2026-01-01T00:00:00+00:00')"
        )
        other.commit()
    finally:
        other.close()

    _teardown(tt)


def test_failed_delete_rolls_back_and_does_not_block_other_writers(tmp_path, monkeypatch):
    """A failing DELETE must not leave the shared connection in an open transaction.

    Mirrors the record() rollback contract for delete_for_users: the DELETE
    opens an implicit write transaction, then the executemany raises. Without
    rollback the transaction keeps the write lock and a second writer fails
    with ``database is locked``.
    """
    tt = _reset_token_tracker(tmp_path, monkeypatch)
    real_conn = tt._get_conn()

    class _FailingExecutemany:
        def __init__(self, conn):
            self._conn = conn

        def executemany(self, sql, params):
            self._conn.execute("DELETE FROM token_usage WHERE user_id = 'u1'")
            raise sqlite3.OperationalError("simulated executemany failure")

        def __getattr__(self, name):
            return getattr(self._conn, name)

    monkeypatch.setattr(tt, "_get_conn", lambda: _FailingExecutemany(real_conn))

    with pytest.raises(sqlite3.OperationalError):
        tt.delete_for_users(["u1"])

    assert not real_conn.in_transaction, "failed delete left an open transaction on shared _conn"

    other = sqlite3.connect(tmp_path / "token_usage.db", timeout=0.5)
    try:
        other.execute(
            "INSERT INTO token_usage (user_id, call_type, input_tokens, output_tokens, created_at) "
            "VALUES ('u_other', 'translate', 1, 1, '2026-01-01T00:00:00+00:00')"
        )
        other.commit()
    finally:
        other.close()

    _teardown(tt)
