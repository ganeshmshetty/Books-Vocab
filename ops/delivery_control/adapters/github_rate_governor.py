"""GitHub API quota governor for delivery reads.

Per resource (``core`` REST, ``graphql``) from the last X-RateLimit headers:
remaining >= 800 proceeds; 50 <= remaining < 800 serves the cached body;
remaining < 50 waits for the reset epoch.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum

STALE_SERVE_REMAINING = 800
QUOTA_WAIT_REMAINING = 50


class QuotaDecision(Enum):
    PROCEED = "proceed"
    SERVE_STALE = "serve-stale"
    WAIT_FOR_RESET = "wait-for-reset"


@dataclass(frozen=True)
class QuotaSnapshot:
    remaining: int
    reset_epoch: float


class QuotaGovernor:
    def __init__(self, *, now: Callable[[], float]) -> None:
        self._now = now
        self._by_resource: dict[str, QuotaSnapshot] = {}

    def observe(self, resource: str, snapshot: QuotaSnapshot) -> None:
        self._by_resource[resource] = snapshot

    def decide(self, resource: str) -> tuple[QuotaDecision, float]:
        """Return the decision and, for WAIT_FOR_RESET, the seconds to wait."""

        snapshot = self._by_resource.get(resource)
        if snapshot is None:
            return QuotaDecision.PROCEED, 0.0
        if snapshot.remaining < QUOTA_WAIT_REMAINING:
            wait = snapshot.reset_epoch - self._now()
            if wait <= 0:
                return QuotaDecision.PROCEED, 0.0
            return QuotaDecision.WAIT_FOR_RESET, wait
        if snapshot.remaining < STALE_SERVE_REMAINING:
            return QuotaDecision.SERVE_STALE, 0.0
        return QuotaDecision.PROCEED, 0.0
