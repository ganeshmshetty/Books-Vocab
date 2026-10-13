import Foundation

enum CardDocumentBuilder {
    static func build(
        word: String,
        translation: String,
        partOfSpeech: String?,
        difficultyTier: String?,
        reviewModeTitle: String,
        examples: [String],
        sourceContext: String,
        bookTitle: String,
        chapterTitle: String?,
        explanation: String?,
        collocations: [String] = [],
        showsSourceContext: Bool
    ) -> CardDocument {
        var blocks: [CardDocumentBlock] = [
            .hero(
                CardDocumentHero(
                    word: word,
                    partOfSpeech: partOfSpeech,
                    difficultyTier: difficultyTier,
                    reviewModeTitle: reviewModeTitle
                )
            )
        ]

        if let example = examples.first?.trimmingCharacters(in: .whitespacesAndNewlines), !example.isEmpty {
            blocks.append(.example(CardMarkdownInlineParser.parseParagraph(example)))
        }

        let meaningParagraphs = buildMeaningParagraphs(
            translation: translation,
            explanation: explanation
        )
        let hasTranslation = !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasTranslation || !meaningParagraphs.isEmpty {
            blocks.append(
                .meaning(
                    CardDocumentMeaning(
                        title: translation,
                        paragraphs: meaningParagraphs
                    )
                )
            )
        }

        if !collocations.isEmpty {
            blocks.append(.collocations(collocations))
        }

        if showsSourceContext {
            let trimmedContext = sourceContext.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContext.isEmpty {
                blocks.append(
                    .source(
                        CardDocumentSource(
                            context: CardMarkdownInlineParser.parseParagraph(trimmedContext),
                            bookTitle: bookTitle,
                            chapterTitle: chapterTitle
                        )
                    )
                )
            }
        }

        return CardDocument(blocks: blocks)
    }

    private static func buildMeaningParagraphs(
        translation: String,
        explanation: String?
    ) -> [CardDocumentParagraph] {
        let trimmedExplanation = explanation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedExplanation.isEmpty else {
            // 沒有 explanation 時不 fallback 翻譯（title 已顯示翻譯，避免重複）
            return []
        }

        let normalized = trimmedExplanation.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return parts.map(CardMarkdownInlineParser.parseParagraph)
    }
}
