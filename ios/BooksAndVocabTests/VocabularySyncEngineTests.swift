import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
@Suite("VocabularySyncEngine")
struct VocabularySyncEngineTests {
    @Test("successful add converges by the server card id")
    func successfulAddConverges() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeEntry(word: "chateau,")
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.addResponse = KGAddResponse(
            created: 1,
            skipped: 0,
            duplicates: [],
            cardIds: [entry.word: "card-1"]
        )

        let result = await VocabularySyncEngine().execute(
            pendingEntries: [entry],
            modelContext: context,
            service: service,
            emit: { _ in }
        )

        #expect(result.terminalOutcome == .completed)
        #expect(entry.kgCardId == "card-1")
        #expect(entry.isSynced)
        #expect(service.calls == ["add", "trigger", "pushStates", "pushEvents", "pull", "pullReviewEvents"])
    }

    @Test("a failing pull emits an error step instead of leaving it running")
    func failingPullEmitsErrorStep() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let service = FakeVocabularySyncService()
        service.pullError = TestError.expected
        var events: [VocabularySyncEvent] = []

        let result = await VocabularySyncEngine().execute(
            pendingEntries: [],
            modelContext: context,
            service: service,
            emit: { events.append($0) }
        )

        #expect(result.terminalOutcome == .fullFailure)
        let errored = events.contains {
            if case .stepFinished("pull", status: .error, _) = $0 { return true }
            return false
        }
        #expect(errored)
    }

    @Test("a pending or failed edit remains uploadable")
    func editedEntriesRemainUploadable() {
        let entry = makePendingEdit()

        #expect(entry.shouldUploadOnNextSync)

        entry.markSyncFailed()

        #expect(entry.shouldUploadOnNextSync)
    }

    @Test("successful edit sends one content update and converges")
    func successfulEditConverges() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makePendingEdit(notebookId: "notebook-a")
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        let result = await VocabularySyncEngine().execute(
            pendingEntries: [entry],
            modelContext: context,
            service: service,
            emit: { _ in }
        )

        #expect(result.terminalOutcome == .completed)
        #expect(service.editRequests == [
            EditRequest(
                word: entry.word,
                translation: entry.translation,
                explanation: entry.explanation,
                notebookId: "notebook-a"
            )
        ])
        #expect(entry.isSynced)
        #expect(entry.syncAction == .add)
        #expect(!entry.shouldUploadOnNextSync)
    }

    @Test("a delete issued while its add is in flight is queued, not dropped, and removed on the next sync")
    func deleteDuringInFlightAddIsQueued() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeEntry(word: "ephemeral")
        entry.restorePendingEntry()
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.addResponse = KGAddResponse(
            created: 1, skipped: 0, duplicates: [], cardIds: [entry.word: "card-9"]
        )
        service.onAddInFlight = { entry.deleteLocally(in: context) }

        _ = await VocabularySyncEngine().execute(
            pendingEntries: [entry], modelContext: context, service: service, emit: { _ in }
        )

        // Row survives the in-flight window so the server copy cannot be re-pulled.
        #expect(!entry.isDeleted)
        #expect(entry.isPendingDelete)
        #expect(entry.kgCardId == "card-9")
        #expect(!entry.isUploadInFlight)

        service.onAddInFlight = nil
        _ = await VocabularySyncEngine().execute(
            pendingEntries: [entry], modelContext: context, service: service, emit: { _ in }
        )

        #expect(service.calls.contains("batchDelete"))
        #expect(entry.isDeleted)
    }

    @Test("a failed edit stays retryable and makes sync partial")
    func failedEditCanRetry() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makePendingEdit()
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.editError = TestError.expected

        let failedResult = await VocabularySyncEngine().execute(
            pendingEntries: [entry],
            modelContext: context,
            service: service,
            emit: { _ in }
        )

        #expect(failedResult.terminalOutcome == .partial)
        #expect(entry.isFailed)
        #expect(entry.syncAction == .edit)
        #expect(entry.shouldUploadOnNextSync)
        #expect(service.editRequests.count == 1)

        service.editError = nil
        let retryResult = await VocabularySyncEngine().execute(
            pendingEntries: [entry],
            modelContext: context,
            service: service,
            emit: { _ in }
        )

        #expect(retryResult.terminalOutcome == .completed)
        #expect(service.editRequests.count == 2)
        #expect(entry.isSynced)
        #expect(entry.syncAction == .add)
        #expect(!entry.shouldUploadOnNextSync)
    }

    @Test("cancelling an edit keeps it pending for retry")
    func editCancellationKeepsRetryableState() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makePendingEdit()
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.blockEdit = true
        let task = Task { @MainActor in
            await VocabularySyncEngine().execute(
                pendingEntries: [entry],
                modelContext: context,
                service: service,
                emit: { _ in }
            )
        }
        let editStarted = await service.waitUntilEditStarted()
        #expect(editStarted)
        task.cancel()
        let result = await task.value

        #expect(result.terminalOutcome == .keepCancelled)
        #expect(entry.isPending)
        #expect(entry.syncAction == .edit)
        #expect(entry.shouldUploadOnNextSync)
    }

    @Test("content edit payload uses the backend PATCH field names")
    func contentEditPayloadUsesBackendFields() throws {
        let payload = KGService.vocabContentPayload(
            translation: "edited translation",
            explanation: "edited explanation"
        )
        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["meaning"] as? String == "edited translation")
        #expect(json["explanation"] as? String == "edited explanation")
    }

    @Test("trigger failure is partial and does not prevent the remaining sync stages")
    func partialFailureContinues() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeEntry(word: "partial")
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.triggerError = TestError.expected

        let result = await VocabularySyncEngine().execute(
            pendingEntries: [entry],
            modelContext: context,
            service: service,
            emit: { _ in }
        )

        #expect(result.terminalOutcome == .partial)
        #expect(service.calls.contains("pull"))
    }

    @Test("batch delete failure falls back to per-card delete")
    func deleteFallback() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeEntry(word: "fallback")
        entry.queueDelete()
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.batchDeleteError = TestError.expected

        let result = await VocabularySyncEngine().execute(
            pendingEntries: [entry],
            modelContext: context,
            service: service,
            emit: { _ in }
        )

        #expect(result.terminalOutcome == .completed)
        #expect(service.calls.contains("batchDelete"))
        #expect(service.calls.contains("delete"))
        #expect(try context.fetch(FetchDescriptor<VocabularyEntry>()).isEmpty)
    }

    @Test("a queued delete and a re-capture of the same word send no delete (#2105)")
    func deleteThenRecaptureSendsNoDelete() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let synced = makeEntry(word: "harbor")
        synced.kgCardId = "card-harbor"
        synced.markSynced()
        synced.queueDelete()
        let recaptured = makeEntry(word: "harbor")
        context.insert(synced)
        context.insert(recaptured)
        try context.save()

        let service = FakeVocabularySyncService()
        service.addResponse = KGAddResponse(
            created: 0,
            skipped: 1,
            duplicates: ["harbor"],
            cardIds: ["harbor": "card-harbor"]
        )
        let result = await VocabularySyncEngine().execute(
            pendingEntries: [synced, recaptured],
            modelContext: context,
            service: service,
            emit: { _ in }
        )

        #expect(result.terminalOutcome == .completed)
        #expect(!service.calls.contains("batchDelete"), "the server card must not be deleted")
        #expect(!service.calls.contains("delete"))
        let all = try context.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(all.count == 1)
        #expect(all.first?.kgCardId == "card-harbor")
        #expect(all.first?.syncAction == .add)
    }

    @Test("cancellation keeps the user-cancelled terminal outcome")
    func cancellationWins() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeEntry(word: "cancel")
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.blockAdd = true
        let task = Task { @MainActor in
            await VocabularySyncEngine().execute(
                pendingEntries: [entry],
                modelContext: context,
                service: service,
                emit: { _ in }
            )
        }
        await service.waitUntilAddStarted()
        task.cancel()
        let result = await task.value

        #expect(result.terminalOutcome == .keepCancelled)
        #expect(!entry.isFailed)
    }

    @Test("backend rejected add items fail the add step and make the sync partial")
    func rejectedAddIsFailedAndPartial() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeEntry(word: "rejected-word")
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.addResponse = KGAddResponse(
            created: 0,
            skipped: 0,
            duplicates: [],
            cardIds: [:],
            rejected: [KGRejectedItem(index: 0, word: "rejected-word", reason: "word: bad")]
        )
        var events: [VocabularySyncEvent] = []

        let result = await VocabularySyncEngine().execute(
            pendingEntries: [entry],
            modelContext: context,
            service: service,
            emit: { events.append($0) }
        )

        #expect(result.terminalOutcome == .partial)
        #expect(entry.isFailed)
        #expect(entry.isRejectedAdd)
        #expect(!entry.isPending)
        #expect(!entry.shouldUploadOnNextSync)
        let failedDetail = L10n.format("部分上傳失敗（%@ 筆）", "1")
        let reportedFailedCount = events.contains {
            if case .stepFinished("upload_add", status: .error, let detail) = $0 {
                return detail == failedDetail
            }
            return false
        }
        #expect(reportedFailedCount)
    }

    @Test("rejected add is terminal: the next sync neither re-uploads it nor re-reports the failure")
    func rejectedAddIsNotRetriedOnNextSync() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeEntry(word: "rejected-word")
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.addResponse = KGAddResponse(
            created: 0,
            skipped: 0,
            duplicates: [],
            cardIds: [:],
            rejected: [KGRejectedItem(index: 0, word: "rejected-word", reason: "word: bad")]
        )
        let first = await VocabularySyncEngine().execute(
            pendingEntries: [entry], modelContext: context, service: service, emit: { _ in }
        )
        #expect(first.terminalOutcome == .partial)

        let second = await VocabularySyncEngine().execute(
            pendingEntries: [entry], modelContext: context, service: service, emit: { _ in }
        )

        #expect(service.calls.filter { $0 == "add" }.count == 1)
        #expect(second.terminalOutcome == .completed)
        #expect(entry.isFailed)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([VocabularyEntry.self, Notebook.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeEntry(word: String) -> VocabularyEntry {
        VocabularyEntry(
            word: word,
            translation: "translation",
            context: "context",
            bookTitle: "book"
        )
    }

    private func makePendingEdit(
        word: String = "edited",
        notebookId: String = "notebook-a"
    ) -> VocabularyEntry {
        let entry = makeEntry(word: word)
        entry.notebookId = notebookId
        entry.kgCardId = "card-1"
        entry.markSynced()
        entry.translation = "edited translation"
        entry.explanation = "edited explanation"
        entry.syncAction = .edit
        entry.syncState = .pending
        return entry
    }
}

private enum TestError: Error {
    case expected
}

private struct EditRequest: Equatable {
    let word: String
    let translation: String
    let explanation: String?
    let notebookId: String
}

@MainActor
private final class FakeVocabularySyncService: VocabularySyncEngineServing {
    var addResponse = KGAddResponse(created: 0, skipped: 0, duplicates: [], cardIds: [:])
    var triggerError: Error?
    var batchDeleteError: Error?
    var editError: Error?
    var pullError: Error?
    var blockAdd = false
    var blockEdit = false
    /// 在 batchAdd 送出後、回傳前執行，模擬 in-flight 期間的使用者操作（#2733）。
    var onAddInFlight: (() -> Void)?
    private(set) var calls: [String] = []
    private(set) var editRequests: [EditRequest] = []
    private var addStarted = false
    private var editStarted = false

    func batchAdd(entries: [VocabularyEntry], notebookId: String) async throws -> KGAddResponse {
        calls.append("add")
        addStarted = true
        if blockAdd {
            try await Task.sleep(for: .seconds(60))
        }
        onAddInFlight?()
        return addResponse
    }

    func batchDeleteCards(words: [String], notebookId: String) async throws -> KGBatchDeleteResponse {
        calls.append("batchDelete")
        if let batchDeleteError { throw batchDeleteError }
        return KGBatchDeleteResponse(deleted: words.count, deleted_words: words, not_found: [])
    }

    func deleteCard(word: String, notebookId: String) async throws {
        calls.append("delete")
    }

    func updateCardContent(
        word: String,
        translation: String,
        explanation: String?,
        notebookId: String
    ) async throws {
        calls.append("edit")
        editStarted = true
        editRequests.append(
            EditRequest(
                word: word,
                translation: translation,
                explanation: explanation,
                notebookId: notebookId
            )
        )
        if blockEdit {
            try await Task.sleep(for: .seconds(60))
        }
        if let editError { throw editError }
    }

    func triggerPipeline(notebookId: String) async throws {
        calls.append("trigger")
        if let triggerError { throw triggerError }
    }

    func pushReviewStates(container: ModelContainer) async throws -> (updated: Int, skipped: Int) {
        calls.append("pushStates")
        return (0, 0)
    }

    func pushReviewEvents(container: ModelContainer) async throws -> (inserted: Int, skipped: Int) {
        calls.append("pushEvents")
        return (0, 0)
    }

    func pullCardsToLocal(
        container: ModelContainer,
        progress: ((String, Int, Int) -> Void)?,
        notebookId: String?
    ) async throws -> KGPullOutcome {
        calls.append("pull")
        if let pullError { throw pullError }
        return .unchanged
    }

    func pullReviewEvents(container: ModelContainer) async throws {
        calls.append("pullReviewEvents")
    }

    func waitUntilAddStarted() async {
        while !addStarted {
            await Task.yield()
        }
    }

    func waitUntilEditStarted() async -> Bool {
        for _ in 0..<1_000 {
            if editStarted { return true }
            await Task.yield()
        }
        return editStarted
    }
}
