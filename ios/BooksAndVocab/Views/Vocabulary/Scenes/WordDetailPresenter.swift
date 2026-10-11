import SwiftUI

enum WordDetailInspectorMetrics {
    static let maxContentWidth: CGFloat = 640
    static let minReadableWidth: CGFloat = 320

    static func contentWidth(containerWidth: CGFloat) -> CGFloat {
        min(max(containerWidth, minReadableWidth), maxContentWidth)
    }
}

struct WordDetailPresenter: View {
    @ObserveInjection private var inject
    struct State {
        struct MetadataItem: Hashable {
            let icon: String
            let text: String
        }

        let title: String
        let systemImage: String
        let card: CardPresentation
        let rootForm: String?
        let metadataItems: [MetadataItem]
        let navigableLinkCardIDs: Set<String>
        let reviewProgress: VocabReviewProgress?

        var shareText: String {
            card.document.plainTextExport()
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appSkin) private var appSkin

    let state: State
    /// 同為 live value。封存後 sheet 刻意不關，底部控制列翻轉成「解除封存」作為 undo。
    let isArchived: Bool
    /// 尚未同步的卡仍顯示封存列，但因 server 尚未有對應卡片而 disabled。
    let canArchive: Bool
    let isReaderHidden: Bool
    let isReviewExcluded: Bool
    /// Local-only cards keep the same four-row layout while the two remote
    /// preference mutations wait for the first successful sync.
    let canEditCardPreferences: Bool
    let showsCardManagement: Bool
    let showsChrome: Bool
    let onClose: (() -> Void)?
    let onEdit: (() -> Void)?
    let onLinkTapped: (KGCardLinkSummary) -> Void
    let onToggleArchive: (() -> Void)?
    let onDelete: (() -> Void)?
    let onToggleReaderHidden: (() -> Void)?
    let onToggleReviewExcluded: (() -> Void)?
    let onAddLink: (() -> Void)?
    let onDeleteLink: ((KGCardLinkSummary) -> Void)?
    let onHideLink: ((KGCardLinkSummary) -> Void)?
    let onUnhideLink: ((KGCardLinkSummary) -> Void)?
    /// A link still being created / failed / partial: opens its creation detail.
    var onPendingLinkTapped: ((KGCardLinkSummary) -> Void)? = nil

    var body: some View {
        Group {
            if showsChrome {
                VStack(spacing: 0) {
                    VocabOverlayHeader(
                        title: state.title,
                        systemImage: state.systemImage,
                        onClose: { onClose?() },
                        trailing: {
                            shareButton
                            if let onEdit {
                                VocabChromeIconButton(systemImage: "pencil", label: "編輯".localized, action: onEdit)
                            }
                        }
                    )

                    detailContentScroll
                }
                .vocabCanvasBackground()
            } else {
                detailContentScroll
            }
        }
        .enableInjection()
    }

    private var detailContentScroll: some View {
        GeometryReader { proxy in
            ScrollView {
                detailContent
                    .frame(
                        maxWidth: WordDetailInspectorMetrics.contentWidth(containerWidth: proxy.size.width),
                        alignment: .leading
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollContentBackground(.hidden)
        }
        .vocabCanvasBackground()
        .animateContentFade(state.title)
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VocabCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    CardDocumentView(document: state.card.document)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("wordDetail.document")

                    if !state.card.forms.isEmpty {
                        CardSectionDivider()
                        CardFormsSection(
                            forms: state.card.forms,
                            rootForm: state.rootForm,
                            colorScheme: colorScheme
                        )
                        .padding(appSkin.metrics.cardBlockPadding)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("wordDetail.forms")
                    }

                    if !state.card.activeLinkGroups.isEmpty || !state.card.hiddenLinks.isEmpty || onAddLink != nil {
                        CardSectionDivider()
                        linksSection
                            .padding(appSkin.metrics.cardBlockPadding)
                    }

                    if let reviewProgress = state.reviewProgress {
                        CardSectionDivider()
                        reviewProgressSection(reviewProgress)
                            .padding(appSkin.metrics.cardBlockPadding)
                    }

                    CardSectionDivider()
                    metadataFooter
                        .padding(appSkin.metrics.cardBlockPadding)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("wordDetail.metadata")
                }
            }
            .padding(appSkin.metrics.cardBlockPadding)

            if hasCardManagement {
                cardManagementSection
                    .padding(.horizontal, appSkin.metrics.cardBlockPadding)
            }

            Spacer()
                .frame(height: appSkin.metrics.cardBlockPadding * 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wordDetail.content")
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockContentGap) {
            HStack {
                CardSectionLabel(title: "知識連結".localized, systemImage: "link")
                Spacer()
                if let onAddLink {
                    // 可點區外擴到 44pt、版面不變（#3117，同複習卡 add-link）。
                    ReviewCardHitTargetButton(
                        action: onAddLink,
                        accessibilityIdentifier: "wordDetail.card.addLink",
                        accessibilityLabel: L10n.string("vocab.card.addLink")
                    ) {
                        Image(systemName: "plus")
                            .font(appSkin.typography.iconSmall)
                            .foregroundStyle(appSkin.palette.secondaryText)
                    }
                }
            }

            ForEach(state.card.activeLinkGroups) { group in
                VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockInnerGap) {
                    Text(group.label.localized)
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.tertiaryText)

                    ForEach(group.items) { link in
                        WordDetailGraphLinkRow(
                            link: link,
                            onTap: state.navigableLinkCardIDs.contains(link.cardId) ? {
                                onLinkTapped(link)
                            } : nil,
                            onDelete: onDeleteLink != nil ? { onDeleteLink?(link) } : nil,
                            onHide: onHideLink != nil ? { onHideLink?(link) } : nil,
                            onUnhide: onUnhideLink != nil ? { onUnhideLink?(link) } : nil,
                            onPendingTap: onPendingLinkTapped != nil ? { onPendingLinkTapped?(link) } : nil
                        )
                    }
                }
            }

            if !state.card.hiddenLinks.isEmpty {
                CollocationFlowLayout(spacing: appSkin.metrics.cardBlockInnerGap) {
                    ForEach(state.card.hiddenLinks) { link in
                        Text(link.word)
                            .font(appSkin.typography.monoBody)
                            .foregroundStyle(appSkin.palette.quaternaryText)
                            .padding(.horizontal, AppSpacing.s2)
                            .padding(.vertical, AppSpacing.s1)
                            .background(
                                AppRoundedRect(roundness: AppRoundness.pill)
                                    .fill(appSkin.palette.divider.opacity(0.5))
                            )
                            .contextMenu {
                                if let onUnhide = onUnhideLink {
                                    Button {
                                        onUnhide(link)
                                    } label: {
                                        Label("恢復連結".localized, systemImage: "eye")
                                    }
                                }
                                if let onDelete = onDeleteLink {
                                    Button(role: .destructive) {
                                        onDelete(link)
                                    } label: {
                                        Label("刪除連結".localized, systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            }
        }
    }

    private func reviewProgressSection(_ progress: VocabReviewProgress) -> some View {
        HStack {
            Text(progress.statusLabel.localized)
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.secondaryText)

            Spacer()

            VocabReviewProgressBar(progress: progress)
        }
    }

    private var metadataFooter: some View {
        CollocationFlowLayout(spacing: AppSpacing.s2) {
            ForEach(Array(state.metadataItems.enumerated()), id: \.offset) { _, item in
                HStack(spacing: AppSpacing.s1) {
                    Image(systemName: item.icon)
                        .font(appSkin.typography.iconTiny)
                    Text(item.text.localized)
                }
                .padding(.horizontal, AppSpacing.s2)
                .padding(.vertical, AppSpacing.s1)
                .background(
                    AppRoundedRect(roundness: AppRoundness.pill)
                        .fill(appSkin.palette.buttonIdleFill)
                )
            }
        }
        .font(appSkin.typography.caption)
        .foregroundStyle(appSkin.palette.quaternaryText)
    }

    private var hasCardManagement: Bool {
        showsCardManagement
    }

    /// 卡片控制區統一壓在內容最底，四列使用同一個 44pt 觸控高度與左對齊。
    /// 封存、刪除是 action；兩個顯示／複習偏好則是獨立 checkbox。
    @ViewBuilder
    private var cardManagementSection: some View {
        AppAirDivider()

        VStack(alignment: .leading, spacing: appSkin.metrics.cardBlockInnerGap) {
            managementRow(
                title: isArchived ? WordDetailCopy.unarchive : WordDetailCopy.archive,
                systemImage: isArchived ? "archivebox.fill" : "archivebox",
                tone: appSkin.palette.secondaryText,
                action: onToggleArchive,
                isEnabled: canArchive,
                accessibilityIdentifier: "wordDetail.action.archive"
            )

            managementRow(
                title: WordDetailCopy.delete,
                systemImage: "trash",
                tone: appSkin.palette.destructive,
                action: onDelete,
                isEnabled: onDelete != nil,
                role: .destructive,
                accessibilityIdentifier: "wordDetail.action.delete"
            )

            checkboxRow(
                title: WordDetailCopy.hideFromReader,
                isOn: isReaderHidden,
                action: onToggleReaderHidden,
                isEnabled: canEditCardPreferences,
                accessibilityIdentifier: "wordDetail.toggle.readerHidden"
            )

            checkboxRow(
                title: WordDetailCopy.excludeFromReview,
                isOn: isReviewExcluded,
                action: onToggleReviewExcluded,
                isEnabled: canEditCardPreferences,
                accessibilityIdentifier: "wordDetail.toggle.reviewExcluded"
            )
        }
    }

    private func managementRow(
        title: String,
        systemImage: String,
        tone: Color,
        action: (() -> Void)?,
        isEnabled: Bool,
        role: ButtonRole? = nil,
        accessibilityIdentifier: String
    ) -> some View {
        Button(role: role, action: { action?() }) {
            HStack(spacing: appSkin.metrics.cardBlockInnerGap) {
                Image(systemName: systemImage)
                    .font(appSkin.typography.body)
                Text(title)
                    .font(appSkin.typography.caption)
            }
            .foregroundStyle(isEnabled ? tone : appSkin.palette.quaternaryText)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func checkboxRow(
        title: String,
        isOn: Bool,
        action: (() -> Void)?,
        isEnabled: Bool,
        accessibilityIdentifier: String
    ) -> some View {
        Button(action: { action?() }) {
            HStack(spacing: appSkin.metrics.cardBlockInnerGap) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(appSkin.typography.body)
                Text(title)
                    .font(appSkin.typography.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isEnabled ? appSkin.palette.secondaryText : appSkin.palette.quaternaryText)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? L10n.string("a11y.toggle.on") : L10n.string("a11y.toggle.off"))
        .accessibilityAddTraits(.isToggle)
        .accessibilityRemoveTraits(.isButton)
    }

    @ViewBuilder
    private var shareButton: some View {
        ShareLink(item: state.shareText, subject: Text(state.title)) {
            VocabChromeSurface(
                fill: appSkin.palette.cardBackground,
                border: appSkin.palette.cardBorder
            ) {
                Image(systemName: "square.and.arrow.up")
                    .font(appSkin.typography.iconMedium)
                    .foregroundStyle(appSkin.palette.secondaryText)
                    .frame(width: appSkin.metrics.chromeButtonSize, height: appSkin.metrics.chromeButtonSize)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("分享".localized)
    }

}
