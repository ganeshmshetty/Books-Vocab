#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

/// #3411：閱讀器 onAppear 的 stale 綁定清理，不得在 notebook 列表尚未 settle（空）時清掉
/// 綁定；否則 nil 會經 BookManifestStore 寫出，其他裝置 reconcile 後一起遺失。
/// ReaderNotebookPicker 與 ReaderView 共用同一純決策，避免兩套規則分歧。
struct ReaderNotebookPickerSanitizeTests {
    @Test func emptyUnsettledListKeepsBindingWithoutClearing() {
        // 列表空 = 尚未 settle：保留綁定，決策為 keep（呼叫端不寫 manifest）
        #expect(Book.sanitizeAction(bound: "X", liveNotebookIds: []) == .keep)
    }

    @Test func nonEmptyListContainingBindingKeepsBinding() {
        #expect(Book.sanitizeAction(bound: "X", liveNotebookIds: ["X", "Y"]) == .keep)
    }

    @Test func settledListLackingBindingClearsBinding() {
        #expect(Book.sanitizeAction(bound: "X", liveNotebookIds: ["Y"]) == .clear)
    }

    @Test func unboundBookIsKept() {
        #expect(Book.sanitizeAction(bound: nil, liveNotebookIds: ["Y"]) == .keep)
        #expect(Book.sanitizeAction(bound: nil, liveNotebookIds: []) == .keep)
    }
}
#endif
