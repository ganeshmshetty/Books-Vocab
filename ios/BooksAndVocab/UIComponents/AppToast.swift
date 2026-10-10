import SwiftUI

/// 頂端滑出的通知 pill（#2047）：只負責通知，沒有動作按鈕；預設單行，過長時先縮小再
/// 尾端截斷。截斷中的 pill 可輕點就地展開成完整多行（#2862，唯一的多行狀態，由使用者
/// 觸發）。何時用 pill、何時用畫面內面板見 docs/sop/ui-design.md「暫時性提示」。
struct AppToast: View {
    @Environment(\.appTheme) private var appTheme
    let item: AppToastItem
    var isExpanded: Bool = false
    var onToggleExpanded: (() -> Void)?
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0
    /// 單行、未縮放時的文案自然寬度（隱藏量測用）。
    @State private var naturalTextWidth: CGFloat = 0
    /// 目前可見文字的版面寬度；截斷時等於可用寬度。
    @State private var visibleTextWidth: CGFloat = 0

    /// 與 `minimumScaleFactor` 一致：縮到此比例仍放不下才算截斷。
    static let minimumTextScale: CGFloat = 0.8
    /// 點擊區外擴量，讓 35pt 的 pill 達到 44pt 觸控目標，不改變視覺尺寸。
    static let hitSlop: CGFloat = 5
    /// iPad 上展開卡片的寬度上限。
    static let expandedMaxWidth: CGFloat = 560

    private var displayText: String { item.message.localized }

    private var isTruncated: Bool {
        naturalTextWidth * Self.minimumTextScale > visibleTextWidth + 0.5
    }

    /// 只有真的截斷、或已展開（可收回）時才可輕點。
    private var canToggle: Bool {
        onToggleExpanded != nil && (isExpanded || isTruncated)
    }

    var body: some View {
        interactivePill
            .offset(y: min(dragOffset, 0))
            // simultaneous：上滑收起在展開與收合狀態都要生效，不與點擊互斥。
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation.height
                    }
                    .onEnded { value in
                        if value.translation.height < -20
                            || value.predictedEndTranslation.height < -200
                        {
                            onDismiss()
                        } else {
                            withAnimation(AppMotion.swipeSnapBackSpring) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("app.toast")
            .accessibilityValue(item.style.accessibilityValue)
            .accessibilityHint(isTruncated && !isExpanded ? Text(L10n.string("toast.expand.hint")) : Text(verbatim: ""))
            // 長文案在 pill 內截斷，而不是讓 pill 貼齊螢幕邊緣。
            .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)
            .padding(.top, AppSpacing.s2)
    }

    @ViewBuilder
    private var interactivePill: some View {
        if canToggle, let onToggleExpanded {
            Button(action: onToggleExpanded) {
                pill
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle().inset(by: -Self.hitSlop))
        } else {
            pill
        }
    }

    private var pill: some View {
        HStack(alignment: isExpanded ? .top : .center, spacing: 10) {
            Image(systemName: item.systemImage)
                .font(AppFonts.caption())
                .foregroundStyle(tintColor)
                .accessibilityHidden(true)

            Text(displayText)
                .font(AppFonts.caption(weight: .semibold))
                .foregroundStyle(tintColor)
                .lineLimit(isExpanded ? nil : 1)
                .fixedSize(horizontal: false, vertical: isExpanded)
                .minimumScaleFactor(isExpanded ? 1 : Self.minimumTextScale)
                .truncationMode(.tail)
                // 同一事件就地取代時只換字，不重播整個進出場。
                .contentTransition(.opacity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    visibleTextWidth = width
                }
                .background(alignment: .leading) {
                    // 單行自然寬度的隱藏量測；不參與版面、不進無障礙樹。
                    Text(displayText)
                        .font(AppFonts.caption(weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            naturalTextWidth = width
                        }
                }

            if isExpanded || isTruncated {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(AppFonts.caption(weight: .semibold))
                    .foregroundStyle(tintColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, AppSpacing.cardPadding)
        .padding(.vertical, AppSkin.baseSpacing.compactRowVerticalPadding)
        .frame(maxWidth: isExpanded ? Self.expandedMaxWidth : nil)
        // Toast is a single transient glass surface. The tint carries the
        // semantic tone; Liquid Glass owns the backdrop, edge highlight and
        // depth, so no second background, border or app elevation is layered on.
        .glassEffect(
            .regular.tint(tintColor.opacity(0.12)),
            in: AppRoundedRect(roundness: isExpanded ? AppRoundness.card : AppRoundness.pill)
        )
    }

    private var tintColor: Color {
        switch item.style {
        case .success: appTheme.palette.success
        case .info: appTheme.palette.accent
        case .warning: appTheme.palette.warning
        case .error: appTheme.palette.destructive
        }
    }
}

private extension AppToastItem.Style {
    /// UITest 可讀的語氣標記（非使用者文案）。
    var accessibilityValue: String {
        switch self {
        case .success: "success"
        case .info: "info"
        case .warning: "warning"
        case .error: "error"
        }
    }
}

// MARK: - Toast Overlay Modifier

private struct ToastOverlayModifier: ViewModifier {
    @Environment(\.toastCoordinator) private var toastCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = toastCoordinator.current {
                AppToast(
                    item: toast,
                    isExpanded: toastCoordinator.isExpanded,
                    onToggleExpanded: {
                        toastCoordinator.toggleExpanded(
                            animation: reduceMotion ? AppMotion.contentFade : AppMotion.panelState
                        )
                    },
                    onDismiss: { toastCoordinator.dismiss() }
                )
                    // 進出場都由 coordinator 以 `AppMotion.panelState` 驅動；Reduce Motion
                    // 時只淡入淡出、不位移。
                    .transition(reduceMotion ? .overlayFade : .bannerReveal)
                    .zIndex(999)
            }
        }
    }
}

extension View {
    func toastOverlay() -> some View {
        modifier(ToastOverlayModifier())
    }
}

#Preview("Toast Styles") {
    AppThemeContainer {
        AppToastPreviewScene()
    }
    .environmentObject(AppAppearanceStore.preview)
}

private struct AppToastPreviewScene: View {
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        VStack(spacing: AppSpacing.s6) {
            AppToast(
                item: .init(message: "已複製", style: .success),
                onDismiss: {}
            )
            AppToast(
                item: .init(message: "背景同步完成，新增 3 個單字", style: .info),
                onDismiss: {}
            )
            AppToast(
                item: .init(message: "部分同步失敗，2 個單字未上傳", style: .warning),
                onDismiss: {}
            )
            AppToast(
                item: .init(message: "刪除失敗", style: .error),
                onDismiss: {}
            )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appTheme.palette.pageBackground)
    }
}
