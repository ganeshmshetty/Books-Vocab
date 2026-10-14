"""notebook_id pass-through for word-level vocab handlers (#3734).

The same word may exist in two notebooks. Each word-level handler must act on
the card of the requested notebook only. Dropping the notebook_id argument
makes find_by_content match any notebook, silently touching the other card.
"""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import patch

import pytest

import kg.routers.vocab as vocab_router_mod
from conftest import _DummyEmbeddingStore
from kg.service_factories import create_card_store, create_notebook_store

WORD = "apple"
DEFAULT_MEANING = "蘋果（水果）"
NB_MEANING = "蘋果公司"
EDITED_MEANING = "改寫後的意思"


def _seed(isolated_api) -> SimpleNamespace:
    user_dir = isolated_api.data_dir / "users" / isolated_api.user_id
    user_dir.mkdir(parents=True, exist_ok=True)
    notebook = create_notebook_store(user_dir).create("Work")
    cards = create_card_store(user_dir)
    # default is added first so an unscoped lookup would hit it.
    default_card = cards.add(WORD, DEFAULT_MEANING, notebook_id="default")
    nb_card = cards.add(WORD, NB_MEANING, notebook_id=notebook.id)
    return SimpleNamespace(
        cards=cards,
        notebook_id=notebook.id,
        default_id=default_card.id,
        nb_id=nb_card.id,
    )


def _delete(client, headers, nb):
    return client.delete(f"/api/vocab/{WORD}", params={"notebook_id": nb}, headers=headers)


def _batch_delete(client, headers, nb):
    return client.post("/api/vocab/batch-delete", json={"words": [WORD]}, params={"notebook_id": nb}, headers=headers)


def _archive(client, headers, nb):
    return client.patch(
        f"/api/vocab/{WORD}/archive", json={"archived": True}, params={"notebook_id": nb}, headers=headers
    )


def _batch_archive(client, headers, nb):
    return client.patch(
        "/api/vocab/batch-archive",
        json={"words": [WORD], "archived": True},
        params={"notebook_id": nb},
        headers=headers,
    )


def _content_update(client, headers, nb):
    return client.patch(
        f"/api/vocab/{WORD}", json={"meaning": EDITED_MEANING}, params={"notebook_id": nb}, headers=headers
    )


def _lookup(client, headers, nb):
    return client.get(f"/api/vocab/{WORD}", params={"notebook_id": nb}, headers=headers)


@pytest.mark.parametrize(
    ("call", "target_changed"),
    [
        pytest.param(_delete, lambda card: card.is_deleted, id="delete"),
        pytest.param(_batch_delete, lambda card: card.is_deleted, id="batch-delete"),
        pytest.param(_archive, lambda card: card.is_archived, id="archive"),
        pytest.param(_batch_archive, lambda card: card.is_archived, id="batch-archive"),
        pytest.param(_content_update, lambda card: card.meaning == EDITED_MEANING, id="content-update"),
    ],
)
def test_mutation_touches_only_requested_notebook(isolated_api, call, target_changed):
    seed = _seed(isolated_api)
    with patch.object(vocab_router_mod, "_embedding_store", return_value=_DummyEmbeddingStore()):
        r = call(isolated_api.client, isolated_api.headers, seed.notebook_id)
    assert r.status_code == 200, r.text

    default = seed.cards.get(seed.default_id)
    assert not default.is_deleted and not default.is_archived
    assert default.meaning == DEFAULT_MEANING
    assert target_changed(seed.cards.get(seed.nb_id))


def test_lookup_returns_card_of_requested_notebook(isolated_api):
    seed = _seed(isolated_api)
    r = _lookup(isolated_api.client, isolated_api.headers, seed.notebook_id)
    assert r.status_code == 200, r.text
    assert r.json()["meaning"] == NB_MEANING

    r = _lookup(isolated_api.client, isolated_api.headers, "default")
    assert r.status_code == 200, r.text
    assert r.json()["meaning"] == DEFAULT_MEANING
