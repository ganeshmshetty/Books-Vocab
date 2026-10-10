"""GitHub API quota governor for delivery reads.

Per resource (``core`` REST, ``graphql``) from the last X-RateLimit headers:
remaining >= 50 proceeds; remaining < 50 waits for the reset epoch.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum

QUOTA_WAIT_REMAINING = 50


class QuotaDecision(Enum):
    PROCEED = "proceed"
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
        if snapshot is None or snapshot.remaining >= QUOTA_WAIT_REMAINING:
            return QuotaDecision.PROCEED, 0.0
        wait = snapshot.reset_epoch - self._now()
        if wait <= 0:
            return QuotaDecision.PROCEED, 0.0
        return QuotaDecision.WAIT_FOR_RESET, wait
