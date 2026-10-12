import Foundation
import SwiftData

/// The narrow transport/persistence surface used by the explicit vocabulary sync.
/// Keeping it separate from `KGServing` makes the whole pipeline independently testable.
@MainActor
protocol VocabularySyncEngineServing: AnyObject {
    func batchAdd(entries: [VocabularyEntry], notebookId: String) async throws -> KGAddResponse
    func batchDeleteCards(words: [String], notebookId: String) async throws -> KGBatchDeleteResponse
    func deleteCard(word: String, notebookId: String) async throws
    func updateCardContent(
        word: String,
        translation: String,
        explanation: String?,
        notebookId: String
    ) async throws
    func triggerPipeline(notebookId: String) async throws
    func pushReviewStates(container: ModelContainer) async throws -> (updated: Int, skipped: Int)
    func pushReviewEvents(container: ModelContainer) async throws -> (inserted: Int, skipped: Int)
    func pullCardsToLocal(
        container: ModelContainer,
        progress: ((String, Int, Int) -> Void)?,
        notebookId: String?
    ) async throws -> KGPullOutcome
    func pullReviewEvents(container: ModelContainer) async throws
}

/// Typed output from the sync engine. The coordinator owns presentation only.
enum VocabularySyncEvent {
    case stepStarted(String)
    case stepProgress(String, current: Int, total: Int, detail: String)
    case stepFinished(String, status: PipelineStep.StepStatus, detail: String)
}

struct VocabularySyncResult {
    let terminalOutcome: SyncTerminalOutcome
    let durationMs: Int
}

enum VocabularySyncEngineError: Error {
    case contentUpdateUnavailable
}

@MainActor
protocol VocabularySyncExecuting: AnyObject {
    func execute(
        pendingEntries: [VocabularyEntry],
        modelContext: ModelContext,
        service: any VocabularySyncEngineServing,
        emit: @escaping (VocabularySyncEvent) -> Void
    ) async -> VocabularySyncResult
}

/// Owns the transport, outbox mutation and persistence ordering for an explicit vocab sync.
@MainActor
final class VocabularySyncEngine: VocabularySyncExecuting {
    func execute(
        pendingEntries: [VocabularyEntry],
        modelContext: ModelContext,
        service: any VocabularySyncEngineServing,
        emit: @escaping (VocabularySyncEvent) -> Void
    ) async -> VocabularySyncResult {
        let start = Date()
        var encounteredFailure = false

        do {
            let sanitizedDeletedEntryIds = SyncCoordinator.sanitizeOutbox(
                pendingEntries: pendingEntries,
                modelContext: modelContext
            )
            let queuedDeletes = pendingEntries.filter {
                !sanitizedDeletedEntryIds.contains($0.id)
                    && $0.syncAction == .delete
                    && $0.shouldUploadOnNextSync
            }
            let deletes = queuedDeletes
            let adds = pendingEntries.filter {
                !sanitizedDeletedEntryIds.contains($0.id)
                    && $0.syncAction == .add
                    && $0.shouldUploadOnNextSync
            }
            let edits = pendingEntries.filter {
                !sanitizedDeletedEntryIds.contains($0.id)
                    && $0.syncAction == .edit
                    && $0.shouldUploadOnNextSync
            }

            // Mark everything captured here before the first suspension below. A user delete in
            // any of those suspensions (delete round trip, an earlier add group, an earlier edit)
            // then queues a server delete instead of hard-deleting a row this sync still holds (#2733).
            // Undo and reader re-capture are refused for these rows until this sync returns (I3, #2484),
            // so a captured delete is still a delete when its response or fallback request completes.
            let captured = queuedDeletes + adds + edits
            captured.forEach { $0.isUploadInFlight = true }
            defer { captured.forEach { $0.isUploadInFlight = false } }

            if !queuedDeletes.isEmpty {
                emit(.stepStarted("upload_delete"))
                queuedDeletes.forEach { $0.prepareForRetryAttempt() }
                let groupedDeletes = Dictionary(grouping: deletes, by: \.notebookId)
                var deleted = 0
                var failedWords: [String] = []

                for (notebookId, entries) in groupedDeletes {
                    if Task.isCancelled { return cancelledResult(since: start) }
                    do {
                        let response = try await service.batchDeleteCards(
                            words: entries.map(\.word), notebookId: notebookId
                        )
                        let outcome = SyncCoordinator.applyBatchDeleteResponse(
                            response: response, entries: entries, modelContext: modelContext
                        )
                        deleted += outcome.deleted
                        failedWords.append(contentsOf: outcome.failedWords)
                        emit(.stepProgress("upload_delete", current: deleted, total: queuedDeletes.count, detail: ""))
                    } catch {
                        // Batch failure is recoverable: retry each card individually.
                        for entry in entries {
                            if Task.isCancelled { return cancelledResult(since: start) }
                            do {
                                try await service.deleteCard(word: entry.word, notebookId: entry.notebookId)
                                // Defensive recheck after the suspension (I3 keeps the held delete a delete): never
                                // hard-delete a row that is no longer a held delete (T5).
                                guard entry.isUploadInFlight, entry.syncAction == .delete else { continue }
                                modelContext.delete(entry)
                                deleted += 1
                                emit(.stepProgress("upload_delete", current: deleted, total: queuedDeletes.count, detail: ""))
                            } catch {
                                if Task.isCancelled { return cancelledResult(since: start) }
                                entry.markSyncFailed()
                                encounteredFailure = true
                                failedWords.append(entry.word)
                            }
                        }
                    }
                }

                if !failedWords.isEmpty { encounteredFailure = true }
                modelContext.safeSave()
                if failedWords.isEmpty {
                    emit(.stepFinished(
                        "upload_delete", status: .done,
                        detail: L10n.format("已刪除 %@ 個單字", "\(deleted)")
                    ))
                } else {
                    emit(.stepFinished(
                        "upload_delete", status: .error,
                        detail: L10n.format("部分失敗: %@", failedWords.joined(separator: ", "))
                    ))
                }
            }

            if !adds.isEmpty {
                emit(.stepStarted("upload_add"))
                let groupedAdds = Dictionary(grouping: adds, by: \.notebookId)
                var totalCreated = 0
                var totalSkipped = 0
                var batchFailed = false
                for (notebookId, entries) in groupedAdds {
                    if Task.isCancelled { return cancelledResult(since: start) }
                    // Revalidate right before the wire: an add the user deleted during an earlier
                    // suspension now carries a queued delete and must not be uploaded (#2733).
                    let uploadable = entries.filter { $0.syncAction == .add && $0.shouldUploadOnNextSync }
                    guard !uploadable.isEmpty else { continue }
                    do {
                        uploadable.forEach { $0.prepareForRetryAttempt() }
                        let response = try await service.batchAdd(entries: uploadable, notebookId: notebookId)
                        SyncCoordinator.convergeAddedEntries(response: response, entries: uploadable)
                        if !response.rejected.isEmpty {
                            batchFailed = true
                            encounteredFailure = true
                        }
                        totalCreated += response.created
                        totalSkipped += response.skipped
                    } catch is CancellationError {
                        return cancelledResult(since: start)
                    } catch {
                        uploadable.forEach { $0.markSyncFailed() }
                        encounteredFailure = true
                        batchFailed = true
                    }
                }
                modelContext.safeSave()
                if batchFailed {
                    let failedCount = adds.filter(\.isFailed).count
                    emit(.stepFinished(
                        "upload_add", status: .error,
                        detail: L10n.format("部分上傳失敗（%@ 筆）", "\(failedCount)")
                    ))
                } else {
                    emit(.stepFinished(
                        "upload_add", status: .done,
                        detail: L10n.format("%@ 新增, %@ 已存在", "\(totalCreated)", "\(totalSkipped)")
                    ))
                }
            }

            for entry in edits {
                if Task.isCancelled { return cancelledResult(since: start) }
                // A delete queued during an earlier suspension supersedes this edit: do not send it.
                guard entry.syncAction == .edit else { continue }
                entry.prepareForRetryAttempt()
                do {
                    try await service.updateCardContent(
                        word: entry.word,
                        translation: entry.translation,
                        explanation: entry.explanationUpdateValue,
                        notebookId: entry.notebookId
                    )
                    if Task.isCancelled { return cancelledResult(since: start) }
                    // A delete queued while the update was on the wire must survive the edit's success (#2733).
                    if entry.syncAction == .edit { entry.markSynced() }
                } catch is CancellationError {
                    return cancelledResult(since: start)
                } catch {
                    entry.markSyncFailed()
                    encounteredFailure = true
                }
            }
            if !edits.isEmpty { modelContext.safeSave() }

            emit(.stepStarted("trigger"))
            let affectedNotebookIds = Set(adds.map(\.notebookId)).filter { !$0.isEmpty }
            let notebookIds = affectedNotebookIds.isEmpty ? ["default"] : affectedNotebookIds.sorted()
            let triggerFailures = await SyncCoordinator.triggerPipelinesIsolated(notebookIds: notebookIds) {
                try await service.triggerPipeline(notebookId: $0)
            }
            if triggerFailures.isEmpty {
                emit(.stepFinished("trigger", status: .done, detail: L10n.string("已交由伺服器背景處理")))
            } else {
                encounteredFailure = true
                emit(.stepFinished(
                    "trigger", status: .error,
                    detail: L10n.format("部分通知失敗: %@", triggerFailures.joined(separator: ", "))
                ))
            }

            emit(.stepStarted("push_review"))
            do {
                let result = try await service.pushReviewStates(container: modelContext.container)
                _ = try await service.pushReviewEvents(container: modelContext.container)
                emit(.stepFinished(
                    "push_review", status: .done,
                    detail: L10n.format("已同步 %@ 筆複習紀錄", "\(result.updated)")
                ))
            } catch is CancellationError {
                return cancelledResult(since: start)
            } catch {
                encounteredFailure = true
                emit(.stepFinished("push_review", status: .error, detail: error.localizedDescription))
            }

            emit(.stepProgress("pull", current: 0, total: 0, detail: L10n.string("正在下載單字...")))
            do {
                var pipelinePending = try await service.pullCardsToLocal(
                    container: modelContext.container,
                    progress: { detail, current, total in
                        emit(.stepProgress("pull", current: current, total: total, detail: detail))
                    },
                    notebookId: nil
                ).pipelinePending

                var retryCount = 0
                while pipelinePending && retryCount < syncPipelinePendingBackoffSeconds.count {
                    retryCount += 1
                    emit(.stepProgress(
                        "pull", current: 0, total: 0,
                        detail: L10n.format(
                            "等待 AI 處理完成（%@/3）...",
                            "\(min(retryCount, 3))"
                        )
                    ))
                    try await Task.sleep(for: .seconds(syncPipelinePendingBackoffSeconds[retryCount - 1]))
                    if Task.isCancelled { return cancelledResult(since: start) }
                    pipelinePending = try await service.pullCardsToLocal(
                        container: modelContext.container, progress: nil, notebookId: nil
                    ).pipelinePending
                }

                try await service.pullReviewEvents(container: modelContext.container)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                emit(.stepFinished("pull", status: .error, detail: SyncFailurePresentation.reason(for: error)))
                throw error
            }

            emit(.stepFinished("pull", status: .done, detail: L10n.string("本地單字已建立完成")))
            let outcome = syncTerminalOutcome(
                wasCancelled: Task.isCancelled,
                thrownError: false,
                encounteredFailure: encounteredFailure
            )
            return VocabularySyncResult(terminalOutcome: outcome, durationMs: elapsedMilliseconds(since: start))
        } catch is CancellationError {
            return cancelledResult(since: start)
        } catch {
            return VocabularySyncResult(terminalOutcome: .fullFailure, durationMs: elapsedMilliseconds(since: start))
        }
    }

    private func cancelledResult(since start: Date) -> VocabularySyncResult {
        VocabularySyncResult(terminalOutcome: .keepCancelled, durationMs: elapsedMilliseconds(since: start))
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

/// Adapter keeps the engine independent from the large `KGServing` surface.
@MainActor
final class KGServingVocabularySyncAdapter: VocabularySyncEngineServing {
    let base: any KGServing

    init(base: any KGServing) {
        self.base = base
    }

    func batchAdd(entries: [VocabularyEntry], notebookId: String) async throws -> KGAddResponse {
        try await base.batchAdd(entries: entries, notebookId: notebookId)
    }

    func batchDeleteCards(words: [String], notebookId: String) async throws -> KGBatchDeleteResponse {
        try await base.batchDeleteCards(words: words, notebookId: notebookId)
    }

    func deleteCard(word: String, notebookId: String) async throws {
        try await base.deleteCard(word: word, notebookId: notebookId)
    }

    func updateCardContent(
        word: String,
        translation: String,
        explanation: String?,
        notebookId: String
    ) async throws {
        guard let contentUpdater = base as? any VocabularyContentUpdating else {
            throw VocabularySyncEngineError.contentUpdateUnavailable
        }
        try await contentUpdater.updateCardContent(
            word: word,
            translation: translation,
            explanation: explanation,
            notebookId: notebookId
        )
    }

    func triggerPipeline(notebookId: String) async throws {
        try await base.triggerPipeline(notebookId: notebookId)
    }

    func pushReviewStates(container: ModelContainer) async throws -> (updated: Int, skipped: Int) {
        try await base.pushReviewStates(container: container)
    }

    func pushReviewEvents(container: ModelContainer) async throws -> (inserted: Int, skipped: Int) {
        try await base.pushReviewEvents(container: container)
    }

    func pullCardsToLocal(
        container: ModelContainer,
        progress: ((String, Int, Int) -> Void)?,
        notebookId: String?
    ) async throws -> KGPullOutcome {
        try await base.pullCardsToLocal(container: container, progress: progress, notebookId: notebookId)
    }

    func pullReviewEvents(container: ModelContainer) async throws {
        try await base.pullReviewEvents(container: container)
    }
}
