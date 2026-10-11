from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field, FiniteFloat, field_validator, model_validator


class ReviewStateEntry(BaseModel):
    word: str
    card_id: str | None = None  # precise matching; falls back to word if absent
    review_interval_hours: float = Field(ge=0, allow_inf_nan=False)
    next_review_at: str  # ISO8601
    last_reviewed_at: str  # ISO8601
    review_count: int = Field(ge=0, le=2_147_483_647)
    lapse_count: int = Field(ge=0, le=2_147_483_647)
    review_streak: int = Field(ge=0, le=2_147_483_647)
    last_review_feedback: int = Field(ge=-1, le=1)
    # 進度覆寫(#2042):為 True 時 review_count/lapse_count 原樣寫入(不取 max),
    # next_review_at 由 client 給定(now);即使 server 卡片較新也會套用。
    override: bool = False

    @field_validator("review_count", "lapse_count", "review_streak", mode="before")
    @classmethod
    def _reject_boolean_counter_values(cls, value: object) -> object:
        if isinstance(value, bool):
            raise ValueError("review counters must be integers")
        return value


class ReviewStatePushRequest(BaseModel):
    entries: list[ReviewStateEntry] = Field(max_length=5000)


class ReviewStatePushResponse(BaseModel):
    updated: int
    skipped: int


class ReviewEventEntry(BaseModel):
    event_id: str = Field(min_length=1)
    card_id: str | None = None
    word_snapshot: str
    notebook_id: str = "default"
    feedback: int = Field(ge=0, le=1)
    reviewed_at: str
    created_at: str
    # SRS 前後狀態快照 — 複習當下由 iOS 計算,backend 原樣鏡像(不算 SRS)。研究「每張卡
    # 學習曲線 / 遺忘規律」需逐筆事件自包含,不能只靠卡片現狀聚合反推。舊 client 不帶這些
    # 欄位仍合法(default None),新 client(Phase 5)固化後上報。
    interval_before: float | None = None
    interval_after: float | None = None
    next_review_before: str | None = None  # ISO8601
    next_review_after: str | None = None  # ISO8601
    review_count_after: int | None = None
    streak_after: int | None = None
    lapse_after: int | None = None
    # 區分「合成的過去」(一次性遷移回填)與「真實的未來」(上線後 iOS 上報),研究時可
    # WHERE 篩選互不污染。
    is_synthetic: bool = False

    @field_validator("event_id")
    @classmethod
    def validate_event_id(cls, event_id: str) -> str:
        if not event_id.strip():
            raise ValueError("event_id must not be blank")
        return event_id


class ReviewEventPushEntry(ReviewEventEntry):
    """Validated review-event input; output entries remain legacy-compatible."""

    interval_before: float | None = Field(default=None, ge=0, allow_inf_nan=False)
    interval_after: float | None = Field(default=None, ge=0, allow_inf_nan=False)
    review_count_after: int | None = Field(default=None, ge=0)
    streak_after: int | None = Field(default=None, ge=0)
    lapse_after: int | None = Field(default=None, ge=0)

    @field_validator("review_count_after", "streak_after", "lapse_after", mode="before")
    @classmethod
    def _reject_boolean_srs_counter_values(cls, value: object) -> object:
        if isinstance(value, bool):
            raise ValueError("review event SRS counters must be integers")
        return value


class ReviewEventsPushRequest(BaseModel):
    entries: list[ReviewEventPushEntry] = Field(max_length=10000)


class ReviewEventsPushResponse(BaseModel):
    inserted: int
    skipped: int


class ReviewEventsResponse(BaseModel):
    entries: list[ReviewEventEntry]
    cursor: str | None = None


class ReviewClockConfig(BaseModel):
    """Per-user 全局複習時鐘暫停態(對標 TranslationLanguageConfig 走 user config)。

    `is_paused` + `paused_at` 為**複合原子狀態**:暫停時鐘的錨點時間只在
    `is_paused=True` 時有意義。單一 `updated_at`(epoch 秒)驅動跨裝置 LWW —
    兩欄位共用一個時戳,確保整組原子收斂(不會 is_paused 與 paused_at 各自比較
    導致半套狀態)。resume(`is_paused=False`)時 `paused_at` 由 validator 正規化為
    `None`,杜絕儲存層自相矛盾;對 client 寬鬆(不 reject,只正規化)。
    """

    is_paused: bool = False
    paused_at: str | None = Field(default=None, max_length=64)  # ISO8601;僅 is_paused=True 時有意義
    updated_at: float | None = None  # LWW timestamp, epoch 秒

    @field_validator("paused_at")
    @classmethod
    def _paused_at_is_iso8601(cls, value: str | None) -> str | None:
        if value is not None:
            try:
                datetime.fromisoformat(value)
            except ValueError as exc:
                raise ValueError("paused_at must be an ISO8601 timestamp") from exc
        return value

    @model_validator(mode="after")
    def _normalize_consistency(self) -> ReviewClockConfig:
        if not self.is_paused and self.paused_at is not None:
            self.paused_at = None
        return self


class ReviewModeConfig(BaseModel):
    """Per-user 複習模式 + 自訂 SRS 參數(對標 ReviewClockConfig 走 user config)。

    `mode` + 5 個 `custom_*` 參數為**複合原子狀態**:
    custom 參數只在 mode="custom" 時生效,但即使 mode 為 relaxed/intensive 仍保存使用者
    調過的值。單一 `updated_at`
    (epoch 秒)驅動跨裝置 LWW — 整組共用一個時戳,確保收斂(不會 mode 取一邊、custom
    參數取另一邊形成半套狀態)。對 client 寬鬆:非法 mode 由 validator 正規化為
    "relaxed",custom 參數不 reject(client UI 已 bound,為 SoT;後端寬鬆存原值)。

    default 對標 iOS `ReviewSettings.default`(relaxed / 12 / 1.9 / 0.45 / 6 / 1440)。
    """

    mode: str = "relaxed"  # relaxed / intensive / custom
    custom_initial_interval_hours: FiniteFloat = 12
    custom_remembered_multiplier: FiniteFloat = 1.9
    custom_forgot_multiplier: FiniteFloat = 0.45
    custom_minimum_interval_hours: FiniteFloat = 6
    custom_maximum_interval_hours: FiniteFloat = 1440
    updated_at: float | None = None  # LWW timestamp, epoch 秒

    @model_validator(mode="after")
    def _normalize_mode(self) -> ReviewModeConfig:
        if self.mode not in ("relaxed", "intensive", "custom"):
            self.mode = "relaxed"
        return self
