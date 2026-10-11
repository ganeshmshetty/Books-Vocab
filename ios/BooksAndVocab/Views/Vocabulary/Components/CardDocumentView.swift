import SwiftUI

enum CardDocumentCollocationState {
    static func hasExplanation(for item: String, in explanations: [String: String]) -> Bool {
        guard let explanation = explanations[item] else { return false }
        return !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CardDocumentView: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin

    let document: CardDocument
    var truncateRadius: Int? = nil
    var targetWord: String? = nil
    var compact: Bool = false
    var collocationExplanations: [String: String] = [:]
    var onExplainCollocation: ((String) -> Void)? = nil
    var onViewCollocationExplanation: ((String) -> Void)? = nil
    var onDeleteCollocationExplanation: ((String) -> Void)? = nil

    private var blockPadding: CGFloat { compact ? 0 : appSkin.metrics.cardBlockPadding }
    private var blockSpacing: CGFloat { compact ? TodayReviewMetrics.foldSectionSpacing : 0 }

    var body: some View {
        let _ = PerfLog.render.tick(
            "cardDocument.body",
            "blocks=\(document.blocks.count) compact=\(compact)"
        )
        // Composite ForEach key `"\(offset)-\(caseTag)"` so a slot whose case
        // changes across cards (the card subtree is now reused in place after the
        // per-card `.id` was removed) is delete-old + insert-new, never an in-place
        // case morph that would strand the previous block's measured height /
        // CoreText layout for a frame. The offset prefix prevents same-type blocks
        // at different positions from colliding.
        let keyedBlocks = document.blocks.enumerated().map { offset, block in
            (key: "\(offset)-\(block.caseTag)", block: block)
        }
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(keyedBlocks, id: \.key) { keyed in
                switch keyed.block {
                case .hero(let hero):
                    CardDocumentHeroBlock(hero: hero)
                        .padding(blockPadding)

                case .example(let paragraph):
                    CardDocumentExampleBlock(paragraph: paragraph, truncateRadius: truncateRadius, targetWord: targetWord)
                        .padding(blockPadding)

                case .divider:
                    if compact {
                        CardSectionDivider(horizontalPadding: 0)
                    } else {
                        CardSectionDivider()
                    }

                case .meaning(let meaning):
                    CardDocumentMeaningBlock(meaning: meaning, compact: compact)
                        .padding(blockPadding)

                case .collocations(let items):
                    CardDocumentCollocationsBlock(
                        items: items,
                        compact: compact,
                        explanations: collocationExplanations,
                        onExplain: onExplainCollocation,
                        onView: onViewCollocationExplanation,
                        onDelete: onDeleteCollocationExplanation
                    )
                    .padding(blockPadding)

                case .source(let source):
                    CardDocumentSourceBlock(source: source)
                        .padding(blockPadding)
                }
            }
        }
        .enableInjection()
    }
}

struct CardDocumentHeroBlock: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.speechService) private var speechService
    @Environment(\.toastCoordinator) private var toastCoordinator
    @State private var copyTrigger = false
    @State private var speakTrigger = false
    let hero: CardDocumentHero

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockContentGap) {
            HStack(alignment: .top, spacing: appSkin.metrics.cardBlockContentGap) {
                VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockInnerGap) {
                    HStack(alignment: .firstTextBaseline, spacing: appSkin.spacing.heroBaselineGap) {
                        Text(hero.word)
                            .font(appSkin.typography.detailWord)
                            // Mochi H2 letter-spacing -0.024em → 27pt 上 ≈ -0.65pt。
                            // 走 `AppFonts.Tracking.h2Tight` token，不寫 magic number。
                            .tracking(AppFonts.Tracking.h2Tight)
                            .foregroundStyle(appSkin.palette.primaryText)
                            .minimumScaleFactor(0.85)
                            .accessibilityIdentifier("cardDocument.hero.word")

                        if let pos = hero.partOfSpeech {
                            Text(pos)
                                .font(appSkin.typography.body.weight(.medium))
                                .foregroundStyle(appSkin.palette.secondaryText)
                        }
                    }

                    HStack(spacing: appSkin.spacing.heroBaselineGap) {
                        // 版面維持 36pt；可點區由 ReviewCardHitTargetButton 外擴到 44pt（#3117）。
                        ReviewCardHitTargetButton(
                            action: {
                                speechService.speak(hero.word)
                                speakTrigger.toggle()
                            },
                            accessibilityIdentifier: "cardDocument.hero.speak",
                            accessibilityLabel: L10n.format("vocab.card.speak", hero.word)
                        ) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(appSkin.typography.iconSmall)
                                .foregroundStyle(appSkin.palette.secondaryText)
                                .symbolEffect(.bounce, value: speakTrigger)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                    }
                }

                Spacer(minLength: appSkin.spacing.blockGap)

                if let tier = hero.difficultyTier {
                    VocabTierLabel(tier: tier)
                }
            }
        }
        .contextMenu {
            Button("複製".localized, systemImage: "doc.on.doc") {
                PlatformClipboard.copy(hero.word)
                copyTrigger.toggle()
                toastCoordinator.success("已複製".localized)
            }
        }
        .appFeedback(.selection, trigger: speakTrigger)
        .appFeedback(.success, trigger: copyTrigger)
        .enableInjection()
    }
}

struct CardDocumentExampleBlock: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let paragraph: CardDocumentParagraph
    var truncateRadius: Int? = nil
    var targetWord: String? = nil

    var body: some View {
        Group {
            if let radius = truncateRadius {
                CardRichTextRenderer.text(
                    paragraph.rawMarkdown,
                    style: CardRichTextStyle(
                        font: appSkin.typography.detailExampleSerif,
                        textColor: appSkin.palette.primaryText,
                        highlightColor: appSkin.palette.highlightMark,
                        italic: false,
                        underlineHighlights: appSkin.highlight.showUnderline,
                        useBackgroundMark: appSkin.highlight.showBackground,
                        highlightWeight: appSkin.highlight.fontWeight,
                        backgroundOpacity: appSkin.highlight.backgroundOpacity,
                        underlineOpacity: appSkin.highlight.underlineOpacity
                    ),
                    truncateAroundMarkedWordRadius: radius,
                    targetWord: targetWord
                )
                .lineSpacing(appSkin.metrics.paragraphLineSpacing)
            } else {
                CardInlineText(
                    paragraph: paragraph,
                    style: .example
                )
                .lineSpacing(appSkin.metrics.paragraphLineSpacing)
            }
        }
        .cardCopyContextMenu(paragraph.plainText)
        .enableInjection()
    }
}

struct CardDocumentMeaningBlock: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let meaning: CardDocumentMeaning
    var compact: Bool = false

    private var copyText: String {
        let parts = [meaning.title] + meaning.paragraphs.map(\.plainText)
        return parts.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockContentGap) {
            if !meaning.title.isEmpty {
                Text(meaning.title)
                    .font(appSkin.typography.translationTitle)
                    // Mochi H2 letter-spacing -0.024em — translationTitle 是區段 H2
                    .tracking(AppFonts.Tracking.h2Tight)
                    .foregroundStyle(appSkin.palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockContentGap) {
                ForEach(meaning.paragraphs) { paragraph in
                    CardInlineText(
                        paragraph: paragraph,
                        style: .body
                    )
                    .lineSpacing(compact ? 5 : appSkin.metrics.detailLineSpacing)
                    .lineLimit(compact ? 3 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .cardCopyContextMenu(copyText)
        .enableInjection()
    }
}

struct CardDocumentSourceBlock: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let source: CardDocumentSource

    static func copyText(for source: CardDocumentSource) -> String {
        var metadata = [source.bookTitle]
        if let chapter = source.chapterTitle {
            metadata.append(chapter)
        }
        let metadataText = metadata.joined(separator: " · ")
        return [source.context.plainText, metadataText].joined(separator: "\n")
    }

    private var copyText: String {
        Self.copyText(for: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockInnerGap) {
            CardSectionLabel(title: "來源".localized, systemImage: "book.closed")

            CardInlineText(paragraph: source.context, style: .source)
                .lineSpacing(appSkin.metrics.paragraphLineSpacing)

            HStack(spacing: appSkin.spacing.sourceMetadataGap) {
                Text(source.bookTitle)
                if let chapterTitle = source.chapterTitle {
                    Text("· \(chapterTitle)")
                }
            }
            .font(appSkin.typography.caption)
            .foregroundStyle(appSkin.palette.secondaryText)
        }
        .cardCopyContextMenu(copyText)
        .enableInjection()
    }
}

struct CardDocumentCollocationsBlock: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let items: [String]
    var compact: Bool = false
    /// Explicit row cap. `nil` keeps the historical rule (compact = 2 rows, full =
    /// unlimited); the review card passes its solved tier instead.
    var maxRows: Int? = nil
    var explanations: [String: String] = [:]
    var onExplain: ((String) -> Void)? = nil
    var onView: ((String) -> Void)? = nil
    var onDelete: ((String) -> Void)? = nil

    private var effectiveMaxRows: Int? { maxRows ?? (compact ? 2 : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockInnerGap) {
            CardSectionLabel(title: "搭配".localized, systemImage: "text.word.spacing")

            CollocationFlowLayout(spacing: appSkin.metrics.cardBlockInnerGap, maxRows: effectiveMaxRows) {
                // Identify pills by content, not position: the FlowLayout still
                // places subviews in source order (unchanged), so offscreen-place
                // logic is unaffected — this only stops an offscreen pill from being
                // reused into a new card's onscreen pill, which would carry over a
                // stale contextMenu closure bound to the old item.
                ForEach(items, id: \.self) { item in
                    collocationPill(item)
                }
            }
        }
        .enableInjection()
    }

    private func collocationPill(_ item: String) -> some View {
        let hasExplanation = CardDocumentCollocationState.hasExplanation(for: item, in: explanations)
        return Text(item)
            .font(appSkin.typography.monoBody)
            .foregroundStyle(appSkin.palette.secondaryText)
            .padding(.horizontal, AppSpacing.s2)
            .padding(.vertical, AppSpacing.s1)
            .background(
                AppRoundedRect(roundness: AppRoundness.pill).fill(
                    hasExplanation
                        ? appSkin.palette.successBg
                        : appSkin.palette.divider.opacity(0.5)
                )
            )
            .overlay {
                AppRoundedRect(roundness: AppRoundness.pill)
                    .stroke(
                        hasExplanation ? appSkin.palette.success.opacity(0.72) : .clear,
                        lineWidth: AppSpacing.hairline
                    )
            }
            .contextMenu {
                if hasExplanation {
                    Button("查看".localized, systemImage: "text.bubble") { onView?(item) }
                    Button("複製".localized, systemImage: "doc.on.doc") { PlatformClipboard.copy(item) }
                    Button("刪除".localized, systemImage: "trash", role: .destructive) { onDelete?(item) }
                } else {
                    Button("解釋".localized, systemImage: "text.bubble") { onExplain?(item) }
                    Button("複製".localized, systemImage: "doc.on.doc") { PlatformClipboard.copy(item) }
                }
            }
    }
}

// MARK: - Flow Layout

/// 自動折行佈局 — 子視圖超出容器寬度時換行
struct CollocationFlowLayout: Layout {
    var spacing: CGFloat
    var maxRows: Int? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let allRows = computeRows(proposal: proposal, subviews: subviews)
        let rows = cappedRows(allRows)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(CGFloat(0)) { sum, row in
            sum + row.height
        } + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let allRows = computeRows(proposal: proposal, subviews: subviews)
        let rows = cappedRows(allRows)
        var y = bounds.minY
        var subviewIndex = 0
        for row in rows {
            var x = bounds.minX
            for _ in 0..<row.count {
                let size = subviews[subviewIndex].sizeThatFits(.unspecified)
                subviews[subviewIndex].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
                subviewIndex += 1
            }
            y += row.height + spacing
        }
        // 超出 maxRows 的子視圖放到畫面外
        for i in subviewIndex..<subviews.count {
            subviews[i].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 1000), proposal: .zero)
        }
    }

    private func cappedRows(_ rows: [Row]) -> [Row] {
        guard let maxRows, rows.count > maxRows else { return rows }
        return Array(rows.prefix(maxRows))
    }

    private struct Row {
        var count: Int
        var height: CGFloat
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var currentRowCount = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = currentRowCount > 0 ? size.width + spacing : size.width
            if currentRowCount > 0 && currentRowWidth + needed > maxWidth {
                rows.append(Row(count: currentRowCount, height: currentRowHeight))
                currentRowWidth = size.width
                currentRowHeight = size.height
                currentRowCount = 1
            } else {
                currentRowWidth += needed
                currentRowHeight = max(currentRowHeight, size.height)
                currentRowCount += 1
            }
        }
        if currentRowCount > 0 {
            rows.append(Row(count: currentRowCount, height: currentRowHeight))
        }
        return rows
    }
}

struct CardInlineText: View {
    @ObserveInjection private var inject
    enum Style {
        case example
        case body
        case source
    }

    @Environment(\.appSkin) private var appSkin

    let paragraph: CardDocumentParagraph
    let style: Style

    var body: some View {
        Text(attributedText)
        .enableInjection()
    }

    private var attributedText: AttributedString {
        var result = AttributedString()
        for inline in paragraph.inlines {
            result += makePart(for: inline)
        }
        return result
    }

    private func makePart(for inline: CardDocumentInline) -> AttributedString {
        switch inline {
        case .text(let value):
            return plain(value)
        case .mark(let value):
            return marked(value)
        case .code(let value):
            return code(value)
        case .emphasis(let value):
            return emphasis(value)
        }
    }

    private func plain(_ value: String) -> AttributedString {
        var part = AttributedString(value)
        part.font = baseFont
        part.foregroundColor = baseColor
        return part
    }

    private func marked(_ value: String) -> AttributedString {
        let hl = appSkin.highlight
        var part = AttributedString(value)
        part.font = markedFont
        part.foregroundColor = appSkin.palette.primaryText
        switch style {
        case .example, .source:
            if hl.showBackground {
                part.backgroundColor = appSkin.palette.highlightMark.opacity(hl.backgroundOpacity)
            }
            if hl.showUnderline {
                part.underlineStyle = Text.LineStyle(
                    pattern: .solid,
                    color: appSkin.palette.highlightMark.opacity(hl.underlineOpacity)
                )
            }
        case .body:
            break
        }
        return part
    }

    private func code(_ value: String) -> AttributedString {
        var part = AttributedString(value)
        part.font = appSkin.typography.monoBody
        part.foregroundColor = appSkin.palette.secondaryText
        return part
    }

    private func emphasis(_ value: String) -> AttributedString {
        var part = AttributedString(value)
        part.font = baseFont.italic()
        part.foregroundColor = baseColor
        return part
    }

    private var baseFont: Font {
        switch style {
        case .example:
            return appSkin.typography.detailExampleSerif
        case .body:
            return appSkin.typography.body
        case .source:
            return appSkin.typography.body.italic()
        }
    }

    private var markedFont: Font {
        switch style {
        case .example:
            return appSkin.typography.detailExampleSerifStrong
        case .body:
            return appSkin.typography.body.weight(.medium)
        case .source:
            return appSkin.typography.body.weight(.medium).italic()
        }
    }

    private var baseColor: Color {
        switch style {
        case .example:
            return appSkin.palette.primaryText
        case .body:
            return appSkin.palette.secondaryText
        case .source:
            return appSkin.palette.secondaryText
        }
    }
}
