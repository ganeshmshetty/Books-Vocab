import Testing
@testable import BooksAndVocab

/// #2734 — the linked-card stack must never hold the same entry twice, otherwise
/// `ForEach(stack, id: \.element.id)` renders duplicate identities.
@MainActor
struct LinkedCardOverlayStackPushTests {
    private static func entry(_ word: String) -> VocabularyEntry {
        VocabularyEntry(word: word, translation: "t", context: "c", bookTitle: "b")
    }

    @Test func pushingDistinctEntriesAppendsInOrder() {
        let (a, b, c) = (Self.entry("a"), Self.entry("b"), Self.entry("c"))
        var stack: [VocabularyEntry] = []
        stack.pushLinkedCard(a)
        stack.pushLinkedCard(b)
        stack.pushLinkedCard(c)
        #expect(stack.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func pushB_C_B_keepsIdsUniqueAndClosesNestedLayers() {
        let (b, c) = (Self.entry("b"), Self.entry("c"))
        var stack: [VocabularyEntry] = []
        stack.pushLinkedCard(b)
        stack.pushLinkedCard(c)
        stack.pushLinkedCard(b)
        #expect(stack.map(\.id) == [b.id])
        #expect(Set(stack.map(\.id)).count == stack.count)
    }

    @Test func pushingTopEntryAgainIsNoOp() {
        let (a, b) = (Self.entry("a"), Self.entry("b"))
        var stack = [a, b]
        stack.pushLinkedCard(b)
        #expect(stack.map(\.id) == [a.id, b.id])
    }
}
