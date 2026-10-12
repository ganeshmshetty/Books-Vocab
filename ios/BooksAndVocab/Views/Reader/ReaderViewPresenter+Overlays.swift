#if os(iOS)
import SwiftUI

extension ReaderViewPresenter {
    var loadingOverlay: some View {
        state.paperColor.ignoresSafeArea()
            .overlay {
                VStack(spacing: AppSpacing.s3) {
                    AppLoadingStateCard(
                        title: state.loadingPhase,
                        systemImage: "book.closed",
                        visualStyle: .vocab
                    )
                    if state.canResolveSlowLoading {
                        Button(L10n.string("繼續載入"), action: onResolveSlowLoading)
                            .buttonStyle(.appCompactAction(.primary))
                            .accessibilityIdentifier("reader.loading.resolve")
                    }
                }
                .frame(maxWidth: ReaderPresentationMetrics.Overlay.loadingMaxWidth)
                .padding(.horizontal, ReaderPresentationMetrics.Overlay.loadingOuterInset)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("reader.loading.\(state.loadingState.accessibilityIdentifier)")
            }
    }

    func underlineProgressOverlay(_ progress: Double) -> some View {
        VStack {
            AppSectionCard(style: .vocab(appSkin)) {
                HStack(spacing: AppSpacing.s2) {
                    AppLoadingProgressBar(progress: progress, tint: appSkin.palette.accent)
                        .frame(width: ReaderPresentationMetrics.Overlay.progressBarWidth)

                    Text("\(Int(min(max(progress, 0), 1) * 100))%")
                        .font(appSkin.typography.monoLabel)
                        .foregroundStyle(appSkin.palette.secondaryText)
                        .accessibilityHidden(true)
                        .frame(
                            width: ReaderPresentationMetrics.Overlay.progressTextWidth,
                            alignment: .trailing
                        )
                }
                .padding(.horizontal, ReaderPresentationMetrics.Overlay.progressHorizontalInset)
                .padding(.vertical, ReaderPresentationMetrics.Overlay.progressVerticalInset)
            }
            .padding(.top, ReaderPresentationMetrics.Overlay.topInset)

            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.overlayFade)
    }

    /// 只剩翻譯面板：閱讀設定已於 APP-20260808-240a94 改由 `ReaderView` 的系統
    /// sheet 呈現，不再是自繪的底部 overlay 卡片。
    var bottomOverlay: some View {
        let placement = ReaderOverlayPanelPlacement(layoutMode: LayoutMode(horizontalSizeClass: sizeClass))

        return VStack {
            Spacer()

            if state.chrome.overlay == .translation {
                overlayPanelChrome(translationPanel, placement: placement)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("reader.translationPanel")
            } else if state.chrome.overlay == .none {
                readerProgressLine
                    .transition(.overlayFade)
            }
        }
        .animation(AppMotion.panelState, value: state.chrome.overlay)
    }

    /// 底部頁邊的安靜進度文字（#2864）：無玻璃、無圖示（未知／無法還原除外）。
    /// 位於 Readium 底部 inset 內，不改變 web view 高度；`allowsHitTesting(false)`
    /// 讓點擊穿透到頁面，不與翻頁／長按查詞搶手勢。
    private var readerProgressLine: some View {
        HStack(spacing: AppSpacing.s1) {
            if let icon = progressIcon {
                Image(systemName: icon)
                    .font(appSkin.typography.iconSmall)
            }
            progressContent
        }
        .foregroundStyle(appSkin.palette.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.bottom, AppSpacing.s2)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(state.progressState.readerProgressAccessibilityIdentifier)
    }

    @ViewBuilder
    private var progressContent: some View {
        switch state.progressState {
        case .zero, .middle, .complete:
            if let progression = state.totalProgression {
                let text = ReadingProgressFormatter.percentText(progression)
                Text(text)
                    .font(appSkin.typography.monoLabel)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animateContentFade(text)
                    .accessibilityLabel(L10n.string("閱讀進度"))
                    .accessibilityValue(text)
                    .accessibilityIdentifier("reader.header.progressBadge")
            }
        case .unknown:
            Text(L10n.string("閱讀進度未知"))
                .font(appSkin.typography.caption)
        case .restoreFailure:
            Text(L10n.string("閱讀進度無法還原"))
                .font(appSkin.typography.caption)
        }
    }

    private var progressIcon: String? {
        switch state.progressState {
        case .restoreFailure: return "exclamationmark.triangle"
        case .unknown: return "questionmark"
        case .zero, .middle, .complete: return nil
        }
    }

    private func overlayPanelChrome<Content: View>(
        _ panel: Content,
        placement: ReaderOverlayPanelPlacement
    ) -> some View {
        panel
            .frame(maxWidth: placement.maxWidth)
            .frame(maxWidth: .infinity, alignment: placement.alignment)
            .padding(.horizontal, placement.horizontalInset)
            .padding(.bottom, placement.bottomInset)
            .transition(.readerPanelReveal)
    }

    // ReaderViewPresenter.swift composes this cross-file extension view. Keep
    // the member internal so Swift's `private` file-extension scope cannot
    // make the production presenter unbuildable.
    var runtimeStateAccessibility: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("reader.runtime.state")
            .accessibilityLabel(L10n.string("閱讀器狀態"))
            .accessibilityValue(runtimeStateValue)
    }

    /// 頁面翻動證據用的精確值。可見進度是整數百分比（每頁約 0.3%，數字常不變），
    /// 所以 UITest 改讀這個 `progression=` 鍵，不靠 header 的顯示文字。
    private var runtimeStateValue: String {
        guard let progression = state.totalProgression else {
            return state.runtimeStateAccessibilityValue
        }
        return state.runtimeStateAccessibilityValue
            + ";progression=" + String(format: "%.4f", progression)
    }
}
#endif
