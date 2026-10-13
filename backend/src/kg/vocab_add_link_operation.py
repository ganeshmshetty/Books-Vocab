"""Durable, idempotent orchestration for Add Link target creation.

The route admits one command and returns immediately.  This module owns the
server-side state machine so iOS can poll one operation while translation,
card creation, enrichment, graph linking, and projection converge.
"""

from __future__ import annotations

import asyncio
import hashlib
import inspect
import json
import logging
import sqlite3
import uuid
from collections.abc import Awaitable, Callable, Iterable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from . import runtime_data_root
from .api_models import AddLinkOperationResponse
from .sqlite_lifecycle import SQLiteLifecycle
from .vocab_shared import _clean_content

logger = logging.getLogger(__name__)

STEP_IDS = (
    "resolve_target",
    "translate",
    "create_card",
    "enrich",
    "create_link",
    "local_projection",
)
_TERMINAL_STATUSES = {"succeeded", "succeeded_with_warnings", "failed", "interrupted"}

# The server stopped (shutdown cancel or crash/restart) before the operation
# reached a terminal state.  One code covers both paths: the client-side remedy
# is identical (retry with a fresh Idempotency-Key) and no user-initiated cancel
# exists.  Legacy rows may still carry the old ``cancelled`` code.
INTERRUPTED_ERROR_CODE = "interrupted"
_ACTIVE_STEP_STATUSES = {"running", "retry"}


class IdempotencyConflict(ValueError):
    """The same idempotency key was reused with a different request."""


class SourceUnavailableError(ValueError):
    """The source card vanished, was archived, or left the notebook."""


class NotebookUnavailableError(ValueError):
    """The notebook was deleted while the operation was in flight."""


class TargetArchivedError(ValueError):
    """The word being linked to exists only as an archived card."""


class TargetIsSourceError(ValueError):
    """The normalized target word resolves to the source card itself."""


_lifecycle = SQLiteLifecycle()
_lock = _lifecycle.lock
_DB_FILENAME = "vocab_add_link_operations.db"


def _db_path(data_root: Path | None = None) -> Path:
    # Runtime calls follow the root the running app holds the worker lock on,
    # i.e. the directory the startup reaper sweeps.
    return (runtime_data_root.current() if data_root is None else data_root) / _DB_FILENAME


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _initial_steps() -> list[dict[str, Any]]:
    return [
        {
            "id": step_id,
            "status": "skipped" if step_id == "local_projection" else "waiting",
            "current": 0,
            "total": 1,
            "detail_code": "client_projection" if step_id == "local_projection" else None,
        }
        for step_id in STEP_IDS
    ]


def _ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS vocab_add_link_operations (
            operation_id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            notebook_id TEXT NOT NULL,
            idempotency_key TEXT NOT NULL,
            request_hash TEXT NOT NULL,
            request_json TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'queued',
            sequence INTEGER NOT NULL DEFAULT 0,
            steps TEXT NOT NULL DEFAULT '[]',
            target_card_id TEXT,
            link_id TEXT,
            warnings TEXT NOT NULL DEFAULT '[]',
            error_code TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            ended_at TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE UNIQUE INDEX IF NOT EXISTS uq_vocab_add_link_user_key
        ON vocab_add_link_operations(user_id, idempotency_key)
        """
    )
    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS ix_vocab_add_link_user_created
        ON vocab_add_link_operations(user_id, created_at)
        """
    )


def _get_conn(data_root: Path | None = None) -> sqlite3.Connection:
    return _lifecycle.get_connection(_db_path(data_root), _ensure_schema)


def reset() -> None:
    """Close the process-local connection; intended for isolated tests."""
    _lifecycle.reset()


def _request_hash(payload: dict[str, Any]) -> str:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _decode_steps(raw: str) -> list[dict[str, Any]]:
    try:
        value = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return _initial_steps()
    if not isinstance(value, list):
        return _initial_steps()
    return [step for step in value if isinstance(step, dict)] or _initial_steps()


def _decode_json_list(raw: str) -> list[str]:
    try:
        value = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return []
    return [item for item in value if isinstance(item, str)] if isinstance(value, list) else []


def _row_to_dict(row: sqlite3.Row | tuple[Any, ...]) -> dict[str, Any]:
    names = (
        "operation_id",
        "user_id",
        "notebook_id",
        "idempotency_key",
        "request_hash",
        "request_json",
        "status",
        "sequence",
        "steps",
        "target_card_id",
        "link_id",
        "warnings",
        "error_code",
        "created_at",
        "updated_at",
        "ended_at",
    )
    values = dict(row) if isinstance(row, sqlite3.Row) else dict(zip(names, row, strict=True))
    try:
        payload = json.loads(values["request_json"])
    except (TypeError, json.JSONDecodeError):
        payload = {}
    return {
        **values,
        "request": payload if isinstance(payload, dict) else {},
        "steps": _decode_steps(values["steps"]),
        "warnings": _decode_json_list(values["warnings"]),
    }


_SELECT = (
    "SELECT operation_id, user_id, notebook_id, idempotency_key, request_hash, "
    "request_json, status, sequence, steps, target_card_id, link_id, warnings, "
    "error_code, created_at, updated_at, ended_at "
    "FROM vocab_add_link_operations"
)


def _select(operation_id: str, user_id: str | None = None) -> dict[str, Any] | None:
    conn = _get_conn()
    if user_id is None:
        row = conn.execute(f"{_SELECT} WHERE operation_id = ?", (operation_id,)).fetchone()
    else:
        row = conn.execute(
            f"{_SELECT} WHERE operation_id = ? AND user_id = ?",
            (operation_id, user_id),
        ).fetchone()
    return _row_to_dict(row) if row else None


def create_operation(
    *, user_id: str, notebook_id: str, idempotency_key: str, payload: dict[str, Any]
) -> tuple[dict[str, Any], bool]:
    """Create or replay an operation, atomically enforcing idempotency."""
    request_hash = _request_hash(payload)
    operation_id = uuid.uuid4().hex[:24]
    now = _now()
    with _lock:
        conn = _get_conn()
        try:
            conn.execute(
                "INSERT INTO vocab_add_link_operations "
                "(operation_id, user_id, notebook_id, idempotency_key, request_hash, "
                "request_json, steps, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    operation_id,
                    user_id,
                    notebook_id,
                    idempotency_key,
                    request_hash,
                    json.dumps(payload, ensure_ascii=False, sort_keys=True),
                    json.dumps(_initial_steps(), ensure_ascii=False),
                    now,
                    now,
                ),
            )
            conn.commit()
        except sqlite3.IntegrityError:
            existing = conn.execute(
                f"{_SELECT} WHERE user_id = ? AND idempotency_key = ?",
                (user_id, idempotency_key),
            ).fetchone()
            if existing is None:
                raise
            result = _row_to_dict(existing)
            if result["request_hash"] != request_hash or result["notebook_id"] != notebook_id:
                raise IdempotencyConflict("Idempotency-Key was reused with a different request") from None
            return result, False
        return _select(operation_id) or {}, True


def find_operation(
    *, user_id: str, notebook_id: str, idempotency_key: str, payload: dict[str, Any]
) -> dict[str, Any] | None:
    """Return the stored operation for this key, or ``None``; a changed payload or notebook conflicts.

    The notebook is part of the replay identity: the payload alone does not carry
    it, so a replay under another notebook must not return the stored operation.
    Lets a replay be answered before any live-state validation (e.g. source card
    lookup) that may have changed since the original admission.
    """
    with _lock:
        row = (
            _get_conn()
            .execute(f"{_SELECT} WHERE user_id = ? AND idempotency_key = ?", (user_id, idempotency_key))
            .fetchone()
        )
    if row is None:
        return None
    existing = _row_to_dict(row)
    if existing["request_hash"] != _request_hash(payload) or existing["notebook_id"] != notebook_id:
        raise IdempotencyConflict("Idempotency-Key was reused with a different request")
    return existing


def get_operation(user_id: str, operation_id: str) -> dict[str, Any] | None:
    with _lock:
        return _select(operation_id, user_id)


def _get_by_id(operation_id: str) -> dict[str, Any] | None:
    with _lock:
        return _select(operation_id)


def _update(
    operation_id: str,
    *,
    status: str | None = None,
    sequence: int | None = None,
    steps: list[dict[str, Any]] | None = None,
    target_card_id: str | None = None,
    link_id: str | None = None,
    warnings: list[str] | None = None,
    error_code: str | None = None,
    ended: bool = False,
    conn: sqlite3.Connection | None = None,
) -> None:
    assignments = ["updated_at = ?"]
    values: list[Any] = [_now()]
    if status is not None:
        assignments.append("status = ?")
        values.append(status)
    if sequence is not None:
        assignments.append("sequence = ?")
        values.append(sequence)
    if steps is not None:
        assignments.append("steps = ?")
        values.append(json.dumps(steps, ensure_ascii=False))
    if target_card_id is not None:
        assignments.append("target_card_id = ?")
        values.append(target_card_id)
    if link_id is not None:
        assignments.append("link_id = ?")
        values.append(link_id)
    if warnings is not None:
        assignments.append("warnings = ?")
        values.append(json.dumps(sorted(set(warnings)), ensure_ascii=False))
    if error_code is not None:
        assignments.append("error_code = ?")
        values.append(error_code)
    if ended:
        assignments.append("ended_at = ?")
        values.append(_now())
    values.append(operation_id)
    with _lock:
        conn = conn if conn is not None else _get_conn()
        conn.execute(
            f"UPDATE vocab_add_link_operations SET {', '.join(assignments)} WHERE operation_id = ?",
            values,
        )
        conn.commit()


def start_operation(operation_id: str) -> None:
    record = _get_by_id(operation_id)
    if record is not None and record["status"] not in _TERMINAL_STATUSES:
        _update(operation_id, status="running", sequence=record["sequence"] + 1)


def update_step(
    operation_id: str,
    step_id: str,
    *,
    status: str,
    current: int = 0,
    total: int = 1,
    detail_code: str | None = None,
) -> None:
    with _lock:
        record = _select(operation_id)
        if record is None:
            return
        steps = record["steps"]
        for step in steps:
            if step.get("id") == step_id:
                step.update(
                    status=status,
                    current=current,
                    total=total,
                    detail_code=detail_code,
                )
                break
        _update(operation_id, sequence=record["sequence"] + 1, steps=steps)


def set_target_card(operation_id: str, card_id: str) -> None:
    record = _get_by_id(operation_id)
    if record:
        _update(operation_id, target_card_id=card_id, sequence=record["sequence"] + 1)


def set_link(operation_id: str, link_id: str) -> None:
    record = _get_by_id(operation_id)
    if record:
        _update(operation_id, link_id=link_id, sequence=record["sequence"] + 1)


def add_warning(operation_id: str, warning: str) -> None:
    record = _get_by_id(operation_id)
    if record:
        _update(
            operation_id,
            warnings=[*record["warnings"], warning],
            sequence=record["sequence"] + 1,
        )


def finish_operation(operation_id: str, *, status: str, error_code: str | None = None) -> None:
    record = _get_by_id(operation_id)
    if record:
        _update(
            operation_id,
            status=status,
            error_code=error_code,
            sequence=record["sequence"] + 1,
            ended=True,
        )


def _mark_interrupted(conn: sqlite3.Connection, operation_id: str, record: dict[str, Any]) -> None:
    steps = record["steps"]
    for step in steps:
        if step.get("status") in _ACTIVE_STEP_STATUSES:
            step.update(status="error", detail_code=INTERRUPTED_ERROR_CODE)
    _update(
        operation_id,
        status="interrupted",
        error_code=INTERRUPTED_ERROR_CODE,
        sequence=record["sequence"] + 1,
        steps=steps,
        ended=True,
        conn=conn,
    )


def reap_interrupted_operations(data_root: Path) -> int:
    """Mark every non-terminal operation under ``data_root`` ``interrupted``; return the count.

    Operations run as in-process background tasks, so anything still queued or
    running when the process starts was orphaned by the previous one and would
    otherwise be polled forever.  Only safe for the ``data_root`` whose
    single-worker lock this process holds (the app lifespan passes the locked
    ``settings.data_dir`` right after ``assert_single_worker``), so the root is
    explicit instead of re-read from ``KG_DATA_DIR``.
    """
    terminal = ", ".join("?" for _ in _TERMINAL_STATUSES)
    with _lock:
        conn = _get_conn(data_root)
        rows = conn.execute(
            f"{_SELECT} WHERE status NOT IN ({terminal})",
            tuple(sorted(_TERMINAL_STATUSES)),
        ).fetchall()
        for row in rows:
            record = _row_to_dict(row)
            _mark_interrupted(conn, record["operation_id"], record)
    return len(rows)


def operation_response(record: dict[str, Any]) -> AddLinkOperationResponse:
    return AddLinkOperationResponse.model_validate(
        {
            "operationId": record["operation_id"],
            "notebookId": record["notebook_id"],
            "status": record["status"],
            "sequence": record["sequence"],
            "steps": [
                {
                    "id": step.get("id", ""),
                    "status": step.get("status", "error"),
                    "current": step.get("current", 0),
                    "total": step.get("total", 1),
                    "detailCode": step.get("detail_code"),
                }
                for step in record["steps"]
            ],
            "targetCardId": record["target_card_id"],
            "linkId": record["link_id"],
            "warnings": record["warnings"],
            "errorCode": record["error_code"],
        }
    )


async def _default_translate(*, payload: dict[str, Any], user: dict[str, Any], logger: logging.Logger):
    from .api_models import TranslateRequest
    from .translate_handlers import translate_quick_response

    return await translate_quick_response(
        TranslateRequest(
            word=payload["target_word"],
            context=payload.get("context", ""),
            source_lang=payload.get("source_lang"),
            target_lang=payload.get("target_lang"),
        ),
        user,
        logger=logger,
    )


async def _default_enrich(
    *,
    card: Any,
    cards: Any,
    user: dict[str, Any],
    client_factory: Callable | None,
    logger: logging.Logger,
    progress: Callable[[dict[str, Any]], None] | None = None,
    sense_context: str = "",
    graph: Any = None,
    open_embeddings: Callable[[], Any] | None = None,
) -> None:
    from .deps_quota import _is_pro
    from .enrich import enrich_cards_stream
    from .llm.providers import provider_for
    from .service_factories import create_client
    from .tracked_llm import TrackedLLM

    provider = provider_for("enrich")
    llm = TrackedLLM(
        (client_factory or create_client)(provider),
        user["id"],
        provider=provider,
        enforce_quota=True,
        is_pro=_is_pro(user),
    )
    async for message in enrich_cards_stream(
        llm,
        [card],
        batch_size=1,
        max_workers=1,
        model=provider.chat_model,
        disambiguation_context_by_card_id={card.id: sense_context} if sense_context.strip() else None,
    ):
        if progress is not None:
            progress(message)
        if message.get("status") == "error":
            raise RuntimeError("enrichment provider returned an error")
        results = message.get("results") or []
        result = next(
            (
                item
                for item in results
                if isinstance(item, dict) and str(item.get("word") or "").casefold() == card.content.casefold()
            ),
            None,
        )
        if result is None:
            continue
        from .vocab_shared import _normalize_pos

        updates: dict[str, Any] = {}
        if result.get("pos") and not card.pos:
            updates["pos"] = _normalize_pos(result["pos"])
        if result.get("note") and not card.note:
            updates["note"] = result["note"]
        if result.get("collocations"):
            updates["collocations"] = result["collocations"]
        meaning_changed = False
        if result.get("meaning_fix"):
            updates["meaning"] = result["meaning_fix"]
            meaning_changed = updates["meaning"] != card.meaning
        if updates:
            cards.batch_update([(card.id, updates)])
            if meaning_changed and open_embeddings is not None:
                from .vocab_crud import reembed_meaning_edits_best_effort

                reembed_meaning_edits_best_effort(
                    [card.id],
                    open_embeddings=open_embeddings,
                    open_graph=lambda: graph,
                )


def _default_link(
    *,
    from_id: str,
    to_id: str,
    notebook_id: str,
    user: dict[str, Any],
    cards: Any,
    graph: Any,
    client_factory: Callable | None,
    logger: logging.Logger,
) -> Any:
    from .deps_quota import _is_pro
    from .judge import ManualLinkJudge
    from .llm.providers import provider_for
    from .service_factories import create_client
    from .tracked_llm import TrackedLLM
    from .vocab_graph_ops import create_manual_link

    provider = provider_for("judge_manual")
    judge = ManualLinkJudge(
        TrackedLLM(
            (client_factory or create_client)(provider),
            user["id"],
            provider=provider,
            enforce_quota=True,
            is_pro=_is_pro(user),
        ),
        model=provider.chat_model,
        user_id=user["id"],
        notebook_id=notebook_id,
    )
    return create_manual_link(
        from_id=from_id,
        to_id=to_id,
        cards_store=cards,
        graph=graph,
        judge=judge,
        notebook_id=notebook_id,
    )


def _error_code(step_id: str, exc: BaseException) -> str:
    from .exceptions import NotFoundError, QuotaExceededError

    if isinstance(exc, QuotaExceededError):
        return "quota_exhausted"
    if isinstance(exc, SourceUnavailableError):
        return "source_unavailable"
    if isinstance(exc, NotebookUnavailableError):
        return "notebook_unavailable"
    if isinstance(exc, TargetArchivedError):
        return "target_archived"
    if isinstance(exc, TargetIsSourceError):
        return "target_is_source"
    if isinstance(exc, NotFoundError):
        return "source_unavailable" if step_id == "resolve_target" else f"{step_id}_unavailable"
    return {
        "resolve_target": "target_unavailable",
        "translate": "translation_failed",
        "create_card": "card_creation_failed",
        "create_link": "link_creation_failed",
    }.get(step_id, "operation_failed")


def _ensure_notebook_alive(notebook_store_factory: Callable | None, user: dict[str, Any], notebook_id: str) -> None:
    """Fail the operation if its notebook was deleted after admission (#2268)."""
    if notebook_store_factory is None:
        return
    from .notebook import DEFAULT_NOTEBOOK_ID

    if notebook_id != DEFAULT_NOTEBOOK_ID and not notebook_store_factory(user["dir"]).exists(notebook_id):
        raise NotebookUnavailableError("notebook unavailable")


async def _maybe_await(value: Any) -> Any:
    return await value if inspect.isawaitable(value) else value


async def run_add_link_operation(
    operation_id: str,
    user: dict[str, Any],
    *,
    card_store_factory: Callable,
    graph_store_factory: Callable,
    get_user_lock_fn: Callable,
    client_factory: Callable | None = None,
    logger: logging.Logger = logger,
    translate_fn: Callable[..., Awaitable[Any]] | None = None,
    enrich_fn: Callable[..., Awaitable[None]] | None = None,
    link_fn: Callable[..., Any] | None = None,
    notebook_store_factory: Callable | None = None,
    embedding_store_factory: Callable | None = None,
) -> None:
    """Run one operation with at-least-once, read-after-write reconciliation."""
    record = _get_by_id(operation_id)
    if record is None or record["status"] in _TERMINAL_STATUSES:
        return
    lock = await _maybe_await(get_user_lock_fn(user["id"]))
    async with lock:
        record = _get_by_id(operation_id)
        if record is None or record["status"] in _TERMINAL_STATUSES:
            return
        start_operation(operation_id)
        payload = record["request"]
        cards = card_store_factory(user["dir"])
        graph = graph_store_factory(user["dir"], notebook_id=record["notebook_id"])
        current_step = "resolve_target"
        warnings: list[str] = []
        try:
            source = cards.get(payload["from_id"])
            if source is None or source.is_deleted or source.is_archived or source.notebook_id != record["notebook_id"]:
                raise SourceUnavailableError("source card unavailable")

            target_word = _clean_content(payload["target_word"])
            if not target_word:
                raise ValueError("target word is empty")
            target = cards.find_by_content(target_word, notebook_id=record["notebook_id"])
            if target is not None and target.is_archived:
                raise TargetArchivedError("target card is archived")
            if target is not None and target.id == source.id:
                raise TargetIsSourceError("target card is source card")

            if target is not None:
                update_step(operation_id, current_step, status="done", current=1, detail_code="existing_card")
                for skipped_id in ("translate", "create_card", "enrich"):
                    update_step(operation_id, skipped_id, status="skipped", detail_code="existing_card")
            else:
                update_step(operation_id, current_step, status="done", current=1, detail_code="target_missing")
                current_step = "translate"
                translation = payload.get("translation")
                root_form = None
                pos = None
                if translation:
                    update_step(operation_id, current_step, status="skipped", detail_code="provided")
                else:
                    update_step(operation_id, current_step, status="running")
                    result = await (translate_fn or _default_translate)(
                        payload=payload,
                        user=user,
                        logger=logger,
                    )
                    translation = (getattr(result, "t", "") or "").strip()
                    root_form = getattr(result, "r", None)
                    pos = getattr(result, "p", None)
                    if not translation:
                        raise ValueError("translation result is empty")
                    update_step(operation_id, current_step, status="done", current=1, detail_code="completed")

                current_step = "create_card"
                # Cheap early exit: avoid creating a card in a notebook deleted during translation.
                _ensure_notebook_alive(notebook_store_factory, user, record["notebook_id"])
                concurrent_target = cards.find_by_content(target_word, notebook_id=record["notebook_id"])
                if concurrent_target is not None:
                    if concurrent_target.is_archived:
                        raise TargetArchivedError("target card is archived")
                    target = concurrent_target
                    set_target_card(operation_id, target.id)
                    update_step(operation_id, current_step, status="skipped", detail_code="existing_card")
                    update_step(operation_id, "enrich", status="skipped", detail_code="existing_card")
                else:
                    update_step(operation_id, current_step, status="running")
                    source_json = (
                        json.dumps(payload["source"], ensure_ascii=False) if payload.get("source") is not None else None
                    )
                    target = cards.add(
                        content=target_word,
                        meaning=translation,
                        pos=pos,
                        examples=[],
                        root_form=root_form,
                        notebook_id=record["notebook_id"],
                        source=source_json,
                    )
                    try:
                        # Residual window: a delete cascade may have swept before this write.
                        _ensure_notebook_alive(notebook_store_factory, user, record["notebook_id"])
                    except NotebookUnavailableError:
                        cards.delete(target.id)  # soft delete -> tombstone for sync pull
                        raise
                    set_target_card(operation_id, target.id)
                    update_step(operation_id, current_step, status="done", current=1, detail_code="created")

                    current_step = "enrich"
                    update_step(operation_id, current_step, status="running")

                    def report_enrichment(message: dict[str, Any]) -> None:
                        status = message.get("status")
                        if status not in {"running", "retry", "error"}:
                            return
                        update_step(
                            operation_id,
                            "enrich",
                            status=status,
                            current=max(0, int(message.get("current", 0) or 0)),
                            total=max(1, int(message.get("total", 1) or 1)),
                            detail_code=(
                                "retryable"
                                if status == "retry"
                                else "enrichment_failed"
                                if status == "error"
                                else "progress"
                            ),
                        )

                    try:
                        if enrich_fn is None:
                            make_embeddings = embedding_store_factory
                            if make_embeddings is None:
                                from .deps import _embedding_store as make_embeddings
                            await _default_enrich(
                                card=target,
                                cards=cards,
                                user=user,
                                client_factory=client_factory,
                                logger=logger,
                                progress=report_enrichment,
                                sense_context=payload.get("context", ""),
                                graph=graph,
                                open_embeddings=lambda: make_embeddings(
                                    user["dir"], llm=None, notebook_id=record["notebook_id"]
                                ),
                            )
                        else:
                            await enrich_fn(
                                card=target,
                                cards=cards,
                                user=user,
                                client_factory=client_factory,
                                logger=logger,
                            )
                        update_step(operation_id, current_step, status="done", current=1, detail_code="completed")
                    except Exception as exc:  # enrichment is non-fatal for explicit link intent
                        logger.warning("Add Link enrichment failed for %s: %s", operation_id, exc, exc_info=True)
                        warnings.append("enrichment_failed")
                        add_warning(operation_id, "enrichment_failed")
                        update_step(operation_id, current_step, status="warning", detail_code="retryable")

            if target is None:
                raise RuntimeError("target reconciliation failed")
            set_target_card(operation_id, target.id)

            current_step = "create_link"
            update_step(operation_id, current_step, status="running")
            try:
                link_kwargs = {
                    "from_id": source.id,
                    "to_id": target.id,
                    "notebook_id": record["notebook_id"],
                    "user": user,
                    "cards": cards,
                    "graph": graph,
                    "client_factory": client_factory,
                    "logger": logger,
                }
                link = (
                    await asyncio.to_thread(_default_link, **link_kwargs)
                    if link_fn is None
                    else await _maybe_await(link_fn(**link_kwargs))
                )
            except Exception as exc:
                from .exceptions import ConflictError

                link = graph.find_link_between(source.id, target.id)
                if isinstance(exc, ConflictError):
                    if link is None or getattr(link, "status", "active") != "active":
                        raise
                elif link is None or getattr(link, "status", "active") != "active":
                    raise
                warnings.append("link_projection_pending")
                add_warning(operation_id, "link_projection_pending")
            set_link(operation_id, link.id)
            update_step(operation_id, current_step, status="done", current=1, detail_code="completed")
            finish_operation(
                operation_id,
                status="succeeded_with_warnings" if warnings else "succeeded",
            )
        except asyncio.CancelledError:
            update_step(operation_id, current_step, status="error", detail_code=INTERRUPTED_ERROR_CODE)
            finish_operation(operation_id, status="interrupted", error_code=INTERRUPTED_ERROR_CODE)
            raise
        except Exception as exc:  # background failure becomes typed operation state
            logger.error("Add Link operation %s failed at %s: %s", operation_id, current_step, exc, exc_info=True)
            update_step(operation_id, current_step, status="error", detail_code=_error_code(current_step, exc))
            finish_operation(operation_id, status="failed", error_code=_error_code(current_step, exc))


def delete_for_users(user_ids: Iterable[str]) -> int:
    """Delete every row owned by the supplied user IDs (operations).

    Account erasure hook: the database lives at the data root, not under each
    user's directory. Idempotent; unrelated user IDs are never touched.
    """
    ids = tuple(dict.fromkeys(user_ids))
    if not ids:
        return 0

    deleted = 0
    with _lock:
        conn = _get_conn()
        try:
            deleted += conn.executemany(
                "DELETE FROM vocab_add_link_operations WHERE user_id = ?",
                ((user_id,) for user_id in ids),
            ).rowcount
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return deleted
