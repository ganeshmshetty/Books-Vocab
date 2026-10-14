"""Admin test-matrix handlers — run pytest matrix, fetch results, render UI."""

from __future__ import annotations

from typing import Any, Protocol

from fastapi.responses import HTMLResponse

from .auth import _set_admin_cookie, _verified_cookie_nonce


class RunPytestMatrix(Protocol):
    def __call__(self, *, selected_items: list[str] | None = None) -> dict[str, Any]: ...


class StoreLastTestRun(Protocol):
    def __call__(self, result: dict[str, Any]) -> dict[str, Any]: ...


class GetLastTestRun(Protocol):
    def __call__(self) -> dict[str, Any] | None: ...


class BuildTestCatalog(Protocol):
    def __call__(self) -> dict[str, Any]: ...


def admin_run_tests_response(
    *,
    req: Any,
    run_pytest_matrix: RunPytestMatrix,
    store_last_test_run: StoreLastTestRun,
) -> dict[str, Any]:
    selected = req.itemIds if req else []
    return store_last_test_run(run_pytest_matrix(selected_items=selected))


def admin_last_test_run_response(
    *,
    get_last_test_run: GetLastTestRun,
) -> dict[str, Any]:
    last_run = get_last_test_run()
    if last_run is None:
        return {"status": "idle"}
    return last_run


def admin_test_catalog_response(
    *,
    build_test_catalog: BuildTestCatalog,
) -> dict[str, Any]:
    return build_test_catalog()


def admin_tests_ui_response(
    *,
    admin_token: str,
    admin_tests_html: str,
    cookie_token: str | None = None,
) -> HTMLResponse:
    return _set_admin_cookie(
        HTMLResponse(admin_tests_html),
        admin_token,
        nonce_hex=_verified_cookie_nonce(cookie_token, admin_token),
    )
