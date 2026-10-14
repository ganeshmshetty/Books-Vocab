from __future__ import annotations

import logging
import sqlite3
import threading
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import kg.quota_service as qs
from kg.api_models import VocabEntry
from kg.exceptions import QuotaExceededError
from kg.vocab_handlers.intake import add_vocab_response


class _Cards:
    def __init__(self) -> None:
        self.add_calls: list[dict] = []

    def all(self, include_deleted: bool = False, notebook_id: str | None = None) -> list:
        return []

    def find_by_contents(self, keys, notebook_id: str | None = None) -> dict:
        return {}

    def add(self, **kwargs):
        self.add_calls.append(kwargs)
        return _Card("c1", kwargs["content"], kwargs["meaning"])

    def get(self, card_id: str):
        if card_id == "c1" and self.add_calls:
            last = self.add_calls[-1]
            return _Card("c1", last["content"], last["meaning"])
        return None


class _Card:
    def __init__(self, card_id: str, content: str, meaning: str) -> None:
        self.id = card_id
        self.content = content
        self.meaning = meaning

    def embed_text(self) -> str:
        return f"{self.content}: {self.meaning}"


@pytest.fixture
def mock_quota_db():
    conn = sqlite3.connect(":memory:", check_same_thread=False)
    conn.execute(
        """
        CREATE TABLE token_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            call_type TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            provider TEXT,
            model TEXT
        )
        """
    )
    conn.commit()
    lock = threading.Lock()
    with patch("kg.quota_service._get_conn", return_value=conn), patch("kg.quota_service._lock", lock):
        yield conn
    conn.close()


def test_add_vocab_blocks_before_any_write_when_embed_quota_exhausted(mock_quota_db):
    cards = _Cards()
    embedding_factory_calls: list[Path] = []
    graph_factory_calls: list[Path] = []

    def embedding_store_factory(path: Path, **kwargs):
        embedding_factory_calls.append(path)
        return MagicMock()

    def graph_store_factory(path: Path, **kwargs):
        graph_factory_calls.append(path)
        return MagicMock()

    qs.clear_reservations()
    qs.configure_limits(pro=0.30, free=0.0)
    try:
        with pytest.raises(QuotaExceededError):
            add_vocab_response(
                [VocabEntry(word="alpha", translation="阿爾法")],
                {"id": "u_vocab_quota", "dir": Path("/tmp/u_vocab_quota"), "isPro": False},
                card_store_factory=lambda _path: cards,
                embedding_store_factory=embedding_store_factory,
                graph_store_factory=graph_store_factory,
                client_factory=lambda _provider: MagicMock(),
                logger=logging.getLogger("test_vocab_handler_quota"),
            )
    finally:
        qs.clear_reservations()
        qs.configure_limits(pro=0.30, free=0.03)

    assert cards.add_calls == []
    assert embedding_factory_calls == []
    assert graph_factory_calls == []


def test_add_vocab_outer_reservation_is_not_counted_twice_during_embedding(mock_quota_db):
    cards = _Cards()
    observed_reserved: list[float] = []

    class _Embeddings:
        def __init__(self) -> None:
            self.ids: set[str] = set()

        def has(self, card_id: str) -> bool:
            return card_id in self.ids

        def add_batch(self, items):
            observed_reserved.append(qs._reserved_usd("u_vocab_quota"))
            self.ids.update(card_id for card_id, _ in items)

    class _Graph:
        def __init__(self) -> None:
            self.pending: list[str] = []

        def add_pending_judge(self, card_ids):
            self.pending.extend(card_ids)

    qs.clear_reservations()
    qs.configure_limits(pro=0.30, free=0.00075)
    try:
        response = add_vocab_response(
            [VocabEntry(word="alpha", translation="阿爾法")],
            {"id": "u_vocab_quota", "dir": Path("/tmp/u_vocab_quota"), "isPro": False},
            card_store_factory=lambda _path: cards,
            embedding_store_factory=lambda _path, **_kwargs: _Embeddings(),
            graph_store_factory=lambda _path, **_kwargs: _Graph(),
            client_factory=lambda _provider: MagicMock(),
            logger=logging.getLogger("test_vocab_handler_quota"),
        )
    finally:
        qs.clear_reservations()
        qs.configure_limits(pro=0.30, free=0.03)

    assert response.created == 1
    assert observed_reserved == [pytest.approx(qs.estimate_call_cost("embed"))]
