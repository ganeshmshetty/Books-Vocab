from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from fastapi import FastAPI

from .llm.providers import validate_provider_routing
from .settings import KGSettings


@dataclass(frozen=True)
class AppLifespanDependencies:
    settings: KGSettings
    logger: logging.Logger | Any
    assert_single_worker_fn: Callable[[Path], None]
    # Reapers take the data root explicitly: they may only touch the directory
    # whose worker lock this process holds (never an independently read env).
    reap_orphaned_runs_fn: Callable[[Path], int]
    reap_interrupted_add_link_operations_fn: Callable[[Path], int]
    # Runtime stores resolve the locked root for exactly as long as the lock is
    # held (see kg.runtime_data_root).
    bind_runtime_data_root_fn: Callable[[Path], None]
    release_runtime_data_root_fn: Callable[[Path], None]
    release_worker_lock_fn: Callable[[], None]
    reset_clients_fn: Callable[[], None]
    reset_async_clients_fn: Callable[[], Awaitable[None]]
    # Optional: compensates orphaned staged shared-deck copies (#2269).
    reap_stale_staged_copies_fn: Callable[[Path], int] | None = None
    # Optional: the daily log-retention loop (#2091). Started once the worker
    # lock is held and cancelled before that lock is released.
    log_retention_loop_fn: Callable[[], Awaitable[None]] | None = None


def build_app_lifespan_from_dependencies(
    *,
    dependencies: AppLifespanDependencies,
):
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        del app
        dependencies.logger.info("KG API starting up")
        # Surface (but do not hard-fail on) missing admin credentials: with a
        # blank token/password, require_admin silently rejects every admin call,
        # which is easy to miss in production. Empty values stay valid for
        # test/dev flows by design.
        if not dependencies.settings.admin_token:
            dependencies.logger.warning("admin_token is empty → admin API is disabled (set ADMIN_TOKEN to enable)")
        if not dependencies.settings.admin_password:
            dependencies.logger.warning(
                "admin_password is empty → admin password login is disabled (set ADMIN_PASSWORD to enable)"
            )
        # Validate LLM routing before taking the worker lock so a bad deploy
        # env fails startup without leaking the lock.
        validate_provider_routing()
        data_root = dependencies.settings.data_dir
        worker_lock_path = data_root / ".worker.lock"
        dependencies.assert_single_worker_fn(worker_lock_path)
        try:
            reaped = dependencies.reap_orphaned_runs_fn(data_root)
            reaped_operations = dependencies.reap_interrupted_add_link_operations_fn(data_root)
            reaped_staged = (
                dependencies.reap_stale_staged_copies_fn(data_root)
                if dependencies.reap_stale_staged_copies_fn is not None
                else 0
            )
        except BaseException:
            dependencies.release_worker_lock_fn()
            worker_lock_path.unlink(missing_ok=True)
            raise
        if reaped:
            dependencies.logger.info(
                "Reaped %d orphaned pipeline run(s) → interrupted",
                reaped,
            )
        if reaped_operations:
            dependencies.logger.info(
                "Reaped %d orphaned add-link operation(s) → interrupted",
                reaped_operations,
            )
        if reaped_staged:
            dependencies.logger.info("Reaped %d orphaned staged shared-deck copy(ies)", reaped_staged)
        dependencies.bind_runtime_data_root_fn(data_root)
        retention_task = (
            asyncio.create_task(dependencies.log_retention_loop_fn())
            if dependencies.log_retention_loop_fn is not None
            else None
        )
        # Teardown also runs when the server aborts instead of sending a clean
        # shutdown: a leaked binding would keep redirecting every runtime store
        # (quota ledger included) to a root this process no longer locks.
        try:
            yield
        finally:
            dependencies.logger.info("KG API shutting down")
            if retention_task is not None:
                # Stop background writers before the runtime root and worker lock go.
                retention_task.cancel()
                await asyncio.gather(retention_task, return_exceptions=True)
            dependencies.release_runtime_data_root_fn(data_root)
            dependencies.release_worker_lock_fn()
            dependencies.reset_clients_fn()
            await dependencies.reset_async_clients_fn()

    return lifespan
