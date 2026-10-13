import Foundation

extension VocabularyEntry {
    /// 依拉桿映射套用進度覆寫（#2042 Stage 3）。`keep` 不動任何欄位；`reschedule`／`reset`
    /// 排入 `pendingReviewProgressReset`，推送帶 `override: true`，確認後由既有機制清除。
    func applyReviewProgressAdjustment(
        _ adjustment: ReviewProgressAdjustment,
        now: Date,
        initialIntervalHours: Double
    ) {
        switch adjustment {
        case .keep:
            return
        case .reset:
            // 歸零語意沿用 Stage 2；間隔改用有效初始間隔（使用者可調整），不用 policy 預設值。
            resetReviewProgress(now: now)
            reviewIntervalHours = initialIntervalHours
        case .reschedule(let intervalHours):
            // 計數保留；排程自 now 起算，lastReviewedAt 取 now 作為 sent-instant 基準（與 Stage 2 reset 相同）。
            reviewIntervalHours = intervalHours
            nextReviewAt = now.addingTimeInterval(intervalHours * 3600)
            lastReviewedAt = now
            pendingReviewProgressReset = true
        }
    }
}
