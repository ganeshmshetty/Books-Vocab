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

    /// #2550：伺服器持有 note 的卡被清空，必須留下「明確清空」（PATCH 送 ""），不是與「未變更」同形的 nil。
    @Test func clearingServerHeldNoteMarksExplicitClear() throws {
        let entry = makeSyncedEntry()
        entry.kgCardId = "card-1"

        try WordEditSheet.commitEdit(entry: entry, translation: "短暫的", explanation: "  ", save: {})

        #expect(entry.explanation == nil)
        #expect(entry.explanationUpdateValue == "")
    }

    /// #2550：本地從未持有 note（伺服器狀態未知，可能尚未 pull）時清空仍是「未變更」，不得升級為明確清空。
    @Test func clearingNeverPulledNoteStaysUnknown() throws {
        let entry = makeSyncedEntry()
        entry.kgCardId = "card-1"
        entry.explanation = nil

        try WordEditSheet.commitEdit(entry: entry, translation: "短暫的", explanation: "", save: {})

        #expect(entry.explanationUpdateValue == nil)
    }

    /// #2550：明確清空後再設定新 note，清空狀態必須撤銷，改送新值。
    @Test func settingNoteAfterClearDropsExplicitClear() throws {
        let entry = makeSyncedEntry()
        entry.kgCardId = "card-1"
        try WordEditSheet.commitEdit(entry: entry, translation: "短暫的", explanation: "", save: {})

        try WordEditSheet.commitEdit(entry: entry, translation: "短暫的", explanation: "新筆記", save: {})

        #expect(entry.explanationClearPending == false)
        #expect(entry.explanationUpdateValue == "新筆記")
    }

    /// #3207：後端拒收（終態）的 edit，使用者再次編輯必須重新排入 pending 並清除拒收原因，否則永遠不會再送。
    @Test func editingRejectedEditRequeuesIt() throws {
        let entry = makeSyncedEntry()
        entry.kgCardId = "card-1"
        entry.syncAction = .edit
        entry.syncState = .failed
        entry.rejectedReason = "HTTP 422"

        try WordEditSheet.commitEdit(entry: entry, translation: "新翻譯", explanation: "", save: {})

        #expect(entry.syncAction == .edit)
        #expect(entry.syncState == .pending)
        #expect(entry.rejectedReason == nil)
        #expect(entry.shouldUploadOnNextSync)
    }

    /// #3248：上傳進行中的列不得被改寫；否則過期回應會把較新的內容標成 synced，新內容永遠不上傳。
    @Test func commitEditWhileUploadInFlightIsRefusedBeforeMutation() {
        let entry = makeSyncedEntry()
        entry.kgCardId = "card-1"
        entry.syncAction = .edit
        entry.syncState = .pending
        entry.isUploadInFlight = true
        var saveCalled = false

        #expect(throws: WordEditSheet.EditValidationError.uploadInFlight) {
            try WordEditSheet.commitEdit(
                entry: entry,
                translation: "新翻譯",
                explanation: "新筆記",
                save: { saveCalled = true }
            )
        }

        #expect(!saveCalled)
        #expect(entry.translation == "短暫的")
        #expect(entry.explanation == "原始筆記")
        #expect(entry.syncAction == .edit)
        #expect(entry.syncState == .pending)
    }

    @Test func failedSaveRestoresRejectedEditState() {
        let entry = makeSyncedEntry()
        entry.kgCardId = "card-1"
        entry.syncAction = .edit
        entry.syncState = .failed
        entry.rejectedReason = "HTTP 422"

        #expect(throws: SaveFailure.self) {
            try WordEditSheet.commitEdit(
                entry: entry,
                translation: "新翻譯",
                explanation: "新筆記",
                save: { throw SaveFailure() }
            )
        }

        #expect(entry.syncState == .failed)
        #expect(entry.rejectedReason == "HTTP 422")
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
