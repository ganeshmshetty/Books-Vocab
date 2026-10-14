import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// NotebookReconciler 護欄 — 根除「iOS 出現多個幽靈『我的單字本』」的 client↔server 不一致。
///
/// 根因：舊版 offline fallback 在 `fetchNotebooks` 失敗時塞 `Notebook(remoteId:"local-<UUID>",
/// syncStatus:0)`；reconcile 的 tombstone pass 只清 `syncStatus==1` → 這些孤兒永遠回收不掉，
/// 等真本同步進來就與之並存重複顯示，且使用者連手動刪都因 server 404 而失敗。
@MainActor
struct NotebookReconcilerTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            PodcastSeries.self,
            PodcastEpisode.self,
            PodcastProgress.self,
            VocabularyEntry.self,
            ReviewRecord.self,
            Notebook.self,
            NotebookSettingsProjection.self,
            Book.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func remote(
        _ id: String,
        name: String = "本",
        isDefault: Bool = false,
        isDeleted: Bool = false
    ) -> KGNotebook {
        KGNotebook(
            id: id, name: name, color: nil, coverPattern: nil,
            sortOrder: 0, isDefault: isDefault, isDeleted: isDeleted,
            cardCount: 0, updatedAt: nil,
            sourceSharedDeckId: nil, sourceVersion: nil
        )
    }

    private func localNB(
        _ remoteId: String,
        name: String = "本",
        isDefault: Bool = false,
        isDeleted: Bool = false,
        syncStatus: Int
    ) -> Notebook {
        let nb = Notebook(remoteId: remoteId, name: name, isDefault: isDefault)
        nb.isSoftDeleted = isDeleted
        nb.syncStatus = syncStatus
        return nb
    }

    private func aliveNotebooks(_ ctx: ModelContext) throws -> [Notebook] {
        try ctx.fetch(FetchDescriptor<Notebook>()).filter { !$0.isSoftDeleted }
    }

    // MARK: - Fix B：回收 local-* 孤兒

    @Test func reconcile_reaps_local_orphans_when_real_default_present() throws {
        let ctx = try makeContext()
        let orphanA = localNB("local-aaaa", name: "我的單字本", isDefault: true, syncStatus: 0)
        let orphanB = localNB("local-bbbb", name: "我的單字本", isDefault: true, syncStatus: 0)
        let realDefault = localNB("default", name: "我的單字本", isDefault: true, syncStatus: 1)
        [orphanA, orphanB, realDefault].forEach { ctx.insert($0) }
        try ctx.save()

        let removed = NotebookReconciler.reconcile(
            remote: [remote("default", name: "我的單字本", isDefault: true)],
            local: [orphanA, orphanB, realDefault],
            allEntries: [],
            modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        let alive = try aliveNotebooks(ctx)
        #expect(alive.count == 1, "兩個 local-* 孤兒應被回收，只剩真本")
        #expect(alive.first?.remoteId == "default")
        #expect(removed.contains("local-aaaa"))
        #expect(removed.contains("local-bbbb"))
    }

    @Test func reconcile_keeps_orphan_when_no_real_notebook_offline() throws {
        // 離線且孤兒是唯一預設本時不可回收（否則使用者沒有任何本子可用）。
        let ctx = try makeContext()
        let orphan = localNB("local-aaaa", name: "我的單字本", isDefault: true, syncStatus: 0)
        ctx.insert(orphan)
        try ctx.save()

        _ = NotebookReconciler.reconcile(
            remote: [], local: [orphan], allEntries: [], modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        #expect(try aliveNotebooks(ctx).count == 1, "無真本時孤兒須保留")
    }

    @Test func reconcile_reassigns_orphan_entries_to_default_not_delete() throws {
        let ctx = try makeContext()
        let orphan = localNB("local-aaaa", isDefault: true, syncStatus: 0)
        let real = localNB("default", isDefault: true, syncStatus: 1)
        ctx.insert(orphan); ctx.insert(real)
        let stray = VocabularyEntry(word: "ghost", translation: "幽靈", context: "ctx", bookTitle: "B")
        stray.notebookId = "local-aaaa"
        stray.markSynced()  // synced+add：若 reap 誤 queueDelete 會變 .delete → 下方斷言 load-bearing
        ctx.insert(stray)
        try ctx.save()

        _ = NotebookReconciler.reconcile(
            remote: [remote("default", isDefault: true)],
            local: [orphan, real],
            allEntries: [stray],
            modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        #expect(stray.notebookId == "default", "孤兒殘留 entry 應改派 default")
        #expect(stray.syncAction == .add, "改派而非刪卡（reap 不得 queueDelete，卡屬 server 真本）")
    }

    @Test func reconcile_reaps_orphan_but_keeps_canonical_default_placeholder() throws {
        // 真實中毒態：離線占位 default(remoteId=="default", syncStatus=0) 與殘留 local-* 孤兒並存。
        // 占位非 local- 前綴 → 不可被 reap；孤兒該被 reap；真本(server id "default")合併占位。
        let ctx = try makeContext()
        let placeholder = localNB("default", name: "我的單字本", isDefault: true, syncStatus: 0)
        let orphan = localNB("local-aaaa", name: "我的單字本", isDefault: true, syncStatus: 0)
        ctx.insert(placeholder); ctx.insert(orphan)
        try ctx.save()

        let removed = NotebookReconciler.reconcile(
            remote: [remote("default", name: "我的單字本", isDefault: true)],
            local: [placeholder, orphan],
            allEntries: [],
            modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        let alive = try aliveNotebooks(ctx)
        #expect(alive.count == 1, "占位 default 合併真本 + 孤兒回收 → 只剩一個")
        #expect(alive.first?.remoteId == "default")
        #expect(alive.first?.syncStatus == 1, "canonical default 占位被 server 真本 upsert 升 synced")
        #expect(removed.contains("local-aaaa"))
        #expect(!removed.contains("default"), "canonical default 占位不可被當孤兒 reap")
    }

    // MARK: - Fix A：canonical default 占位 + 可被真本合併

    @Test func ensureOfflineDefault_creates_canonical_default_idempotently() throws {
        let ctx = try makeContext()
        NotebookReconciler.ensureOfflineDefault(local: [], modelContext: ctx)
        try ctx.save()

        var all = try ctx.fetch(FetchDescriptor<Notebook>())
        #expect(all.count == 1)
        #expect(all.first?.remoteId == "default", "占位本用 canonical default 而非 local-UUID")
        #expect(all.first?.syncStatus == 0)

        NotebookReconciler.ensureOfflineDefault(local: all, modelContext: ctx)
        try ctx.save()
        all = try ctx.fetch(FetchDescriptor<Notebook>())
        #expect(all.count == 1, "已存在 default 不可再建（idempotent）")
    }

    @Test func ensureOfflineDefault_resurrects_deleted_default_sentinel() throws {
        let ctx = try makeContext()
        let deadDefault = localNB("default", isDefault: true, isDeleted: true, syncStatus: 1)
        ctx.insert(deadDefault)
        try ctx.save()

        NotebookReconciler.ensureOfflineDefault(local: [deadDefault], modelContext: ctx)
        try ctx.save()

        #expect(deadDefault.isSoftDeleted == false, "被刪的 default sentinel 應 resurrect 而非另建")
        #expect(try ctx.fetch(FetchDescriptor<Notebook>()).count == 1)
    }

    @Test func offline_default_merges_with_server_default_no_duplicate() throws {
        let ctx = try makeContext()
        NotebookReconciler.ensureOfflineDefault(local: [], modelContext: ctx)
        try ctx.save()

        let local = try ctx.fetch(FetchDescriptor<Notebook>())
        _ = NotebookReconciler.reconcile(
            remote: [remote("default", name: "我的單字本", isDefault: true)],
            local: local,
            allEntries: [],
            modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        let alive = try aliveNotebooks(ctx)
        #expect(alive.count == 1, "離線占位 default 應被 server default upsert 就地合併，不分裂")
        #expect(alive.first?.syncStatus == 1, "合併後升級為 synced")
    }

    // MARK: - #3675：create / reconcile race

    @Test func reconcile_does_not_tombstone_rows_created_after_fetch_started() throws {
        // GET 在 t=1000 發出；t=2000 才本地建立的列不可能在該 GET 的結果裡，不是遠端刪除證據。
        let ctx = try makeContext()
        let stale = localNB("nb-old", syncStatus: 1)
        stale.localInsertedAt = Date(timeIntervalSince1970: 500)
        let fresh = localNB("nb-new", syncStatus: 1)
        fresh.localInsertedAt = Date(timeIntervalSince1970: 2_000)
        ctx.insert(stale); ctx.insert(fresh)
        try ctx.save()

        _ = NotebookReconciler.reconcile(
            remote: [], local: [stale, fresh], allEntries: [], modelContext: ctx,
            fetchStartedAt: Date(timeIntervalSince1970: 1_000)
        )
        try ctx.save()

        #expect(stale.isSoftDeleted, "快照前已同步、server 不回報 → 仍須 tombstone")
        #expect(!fresh.isSoftDeleted, "快照開始後才建立的本子不可被過期快照 tombstone")
    }

    @Test func reconcile_collapses_duplicate_rows_sharing_remoteId() throws {
        // 舊 create/reconcile race 殘留的重複列：upsert 只更新第一列，其餘永久殘留。
        let ctx = try makeContext()
        let first = localNB("nb-1", syncStatus: 1)
        let second = localNB("nb-1", syncStatus: 1)
        ctx.insert(first); ctx.insert(second)
        try ctx.save()

        _ = NotebookReconciler.reconcile(
            remote: [remote("nb-1")], local: [first, second], allEntries: [],
            modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Notebook>()).filter { $0.remoteId == "nb-1" }
        #expect(rows.count == 1, "同 remoteId 的重複列應收斂為一列")
    }

    // MARK: - 既有行為回歸（behavior-preserving）

    @Test func reconcile_tombstones_synced_notebook_missing_from_server() throws {
        let ctx = try makeContext()
        let a = localNB("nb-a", syncStatus: 1)
        let def = localNB("default", isDefault: true, syncStatus: 1)
        ctx.insert(a); ctx.insert(def)
        try ctx.save()

        let removed = NotebookReconciler.reconcile(
            remote: [remote("default", isDefault: true)],
            local: [a, def],
            allEntries: [],
            modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        let aAfter = try ctx.fetch(FetchDescriptor<Notebook>()).first { $0.remoteId == "nb-a" }
        #expect(aAfter?.isSoftDeleted == true, "曾同步但 server 不回報 → tombstone")
        #expect(removed.contains("nb-a"))
    }

    @Test func reconcile_inserts_new_remote_notebook() throws {
        let ctx = try makeContext()
        let def = localNB("default", isDefault: true, syncStatus: 1)
        ctx.insert(def)
        try ctx.save()

        _ = NotebookReconciler.reconcile(
            remote: [remote("default", isDefault: true), remote("nb-new", name: "新本")],
            local: [def],
            allEntries: [],
            modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        let newNB = try ctx.fetch(FetchDescriptor<Notebook>()).first { $0.remoteId == "nb-new" }
        #expect(newNB != nil, "remote 新增本子應 insert 進本地")
        #expect(newNB?.syncStatus == 1)
    }

    @Test func reconcile_cascades_entries_of_tombstoned_notebook() throws {
        let ctx = try makeContext()
        let nb = localNB("nb-x", syncStatus: 1)
        ctx.insert(nb)
        let entry = VocabularyEntry(word: "w", translation: "m", context: "c", bookTitle: "B")
        entry.notebookId = "nb-x"
        ctx.insert(entry)
        try ctx.save()

        // server 不再回報 nb-x → tombstone → 其下 entry 應 queueDelete
        _ = NotebookReconciler.reconcile(
            remote: [],
            local: [nb],
            allEntries: [entry],
            modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        #expect(entry.syncAction == .delete, "tombstone 真本下 entry 應 cascade queueDelete")
    }

    /// #2730：caller 傳入的 allEntries 只含已同步且未封存者（knowledgeListPredicate），
    /// pending / 封存的卡不在其中，cascade 必須以 notebookId 自行查詢而非依賴該陣列。
    @Test func cascade_includes_pending_and_archived_entries_outside_passed_list() throws {
        let ctx = try makeContext()
        let synced = VocabularyEntry(word: "a", translation: "m", context: "c", bookTitle: "B")
        synced.notebookId = "nb-x"
        synced.syncStatus = 1
        let pending = VocabularyEntry(word: "b", translation: "m", context: "c", bookTitle: "B")
        pending.notebookId = "nb-x"
        pending.syncStatus = 0
        let archived = VocabularyEntry(word: "c", translation: "m", context: "c", bookTitle: "B")
        archived.notebookId = "nb-x"
        archived.syncStatus = 1
        archived.isArchived = true
        let other = VocabularyEntry(word: "d", translation: "m", context: "c", bookTitle: "B")
        other.notebookId = "nb-y"
        [synced, pending, archived, other].forEach { ctx.insert($0) }
        try ctx.save()

        NotebookReconciler.cascadeDeleteEntries(
            matching: ["nb-x"],
            allEntries: [synced],
            modelContext: ctx
        )

        #expect(synced.syncAction == .delete)
        #expect(pending.syncAction == .delete, "pending 卡不可被漏掉")
        #expect(archived.syncAction == .delete, "封存卡不可被漏掉")
        #expect(other.syncAction != .delete, "他本子的卡不可被刪")
    }

    @Test func reconcile_tombstone_removes_notebook_settings_projection() throws {
        let ctx = try makeContext()
        let notebook = localNB("nb-deleted", syncStatus: 1)
        let projection = NotebookSettingsProjection(notebookId: notebook.remoteId)
        ctx.insert(notebook)
        ctx.insert(projection)
        try ctx.save()

        _ = NotebookReconciler.reconcile(
            remote: [],
            local: [notebook],
            allEntries: [],
            modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<NotebookSettingsProjection>()).isEmpty)
    }

    @Test func reconcile_deleted_remote_with_settings_removes_projection() throws {
        let ctx = try makeContext()
        let notebook = localNB("nb-deleted", syncStatus: 1)
        let projection = NotebookSettingsProjection(notebookId: notebook.remoteId)
        projection.applyRemote(KGNotebookSettings(
            reviewPolicy: KGNotebookSettingsGroup(
                value: KGNotebookReviewPolicy(.default), updatedAt: 10
            ),
            cardLayout: KGNotebookSettingsGroup<KGNotebookCardLayout>(
                value: nil, updatedAt: nil
            )
        ))
        ctx.insert(notebook)
        ctx.insert(projection)
        try ctx.save()

        let deleted = KGNotebook(
            id: notebook.remoteId,
            name: notebook.name,
            color: nil,
            coverPattern: nil,
            sortOrder: 0,
            isDefault: false,
            isDeleted: true,
            cardCount: 0,
            updatedAt: nil,
            sourceSharedDeckId: nil,
            sourceVersion: nil,
            settings: KGNotebookSettings(
                reviewPolicy: KGNotebookSettingsGroup(
                    value: KGNotebookReviewPolicy(.default), updatedAt: 10
                ),
                cardLayout: KGNotebookSettingsGroup<KGNotebookCardLayout>(
                    value: nil, updatedAt: nil
                )
            )
        )
        _ = NotebookReconciler.reconcile(
            remote: [deleted],
            local: [notebook],
            allEntries: [],
            modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<NotebookSettingsProjection>()).isEmpty)
    }

    @Test func reconcile_failed_projection_with_older_remote_stays_failed() throws {
        let ctx = try makeContext()
        let notebook = localNB("nb-dirty", syncStatus: 1)
        let projection = NotebookSettingsProjection(notebookId: notebook.remoteId)
        var localPolicy = ReviewPolicy.default
        localPolicy.mode = .custom
        projection.applyLocalReviewPolicy(localPolicy, updatedAt: 50)
        projection.syncState = .failed
        projection.syncError = "offline"
        ctx.insert(notebook)
        ctx.insert(projection)
        try ctx.save()

        let stale = KGNotebook(
            id: notebook.remoteId, name: notebook.name, color: nil, coverPattern: nil,
            sortOrder: 0, isDefault: false, isDeleted: false, cardCount: 0, updatedAt: nil,
            sourceSharedDeckId: nil, sourceVersion: nil,
            settings: KGNotebookSettings(
                reviewPolicy: KGNotebookSettingsGroup(
                    value: KGNotebookReviewPolicy(.default), updatedAt: 40
                ),
                cardLayout: KGNotebookSettingsGroup<KGNotebookCardLayout>(value: nil, updatedAt: nil)
            )
        )
        _ = NotebookReconciler.reconcile(
            remote: [stale], local: [notebook], allEntries: [], modelContext: ctx, fetchStartedAt: .distantFuture
        )
        try ctx.save()

        #expect(projection.syncState == .failed)
        #expect(projection.syncError == "offline")
        #expect(projection.reviewPolicyOverride == localPolicy)
        #expect(projection.reviewPolicyUpdatedAt == 50)
    }
}
