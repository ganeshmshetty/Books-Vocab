from __future__ import annotations

import math
import time
from typing import Final, Literal

from pydantic import BaseModel, Field, FiniteFloat, field_validator, model_validator
from pydantic_core import PydanticCustomError

NotebookReviewMode = Literal["relaxed", "intensive", "custom"]
NotebookCardLayoutPreset = Literal["standard", "compact"]
_NON_FINITE_TIMESTAMP_MARKER = "<non-finite-updated-at>"
_NON_FINITE_REVIEW_POLICY_VALUE_MARKER = "<non-finite-review-policy-value>"
_REVIEW_POLICY_NUMERIC_FIELDS = (
    "customInitialIntervalHours",
    "customRememberedMultiplier",
    "customForgotMultiplier",
    "customMinimumIntervalHours",
    "customMaximumIntervalHours",
)


MAX_FUTURE_SKEW_SECONDS: Final = 24 * 3600  # LWW updatedAt 允許的時鐘偏移上限


def reject_far_future_timestamp(value: float | None) -> float | None:
    """LWW 時戳不得超過 server now + 24h,否則單一偏移裝置會永久釘住該紀錄。"""
    if value is not None and value > time.time() + MAX_FUTURE_SKEW_SECONDS:
        raise PydanticCustomError("timestamp_too_far_future", "updatedAt is too far in the future")
    return value


def _is_non_finite_timestamp(value) -> bool:
    return (isinstance(value, float) and not math.isfinite(value)) or (
        isinstance(value, str) and value in {"NaN", "Infinity", "-Infinity"}
    )


def _sanitize_non_finite_timestamps(value):
    if isinstance(value, dict):
        return {
            key: _NON_FINITE_TIMESTAMP_MARKER
            if key == "updatedAt" and _is_non_finite_timestamp(item)
            else _NON_FINITE_REVIEW_POLICY_VALUE_MARKER
            if key in _REVIEW_POLICY_NUMERIC_FIELDS and _is_non_finite_timestamp(item)
            else _sanitize_non_finite_timestamps(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_sanitize_non_finite_timestamps(item) for item in value]
    return value


class NotebookReviewPolicy(BaseModel):
    mode: NotebookReviewMode
    customInitialIntervalHours: FiniteFloat
    customRememberedMultiplier: FiniteFloat
    customForgotMultiplier: FiniteFloat
    customMinimumIntervalHours: FiniteFloat
    customMaximumIntervalHours: FiniteFloat

    @field_validator(*_REVIEW_POLICY_NUMERIC_FIELDS, mode="before")
    @classmethod
    def reject_non_finite_values(cls, value):
        if value == _NON_FINITE_REVIEW_POLICY_VALUE_MARKER:
            raise PydanticCustomError("finite_number", "Input should be a finite number")
        return value

    @model_validator(mode="after")
    def require_ordered_custom_intervals(self):
        if self.customMinimumIntervalHours > self.customMaximumIntervalHours:
            raise ValueError("customMinimumIntervalHours must not exceed customMaximumIntervalHours")
        return self


class NotebookCardLayout(BaseModel):
    recognition: NotebookCardLayoutPreset
    production: NotebookCardLayoutPreset


class NotebookSettingsGroup[ValueT](BaseModel):
    value: ValueT | None = None
    updatedAt: float | None = None


class NotebookSettingsPatchGroup[ValueT](BaseModel):
    value: ValueT | None = None
    updatedAt: FiniteFloat

    @field_validator("updatedAt", mode="before")
    @classmethod
    def reject_non_finite_updated_at(cls, value):
        if value == _NON_FINITE_TIMESTAMP_MARKER or _is_non_finite_timestamp(value):
            raise PydanticCustomError("finite_number", "Input should be a finite number")
        return value

    @field_validator("updatedAt")
    @classmethod
    def reject_far_future_updated_at(cls, value: float) -> float:
        return reject_far_future_timestamp(value)


class NotebookSettingsResponse(BaseModel):
    reviewPolicy: NotebookSettingsGroup[NotebookReviewPolicy]
    cardLayout: NotebookSettingsGroup[NotebookCardLayout]


class NotebookSettingsPatchRequest(BaseModel):
    reviewPolicy: NotebookSettingsPatchGroup[NotebookReviewPolicy] | None = None
    cardLayout: NotebookSettingsPatchGroup[NotebookCardLayout] | None = None

    @model_validator(mode="before")
    @classmethod
    def sanitize_non_finite_updated_at(cls, value):
        return _sanitize_non_finite_timestamps(value)

    @model_validator(mode="after")
    def require_at_least_one_group(self):
        if self.reviewPolicy is None and self.cardLayout is None:
            raise ValueError("At least one notebook settings group is required")
        return self


class NotebookResponse(BaseModel):
    id: str
    name: str
    color: str | None = None
    coverPattern: str | None = None
    sortOrder: int = 0
    isDefault: bool = False
    isDeleted: bool = False
    cardCount: int = 0
    updatedAt: str | None = None
    createdAt: str | None = None
    # Provenance (v1 inert): where this notebook was copied from (Phase 2 copy).
    sourceSharedDeckId: str | None = None
    sourceVersion: int | None = None
    settings: NotebookSettingsResponse | None = None


VALID_COVER_PATTERNS: Final[frozenset[str]] = frozenset({"dots", "lines", "grid", "waves", "circles", "noise"})


def _validate_cover_pattern(v: str | None) -> str | None:
    if v is not None and v != "" and v not in VALID_COVER_PATTERNS:
        raise ValueError(f"cover_pattern must be one of {VALID_COVER_PATTERNS} or empty string to clear")
    return v


def _validate_non_blank_name(value: str | None) -> str | None:
    if value is not None and not value.strip():
        raise ValueError("name must contain at least one non-whitespace character")
    return value


class NotebookCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    color: str | None = Field(default=None, max_length=20, pattern=r"^#[0-9a-fA-F]{6}$")
    cover_pattern: str | None = Field(default=None, max_length=30)

    _validate_name = field_validator("name")(staticmethod(_validate_non_blank_name))
    _validate_cover_pattern = field_validator("cover_pattern")(staticmethod(_validate_cover_pattern))


class NotebookUpdateRequest(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    color: str | None = Field(default=None, max_length=20, pattern=r"^#[0-9a-fA-F]{6}$")
    sort_order: int | None = Field(default=None, ge=-(2**31), le=2**31 - 1)
    cover_pattern: str | None = Field(default=None, max_length=30)

    _validate_name = field_validator("name")(staticmethod(_validate_non_blank_name))
    _validate_cover_pattern = field_validator("cover_pattern")(staticmethod(_validate_cover_pattern))


class VocabUIConfig(BaseModel):
    """Per-user vocab UI 跨裝置偏好 group(走 user config /api/user/config,對齊
    architecture.md User config contract 的 `vocab_ui` domain;屬 ReviewClockConfig /
    ReviewModeConfig 的 LWW 家族,用 snake_case wire 而非本檔 notebook CRUD 的 camelCase)。

    目前僅 `active_notebook_id` = 決定新選詞預設歸進哪一本的全域游標;預留未來
    notebook filter / sort 等 vocab UI 偏好(architecture.md:60)。per-book
    `preferredNotebookId` 走 CloudKit,不在此。單一 `updated_at`(epoch 秒)驅動整組
    跨裝置 LWW。

    對 client 寬鬆:id 指向已刪 notebook 的 stale 清理由各 client 自理(iOS
    NotebookListCoordinator / chrome reconcile 皆已有),後端此階段 passthrough 不驗
    存在性,與現有 translation / review_* group 一致;architecture.md:89 規劃的
    「server 拒絕已刪 notebook」+ stale-write gate 歸入後續 server-LWW 真化階段統一
    處理(屆時涵蓋全部 group,不單獨特殊化 vocab_ui)。default "default" 對齊 iOS
    `Book.resolvedNotebookId` fallback 與 chrome 預設本。
    """

    active_notebook_id: str = Field(default="default", pattern=r"^[A-Za-z0-9_-]{1,64}$")
    updated_at: float | None = None  # LWW timestamp, epoch 秒
