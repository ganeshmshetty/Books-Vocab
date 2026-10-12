import SwiftUI

enum VocabActionTone {
    case primary
    case neutral
    case success
    case warning
    case destructive
}

typealias VocabTabOption<ID: Hashable> = AppTabOption<ID>

struct VocabTabSelector<ID: Hashable>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let options: [VocabTabOption<ID>]
    @Binding var selection: ID

    var body: some View {
        AppTabSelector(
            options: options,
            selection: $selection,
            style: .vocab(appSkin)
        )
        .enableInjection()
    }
}

struct VocabFilterChipBar<ID: Hashable>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let options: [VocabTabOption<ID>]
    @Binding var selection: Set<ID>

    var body: some View {
        AppFilterChipBar(
            options: options,
            selection: $selection,
            style: .vocab(appSkin)
        )
        .enableInjection()
    }
}

/// Semantic library controls for p11.
///
/// The review-state filter uses the same three-column pill grid as the report,
/// with counts from the shared projection and explicit query mutation at the
/// button boundary. A native Picker
/// hid the interaction contract from UI tests and made the layout diverge
/// from the report, so these controls are rendered as buttons.
struct VocabLibraryFilterBar: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin

    let reviewOptions: [VocabTabOption<VocabularyReviewState>]
    @Binding var query: VocabularyLibraryQuery
    let visibleCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.rowMicroGap) {
            filterGrid(
                options: reviewOptions,
                isSelected: { query.reviewStates.contains($0) },
                identifierPrefix: "vocab.filter.reviewState",
                identifier: { $0.rawValue }
            ) { option in
                query.toggleReviewState(option)
            }

            if !query.reviewStates.isEmpty {
                Button {
                    query.setReviewState(nil)
                } label: {
                    Label(L10n.string("explore.noResults.clear"), systemImage: "xmark.circle")
                }
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("vocab.filter.reviewState.clear")
            }

            // Facet counts are scope-wide; this is the post-search visible-row
            // count. Keeping it separate prevents a search from changing the
            // counts rendered in the report-style pills.
            Text(L10n.format("%@ 張", "\(visibleCount)"))
                .font(appSkin.typography.monoLabel)
                .monospacedDigit()
                .foregroundStyle(appSkin.palette.quaternaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("vocab.filter.visibleCount")
                .accessibilityLabel(L10n.format("%@ 張", "\(visibleCount)"))
        }
        .enableInjection()
    }

    @ViewBuilder
    private func filterGrid<ID: RawRepresentable & Hashable>(
        options: [VocabTabOption<ID>],
        isSelected: @escaping (ID) -> Bool,
        identifierPrefix: String,
        identifier: @escaping (ID) -> String,
        action: @escaping (ID) -> Void
    ) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: appSkin.spacing.inlineGap),
            count: 3
        )
        LazyVGrid(columns: columns, spacing: appSkin.spacing.inlineGap) {
            ForEach(options) { option in
                let selected = isSelected(option.id)
                Button {
                    withAnimation(AppMotion.chipSelect) {
                        action(option.id)
                    }
                } label: {
                    appChipLabel(
                        option: option,
                        isSelected: selected,
                        style: .vocab(appSkin)
                    )
                }
                .buttonStyle(.plain)
                .appPointerHover()
                .accessibilityIdentifier("\(identifierPrefix).\(identifier(option.id))")
                .accessibilityLabel(appChipAccessibilityLabel(option: option))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct VocabSearchField: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Binding var text: String
    let prompt: String
    var isFocused: FocusState<Bool>.Binding? = nil
    var accessibilityID: String = ""

    var body: some View {
        AppSearchField(
            text: $text,
            prompt: prompt,
            style: .vocab(appSkin),
            isFocused: isFocused,
            accessibilityID: accessibilityID
        )
        .enableInjection()
    }
}

struct VocabToolbarGlyph: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let systemImage: String
    let badge: String?
    let tone: Color?

    init(systemImage: String, badge: String? = nil, tone: Color? = nil) {
        self.systemImage = systemImage
        self.badge = badge
        self.tone = tone
    }

    var body: some View {
        AppToolbarGlyph(
            systemImage: systemImage,
            badge: badge,
            style: .vocab(appSkin, tone: tone)
        )
        .enableInjection()
    }
}

struct VocabChromeIconButton: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let systemImage: String
    var tone: Color? = nil
    var label: String? = nil
    var identifier: String? = nil
    /// Glyph only: no surface and no stroke. The 44pt touch box is unchanged (#3112).
    var borderless: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // Group 包住 if/else：否則 `.frame` 與 `.contentShape` 換行後會被 result builder
            // 當成獨立語句解析，swiftc 報 "cannot infer contextual base"（編譯失敗）。
            Group {
                if borderless {
                    Image(systemName: systemImage)
                        .font(appSkin.typography.iconSmall)
                        .foregroundStyle(tone ?? appSkin.palette.tertiaryText)
                } else {
                    VocabChromeSurface(
                        fill: appSkin.palette.cardBackground,
                        border: appSkin.palette.cardBorder
                    ) {
                        Image(systemName: systemImage)
                            .font(appSkin.typography.iconMedium)
                            .foregroundStyle(tone ?? appSkin.palette.secondaryText)
                            .frame(width: appSkin.metrics.chromeButtonSize, height: appSkin.metrics.chromeButtonSize)
                    }
                }
            }
            // 視覺維持 32pt（VocabChromeSurface），僅外擴觸控目標到 HIG 44pt 下限。
            // contentShape 確保整個 44pt 區域可點，但不撐大版面佔位（frame minWidth/minHeight 不放大視覺）。
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appPointerHover()
        .accessibilityLabel(label ?? systemImage)
        .accessibilityIdentifier(identifier ?? "")
        .enableInjection()
    }
}

struct VocabChromeSurface<Content: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let fill: Color
    let border: Color
    let content: Content

    init(
        fill: Color? = nil,
        border: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.fill = fill ?? .clear
        self.border = border ?? .clear
        self.content = content()
    }

    var body: some View {
        content
            .background(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .fill(fill)
            )
            .overlay(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .stroke(border, lineWidth: 1)
            )
            .enableInjection()
    }
}

struct VocabOverlayHeader<LeadingAccessory: View, TrailingAccessory: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let title: String
    let systemImage: String
    var badgeText: String? = nil
    let onClose: () -> Void
    @ViewBuilder let leadingAccessory: LeadingAccessory
    @ViewBuilder let trailingAccessory: TrailingAccessory

    init(
        title: String,
        systemImage: String,
        badgeText: String? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder trailing trailingAccessory: () -> TrailingAccessory = { EmptyView() },
        @ViewBuilder leadingAccessory: () -> LeadingAccessory = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.badgeText = badgeText
        self.onClose = onClose
        self.trailingAccessory = trailingAccessory()
        self.leadingAccessory = leadingAccessory()
    }

    var body: some View {
        HStack(spacing: appSkin.metrics.sectionHeaderGap) {
            leadingAccessory

            Label(title.localized, systemImage: systemImage)
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.tertiaryText)

            if let badgeText {
                Text(badgeText)
                    .font(appSkin.typography.monoLabel)
                    .foregroundStyle(appSkin.palette.quaternaryText)
                    .padding(.horizontal, appSkin.spacing.compactChipHorizontalPadding)
                    .padding(.vertical, appSkin.spacing.compactChipVerticalPadding)
                    .background(
                        AppRoundedRect(roundness: AppRoundness.pill)
                            .fill(appSkin.palette.mutedFill)
                    )
            }

            Spacer()

            trailingAccessory

            VocabChromeIconButton(systemImage: "xmark", label: L10n.string("a11y.action.close"), action: onClose)
        }
        .padding(.horizontal, appSkin.metrics.overlayHeaderHorizontalInset)
        .padding(.vertical, appSkin.metrics.overlayHeaderVerticalInset)
        .enableInjection()
    }
}
