#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
@Suite("WordEditSheet save")
struct WordEditSheetSaveTests {
    private struct SaveFailure: Error {}

    private func makeSyncedEntry() -> VocabularyEntry {
        let entry = VocabularyEntry(
            word: "ephemeral",
            translation: "短暫的",
            context: "an ephemeral joy",
            explanation: "原始筆記",
            bookTitle: "Book"
        )
        entry.syncAction = .add
        entry.syncState = .synced
        return entry
    }

    @Test func failedSaveRestoresOriginalFields() {
        let entry = makeSyncedEntry()

        #expect(throws: SaveFailure.self) {
            try WordEditSheet.commitEdit(
                entry: entry,
                translation: "  新翻譯  ",
                explanation: "新筆記",
                save: { throw SaveFailure() }
            )
        }

        #expect(entry.translation == "短暫的")
        #expect(entry.explanation == "原始筆記")
        #expect(entry.syncAction == .add)
        #expect(entry.syncState == .synced)
    }

    @Test func successfulSaveAppliesTrimmedEditAndMarksPending() throws {
        let entry = makeSyncedEntry()

        try WordEditSheet.commitEdit(
            entry: entry,
            translation: "  新翻譯  ",
            explanation: "   ",
            save: {}
        )

        #expect(entry.translation == "新翻譯")
        #expect(entry.explanation == nil)
        #expect(entry.syncAction == .edit)
        #expect(entry.syncState == .pending)
    }

    @Test func emptyOrWhitespaceTranslationIsRejectedBeforeMutation() {
        for blank in ["", "   \n\t"] {
            let entry = makeSyncedEntry()
            var saveCalled = false

            #expect(throws: WordEditSheet.EditValidationError.translationLength) {
                try WordEditSheet.commitEdit(
                    entry: entry,
                    translation: blank,
                    explanation: "新筆記",
                    save: { saveCalled = true }
                )
            }

            #expect(!saveCalled)
            #expect(entry.translation == "短暫的")
            #expect(entry.syncAction == .add)
            #expect(entry.syncState == .synced)
        }
    }

    @Test func translationLengthBoundaryIsInclusiveAtMaximum() throws {
        let entry = makeSyncedEntry()
        let atLimit = String(repeating: "譯", count: 1000)

        try WordEditSheet.commitEdit(
            entry: entry,
            translation: atLimit,
            explanation: "",
            save: {}
        )
        #expect(entry.translation == atLimit)

        let overLimit = atLimit + "譯"
        let other = makeSyncedEntry()
        #expect(throws: WordEditSheet.EditValidationError.translationLength) {
            try WordEditSheet.commitEdit(
                entry: other,
                translation: overLimit,
                explanation: "",
                save: {}
            )
        }
        #expect(other.translation == "短暫的")
    }

    /// 伺服器以 Unicode scalar 計長度（#2548）。combining mark 會讓 Character 數與 scalar 數不同：
    /// 500 組 "e\u{301}" = 1000 scalars／500 Characters 應接受；501 組 = 1002 scalars 應拒絕。
    /// 若改回 `.count`（Character），501 組會被誤收，此測試必紅。
    @Test func translationLengthCountsUnicodeScalarsNotCharacters() throws {
        let combining = "e\u{301}"
        let atLimit = String(repeating: combining, count: 500)
        #expect(atLimit.unicodeScalars.count == 1000)
        #expect(atLimit.count == 500)

        let entry = makeSyncedEntry()
        try WordEditSheet.commitEdit(
            entry: entry,
            translation: atLimit,
            explanation: "",
            save: {}
        )
        #expect(entry.translation == atLimit)

        let overLimit = String(repeating: combining, count: 501)
        #expect(overLimit.unicodeScalars.count == 1002)
        let other = makeSyncedEntry()
        #expect(throws: WordEditSheet.EditValidationError.translationLength) {
            try WordEditSheet.commitEdit(
                entry: other,
                translation: overLimit,
                explanation: "",
                save: {}
            )
        }
        #expect(other.translation == "短暫的")
    }

    @Test func oversizedNoteIsRejectedBeforeMutation() {
        let entry = makeSyncedEntry()
        var saveCalled = false
        let overLimit = String(repeating: "n", count: 5001)

        #expect(throws: WordEditSheet.EditValidationError.noteLength) {
            try WordEditSheet.commitEdit(
                entry: entry,
                translation: "新翻譯",
                explanation: overLimit,
                save: { saveCalled = true }
            )
        }

        #expect(!saveCalled)
        #expect(entry.translation == "短暫的")
        #expect(entry.explanation == "原始筆記")
    }

    @Test func noteLengthBoundaryIsInclusiveAtMaximum() throws {
        let entry = makeSyncedEntry()
        let atLimit = String(repeating: "n", count: 5000)

        try WordEditSheet.commitEdit(
            entry: entry,
            translation: "新翻譯",
            explanation: atLimit,
            save: {}
        )

        #expect(entry.explanation == atLimit)
    }

    /// 後端 Python `str.strip()`（`vocab.py` 的 meaning 空白驗證）剝除 U+001C–U+001F（`isspace()` 為真），
    /// Swift `whitespacesAndNewlines` 不含這四個 scalar。若客端不一併剝除，僅含分隔符的翻譯會
    /// 通過本地驗證，PATCH 得 422 並進入重試迴圈（#2548）。
    @Test func informationSeparatorsCountAsBlankLikeBackendStrip() {
        for blank in ["\u{1C}", "\u{1D}\u{1E}", " \u{1F} \n", "\u{1F}\u{1C}"] {
            let entry = makeSyncedEntry()
            var saveCalled = false

            #expect(throws: WordEditSheet.EditValidationError.translationLength) {
                try WordEditSheet.commitEdit(
                    entry: entry,
                    translation: blank,
                    explanation: "新筆記",
                    save: { saveCalled = true }
                )
            }

            #expect(!saveCalled)
            #expect(entry.translation == "短暫的")
            #expect(entry.syncAction == .add)
            #expect(entry.syncState == .synced)
        }
    }

    @Test func informationSeparatorsAreTrimmedFromSavedValueEdges() throws {
        let entry = makeSyncedEntry()

        try WordEditSheet.commitEdit(
            entry: entry,
            translation: "\u{1C}新翻譯\u{1F}",
            explanation: "\u{1D} \u{1E}",
            save: {}
        )

        #expect(entry.translation == "新翻譯")
        #expect(entry.explanation == nil)
    }
}
#endif
