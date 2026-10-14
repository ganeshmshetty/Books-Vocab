from __future__ import annotations

import math
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator
from pydantic_core import PydanticCustomError

from kg.api_models.graph import AutoLinkConfig
from kg.api_models.notebook import VocabUIConfig, reject_far_future_timestamp
from kg.api_models.review import ReviewClockConfig, ReviewModeConfig
from kg.api_models.translate import TranslationLanguageConfig

_NON_FINITE_UPDATED_AT_MARKER = "<non-finite-updated-at>"
_USER_CONFIG_GROUPS = ("translation", "review_clock", "review_mode", "vocab_ui", "auto_link")


def _is_non_finite_timestamp(value) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, (int, float)):
        return isinstance(value, float) and not math.isfinite(value)
    if isinstance(value, str):
        try:
            return not math.isfinite(float(value))
        except ValueError:
            return False
    return False


def _sanitize_non_finite_updated_at(value):
    if not isinstance(value, dict):
        return value
    sanitized = dict(value)
    for group in _USER_CONFIG_GROUPS:
        group_value = value.get(group)
        if not isinstance(group_value, dict):
            continue
        timestamp = group_value.get("updated_at")
        if _is_non_finite_timestamp(timestamp):
            sanitized[group] = {**group_value, "updated_at": _NON_FINITE_UPDATED_AT_MARKER}
    return sanitized


class AuthVerifyRequest(BaseModel):
    provider: Literal["apple", "google"]
    token: str = Field(min_length=1, max_length=10000)
    # Sign in with Apple authorization code (iOS `authorizationCode`). Exchanged for a
    # refresh token only when SIWA revocation is configured; ignored for other providers (#3815).
    authorization_code: str | None = Field(default=None, min_length=1, max_length=10000)
    # NOTE: client-supplied `email` field is intentionally accepted-and-ignored
    # (Pydantic drops unknown fields by default). Server trusts ONLY the
    # provider-token-derived email for account linkage; see C1 takeover
    # regression in tests/test_auth_takeover.py.
    email: str | None = None


class AuthVerifyResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_id: str
    expires_in: int  # seconds


class UserConfigRequest(BaseModel):
    translation: TranslationLanguageConfig | None = None
    review_clock: ReviewClockConfig | None = None
    review_mode: ReviewModeConfig | None = None
    vocab_ui: VocabUIConfig | None = None
    auto_link: AutoLinkConfig | None = None

    @model_validator(mode="before")
    @classmethod
    def sanitize_non_finite_updated_at(cls, value):
        return _sanitize_non_finite_updated_at(value)

    @field_validator(*_USER_CONFIG_GROUPS, mode="before")
    @classmethod
    def reject_non_finite_updated_at(cls, value):
        if isinstance(value, dict) and value.get("updated_at") == _NON_FINITE_UPDATED_AT_MARKER:
            raise PydanticCustomError("finite_number", "Input should be a finite number")
        return value

    @field_validator(*_USER_CONFIG_GROUPS)
    @classmethod
    def reject_far_future_updated_at(cls, value):
        if value is not None:
            reject_far_future_timestamp(value.updated_at)
        return value


class UserConfigResponse(BaseModel):
    translation: TranslationLanguageConfig | None = None
    review_clock: ReviewClockConfig | None = None
    review_mode: ReviewModeConfig | None = None
    vocab_ui: VocabUIConfig | None = None
    auto_link: AutoLinkConfig | None = None


class UserProfileResponse(BaseModel):
    """Read-only identity face (GET /api/user/profile).

    Derived from the stored user record (provider/email set at login by
    auth_service.resolve_and_link_user). Distinct from UserConfigResponse,
    which is the mutable, LWW-synced settings bundle. `displayName` prefers an
    explicit stored name, falls back to the email local-part, else null (no
    fabrication when neither is known).
    """

    displayName: str | None = None
    email: str | None = None
    provider: str | None = None


class DeleteAccountResponse(BaseModel):
    deleted_user_id: str
    linked_ids: list[str]
    deleted_dirs: list[str]
