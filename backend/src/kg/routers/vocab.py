from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, BackgroundTasks, Header, Query
from fastapi.responses import Response
from pydantic import BaseModel, Field, PlainValidator

from ..api_models import (
    AddLinkOperationRequest,
    AddLinkOperationResponse,
    ArchiveWordRequest,
    ArchiveWordResponse,
    BatchArchiveRequest,
    BatchArchiveResponse,
    BatchDeleteRequest,
    BatchDeleteResponse,
    CardPreferencesUpdateRequest,
    CardResponse,
    DeleteWordResponse,
    GraphLinkResponse,
    ManualLinkRequest,
    ReviewEventsPushRequest,
    ReviewEventsPushResponse,
    ReviewEventsResponse,
    ReviewStatePushRequest,
    ReviewStatePushResponse,
    VocabAddResponse,
    VocabContentUpdateRequest,
    parse_vocab_batch,
)
from ..deps import (
    CurrentUser,
    _apply_quota_headers,
    _card_store,
    _check_quota,
    _embedding_store,
    _graph_store,
    _notebook_store,
    _review_event_store,
    get_user_lock,
    logger,
)
from ..deps import _card_response as _build_card_response
from ..exceptions import BadRequestError, ConflictError, NotFoundError
from ..notebook import validate_notebook_access
from ..service_factories import create_client
from ..vocab_add_link_operation import (
    IdempotencyConflict,
    create_operation,
    find_operation,
    get_operation,
    operation_response,
    run_add_link_operation,
)
from ..vocab_handlers import (
    add_vocab_response,
    archive_word_response,
    batch_archive_response,
    batch_delete_response,
    create_manual_link_response,
    delete_graph_link_response,
    delete_word_response,
    get_graph_links_response,
    hide_graph_link_response,
    list_vocab_response,
    lookup_word_response,
    pull_review_events_response,
    push_review_events_response,
    push_review_response,
    unhide_graph_link_response,
    update_word_content_response,
    update_word_preferences_response,
)
from ..vocab_shared import _clean_content

NOTEBOOK_ID_PATTERN = r"^[A-Za-z0-9_-]{1,64}$"

router = APIRouter(tags=["vocab"])


def _card_response(card, graph, cards_by_id):
    """Pass-through; the shared builder projects per-card preferences."""
    return _build_card_response(card, graph, cards_by_id)


@router.get("/api/vocab", response_model=list[CardResponse])
def list_vocab(
    response: Response,
    user: CurrentUser,
    since: str | None = None,
    notebook_id: str | None = Query(None, pattern=NOTEBOOK_ID_PATTERN),
    limit: int = Query(5000, ge=1, le=10000),
    cursor: str | None = None,
):
    from ..pipeline_service import is_pipeline_running

    # Body stays response_model=list[CardResponse] (iOS parsing unchanged); the
    # opaque next-page cursor rides the X-Next-Cursor header (same out-of-band
    # pattern as X-Pipeline-Pending). A malformed cursor -> BadRequestError.
    result, next_cursor = list_vocab_response(
        since=since,
        user=user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        card_response_builder=_card_response,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
        limit=limit,
        cursor=cursor,
    )
    response.headers["X-Pipeline-Pending"] = "true" if is_pipeline_running(user["id"]) else "false"
    if next_cursor is not None:
        response.headers["X-Next-Cursor"] = next_cursor
    return result


@router.post(
    "/api/graph/links/ensure-target",
    response_model=AddLinkOperationResponse,
    status_code=202,
)
async def enqueue_add_link_operation(
    req: AddLinkOperationRequest,
    background_tasks: BackgroundTasks,
    user: CurrentUser,
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)],
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    normalized_key = idempotency_key.strip()
    if not normalized_key:
        raise BadRequestError("Idempotency-Key must not be blank")
    payload = req.model_dump(mode="json")
    # A replay is answered from the stored operation before any live-state
    # validation: the source may have been archived since the first admission.
    try:
        existing = find_operation(
            user_id=user["id"], notebook_id=notebook_id, idempotency_key=normalized_key, payload=payload
        )
    except IdempotencyConflict as exc:
        raise ConflictError(str(exc)) from exc
    if existing is not None:
        return operation_response(existing)
    validate_notebook_access(_notebook_store(user["dir"]), notebook_id)
    source = _card_store(user["dir"]).get(req.from_id)
    if source is None or source.is_deleted or source.is_archived or source.notebook_id != notebook_id:
        raise NotFoundError("Card", req.from_id)

    try:
        record, created = create_operation(
            user_id=user["id"],
            notebook_id=notebook_id,
            idempotency_key=normalized_key,
            payload=payload,
        )
    except IdempotencyConflict as exc:
        raise ConflictError(str(exc)) from exc
    if created:
        background_tasks.add_task(
            run_add_link_operation,
            record["operation_id"],
            user,
            card_store_factory=_card_store,
            graph_store_factory=_graph_store,
            get_user_lock_fn=get_user_lock,
            client_factory=create_client,
            logger=logger,
            notebook_store_factory=_notebook_store,
        )
    return operation_response(record)


@router.get("/api/operations/{operation_id}", response_model=AddLinkOperationResponse)
def get_add_link_operation(operation_id: str, user: CurrentUser):
    record = get_operation(user["id"], operation_id)
    if record is None:
        raise NotFoundError("Operation", operation_id)
    return operation_response(record)


# Static paths MUST be registered before {word} path parameter. The static PATCH
# routes below shadow PATCH /api/vocab/{word} for a saved word equal to their
# segment ("review", "review-events", "batch-archive"), so they forward that
# word-addressed content edit to update_word_content (#2254).

_CONTENT_EDIT_KEYS = frozenset({"meaning", "note", "explanation"})


def _forward_content_edit(static_model: type[BaseModel], required_key: str) -> PlainValidator:
    """Validate a static-route body, or a content edit for the word equal to the segment.

    Only a dict that lacks ``required_key`` and carries a content key — a body the
    static model always rejected with 422 — becomes a VocabContentUpdateRequest.
    Every other body is validated by ``static_model`` alone, in the same
    ``from_attributes`` mode FastAPI validates bodies with, so its 422 details
    (``loc`` and error type) are unchanged.
    """

    def _validate(body: Any) -> BaseModel:
        if isinstance(body, dict) and required_key not in body and not _CONTENT_EDIT_KEYS.isdisjoint(body):
            return VocabContentUpdateRequest.model_validate(body, from_attributes=True)
        return static_model.model_validate(body, from_attributes=True)

    return PlainValidator(_validate, json_schema_input_type=static_model | VocabContentUpdateRequest)


_BatchArchiveBody = Annotated[
    BatchArchiveRequest | VocabContentUpdateRequest, _forward_content_edit(BatchArchiveRequest, "words")
]
_ReviewStatePushBody = Annotated[
    ReviewStatePushRequest | VocabContentUpdateRequest, _forward_content_edit(ReviewStatePushRequest, "entries")
]
_ReviewEventsPushBody = Annotated[
    ReviewEventsPushRequest | VocabContentUpdateRequest, _forward_content_edit(ReviewEventsPushRequest, "entries")
]


@router.post("/api/vocab/batch-delete", response_model=BatchDeleteResponse)
def batch_delete(
    req: BatchDeleteRequest,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    return batch_delete_response(
        req,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        notebook_store_factory=_notebook_store,
        embedding_store_factory=_embedding_store,
        client_factory=create_client,
        notebook_id=notebook_id,
    )


@router.patch("/api/vocab/batch-archive", response_model=BatchArchiveResponse | CardResponse)
def batch_archive(
    req: _BatchArchiveBody,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    if isinstance(req, VocabContentUpdateRequest):
        return update_word_content("batch-archive", req, user, notebook_id=notebook_id)
    return batch_archive_response(
        req,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )


@router.patch("/api/vocab/review", response_model=ReviewStatePushResponse | CardResponse)
def push_review(
    req: _ReviewStatePushBody,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    if isinstance(req, VocabContentUpdateRequest):
        return update_word_content("review", req, user, notebook_id=notebook_id)
    # notebook_id 不做過濾：iOS client 推送全部 notebook 的複習狀態，
    # 後端需在全域卡片中查找匹配（query notebook_id 只用於上面的內容編輯）；staged notebook 由 handler 排除。
    return push_review_response(
        req,
        user,
        card_store_factory=_card_store,
        notebook_store_factory=_notebook_store,
        logger=logger,
        notebook_id=None,
    )


@router.get("/api/vocab/review-events", response_model=ReviewEventsResponse)
def pull_review_events(user: CurrentUser, since: str | None = None):
    return pull_review_events_response(
        since,
        user,
        review_event_store_factory=_review_event_store,
    )


@router.patch("/api/vocab/review-events", response_model=ReviewEventsPushResponse | CardResponse)
def push_review_events(
    req: _ReviewEventsPushBody,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    if isinstance(req, VocabContentUpdateRequest):
        return update_word_content("review-events", req, user, notebook_id=notebook_id)
    return push_review_events_response(
        req,
        user,
        review_event_store_factory=_review_event_store,
    )


@router.patch("/api/vocab/{word:path}/preferences", response_model=CardResponse, include_in_schema=False)
@router.patch("/api/vocab/{word}/preferences", response_model=CardResponse)
def update_word_preferences(
    word: str,
    req: CardPreferencesUpdateRequest,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    return update_word_preferences_response(
        word,
        req,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        card_response_builder=_card_response,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )


@router.patch("/api/vocab/{word:path}/archive", response_model=ArchiveWordResponse, include_in_schema=False)
@router.patch("/api/vocab/{word}/archive", response_model=ArchiveWordResponse)
def archive_word(
    word: str,
    req: ArchiveWordRequest,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    return archive_word_response(
        word,
        req,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )


@router.get("/api/vocab/{word:path}", response_model=CardResponse, include_in_schema=False)
@router.get("/api/vocab/{word}", response_model=CardResponse)
def lookup_word(
    word: str,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    return lookup_word_response(
        word,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        card_response_builder=_card_response,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )


@router.patch("/api/vocab/{word:path}", response_model=CardResponse, include_in_schema=False)
@router.patch("/api/vocab/{word}", response_model=CardResponse)
def update_word_content(
    word: str,
    req: VocabContentUpdateRequest,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    # Editorial content update (meaning / note). Distinct from
    # {word}/archive (archive toggle) and DELETE {word} (soft delete).
    return update_word_content_response(
        word,
        req,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        card_response_builder=_card_response,
        notebook_store_factory=_notebook_store,
        embedding_store_factory=_embedding_store,
        notebook_id=notebook_id,
    )


@router.delete("/api/vocab/{word:path}", response_model=DeleteWordResponse, include_in_schema=False)
@router.delete("/api/vocab/{word}", response_model=DeleteWordResponse)
def delete_word(
    word: str,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    return delete_word_response(
        word,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        notebook_store_factory=_notebook_store,
        embedding_store_factory=_embedding_store,
        client_factory=create_client,
        notebook_id=notebook_id,
    )


@router.get("/api/graph/links", response_model=list[GraphLinkResponse])
def get_graph_links(
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    return get_graph_links_response(
        user,
        graph_store_factory=_graph_store,
        card_store_factory=_card_store,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )


@router.post("/api/graph/links", response_model=GraphLinkResponse)
def create_graph_link(
    req: ManualLinkRequest,
    response: Response,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    # Manual link creation invokes ManualLinkJudge + TrackedLLM (real LLM
    # call). Gate it with the daily quota, like add_vocab / pipeline /
    # translate, so an over-quota user cannot burn unbounded LLM cost.
    quota = _check_quota(user, "manual_link", response)
    result = create_manual_link_response(
        req,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        client_factory=create_client,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )
    _apply_quota_headers(response, quota)
    return result


@router.patch("/api/graph/links/{link_id}/hide", status_code=204)
def hide_graph_link(
    link_id: str,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    hide_graph_link_response(
        link_id,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )


@router.patch("/api/graph/links/{link_id}/unhide", status_code=204)
def unhide_graph_link(
    link_id: str,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    unhide_graph_link_response(
        link_id,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )


@router.delete("/api/graph/links/{link_id}", status_code=204)
def delete_graph_link(
    link_id: str,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    delete_graph_link_response(
        link_id,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )


@router.post("/api/vocab", response_model=VocabAddResponse)
def add_vocab(
    # Cap intake batch at the schema layer (matches batch-delete/archive's
    # max_length=500) so an oversized list is rejected at request validation
    # before being deserialized — bounds LLM/DB amplification. The handler keeps
    # its own MAX_BATCH_SIZE guard as defense-in-depth.
    entries: Annotated[list[Any], Field(max_length=500)],
    response: Response,
    user: CurrentUser,
    notebook_id: str = Query("default", pattern=NOTEBOOK_ID_PATTERN),
):
    quota = _check_quota(user, "vocab_add", response)
    # Per-item validation (#2248): invalid items come back in `rejected`; valid ones proceed.
    valid_entries, rejected = parse_vocab_batch(entries, clean=_clean_content)
    if not valid_entries:
        _apply_quota_headers(response, quota)
        return VocabAddResponse(created=0, skipped=0, rejected=rejected, duplicates=[], cardIds={})
    result = add_vocab_response(
        valid_entries,
        user,
        card_store_factory=_card_store,
        embedding_store_factory=_embedding_store,
        graph_store_factory=_graph_store,
        client_factory=create_client,
        logger=logger,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )
    result.rejected = rejected
    _apply_quota_headers(response, quota)
    return result
