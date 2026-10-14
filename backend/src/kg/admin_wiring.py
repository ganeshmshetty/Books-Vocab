"""Admin route handler wiring — creates admin endpoint functions with injected dependencies."""

from __future__ import annotations

import logging
import os
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Protocol

from fastapi import Cookie, Header, HTTPException, Query
from fastapi.responses import HTMLResponse
from starlette.concurrency import run_in_threadpool

from .admin_assets import ADMIN_HTML, ADMIN_TESTS_HTML, ADMIN_USER_DETAIL_HTML
from .admin_handlers import (
    admin_actor_fingerprint,
    admin_audit_response,
    admin_grant_pro_access_response,
    admin_host_metrics_response,
    admin_last_test_run_response,
    admin_logs_response,
    admin_revoke_pro_access_response,
    admin_run_tests_response,
    admin_stats_response,
    admin_test_catalog_response,
    admin_tests_ui_response,
    admin_ui_response,
    admin_user_entitlement_response,
)
from .admin_test_matrix import (
    build_test_catalog,
    get_last_test_run,
    run_pytest_matrix,
    store_last_test_run,
)
from .api_models import (
    AdminGrantRequest,
    AdminTestRunRequest,
    AdminUserEntitlementResponse,
    EntitlementsResponse,
)
from .types import AdminGrantRecord, StoredUserRecord, UsersPayload

if TYPE_CHECKING:
    from .cards import CardStore

PIPELINE_RUNS_MAX = 100
TRANSLATE_HISTORY_MAX = 200
logger = logging.getLogger(__name__)


class SupportsAdminSettings(Protocol):
    admin_token: str
    admin_password: str
    data_dir: Path


RuntimeSettingsFn = Callable[[], SupportsAdminSettings]
UsersLoader = Callable[[], UsersPayload]
UsersSaver = Callable[[UsersPayload], None]


class MemLogGetter(Protocol):
    def __call__(self, n: int = 200, level: str | None = None) -> list[dict[str, Any]]: ...


class CardStoreFactory(Protocol):
    def __call__(self, data_dir: Path) -> CardStore: ...


EntitlementsBuilder = Callable[[StoredUserRecord | None], EntitlementsResponse]
AdminGrantRecordReader = Callable[[StoredUserRecord | None], AdminGrantRecord]
AdminEndpointResult = dict[str, Any]


@dataclass(frozen=True)
class AdminHandlerDependencies:
    runtime_settings_fn: RuntimeSettingsFn
    runtime_users_lock_file_fn: Callable[[], Path]
    load_users_fn: UsersLoader
    save_users_fn: UsersSaver
    mem_log_getter: MemLogGetter
    card_store_factory: CardStoreFactory
    build_entitlements_response_fn: EntitlementsBuilder
    current_admin_grant_record_fn: AdminGrantRecordReader


@dataclass(frozen=True)
class AdminHandlers:
    admin_ui: Callable[[str | None], HTMLResponse]
    admin_stats: Callable[[], AdminEndpointResult]
    admin_logs: Callable[[int, str | None], AdminEndpointResult]
    admin_user_entitlement: Callable[[str], AdminUserEntitlementResponse]
    admin_grant_pro_access: Callable[
        [AdminGrantRequest, str, str | None, str | None, str | None],
        AdminUserEntitlementResponse,
    ]
    admin_revoke_pro_access: Callable[[str, str | None, str | None, str | None], AdminUserEntitlementResponse]
    admin_run_tests: Callable[[AdminTestRunRequest | None], AdminEndpointResult]
    admin_last_test_run: Callable[[], AdminEndpointResult]
    admin_test_catalog: Callable[[], AdminEndpointResult]
    admin_tests_ui: Callable[[str | None], HTMLResponse]
    admin_graph_density: Callable[[str, str], AdminEndpointResult]
    admin_graph_playback: Callable[[str, str], AdminEndpointResult]
    admin_pipeline_runs: Callable[[str, int], AdminEndpointResult]
    admin_judge_stats: Callable[[str], AdminEndpointResult]
    admin_translate_history: Callable[[str, int, str | None, str | None], AdminEndpointResult]
    admin_user_activity: Callable[[str, int], AdminEndpointResult]
    admin_user_usage: Callable[[str, str], AdminEndpointResult]
    admin_user_cost_summary: Callable[[str, str], AdminEndpointResult]
    admin_host_metrics: Callable[[], AdminEndpointResult]
    admin_users_search: Callable[[str, int], AdminEndpointResult]
    admin_observability: Callable[[], AdminEndpointResult]
    admin_stats_trends: Callable[[int], AdminEndpointResult]
    admin_log_retention_run: Callable[[], Awaitable[AdminEndpointResult]]
    admin_audit: Callable[[str | None, int, str | None], AdminEndpointResult]
    admin_user_detail_ui: Callable[[str | None], HTMLResponse]
    admin_orphans_scan: Callable[[], Awaitable[AdminEndpointResult]]


def _clamp_limit(limit: int, cap: int) -> int:
    return max(1, min(limit, cap))


def create_admin_handlers_from_dependencies(
    *,
    dependencies: AdminHandlerDependencies,
) -> AdminHandlers:
    """Create all admin endpoint handler functions with dependencies wired in.

    Returns a typed bundle consumed by admin router composition.
    """
    runtime_settings_fn = dependencies.runtime_settings_fn
    runtime_users_lock_file_fn = dependencies.runtime_users_lock_file_fn
    load_users_fn = dependencies.load_users_fn
    save_users_fn = dependencies.save_users_fn
    mem_log_getter = dependencies.mem_log_getter
    build_entitlements_response_fn = dependencies.build_entitlements_response_fn
    current_admin_grant_record_fn = dependencies.current_admin_grant_record_fn

    def admin_ui(admin_session: str | None = None) -> HTMLResponse:
        """Admin dashboard UI."""
        return admin_ui_response(
            admin_html=ADMIN_HTML,
            admin_token=runtime_settings_fn().admin_token,
            cookie_token=admin_session,
        )

    def admin_stats() -> AdminEndpointResult:
        """Return per-user token + vocab stats for admin dashboard."""
        from .token_tracker import get_all_stats

        settings = runtime_settings_fn()
        return admin_stats_response(
            load_users=load_users_fn,
            get_all_stats=get_all_stats,
            build_entitlements_response=build_entitlements_response_fn,
            current_admin_grant_record=current_admin_grant_record_fn,
            data_dir=settings.data_dir,
        )

    def admin_logs(n: int = 200, level: str | None = None) -> AdminEndpointResult:
        """Return recent in-memory log entries for the admin dashboard."""
        return admin_logs_response(
            log_getter=mem_log_getter,
            n=n,
            level=level,
        )

    def admin_user_entitlement(user_id: str) -> AdminUserEntitlementResponse:
        """Return one user's computed Pro entitlement plus raw admin grant metadata."""
        return admin_user_entitlement_response(
            user_id,
            load_users=load_users_fn,
            build_entitlements_response=build_entitlements_response_fn,
            current_admin_grant_record=current_admin_grant_record_fn,
        )

    def _actor_from_request(
        token: str | None,
        authorization: str | None,
        admin_session: str | None,
    ) -> str:
        return admin_actor_fingerprint(
            token=token,
            authorization=authorization,
            cookie_token=admin_session,
            admin_token=runtime_settings_fn().admin_token,
        )

    def admin_grant_pro_access(
        req: AdminGrantRequest,
        user_id: str,
        token: str | None = Query(None),
        authorization: str | None = Header(None),
        admin_session: str | None = Cookie(None),
    ) -> AdminUserEntitlementResponse:
        """Manually grant Pro access for a user through the admin surface."""
        actor = _actor_from_request(token, authorization, admin_session)
        return admin_grant_pro_access_response(
            user_id,
            req,
            users_lock_file=runtime_users_lock_file_fn(),
            load_users=load_users_fn,
            save_users=save_users_fn,
            current_admin_grant_record=current_admin_grant_record_fn,
            build_entitlements_response=build_entitlements_response_fn,
            admin_uid=actor,
        )

    def admin_revoke_pro_access(
        user_id: str,
        token: str | None = Query(None),
        authorization: str | None = Header(None),
        admin_session: str | None = Cookie(None),
    ) -> AdminUserEntitlementResponse:
        """Remove manual Pro access for a user through the admin surface."""
        actor = _actor_from_request(token, authorization, admin_session)
        return admin_revoke_pro_access_response(
            user_id,
            users_lock_file=runtime_users_lock_file_fn(),
            load_users=load_users_fn,
            save_users=save_users_fn,
            current_admin_grant_record=current_admin_grant_record_fn,
            build_entitlements_response=build_entitlements_response_fn,
            admin_uid=actor,
        )

    def admin_run_tests(
        req: AdminTestRunRequest | None = None,
    ) -> AdminEndpointResult:
        """Run test suite and return matrix view data."""
        return admin_run_tests_response(
            req=req,
            run_pytest_matrix=run_pytest_matrix,
            store_last_test_run=store_last_test_run,
        )

    def admin_last_test_run() -> AdminEndpointResult:
        """Get latest test run result for matrix page."""
        return admin_last_test_run_response(
            get_last_test_run=get_last_test_run,
        )

    def admin_test_catalog() -> AdminEndpointResult:
        """Return clickable test-matrix catalog."""
        return admin_test_catalog_response(
            build_test_catalog=build_test_catalog,
        )

    def admin_tests_ui(admin_session: str | None = None) -> HTMLResponse:
        """Minimal grayscale test matrix dashboard."""
        return admin_tests_ui_response(
            admin_tests_html=ADMIN_TESTS_HTML,
            admin_token=runtime_settings_fn().admin_token,
            cookie_token=admin_session,
        )

    def _safe_user_dir(uid: str) -> Path:
        """Resolve user directory, rejecting path traversal.

        Defense in depth (Track-5): the boundary check below uses
        ``commonpath`` rather than a bare ``startswith`` prefix. A prefix
        check has no trailing-separator guard, so ``users_root=<data>/users``
        with ``uid="../users-x"`` resolves to the sibling ``<data>/users-x``,
        whose string still starts with ``<data>/users`` — leaking a neighbour
        of the users root. ``commonpath`` compares path *components*, closing
        that gap, and uids containing a path separator are rejected up front.
        """
        users_root = (runtime_settings_fn().data_dir / "users").resolve()
        user_dir = (users_root / uid).resolve()
        try:
            within_root = os.path.commonpath([str(user_dir), str(users_root)]) == str(users_root)
        except ValueError:
            logger.warning(
                "Failed to resolve commonpath for admin user_id=%r user_dir=%s users_root=%s",
                uid,
                user_dir,
                users_root,
            )
            within_root = False  # different drives (Windows) → not under root
        if "/" in uid or os.sep in uid or user_dir == users_root or not within_root:
            raise HTTPException(status_code=400, detail="Invalid user_id")
        return user_dir

    def admin_graph_density(user_id: str, notebook_id: str = "default") -> AdminEndpointResult:
        """Return time-series graph density data for a user."""
        from .admin_graph_density import compute_graph_density

        return compute_graph_density(_safe_user_dir(user_id), notebook_id, user_id=user_id)

    def admin_graph_playback(user_id: str, notebook_id: str = "default") -> AdminEndpointResult:
        """Return full graph nodes + edges with timestamps for playback."""
        from .admin_graph_playback import compute_graph_playback

        return compute_graph_playback(_safe_user_dir(user_id), notebook_id, user_id=user_id)

    def admin_pipeline_runs(user_id: str, limit: int = 20) -> AdminEndpointResult:
        """Return pipeline run history for a user."""
        from .pipeline_log import get_runs

        return {
            "user_id": user_id,
            "runs": get_runs(user_id, limit=_clamp_limit(limit, PIPELINE_RUNS_MAX)),
        }

    def admin_judge_stats(user_id: str) -> AdminEndpointResult:
        """Return per-user judge acceptance stats."""
        from .judge_log import get_acceptance_stats

        return get_acceptance_stats(user_id=user_id)

    def admin_translate_history(
        user_id: str,
        limit: int = 50,
        q: str | None = None,
        op: str | None = None,
    ) -> AdminEndpointResult:
        """Return translate/explain call history for a user, with optional search/filter.

        Query params:
          - ``q``: case-insensitive substring filter over word/context.
          - ``op``: exact operation filter (``translate_quick`` /
            ``translate_phrase`` / ``translate_explain``).
        """
        from .translate_log import get_log

        return {
            "user_id": user_id,
            "history": get_log(user_id, limit=_clamp_limit(limit, TRANSLATE_HISTORY_MAX), q=q, op=op),
            "q": q or "",
            "op": op or "",
        }

    def admin_user_activity(user_id: str, hours: int = 24) -> AdminEndpointResult:
        """Return merged recent-activity timeline (translate + pipeline + judge)."""
        from .admin_user_activity import get_user_activity

        return get_user_activity(user_id, hours=hours)

    def admin_user_usage(user_id: str, range: str = "24h") -> AdminEndpointResult:
        """Return per-type usage breakdown for a user, filtered by time range."""
        from .admin_handlers import admin_user_usage_response

        return admin_user_usage_response(user_id, range_=range)

    def admin_user_cost_summary(user_id: str, range: str = "month") -> AdminEndpointResult:
        """Return per-service / per-model AI cost summary for a user.

        ``range`` accepts ``24h`` / ``7d`` / ``30d`` / ``month`` (default,
        current calendar month UTC) / ``all``.
        """
        from .admin_cost_summary import get_user_cost_summary

        try:
            return get_user_cost_summary(user_id, range_=range)
        except ValueError as exc:
            raise HTTPException(
                status_code=400,
                detail="Invalid range. Expected one of 24h/7d/30d/month/all",
            ) from exc

    def admin_host_metrics() -> AdminEndpointResult:
        """Return real-time host metrics for admin dashboard."""
        return admin_host_metrics_response()

    def admin_users_search(q: str = "", limit: int = 50) -> AdminEndpointResult:
        """Search users by uid prefix / email substring / display name substring."""
        from .admin_users_search import search_users

        return search_users(load_users_fn(), q=q, limit=limit)

    def admin_observability() -> AdminEndpointResult:
        """Return site-wide aggregated observability metrics (24h / 7d)."""
        from .admin_observability import collect_observability

        return collect_observability()

    def admin_stats_trends(days: int = 30) -> AdminEndpointResult:
        """Return site-wide 30-day error/token/DAU trend buckets."""
        from .admin_trends import collect_trends

        return collect_trends(window_days=days)

    async def admin_log_retention_run() -> AdminEndpointResult:
        """Manually trigger log-retention pruners across all 4 log DBs.

        Response shape merges the nested per-DB report with flat
        ``{pipeline,judge,translate,token}_deleted`` aliases for downstream
        consumers (cron-style monitors / dashboards) that prefer a flat map.
        """
        from .log_retention import run_all

        report = await run_in_threadpool(run_all)
        return {
            **report,
            "pipeline_deleted": report["pipeline_log"]["deleted"],
            "judge_deleted": report["judge_log"]["deleted"],
            "translate_deleted": report["translate_log"]["deleted"],
            "translate_cache_hits_deleted": report["translate_cache_hits"]["deleted"],
            "token_deleted": report["token_usage"]["deleted"],
        }

    def admin_audit(since: str | None = None, limit: int = 100, action: str | None = None) -> AdminEndpointResult:
        """Return recent admin mutation audit log entries.

        Optional ``action`` query param filters to an exact action
        (e.g. ``grant_pro`` / ``revoke_pro``); omitted returns all.
        """
        return admin_audit_response(since=since, limit=limit, action=action)

    def admin_user_detail_ui(admin_session: str | None = None) -> HTMLResponse:
        """User detail page UI."""
        return admin_ui_response(
            admin_html=ADMIN_USER_DETAIL_HTML,
            admin_token=runtime_settings_fn().admin_token,
            cookie_token=admin_session,
        )

    async def admin_orphans_scan() -> AdminEndpointResult:
        """Return a read-only data-consistency scan report.

        ``orphan_scan.scan`` is synchronous + heavy I/O (walks every users/<uid>
        directory, opens 5 SQLite databases, parses ``graph_*.json``). Running
        it directly on the FastAPI event loop blocks every other request for
        the duration of the scan, so we hand it off to a worker thread via
        ``run_in_threadpool``.
        """
        from starlette.concurrency import run_in_threadpool

        from .orphan_scan import scan

        return await run_in_threadpool(scan, data_dir=runtime_settings_fn().data_dir)

    return AdminHandlers(
        admin_ui=admin_ui,
        admin_stats=admin_stats,
        admin_logs=admin_logs,
        admin_user_entitlement=admin_user_entitlement,
        admin_grant_pro_access=admin_grant_pro_access,
        admin_revoke_pro_access=admin_revoke_pro_access,
        admin_run_tests=admin_run_tests,
        admin_last_test_run=admin_last_test_run,
        admin_test_catalog=admin_test_catalog,
        admin_tests_ui=admin_tests_ui,
        admin_graph_density=admin_graph_density,
        admin_graph_playback=admin_graph_playback,
        admin_pipeline_runs=admin_pipeline_runs,
        admin_judge_stats=admin_judge_stats,
        admin_translate_history=admin_translate_history,
        admin_user_activity=admin_user_activity,
        admin_user_usage=admin_user_usage,
        admin_user_cost_summary=admin_user_cost_summary,
        admin_host_metrics=admin_host_metrics,
        admin_users_search=admin_users_search,
        admin_observability=admin_observability,
        admin_stats_trends=admin_stats_trends,
        admin_log_retention_run=admin_log_retention_run,
        admin_audit=admin_audit,
        admin_user_detail_ui=admin_user_detail_ui,
        admin_orphans_scan=admin_orphans_scan,
    )
