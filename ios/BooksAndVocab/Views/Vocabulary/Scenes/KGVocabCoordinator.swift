import Foundation
import SwiftData
import SwiftUI

@MainActor protocol KGVocabCoordinating: AnyObject, Observable {
    var isLoading: Bool { get }
    var errorMessage: String? { get }
    var selectedEntry: VocabularyEntry? { get set }
    func dismissBanner()
    func handleRowTap(_ entryID: UUID, syncedEntries: [VocabularyEntry])
    func handleDeleteTap(_ entryID: UUID, syncedEntries: [VocabularyEntry], modelContext: ModelContext, toastCoordinator: AppToastCoordinator)
    func loadInitialData(authManager: any AuthManaging, kgService: any KGServing, modelContext: ModelContext) async
    func forceRefresh(kgService: any KGServing, modelContext: ModelContext) async
    func retryPendingDeletes(
        pendingDeletes: [VocabularyEntry],
        kgService: any VocabularyDeleting & HealthChecking,
        modelContext: ModelContext
    ) async
    func handleBatchDelete(_ entryIDs: Set<UUID>, syncedEntries: [VocabularyEntry], modelContext: ModelContext, toastCoordinator: AppToastCoordinator)
    func handleBatchArchive(_ entryIDs: Set<UUID>, syncedEntries: [VocabularyEntry], kgService: any KGServing, modelContext: ModelContext, toastCoordinator: AppToastCoordinator) async
}

@Observable @MainActor
final class KGVocabCoordinator: KGVocabCoordinating {
    var isLoading = false
    /// 錯誤 banner 的單一真相；`errorMessage` 由它衍生（保持 protocol / 既有讀者不變）。
    /// 呈現交給純函式 `KGVocabBanner.panel` / `.pill`，依實際 error 型別決定文案 / glyph / 可否重試。
    var bannerError: KGVocabBannerError?
    var refreshSuccessMessage: String?
    /// 每次操作寫下終態結果（成功／失敗）就 +1。頂端 pill 是「事件」不是「狀態」：
    /// 連續兩次相同結果（例如兩次下拉都「已是最新」）值不變，view 只能靠這個序號
    /// 知道又發生了一次、該再通知一次。取消不算終態，不前進。
    private(set) var noticeRevision = 0
    /// 最近一次 refresh 終態的觸發來源。可重試的錯誤一律進面板；只有使用者主動
    /// 觸發（`.explicit`）時才另彈 pill —— 進頁自動載入的失敗只顯示面板。
    private(set) var lastRefreshTrigger: RefreshTrigger?
    var selectedEntry: VocabularyEntry?

    /// 衍生自 `bannerError`。滿足 `KGVocabCoordinating.errorMessage` 唯讀契約，
    /// 亦供 `KGVocabView` 的 empty-state / phase-change 判斷沿用。
    var errorMessage: String? { bannerError?.message }

    func dismissBanner() {
        bannerError = nil
        refreshSuccessMessage = nil
    }

    func handleRowTap(_ entryID: UUID, syncedEntries: [VocabularyEntry]) {
        selectedEntry = syncedEntries.first { $0.id == entryID }
    }

    func handleDeleteTap(
        _ entryID: UUID,
        syncedEntries: [VocabularyEntry],
        modelContext: ModelContext,
        toastCoordinator: AppToastCoordinator
    ) {
        guard let entry = syncedEntries.first(where: { $0.id == entryID }) else { return }
        entry.queueDelete()
        if modelContext.safeSaveWithToast(toastCoordinator) {
            toastCoordinator.success("已刪除".localized)
        }
    }

    func loadInitialData(
        authManager: any AuthManaging,
        kgService: any KGServing,
        modelContext: ModelContext
    ) async {
        guard authManager.isLoggedIn else { return }

        // Demo 模式已有本地資料，不需呼叫 API
        if authManager.isDemoMode { return }

        isLoading = true
        defer { isLoading = false }

        await pullAndApplyResult(trigger: .automatic, kgService: kgService, modelContext: modelContext)
    }

    func forceRefresh(
        kgService: any KGServing,
        modelContext: ModelContext
    ) async {
        isLoading = true
        defer { isLoading = false }

        async let health: Void = kgService.healthCheck()
        await pullAndApplyResult(trigger: .explicit, kgService: kgService, modelContext: modelContext)
        await health
    }

    /// 誰發起了這次同步 —— 決定「沒有變化」時要不要出聲。
    ///
    /// 對齊 `ExplicitSync` 已經定下的全 app 政策：**自動同步成功靜默、顯式同步成功回饋**。
    /// 使用者主動下拉需要知道手勢生效了；每次進頁面自動跑的那輪則不該搶版面。
    enum RefreshTrigger {
        /// 進入單字本時 `.task` 自動觸發。
        case automatic
        /// 使用者下拉刷新 / 按重試 / 空狀態 CTA。
        case explicit
    }

    private func pullAndApplyResult(
        trigger: RefreshTrigger,
        kgService: any KGServing,
        modelContext: ModelContext
    ) async {
        do {
            let outcome = try await kgService.pullCardsToLocal(
                container: modelContext.container, progress: nil, notebookId: nil
            )
            // 同步本身刻意不可取消（跑在 KGService 的 unstructured Task 裡，已付出的
            // round trip 一定寫完）；可取消的是**等待的這一端**。使用者已經離開畫面時
            // 就別再改它的 banner ——「等待者」與「工作」在此分道。
            try Task.checkCancellation()
            bannerError = nil
            refreshSuccessMessage = Self.successMessage(for: outcome, trigger: trigger)
            lastRefreshTrigger = trigger
            noticeRevision += 1
        } catch is CancellationError {
            // 換頁、view 重建、或這一輪被取代。那是生命週期事件，不是故障：使用者什麼
            // 都沒做錯，網路也沒壞。保持畫面原狀（不覆寫既有 banner、不謊報網路錯誤）。
            // 資料不會因此漏掉——pull 已在背景跑完並寫入。
            AppLog.kg.info("vocab refresh cancelled (trigger=\(String(describing: trigger))) — banner untouched")
        } catch {
            // 依實際 error 型別分類，而非一律「離線模式」（見 KGVocabBanner）。
            bannerError = KGVocabBannerErrorClassifier.refreshError(from: error)
            refreshSuccessMessage = nil
            lastRefreshTrigger = trigger
            noticeRevision += 1
        }
    }

    /// 成功同步後該說什麼（`nil` = 什麼都不說）。
    ///
    /// 純函式，可單元測試。三條規則：
    /// 1. 真的有變化 → 一律報「已更新」，不分觸發來源。
    /// 2. 沒有變化 + 自動觸發 → **靜默**。這是原本每次進單字本都彈「單字庫已更新」的修正：
    ///    那則提示與實際同步結果無關，出現得太廉價，久了就沒人看。
    /// 3. 沒有變化 + 顯式觸發 → 回「已是最新」。使用者主動下拉，沉默會讓人以為刷新沒生效。
    static func successMessage(for outcome: KGPullOutcome, trigger: RefreshTrigger) -> String? {
        if outcome.hasChanges { return L10n.string("單字庫已更新") }
        switch trigger {
        case .automatic: return nil
        case .explicit: return L10n.string("單字庫已是最新")
        }
    }

    /// 待刪除 banner 的「重試」= outbox 的**第二條** drain。
    ///
    /// 與顯式同步共用普通卡的 batch delete，失敗時逐字重試。
    func retryPendingDeletes(
        pendingDeletes: [VocabularyEntry],
        kgService: any VocabularyDeleting & HealthChecking,
        modelContext: ModelContext
    ) async {
        var failedCount = 0
        var deferredCount = 0
        let grouped = Dictionary(grouping: pendingDeletes, by: \.notebookId)

        for (nbId, entries) in grouped {
            let words = entries.map(\.word)
            do {
                let response = try await kgService.batchDeleteCards(words: words, notebookId: nbId)
                // not_found = 已不存在於 server → 刪除意圖已達成，與 deleted_words
                // 走同一條本地收斂路徑；否則該字永遠 failed+delete → 永久卡死重試。
                let resolvableSet = SyncCoordinator.locallyResolvableDeletes(from: response)
                for entry in entries {
                    if resolvableSet.contains(entry.word) {
                        settleResolvedDelete(entry, in: modelContext, deferred: &deferredCount)
                    } else {
                        failedCount += 1
                        AppLog.kg.error("batchDelete: word unresolved on server '\(entry.word)'")
                    }
                }
            } catch {
                // Fallback to per-word delete
                for entry in entries {
                    do {
                        try await kgService.deleteCard(word: entry.word, notebookId: entry.notebookId)
                        settleResolvedDelete(entry, in: modelContext, deferred: &deferredCount)
                    } catch let KGError.httpError(statusCode: 404, _) {
                        // 404 = server 已無此字 → 刪除意圖已達成，本地收斂（#2728）。
                        settleResolvedDelete(entry, in: modelContext, deferred: &deferredCount)
                    } catch {
                        failedCount += 1
                        AppLog.kg.error("deleteCard retry failed '\(entry.word)': \(error.localizedDescription)")
                    }
                }
            }
        }

        modelContext.safeSave()

        if failedCount > 0 {
            bannerError = .pendingDeletesFailure(
                message: L10n.format("刪除失敗 %@ 筆，稍後將自動重試", "\(failedCount)")
            )
        } else {
            // 全數收斂成功 → 清空前次失敗殘留的 error banner，
            // 對齊 loadInitialData / forceRefresh 成功路徑的清空慣例。
            // 有列被延後給進行中的 sync（deferredCount）時不宣稱已同步：該列仍是 pending delete，由下一輪 sync 收斂。
            bannerError = nil
            if deferredCount == 0 {
                refreshSuccessMessage = L10n.string("待刪除項目已同步")
            }
        }
        noticeRevision += 1

        await kgService.healthCheck()
    }

    /// server 已確認此字不存在後的本地收斂（#2733、#3059 (4)）。守門在 await 之後重驗，不信 await 前的快照。
    /// - `isUploadInFlight` 的列仍由進行中的 sync 持有：刪除由該輪 sync 回應收斂（I3 / T5），retry 不得搶先移除，
    ///   否則 server 稍後建立的卡會被 pull 復活（#2733）；計入 `deferred`，呼叫端不得宣稱已同步。
    /// - await 期間被撤銷的列已不是 delete：server 卡已不存在，殘留的 `kgCardId` 失效，依 T7 清除後改回 pending add，
    ///   不留下標成 synced 的失效列（I1）。
    private func settleResolvedDelete(
        _ entry: VocabularyEntry,
        in modelContext: ModelContext,
        deferred: inout Int
    ) {
        guard !entry.isUploadInFlight else {
            deferred += 1
            return
        }
        switch entry.syncAction {
        case .delete:
            modelContext.delete(entry)
        case .add, .edit:
            entry.kgCardId = nil
            // 排入刪除前已被 server 拒收（rejectedReason 非 nil）：server 卡已不存在，依 T7 還原為終態拒收，不重送（#3370）。
            if entry.rejectedReason != nil {
                entry.restoreRejectedAdd()
            } else {
                entry.restorePendingEntry()
            }
        }
    }

    func handleBatchDelete(
        _ entryIDs: Set<UUID>,
        syncedEntries: [VocabularyEntry],
        modelContext: ModelContext,
        toastCoordinator: AppToastCoordinator
    ) {
        let entries = syncedEntries.filter { entryIDs.contains($0.id) }
        for entry in entries {
            entry.queueDelete()
        }
        if modelContext.safeSaveWithToast(toastCoordinator) {
            toastCoordinator.success(L10n.format("已刪除 %@ 個", String(entries.count)))
        }
    }

    func handleBatchArchive(
        _ entryIDs: Set<UUID>,
        syncedEntries: [VocabularyEntry],
        kgService: any KGServing,
        modelContext: ModelContext,
        toastCoordinator: AppToastCoordinator
    ) async {
        let entries = syncedEntries.filter { entryIDs.contains($0.id) }
        var failCount = 0
        let grouped = Dictionary(grouping: entries, by: \.notebookId)

        for (nbId, nbEntries) in grouped {
            let words = nbEntries.map(\.word)
            do {
                let response = try await kgService.batchArchiveCards(words: words, archived: true, notebookId: nbId)
                let updatedSet = Self.locallyResolvableArchives(from: response)
                for entry in nbEntries {
                    if updatedSet.contains(entry.word) {
                        entry.isArchived = true
                    } else {
                        failCount += 1
                    }
                }
            } catch {
                // Fallback to per-word archive
                for entry in nbEntries {
                    do {
                        try await kgService.archiveCard(word: entry.word, archived: true, notebookId: entry.notebookId)
                        entry.isArchived = true
                    } catch {
                        failCount += 1
                        AppLog.kg.error("Batch archive failed '\(entry.word)': \(error.localizedDescription)")
                    }
                }
            }
        }
        if modelContext.safeSaveWithToast(toastCoordinator) {
            if failCount > 0 {
                let successCount = entries.count - failCount
                bannerError = .archivePartial(
                    message: L10n.format("%@/%@ 張卡片已封存，部分失敗", "\(successCount)", "\(entries.count)")
                )
                noticeRevision += 1
            } else {
                // 全數封存成功 → 清空前次部分失敗殘留的 error 狀態，
                // 對齊 loadInitialData / forceRefresh 成功路徑的清空慣例。
                // 成功回饋只發這一則 pill；不再另寫 `refreshSuccessMessage`，否則同一動作
                // 會連續排出兩則成功 pill（#2047：一個事件一則通知）。
                bannerError = nil
                refreshSuccessMessage = nil
                toastCoordinator.success(L10n.format("已封存 %@ 個", String(entries.count)))
            }
        }
    }

    static func locallyResolvableArchives(
        from response: KGBatchArchiveResponse
    ) -> Set<String> {
        Set(response.updated_words).union(response.not_found)
    }

}
