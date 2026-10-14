//
//  NotebookReconciler.swift
//  Books & Vocab
//
//  Notebook reconcile 的純邏輯核心（無網路 / 無 UserDefaults / 不 save）。
//  從 `NotebookListCoordinator.reconcileNotebooks` 抽出，使 upsert / tombstone /
//  孤兒回收 / 離線占位 等不變式可單元測試 — 對齊 `PodcastSyncService.reconcileLocalState`
//  範式。Server 為權威；本地 SwiftData 為鏡像。

import Foundation
import SwiftData

/// 進程內 reconcile 證據帳（#3799，#3674 acceptance 2）。
///
/// 綁定經 CloudKit 抵達，「不在本機列表」可能是另一裝置新建、尚未進 snapshot 的合法缺席。
/// 因此只有**觀察到綁定之後才開始**、且 server 回報不含該 id 的 reconcile 才是刪除證據：
/// - `observeBinding`：caller 評估綁定時記下首次觀察時刻（必 ≥ 綁定實際抵達，故偏保守）。
/// - `recordReconcile`：reconcile 完成時以「開始時刻 + server 回報 id 集合」入帳（僅保留近期 N 筆）。
/// 不持久化：重啟後由新的觀察重新累積，只會偏向 keep。
final class NotebookReconcileLedger {
    static let shared = NotebookReconcileLedger()

    private struct Snapshot {
        let startedAt: Date
        let remoteIds: Set<String>
    }

    private static let retainedSnapshotLimit = 16

    private let lock = NSLock()
    private var snapshots: [Snapshot] = []
    private var firstObservedAt: [String: Date] = [:]

    func observeBinding(_ id: String, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if firstObservedAt[id] == nil { firstObservedAt[id] = now }
    }

    func recordReconcile(startedAt: Date, remoteIds: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.append(Snapshot(startedAt: startedAt, remoteIds: remoteIds))
        if snapshots.count > Self.retainedSnapshotLimit {
            snapshots.removeFirst(snapshots.count - Self.retainedSnapshotLimit)
        }
    }

    /// 是否有「觀察綁定之後才開始、且 server 不含此 id」的 reconcile。未觀察過 → false。
    func omittedAfterBinding(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let observed = firstObservedAt[id] else { return false }
        return snapshots.contains { $0.startedAt > observed && !$0.remoteIds.contains(id) }
    }
}

enum NotebookReconciler {

    /// 將 server 權威 notebook 清單與本地 SwiftData reconcile。
    ///
    /// - upsert：remote 新增 → insert；remoteId 命中 → 更新欄位（含 `isSoftDeleted`，對應遠端刪除）
    /// - tombstone：本地 `syncStatus == 1` 但 remote 不回報 → 標記 `isSoftDeleted`（其他裝置刪除）
    /// - **reap 孤兒**：本地 `remoteId` 前綴 `local-` 且 `syncStatus == 0` 的離線占位本，
    ///   在「已有可用真本」時硬刪。修舊版 offline fallback 用隨機 `local-<UUID>` 製造、
    ///   且永遠不被上面 `syncStatus == 1` tombstone pass 回收的重複「我的單字本」幽靈本。
    ///   殘留 entry 改派 `"default"`（對齊 `VocabularyEntry.resolveNotebookId` sentinel），
    ///   **不** queueDelete（那些卡屬於 server 上的真本，不可刪）。
    /// - cascade：被 tombstone 的**真本**下 entries `queueDelete`（讓 server 也刪）。
    ///
    /// - Returns: 本回合轉為不可見的 remoteId 集合（tombstoned ∪ reaped），
    ///   供 caller 清掉指向它們的 stale `activeNotebookId`。
    /// - Note: **不**呼叫 `modelContext.save()`；由 caller 統一 save。
    /// - Parameter fetchStartedAt: 發出 `remote` 那次 GET 的開始時間（本機時鐘）。tombstone 只對
    ///   `localInsertedAt < fetchStartedAt` 的列生效：之後才本地建立的列（例如 create 與 reconcile 交錯）
    ///   不可能在這份快照裡，不是遠端刪除的證據（#3675）。
    @discardableResult
    static func reconcile(
        remote: [KGNotebook],
        local localRows: [Notebook],
        allEntries: [VocabularyEntry],
        modelContext: ModelContext,
        fetchStartedAt: Date
    ) -> Set<String> {
        let local = collapseDuplicates(localRows, modelContext: modelContext)
        let localByRemoteId = Dictionary(
            local.map { ($0.remoteId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localSettings = (try? modelContext.fetch(
            FetchDescriptor<NotebookSettingsProjection>()
        )) ?? []
        let settingsByNotebookId = Dictionary(
            localSettings.map { ($0.notebookId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteIds = Set(remote.map(\.id))
        var tombstoned: Set<String> = []

        // Upsert remote → local
        for r in remote {
            if let l = localByRemoteId[r.id] {
                let wasAlive = !l.isSoftDeleted
                l.name = r.name
                l.color = r.color
                l.coverPattern = r.coverPattern
                l.isDefault = r.isDefault
                l.sortOrder = r.sortOrder
                if let created = serverCreatedAt(r) { l.createdAt = created }
                l.isSoftDeleted = r.isDeleted
                l.syncStatus = 1
                // Explore copy provenance（v1 inert；跨裝置 round-trip）。
                l.sourceSharedDeckId = r.sourceSharedDeckId
                l.sourceVersion = r.sourceVersion
                if r.isDeleted, let projection = settingsByNotebookId[r.id] {
                    modelContext.delete(projection)
                } else if let settings = r.settings {
                    let projection = settingsByNotebookId[r.id] ?? {
                        let created = NotebookSettingsProjection(notebookId: r.id)
                        modelContext.insert(created)
                        return created
                    }()
                    projection.applyRemote(settings)
                }
                if wasAlive && r.isDeleted { tombstoned.insert(l.remoteId) }
            } else if !r.isDeleted {
                let nb = Notebook(
                    remoteId: r.id,
                    name: r.name,
                    color: r.color,
                    isDefault: r.isDefault
                )
                nb.coverPattern = r.coverPattern
                nb.sortOrder = r.sortOrder
                if let created = serverCreatedAt(r) { nb.createdAt = created }
                nb.syncStatus = 1
                nb.sourceSharedDeckId = r.sourceSharedDeckId
                nb.sourceVersion = r.sourceVersion
                modelContext.insert(nb)
                if let settings = r.settings {
                    let projection = NotebookSettingsProjection(notebookId: r.id)
                    projection.applyRemote(settings)
                    modelContext.insert(projection)
                }
            } else if let projection = settingsByNotebookId[r.id] {
                // A deleted notebook's settings mirror must not outlive the
                // notebook tombstone and become a cross-notebook fallback.
                modelContext.delete(projection)
            }
        }

        // 曾同步但 server 不再回報 → tombstone（跨裝置刪除）。
        // 快照開始後才建立的列不在這份回應裡，不可據此 tombstone（#3675）。
        for l in local where l.syncStatus == 1 && !remoteIds.contains(l.remoteId) && !l.isSoftDeleted
            && l.localInsertedAt < fetchStartedAt {
            l.isSoftDeleted = true
            l.updatedAt = Date()
            tombstoned.insert(l.remoteId)
            if let projection = settingsByNotebookId[l.remoteId] {
                modelContext.delete(projection)
            }
        }

        // Reap 遺留 local-* 孤兒（僅在已有可用真本時，否則離線只有孤兒當預設會被清光）
        var reaped: Set<String> = []
        let hasUsableReal = local.contains { !$0.remoteId.hasPrefix("local-") && !$0.isSoftDeleted }
            || remote.contains { !$0.isDeleted }
        if hasUsableReal {
            for orphan in local
            where orphan.remoteId.hasPrefix("local-") && orphan.syncStatus == 0 && !orphan.isSoftDeleted {
                for entry in allEntries where entry.notebookId == orphan.remoteId {
                    entry.notebookId = "default"
                }
                reaped.insert(orphan.remoteId)
                modelContext.delete(orphan)
            }
        }

        // Cascade：僅 tombstone 的真本（reaped 孤兒的 entry 已改派、不刪卡）
        if !tombstoned.isEmpty {
            cascadeDeleteEntries(matching: tombstoned, allEntries: allEntries, modelContext: modelContext)
        }

        NotebookReconcileLedger.shared.recordReconcile(startedAt: fetchStartedAt, remoteIds: remoteIds)
        return tombstoned.union(reaped)
    }

    /// 收斂同 remoteId 的重複列（舊 create/reconcile race 的殘留，#3675）。保留一列：
    /// 優先未刪除、其次已同步；保留列沒有封面時接收其他列的封面，兩者封面不同則丟棄其他列的檔。
    /// Notebook 不持有 entry（entry 以 notebookId 字串關聯），刪重複列不影響卡片。
    private static func collapseDuplicates(
        _ rows: [Notebook],
        modelContext: ModelContext
    ) -> [Notebook] {
        var keeperByRemoteId: [String: Notebook] = [:]
        var extras: [Notebook] = []
        for row in rows {
            guard let current = keeperByRemoteId[row.remoteId] else {
                keeperByRemoteId[row.remoteId] = row
                continue
            }
            if isPreferredKeeper(row, over: current) {
                keeperByRemoteId[row.remoteId] = row
                extras.append(current)
            } else {
                extras.append(row)
            }
        }
        for extra in extras {
            guard let keeper = keeperByRemoteId[extra.remoteId] else { continue }
            if keeper.coverImagePath == nil {
                keeper.coverImagePath = extra.coverImagePath
            } else {
                NotebookCoverCommit.discardStagedFile(
                    staged: extra.coverImagePath,
                    original: keeper.coverImagePath
                )
            }
            modelContext.delete(extra)
        }
        return Array(keeperByRemoteId.values)
    }

    private static func isPreferredKeeper(_ candidate: Notebook, over current: Notebook) -> Bool {
        if candidate.isSoftDeleted != current.isSoftDeleted {
            return !candidate.isSoftDeleted
        }
        if (candidate.syncStatus == 1) != (current.syncStatus == 1) {
            return candidate.syncStatus == 1
        }
        return false
    }

    /// server 建立時間；舊後端不回傳 → nil，呼叫端保留本機值（#3677）。
    static func serverCreatedAt(_ remote: KGNotebook) -> Date? {
        remote.createdAt.flatMap(AppDateFormatters.parseISO8601)
    }

    /// 離線 / `fetchNotebooks` 失敗且本地無可見本子時，建立 canonical default 占位本。
    ///
    /// 用 `remoteId == "default"`（server-side sentinel）而非隨機 `local-<UUID>`，使真本
    /// 同步進來時 `reconcile` 的 upsert 就地合併、**不再分裂出孤兒**。idempotent：
    /// 已存在 `"default"` 紀錄則不重建（被刪的 sentinel 直接 resurrect，對齊
    /// `resolveNotebookId` 對 `"default"` 永遠有效的契約）。
    static func ensureOfflineDefault(local: [Notebook], modelContext: ModelContext) {
        if let existing = local.first(where: { $0.remoteId == "default" }) {
            if existing.isSoftDeleted {
                existing.isSoftDeleted = false
                existing.updatedAt = Date()
            }
            return
        }
        guard !local.contains(where: { !$0.isSoftDeleted }) else { return }
        let nb = Notebook(remoteId: "default", name: "我的單字本", isDefault: true)
        nb.syncStatus = 0
        modelContext.insert(nb)
    }

    /// 將指定 notebook 集合下尚未刪除的 entries 排入刪除 queue。
    /// 一律走 `queueDelete()`，由 sync 層處理 lifecycle，避免 hard delete 與
    /// in-flight upload task 競爭。
    ///
    /// caller 傳入的 `allEntries` 通常來自 `knowledgeListPredicate`（僅已同步且未封存），
    /// 會漏掉 pending / 封存的卡（#2730）；故以 `notebookId` 自行查詢，再與 `allEntries`
    /// 取聯集（以 persistentModelID 去重）。
    static func cascadeDeleteEntries(
        matching notebookIds: Set<String>,
        allEntries: [VocabularyEntry],
        modelContext: ModelContext
    ) {
        var targets: [PersistentIdentifier: VocabularyEntry] = [:]
        for entry in allEntries where notebookIds.contains(entry.notebookId) {
            targets[entry.persistentModelID] = entry
        }
        for notebookId in notebookIds {
            let descriptor = FetchDescriptor<VocabularyEntry>(
                predicate: #Predicate { $0.notebookId == notebookId }
            )
            for entry in (try? modelContext.fetch(descriptor)) ?? [] {
                targets[entry.persistentModelID] = entry
            }
        }
        for entry in targets.values where entry.syncAction != .delete {
            entry.queueDelete()
        }
    }
}
