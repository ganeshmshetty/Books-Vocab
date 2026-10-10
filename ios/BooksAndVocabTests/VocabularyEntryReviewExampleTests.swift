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

    @Test func wordInsideContextWithoutStandaloneOccurrenceFallsBackToStem() {
        // "I" appears only inside "It", so no whole-word match exists and the
        // stem fallback is skipped (word length < 4); the context is returned unchanged.
        #expect(Self.fallbackExample(word: "I", context: "It is here.") == "It is here.")
    }
}
