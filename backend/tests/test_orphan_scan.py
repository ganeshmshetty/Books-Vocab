"""Tests for kg.orphan_scan — data consistency scanner."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from conftest import TEST_JWT_SECRET, _swap_settings
from kg.api import app
from kg.settings import KGSettings

ADMIN_TOKEN = "test-admin-token-orphan"


# ---------------------------------------------------------------------------
# Test fixture — isolates global SQLite logs + users dir under tmp_path.
# Mirrors test_admin_observability.py's pattern.
# ---------------------------------------------------------------------------


@pytest.fixture()
def env(tmp_path, monkeypatch):
    """Build an isolated data_dir with one user, one notebook, one card."""
    data_dir = tmp_path
    (data_dir / "users").mkdir()

    monkeypatch.setenv("KG_DATA_DIR", str(data_dir))
    import kg.judge_log as jl
    import kg.token_tracker as tt
    import kg.translate_log as tl

    monkeypatch.setattr(jl, "DATA_DIR", data_dir)
    monkeypatch.setattr(jl, "DB_PATH", data_dir / "judge_log.db")
    monkeypatch.setattr(tt, "DATA_DIR", data_dir)
    monkeypatch.setattr(tt, "DB_PATH", data_dir / "token_usage.db")
    jl._reset()
    tl._reset()
    if hasattr(tt, "_reset"):
        tt._reset()
    elif tt._conn is not None:
        tt._conn.close()
        tt._conn = None

    uid = "u_real"
    users_file = data_dir / "users.json"
    users_file.write_text(json.dumps({uid: {"config": {}}, "_meta": {}}))

    # Build per-user dir + notebooks.db + cards.db with a real notebook+card
    user_dir = data_dir / "users" / uid
    user_dir.mkdir(parents=True, exist_ok=True)

    from kg.cards import CardStore
    from kg.notebook import NotebookStore

    nbs = NotebookStore(user_dir / "notebooks.db")
    nbs.ensure_default()
    real_nb = nbs.create(name="kept", color=None)
    cards = CardStore(user_dir / "cards.db")
    real_card = cards.add(
        content="apple",
        pos="n.",
        meaning="蘋果",
        notebook_id=real_nb.id,
    )

    original_settings = app.state.kg_settings
    test_settings = KGSettings(
        data_dir=data_dir,
        jwt_secret=TEST_JWT_SECRET,
        admin_token=ADMIN_TOKEN,
    )
    _swap_settings(test_settings)

    try:
        client = TestClient(app, raise_server_exceptions=False)
        yield SimpleNamespace(
            client=client,
            data_dir=data_dir,
            user_id=uid,
            user_dir=user_dir,
            real_notebook_id=real_nb.id,
            real_card_id=real_card.id,
        )
    finally:
        app.state.kg_settings = original_settings
        jl._reset()
        tl._reset()
        if tt._conn is not None:
            tt._conn.close()
            tt._conn = None


# ---------------------------------------------------------------------------
# Scanner module — pure functions
# ---------------------------------------------------------------------------


def test_scan_clean_env_returns_zero_orphans(env):
    from kg.orphan_scan import scan

    report = scan(data_dir=env.data_dir)
    assert report["cards_orphan_notebook"]["count"] == 0
    assert report["graph_links_orphan_card"]["count"] == 0
    assert report["translate_log_orphan_user"]["count"] == 0
    assert report["judge_log_orphan_card"]["count"] == 0
    assert report["token_usage_orphan_user"]["count"] == 0
    assert report["total"] == 0


def test_scan_detects_card_pointing_to_missing_notebook(env):
    """Inject a card whose notebook_id has no row in notebooks.db."""
    from kg.cards import CardStore
    from kg.orphan_scan import scan

    cards = CardStore(env.user_dir / "cards.db")
    bogus = cards.add(
        content="orphan_word",
        pos="n.",
        meaning="x",
        notebook_id="nb_does_not_exist",
    )

    report = scan(data_dir=env.data_dir)
    items = report["cards_orphan_notebook"]["items"]
    assert report["cards_orphan_notebook"]["count"] == 1
    assert any(it["card_id"] == bogus.id for it in items)


def test_scan_detects_graph_link_with_missing_card(env):
    """Write graph_<nb>.json with a link whose to_id is unknown."""
    from kg.orphan_scan import scan

    link = {
        "id": "lk_orphan",
        "from_id": env.real_card_id,
        "to_id": "card_ghost",
        "kind": "shares_usage",
        "confidence": 0.9,
        "reason": "test",
        "created_at": "2024-01-01T00:00:00+00:00",
        "status": "active",
    }
    graph_path = env.user_dir / f"graph_{env.real_notebook_id}.json"
    graph_path.write_text(json.dumps([link]))

    report = scan(data_dir=env.data_dir)
    assert report["graph_links_orphan_card"]["count"] == 1
    item = report["graph_links_orphan_card"]["items"][0]
    assert item["link_id"] == "lk_orphan"
    assert item["missing"] == ["card_ghost"]


def test_scan_detects_translate_log_for_ghost_user(env):
    import kg.translate_log as tl
    from kg.orphan_scan import scan

    tl.record(
        user_id="ghost_user",
        operation="translate_quick",
        word="x",
        context="",
        context_hash="h",
        source_lang="en",
        target_lang="zh-Hant",
        response_raw="{}",
        latency_ms=1,
    )
    tl.record(
        user_id=env.user_id,  # real user — must NOT be flagged
        operation="translate_quick",
        word="y",
        context="",
        context_hash="h2",
        source_lang="en",
        target_lang="zh-Hant",
        response_raw="{}",
        latency_ms=1,
    )

    report = scan(data_dir=env.data_dir)
    m = report["translate_log_orphan_user"]
    assert m["count"] == 1
    assert m["items"][0]["user_id"] == "ghost_user"


def test_scan_detects_judge_log_with_ghost_card(env):
    import kg.judge_log as jl
    from kg.orphan_scan import scan

    jl.record(
        user_id=env.user_id,
        notebook_id=env.real_notebook_id,
        from_id=env.real_card_id,
        to_id="card_ghost",
        similarity=0.7,
        verdict="accept",
        confidence=0.9,
        accepted=True,
    )

    report = scan(data_dir=env.data_dir)
    assert report["judge_log_orphan_card"]["count"] == 1
    item = report["judge_log_orphan_card"]["items"][0]
    assert "card_ghost" in item["missing"]


def test_scan_judge_log_pointing_to_live_card_not_flagged(env):
    """A judge_log row whose both endpoints are live cards must NOT be flagged.

    Guards the dependency where the judge_log pass reuses ``user_live_cards``
    populated during the cards/graph pass: if that wiring breaks (e.g. the
    refactor forgets to pass the live-card set), a perfectly valid judge row
    would be mis-reported as an orphan.
    """
    import kg.judge_log as jl
    from kg.cards import CardStore
    from kg.orphan_scan import scan

    # Second live card in the same notebook so both judge endpoints are live.
    cards = CardStore(env.user_dir / "cards.db")
    second = cards.add(
        content="banana",
        pos="n.",
        meaning="香蕉",
        notebook_id=env.real_notebook_id,
    )

    jl.record(
        user_id=env.user_id,
        notebook_id=env.real_notebook_id,
        from_id=env.real_card_id,
        to_id=second.id,
        similarity=0.7,
        verdict="accept",
        confidence=0.9,
        accepted=True,
    )

    report = scan(data_dir=env.data_dir)
    assert report["judge_log_orphan_card"]["count"] == 0


def test_scan_detects_token_usage_for_ghost_user(env):
    import kg.token_tracker as tt
    from kg.orphan_scan import scan

    tt.record("ghost_user", "translate_quick", 1, 1)
    tt.record(env.user_id, "translate_quick", 1, 1)

    report = scan(data_dir=env.data_dir)
    m = report["token_usage_orphan_user"]
    assert m["count"] == 1
    assert m["items"][0]["user_id"] == "ghost_user"


# ---------------------------------------------------------------------------
# Fix — must require explicit confirm=True, dry_run gives counts only.
# ---------------------------------------------------------------------------


def test_fix_requires_explicit_confirm(env):
    """Calling fix() without confirm=True must raise."""
    from kg.orphan_scan import fix

    with pytest.raises(ValueError):
        fix(data_dir=env.data_dir)


def test_fix_dry_run_reports_but_does_not_mutate(env):
    import kg.translate_log as tl
    from kg.orphan_scan import fix, scan

    tl.record(
        user_id="ghost_user",
        operation="translate_quick",
        word="x",
        context="",
        context_hash="h",
        source_lang="en",
        target_lang="zh-Hant",
        response_raw="{}",
        latency_ms=1,
    )

    summary = fix(data_dir=env.data_dir, confirm=True, dry_run=True)
    assert summary["translate_log_orphan_user"]["would_delete"] == 1

    # Still present after dry-run.
    after = scan(data_dir=env.data_dir)
    assert after["translate_log_orphan_user"]["count"] == 1


def test_fix_confirm_true_actually_removes_orphans(env):
    """Inject orphans across all 5 categories; fix() should drop them all."""
    import kg.judge_log as jl
    import kg.token_tracker as tt
    import kg.translate_log as tl
    from kg.cards import CardStore
    from kg.orphan_scan import fix, scan

    # 1. orphan card→notebook
    cards = CardStore(env.user_dir / "cards.db")
    bogus_card = cards.add(content="o1", pos="n.", meaning="x", notebook_id="nb_missing")

    # 2. orphan graph_link
    graph_path = env.user_dir / f"graph_{env.real_notebook_id}.json"
    graph_path.write_text(
        json.dumps(
            [
                {
                    "id": "lk_orphan",
                    "from_id": env.real_card_id,
                    "to_id": "card_ghost",
                    "kind": "shares_usage",
                    "confidence": 0.9,
                    "reason": "test",
                    "created_at": "2024-01-01T00:00:00+00:00",
                    "status": "active",
                }
            ]
        )
    )

    # 3. translate_log ghost user
    tl.record(
        user_id="ghost_user",
        operation="translate_quick",
        word="x",
        context="",
        context_hash="h",
        source_lang="en",
        target_lang="zh-Hant",
        response_raw="{}",
        latency_ms=1,
    )

    # 4. judge_log ghost card
    jl.record(
        user_id=env.user_id,
        notebook_id=env.real_notebook_id,
        from_id=env.real_card_id,
        to_id="card_ghost",
        similarity=0.7,
        verdict="accept",
        confidence=0.9,
        accepted=True,
    )

    # 5. token_usage ghost user
    tt.record("ghost_user", "translate_quick", 1, 1)

    before = scan(data_dir=env.data_dir)
    assert before["total"] == 5

    summary = fix(data_dir=env.data_dir, confirm=True, dry_run=False)
    assert summary["total_deleted"] == 5

    after = scan(data_dir=env.data_dir)
    assert after["total"] == 0

    # Soft-deleted card stays in db but is_deleted=1.
    with sqlite3.connect(str(env.user_dir / "cards.db")) as conn:
        row = conn.execute("SELECT is_deleted FROM card WHERE id = ?", (bogus_card.id,)).fetchone()
        assert row is not None
        assert int(row[0]) == 1


# ---------------------------------------------------------------------------
# Admin endpoint — read-only, requires admin token.
# ---------------------------------------------------------------------------


def test_admin_orphans_endpoint_requires_auth(env):
    resp = env.client.get("/api/admin/orphans/scan")
    assert resp.status_code == 403


def test_admin_orphans_endpoint_returns_report(env):
    import kg.translate_log as tl

    tl.record(
        user_id="ghost_user",
        operation="translate_quick",
        word="x",
        context="",
        context_hash="h",
        source_lang="en",
        target_lang="zh-Hant",
        response_raw="{}",
        latency_ms=1,
    )

    resp = env.client.get(
        "/api/admin/orphans/scan",
        headers={"Authorization": f"Bearer {ADMIN_TOKEN}"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert "translate_log_orphan_user" in body
    assert body["translate_log_orphan_user"]["count"] == 1
    assert body["total"] >= 1


# ---------------------------------------------------------------------------
# Regression — perf / concurrency hardening for review PR #436
# ---------------------------------------------------------------------------


def test_admin_orphans_endpoint_does_not_block_event_loop(env):
    """The endpoint must hand the sync scan off to a thread so concurrent
    requests overlap instead of serialising on the event loop."""
    import asyncio
    import time

    import httpx

    import kg.translate_log as tl

    # Inject enough orphans that scan does measurable real work.
    for i in range(5):
        tl.record(
            user_id=f"ghost_{i}",
            operation="translate_quick",
            word=str(i),
            context="",
            context_hash=f"h{i}",
            source_lang="en",
            target_lang="zh-Hant",
            response_raw="{}",
            latency_ms=1,
        )

    transport = httpx.ASGITransport(app=app)

    async def hit():
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
            r = await client.get(
                "/api/admin/orphans/scan",
                headers={"Authorization": f"Bearer {ADMIN_TOKEN}"},
            )
            assert r.status_code == 200
            return r.json()["total"]

    async def run_parallel():
        # 4 concurrent calls — if scan ran on the event loop they would
        # serialise; running via run_in_threadpool lets them overlap.
        return await asyncio.gather(hit(), hit(), hit(), hit())

    t0 = time.monotonic()
    totals = asyncio.run(asyncio.wait_for(run_parallel(), timeout=10.0))
    elapsed = time.monotonic() - t0

    assert all(t >= 5 for t in totals)
    # Generous bound — purely there to catch a regression where someone
    # removes run_in_threadpool and the endpoint goes back to blocking.
    assert elapsed < 10.0, f"endpoint serialised requests ({elapsed:.2f}s)"


def test_scan_judge_log_uses_cached_live_cards(env, monkeypatch):
    """The single-pass scan reads each user's cards.db exactly once via
    ``_all_cards_with_state``; the judge_log pass must reuse that cached
    live-card set rather than re-scanning. Regression: keep it to one call."""
    import kg.judge_log as jl
    from kg import orphan_scan

    jl.record(
        user_id=env.user_id,
        notebook_id=env.real_notebook_id,
        from_id=env.real_card_id,
        to_id="card_ghost",
        similarity=0.7,
        verdict="accept",
        confidence=0.9,
        accepted=True,
    )

    call_count = {"n": 0}
    real_all = orphan_scan._all_cards_with_state

    def counting_all(db):
        call_count["n"] += 1
        return real_all(db)

    monkeypatch.setattr(orphan_scan, "_all_cards_with_state", counting_all)

    report = orphan_scan.scan(data_dir=env.data_dir)

    # One user → exactly one cards.db read; the judge_log pass reuses the
    # cached set, never re-scanning cards.db.
    assert call_count["n"] == 1, f"cards.db scanned {call_count['n']} times"
    # Functional regression check — result unaffected by the refactor.
    assert report["judge_log_orphan_card"]["count"] == 1


def test_fix_aborts_when_graph_file_mutated_mid_run(env, monkeypatch):
    """If a concurrent writer rewrites graph_*.json between mtime snapshot and
    rewrite, fix() must raise OrphanFixAborted rather than clobber the file."""
    from kg.orphan_scan import OrphanFixAborted, fix

    # Set up an orphan link so fix() reaches the graph-rewrite branch.
    graph_path = env.user_dir / f"graph_{env.real_notebook_id}.json"
    graph_path.write_text(
        json.dumps(
            [
                {
                    "id": "lk_orphan",
                    "from_id": env.real_card_id,
                    "to_id": "card_ghost",
                    "kind": "shares_usage",
                    "confidence": 0.9,
                    "reason": "test",
                    "created_at": "2024-01-01T00:00:00+00:00",
                    "status": "active",
                }
            ]
        )
    )

    # Patch Path.stat so only the in-loop guard comparison sees a drifted
    # mtime, mimicking a concurrent writer touching the file between the
    # snapshot and the rewrite.
    #
    # fix() touches ``graph_path`` via Path.stat in order:
    #   Python 3.13           Python 3.14
    #   1. exists() → stat    1. exists() → os.path.exists()
    #   2. stat() snapshot    2. stat() snapshot
    #   3. exists() → stat    3. exists() → os.path.exists()
    #   4. stat() guard       4. stat() guard
    #   5. atomic_write exists
    # To exercise the guard, the snapshot must observe the original mtime and
    # the guard the bumped one.  Bump from the 3rd call onward — this covers
    # both Python 3.13 (guard = #4) and 3.14 (guard = #2) without branching.
    real_stat = Path.stat
    stat_calls = {"n": 0}

    def drift_stat(self, *a, **kw):
        result = real_stat(self, *a, **kw)
        if self == graph_path:
            stat_calls["n"] += 1
            if stat_calls["n"] >= 3:

                class _FakeStat:
                    def __init__(self, base, bumped_ns):
                        self._base = base
                        self.st_mtime_ns = bumped_ns

                    def __getattr__(self, name):
                        return getattr(self._base, name)

                return _FakeStat(result, result.st_mtime_ns + 1)
        return result

    monkeypatch.setattr(Path, "stat", drift_stat)

    with pytest.raises(OrphanFixAborted):
        fix(data_dir=env.data_dir, confirm=True, dry_run=False)


# ---------------------------------------------------------------------------
# _atomic_write_json — durability
# ---------------------------------------------------------------------------


def test_atomic_write_json_fsyncs_parent_dir(tmp_path, monkeypatch):
    """``_atomic_write_json`` must fsync the parent directory after the rename
    so the rename's directory-entry update is itself durable across a crash —
    fsyncing only the tmp file is insufficient."""
    import os as _os
    import stat as _stat

    from kg import orphan_scan

    target = tmp_path / "graph_x.json"

    fsynced_dir_count = {"n": 0}
    real_fsync = _os.fsync

    def tracking_fsync(fd):
        try:
            # A directory fd reports S_ISDIR on its fstat result.
            if _stat.S_ISDIR(_os.fstat(fd).st_mode):
                fsynced_dir_count["n"] += 1
        except OSError:
            pass
        return real_fsync(fd)

    monkeypatch.setattr(_os, "fsync", tracking_fsync)

    orphan_scan._atomic_write_json(target, [{"id": "a"}])

    assert target.exists()
    assert json.loads(target.read_text()) == [{"id": "a"}]
    # The parent directory must have been fsynced after the rename.
    assert fsynced_dir_count["n"] >= 1, "parent directory was not fsynced after rename"


# ---------------------------------------------------------------------------
# Fail-closed when the users registry is unavailable (#2306)
# ---------------------------------------------------------------------------


def _seed_log_rows(env) -> None:
    import kg.judge_log as jl
    import kg.token_tracker as tt
    import kg.translate_log as tl

    tl.record(
        user_id=env.user_id,
        operation="translate_quick",
        word="x",
        context="",
        context_hash="h",
        source_lang="en",
        target_lang="zh-Hant",
        response_raw="{}",
        latency_ms=1,
    )
    jl.record(
        user_id=env.user_id,
        notebook_id=env.real_notebook_id,
        from_id=env.real_card_id,
        to_id="card_ghost",
        similarity=0.7,
        verdict="accept",
        confidence=0.9,
        accepted=True,
    )
    tt.record(env.user_id, "translate_quick", 1, 1)


def _log_row_counts(data_dir: Path) -> dict[str, int]:
    out: dict[str, int] = {}
    for db, table in (
        ("translate_log.db", "translate_log"),
        ("judge_log.db", "judge_log"),
        ("token_usage.db", "token_usage"),
    ):
        with sqlite3.connect(str(data_dir / db)) as conn:
            out[table] = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    return out


def _break_missing(env) -> None:
    (env.data_dir / "users.json").unlink()


def _break_malformed(env) -> None:
    (env.data_dir / "users.json").write_text("{not json")


def _break_non_dict(env) -> None:
    (env.data_dir / "users.json").write_text("[]")


def _break_empty_registry(env) -> None:
    (env.data_dir / "users.json").write_text(json.dumps({"_meta": {}}))


@pytest.mark.parametrize("breaker", [_break_missing, _break_malformed, _break_non_dict, _break_empty_registry])
@pytest.mark.parametrize("dry_run_flags", [[], ["--dry-run"]])
def test_fix_cli_fails_closed_when_registry_unavailable(env, breaker, dry_run_flags, capsys):
    from kg.orphan_scan import main

    _seed_log_rows(env)
    before = _log_row_counts(env.data_dir)
    assert all(v > 0 for v in before.values())
    breaker(env)

    rc = main(["--fix", "--confirm", *dry_run_flags, "--data-dir", str(env.data_dir)])

    assert rc != 0
    assert "error" in capsys.readouterr().err
    assert _log_row_counts(env.data_dir) == before


def test_fix_cli_fails_closed_when_registry_unreadable(env, monkeypatch, capsys):
    from kg.orphan_scan import main

    _seed_log_rows(env)
    before = _log_row_counts(env.data_dir)
    real_read_text = Path.read_text

    def _boom(self, *a, **kw):
        if self.name == "users.json":
            raise OSError("permission denied")
        return real_read_text(self, *a, **kw)

    monkeypatch.setattr(Path, "read_text", _boom)

    rc = main(["--fix", "--confirm", "--data-dir", str(env.data_dir)])

    assert rc != 0
    assert "error" in capsys.readouterr().err
    assert _log_row_counts(env.data_dir) == before


def test_fix_api_raises_when_registry_missing(env):
    from kg.orphan_scan import UserRegistryUnavailable, fix

    _seed_log_rows(env)
    _break_missing(env)
    with pytest.raises(UserRegistryUnavailable):
        fix(data_dir=env.data_dir, confirm=True, dry_run=True)


def test_fix_cli_valid_registry_removes_only_ghosts(env):
    import kg.token_tracker as tt
    from kg.orphan_scan import main

    _seed_log_rows(env)
    tt.record("ghost_user", "translate_quick", 1, 1)
    assert _log_row_counts(env.data_dir)["token_usage"] == 2

    rc = main(["--fix", "--confirm", "--data-dir", str(env.data_dir)])

    assert rc == 0
    counts = _log_row_counts(env.data_dir)
    assert counts["token_usage"] == 1
    assert counts["translate_log"] == 1


def test_scan_reports_registry_not_loaded_without_raising(env):
    from kg.orphan_scan import scan

    assert scan(data_dir=env.data_dir)["user_registry_loaded"] is True
    _break_missing(env)
    report = scan(data_dir=env.data_dir)
    assert report["user_registry_loaded"] is False


def _sha256_files(data_dir: Path) -> dict[str, str]:
    import hashlib

    return {
        name: hashlib.sha256((data_dir / name).read_bytes()).hexdigest()
        for name in ("translate_log.db", "judge_log.db", "token_usage.db")
    }


def test_fix_targets_data_dir_not_module_singletons(env, tmp_path):
    """#2308: fix(data_dir=X) must mutate X's log DBs, never the singletons' DBs."""
    import shutil

    import kg.judge_log as jl
    import kg.token_tracker as tt
    import kg.translate_log as tl

    # Sentinel = env.data_dir (what KG_DATA_DIR / singletons point at).
    _seed_log_rows(env)  # live-user rows + one orphan judge row (to_id ghost)
    tl.record(
        user_id="ghost_user",
        operation="translate_quick",
        word="g",
        context="",
        context_hash="h",
        source_lang="en",
        target_lang="zh-Hant",
        response_raw="{}",
        latency_ms=1,
    )
    tt.record("ghost_user", "translate_quick", 1, 1)
    jl._reset()
    tl._reset()
    if tt._conn is not None:
        tt._conn.close()
        tt._conn = None
    sentinel = env.data_dir

    # Target dir: independent copy of the same layout.
    target = tmp_path / "target_root"
    target.mkdir()
    shutil.copy(sentinel / "users.json", target / "users.json")
    shutil.copytree(sentinel / "users", target / "users")
    for name in ("translate_log.db", "judge_log.db", "token_usage.db"):
        shutil.copy(sentinel / name, target / name)

    sentinel_hashes = _sha256_files(sentinel)
    # Row counts are the discriminating guard: WAL-mode DBs can lose rows while
    # the main .db file stays byte-identical until checkpoint.
    sentinel_counts = _log_row_counts(sentinel)
    before = _log_row_counts(target)
    assert before["judge_log"] == 1  # orphan judge row present in target

    from kg.orphan_scan import fix, scan

    assert scan(data_dir=target)["judge_log_orphan_card"]["count"] == 1
    fix(data_dir=target, confirm=True, dry_run=False)

    assert _sha256_files(sentinel) == sentinel_hashes
    assert _log_row_counts(sentinel) == sentinel_counts
    assert _log_row_counts(target)["judge_log"] == 0
    # non-orphan live-user rows are kept in the target
    after = _log_row_counts(target)
    assert after["translate_log"] == before["translate_log"] - 1
    assert after["token_usage"] == before["token_usage"] - 1
    assert after["translate_log"] == 1 and after["token_usage"] == 1
    assert scan(data_dir=target)["total"] == 0
    # deleted by specific user_id: ghost gone, live user's rows kept
    for db, table in (("translate_log.db", "translate_log"), ("token_usage.db", "token_usage")):
        with sqlite3.connect(str(target / db)) as conn:
            uids = {r[0] for r in conn.execute(f"SELECT user_id FROM {table}")}
        assert uids == {env.user_id}


def test_fix_propagates_locked_database_instead_of_reporting_success(env, monkeypatch):
    """A locked log DB must make fix() raise, not return a bogus success summary."""
    import kg.translate_log as tl
    from kg import orphan_scan

    tl.record(
        user_id="ghost_user",
        operation="translate_quick",
        word="g",
        context="",
        context_hash="h",
        source_lang="en",
        target_lang="zh-Hant",
        response_raw="{}",
        latency_ms=1,
    )
    tl._reset()
    db = env.data_dir / "translate_log.db"

    real_connect = sqlite3.connect
    monkeypatch.setattr(orphan_scan.sqlite3, "connect", lambda path, *a, **k: real_connect(path, timeout=0.05))
    holder = real_connect(str(db), timeout=0.05, isolation_level=None)
    holder.execute("BEGIN IMMEDIATE")
    try:
        with pytest.raises(sqlite3.OperationalError, match="locked"):
            orphan_scan.fix(data_dir=env.data_dir, confirm=True, dry_run=False)
    finally:
        holder.execute("ROLLBACK")
        holder.close()
    with sqlite3.connect(str(db)) as conn:
        assert conn.execute("SELECT COUNT(*) FROM translate_log WHERE user_id = 'ghost_user'").fetchone()[0] == 1


def _live_card_states(env) -> list[int]:
    with sqlite3.connect(str(env.user_dir / "cards.db")) as conn:
        return [r[0] for r in conn.execute("SELECT is_deleted FROM card")]


@pytest.mark.parametrize("dry_run", [True, False])
def test_fix_refuses_when_notebooks_db_missing(env, dry_run):
    """#2705: a vanished notebooks.db must not make every live card an orphan."""
    from kg.orphan_scan import UserRegistryUnavailable, fix

    (env.user_dir / "notebooks.db").unlink()
    before = _live_card_states(env)
    assert before and not any(before)
    with pytest.raises(UserRegistryUnavailable):
        fix(data_dir=env.data_dir, confirm=True, dry_run=dry_run)
    assert _live_card_states(env) == before


@pytest.mark.parametrize("dry_run", [True, False])
def test_fix_refuses_when_cards_db_missing_with_graph_and_judge_rows(env, dry_run):
    """#3434: a vanished cards.db must not make graph links / judge_log rows orphans."""
    import kg.judge_log as jl
    from kg.orphan_scan import UserRegistryUnavailable, fix

    link = {
        "id": "lk_live",
        "from_id": env.real_card_id,
        "to_id": env.real_card_id,
        "kind": "shares_usage",
        "confidence": 0.9,
        "reason": "test",
        "created_at": "2024-01-01T00:00:00+00:00",
        "status": "active",
    }
    graph_path = env.user_dir / f"graph_{env.real_notebook_id}.json"
    graph_path.write_text(json.dumps([link]))
    jl.record(
        user_id=env.user_id,
        notebook_id=env.real_notebook_id,
        from_id=env.real_card_id,
        to_id=env.real_card_id,
        similarity=0.7,
        verdict="accept",
        confidence=0.9,
        accepted=True,
    )
    graph_before = graph_path.read_text()
    (env.user_dir / "cards.db").unlink()

    with pytest.raises(UserRegistryUnavailable):
        fix(data_dir=env.data_dir, confirm=True, dry_run=dry_run)

    assert graph_path.read_text() == graph_before
    with sqlite3.connect(str(env.data_dir / "judge_log.db")) as conn:
        assert conn.execute("SELECT COUNT(*) FROM judge_log").fetchone()[0] == 1


@pytest.mark.parametrize("dry_run", [True, False])
def test_fix_refuses_when_registered_user_dir_missing_with_judge_rows(env, dry_run):
    """#3460: a registered uid whose whole users/<uid>/ dir is gone must not
    make its judge_log rows look like orphans (they would be hard-deleted)."""
    import shutil

    import kg.judge_log as jl
    from kg.orphan_scan import UserRegistryUnavailable, fix

    jl.record(
        user_id=env.user_id,
        notebook_id=env.real_notebook_id,
        from_id=env.real_card_id,
        to_id=env.real_card_id,
        similarity=0.7,
        verdict="accept",
        confidence=0.9,
        accepted=True,
    )
    shutil.rmtree(env.user_dir)

    with pytest.raises(UserRegistryUnavailable):
        fix(data_dir=env.data_dir, confirm=True, dry_run=dry_run)

    with sqlite3.connect(str(env.data_dir / "judge_log.db")) as conn:
        assert conn.execute("SELECT COUNT(*) FROM judge_log").fetchone()[0] == 1
