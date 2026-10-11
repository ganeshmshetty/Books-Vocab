import SwiftUI

// MARK: - Navigation Rows, Card Navigation, Buttons, Subscription Components, Selection

struct SettingsNavigationRow<Trailing: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let icon: String
    let label: String
    let action: () -> Void
    let accessibilityIdentifier: String?
    let trailing: Trailing

    init(
        icon: String,
        label: String,
        action: @escaping () -> Void,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.label = label
        self.action = action
        self.accessibilityIdentifier = accessibilityIdentifier
        self.trailing = trailing()
    }

    @ViewBuilder
    var body: some View {
        if let accessibilityIdentifier {
            rowButton.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            rowButton
        }
    }

    private var rowButton: some View {
        Button(action: action) {
            AppKeyValueRow(icon: icon, label: label, style: .settings(appSkin)) {
                HStack(spacing: 6) {
                    trailing
                    SettingsTrailingChevronIcon()
                }
            }
            .appHoverRowTint()
            // .plain button hit-testing falls through transparent pixels, so
            // without an explicit shape only the label/value text is tappable
            // and the whole middle of the row (the Spacer gap) is dead.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .enableInjection()
    }
}

struct SettingsCardNavigationRow<Leading: View, Trailing: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let action: () -> Void
    let leading: Leading
    let trailing: Trailing

    init(
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.action = action
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: appSkin.spacing.controlGap) {
                leading

                Spacer(minLength: appSkin.spacing.inlineGap)

                trailing

                SettingsTrailingChevronIcon()
            }
            .padding(.horizontal, appSkin.spacing.cardPadding)
            .padding(.vertical, appSkin.spacing.actionButtonVerticalPadding)
            .appHoverRowTint()
            // Same dead-middle-of-the-row hole as SettingsNavigationRow.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .enableInjection()
    }
}

struct SettingsActionRowLabel<Trailing: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let title: String
    let systemImage: String
    let isLoading: Bool
    let trailing: Trailing

    init(
        title: String,
        systemImage: String,
        isLoading: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { SettingsTrailingChevronIcon() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: appSkin.spacing.controlGap) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(appSkin.typography.iconMedium)
            }

            Text(title)
                .font(appSkin.typography.body.weight(.medium))

            Spacer()

            trailing
        }
        .foregroundStyle(appSkin.palette.primaryText)
        .padding(.horizontal, appSkin.spacing.cardPadding)
        .padding(.vertical, appSkin.spacing.actionButtonVerticalPadding)
        .frame(minHeight: 50)
        .enableInjection()
    }
}

struct SettingsCompactActionButton: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let title: String
    let action: () -> Void
    let isEnabled: Bool

    init(title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        self.isEnabled = isEnabled
    }

    var body: some View {
        Button(title, action: action)
            .font(appSkin.typography.caption)
            .foregroundStyle(isEnabled ? appSkin.palette.primaryText : appSkin.palette.quaternaryText)
            .padding(.horizontal, AppSpacing.s3)
            .padding(.vertical, appSkin.spacing.rowPadding)
            .background(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .fill(appSkin.palette.pageBackground)
            )
            .overlay(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .stroke(appSkin.palette.cardBorder, lineWidth: 1)
            )
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .enableInjection()
    }
}

extension SubscriptionBadgeTone {
    func color(in skin: AppSkin) -> Color {
        switch self {
        case .neutral:
            skin.palette.secondaryText
        case .accent:
            skin.palette.accent
        case .success:
            skin.palette.success
        }
    }
}

struct SettingsFeaturePanel<Content: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let borderTone: Color
    let content: Content

    init(borderTone: Color, @ViewBuilder content: () -> Content) {
        self.borderTone = borderTone
        self.content = content()
    }

    var body: some View {
        content
            .padding(appSkin.spacing.cardPadding)
            .background(appSkin.palette.cardBackground)
            .clipShape(AppRoundedRect(roundness: appSkin.roundness.card))
            .overlay(
                AppRoundedRect(roundness: appSkin.roundness.card)
                    .stroke(borderTone, lineWidth: 1)
            )
            .enableInjection()
    }
}

struct SettingsSubscriptionInfoBlock: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let title: String
    let subtitle: String?
    let detail: String?
    let titleFont: Font

    init(title: String, subtitle: String? = nil, detail: String? = nil, titleFont: Font) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.titleFont = titleFont
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.rowMicroGap) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(appSkin.palette.primaryText)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.secondaryText)
                    .lineSpacing(3)
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.tertiaryText)
                    .lineSpacing(3)
            }
        }
        .enableInjection()
    }
}

struct SettingsSubscriptionFeatureItem: Identifiable {
    let title: String
    let description: String?
    let icon: String
    let tone: Color

    var id: String { title }
}

/// Paywall Free vs Pro 對照表的單行資料
struct SettingsPlanComparisonRow: Identifiable {
    enum Mark: Equatable {
        case check
        case cross
        case label(String)
    }

    let title: String
    let freeMark: Mark
    let proMark: Mark

    var id: String { title }
}

/// Paywall 用 Free vs Pro 功能對照表
///
/// 用途：取代「只列 Pro 有什麼」的單欄 bullet list，直接呈現兩欄差異，
/// 提升決策資訊密度（業界做法：Notion / Linear / Cursor 訂閱頁）。
struct SettingsPlanComparisonTable: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let rows: [SettingsPlanComparisonRow]

    var body: some View {
        SettingsFeaturePanel(borderTone: appSkin.palette.cardBorder) {
            VStack(spacing: 0) {
                headerRow

                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Rectangle()
                        .fill(appSkin.palette.divider.opacity(0.5))
                        .frame(height: 1)
                        .padding(.vertical, appSkin.spacing.rowMicroGap)

                    comparisonRow(row, isLast: index == rows.count - 1)
                }
            }
        }
        .enableInjection()
    }

    private var headerRow: some View {
        HStack(spacing: appSkin.spacing.controlGap) {
            Text(L10n.string("功能"))
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(L10n.string("Free"))
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)
                .frame(minWidth: 52, alignment: .center)

            Text("Pro")
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.accent)
                .frame(minWidth: 52, alignment: .center)
        }
    }

    private func comparisonRow(_ row: SettingsPlanComparisonRow, isLast _: Bool) -> some View {
        HStack(spacing: appSkin.spacing.controlGap) {
            Text(row.title)
                .font(appSkin.typography.body)
                .foregroundStyle(appSkin.palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            markView(row.freeMark, isProColumn: false)
                .frame(minWidth: 52, alignment: .center)

            markView(row.proMark, isProColumn: true)
                .frame(minWidth: 52, alignment: .center)
        }
    }

    @ViewBuilder
    private func markView(_ mark: SettingsPlanComparisonRow.Mark, isProColumn: Bool) -> some View {
        switch mark {
        case .check:
            Image(systemName: "checkmark.circle.fill")
                .font(appSkin.typography.iconMedium)
                .foregroundStyle(isProColumn ? appSkin.palette.accent : appSkin.palette.success)
        case .cross:
            Image(systemName: "minus")
                .font(appSkin.typography.iconMedium)
                .foregroundStyle(appSkin.palette.quaternaryText)
        case .label(let text):
            Text(text)
                .font(appSkin.typography.caption)
                .foregroundStyle(isProColumn ? appSkin.palette.accent : appSkin.palette.secondaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
        }
    }
}

struct SettingsSubscriptionFeatureList: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let borderTone: Color
    let items: [SettingsSubscriptionFeatureItem]

    var body: some View {
        SettingsFeaturePanel(borderTone: borderTone) {
            VStack(alignment: .leading, spacing: appSkin.spacing.rowContentSpacing) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: appSkin.spacing.controlGap) {
                        Image(systemName: item.icon)
                            .font(appSkin.typography.iconMedium)
                            .foregroundStyle(item.tone)

                        VStack(alignment: .leading, spacing: AppSpacing.microGap) {
                            Text(item.title)
                                .font(item.description == nil ? appSkin.typography.body : appSkin.typography.body.weight(.medium))
                                .foregroundStyle(appSkin.palette.primaryText)

                            if let description = item.description {
                                Text(description)
                                    .font(appSkin.typography.caption)
                                    .foregroundStyle(appSkin.palette.tertiaryText)
                            }
                        }

                        Spacer()
                    }
                }
            }
        }
        .enableInjection()
    }
}

struct SettingsSelectableRow<Leading: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let isSelected: Bool
    let leading: Leading

    init(isSelected: Bool, @ViewBuilder leading: () -> Leading) {
        self.isSelected = isSelected
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: appSkin.spacing.inlineGap) {
            leading

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(appSkin.typography.iconSmall)
                    .foregroundStyle(appSkin.palette.accent)
            }
        }
        .padding(.horizontal, appSkin.spacing.cardPadding)
        .padding(.vertical, appSkin.spacing.rowPadding)
        .contentShape(Rectangle())
        .background(isSelected ? appSkin.palette.accent.opacity(0.08) : Color.clear)
        .enableInjection()
    }
}

/// 選中／未選的方塊式選項 —— repo 內**唯一**一份（APP-20260808-f0770b）。
/// reader 側原本的同構實作 `ReaderSelectionTile` 已併入本型別：選取填色、描邊、
/// 前景色與 `.isSelected` trait 都只寫在這裡，padding 由具名密度表達、不開放自由值。
///
/// 不含 row 型的選擇：`SettingsSelectableRow`（accent 8% 底 + 右側 checkmark）
/// 是另一種語意，刻意不合併。
struct SettingsSelectionTile<Content: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let isSelected: Bool
    let density: Density
    let content: Content

    /// 只開放兩個具名密度，不開放自由 padding —— 合併前兩份實作的差異就出在
    /// padding 責任歸屬，重新開放等於把裂縫留著。
    enum Density {
        case standard
        case compact

        var verticalPadding: CGFloat {
            switch self {
            case .standard: AppSettingsMetrics.selectionTileVerticalPaddingStandard
            case .compact: AppSettingsMetrics.selectionTileVerticalPaddingCompact
            }
        }
    }

    init(isSelected: Bool, density: Density = .standard, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.density = density
        self.content = content()
    }

    var body: some View {
        content
            .foregroundStyle(isSelected ? appSkin.palette.primaryText : appSkin.palette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSettingsMetrics.selectionTileHorizontalPadding)
            .padding(.vertical, density.verticalPadding)
            .background(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .fill(isSelected ? appSkin.palette.mutedFill : appSkin.palette.pageBackground)
            )
            .overlay(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .stroke(
                        isSelected
                            ? appSkin.palette.cardBorder
                            : appSkin.palette.divider.opacity(AppSettingsMetrics.selectionTileUnselectedBorderOpacity),
                        lineWidth: 1
                    )
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .enableInjection()
    }
}
