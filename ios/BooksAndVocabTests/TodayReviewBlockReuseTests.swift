import Testing
@testable import BooksAndVocab

/// Guards the view-reuse fix that removed the per-card `.id(cardIdentity)` from the
/// Today Review card subtree (skeleton is now reused in place; advancing only diffs
/// content). We cannot machine-verify pixel-level residue (the operator confirms that
/// on-device), but we CAN prove the *precondition* that makes positional `ForEach`
/// reuse dangerous is real — adjacent queue cards whose `reviewBackSubset()` block
/// `caseTag` sequences genuinely diverge — and that the composite ForEach key
/// (`"\(offset)-\(caseTag)"`) flips exactly where a slot's case changes. We also pin
/// the per-advance reset contract (revealStage → .front, content flows to the new card).
@MainActor
struct TodayReviewBlockReuseTests {

    /// Card A: context (→ example) + explanation (→ meaning) + collocations.
    /// reviewBackSubset() ⇒ [example, meaning, collocations] (builder emits no dividers).
    private func makeRichEntry() -> VocabularyEntry {
        let entry = VocabularyEntry(
            word: "ephemeral",
            translation: "短暫的",
            context: "The ephemeral beauty of cherry blossoms.",
            explanation: "Lasting for a very short time.",
            bookTitle: "Sample"
        )
        entry.collocations = ["ephemeral nature", "ephemeral moment"]
        entry.markSynced()
        return entry
    }

    /// Card B: translation only; no context / explanation / collocations.
    /// Full doc ⇒ [hero, meaning]; reviewBackSubset() drops the hero
    /// but retains the translation-only meaning block ⇒ [meaning].
    private func makeMinimalEntry() -> VocabularyEntry {
        let entry = VocabularyEntry(
            word: "void",
            translation: "空",
            context: "",
            bookTitle: "Sample"
        )
        entry.markSynced()
        return entry
    }

    private func caseTags(_ document: CardDocument) -> [String] {
        document.blocks.map(\.caseTag)
    }

    private func compositeKeys(_ document: CardDocument) -> [String] {
        document.blocks.enumerated().map { "\($0.offset)-\($0.element.caseTag)" }
    }

    /// (a) Adjacent cards' back-document structures must actually diverge — this is the
    ///     precondition under which positional reuse would strand the previous card's
    ///     measured height / CoreText layout. If this ever stops diverging the residue
    ///     hazard is moot, but so is the value of the guard, so we assert it explicitly.
    @Test func adjacentCardsHaveDivergentBackBlockStructure() throws {
        let rich = makeRichEntry()
        let minimal = makeMinimalEntry()
        let entries = [rich, minimal]

        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: nil)

        let current = try #require(state.currentCardForTesting)
        let next = try #require(state.nextCardForTesting)

        let currentTags = caseTags(current.backDocument)
        let nextTags = caseTags(next.backDocument)

        // Card A is structurally rich, Card B is translation-only ⇒ sequences differ.
        #expect(currentTags == ["example", "meaning", "collocations"])
        #expect(nextTags == ["meaning"])
        #expect(currentTags != nextTags)
    }

    /// (b) Per-advance reset contract: after goNext() the reveal collapses to .front and
    ///     the current card's content is the new card (value-flow swapped the content).
    @Test func advancingResetsRevealAndSwapsContent() throws {
        let rich = makeRichEntry()
        let minimal = makeMinimalEntry()
        let entries = [rich, minimal]

        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: nil)

        let firstWord = try #require(state.currentCardForTesting?.card.word)
        #expect(firstWord == "ephemeral")

        // Reveal the back, then advance — the new card must come back at .front.
        state.advanceReveal()
        #expect(state.revealStage != .front)

        state.goNext()

        #expect(state.revealStage == .front)
        let secondWord = try #require(state.currentCardForTesting?.card.word)
        #expect(secondWord == "void")
        #expect(secondWord != firstWord)
    }

    /// (c) Composite-key diff semantics: the key changes on exactly the offsets where the
    ///     caseTag changes — proving the new ForEach key forces delete-old + insert-new
    ///     (no in-place case morph) at every divergent slot.
    @Test func compositeKeyChangesWhereCaseTagChanges() throws {
        let rich = makeRichEntry()
        let minimal = makeMinimalEntry()
        let entries = [rich, minimal]

        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: nil)

        let richDoc = try #require(state.currentCardForTesting).backDocument
        let minimalDoc = try #require(state.nextCardForTesting).backDocument

        let richKeys = compositeKeys(richDoc)
        let minimalKeys = compositeKeys(minimalDoc)

        // offset prefix prevents same-type-different-position collisions.
        #expect(richKeys == ["0-example", "1-meaning", "2-collocations"])
        #expect(minimalKeys == ["0-meaning"])

        // At every offset present in the longer doc, if the caseTag differs (here every
        // offset, since minimal is empty) the composite key differs ⇒ delete + insert.
        let richTags = caseTags(richDoc)
        let minimalTags = caseTags(minimalDoc)
        for offset in richTags.indices {
            let richKey = "\(offset)-\(richTags[offset])"
            let minimalTag = offset < minimalTags.count ? minimalTags[offset] : nil
            if minimalTag != richTags[offset] {
                let minimalKey = minimalTag.map { "\(offset)-\($0)" }
                #expect(minimalKey != richKey)
            }
        }

        // divider caseTag is the bare constant (no UUID) so two dividers at the same
        // offset would produce a stable key across rebuilds — assert that invariant.
        #expect(CardDocumentBlock.divider.caseTag == "divider")
        #expect(!CardDocumentBlock.divider.caseTag.contains("-"))
    }
}
