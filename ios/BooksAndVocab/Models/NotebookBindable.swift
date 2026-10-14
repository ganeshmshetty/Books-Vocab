import Foundation

/// 可綁定單字本的內容容器（書 / podcast 系列）。
///
/// 不變式：每個容器綁定**恰好一本真實單字本**。開啟時以 seed（最近使用的真實
/// 單字本）固化綁定，之後 highlight / 查詢 / autoSave scope 一律認綁定本，不再隨
/// 全域 active 中途漂移。Book 與 PodcastSeries 共用此語意。
protocol NotebookBindable: AnyObject {
    /// 綁定的單字本 remoteId（nil = 尚未綁定，待 seed 固化）。server 不下發；但 `Book` 經 CloudKit
    /// 鏡射，寫入會同步到使用者所有裝置，因此清除必須有正面刪除證據（見 `sanitizeAction`）。
    var preferredNotebookId: String? { get set }
}

extension NotebookBindable {
    /// 目標單字本 ID。**綁定即真相**：正常流程下開啟時即被 `ensureBoundNotebook(seed:)`
    /// 固化，故恆回 `preferredNotebookId`。`?? activeNotebookId` 僅為「未經開啟流程就
    /// 讀取」的防禦性 last-resort，非主路徑 —— scope 不隨全域 active 漂移。
    var resolvedNotebookId: String {
        preferredNotebookId ?? ActiveNotebookStore.shared.activeNotebookId
    }

    /// 強制綁定：未綁定時以 seed 固化並回傳；已綁定則回既有值、不覆寫（idempotent）。
    /// caller 負責持久化。
    @discardableResult
    func ensureBoundNotebook(seed: String) -> String {
        if let bound = preferredNotebookId { return bound }
        preferredNotebookId = seed
        return seed
    }

    /// seed 是否可固化成永久綁定：必須指向一本「已 settle 的真實 notebook」（存在於
    /// live 清單）。擋掉把離線占位 / 真本同步前的 `"default"` sentinel 凍結成綁定
    /// —— 那會把容器釘死在可能不存在的 notebook。live 清單空（尚未 settle）→ 不固化，
    /// 留 nil 由 `resolvedNotebookId` 防禦 fallback 撐過本 session，待 settle 後再 seed。
    static func canSeedBinding(seed: String, liveNotebookIds: Set<String>) -> Bool {
        liveNotebookIds.contains(seed)
    }

    /// stale 綁定清理決策（純函式，ReaderView、ReaderNotebookPicker、PodcastNotebookPicker 共用）。
    ///
    /// 只有正面證據才 clear：
    /// - `tombstonedNotebookIds`：本機列 `isSoftDeleted`（reconcile 或刪除寫入）→ 確定已刪除。
    /// - `local-*` 離線占位已不在本機（reconcile 回收）：server 永遠不會回報此 id，無法再解析 → clear。
    /// - `omittedByReconcileAfterBinding`：綁定之後才開始的 reconcile 回報 server 不含此 id，且本機無列
    ///   （#3799；證據由 `NotebookReconcileLedger` 提供）→ 從未同步且已刪除，永遠無法解析 → clear。
    ///
    /// 「不在本機 live 清單」本身不是刪除證據（另一裝置新建、尚未 reconcile 的 notebook 也會缺席，#3674）。
    /// 空列表仍是未 settle（#3411），不採信任何證據。
    /// 呼叫端只在 clear 時才清綁定並寫 manifest，keep 時不寫。
    static func sanitizeAction(
        bound: String?,
        localNotebookIds: Set<String>,
        tombstonedNotebookIds: Set<String>,
        omittedByReconcileAfterBinding: Bool = false
    ) -> NotebookBindingSanitizeAction {
        guard let bound else { return .keep }
        if tombstonedNotebookIds.contains(bound) { return .clear }
        if bound.hasPrefix("local-"), !localNotebookIds.contains(bound) { return .clear }
        if omittedByReconcileAfterBinding, !localNotebookIds.isEmpty, !localNotebookIds.contains(bound) {
            return .clear
        }
        return .keep
    }

    /// 呼叫端入口：先記下綁定的首次觀察時刻，再以 ledger 證據判定。
    static func sanitizeActionWithLedger(
        bound: String?,
        localNotebookIds: Set<String>,
        tombstonedNotebookIds: Set<String>,
        ledger: NotebookReconcileLedger = .shared
    ) -> NotebookBindingSanitizeAction {
        var omitted = false
        if let bound {
            ledger.observeBinding(bound)
            omitted = ledger.omittedAfterBinding(bound)
        }
        return sanitizeAction(
            bound: bound,
            localNotebookIds: localNotebookIds,
            tombstonedNotebookIds: tombstonedNotebookIds,
            omittedByReconcileAfterBinding: omitted
        )
    }
}

/// `NotebookBindable.sanitizeAction` 的結果。
enum NotebookBindingSanitizeAction: Equatable {
    /// 保留綁定，不寫 manifest。
    case keep
    /// 綁定的 notebook 有本機刪除證據（tombstone 或已回收的 local-* 占位），清除綁定。
    case clear
}
