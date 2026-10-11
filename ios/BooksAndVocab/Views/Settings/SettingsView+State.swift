//
//  SettingsView+State.swift
//  Books & Vocab
//

import SwiftUI

extension SettingsView {
    var userInitials: String? {
        guard let name = authManager.displayName, !name.isEmpty else { return nil }
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1)) + String(parts[1].prefix(1))
        }
        return String(name.prefix(2)).uppercased()
    }

    var authDebugState: SettingsPresenterState.DebugAuthSection? {
#if DEBUG
        SettingsPresenterState.DebugAuthSection(manualLoginHint: L10n.string("手動登入只用於切換測試帳號；Pro 權限請改由 /admin 或 App Store 管理。"))
#else
        nil
#endif
    }

    /// Local count (same source as notebook list) with server fallback for first login.
    var displayCardCount: Int {
        let local = allEntries.count
        if local > 0 { return local }
        return kgService.serverCardCount
    }

    /// Connection + card count only. The last-sync time lives on its own line
    /// (`lastSyncedText`): as a third `·` segment here it never fit the row's
    /// single trailing line and was always the part that got truncated away.
    var syncSummaryText: String {
        if !kgService.isConnected { return "離線".localized }
        var parts: [String] = ["已連線".localized]
        if displayCardCount > 0 {
            parts.append(L10n.format("card_count_plural", Int64(displayCardCount)))
        }
        return parts.joined(separator: " · ")
    }

    /// `nil` until this device completes a sync — the row then simply omits the
    /// line rather than claiming a time it does not have.
    var lastSyncedText: String? {
        guard let lastSync = kgService.lastSyncDate else { return nil }
        return L10n.format("settings.sync.lastSynced", lastSync.formatted(.relative(presentation: .named)))
    }

    var resetBeforeSnapshot: SettingsResetLifecycle.Snapshot {
        coordinator.readResetSnapshot(authManager: authManager, modelContext: modelContext)
    }

    func resetCardLifecycle(fresh: SettingsResetLifecycle.Snapshot) -> SettingsResetLifecycle {
        coordinator.resetLifecycle?.refreshed(with: fresh) ?? .preReset(before: fresh)
    }

    var presenterState: SettingsPresenterState {
        let pro = subscriptionManager.entitlements.pro
        return SettingsPresenterState(
            auth: .init(
                isLoggedIn: authManager.isLoggedIn,
                userInitials: userInitials,
                avatarURL: authManager.avatarURL,
                displayName: authManager.displayName ?? authManager.userEmail ?? L10n.string("已登入"),
                email: authManager.displayName != nil ? authManager.userEmail : nil,
                authError: authManager.authError,
                isAuthenticating: authManager.isAuthenticating,
                iconBreathing: coordinator.iconBreathing,
                debug: authDebugState,
                identityFingerprint: AccountIdentityFingerprint.sha256(authManager.userEmail)
            ),
            preferences: .init(
                selectedLanguage: L10n.string(appLanguage.selection.titleKey),
                selectedAppearance: appearanceStore.selection.titleKey,
                translationSource: coordinator.translationSourceLang.nativeName,
                translationTarget: coordinator.translationTargetLang.nativeName,
                selectedReviewMode: SettingsPresenterState.PreferencesSection.reviewModeDisplayName(
                    for: reviewSettingsStore.settings
                ),
                autoSyncEnabled: autoSyncSettingsStore.isEnabled,
                showAutoSync: authManager.isLoggedIn,
                autoLinkEnabled: autoLinkSettingsStore.isEnabled,
                showAutoLink: authManager.isLoggedIn,
                soundFeedbackEnabled: feedbackSettingsStore.soundFeedbackEnabled,
                hapticFeedbackEnabled: feedbackSettingsStore.hapticFeedbackEnabled
            ),
            kg: authManager.isLoggedIn
                ? .init(
                    serverURL: KGService.getServerURL(),
                    isConnected: kgService.isConnected,
                    connectionPulse: coordinator.connectionPulse,
                    serverCardCount: displayCardCount,
                    lastSyncDescription: kgService.lastSyncDate?.formatted(.relative(presentation: .named)),
                    debug: kgDebugState
                )
                : nil,
            subscription: authManager.isLoggedIn
                ? .init(
                    isActive: pro.is_active,
                    planName: pro.plan_name ?? "Books & Vocab Pro",
                    badgeText: SubscriptionPresentation.badgeText(for: pro),
                    badgeTone: SubscriptionPresentation.badgeTone(for: pro),
                    summary: SubscriptionPresentation.summary(for: pro),
                    detail: SubscriptionPresentation.detail(for: pro, proProduct: subscriptionManager.proProduct),
                    sourceLabel: SubscriptionPresentation.sourceLabel(for: pro),
                    managementNote: SubscriptionPresentation.managementNote(for: pro),
                    pricingUnavailableMessage: SubscriptionPresentation.pricingUnavailableMessage(for: pro, hasStorePrice: subscriptionManager.proProduct?.displayPrice.isEmpty == false),
                    restoreLabel: SubscriptionPresentation.restoreLabel(for: pro),
                    restoreDescription: SubscriptionPresentation.restoreDescription(for: pro),
                    isRestoreAvailable: SubscriptionPresentation.restoreAvailable(for: pro),
                    ctaTitle: SubscriptionPresentation.ctaTitle(for: pro),
                    isRefreshing: subscriptionManager.isLoading
                )
                : nil,
            syncSummary: authManager.isLoggedIn
                ? .init(
                    isConnected: kgService.isConnected,
                    lifecycle: coordinator.syncLifecycle,
                    summaryText: syncSummaryText,
                    lastSyncedText: lastSyncedText,
                    attempt: coordinator.syncAttempt,
                    dataOutcome: coordinator.syncDataOutcome,
                    message: coordinator.syncMessage,
                    evidence: coordinator.syncEvidence
                )
                : nil,
            // 書庫綁 Apple ID 不綁 app 帳號 — 不掛 isLoggedIn gate。
            bookSync: .from(phase: CloudKitMirroringMonitor.shared.phase),
            configurationIssue: coordinator.configurationIssue,
            about: .init(
                version: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-",
                developerName: "陳亮宇" // i18n-allow: 人名
            ),
            danger: authManager.isLoggedIn
                ? .init(
                    isDeletingAccount: coordinator.isDeletingAccount,
                    resetLifecycle: resetCardLifecycle(fresh: resetBeforeSnapshot),
                    currentSnapshot: resetBeforeSnapshot
                )
                : nil
        )
    }

    var presenterActions: SettingsPresenterActions {
        SettingsPresenterActions(
            dismiss: { dismiss() },
            loginWithGoogle: { authManager.loginWithGoogle(modelContainer: modelContext.container) },
            loginWithApple: { authManager.loginWithApple(modelContainer: modelContext.container) },
            logout: { authManager.logout(modelContainer: modelContext.container, reason: "settings_logout") },
            manualLogin: { coordinator.handleManualLogin(authManager: authManager) },
            useProductionBackend: {
                #if DEBUG
                Task {
                    await coordinator.useProductionBackend(authManager: authManager, kgService: kgService)
                }
                #endif
            },
            useLocalBackend: {
                #if DEBUG
                Task {
                    await coordinator.useLocalBackend(authManager: authManager, kgService: kgService)
                }
                #endif
            },
            selectLanguage: { appLanguage.setLanguage($0) },
            selectAppearance: { appearanceStore.setAppearance($0) },
            showSubscriptionPaywall: {
                subscriptionManager.activePaywallSource = .settings
                coordinator.presentSubscriptionPaywall()
            },
            requestDeleteAccount: coordinator.requestDeleteAccount,
            openPrivacyPolicy: { openURL(AppURLs.privacy) },
            openTermsOfService: { openURL(AppURLs.terms) },
            openSupport: { openURL(AppURLs.support) },
            requestAppRating: {
                requestReview()
            },
            resync: {
                Task {
                    await coordinator.resync(authManager: authManager, kgService: kgService, modelContext: modelContext)
                }
            },
            retrySync: {
                Task {
                    await coordinator.resync(authManager: authManager, kgService: kgService, modelContext: modelContext)
                }
            },
            dismissSyncStatus: coordinator.dismissSyncStatus,
            toggleAutoSync: { autoSyncSettingsStore.setEnabled($0) },
            exportVocabularyCSV: {
                switch VocabularyExporter.export(entries: allEntries, format: .csv) {
                case .success(let url):
                    exportURL = url
                case .failure(.empty):
                    toastCoordinator.error(NotebookListCopy.allWordsExportEmpty)
                case .failure(.writeFailed):
                    toastCoordinator.error("匯出失敗".localized)
                }
            },
            toggleAutoLink: { enabled in
                Task {
                    await coordinator.updateAutoLink(
                        enabled: enabled,
                        autoLinkStore: autoLinkSettingsStore,
                        authManager: authManager,
                        kgService: kgService,
                        toastCoordinator: toastCoordinator
                    )
                }
            },
            toggleSoundFeedback: { feedbackSettingsStore.setSoundFeedbackEnabled($0) },
            toggleHapticFeedback: { feedbackSettingsStore.setHapticFeedbackEnabled($0) },
            resetLocalData: {
                Task {
                    await coordinator.resetLocalData(
                        authManager: authManager,
                        kgService: kgService,
                        modelContext: modelContext,
                        acknowledgeUnsyncedLoss: false
                    )
                }
            },
            resetLocalDataDiscardingUnsynced: {
                Task {
                    await coordinator.resetLocalData(
                        authManager: authManager,
                        kgService: kgService,
                        modelContext: modelContext,
                        acknowledgeUnsyncedLoss: true
                    )
                }
            }
        )
    }

    var kgDebugState: SettingsPresenterState.KGSection.DebugSection? {
#if DEBUG
        .init(
            isUsingLocalServer: KGService.getDebugServerMode() == .local,
            localServerURL: coordinator.debugLocalServerURL,
            observation: .init(
                previewLines: coordinator.observationPreviewLines,
                totalCount: coordinator.observationTotalCount
            )
        )
#else
        nil
#endif
    }
}
