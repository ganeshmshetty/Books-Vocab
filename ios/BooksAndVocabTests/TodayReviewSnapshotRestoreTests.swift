//
//  TodayReviewSnapshotRestoreTests.swift
//  Books & Vocab Tests
//
//  Issue #2484: 還原快照的兩個陷阱。
//    1. 同一 persistenceID 出現兩筆 VocabularyEntry（sync 競態）→ Dictionary(uniqueKeysWithValues:)
//       trap；重複 ID 必須去重且不重複入列。
//    2. 佇列中一張卡遺失 → 舊實作整份快照清除，其他卡尚未 flush 的答案一併遺失。
//       必須 partial restore：保留存活卡與其答案，並把 index 重映射到新佇列。
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
@Suite("TodayReviewSnapshotRestore")
struct TodayReviewSnapshotRestoreTests {
    private let userId = "snapshot-restore-2484"

    private func makeEntry(_ name: String, kgCardId: String) -> VocabularyEntry {
        let entry = VocabularyEntry(word: name, translation: "t-\(name)", context: "c", bookTitle: "b")
        entry.kgCardId = kgCardId
        entry.markSynced()
        return entry
    }

    private func answer(_ feedback: ReviewFeedback, at date: Date, flushed: Bool = false) -> TodayReviewState.SubmittedAnswer {
        TodayReviewState.SubmittedAnswer(
            feedback: feedback,
            answeredAt: date,
            reviewRecordID: UUID(),
            flushed: flushed
        )
    }

    private func cleanUp() {
        TodayReviewSessionSnapshotStore.clear(for: userId)
        ReviewSessionStore.clear(userID: userId)
    }

    // MARK: - Duplicate persistence ids

    @Test func duplicatePersistenceIDsAreCollapsedToTheFirstEntry() {
        cleanUp()
        defer { cleanUp() }
        let first = makeEntry("dup-first", kgCardId: "card-dup")
        let second = makeEntry("dup-second", kgCardId: "card-dup")
        let other = makeEntry("other", kgCardId: "card-other")
        ReviewSessionPersistence.persistSnapshot(
            userId: userId,
            sessionStartTime: Date(),
            currentIndex: 0,
            queueCount: 2,
            queuePersistenceIDs: ["kg:card-dup", "kg:card-other"],
            queueBaselines: [
                ReviewSessionPersistence.makeBaseline(from: first),
                ReviewSessionPersistence.makeBaseline(from: other),
            ],
            submittedAnswers: [:]
        )

        let restored = ReviewSessionPersistence.restoreSnapshotIfPossible(
            orderedEntries: [first, second, other],
            userId: userId
        )

        #expect(restored?.persistenceIDs == ["kg:card-dup", "kg:card-other"])
        #expect(restored?.queue.count == 2)
        #expect(restored?.queue.first === first)
    }

    @Test func duplicateIDsInSnapshotQueueOccupyOneSlotAndNoDoubleAnswer() {
        cleanUp()
        defer { cleanUp() }
        let a = makeEntry("a", kgCardId: "card-a")
        let b = makeEntry("b", kgCardId: "card-b")
        let now = Date()
        // 快照內 index 1 重複 index 0 的 persistenceID：第二個出現視為遺失。
        ReviewSessionPersistence.persistSnapshot(
            userId: userId,
            sessionStartTime: now,
            currentIndex: 0,
            queueCount: 3,
            queuePersistenceIDs: ["kg:card-a", "kg:card-a", "kg:card-b"],
            queueBaselines: [a, a, b].map(ReviewSessionPersistence.makeBaseline(from:)),
            submittedAnswers: [
                0: answer(.remembered, at: now),
                1: answer(.forgot, at: now),
                2: answer(.forgot, at: now),
            ]
        )

        let restored = ReviewSessionPersistence.restoreSnapshotIfPossible(
            orderedEntries: [a, b],
            userId: userId
        )

        #expect(restored?.persistenceIDs == ["kg:card-a", "kg:card-b"])
        #expect(restored?.queue.count == 2)
        // 重複槽的答案不得再映射成第二次評分。
        #expect(restored?.submittedAnswers.count == 2)
        #expect(restored?.submittedAnswers[0]?.feedback == .remembered)
        #expect(restored?.submittedAnswers[1]?.feedback == .forgot)
        #expect(restored?.rememberedCount == 1)
        #expect(restored?.forgotCount == 1)
    }

    @Test func loadOrderCollapsesDuplicatePersistenceIDs() {
        cleanUp()
        defer { cleanUp() }
        let suite = "snapshot-restore-2484-order-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeEntry("dup-first", kgCardId: "card-dup")
        let second = makeEntry("dup-second", kgCardId: "card-dup")
        let other = makeEntry("other", kgCardId: "card-other")
        ReviewSessionStore.saveOrder([first, second, other], userID: userId, defaults: defaults)

        let ordered = ReviewSessionStore.loadOrder(
            availableEntries: [first, second, other],
            userID: userId,
            allowPartialQueue: true,
            defaults: defaults
        )

        #expect(ordered?.count == 2)
        #expect(ordered?.first === first)
        #expect(ordered?.last === other)
    }

    @Test func todayReviewStateCollapsesDuplicateKgCardIdIntoOneSlot() {
        cleanUp()
        defer { cleanUp() }
        let first = makeEntry("dup-first", kgCardId: "card-dup")
        let second = makeEntry("dup-second", kgCardId: "card-dup")
        let other = makeEntry("other", kgCardId: "card-other")

        let state = TodayReviewState(
            entries: [first, second, other],
            allEntries: [first, second, other],
            currentUserID: userId
        )

        #expect(state.queue.count == 2)
        #expect(state.queue.first === first)
    }

    @Test func uniqueByPersistenceIDWinnerIsIndependentOfInputOrder() {
        let older = makeEntry("dup-older", kgCardId: "card-dup")
        let newer = makeEntry("dup-newer", kgCardId: "card-dup")
        older.dateAdded = Date(timeIntervalSince1970: 1_000)
        newer.dateAdded = Date(timeIntervalSince1970: 2_000)
        let other = makeEntry("other", kgCardId: "card-other")

        let forward = ReviewSessionPersistence.uniqueByPersistenceID([older, newer, other])
        let reversed = ReviewSessionPersistence.uniqueByPersistenceID([other, newer, older])

        // 勝者由 dateAdded 決定（最早者），與 fetch 順序無關；結果仍保持輸入的相對順序。
        #expect(forward.map(\.word) == ["dup-older", "other"])
        #expect(reversed.map(\.word) == ["other", "dup-older"])
    }

    // MARK: - Missing queued card

    @Test func missingQueuedCardKeepsSurvivingAnswersAndRemapsIndices() {
        cleanUp()
        defer { cleanUp() }
        let a = makeEntry("a", kgCardId: "card-a")
        let gone = makeEntry("gone", kgCardId: "card-gone")
        let b = makeEntry("b", kgCardId: "card-b")
        let now = Date()
        ReviewSessionPersistence.persistSnapshot(
            userId: userId,
            sessionStartTime: now,
            currentIndex: 2,
            queueCount: 3,
            queuePersistenceIDs: ["kg:card-a", "kg:card-gone", "kg:card-b"],
            queueBaselines: [a, gone, b].map(ReviewSessionPersistence.makeBaseline(from:)),
            submittedAnswers: [
                0: answer(.remembered, at: now),
                2: answer(.forgot, at: now),
            ]
        )

        // gone 已從資料庫消失：其餘卡的未 flush 答案不得被整份丟棄。
        let restored = ReviewSessionPersistence.restoreSnapshotIfPossible(
            orderedEntries: [a, b],
            userId: userId
        )

        #expect(restored != nil)
        #expect(restored?.persistenceIDs == ["kg:card-a", "kg:card-b"])
        #expect(restored?.submittedAnswers[0]?.feedback == .remembered)
        #expect(restored?.submittedAnswers[1]?.feedback == .forgot)
        #expect(restored?.submittedAnswers[1]?.flushed == false)
        #expect(restored?.submittedAnswers.count == 2)
        #expect(restored?.rememberedCount == 1)
        #expect(restored?.forgotCount == 1)
        // currentIndex 指向原本的 b（index 2），去掉 gone 後應為 1。
        #expect(restored?.currentIndex == 1)
    }

    @Test func missingCardWithOnlyFlushedAnswersStillClearsSnapshot() {
        cleanUp()
        defer { cleanUp() }
        let a = makeEntry("a", kgCardId: "card-a")
        let gone = makeEntry("gone", kgCardId: "card-gone")
        let b = makeEntry("b", kgCardId: "card-b")
        let now = Date()
        ReviewSessionPersistence.persistSnapshot(
            userId: userId,
            sessionStartTime: now,
            currentIndex: 2,
            queueCount: 3,
            queuePersistenceIDs: ["kg:card-a", "kg:card-gone", "kg:card-b"],
            queueBaselines: [a, gone, b].map(ReviewSessionPersistence.makeBaseline(from:)),
            submittedAnswers: [
                0: answer(.remembered, at: now, flushed: true),
            ]
        )

        // 沒有任何仍存活卡的未 flush 答案 → 維持舊行為：清除快照、回傳 nil。
        let restored = ReviewSessionPersistence.restoreSnapshotIfPossible(
            orderedEntries: [a, b],
            userId: userId
        )

        #expect(restored == nil)
        #expect(TodayReviewSessionSnapshotStore.load(for: userId) == nil)
    }

    @Test func allQueuedCardsMissingClearsTheSnapshot() {
        cleanUp()
        defer { cleanUp() }
        let gone = makeEntry("gone", kgCardId: "card-gone")
        ReviewSessionPersistence.persistSnapshot(
            userId: userId,
            sessionStartTime: Date(),
            currentIndex: 0,
            queueCount: 1,
            queuePersistenceIDs: ["kg:card-gone"],
            queueBaselines: [ReviewSessionPersistence.makeBaseline(from: gone)],
            submittedAnswers: [:]
        )

        let restored = ReviewSessionPersistence.restoreSnapshotIfPossible(
            orderedEntries: [makeEntry("unrelated", kgCardId: "card-unrelated")],
            userId: userId
        )

        #expect(restored == nil)
        #expect(TodayReviewSessionSnapshotStore.load(for: userId) == nil)
    }
}
