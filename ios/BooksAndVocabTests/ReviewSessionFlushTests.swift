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

@MainActor
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
        await withCheckedContinuation { continuation in
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

    @Test func completedSessionKeepsSnapshotWhenAnAnswerCannotBeStaged() async throws {
        TodayReviewSessionSnapshotStore.clear(for: Self.userID)
        defer { TodayReviewSessionSnapshotStore.clear(for: Self.userID) }
        let entries = makeEntries(3)
        let (container, context) = try makeContainer(entries)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: Self.userID)
        for _ in 0..<3 {
            state.submit(.remembered, container: container, reviewSettings: .default)
        }
        #expect(state.currentEntry == nil)

        // Entry #2 leaves the store before the deferred flush runs: its answer cannot be
        // staged. The other two must still persist.
        context.delete(entries[2])
        #expect(context.safeSave())

        await flushAndFinalize(state, container: container, completed: true)

        #expect(TodayReviewSessionSnapshotStore.load(for: Self.userID) != nil)
        #expect(state.submittedAnswers[0]?.flushed == true)
        #expect(state.submittedAnswers[1]?.flushed == true)
        #expect(state.submittedAnswers[2]?.flushed == false)
        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        #expect(records.count == 2)
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
}
