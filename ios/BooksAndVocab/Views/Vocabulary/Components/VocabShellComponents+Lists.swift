import SwiftUI

// MARK: - List Cards, Status Hero, Timeline, Button Styles

struct VocabListCard<Header: View, Content: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let headerPadding: EdgeInsets
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    init(
        headerPadding: EdgeInsets? = nil,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.headerPadding = headerPadding ?? EdgeInsets(
            top: AppSkin.baseMetrics.listCardHeaderTopInset,
            leading: AppSkin.baseMetrics.listRowHorizontalInset,
            bottom: AppSkin.baseMetrics.listCardHeaderBottomInset,
            trailing: AppSkin.baseMetrics.listRowHorizontalInset
        )
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VocabCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(headerPadding)

                Rectangle()
                    .fill(appSkin.palette.divider)
                    .frame(height: AppMetrics.dividerThin)
                    .padding(.horizontal, appSkin.metrics.listDividerInset)

                content
            }
        }
        .enableInjection()
    }
}

struct VocabStatusHero<Badges: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let systemImage: String
    var tone: Color
    let title: String
    var description: String? = nil
    @ViewBuilder let badges: Badges

    init(
        systemImage: String,
        tone: Color,
        title: String,
        description: String? = nil,
        @ViewBuilder badges: () -> Badges = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.tone = tone
        self.title = title
        self.description = description
        self.badges = badges()
    }

    var body: some View {
        VStack(spacing: appSkin.spacing.statusHeroGap) {
            Image(systemName: systemImage)
                .font(appSkin.typography.symbolHero)
                .foregroundStyle(tone)

            Text(title.localized)
                .font(appSkin.typography.sectionTitle)

            if let description {
                Text(description.localized)
                    .font(appSkin.typography.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(appSkin.palette.secondaryText)
                    .padding(.horizontal, appSkin.spacing.heroDescriptionHorizontalInset)
            }

            badges
        }
        .enableInjection()
    }
}

struct VocabTimelineRow<Trailing: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let statusSymbol: AnyView
    let title: String
    let titleTone: Color
    let detail: String?
    let detailTone: Color
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        titleTone: Color,
        detail: String? = nil,
        detailTone: Color,
        @ViewBuilder statusSymbol: () -> some View,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.statusSymbol = AnyView(statusSymbol())
        self.title = title
        self.titleTone = titleTone
        self.detail = detail
        self.detailTone = detailTone
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: appSkin.spacing.timelineRowGap) {
            statusSymbol
                .frame(width: 20)

            VStack(alignment: .leading, spacing: appSkin.spacing.timelineDetailGap) {
                HStack {
                    Text(title.localized)
                        .font(appSkin.typography.body.weight(.medium))
                        .foregroundStyle(titleTone)

                    Spacer()

                    trailing
                }

                if let detail, !detail.isEmpty {
                    Text(detail.localized)
                        .font(appSkin.typography.caption)
                        .foregroundStyle(detailTone)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, appSkin.spacing.sectionGap)
        .enableInjection()
    }
}

struct VocabActionButtonStyle: ButtonStyle {
    @Environment(\.appSkin) private var appSkin
    let tone: VocabActionTone
    /// 按下瞬間的 selection 觸感＋點擊音。會與該動作自己的回饋（例如複習評分的甩出）重複，
    /// 那種動作傳 `false`，只保留視覺按壓縮放（#3127）。
    var pressFeedback: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        let palette = stylePalette

        configuration.label
            .font(appSkin.typography.caption)
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, appSkin.spacing.actionButtonHorizontalPadding)
            .padding(.vertical, appSkin.spacing.actionButtonVerticalPadding)
            .background(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .fill(palette.background)
            )
            .overlay(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .stroke(palette.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(AppMotion.pressFeedback, value: configuration.isPressed)
            .appFeedback(.selection, trigger: configuration.isPressed) { _, newValue in pressFeedback && newValue }
    }

    private var stylePalette: (foreground: Color, background: Color, border: Color) {
        switch tone {
        case .primary:
            return styleFromShared(.primary)
        case .neutral:
            return styleFromShared(.neutral)
        case .success:
            return (
                appSkin.palette.success,
                appSkin.palette.success.opacity(VocabActionButtonPalette.idleFillOpacity),
                appSkin.palette.success.opacity(VocabActionButtonPalette.borderOpacity)
            )
        case .warning:
            let warning = appSkin.palette.warning
            return (
                warning,
                warning.opacity(VocabActionButtonPalette.warningIdleFillOpacity),
                warning.opacity(VocabActionButtonPalette.borderOpacity)
            )
        case .destructive:
            return styleFromShared(.destructive)
        }
    }

    private func styleFromShared(_ tone: AppActionTone) -> (foreground: Color, background: Color, border: Color) {
        switch tone {
        case .primary:
            return (appSkin.palette.pageBackground, appSkin.palette.primaryText, appSkin.palette.primaryText)
        case .neutral:
            return (
                appSkin.palette.primaryText,
                appSkin.palette.cardBackground,
                appSkin.palette.cardBorder
            )
        case .outline:
            return (
                appSkin.palette.primaryText,
                .clear,
                appSkin.palette.secondaryText.opacity(VocabActionButtonPalette.outlineBorderOpacity)
            )
        case .destructive:
            return (
                appSkin.palette.destructive,
                appSkin.palette.destructive.opacity(VocabActionButtonPalette.idleFillOpacity),
                appSkin.palette.destructive.opacity(VocabActionButtonPalette.borderOpacity)
            )
        }
    }
}

private enum VocabActionButtonPalette {
    static let idleFillOpacity: Double = 0.10
    static let warningIdleFillOpacity: Double = 0.12
    static let borderOpacity: Double = 0.22
    static let outlineBorderOpacity: Double = 0.3
}

extension ButtonStyle where Self == VocabActionButtonStyle {
    static func vocabAction(_ tone: VocabActionTone = .primary, pressFeedback: Bool = true) -> VocabActionButtonStyle {
        VocabActionButtonStyle(tone: tone, pressFeedback: pressFeedback)
    }
}
