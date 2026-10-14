from __future__ import annotations

import asyncio
import contextlib
import logging
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from typing import Any, Protocol

from openai import OpenAIError

from ..exceptions import QuotaExceededError
from ..ops_cli_shared import _normalize_persisted_bool
from ..text_utils import normalize_nfc_lower
from ..types import UserRecord
from ..vocab_graph import CANDIDATE_K, MAX_DEGREE, SIMILARITY_THRESHOLD


class CardStoreFactory(Protocol):
    def __call__(self, user_dir: Any) -> Any: ...


class GraphStoreFactory(Protocol):
    def __call__(self, user_dir: Any, notebook_id: str = "default") -> Any: ...


class EmbeddingStoreFactory(Protocol):
    def __call__(self, user_dir: Any, llm: Any, notebook_id: str = "default") -> Any: ...


class ClientFactory(Protocol):
    def __call__(self, provider: Any) -> Any: ...


def _touch_linked_cards(
    cards: Any,
    all_links: list[tuple],
    *,
    notebook_id: str | None = None,
) -> None:
    """Bump updated_at for all cards involved in newly created links.

    This ensures incremental sync (filtered by updated_at) delivers the
    new links to iOS clients.
    """
    # Links are 5-tuples (from_id, to_id, kind, confidence, reason); index
    # explicitly so a future dataclass/namedtuple migration fails loudly
    # instead of silently shifting fields.
    touched_ids = {cid for link in all_links for cid in (link[0], link[1])}
    cards.batch_touch(touched_ids, notebook_id=notebook_id)


class _JudgeClaim:
    """Settlement ledger for the ids one judge run claimed (#2084).

    ``pop_pending_judge`` keeps claimed ids in the durable pending file until
    they are settled, so a killed process leaves them for the next one. In
    process, every claimed id is settled exactly once before the step returns
    or propagates: ``ack`` once its links are persisted (or it needs none),
    ``requeue`` to hand it back to the queue for the next run.
    """

    def __init__(self, graph: Any, card_ids: list[str]) -> None:
        self._graph = graph
        self._ids = list(dict.fromkeys(card_ids))
        self._settled: set[str] = set()

    def _unsettled(self, card_ids: list[str]) -> list[str]:
        return [cid for cid in dict.fromkeys(card_ids) if cid not in self._settled]

    def requeue(self, card_ids: list[str]) -> list[str]:
        ids = self._unsettled(card_ids)
        if ids:
            self._graph.add_pending_judge(ids)
            self._settled.update(ids)
        return ids

    def ack(self, card_ids: list[str]) -> None:
        ids = self._unsettled(card_ids)
        if ids:
            self._graph.ack_pending_judge(ids)
            self._settled.update(ids)

    def requeue_rest(self) -> list[str]:
        return self.requeue(self._ids)

    def ack_rest(self) -> None:
        self.ack(self._ids)


def _index_enrichment_results(results: Any) -> tuple[dict[str, dict], int]:
    """Map lower-cased word -> enrichment item for one batch of LLM output.

    LLM JSON is untrusted: ``results`` may not be a list, and items may be
    non-dicts or lack a str ``word``. Those are counted as skipped instead of
    raising, which would abort the whole enrich run over one bad item.
    Returns ``(result_map, skipped_count)``.
    """
    if not isinstance(results, list):
        return {}, 1
    from ..enrich import sanitize_enrich_item

    result_map: dict[str, dict] = {}
    skipped = 0
    for item in results:
        clean = sanitize_enrich_item(item)
        if clean is None:
            skipped += 1
        else:
            result_map[normalize_nfc_lower(clean["word"])] = clean
    return result_map, skipped


# Server-side cap on LLM enrich attempts per card: a card the model never returns
# (or returns without pos/note) would otherwise be re-billed on every pipeline run.
# An attempt is consumed only by cards in a batch that answered (success terminal,
# even with empty/malformed results, since it was billed);
# batches that errored (transient 5xx after retries) and the all-batches-fail path
# consume none, so an outage never permanently excludes a card. Force bypasses the cap.
ENRICH_MAX_ATTEMPTS = 3


async def _step_enrich(
    uid: str,
    user: UserRecord,
    *,
    card_store_factory: CardStoreFactory,
    client_factory: ClientFactory,
    logger: logging.Logger,
    force: bool = False,
    notebook_id: str = "default",
    embedding_store_factory: EmbeddingStoreFactory | None = None,
    graph_store_factory: GraphStoreFactory | None = None,
) -> int:
    logger.info("[%s] Step 1: Enrich (force=%s, notebook=%s)", uid, force, notebook_id)
    cards = card_store_factory(user["dir"])
    eligible_cards = list(cards.all(include_deleted=False, notebook_id=notebook_id))
    if force:
        targets = eligible_cards
    else:
        targets = [
            card
            for card in eligible_cards
            if (not card.pos or card.note is None) and card.enrich_attempts < ENRICH_MAX_ATTEMPTS
        ]

    if not targets:
        logger.info("[%s] All cards already enriched", uid)
        return 0

    from ..deps_quota import _is_pro
    from ..enrich import enrich_cards_stream
    from ..llm.providers import provider_for
    from ..tracked_llm import TrackedLLM

    provider = provider_for("enrich")
    llm = TrackedLLM(
        client_factory(provider),
        uid,
        provider=provider,
        enforce_quota=True,
        is_pro=_is_pro(user),
    )
    logger.info("[%s] Enriching %d cards...", uid, len(targets))
    updated = 0
    batch_errors: list[str] = []
    got_results = False
    answered_ids: list[str] = []
    meaning_changed_ids: list[str] = []

    # aclosing: a consumer-side failure (e.g. SQLite busy in batch_update) must
    # shut the stream's executor down now, not at GC, and before _run_step's
    # retry can start a second stream.
    async with contextlib.aclosing(
        enrich_cards_stream(llm, targets, batch_size=20, max_workers=5, model=provider.chat_model)
    ) as stream:
        async for msg in stream:
            if msg.get("status") == "error":
                logger.warning("[%s] Enrichment batch error: %s", uid, msg.get("detail"))
                batch_errors.append(str(msg.get("detail")))

            if msg.get("status") != "error" and msg.get("card_ids"):
                answered_ids.extend(msg["card_ids"])

            if msg.get("results"):
                got_results = True
                result_map, skipped = _index_enrichment_results(msg["results"])
                if skipped:
                    logger.warning("[%s] Skipped %d malformed enrichment items", uid, skipped)
                batch_updates: list[tuple[str, dict]] = []
                for card in targets:
                    enrichment = result_map.get(normalize_nfc_lower(card.content))
                    if not enrichment:
                        continue
                    kwargs: dict[str, Any] = {}
                    if enrichment.get("pos"):
                        if force or not card.pos:
                            from ..vocab_shared import _normalize_pos

                            kwargs["pos"] = _normalize_pos(enrichment["pos"])
                    if enrichment.get("note"):
                        if force or card.note is None:
                            kwargs["note"] = enrichment["note"]
                    if enrichment.get("collocations"):
                        kwargs["collocations"] = enrichment["collocations"]
                    # note == "" is the user's explicit clear: their meaning edit must not be reverted.
                    if enrichment.get("meaning_fix") and (force or card.note != ""):
                        kwargs["meaning"] = enrichment["meaning_fix"]
                        if kwargs["meaning"] != card.meaning:
                            meaning_changed_ids.append(card.id)
                    if kwargs:
                        batch_updates.append((card.id, kwargs))
                if batch_updates:
                    updated += cards.batch_update(batch_updates)
                if meaning_changed_ids:
                    from ..deps import _embedding_store, _graph_store
                    from ..vocab_crud import reembed_meaning_edits_best_effort

                    make_embeddings = embedding_store_factory or _embedding_store
                    make_graph = graph_store_factory or _graph_store
                    reembed_meaning_edits_best_effort(
                        meaning_changed_ids,
                        open_embeddings=partial(make_embeddings, user["dir"], llm=None, notebook_id=notebook_id),
                        open_graph=partial(make_graph, user["dir"], notebook_id=notebook_id),
                    )
                    meaning_changed_ids.clear()

    if batch_errors and not got_results:
        raise RuntimeError(f"Enrich failed for all batches: {batch_errors[0]}")
    # Consume one attempt per card whose batch answered so cards the LLM never resolves
    # stop being re-billed. Best-effort: if the stream or batch_update raises (and
    # _run_step retries), billed batches of the failed pass consume no attempt.
    if not force and answered_ids:
        cards.bump_enrich_attempts(answered_ids)
    logger.info("[%s] Enriched %d cards", uid, updated)
    return updated


async def _step_embed_and_judge(
    uid: str,
    user: UserRecord,
    *,
    card_store_factory: CardStoreFactory,
    graph_store_factory: GraphStoreFactory,
    embedding_store_factory: EmbeddingStoreFactory,
    client_factory: ClientFactory,
    logger: logging.Logger,
    link_kind_enum: Any,
    notebook_id: str = "default",
) -> int:
    """Combined embed + judge step. Replaces _step_embed + _step_link."""
    from ..deps_quota import _is_pro
    from ..llm.providers import provider_for
    from ..tracked_llm import TrackedLLM

    is_pro = _is_pro(user)

    cards = card_store_factory(user["dir"])
    # `embed` resolves independently of the chat default — DeepSeek has no
    # embeddings endpoint, so flipping LLM_PROVIDER_DEFAULT must not drag it.
    embed_provider = provider_for("embed")
    embed_llm = TrackedLLM(
        client_factory(embed_provider),
        uid,
        provider=embed_provider,
        enforce_quota=True,
        is_pro=is_pro,
    )
    embeddings = embedding_store_factory(user["dir"], llm=embed_llm, notebook_id=notebook_id)
    graph = graph_store_factory(user["dir"], notebook_id=notebook_id)

    # ── Phase 1: Embed missing cards ──
    missing = [
        card for card in cards.all(notebook_id=notebook_id) if not embeddings.has(card.id) and not card.is_archived
    ]
    newly_embedded: list[str] = []
    if missing:
        logger.info("[%s] Embedding %d cards", uid, len(missing))
        # Queue BEFORE embedding (#2084). The embedding persists from an
        # executor thread that outlives a cancelled step, and a kill can land
        # between its save and a later queue write; either way the card would
        # end up embedded but never queued, and Phase 1 never revisits embedded
        # cards. A queued card whose embedding failed is harmless: Phase 2
        # finds no neighbours and acks it, and the next run re-queues it while
        # it is still missing.
        graph.add_pending_judge([card.id for card in missing])
        items = [(card.id, card.embed_text()) for card in missing]
        loop = asyncio.get_running_loop()
        try:
            await loop.run_in_executor(None, embeddings.add_batch, items)
        except (OpenAIError, OSError, ValueError) as exc:
            logger.warning("[%s] Batch embedding failed: %s", uid, exc)
        # add_batch persists chunk by chunk, so a mid-batch failure still
        # leaves the earlier chunks embedded (#2264): report those too.
        newly_embedded = [card.id for card in missing if embeddings.has(card.id)]

        if newly_embedded:
            logger.info("[%s] Embedded %d cards, queued for judge", uid, len(newly_embedded))

    # ── Phase 2: Judge pending cards ──
    # Per-user auto_link 開關(user config 的 auto_link group):關閉時不消費
    # pending_judge——新卡仍照常 embed 並入列(上方 Phase 1),重新開啟後下一輪
    # pipeline 續判,不丟失。缺省/壞型別 fallback enabled=True 向後相容,語意
    # 對齊 user_handlers._build_user_config_response。
    user_config = user.get("config")
    auto_link_cfg = user_config.get("auto_link") if isinstance(user_config, dict) else None
    if isinstance(auto_link_cfg, dict) and not _normalize_persisted_bool(
        auto_link_cfg.get("enabled"),
        default=True,
    ):
        logger.info("[%s] Auto-link disabled by user config; judge skipped", uid)
        return 0

    pending = graph.pop_pending_judge()
    if not pending:
        logger.info("[%s] No pending cards to judge", uid)
        return 0

    claim = _JudgeClaim(graph, pending)
    try:
        created = await _judge_pending(
            uid,
            pending,
            claim,
            is_pro=is_pro,
            cards=cards,
            graph=graph,
            embeddings=embeddings,
            client_factory=client_factory,
            logger=logger,
            link_kind_enum=link_kind_enum,
            notebook_id=notebook_id,
        )
        claim.ack_rest()
    except BaseException:
        # Any exception *and* cancellation (CancelledError is a BaseException,
        # so a deploy-time task cancel used to skip every requeue): hand each
        # unsettled id back before propagating. Handing back a claimed id is
        # memory-only, so this cannot fail on I/O; if it still fails, the ids
        # remain durable on disk and the next process requeues them.
        try:
            requeued = claim.requeue_rest()
        except Exception:
            logger.warning("[%s] Failed to requeue claimed judge cards", uid, exc_info=True)
        else:
            if requeued:
                logger.warning("[%s] Judge aborted; requeued %d claimed cards", uid, len(requeued))
        raise
    return created


async def _judge_pending(
    uid: str,
    pending: list[str],
    claim: _JudgeClaim,
    *,
    is_pro: bool,
    cards: Any,
    graph: Any,
    embeddings: Any,
    client_factory: ClientFactory,
    logger: logging.Logger,
    link_kind_enum: Any,
    notebook_id: str,
) -> int:
    """Phase 2 body: judge the claimed ``pending`` ids and persist their links.

    Settles ids through ``claim`` only where the outcome is known mid-run
    (failed similarity lookups, partially persisted links); the caller acks
    the rest on success and requeues them on any failure.
    """
    from ..judge import Judge
    from ..llm.providers import provider_for
    from ..tracked_llm import TrackedLLM

    logger.info("[%s] Judging %d pending cards", uid, len(pending))
    judge_provider = provider_for("judge")
    judge_llm = TrackedLLM(
        client_factory(judge_provider),
        uid,
        provider=judge_provider,
        enforce_quota=True,
        is_pro=is_pro,
    )
    from ..settings import load_settings

    judge = Judge(
        judge_llm,
        model=judge_provider.chat_model,
        user_id=uid,
        notebook_id=notebook_id,
        confidence_threshold=load_settings().judge_confidence_threshold,
    )

    # Pre-fetch pending cards
    cards_cache = cards.get_batch(set(pending))

    all_links: list[tuple[str, str, Any, float, str]] = []

    def _active_degree(cid: str) -> int:
        return sum(1 for lk in graph.get_links_for(cid) if lk.status == "active")

    # ── Phase 2a: Prepare judge tasks ──
    # Pass 1: collect all other_ids from find_similar across all pending cards
    # to do ONE batch fetch instead of per-card get_batch (fixes C2 N+1 query).
    #
    # Eligibility (not deleted/archived, under MAX_DEGREE) is resolved up front
    # so similarity is computed only for cards that can actually gain links. The
    # neighbour lookup is then done in a single batched matmul via
    # find_similar_batch when the store supports it (real EmbeddingStore);
    # the per-card find_similar path is kept as a fallback for fakes/stores that
    # only implement find_similar (the audit found 11+ such test doubles).
    eligible: list[tuple[str, Any, int]] = []
    for card_id in pending:
        card = cards_cache.get(card_id)
        if not card or card.is_deleted or card.is_archived:
            continue
        if getattr(card, "notebook_id", notebook_id) != notebook_id:
            continue  # moved to another notebook (#2532): never link across notebooks
        current_degree = _active_degree(card_id)
        if current_degree >= MAX_DEGREE:
            continue
        eligible.append((card_id, card, current_degree))

    similar_by_id: dict[str, list[tuple[str, float]]] = {}
    failed_similarity_ids: list[str] = []
    if hasattr(embeddings, "find_similar_batch"):
        try:
            similar_by_id = embeddings.find_similar_batch([cid for cid, _, _ in eligible], k=CANDIDATE_K)
        except (OSError, ValueError) as exc:
            logger.warning("[%s] find_similar_batch failed: %s", uid, exc)
            failed_similarity_ids = list(dict.fromkeys(cid for cid, _, _ in eligible))
            similar_by_id = {}
    else:
        for card_id, _, _ in eligible:
            try:
                similar_by_id[card_id] = embeddings.find_similar(card_id, k=CANDIDATE_K)
            except (OSError, ValueError) as exc:
                logger.warning("[%s] find_similar failed for '%s': %s", uid, card_id, exc)
                failed_similarity_ids.append(card_id)

    # Hand back only the cards whose lookup actually failed; a successful empty
    # result is a normal completion and is acked with the rest of the claim.
    # GraphStore deduplicates the requeue, so a concurrent add cannot create
    # duplicate pending work.
    if failed_similarity_ids:
        claim.requeue(failed_similarity_ids)

    per_card_similar: list[tuple[str, Any, int, list[tuple[str, float]]]] = []
    all_other_ids: set[str] = set()
    for card_id, card, current_degree in eligible:
        similar = similar_by_id.get(card_id)
        if not similar:
            continue

        candidates: list[tuple[str, float]] = []
        for other_id, score in similar:
            if score <= SIMILARITY_THRESHOLD:
                continue
            if graph.has_link(card_id, other_id):
                continue
            candidates.append((other_id, score))
            all_other_ids.add(other_id)

        if candidates:
            per_card_similar.append((card_id, card, current_degree, candidates))

    # Single batch fetch for ALL other_ids across all pending cards
    others_cache = cards.get_batch(all_other_ids) if all_other_ids else {}

    # Pass 2: filter candidates using the shared cache, build judge_tasks.
    # Include current_degree in the tuple so Phase 2b can initialize
    # from_link_counts without redundant get_links_for calls (fixes W3).
    judge_tasks: list[tuple[str, Any, list, dict, int | None, int]] = []
    for card_id, card, current_degree, candidates in per_card_similar:
        available = MAX_DEGREE - current_degree
        filtered: list[tuple[str, str, str, float]] = []
        for other_id, score in candidates:
            other = others_cache.get(other_id)
            if not other or other.is_deleted or other.is_archived:
                continue
            if getattr(other, "notebook_id", notebook_id) != notebook_id:
                continue  # stale vector of a card moved out of this notebook (#2532)
            if _active_degree(other_id) >= MAX_DEGREE:
                continue
            filtered.append((other_id, other.content, other.meaning, score))

        if not filtered:
            continue

        batch_cands = [(oid, w, m) for oid, w, m, _ in filtered]
        sims = {oid: s for oid, _, _, s in filtered}
        max_links = available if len(filtered) >= 5 else None
        judge_tasks.append((card_id, card, batch_cands, sims, max_links, current_degree))

    if not judge_tasks:
        logger.info("[%s] No cards need judging after filtering", uid)
        return 0

    # ── Phase 2b: Parallel judge ──
    executor = ThreadPoolExecutor(max_workers=8)
    loop = asyncio.get_running_loop()

    futures: list[tuple[str, asyncio.Future]] = []
    for card_id, card, batch_cands, sims, max_links, _deg in judge_tasks:
        futures.append(
            (
                card_id,
                loop.run_in_executor(
                    executor,
                    lambda c=card, bc=batch_cands, s=sims, ml=max_links, fid=card_id: judge.evaluate_batch(
                        c.content,
                        c.meaning,
                        bc,
                        from_id=fid,
                        similarities=s,
                        max_links=ml,
                    ),
                ),
            )
        )

    # Track per-card link count to enforce MAX_DEGREE on both sides.
    # from_link_counts: from-side — seeded from current_degree computed in
    #   Phase 2a to avoid redundant get_links_for calls (W3 fix).
    # to_link_counts: to-side (the other_id being linked TO) — tracks
    #   in-flight links so multiple pending cards don't exceed MAX_DEGREE
    #   on a shared target (C1 fix).
    from_link_counts: dict[str, int] = {cid: deg for cid, _, _, _, _, deg in judge_tasks}
    to_link_counts: dict[str, int] = {}

    # Per-card similarity map for audit logging when degree cap forces a
    # reject — built lazily so we only pay if a cap actually fires.
    sims_by_card: dict[str, dict[str, float]] = {cid: s for cid, _, _, s, _, _ in judge_tasks}

    def _log_degree_cap(from_id: str, to_id: str, judgement) -> None:
        """Mark an LLM-accepted candidate as cap-evicted in judge_log.

        ``Judge.evaluate_batch`` has already inserted an ``accepted=1`` row
        for this candidate. Inserting a second ``accepted=0`` row would
        double-count the pair and pollute ``get_acceptance_stats``. Instead,
        flip the existing row to ``accepted=0`` with
        ``reject_reason='degree_cap'`` so the audit trail tells "LLM
        accepted, pipeline capped" without inflating the denominator.
        """
        if not uid:
            return
        try:
            from .. import judge_log

            updated = judge_log.update_to_rejected(
                from_id,
                to_id,
                reason="degree_cap",
            )
            if not updated:
                # Fallback: no prior accepted row (e.g. judge bypassed
                # logging). Insert a fresh degree_cap row so the eviction
                # is still observable.
                judge_log.record(
                    user_id=uid,
                    notebook_id=notebook_id,
                    from_id=from_id,
                    to_id=to_id,
                    similarity=sims_by_card.get(from_id, {}).get(to_id),
                    verdict=judgement.link,
                    confidence=judgement.confidence,
                    accepted=False,
                    reject_reason="degree_cap",
                    reason=judgement.reason,
                    source="auto",
                )
        except Exception:
            logger.warning("[%s] Failed to write degree_cap judge_log", uid, exc_info=True)

    def _consume(card_id: str, results: dict) -> None:
        # NOTE: do NOT stop early on from-cap: we still need to walk
        # remaining results so over-cap accepted candidates get
        # logged as degree_cap rejects (audit trail).
        for other_id, judgement in results.items():
            if judgement is None:
                continue
            if from_link_counts[card_id] >= MAX_DEGREE:
                _log_degree_cap(card_id, other_id, judgement)
                continue  # from-side at cap; keep logging surplus
            # Initialize to-side count on first access
            if other_id not in to_link_counts:
                to_link_counts[other_id] = _active_degree(other_id)
            if to_link_counts[other_id] >= MAX_DEGREE:
                _log_degree_cap(card_id, other_id, judgement)
                continue
            all_links.append(
                (
                    card_id,
                    other_id,
                    link_kind_enum(judgement.link),
                    judgement.confidence,
                    judgement.reason,
                )
            )
            from_link_counts[card_id] += 1
            to_link_counts[other_id] += 1

    consumed: list[str] = []
    quota_error: QuotaExceededError | None = None
    current_id: str | None = None
    try:
        for card_id, fut in futures:
            current_id = card_id
            try:
                results = await fut
            except QuotaExceededError as exc:
                # Real exhaustion rejected this one call. Keep collecting: the
                # other calls already ran, were billed and wrote accepted
                # judge_log rows, so their links must be applied, not orphaned.
                quota_error = quota_error or exc
                continue
            _consume(card_id, results)
            # Record ONLY after a card's results are FULLY consumed.
            # If an exception fires inside _consume (e.g. `link_kind_enum`
            # rejects an illegal enum value), the card is not in `consumed`,
            # so it is requeued. Phase 2a's `graph.has_link` check then skips
            # any links this card already persisted, so the re-judge neither
            # double-links nor double-counts.
            consumed.append(card_id)
        if quota_error is not None:
            raise quota_error
    except BaseException:
        # Exception or cancellation mid-loop. A card enters `consumed` only
        # AFTER its results are fully consumed, so a card that failed — in
        # `await fut`, on quota rejection, or mid result-consumption — is
        # absent. Persist the consumed cards' links and ack exactly those;
        # the caller requeues everything else still claimed (including these
        # cards if their links never reached disk).
        # #2699: futures that already finished successfully (billed, judge_log
        # accepted=1 written) must not be dropped and re-judged: salvage them.
        for cid, fut in futures:
            if cid in consumed or cid == current_id:
                continue
            if not fut.done() or fut.cancelled() or fut.exception() is not None:
                continue
            try:
                _consume(cid, fut.result())
                consumed.append(cid)
            except Exception:
                logger.warning("[%s] Failed to salvage completed judge result for %s", uid, cid, exc_info=True)
        consumed_set = set(consumed)
        remaining = [(cid, fut) for cid, fut in futures if cid not in consumed_set]
        unprocessed_ids = [cid for cid, _ in remaining]
        logger.warning(
            "[%s] Judge interrupted at %d/%d, requeueing %d", uid, len(consumed), len(futures), len(unprocessed_ids)
        )
        # Wrap the persistence: a failure here must NOT mask the original
        # judge-loop exception that we're about to re-raise.
        try:
            if all_links:
                graph.batch_add_links(all_links)
                _touch_linked_cards(cards, all_links, notebook_id=notebook_id)
            claim.ack(consumed)
        except Exception:
            logger.warning("[%s] Failed to persist partial links/touch", uid, exc_info=True)
        # Drain in-flight futures: their exceptions are unobserved otherwise,
        # and asyncio logs "Future exception was never retrieved" at ERROR
        # level on GC. We're already aborting; cancel pending and silently
        # consume any exception already raised.
        for _cid, fut in remaining:
            if not fut.done():
                fut.cancel()
                continue
            if not fut.cancelled():
                fut.exception()  # mark as retrieved; return value discarded
        raise
    finally:
        executor.shutdown(wait=False)

    # Batch create all links
    created = graph.batch_add_links(all_links) if all_links else []

    # Touch all cards involved in new links so incremental sync picks them up.
    # Without this, cards with new pipeline-created links keep their old
    # updated_at and iOS incremental sync (filtered by updated_at) never
    # sends the new links to the client.
    if created:
        _touch_linked_cards(cards, all_links, notebook_id=notebook_id)

    logger.info("[%s] Created %d links from %d cards", uid, len(created), len(pending))
    return len(created)


async def _step_difficulty(
    uid: str,
    user: UserRecord,
    *,
    card_store_factory: CardStoreFactory,
    logger: logging.Logger,
    notebook_id: str = "default",
) -> int:
    logger.info("[%s] Step 3: Difficulty (notebook=%s)", uid, notebook_id)
    from ..difficulty import get_zipf

    cards = card_store_factory(user["dir"])
    updates = []
    for card in cards.all(include_deleted=False, notebook_id=notebook_id):
        difficulty = round(get_zipf(card.content), 2)
        if card.difficulty != difficulty:
            updates.append((card.id, {"difficulty": difficulty}))
    scored = cards.batch_update(updates)
    logger.info("[%s] Scored %d cards", uid, scored)
    return scored
