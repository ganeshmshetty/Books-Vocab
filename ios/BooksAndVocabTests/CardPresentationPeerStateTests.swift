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
        #expect(try #require(state.preparedCardCache[source.id]).linkGroups.flatMap(\.items).count == 1)

        b.isArchived = true
        state.refreshPeerDependentCards()
        #expect(try #require(state.preparedCardCache[source.id]).linkGroups.isEmpty)

        b.isArchived = false
        state.refreshPeerDependentCards()
        #expect(try #require(state.preparedCardCache[source.id]).linkGroups.flatMap(\.items).count == 1)
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
