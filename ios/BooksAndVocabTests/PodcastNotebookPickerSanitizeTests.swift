#if os(iOS)
import Testing
@testable import BooksAndVocab

/// #3497：播客系列綁定清理只能在「單字本列表已 settle 且不含綁定 id」時清除。
/// 空 @Query（尚未載入）不得把綁定清成 nil。
/// #3527：決策邏輯統一走 `NotebookBindable.sanitizeAction`（PodcastSeries 已 conform），不再維護 picker 私有副本。
@Suite("PodcastNotebookPickerSanitize")
struct PodcastNotebookPickerSanitizeTests {
    @Test func emptyUnsettledListKeepsBinding() {
        #expect(PodcastSeries.sanitizeAction(bound: "X", liveNotebookIds: []) == .keep)
    }

    @Test func settledListMissingBindingClears() {
        #expect(PodcastSeries.sanitizeAction(bound: "X", liveNotebookIds: ["Y"]) == .clear)
    }

    @Test func listContainingBindingKeeps() {
        #expect(PodcastSeries.sanitizeAction(bound: "X", liveNotebookIds: ["X", "Y"]) == .keep)
    }
}
#endif
