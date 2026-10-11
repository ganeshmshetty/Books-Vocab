import Testing
@testable import BooksAndVocab

/// #2725 — the client-side fallback example must bold the target word only at
/// whole-word boundaries, mirroring the backend `_boundary_pattern`.
@MainActor
struct VocabularyEntryReviewExampleTests {
    private static func fallbackExample(word: String, context: String) -> String? {
        let entry = VocabularyEntry(word: word, translation: "t", context: context, bookTitle: "b")
        return entry.allReviewExamples.first
    }

    @Test func shortWordDoesNotBoldInsideLongerWord() {
        #expect(Self.fallbackExample(word: "art", context: "She started to love art.") == "She started to love **art**.")
    }

    @Test func singleLetterWordBoldsStandaloneOnly() {
        #expect(Self.fallbackExample(word: "I", context: "It is here, I think.") == "It is here, **I** think.")
    }

    @Test func wordInsideContextWithoutStandaloneOccurrenceReturnsContextUnchanged() {
        // "I" appears only inside "It", so no whole-word match exists. The stem path
        // is skipped because the word is shorter than 4 characters; the context is returned unchanged.
        #expect(Self.fallbackExample(word: "I", context: "It is here.") == "It is here.")
    }

    private static func fallbackExample(word: String, inflections: [String], context: String) -> String? {
        let entry = VocabularyEntry(word: word, translation: "t", context: context, bookTitle: "b")
        entry.inflections = inflections
        return entry.allReviewExamples.first
    }

    /// Mirrors backend `_build_example`: `[word, *alternatives]` are tried in order with boundaries,
    /// so an inflected form in the context is bolded when the base form does not occur.
    @Test func inflectedFormBoldsWhenBaseWordAbsent() {
        #expect(
            Self.fallbackExample(word: "run", inflections: ["runs", "ran", "running"], context: "He runs fast.")
                == "He **runs** fast."
        )
    }

    @Test func baseWordWinsOverInflectionWhenBothPresent() {
        #expect(
            Self.fallbackExample(word: "run", inflections: ["runs"], context: "They run and he runs.")
                == "They **run** and he runs."
        )
    }

    /// 未 trim 的 inflection（" runs "）不得把前後空白一併加粗。RED：舊碼輸出 "She** runs **daily."。
    @Test func inflectionWithSurroundingWhitespaceBoldsOnlyTheWord() {
        #expect(
            Self.fallbackExample(word: "run", inflections: [" runs "], context: "She runs daily.")
                == "She **runs** daily."
        )
    }

    @Test func inflectionDoesNotBoldInsideLongerWord() {
        #expect(
            Self.fallbackExample(word: "run", inflections: ["runs"], context: "The rerunning began.")
                == "The rerunning began."
        )
    }
}
