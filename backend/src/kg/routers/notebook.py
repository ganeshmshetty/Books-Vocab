from __future__ import annotations

import json

from fastapi import APIRouter

from ..api_models import (
    NotebookCardLayout,
    NotebookCreateRequest,
    NotebookResponse,
    NotebookReviewPolicy,
    NotebookSettingsGroup,
    NotebookSettingsPatchRequest,
    NotebookSettingsResponse,
    NotebookUpdateRequest,
)
from ..deps import CurrentUser, _card_store, _notebook_store
from ..exceptions import BadRequestError, NotFoundError
from ..notebook import NotebookSettings
from ..vocab_shared import _dt_to_iso

router = APIRouter(tags=["notebook"])


def _settings_response(row: NotebookSettings | None) -> NotebookSettingsResponse:
    def group(value: str | None, updated_at: float | None, model):
        return NotebookSettingsGroup(
            value=None if value is None else model.model_validate(json.loads(value)),
            updatedAt=updated_at,
        )

    return NotebookSettingsResponse(
        reviewPolicy=group(
            row.review_policy if row else None, row.review_policy_updated_at if row else None, NotebookReviewPolicy
        ),
        cardLayout=group(
            row.card_layout if row else None, row.card_layout_updated_at if row else None, NotebookCardLayout
        ),
    )


def _notebook_response(nb, card_count: int = 0, settings: NotebookSettings | None = None) -> NotebookResponse:
    return NotebookResponse(
        id=nb.id,
        name=nb.name,
        color=nb.color,
        coverPattern=nb.cover_pattern,
        sortOrder=nb.sort_order,
        isDefault=nb.is_default,
        isDeleted=nb.is_deleted,
        cardCount=card_count,
        updatedAt=_dt_to_iso(nb.updated_at),
        createdAt=_dt_to_iso(nb.created_at),
        sourceSharedDeckId=nb.source_shared_deck_id,
        sourceVersion=nb.source_version,
        settings=_settings_response(settings),
    )


@router.get("/api/notebooks", response_model=list[NotebookResponse])
def list_notebooks(user: CurrentUser, since: str | None = None):
    store = _notebook_store(user["dir"])
    store.ensure_default()
    cards = _card_store(user["dir"])

    if since is not None:
        from ..user_store import parse_datetime

        parsed = parse_datetime(since)
        if parsed is None:
            raise BadRequestError("Invalid since timestamp")
        notebooks = store.get_modified_since(parsed)
    else:
        notebooks = store.all(include_deleted=True)

    counts = cards.count_by_notebook()
    return [
        _notebook_response(nb, card_count=counts.get(nb.id, 0), settings=store.get_settings(nb.id)) for nb in notebooks
    ]


@router.post("/api/notebooks", response_model=NotebookResponse, status_code=201)
def create_notebook(req: NotebookCreateRequest, user: CurrentUser):
    store = _notebook_store(user["dir"])
    nb = store.create(name=req.name, color=req.color, cover_pattern=req.cover_pattern)
    return _notebook_response(nb, settings=store.get_settings(nb.id))


@router.patch("/api/notebooks/{nb_id}", response_model=NotebookResponse)
def update_notebook(nb_id: str, req: NotebookUpdateRequest, user: CurrentUser):
    store = _notebook_store(user["dir"])
    kwargs = {}
    if req.name is not None:
        kwargs["name"] = req.name
    if "color" in req.model_fields_set:
        kwargs["color"] = req.color
    if req.cover_pattern is not None:
        kwargs["cover_pattern"] = req.cover_pattern if req.cover_pattern != "" else None
    if req.sort_order is not None:
        kwargs["sort_order"] = req.sort_order
    if not kwargs:
        raise BadRequestError("No fields to update")
    nb = store.update(nb_id, **kwargs)
    if nb is None:
        raise NotFoundError("Notebook", nb_id)
    cards = _card_store(user["dir"])
    return _notebook_response(nb, card_count=cards.count(notebook_id=nb.id), settings=store.get_settings(nb.id))


@router.patch("/api/notebooks/{nb_id}/settings", response_model=NotebookResponse)
def update_notebook_settings(nb_id: str, req: NotebookSettingsPatchRequest, user: CurrentUser):
    store = _notebook_store(user["dir"])
    kwargs = {}
    if req.reviewPolicy is not None:
        kwargs["review_policy"] = (
            None if req.reviewPolicy.value is None else req.reviewPolicy.value.model_dump(),
            req.reviewPolicy.updatedAt,
        )
    if req.cardLayout is not None:
        kwargs["card_layout"] = (
            None if req.cardLayout.value is None else req.cardLayout.value.model_dump(),
            req.cardLayout.updatedAt,
        )
    nb = store.update_settings(nb_id, **kwargs)
    if nb is None:
        raise NotFoundError("Notebook", nb_id)
    cards = _card_store(user["dir"])
    return _notebook_response(
        nb,
        card_count=cards.count(notebook_id=nb.id),
        settings=store.get_settings(nb.id),
    )


@router.delete("/api/notebooks/{nb_id}")
def delete_notebook(nb_id: str, user: CurrentUser):
    store = _notebook_store(user["dir"])
    cards = _card_store(user["dir"])
    result = store.delete(nb_id)
    if result is False:
        raise BadRequestError("Cannot delete: notebook not found or is default")
    cards_deleted = 0
    # A tombstone is a cleanup barrier, not proof that cascading cleanup
    # completed. Retry the full idempotent cascade after any prior failure.
    if result is True or result is None:
        cards_deleted = cards.soft_delete_by_notebook(nb_id)
        # Remove every per-notebook artifact + evict cached stores (shared with ops CLI).
        from ..ops_shared import remove_notebook_artifacts

        remove_notebook_artifacts(user["dir"], nb_id)
    return {"deleted": nb_id, "cardsDeleted": cards_deleted}
