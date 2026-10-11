import Foundation
import Testing
@testable import BooksAndVocab

/// Pins `VocabularyEntryPresentation.project(_:query:now:)` review queue
/// (#3059 (1)): one server card contributes at most one review row.
@Suite("VocabularyEntryPresentation review queue")
@MainActor
struct VocabularyEntryPresentationReviewQueueTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 已同步、已複習過且到期的卡（`reviewState(at:) == .due`，且 `shouldAppearInReview`）。
    private func makeDueSyncedEntry(_ word: String, kgCardId: String?) -> VocabularyEntry {
        let entry = VocabularyEntry(word: word, translation: "t", context: "c", bookTitle: "b")
        entry.markSynced()
        entry.kgCardId = kgCardId
        entry.reviewCount = 1
        entry.nextReviewAt = now.addingTimeInterval(-3600)
        return entry
    }

    @Test("同一 kgCardId 的重複列在複習佇列只出現一次")
    func duplicateRowsSharingCardIdAppearOnceInDueQueue() {
        let first = makeDueSyncedEntry("dup", kgCardId: "card-1")
        let second = makeDueSyncedEntry("dup", kgCardId: "card-1")

        let projection = VocabularyEntryPresentation.project(
            [first, second],
            query: VocabularyLibraryQuery(),
            now: now
        )

        #expect(projection.reviewQueue.due.count == 1)
        #expect(projection.reviewQueue.due.first?.id == first.id)
    }

    @Test("沒有 kgCardId 的列彼此不視為重複")
    func rowsWithoutCardIdAreNotDeduplicated() {
        let a = makeDueSyncedEntry("alpha", kgCardId: nil)
        let b = makeDueSyncedEntry("beta", kgCardId: nil)

        let projection = VocabularyEntryPresentation.project(
            [a, b],
            query: VocabularyLibraryQuery(),
            now: now
        )

        #expect(projection.reviewQueue.due.count == 2)
    }
}
