"""Tests for kg.vocab_intake — add_vocab_entries + private helpers.

Covers branches not already exercised by test_vocab_service.py /
test_cards.py:
  * _build_example: word in context / alternative match / no match /
    pre-existing bold stripping / case-insensitive replace.
  * _derive_inflections: single-token vs phrase / missing root_form /
    lemminflect ImportError fallback / fallback when root is unknown.
  * add_vocab_entries: duplicate cardIds wiring / notebook scoping /
    skip when embedding API errors / VocabSource serialization /
    no-embedding when nothing created.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

import pytest

import test_notebook_api
from kg.api_models import VocabEntry, VocabSource
from kg.exceptions import ValidationError
from kg.text_utils import normalize_nfc_lower
from kg.vocab_intake import _build_example, _derive_inflections, add_vocab_entries

isolated_api = test_notebook_api.isolated_api  # reuse the real-app fixture


@dataclass
class _IntakeCard:
    id: str
    content: str
    meaning: str = "m"
    examples: list[str] = field(default_factory=list)
    root_form: str | None = None
    inflections: list[str] = field(default_factory=list)
    notebook_id: str = "default"
    source: str | None = None
    is_deleted: bool = False

    def embed_text(self) -> str:
        return f"{self.content}: {self.meaning}"


class _IntakeCardsStore:
    """Minimal cards-store double tracking notebook scope and add() kwargs."""

    def __init__(self, preload: list[_IntakeCard] | None = None) -> None:
        self._cards: list[_IntakeCard] = list(preload or [])
        self.add_calls: list[dict[str, Any]] = []
        self._counter = 0
        self.all_calls: list[str | None] = []
        self.lookup_calls: list[tuple[list[str], str | None]] = []

    def all(self, include_deleted: bool = False, notebook_id: str | None = None) -> list[_IntakeCard]:
        self.all_calls.append(notebook_id)
        return [c for c in self._cards if c.notebook_id == notebook_id and (include_deleted or not c.is_deleted)]

    def find_by_contents(self, keys: Any, notebook_id: str | None = None) -> dict[str, _IntakeCard]:
        self.lookup_calls.append((list(keys), notebook_id))
        wanted = set(keys)
        found: dict[str, _IntakeCard] = {}
        for c in self._cards:
            key = normalize_nfc_lower(c.content)
            if key in wanted and not c.is_deleted and (notebook_id is None or c.notebook_id == notebook_id):
                found.setdefault(key, c)
        return found

    def add(self, **kwargs: Any) -> _IntakeCard:
        self.add_calls.append(kwargs)
        self._counter += 1
        card = _IntakeCard(
            id=f"id_{self._counter}",
            content=kwargs["content"],
            meaning=kwargs["meaning"],
            examples=list(kwargs.get("examples") or []),
            root_form=kwargs.get("root_form"),
            inflections=list(kwargs.get("inflections") or []),
            notebook_id=kwargs.get("notebook_id", "default"),
            source=kwargs.get("source"),
        )
        self._cards.append(card)
        return card

    def delete(self, card_id: str) -> bool:
        card = self.get(card_id)
        if card is None or card.is_deleted:
            return False
        card.is_deleted = True
        return True

    def get(self, card_id: str) -> _IntakeCard | None:
        for c in self._cards:
            if c.id == card_id:
                return c
        return None


class _IntakeEmbeddings:
    def __init__(self, *, fail: bool = False) -> None:
        self.added: list[tuple[str, str]] = []
        self.fail = fail

    def has(self, card_id: str) -> bool:
        return any(cid == card_id for cid, _ in self.added)

    def add_batch(self, items: list[tuple[str, str]]) -> None:
        if self.fail:
            raise OSError("simulated disk failure")
        self.added.extend(items)


class _IntakeGraph:
    def __init__(self) -> None:
        self.pending: list[str] = []

    def add_pending_judge(self, card_ids: list[str]) -> None:
        self.pending.extend(card_ids)


def _silent_logger() -> logging.Logger:
    log = logging.getLogger("intake_test")
    log.addHandler(logging.NullHandler())
    return log


# --------------------------------------------------------------------- #
# _build_example
# --------------------------------------------------------------------- #
class TestBuildExample:
    def test_empty_context_returns_empty(self):
        assert _build_example("run", "") == ""

    def test_wraps_exact_word(self):
        assert _build_example("run", "I run fast") == "I **run** fast"

    def test_case_insensitive_match_normalises_word_case(self):
        # Match is case-insensitive and the context's original casing is kept.
        assert _build_example("run", "Run forward") == "**Run** forward"

    def test_replaces_only_first_occurrence(self):
        out = _build_example("run", "run run run")
        assert out == "**run** run run"

    def test_strips_existing_bold_before_wrapping(self):
        # Pre-existing ** must not produce **double bold**.
        out = _build_example("run", "I **run** fast")
        assert out == "I **run** fast"
        assert "****" not in out

    def test_falls_back_to_alternative_inflection(self):
        # Word not present but an alternative (e.g. lemma) is — wrap that.
        out = _build_example("ran", "He runs daily", alternatives=["runs"])
        assert out == "He **runs** daily"

    def test_keeps_client_marker_on_target(self):
        assert _build_example("art", "She started to love **art**.") == "She started to love **art**."
        assert _build_example("on", "Once upon a time, he sat **on** it.") == "Once upon a time, he sat **on** it."

    def test_no_marker_respects_word_boundary(self):
        assert _build_example("art", "She started to love art.") == "She started to love **art**."

    def test_sentence_initial_casing_kept(self):
        assert _build_example("once", "Once upon a time.") == "**Once** upon a time."

    def test_ligature_context_is_nfkc_normalised(self):
        out = _build_example("finance", "Personal \ufb01nance matters.")
        assert out == "Personal **finance** matters."

    def test_fullwidth_context(self):
        out = _build_example("art", "She loves \uff41\uff52\uff54.")
        assert out == "She loves **art**."

    def test_multiple_spans_fall_through_to_search(self):
        out = _build_example("art", "The **start** of **art** here.")
        assert out == "The start of **art** here."

    def test_mismatched_marker_falls_through_to_search(self):
        out = _build_example("art", "I started **love** art.")
        assert out == "I started love **art**."

    def test_alternatives_use_word_boundaries(self):
        out = _build_example("ran", "He started running, he runs daily", alternatives=["run", "runs"])
        assert out == "He started running, he **runs** daily"

    def test_returns_context_unchanged_when_no_match(self):
        out = _build_example("ran", "She walks daily", alternatives=["run"])
        assert out == "She walks daily"


# --------------------------------------------------------------------- #
# _derive_inflections
# --------------------------------------------------------------------- #
class TestDeriveInflections:
    def test_phrase_returns_no_inflections(self):
        root, infl = _derive_inflections("ad hoc", "ad hoc", logger=_silent_logger())
        assert root is None
        assert infl == []

    def test_missing_root_form_returns_none(self):
        root, infl = _derive_inflections("running", None, logger=_silent_logger())
        assert root is None
        assert infl == []

    def test_blank_root_form_returns_none(self):
        root, infl = _derive_inflections("running", "   ", logger=_silent_logger())
        assert root is None
        assert infl == []

    def test_lemminflect_import_failure_is_swallowed(self, monkeypatch):
        """If lemminflect cannot import, function must return root + [] (no raise)."""
        import builtins

        real_import = builtins.__import__

        def fake_import(name: str, *a, **kw):
            if name == "lemminflect":
                raise ImportError("simulated")
            return real_import(name, *a, **kw)

        monkeypatch.setattr(builtins, "__import__", fake_import)
        root, infl = _derive_inflections("running", "run", logger=_silent_logger())
        assert root == "run"
        assert infl == []

    def test_unknown_lemma_falls_back_to_word(self, monkeypatch):
        """When lemminflect returns empty for the root, fall back to word."""
        calls: list[str] = []

        def fake_get_all(lemma: str):
            calls.append(lemma)
            if lemma == "qzqzqz":
                return {}  # unknown root
            return {"VBZ": ("studies",), "VBD": ("studied",)}

        import sys
        import types

        fake_mod = types.ModuleType("lemminflect")
        fake_mod.getAllInflections = fake_get_all  # type: ignore[attr-defined]
        monkeypatch.setitem(sys.modules, "lemminflect", fake_mod)

        root, infl = _derive_inflections("study", "qzqzqz", logger=_silent_logger())
        # Fallback path: root replaced by word.lower(), second lookup runs.
        assert root == "study"
        assert "studies" in infl and "studied" in infl
        assert calls == ["qzqzqz", "study"]

    def test_unknown_lemma_log_does_not_leak_user_text(self, monkeypatch, caplog):
        """WARNING logs become Sentry breadcrumbs; they must not carry the user's word/root (#2823)."""
        import sys
        import types

        fake_mod = types.ModuleType("lemminflect")
        fake_mod.getAllInflections = lambda lemma: {} if lemma == "secretroot" else {"VBZ": ("x",)}  # type: ignore[attr-defined]
        monkeypatch.setitem(sys.modules, "lemminflect", fake_mod)
        with caplog.at_level(logging.DEBUG):
            _derive_inflections("secretword", "secretroot", logger=logging.getLogger("test.intake"))
        assert caplog.records
        assert all("secretword" not in r.getMessage() and "secretroot" not in r.getMessage() for r in caplog.records)

    def test_lemminflect_failure_log_does_not_leak_user_text(self, monkeypatch, caplog):
        import sys
        import types

        def boom(lemma: str):
            raise ValueError("bad")

        fake_mod = types.ModuleType("lemminflect")
        fake_mod.getAllInflections = boom  # type: ignore[attr-defined]
        monkeypatch.setitem(sys.modules, "lemminflect", fake_mod)
        with caplog.at_level(logging.DEBUG):
            _derive_inflections("secretword", "secretroot", logger=logging.getLogger("test.intake"))
        assert caplog.records
        assert all("secretroot" not in r.getMessage() and "secretword" not in r.getMessage() for r in caplog.records)


# --------------------------------------------------------------------- #
# add_vocab_entries
# --------------------------------------------------------------------- #
class TestAddVocabEntries:
    def _kwargs(self, cards=None, embeddings=None, graph=None):
        return dict(
            user={"id": "u1"},
            cards=cards or _IntakeCardsStore(),
            embeddings=embeddings or _IntakeEmbeddings(),
            graph=graph or _IntakeGraph(),
            logger=_silent_logger(),
        )

    def test_duplicate_still_returned_in_card_ids(self):
        existing = _IntakeCard(id="dup1", content="hello")
        store = _IntakeCardsStore(preload=[existing])
        entries = [VocabEntry(word="hello", translation="你好", context="hello world")]

        result = add_vocab_entries(entries, **self._kwargs(cards=store))

        assert result.created == 0
        assert result.skipped == 1
        assert result.duplicates == ["hello"]
        # Caller relies on cardIds even for duplicates so the client can link
        # back to the existing card.
        assert result.cardIds == {"hello": "dup1"}

    @pytest.mark.parametrize("word", [".", "   "])
    def test_cleaned_empty_word_is_rejected_before_persistence(self, word):
        store = _IntakeCardsStore()
        embeddings = _IntakeEmbeddings()
        graph = _IntakeGraph()

        with pytest.raises(ValidationError) as exc_info:
            add_vocab_entries(
                [VocabEntry(word=word, translation="ignored", context="")],
                **self._kwargs(cards=store, embeddings=embeddings, graph=graph),
            )

        assert exc_info.value.status_code == 422
        assert store.add_calls == []
        assert store.all_calls == []
        assert store._cards == []
        assert embeddings.added == []
        assert graph.pending == []

    def test_response_card_ids_keyed_by_original_submitted_word(self):
        """Response cardIds/duplicates 用 client 送出的『原始』word 當 key,而非清洗後的。

        sync 配對 bug 根因:client 上傳 "chateau,"(未清洗),後端清成 "chateau" 存庫;
        若 response 用 "chateau" 當 key,iOS 拿 entry.word="chateau," 永遠 cardIds 查無 →
        卡在佇列。key 改回原始 word 後,client 用自己送出的字串配對必中,無須鏡像清洗邏輯。
        """
        store = _IntakeCardsStore()
        entries = [VocabEntry(word="chateau,", translation="莊園", context="this chateau, ...")]

        result = add_vocab_entries(entries, **self._kwargs(cards=store))

        assert result.created == 1
        # 存庫仍是清洗後的內容
        assert store.add_calls[0]["content"] == "chateau"
        # 但 response 用原始 submitted word 當 key（client 用 entry.word 配對必中）
        assert result.cardIds == {"chateau,": "id_1"}

    def test_duplicate_response_keyed_by_original_word(self):
        """重複情況也用原始 word —— 否則 duplicate 永遠無法在 client 端出列。"""
        existing = _IntakeCard(id="dup1", content="chateau")  # 已是清洗後存庫形
        store = _IntakeCardsStore(preload=[existing])
        entries = [VocabEntry(word="chateau,", translation="莊園", context="")]

        result = add_vocab_entries(entries, **self._kwargs(cards=store))

        assert result.created == 0
        assert result.skipped == 1
        assert result.duplicates == ["chateau,"]
        assert result.cardIds == {"chateau,": "dup1"}

    def test_same_batch_duplicate_gets_card_id_for_original_word(self):
        """A duplicate created earlier in the same request must still return a card id.

        iOS removes pending + add entries by looking up cardIds[entry.word].
        If the second same-batch duplicate lacks a card id, it remains stuck in
        the pending queue even though the server already created the card.
        """
        store = _IntakeCardsStore()
        entries = [
            VocabEntry(word="Hello.", translation="你好", context=""),
            VocabEntry(word="hello", translation="你好", context=""),
        ]

        result = add_vocab_entries(entries, **self._kwargs(cards=store))

        assert result.created == 1
        assert result.skipped == 1
        assert result.duplicates == ["hello"]
        assert result.cardIds == {"Hello.": "id_1", "hello": "id_1"}
        assert len(store.add_calls) == 1

    def test_notebook_scope_threads_through(self):
        # Same word lives in another notebook — must NOT be treated as duplicate
        # because the keyed lookup is called with the notebook_id filter.
        store = _IntakeCardsStore(preload=[_IntakeCard(id="other", content="hello", notebook_id="nb_other")])
        entries = [VocabEntry(word="hello", translation="你好", context="")]

        result = add_vocab_entries(entries, notebook_id="nb_target", **self._kwargs(cards=store))

        assert result.created == 1
        assert store.lookup_calls == [(["hello"], "nb_target")]
        assert store.all_calls == []
        assert store.add_calls[0]["notebook_id"] == "nb_target"

    def test_no_embedding_when_nothing_created(self):
        existing = _IntakeCard(id="x", content="cat")
        store = _IntakeCardsStore(preload=[existing])
        embeddings = _IntakeEmbeddings()
        graph = _IntakeGraph()

        result = add_vocab_entries(
            [VocabEntry(word="cat", translation="貓", context="")],
            **self._kwargs(cards=store, embeddings=embeddings, graph=graph),
        )

        assert result.created == 0
        assert embeddings.added == []
        assert graph.pending == []

    def test_embedding_failure_is_swallowed(self):
        """vocab_graph.embed_and_link_new_cards catches OSError — must not bubble."""
        store = _IntakeCardsStore()
        embeddings = _IntakeEmbeddings(fail=True)
        graph = _IntakeGraph()

        result = add_vocab_entries(
            [VocabEntry(word="cat", translation="貓", context="")],
            **self._kwargs(cards=store, embeddings=embeddings, graph=graph),
        )

        assert result.created == 1
        # graph.add_pending_judge must NOT be called when batch_items fails.
        assert graph.pending == []

    def test_vocab_source_is_json_serialised(self):
        store = _IntakeCardsStore()
        src = VocabSource(type="book", title="Moby Dick", chapter="1")
        entries = [VocabEntry(word="whale", translation="鯨", context="", source=src)]

        add_vocab_entries(entries, **self._kwargs(cards=store))

        import json

        raw = store.add_calls[0]["source"]
        assert raw is not None
        payload = json.loads(raw)
        assert payload["type"] == "book"
        assert payload["title"] == "Moby Dick"

    def test_no_source_passes_none(self):
        store = _IntakeCardsStore()
        add_vocab_entries(
            [VocabEntry(word="dog", translation="狗", context="")],
            **self._kwargs(cards=store),
        )
        assert store.add_calls[0]["source"] is None

    def test_clean_content_lowercases_first_letter(self):
        """add_vocab_entries delegates to _clean_content — verify wired in."""
        store = _IntakeCardsStore()
        add_vocab_entries(
            [VocabEntry(word="Hello.", translation="你好", context="")],
            **self._kwargs(cards=store),
        )
        # Trailing "." stripped, leading "H" lowercased.
        assert store.add_calls[0]["content"] == "hello"

    def test_clean_content_preserves_mixed_case_word(self):
        store = _IntakeCardsStore()
        add_vocab_entries(
            [VocabEntry(word="PhD", translation="博士", context="")],
            **self._kwargs(cards=store),
        )
        assert store.add_calls[0]["content"] == "PhD"

    def test_pending_judge_only_for_successfully_embedded(self):
        store = _IntakeCardsStore()
        embeddings = _IntakeEmbeddings()
        graph = _IntakeGraph()

        add_vocab_entries(
            [VocabEntry(word="cat", translation="貓", context="")],
            **self._kwargs(cards=store, embeddings=embeddings, graph=graph),
        )

        assert len(embeddings.added) == 1
        assert graph.pending == [embeddings.added[0][0]]

    def test_word_mutated_by_clean_content_is_still_embedded(self):
        """Regression: a word that _clean_content rewrites (trailing punctuation
        / uppercase first char) must still be embedded + queued for judging.

        card_ids is keyed by the CLEANED word, so embed_and_link_new_cards must
        clean entry.word before looking it up — otherwise "Hello." stored as
        "hello" is silently never embedded nor linked into the graph.
        """
        store = _IntakeCardsStore()
        embeddings = _IntakeEmbeddings()
        graph = _IntakeGraph()

        result = add_vocab_entries(
            [VocabEntry(word="Hello.", translation="你好", context="")],
            **self._kwargs(cards=store, embeddings=embeddings, graph=graph),
        )

        assert result.created == 1
        # The stored card content is the cleaned form …
        assert store.add_calls[0]["content"] == "hello"
        # … and it MUST have been embedded + marked pending despite the rewrite.
        assert len(embeddings.added) == 1
        assert graph.pending == [embeddings.added[0][0]]


class TestNotebookDeletedDuringIntake:
    def test_failed_notebook_check_tombstones_only_new_cards_and_skips_embed(self):
        existing = _IntakeCard(id="dup1", content="old")
        store = _IntakeCardsStore(preload=[existing])
        embeddings = _IntakeEmbeddings()
        graph = _IntakeGraph()

        def gone() -> None:
            raise RuntimeError("Notebook access denied")

        entries = [
            VocabEntry(word="old", translation="舊", context=""),
            VocabEntry(word="fresh", translation="新", context=""),
        ]
        with pytest.raises(RuntimeError, match="Notebook access denied"):
            add_vocab_entries(
                entries,
                user={"id": "u1"},
                cards=store,
                embeddings=embeddings,
                graph=graph,
                logger=_silent_logger(),
                notebook_check=gone,
            )

        assert store.get("id_1").is_deleted is True
        assert existing.is_deleted is False
        assert embeddings.added == []
        assert graph.pending == []


def test_post_vocab_notebook_deleted_mid_call_returns_403_and_tombstones_cards(isolated_api, monkeypatch):
    import kg.vocab_intake as intake
    from kg.cards import CardStore
    from kg.notebook import NotebookStore

    user_dir = isolated_api.data_dir / "users" / isolated_api.user_id
    notebooks = NotebookStore(user_dir / "notebooks.db")
    nb = notebooks.create("Racy")
    real_derive = intake._derive_inflections

    def derive_then_delete(*args, **kwargs):
        notebooks.delete(nb.id)  # notebook removed after validate_notebook_access
        return real_derive(*args, **kwargs)

    monkeypatch.setattr(intake, "_derive_inflections", derive_then_delete)
    try:
        response = isolated_api.client.post(
            "/api/vocab",
            json=[{"word": "apple", "translation": "蘋果"}],
            params={"notebook_id": nb.id},
            headers=isolated_api.headers,
        )
        assert response.status_code == 403, response.text
        assert response.json()["detail"] == "Notebook access denied"

        cards = CardStore(user_dir / "cards.db")
        rows = [c for c in cards.all(include_deleted=True) if c.notebook_id == nb.id]
        assert [c.content for c in rows] == ["apple"]
        assert all(c.is_deleted for c in rows)  # tombstone, not hard delete
    finally:
        notebooks.close()
