"""#2085: ``async def`` routes must keep blocking work off the event loop.

Production runs a single uvicorn worker, so one synchronous store, SQLite,
``pipeline_log`` or LLM call made directly inside an ``async def`` route
freezes every in-flight request. In a guarded module an ``async def`` route may
only:

- call a callable that the module's allowlist names as loop-safe (pure
  in-memory work), and
- ``await`` coroutines: the offload primitives ``run_in_threadpool`` /
  ``asyncio.to_thread`` and async admission such as ``_admit_external``.

Arguments of an awaited call are still evaluated on the loop, so they are
checked too. A nested function or lambda body runs wherever it is later
called, so only its decorators and defaults are checked. Any other call,
including one whose target cannot be named statically, is a violation.

A module joins the guard with one ``GUARDED_ROUTE_MODULES`` entry.
"""

from __future__ import annotations

import ast
from collections.abc import Iterator
from pathlib import Path
from textwrap import dedent

import pytest

_KG_SRC = Path(__file__).resolve().parents[1] / "src" / "kg"
_ROUTE_DECORATORS = frozenset({"get", "post", "put", "patch", "delete", "head", "options", "api_route"})

# Module path under ``backend/src/kg`` -> callables an async route may call directly on the loop.
GUARDED_ROUTE_MODULES: dict[str, frozenset[str]] = {
    # `_require_pro` only reads the in-memory user record, and it must reject
    # before `_admit_external` spends the caller's rate-limit budget.
    "routers/external_api.py": frozenset({"_require_pro"}),
    # #3829: quota gates take token_tracker._lock, so they must be offloaded;
    # `_apply_quota_headers` only sets response headers from an in-memory dict.
    "routers/translate.py": frozenset({"_apply_quota_headers"}),
}


def _dotted_name(node: ast.expr) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        owner = _dotted_name(node.value)
        return f"{owner}.{node.attr}" if owner is not None else None
    return None


def _async_routes(source: str) -> list[ast.AsyncFunctionDef]:
    """Top-level ``async def`` functions decorated with ``@<router>.<http method>(...)``."""
    return [
        node
        for node in ast.parse(source).body
        if isinstance(node, ast.AsyncFunctionDef)
        and any(
            isinstance(decorator, ast.Call)
            and isinstance(decorator.func, ast.Attribute)
            and decorator.func.attr in _ROUTE_DECORATORS
            for decorator in node.decorator_list
        )
    ]


def _calls_on_the_loop(func: ast.AsyncFunctionDef) -> Iterator[ast.Call]:
    """Yield the calls ``func`` evaluates on the event loop without awaiting them."""
    awaited: set[int] = set()
    pending: list[ast.AST] = list(func.body)
    while pending:
        node = pending.pop()
        if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef | ast.Lambda):
            pending.extend(node.args.defaults)
            pending.extend(default for default in node.args.kw_defaults if default is not None)
            pending.extend(getattr(node, "decorator_list", []))
            continue
        if isinstance(node, ast.Await) and isinstance(node.value, ast.Call):
            awaited.add(id(node.value))
        if isinstance(node, ast.Call) and id(node) not in awaited:
            yield node
        pending.extend(ast.iter_child_nodes(node))


def blocking_call_violations(source: str, loop_safe: frozenset[str], *, label: str) -> list[str]:
    violations: list[tuple[int, str]] = []
    for route in _async_routes(source):
        for call in _calls_on_the_loop(route):
            name = _dotted_name(call.func)
            if name not in loop_safe:
                target = name or ast.unparse(call.func)
                violations.append(
                    (call.lineno, f"{label}:{call.lineno} {route.name}() calls {target} on the event loop")
                )
    return [message for _, message in sorted(violations)]


@pytest.mark.parametrize("module", sorted(GUARDED_ROUTE_MODULES))
def test_async_routes_keep_blocking_calls_off_the_event_loop(module):
    source = (_KG_SRC / module).read_text(encoding="utf-8")
    loop_safe = GUARDED_ROUTE_MODULES[module]
    routes = _async_routes(source)

    # Positive control: a module with no async route would pass vacuously.
    assert routes, f"{module} has no async def route to guard"
    assert blocking_call_violations(source, loop_safe, label=module) == []
    in_use = {_dotted_name(call.func) for route in routes for call in _calls_on_the_loop(route)}
    assert loop_safe <= in_use, f"{module}: stale loop-safe allowlist entries {sorted(loop_safe - in_use)}"


_DIRECT_BLOCKING_SOURCE = dedent(
    """
    @router.get("/a")
    async def reads_store(card_id: str, response: Response, user: ExternalUser):
        _require_pro(user)
        await _admit_external(response, user, read_limiter)
        return _card_store(user["dir"]).get(card_id)

    @router.get("/b")
    async def reads_runs(response: Response, user: ExternalUser):
        runs = pipeline_log.get_runs(user["id"], limit=10)
        time.sleep(0.01)
        return runs

    @router.post("/c")
    async def evaluates_offload_argument_on_the_loop(response: Response, user: ExternalUser):
        return await run_in_threadpool(_helper, _check_quota(user, "manual_link", response))
    """
)


def test_guard_flags_blocking_calls_made_directly_in_async_routes():
    violations = blocking_call_violations(_DIRECT_BLOCKING_SOURCE, frozenset({"_require_pro"}), label="m.py")

    assert violations == [
        "m.py:6 reads_store() calls _card_store on the event loop",
        "m.py:6 reads_store() calls _card_store(user['dir']).get on the event loop",
        "m.py:10 reads_runs() calls pipeline_log.get_runs on the event loop",
        "m.py:11 reads_runs() calls time.sleep on the event loop",
        "m.py:16 evaluates_offload_argument_on_the_loop() calls _check_quota on the event loop",
    ]


_OFFLOADED_SOURCE = dedent(
    """
    @router.get("/a")
    async def offloads(card_id: str, response: Response, user: ExternalUser):
        _require_pro(user)
        await _admit_external(response, user, read_limiter)
        await asyncio.to_thread(pipeline_log.get_runs, user["id"], limit=10)
        await run_in_threadpool(lambda: _card_store(user["dir"]).get(card_id))
        return await run_in_threadpool(_helper, user, card_id=card_id)

    @router.get("/b")
    def sync_route_runs_in_the_threadpool(user: ExternalUser):
        return _card_store(user["dir"]).list_all()

    async def _not_a_route(user):
        return _card_store(user["dir"]).list_all()
    """
)


def test_guard_allows_offloaded_awaited_and_loop_safe_calls():
    assert blocking_call_violations(_OFFLOADED_SOURCE, frozenset({"_require_pro"}), label="m.py") == []


def test_guard_checks_where_nested_definitions_run_but_not_their_bodies():
    source = dedent(
        """
        @router.get("/a")
        async def defines_helpers(user: ExternalUser):
            def helper(store=_card_store(user["dir"])):
                return pipeline_log.get_runs(user["id"])

            return await run_in_threadpool(helper)
        """
    )

    assert blocking_call_violations(source, frozenset(), label="m.py") == [
        "m.py:4 defines_helpers() calls _card_store on the event loop"
    ]
