import Foundation
import SwiftData
import SwiftUI
import TipKit

@MainActor protocol SyncCoordinating: AnyObject, Observable {
    var steps: [PipelineStep] { get }
    var phase: SyncPhase { get }
    var summaryText: String { get }
    var failureKind: SyncFailureKind? { get }
    func buildSteps(deleteCount: Int, addCount: Int)
    func startSync(pendingEntries: [VocabularyEntry], modelContext: ModelContext, kgService: any KGServing)
    func cancelSync()
    func resetForRetry(deleteCount: Int, addCount: Int)
}

// `PipelineStep` / `SyncPhase` 已搬到 `Services/SyncProgress.swift`——設定頁的
// 逐步同步進度共用同一組型別與同一套呈現，不該為此 import 詞庫頁這條管線。

enum SyncFailureKind {
    case partial
    case full
    case cancelled
}

/// Pipeline 跑完(或拋錯)後該落入的終態。
///
/// 抽成純函式讓「cancel 後不被泛型全失敗覆寫」的關鍵分類邏輯可單元測試,
/// 不必拖整條真實 async pipeline。三個輸入完全決定終態:
/// - `wasCancelled`：使用者已按取消(`cancelSync()` 設旗標)。**最高優先級** —
///   cancel 後無論 pipeline 走 break 正常結束、或某 `try await` 拋 `CancellationError`,
///   都不可覆寫 `cancelSync()` 已設好的 `.cancelled` 終態。回 `nil` 代表「保持現狀,
///   呼叫端不要動 phase/failureKind/summary」。
/// - `thrownError`：catch 收到的 error。非 nil = 走了 catch path。
/// - `encounteredFailure`：success path 累積的部分失敗旗標。
enum SyncTerminalOutcome: Equatable {
    /// 維持 `cancelSync()` 已設的 `.cancelled` 終態,呼叫端不覆寫。
    case keepCancelled
    /// `.completed` 全綠。
    case completed
    /// `.failed` + `.partial`,部分項目未同步。
    case partial
    /// `.failed` + `.full`,整條 pipeline 拋錯。
    case fullFailure
}

/// 等待伺服器 AI pipeline 收尾的重試間隔（秒），前密後疏。
///
/// 舊版是固定 10s × 3。pipeline 多數時候在數秒內就好了,固定 10s 代表**已經好了
/// 也要再等滿 10 秒**才會看到——使用者感受到的「Pending 很久」有一大半是這段空等,
/// 不是伺服器真的還在算。前密後疏讓常見的快路徑 1 秒就收斂,慢路徑仍有 15s 總預算
/// (舊版 30s)可等。
let syncPipelinePendingBackoffSeconds: [Double] = [1, 2, 4, 8]

/// 純函式:由三個訊號決定 sync 終態。見 `SyncTerminalOutcome`。
/// `wasCancelled` 一律壓過其他訊號(含 catch path 拋的 `CancellationError`)。
func syncTerminalOutcome(
    wasCancelled: Bool,
    thrownError: Bool,
    encounteredFailure: Bool
) -> SyncTerminalOutcome {
    if wasCancelled { return .keepCancelled }
    if thrownError { return .fullFailure }
    return encounteredFailure ? .partial : .completed
}

@Observable @MainActor
final class SyncCoordinator: SyncCoordinating {
    var steps: [PipelineStep] = []
    var phase: SyncPhase = .ready
    var summaryText: String = ""
    var failureKind: SyncFailureKind?

    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    /// 使用者已按取消。`cancelSync()` 已搶先把終態設成 `.cancelled`;pipeline
    /// 收尾(success path 或 catch path)看到此旗標就不覆寫終態。
    /// `Task.isCancelled` 不夠用——非 cancel 的真實錯誤也可能在 cancel 之外發生,
    /// 而此旗標只在使用者主動取消時為 true。
    @ObservationIgnored private var wasCancelledByUser = false

    func buildSteps(deleteCount: Int, addCount: Int) {
        var list: [PipelineStep] = []

        if deleteCount > 0 {
            list.append(PipelineStep(id: "upload_delete", label: "刪除 Books & Vocab 單字".localized))
        }
        if addCount > 0 {
            list.append(PipelineStep(id: "upload_add", label: "上傳新單字".localized))
        }

        list.append(PipelineStep(id: "trigger", label: "觸發背景 AI 處理".localized))
        list.append(PipelineStep(id: "push_review", label: "上傳複習進度".localized))
        list.append(PipelineStep(id: "pull", label: "下載單字至本地".localized))

        steps = list
    }

    func startSync(
        pendingEntries: [VocabularyEntry],
        modelContext: ModelContext,
        kgService: any KGServing
    ) {
        guard phase != .running else { return }
        phase = .running
        summaryText = ""
        failureKind = nil
        wasCancelledByUser = false
        AppAnalytics.track(.syncStarted)

        let adapter = KGServingVocabularySyncAdapter(base: kgService)
        let executor: any VocabularySyncExecuting = VocabularySyncEngine()
        pipelineTask = Task { [weak self] in
            defer { self?.pipelineTask = nil }
            guard let self else { return }

            let result = await executor.execute(
                pendingEntries: pendingEntries,
                modelContext: modelContext,
                service: adapter,
                emit: { [weak self] event in
                    self?.project(event)
                }
            )

            switch result.terminalOutcome {
            case .keepCancelled:
                break
            case .partial:
                self.summaryText = L10n.string("部分項目未成功同步，可直接再次重試。")
                self.failureKind = .partial
                self.phase = .failed
                AppAnalytics.track(.syncCompleted(durationMs: result.durationMs, outcome: .partial))
            case .completed:
                self.phase = .completed
                await SyncPendingTip.syncCompleted.donate()
                SyncPendingTip().invalidate(reason: .actionPerformed)
                AppAnalytics.track(.syncCompleted(durationMs: result.durationMs, outcome: .success))
            case .fullFailure:
                self.failureKind = .full
                self.phase = .failed
                AppAnalytics.track(.syncCompleted(durationMs: result.durationMs, outcome: .failed))
            }
        }
    }

    func cancelSync() {
        wasCancelledByUser = true
        pipelineTask?.cancel()
        phase = .failed
        failureKind = .cancelled
        summaryText = L10n.string("同步已取消")
        AppAnalytics.track(.syncCompleted(durationMs: 0, outcome: .cancelled))
    }

    func resetForRetry(deleteCount: Int, addCount: Int) {
        buildSteps(deleteCount: deleteCount, addCount: addCount)
        phase = .ready
        summaryText = ""
        failureKind = nil
    }

    /// 把 outbox 內指向已刪 / 不存在 notebook 的孤兒 entry 修好。
    ///
    /// - **Pending add orphan** → reassign to "default"，下次 sync 用 default 上傳
    /// - **Pending delete orphan** → local hard-delete（不送 server）。理由：
    ///   server 端 cascade 已經把該 notebook 下所有 card 刪掉了，繼續對 server
    ///   發 delete 不只多餘，rewrite 到 default 還可能誤刪 default 內同名字（同
    ///   `word` 但 cardId 不同），破壞使用者資料。
    /// - 同時是歷史 orphan 的 in-place migration，無需獨立 launch-time script
    /// - Idempotent — 重複跑無副作用，已是 default 或已 valid 的 entry 完全不變
    /// - 在 sync 入口呼叫一次，把 race condition 的後果在落 server 之前修好
    @discardableResult
    static func sanitizeOutbox(
        pendingEntries: [VocabularyEntry],
        modelContext: ModelContext
    ) -> Set<UUID> {
        var sanitized = 0
        var deletedEntryIds: Set<UUID> = []
        for entry in pendingEntries where entry.shouldUploadOnNextSync {
            let resolved = VocabularyEntry.resolveNotebookId(entry.notebookId, in: modelContext)
            guard resolved != entry.notebookId else { continue }
            if entry.syncAction == .delete {
                // 孤兒 delete：server 已 cascade 過，rewrite 到 default 風險大於收益
                AppLog.kg.warning("drop orphan delete: \(entry.word) from \(entry.notebookId)")
                deletedEntryIds.insert(entry.id)
                modelContext.delete(entry)
            } else {
                AppLog.kg.warning("sanitize orphan add: \(entry.word) \(entry.notebookId) → \(resolved)")
                entry.notebookId = resolved
            }
            sanitized += 1
        }
        let collapsed = collapseRecapturedDeletes(
            pendingEntries: pendingEntries.filter { !deletedEntryIds.contains($0.id) },
            modelContext: modelContext
        )
        deletedEntryIds.formUnion(collapsed)
        if sanitized > 0 || !collapsed.isEmpty {
            modelContext.safeSave()
        }
        return deletedEntryIds
    }

    /// 同 notebook 同字的「待刪 + 待新增」收斂成還原待刪那筆（#2105 defense-in-depth）。
    ///
    /// 若照原樣上傳，delete 先跑會刪掉 server card（SRS 歷史、AI 內容、graph links），
    /// add 再建一張沒有歷史的新卡。收斂規則：待刪那筆 `restorePendingEntry()` 並承接
    /// 新擷取的 translation／rootForm，新增那筆本機刪除（它從未上過 server），其 id
    /// 回傳給呼叫端排除在上傳批次外。只碰「從未同步的 add」，不碰 edit。
    private static func collapseRecapturedDeletes(
        pendingEntries: [VocabularyEntry],
        modelContext: ModelContext
    ) -> Set<UUID> {
        let uploadable = pendingEntries.filter(\.shouldUploadOnNextSync)
        var deletesByKey: [String: VocabularyEntry] = [:]
        for entry in uploadable where entry.syncAction == .delete {
            deletesByKey[outboxKey(entry)] = deletesByKey[outboxKey(entry)] ?? entry
        }
        guard !deletesByKey.isEmpty else { return [] }

        var removed: Set<UUID> = []
        for add in uploadable where add.syncAction == .add && add.kgCardId == nil {
            guard let queuedDelete = deletesByKey[outboxKey(add)] else { continue }
            AppLog.kg.warning("collapse delete+add into restore: \(add.word) in \(add.notebookId)")
            queuedDelete.restorePendingEntry()
            queuedDelete.translation = add.translation
            if let rootForm = add.rootForm { queuedDelete.rootForm = rootForm }
            removed.insert(add.id)
            modelContext.delete(add)
        }
        return removed
    }

    private static func outboxKey(_ entry: VocabularyEntry) -> String {
        "\(entry.notebookId)\u{1F}\(entry.word.lowercased())"
    }

    /// Batch-delete 回應中「可在本地安全收斂(刪除)」的字集合。
    ///
    /// = `deleted_words ∪ not_found`。兩者都是 happy-path:
    /// - `deleted_words`：server 這次成功刪掉的字。
    /// - `not_found`：server 上本就不存在的字（前一次已刪 / race）。對本地而言
    ///   刪除意圖已達成，必須同樣本地移除，否則該 entry 永遠標 `failed+delete`
    ///   → 每次 sync server 都回 `not_found` → 永久卡死的隱形重試迴圈。
    ///
    /// 只有「既不在 deleted_words 也不在 not_found」的字才是真正的 server 異常，
    /// 應 `markSyncFailed()` 重試。Set union 自然去重（兩集合理論上不重疊，但不依賴此前提）。
    static func locallyResolvableDeletes(
        from response: KGBatchDeleteResponse
    ) -> Set<String> {
        Set(response.deleted_words).union(response.not_found)
    }

    /// startSync batch-delete happy path 的回應分類收斂。抽成 static 函式讓
    /// 測試與 production 共用同一份邏輯（消除測試手抄 mirror loop 的
    /// dead-test 風險，比照 `triggerPipelinesIsolated`）。
    ///
    /// 本地收斂集合 = `deleted_words ∪ not_found`（`locallyResolvableDeletes`）：
    /// not_found = 已不存在於 server，刪除意圖已達成，必須本地移除，否則
    /// 永遠 failed+delete → 每次 sync 回 not_found → 卡死的隱形重試迴圈。
    /// 不在集合內（含 `failed` bucket = server graph 操作已回滾、卡片仍在）
    /// → markSyncFailed 保留重試（sync_lifecycle.md 不變式 1/2，#720）。
    static func applyBatchDeleteResponse(
        response: KGBatchDeleteResponse,
        entries: [VocabularyEntry],
        modelContext: ModelContext
    ) -> (deleted: Int, failedWords: [String]) {
        let resolvableSet = locallyResolvableDeletes(from: response)
        var deleted = 0
        var failedWords: [String] = []
        for entry in entries {
            // I3（VocabularyEntry）：擷取後的列在往返期間不得被還原，回應到達時仍為 delete。此守門只擋已非 delete 的
            // 陳舊列：不得硬刪（會丟掉從未上傳的 add），也不得標 failed（T5/T6）。
            guard entry.syncAction == .delete else { continue }
            if resolvableSet.contains(entry.word) {
                modelContext.delete(entry)
                deleted += 1
            } else {
                entry.markSyncFailed()
                failedWords.append(entry.word)
            }
        }
        return (deleted, failedWords)
    }

    /// startSync add-path 的 batchAdd 回應收斂。抽成 static 純函式讓測試與
    /// production 共用同一份邏輯（比照 `locallyResolvableDeletes`）。
    ///
    /// 後端以『原始』submitted word 為 cardIds key（created 與 duplicate 皆
    /// 回填 id），故 `entry.word` byte-exact 配對必中（sync_lifecycle.md
    /// 不變式 6）。回傳 cardId = 卡片確實存在 server（權威確認）→ 直接
    /// markSynced 出列，不再依賴 pull-merge 用 content 比對（會被後端清洗
    /// strip 尾標點/首字小寫破壞，例 "chateau," 永遠對不上 "chateau" →
    /// 卡在佇列重送）。無 cardId（異常）才保持 pending，下次重試。
    ///
    /// 後端 `rejected` 以提交陣列 `index` 指向原 entry（#2248），依 index 而非 word
    /// 標記（同字重複時 word 對不上）：直接 markSyncFailed，不留 pending 無限重送。
    /// 例外：in-flight 期間被刪除的 add 由 `markRejected` 保留 pending delete（#2733），交下一輪 batchDelete 收斂。
    ///
    /// 回傳未收斂的 entries（rejected 與無 cardId 的異常項）供呼叫端判定失敗；
    /// 無 cardId 且未被拒收者維持 pending+add，下一輪自然重試。
    @discardableResult
    static func convergeAddedEntries(
        response: KGAddResponse,
        entries: [VocabularyEntry]
    ) -> [VocabularyEntry] {
        let rejectedReasons = Dictionary(
            response.rejected.map { ($0.index, $0.reason) },
            uniquingKeysWith: { first, _ in first }
        )
        var unresolved: [VocabularyEntry] = []
        for (index, entry) in entries.enumerated() {
            if let reason = rejectedReasons[index] {
                entry.markRejected(reason: reason)
                unresolved.append(entry)
            } else if let cardId = response.cardIds[entry.word] {
                entry.kgCardId = cardId
                // A delete queued while the add was in flight stays queued: the card now exists server-side (#2733).
                if entry.syncAction != .delete {
                    entry.markSynced()
                }
            } else {
                unresolved.append(entry)
            }
        }
        return unresolved
    }

    /// Per-notebook isolated trigger pipeline 呼叫迴圈。
    ///
    /// 抽出來讓 `SyncCoordinator.startSync` 與測試共享同一份 isolation 邏輯，
    /// 避免「測試裡寫的 pattern」與「production 跑的 pattern」分裂的 dead-test 問題。
    /// 任何單一 notebook 失敗（例：notebook 已被刪 → 403）絕不會中斷其他 notebook 的觸發。
    /// 回傳失敗的 notebook id 列表（成功時為空）。
    static func triggerPipelinesIsolated(
        notebookIds: [String],
        trigger: (String) async throws -> Void
    ) async -> [String] {
        var failures: [String] = []
        for nbId in notebookIds {
            if Task.isCancelled { break }
            do {
                try await trigger(nbId)
            } catch {
                failures.append(nbId)
                AppLog.kg.error("triggerPipeline(\(nbId)) failed: \(error.localizedDescription)")
            }
        }
        return failures
    }

    private func project(_ event: VocabularySyncEvent) {
        switch event {
        case .stepStarted(let id):
            updateStep(id, status: .running)
        case .stepProgress(let id, let current, let total, let detail):
            updateStep(id, status: .running, current: current, total: total, detail: detail)
        case .stepFinished(let id, let status, let detail):
            updateStep(id, status: status, detail: detail)
        }
    }

    private func updateStep(
        _ id: String,
        status: PipelineStep.StepStatus,
        current: Int = 0,
        total: Int = 0,
        detail: String = ""
    ) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }

        withAnimation(AppMotion.phaseChange) {
            steps[idx].status = status
            steps[idx].current = current
            steps[idx].total = total
            if !detail.isEmpty {
                steps[idx].detail = detail
            }

            if status == .running && steps[idx].startTime == nil {
                steps[idx].startTime = Date()
            }
            if status == .done || status == .skipped || status == .error {
                if steps[idx].endTime == nil {
                    steps[idx].endTime = Date()
                    let durationMs = steps[idx].startTime.map {
                        Int(Date().timeIntervalSince($0) * 1000)
                    } ?? 0
                    AppAnalytics.track(.syncStepCompleted(
                        step: id,
                        durationMs: durationMs,
                        success: status == .done || status == .skipped
                    ))
                }
            }
        }
    }
}
