"""FastAPI server for Knowledge Graph — lightweight bridge for BooksAndVocab.

App factory, middleware stack, and route wiring.
Endpoint functions live in their respective routers/*.py files.
Shared dependencies live in deps.py.

Usage:
    uvicorn kg.api:app --reload --port 8000
"""

from __future__ import annotations

import atexit
import logging
from functools import partial
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI

from .logging_config import configure_logging

configure_logging()
logger = logging.getLogger(__name__)

# Memory ring-buffer log handler for the admin dashboard.
# Re-exported so existing tests (from kg.api import _mem_log) keep working.
from .mem_log import _MemoryLogHandler, install_memory_log_handler  # noqa: F401

_mem_log = install_memory_log_handler(maxlen=1000)

from .api_compat import *  # noqa: F401,F403 - stable kg.api compatibility surface
from .api_compat import (
    _build_entitlements_response,
    _card_store,
    _current_admin_grant_record,
    _default_subscription_payload,
)
from .app_exception_handlers import (
    AppExceptionHandlerDependencies,
    install_app_exception_handlers_from_dependencies,
)
from .app_lifespan import AppLifespanDependencies, build_app_lifespan_from_dependencies
from .app_middleware import AppMiddlewareDependencies, install_app_middlewares_from_dependencies
from .app_router_composition import AppRouterDependencies, build_app_routers_from_dependencies, include_app_routers
from .app_runtime_state import RuntimeUserStateDependencies, install_runtime_user_state_from_dependencies
from .log_retention_scheduler import LogRetentionScheduler
from .rate_limit import api_limiter, login_limiter, translate_limiter
from .service_factories import clear_store_cache
from .settings import KGSettings, load_settings

load_dotenv()

# Initialize Sentry early so module-level errors and the lifespan are captured.
# No-op when SENTRY_DSN is unset.
from .sentry_init import init_sentry  # noqa: E402

init_sentry()


def create_app(settings: KGSettings | None = None) -> FastAPI:
    atexit.register(clear_store_cache)

    settings = settings or load_settings()

    # Sync quota limits with settings
    from .quota_service import configure_limits

    configure_limits(pro=settings.pro_daily_limit_usd, free=settings.free_daily_limit_usd)
    from . import runtime_data_root
    from .pipeline_log import reap_orphaned_runs
    from .service_factories import reset_async_clients, reset_clients
    from .shared_decks.reaper import reap_stale_staged_copies
    from .vocab_add_link_operation import reap_interrupted_operations
    from .worker_guard import assert_single_worker, release_worker_lock

    app = FastAPI(
        title="Knowledge Graph API",
        version="2.1.0",
        lifespan=build_app_lifespan_from_dependencies(
            dependencies=AppLifespanDependencies(
                settings=settings,
                logger=logger,
                assert_single_worker_fn=assert_single_worker,
                reap_orphaned_runs_fn=reap_orphaned_runs,
                reap_interrupted_add_link_operations_fn=reap_interrupted_operations,
                bind_runtime_data_root_fn=runtime_data_root.bind,
                release_runtime_data_root_fn=runtime_data_root.release,
                release_worker_lock_fn=release_worker_lock,
                reset_clients_fn=reset_clients,
                reset_async_clients_fn=reset_async_clients,
                reap_stale_staged_copies_fn=partial(
                    reap_stale_staged_copies, shared_decks_path=settings.shared_decks_path
                ),
                log_retention_loop_fn=LogRetentionScheduler().run_forever,
            )
        ),
    )
    app.state.kg_settings = settings

    # --- user store helpers ---
    install_runtime_user_state_from_dependencies(
        dependencies=RuntimeUserStateDependencies(
            app=app,
            settings=settings,
            default_subscription_payload_fn=_default_subscription_payload,
        )
    )

    # --- middleware stack ---
    from . import sentry_init as _sentry_init
    from .request_context import request_id_var

    install_app_middlewares_from_dependencies(
        dependencies=AppMiddlewareDependencies(
            app=app,
            cors_origins=settings.cors_origins,
            rate_limit_trusted_hops=settings.rate_limit_trusted_hops,
            request_id_var=request_id_var,
            tag_request_id=_sentry_init.tag_request_id,
            api_limiter=api_limiter,
            translate_limiter=translate_limiter,
            login_limiter=login_limiter,
        )
    )
    install_app_exception_handlers_from_dependencies(
        dependencies=AppExceptionHandlerDependencies(
            app=app,
            logger=logger,
        )
    )

    # --- routers ---
    def _settings_fn() -> KGSettings:
        return app.state.kg_settings

    def _users_lock_file_fn() -> Path:
        return app.state.kg_settings.users_lock_file

    def _load_users_runtime():
        return app.state.load_users()

    def _save_users_runtime(users):
        app.state.save_users(users)

    app_routers = build_app_routers_from_dependencies(
        dependencies=AppRouterDependencies(
            runtime_settings_fn=_settings_fn,
            runtime_users_lock_file_fn=_users_lock_file_fn,
            load_users_fn=_load_users_runtime,
            save_users_fn=_save_users_runtime,
            mem_log_getter=_mem_log.get,
            card_store_factory=_card_store,
            build_entitlements_response_fn=_build_entitlements_response,
            current_admin_grant_record_fn=_current_admin_grant_record,
        )
    )
    include_app_routers(app, app_routers)

    # NOTE: the legacy public /api/podcast-media/ StaticFiles mount was removed
    # (2026-05). It served podcast audio/subtitles WITHOUT auth — a public-read
    # bypass of the authenticated /api/podcasts/{series_id}/{ep_num}/audio
    # endpoint. Production deprecation logs showed zero hits over a 12-day
    # window while the authenticated endpoint served all traffic, confirming
    # every shipped client had migrated. Do NOT reintroduce an unauthenticated
    # mount — route podcast media through the authenticated router instead.

    # --- public static assets (官網 design-system CSS + brand fonts) ---
    # Served at /static/* for the public pages (privacy/terms/support/guide). The
    # files live in backend/static/ so the rsync-only-backend/ deploy ships them;
    # kg-tokens.css / kg-components.css are GENERATED by ops/gen_web_tokens.py
    # (drift from the iOS SoT is guarded by ops/token_drift_check.py). This is a
    # read-only public asset mount — unlike the removed podcast-media mount, it
    # serves no user data, only design-system stylesheets and brand fonts.
    from fastapi.staticfiles import StaticFiles

    _static_dir = Path(__file__).resolve().parent.parent.parent / "static"
    if _static_dir.is_dir():
        app.mount("/static", StaticFiles(directory=_static_dir), name="static")

    # Pin the podcast_progress singleton to the same per-instance data_dir
    # as the rest of the app state — keeps test isolation honest when
    # conftest swaps the settings without touching env vars.
    from . import podcast_progress as _progress_store

    _progress_store.set_data_dir(settings.data_dir)

    return app


app = create_app()
