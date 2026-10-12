import Foundation

/// 一次評分後的下次複習間隔（#3135）。純函式：評分按鈕的提示與 flush 寫入
/// （`ReviewSessionPersistence.applySubmittedAnswer`）共用此處，兩者不會分歧。
enum ReviewIntervalProjection {
    static func nextIntervalHours(
        baseline: TodayReviewSessionSnapshotStore.ReviewBaseline,
        feedback: ReviewFeedback,
        settings: ReviewSettings
    ) -> Double {
        let minInterval = settings.effectiveMinimumIntervalHours
        let baseInterval = baseline.reviewCount == 0
            ? settings.effectiveInitialIntervalHours
            : max(baseline.reviewIntervalHours, minInterval)
        return VocabularyReviewPolicy.nextIntervalHours(
            currentIntervalHours: baseInterval,
            feedback: feedback,
            settings: settings
        )
    }
}

/// 目前卡在「忘記／記得」兩顆按鈕上的下次間隔文字（#3135）。
struct ReviewGradeIntervalHints: Equatable {
    let forgotText: String
    let rememberedText: String

    init(baseline: TodayReviewSessionSnapshotStore.ReviewBaseline, settings: ReviewSettings) {
        forgotText = ReviewIntervalFormatter.text(
            hours: ReviewIntervalProjection.nextIntervalHours(baseline: baseline, feedback: .forgot, settings: settings)
        )
        rememberedText = ReviewIntervalFormatter.text(
            hours: ReviewIntervalProjection.nextIntervalHours(baseline: baseline, feedback: .remembered, settings: settings)
        )
    }
}

/// 下次間隔的顯示格式（#3135）：不足 24 小時顯示整數小時；不足 10 天顯示至多一位小數（去掉
/// 尾隨 .0）；不足 60 天顯示整數天；其餘以 30 天為一月取整。單位選擇與取整是純函式，文字走 `L10n`。
enum ReviewIntervalFormatter {
    enum Unit: Equatable {
        case hours
        case days
        case months
    }

    struct Components: Equatable {
        let unit: Unit
        let value: Double
    }

    static func components(hours: Double) -> Components {
        if hours < 24 {
            return .init(unit: .hours, value: max(1, hours.rounded()))
        }
        let days = hours / 24
        if days < 10 {
            return .init(unit: .days, value: (days * 10).rounded() / 10)
        }
        if days < 60 {
            return .init(unit: .days, value: days.rounded())
        }
        return .init(unit: .months, value: (days / 30).rounded())
    }

    static func text(hours: Double) -> String {
        let parts = components(hours: hours)
        let key: String
        switch parts.unit {
        case .hours: key = "todayReview.interval.hours"
        case .days: key = "todayReview.interval.days"
        case .months: key = "todayReview.interval.months"
        }
        return L10n.format(key, number(parts.value))
    }

    /// 數字依 App 語言格式化（小數點符號隨 locale）。
    static func number(_ value: Double) -> String {
        LocaleAwareFormatter.shared.string(from: NSNumber(value: value), style: .decimal)
    }
}
