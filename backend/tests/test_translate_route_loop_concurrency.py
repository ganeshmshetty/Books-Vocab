"""#3829: translate quota gates must not freeze the event loop behind token_tracker._lock.

Production runs a single uvicorn worker. ``token_tracker.get_all_stats`` holds the
process-wide ``_lock`` for a full-table scan, so any translate request that takes
that lock on the event loop stalls every other request on the worker, health
checks included. This test holds the lock from a background thread while a
translate request and a health probe run concurrently on one event loop.
"""

from __future__ import annotations

import asyncio
import threading
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from kg import token_tracker, translate_log
from kg.api import app

_LOCK_HOLD_SECONDS = 1.0
_HEALTH_BUDGET_SECONDS = 0.1


def _stub_quick_llm() -> MagicMock:
    client = MagicMock()
    client.chat.completions.create = AsyncMock(
        return_value=SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content='{"t":"喚起","p":"v.","r":"evoke"}'))],
            usage=None,
        )
    )
    return client


def _hold_lock(lock, acquired: threading.Event) -> threading.Thread:
    def hold() -> None:
        with lock:
            acquired.set()
            time.sleep(_LOCK_HOLD_SECONDS)

    holder = threading.Thread(target=hold, daemon=True)
    holder.start()
    return holder


@pytest.mark.asyncio
@pytest.mark.parametrize("lock", [token_tracker._lock, translate_log._lock], ids=["token_tracker", "translate_log"])
async def test_health_stays_responsive_while_translate_waits_on_store_lock(isolated_api, lock):
    headers = isolated_api.headers
    fake = _stub_quick_llm()
    transport = httpx.ASGITransport(app=app)

    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        warm = await client.get("/api/health", headers=headers)
        assert warm.status_code == 200, warm.text

        acquired = threading.Event()
        holder = _hold_lock(lock, acquired)
        assert acquired.wait(timeout=5)
        try:
            with patch("kg.translate_handlers.create_async_client", return_value=fake):
                translate = asyncio.create_task(
                    client.post(
                        "/api/translate/quick",
                        json={"word": "evoke", "context": "The story can evoke deep memories."},
                        headers=headers,
                    )
                )
                await asyncio.sleep(0)
                started = time.perf_counter()
                health = await client.get("/api/health", headers=headers)
                elapsed = time.perf_counter() - started
                translated = await translate
        finally:
            holder.join()

    assert health.status_code == 200, health.text
    assert translated.status_code == 200, translated.text
    assert elapsed < _HEALTH_BUDGET_SECONDS, (
        f"/api/health took {elapsed:.3f}s while a translate request waited on a store lock"
    )
