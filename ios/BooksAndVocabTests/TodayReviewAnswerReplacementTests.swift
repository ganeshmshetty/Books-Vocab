//
//  TodayReviewAnswerReplacementTests.swift
//  Books & Vocab Tests
//
//  Issue #2025: Remember → Back → Forget 曾停在 Remember(`submit` 見已有答案只前進,
//  不重新評分)。語意(方案 B):返回後重新作答 = 新答案「取代」舊答案,兩個計數同步
//  修正;同答案重按 = 冪等前進;haptic trigger 單調不扣。
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
struct TodayReviewAnswerReplacementTests {

    // MARK: - Scoring layer

    @Test func replacingAnswerMovesTheCountsAndKeepsTheRecordID() {
        let scoring = ReviewScoringState()
        scoring.record(.remembered, at: 0)
        let recordID = scoring.submittedAnswers[0]?.reviewRecordID
        scoring.markFlushed(at: 0)

        let outcome = scoring.score(.forgot, at: 0)

        #expect(outcome == .replaced(previous: .remembered))
        #expect(scoring.submittedAnswers[0]?.feedback == .forgot)
        #expect(scoring.rememberedCount == 0)
        #expect(scoring.forgotCount == 1)
        #expect(scoring.submittedAnswers[0]?.reviewRecordID == recordID)
        // 取代後必須重新 flush,DB 才會跟上。
        #expect(scoring.submittedAnswers[0]?.flushed == false)
    }

    @Test func sameFeedbackIsIdempotentAndDoesNotTouchCountsOrFlushFlag() {
        let scoring = ReviewScoringState()
        #expect(scoring.score(.remembered, at: 0) == .recorded)
        scoring.markFlushed(at: 0)
        let triggerBefore = scoring.rememberedFeedbackTrigger

        #expect(scoring.score(.remembered, at: 0) == .unchanged)

        #expect(scoring.rememberedCount == 1)
        #expect(scoring.forgotCount == 0)
        #expect(scoring.submittedAnswers[0]?.flushed == true)
        #expect(scoring.rememberedFeedbackTrigger == triggerBefore)
    }

    @Test func hapticTriggersStayMonotonicAcrossReplacement() {
        let scoring = ReviewScoringState()
        scoring.score(.remembered, at: 0)
        #expect(scoring.rememberedFeedbackTrigger == 1)

        scoring.score(.forgot, at: 0)
        // 舊答案的 trigger 不扣回;新答案的 trigger +1(使用者確實按了那顆鍵)。
        #expect(scoring.rememberedFeedbackTrigger == 1)
        #expect(scoring.forgotFeedbackTrigger == 1)
    }

    // MARK: - State layer

    private func makeEntries(_ count: Int) -> [VocabularyEntry] {
        (0..<count).map { index in
            let entry = VocabularyEntry(
                word: "replace-\(UUID().uuidString.prefix(6))-\(index)",
                translation: "t\(index)",
                context: "Sentence \(index).",
                bookTitle: "Sample"
            )
            entry.kgCardId = "card-replace-\(UUID().uuidString.prefix(8))"
            entry.markSynced()
            return entry
        }
    }

    private func makeContainer(_ entries: [VocabularyEntry]) throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        entries.forEach { context.insert($0) }
        #expect(context.safeSave())
        return (container, context)
    }

    private func waitForFlush(
        _ state: TodayReviewState,
        index: Int,
        timeout: Int = 400
    ) async throws {
        for _ in 0..<timeout {
            if state.submittedAnswers[index]?.flushed == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func rememberBackForgotYieldsForgotAndAdvances() throws {
        TodayReviewSessionSnapshotStore.clear(for: "replace-user")
        defer { TodayReviewSessionSnapshotStore.clear(for: "replace-user") }
        let entries = makeEntries(3)
        let (container, _) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")

        state.submit(.remembered, container: container, reviewSettings: .default)
        state.goPrevious()
        state.submit(.forgot, container: container, reviewSettings: .default)

        #expect(state.submittedAnswers[0]?.feedback == .forgot)
        #expect(state.rememberedCount == 0)
        #expect(state.forgotCount == 1)
        #expect(state.presenterState.rememberedCount == 0)
        #expect(state.presenterState.forgotCount == 1)
        #expect(state.currentIndex == 1)
    }

    @Test func repeatedSameFeedbackAfterBackIsIdempotent() throws {
        TodayReviewSessionSnapshotStore.clear(for: "replace-user")
        defer { TodayReviewSessionSnapshotStore.clear(for: "replace-user") }
        let entries = makeEntries(3)
        let (container, _) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")

        state.submit(.remembered, container: container, reviewSettings: .default)
        state.goPrevious()
        state.submit(.remembered, container: container, reviewSettings: .default)

        #expect(state.rememberedCount == 1)
        #expect(state.forgotCount == 0)
        #expect(state.currentIndex == 1)
    }

    @Test func repeatedSubmitOnLastCardStillCompletesTheSession() throws {
        TodayReviewSessionSnapshotStore.clear(for: "replace-user")
        defer { TodayReviewSessionSnapshotStore.clear(for: "replace-user") }
        let entries = makeEntries(1)
        let (container, _) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")

        state.submit(.remembered, container: container, reviewSettings: .default)
        #expect(state.currentIndex == 1)           // 已完成
        state.goPrevious()
        #expect(state.currentIndex == 0)
        state.submit(.remembered, container: container, reviewSettings: .default)

        #expect(state.currentIndex == 1)
        #expect(state.currentEntry == nil)
        #expect(state.rememberedCount == 1)
    }

    @Test func replacementAfterCompletionRecomputesCountsAndCompletesAgain() throws {
        TodayReviewSessionSnapshotStore.clear(for: "replace-user")
        defer { TodayReviewSessionSnapshotStore.clear(for: "replace-user") }
        let entries = makeEntries(2)
        let (container, _) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")

        state.submit(.remembered, container: container, reviewSettings: .default)
        state.submit(.remembered, container: container, reviewSettings: .default)
        #expect(state.currentEntry == nil)

        state.goPrevious()
        state.submit(.forgot, container: container, reviewSettings: .default)

        #expect(state.submittedAnswers[1]?.feedback == .forgot)
        #expect(state.rememberedCount == 1)
        #expect(state.forgotCount == 1)
        #expect(state.currentEntry == nil)
    }

    /// Re-completing after back + shuffle must still drop the saved order:
    /// only the analytics event is once-per-session, the store clear is not.
    /// Shuffle pins answered slots (#2482) and only permutes the unanswered ones,
    /// so the back + shuffle leg needs two unanswered slots ahead of the cursor.
    @Test func recompletingAfterBackAndShuffleClearsTheSavedOrder() throws {
        TodayReviewSessionSnapshotStore.clear(for: "replace-user")
        ReviewSessionStore.clear(userID: "replace-user")
        defer {
            TodayReviewSessionSnapshotStore.clear(for: "replace-user")
            ReviewSessionStore.clear(userID: "replace-user")
        }
        let entries = makeEntries(4)
        let (container, _) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")

        state.submit(.remembered, container: container, reviewSettings: .default)
        state.submit(.remembered, container: container, reviewSettings: .default)
        state.goPrevious()
        state.goPrevious()
        state.shuffleQueue()
        // Precondition: the shuffle really persisted an order over the two unanswered
        // slots (else the final assertion would pass vacuously).
        #expect(ReviewSessionStore.loadOrder(
            availableEntries: entries, userID: "replace-user", allowPartialQueue: true
        ) != nil)

        // Index 0-1 re-submit their existing answer (idempotent advance); 2-3 are the
        // shuffled unanswered slots. The last submit completes the session.
        for _ in 0..<4 {
            state.submit(.remembered, container: container, reviewSettings: .default)
        }
        #expect(state.currentEntry == nil)

        #expect(ReviewSessionStore.loadOrder(
            availableEntries: entries, userID: "replace-user", allowPartialQueue: true
        ) == nil)
    }

    @Test func restoredSessionAllowsBackAndChangingTheAnswer() throws {
        TodayReviewSessionSnapshotStore.clear(for: "replace-user")
        defer { TodayReviewSessionSnapshotStore.clear(for: "replace-user") }
        let entries = makeEntries(3)
        let (container, _) = try makeContainer(entries)
        let first = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")
        first.submit(.remembered, container: container, reviewSettings: .default)

        let restored = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")
        #expect(restored.rememberedCount == 1)
        restored.goPrevious()
        restored.submit(.forgot, container: container, reviewSettings: .default)

        #expect(restored.rememberedCount == 0)
        #expect(restored.forgotCount == 1)
        #expect(restored.submittedAnswers[0]?.feedback == .forgot)
        #expect(restored.currentIndex == 1)

        // 取代後的快照也要是新答案,否則 crash 後會復活舊答案。
        let again = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")
        #expect(again.submittedAnswers[0]?.feedback == .forgot)
        #expect(again.rememberedCount == 0)
        #expect(again.forgotCount == 1)
    }

    // MARK: - Persistence

    @Test func flushAfterReplacementPersistsTheNewAnswerOnly() async throws {
        TodayReviewSessionSnapshotStore.clear(for: "replace-user")
        defer { TodayReviewSessionSnapshotStore.clear(for: "replace-user") }
        let entries = makeEntries(2)
        let (container, context) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")

        state.submit(.remembered, container: container, reviewSettings: .default)
        state.goPrevious()
        state.submit(.forgot, container: container, reviewSettings: .default)
        state.flushPendingAnswers(container: container, reviewSettings: .default)
        try await waitForFlush(state, index: 0)

        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        let entry = try #require(try context.fetch(FetchDescriptor<VocabularyEntry>())
            .first { $0.kgCardId == entries[0].kgCardId })
        #expect(records.count == 1)
        #expect(records.first?.feedback == ReviewFeedback.forgot.rawValue)
        #expect(entry.lastReviewFeedbackRaw == ReviewFeedback.forgot.rawValue)
        #expect(entry.reviewCount == 1)
        #expect(entry.lapseCount == 1)
        #expect(entry.reviewStreak == 0)
    }

    @Test func replacingAnAlreadyFlushedAnswerUpdatesTheExistingRecordAndSRS() async throws {
        TodayReviewSessionSnapshotStore.clear(for: "replace-user")
        defer { TodayReviewSessionSnapshotStore.clear(for: "replace-user") }
        let entries = makeEntries(2)
        let (container, context) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")

        state.submit(.remembered, container: container, reviewSettings: .default)
        state.flushPendingAnswers(container: container, reviewSettings: .default)
        try await waitForFlush(state, index: 0)
        let originalID = try #require(state.submittedAnswers[0]?.reviewRecordID)
        let afterRemember = try #require(try context.fetch(FetchDescriptor<ReviewRecord>()).first)
        #expect(afterRemember.feedback == ReviewFeedback.remembered.rawValue)

        state.goPrevious()
        state.submit(.forgot, container: container, reviewSettings: .default)
        #expect(state.submittedAnswers[0]?.flushed == false)
        state.flushPendingAnswers(container: container, reviewSettings: .default)
        try await waitForFlush(state, index: 0)

        let fresh = ModelContext(container)
        let records = try fresh.fetch(FetchDescriptor<ReviewRecord>())
        let entry = try #require(try fresh.fetch(FetchDescriptor<VocabularyEntry>())
            .first { $0.kgCardId == entries[0].kgCardId })
        #expect(records.count == 1)
        #expect(records.first?.id == originalID)
        #expect(records.first?.feedback == ReviewFeedback.forgot.rawValue)
        #expect(records.first?.lapseAfter == 1)
        #expect(records.first?.streakAfter == 0)
        #expect(entry.reviewCount == 1)             // 取代,不是多記一次複習
        #expect(entry.lapseCount == 1)
        #expect(entry.reviewStreak == 0)
        #expect(entry.lastReviewFeedbackRaw == ReviewFeedback.forgot.rawValue)
    }

    /// #2482: answered slots are pinned on shuffle. Answers are keyed by queue
    /// index, so a shuffle that moved slot 1 or 2 would grade the wrong cards on flush.
    @Test func shuffleAfterBackKeepsAnsweredSlotsAndTheirGradingTargets() async throws {
        TodayReviewSessionSnapshotStore.clear(for: "replace-user")
        ReviewSessionStore.clear(userID: "replace-user")
        defer {
            TodayReviewSessionSnapshotStore.clear(for: "replace-user")
            ReviewSessionStore.clear(userID: "replace-user")
        }
        let entries = makeEntries(6)
        let (container, _) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: "replace-user")

        state.submit(.remembered, container: container, reviewSettings: .default)
        state.submit(.forgot, container: container, reviewSettings: .default)
        state.submit(.remembered, container: container, reviewSettings: .default)
        state.goPrevious()
        state.goPrevious()
        let answeredBefore = Array(state.queue[0...2])
        for _ in 0..<5 {
            state.shuffleQueue()
        }

        #expect(zip(answeredBefore, state.queue[0...2]).allSatisfy { pair in pair.0 === pair.1 })
        #expect(state.submittedAnswers.keys.sorted() == [0, 1, 2])

        state.flushPendingAnswers(container: container, reviewSettings: .default)
        for index in 0..<3 {
            try await waitForFlush(state, index: index)
        }

        let fresh = ModelContext(container)
        let feedbackByCard = Dictionary(
            try fresh.fetch(FetchDescriptor<ReviewRecord>()).compactMap { record in
                record.kgCardId.map { ($0, record.feedback) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(feedbackByCard[entries[0].kgCardId ?? ""] == ReviewFeedback.remembered.rawValue)
        #expect(feedbackByCard[entries[1].kgCardId ?? ""] == ReviewFeedback.forgot.rawValue)
        #expect(feedbackByCard[entries[2].kgCardId ?? ""] == ReviewFeedback.remembered.rawValue)
        #expect(feedbackByCard.count == 3)
    }

    /// #2482 (review P1): a flushed answer's baseline is the pre-review snapshot. After a
    /// restore, shuffling must keep that baseline; re-deriving it from the live (post-review)
    /// entry makes the replace re-apply the grade on top and double-counts.
    @Test func replaceAfterRestoreAndShuffleDoesNotDoubleCountFlushedAnswer() async throws {
        let userID = "replace-user"
        TodayReviewSessionSnapshotStore.clear(for: userID)
        ReviewSessionStore.clear(userID: userID)
        defer {
            TodayReviewSessionSnapshotStore.clear(for: userID)
            ReviewSessionStore.clear(userID: userID)
        }
        let entries = makeEntries(6)
        let (container, _) = try makeContainer(entries)
        let first = TodayReviewState(entries: entries, allEntries: entries, currentUserID: userID)
        first.submit(.remembered, container: container, reviewSettings: .default)
        first.flushPendingAnswers(container: container, reviewSettings: .default)
        try await waitForFlush(first, index: 0)
        first.persistSnapshot()
        let target = first.queue[0]

        let restored = TodayReviewState(entries: entries, allEntries: entries, currentUserID: userID)
        #expect(restored.queue[0] === target)
        #expect(restored.submittedAnswers[0]?.flushed == true)
        restored.goPrevious()
        for _ in 0..<5 {
            restored.shuffleQueue()
        }
        #expect(restored.queue[0] === target)
        #expect(restored.currentEntry === target)

        restored.submit(.forgot, container: container, reviewSettings: .default)
        restored.flushPendingAnswers(container: container, reviewSettings: .default)
        try await waitForFlush(restored, index: 0)

        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<VocabularyEntry>())
            .first { $0.kgCardId == target.kgCardId })
        let records = try fresh.fetch(FetchDescriptor<ReviewRecord>())
            .filter { $0.kgCardId == target.kgCardId }
        #expect(stored.reviewCount == 1)
        #expect(records.count == 1)
        #expect(records.first?.feedback == ReviewFeedback.forgot.rawValue)
    }

    /// #2482 (CR on #3167): an answered row re-keyed by sync mid-session changes its persistence id
    /// but is still the same row. Its pre-review baseline must survive a reorder; re-deriving it from
    /// the live, already-flushed (post-review) row double-counts `reviewCount` on the next replace.
    @Test func syncQueueMetadataKeepsBaselineOfAnsweredRowReKeyedMidSession() {
        let entries = makeEntries(3)
        var controller = TodayReviewSessionPersistenceController(queue: entries, currentUserID: nil)
        let original = controller.queueBaselines[0]

        entries[0].reviewCount = original.reviewCount + 1
        entries[0].kgCardId = "card-rekeyed-\(UUID().uuidString.prefix(8))"
        controller.syncQueueMetadata(for: entries, keepingBaselinesAt: [0])

        #expect(controller.queuePersistenceIDs[0] == ReviewSessionPersistence.persistenceID(for: entries[0]))
        #expect(controller.queueBaselines[0].reviewCount == original.reviewCount)
    }

    private struct FetchFailure: Error {}

    /// #2796: a failed `ReviewRecord` lookup must NOT be read as "no record yet" (would insert a
    /// duplicate id and double the review event). The answer stays un-staged for a later retry.
    @Test func recordFetchErrorDoesNotInsertDuplicateAndLeavesAnswerUnstaged() throws {
        let entries = makeEntries(1)
        let (container, context) = try makeContainer(entries)
        let entry = try #require(try context.fetch(FetchDescriptor<VocabularyEntry>()).first)
        let before = TodayReviewSessionSnapshotStore.ReviewBaseline(
            reviewIntervalHours: entry.reviewIntervalHours,
            nextReviewAt: entry.nextReviewAt,
            lastReviewedAt: entry.lastReviewedAt,
            reviewCount: entry.reviewCount,
            lapseCount: entry.lapseCount,
            reviewStreak: entry.reviewStreak,
            lastReviewFeedbackRaw: entry.lastReviewFeedbackRaw
        )
        let answer = TodayReviewState.SubmittedAnswer(
            feedback: .forgot, answeredAt: Date(), reviewRecordID: UUID())
        let snapshot = NotebookSettingsResolver(
            globalReviewSettings: .default, globalCardLayout: .default
        ).snapshot(for: [])

        let staged = ReviewSessionPersistence.stageAnswer(
            answer, baseline: before, entry: entry,
            notebookSettingsSnapshot: snapshot, in: context,
            fetchRecord: { _, _ in throw FetchFailure() }
        )

        #expect(staged == false)
        #expect(context.safeSave())
        #expect(try ModelContext(container).fetch(FetchDescriptor<ReviewRecord>()).isEmpty)
        #expect(entry.reviewCount == before.reviewCount)
    }

    // MARK: - Analytics

    @Test func correctionEventMovesAggregateCountsWithoutInflatingTotal() {
        let metrics = SessionMetrics.makeIsolatedForTesting()
        metrics.record(.reviewCardSubmitted(feedback: "remembered", cardIndex: 0, totalCards: 2))
        metrics.record(.reviewAnswerCorrected(from: "remembered", to: "forgot", cardIndex: 0, totalCards: 2))

        let snapshot = metrics.snapshot()
        #expect(snapshot.reviewCardsTotal == 1)
        #expect(snapshot.reviewRemembered == 0)
        #expect(snapshot.reviewForgot == 1)
    }
}
