import Testing
@testable import BooksAndVocab

/// #3397: `reviewBackSubset()` used to re-insert `.divider` blocks from a `pendingDivider`
/// flag. Nothing emits `.divider` any more (the builder emits no dividers), so that
/// branch was dead; these tests pin that the review subset never contains a divider and
/// still keeps meaning / collocations in their original order.
struct CardDocumentReviewBackSubsetTests {

    private func paragraph(_ text: String) -> CardDocumentParagraph {
        CardDocumentParagraph(inlines: [.text(text)])
    }

    @Test func reviewBackSubsetDropsDividerBetweenMeaningAndCollocations() {
        let document = CardDocument(blocks: [
            .meaning(CardDocumentMeaning(title: "", paragraphs: [paragraph("explanation")])),
            .divider,
            .collocations(["ephemeral nature"])
        ])

        let subset = document.reviewBackSubset()

        #expect(subset.blocks.map(\.caseTag) == ["meaning", "collocations"])
        #expect(!subset.blocks.contains { block in
            if case .divider = block { return true }
            return false
        })
    }

    @Test func reviewBackSubsetKeepsMeaningAndCollocationsInOrder() {
        let document = CardDocument(blocks: [
            .hero(CardDocumentHero(word: "ephemeral", partOfSpeech: nil, difficultyTier: nil, reviewModeTitle: "")),
            .meaning(CardDocumentMeaning(title: "t", paragraphs: [paragraph("explanation")])),
            .divider,
            .collocations(["a", "b"]),
            .source(CardDocumentSource(context: paragraph("ctx"), bookTitle: "Book", chapterTitle: nil))
        ])

        let subset = document.reviewBackSubset()

        #expect(subset.blocks.map(\.caseTag) == ["meaning", "collocations"])
        if case .meaning(let meaning) = subset.blocks[0] {
            #expect(meaning.title == "")
        } else {
            Issue.record("expected meaning block first")
        }
    }
}
