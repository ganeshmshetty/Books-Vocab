#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

/// #3824：閱讀器與播客的 highlight 刷新 key（`VocabularyHighlightSignature.revision`）。
/// 插入或封存一筆影響高亮集合的 entry 必須改變 key，讓 owner 的 `.onChange` 觀察到變化；
/// 其他 notebook 的變動不得影響目前綁定本的 key。
///
/// 「翻頁不重算高亮」不在此檔斷言：翻頁狀態已獨立於 `ReaderPageTurnState`，owner body 不讀它，
/// 這是結構性隔離；SwiftUI body 求值次數無法在單元測試中計量，該驗收留給 UI／Instruments 證據。
@MainActor
@Suite("VocabularyHighlightSignature")
struct VocabularyHighlightSignatureTests {
    private func makeEntries(_ count: Int, notebookId: String = "nb") -> [VocabularyEntry] {
        (0..<count).map { index in
            let entry = VocabularyEntry(word: "word\(index)", translation: "t", context: "c", bookTitle: "b")
            entry.notebookId = notebookId
            return entry
        }
    }

    /// 插入一筆新 entry → key 改變；同一狀態再求值則穩定。
    @Test func insertingOneEntryChangesRevisionOnce() {
        var entries = makeEntries(5_000)
        let before = VocabularyHighlightSignature.revision(entries: entries, notebookId: "nb")
        entries.append(contentsOf: makeEntries(1).map { entry in
            entry.word = "inserted"
            return entry
        })
        let after = VocabularyHighlightSignature.revision(entries: entries, notebookId: "nb")
        #expect(after != before)
        #expect(VocabularyHighlightSignature.revision(entries: entries, notebookId: "nb") == after)
    }

    /// 封存一筆（shouldAppearInReader 由 true 轉 false）→ key 改變。
    @Test func archivingOneEntryChangesRevision() {
        let entries = makeEntries(5_000)
        let before = VocabularyHighlightSignature.revision(entries: entries, notebookId: "nb")
        entries[0].isArchived = true
        #expect(VocabularyHighlightSignature.revision(entries: entries, notebookId: "nb") != before)
    }

    /// 其他 notebook 的變動不影響目前綁定本的高亮 key。
    @Test func otherNotebookChangesDoNotChangeScopedRevision() {
        var entries = makeEntries(100)
        let before = VocabularyHighlightSignature.revision(entries: entries, notebookId: "nb")
        let foreign = makeEntries(1, notebookId: "other")
        entries.append(contentsOf: foreign)
        #expect(VocabularyHighlightSignature.revision(entries: entries, notebookId: "nb") == before)
    }
}
#endif
