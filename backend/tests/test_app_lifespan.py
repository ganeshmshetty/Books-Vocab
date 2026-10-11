from __future__ import annotations

import asyncio
from dataclasses import replace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from kg import worker_guard
from kg.app_lifespan import AppLifespanDependencies, build_app_lifespan_from_dependencies
from kg.settings import KGSettings


class _SpyLogger:
    def __init__(self, events: list[object]) -> None:
        self._events = events

    def info(self, message: str, *args: object) -> None:
        rendered = message % args if args else message
        self._events.append(("log", rendered))

    def warning(self, message: str, *args: object) -> None:
        rendered = message % args if args else message
        self._events.append(("warning", rendered))


def _settings(tmp_path) -> KGSettings:
    return KGSettings(
        data_dir=tmp_path,
        jwt_secret="test-secret-key-for-ci-at-least-32-bytes",
        admin_token="adm-secret",
        admin_password="adm-pw-secret",
        app_store_allow_unsigned_sync=True,
        app_store_allow_unsigned_notifications=True,
    )


def _dependencies(tmp_path, events: list[object]) -> AppLifespanDependencies:
    async def _reset_async_clients() -> None:
        events.append("reset_async_clients")

    def _assert_single_worker(lock_path) -> None:
        events.append(("assert_single_worker", lock_path))

    def _reap_orphaned_runs(data_root) -> int:
        events.append(("reap_orphaned_runs", data_root))
        return 2

    def _reap_add_link_operations(data_root) -> int:
        events.append(("reap_add_link_operations", data_root))
        return 3

    def _bind_runtime_data_root(data_root) -> None:
        events.append(("bind_runtime_data_root", data_root))

    def _release_runtime_data_root(data_root) -> None:
        events.append(("release_runtime_data_root", data_root))

    def _release_worker_lock() -> None:
        events.append("release_worker_lock")

    def _reset_clients() -> None:
        events.append("reset_clients")

    return AppLifespanDependencies(
        settings=_settings(tmp_path),
        logger=_SpyLogger(events),
        assert_single_worker_fn=_assert_single_worker,
        reap_orphaned_runs_fn=_reap_orphaned_runs,
        reap_interrupted_add_link_operations_fn=_reap_add_link_operations,
        bind_runtime_data_root_fn=_bind_runtime_data_root,
        release_runtime_data_root_fn=_release_runtime_data_root,
        release_worker_lock_fn=_release_worker_lock,
        reset_clients_fn=_reset_clients,
        reset_async_clients_fn=_reset_async_clients,
    )


def test_build_app_lifespan_from_dependencies_runs_expected_flow(tmp_path):
    events: list[object] = []
    lifespan = build_app_lifespan_from_dependencies(dependencies=_dependencies(tmp_path, events))
    app = FastAPI(lifespan=lifespan)

    with TestClient(app):
        pass

    assert events == [
        ("log", "KG API starting up"),
        ("assert_single_worker", tmp_path / ".worker.lock"),
        # Reapers get the exact directory whose worker lock was just taken.
        ("reap_orphaned_runs", tmp_path),
        ("reap_add_link_operations", tmp_path),
        ("log", "Reaped 2 orphaned pipeline run(s) → interrupted"),
        ("log", "Reaped 3 orphaned add-link operation(s) → interrupted"),
        # Runtime stores use the locked root only while the lock is held.
        ("bind_runtime_data_root", tmp_path),
        ("log", "KG API shutting down"),
        ("release_runtime_data_root", tmp_path),
        "release_worker_lock",
        "reset_clients",
        "reset_async_clients",
    ]


def test_lifespan_releases_worker_lock_when_reaping_fails(tmp_path):
    lock_path = tmp_path / ".worker.lock"
    worker_guard.release_worker_lock()
    events: list[object] = []

    def _reap_orphaned_runs(data_root) -> int:
        events.append(("reap_orphaned_runs", data_root))
        raise RuntimeError("reap failed")

    deps = replace(
        _dependencies(tmp_path, events),
        assert_single_worker_fn=worker_guard.assert_single_worker,
        reap_orphaned_runs_fn=_reap_orphaned_runs,
        release_worker_lock_fn=worker_guard.release_worker_lock,
    )
    app = FastAPI(lifespan=build_app_lifespan_from_dependencies(dependencies=deps))

    try:
        with pytest.raises(RuntimeError, match="reap failed"):
            with TestClient(app):
                pass

        assert worker_guard._lock_fd is None
        assert not lock_path.exists()
        assert not any(isinstance(event, tuple) and event[0] == "bind_runtime_data_root" for event in events)
    finally:
        worker_guard.release_worker_lock()
        lock_path.unlink(missing_ok=True)


def test_lifespan_releases_worker_lock_when_add_link_reaping_fails(tmp_path):
    lock_path = tmp_path / ".worker.lock"
    worker_guard.release_worker_lock()
    events: list[object] = []

    def _reap_add_link_operations(data_root) -> int:
        events.append(("reap_add_link_operations", data_root))
        raise RuntimeError("add-link reap failed")

    deps = replace(
        _dependencies(tmp_path, events),
        assert_single_worker_fn=worker_guard.assert_single_worker,
        reap_interrupted_add_link_operations_fn=_reap_add_link_operations,
        release_worker_lock_fn=worker_guard.release_worker_lock,
    )
    app = FastAPI(lifespan=build_app_lifespan_from_dependencies(dependencies=deps))

    try:
        with pytest.raises(RuntimeError, match="add-link reap failed"):
            with TestClient(app):
                pass

        assert worker_guard._lock_fd is None
        assert not lock_path.exists()
        # A failed startup never binds the runtime root it no longer holds the lock on.
        assert not any(isinstance(event, tuple) and event[0] == "bind_runtime_data_root" for event in events)
    finally:
        worker_guard.release_worker_lock()
        lock_path.unlink(missing_ok=True)


def _run_lifespan_with_settings(tmp_path, settings: KGSettings) -> list[object]:
    events: list[object] = []
    deps = replace(_dependencies(tmp_path, events), settings=settings)
    lifespan = build_app_lifespan_from_dependencies(dependencies=deps)
    app = FastAPI(lifespan=lifespan)
    with TestClient(app):
        pass
    return events


def _warnings(events: list[object]) -> list[str]:
    return [e[1] for e in events if isinstance(e, tuple) and len(e) == 2 and e[0] == "warning"]


def test_empty_admin_token_logs_startup_warning(tmp_path):
    """Blank admin_token at startup → a prominent WARNING (no hard-fail)."""
    settings = replace(_settings(tmp_path), admin_token="", admin_password="adm-pw")
    events = _run_lifespan_with_settings(tmp_path, settings)
    warnings = _warnings(events)
    assert any("admin_token" in w.lower() or "admin token" in w.lower() for w in warnings), warnings


def test_empty_admin_password_logs_startup_warning(tmp_path):
    """Blank admin_password at startup → a prominent WARNING (no hard-fail)."""
    settings = replace(_settings(tmp_path), admin_token="adm-tok", admin_password="")
    events = _run_lifespan_with_settings(tmp_path, settings)
    warnings = _warnings(events)
    assert any("admin_password" in w.lower() or "admin password" in w.lower() for w in warnings), warnings


def test_configured_admin_secrets_emit_no_warning(tmp_path):
    """Both admin secrets set → no admin-secret startup warning."""
    settings = replace(_settings(tmp_path), admin_token="adm-tok", admin_password="adm-pw")
    events = _run_lifespan_with_settings(tmp_path, settings)
    warnings = _warnings(events)
    assert not any("admin" in w.lower() for w in warnings), warnings


def test_empty_admin_secrets_do_not_hard_fail(tmp_path):
    """Blank admin secrets must NOT raise at startup (dev/test flow preserved)."""
    settings = replace(_settings(tmp_path), admin_token="", admin_password="")
    events = _run_lifespan_with_settings(tmp_path, settings)
    # Startup + shutdown both completed (no exception escaped TestClient).
    assert ("log", "KG API starting up") in events
    assert ("log", "KG API shutting down") in events


def test_app_lifespan_dependencies_are_replaceable_named_contract(tmp_path):
    deps = _dependencies(tmp_path, [])
    replacement_logger = _SpyLogger([])

    replaced = replace(deps, logger=replacement_logger)

    assert replaced.logger is replacement_logger
    assert replaced.settings == deps.settings


def _run_lifespan(tmp_path) -> list[object]:
    events: list[object] = []
    deps = _dependencies(tmp_path, events)
    app = FastAPI(lifespan=build_app_lifespan_from_dependencies(dependencies=deps))
    with TestClient(app):
        pass
    return events


def _clear_llm_env(monkeypatch) -> None:
    import os

    for key in list(os.environ):
        if key.startswith("LLM_PROVIDER_"):
            monkeypatch.delenv(key)
    monkeypatch.setenv("GEMINI_API_KEY", "fake-key")


def _assert_fails_before_worker_lock(tmp_path, exc: type[Exception], match: str) -> None:
    events: list[object] = []
    deps = _dependencies(tmp_path, events)
    app = FastAPI(lifespan=build_app_lifespan_from_dependencies(dependencies=deps))
    with pytest.raises(exc, match=match):
        with TestClient(app):
            pass
    assert not any(isinstance(e, tuple) and e[0] == "assert_single_worker" for e in events)


def test_lifespan_starts_with_default_gemini_routing(tmp_path, monkeypatch):
    _clear_llm_env(monkeypatch)
    events = _run_lifespan(tmp_path)
    assert ("assert_single_worker", tmp_path / ".worker.lock") in events


def test_lifespan_rejects_unknown_provider_before_worker_lock(tmp_path, monkeypatch):
    _clear_llm_env(monkeypatch)
    monkeypatch.setenv("LLM_PROVIDER_TRANSLATE", "deepseak")
    _assert_fails_before_worker_lock(tmp_path, ValueError, "deepseak")


@pytest.mark.parametrize("value", [None, "", "   "])
def test_lifespan_rejects_missing_provider_api_key(tmp_path, monkeypatch, value):
    _clear_llm_env(monkeypatch)
    monkeypatch.setenv("LLM_PROVIDER_DEFAULT", "deepseek")
    if value is None:
        monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    else:
        monkeypatch.setenv("DEEPSEEK_API_KEY", value)
    _assert_fails_before_worker_lock(tmp_path, RuntimeError, "DEEPSEEK_API_KEY")


def test_lifespan_accepts_deepseek_default_with_key(tmp_path, monkeypatch):
    _clear_llm_env(monkeypatch)
    monkeypatch.setenv("LLM_PROVIDER_DEFAULT", "deepseek")
    monkeypatch.setenv("DEEPSEEK_API_KEY", "k")
    _run_lifespan(tmp_path)


def test_lifespan_rejects_embed_routed_to_non_embedding_provider(tmp_path, monkeypatch):
    _clear_llm_env(monkeypatch)
    monkeypatch.setenv("DEEPSEEK_API_KEY", "k")
    monkeypatch.setenv("LLM_PROVIDER_EMBED", "deepseek")
    _assert_fails_before_worker_lock(tmp_path, ValueError, "embeddings")


def test_lifespan_rejects_missing_gemini_key_for_default_routing(tmp_path, monkeypatch):
    _clear_llm_env(monkeypatch)
    monkeypatch.delenv("GEMINI_API_KEY")
    _assert_fails_before_worker_lock(tmp_path, RuntimeError, "GEMINI_API_KEY")


def test_lifespan_reaps_staged_copies_after_worker_lock(tmp_path):
    events: list[object] = []

    def _reap_staged(data_root) -> int:
        events.append(("reap_staged", data_root))
        return 1

    deps = replace(_dependencies(tmp_path, events), reap_stale_staged_copies_fn=_reap_staged)
    app = FastAPI(lifespan=build_app_lifespan_from_dependencies(dependencies=deps))

    with TestClient(app):
        pass

    names = [e[0] if isinstance(e, tuple) else e for e in events]
    assert names.index("assert_single_worker") < names.index("reap_staged") < names.index("bind_runtime_data_root")
    assert ("reap_staged", tmp_path) in events


def test_create_app_startup_reaps_orphaned_staged_copy_via_settings_catalog_path(tmp_path, monkeypatch):
    """End-to-end wiring (#2269): the real create_app hands the reaper the
    catalog path from settings, so a staged notebook with a committed copy-log
    survives startup while an un-logged orphan is reaped."""
    from kg.api import create_app
    from kg.notebook import NotebookStore
    from kg.shared_decks.store import SharedDeckStore
    from test_shared_decks_reaper import _age

    _clear_llm_env(monkeypatch)
    settings = _settings(tmp_path)
    user_dir = tmp_path / "users" / "u1"
    user_dir.mkdir(parents=True)
    nbs = NotebookStore(user_dir / "notebooks.db")
    orphan = nbs.create(name="orphan", is_staged=True)
    logged = nbs.create(name="logged", is_staged=True)
    for nb in (orphan, logged):
        _age(nbs, nb.id, 60)
    catalog = SharedDeckStore(settings.shared_decks_path)
    assert catalog.record_copy("u1", "k", "deck", 1, logged.id)
    catalog.close()

    with TestClient(create_app(settings)):
        pass

    assert NotebookStore(user_dir / "notebooks.db").staged_ids() == [logged.id]


def test_lifespan_cancels_log_retention_loop_before_releasing_lock(tmp_path):
    """The daily retention loop is cancelled before the worker lock or runtime root is released (#2091)."""
    events: list[object] = []

    async def _log_retention_loop() -> None:
        events.append("log_retention_loop_started")
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            events.append("log_retention_loop_cancelled")
            raise

    deps = replace(_dependencies(tmp_path, events), log_retention_loop_fn=_log_retention_loop)
    app = FastAPI(lifespan=build_app_lifespan_from_dependencies(dependencies=deps))

    with TestClient(app):
        pass

    assert "log_retention_loop_started" in events
    cancelled = events.index("log_retention_loop_cancelled")
    assert cancelled < events.index(("release_runtime_data_root", tmp_path))
    assert cancelled < events.index("release_worker_lock")
    # The loop only starts once the worker lock is held and the runtime root is bound.
    assert events.index(("bind_runtime_data_root", tmp_path)) < events.index("log_retention_loop_started")
