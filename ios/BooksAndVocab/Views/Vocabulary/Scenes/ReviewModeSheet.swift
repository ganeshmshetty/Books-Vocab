import SwiftUI

/// #2042 Stage 3：辨識⇄產出切換面板。拉桿＝忘記程度，預設在右端（紫＝歸零）；確認才寫入。
/// 不放說明文字：方向文案與兩端顏色即足夠。
struct ReviewModeSheet: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    /// 切換後的目標方向（目前卡的反向）。
    let targetMode: VocabularyCardMode
    let onConfirm: (Double) -> Void
    @State private var level: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s4) {
            Text(L10n.string(targetMode.switchTargetLabelKey))
                .font(appSkin.typography.body)
                .foregroundStyle(appSkin.palette.primaryText)
            ReviewForgettingSlider(level: $level)
            Button {
                onConfirm(ReviewProgressAdjustment.snapped(level))
            } label: {
                Text(L10n.string("todayReview.reviewMode.sheet.confirm"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(AppSpacing.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .enableInjection()
    }
}

/// 忘記程度拉桿。`DragGesture` 直接驅動 `level`；底圖重用 `ReviewGradientBar`（左綠＝保留、右紫＝歸零）。
struct ReviewForgettingSlider: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Binding var level: Double
    static let knobSize: CGFloat = 32

    /// 觸點 x（拉桿座標）→ level。旋鈕中心可行區間為 `[knob/2, width − knob/2]`，超出即夾住。
    static func level(forX x: CGFloat, width: CGFloat, knobSize: CGFloat) -> Double {
        let travel = width - knobSize
        guard travel > 0 else { return 0 }
        return ReviewProgressAdjustment.clampedLevel(Double((x - knobSize / 2) / travel))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let travel = max(width - Self.knobSize, 0)
            ZStack(alignment: .leading) {
                ReviewGradientBar()
                    .frame(height: Self.knobSize / 2)
                    .clipShape(AppRoundedRect(roundness: AppRoundness.pill))
                    .padding(.horizontal, Self.knobSize / 2)
                Circle()
                    .fill(.background)
                    .overlay(Circle().stroke(appSkin.palette.secondaryText.opacity(0.3), lineWidth: 1))
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .offset(x: travel * level)
                    // 只在吸附到右端時以 spring 過渡；拖曳中的位置逐幀直接跟手。
                    .animation(AppMotion.reviewRevealSpring, value: level == 1)
            }
            .frame(width: width, height: Self.knobSize, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        level = ReviewProgressAdjustment.snapped(
                            Self.level(forX: value.location.x, width: width, knobSize: Self.knobSize)
                        )
                    }
            )
        }
        .frame(height: Self.knobSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("todayReview.reviewMode.level.label"))
        .accessibilityValue(levelDescription)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: level = ReviewProgressAdjustment.snapped(min(level + 0.1, 1))
            case .decrement: level = ReviewProgressAdjustment.snapped(max(level - 0.1, 0))
            @unknown default: break
            }
        }
        .enableInjection()
    }

    private var levelDescription: String {
        if level <= 0 { return L10n.string("todayReview.reviewMode.level.keep") }
        if level >= 1 { return L10n.string("todayReview.reviewMode.level.reset") }
        return L10n.string("todayReview.reviewMode.level.partial")
    }
}
