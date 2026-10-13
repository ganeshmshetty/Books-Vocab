import Foundation

/// 可綁定單字本的內容容器（書 / podcast 系列）。
///
/// 不變式：每個容器綁定**恰好一本真實單字本**。開啟時以 seed（最近使用的真實
/// 單字本）固化綁定，之後 highlight / 查詢 / autoSave scope 一律認綁定本，不再隨
/// 全域 active 中途漂移。Book 與 PodcastSeries 共用此語意。
protocol NotebookBindable: AnyObject {
    /// 綁定的單字本 remoteId（nil = 尚未綁定，待 seed 固化）。本機偏好，server 不下發。
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

    /// onAppear / onChange 的 stale 綁定清理決策（純函式，ReaderView 與 ReaderNotebookPicker 共用）。
    /// 未綁定、live 清單空（尚未 settle）、或清單包含綁定 id → keep；僅「已 settle 且不含綁定 id」
    /// 才 clear。呼叫端只在 clear 時才清綁定並寫 manifest，keep 時不寫（避免把未 settle 的 nil 同步出去）。
    static func sanitizeAction(bound: String?, liveNotebookIds: Set<String>) -> NotebookBindingSanitizeAction {
        guard let bound else { return .keep }
        guard !liveNotebookIds.isEmpty else { return .keep }
        return liveNotebookIds.contains(bound) ? .keep : .clear
    }
}

/// `NotebookBindable.sanitizeAction` 的結果。
enum NotebookBindingSanitizeAction: Equatable {
    /// 保留綁定，不寫 manifest。
    case keep
    /// notebook 列表已 settle 且不含綁定 id，清除綁定。
    case clear
}
