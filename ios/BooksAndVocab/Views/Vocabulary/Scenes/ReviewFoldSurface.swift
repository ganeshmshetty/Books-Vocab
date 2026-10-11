import SwiftUI

// MARK: - Fold Segment Position

enum FoldSegmentPosition {
    case single
    case top
    case middle
    case bottom
}

// MARK: - Fold Surface Container

struct ReviewFoldSurface<Content: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin

    let position: FoldSegmentPosition
    /// 邊框線條透明度 — 預設為 active 值；常駐 slot（Phase 3a）以
    /// `TodayReviewCardSlotLayout.borderOpacity` 內插（preview 0.45 → active 0.72）。
    var borderOpacity: Double = TodayReviewMetrics.cardBorderActiveOpacity
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            // 卡面必須完全不透明：它是這張卡的最底層，正下方 z 序就是 preview slot
            // （整層 opacity 0.72、縮放 0.975、下移 5pt 的**下一張真卡**）。舊值 0.985
            // 的 1.5% 縫隙讓下一張的單字以 0.72×0.015 ≈ 1.1% 透出（實測灰階 253 vs
            // 卡片白 255），在白底大字上剛好可辨；那 1.5% 換不到任何視覺效果——卡片
            // 下方就是 pageBackground。三個主題的 cardBackground 都是不透明色值。
            .background(appSkin.palette.cardBackground)
            .clipShape(shape)
            .overlay(shape.stroke(appSkin.palette.cardBorder.opacity(borderOpacity), lineWidth: 1))
            .overlay(alignment: .top) {
                if position != .top && position != .single {
                    Rectangle()
                        .fill(appSkin.palette.divider.opacity(TodayReviewMetrics.dividerFillOpacity))
                        .frame(height: AppMetrics.dividerThin)
                        .padding(.horizontal, appSkin.spacing.cardPadding)
                }
            }
            .appElevation(.z1)
            .enableInjection()
    }

    /// 外緣走卡片圓度、接縫走 `foldJoinRoundness`；左右恆對稱，故只有 top / bottom 兩個自由度。
    ///
    /// 基準明確釘在 `foldRoundnessBasis`，**不用各段自己的 box**：摺頁卡是「一張卡
    /// 切成 front(≥120) + answer(≥188) 兩段」，兩段高度不同。若各自導出，同一條接縫
    /// 的上下緣會是 4.5 vs 7.05pt、整張卡的上下外緣會是 9.0 vs 14.1pt——單一物件的角
    /// 自己對不上。共用基準讓四個角回到舊碼那種天生對稱。
    private var shape: AppUnevenRoundedRect {
        let top = (position == .single || position == .top) ? appSkin.roundness.card : TodayReviewMetrics.foldJoinRoundness
        let bottom = (position == .single || position == .bottom) ? appSkin.roundness.card : TodayReviewMetrics.foldJoinRoundness
        return AppUnevenRoundedRect(
            topRoundness: top,
            bottomRoundness: bottom,
            basis: TodayReviewMetrics.foldRoundnessBasis
        )
    }
}

// MARK: - Fold Chevron Pill (centered collapse handle)

struct ReviewFoldChevronPill: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let action: () -> Void
    let accessibilityLabel: String

    var body: some View {
        // 版面維持 48×30；可點區由 ReviewCardHitTargetButton 外擴到 44pt 見方（#3117）。
        // 命中形狀刻意為矩形：44pt 高度只能靠上下各 7pt 外擴，pill 形命中區達不到 44pt；
        // 寬度 44 < 48 pill 寬，橫向不侵入卡面。外擴的 7pt 帶位於 fold 接縫，由 UITest 鎖定幾何範圍。
        ReviewCardHitTargetButton(
            action: action,
            accessibilityIdentifier: "todayReview.fold.collapse",
            accessibilityLabel: accessibilityLabel
        ) {
            Image(systemName: "chevron.up")
                .font(appSkin.typography.iconTiny.weight(.semibold))
                .foregroundStyle(appSkin.palette.tertiaryText.opacity(0.78))
                .frame(width: 34, height: 18)
                .background(
                    AppRoundedRect(roundness: AppRoundness.pill)
                        .fill(appSkin.palette.cardBackground.opacity(0.94))
                )
                .overlay(
                    AppRoundedRect(roundness: AppRoundness.pill)
                        .stroke(appSkin.palette.divider.opacity(0.58), lineWidth: AppSpacing.hairline)
                )
                .frame(width: 48, height: TodayReviewMetrics.chevronButtonSize)
        }
        .enableInjection()
    }
}

// MARK: - Paper Fold Modifier (Animatable)

/// 摺疊動畫 — progress 0=完全摺疊 1=完全展開。
/// 實作 Animatable 使 SwiftUI 逐幀插值 progress，
/// 確保 scaleEffect / rotation3D / opacity / offset 完美同步。
struct PaperFoldModifier: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(y: max(progress, 0.02), anchor: .top)
            .rotation3DEffect(
                .degrees(Double((1 - progress) * -88)),
                axis: (x: 1, y: 0, z: 0),
                anchor: .top,
                perspective: 0.86
            )
            .opacity(progress)
            .offset(y: (1 - progress) * -TodayReviewMetrics.paperFoldOffsetY)
    }
}
