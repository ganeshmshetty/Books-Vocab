import Testing
@testable import BooksAndVocab

/// #2535 — link chips must not point at peers the user archived or queued for
/// delete locally; restoring the peer restores the chip.
@MainActor
struct CardPresentationPeerStateTests {
    private static func entry(_ word: String, cardId: String) -> VocabularyEntry {
        let entry = VocabularyEntry(word: word, translation: "t", context: "c", bookTitle: "Sample")
        entry.kgCardId = cardId
        return entry
    }

    private static func source(linkingTo peers: [String]) -> VocabularyEntry {
        let source = entry("source", cardId: "src")
        source.graphLinksByKind = ["shares_usage": peers.map {
            KGCardLinkSummary(id: "l-\($0)", cardId: $0, word: $0, kind: "shares_usage",
                              label: "共用用法", confidence: 1, reason: "r")
        }]
        return source
    }

    @Test func archivedPeerChipIsDroppedAndCountExcludesIt() {
        let source = Self.source(linkingTo: ["b", "c"])
        let b = Self.entry("b", cardId: "b")
        let c = Self.entry("c", cardId: "c")
        b.isArchived = true
        let card = CardPresentation(entry: source, pendingLinks: [], peerLookup: ["b": b, "c": c])
        #expect(card.linkGroups.flatMap(\.items).map(\.cardId) == ["c"])
        #expect(card.activeLinkGroups.flatMap(\.items).map(\.cardId) == ["c"])
        #expect(card.totalLinkCount == 1)
    }

    @Test func deleteQueuedPeerChipIsDropped() {
        let source = Self.source(linkingTo: ["b"])
        let b = Self.entry("b", cardId: "b")
        b.syncAction = .delete
        let card = CardPresentation(entry: source, pendingLinks: [], peerLookup: ["b": b])
        #expect(card.linkGroups.isEmpty)
        #expect(card.totalLinkCount == 0)
    }

    @Test func unarchivingPeerRestoresChip() {
        let source = Self.source(linkingTo: ["b"])
        let b = Self.entry("b", cardId: "b")
        b.isArchived = true
        #expect(CardPresentation(entry: source, pendingLinks: [], peerLookup: ["b": b]).totalLinkCount == 0)
        b.isArchived = false
        #expect(CardPresentation(entry: source, pendingLinks: [], peerLookup: ["b": b]).totalLinkCount == 1)
    }

    @Test func unknownPeerChipIsKept() {
        let source = Self.source(linkingTo: ["b"])
        let card = CardPresentation(entry: source, pendingLinks: [], peerLookup: [:])
        #expect(card.totalLinkCount == 1)
    }

    @Test func wordDetailStateExcludesArchivedPeerFromNavigableIDsAndCount() {
        let source = Self.source(linkingTo: ["b", "c"])
        let b = Self.entry("b", cardId: "b")
        let c = Self.entry("c", cardId: "c")
        b.isArchived = true
        let state = WordDetailPresentation.state(for: source, in: [source, b, c])
        #expect(state.navigableLinkCardIDs == ["c"])
        #expect(state.card.totalLinkCount == 1)
    }

    @Test func reviewCacheBuildHonoursPeerState() {
        let source = Self.source(linkingTo: ["b"])
        let b = Self.entry("b", cardId: "b")
        b.isArchived = true
        let prepared = TodayReviewCardCache.buildOne(source, peers: ["b": b])
        #expect(prepared.linkGroups.isEmpty)
    }

    /// #2535 review path: the prewarmed card must honour peers that are already
    /// archived when the session starts (the bug: prewarm passed no peers).
    @Test func reviewSessionPrewarmDropsArchivedPeerChip() throws {
        let source = Self.source(linkingTo: ["b"])
        source.markSynced()
        let b = Self.entry("b", cardId: "b")
        b.isArchived = true
        let state = TodayReviewState(entries: [source], allEntries: [source, b], currentUserID: nil)
        let card = try #require(state.preparedCardCache[source.id])
        #expect(card.linkGroups.isEmpty)
    }

    /// #2535: archiving a peer while the session is open must drop the chip on
    /// refresh, and a rolled-back archive must bring it back.
    @Test func peerArchiveAndRollbackUpdatesReviewCardChips() throws {
        let source = Self.source(linkingTo: ["b"])
        source.markSynced()
        let b = Self.entry("b", cardId: "b")
        let state = TodayReviewState(entries: [source], allEntries: [source, b], currentUserID: nil)
        let before = try #require(state.preparedCardCache[source.id])
        #expect(before.linkGroups.flatMap(\.items).count == 1)

        b.isArchived = true
        state.refreshPeerDependentCards()
        let archived = try #require(state.preparedCardCache[source.id])
        #expect(archived.linkGroups.isEmpty)

        b.isArchived = false
        state.refreshPeerDependentCards()
        let restored = try #require(state.preparedCardCache[source.id])
        #expect(restored.linkGroups.flatMap(\.items).count == 1)
    }

    /// #2535: a delete-queued peer is dropped from the review prewarm as well, not only archived ones.
    @Test func reviewSessionPrewarmDropsDeleteQueuedPeerChip() throws {
        let source = Self.source(linkingTo: ["b"])
        source.markSynced()
        let b = Self.entry("b", cardId: "b")
        b.syncAction = .delete
        let state = TodayReviewState(entries: [source], allEntries: [source, b], currentUserID: nil)
        let card = try #require(state.preparedCardCache[source.id])
        #expect(card.linkGroups.isEmpty)
    }

    /// #2535: a delete-queued peer's chip is removed on refresh and restored after rollback.
    @Test func peerDeleteQueueAndRollbackUpdatesReviewCardChips() throws {
        let source = Self.source(linkingTo: ["b"])
        source.markSynced()
        let b = Self.entry("b", cardId: "b")
        let state = TodayReviewState(entries: [source], allEntries: [source, b], currentUserID: nil)
        #expect(try #require(state.preparedCardCache[source.id]).linkGroups.flatMap(\.items).count == 1)

        b.syncAction = .delete
        state.refreshPeerDependentCards()
        #expect(try #require(state.preparedCardCache[source.id]).linkGroups.isEmpty)

        b.syncAction = .add
        state.refreshPeerDependentCards()
        #expect(try #require(state.preparedCardCache[source.id]).linkGroups.flatMap(\.items).count == 1)
    }

    /// #2535: an optimistic archive whose request fails is rolled back after the overlay
    /// has already closed. Nothing touches the overlay stack then, so the fingerprint the
    /// view watches is what brings the chip back.
    @Test func archiveRolledBackAfterOverlayClosedRestoresChip() throws {
        let source = Self.source(linkingTo: ["b"])
        source.markSynced()
        let b = Self.entry("b", cardId: "b")
        let state = TodayReviewState(entries: [source], allEntries: [source, b], currentUserID: nil)
        let linked = state.peerChipFingerprint

        b.isArchived = true
        state.refreshPeerDependentCards()
        #expect(try #require(state.preparedCardCache[source.id]).linkGroups.isEmpty)
        let archived = state.peerChipFingerprint
        #expect(archived != linked)

        b.isArchived = false
        #expect(state.peerChipFingerprint != archived)
        state.refreshPeerDependentCards()
        #expect(try #require(state.preparedCardCache[source.id]).linkGroups.flatMap(\.items).count == 1)
    }

    /// #2535: the fingerprint watches only the peers the queue links to, so an unrelated
    /// card's archive does not trigger a chip rebuild.
    @Test func peerChipFingerprintIgnoresUnlinkedEntries() {
        let source = Self.source(linkingTo: ["b"])
        source.markSynced()
        let b = Self.entry("b", cardId: "b")
        let stranger = Self.entry("x", cardId: "x")
        let state = TodayReviewState(entries: [source], allEntries: [source, b, stranger], currentUserID: nil)
        let before = state.peerChipFingerprint

        stranger.isArchived = true
        #expect(state.peerChipFingerprint == before)
    }

    /// #2133 + #2535: a peer change re-derives the on-screen card's chips in place and
    /// keeps its measurement cache, so the card does not jump.
    @Test func peerRefreshKeepsPreparedCardMeasurements() throws {
        let source = Self.source(linkingTo: ["b"])
        source.markSynced()
        let b = Self.entry("b", cardId: "b")
        let state = TodayReviewState(entries: [source], allEntries: [source, b], currentUserID: nil)
        let before = try #require(state.preparedCardCache[source.id])
        before.measurementCache.recordFront(ReviewCardFrontMeasurement(height: 240, cardKey: "k"))

        b.isArchived = true
        state.refreshPeerDependentCards()
        let after = try #require(state.preparedCardCache[source.id])
        #expect(after.measurementCache === before.measurementCache)
        #expect(after.measurementCache.measuredFrontHeight == 240)
        #expect(after.linkGroups.isEmpty)
    }

    /// #2535: a stale chip tapped after its peer was delete-queued must not open the peer.
    @Test func navigatingToDeleteQueuedPeerIsRefused() {
        let source = Self.source(linkingTo: ["b"])
        source.markSynced()
        let b = Self.entry("b", cardId: "b")
        let state = TodayReviewState(entries: [source], allEntries: [source, b], currentUserID: nil)
        b.syncAction = .delete
        let link = KGCardLinkSummary(id: "l-b", cardId: "b", word: "b", kind: "shares_usage",
                                     label: "共用用法", confidence: 1, reason: "r")
        state.navigateToLinkedCard(link: link)
        #expect(state.linkedCardStack.isEmpty)
    }

    /// #2535: a stale chip tapped after its peer was archived must not open the peer.
    @Test func navigatingToArchivedPeerIsRefused() {
        let source = Self.source(linkingTo: ["b"])
        source.markSynced()
        let b = Self.entry("b", cardId: "b")
        let state = TodayReviewState(entries: [source], allEntries: [source, b], currentUserID: nil)
        b.isArchived = true
        let link = KGCardLinkSummary(id: "l-b", cardId: "b", word: "b", kind: "shares_usage",
                                     label: "共用用法", confidence: 1, reason: "r")
        state.navigateToLinkedCard(link: link)
        #expect(state.linkedCardStack.isEmpty)
    }
}
