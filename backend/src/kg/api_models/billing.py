from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from pydantic import AliasChoices, BaseModel, Field, field_validator


class SubscriptionStatusResponse(BaseModel):
    is_active: bool
    product_id: str | None = None
    plan_name: str | None = None
    price_display: str | None = None
    status: str
    is_trial: bool = False
    trial_days: int | None = None
    will_renew: bool = False
    expires_at: str | None = None
    source: str = "app_store"
    last_synced_at: str | None = None


class EntitlementsResponse(BaseModel):
    pro: SubscriptionStatusResponse


class AdminGrantStatusResponse(BaseModel):
    is_active: bool
    status: str
    plan_name: str | None = None
    source: str = "admin"
    expires_at: str | None = None
    granted_at: str | None = None
    granted_by: str | None = None
    reason: str | None = None
    last_synced_at: str | None = None


class AdminGrantRequest(BaseModel):
    reason: str | None = None
    expires_at: str | None = None
    granted_by: str | None = None

    @field_validator("expires_at")
    @classmethod
    def _normalize_expires_at(cls, value: str | None) -> str | None:
        # An unparseable value would otherwise be stored verbatim and never
        # expire (admin_grant_is_active treats it as "no expiry").
        if value is None or not value.strip():
            return None
        try:
            parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        except ValueError as exc:
            raise ValueError("expires_at must be an ISO-8601 datetime") from exc
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed.astimezone(UTC).isoformat()


class AdminUserEntitlementResponse(BaseModel):
    user_id: str
    pro: SubscriptionStatusResponse
    admin_grant: AdminGrantStatusResponse


class AppStoreSyncRequest(BaseModel):
    product_id: str = Field(min_length=1)
    transaction_id: str | None = None
    original_transaction_id: str | None = None
    environment: str = "sandbox"
    status: str = "active"
    is_trial: bool = False
    expires_at: str | None = None
    will_renew: bool = True
    price_display: str | None = None
    signed_transaction_info: str | None = None


class AppStoreNotificationRequest(BaseModel):
    notification_type: str | None = None
    subtype: str | None = None
    product_id: str | None = None
    transaction_id: str | None = None
    original_transaction_id: str | None = None
    environment: str = "production"
    status: str | None = None
    is_trial: bool = False
    expires_at: str | None = None
    will_renew: bool | None = None
    # Apple posts {"signedPayload": "<JWS>"}; internal callers and existing tests use snake_case.
    signed_payload: str | None = Field(
        default=None,
        validation_alias=AliasChoices("signedPayload", "signed_payload"),
    )
    raw_payload: dict[str, Any] | None = None


class AppStoreReconcileRequest(BaseModel):
    transaction_id: str = Field(min_length=1)
    environment: str = "production"


class AppStoreNotificationResponse(BaseModel):
    status: str
    updated: bool
    reason: str | None = None
    user_id: str | None = None
    entitlements: dict[str, Any] | None = None


class QuotaResponse(BaseModel):
    fraction: float = Field(ge=0, le=1)
    reset_seconds: int = Field(ge=0)
