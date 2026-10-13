#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
@Suite("KGVocabCoordinator banners")
struct KGVocabCoordinatorBannerTests {
    private final class StubDeleter: VocabularyDeleting, HealthChecking {
        var batchError: (any Error)?
        var batchResponse: KGBatchDeleteResponse?
        var deleteError: (any Error)?
        /// 模擬使用者在請求 await 期間撤銷刪除（#3059 (4)）。
        var beforeBatchReply: (@MainActor () -> Void)?
        var beforeDeleteCardReply: (@MainActor () -> Void)?
        func deleteCard(word: String, notebookId: String) async throws {
            if let beforeDeleteCardReply { await beforeDeleteCardReply() }
            if let deleteError { throw deleteError }
        }
        func batchDeleteCards(words: [String], notebookId: String) async throws -> KGBatchDeleteResponse {
            if let beforeBatchReply { await beforeBatchReply() }
            if let batchError { throw batchError }
            if let batchResponse { return batchResponse }
            return KGBatchDeleteResponse(deleted: words.count, deleted_words: words, not_found: [])
        }
        func healthCheck() async {}
    }

    @Test func dismissBannerClearsErrorAndSuccessMessages() {
        let coordinator = KGVocabCoordinator()
        coordinator.bannerError = .refresh(message: "offline", isRetryable: true, isNetworkRelated: true)
        coordinator.refreshSuccessMessage = "updated"

        coordinator.dismissBanner()

        #expect(coordinator.bannerError == nil)
        #expect(coordinator.errorMessage == nil)  // 衍生自 bannerError
        #expect(coordinator.refreshSuccessMessage == nil)
    }

    /// The top pill is an *event* (#2047): two identical outcomes in a row must
    /// notify twice, so every terminal result advances `noticeRevision` even when
    /// the resulting state value is unchanged.
    @Test func identicalRetryOutcomesEachAdvanceNoticeRevision() async throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let coordinator = KGVocabCoordinator()
        let stub = StubDeleter()
        #expect(coordinator.noticeRevision == 0)

        await coordinator.retryPendingDeletes(pendingDeletes: [], kgService: stub, modelContext: context)
        #expect(coordinator.noticeRevision == 1)
        #expect(coordinator.refreshSuccessMessage == L10n.string("待刪除項目已同步"))

        await coordinator.retryPendingDeletes(pendingDeletes: [], kgService: stub, modelContext: context)
        #expect(coordinator.noticeRevision == 2)
        #expect(coordinator.refreshSuccessMessage == L10n.string("待刪除項目已同步"))
    }

    /// #2728: per-word fallback 遇 404 = server 已無此字 → 刪除意圖已達成，
    /// 須本地收斂而非計為失敗（否則永久卡死重試 banner）。
    @Test func fallbackDelete404IsTreatedAsResolved() async throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let entry = VocabularyEntry(word: "ghost", translation: "鬼", context: "c", bookTitle: "b")
        entry.queueDelete()
        context.insert(entry)
        let stub = StubDeleter()
        stub.batchError = KGError.httpError(statusCode: 500, detail: "boom")
        stub.deleteError = KGError.httpError(statusCode: 404, detail: "not found")
        let coordinator = KGVocabCoordinator()

        await coordinator.retryPendingDeletes(pendingDeletes: [entry], kgService: stub, modelContext: context)

        #expect(coordinator.bannerError == nil)
        #expect(coordinator.refreshSuccessMessage == L10n.string("待刪除項目已同步"))
        #expect(try context.fetch(FetchDescriptor<VocabularyEntry>()).isEmpty)
    }

    /// #2733: 列仍被 sync 擷取（`isUploadInFlight`）時，batch not_found 不得硬刪；
    /// 該輪 sync 回應會自行收斂，retry 搶刪會讓 server 稍後建立的卡被 pull 復活。
    @Test func retryPendingDeletesKeepsRowHeldByInFlightSyncOnBatchNotFound() async throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let entry = VocabularyEntry(word: "inflight", translation: "t", context: "c", bookTitle: "b")
        entry.queueDelete()
        context.insert(entry)
        entry.isUploadInFlight = true
        let stub = StubDeleter()
        stub.batchResponse = KGBatchDeleteResponse(deleted: 0, deleted_words: [], not_found: ["inflight"])
        let coordinator = KGVocabCoordinator()

        await coordinator.retryPendingDeletes(pendingDeletes: [entry], kgService: stub, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<VocabularyEntry>()).count == 1)
        #expect(entry.syncAction == .delete)
        // 延後給進行中的 sync 收斂：不得宣稱「待刪除項目已同步」。
        #expect(coordinator.refreshSuccessMessage == nil)
    }

    /// #2733: 同上，但走 per-word fallback（batch 失敗後逐字 404 收斂）。
    @Test func retryPendingDeletesKeepsRowHeldByInFlightSyncOnFallback404() async throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let entry = VocabularyEntry(word: "inflight", translation: "t", context: "c", bookTitle: "b")
        entry.queueDelete()
        context.insert(entry)
        entry.isUploadInFlight = true
        let stub = StubDeleter()
        stub.batchError = KGError.httpError(statusCode: 500, detail: "boom")
        stub.deleteError = KGError.httpError(statusCode: 404, detail: "not found")
        let coordinator = KGVocabCoordinator()

        await coordinator.retryPendingDeletes(pendingDeletes: [entry], kgService: stub, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<VocabularyEntry>()).count == 1)
        #expect(entry.syncAction == .delete)
        // 延後給進行中的 sync 收斂：不得宣稱「待刪除項目已同步」。
        #expect(coordinator.refreshSuccessMessage == nil)
    }

    /// #3059 (4): batch 回應到達前使用者已撤銷刪除（列回到 add）→ 不得硬刪。
    /// 守門需在 await 之後重驗 `syncAction == .delete`，而非信任 await 前的快照。
    @Test func retryPendingDeletesKeepsRowUndoneDuringBatchAwait() async throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let entry = VocabularyEntry(word: "undone", translation: "t", context: "c", bookTitle: "b")
        entry.queueDelete()
        context.insert(entry)
        let stub = StubDeleter()
        stub.batchResponse = KGBatchDeleteResponse(deleted: 0, deleted_words: [], not_found: ["undone"])
        stub.beforeBatchReply = { entry.undoQueuedDelete() }
        let coordinator = KGVocabCoordinator()

        await coordinator.retryPendingDeletes(pendingDeletes: [entry], kgService: stub, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<VocabularyEntry>()).count == 1)
        #expect(entry.syncAction == .add)
    }

    /// #3059 (4): 同上，per-word fallback 的 404 回應到達前被撤銷。
    @Test func retryPendingDeletesKeepsRowUndoneDuringFallbackAwait() async throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let entry = VocabularyEntry(word: "undone", translation: "t", context: "c", bookTitle: "b")
        entry.queueDelete()
        context.insert(entry)
        let stub = StubDeleter()
        stub.batchError = KGError.httpError(statusCode: 500, detail: "boom")
        stub.deleteError = KGError.httpError(statusCode: 404, detail: "not found")
        stub.beforeDeleteCardReply = { entry.undoQueuedDelete() }
        let coordinator = KGVocabCoordinator()

        await coordinator.retryPendingDeletes(pendingDeletes: [entry], kgService: stub, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<VocabularyEntry>()).count == 1)
        #expect(entry.syncAction == .add)
    }

    /// #3059 (4) residual / I1: 已有 kgCardId 的列在 batch 回應前被撤銷（撤銷 → synced，保留舊 kgCardId），
    /// 但 server 已刪除該卡。收斂時不得留下失效的 kgCardId 標成 synced；依 T7 改回 pending add（無 kgCardId）。
    @Test func retryPendingDeletesRequeuesAddWhenUndoneDuringAwaitWithServerCard() async throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let entry = VocabularyEntry(word: "carded", translation: "t", context: "c", bookTitle: "b")
        entry.markSynced()
        entry.kgCardId = "card-carded"
        entry.queueDelete()
        context.insert(entry)
        let stub = StubDeleter()
        stub.batchResponse = KGBatchDeleteResponse(deleted: 1, deleted_words: ["carded"], not_found: [])
        stub.beforeBatchReply = { entry.undoQueuedDelete() }
        let coordinator = KGVocabCoordinator()

        await coordinator.retryPendingDeletes(pendingDeletes: [entry], kgService: stub, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<VocabularyEntry>()).count == 1)
        #expect(entry.syncAction == .add)
        #expect(entry.syncState == .pending)
        #expect(entry.kgCardId == nil)
    }

    /// #3370: 被 server 拒收的 add 排入刪除後，batch 回應前被撤銷（T7 還原為終態拒收），
    /// 回應到達時 settleResolvedDelete 不得把它復活為 pending add 重新上傳；拒收原因需保留。
    @Test func retryPendingDeletesKeepsRejectedAddUndoneDuringAwait() async throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let entry = VocabularyEntry(word: "rejected", translation: "t", context: "c", bookTitle: "b")
        entry.markRejected(reason: "invalid")
        entry.queueDelete()
        context.insert(entry)
        let stub = StubDeleter()
        stub.batchResponse = KGBatchDeleteResponse(deleted: 0, deleted_words: [], not_found: ["rejected"])
        stub.beforeBatchReply = { entry.undoQueuedDelete() }
        let coordinator = KGVocabCoordinator()

        await coordinator.retryPendingDeletes(pendingDeletes: [entry], kgService: stub, modelContext: context)

        #expect(try context.fetch(FetchDescriptor<VocabularyEntry>()).count == 1)
        #expect(entry.syncAction == .add)
        #expect(entry.syncState == .failed)
        #expect(entry.rejectedReason != nil)
    }

    @Test func dismissingTheStateDoesNotEmitANotice() {
        let coordinator = KGVocabCoordinator()
        coordinator.bannerError = .archivePartial(message: "1/3")
        coordinator.dismissBanner()
        #expect(coordinator.noticeRevision == 0)
    }
}
#endif
