//
//  ReviewSessionFlushTests.swift
//  Books & Vocab Tests
//
//  #3123: the dismiss-time finalize must not drop the crash-recovery snapshot while
//  an answer is still un-flushed. A skipped answer (entry gone from the store, or a
//  transient stage/save failure) stays un-flushed; the snapshot then survives so
//  restore can retry it.
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

private struct InjectedFetchError: Error {}

@MainActor
@Suite(.serialized)
struct ReviewSessionFlushTests {
    private static let userID = "flush-finalize-user"

    private func makeEntries(_ count: Int) -> [VocabularyEntry] {
        (0..<count).map { index in
            let entry = VocabularyEntry(
                word: "flush-\(UUID().uuidString.prefix(6))-\(index)",
                translation: "t\(index)",
                context: "Sentence \(index).",
                bookTitle: "Sample"
            )
            entry.kgCardId = "card-flush-\(UUID().uuidString.prefix(8))"
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

    /// Runs the deferred flush and the same finalize the view runs on dismiss, and
    /// returns once the flush has either finalized or failed.
    private func flushAndFinalize(
        _ state: TodayReviewState,
        container: ModelContainer,
        completed: Bool
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.flushPendingAnswers(
                container: container,
                reviewSettings: .default,
                onFinalize: {
                    state.finalizeSnapshotAfterFlush(completed: completed)
                    continuation.resume()
                },
                onFailure: { continuation.resume() }
            )
        }
    }

    @Test func completedSessionDropsAnswerForDeletedEntryAndClearsSnapshot() async throws {
        TodayReviewSessionSnapshotStore.clear(for: Self.userID)
        defer { TodayReviewSessionSnapshotStore.clear(for: Self.userID) }
        let entries = makeEntries(3)
        let (container, context) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: Self.userID)
        for _ in 0..<3 {
            state.submit(.remembered, container: container, reviewSettings: .default)
        }
        #expect(state.currentEntry == nil)

        // Entry #2 leaves the store before the deferred flush runs. Its answer has no row
        // left to write, so it is dropped (settled) rather than kept as unflushed; the
        // other two persist and the completed session's snapshot is cleared.
        context.delete(entries[2])
        #expect(context.safeSave())

        await flushAndFinalize(state, container: container, completed: true)

        #expect(TodayReviewSessionSnapshotStore.load(for: Self.userID) == nil)
        #expect(state.submittedAnswers[0]?.flushed == true)
        #expect(state.submittedAnswers[1]?.flushed == true)
        #expect(state.submittedAnswers[2]?.flushed == true)
        #expect(state.hasUnflushedAnswers == false)
        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        #expect(records.count == 2)
    }

    /// #3123 re-key: BackgroundSyncActor can reassign a queued row's kgCardId mid-session. The row
    /// still exists and still holds the answered card, so its grade must land on it (not be dropped
    /// as deleted), and the completed session may then clear the snapshot.
    @Test func completedSessionKeepsAnswerForRekeyedEntry() async throws {
        TodayReviewSessionSnapshotStore.clear(for: Self.userID)
        defer { TodayReviewSessionSnapshotStore.clear(for: Self.userID) }
        let entries = makeEntries(2)
        let (container, context) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: Self.userID)
        state.submit(.remembered, container: container, reviewSettings: .default)
        state.submit(.forgot, container: container, reviewSettings: .default)
        #expect(state.currentEntry == nil)

        // The queued persistence id of entry #1 is now stale: the same row lives on under a new card id.
        let rekeyedCardID = "card-rekeyed-\(UUID().uuidString.prefix(8))"
        entries[1].kgCardId = rekeyedCardID
        #expect(context.safeSave())

        await flushAndFinalize(state, container: container, completed: true)

        #expect(TodayReviewSessionSnapshotStore.load(for: Self.userID) == nil)
        #expect(state.hasUnflushedAnswers == false)
        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        #expect(records.count == 2)
        let rekeyedRecords = records.filter { $0.kgCardId == rekeyedCardID }
        #expect(rekeyedRecords.count == 1)
        #expect(rekeyedRecords.first?.feedback == ReviewFeedback.forgot.rawValue)
    }

    /// #3123 fetch error: a row fetch that throws is not a deleted entry. That answer stays
    /// un-settled (so the caller keeps its snapshot and restore retries it), while the other
    /// answer still settles and is written.
    @Test func fetchErrorLeavesAnswerUnsettledForRetry() async throws {
        let entries = makeEntries(2)
        let (container, context) = try makeContainer(entries)
        let answeredAt = Date()
        let answers: [Int: TodayReviewState.SubmittedAnswer] = [
            0: TodayReviewState.SubmittedAnswer(feedback: .remembered, answeredAt: answeredAt, reviewRecordID: UUID()),
            1: TodayReviewState.SubmittedAnswer(feedback: .forgot, answeredAt: answeredAt, reviewRecordID: UUID())
        ]
        let persistenceIDs = entries.map(ReviewSessionPersistence.persistenceID(for:))
        let baselines = entries.map(ReviewSessionPersistence.makeBaseline(from:))
        let failingID = persistenceIDs[0]
        let snapshot = NotebookSettingsResolver(
            globalReviewSettings: .default,
            globalCardLayout: .default
        ).snapshot(for: [])

        let settled: [Int] = await withCheckedContinuation { (continuation: CheckedContinuation<[Int], Never>) in
            ReviewSessionPersistence.flushPendingAnswers(
                queuePersistenceIDs: persistenceIDs,
                queueBaselines: baselines,
                queueEntryIDs: entries.map(\.id),
                submittedAnswers: answers,
                container: container,
                notebookSettingsSnapshot: snapshot,
                onFlushed: { indices in continuation.resume(returning: indices) },
                onFailure: { continuation.resume(returning: []) },
                resolveEntry: { entryID, persistenceID, ctx in
                    if persistenceID == failingID { throw InjectedFetchError() }
                    return try ReviewSessionPersistence.fetchQueuedEntry(
                        entryID: entryID,
                        persistenceID: persistenceID,
                        in: ctx
                    )
                }
            )
        }

        #expect(settled == [1])
        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        #expect(records.count == 1)
    }

    /// #3123 (review P3): re-flushing restored answers must finalize like the dismiss path, so a
    /// completed session's snapshot is cleared once every restored answer is confirmed.
    @Test func reflushOfRestoredCompletedSessionClearsSnapshot() async throws {
        TodayReviewSessionSnapshotStore.clear(for: Self.userID)
        ReviewSessionStore.clear(userID: Self.userID)
        defer {
            TodayReviewSessionSnapshotStore.clear(for: Self.userID)
            ReviewSessionStore.clear(userID: Self.userID)
        }
        let entries = makeEntries(2)
        let (container, _) = try makeContainer(entries)
        let first = TodayReviewState(entries: entries, allEntries: entries, currentUserID: Self.userID)
        first.submit(.remembered, container: container, reviewSettings: .default)
        first.submit(.forgot, container: container, reviewSettings: .default)
        #expect(first.currentEntry == nil)

        let restored = TodayReviewState(entries: entries, allEntries: entries, currentUserID: Self.userID)
        #expect(restored.hasUnflushedAnswers)
        #expect(restored.currentEntry == nil)
        restored.reflushUnflushedRestoredAnswers(container: container, reviewSettings: .default)
        for _ in 0..<400 where restored.hasUnflushedAnswers {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(restored.hasUnflushedAnswers == false)
        #expect(TodayReviewSessionSnapshotStore.load(for: Self.userID) == nil)
    }

    @Test func completedSessionWithEveryAnswerFlushedClearsSnapshot() async throws {
        TodayReviewSessionSnapshotStore.clear(for: Self.userID)
        defer { TodayReviewSessionSnapshotStore.clear(for: Self.userID) }
        let entries = makeEntries(2)
        let (container, context) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: Self.userID)
        state.submit(.remembered, container: container, reviewSettings: .default)
        state.submit(.forgot, container: container, reviewSettings: .default)

        await flushAndFinalize(state, container: container, completed: true)

        #expect(TodayReviewSessionSnapshotStore.load(for: Self.userID) == nil)
        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        #expect(records.count == 2)
    }

    /// #3123 core branch: a completed session that still holds an unflushed answer keeps its
    /// snapshot, because that answer exists only there until a flush confirms it. Clearing
    /// unconditionally here would silently lose the answer on dismiss.
    @Test func completedSessionWithUnflushedAnswerKeepsSnapshot() throws {
        let userID = "flush-finalize-unflushed-user"
        TodayReviewSessionSnapshotStore.clear(for: userID)
        defer { TodayReviewSessionSnapshotStore.clear(for: userID) }
        let entries = makeEntries(2)
        let (container, _) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: userID)
        state.submit(.remembered, container: container, reviewSettings: .default)
        state.submit(.forgot, container: container, reviewSettings: .default)
        #expect(state.currentEntry == nil)
        #expect(state.hasUnflushedAnswers)

        state.finalizeSnapshotAfterFlush(completed: true)

        #expect(TodayReviewSessionSnapshotStore.load(for: userID) != nil)
    }
}
