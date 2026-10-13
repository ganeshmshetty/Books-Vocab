import Foundation

/// #2042 Stage 3：拉桿 level → 進度覆寫的純函式映射。
/// level 0 ＝ 左端綠，保留進度只改方向；level 1 ＝ 右端紫，歸零。
enum ReviewProgressAdjustment: Equatable {
    /// 保留既有進度，只切換方向。
    case keep
    /// 計數與 streak 保留，間隔縮為 `intervalHours`，排程自套用時刻起算。
    case reschedule(intervalHours: Double)
    /// 歸零：計數與 streak 歸 0，排程立即到期（與 `VocabularyEntry.resetReviewProgress` 一致）。
    case reset

    /// 達到此值即吸附為歸零（拉桿接近右端時不留「差一點歸零」的尷尬值）。
    static let resetSnapThreshold = 0.92

    /// 吸附後的拉桿值：≥ 門檻即為 1，其餘夾在 [0, 1]。
    static func snapped(_ level: Double) -> Double {
        let clamped = clampedLevel(level)
        return clamped >= resetSnapThreshold ? 1 : clamped
    }

    /// 拉桿值夾在 [0, 1]；非有限值視為左端（保留），避免 NaN 污染進度。
    static func clampedLevel(_ level: Double) -> Double {
        guard level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }

    /// `currentIntervalHours`／`initialIntervalHours` 皆取自該卡的 session 基準與有效初始間隔。
    static func forgetting(
        level: Double,
        currentIntervalHours: Double,
        initialIntervalHours: Double
    ) -> ReviewProgressAdjustment {
        let fraction = clampedLevel(level)
        if fraction == 0 { return .keep }
        if fraction >= resetSnapThreshold { return .reset }
        let scaled = currentIntervalHours * (1 - fraction)
        return .reschedule(intervalHours: max(scaled, initialIntervalHours))
    }
}
