import SwiftUI

/// 連結卡片疊層的層次位移參數 — 僅 LinkedCardOverlayStack 使用。
private enum AppOverlayMetrics {
    static let linkedCardLayerOffsetX: CGFloat = 8
    static let linkedCardLayerOffsetY: CGFloat = 10
    static let linkedCardLayerShrinkStep: CGFloat = 18
}

struct LinkedCardOverlayStack: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Binding var stack: [VocabularyEntry]
    var allEntries: [VocabularyEntry] = []

    var body: some View {
        Group {
            if !stack.isEmpty {
                ZStack {
                    appSkin.palette.overlayScrim
                        .ignoresSafeArea()
                        .onTapGesture {
                            _ = stack.popLast()
                        }
                        // 純裝飾的點擊關閉區；每層卡片的 VocabOverlayHeader 有明確 close 按鈕。
                        .accessibilityHidden(true)

                    ForEach(Array(stack.enumerated()), id: \.element.id) { index, entry in
                        linkedCardLayer(entry: entry, index: index)
                            .zIndex(Double(index + 1))
                            .allowsHitTesting(index == stack.count - 1)
                            .animateSpring(stack.count)
                    }
                }
                .transition(.overlayFade)
            }
        }
        .enableInjection()
    }

    private func linkedCardLayer(entry: VocabularyEntry, index: Int) -> some View {
        VStack(spacing: 0) {
            VocabOverlayHeader(
                title: index == 0 ? "Linked Card" : "Nested Link",
                systemImage: "rectangle.stack",
                badgeText: index > 0 ? "+\(index)" : nil,
                onClose: { close(from: index) }
            )

            Rectangle()
                .fill(appSkin.palette.divider)
                .frame(height: AppMetrics.dividerThin)

            WordDetailSheet(
                entry: entry,
                allEntries: allEntries,
                wrapInNavigation: false,
                linkedCardStack: $stack
            )
        }
        .frame(
            maxWidth: max(420, 680 - CGFloat(index) * AppOverlayMetrics.linkedCardLayerShrinkStep),
            maxHeight: max(420, 620 - CGFloat(index) * AppOverlayMetrics.linkedCardLayerShrinkStep)
        )
        .background(appSkin.palette.cardBackground)
        .clipShape(AppRoundedRect(roundness: appSkin.roundness.card))
        .overlay(
            AppRoundedRect(roundness: appSkin.roundness.card)
                .stroke(appSkin.palette.cardBorder.opacity(0.8), lineWidth: 1)
        )
        .appElevation(.z4)
        .padding(.horizontal, AppSpacing.s4 + CGFloat(index) * AppOverlayMetrics.linkedCardLayerOffsetY)
        .padding(.vertical, AppSpacing.s5 + CGFloat(index) * AppOverlayMetrics.linkedCardLayerOffsetX)
        .scaleEffect(max(0.94, 1 - CGFloat(index) * 0.02))
        .offset(x: CGFloat(index) * AppOverlayMetrics.linkedCardLayerOffsetX, y: CGFloat(index) * AppOverlayMetrics.linkedCardLayerOffsetY)
        .transition(.linkedOverlayCard)
    }

    private func close(from index: Int) {
        guard stack.indices.contains(index) else { return }
        stack.removeSubrange(index...)
    }
}

extension Array where Element == VocabularyEntry {
    /// Pushes a linked card without ever holding the same entry twice (#2734).
    /// An entry already on the stack closes the layers above it instead, so `ForEach` ids stay unique.
    mutating func pushLinkedCard(_ entry: VocabularyEntry) {
        if let index = firstIndex(where: { $0.id == entry.id }) {
            removeSubrange((index + 1)...)
        } else {
            append(entry)
        }
    }
}
