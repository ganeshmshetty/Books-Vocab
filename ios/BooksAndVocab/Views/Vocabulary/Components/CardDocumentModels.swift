import Foundation

struct CardDocument {
    let blocks: [CardDocumentBlock]
}

enum CardDocumentBlock: Identifiable {
    case hero(CardDocumentHero)
    case example(CardDocumentParagraph)
    case divider
    case meaning(CardDocumentMeaning)
    case collocations([String])
    case source(CardDocumentSource)

    var id: String {
        switch self {
        case .hero:
            return "hero"
        case .example:
            return "example"
        case .divider:
            return "divider-\(UUID().uuidString)"
        case .meaning:
            return "meaning"
        case .collocations:
            return "collocations"
        case .source:
            return "source"
        }
    }

    /// Position-independent case discriminator for composing a stable ForEach key
    /// (`"\(offset)-\(caseTag)"`). Distinct from `id`: `.divider` returns the bare
    /// constant `"divider"` (no UUID) so the composite key stays stable across
    /// frames for a divider at a fixed slot, yet still flips when that slot's case
    /// changes. Used only as a reuse-diff key — `id` / plainTextExport / reviewBackSubset
    /// are untouched.
    var caseTag: String {
        switch self {
        case .hero: return "hero"
        case .example: return "example"
        case .divider: return "divider"
        case .meaning: return "meaning"
        case .collocations: return "collocations"
        case .source: return "source"
        }
    }
}

struct CardDocumentHero {
    let word: String
    let partOfSpeech: String?
    let difficultyTier: String?
    let reviewModeTitle: String
}

struct CardDocumentMeaning {
    let title: String
    let paragraphs: [CardDocumentParagraph]
}

struct CardDocumentSource {
    let context: CardDocumentParagraph
    let bookTitle: String
    let chapterTitle: String?
}

struct CardDocumentParagraph: Identifiable {
    let id = UUID()
    let inlines: [CardDocumentInline]

    var rawMarkdown: String {
        inlines.map { inline in
            switch inline {
            case .text(let v): return v
            case .mark(let v): return "**\(v)**"
            case .code(let v): return "`\(v)`"
            case .emphasis(let v): return v
            }
        }.joined()
    }

    var plainText: String {
        inlines.map { inline in
            switch inline {
            case .text(let v), .mark(let v), .code(let v), .emphasis(let v): return v
            }
        }.joined()
    }
}

// MARK: - Review Helpers

extension CardDocument {
    /// 從完整文件中擷取複習用背面內容（meaning + collocations + 最多 1 例句，排除 hero/source）
    func reviewBackSubset() -> CardDocument {
        var result: [CardDocumentBlock] = []
        var exampleCount = 0
        for block in blocks {
            switch block {
            case .hero, .divider, .source:
                continue
            case .meaning(let meaning):
                // Review 背面已自行渲染 translation，meaning 只保留 explanation paragraphs
                let stripped = CardDocumentMeaning(title: "", paragraphs: meaning.paragraphs)
                result.append(.meaning(stripped))
            case .collocations:
                result.append(block)
            case .example:
                guard exampleCount < 1 else { continue }
                result.append(block)
                exampleCount += 1
            }
        }
        return CardDocument(blocks: result)
    }

    /// 擷取第一個 meaning block 的段落
    func meaningParagraphs() -> [CardDocumentParagraph] {
        for block in blocks {
            if case .meaning(let meaning) = block {
                return meaning.paragraphs
            }
        }
        return []
    }

    /// 將整張卡片組成可分享的純文字（單字 / 例句 / 翻譯 / 搭配 / 來源）
    func plainTextExport() -> String {
        var lines: [String] = []
        for block in blocks {
            switch block {
            case .hero(let hero):
                var head = hero.word
                if let pos = hero.partOfSpeech, !pos.isEmpty {
                    head += " (\(pos))"
                }
                lines.append(head)
            case .example(let paragraph):
                let text = paragraph.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
            case .meaning(let meaning):
                if !meaning.title.isEmpty {
                    lines.append(meaning.title)
                }
                for paragraph in meaning.paragraphs {
                    let text = paragraph.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { lines.append(text) }
                }
            case .collocations(let items):
                let joined = items.joined(separator: ", ")
                if !joined.isEmpty { lines.append(joined) }
            case .source(let source):
                var parts = [source.bookTitle]
                if let chapter = source.chapterTitle { parts.append(chapter) }
                lines.append("— " + parts.joined(separator: " · "))
            case .divider:
                continue
            }
        }
        return lines.joined(separator: "\n\n")
    }
}

enum CardDocumentInline: Identifiable {
    case text(String)
    case mark(String)
    case code(String)
    case emphasis(String)

    var id: String {
        switch self {
        case .text(let value):
            return "text-\(value)"
        case .mark(let value):
            return "mark-\(value)"
        case .code(let value):
            return "code-\(value)"
        case .emphasis(let value):
            return "em-\(value)"
        }
    }
}

