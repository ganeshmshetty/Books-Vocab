#if os(iOS)
import Foundation
import ReadiumShared
import Testing
@testable import BooksAndVocab

/// #3824：閱讀器與播客的 highlight 刷新 key（`VocabularyHighlightSignature.revision`）。
/// 翻頁只更新 locator / progression，不改 @Query 結果，key 必須不變（不觸發 highlight 重算）；
/// 插入或封存一筆影響高亮集合的 entry 必須改變 key，讓 `loadLookedUpWords` 恰好刷新一次。
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

    /// 50 次翻頁（locator 更新、entries 不變）× 5,000 筆：key 全程不變 → 高亮刷新 0 次。
    @Test func pageTurnsOverFiveThousandEntriesDoNotChangeRevision() {
        let entries = makeEntries(5_000)
        let baseline = VocabularyHighlightSignature.revision(entries: entries, notebookId: "nb")
        var changes = 0
        for _ in 0..<50 {
            if VocabularyHighlightSignature.revision(entries: entries, notebookId: "nb") != baseline {
                changes += 1
            }
        }
        #expect(changes == 0)
    }

    /// 50 次翻頁（`ReaderPageTurnState.currentLocator` 更新）× 5,000 筆：高亮 revision 求值 0 次。
    /// 正控：翻頁後手動求值一次必須計 1，否則計數器失效，零次斷言即假綠。
    @Test func pageTurnsEvaluateNoHighlightRevisionOverFiveThousandEntries() throws {
        let entries = makeEntries(5_000)
        let source = VocabularyHighlightRevisionSource()
        let pageTurn = ReaderPageTurnState()
        let mediaType = try #require(MediaType("application/xhtml+xml"))
        for index in 0..<50 {
            let href = try #require(AnyURL(path: "chapter\(index).xhtml"))
            pageTurn.currentLocator = Locator(href: href, mediaType: mediaType)
        }
        #expect(source.computations == 0)
        _ = source.revision(entries: entries, notebookId: "nb")
        #expect(source.computations == 1)
    }

    /// 插入一筆新 entry → key 改變恰好一次（之後再翻頁不再改變）。
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
