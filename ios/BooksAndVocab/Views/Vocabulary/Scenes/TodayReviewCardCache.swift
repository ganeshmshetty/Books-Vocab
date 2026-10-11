import Foundation

struct TodayReviewCardCache {
    typealias PreparedCard = TodayReviewPresenterState.CurrentCard

    private(set) var storage: [UUID: PreparedCard] = [:]

    /// Non-mutating render-path lookup. MUST stay non-`mutating`: it is called from
    /// `TodayReviewState.currentCardState`/`nextCardState` during SwiftUI body
    /// evaluation, and `cardCache` is an `@Observable` stored property. A `mutating`
    /// call here goes through the synthesized `_modify` accessor, which fires a
    /// spurious per-render mutation notification (even on a cache hit, even when
    /// storage doesn't change) → body reads+writes the same property → infinite
    /// re-eval loop. Build/store happens only off-body via `prewarm`/`rebuild`.
    func cached(for entry: VocabularyEntry) -> PreparedCard? {
        if let card = storage[entry.id] {
            PerfLog.review.tick("card.cacheHit", "w=\(entry.word)")
            return card
        }
        PerfLog.review.tick("card.cacheMiss", "w=\(entry.word)")
        return nil
    }

    mutating func rebuild(
        for entry: VocabularyEntry,
        pendingLinks: [KGCardLinkSummary]? = nil,
        peers: [String: VocabularyEntry] = [:]
    ) {
        let card = CardPresentation(entry: entry, pendingLinks: pendingLinks, peerLookup: peers)
        let linkGroups = card.activeLinkGroups.map { Self.reviewLinkGroup($0.pendingFirst()) }
        let backDocument = card.document.reviewBackSubset()
        storage[entry.id] = .init(
            card: card,
            linkGroups: linkGroups,
            backDocument: backDocument,
            measurementCache: .init()
        )
    }

    /// Pending-creation updates (a job starts, creating -> failed, warning, removed).
    /// Swaps only the card's link content and KEEPS its `measurementCache`: a full
    /// `rebuild` would drop every measured section height, so a card on screen
    /// (even with its back revealed) re-solves from defaults and jumps for a frame
    /// (#2133). The only measurement that can go stale is the graph-links section,
    /// and only when the set of link items changed (a creating -> failed flip keeps
    /// the same ids, hence the same strip), so just that section is re-measured.
    /// Existing items keep their on-screen order; new ones follow `pendingFirst`.
    /// A card that is not cached falls back to `rebuild`: dropping the update would
    /// leave the card stale until the next prewarm (the old rebuild self-healed).
    /// - Parameter pendingLinks: `nil` reads the app-wide `PendingLinkProjection`;
    ///   tests pass an explicit list to stay deterministic.
    mutating func refreshLinks(
        for entry: VocabularyEntry,
        pendingLinks: [KGCardLinkSummary]? = nil,
        peers: [String: VocabularyEntry] = [:]
    ) {
        guard let existing = storage[entry.id] else {
            rebuild(for: entry, pendingLinks: pendingLinks, peers: peers)
            return
        }
        let card = CardPresentation(entry: entry, pendingLinks: pendingLinks, peerLookup: peers)
        let previousOrder = existing.linkGroups
            .flatMap(\.items)
            .enumerated()
            .reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        let linkGroups = card.activeLinkGroups.map { group in
            let stable = group.items.enumerated().sorted { lhs, rhs in
                let l = previousOrder[lhs.element.id] ?? Int.max
                let r = previousOrder[rhs.element.id] ?? Int.max
                return l == r ? lhs.offset < rhs.offset : l < r
            }.map(\.element)
            return Self.reviewLinkGroup(
                CardLinkGroupPresentation(id: group.id, label: group.label, items: stable).pendingFirst()
            )
        }
        if Self.linkIdentity(of: linkGroups) != Self.linkIdentity(of: existing.linkGroups) {
            existing.measurementCache.invalidateGraphLinksMeasurements()
        }
        storage[entry.id] = .init(
            card: card,
            linkGroups: linkGroups,
            backDocument: card.document.reviewBackSubset(),
            measurementCache: existing.measurementCache
        )
    }

    private static func linkIdentity(of groups: [ReviewCardLinkGroup]) -> Set<String> {
        Set(groups.flatMap { group in group.items.map { group.id + "/" + $0.id } })
    }

    mutating func prewarm(
        queue: [VocabularyEntry],
        currentIndex: Int,
        lookaheadLimit: Int,
        peers: [String: VocabularyEntry] = [:]
    ) {
        guard !queue.isEmpty, currentIndex < queue.count else {
            storage.removeAll(keepingCapacity: false)
            return
        }

        let start = max(currentIndex - 1, 0)
        let end = min(currentIndex + lookaheadLimit, queue.count - 1)
        let visibleEntries = Array(queue[start...end])
        let visibleIDs = Set(visibleEntries.map(\.id))

        storage = storage.filter { visibleIDs.contains($0.key) }

        let missingEntries = visibleEntries.filter { storage[$0.id] == nil }
        guard !missingEntries.isEmpty else { return }
        storage.merge(Self.build(from: missingEntries, peers: peers)) { current, _ in current }
    }

    static func build(from entries: [VocabularyEntry], peers: [String: VocabularyEntry] = [:]) -> [UUID: PreparedCard] {
        var cache: [UUID: PreparedCard] = [:]
        cache.reserveCapacity(entries.count)
        PerfLog.review.mark("prewarm.build", "count=\(entries.count)")
        for entry in entries {
            cache[entry.id] = buildOne(entry, peers: peers)
        }
        return cache
    }

    /// Pure single-card builder (no storage write). Shared by `build` (prewarm) and
    /// the non-mutating render-miss fallback in `TodayReviewState.cachedOrBuildCard`.
    static func buildOne(_ entry: VocabularyEntry, peers: [String: VocabularyEntry] = [:]) -> PreparedCard {
        let (card, _) = PerfLog.review.measure("prewarm.card", "w=\(entry.word)") {
            CardPresentation(entry: entry, peerLookup: peers)
        }
        let linkGroups = card.activeLinkGroups.map { Self.reviewLinkGroup($0.shuffled().pendingFirst()) }
        let backDocument = card.document.reviewBackSubset()
        return .init(
            card: card,
            linkGroups: linkGroups,
            backDocument: backDocument,
            measurementCache: .init()
        )
    }

    /// The prepared card keeps EVERY active link of the group, in display order
    /// (pending first). How many show beside the label, and the "+N", is decided
    /// at render time by `ReviewCardLinkStripLayout` — truncating here made the
    /// "+N" impossible to expand (#2043).
    private static func reviewLinkGroup(_ group: CardLinkGroupPresentation) -> ReviewCardLinkGroup {
        ReviewCardLinkGroup(id: group.id, label: group.label, items: group.items, overflowCount: 0)
    }
}
