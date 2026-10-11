"""Shared ops test fixtures."""

from __future__ import annotations

from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _isolated_delivery_operation_lock(
    tmp_path_factory: pytest.TempPathFactory, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Keep tests off the real, shared delivery mutation lock.

    Production OperationLock waits up to 30s by default, then fails closed, so a
    real delivery running concurrently would otherwise turn unrelated tests red
    with "delivery mutation already in progress".  Subprocesses inherit the env var.
    The hook makes the default wait 0 (fail-fast) for every command except
    cleanup-merged, which keeps its 120s CLI default (see the SOP).
    """
    lock_dir: Path = tmp_path_factory.mktemp("delivery-locks")
    monkeypatch.setenv("KG_DELIVERY_LOCK_DIR", str(lock_dir))
    # Operators and daemons may export KG_DELIVERY_LOCK_WAIT_SECONDS (e.g. 120);
    # an inherited value would turn tests that expect an immediate busy refusal
    # into long stalls.
    monkeypatch.delenv("KG_DELIVERY_LOCK_WAIT_SECONDS", raising=False)
