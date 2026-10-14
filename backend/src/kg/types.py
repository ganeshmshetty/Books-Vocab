"""Shared type definitions for the KG backend."""

from __future__ import annotations

from pathlib import Path
from typing import Any, TypedDict


class UserRecord(TypedDict, total=False):
    """Authenticated user context returned by resolve_current_user."""

    id: str
    dir: Path
    record: dict[str, Any]
    config: dict[str, Any]


class SubscriptionRecord(TypedDict, total=False):
    """Stored App Store subscription snapshot / entitlement-bearing payload."""

    is_active: bool
    product_id: str | None
    plan_name: str
    price_display: str | None
    status: str
    is_trial: bool
    trial_days: int | None
    will_renew: bool
    expires_at: str | None
    grace_period_expires_at: str | None
    source: str
    last_synced_at: str | None
    transaction_id: str | None
    original_transaction_id: str | None
    environment: str | None
    last_signed_date: str | None
    last_notification_uuid: str | None


class AdminGrantRecord(TypedDict, total=False):
    """Stored manual Pro grant payload."""

    is_active: bool
    plan_name: str
    status: str
    source: str
    expires_at: str | None
    granted_at: str | None
    granted_by: str | None
    reason: str | None
    last_synced_at: str | None


class StoredUserRecord(TypedDict, total=False):
    """Persisted user entry in ``users.json`` (excluding reserved metadata rows)."""

    config: dict[str, Any]
    subscription: SubscriptionRecord
    admin_grant: AdminGrantRecord
    linked_ids: list[str]
    _linked_to: str
    # Sign in with Apple refresh token, kept only when SIWA revocation is configured (#3815).
    apple_refresh_token: str


type UsersPayload = dict[str, Any]
type CardsById = dict[str, Any]


class QuotaState(TypedDict):
    """Quota snapshot crossing the iOS API boundary: remaining fraction + reset window."""

    fraction: float
    reset_seconds: float


class QuotaCheck(TypedDict):
    """Pre-flight quota gate result crossing the iOS API boundary."""

    exceeded: bool
    fraction: float
    reset_seconds: float
