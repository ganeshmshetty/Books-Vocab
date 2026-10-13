"""Link CRUD operations for the graph store."""

from __future__ import annotations

import hashlib
import threading
import weakref
from collections.abc import Callable
from contextlib import ExitStack
from pathlib import Path
from typing import Any

from .filelock import path_write_lock
from .models import GraphLink, LinkKind

_PAIR_THREAD_LOCKS: weakref.WeakValueDictionary[tuple[str, tuple[str, str]], threading.Lock] = (
    weakref.WeakValueDictionary()
)
_PAIR_THREAD_LOCKS_GUARD = threading.Lock()


class _LinksMixin:
    """Link create / query / mutate / block operations for :class:`GraphStore`."""

    # Attributes provided by GraphStore -- declared for type checkers.
    _lock: threading.Lock
    _links: dict[str, GraphLink]
    _blocked_pairs: set[tuple[str, str]]
    _known_blocked_pairs: set[tuple[str, str]]
    _from_index: dict[str, set[str]]
    _to_index: dict[str, set[str]]
    links_path: Path
    _known_link_ids: set[str]
    _links_write_lock: threading.Lock
    _links_snapshot_sequence: int
    _last_flushed_links_snapshot_sequence: int
    _links_disk_sig: tuple[int, int, int] | None
    _synced_link_ids: set[str]
    _pending_link_ids: dict[str, int]

    # Helpers supplied by other mixins / GraphStore.
    @staticmethod
    def _disk_signature(path: Path | None) -> tuple[int, int, int] | None: ...  # noqa: D102
    def refresh_if_stale(self) -> bool: ...  # noqa: D102
    def _touch_links(self, link_ids: Any) -> None: ...  # noqa: D102
    def _touch_blocked(self, pairs: Any) -> None: ...  # noqa: D102
    def _index_link(self, link: GraphLink) -> None: ...  # noqa: D102
    def _unindex_link(self, link: GraphLink) -> None: ...  # noqa: D102
    def _links_to_serializable(self) -> list[dict]: ...  # noqa: D102
    def _read_json_list(self, path: Path) -> list[Any]: ...  # noqa: D102
    @staticmethod
    def _atomic_json_write(path: Path, data: Any, *, indent: int | None = 2) -> None: ...  # noqa: D102
    def _blocked_to_serializable(self) -> list[list[str]]: ...  # noqa: D102
    def _flush_links(self, snapshot: list[dict]) -> None: ...  # noqa: D102
    def _flush_blocked(self, snapshot: list[list[str]]) -> None: ...  # noqa: D102
    def _emit_graph_event(self, event_type: str, **kw: Any) -> None: ...  # noqa: D102
    def _build_graph_event_draft(self, event_type: str, **kw: Any) -> Any: ...  # noqa: D102
    def _emit_graph_events(self, drafts: list[Any]) -> None: ...  # noqa: D102

    @staticmethod
    def _normalize_pair(a: str, b: str) -> tuple[str, str]: ...  # noqa: D102

    # ------------------------------------------------------------------
    # Links
    # ------------------------------------------------------------------

    def _snapshot_link_pairs(self, snapshot: list[dict]) -> set[tuple[str, str]]:
        """Return active/hidden semantic pairs represented by a snapshot."""
        pairs: set[tuple[str, str]] = set()
        for row in snapshot:
            if not isinstance(row, dict) or row.get("status", "active") not in (
                "active",
                "hidden",
            ):
                continue
            from_id, to_id = row.get("from_id"), row.get("to_id")
            if isinstance(from_id, str) and isinstance(to_id, str):
                pairs.add(self._normalize_pair(from_id, to_id))
        return pairs

    def _pair_lock_path(self, pair: tuple[str, str]) -> Path:
        """Return a stable lock target that serialises creates for one pair."""
        digest = hashlib.sha256(f"{pair[0]}\0{pair[1]}".encode()).hexdigest()
        return self.links_path.with_name(f"{self.links_path.name}.pair-{digest}")

    def _pair_thread_lock(self, pair: tuple[str, str]) -> threading.Lock:
        """Return the in-process half of the per-pair lock."""
        key = (str(self.links_path.absolute()), pair)
        with _PAIR_THREAD_LOCKS_GUARD:
            lock = _PAIR_THREAD_LOCKS.get(key)
            if lock is None:
                lock = threading.Lock()
                _PAIR_THREAD_LOCKS[key] = lock
            return lock

    def _reconcile_persisted_pairs(
        self,
        snapshot: list[dict],
        pairs: set[tuple[str, str]],
        *,
        preferred_link: GraphLink | None = None,
    ) -> GraphLink | None:
        """Collapse persisted duplicates and synchronise this store's cache.

        ``_flush_links`` intentionally merges foreign IDs, so it can leave two
        IDs for one semantic pair when independent stores create concurrently.
        Re-read the durable rows after that flush, retain the first valid
        active/hidden row, and remove later duplicates while holding the normal
        file write lock. The in-memory loser is removed and the durable winner
        is indexed locally before the caller returns.

        A snapshot containing a discarded ID may already be queued behind the
        per-instance write lock. Advancing the sequence watermark invalidates
        that stale snapshot while allowing the next fresh snapshot through.
        """
        if not pairs:
            return None

        snapshot_ids = {row.get("id") for row in snapshot if isinstance(row, dict) and isinstance(row.get("id"), str)}
        canonical_by_pair: dict[tuple[str, str], GraphLink] = {}
        duplicate_ids: set[str] = set()

        with self._links_write_lock, path_write_lock(self.links_path):
            disk_sig = self._disk_signature(self.links_path)
            rows = self._read_json_list(self.links_path)
            retained: list[Any] = []
            changed = False
            for row in rows:
                if not isinstance(row, dict):
                    retained.append(row)
                    continue
                if row.get("status", "active") not in ("active", "hidden"):
                    retained.append(row)
                    continue
                from_id, to_id = row.get("from_id"), row.get("to_id")
                if not isinstance(from_id, str) or not isinstance(to_id, str):
                    retained.append(row)
                    continue
                pair = self._normalize_pair(from_id, to_id)
                if pair not in pairs:
                    retained.append(row)
                    continue
                try:
                    link = GraphLink.model_validate(row)
                except (TypeError, ValueError):
                    retained.append(row)
                    continue
                canonical = canonical_by_pair.get(pair)
                if canonical is None:
                    canonical_by_pair[pair] = link
                    retained.append(row)
                else:
                    changed = True
                    if link.id != canonical.id:
                        duplicate_ids.add(link.id)

            if changed:
                self._atomic_json_write(self.links_path, retained)
                # Only claim the new file as our sync point when the one we
                # rewrote already was; otherwise a foreign change it carried
                # would be hidden from the next flush (#2086).
                if disk_sig == self._links_disk_sig:
                    self._links_disk_sig = self._disk_signature(self.links_path)
                    self._synced_link_ids -= duplicate_ids

            with self._lock:
                removed_local = False
                local_by_pair: dict[tuple[str, str], list[str]] = {}
                if canonical_by_pair:
                    for link_id, managed in self._links.items():
                        if managed.status in ("active", "hidden"):
                            local_by_pair.setdefault(self._normalize_pair(managed.from_id, managed.to_id), []).append(
                                link_id
                            )
                for pair, canonical in canonical_by_pair.items():
                    for link_id in local_by_pair.get(pair, ()):
                        if link_id == canonical.id:
                            continue
                        managed = self._links.pop(link_id)
                        self._unindex_link(managed)
                        self._pending_link_ids.pop(link_id, None)
                        removed_local = True

                    cached = self._links.get(canonical.id)
                    if cached is None:
                        self._links[canonical.id] = canonical
                        self._index_link(canonical)
                    elif cached.status not in ("active", "hidden") and canonical.id not in self._pending_link_ids:
                        # An unflushed local status change (e.g. deprecated) wins over the stale disk copy.
                        self._links[canonical.id] = canonical
                        self._index_link(canonical)

                if removed_local or snapshot_ids.intersection(duplicate_ids):
                    current_sequence = getattr(self, "_links_snapshot_sequence", 0)
                    self._last_flushed_links_snapshot_sequence = max(
                        getattr(self, "_last_flushed_links_snapshot_sequence", 0),
                        current_sequence + 1,
                    )

        if preferred_link is None:
            return None
        preferred_pair = self._normalize_pair(preferred_link.from_id, preferred_link.to_id)
        return canonical_by_pair.get(preferred_pair)

    def _flush_links_and_reconcile(
        self,
        snapshot: list[dict],
        *,
        pair_locks: set[tuple[str, str]] | None = None,
        preferred_link: GraphLink | None = None,
        pre_reconcile: bool = True,
    ) -> GraphLink | None:
        """Flush links, then enforce semantic uniqueness for affected pairs."""
        pairs = pair_locks if pair_locks is not None else self._snapshot_link_pairs(snapshot)
        if pair_locks is None:
            self._flush_links(snapshot)
            return self._reconcile_persisted_pairs(snapshot, pairs, preferred_link=preferred_link)

        # Hold pair locks across the ordinary flush and reconciliation so two
        # same-pair creators cannot return different winners. Pair-scoping keeps
        # unrelated mutations independent, including delayed-flush tests.
        with ExitStack() as locks:
            for pair in sorted(pair_locks):
                locks.enter_context(self._pair_thread_lock(pair))
                locks.enter_context(path_write_lock(self._pair_lock_path(pair)))
            # A stale instance may already have a provisional link for a pair
            # that another instance persisted first. Reconcile before flushing
            # so the stale snapshot cannot put its provisional row first and
            # accidentally replace the durable winner.
            # A hard delete skips it: the row is gone locally on purpose, and
            # adopting the durable copy here would resurrect it.
            if pre_reconcile:
                self._reconcile_persisted_pairs(snapshot, pair_locks)
            with self._lock:
                snapshot = self._links_to_serializable()
            self._flush_links(snapshot)
            return self._reconcile_persisted_pairs(snapshot, pairs, preferred_link=preferred_link)

    def _persist_new_link(self, link: GraphLink, snapshot: list[dict]) -> GraphLink | None:
        """Persist a new link and return the durable winner for its pair."""
        pair = self._normalize_pair(link.from_id, link.to_id)
        with ExitStack() as locks:
            locks.enter_context(self._pair_thread_lock(pair))
            locks.enter_context(path_write_lock(self._pair_lock_path(pair)))

            # A stale store may already have a durable winner. Check before
            # flushing its provisional ID so a later request cannot replace
            # the winner merely because its snapshot lists its own ID first.
            winner = self._reconcile_persisted_pairs(snapshot, {pair}, preferred_link=link)
            if winner is not None:
                return winner if winner.id != link.id else None

            self._flush_links(snapshot)
            winner = self._reconcile_persisted_pairs(snapshot, {pair}, preferred_link=link)
        return winner if winner is not None and winner.id != link.id else None

    def add_link(
        self,
        from_id: str,
        to_id: str,
        kind: LinkKind,
        confidence: float,
        reason: str,
        *,
        source: str = "auto",
        require_live: Callable[[str], Any] | None = None,
    ) -> GraphLink:
        """Create and store a new link. Idempotent per pair across store instances.

        The sole caller (create_manual_link) does check-then-act: it reads
        find_link_between == None, runs a multi-second LLM call without holding
        _lock, then calls add_link. Two concurrent manual-link requests for the
        same pair therefore both reach add_link. Re-checking inside _lock closes
        the same-instance gap; _persist_new_link re-reads under the cross-process
        file lock so an already-persisted (active/hidden) pair returns the
        existing link instead of inserting a duplicate.

        ``require_live`` is called for both endpoints under ``_lock`` before the
        insert and may raise to refuse the link. The delete/archive path marks the
        card dead before ``cleanup_for_card`` takes ``_lock`` to deprecate its
        links, so a check and insert inside one critical section either sees the
        card dead or is deprecated by that cleanup; no live edge can survive it.
        """
        if from_id == to_id:
            raise ValueError("cannot link a card to itself")
        if not 0.0 <= confidence <= 1.0:
            raise ValueError("confidence must be between 0.0 and 1.0")
        link = GraphLink(
            from_id=from_id,
            to_id=to_id,
            kind=kind,
            confidence=confidence,
            reason=reason,
        )
        with self._lock:
            if require_live is not None:
                require_live(from_id)
                require_live(to_id)
            existing = self._find_link_between_unlocked(from_id, to_id)
            if existing is not None:
                return existing
            self._links[link.id] = link
            self._index_link(link)
            self._touch_links((link.id,))
            snapshot = self._links_to_serializable()
        try:
            existing = self._persist_new_link(link, snapshot)
        except BaseException:
            # Do not leave an un-persisted link visible as active in memory;
            # callers would otherwise treat a failed create as a success.
            with self._lock:
                if self._links.get(link.id) is link:
                    self._unindex_link(link)
                    del self._links[link.id]
                self._pending_link_ids.pop(link.id, None)
            raise
        if existing is not None:
            return existing
        self._emit_graph_event(
            "link_added",
            link_id=link.id,
            from_id=from_id,
            to_id=to_id,
            links_snapshot=snapshot,
            kind=str(kind),
            source=source,
            confidence_before=None,
            confidence_after=confidence,
            status_before=None,
            status_after="active",
            reason=reason,
        )
        return link

    def batch_add_links(
        self,
        links: list[tuple[str, str, LinkKind, float, str]],
        *,
        source: str = "auto",
    ) -> list[GraphLink]:
        """Create multiple links with a single disk write. Returns created links."""
        created: list[GraphLink] = []
        with self._lock:
            for from_id, to_id, kind, confidence, reason in links:
                if from_id == to_id:
                    raise ValueError("cannot link a card to itself")
                if not 0.0 <= confidence <= 1.0:
                    raise ValueError("confidence must be between 0.0 and 1.0")
                if self._has_link_unlocked(from_id, to_id):
                    continue
                link = GraphLink(
                    from_id=from_id,
                    to_id=to_id,
                    kind=kind,
                    confidence=confidence,
                    reason=reason,
                )
                self._links[link.id] = link
                self._index_link(link)
                created.append(link)
            self._touch_links(lk.id for lk in created)
            snapshot = self._links_to_serializable() if created else None
        if snapshot is not None:
            self._flush_links_and_reconcile(
                snapshot,
                pair_locks={self._normalize_pair(lk.from_id, lk.to_id) for lk in created},
            )
            # Reconciliation can discard a provisional link when a stale
            # GraphStore instance races with another writer for the same pair.
            # Only links still owned by this instance after reconciliation were
            # actually created by this batch; reporting the discarded object
            # would overcount pipeline work and emit an event for a dead ID.
            with self._lock:
                persisted_created = [link for link in created if self._links.get(link.id) is link]
                event_snapshot = self._links_to_serializable() if persisted_created else None
            self._emit_graph_events(
                [
                    self._build_graph_event_draft(
                        "link_added",
                        link_id=lk.id,
                        from_id=lk.from_id,
                        to_id=lk.to_id,
                        kind=str(lk.kind),
                        source=source,
                        confidence_before=None,
                        confidence_after=lk.confidence,
                        status_before=None,
                        status_after="active",
                        reason=lk.reason,
                    )
                    for lk in persisted_created
                ],
                links_snapshot=event_snapshot,
            )
            created = persisted_created
        return created

    def get_links_for(self, card_id: str) -> list[GraphLink]:
        """Get all active and hidden links involving a card."""
        # Lock: the index sets and _links are mutated by concurrent writers on the
        # same cached instance; reading them lock-free risks a KeyError when a
        # link was just hard-deleted between the index read and the dict lookup.
        with self._lock:
            link_ids = self._from_index.get(card_id, set()) | self._to_index.get(card_id, set())
            return [
                self._links[lid]
                for lid in link_ids
                if lid in self._links and self._links[lid].status in ("active", "hidden")
            ]

    def _has_link_unlocked(self, id_a: str, id_b: str) -> bool:
        """Check link existence without acquiring the lock (internal use)."""
        if self._normalize_pair(id_a, id_b) in self._blocked_pairs:
            return True
        candidates = self._from_index.get(id_a, set()) | self._to_index.get(id_a, set())
        for lid in candidates:
            lk = self._links.get(lid)
            if lk is None or lk.status not in ("active", "hidden"):
                continue
            if (lk.from_id == id_a and lk.to_id == id_b) or (lk.from_id == id_b and lk.to_id == id_a):
                return True
        return False

    def has_link(self, id_a: str, id_b: str) -> bool:
        """Check if a link exists between two cards (active or rejected counts)."""
        # _has_link_unlocked is the lock-free variant for internal callers that
        # already hold _lock; the public entry point must take the lock itself.
        with self._lock:
            return self._has_link_unlocked(id_a, id_b)

    def _find_link_between_unlocked(self, id_a: str, id_b: str) -> GraphLink | None:
        """Lock-free find of an active/hidden link for a pair (internal use).

        Callers must already hold _lock. The public find_link_between takes the
        lock; add_link reuses this while holding the lock to dedup in-place.
        """
        candidates = self._from_index.get(id_a, set()) | self._to_index.get(id_a, set())
        for lid in candidates:
            lk = self._links.get(lid)
            if lk is None or lk.status not in ("active", "hidden"):
                continue
            if (lk.from_id == id_a and lk.to_id == id_b) or (lk.from_id == id_b and lk.to_id == id_a):
                return lk
        return None

    def find_link_between(self, id_a: str, id_b: str) -> GraphLink | None:
        """Find active or hidden link between two cards (bidirectional). Returns None for deprecated/absent."""
        with self._lock:
            return self._find_link_between_unlocked(id_a, id_b)

    def get_link(self, link_id: str) -> GraphLink | None:
        """Return a link by ID, or None if not found."""
        # Take _lock to read _links: concurrent writers mutate the dict on the
        # same cached instance, so this mirrors get_links_for/find_link_between
        # rather than reading lock-free. All public callers (vocab_graph_ops)
        # invoke this outside _lock, so acquiring it here cannot deadlock.
        with self._lock:
            return self._links.get(link_id)

    def update_link(self, link_id: str, *, source: str = "auto", **attrs: Any) -> GraphLink:
        """Update attributes of an existing link and persist."""
        ALLOWED = {"status", "kind", "confidence", "reason"}
        self.refresh_if_stale()  # edit the other writer's row, not a stale copy (#2086)
        with self._lock:
            lk = self._links.get(link_id)
            if lk is None:
                raise KeyError(link_id)
            conf_before, status_before = lk.confidence, lk.status
            # Validate everything before the first setattr so a bad input never
            # leaves the cached link half-mutated (#2690).
            for key, value in attrs.items():
                if key not in ALLOWED:
                    raise ValueError(f"Cannot update attribute: {key}")
                if key == "confidence" and not 0.0 <= value <= 1.0:
                    raise ValueError("confidence must be between 0.0 and 1.0")
            for key, value in attrs.items():
                setattr(lk, key, value)
            conf_after, status_after = lk.confidence, lk.status
            reason_after = lk.reason
            from_id, to_id, kind = lk.from_id, lk.to_id, str(lk.kind)
            self._touch_links((link_id,))
            snapshot = self._links_to_serializable()
        self._flush_links_and_reconcile(snapshot, pair_locks={self._normalize_pair(from_id, to_id)})
        self._emit_graph_event(
            "link_updated",
            link_id=link_id,
            from_id=from_id,
            to_id=to_id,
            kind=kind,
            links_snapshot=snapshot,
            source=source,
            confidence_before=conf_before,
            confidence_after=conf_after,
            status_before=status_before,
            status_after=status_after,
            reason=reason_after,
        )
        return lk

    def hide_link(self, link_id: str, *, source: str = "auto") -> None:
        """Set link status to hidden. Raises KeyError if not found."""
        self.refresh_if_stale()
        with self._lock:
            lk = self._links.get(link_id)
            if lk is None:
                raise KeyError(link_id)
            status_before = lk.status
            lk.status = "hidden"
            from_id, to_id, kind, conf = lk.from_id, lk.to_id, str(lk.kind), lk.confidence
            self._touch_links((link_id,))
            snapshot = self._links_to_serializable()
        self._flush_links_and_reconcile(snapshot, pair_locks={self._normalize_pair(from_id, to_id)})
        self._emit_graph_event(
            "link_hidden",
            link_id=link_id,
            from_id=from_id,
            to_id=to_id,
            kind=kind,
            links_snapshot=snapshot,
            source=source,
            confidence_before=conf,
            confidence_after=conf,
            status_before=status_before,
            status_after="hidden",
        )

    def unhide_link(self, link_id: str, *, source: str = "auto") -> None:
        """Set link status back to active. Raises KeyError if not found."""
        self.refresh_if_stale()
        with self._lock:
            lk = self._links.get(link_id)
            if lk is None:
                raise KeyError(link_id)
            status_before = lk.status
            lk.status = "active"
            from_id, to_id, kind, conf = lk.from_id, lk.to_id, str(lk.kind), lk.confidence
            self._touch_links((link_id,))
            snapshot = self._links_to_serializable()
        self._flush_links_and_reconcile(snapshot, pair_locks={self._normalize_pair(from_id, to_id)})
        self._emit_graph_event(
            "link_unhidden",
            link_id=link_id,
            from_id=from_id,
            to_id=to_id,
            kind=kind,
            links_snapshot=snapshot,
            source=source,
            confidence_before=conf,
            confidence_after=conf,
            status_before=status_before,
            status_after="active",
        )

    def hard_delete_link(self, link_id: str, *, source: str = "auto") -> tuple[str, str]:
        """Delete a link and add the pair to blocked list. Returns (from_id, to_id)."""
        self.refresh_if_stale()
        with self._lock:
            lk = self._links.get(link_id)
            if lk is None:
                raise KeyError(link_id)
            from_id, to_id = lk.from_id, lk.to_id
            kind, conf, status_before = str(lk.kind), lk.confidence, lk.status
            pair = self._normalize_pair(from_id, to_id)
            newly_blocked = pair not in self._blocked_pairs
            self._blocked_pairs.add(pair)
            # Register so a later _flush_blocked merge treats this pair as
            # managed by this instance (a subsequent unblock is honoured).
            self._known_blocked_pairs.add(pair)
            self._touch_blocked((pair,))
            blocked_snapshot = self._blocked_to_serializable()
        # Persist the block first (#2690): if it fails the link is still intact,
        # so the caller can retry instead of hitting a 404 with no durable block.
        try:
            self._flush_blocked(blocked_snapshot)
        except BaseException:
            if newly_blocked:
                with self._lock:
                    self._blocked_pairs.discard(pair)
                    self._touch_blocked((pair,))
            raise
        with self._lock:
            lk = self._links.get(link_id)
            if lk is None:
                raise KeyError(link_id)
            self._unindex_link(lk)
            del self._links[link_id]
            self._touch_links((link_id,))
            links_snapshot = self._links_to_serializable()
        self._flush_links_and_reconcile(
            links_snapshot, pair_locks={self._normalize_pair(from_id, to_id)}, pre_reconcile=False
        )
        self._emit_graph_event(
            "link_deleted",
            link_id=link_id,
            from_id=from_id,
            to_id=to_id,
            kind=kind,
            links_snapshot=links_snapshot,
            source=source,
            confidence_before=conf,
            confidence_after=None,
            status_before=status_before,
            status_after=None,
        )
        return (from_id, to_id)

    def is_blocked(self, from_id: str, to_id: str) -> bool:
        """Check if a pair is blocked."""
        return self._normalize_pair(from_id, to_id) in self._blocked_pairs

    def remove_blocked_pairs_for(self, card_id: str) -> None:
        """Remove all blocked pairs involving a card."""
        with self._lock:
            removed = {pair for pair in self._blocked_pairs if card_id in pair}
            self._blocked_pairs = self._blocked_pairs - removed
            self._touch_blocked(removed)
            snapshot = self._blocked_to_serializable()
        self._flush_blocked(snapshot)

    def unblock_pair(self, from_id: str, to_id: str) -> None:
        """Remove a specific blocked pair."""
        with self._lock:
            pair = self._normalize_pair(from_id, to_id)
            self._blocked_pairs.discard(pair)
            self._touch_blocked((pair,))
            snapshot = self._blocked_to_serializable()
        self._flush_blocked(snapshot)

    def all_links(self) -> list[GraphLink]:
        # Return a snapshot list taken under the lock, not a lazy view: iterating
        # _links.values() while a writer inserts raises "dictionary changed size
        # during iteration".
        with self._lock:
            return list(self._links.values())

    def link_count(self) -> int:
        with self._lock:
            return sum(1 for lk in self._links.values() if lk.status == "active")
