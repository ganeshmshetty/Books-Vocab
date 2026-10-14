from __future__ import annotations

from pydantic import BaseModel, Field

from kg.api_models.common import VocabSource


class CardResponse(BaseModel):
    id: str
    content: str
    meaning: str
    pos: str | None
    difficulty: float | None
    difficultyTier: str | None
    note: str | None
    collocations: list[str] = []
    examples: list[str]
    mode: str
    isDeleted: bool
    isArchived: bool = False
    isReaderHidden: bool = False
    isReviewExcluded: bool = False
    inflections: list[str] = []
    linksByKind: dict[str, list[CardLinkSummaryResponse]] = Field(default_factory=dict)
    notebookId: str = "default"
    source: VocabSource | None = None
    updatedAt: str | None = None
    createdAt: str | None = None
    # Review state
    reviewIntervalHours: float = 12.0
    nextReviewAt: str | None = None
    lastReviewedAt: str | None = None
    reviewCount: int = 0
    lapseCount: int = 0
    reviewStreak: int = 0
    lastReviewFeedback: int = -1


class CardLinkSummaryResponse(BaseModel):
    id: str
    cardId: str
    word: str
    kind: str
    label: str
    confidence: float
    reason: str
    hidden: bool = False


CardResponse.model_rebuild()
