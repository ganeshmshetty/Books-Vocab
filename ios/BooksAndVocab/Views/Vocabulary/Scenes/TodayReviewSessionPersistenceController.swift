import Foundation
import SwiftData

struct TodayReviewSessionPersistenceController {
    private(set) var queuePersistenceIDs: [String]
    private(set) var queueBaselines: [TodayReviewSessionSnapshotStore.ReviewBaseline]
    /// The queued rows' own ids, in queue order. Unlike `queuePersistenceIDs` they survive a
    /// mid-session kgCardId re-key, so the deferred flush can still find the row (#3123).
    /// Empty when restored from a snapshot without row ids; the flush then uses persistence ids.
    private(set) var queueEntryIDs: [UUID]
    private let currentUserID: String?

    init(queue: [VocabularyEntry], currentUserID: String?) {
        self.queuePersistenceIDs = queue.map(ReviewSessionPersistence.persistenceID(for:))
        self.queueBaselines = queue.map(ReviewSessionPersistence.makeBaseline(from:))
        self.queueEntryIDs = queue.map(\.id)
        self.currentUserID = currentUserID
    }

    init(
        queuePersistenceIDs: [String],
        queueBaselines: [TodayReviewSessionSnapshotStore.ReviewBaseline],
        queueEntryIDs: [UUID] = [],
        currentUserID: String?
    ) {
        self.queuePersistenceIDs = queuePersistenceIDs
        self.queueBaselines = queueBaselines
        self.queueEntryIDs = queueEntryIDs
        self.currentUserID = currentUserID
    }

    /// Re-derives the queue identity and baselines after a reorder. Answered slots keep their
    /// existing baseline when the row in that slot is unchanged: a live entry for an already
    /// flushed answer already carries the post-review values, and re-deriving from it would make a
    /// later replace re-apply the grade on top (#2482). "Unchanged" is the same persistence id or
    /// the same row id, so a row re-keyed by sync mid-session keeps its baseline as well.
    mutating func syncQueueMetadata(for queue: [VocabularyEntry], keepingBaselinesAt answeredSlots: Set<Int>) {
        let newIDs = queue.map(ReviewSessionPersistence.persistenceID(for:))
        var newBaselines = queue.map(ReviewSessionPersistence.makeBaseline(from:))
        for slot in answeredSlots
        where slot < newIDs.count
            && slot < queuePersistenceIDs.count
            && slot < queueBaselines.count
            && isSameRow(at: slot, in: queue, newPersistenceIDs: newIDs) {
            newBaselines[slot] = queueBaselines[slot]
        }
        queuePersistenceIDs = newIDs
        queueBaselines = newBaselines
        queueEntryIDs = queue.map(\.id)
    }

    private func isSameRow(at slot: Int, in queue: [VocabularyEntry], newPersistenceIDs: [String]) -> Bool {
        newPersistenceIDs[slot] == queuePersistenceIDs[slot]
            || (slot < queueEntryIDs.count && queue[slot].id == queueEntryIDs[slot])
    }

    func flushPendingAnswers(
        submittedAnswers: [Int: TodayReviewState.SubmittedAnswer],
        container: ModelContainer,
        notebookSettingsSnapshot: NotebookSettingsSnapshot,
        onFinalize: @escaping @MainActor () -> Void = {},
        onFailure: (@MainActor @Sendable () -> Void)? = nil,
        onFlushed: @escaping @MainActor ([Int]) -> Void
    ) {
        ReviewSessionPersistence.flushPendingAnswers(
            queuePersistenceIDs: queuePersistenceIDs,
            queueBaselines: queueBaselines,
            queueEntryIDs: queueEntryIDs,
            submittedAnswers: submittedAnswers,
            container: container,
            notebookSettingsSnapshot: notebookSettingsSnapshot,
            onFlushed: { indices in
                onFlushed(indices)
                onFinalize()
            },
            onFailure: onFailure
        )
    }

    func flushPendingAnswers(
        submittedAnswers: [Int: TodayReviewState.SubmittedAnswer],
        container: ModelContainer,
        reviewSettings: ReviewSettings,
        onFinalize: @escaping @MainActor () -> Void = {},
        onFailure: (@MainActor @Sendable () -> Void)? = nil,
        onFlushed: @escaping @MainActor ([Int]) -> Void
    ) {
        let snapshot = NotebookSettingsResolver(
            globalReviewSettings: reviewSettings,
            globalCardLayout: .default
        ).snapshot(for: [])
        flushPendingAnswers(
            submittedAnswers: submittedAnswers,
            container: container,
            notebookSettingsSnapshot: snapshot,
            onFinalize: onFinalize,
            onFailure: onFailure,
            onFlushed: onFlushed
        )
    }

    func persistSnapshot(
        sessionStartTime: Date,
        currentIndex: Int,
        queueCount: Int,
        submittedAnswers: [Int: TodayReviewState.SubmittedAnswer]
    ) {
        guard let currentUserID else { return }
        ReviewSessionPersistence.persistSnapshot(
            userId: currentUserID,
            sessionStartTime: sessionStartTime,
            currentIndex: currentIndex,
            queueCount: queueCount,
            queuePersistenceIDs: queuePersistenceIDs,
            queueBaselines: queueBaselines,
            submittedAnswers: submittedAnswers
        )
    }

    func clearSnapshot() {
        ReviewSessionPersistence.clearSnapshot(for: currentUserID)
    }
}
