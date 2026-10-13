#if os(iOS)
import Testing
@testable import BooksAndVocab

/// #3497：播客系列綁定清理只能在「單字本列表已 settle 且不含綁定 id」時清除。
/// 空 @Query（尚未載入）不得把綁定清成 nil。
@Suite("PodcastNotebookPickerSanitize")
struct PodcastNotebookPickerSanitizeTests {
    @Test func emptyUnsettledListKeepsBinding() {
        #expect(PodcastNotebookPicker.shouldClearBinding(bound: "X", liveNotebookIds: []) == false)
    }

    @Test func settledListMissingBindingClears() {
        #expect(PodcastNotebookPicker.shouldClearBinding(bound: "X", liveNotebookIds: ["Y"]) == true)
    }

    @Test func listContainingBindingKeeps() {
        #expect(PodcastNotebookPicker.shouldClearBinding(bound: "X", liveNotebookIds: ["X", "Y"]) == false)
    }
}
#endif
