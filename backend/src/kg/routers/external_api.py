"""Versioned Pro-only external API for card capture and enrichment.

Routes are ``async def`` only because rate-limit admission (``_admit_external``)
awaits an ``asyncio.Lock``. Everything after admission touches stores, SQLite,
``pipeline_log`` or the LLM, so each route hands it to a sync helper through
``run_in_threadpool``; ``tests/test_async_route_blocking_guard.py`` enforces this.
"""

from __future__ import annotations

import sqlite3
import threading
import time
import uuid
from collections import OrderedDict
from collections.abc import Callable
from copy import copy
from typing import Annotated, Any

from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, Query, Request, Response
from sqlalchemy.exc import OperationalError
from starlette.concurrency import run_in_threadpool

from ..api_models.cards import CardResponse
from ..api_models.external_api import (
    ExternalApiKeyCreateRequest,
    ExternalApiKeyResponse,
    ExternalCardArchiveRequest,
    ExternalCardBatchRequest,
    ExternalCardBatchResponse,
    ExternalCardCreateRequest,
    ExternalCardDeleteResponse,
    ExternalCardIngestResponse,
    ExternalCardListResponse,
    ExternalCardReviewRequest,
    ExternalCardUpdateRequest,
    ExternalEnrichRequest,
    ExternalLinkListResponse,
    ExternalManualLinkRequest,
    ExternalOperationListResponse,
    ExternalOperationResponse,
)
from ..api_models.graph import GraphLinkResponse, ManualLinkRequest
from ..api_models.notebook import NotebookCreateRequest, NotebookResponse, NotebookUpdateRequest
from ..api_models.review import ReviewStateEntry, ReviewStatePushRequest
from ..api_models.vocab import ArchiveWordRequest
from ..app_middleware import _anon_rate_limit_key
from ..deps import (
    CurrentUser,
    _apply_quota_headers,
    _card_response,
    _card_store,
    _check_quota,
    _embedding_store,
    _graph_store,
    _is_pro,
    _notebook_store,
    get_user_lock,
    logger,
)
from ..exceptions import BadRequestError, ForbiddenError, NotFoundError, ValidationError
from ..external_api_keys import (
    authenticate_api_key,
    issue_api_key,
    list_api_keys,
    revoke_api_key,
)
from ..external_api_rate_limit import (
    auth_failure_limiter,
    enrich_limiter,
    read_limiter,
    user_enrich_limiter,
    user_write_limiter,
    write_limiter,
)
from ..graph import LinkKind
from ..notebook import validate_notebook_access
from ..pipeline_service import run_pipeline_background as _run_pipeline_bg
from ..sentry_init import capture_handled
from ..service_factories import create_client
from ..types import UserRecord
from ..vocab_crud import evict_card_embedding, reembed_after_meaning_edit
from ..vocab_graph_ops import link_peer_ids, touch_peers
from ..vocab_handlers import (
    archive_word_response,
    create_manual_link_response,
    delete_graph_link_response,
    get_graph_links_response,
    hide_graph_link_response,
    list_vocab_response,
    push_review_response,
    unhide_graph_link_response,
)
from ..vocab_shared import _clean_content, _normalize_pos
from .notebook import (
    create_notebook as _create_notebook,
)
from .notebook import (
    delete_notebook as _delete_notebook,
)
from .notebook import (
    list_notebooks as _list_notebooks,
)
from .notebook import (
    update_notebook as _update_notebook,
)

router = APIRouter(tags=["external-v1"])


_OPERATIONS: dict[str, dict[str, str]] = {}
_OPERATIONS_LOCK = threading.Lock()
_MAX_REMEMBERED_OPERATIONS = 10_000
_BATCH_WRITE_MAX_ATTEMPTS = 3
_CARD_WRITE_LOCKS: OrderedDict[str, threading.Lock] = OrderedDict()
_CARD_WRITE_LOCKS_MUTEX = threading.Lock()
_MAX_CARD_WRITE_LOCKS = 500


def _external_card_write_lock(user: UserRecord) -> threading.Lock:
    """Return the bounded per-user lock for single-card creation."""
    key = str(user["dir"].resolve())
    with _CARD_WRITE_LOCKS_MUTEX:
        lock = _CARD_WRITE_LOCKS.get(key)
        if lock is None:
            lock = threading.Lock()
            while len(_CARD_WRITE_LOCKS) >= _MAX_CARD_WRITE_LOCKS:
                for candidate_key, candidate_lock in _CARD_WRITE_LOCKS.items():
                    if not candidate_lock.locked():
                        del _CARD_WRITE_LOCKS[candidate_key]
                        break
                else:
                    # Do not evict a held/queued lock and risk creating a second
                    # lock for the same user; a short-lived cap overrun is safe.
                    break
            _CARD_WRITE_LOCKS[key] = lock
        else:
            _CARD_WRITE_LOCKS.move_to_end(key)
        return lock


def _is_retryable_sqlite_lock(exc: OperationalError) -> bool:
    error_code = getattr(exc.orig, "sqlite_errorcode", None)
    return isinstance(error_code, int) and error_code & 0xFF in {
        sqlite3.SQLITE_BUSY,
        sqlite3.SQLITE_LOCKED,
    }


def _remember_operation(operation_id: str, user_id: str, notebook_id: str) -> None:
    with _OPERATIONS_LOCK:
        _OPERATIONS[operation_id] = {
            "user_id": user_id,
            "notebook_id": notebook_id,
            "status": "queued",
        }
        while len(_OPERATIONS) > _MAX_REMEMBERED_OPERATIONS:
            _OPERATIONS.pop(next(iter(_OPERATIONS)))


def _mark_operation_failed(operation_id: str) -> None:
    with _OPERATIONS_LOCK:
        record = _OPERATIONS.get(operation_id)
        if record is not None:
            record["status"] = "failed"


def _operation_owner(operation_id: str) -> dict[str, str] | None:
    with _OPERATIONS_LOCK:
        record = _OPERATIONS.get(operation_id)
        return dict(record) if record is not None else None


def _persisted_operation(operation_id: str, user_id: str) -> dict[str, Any] | None:
    """Find an operation in durable telemetry after process-local state is lost."""
    from .. import pipeline_log

    return pipeline_log.get_run(operation_id, user_id)


async def get_external_api_user(
    request: Request,
    api_key: str | None = Header(default=None, alias="X-KG-API-Key"),
) -> UserRecord:
    # /api/v1 is exempt from the generic IP limiter, so failed key
    # authentications are throttled here, per client IP (#2803).
    settings = request.app.state.kg_settings
    client_host = request.client.host if request.client else None
    client_key = "ip:" + _anon_rate_limit_key(
        request.headers.get("x-forwarded-for", ""), client_host, settings.rate_limit_trusted_hops
    )
    if await auth_failure_limiter.is_exhausted(client_key):
        raise HTTPException(status_code=429, detail="Too many invalid external API keys", headers={"Retry-After": "60"})
    resolved = await run_in_threadpool(authenticate_api_key, api_key, load_users=request.app.state.load_users)
    if resolved is None:
        decision = await auth_failure_limiter.admit(client_key)
        if not decision.allowed:
            raise HTTPException(status_code=429, detail="Too many invalid external API keys", headers=decision.headers)
        raise HTTPException(
            status_code=401,
            detail="Invalid external API key",
            headers={"WWW-Authenticate": "ApiKey"},
        )

    key_id, user_id, record = resolved

    user_dir = settings.data_dir / "users" / user_id
    return {
        "id": user_id,
        "dir": user_dir,
        "record": record,
        "config": record.get("config", {}) if isinstance(record.get("config"), dict) else {},
        "external_api_key_id": key_id,
    }


ExternalUser = Annotated[UserRecord, Depends(get_external_api_user)]


def _require_pro(user: UserRecord) -> None:
    if not _is_pro(user):
        raise ForbiddenError("Pro plan required for the external API")


async def _admit_external(
    response: Response,
    user: UserRecord,
    limiter: Any,
) -> None:
    key_id = user.get("external_api_key_id")
    if not isinstance(key_id, str):
        raise HTTPException(status_code=401, detail="Invalid external API key")
    decision = await limiter.admit(key_id)
    headers = decision.headers
    if not decision.allowed:
        raise HTTPException(status_code=429, detail="External API rate limit exceeded", headers=headers)
    # Writes and enrich also share a per-user budget so minting fresh keys
    # cannot reset it (#2805).
    user_limiter = (
        user_write_limiter if limiter is write_limiter else user_enrich_limiter if limiter is enrich_limiter else None
    )
    if user_limiter is not None:
        user_decision = await user_limiter.admit(f"user:{user['id']}")
        if not user_decision.allowed:
            raise HTTPException(
                status_code=429, detail="External API rate limit exceeded", headers=user_decision.headers
            )
    for name, value in headers.items():
        response.headers[name] = value


def _validate_notebook(user: UserRecord, notebook_id: str) -> None:
    validate_notebook_access(_notebook_store(user["dir"]), notebook_id)


def _card_or_404(user: UserRecord, card_id: str, notebook_id: str):
    card = _card_store(user["dir"]).get(card_id)
    if not card or card.is_deleted or card.notebook_id != notebook_id:
        raise NotFoundError("Card", card_id)
    return card


def _render_card(
    user: UserRecord,
    card: Any,
    notebook_id: str,
    *,
    cards: Any | None = None,
) -> CardResponse:
    cards = cards or _card_store(user["dir"])
    graph = _graph_store(user["dir"], notebook_id=notebook_id)
    cards_by_id: dict[str, Any] = {card.id: card}
    for link in graph.get_links_for(card.id):
        other_id = link.to_id if link.from_id == card.id else link.from_id
        other = cards.get(other_id)
        if other is not None:
            cards_by_id[other.id] = other
    return _card_response(card, graph, cards_by_id)


def _ingest_card(
    user: UserRecord,
    req: ExternalCardCreateRequest,
    *,
    cards: Any | None = None,
    write_lock: threading.Lock | None = None,
) -> tuple[CardResponse, bool]:
    _validate_notebook(user, req.notebookId)
    content = _clean_content(req.content)
    if not content:
        raise ValidationError("content must contain a word or phrase")

    cards = cards or _card_store(user["dir"])
    existing = cards.find_by_content(content, notebook_id=req.notebookId)
    if existing is not None:
        return _render_card(user, existing, req.notebookId, cards=cards), False

    examples = list(req.examples)
    if req.context and not examples:
        examples = [req.context]
    source = req.source.model_dump_json() if req.source is not None else None
    if write_lock is None:
        card = cards.add(
            content=content,
            meaning=req.meaning.strip(),
            pos=_normalize_pos(req.pos),
            examples=examples,
            collocations=list(req.collocations),
            mode=req.mode,
            notebook_id=req.notebookId,
            source=source,
        )
    else:
        with write_lock:
            existing = cards.find_by_content(content, notebook_id=req.notebookId)
            if existing is not None:
                return _render_card(user, existing, req.notebookId, cards=cards), False
            card = cards.add(
                content=content,
                meaning=req.meaning.strip(),
                pos=_normalize_pos(req.pos),
                examples=examples,
                collocations=list(req.collocations),
                mode=req.mode,
                notebook_id=req.notebookId,
                source=source,
            )
    if req.note is not None:
        card = cards.update(card.id, note=req.note or None) or card
    return _render_card(user, card, req.notebookId, cards=cards), True


@router.get("/api/v1/notebooks", response_model=list[NotebookResponse])
async def list_external_notebooks(response: Response, user: ExternalUser, since: str | None = None):
    _require_pro(user)
    await _admit_external(response, user, read_limiter)
    return await run_in_threadpool(_list_notebooks, user, since=since)


@router.post("/api/v1/notebooks", response_model=NotebookResponse, status_code=201)
async def create_external_notebook(req: NotebookCreateRequest, response: Response, user: ExternalUser):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    return await run_in_threadpool(_create_notebook, req, user)


@router.patch("/api/v1/notebooks/{notebook_id}", response_model=NotebookResponse)
async def update_external_notebook(
    notebook_id: str,
    req: NotebookUpdateRequest,
    response: Response,
    user: ExternalUser,
):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    return await run_in_threadpool(_update_notebook, notebook_id, req, user)


@router.delete("/api/v1/notebooks/{notebook_id}")
async def delete_external_notebook(notebook_id: str, response: Response, user: ExternalUser):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    return await run_in_threadpool(_delete_notebook, notebook_id, user)


def _operation_from_run(run: dict[str, Any]) -> ExternalOperationResponse:
    raw_status = run.get("status")
    status = {
        "completed": "succeeded",
        "running": "running",
        "quota_exhausted": "quota_exhausted",
        "failed": "failed",
        "interrupted": "interrupted",
    }.get(raw_status, "unknown")
    return ExternalOperationResponse(
        operationId=run["run_id"],
        status=status,
        notebookId=run.get("notebook_id", "default"),
        startedAt=run.get("started_at"),
        endedAt=run.get("ended_at"),
        durationSeconds=run.get("duration_s"),
        steps=run.get("steps") or [],
    )


def _queued_operation(operation_id: str, record: dict[str, str]) -> ExternalOperationResponse:
    return ExternalOperationResponse(
        operationId=operation_id,
        status=record.get("status", "queued"),
        notebookId=record["notebook_id"],
    )


async def _run_external_pipeline(
    user: UserRecord,
    operation_id: str,
    *,
    force: bool,
    notebook_id: str,
) -> None:
    try:
        await _run_pipeline_bg(
            user,
            get_user_lock_fn=get_user_lock,
            card_store_factory=_card_store,
            graph_store_factory=_graph_store,
            embedding_store_factory=_embedding_store,
            client_factory=create_client,
            logger=logger,
            link_kind_enum=LinkKind,
            force_enrich=force,
            notebook_id=notebook_id,
            run_id=operation_id,
            telemetry_started=True,
        )
    except Exception as exc:
        logger.exception("External enrich operation failed before pipeline telemetry: %s", operation_id)
        capture_handled(exc, context="external_api.enrich_operation")
        _mark_operation_failed(operation_id)
        try:
            from .. import pipeline_log

            pipeline_log.end_run(operation_id, "failed")
        except Exception as close_exc:
            logger.warning("Failed to close external operation telemetry: %s", operation_id, exc_info=True)
            capture_handled(close_exc, context="external_api.operation_telemetry_close")


@router.post("/api/v1/api-keys", response_model=ExternalApiKeyResponse, status_code=201)
def create_external_api_key(req: ExternalApiKeyCreateRequest, request: Request, user: CurrentUser):
    _require_pro(user)
    settings = request.app.state.kg_settings
    try:
        return issue_api_key(
            user["id"],
            label=req.label,
            users_lock_file=settings.users_lock_file,
            load_users=request.app.state.load_users,
            save_users=request.app.state.save_users,
        )
    except ValueError as exc:
        raise ForbiddenError(str(exc)) from exc


@router.get(
    "/api/v1/api-keys",
    response_model=list[ExternalApiKeyResponse],
    response_model_exclude_none=True,
)
def get_external_api_keys(request: Request, user: CurrentUser):
    _require_pro(user)
    return list_api_keys(user["id"], load_users=request.app.state.load_users)


@router.delete(
    "/api/v1/api-keys/{key_id}",
    response_model=ExternalApiKeyResponse,
    response_model_exclude_none=True,
)
def delete_external_api_key(key_id: str, request: Request, user: CurrentUser):
    settings = request.app.state.kg_settings
    record = revoke_api_key(
        user["id"],
        key_id,
        users_lock_file=settings.users_lock_file,
        load_users=request.app.state.load_users,
        save_users=request.app.state.save_users,
    )
    if record is None:
        raise NotFoundError("API key", key_id)
    return record


def _ingest_card_batch(req: ExternalCardBatchRequest, user: UserRecord) -> ExternalCardBatchResponse:
    cards = _card_store(user["dir"])
    for attempt in range(_BATCH_WRITE_MAX_ATTEMPTS):
        items: list[ExternalCardIngestResponse] = []
        created = 0
        try:
            with cards.engine.begin() as connection:
                connection.exec_driver_sql("BEGIN")
                transaction_cards = copy(cards)
                transaction_cards.engine = connection
                for entry in req.items:
                    with connection.begin_nested():
                        card, was_created = _ingest_card(user, entry, cards=transaction_cards)
                    created += int(was_created)
                    items.append(ExternalCardIngestResponse(card=card, created=was_created, clientId=entry.clientId))
            break
        except OperationalError as exc:
            if attempt + 1 == _BATCH_WRITE_MAX_ATTEMPTS or not _is_retryable_sqlite_lock(exc):
                raise
            time.sleep(0.01 * (2**attempt))
    return ExternalCardBatchResponse(items=items, created=created, duplicates=len(items) - created)


@router.post("/api/v1/cards/batch", response_model=ExternalCardBatchResponse, status_code=201)
async def ingest_card_batch(req: ExternalCardBatchRequest, response: Response, user: ExternalUser):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    return await run_in_threadpool(_ingest_card_batch, req, user)


def _ingest_single_card(req: ExternalCardCreateRequest, user: UserRecord) -> ExternalCardIngestResponse:
    card, created = _ingest_card(user, req, write_lock=_external_card_write_lock(user))
    return ExternalCardIngestResponse(card=card, created=created, clientId=req.clientId)


@router.post("/api/v1/cards", response_model=ExternalCardIngestResponse, status_code=201)
async def ingest_card(req: ExternalCardCreateRequest, response: Response, user: ExternalUser):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    return await run_in_threadpool(_ingest_single_card, req, user)


def _list_external_cards(
    response: Response,
    user: UserRecord,
    *,
    notebook_id: str,
    since: str | None,
    limit: int,
    cursor: str | None,
) -> ExternalCardListResponse:
    _validate_notebook(user, notebook_id)
    cards, next_cursor = list_vocab_response(
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
    if next_cursor is not None:
        response.headers["X-Next-Cursor"] = next_cursor
    return ExternalCardListResponse(items=cards, nextCursor=next_cursor)


@router.get("/api/v1/cards", response_model=ExternalCardListResponse)
async def list_external_cards(
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
    since: str | None = None,
    limit: int = Query(100, ge=1, le=1000),
    cursor: str | None = None,
):
    _require_pro(user)
    await _admit_external(response, user, read_limiter)
    return await run_in_threadpool(
        _list_external_cards, response, user, notebook_id=notebook_id, since=since, limit=limit, cursor=cursor
    )


def _get_external_card(user: UserRecord, card_id: str, notebook_id: str) -> CardResponse:
    _validate_notebook(user, notebook_id)
    return _render_card(user, _card_or_404(user, card_id, notebook_id), notebook_id)


@router.get("/api/v1/cards/{card_id}", response_model=CardResponse)
async def get_external_card(
    card_id: str,
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
):
    _require_pro(user)
    await _admit_external(response, user, read_limiter)
    return await run_in_threadpool(_get_external_card, user, card_id, notebook_id)


def _update_external_card(
    user: UserRecord, card_id: str, req: ExternalCardUpdateRequest, notebook_id: str
) -> CardResponse:
    _validate_notebook(user, notebook_id)
    card = _card_or_404(user, card_id, notebook_id)
    updates: dict[str, Any] = {}
    for field in ("meaning", "note", "examples", "collocations", "mode"):
        value = getattr(req, field)
        if value is not None:
            updates[field] = value
    if req.pos is not None:
        updates["pos"] = _normalize_pos(req.pos)
    if not updates:
        raise BadRequestError("No card fields to update")
    updated = _card_store(user["dir"]).update(card.id, **updates)
    if updated is None:
        raise NotFoundError("Card", card_id)
    if "meaning" in updates and updates["meaning"] != card.meaning:
        _reembed_after_meaning_edit(user, card.id, notebook_id)
    return _render_card(user, updated, notebook_id)


def _reembed_after_meaning_edit(user: UserRecord, card_id: str, notebook_id: str) -> None:
    # The edit is already durable; store-creation failures are captured and
    # skipped so they never turn a successful update into a retry-prone 5xx.
    try:
        embeddings = _embedding_store(user["dir"], llm=None, notebook_id=notebook_id)
    except Exception as exc:
        capture_handled(exc, context="external_api.embedding_evict")
        embeddings = None
    try:
        graph = _graph_store(user["dir"], notebook_id=notebook_id)
    except Exception as exc:
        capture_handled(exc, context="external_api.judge_requeue")
        graph = None
    reembed_after_meaning_edit(embeddings, graph, card_id)


@router.patch("/api/v1/cards/{card_id}", response_model=CardResponse)
async def update_external_card(
    card_id: str,
    req: ExternalCardUpdateRequest,
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    return await run_in_threadpool(_update_external_card, user, card_id, req, notebook_id)


def _archive_external_card(
    user: UserRecord, card_id: str, req: ExternalCardArchiveRequest, notebook_id: str
) -> CardResponse:
    _validate_notebook(user, notebook_id)
    card = _card_or_404(user, card_id, notebook_id)
    archive_word_response(
        card.content,
        ArchiveWordRequest(archived=req.archived),
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )
    updated = _card_store(user["dir"]).get(card_id)
    if updated is None:
        raise NotFoundError("Card", card_id)
    return _render_card(user, updated, notebook_id)


@router.post("/api/v1/cards/{card_id}/archive", response_model=CardResponse)
async def archive_external_card(
    card_id: str,
    req: ExternalCardArchiveRequest,
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    return await run_in_threadpool(_archive_external_card, user, card_id, req, notebook_id)


def _delete_external_card(user: UserRecord, card_id: str, notebook_id: str) -> ExternalCardDeleteResponse:
    _validate_notebook(user, notebook_id)
    card = _card_or_404(user, card_id, notebook_id)
    cards = _card_store(user["dir"])
    graph = _graph_store(user["dir"], notebook_id=notebook_id)
    cards.delete(card.id)
    try:
        # Peers must be read before cleanup deprecates the links.
        peer_ids = link_peer_ids(graph, card.id)
        graph.cleanup_for_card(card.id, remove_blocked=True, source="manual")
    except Exception:
        try:
            cards.restore(card.id, notebook_id=notebook_id)
        except Exception:
            # Never let a failed rollback mask the original graph error.
            logger.warning("[%s] Failed to restore card %s after graph error", user["id"], card.id, exc_info=True)
        raise
    touch_peers(cards, peer_ids, card)
    embeddings = None
    try:
        embeddings = _embedding_store(user["dir"], llm=None, notebook_id=notebook_id)
    except Exception as exc:
        # Card/graph deletion is already durable; a store that cannot open must
        # not turn a successful delete into a retry-prone 5xx. The shared helper
        # below is best-effort for the remove itself.
        logger.warning("[%s] Failed to open embedding store for deleted card %s", user["id"], card.id, exc_info=True)
        capture_handled(exc, context="external_api.embedding_evict")
    evict_card_embedding(embeddings, card.id)
    return ExternalCardDeleteResponse(cardId=card.id, deleted=True)


@router.delete("/api/v1/cards/{card_id}", response_model=ExternalCardDeleteResponse)
async def delete_external_card(
    card_id: str,
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    return await run_in_threadpool(_delete_external_card, user, card_id, notebook_id)


def _review_external_card(
    user: UserRecord, card_id: str, req: ExternalCardReviewRequest, notebook_id: str
) -> CardResponse:
    _validate_notebook(user, notebook_id)
    card = _card_or_404(user, card_id, notebook_id)
    push_review_response(
        ReviewStatePushRequest(
            entries=[
                ReviewStateEntry(
                    word=card.content,
                    card_id=card.id,
                    review_interval_hours=req.reviewIntervalHours,
                    next_review_at=req.nextReviewAt,
                    last_reviewed_at=req.lastReviewedAt,
                    review_count=req.reviewCount,
                    lapse_count=req.lapseCount,
                    review_streak=req.reviewStreak,
                    last_review_feedback=req.lastReviewFeedback,
                )
            ]
        ),
        user,
        card_store_factory=_card_store,
        logger=logger,
        notebook_id=notebook_id,
    )
    updated = _card_store(user["dir"]).get(card_id)
    if updated is None:
        raise NotFoundError("Card", card_id)
    return _render_card(user, updated, notebook_id)


@router.post("/api/v1/cards/{card_id}/review", response_model=CardResponse)
async def review_external_card(
    card_id: str,
    req: ExternalCardReviewRequest,
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    return await run_in_threadpool(_review_external_card, user, card_id, req, notebook_id)


def _list_external_links(user: UserRecord, notebook_id: str) -> ExternalLinkListResponse:
    _validate_notebook(user, notebook_id)
    return ExternalLinkListResponse(
        items=get_graph_links_response(
            user,
            graph_store_factory=_graph_store,
            card_store_factory=_card_store,
            notebook_store_factory=_notebook_store,
            notebook_id=notebook_id,
        )
    )


@router.get("/api/v1/links", response_model=ExternalLinkListResponse)
async def list_external_links(
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
):
    _require_pro(user)
    await _admit_external(response, user, read_limiter)
    return await run_in_threadpool(_list_external_links, user, notebook_id)


def _create_external_link(
    req: ExternalManualLinkRequest, response: Response, user: UserRecord, notebook_id: str
) -> GraphLinkResponse:
    _validate_notebook(user, notebook_id)
    quota = _check_quota(user, "manual_link", response)
    result = create_manual_link_response(
        ManualLinkRequest(from_id=req.fromId, to_id=req.toId),
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        client_factory=create_client,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )
    _apply_quota_headers(response, quota)
    return result


@router.post("/api/v1/links", response_model=GraphLinkResponse)
async def create_external_link(
    req: ExternalManualLinkRequest,
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
):
    _require_pro(user)
    # Manual linking invokes the LLM judge, so use the expensive-operation
    # bucket rather than the cheap card-write bucket.
    await _admit_external(response, user, enrich_limiter)
    return await run_in_threadpool(_create_external_link, req, response, user, notebook_id)


def _change_external_link(handler: Callable[..., None], link_id: str, user: UserRecord, notebook_id: str) -> None:
    """Run a hide/unhide/delete graph-link handler against the caller's notebook."""
    _validate_notebook(user, notebook_id)
    handler(
        link_id,
        user,
        card_store_factory=_card_store,
        graph_store_factory=_graph_store,
        notebook_store_factory=_notebook_store,
        notebook_id=notebook_id,
    )


@router.patch("/api/v1/links/{link_id}/hide", status_code=204)
async def hide_external_link(
    link_id: str,
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    await run_in_threadpool(_change_external_link, hide_graph_link_response, link_id, user, notebook_id)


@router.patch("/api/v1/links/{link_id}/unhide", status_code=204)
async def unhide_external_link(
    link_id: str,
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    await run_in_threadpool(_change_external_link, unhide_graph_link_response, link_id, user, notebook_id)


@router.delete("/api/v1/links/{link_id}", status_code=204)
async def delete_external_link(
    link_id: str,
    response: Response,
    user: ExternalUser,
    notebook_id: str = Query("default", alias="notebookId", pattern=r"^[A-Za-z0-9_-]{1,64}$"),
):
    _require_pro(user)
    await _admit_external(response, user, write_limiter)
    await run_in_threadpool(_change_external_link, delete_graph_link_response, link_id, user, notebook_id)


def _enqueue_external_enrich(
    req: ExternalEnrichRequest, background_tasks: BackgroundTasks, response: Response, user: UserRecord
) -> ExternalOperationResponse:
    _validate_notebook(user, req.notebookId)
    quota = _check_quota(user, "pipeline", response)
    operation_id = uuid.uuid4().hex[:12]
    from .. import pipeline_log

    # Persist before scheduling the background task. If the process exits
    # between these two operations, startup recovery marks the run interrupted
    # and the operation remains queryable instead of disappearing from memory.
    pipeline_log.start_run(operation_id, user["id"], req.notebookId, "background")
    _remember_operation(operation_id, user["id"], req.notebookId)
    background_tasks.add_task(
        _run_external_pipeline,
        user,
        operation_id,
        force=req.force,
        notebook_id=req.notebookId,
    )
    _apply_quota_headers(response, quota)
    return _queued_operation(
        operation_id, _operation_owner(operation_id) or {"notebook_id": req.notebookId, "status": "queued"}
    )


@router.post("/api/v1/enrich", response_model=ExternalOperationResponse, status_code=202)
async def enqueue_external_enrich(
    req: ExternalEnrichRequest,
    background_tasks: BackgroundTasks,
    response: Response,
    user: ExternalUser,
):
    _require_pro(user)
    await _admit_external(response, user, enrich_limiter)
    return await run_in_threadpool(_enqueue_external_enrich, req, background_tasks, response, user)


def _get_external_operation(operation_id: str, user: UserRecord) -> ExternalOperationResponse:
    owner = _operation_owner(operation_id)
    if owner is not None and owner.get("user_id") != user["id"]:
        raise NotFoundError("Operation", operation_id)
    persisted = _persisted_operation(operation_id, user["id"])
    if persisted is not None:
        return _operation_from_run(persisted)
    if owner is None:
        raise NotFoundError("Operation", operation_id)
    return _queued_operation(operation_id, owner)


@router.get("/api/v1/operations/{operation_id}", response_model=ExternalOperationResponse)
async def get_external_operation(operation_id: str, response: Response, user: ExternalUser):
    _require_pro(user)
    await _admit_external(response, user, read_limiter)
    return await run_in_threadpool(_get_external_operation, operation_id, user)


def _list_external_enrich_runs(user: UserRecord, limit: int) -> ExternalOperationListResponse:
    from .. import pipeline_log

    return ExternalOperationListResponse(
        items=[_operation_from_run(run) for run in pipeline_log.get_runs(user["id"], limit=limit)]
    )


@router.get("/api/v1/enrich/runs", response_model=ExternalOperationListResponse)
async def list_external_enrich_runs(
    response: Response,
    user: ExternalUser,
    limit: int = Query(20, ge=1, le=100),
):
    _require_pro(user)
    await _admit_external(response, user, read_limiter)
    return await run_in_threadpool(_list_external_enrich_runs, user, limit)
