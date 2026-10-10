#if os(iOS)
import Foundation

enum StatsCopy {
    static var loadingTitle: String { L10n.string("計算統計資料...") }
    static var emptyTitle: String { L10n.string("尚無學習資料") }
    static var emptyDescription: String { L10n.string("完成同步並開始複習後，這裡會顯示你的進度與預測。") }
    static var graphErrorTitle: String { L10n.string("關聯圖載入失敗") }
    static var retryTitle: String { L10n.string("重試") }
    static var graphTitle: String { L10n.string("關聯圖") }
    static var staleDataTitle: String { L10n.string("資料可能不是最新") }
    static var renderingTitle: String { L10n.string("關聯圖繪製中") }
    static var graphUnpaintedTitle: String { L10n.string("關聯圖尚未顯示") }
    static var graphEmptyTitle: String { L10n.string("探索單字建立連結") }
    static var currentStreakTitle: String { L10n.string("連續學習") }
    static var longestStreakTitle: String { L10n.string("最長紀錄") }
    static var totalCardsTitle: String { L10n.string("單字總數") }
    static var reviewedTodayTitle: String { L10n.string("今日複習") }
    static var dueTodayTitle: String { L10n.string("今日到期") }
    static var cardUnit: String { L10n.string("張") }
    static var dayUnit: String { L10n.string("天") }
    static var calendarTitle: String { L10n.string("學習日曆") }
    static var forecastTitle: String { L10n.string("複習預測") }
}
#endif
