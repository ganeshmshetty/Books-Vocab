import Foundation
import SwiftData

/// Boundary for the state that the Settings reset lifecycle renders.
///
/// The reset service owns cleanup mutations, while this port owns observing
/// the stores that prove what was left before and after that mutation. Keeping
/// the two seams separate lets unit tests model partial cleanup without
/// replacing SwiftData or UserDefaults with presentation constants.
@MainActor
protocol SettingsResetStorePort: AnyObject {
    func readSnapshot(
        authManager: any AuthManaging,
        modelContext: ModelContext
    ) -> SettingsResetLifecycle.Snapshot
    func resetPreferences()
    /// Push the default review/auto-link configs so the server and other
    /// devices converge with the local reset instead of out-voting it later.
    func pushDefaultPreferences(to configService: any UserConfigServing) async throws
}

@MainActor
final class LiveSettingsResetStore: SettingsResetStorePort {
    func readSnapshot(
        authManager: any AuthManaging,
        modelContext: ModelContext
    ) -> SettingsResetLifecycle.Snapshot {
        do {
            // Same knowledge-list criterion as the Settings card count and CSV export (#3812, #3673).
            let descriptor = FetchDescriptor<VocabularyEntry>(predicate: VocabularyEntry.knowledgeListPredicate())
            let localCardCount = try modelContext.fetch(descriptor).count
            // Every row reset deletes that the server has not confirmed:
            // pending (0) or failed (2), including queued deletes/archives.
            // Unsynced notebooks (reset deletes them too) are not counted; the
            // warning copy is card- and review-denominated.
            let unsyncedCardCount = try modelContext.fetchCount(
                FetchDescriptor<VocabularyEntry>(predicate: #Predicate { $0.syncStatus != 1 })
            )
            // Reset also deletes every ReviewRecord; events not yet acknowledged
            // by the server (`pushedAt == nil`) would be lost for good.
            let unsyncedReviewCount = try modelContext.fetchCount(
                FetchDescriptor<ReviewRecord>(predicate: #Predicate { $0.pushedAt == nil })
            )
            return .init(
                localCardCount: localCardCount,
                unsyncedCardCount: unsyncedCardCount,
                unsyncedReviewCount: unsyncedReviewCount,
                hasCustomPreferences: hasCustomPreferences,
                isLoggedIn: authManager.isLoggedIn
            )
        } catch {
            AppLog.kg.error("Settings reset snapshot could not read local cards: \(error.localizedDescription)")
            return .init(
                unreadableLocalCardCount: error.localizedDescription,
                hasCustomPreferences: hasCustomPreferences,
                isLoggedIn: authManager.isLoggedIn
            )
        }
    }

    func resetPreferences() {
        ReviewSettingsStore.shared.update(.default)
        TranslationLanguage.currentSource = .en
        TranslationLanguage.currentTarget = .zhHant
        // A root language refresh would destroy the active Settings
        // navigation before the terminal reset state can be observed.
        AppLanguageStore.shared.setLanguage(.system, preservingRootPresentation: true)
        AppAppearanceStore.shared.setAppearance(.system)
        AutoSyncSettingsStore.shared.setEnabled(false)
        AutoLinkSettingsStore.shared.setEnabled(true)
        FeedbackSettingsStore.shared.setSoundFeedbackEnabled(false)
        FeedbackSettingsStore.shared.setHapticFeedbackEnabled(true)
    }

    /// Stamps every server-synced config (review, clock, auto-link, translation) with one fresh `updated_at` so the defaults win LWW
    /// on the server and on the user's other devices.
    static func pushDefaultPreferences(to configService: any UserConfigServing) async throws {
        let stamp = Date().timeIntervalSince1970
        let defaults = ReviewSettings.default
        _ = try await configService.updateReviewModeConfig(
            KGReviewModeConfig(
                mode: defaults.mode.rawValue,
                custom_initial_interval_hours: defaults.customInitialIntervalHours,
                custom_remembered_multiplier: defaults.customRememberedMultiplier,
                custom_forgot_multiplier: defaults.customForgotMultiplier,
                custom_minimum_interval_hours: defaults.customMinimumIntervalHours,
                custom_maximum_interval_hours: defaults.customMaximumIntervalHours,
                updated_at: stamp
            )
        )
        _ = try await configService.updateReviewClockConfig(
            KGReviewClockConfig(is_paused: false, paused_at: nil, updated_at: stamp)
        )
        _ = try await configService.updateAutoLinkConfig(
            KGAutoLinkConfig(enabled: true, updated_at: stamp)
        )
        _ = try await configService.updateTranslationConfig(
            KGTranslationConfig(
                source_lang: TranslationLanguage.en.rawValue,
                target_lang: TranslationLanguage.zhHant.rawValue,
                updated_at: stamp
            )
        )
    }

    func pushDefaultPreferences(to configService: any UserConfigServing) async throws {
#if DEBUG
        // UI-test worlds have no reachable config server; the push itself is
        // covered by unit tests, so the reset-lifecycle UI flow opts out.
        if ProcessInfo.processInfo.environment["KG_UI_TEST_SETTINGS_RESET_SKIP_CONFIG_PUSH"] == "1" { return }
#endif
        try await Self.pushDefaultPreferences(to: configService)
    }

    private var hasCustomPreferences: Bool {
        let review = ReviewSettingsStore.shared.settings
        let defaults = ReviewSettings.default
        return !AppLanguageStore.shared.isAtDefaultSelection
            || AppAppearanceStore.shared.selection != .system
            || TranslationLanguage.currentSource != .en
            || TranslationLanguage.currentTarget != .zhHant
            || review.mode != defaults.mode
            || review.customInitialIntervalHours != defaults.customInitialIntervalHours
            || review.customRememberedMultiplier != defaults.customRememberedMultiplier
            || review.customForgotMultiplier != defaults.customForgotMultiplier
            || review.customMinimumIntervalHours != defaults.customMinimumIntervalHours
            || review.customMaximumIntervalHours != defaults.customMaximumIntervalHours
            || review.isProgressPaused != defaults.isProgressPaused
            || review.autoplaySpeed != defaults.autoplaySpeed
            || review.autoplaySoundEnabled != defaults.autoplaySoundEnabled
            || AutoSyncSettingsStore.shared.isEnabled
            || !AutoLinkSettingsStore.shared.isEnabled
            || FeedbackSettingsStore.shared.soundFeedbackEnabled
            || !FeedbackSettingsStore.shared.hapticFeedbackEnabled
    }
}
