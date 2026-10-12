import Testing
@testable import BooksAndVocab

@MainActor
struct TodayReviewCollocationStateTests {

    @Test func sync_readsCurrentEntryExplanations() {
        let entry = makeEntry()
        entry.collocationExplanations = ["take shape": "become clear gradually"]

        var state = TodayReviewCollocationState()
        state.sync(from: entry)

        #expect(state.explanations == ["take shape": "become clear gradually"])
    }

    @Test func update_setsAndRemovesExplanationOnEntryAndLocalState() {
        let entry = makeEntry()
        var state = TodayReviewCollocationState()
        state.sync(from: entry)

        state.update("used for soft refusal", for: "not exactly", entry: entry)
        #expect(state.explanations["not exactly"] == "used for soft refusal")
        #expect(entry.collocationExplanations["not exactly"] == "used for soft refusal")

        state.update(nil, for: "not exactly", entry: entry)
        #expect(state.explanations["not exactly"] == nil)
        #expect(entry.collocationExplanations["not exactly"] == nil)
    }

    @Test func update_withoutEntryClearsLocalState() {
        var state = TodayReviewCollocationState()
        let entry = makeEntry()
        entry.collocationExplanations = ["turn out": "be revealed eventually"]
        state.sync(from: entry)

        state.update("ignored", for: "turn out", entry: nil)

        #expect(state.explanations.isEmpty)
    }

    @Test func commit_failedSaveRollsBackEntryAndLocalState() {
        let entry = makeEntry()
        entry.collocationExplanations = ["take shape": "become clear gradually"]
        var state = TodayReviewCollocationState()
        state.sync(from: entry)

        let saved = TodayReviewCollocationCommit.commit(
            "rewritten", for: "take shape", entry: entry, state: &state, save: { false }
        )

        #expect(saved == false)
        #expect(entry.collocationExplanations == ["take shape": "become clear gradually"])
        #expect(state.explanations == ["take shape": "become clear gradually"])
    }

    @Test func commit_successfulSaveKeepsUpdate() {
        let entry = makeEntry()
        var state = TodayReviewCollocationState()
        state.sync(from: entry)

        let saved = TodayReviewCollocationCommit.commit(
            "fresh", for: "take shape", entry: entry, state: &state, save: { true }
        )

        #expect(saved)
        #expect(entry.collocationExplanations["take shape"] == "fresh")
        #expect(state.explanations["take shape"] == "fresh")
    }

    private func makeEntry() -> VocabularyEntry {
        VocabularyEntry(
            word: "example",
            translation: "範例",
            context: "example context",
            bookTitle: "Book"
        )
    }
}
