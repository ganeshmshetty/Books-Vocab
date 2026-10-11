#if os(iOS)
//
//  TranslationVocabPresenter.swift
//  Books & Vocab
//
//  TranslationPanel 的 Vocab-style 渲染器。
//  與 Glass presenter 共用相同的內容狀態與操作語意，
//  僅切換卡片視覺與字體 / 色彩 token。
//

import SwiftUI

struct TranslationVocabPresenter: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.horizontalSizeClass) private var sizeClass

    let state: TranslationPanelPresenterState
    let onSpeak: () -> Void
    let onExpand: () -> Void
    let onDelete: () -> Void
    let onShowDetail: (() -> Void)?
    let onDismiss: () -> Void
    var onLogin: (() -> Void)? = nil
    var onRetryTranslation: (() -> Void)? = nil
    var onRetryExplanation: (() -> Void)? = nil
    var onToggleHeight: () -> Void = {}

    var body: some View {
        let chrome = ReaderPanelChromeStyle(layoutMode: LayoutMode(horizontalSizeClass: sizeClass))

        return VocabCard(padding: 0) {
            VStack(spacing: 0) {
                if chrome.showsDragHandle {
                    AppRoundedRect(roundness: AppRoundness.pill)
                        .fill(appSkin.palette.quaternaryText.opacity(appSkin.metrics.panelHandleOpacity))
                        .frame(
                            width: ReaderMetrics.panelHandleWidth,
                            height: ReaderMetrics.panelHandleHeight
                        )
                        .padding(.top, ReaderMetrics.panelHandleTopInset)
                        .padding(.bottom, ReaderMetrics.panelHandleBottomInset)
                }

                VStack(alignment: .leading, spacing: AppSpacing.s3) {
                    heroSection
                    panelBody
                }
                .padding(.horizontal, ReaderMetrics.panelHorizontalInset)
                .padding(.top, chrome.contentTopInset)
                .padding(.bottom, ReaderMetrics.panelBottomInset)
            }
        }
        // Mochi 北極星 #3：shadow 收兩階 — z3 → z2,翻譯 panel 降低 floating 感,
        // 但仍保留 panel handle 視覺辨識(VocabCard 內的 pill handle)。
        .appElevation(.z2, direction: .up)
        .modifier(LargePanelModifier(apply: state.isPanelLarge && chrome == .bottomSheet))
        .enableInjection()
    }

    private var heroSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.s2) {
            Text(state.word)
                .font(state.word.count > 12
                      ? appSkin.typography.translationTitle
                      : appSkin.typography.detailWord)
                .foregroundStyle(appSkin.palette.primaryText)
                .accessibilityIdentifier("reader.translationPanel.word")

            // 10pt 字形的可點區外擴到 44pt、版面不變（#3117）。
            ReviewCardHitTargetButton(
                action: onSpeak,
                accessibilityIdentifier: "reader.translationPanel.speak",
                accessibilityLabel: L10n.format("translation.vocab.speak", state.word)
            ) {
                Image(systemName: "speaker.wave.2")
                    .font(appSkin.typography.iconTiny)
                    .foregroundStyle(appSkin.palette.secondaryText)
                    .symbolEffect(.bounce, value: state.isSpeaking)
            }

            Spacer()

            if let pos = state.partOfSpeech {
                VocabToneChip(text: pos, tone: appSkin.palette.accent)
            }
        }
    }

    @ViewBuilder
    private var panelBody: some View {
        switch state.contentMode {
        case .loading:
            loadingSection
        case .guest:
            guestModeBody
        case .explanationOnly:
            explanationOnlyBody
        case .translation(let translation):
            translationBody(translation)
        case .translationError(let message):
            translationErrorBody(message)
        case .empty:
            emptyStateBody
        }
    }

    private var loadingSection: some View {
        VocabStateMessageCard(
            title: state.loadingTitle,
            systemImage: "translate"
        ) {
            HStack {
                ProgressView().scaleEffect(AppMetrics.loadingIndicatorScaleMedium)
                Spacer()
                if let timerText = state.activeTimerText {
                    Text(timerText)
                        .font(appSkin.typography.monoLabel)
                        .foregroundStyle(appSkin.palette.quaternaryText)
                }
            }
        }
    }

    private var guestModeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            VocabStateMessageCard(
                title: state.guestMessageTitle,
                systemImage: state.guestMessageIcon,
                description: "登入後即可獲得 AI 翻譯，並同步至雲端。".localized
            )

            if let onLogin {
                Button("登入帳號".localized, action: onLogin)
                    .buttonStyle(.vocabAction())
            }

            footerToolbar(showChevron: false, timerValue: nil)
        }
    }

    private var explanationOnlyBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            explanationSection

            footerToolbar(showChevron: false, timerValue: state.statusTimerText)
        }
    }

    private func translationBody(_ translation: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(translation)
                .font(appSkin.typography.translationTitle)
                .foregroundStyle(appSkin.palette.translationText)
                .accessibilityIdentifier("reader.translationPanel.translation")

            if state.isExpanded {
                explanationSection
            }

            if state.isPanelLarge {
                Spacer()
            }

            footerToolbar(showChevron: state.showsExpandAction, timerValue: state.statusTimerText)
        }
    }

    private func translationErrorBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VocabStateMessageCard(
                title: "翻譯暫時失敗".localized,
                systemImage: "exclamationmark.triangle.fill",
                description: message
            )

            if let onRetryTranslation {
                Button(action: onRetryTranslation) {
                    Label("重試翻譯".localized, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.vocabAction())
            }

            footerToolbar(showChevron: false, timerValue: state.statusTimerText)
        }
    }

    private var emptyStateBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            VocabStateMessageCard(
                title: "尚未取得翻譯".localized,
                systemImage: "text.viewfinder",
                description: "請重新選取文字，或稍後再試一次。".localized
            )

            footerToolbar(showChevron: false, timerValue: state.statusTimerText)
        }
    }

    private var emptyExplainStateCard: some View {
        VocabStateMessageCard(
            title: "還沒有語境解釋".localized,
            systemImage: "text.bubble",
            description: "展開後會在這裡顯示上下文說明。".localized
        )
    }

    private var explanationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionDivider(horizontalPadding: 0)
                .padding(.vertical, AppSpacing.microGap)

            Label("語境解釋".localized, systemImage: "text.bubble")
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.quaternaryText)
                .padding(.bottom, ReaderMetrics.translationExplanationHeaderGap)

            explanationContent
        }
        .frame(maxHeight: state.isPanelLarge ? .infinity : nil, alignment: .top)
    }

    @ViewBuilder
    private var explanationContent: some View {
        switch state.explanationContentMode {
        case .loading(let title):
            VocabStateMessageCard(
                title: title,
                systemImage: "text.bubble"
            ) {
                HStack {
                    ProgressView().scaleEffect(AppMetrics.loadingIndicatorScaleSmall)
                    Spacer()
                    if let timerText = state.activeTimerText {
                        Text(timerText)
                            .font(appSkin.typography.monoLabel)
                            .foregroundStyle(appSkin.palette.quaternaryText)
                    }
                }
            }
            .padding(.vertical, appSkin.spacing.tinyGap)
        case .error(let errorMessage):
            VStack(alignment: .leading, spacing: 10) {
                VocabStateMessageCard(
                    title: "語境解釋暫時無法載入".localized,
                    systemImage: "exclamationmark.triangle.fill",
                    description: errorMessage
                )

                if let onRetryExplanation {
                    Button(action: onRetryExplanation) {
                        Label("重試解釋".localized, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.vocabAction())
                }
            }
            .padding(.vertical, appSkin.spacing.tinyGap)
        case .content(let explanation):
            if state.isPanelLarge {
                ScrollView {
                    Text(explanation)
                        .font(appSkin.typography.body)
                        .foregroundStyle(appSkin.palette.secondaryText)
                        .lineSpacing(ReaderMetrics.translationExplanationLineSpacing)
                        .padding(.top, ReaderMetrics.translationExplanationContentTopInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(explanation)
                    .font(appSkin.typography.body)
                    .foregroundStyle(appSkin.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(ReaderMetrics.translationExplanationLineSpacing)
                    .padding(.top, ReaderMetrics.translationExplanationContentTopInset)
            }
        case .empty:
            emptyExplainStateCard
                .padding(.vertical, appSkin.spacing.tinyGap)
        }
    }

    @ViewBuilder
    private func footerToolbar(showChevron: Bool, timerValue: String?) -> some View {
        HStack(spacing: AppSpacing.s1) {
            if state.showsSavedStatus {
                Label("已加入".localized, systemImage: "checkmark.circle.fill")
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.success)
                    .symbolEffect(.bounce, value: state.isSaved)
                    .transition(.feedbackBadge)
            }

            if let timerValue {
                Text(timerValue)
                    .font(appSkin.typography.monoLabel)
                    .foregroundStyle(appSkin.palette.quaternaryText)
                    .padding(.leading, state.showsSavedStatus ? appSkin.spacing.inlineGap : 0)
            }

            Spacer()

            if let onShowDetail {
                VocabChromeIconButton(
                    systemImage: "rectangle.portrait.on.rectangle.portrait",
                    label: L10n.string("vocab.chromeIcon.translation.detail"),
                    action: onShowDetail
                )
            }

            if state.showsHeightToggle {
                VocabChromeIconButton(
                    systemImage: state.isPanelLarge ? "chevron.down" : "chevron.up",
                    label: L10n.string(state.isPanelLarge ? "vocab.chromeIcon.translation.shrink" : "vocab.chromeIcon.translation.enlarge"),
                    action: onToggleHeight
                )
            }

            if showChevron {
                VocabChromeIconButton(
                    systemImage: state.isExpanded ? "chevron.up" : "chevron.down",
                    label: L10n.string(state.isExpanded ? "vocab.chromeIcon.translation.collapse" : "vocab.chromeIcon.translation.expand"),
                    action: onExpand
                )
            }

            if state.showsDeleteAction {
                VocabChromeIconButton(
                    systemImage: "trash",
                    tone: appSkin.palette.destructive,
                    label: L10n.string("vocab.chromeIcon.translation.delete"),
                    action: onDelete
                )
            }

            VocabChromeIconButton(
                systemImage: "xmark",
                label: L10n.string("vocab.chromeIcon.translation.dismiss"),
                action: onDismiss
            )
            .accessibilityIdentifier("reader.translationPanel.dismissButton")
        }
        .padding(.top, appSkin.spacing.tinyGap)
    }
}

private struct LargePanelModifier: ViewModifier {
    let apply: Bool
    func body(content: Content) -> some View {
        if apply {
            content
                .containerRelativeFrame(.vertical, alignment: .bottom) { h, _ in h * 0.84 }
        } else {
            content
        }
    }
}

#Preview("Translation Vocab / Full Result") {
    AppThemeContainer {
        VStack {
            Spacer()
            TranslationVocabPresenter(
                state: TranslationPanelPreviewData.fullTranslation,
                onSpeak: {}, onExpand: {}, onDelete: {}, onShowDetail: nil, onDismiss: {}
            )
            .padding()
        }
    }
    .environmentObject(AppAppearanceStore.preview)
}

#Preview("Translation Vocab / Explanation Error") {
    AppThemeContainer {
        VStack {
            Spacer()
            TranslationVocabPresenter(
                state: TranslationPanelPreviewData.explanationError,
                onSpeak: {}, onExpand: {}, onDelete: {}, onShowDetail: nil, onDismiss: {}
            )
            .padding()
        }
    }
    .environmentObject(AppAppearanceStore.preview)
}
#endif
