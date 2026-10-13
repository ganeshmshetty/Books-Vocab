from __future__ import annotations

import asyncio
from pathlib import Path
from types import SimpleNamespace

import pytest

from kg.vocab_add_link_operation import (
    STEP_IDS,
    IdempotencyConflict,
    create_operation,
    get_operation,
    operation_response,
    run_add_link_operation,
)


@pytest.fixture(autouse=True)
def isolated_operation_db(tmp_path, monkeypatch):
    import kg.vocab_add_link_operation as operations

    monkeypatch.setenv("KG_DATA_DIR", str(tmp_path))
    operations.reset()
    yield
    operations.reset()


def payload(word: str = "luminous", translation: str | None = None) -> dict:
    return {
        "from_id": "source-card",
        "target_word": word,
        "translation": translation,
        "context": "a luminous room",
        "source": None,
        "source_lang": "en",
        "target_lang": "zh-Hant",
    }


class Cards:
    def __init__(self, source, target=None):
        self.items = {source.id: source}
        if target is not None:
            self.items[target.id] = target
        self.added = []
        self.updated = []
        self.deleted = []

    def get(self, card_id):
        return self.items.get(card_id)

    def find_by_content(self, content, notebook_id=None):
        return next(
            (
                card
                for card in self.items.values()
                if card.content.casefold() == content.casefold()
                and (notebook_id is None or card.notebook_id == notebook_id)
            ),
            None,
        )

    def add(self, **kwargs):
        card = SimpleNamespace(
            id=f"target-{len(self.added) + 1}",
            content=kwargs["content"],
            meaning=kwargs["meaning"],
            pos=kwargs.get("pos"),
            note=None,
            collocations=[],
            examples=kwargs.get("examples", []),
            notebook_id=kwargs.get("notebook_id", "default"),
            is_archived=False,
            is_deleted=False,
        )
        self.items[card.id] = card
        self.added.append(card)
        return card

    def batch_update(self, updates):
        self.updated.extend(updates)
        return len(updates)

    def delete(self, card_id):
        card = self.items.get(card_id)
        if card is None or card.is_deleted:
            return False
        card.is_deleted = True
        self.deleted.append(card_id)
        return True


class Graph:
    def __init__(self):
        self.links = []

    def find_link_between(self, from_id, to_id):
        return next(
            (link for link in self.links if {link.from_id, link.to_id} == {from_id, to_id}),
            None,
        )


class AsyncLock:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False


def user():
    return {"id": "user-1", "dir": Path("/tmp/user-1"), "record": {}, "config": {}}


def run(operation_id, cards, graph, **kwargs):
    asyncio.run(
        run_add_link_operation(
            operation_id,
            user(),
            card_store_factory=lambda _: cards,
            graph_store_factory=lambda *_args, **_kwargs: graph,
            get_user_lock_fn=lambda _uid: AsyncLock(),
            **kwargs,
        )
    )


def test_idempotency_and_request_conflict():
    first, created = create_operation(
        user_id="user-1", notebook_id="default", idempotency_key="tap-1", payload=payload()
    )
    assert created is True
    assert first["status"] == "queued"
    assert [step["id"] for step in first["steps"]] == list(STEP_IDS)

    replay, replay_created = create_operation(
        user_id="user-1", notebook_id="default", idempotency_key="tap-1", payload=payload()
    )
    assert replay_created is False
    assert replay["operation_id"] == first["operation_id"]

    with pytest.raises(IdempotencyConflict):
        create_operation(
            user_id="user-1",
            notebook_id="default",
            idempotency_key="tap-1",
            payload=payload("different"),
        )


def test_missing_target_translates_enriches_and_links_once():
    source = SimpleNamespace(
        id="source-card",
        content="source",
        meaning="來源",
        notebook_id="default",
        is_deleted=False,
        is_archived=False,
    )
    cards = Cards(source)
    graph = Graph()
    calls = []

    async def translate(**_kwargs):
        calls.append("translate")
        return SimpleNamespace(t="發光的", p="adj.", r="luminous")

    async def enrich(**_kwargs):
        calls.append("enrich")

    def link(**kwargs):
        calls.append("link")
        result = SimpleNamespace(id="link-1", from_id=kwargs["from_id"], to_id=kwargs["to_id"], status="active")
        graph.links.append(result)
        return result

    operation, _ = create_operation(user_id="user-1", notebook_id="default", idempotency_key="tap-2", payload=payload())
    run(operation["operation_id"], cards, graph, translate_fn=translate, enrich_fn=enrich, link_fn=link)

    result = get_operation("user-1", operation["operation_id"])
    assert result["status"] == "succeeded"
    assert calls == ["translate", "enrich", "link"]
    assert result["target_card_id"] == "target-1"
    assert result["link_id"] == "link-1"
    assert cards.added[0].examples == []

    # A retry/re-entry is a no-op after the durable terminal state.
    run(operation["operation_id"], cards, graph, translate_fn=translate, enrich_fn=enrich, link_fn=link)
    assert len(cards.added) == 1
    assert calls == ["translate", "enrich", "link"]


def test_existing_target_skips_translation_and_enrichment():
    source = SimpleNamespace(
        id="source-card",
        content="source",
        meaning="來源",
        notebook_id="default",
        is_deleted=False,
        is_archived=False,
    )
    target = SimpleNamespace(
        id="target-card",
        content="luminous",
        meaning="明亮的",
        notebook_id="default",
        is_deleted=False,
        is_archived=False,
    )
    cards = Cards(source, target)
    graph = Graph()
    calls = []

    async def translate(**_kwargs):
        calls.append("translate")
        return SimpleNamespace(t="明亮的")

    async def enrich(**_kwargs):
        calls.append("enrich")

    def link(**kwargs):
        calls.append("link")
        return SimpleNamespace(id="link-existing", from_id=kwargs["from_id"], to_id=kwargs["to_id"], status="active")

    operation, _ = create_operation(user_id="user-1", notebook_id="default", idempotency_key="tap-3", payload=payload())
    run(operation["operation_id"], cards, graph, translate_fn=translate, enrich_fn=enrich, link_fn=link)

    result = get_operation("user-1", operation["operation_id"])
    assert result["status"] == "succeeded"
    assert calls == ["link"]
    assert result["target_card_id"] == "target-card"


def test_enrichment_failure_is_pollable_warning_but_does_not_block_link():
    source = SimpleNamespace(
        id="source-card",
        content="source",
        meaning="來源",
        notebook_id="default",
        is_deleted=False,
        is_archived=False,
    )
    cards = Cards(source)
    graph = Graph()

    async def translate(**_kwargs):
        return SimpleNamespace(t="發光的", p="adj.", r="luminous")

    async def enrich(**_kwargs):
        raise TimeoutError("upstream")

    def link(**kwargs):
        result = SimpleNamespace(id="link-2", from_id=kwargs["from_id"], to_id=kwargs["to_id"], status="active")
        graph.links.append(result)
        return result

    operation, _ = create_operation(user_id="user-1", notebook_id="default", idempotency_key="tap-4", payload=payload())
    run(operation["operation_id"], cards, graph, translate_fn=translate, enrich_fn=enrich, link_fn=link)

    result = get_operation("user-1", operation["operation_id"])
    assert result["status"] == "succeeded_with_warnings"
    assert "enrichment_failed" in result["warnings"]
    assert result["link_id"] == "link-2"


def test_cancellation_interrupts_running_operation_and_current_step():
    source = SimpleNamespace(
        id="source-card",
        content="source",
        meaning="來源",
        notebook_id="default",
        is_deleted=False,
        is_archived=False,
    )
    cards = Cards(source)
    graph = Graph()
    translate_started = asyncio.Event()
    allow_translate = asyncio.Event()

    async def translate(**_kwargs):
        translate_started.set()
        await allow_translate.wait()
        return SimpleNamespace(t="發光的", p="adj.", r="luminous")

    operation, _ = create_operation(
        user_id="user-1", notebook_id="default", idempotency_key="tap-cancel", payload=payload()
    )

    async def exercise_cancellation():
        task = asyncio.create_task(
            run_add_link_operation(
                operation["operation_id"],
                user(),
                card_store_factory=lambda _: cards,
                graph_store_factory=lambda *_args, **_kwargs: graph,
                get_user_lock_fn=lambda _uid: AsyncLock(),
                translate_fn=translate,
            )
        )
        await translate_started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    asyncio.run(exercise_cancellation())

    result = get_operation("user-1", operation["operation_id"])
    assert result["status"] == "interrupted"
    assert result["ended_at"] is not None
    assert result["error_code"] == "interrupted"
    translate_step = next(step for step in result["steps"] if step["id"] == "translate")
    assert translate_step["status"] == "error"
    assert translate_step["detail_code"] == "interrupted"
    assert get_operation("user-1", operation["operation_id"])["status"] != "running"
    # The interrupted record must stay serializable on the poll surface.
    wire = operation_response(result)
    assert wire.status == "interrupted"
    assert wire.errorCode == "interrupted"


def _card(card_id, content, **overrides):
    return SimpleNamespace(
        **{
            "id": card_id,
            "content": content,
            "meaning": f"{content}-meaning",
            "notebook_id": "default",
            "is_deleted": False,
            "is_archived": False,
            **overrides,
        }
    )


def _failed_operation(cards, *, key, word="luminous", **kwargs):
    operation, _ = create_operation(user_id="user-1", notebook_id="default", idempotency_key=key, payload=payload(word))
    run(operation["operation_id"], cards, Graph(), **kwargs)
    result = get_operation("user-1", operation["operation_id"])
    assert result["status"] == "failed"
    return result


def test_archived_target_reports_distinct_error_code():
    cards = Cards(_card("source-card", "source"), _card("target-card", "luminous", is_archived=True))

    result = _failed_operation(cards, key="tap-archived")

    assert result["error_code"] == "target_archived"
    assert operation_response(result).errorCode == "target_archived"


def test_target_equal_to_source_reports_distinct_error_code():
    cards = Cards(_card("source-card", "luminous"))

    result = _failed_operation(cards, key="tap-self")

    assert result["error_code"] == "target_is_source"


def test_unavailable_source_is_not_reported_as_target_unavailable():
    cards = Cards(_card("source-card", "source", is_archived=True))

    result = _failed_operation(cards, key="tap-source-gone")

    assert result["error_code"] == "source_unavailable"


def test_unexpected_target_resolution_failure_stays_target_unavailable():
    class BrokenCards(Cards):
        def find_by_content(self, *_args, **_kwargs):
            raise RuntimeError("store down")

    result = _failed_operation(BrokenCards(_card("source-card", "source")), key="tap-broken")

    assert result["error_code"] == "target_unavailable"


def test_enrichment_is_never_an_operation_error_code():
    # Enrichment failures are non-fatal warnings; even an unexpected exception
    # attributed to the enrich step must not surface as the terminal errorCode
    # (iOS reads enrichment_failed as "partially synced", not as a failure).
    from kg.vocab_add_link_operation import _error_code

    assert _error_code("enrich", RuntimeError("boom")) != "enrichment_failed"


def _seed_operation(key, *, status, user_id="user-1", running_step=None):
    import kg.vocab_add_link_operation as operations

    operation, _ = create_operation(user_id=user_id, notebook_id="default", idempotency_key=key, payload=payload())
    operation_id = operation["operation_id"]
    if running_step:
        operations.update_step(operation_id, running_step, status="running")
    if status == "running":
        operations.start_operation(operation_id)
    elif status != "queued":
        operations.finish_operation(operation_id, status=status)
    return operation_id


def test_restart_marks_non_terminal_operations_interrupted(tmp_path):
    import kg.vocab_add_link_operation as operations

    queued = _seed_operation("restart-queued", status="queued")
    running = _seed_operation("restart-running", status="running", running_step="translate")
    other_user = _seed_operation("restart-other-user", status="running", user_id="user-2")
    done = _seed_operation("restart-done", status="succeeded")
    failed = _seed_operation("restart-failed", status="failed")
    before_running = get_operation("user-1", running)
    operations.reset()  # simulate process restart: only SQLite survives

    assert operations.reap_interrupted_operations(tmp_path) == 3

    for operation_id, user_id in ((queued, "user-1"), (running, "user-1"), (other_user, "user-2")):
        record = get_operation(user_id, operation_id)
        assert record["status"] == "interrupted"
        assert record["error_code"] == "interrupted"
        assert record["ended_at"] is not None
        assert operation_response(record).errorCode == "interrupted"
    after_running = get_operation("user-1", running)
    assert after_running["sequence"] > before_running["sequence"]
    translate_step = next(step for step in after_running["steps"] if step["id"] == "translate")
    assert (translate_step["status"], translate_step["detail_code"]) == ("error", "interrupted")
    assert get_operation("user-1", done)["status"] == "succeeded"
    assert get_operation("user-1", failed)["status"] == "failed"
    assert get_operation("user-1", failed)["error_code"] is None


def test_restart_reaping_is_idempotent_and_a_noop_when_clean(tmp_path):
    import kg.vocab_add_link_operation as operations

    assert operations.reap_interrupted_operations(tmp_path) == 0
    _seed_operation("idem-running", status="running")
    assert operations.reap_interrupted_operations(tmp_path) == 1
    assert operations.reap_interrupted_operations(tmp_path) == 0


def test_interrupted_operation_is_not_resumed_by_late_runner(tmp_path):
    import kg.vocab_add_link_operation as operations

    operation_id = _seed_operation("late-runner", status="queued")
    operations.reap_interrupted_operations(tmp_path)
    cards = Cards(_card("source-card", "source"))

    run(operation_id, cards, Graph(), translate_fn=lambda **_k: pytest.fail("must not run"))

    assert get_operation("user-1", operation_id)["status"] == "interrupted"
    assert cards.added == []


def test_delete_for_users_is_scoped_idempotent_and_handles_empty():
    import kg.vocab_add_link_operation as operations

    for uid in ("gone", "linked", "keep"):
        operations.create_operation(user_id=uid, notebook_id="nb", idempotency_key="k", payload=payload())

    assert operations.delete_for_users([]) == 0
    assert operations.delete_for_users(["gone", "linked", "gone"]) == 2
    assert operations.delete_for_users(["gone"]) == 0
    with operations._lock:
        rows = operations._get_conn().execute("SELECT user_id FROM vocab_add_link_operations").fetchall()
    assert [r[0] for r in rows] == ["keep"]


class _NotebookStore:
    def __init__(self):
        self.alive = True

    def exists(self, _notebook_id):
        return self.alive

    def ensure_default(self):
        return None


def _race_source(notebook_id):
    return SimpleNamespace(
        id="source-card",
        content="source",
        meaning="來源",
        notebook_id=notebook_id,
        is_deleted=False,
        is_archived=False,
    )


def _run_race(cards, notebooks, **kwargs):
    operation, _ = create_operation(user_id="user-1", notebook_id="nb-x", idempotency_key="race", payload=payload())
    run(operation["operation_id"], cards, Graph(), notebook_store_factory=lambda _dir: notebooks, **kwargs)
    return get_operation("user-1", operation["operation_id"])


def test_notebook_deleted_during_translate_fails_without_orphan_card():
    cards = Cards(_race_source("nb-x"))
    notebooks = _NotebookStore()
    calls = []

    async def translate(**_kwargs):
        notebooks.alive = False  # notebook X is deleted while translation is in flight
        return SimpleNamespace(t="發光的", p="adj.", r="luminous")

    async def enrich(**_kwargs):
        calls.append("enrich")

    result = _run_race(cards, notebooks, translate_fn=translate, enrich_fn=enrich)

    assert result["status"] == "failed"
    assert result["error_code"] == "notebook_unavailable"
    assert calls == []
    assert not [
        c for c in cards.items.values() if c.notebook_id == "nb-x" and c.id != "source-card" and not c.is_deleted
    ]


def test_notebook_deleted_during_card_write_tombstones_created_target():
    class RacingCards(Cards):
        def __init__(self, source, notebooks):
            super().__init__(source)
            self.notebooks = notebooks

        def add(self, **kwargs):
            card = super().add(**kwargs)
            self.notebooks.alive = False  # delete cascade ran right after this write
            return card

    notebooks = _NotebookStore()
    cards = RacingCards(_race_source("nb-x"), notebooks)
    calls = []

    async def translate(**_kwargs):
        return SimpleNamespace(t="發光的", p="adj.", r="luminous")

    async def enrich(**_kwargs):
        calls.append("enrich")

    result = _run_race(cards, notebooks, translate_fn=translate, enrich_fn=enrich)

    assert result["status"] == "failed"
    assert result["error_code"] == "notebook_unavailable"
    assert calls == []
    assert cards.deleted == ["target-1"]  # soft delete (tombstone), not a hard delete
    assert cards.items["target-1"].is_deleted is True


def test_link_persist_failure_is_failed_not_warning(tmp_path, monkeypatch):
    from kg.graph import GraphStore, LinkKind

    source = SimpleNamespace(
        id="source-card",
        content="source",
        meaning="來源",
        notebook_id="default",
        is_deleted=False,
        is_archived=False,
    )
    cards = Cards(source)
    graph = GraphStore(
        links_path=tmp_path / "links.json",
        candidates_path=tmp_path / "candidates.json",
        blocked_path=tmp_path / "blocked.json",
    )

    def boom(*_args, **_kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(graph, "_flush_links", boom)

    async def translate(**_kwargs):
        return SimpleNamespace(t="發光的", p="adj.", r="luminous")

    async def enrich(**_kwargs):
        return None

    def link(**kwargs):
        return graph.add_link(kwargs["from_id"], kwargs["to_id"], LinkKind.CONTRASTS_WITH, 0.9, "r")

    operation, _ = create_operation(user_id="user-1", notebook_id="default", idempotency_key="tap-5", payload=payload())
    run(operation["operation_id"], cards, graph, translate_fn=translate, enrich_fn=enrich, link_fn=link)

    result = get_operation("user-1", operation["operation_id"])
    assert result["status"] == "failed"
    assert not result.get("link_id")


def test_find_operation_replays_by_key_and_rejects_changed_payload():
    from kg.vocab_add_link_operation import find_operation

    assert find_operation(user_id="user-1", notebook_id="default", idempotency_key="tap-1", payload=payload()) is None
    first, _ = create_operation(user_id="user-1", notebook_id="default", idempotency_key="tap-1", payload=payload())

    found = find_operation(user_id="user-1", notebook_id="default", idempotency_key="tap-1", payload=payload())
    assert found is not None and found["operation_id"] == first["operation_id"]
    assert find_operation(user_id="user-2", notebook_id="default", idempotency_key="tap-1", payload=payload()) is None
    with pytest.raises(IdempotencyConflict):
        find_operation(user_id="user-1", notebook_id="default", idempotency_key="tap-1", payload=payload("different"))


def test_replay_with_another_notebook_conflicts_instead_of_returning_foreign_operation():
    first, created = create_operation(user_id="user-1", notebook_id="nb-a", idempotency_key="tap-nb", payload=payload())
    assert created is True

    with pytest.raises(IdempotencyConflict):
        create_operation(user_id="user-1", notebook_id="nb-b", idempotency_key="tap-nb", payload=payload())

    replay, replay_created = create_operation(
        user_id="user-1", notebook_id="nb-a", idempotency_key="tap-nb", payload=payload()
    )
    assert replay_created is False
    assert replay["operation_id"] == first["operation_id"]


def test_find_operation_rejects_replay_under_another_notebook():
    from kg.vocab_add_link_operation import find_operation

    first, _ = create_operation(user_id="user-1", notebook_id="nb-a", idempotency_key="tap-fo", payload=payload())

    found = find_operation(user_id="user-1", notebook_id="nb-a", idempotency_key="tap-fo", payload=payload())
    assert found is not None and found["operation_id"] == first["operation_id"]
    with pytest.raises(IdempotencyConflict):
        find_operation(user_id="user-1", notebook_id="nb-b", idempotency_key="tap-fo", payload=payload())


class _AddLinkMeaningCards:
    def __init__(self):
        self.updates: list[list[tuple[str, dict]]] = []

    def batch_update(self, updates):
        self.updates.append(list(updates))
        return len(updates)


class _AddLinkEmbeddings:
    def __init__(self):
        self.removed: list[str] = []

    def remove(self, card_id):
        self.removed.append(card_id)


class _AddLinkGraph:
    def __init__(self):
        self.queued: list[str] = []

    def add_pending_judge(self, card_id):
        self.queued.append(card_id)


def _run_default_enrich(monkeypatch, *, meaning_fix, embeddings=None, graph, open_embeddings=None, note=None):
    import logging
    from types import SimpleNamespace

    import kg.deps_quota as deps_quota
    import kg.enrich as enrich_mod
    import kg.llm.providers as providers
    import kg.tracked_llm as tracked_llm
    from kg.vocab_add_link_operation import _default_enrich

    result = {"word": "luminous", "meaning_fix": meaning_fix}
    if note is not None:
        result["note"] = note

    async def stream(llm, targets, **kwargs):
        yield {"status": "running", "results": [result]}

    monkeypatch.setattr(enrich_mod, "enrich_cards_stream", stream)
    monkeypatch.setattr(providers, "provider_for", lambda _task: SimpleNamespace(chat_model="m"))
    monkeypatch.setattr(tracked_llm, "TrackedLLM", lambda *_a, **_k: None)
    monkeypatch.setattr(deps_quota, "_is_pro", lambda _user: False)

    card = SimpleNamespace(id="t1", content="luminous", pos=None, note=None, meaning="旧")
    cards = _AddLinkMeaningCards()
    asyncio.run(
        _default_enrich(
            card=card,
            cards=cards,
            user={"id": "user-1", "dir": "/tmp/user-1"},
            client_factory=lambda _provider: None,
            logger=logging.getLogger("test_add_link_meaning"),
            open_embeddings=open_embeddings or (lambda: embeddings),
            graph=graph,
        )
    )
    return cards


def test_add_link_meaning_fix_evicts_vector_and_requeues_judging(monkeypatch):
    embeddings, graph = _AddLinkEmbeddings(), _AddLinkGraph()

    cards = _run_default_enrich(monkeypatch, meaning_fix="新", embeddings=embeddings, graph=graph)

    assert cards.updates == [[("t1", {"meaning": "新"})]]
    assert embeddings.removed == ["t1"]
    assert graph.queued == ["t1"]


def test_add_link_unchanged_meaning_fix_neither_evicts_nor_queues(monkeypatch):
    embeddings, graph = _AddLinkEmbeddings(), _AddLinkGraph()

    _run_default_enrich(monkeypatch, meaning_fix="旧", embeddings=embeddings, graph=graph)

    assert embeddings.removed == []
    assert graph.queued == []


def _broken_embedding_factory():
    raise RuntimeError("embedding store unavailable")


def test_add_link_unchanged_meaning_never_opens_embedding_store(monkeypatch):
    opened = []

    def open_embeddings():
        opened.append(True)
        return _broken_embedding_factory()

    cards = _run_default_enrich(
        monkeypatch, meaning_fix="旧", graph=_AddLinkGraph(), open_embeddings=open_embeddings, note="新注解"
    )

    assert opened == []
    assert cards.updates == [[("t1", {"note": "新注解", "meaning": "旧"})]]


def test_add_link_embedding_store_failure_keeps_other_enrich_fields(monkeypatch):
    graph = _AddLinkGraph()

    cards = _run_default_enrich(
        monkeypatch,
        meaning_fix="新",
        graph=graph,
        open_embeddings=_broken_embedding_factory,
        note="新注解",
    )

    assert cards.updates == [[("t1", {"meaning": "新", "note": "新注解"})]]
    assert graph.queued == []


class _CommitFailsOnce:
    """Proxy whose first commit raises; every other call delegates to the real connection."""

    def __init__(self, real):
        self._real = real
        self._armed = True

    def commit(self):
        if self._armed:
            self._armed = False
            import sqlite3

            raise sqlite3.OperationalError("simulated commit failure")
        self._real.commit()

    def __getattr__(self, name):
        return getattr(self._real, name)


def test_delete_for_users_rolls_back_when_commit_fails(monkeypatch):
    """A failed erasure must leave no open transaction on the shared connection."""
    import sqlite3

    import kg.vocab_add_link_operation as operations

    operations.create_operation(user_id="gone", notebook_id="nb", idempotency_key="k", payload=payload())
    real = operations._get_conn()
    proxy = _CommitFailsOnce(real)
    monkeypatch.setattr(operations, "_get_conn", lambda *a, **k: proxy)

    with pytest.raises(sqlite3.OperationalError):
        operations.delete_for_users(["gone"])

    assert real.in_transaction is False
    assert operations.delete_for_users(["gone"]) == 1
