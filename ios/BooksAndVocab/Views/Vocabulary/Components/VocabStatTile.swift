import SwiftUI

/// Column policy for the Overview metric block (#2859). Pure so the reflow rule can
/// be pinned without a SwiftUI runtime.
enum VocabStatTileLayout {
    /// Two equal columns at standard Dynamic Type sizes. From the accessibility sizes
    /// up a numeral no longer fits beside its neighbour, so the row reflows to one column.
    static func columnCount(for size: DynamicTypeSize) -> Int {
        size.isAccessibilitySize ? 1 : 2
    }
}

/// Frame anchor for one Overview metric readout. Its content must hug the top edge: a
/// readout that stretches to its grid row's height would otherwise center its numeral,
/// breaking the shared top line with the neighbouring readout in the row (#3271).
enum VocabStatReadoutLayout {
    static let frameAlignment: Alignment = .topLeading
}

/// One Overview metric readout. It owns its padding, so its accessibility frame is the
/// whole readout; any surface is drawn by the caller around it.
struct VocabStatReadout: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let title: String
    let value: String
    let unit: String
    let systemImage: String
    let identifier: String
    var isHero = false

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.rowMicroGap) {
            HStack(spacing: appSkin.spacing.rowMicroGap) {
                Image(systemName: systemImage)
                    .font(appSkin.typography.iconSmall)
                Text(title)
                    .font(appSkin.typography.caption)
            }
            .foregroundStyle(appSkin.palette.tertiaryText)
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.microGap) {
                Text(value)
                    .font(isHero ? appSkin.typography.numericHero : appSkin.typography.monoEmphasis)
                    .monospacedDigit()
                    .lineLimit(StatsMetricValueLayout.maximumLines)
                    .minimumScaleFactor(StatsMetricValueLayout.minimumScaleFactor)
                    .allowsTightening(StatsMetricValueLayout.allowsTightening)
                    .layoutPriority(1)
                    .foregroundStyle(appSkin.palette.primaryText)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(appSkin.typography.caption)
                    .lineLimit(StatsMetricValueLayout.maximumLines)
                    .fixedSize(horizontal: StatsMetricValueLayout.unitIsFixedWidth, vertical: false)
                    .foregroundStyle(appSkin.palette.tertiaryText)
            }
        }
        .padding(AppSkin.baseSpacing.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: VocabStatReadoutLayout.frameAlignment)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(value)
        .enableInjection()
    }
}

/// Flat grid surface: fill only. No border and no elevation (`ui-design.md` rules 2-3).
struct VocabStatSurface<Content: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                AppRoundedRect(roundness: appSkin.roundness.card)
                    .fill(appSkin.palette.cardBackground)
            }
            .enableInjection()
    }
}

/// Today hero: one Liquid Glass surface holding the primary and secondary figures.
/// Glass carries no stroke, no elevation, and no second background (`ui-design.md`).
struct VocabStatHeroSurface<Content: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: AppRoundedRect(roundness: appSkin.roundness.card))
            .enableInjection()
    }
}
