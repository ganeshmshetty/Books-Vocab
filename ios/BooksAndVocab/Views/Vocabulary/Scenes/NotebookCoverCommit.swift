//
//  NotebookCoverCommit.swift
//  Books & Vocab
//
//  Notebook 封面圖（device-local，不上 server）的「提交 / 回滾」原子操作。
//
//  封面圖是 device-local：寫入 SwiftData `Notebook.coverImagePath` + 刪舊 jpg。
//  舊設計在 `updateNotebook` API 呼叫**前**就持久化新封面並刪舊圖，若 API 失敗
//  → name/color/coverPattern 保留 server 舊值，但 coverImagePath 已是新值且舊圖
//  已刪 → 「新封面 + 舊欄位」drift 且舊封面回不去（track-23）。
//
//  此型別把「封面落地」收斂成一個 side-effect helper，**只在 API 成功後呼叫**，
//  失敗則完全不動 → 與 server 欄位的成敗一致（全有或全無）。
//

import Foundation

/// 封面提交的純資料結果：要寫進 model 的新路徑，以及成功後該刪的舊檔。
/// 與檔案系統解耦，方便單元測試成功 / 失敗分支。
struct NotebookCoverCommitPlan: Equatable {
    /// 提交後 `Notebook.coverImagePath` 應持有的值（可能為 nil = 已移除封面）。
    let resolvedPath: String?
    /// 提交成功後應從磁碟移除的舊檔路徑（換圖 / 移除時的原檔）；nil = 無需刪除。
    let fileToRemove: String?
}

enum NotebookCoverCommit {

    /// 計算封面提交計畫。**純函式、無副作用**，可獨立測試。
    ///
    /// - Parameters:
    ///   - staged: EditSheet 當前選定的封面路徑（nil = 使用者移除了封面）。
    ///   - original: 進入編輯前的原始封面路徑（nil = 原本就沒有封面）。
    /// - Returns: 新路徑 + 待刪舊檔。僅在 `staged != original` 時才有舊檔要刪。
    static func plan(staged: String?, original: String?) -> NotebookCoverCommitPlan {
        // 封面未變更 → 不動 model、不刪檔（保險：避免誤刪仍在使用的圖）。
        guard staged != original else {
            return NotebookCoverCommitPlan(resolvedPath: original, fileToRemove: nil)
        }
        return NotebookCoverCommitPlan(resolvedPath: staged, fileToRemove: original)
    }

    /// 套用提交計畫：刪除舊檔（best-effort，失敗不影響 model 一致性）。
    /// 呼叫端負責把 `plan.resolvedPath` 寫進 `Notebook.coverImagePath`。
    static func removeStaleFile(_ plan: NotebookCoverCommitPlan) {
        if let stale = plan.fileToRemove {
            try? FileManager.default.removeItem(atPath: stale)
        }
    }
}

extension NotebookCoverCommit {
    /// 放棄 staged 新圖：提交失敗（API / 存檔）且 sheet 已 dismiss 時，staged 檔沒有任何
    /// owner，必須由 coordinator 清掉。`staged == original`（使用者沒換圖）時絕不動檔案。
    static func discardStagedFile(staged: String?, original: String?) {
        guard let staged, staged != original else { return }
        try? FileManager.default.removeItem(atPath: staged)
    }

    /// sheet 關閉（取消、下滑或 API / save 之外的任何 dismiss）時的 staged 清理（#3414）。
    /// `committed == true` 表示 staged 已交給 onSave，所有權轉給 coordinator，這裡一律不動檔案。
    static func discardUncommittedStaged(staged: String?, original: String?, committed: Bool) {
        guard !committed else { return }
        discardStagedFile(staged: staged, original: original)
    }

    /// processPhoto 寫出新 JPEG 後，若 sheet 已 commit（staged 已交給 onSave）或已關閉，
    /// 該檔沒有 owner，必須丟棄；只有仍在編輯中才可收為 staged（#3498）。
    static func shouldDiscardLateWrite(committed: Bool, dismissed: Bool) -> Bool {
        committed || dismissed
    }
}
