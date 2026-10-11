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
        let entryId = entry.id
        entry.restorePendingEntry()
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.addResponse = KGAddResponse(
            created: 1, skipped: 0, duplicates: [], cardIds: [entry.word: "card-9"]
        )
        service.onAddInFlight = { _ in entry.deleteLocally(in: context) }

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
        let removed = try isRemoved(entryId, from: context)
        #expect(removed)
    }

    @Test("a delete issued during the delete round trip keeps a captured add from being uploaded")
    func deleteDuringDeleteRoundTripSkipsCapturedAdd() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let queuedDelete = makeEntry(word: "gone")
        queuedDelete.kgCardId = "card-gone"
        queuedDelete.markSynced()
        queuedDelete.queueDelete()
        let add = makeEntry(word: "ghost")
        add.restorePendingEntry()
        context.insert(queuedDelete)
        context.insert(add)
        try context.save()

        let service = FakeVocabularySyncService()
        // Suspension point before the add group is reached: the add is captured but not yet on the wire.
        service.onDeleteInFlight = { add.deleteLocally(in: context) }

        _ = await VocabularySyncEngine().execute(
            pendingEntries: [queuedDelete, add], modelContext: context, service: service, emit: { _ in }
        )

        #expect(service.calls.contains("batchDelete"))
        #expect(!service.calls.contains("add"))
        #expect(!service.uploadedWords.contains("ghost"))
        #expect(add.kgCardId == nil)
        // The delete stays queued; the next sync resolves it as not_found on the server.
        #expect(add.isPendingDelete)
        #expect(!add.isUploadInFlight)
    }

    @Test("undo of a delete on an add the server never got restores a pending add that uploads on the next sync (#2484)")
    func undoOfUnsentAddDeleteUploadsOnNextSync() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let queuedDelete = makeEntry(word: "gone")
        queuedDelete.kgCardId = "card-gone"
        queuedDelete.markSynced()
        queuedDelete.queueDelete()
        let add = makeEntry(word: "ghost")
        add.restorePendingEntry()
        context.insert(queuedDelete)
        context.insert(add)
        try context.save()

        let service = FakeVocabularySyncService()
        service.onDeleteInFlight = { add.deleteLocally(in: context) }
        _ = await VocabularySyncEngine().execute(
            pendingEntries: [queuedDelete, add], modelContext: context, service: service, emit: { _ in }
        )
        #expect(add.isPendingDelete)
        #expect(add.kgCardId == nil)

        // SyncView「還原」
        add.undoQueuedDelete()
        #expect(add.isPendingAdd)

        service.onDeleteInFlight = nil
        service.addResponse = KGAddResponse(
            created: 1, skipped: 0, duplicates: [], cardIds: ["ghost": "card-ghost"]
        )
        let next = await VocabularySyncEngine().execute(
            pendingEntries: [add], modelContext: context, service: service, emit: { _ in }
        )

        #expect(next.terminalOutcome == .completed)
        #expect(service.uploadedWords == ["ghost"])
        #expect(add.isSynced)
        #expect(add.kgCardId == "card-ghost")
    }

    @Test("undo during the delete round trip is a no-op and the response removes the row (#2484)")
    func undoDuringDeleteRoundTripIsNoOp() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // 同步開始時已是 pending delete 且 kgCardId 為空（server 可能沒有此卡）。
        let entry = makeEntry(word: "flip")
        let entryId = entry.id
        entry.queueDelete()
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        var actionAfterUndo: VocabularySyncAction?
        service.onDeleteInFlight = {
            entry.undoQueuedDelete()
            actionAfterUndo = entry.syncAction
        }

        _ = await VocabularySyncEngine().execute(
            pendingEntries: [entry], modelContext: context, service: service, emit: { _ in }
        )

        #expect(actionAfterUndo == VocabularySyncAction.delete)
        let removed = try isRemoved(entryId, from: context)
        #expect(removed)
        #expect(!service.calls.contains("add"))
    }

    @Test("undo of a confirmed delete during its round trip cannot leave a synced row without a server card (#2484 P1)")
    func undoOfConfirmedDeleteDuringRoundTripStaysDeleted() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeEntry(word: "confirmed")
        let entryId = entry.id
        entry.kgCardId = "card-p1"
        entry.markSynced()
        entry.queueDelete()
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        var actionAfterUndo: VocabularySyncAction?
        service.onDeleteInFlight = {
            entry.undoQueuedDelete()
            actionAfterUndo = entry.syncAction
        }

        _ = await VocabularySyncEngine().execute(
            pendingEntries: [entry], modelContext: context, service: service, emit: { _ in }
        )

        // The server deletes the card, so the row must be removed, not restored to synced for the orphan cleanup.
        #expect(actionAfterUndo == VocabularySyncAction.delete)
        let removed = try isRemoved(entryId, from: context)
        #expect(removed)
        #expect(!service.calls.contains("add"))
    }

    @Test("undo during a per-card fallback request is a no-op and the row is removed (#2484 P2)")
    func undoDuringPerCardFallbackIsNoOp() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeEntry(word: "fallback-undo")
        let entryId = entry.id
        entry.kgCardId = "card-p2"
        entry.markSynced()
        entry.queueDelete()
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.batchDeleteError = TestError.expected
        var actionAfterUndo: VocabularySyncAction?
        service.onDeleteCardInFlight = {
            entry.undoQueuedDelete()
            actionAfterUndo = entry.syncAction
        }

        let result = await VocabularySyncEngine().execute(
            pendingEntries: [entry], modelContext: context, service: service, emit: { _ in }
        )

        #expect(result.terminalOutcome == .completed)
        #expect(actionAfterUndo == VocabularySyncAction.delete)
        #expect(service.calls.contains("delete"))
        let removed = try isRemoved(entryId, from: context)
        #expect(removed)
    }

    @Test("a delete the server never confirmed is undone to synced with its card after the sync returns (#2484)")
    func undoAfterFailedDeleteRestoresSyncedCard() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makeEntry(word: "kept")
        entry.kgCardId = "card-kept"
        entry.markSynced()
        entry.queueDelete()
        context.insert(entry)
        try context.save()

        let failing = FakeVocabularySyncService()
        failing.batchDeleteError = TestError.expected
        failing.deleteCardError = TestError.expected
        let first = await VocabularySyncEngine().execute(
            pendingEntries: [entry], modelContext: context, service: failing, emit: { _ in }
        )
        #expect(first.terminalOutcome == .partial)
        #expect(entry.isFailedDelete)

        entry.undoQueuedDelete()
        #expect(entry.isSynced)
        #expect(entry.kgCardId == "card-kept")

        let next = FakeVocabularySyncService()
        _ = await VocabularySyncEngine().execute(
            pendingEntries: [entry], modelContext: context, service: next, emit: { _ in }
        )
        #expect(entry.isSynced)
        #expect(!next.calls.contains("batchDelete"))
        #expect(!next.calls.contains("add"))
    }

    @Test("a delete issued while another notebook's add group uploads keeps the unsent add from being uploaded")
    func deleteDuringOtherGroupUploadSkipsAdd() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let alpha = makeEntry(word: "alpha")
        alpha.notebookId = "nb-a"
        alpha.restorePendingEntry()
        let beta = makeEntry(word: "beta")
        beta.notebookId = "nb-b"
        beta.restorePendingEntry()
        context.insert(alpha)
        context.insert(beta)
        try context.save()

        let service = FakeVocabularySyncService()
        service.addResponse = KGAddResponse(
            created: 1, skipped: 0, duplicates: [], cardIds: ["alpha": "card-alpha", "beta": "card-beta"]
        )
        // Group order comes from a dictionary, so delete whichever add the first upload has not sent.
        var removed: VocabularyEntry?
        service.onAddInFlight = { notebookId in
            guard removed == nil else { return }
            let other = notebookId == "nb-a" ? beta : alpha
            removed = other
            other.deleteLocally(in: context)
        }

        _ = await VocabularySyncEngine().execute(
            pendingEntries: [alpha, beta], modelContext: context, service: service, emit: { _ in }
        )

        let deletedAdd = try #require(removed)
        let sentAdd = deletedAdd === alpha ? beta : alpha
        #expect(service.calls.filter { $0 == "add" }.count == 1)
        #expect(service.uploadedWords == [sentAdd.word])
        #expect(sentAdd.isSynced)
        #expect(sentAdd.kgCardId != nil)
        #expect(deletedAdd.isPendingDelete)
        #expect(deletedAdd.kgCardId == nil)
        #expect(!deletedAdd.isUploadInFlight)
    }

    @Test("a delete issued while an edit is on the wire stays queued instead of being overwritten by the edit's success")
    func deleteDuringEditStaysQueued() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let entry = makePendingEdit()
        context.insert(entry)
        try context.save()

        let service = FakeVocabularySyncService()
        service.onEditInFlight = { entry.deleteLocally(in: context) }

        _ = await VocabularySyncEngine().execute(
            pendingEntries: [entry], modelContext: context, service: service, emit: { _ in }
        )

        #expect(entry.isPendingDelete)
        #expect(entry.kgCardId == "card-1")
        #expect(!entry.isUploadInFlight)
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

    /// 以 fetch 判定列是否已自 store 移除。`PersistentModel.isDeleted` 在 engine 的 save 後不是可靠的生命週期契約
    /// （見 BooksAndVocabTests `sanitizeOutbox_tombstonedOrphanDelete`），故斷言 store 內容。
    private func isRemoved(_ id: UUID, from context: ModelContext) throws -> Bool {
        try context.fetch(FetchDescriptor<VocabularyEntry>(predicate: #Predicate { $0.id == id })).isEmpty
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
    /// 在 batchAdd 送出後、回傳前執行，模擬 in-flight 期間的使用者操作（#2733）。參數為本批的 notebookId。
    var onAddInFlight: ((String) -> Void)?
    /// 在 batchDelete 往返期間執行（suspension 點），模擬使用者在 add 上傳前刪除。
    var onDeleteInFlight: (() -> Void)?
    /// 在 updateCardContent 送出後、回傳前執行，模擬 edit in-flight 期間的使用者刪除。
    var onEditInFlight: (() -> Void)?
    /// 在逐卡 fallback 的 deleteCard 往返期間執行（suspension 點），模擬 batch 失敗後的使用者操作（#2484 P2）。
    var onDeleteCardInFlight: (() -> Void)?
    var deleteCardError: Error?
    private(set) var calls: [String] = []
    private(set) var uploadedWords: [String] = []
    private(set) var editRequests: [EditRequest] = []
    private var addStarted = false
    private var editStarted = false

    func batchAdd(entries: [VocabularyEntry], notebookId: String) async throws -> KGAddResponse {
        calls.append("add")
        uploadedWords.append(contentsOf: entries.map(\.word))
        addStarted = true
        if blockAdd {
            try await Task.sleep(for: .seconds(60))
        }
        onAddInFlight?(notebookId)
        return addResponse
    }

    func batchDeleteCards(words: [String], notebookId: String) async throws -> KGBatchDeleteResponse {
        calls.append("batchDelete")
        onDeleteInFlight?()
        if let batchDeleteError { throw batchDeleteError }
        return KGBatchDeleteResponse(deleted: words.count, deleted_words: words, not_found: [])
    }

    func deleteCard(word: String, notebookId: String) async throws {
        calls.append("delete")
        onDeleteCardInFlight?()
        if let deleteCardError { throw deleteCardError }
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
        onEditInFlight?()
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
