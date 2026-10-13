//
//  CardMarkdownParserTests.swift
//  Books & Vocab Tests
//
//  Characterization tests for two zero-test pure-logic types in the Vocabulary
//  card rendering pipeline:
//
//    1. `CardMarkdownInlineParser` (parseInlines / parseParagraph /
//       normalizeLeadingMarker) — the inline markdown tokenizer that turns raw
//       card strings into `[CardDocumentInline]`.
//    2. `CardDocumentBuilder` (build / buildMeaningParagraphs) — assembles the
//       ordered `[CardDocumentBlock]` (hero / example / divider / meaning /
//       collocations / source) for a card.
//
//  All expected values were derived by reading the implementations line-by-line
//  (NOT from any spec) — these pin the ordered card-document contract,
//  including the regression that a translation remains visible when
//  explanation is empty.
//
//  Note: `CardDocumentInline` and `CardDocumentBlock` are NOT Equatable, so the
//  helpers below pattern-match to extract values / tags rather than `==`.
//  In particular `CardDocumentBlock.divider` has a UUID-randomized `id`, so we
//  tag blocks by case (not by `id`) to keep assertions deterministic.
//

import Foundation
import Testing
@testable import BooksAndVocab

@Suite struct CardMarkdownParserTests {

    // MARK: - Inline extraction helpers

    /// Maps an inline to a "<case>:<value>" tag for stable, readable assertions.
    private func tag(_ inline: CardDocumentInline) -> String {
        switch inline {
        case .text(let v): return "text:\(v)"
        case .mark(let v): return "mark:\(v)"
        case .code(let v): return "code:\(v)"
        case .emphasis(let v): return "em:\(v)"
        }
    }

    private func tags(_ inlines: [CardDocumentInline]) -> [String] {
        inlines.map(tag)
    }

    /// Maps a block to its case name (ignores associated values & random ids).
    private func blockTag(_ block: CardDocumentBlock) -> String {
        switch block {
        case .hero: return "hero"
        case .example: return "example"
        case .divider: return "divider"
        case .meaning: return "meaning"
        case .collocations: return "collocations"
        case .source: return "source"
        }
    }

    private func blockTags(_ doc: CardDocument) -> [String] {
        doc.blocks.map(blockTag)
    }

    private func sourceDocumentBlock(_ doc: CardDocument) -> CardDocumentSource? {
        for block in doc.blocks {
            if case .source(let source) = block {
                return source
            }
        }
        return nil
    }

    private func meaningTitle(_ doc: CardDocument) -> String? {
        for block in doc.blocks {
            if case .meaning(let meaning) = block {
                return meaning.title
            }
        }
        return nil
    }

    // MARK: - parseInlines: plain text & each delimiter

    @Test(arguments: [
        ("hello", ["text:hello"]),                                          // No delimiter: every char buffers, flushed once at EOF (lines 69-73).
        ("==hi==", ["mark:hi"]),                                            // "==hi==": hasPrefix "==" + dropFirst(2)="hi==" finds closing "=="; contentStart = +2, value = raw[2..<closing] = "hi" → .mark (lines 27-35).
        ("**bold**", ["mark:bold"]),                                        // "**bold**": same branch as "==", also produces .mark (lines 38-46).
        ("use `code` now", ["text:use ", "code:code", "text: now"]),        // backticks → .code, surrounding text flushed around it (lines 49-57).
        ("a _b_ c", ["text:a ", "em:b", "text: c"]),                        // single underscores → .emphasis (lines 59-67).
        ("==hi", ["text:==hi"]),                                            // Unclosed "==hi": dropFirst(2)="hi" has no closing "==", so the "==" branch is skipped; the '=' chars fall through to `buffer.append` (line 69) and the whole string flushes as one text run at EOF.
        ("a `b", ["text:a `b"]),                                            // Unclosed backtick: firstIndex(of "`") after the first finds nothing, so the '`' branch is skipped and the backtick itself buffers as text.
    ])
    func parseInlines(input: String, expected: [String]) async throws {
        #expect(tags(CardMarkdownInlineParser.parseInlines(input)) == expected)
    }

    // Underscore emphasis follows the CommonMark intraword rule: an opener must sit at a
    // boundary (start / whitespace / punctuation) and a closer must be followed by one;
    // otherwise the underscores stay literal (snake_case identifiers, etc.).
    @Test(arguments: [
        ("snake_case vs my_var", ["text:snake_case vs my_var"]),
        ("_emph_", ["em:emph"]),
        ("a _emph_ b", ["text:a ", "em:emph", "text: b"]),
        ("foo_bar_", ["text:foo_bar_"]),
        ("_foo_bar", ["text:_foo_bar"]),
        ("_foo_bar_", ["em:foo_bar"]),
        ("(_x_)", ["text:(", "em:x", "text:)"]),
        ("_ x_", ["text:_ x_"]),
    ])
    func parseInlines_underscoreIntraword(input: String, expected: [String]) async throws {
        #expect(tags(CardMarkdownInlineParser.parseInlines(input)) == expected)
    }

    // "====": dropFirst(2)="==" finds closing "==" immediately; value = raw[2..<2]
    // = "" which is `.isEmpty`, so nothing is appended and index jumps to EOF.
    // "``": value between the two backticks is "" → dropped.
    // "": while loop never runs, buffer empty → [].
    @Test(arguments: ["====", "``", ""])
    func parseInlines_yieldsNoInlines(input: String) async throws {
        #expect(CardMarkdownInlineParser.parseInlines(input).isEmpty)
    }

    // MARK: - normalizeLeadingMarker (via parseParagraph)

    @Test(arguments: [
        ("==名詞==,數量", ["text:名詞", "text:,數量"]),                       // "==名詞==,數量" → [.mark("名詞"), .text(",數量")]. Leading marker "名詞" is in demotedLeadingMarkers AND the next text trimmed starts with "," → demote to .text (lines 107-113). Final: [.text("名詞"), .text(",數量")].
        ("==動詞==，移動", ["text:動詞", "text:，移動"]),                       // Fullwidth comma "，" also triggers demotion (line 113).
        ("==noun==: a thing", ["text:noun", "text:: a thing"]),            // Colon (halfwidth or fullwidth) also triggers demotion (line 113).
        ("==verb== to run", ["mark:verb", "text: to run"]),                // "==verb== to run" → [.mark("verb"), .text(" to run")]. "verb" is in the set but the following text trimmed = "to run" does NOT start with comma/colon, so shouldDemoteLeadingMarker returns false → marker stays .mark (line 113 false branch). NOTE: the leading space is trimmed only for the prefix test; the stored text run keeps its leading space.
        ("==名詞==", ["text:名詞"]),                                         // "==名詞==" → [.mark("名詞")] with nothing following. following.first is nil → shouldDemoteLeadingMarker returns true (line 109) → demote to .text.
        ("==Apple==,fruit", ["mark:Apple", "text:,fruit"]),                // "==Apple==" → [.mark("Apple")]. "apple" (lowercased) is NOT in the set → no demotion regardless of what follows (line 107 guard fails).
        ("==NOUN==,thing", ["text:NOUN", "text:,thing"]),                  // Case-insensitivity: "NOUN" lowercases to "noun" which IS in the set, and the comma-prefixed follower triggers demotion (lines 106-113).
        ("==n.==,a noun", ["text:n.", "text:,a noun"]),                    // Abbreviation form "n." is in the set; comma follower → demote.
        ("x ==名詞==,y", ["text:x ", "mark:名詞", "text:,y"]),               // Leading non-mark text means firstContentIndex is the .text run (which is not a .mark), so the `case .mark` guard at line 91 fails → no demotion, even if a pos marker appears later (normalize only inspects the FIRST content inline).
        ("  ==名詞==,z", ["text:  ", "text:名詞", "text:,z"]),               // A leading whitespace-only text run is skipped by firstContentIndex (line 83 trims and treats empty as non-content), so the first *content* inline is the mark, which then demotes. The leading-space text run is preserved as-is. parseInlines flushes "  " as text before the mark → [.text("  "), .mark("名詞"), .text(",z")]; firstContentIndex skips index 0 → index 1 (mark) → following [.text(",z")] starts with "," → demote index 1.
    ])
    func normalizeLeadingMarker(input: String, expected: [String]) async throws {
        #expect(tags(CardMarkdownInlineParser.parseParagraph(input).inlines) == expected)
    }

    // MARK: - CardDocumentBuilder.build

    private func makeDoc(
        translation: String = "",
        examples: [String] = [],
        sourceContext: String = "",
        bookTitle: String = "book",
        chapterTitle: String? = nil,
        explanation: String? = nil,
        collocations: [String] = [],
        showsSourceContext: Bool = false
    ) -> CardDocument {
        CardDocumentBuilder.build(
            word: "word",
            translation: translation,
            partOfSpeech: nil,
            difficultyTier: nil,
            reviewModeTitle: "mode",
            examples: examples,
            sourceContext: sourceContext,
            bookTitle: bookTitle,
            chapterTitle: chapterTitle,
            explanation: explanation,
            collocations: collocations,
            showsSourceContext: showsSourceContext
        )
    }

    // Minimal card: empty examples, nil explanation, no collocations, no source.
    // Only the always-present hero block survives (lines 18-27); examples.first is
    // nil (skip 29-31), meaningParagraphs is [] (skip 37-47), collocations empty
    // (skip 49-52), showsSourceContext false (skip 54-68).
    @Test func build_minimal_yieldsOnlyHero() async throws {
        #expect(blockTags(makeDoc()) == ["hero"])
    }

    // Non-empty explanation → meaning block gets a preceding divider (lines 37-47).
    @Test func build_withExplanation_addsDividerThenMeaning() async throws {
        let doc = makeDoc(explanation: "a meaning")
        #expect(blockTags(doc) == ["hero", "divider", "meaning"])
    }

    // Empty explanation still preserves a non-empty translation in the meaning
    // title, so Word Detail and share text do not lose the card's translation.
    @Test func build_emptyExplanation_preservesTranslation() async throws {
        let doc = makeDoc(translation: "非空翻譯", explanation: "")
        #expect(blockTags(doc) == ["hero", "divider", "meaning"])
        #expect(meaningTitle(doc) == "非空翻譯")
    }

    // Whitespace-only explanation is still allowed to show a non-empty translation.
    @Test func build_whitespaceExplanation_yieldsNoMeaning() async throws {
        let doc = makeDoc(translation: "", explanation: "   \n  ")
        #expect(blockTags(doc) == ["hero"])
    }

    // "a\n\nb" → split on "\n\n" into ["a","b"], both non-empty → 2 paragraphs
    // (buildMeaningParagraphs lines 83-89).
    @Test func build_explanationWithBlankLine_yieldsTwoParagraphs() async throws {
        let doc = makeDoc(explanation: "a\n\nb")
        let paras = doc.meaningParagraphs()
        #expect(paras.count == 2)
        #expect(paras[0].plainText == "a")
        #expect(paras[1].plainText == "b")
    }

    // Empty segments between blank lines are filtered (line 87 filter). "a\n\n\n\nb"
    // → components on "\n\n" gives ["a", "", "b"]; the "" is dropped → 2 paragraphs.
    @Test func build_explanationWithExtraBlankLines_filtersEmptySegments() async throws {
        let doc = makeDoc(explanation: "a\n\n\n\nb")
        #expect(doc.meaningParagraphs().count == 2)
    }

    // CRLF normalized to LF before splitting (line 83), so "a\r\n\r\nb" → 2 paras.
    @Test func build_explanationWithCRLF_normalizesAndSplits() async throws {
        let doc = makeDoc(explanation: "a\r\n\r\nb")
        #expect(doc.meaningParagraphs().count == 2)
    }

    // First trimmed example non-empty → example block added right after hero,
    // BEFORE any divider/meaning (lines 29-31). Order: hero, example.
    @Test func build_withExample_addsExampleAfterHero() async throws {
        let doc = makeDoc(examples: ["She ran."])
        #expect(blockTags(doc) == ["hero", "example"])
    }

    // Whitespace-only first example is trimmed to "" → skipped (line 29 guard).
    @Test func build_whitespaceExample_isSkipped() async throws {
        let doc = makeDoc(examples: ["   "])
        #expect(blockTags(doc) == ["hero"])
    }

    // collocations non-empty → divider + collocations block appended (lines 49-52).
    @Test func build_withCollocations_addsDividerThenCollocations() async throws {
        let doc = makeDoc(collocations: ["take off", "take over"])
        #expect(blockTags(doc) == ["hero", "divider", "collocations"])
    }

    // showsSourceContext true + non-empty context → divider + source (lines 54-68).
    @Test func build_withSourceContext_addsDividerThenSource() async throws {
        let doc = makeDoc(sourceContext: "in the book", showsSourceContext: true)
        #expect(blockTags(doc) == ["hero", "divider", "source"])
    }

    // showsSourceContext true but context trims to empty → NO source block
    // (lines 55-56 inner guard).
    @Test func build_showsSourceButEmptyContext_omitsSource() async throws {
        let doc = makeDoc(sourceContext: "   ", showsSourceContext: true)
        #expect(blockTags(doc) == ["hero"])
    }

    // Non-empty context but showsSourceContext false → source suppressed (line 54).
    @Test func build_sourceContextButFlagOff_omitsSource() async throws {
        let doc = makeDoc(sourceContext: "in the book", showsSourceContext: false)
        #expect(blockTags(doc) == ["hero"])
    }

    @Test func build_withSourceContext_preservesContextBookAndChapter() throws {
        let source = try #require(
            sourceDocumentBlock(
                makeDoc(
                    sourceContext: "  A **marked** context.  ",
                    bookTitle: "Book title",
                    chapterTitle: "Chapter title",
                    showsSourceContext: true
                )
            )
        )
        #expect(source.context.rawMarkdown == "A **marked** context.")
        #expect(source.context.plainText == "A marked context.")
        #expect(source.bookTitle == "Book title")
        #expect(source.chapterTitle == "Chapter title")
    }

    @Test func sourceCopyText_includesPlainContextBeforeBookAndChapter() throws {
        let source = try #require(
            sourceDocumentBlock(
                makeDoc(
                    sourceContext: "A **marked** context.",
                    bookTitle: "Book title",
                    chapterTitle: "Chapter title",
                    showsSourceContext: true
                )
            )
        )

        #expect(
            CardDocumentSourceBlock.copyText(for: source)
                == "A marked context.\nBook title · Chapter title"
        )
    }


    // Full assembly ordering: example precedes meaning precedes collocations
    // precedes source, each non-hero/example section preceded by its own divider
    // (build lines 18-70). Pins the canonical block sequence.
    @Test func build_fullCard_blockOrderingIsStable() async throws {
        let doc = makeDoc(
            translation: "翻譯",
            examples: ["An example."],
            sourceContext: "from a book",
            explanation: "explanation text",
            collocations: ["a b"],
            showsSourceContext: true
        )
        #expect(
            blockTags(doc)
                == ["hero", "example", "divider", "meaning", "divider", "collocations", "divider", "source"]
        )
    }
}
