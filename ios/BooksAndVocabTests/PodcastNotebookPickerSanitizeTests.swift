#if os(iOS)
import Testing
@testable import BooksAndVocab

/// #3497、#3674：播客系列綁定清理與閱讀器共用同一決策（`NotebookBindable.sanitizeAction`）。
/// 只有本機 tombstone 或已回收的 local-* 占位才 clear；「不在本機列表」不是刪除證據，空列表也不清。
/// #3527：PodcastSeries 已 conform，不再維護 picker 私有副本。
@Suite("PodcastNotebookPickerSanitize")
struct PodcastNotebookPickerSanitizeTests {
    @Test func emptyUnsettledListKeepsBinding() {
        #expect(PodcastSeries.sanitizeAction(
            bound: "X", localNotebookIds: [], tombstonedNotebookIds: []
        ) == .keep)
    }

    /// #3674：另一裝置新建、本機尚未 reconcile 的綁定，不得因缺席而被清掉。
    @Test func missingFromLocalListWithoutTombstoneKeepsBinding() {
        #expect(PodcastSeries.sanitizeAction(
            bound: "X", localNotebookIds: ["Y"], tombstonedNotebookIds: []
        ) == .keep)
    }

    @Test func tombstonedBindingClears() {
        #expect(PodcastSeries.sanitizeAction(
            bound: "X", localNotebookIds: ["X", "Y"], tombstonedNotebookIds: ["X"]
        ) == .clear)
    }

    @Test func reapedLocalOrphanBindingClears() {
        #expect(PodcastSeries.sanitizeAction(
            bound: "local-aaaa", localNotebookIds: ["Y"], tombstonedNotebookIds: []
        ) == .clear)
    }

    @Test func listContainingBindingKeeps() {
        #expect(PodcastSeries.sanitizeAction(
            bound: "X", localNotebookIds: ["X", "Y"], tombstonedNotebookIds: []
        ) == .keep)
    }
}
#endif
