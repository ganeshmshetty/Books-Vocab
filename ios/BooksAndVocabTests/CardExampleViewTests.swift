import SwiftUI
import Testing
@testable import BooksAndVocab

/// 書摘卡（#3113）：Linked Card／Word Detail 與複習卡共用同一個例句渲染。
/// 同一份 markup 必須得到同一份 attributed output；與例句相同的來源不得在 Linked Card 重印。
@MainActor
@Suite("CardExampleView shared rendering")
struct CardExampleViewTests {
    private let style = CardRichTextStyle(
        font: .body,
        textColor: .primary,
        highlightColor: .yellow,
        italic: false
    )

    @Test func sameMarkupRendersIdenticallyOnLinkedCardAndReview() {
        let markup = "Here, **stately** and `code` stay."
        let review = CardRichTextRenderer.attributedString(markup, style: style)
        // Linked Card 走 CardDocument 的 paragraph；它的 rawMarkdown 必須回到同一份 markup。
        let linkedRaw = CardMarkdownInlineParser.parseParagraph(markup).rawMarkdown
        let linked = CardRichTextRenderer.attributedString(linkedRaw, style: style)

        #expect(String(review.characters) == String(linked.characters))
        #expect(highlightedRuns(review) == highlightedRuns(linked))
        // 反引號 code span 在兩個面都是高亮，不再一邊 monospace、一邊高亮。
        #expect(highlightedRuns(linked) == ["stately", "code"])
    }

    @Test func clozeReplacesTargetOnlyWhenModeIsCloze() {
        let markup = "He was **stately** indeed."
        let cloze = CardRichTextRenderer.attributedString(markup, style: style, mode: .cloze)
        let highlight = CardRichTextRenderer.attributedString(markup, style: style, mode: .highlight)

        #expect(String(cloze.characters) == "He was ______ indeed.")
        #expect(String(highlight.characters) == "He was stately indeed.")
    }

    @Test func plainTextStripsBoldMarksAndCodeTicks() {
        #expect(CardRichTextRenderer.plainText("a **stately** `code` b") == "a stately code b")
        #expect(CardRichTextRenderer.plainText("no marks") == "no marks")
    }

    @Test func addLinkExampleUsesSharedRendererWithNormalizedMarkup() {
        // Add Link 例句與 Linked Card 同一條路徑：先經 CardMarkdownInlineParser 正規化（`==` → `**`），
        // 再由 CardRichTextRenderer 畫；兩個面對同一句話得到同一組高亮。
        let markup = AddLinkCoordinator.exampleMarkup(for: "A ==concoction== and `code` here.")
        let rendered = CardRichTextRenderer.attributedString(markup, style: style)

        #expect(highlightedRuns(rendered) == ["concoction", "code"])
        #expect(CardRichTextRenderer.plainText(markup) == "A concoction and code here.")
    }

    @Test func addLinkExampleBoldIsNotLiteralAsterisks() {
        let markup = AddLinkCoordinator.exampleMarkup(for: "A **concoction** of herbs.")
        let rendered = CardRichTextRenderer.attributedString(markup, style: style)

        #expect(highlightedRuns(rendered) == ["concoction"])
        #expect(String(rendered.characters) == "A concoction of herbs.")
    }

    @Test func sourceLineHidesKnowledgeGraphFallbackAndEmptyBook() {
        #expect(CardExampleSource.make(bookTitle: "Knowledge Graph", chapterTitle: "Chapter 1") == nil)
        #expect(CardExampleSource.make(bookTitle: "   ", chapterTitle: nil) == nil)
    }

    @Test func sourceLineJoinsBookAndChapterAndOmitsBlankChapter() {
        #expect(CardExampleSource.make(bookTitle: "Warbreaker", chapterTitle: "Chapter Twelve")?.displayText
            == "Warbreaker · Chapter Twelve")
        #expect(CardExampleSource.make(bookTitle: "Warbreaker", chapterTitle: " ")?.displayText == "Warbreaker")
        #expect(CardExampleSource.make(bookTitle: "Warbreaker", chapterTitle: nil)?.displayText == "Warbreaker")
    }

    @Test func sameSentenceAsContextMovesSourceIntoFooterOnly() {
        // 例句與來源 context 相同：Linked Card 不再印第二次整句，書名／章節改由例句 footer 承載。
        let card = Self.presentation(
            context: "Here—close enough.",
            example: "Here—close enough.\n",
            bookTitle: "Warbreaker",
            chapterTitle: "Chapter Twelve"
        )
        #expect(card.document.blocks.contains { $0.caseTag == "source" } == false)
        #expect(card.exampleSource == CardExampleSource(bookTitle: "Warbreaker", chapterTitle: "Chapter Twelve"))
    }

    @Test func differentContextKeepsSeparateSourceBlockAndNoFooterSource() {
        let card = Self.presentation(
            context: "A different passage.",
            example: "Here—close enough.",
            bookTitle: "Warbreaker",
            chapterTitle: nil
        )
        #expect(card.document.blocks.contains { $0.caseTag == "source" })
        #expect(card.exampleSource == nil)
    }

    @Test func knowledgeGraphFallbackSourceIsHiddenEverywhere() {
        let card = Self.presentation(
            context: "Here—close enough.",
            example: "Here—close enough.",
            bookTitle: "Knowledge Graph",
            chapterTitle: nil
        )
        #expect(card.document.blocks.contains { $0.caseTag == "source" } == false)
        #expect(card.exampleSource == nil)
    }

    private static func presentation(
        context: String,
        example: String,
        bookTitle: String,
        chapterTitle: String?
    ) -> CardPresentation {
        let entry = VocabularyEntry(
            word: "stately",
            translation: "莊嚴的",
            context: context,
            bookTitle: bookTitle,
            chapterTitle: chapterTitle
        )
        entry.reviewExamples = [example]
        return CardPresentation(entry: entry, pendingLinks: [])
    }

    /// 只收集有 background（高亮）的片段文字，用來比對兩個面的標記是否一致。
    private func highlightedRuns(_ text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            text[run.range].backgroundColor == nil ? nil : String(text[run.range].characters)
        }
    }
}
