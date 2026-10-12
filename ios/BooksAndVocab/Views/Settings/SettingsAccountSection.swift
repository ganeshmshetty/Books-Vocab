import SwiftData
import SwiftUI

/// Logout gate decision (#2745). Logout deletes every local vocabulary row and
/// every review record, so unsynced data must never be discarded without an
/// explicit confirmation.
enum SettingsLogoutGate: Equatable {
    case proceed
    case confirmUnsynced(cards: Int, reviews: Int)
    case confirmUnreadable

    /// A `nil` count means that read failed, so logout must not proceed silently.
    static func decide(unsyncedCards: Int?, unsyncedReviews: Int?) -> SettingsLogoutGate {
        guard let unsyncedCards, let unsyncedReviews else { return .confirmUnreadable }
        if unsyncedCards == 0 && unsyncedReviews == 0 { return .proceed }
        return .confirmUnsynced(cards: unsyncedCards, reviews: unsyncedReviews)
    }

    /// Reads both unsynced counts from the caller's context. A failed read of
    /// either one fails closed to `.confirmUnreadable`.
    static func evaluate(in context: ModelContext) -> SettingsLogoutGate {
        var cards: Int?
        var reviews: Int?
        do {
            cards = try BackgroundSyncActor.unsyncedEntryCount(in: context)
            reviews = try BackgroundSyncActor.unsyncedReviewCount(in: context)
        } catch {
            AppLog.kg.error("Logout gate could not count unsynced local data: \(error.localizedDescription)")
        }
        return decide(unsyncedCards: cards, unsyncedReviews: reviews)
    }
}

struct SettingsAccountSection: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.modelContext) private var modelContext
    /// Pending confirmation (#2745); nil while no prompt is shown.
    @State private var logoutPrompt: SettingsLogoutGate?
    let state: SettingsPresenterState.AuthSection
    let subscription: SettingsPresenterState.SubscriptionSection?
    let manualLoginUserId: Binding<String>?
    let actions: SettingsPresenterActions
    var onShowAccountDetail: (() -> Void)?
    var onShowSubscriptionDetail: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.sectionGap) {
            SettingsSectionHeader(title: SettingsAccountCopy.sectionTitle, icon: "person.crop.circle")

            VStack(spacing: 0) {
                if state.isLoggedIn {
                    loggedInView
                        .transition(.modalSwap)
                        // `.contain` keeps the identifier on the container —
                        // otherwise it propagates onto children and shadows
                        // `settings.account.logoutButton`.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings.account.loggedInView")
                } else {
                    loginView
                        .transition(.modalSwap)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings.account.loginView")
                }
            }
            .settingsCard()
            .overlay {
                if state.isAuthenticating {
                    ZStack {
                        AppRoundedRect(roundness: appSkin.roundness.card)
                            .fill(appSkin.palette.pageBackground.opacity(0.85))
                        VStack(spacing: appSkin.spacing.controlGap) {
                            ProgressView()
                                .controlSize(.regular)
                            Text(SettingsAccountCopy.authenticatingTitle)
                                .font(appSkin.typography.caption)
                                .foregroundStyle(appSkin.palette.secondaryText)
                        }
                    }
                    .transition(.contentSwap)
                }
            }
            .animatePhaseChange(state.isAuthenticating)
            .animation(AppMotion.modalSwapSpring, value: state.isLoggedIn)
        }
        .enableInjection()
    }

    private var loginView: some View {
        VStack(spacing: 0) {
            VStack(spacing: AppSettingsMetrics.accountHeroSpacing) {
                Image("AppIconImage")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    // 這裡原本誤把 spacing token(controlHorizontalPadding = 14pt)當半徑用。
                    // 正解是 app icon 語意：`icon` 0.45 在 64pt 方形得 r = 14.4，與誤用值等價。
                    .clipShape(AppRoundedRect(roundness: appSkin.roundness.icon))
                    .opacity(state.iconBreathing ? 0.85 : 1.0)
                    .animation(AppMotion.breathing, value: state.iconBreathing)

                VStack(spacing: AppSpacing.s1) {
                    Text(SettingsAccountCopy.marketingTitle)
                        .font(appSkin.typography.displayTitle)
                        .foregroundStyle(appSkin.palette.primaryText)
                    Text(SettingsAccountCopy.marketingSubtitle)
                        .font(appSkin.typography.body)
                        .foregroundStyle(appSkin.palette.secondaryText)
                }
            }
            .padding(.vertical, AppSpacing.s6)
            .frame(maxWidth: .infinity)

            SettingsDivider(leadingInset: 0)

            VStack(spacing: AppSettingsMetrics.accountActionSpacing) {
                Button(action: actions.loginWithGoogle) {
                    SettingsAuthButton(title: "以 Google 繼續") {
                        SettingsSocialBadge(kind: .google)
                    }
                }
                .buttonStyle(.pressable)
                .appSettingsButtonChrome()
                .accessibilityLabel(SettingsAccountCopy.googleLoginAccessibility)
                .accessibilityIdentifier("settings.account.googleLoginButton")

                Button(action: actions.loginWithApple) {
                    SettingsAuthButton(title: "以 Apple 繼續") {
                        SettingsSocialBadge(kind: .apple)
                    }
                }
                .buttonStyle(.pressable)
                .appSettingsButtonChrome()
                .accessibilityLabel(SettingsAccountCopy.appleLoginAccessibility)
                .accessibilityIdentifier("settings.account.appleLoginButton")

#if DEBUG
                if let manualLoginUserId, let debug = state.debug {
                    SettingsDivider(leadingInset: 0)
                        .padding(.vertical, AppSpacing.s2)

                    HStack(spacing: AppSpacing.s2) {
                        TextField(SettingsAccountCopy.manualLoginPlaceholder, text: manualLoginUserId)
                            .appSettingsTextInputStyle(alignment: .leading)
                            // Account ID is ASCII-only — force English IME regardless of source lang.
                            .platformSourceLangTextInput(source: .en)

                        SettingsCompactActionButton(
                            title: SettingsAccountCopy.manualLoginTitle,
                            isEnabled: !manualLoginUserId.wrappedValue.isEmpty,
                            action: actions.manualLogin
                        )
                            .accessibilityLabel(SettingsAccountCopy.manualLoginAccessibility)
                    }

                    if let manualLoginHint = debug.manualLoginHint, !manualLoginHint.isEmpty {
                        Text(manualLoginHint)
                            .font(appSkin.typography.caption)
                            .foregroundStyle(appSkin.palette.tertiaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
#endif

                if let error = state.authError {
                    VocabStateMessageCard(
                        title: SettingsAccountCopy.authErrorTitle,
                        systemImage: "exclamationmark.triangle.fill",
                        description: error
                    )
                    .padding(.top, appSkin.spacing.rowMicroGap)
                }
            }
            .padding(.horizontal, AppSpacing.s4)
            .padding(.vertical, AppSpacing.s4)
        }
    }

    private var loggedInView: some View {
        VStack(spacing: 0) {
            // Account info — tappable to show account detail
            accountSummaryRow()

            // Subscription summary row
            if let subscription {
                SettingsDivider(leadingInset: 0)

                subscriptionSummaryRow(subscription)
            }

            SettingsDivider(leadingInset: 0)

            // Logout button
            Button(role: .destructive, action: { requestLogout() }) {
                Text(SettingsAccountCopy.logoutTitle)
                    .font(appSkin.typography.body)
                    .foregroundStyle(appSkin.palette.destructive)
            }
            .buttonStyle(.appAction(.destructive))
            .padding(appSkin.spacing.cardPadding)
            .accessibilityLabel(SettingsAccountCopy.logoutTitle)
            .accessibilityIdentifier("settings.account.logoutButton")
            .confirmationDialog(
                SettingsAccountCopy.unsyncedLogoutTitle,
                isPresented: Binding(
                    get: { logoutPrompt != nil },
                    set: { if !$0 { logoutPrompt = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(SettingsAccountCopy.unsyncedLogoutConfirmTitle, role: .destructive) {
                    actions.logout()
                }
                .accessibilityIdentifier("settings.account.logoutConfirmButton")
                Button(SettingsAccountCopy.unsyncedLogoutCancelTitle, role: .cancel) {}
            } message: {
                Text(logoutPromptMessage)
            }
        }
    }

    /// Logout with no unsynced rows proceeds directly. Otherwise the user must
    /// confirm the discard: logout deletes every local vocabulary row and review
    /// record, so unsynced data must never disappear without an explicit choice (#2745).
    private func requestLogout() {
        let gate = SettingsLogoutGate.evaluate(in: modelContext)
        if gate == .proceed {
            actions.logout()
        } else {
            logoutPrompt = gate
        }
    }

    private var logoutPromptMessage: String {
        if case .confirmUnsynced(let cards, let reviews)? = logoutPrompt {
            return SettingsAccountCopy.unsyncedLogoutMessage(cards: cards, reviews: reviews)
        }
        return SettingsAccountCopy.unsyncedLogoutUnknownMessage
    }

    private func accountSummaryRow() -> some View {
        SettingsCardNavigationRow(
            action: { onShowAccountDetail?() }
        ) {
            SettingsAuthSummary(
                state: state,
                isProActive: subscription?.isActive ?? false
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                state.identityFingerprint.map { "settings.account.identity.\($0)" }
                    ?? "settings.account.identity.unavailable"
            )
        }
        // The action target is a Button (`SettingsCardNavigationRow`), so the
        // identifier must live on that element rather than its nested summary.
        .accessibilityIdentifier("settings.account.accountDetailRow")
    }

    private func subscriptionSummaryRow(_ subscription: SettingsPresenterState.SubscriptionSection) -> some View {
        SettingsCardNavigationRow(
            action: {
                if subscription.isActive {
                    onShowSubscriptionDetail?()
                } else {
                    actions.showSubscriptionPaywall()
                }
            }
        ) {
            HStack(spacing: appSkin.spacing.controlGap) {
                Image(systemName: subscription.isActive
                      ? "checkmark.seal.fill"
                      : "sparkles.rectangle.stack")
                    .font(appSkin.typography.iconMedium)
                    .foregroundStyle(subscription.isActive
                                     ? appSkin.palette.success
                                     : appSkin.palette.accent)

                SettingsTitleSubtitleStack(
                    title: subscriptionRowTitle(for: subscription),
                    subtitle: subscriptionRowSubtitle(for: subscription),
                    titleFont: appSkin.typography.body.weight(.medium),
                    titleColor: appSkin.palette.primaryText,
                    subtitleColor: appSkin.palette.secondaryText,
                    subtitleLineLimit: 2
                )
            }
        } trailing: {
            if subscription.isActive {
                subscriptionBadge(subscription)
            } else {
                SettingsStatusBadge(
                    text: SettingsAccountCopy.upgradeTitle,
                    tone: appSkin.palette.accent
                )
            }
        }
    }

    private func subscriptionBadge(_ sub: SettingsPresenterState.SubscriptionSection) -> some View {
        SettingsStatusBadge(text: sub.badgeText, tone: sub.badgeTone.color(in: appSkin))
    }

    private func subscriptionRowTitle(for subscription: SettingsPresenterState.SubscriptionSection) -> String {
        SettingsAccountCopy.subscriptionRowTitle(
            isActive: subscription.isActive,
            planName: subscription.planName
        )
    }

    private func subscriptionRowSubtitle(for subscription: SettingsPresenterState.SubscriptionSection) -> String {
        if subscription.isActive {
            return subscription.summary.isEmpty ? subscription.detail : subscription.summary
        }
        if let pricingUnavailableMessage = subscription.pricingUnavailableMessage, !pricingUnavailableMessage.isEmpty {
            return pricingUnavailableMessage
        }
        return subscription.summary
    }
}

// MARK: - Pro Badge

struct SettingsProBadge: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin

    var body: some View {
        HStack(spacing: appSkin.spacing.rowMicroGap) {
            Image(systemName: "sparkles")
                .font(appSkin.typography.caption)
            Text(SettingsAccountCopy.proBadgeTitle)
                .font(appSkin.typography.monoLabel)
        }
        .foregroundStyle(appSkin.palette.accent)
        .padding(.horizontal, appSkin.spacing.badgeHorizontalPadding)
        .padding(.vertical, appSkin.spacing.chipVerticalPadding)
        .background(appSkin.palette.accent.opacity(0.12))
        .clipShape(AppRoundedRect(roundness: AppRoundness.pill))
        .accessibilityElement(children: .combine)
        .enableInjection()
    }
}

// MARK: - Private Helpers

enum SettingsSocialKind {
    case google
    case apple
}

struct SettingsSocialBadge: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let kind: SettingsSocialKind

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(
                    width: AppSettingsMetrics.socialBadgeSize,
                    height: AppSettingsMetrics.socialBadgeSize
                )
                .appElevation(elevation)

            Group {
                switch kind {
                case .google:
                    Text("G")
                        .font(appSkin.typography.caption)
                        .foregroundStyle(AppBrandColors.googleRed)
                case .apple:
                    Image(systemName: "apple.logo")
                        .font(appSkin.typography.iconTiny)
                        .foregroundStyle(appSkin.palette.pageBackground)
                }
            }
        }
        .enableInjection()
    }

    private var backgroundColor: Color {
        switch kind {
        case .google:
            return appSkin.palette.cardBackground
        case .apple:
            return AppBrandColors.appleBlack
        }
    }

    private var elevation: AppElevation {
        switch kind {
        case .google:
            return .z1
        case .apple:
            return .z0
        }
    }
}

private struct SettingsAuthButton<Leading: View>: View {
    @Environment(\.appSkin) private var appSkin
    let title: String
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: AppSettingsMetrics.accountButtonSpacing) {
            leading

            Text(L10n.string(title))
                .font(appSkin.typography.body.weight(.medium))

            Spacer()

            SettingsTrailingChevronIcon()
        }
    }
}

struct SettingsAuthSummary: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    let state: SettingsPresenterState.AuthSection
    var isProActive: Bool = false

    var body: some View {
        HStack(spacing: AppSettingsMetrics.accountRowSpacing) {
            avatar

            VStack(alignment: .leading, spacing: appSkin.spacing.rowMicroGap) {
                HStack(spacing: appSkin.spacing.rowMicroGap) {
                    Text(state.displayName)
                        .font(appSkin.typography.sectionTitle)
                        .foregroundStyle(appSkin.palette.primaryText)
                        .lineLimit(1)

                    ZStack {
                        if isProActive {
                            SettingsProBadge()
                                .transition(.modalSwap)
                                .accessibilityLabel(SettingsAccountCopy.proAccessibilityLabel)
                        }
                    }
                    .animation(AppMotion.modalSwapSpring, value: isProActive)
                }

                if let email = state.email, !email.isEmpty {
                    Text(email)
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(appSkin.typography.symbolLarge)
                .foregroundStyle(appSkin.palette.success)
                .symbolEffect(.bounce, value: state.isLoggedIn)
        }
        .enableInjection()
    }

    @ViewBuilder
    private var avatar: some View {
        ZStack {
            Circle()
                .fill(appSkin.palette.mutedFill)
                .frame(
                    width: AppSettingsMetrics.accountAvatarSize,
                    height: AppSettingsMetrics.accountAvatarSize
                )

            if let avatarURL = state.avatarURL {
                AsyncImage(url: avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.fill")
                        .font(appSkin.typography.symbolLarge)
                        .foregroundStyle(appSkin.palette.secondaryText)
                }
                .frame(
                    width: AppSettingsMetrics.accountAvatarSize,
                    height: AppSettingsMetrics.accountAvatarSize
                )
                .clipShape(Circle())
            } else if let initials = state.userInitials {
                Text(initials)
                    .font(appSkin.typography.sectionTitle)
                    .foregroundStyle(appSkin.palette.secondaryText)
            } else {
                Image(systemName: "person.fill")
                    .font(appSkin.typography.symbolLarge)
                    .foregroundStyle(appSkin.palette.secondaryText)
            }
        }
    }
}
