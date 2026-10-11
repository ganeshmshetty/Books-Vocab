import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Pins `SyncCoordinator.convergeAddedEntries(response:entries:)` — startSync
/// add-path 的 cardIds 回填收斂，production 與測試共用同一份邏輯（比照
/// `locallyResolvableDeletes` / `triggerPipelinesIsolated` 的 dead-test 防護範式）。
///
/// 契約來源 `docs/reference/sync_lifecycle.md`「本地新增上傳成功」：
/// - 不變式 4：收斂依據是回傳的 cardId（卡片確實存在 server 的權威確認），
///   不靠 pull-merge 的 content 字面比對。
/// - 不變式 6：`cardIds` 的 key 是 client submitted word 的 byte-exact echo；
///   iOS 以 `entry.word` 逐字節查找，任何 normalization 都會 silent miss。
/// - 無 cardId 回傳（異常）的 entry 保持 `pending + add`，下次重試。
@Suite("SyncAddConvergence")
@MainActor
struct SyncAddConvergenceTests {

    private func makePendingAdd(_ word: String) -> VocabularyEntry {
        let entry = VocabularyEntry(
            word: word,
            translation: "t",
            context: "ctx",
            bookTitle: "B"
        )
        entry.restorePendingEntry()
        return entry
    }

    private func makeResponse(cardIds: [String: String]) -> KGAddResponse {
        KGAddResponse(
            created: cardIds.count,
            skipped: 0,
            duplicates: [],
            cardIds: cardIds
        )
    }

    // MARK: - 命中收斂（created 與 duplicate 同路徑）

    @Test("cardIds 命中 → 回填 kgCardId 並 markSynced 出列")
    func hit_backfills_cardId_and_marks_synced() {
        let entry = makePendingAdd("ephemeral")
        let response = makeResponse(cardIds: ["ephemeral": "card-1"])

        SyncCoordinator.convergeAddedEntries(response: response, entries: [entry])

        #expect(entry.kgCardId == "card-1")
        #expect(entry.isSynced)
        #expect(!entry.shouldUploadOnNextSync)
    }

    @Test("duplicate（已存在 server）同樣回填收斂 — 與 created 走同一路徑")
    func duplicate_word_also_converges() {
        let entry = makePendingAdd("apple")
        // 後端對 duplicate 也回填 cardId（sync_lifecycle.md 轉移 2）
        let response = KGAddResponse(
            created: 0,
            skipped: 1,
            duplicates: ["apple"],
            cardIds: ["apple": "card-dup"]
        )

        SyncCoordinator.convergeAddedEntries(response: response, entries: [entry])

        #expect(entry.kgCardId == "card-dup")
        #expect(entry.isSynced)
    }

    // MARK: - 無 cardId（異常）→ 保持 pending 重試

    @Test("cardIds 無此 word → 保持 pending+add，不回填、不收斂")
    func miss_stays_pending_for_retry() {
        let entry = makePendingAdd("orphan")
        let response = makeResponse(cardIds: ["other": "card-x"])

        let unresolved = SyncCoordinator.convergeAddedEntries(
            response: response, entries: [entry]
        )

        #expect(entry.kgCardId == nil)
        #expect(entry.isPendingAdd)
        #expect(entry.shouldUploadOnNextSync)
        #expect(unresolved.map(\.word) == ["orphan"])
    }

    /// 不變式 6 的反向釘死：iOS 端是 byte-exact 查找。若後端違約對 key 做
    /// 清洗（"chateau," → "chateau"），client 端的正確行為是 MISS（保持
    /// pending 暴露違約），絕不是模糊比對硬收斂——模糊收斂會把 contract
    /// 破口藏起來（#720 同族問題）。
    @Test("後端違約清洗 key 時 byte-exact 查找必 miss — 不做模糊比對")
    func normalized_key_does_not_converge_byte_exact_lookup() {
        let entry = makePendingAdd("chateau,")
        let response = makeResponse(cardIds: ["chateau": "card-clean"])

        SyncCoordinator.convergeAddedEntries(response: response, entries: [entry])

        #expect(entry.kgCardId == nil)
        #expect(entry.isPendingAdd, "清洗後的 key 不得與原始 word 配對")
    }

    // MARK: - 混合批次

    @Test("混合批次：命中各自收斂、未命中各自保留，互不影響")
    func mixed_batch_converges_independently() {
        let hit = makePendingAdd("alpha")
        let miss = makePendingAdd("beta")
        let response = makeResponse(cardIds: ["alpha": "card-a"])

        let unresolved = SyncCoordinator.convergeAddedEntries(
            response: response, entries: [hit, miss]
        )

        #expect(hit.isSynced)
        #expect(hit.kgCardId == "card-a")
        #expect(miss.isPendingAdd)
        #expect(unresolved.map(\.word) == ["beta"])
    }

    @Test("空 entries → no-op，回傳空 unresolved")
    func empty_entries_is_noop() {
        let unresolved = SyncCoordinator.convergeAddedEntries(
            response: makeResponse(cardIds: [:]), entries: []
        )
        #expect(unresolved.isEmpty)
    }

    // MARK: - in-flight 期間被刪除（#2733）

    @Test("in-flight 期間被使用者刪除 → 命中後保留 pending delete，不被改回 synced")
    func delete_queued_during_flight_survives_convergence() {
        let entry = makePendingAdd("doomed")
        entry.isUploadInFlight = true
        #expect(entry.requiresServerDelete)
        entry.queueDelete()
        let response = makeResponse(cardIds: ["doomed": "card-d"])

        let unresolved = SyncCoordinator.convergeAddedEntries(response: response, entries: [entry])

        #expect(entry.kgCardId == "card-d")
        #expect(entry.isPendingDelete)
        #expect(unresolved.isEmpty)
    }

    @Test("in-flight 期間被刪除後 server 拒收 add → 不成為 rejected add，保留 delete 並經 batchDelete 本地移除（#2733）")
    func delete_queued_during_flight_survives_rejection() throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let entry = makePendingAdd("ghost")
        context.insert(entry)
        entry.isUploadInFlight = true
        entry.deleteLocally(in: context)
        #expect(entry.isPendingDelete)
        let response = KGAddResponse(
            created: 0,
            skipped: 0,
            duplicates: [],
            cardIds: [:],
            rejected: [KGRejectedItem(index: 0, word: "ghost", reason: "word: bad")]
        )

        let unresolved = SyncCoordinator.convergeAddedEntries(response: response, entries: [entry])

        #expect(!entry.isRejectedAdd)
        #expect(entry.rejectedReason == nil)
        #expect(entry.isPendingDelete)
        #expect(entry.shouldUploadOnNextSync)
        #expect(unresolved.map(\.word) == ["ghost"])

        // 下一輪 batchDelete：server 從未建立該卡 → not_found → 本地移除，不殘留任何終態列。
        _ = SyncCoordinator.applyBatchDeleteResponse(
            response: KGBatchDeleteResponse(deleted: 0, deleted_words: [], not_found: ["ghost"]),
            entries: [entry],
            modelContext: context
        )
        #expect(entry.isDeleted)
    }

    @Test("非 in-flight 的 pending add 本地刪除 → 直接移除，不排 server delete")
    func idle_pending_add_delete_is_local_only() throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let entry = makePendingAdd("idle")
        context.insert(entry)

        #expect(!entry.requiresServerDelete)
        entry.deleteLocally(in: context)
        #expect(entry.isDeleted)
    }

    @Test("已同步卡片被編輯（syncState 落在 pending+edit、kgCardId 保留）後本地刪除 → 不硬刪，排 server delete")
    func edited_synced_entry_delete_is_queued_not_hard_deleted() throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let entry = makePendingAdd("edited")
        context.insert(entry)
        entry.markSynced()
        entry.kgCardId = "card-edited"
        // WordEditSheet 的編輯路徑：synced → pending+edit，但 server 卡片仍存在。
        entry.syncAction = .edit
        entry.syncState = .pending
        #expect(!entry.isSynced)
        #expect(entry.requiresServerDelete)

        entry.deleteLocally(in: context)

        #expect(!entry.isDeleted)
        #expect(entry.isPendingDelete)
    }

    // MARK: - 撤銷待刪（SyncView「還原」，#2484）

    @Test("未送出的 add 被刪除後撤銷 → 回到 pending add，絕不 markSynced（server 從未確認此卡）")
    func undo_of_delete_on_unsent_add_restores_pending_add() {
        let entry = makePendingAdd("unsent")
        entry.isUploadInFlight = true
        entry.queueDelete()
        entry.isUploadInFlight = false
        #expect(entry.kgCardId == nil)
        #expect(entry.isPendingDelete)

        entry.undoQueuedDelete()

        #expect(entry.isPendingAdd)
        #expect(!entry.isSynced)
        #expect(entry.shouldUploadOnNextSync)
    }

    @Test("已確認 kgCardId 的待刪被撤銷 → synced，kgCardId 保留")
    func undo_of_delete_on_confirmed_card_restores_synced() {
        let entry = makePendingAdd("confirmed")
        entry.kgCardId = "card-c"
        entry.markSynced()
        entry.queueDelete()
        #expect(entry.isPendingDelete)

        entry.undoQueuedDelete()

        #expect(entry.isSynced)
        #expect(entry.kgCardId == "card-c")
        #expect(!entry.shouldUploadOnNextSync)
    }

    @Test("撤銷只作用於 delete 列；其他 action 為 no-op")
    func undo_is_noop_for_non_delete_rows() {
        let entry = makePendingAdd("plain")
        entry.undoQueuedDelete()
        #expect(entry.isPendingAdd)
    }

    @Test("in-flight 的待刪在 batchDelete 往返期間撤銷為 no-op，回應 not_found 直接硬刪（#2484 P1, I3）")
    func undo_during_flight_is_noop_and_response_removes_row() throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let entry = makePendingAdd("held")
        context.insert(entry)
        entry.queueDelete()
        entry.isUploadInFlight = true

        entry.undoQueuedDelete()
        #expect(entry.isPendingDelete)

        let outcome = SyncCoordinator.applyBatchDeleteResponse(
            response: KGBatchDeleteResponse(deleted: 0, deleted_words: [], not_found: ["held"]),
            entries: [entry],
            modelContext: context
        )

        #expect(entry.isDeleted)
        #expect(outcome.deleted == 1)
        #expect(outcome.failedWords.isEmpty)
    }

    @Test("陳舊的 batchDelete 回應不硬刪已非 delete 的列（防禦性守門）")
    func stale_batch_delete_response_skips_non_delete_row() throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let entry = makePendingAdd("stale")
        context.insert(entry)

        let outcome = SyncCoordinator.applyBatchDeleteResponse(
            response: KGBatchDeleteResponse(deleted: 0, deleted_words: [], not_found: ["stale"]),
            entries: [entry],
            modelContext: context
        )

        #expect(!entry.isDeleted)
        #expect(entry.isPendingAdd)
        #expect(outcome.deleted == 0)
        #expect(outcome.failedWords.isEmpty)
    }

    #if os(iOS)
    @Test("in-flight 的待刪被閱讀器重新擷取：不還原（I3），改新增一筆 pending add，原列保留待刪")
    func recapture_of_in_flight_delete_saves_fresh_add() throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self, Book.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let ctx = ModelContext(container)
        let held = makePendingAdd("held")
        held.kgCardId = "card-held"
        held.markSynced()
        held.queueDelete()
        held.isUploadInFlight = true
        ctx.insert(held)
        let book = Book(title: "B", author: "A", fileName: "f.epub")
        ctx.insert(book)
        let capture = ReaderVocabularyContext(
            vocabulary: [],
            modelContext: ctx,
            book: book,
            currentLocator: nil,
            notebookId: "default",
            toastCoordinator: AppToastCoordinator()
        )

        let saved = capture.saveEntry(
            selection: WordSelection(word: "held", context: "ctx", position: .zero),
            translation: "新譯文",
            rootForm: nil
        )
        try ctx.save()

        #expect(saved)
        #expect(held.isPendingDelete)
        #expect(held.kgCardId == "card-held")
        let all = try ctx.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(all.count == 2)
        #expect(all.contains { $0.isPendingAdd && $0.translation == "新譯文" })
    }
    #endif

    // MARK: - retry 路徑：failed+add 也能被收斂

    /// prepareForRetryAttempt 把 failed 轉回 pending 後才上傳，但防禦性釘住：
    /// 即使 entry 處於 failed+add，收斂（server 權威確認卡片存在）仍應成立。
    @Test("failed+add 命中 cardIds 同樣收斂為 synced")
    func failed_add_converges_on_hit() {
        let entry = makePendingAdd("retry-word")
        entry.markSyncFailed()
        let response = makeResponse(cardIds: ["retry-word": "card-r"])

        SyncCoordinator.convergeAddedEntries(response: response, entries: [entry])

        #expect(entry.isSynced)
        #expect(entry.kgCardId == "card-r")
    }

    @Test("後端 rejected 依 index 標 failed，不留 pending，其他項目照常收斂")
    func rejected_item_marks_failed_not_pending() {
        let ok = makePendingAdd("ok-word")
        let bad = makePendingAdd("bad-word")
        let response = KGAddResponse(
            created: 1,
            skipped: 0,
            duplicates: [],
            cardIds: ["ok-word": "card-ok"],
            rejected: [KGRejectedItem(index: 1, word: "bad-word", reason: "source.title: too long")]
        )

        let unresolved = SyncCoordinator.convergeAddedEntries(response: response, entries: [ok, bad])

        #expect(ok.isSynced)
        #expect(bad.isFailed)
        #expect(!bad.isPending)
        #expect(bad.rejectedReason == "source.title: too long")
        #expect(!bad.shouldUploadOnNextSync)
        #expect(unresolved.map(\.word) == ["bad-word"])
    }

    @Test("KGAddResponse 解碼 rejected；舊回應缺欄位時預設為空陣列")
    func decodes_rejected_and_defaults_when_absent() throws {
        let withRejected = #"{"created":0,"skipped":0,"duplicates":[],"cardIds":{},"rejected":[{"index":0,"word":"x","reason":"word: bad"}]}"#
        let decoded = try JSONDecoder().decode(KGAddResponse.self, from: Data(withRejected.utf8))
        #expect(decoded.rejected == [KGRejectedItem(index: 0, word: "x", reason: "word: bad")])

        let legacy = #"{"created":0,"skipped":0,"duplicates":[],"cardIds":{}}"#
        let decodedLegacy = try JSONDecoder().decode(KGAddResponse.self, from: Data(legacy.utf8))
        #expect(decodedLegacy.rejected.isEmpty)

        let nullWord = #"{"created":0,"skipped":0,"duplicates":[],"cardIds":{},"rejected":[{"index":0,"word":null,"reason":"source.title: too long"}]}"#
        let decodedNullWord = try JSONDecoder().decode(KGAddResponse.self, from: Data(nullWord.utf8))
        #expect(decodedNullWord.rejected == [KGRejectedItem(index: 0, word: nil, reason: "source.title: too long")])
    }
}
