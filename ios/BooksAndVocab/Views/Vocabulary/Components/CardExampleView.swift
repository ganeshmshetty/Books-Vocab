import SwiftUI

/// 書摘卡的來源行（書名 · 章節）。`make` 回傳 nil 表示不顯示來源：
/// 圖譜來源（`Knowledge Graph` fallback，`BackgroundSyncActor` 寫入）或書名為空。
struct CardExampleSource: Equatable {
    static let knowledgeGraphFallback = "Knowledge Graph"

    let bookTitle: String
    let chapterTitle: String?

    static func make(bookTitle: String, chapterTitle: String?) -> CardExampleSource? {
        let book = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !book.isEmpty, book != knowledgeGraphFallback else { return nil }
        let chapter = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CardExampleSource(
            bookTitle: book,
            chapterTitle: chapter?.isEmpty == false ? chapter : nil
        )
    }

    var displayText: String {
        [bookTitle, chapterTitle].compactMap { $0 }.joined(separator: " · ")
    }
}

/// 書摘卡（#3113）：一句例句的唯一呈現。Linked Card／Word Detail 與複習卡背面共用，
/// 只有一條渲染路徑（`CardRichTextRenderer`），同一份 markup 得到同一份 attributed output。
///
/// footer（來源 + 朗讀句子 + 複習）只在 `showsFooter` 為 true 時畫出。複習卡正面是 cloze，
/// 不畫 footer：朗讀句子會把被挖空的答案唸出來。
struct CardExampleView: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.speechService) private var speechService
    @Environment(\.toastCoordinator) private var toastCoordinator
    @State private var copyTrigger = false
    @State private var speakTrigger = false

    /// 原始 inline markup（`**target**`、反引號）。
    let markdown: String
    var targetWord: String? = nil
    var mode: CardRichTextMode = .highlight
    var truncateRadius: Int? = nil
    /// 來源行；nil 不顯示。
    var source: CardExampleSource? = nil
    /// false 時來源與朗讀／複製都不畫（複習卡正面）。
    var showsFooter: Bool = true

    private var style: CardRichTextStyle {
        CardRichTextStyle(
            font: appSkin.typography.cardExample,
            textColor: appSkin.palette.primaryText,
            highlightColor: appSkin.palette.highlightMark,
            italic: false,
            underlineHighlights: appSkin.highlight.showUnderline,
            useBackgroundMark: appSkin.highlight.showBackground,
            highlightWeight: appSkin.highlight.fontWeight,
            backgroundOpacity: appSkin.highlight.backgroundOpacity,
            underlineOpacity: appSkin.highlight.underlineOpacity
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockInnerGap) {
            HStack(alignment: .top, spacing: appSkin.spacing.inlineGap) {
                Text("\u{201C}")
                    .font(appSkin.typography.cardExample)
                    .foregroundStyle(appSkin.palette.highlightMark)
                    .accessibilityHidden(true)

                CardRichTextRenderer.text(
                    markdown,
                    style: style,
                    mode: mode,
                    truncateAroundMarkedWordRadius: truncateRadius,
                    targetWord: targetWord
                )
                .lineSpacing(appSkin.metrics.paragraphLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsFooter {
                footer
            }
        }
        // 上與左右 s4、下 s4：44pt 命中帶外擴約 15pt，留足 padding 才不蓋到下一個可點元件。
        .padding(.horizontal, AppSpacing.s4)
        .padding(.top, AppSpacing.s4)
        .padding(.bottom, AppSpacing.s4)
        .background(
            AppRoundedRect(roundness: AppRoundness.control)
                .fill(appSkin.palette.mutedFill)
        )
        .appFeedback(.selection, trigger: speakTrigger)
        .appFeedback(.success, trigger: copyTrigger)
        .enableInjection()
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: AppSpacing.s2) {
            if let source {
                Label {
                    Text(source.displayText)
                        .font(appSkin.typography.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: "book.closed")
                        .font(appSkin.typography.iconTiny)
                }
                .foregroundStyle(appSkin.palette.tertiaryText)
            }

            Spacer(minLength: 0)

            ReviewCardHitTargetButton(
                action: speakSentence,
                accessibilityIdentifier: "cardExample.speak",
                accessibilityLabel: L10n.string("vocab.card.example.speak")
            ) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(appSkin.typography.iconSmall)
                    .foregroundStyle(appSkin.palette.secondaryText)
            }

            ReviewCardHitTargetButton(
                action: copySentence,
                accessibilityIdentifier: "cardExample.copy",
                accessibilityLabel: L10n.string("複製")
            ) {
                Image(systemName: "doc.on.doc")
                    .font(appSkin.typography.iconSmall)
                    .foregroundStyle(appSkin.palette.secondaryText)
            }
        }
    }

    private func speakSentence() {
        speechService.speak(CardRichTextRenderer.plainText(markdown))
        speakTrigger.toggle()
    }

    private func copySentence() {
        PlatformClipboard.copy(CardRichTextRenderer.plainText(markdown))
        copyTrigger.toggle()
        toastCoordinator.success(L10n.string("已複製"))
    }
}
