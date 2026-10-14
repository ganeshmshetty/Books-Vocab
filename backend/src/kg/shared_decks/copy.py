"""Server-side copy of a shared deck into a copier's private Notebook (Phase 2).

Clones the official deck's **content plane** into fresh Cards in the copier's
``user_dir`` — never SRS, never an LLM call. Every load-bearing guardrail lives
here so the router stays a thin adapter:

* **new Notebook**: ``is_default`` forced false (model default), name made
  unique against the copier's active notebooks (the world-export duplicate-name
  trap), provenance (``source_shared_deck_id`` + ``source_version``) stamped.
* **ordinary-card copy**: verbatim content fields via
  ``CardStore.add_shared_copy``, model-default SRS, freshly-minted ids,
  **strictly-monotonic ``updated_at``** (§4.4 — a timestamp tie lets a keyset
  page boundary silently drop cards on sync-down), and
  ``source_shared_card_guid`` = the source card's ``content_guid``.
* **idempotency**: ``shared_deck_copy_log(copier_id, idempotency_key)`` UNIQUE —
  a transport retry replays to the same notebook, never a duplicate. Replay is
  keyed by the log alone, so it still works after the source is unpublished or
  hidden (#3898); the discoverability gate applies only to new copies.
* **materialization barrier + compensating rollback**: cards.db / notebooks.db
  have no cross-file transaction, so the notebook is staged HIDDEN and revealed
  only after the idempotency log commits. Any pre-commit failure compensates
  (tombstones the partial cards, removes the graph file, and only then the
  notebook row — the staged flag is the marker that keeps half-cleaned cards out
  of global pulls and lets a later sweep retry) and re-raises. The copy_log is
  the point of no return: written BEFORE reveal, so a crash in the reveal window
  self-heals — the retry finds the log and _replay finishes the reveal, never
  minting a duplicate.
* **reveal = flip + restamp + mark** (:func:`_reveal`): once the notebook is
  visible its cards are re-stamped (hidden-window pullers would otherwise skip
  them), then ``download_counted`` is committed. The marker is the durable
  "reveal complete" bit, so a crash at any point inside the reveal is redone
  whole by the retry, and a settled deck is never touched again.
* **reveal sweep (#3897)**: a reveal that raises after the point of no return
  leaves a durable copy with its marker unset, and the client may never retry
  the key. :func:`reveal_uncounted_copies` settles those rows at startup and
  every 5 minutes, under the same per-user lock as the request path.
* **count-equality**: copied distinct cards == source snapshot, else fail-loud
  (a NOCASE/NFC collapse under the card table's per-notebook uniqueness — e.g. a
  homograph pair distinct only by pos/meaning — must not silently drop a card).
* **graph links remap seam**: an official ``shared_deck_card`` is a pure content
  plane with ZERO inter-card links (§2), so remap is a structural no-op today;
  the old→new id map is still built so a future link-carrying schema flows
  through :func:`_remap_graph_links` unchanged. We do NOT synthesize links.
* **download_count**: exactly-once log-marked atomic increment (never Python
  get-then-set), so retries recover a finalizer crash without double-counting.
"""

from __future__ import annotations

import asyncio
import json
import logging
import threading
from collections import OrderedDict
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from ..cards import CardStore
from ..exceptions import ConflictError, NotFoundError
from ..notebook import NotebookStore
from .store import SharedDeckStore

_LOGGER = logging.getLogger(__name__)

_DEFAULT_TITLE = "Untitled Deck"


# Per-user copy serialization (see _user_copy_lock). LRU-bounded so a burst of
# distinct users cannot leak locks without limit — mirrors deps._USER_LOCKS.
_USER_COPY_LOCKS: OrderedDict[str, threading.Lock] = OrderedDict()
_USER_COPY_LOCKS_MUTEX = threading.Lock()
_MAX_USER_COPY_LOCKS = 500


def _user_copy_lock(user_dir: Path) -> threading.Lock:
    """Per-user serialization lock for the copy critical section.

    ``deps.get_user_lock`` is an ``asyncio.Lock`` serving the async pipeline; it
    cannot serialize the copy handler, which is a SYNC endpoint running in
    anyio's threadpool (concurrent same-user copies land on different threads).
    This is the faithful threading translation of that same per-user pattern:
    an LRU-bounded, mutex-guarded registry keyed by the user's dir (the mutated
    resource). ``move_to_end`` on access keeps an in-flight lock recently-used
    and eviction skips held locks (mirrors deps.get_user_lock).
    """
    key = str(Path(user_dir).resolve())
    with _USER_COPY_LOCKS_MUTEX:
        lock = _USER_COPY_LOCKS.get(key)
        if lock is None:
            lock = threading.Lock()
            _USER_COPY_LOCKS[key] = lock
            while len(_USER_COPY_LOCKS) > _MAX_USER_COPY_LOCKS:
                for candidate_key, candidate in _USER_COPY_LOCKS.items():
                    if not candidate.locked():
                        del _USER_COPY_LOCKS[candidate_key]
                        break
                else:
                    # Every lock is held: evicting one would hand its user a
                    # second lock. Let the cache exceed the cap temporarily.
                    break
        else:
            _USER_COPY_LOCKS.move_to_end(key)
        return lock


@dataclass(frozen=True)
class CopyOutcome:
    notebook_id: str
    notebook_name: str
    deck_id: str
    source_version: int
    card_count: int
    already_copied: bool


def _unique_notebook_name(notebook_store: NotebookStore, base: str) -> str:
    """Disambiguate ``base`` against the copier's ACTIVE notebook names.

    world-export fails loud on two same-named active notebooks (its name→id map
    can't tell them apart), so a second copy of the same deck must not reuse the
    title verbatim. The staged copy notebook is created hidden, so it never
    collides with itself here.
    """
    existing = {nb.name for nb in notebook_store.all()}
    if base not in existing:
        return base
    n = 2
    while f"{base} ({n})" in existing:
        n += 1
    return f"{base} ({n})"


def _remap_graph_links(
    user_dir: Path,
    notebook_id: str,
    *,
    source_links: Sequence[dict],
    id_map: dict[str, str],
) -> None:
    """Remap old→new card ids for any inter-card links the source deck carries,
    persisting ``graph_<nb>.json``.

    Official shared decks carry ZERO links (the ``shared_deck_card`` table is a
    pure content plane, §2), so ``source_links`` is always empty here and this is
    a structural no-op — no graph file is written. The seam exists so a future
    link-carrying deck schema flows through unchanged; DO NOT synthesize links
    for a link-less deck.
    """
    if not source_links:
        return
    remapped = [
        {**lk, "from_id": id_map[lk["from_id"]], "to_id": id_map[lk["to_id"]]}
        for lk in source_links
        if lk.get("from_id") in id_map and lk.get("to_id") in id_map
    ]
    if remapped:
        (user_dir / f"graph_{notebook_id}.json").write_text(json.dumps(remapped, ensure_ascii=False), encoding="utf-8")


def compensate_staged_copy(
    card_store: CardStore,
    notebook_store: NotebookStore,
    user_dir: Path,
    notebook_id: str,
) -> bool:
    """Best-effort teardown of a partially-materialized copy. Runs on any failure
    before the copy_log is committed; secondary errors are logged, not raised, so
    the original fault propagates. Returns ``True`` only when everything was
    cleaned up.

    Cards are TOMBSTONED (soft-deleted, ``updated_at`` bumped), not erased: a
    client may already have pulled them, and only a tombstone propagates the
    deletion on incremental sync. The notebook row goes LAST: while it stays
    ``is_staged`` its cards are hidden from global pulls, so a failed step leaves
    the staged marker in place (cards still hidden, nothing leaked) and returns
    ``False`` for a later sweep to retry. Every step is idempotent."""
    try:
        card_store.soft_delete_by_notebook(notebook_id)
    except Exception:  # noqa: BLE001 — compensation must not mask the root fault
        _LOGGER.warning("copy compensation: card cleanup failed for %s", notebook_id, exc_info=True)
        return False
    try:
        (user_dir / f"graph_{notebook_id}.json").unlink(missing_ok=True)
    except OSError:
        _LOGGER.warning("copy compensation: graph cleanup failed for %s", notebook_id, exc_info=True)
        return False
    try:
        notebook_store.hard_delete(notebook_id)
    except Exception:  # noqa: BLE001
        _LOGGER.warning("copy compensation: notebook cleanup failed for %s", notebook_id, exc_info=True)
        return False
    return True


def _reveal(
    shared_store: SharedDeckStore,
    card_store: CardStore,
    notebook_store: NotebookStore,
    *,
    copier_id: str,
    idempotency_key: str,
    notebook_id: str,
    deck_id: str,
) -> None:
    """Complete a committed copy: flip the notebook visible, re-stamp its cards,
    then commit the ``download_counted`` marker.

    The cards were hidden from global pulls while staged, so an incremental
    puller whose boundary fell inside the copy window already skipped them and
    would never re-fetch (their ``updated_at`` predates its boundary). Re-stamping
    AFTER the flip guarantees every such boundary is older than the new stamps
    (re-stamping before it would let a pull advance past them while still hidden).

    Every step is idempotent and the marker is written strictly last, so callers
    run this whenever the marker is unset: a crash or raise between the flip and
    the restamp is redone whole by the retry (``materialize`` alone would report
    "already visible" and skip the restamp forever). A settled copy is never
    re-stamped — its marker is set."""
    notebook_store.materialize(notebook_id)
    card_store.restamp_by_notebook(notebook_id, datetime.now(UTC))
    shared_store.finalize_copy_download(copier_id, idempotency_key, deck_id)


def _replay(
    shared_store: SharedDeckStore,
    notebook_store: NotebookStore,
    card_store: CardStore,
    log,
    deck_id: str,
) -> CopyOutcome:
    if log.source_shared_deck_id != deck_id:
        raise ConflictError("idempotency key already belongs to another deck")

    # Finish a reveal the original request did not complete: it may have crashed
    # before the flip, between the flip and the restamp, or before the marker
    # commit. ``download_counted`` is written last, so unset means "redo it all";
    # set means the copy is settled and a replay is a pure read.
    if not log.download_counted:
        _reveal(
            shared_store,
            card_store,
            notebook_store,
            copier_id=log.copier_id,
            idempotency_key=log.idempotency_key,
            notebook_id=log.result_notebook_id,
            deck_id=deck_id,
        )
    nb = notebook_store.get(log.result_notebook_id)
    return CopyOutcome(
        notebook_id=log.result_notebook_id,
        notebook_name=nb.name if nb is not None else "",
        deck_id=deck_id,
        source_version=log.source_version,
        card_count=card_store.count(notebook_id=log.result_notebook_id),
        already_copied=True,
    )


def copy_shared_deck(
    *,
    shared_store: SharedDeckStore,
    card_store: CardStore,
    notebook_store: NotebookStore,
    user_dir: Path,
    deck_id: str,
    copier_id: str,
    idempotency_key: str,
    notebook_name: str | None = None,
    now: datetime | None = None,
    _on_card: Callable[[int], None] | None = None,
) -> CopyOutcome:
    """Copy an official/public deck into the copier's private notebook.

    ``_on_card(i)`` is an internal test hook fired after each card insert; a test
    raises from it to exercise the mid-copy compensation path.
    """
    now = now or datetime.now(UTC)

    # Serialize per-user copies (see _user_copy_lock): the copy handler is a SYNC
    # FastAPI endpoint, so two concurrent same-user copies run on separate
    # threadpool threads. Without this lock they would both read the pre-create
    # notebook snapshot, compute the SAME unique name, and both INSERT → two
    # same-named active notebooks → world-export's name→id map collapses (§2 name
    # uniqueness is mandatory). Held through materialize so the second copy sees
    # the first's committed notebook and disambiguates to "X (2)". The
    # discoverability gate also runs under the lock, so it cannot race a replay
    # that the in-flight copy is about to log.
    with _user_copy_lock(user_dir):
        return _copy_locked(
            shared_store=shared_store,
            card_store=card_store,
            notebook_store=notebook_store,
            user_dir=user_dir,
            deck_id=deck_id,
            copier_id=copier_id,
            idempotency_key=idempotency_key,
            notebook_name=notebook_name,
            now=now,
            _on_card=_on_card,
        )


def _copy_locked(
    *,
    shared_store: SharedDeckStore,
    card_store: CardStore,
    notebook_store: NotebookStore,
    user_dir: Path,
    deck_id: str,
    copier_id: str,
    idempotency_key: str,
    notebook_name: str | None,
    now: datetime,
    _on_card: Callable[[int], None] | None,
) -> CopyOutcome:
    """The per-user-serialized body of :func:`copy_shared_deck`, executed while
    holding the per-user copy lock. Every user-dir mutation (name-compute →
    create → card copy → record_copy → materialize) happens here so a concurrent
    same-user copy is fully queued behind it."""
    # Idempotent replay is keyed by the copy log, not by discoverability: a
    # same-key retry after the source was unpublished or hidden must still replay
    # (and finish an interrupted reveal) instead of 404ing (#3898). Only a NEW
    # copy passes the discoverability gate below.
    prior = shared_store.get_copy_log(copier_id, idempotency_key)
    if prior is not None:
        source = shared_store.get_any(deck_id)
        if source is None or source.source != "official":
            raise NotFoundError("Deck", deck_id)
        return _replay(shared_store, notebook_store, card_store, prior, source.id)

    deck = shared_store.get(deck_id)
    if deck is None:  # not discoverable → 404 (never leak hidden decks)
        raise NotFoundError("Deck", deck_id)
    if deck.source != "official":
        # Explore copy is intentionally limited to curated official content.
        # Community publishing/copying remains a separate product phase.
        raise ConflictError("Only official decks can be copied")

    version = deck.current_version
    src_cards = shared_store.all_cards(deck.id, version=version)
    source_count = len(src_cards)

    base_name = (notebook_name or "").strip() or (deck.title or "").strip() or _DEFAULT_TITLE
    unique_name = _unique_notebook_name(notebook_store, base_name)

    # Stage the notebook HIDDEN (barrier) with provenance; revealed only after
    # every card lands + count-equality holds. is_staged (NOT is_deleted) is the
    # barrier, so the reveal can never resurrect a user-deleted copy on replay.
    nb = notebook_store.create(
        name=unique_name,
        color=deck.color,
        cover_pattern=deck.cover_pattern,
        source_shared_deck_id=deck.id,
        source_version=version,
        is_staged=True,
    )

    id_map: dict[str, str] = {}
    created = 0
    try:
        for i, sc in enumerate(src_cards):
            card, was_created = card_store.add_shared_copy(
                content=sc.content,
                meaning=sc.meaning,
                pos=sc.pos,
                examples=sc.examples,
                collocations=sc.collocations,
                note=sc.note,
                difficulty=sc.difficulty,
                mode=sc.mode,
                root_form=sc.root_form,
                inflections=sc.inflections,
                notebook_id=nb.id,
                # strictly-monotonic, distinct per card (§4.4 tie defense)
                updated_at=now + timedelta(milliseconds=i),
                source_shared_card_guid=sc.content_guid,
            )
            id_map[sc.content_guid] = card.id
            if was_created:
                created += 1
            if _on_card is not None:
                _on_card(i)

        if created != source_count:
            # A NOCASE/NFC collapse merged two source cards into one row — fail
            # loud rather than hand back a lossy deck.
            raise ConflictError(
                f"deck copy card-count mismatch: materialized {created} of "
                f"{source_count} (content collision under per-notebook uniqueness)"
            )

        # No-op for official decks (zero links); seam kept honest for the future.
        _remap_graph_links(user_dir, nb.id, source_links=(), id_map=id_map)
    except Exception:
        # Everything above is pre-commit: no copy_log points at this notebook yet,
        # so compensation can safely erase the whole partial copy.
        compensate_staged_copy(card_store, notebook_store, user_dir, nb.id)
        raise

    # ── point of no return ─────────────────────────────────────────
    # Commit the idempotency log BEFORE revealing the notebook. If a concurrent
    # request with the same key won the race, roll OUR copy back and replay to
    # theirs (never two notebooks). Ordering matters: were the notebook revealed
    # first, a crash before record_copy would leave a visible copy with no log →
    # a retry would mint a SECOND notebook (the duplicate idempotency exists to
    # prevent). With the log first, a crash before materialize self-heals — the
    # retry finds the log and _replay reveals the still-hidden notebook.
    try:
        recorded = shared_store.record_copy(copier_id, idempotency_key, deck.id, version, nb.id)
    except Exception:
        # record_copy only converts an idempotency collision to False; any other
        # fault (e.g. OperationalError: database is locked) escapes. The staged
        # notebook + cards were written before this log row, so compensate before
        # re-raising — otherwise they leak as invisible orphan rows forever.
        compensate_staged_copy(card_store, notebook_store, user_dir, nb.id)
        raise
    if not recorded:
        compensate_staged_copy(card_store, notebook_store, user_dir, nb.id)
        winner = shared_store.get_copy_log(copier_id, idempotency_key)
        if winner is not None:
            return _replay(shared_store, notebook_store, card_store, winner, deck.id)
        # Extremely unlikely (row vanished between conflict and re-read); surface
        # it rather than pretend success.
        raise ConflictError("deck copy idempotency conflict could not be resolved")

    # Post-commit finalizers — best-effort, never compensated (rolling back after
    # the idempotency log is committed would strand its pointer). A crash here is
    # recovered by the next retry via _replay (the marker is still unset).
    _reveal(
        shared_store,
        card_store,
        notebook_store,
        copier_id=copier_id,
        idempotency_key=idempotency_key,
        notebook_id=nb.id,
        deck_id=deck.id,
    )
    return CopyOutcome(
        notebook_id=nb.id,
        notebook_name=unique_name,
        deck_id=deck.id,
        source_version=version,
        card_count=created,
        already_copied=False,
    )


def reveal_uncounted_copies(data_root: Path, *, shared_decks_path: Path) -> int:
    """Finish committed copies whose reveal raised (#3897).

    The request path raises after the point of no return when materialize,
    restamp or the counter fails. The copy is durable, but the client may never
    retry the same key, so nothing else would reveal the notebook. This sweep
    drives every copy_log row with ``download_counted`` unset through
    :func:`_reveal`, the same idempotent finisher ``_replay`` uses.

    Each row is settled under the copier's per-user copy lock, which the request
    holds across its own ``_reveal``: an in-flight copy is never raced, and the
    marker is re-read under the lock so a settled copy is skipped. A row that
    still fails is logged and retried by the next pass. Returns the number of
    copies settled in this pass.
    """
    users_dir = data_root / "users"
    if not users_dir.is_dir():
        return 0
    shared = SharedDeckStore(shared_decks_path)
    settled = 0
    try:
        for row in shared.list_uncounted_copies():
            user_dir = users_dir / row.copier_id
            if not (user_dir / "notebooks.db").is_file():
                continue
            try:
                with _user_copy_lock(user_dir):
                    current = shared.get_copy_log(row.copier_id, row.idempotency_key)
                    if current is None or current.download_counted:
                        continue
                    if shared.get_any(current.source_shared_deck_id) is None:
                        # _reveal would flip the notebook visible and then fail to
                        # count it. Keep it staged (hidden) until the deck exists.
                        _LOGGER.warning("reveal sweep: source deck missing for copy %s", row.copier_id)
                        continue
                    notebooks = NotebookStore(user_dir / "notebooks.db")
                    cards = CardStore(user_dir / "cards.db")
                    try:
                        _reveal(
                            shared,
                            cards,
                            notebooks,
                            copier_id=current.copier_id,
                            idempotency_key=current.idempotency_key,
                            notebook_id=current.result_notebook_id,
                            deck_id=current.source_shared_deck_id,
                        )
                    finally:
                        notebooks.close()
                        cards.close()
                settled += 1
            except Exception:  # noqa: BLE001 — one stuck copy must not block the others
                _LOGGER.warning("reveal sweep failed for copy %s", row.copier_id, exc_info=True)
    finally:
        shared.close()
    return settled


REVEAL_SWEEP_INTERVAL = timedelta(minutes=5)


async def run_reveal_sweep_forever(
    data_root: Path,
    *,
    shared_decks_path: Path,
    interval: timedelta = REVEAL_SWEEP_INTERVAL,
) -> None:
    """Run :func:`reveal_uncounted_copies` every ``interval`` for the process
    lifetime. Blocking SQLite work runs in a worker thread. Cancellation is safe
    at any point: a pass interrupted by shutdown leaves the marker unset, and
    the next startup sweep redoes that copy whole."""
    while True:
        await asyncio.sleep(interval.total_seconds())
        try:
            await asyncio.to_thread(reveal_uncounted_copies, data_root, shared_decks_path=shared_decks_path)
        except Exception:  # noqa: BLE001 — keep the loop alive; the next pass retries
            _LOGGER.warning("reveal sweep pass failed", exc_info=True)


__all__ = ["CopyOutcome", "copy_shared_deck", "reveal_uncounted_copies", "run_reveal_sweep_forever"]
