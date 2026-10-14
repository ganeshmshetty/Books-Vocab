"""Admin request handlers package.

Split from the former monolithic ``kg.admin_handlers`` module into
responsibility-scoped submodules:

- ``auth`` — cookie signing/verification, ``require_admin``, login pages, UI responses, logout
- ``session_store`` — revocation ledger for logged-out admin session nonces
- ``stats`` — user stats, host metrics, usage ranges, log retrieval
- ``test_matrix`` — pytest-matrix run/result/catalog handlers
- ``entitlements`` — Pro grant/revoke, entitlement lookup, audit log

All public names are re-exported here (and via the ``kg.admin_handlers``
shim) so existing imports keep working unchanged.
"""

from __future__ import annotations

from .auth import (
    ADMIN_COOKIE_NAME,
    ADMIN_COOKIE_TTL_SECONDS,
    ADMIN_LOGIN_HTML,
    _build_cookie_value,
    _resolve_admin_token,
    _set_admin_cookie,
    _sign_cookie,
    _sign_payload,
    _verify_cookie,
    admin_actor_fingerprint,
    admin_login_page,
    admin_login_post,
    admin_logout_response,
    admin_ui_response,
    check_admin_auth,
    require_admin,
)
from .entitlements import (
    _mutate_admin_grant,
    admin_audit_response,
    admin_grant_pro_access_response,
    admin_revoke_pro_access_response,
    admin_user_entitlement_response,
)
from .stats import (
    admin_host_metrics_response,
    admin_logs_response,
    admin_stats_response,
    admin_user_usage_response,
)
from .test_matrix import (
    admin_last_test_run_response,
    admin_run_tests_response,
    admin_test_catalog_response,
    admin_tests_ui_response,
)

__all__ = [
    "ADMIN_COOKIE_NAME",
    "ADMIN_COOKIE_TTL_SECONDS",
    "ADMIN_LOGIN_HTML",
    "_build_cookie_value",
    "_mutate_admin_grant",
    "_resolve_admin_token",
    "_set_admin_cookie",
    "_sign_cookie",
    "_sign_payload",
    "_verify_cookie",
    "admin_actor_fingerprint",
    "admin_audit_response",
    "admin_grant_pro_access_response",
    "admin_host_metrics_response",
    "admin_last_test_run_response",
    "admin_login_page",
    "admin_login_post",
    "admin_logout_response",
    "admin_logs_response",
    "admin_revoke_pro_access_response",
    "admin_run_tests_response",
    "admin_stats_response",
    "admin_test_catalog_response",
    "admin_tests_ui_response",
    "admin_ui_response",
    "admin_user_entitlement_response",
    "admin_user_usage_response",
    "check_admin_auth",
    "require_admin",
]
