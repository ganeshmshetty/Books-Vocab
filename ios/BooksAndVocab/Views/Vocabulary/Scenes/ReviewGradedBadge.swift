import SwiftUI

/// 已評卡片的「已評：記得／忘記」標示（#3371）。
///
/// 純標示：不可點（`allowsHitTesting(false)`），點擊照常落到翻卡手勢。版面位置由卡片 chrome 決定，
/// 本 view 不佔右上角三槽（喇叭／詳情／⋯，#3112）；字級上限與 notebook 標示相同，確保收在留白內。
struct ReviewGradedBadgeView: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let badge: ReviewGradedBadge

    var body: some View {
        Text(badge.text)
            .font(appSkin.typography.caption)
            .foregroundStyle(appSkin.palette.tertiaryText)
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .allowsHitTesting(false)
            .transition(.feedbackBadge)
            .accessibilityIdentifier("todayReview.card.graded")
            .enableInjection()
    }
}
