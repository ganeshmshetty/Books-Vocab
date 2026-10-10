#if os(iOS)
import Testing
@testable import BooksAndVocab

struct StatsCopyTests {

    @Test func phaseCopy_staysStable() {
        #expect(StatsCopy.loadingTitle == L10n.string("計算統計資料..."))
        #expect(StatsCopy.emptyTitle == L10n.string("尚無學習資料"))
        #expect(StatsCopy.emptyDescription == L10n.string("完成同步並開始複習後，這裡會顯示你的進度與預測。"))
    }

    @Test func graphCopy_staysStable() {
        #expect(StatsCopy.graphErrorTitle == L10n.string("關聯圖載入失敗"))
        #expect(StatsCopy.retryTitle == L10n.string("重試"))
        #expect(StatsCopy.graphTitle == L10n.string("關聯圖"))
        #expect(StatsCopy.staleDataTitle == L10n.string("資料可能不是最新"))
        #expect(StatsCopy.renderingTitle == L10n.string("關聯圖繪製中"))
        #expect(StatsCopy.graphUnpaintedTitle == L10n.string("關聯圖尚未顯示"))
        #expect(StatsCopy.graphEmptyTitle == L10n.string("探索單字建立連結"))
    }

    @Test func sectionCopy_staysStable() {
        #expect(StatsCopy.currentStreakTitle == L10n.string("連續學習"))
        #expect(StatsCopy.longestStreakTitle == L10n.string("最長紀錄"))
        #expect(StatsCopy.dayUnit == L10n.string("天"))
        #expect(StatsCopy.calendarTitle == L10n.string("學習日曆"))
        #expect(StatsCopy.forecastTitle == L10n.string("複習預測"))
    }

    @Test func summaryCopy_staysStable() {
        #expect(StatsCopy.totalCardsTitle == L10n.string("單字總數"))
        #expect(StatsCopy.reviewedTodayTitle == L10n.string("今日複習"))
        #expect(StatsCopy.dueTodayTitle == L10n.string("今日到期"))
        #expect(StatsCopy.cardUnit == L10n.string("張"))
    }
}
#endif
