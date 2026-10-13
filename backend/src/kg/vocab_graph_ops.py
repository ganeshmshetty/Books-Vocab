"""Graph link operations: create, hide, unhide, delete.

Touch barrier (#720 Q2)
-----------------------
Each op mutates the graph, then bumps both endpoint cards' ``updated_at`` via
``cards_store.touch()``. That bump is what makes the change visible to iOS: the
client pulls deltas through ``get_modified_since(updated_at)`` and, on seeing a
card change, re-fetches that card's links. If ``touch`` were to fail *after* a
successful graph mutation with no guard, the graph would have changed but no
card's ``updated_at`` moved -> the client would *permanently* miss the change
and graph/card state would silently diverge.

``_touch_both`` closes that silent window:

* It always attempts *both* endpoints (a failure on the first must not skip the
  second -- if at least one card's ``updated_at`` advances, the client still
  re-fetches that card's links and converges).
* Any failure is logged at ERROR (observable, not swallowed) and re-raised so
  the caller / HTTP layer surfaces an error instead of a fake success.

Reversible callers (hide / unhide, and create_manual_link's unhide branch) wrap
the barrier and roll the graph mutation back on failure, keeping graph and card
state consistent. ``delete`` and the create-new-link path are not cleanly
reversible (hard_delete is destructive; add_link's inverse adds a blocked pair),
so they rely on the barrier's observability + re-raise contract alone.

Card archive / unarchive / delete also change *other* cards' ``linksByKind``
(the server drops a peer that is archived or deleted), yet only the card itself
moves. Those paths bump the peers via ``link_peer_ids`` + ``touch_peers``.
"""

from __future__ import annotations

import logging
from typing import Any, Protocol

from .exceptions import BadRequestError, ConflictError, NotFoundError

logger = logging.getLogger(__name__)


class LinkMutation(Protocol):
    def __call__(self, link_id: str) -> None: ...


def _touch_both(cards_store: Any, from_id: str, to_id: str) -> None:
    """Bump updated_at on both endpoints; never silently swallow a failure.

    Both endpoints are always attempted, even if the first raises, so the
    client can still converge from whichever side succeeded. The first
    exception encountered is logged at ERROR and re-raised after both attempts.
    """
    first_error: BaseException | None = None
    for card_id in (from_id, to_id):
        try:
            cards_store.touch(card_id)
        except Exception as exc:  # noqa: BLE001 - re-raised below after logging
            if first_error is None:
                first_error = exc
            logger.error(
                "cards_store.touch failed for card %s after graph mutation; "
                "updated_at not bumped, client may miss this change",
                card_id,
                exc_info=True,
            )
    if first_error is not None:
        raise first_error


def link_peer_ids(graph: Any, card_id: str) -> set[str]:
    """Ids of cards joined to ``card_id`` by an active or hidden link.

    Re-syncs the store first: ``get_links_for`` only reads the in-memory indexes,
    while the ``cleanup_for_card`` that follows this snapshot refreshes before it
    deprecates. A cached instance that missed another process's new link would
    therefore deprecate a link whose peer was never snapshotted, leaving that peer
    with a stale ``linksByKind`` until a full resync.
    """
    graph.refresh_if_stale()
    return {link.to_id if link.from_id == card_id else link.from_id for link in graph.get_links_for(card_id)}


def touch_peers(cards_store: Any, peer_ids: set[str], card: Any) -> None:
    """Bump ``updated_at`` on peers whose ``linksByKind`` changed with ``card``.

    A peer's response hides links to archived/deleted cards, so flipping this
    card's state changes the peer's wire form. The incremental vocab pull is
    keyed by ``(updated_at, id)``; without the bump other devices never re-fetch
    the peer and keep a stale ``linksByKind``.

    Best-effort by design: the card change is already committed and is not
    cleanly reversible (delete hard-removes blocked pairs), unlike the
    reversible hide/unhide ops guarded by ``_touch_both``. A failure is logged
    at ERROR and swallowed; peers then heal on the next full resync.
    """
    peer_ids = peer_ids - {card.id}
    if not peer_ids:
        return
    try:
        cards_store.batch_touch(peer_ids, notebook_id=getattr(card, "notebook_id", None))
    except Exception:
        logger.error("Failed to bump linked peers of card %s", card.id, exc_info=True)


def _get_link_or_404(link_id: str, graph: Any) -> Any:
    """Fetch a link by id, raising NotFoundError if it doesn't exist."""
    lk = graph.get_link(link_id)
    if lk is None:
        raise NotFoundError("Link", link_id)
    return lk


def _require_live_card(cards_store: Any, card_id: str, notebook_id: str) -> Any:
    """Return the card if it is live (not deleted/archived) in ``notebook_id``, else 404."""
    card = cards_store.get(card_id)
    if not card or card.is_deleted or card.is_archived or card.notebook_id != notebook_id:
        raise NotFoundError("Card", card_id)
    return card


def create_manual_link(
    *,
    from_id: str,
    to_id: str,
    cards_store: Any,
    graph: Any,
    judge: Any,
    notebook_id: str,
) -> Any:
    """Create a manual link between two cards. Calls LLM for kind + reason.

    ``notebook_id`` is the notebook being operated on. The card store is
    per-user (not per-notebook) while the graph IS per-notebook, so a card
    from another notebook would otherwise be linkable across the isolation
    boundary. Both cards must belong to ``notebook_id``; one that doesn't is
    treated as absent from this notebook (404), matching the iOS client's
    notebook-scoped candidate list.
    """
    from .graph import LinkKind

    card_a = _require_live_card(cards_store, from_id, notebook_id)
    card_b = _require_live_card(cards_store, to_id, notebook_id)
    if from_id == to_id:
        raise BadRequestError("cannot link a card to itself")

    existing = graph.find_link_between(from_id, to_id)
    if existing and existing.status == "active":
        raise ConflictError("Link already exists between these cards")

    # Hidden → unhide directly, skip LLM. Reversible: roll back to hidden if the
    # touch barrier fails so graph and card state stay consistent.
    if existing and existing.status == "hidden":
        graph.unhide_link(existing.id, source="manual")
        try:
            _touch_both(cards_store, from_id, to_id)
        except Exception:
            graph.hide_link(existing.id, source="manual")
            raise
        return existing

    # Judge first: a failure here (quota, bad LLM payload) must leave a
    # user-deleted (blocked) pair blocked so the auto pipeline cannot re-create it.
    judgement = judge.evaluate(
        card_a.content,
        card_a.meaning,
        card_b.content,
        card_b.meaning,
        from_id=from_id,
        to_id=to_id,
    )

    # The judge is a multi-second LLM call. add_link re-validates both endpoints
    # under its own lock, in the same critical section as the insert, so a card
    # deleted or archived meanwhile never gets a live edge (no check-then-act gap).
    link = graph.add_link(
        from_id,
        to_id,
        LinkKind(judgement.link),
        confidence=1.0,
        reason=judgement.reason,
        source="manual",
        require_live=lambda card_id: _require_live_card(cards_store, card_id, notebook_id),
    )

    # Blocked pair → unblock only after the link is in. A refused add must leave a
    # user-deleted (blocked) pair blocked so the auto pipeline cannot re-create it.
    # try/finally: the link is already persisted, so the touch barrier must run even
    # if unblock_pair raises (otherwise a client retry sees 409 with no bumped cards).
    try:
        if graph.is_blocked(from_id, to_id):
            graph.unblock_pair(from_id, to_id)
    finally:
        # New link is not cleanly reversible (add_link's inverse, hard_delete, would
        # introduce a blocked pair). Rely on the barrier: observable + re-raise.
        _touch_both(cards_store, from_id, to_id)
    return link


def _reversible_link_toggle(
    *,
    link_id: str,
    graph: Any,
    cards_store: Any,
    from_status: str,
    to_status: str,
    apply: LinkMutation,
    revert: LinkMutation,
) -> None:
    """Apply a reversible graph link mutation, then run the touch barrier.

    Shared skeleton for hide/unhide (mirror images): fetch-or-404, run the
    forward mutation (``KeyError`` → 404 for a link that vanished mid-call), then
    bump both endpoints. If the barrier fails, ``revert`` rolls the mutation back
    so graph and card state stay consistent before re-raising.
    """
    lk = _get_link_or_404(link_id, graph)
    if lk.status == to_status:
        return  # idempotent no-op: no mutation, no touch, no ledger event
    if lk.status != from_status:
        # deprecated (endpoint archived/deleted) or candidate: not toggleable
        raise NotFoundError("Link", link_id)
    try:
        apply(link_id)
    except KeyError as exc:
        raise NotFoundError("Link", link_id) from exc
    try:
        _touch_both(cards_store, lk.from_id, lk.to_id)
    except Exception:
        revert(link_id)
        raise


def hide_graph_link(
    *,
    link_id: str,
    graph: Any,
    cards_store: Any,
) -> None:
    """Hide a link (user wants to stop seeing it but not permanently delete)."""
    _reversible_link_toggle(
        link_id=link_id,
        graph=graph,
        cards_store=cards_store,
        from_status="active",
        to_status="hidden",
        apply=lambda lid: graph.hide_link(lid, source="manual"),
        revert=lambda lid: graph.unhide_link(lid, source="manual"),
    )


def unhide_graph_link(
    *,
    link_id: str,
    graph: Any,
    cards_store: Any,
) -> None:
    """Unhide a previously hidden link."""
    _reversible_link_toggle(
        link_id=link_id,
        graph=graph,
        cards_store=cards_store,
        from_status="hidden",
        to_status="active",
        apply=lambda lid: graph.unhide_link(lid, source="manual"),
        revert=lambda lid: graph.hide_link(lid, source="manual"),
    )


def delete_graph_link(
    *,
    link_id: str,
    graph: Any,
    cards_store: Any,
) -> None:
    """Hard-delete a link and block the pair from being re-created.

    Only ``active``/``hidden`` links are user-deletable. A ``deprecated`` link
    (endpoint archived/deleted) must survive so ``restore_links_for`` can bring
    it back on un-archive; deleting it would drop the row and block the pair.
    """
    lk = _get_link_or_404(link_id, graph)
    if lk.status not in ("active", "hidden"):
        raise NotFoundError("Link", link_id)
    try:
        from_id, to_id = graph.hard_delete_link(link_id, source="manual")
    except KeyError as exc:
        raise NotFoundError("Link", link_id) from exc
    # hard_delete is destructive and not cleanly reversible. Rely on the
    # barrier: observable (logged) + re-raise instead of a silent divergence.
    _touch_both(cards_store, from_id, to_id)
