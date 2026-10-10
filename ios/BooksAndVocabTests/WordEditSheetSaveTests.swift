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
}
#endif
