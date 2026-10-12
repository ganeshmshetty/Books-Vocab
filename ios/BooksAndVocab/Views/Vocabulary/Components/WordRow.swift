import SwiftUI

struct WordRow: View {
    @ObserveInjection private var inject
    struct ViewData: Identifiable, Hashable {
        enum Tone: Hashable {
            case primary
            case secondary
            case tertiary
            case quaternary
            case destructive
            case reviewDue
        }

        let id: UUID
        let word: String
        let wordTone: Tone
        let isStrikethrough: Bool
        let partOfSpeech: String?
        let translation: String?
        let bookTitle: String?
        let chapterTitle: String?
        let difficultyTier: String?
        let reviewProgress: VocabReviewProgress?
        let leadingSystemImage: String?
        let leadingTone: Tone?
        let trailingLabel: String?
        let trailingTone: Tone?
        let statusText: String?
        let statusTone: Tone?
    }

    @Environment(\.appSkin) private var appSkin
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let viewData: ViewData

    private var usesCompactLayout: Bool {
        dynamicTypeSize < .accessibility1
    }

    private var accessibilityRowLabel: String {
        var parts: [String] = [viewData.word]
        if let pos = viewData.partOfSpeech { parts.append(pos) }
        if let translation = viewData.translation, !translation.isEmpty {
            parts.append(translation)
        }
        return parts.joined(separator: ", ")
    }

    private var accessibilityProgressDescription: String {
        guard let progress = viewData.reviewProgress else { return "" }
        var parts = [progress.statusLabel]
        if let ratio = progress.ratio {
            parts.append(L10n.format("vocab.reviewProgress.percent", Int64(min(ratio, 1.0) * 100)))
        }
        if let detail = progress.detailLabel {
            parts.append(detail)
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: appSkin.spacing.wordRowHorizontalGap) {
            VStack(alignment: .leading, spacing: appSkin.spacing.wordRowVerticalGap) {
                HStack(alignment: .firstTextBaseline, spacing: appSkin.spacing.wordRowBaselineGap) {
                    if let systemImage = viewData.leadingSystemImage {
                        Image(systemName: systemImage)
                            .font(appSkin.typography.iconSmall)
                            .foregroundStyle(resolveTone(viewData.leadingTone ?? .tertiary))
                    }

                    // Why: 單字若超長(`pneumonoultramicroscopic…`)在窄寬度
                    // 會把 partOfSpeech / trailingLabel 擠出版,truncate 是底線。
                    Text(viewData.word)
                        .font(appSkin.typography.rowWord)
                        .strikethrough(viewData.isStrikethrough, color: resolveTone(viewData.wordTone))
                        .foregroundStyle(resolveTone(viewData.wordTone))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let pos = viewData.partOfSpeech {
                        Text(pos)
                            .font(appSkin.typography.caption)
                            .foregroundStyle(appSkin.palette.tertiaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    if let trailingLabel = viewData.trailingLabel {
                        Spacer()
                        // monospacedDigit: `42d / 2d` 之類數字欄位避免比例字寬抖動。
                        Text(trailingLabel.localized)
                            .font(appSkin.typography.monoLabel)
                            .monospacedDigit()
                            .foregroundStyle(resolveTone(viewData.trailingTone ?? .tertiary))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                if let translation = viewData.translation, !translation.isEmpty {
                    Text(translation)
                        .font(appSkin.typography.body)
                        .foregroundStyle(appSkin.palette.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                } else if !viewData.isStrikethrough {
                    Label("待翻譯".localized, systemImage: "clock")
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.tertiaryText)
                        .lineLimit(1)
                }

                if let book = viewData.bookTitle, !book.isEmpty {
                    HStack(spacing: appSkin.spacing.metadataGap) {
                        Image(systemName: "book.closed")
                            .font(appSkin.typography.iconTiny)
                        Text(book)
                            .font(appSkin.typography.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let chapter = viewData.chapterTitle {
                            Text("· \(chapter)")
                                .font(appSkin.typography.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .foregroundStyle(appSkin.palette.tertiaryText)
                }

                if let statusText = viewData.statusText, !statusText.isEmpty {
                    Text(statusText.localized)
                        .font(appSkin.typography.caption)
                        .foregroundStyle(resolveTone(viewData.statusTone ?? .tertiary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            if usesCompactLayout, !viewData.isStrikethrough {
                if let reviewProgress = viewData.reviewProgress {
                    VocabReviewProgressBar(progress: reviewProgress)
                } else if let tier = viewData.difficultyTier {
                    VStack(alignment: .trailing, spacing: appSkin.spacing.wordRowVerticalGap) {
                        VocabTierLabel(tier: tier)
                    }
                }
            }
        }
        .padding(.vertical, appSkin.spacing.compactRowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityValue(accessibilityProgressDescription)
        .accessibilityHint(L10n.string("點兩下查看詳情"))
        .enableInjection()
    }

    private func resolveTone(_ tone: ViewData.Tone) -> Color {
        switch tone {
        case .primary:
            return appSkin.palette.primaryText
        case .secondary:
            return appSkin.palette.secondaryText
        case .tertiary:
            return appSkin.palette.tertiaryText
        case .quaternary:
            return appSkin.palette.quaternaryText
        case .destructive:
            return appSkin.palette.destructive
        case .reviewDue:
            return appSkin.palette.warning
        }
    }

}

#Preview("WordRow") {
    func make(
        word: String,
        tone: WordRow.ViewData.Tone = .primary,
        strike: Bool = false,
        pos: String? = "n.",
        translation: String? = "a placeholder gloss for preview",
        book: String? = "Sample Book",
        chapter: String? = "Chapter One",
        tier: String? = "B2",
        progress: VocabReviewProgress? = nil,
        leadingImage: String? = nil,
        trailing: String? = nil,
        trailingTone: WordRow.ViewData.Tone? = nil,
        status: String? = nil,
        statusTone: WordRow.ViewData.Tone? = nil
    ) -> WordRow.ViewData {
        WordRow.ViewData(
            id: UUID(),
            word: word,
            wordTone: tone,
            isStrikethrough: strike,
            partOfSpeech: pos,
            translation: translation,
            bookTitle: book,
            chapterTitle: chapter,
            difficultyTier: tier,
            reviewProgress: progress,
            leadingSystemImage: leadingImage,
            leadingTone: nil,
            trailingLabel: trailing,
            trailingTone: trailingTone,
            statusText: status,
            statusTone: statusTone
        )
    }

    let rows: [WordRow.ViewData] = [
        make(word: "serendipity"),
        make(
            word: "ephemeral",
            tone: .reviewDue,
            tier: nil,
            progress: VocabReviewProgress(statusLabel: "Due", detailLabel: "2 / 5", ratio: 0.4),
            leadingImage: "clock"
        ),
        make(
            word: "ubiquitous",
            tone: .secondary,
            translation: nil,
            tier: "C1",
            trailing: "42",
            trailingTone: .tertiary
        ),
        make(
            word: "obsolete",
            tone: .tertiary,
            strike: true,
            translation: "no longer in use",
            tier: nil
        )
    ]

    return AppThemeContainer {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                WordRow(viewData: row)
                    .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }
    .environmentObject(AppAppearanceStore.preview)
}
