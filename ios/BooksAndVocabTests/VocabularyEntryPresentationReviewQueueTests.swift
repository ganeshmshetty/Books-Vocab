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
        first.dateAdded = now.addingTimeInterval(-7200)
        second.dateAdded = now.addingTimeInterval(-3600)

        let projection = VocabularyEntryPresentation.project(
            [first, second],
            query: VocabularyLibraryQuery(),
            now: now
        )

        #expect(projection.reviewQueue.due.count == 1)
        #expect(projection.reviewQueue.due.first?.id == first.id)
    }

    /// #3059 (1) P2 regression: 代表列規則必須與今日複習一致（`ReviewSessionPersistence.representative(among:)`）。
    /// 較晚加入但未學的列排在前，較早加入且到期的列才是代表；庫的 due 桶必須保留它，不可因輸入順序丟掉。
    @Test("重複列的代表與今日複習一致：較早加入的到期列勝出，不因輸入順序")
    func duplicateRepresentativeMatchesTodayRuleRegardlessOfInputOrder() {
        let unlearned = VocabularyEntry(word: "dup", translation: "t", context: "c", bookTitle: "b")
        unlearned.markSynced()
        unlearned.kgCardId = "card-2"
        unlearned.dateAdded = now.addingTimeInterval(-600)

        let due = makeDueSyncedEntry("dup", kgCardId: "card-2")
        due.dateAdded = now.addingTimeInterval(-7200)

        let projection = VocabularyEntryPresentation.project(
            [unlearned, due],
            query: VocabularyLibraryQuery(),
            now: now
        )

        #expect(ReviewSessionPersistence.representative(among: [unlearned, due])?.id == due.id)
        #expect(projection.reviewQueue.due.map(\.id) == [due.id])
        #expect(projection.reviewQueue.unlearned.isEmpty)
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
