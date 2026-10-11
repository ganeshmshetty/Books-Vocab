//
//  SettingsCoordinatorReviewClockTests.swift
//  Books & Vocab Tests
//
//  Defect A 回歸測試：`SettingsCoordinator.applyServerReviewClock` 套用
//  server pause-clock 時，`paused_at` 若走 strict `AppDateFormatters.iso8601`
//  （要求小數秒）解析，後端回傳不含小數秒的 ISO8601 時戳會靜默解析失敗
//  （`.date(from:)` 回 nil）→ 凍結沒套上，但 config 仍回報 `is_paused=true`
//  （false-green）。修法：改用 `AppDateFormatters.parseISO8601`（含小數秒優先，
//  失敗再 fallback 不含小數秒），對稱寫入側（`SettingsCoordinator.swift:207`
//  `iso8601.string(from:)` 恆產小數秒）。
//
//  走公開路徑 `SettingsCoordinator.loadData` 觸發（`applyServerReviewClock` 為
//  private），對齊 `ReviewSettingsStore.shared` 單例 + `UserDefaults.standard`
//  的既有測試慣例（見 TranslationLanguageDefaultTests 的 snapshot/restore）。
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@Suite(.serialized)
@MainActor
struct SettingsCoordinatorReviewClockTests {

    // MARK: - Mocks

    private final class MockAuth: AuthManaging {
        var isLoggedIn: Bool = true
        var userId: String? = "test_user"
        var token: String? = "test_token"
        var displayName: String?
        var userEmail: String?
        var avatarURL: URL?
        var authError: String?
        var isAuthenticating: Bool = false
        var isDemoMode: Bool = false

        func enterDemoMode(modelContainer: ModelContainer) {}
        func exitDemoMode(modelContainer: ModelContainer) {}
        func refreshSessionIfNeeded() {}
        func login(userId: String, token: String) {}
        func login(customToken: String) async {}
        func logout(modelContainer: ModelContainer?, reason: String) {}
        func logoutAfterAccountDeletion(modelContainer: ModelContainer?, deletedAccountID: String?) {}
        func loginWithGoogle(modelContainer: ModelContainer?) {}
        func loginWithApple(modelContainer: ModelContainer?) {}
    }

    /// `loadData` 只用到 `healthCheck` + `fetchUserConfig`。
    private final class StubKGService: HealthChecking, UserConfigFetching {

        var userConfigToReturn = KGUserConfig(
            translation: nil, review_clock: nil, review_mode: nil, vocab_ui: nil, auto_link: nil
        )

        func healthCheck() async {}
        func fetchUserConfig() async throws -> KGUserConfig { userConfigToReturn }
    }

    private struct DeferredConfigFailure: Error {}

    private actor DeferredFailureGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                startWaiters.append(continuation)
            }
        }

        func waitForRelease() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }

            guard !released else { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private final class DeferredFailureKGService: HealthChecking, UserConfigFetching {
        private let gate = DeferredFailureGate()

        func healthCheck() async {}

        func fetchUserConfig() async throws -> KGUserConfig {
            await gate.waitForRelease()
            throw DeferredConfigFailure()
        }

        func waitUntilStarted() async {
            await gate.waitUntilStarted()
        }

        func release() async {
            await gate.release()
        }
    }

    // MARK: - Helpers

    /// 走 `SettingsCoordinator.loadData` 路徑套用 server pause-clock，驗證
    /// `ReviewSettingsStore.shared` 的三層是否套上，跑完還原原狀避免污染其他測試。
    private func runServerApply(pausedAtISO: String, updatedAt: Double) async -> PauseClockState {
        let store = ReviewSettingsStore.shared
        let originalSnapshot = store.pauseClockSnapshot
        defer { store.restorePauseState(originalSnapshot) }

        // 清掉本地 pause updatedAt，讓 server timestamp 成為可比較的基準。
        UserDefaults.standard.removeObject(forKey: "review_settings_progress_updated_at")

        let coordinator = SettingsCoordinator(translationLifecycle: NoopAccountPreferenceLifecycle())
        let auth = MockAuth()
        let kgService = StubKGService()
        kgService.userConfigToReturn = KGUserConfig(
            translation: nil,
            review_clock: KGReviewClockConfig(is_paused: true, paused_at: pausedAtISO, updated_at: updatedAt),
            review_mode: nil,
            vocab_ui: nil,
            auto_link: nil
        )

        await coordinator.loadData(authManager: auth, kgService: kgService)

        return PauseClockState(
            isPaused: store.settings.isProgressPaused,
            pausedAt: store.settings.progressPausedAt,
            updatedAt: nil
        )
    }

    private func expectedUTCDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        var comps = DateComponents()
        comps.timeZone = TimeZone(identifier: "UTC")
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: comps)!
    }

    // MARK: - Tests

    /// Defect A 案例：後端回傳的 `paused_at` 不含小數秒。修前用 strict formatter
    /// 解析回 nil → `progressPausedAt` 沒套上（凍結靜默失效）。
    @Test func serverAppliesPauseClock_whenPausedAtHasNoFractionalSeconds() async {
        let result = await runServerApply(
            pausedAtISO: "2026-07-09T14:59:59Z",
            updatedAt: 1_800_000_000
        )
        let expected = expectedUTCDate(year: 2026, month: 7, day: 9, hour: 14, minute: 59, second: 59)
        #expect(result.isPaused == true)
        #expect(result.pausedAt == expected)
    }

    @Test func delayedFailureFromPreviousAccountDoesNotSetCurrentAccountIssue() async {
        let auth = MockAuth()
        auth.userId = "account-a"
        let service = DeferredFailureKGService()
        let coordinator = SettingsCoordinator(translationLifecycle: NoopAccountPreferenceLifecycle())

        let task = Task { @MainActor in
            await coordinator.loadData(authManager: auth, kgService: service)
        }
        await service.waitUntilStarted()

        auth.userId = "account-b"
        auth.token = "token-b"
        coordinator.resetForAccountBoundary()
        await service.release()
        await task.value

        #expect(coordinator.configurationIssue == nil)
    }

    /// 對照案例：含小數秒的既有格式仍要正確解析（防迴歸）。
    @Test func serverAppliesPauseClock_whenPausedAtHasFractionalSeconds() async {
        let result = await runServerApply(
            pausedAtISO: "2026-07-09T14:59:59.000Z",
            updatedAt: 1_800_000_001
        )
        let expected = expectedUTCDate(year: 2026, month: 7, day: 9, hour: 14, minute: 59, second: 59)
        #expect(result.isPaused == true)
        #expect(result.pausedAt == expected)
    }

    /// Guest settings must complete the same optimistic local write path as a
    /// signed-in user; only the remote push is skipped. This guards the state
    /// contract consumed by the SettingsReviewSection binding.
    @Test func guestUpdateReviewClockWritesLocalStateBeforeReturning() async {
        let suite = "test.settings-coordinator.review-clock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = ReviewSettingsStore(defaults: defaults, cloud: FakeCloudKVStore())
        let auth = MockAuth()
        auth.isLoggedIn = false

        let result = await SettingsCoordinator(translationLifecycle: NoopAccountPreferenceLifecycle()).updateReviewClock(
            isPaused: true,
            reviewSettingsStore: store,
            authManager: auth,
            kgService: KGService(),
            toastCoordinator: AppToastCoordinator()
        )

        #expect(result == true)
        #expect(store.settings.isProgressPaused == true)
        #expect(store.settings.progressPausedAt != nil)
        #expect(defaults.bool(forKey: "review_settings_progress_paused") == true)
    }

    @Test func serverPauseClockAppliesWhenTimestampIsNewer() {
        let defaults = UserDefaults(suiteName: "test.settings-review-clock-newer.\(UUID().uuidString)")!
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        let pausedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let applied = store.applyServerPauseState(
            isPaused: true,
            pausedAt: pausedAt,
            updatedAt: 200
        )

        #expect(applied)
        #expect(store.settings.isProgressPaused)
        #expect(store.settings.progressPausedAt == pausedAt)
        #expect(defaults.double(forKey: "review_settings_progress_updated_at") == 200)
        #expect(cloud.double(forKey: "review_settings_progress_updated_at") == nil)
    }

    @Test func firstAccountActivationMigratesLegacyReviewPreferencesOnlyOnce() {
        let suite = "test.review-legacy-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let cloud = FakeCloudKVStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let customParams: [String: Double] = [
            "initialIntervalHours": 18,
            "rememberedMultiplier": 2.1,
            "forgotMultiplier": 0.4,
            "minimumIntervalHours": 5,
            "maximumIntervalHours": 1000,
        ]
        let customData = try! JSONSerialization.data(withJSONObject: customParams)
        defaults.set("custom", forKey: "review_settings_mode")
        defaults.set(customData, forKey: "review_settings_custom_params")
        defaults.set(100.0, forKey: "review_settings_mode_updated_at")
        defaults.set(true, forKey: "review_settings_progress_paused")
        defaults.set(1_700_000_000.0, forKey: "review_settings_progress_paused_at")
        defaults.set(101.0, forKey: "review_settings_progress_updated_at")
        defaults.set("fast", forKey: "review_settings_autoplay_speed")
        defaults.set(false, forKey: "review_settings_autoplay_sound_enabled")
        cloud.set("custom", forKey: "review_settings_mode")
        cloud.set(100.0, forKey: "review_settings_mode_updated_at")
        cloud.set(1.0, forKey: "review_settings_progress_paused")
        cloud.set(1_700_000_000.0, forKey: "review_settings_progress_paused_at")
        cloud.set(101.0, forKey: "review_settings_progress_updated_at")

        let accountA = ReviewSettingsStore(defaults: defaults, cloud: cloud, accountID: "account-a")
        #expect(accountA.settings.mode == .custom)
        #expect(accountA.settings.customInitialIntervalHours == 18)
        #expect(accountA.settings.isProgressPaused)
        #expect(accountA.settings.autoplaySpeed == .fast)
        #expect(accountA.settings.autoplaySoundEnabled == false)
        #expect(
            defaults.string(
                forKey: AccountPreferenceNamespace.key("review_settings_mode", accountID: "account-a")
            ) == "custom"
        )

        let accountB = ReviewSettingsStore(defaults: defaults, cloud: cloud, accountID: "account-b")
        #expect(accountB.settings == .default)
        #expect(
            defaults.string(
                forKey: AccountPreferenceNamespace.key("review_settings_mode", accountID: "account-b")
            ) == nil
        )
    }

    @Test func serverPauseClockIgnoredWhenLocalTimestampIsNewer() {
        let defaults = UserDefaults(suiteName: "test.settings-review-clock-local-newer.\(UUID().uuidString)")!
        defaults.set(true, forKey: "review_settings_progress_paused")
        defaults.set(1_700_000_000.0, forKey: "review_settings_progress_paused_at")
        defaults.set(300.0, forKey: "review_settings_progress_updated_at")
        let store = ReviewSettingsStore(defaults: defaults, cloud: FakeCloudKVStore())
        let original = store.pauseClockSnapshot

        let applied = store.applyServerPauseState(
            isPaused: false,
            pausedAt: nil,
            updatedAt: 200
        )

        #expect(!applied)
        #expect(store.pauseClockSnapshot == original)
        #expect(defaults.double(forKey: "review_settings_progress_updated_at") == 300)
    }

    @Test func serverPauseClockAfterAccountSwitchDoesNotWriteSharedCloudState() {
        let defaults = UserDefaults(suiteName: "test.settings-review-clock-account-switch.\(UUID().uuidString)")!
        let cloud = FakeCloudKVStore()
        cloud.set(1.0, forKey: "review_settings_progress_paused")
        cloud.set(1_600_000_000.0, forKey: "review_settings_progress_paused_at")
        cloud.set(100.0, forKey: "review_settings_progress_updated_at")

        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        defaults.removeObject(forKey: "review_settings_progress_paused")
        defaults.removeObject(forKey: "review_settings_progress_paused_at")
        defaults.removeObject(forKey: "review_settings_progress_updated_at")
        let nextAccountStore = ReviewSettingsStore(defaults: defaults, cloud: cloud)

        let applied = nextAccountStore.applyServerPauseState(
            isPaused: false,
            pausedAt: nil,
            updatedAt: 200
        )

        #expect(applied)
        #expect(!nextAccountStore.settings.isProgressPaused)
        #expect(nextAccountStore.settings.progressPausedAt == nil)
        #expect(defaults.double(forKey: "review_settings_progress_updated_at") == 200)
        #expect(cloud.double(forKey: "review_settings_progress_updated_at") == 100)
        _ = store
    }

    private func reviewModeState(
        mode: ReviewSettingsMode,
        initialIntervalHours: Double,
        updatedAt: Double?
    ) -> ReviewModeState {
        ReviewModeState(
            mode: mode,
            customInitialIntervalHours: initialIntervalHours,
            customRememberedMultiplier: 3.0,
            customForgotMultiplier: 0.3,
            customMinimumIntervalHours: 12,
            customMaximumIntervalHours: 2_000,
            updatedAt: updatedAt
        )
    }

    @Test func serverReviewModeAppliesWhenTimestampIsNewer() {
        let defaults = UserDefaults(suiteName: "test.settings-review-mode-newer.\(UUID().uuidString)")!
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        let serverState = reviewModeState(mode: .custom, initialIntervalHours: 48, updatedAt: 200)

        let applied = store.applyServerModeState(serverState)

        #expect(applied)
        #expect(store.settings.mode == .custom)
        #expect(store.settings.customInitialIntervalHours == 48)
        #expect(defaults.string(forKey: "review_settings_mode") == "custom")
        #expect(defaults.double(forKey: "review_settings_mode_updated_at") == 200)
        #expect(cloud.double(forKey: "review_settings_mode_updated_at") == nil)
    }

    @Test func serverReviewModeIgnoredWhenLocalTimestampIsNewer() {
        let defaults = UserDefaults(suiteName: "test.settings-review-mode-local-newer.\(UUID().uuidString)")!
        defaults.set("intensive", forKey: "review_settings_mode")
        defaults.set(
            try! JSONSerialization.data(withJSONObject: [
                "initialIntervalHours": 30.0,
                "rememberedMultiplier": 2.2,
                "forgotMultiplier": 0.4,
                "minimumIntervalHours": 8.0,
                "maximumIntervalHours": 1_500.0,
            ]),
            forKey: "review_settings_custom_params"
        )
        defaults.set(300.0, forKey: "review_settings_mode_updated_at")
        let store = ReviewSettingsStore(defaults: defaults, cloud: FakeCloudKVStore())
        let original = store.reviewModeSnapshot

        let applied = store.applyServerModeState(
            reviewModeState(mode: .relaxed, initialIntervalHours: 7, updatedAt: 200)
        )

        #expect(!applied)
        #expect(store.reviewModeSnapshot == original)
        #expect(defaults.double(forKey: "review_settings_mode_updated_at") == 300)
    }

    @Test func serverReviewModeMergesNewerStateAfterCloudDeviceUpdate() {
        let defaults = UserDefaults(suiteName: "test.settings-review-mode-cloud-merge.\(UUID().uuidString)")!
        let cloud = FakeCloudKVStore()
        cloud.set("relaxed", forKey: "review_settings_mode")
        cloud.set(
            "{\"initialIntervalHours\":12,\"rememberedMultiplier\":1.9,\"forgotMultiplier\":0.45,\"minimumIntervalHours\":6,\"maximumIntervalHours\":1440}",
            forKey: "review_settings_custom_params"
        )
        cloud.set(100.0, forKey: "review_settings_mode_updated_at")
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)

        let applied = store.applyServerModeState(
            reviewModeState(mode: .custom, initialIntervalHours: 48, updatedAt: 200)
        )

        #expect(applied)
        #expect(store.settings.mode == .custom)
        #expect(store.settings.customInitialIntervalHours == 48)
        #expect(store.settings.customMaximumIntervalHours == 2_000)
        #expect(cloud.string(forKey: "review_settings_mode") == "relaxed")
        #expect(cloud.double(forKey: "review_settings_mode_updated_at") == 100)
    }

    @Test func restoringUnwrittenPauseClockClearsStaleCloudPayload() {
        let defaults = UserDefaults(suiteName: "test.settings-review-clock-restore-empty.\(UUID().uuidString)")!
        let cloud = FakeCloudKVStore()
        cloud.set(1.0, forKey: "review_settings_progress_paused")
        cloud.set(1_600_000_000.0, forKey: "review_settings_progress_paused_at")
        cloud.set(100.0, forKey: "review_settings_progress_updated_at")

        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        store.restorePauseState(PauseClockState(isPaused: false, pausedAt: nil, updatedAt: nil))

        let rebuilt = ReviewSettingsStore(defaults: defaults, cloud: cloud)

        #expect(!rebuilt.settings.isProgressPaused)
        #expect(rebuilt.settings.progressPausedAt == nil)
        #expect(cloud.double(forKey: "review_settings_progress_paused") == 0)
        #expect(cloud.double(forKey: "review_settings_progress_paused_at") == 0)
        #expect(cloud.double(forKey: "review_settings_progress_updated_at") == 0)
    }

    @Test func restoringUnwrittenReviewModeClearsStaleCloudPayload() {
        let suite = "test.settings-review-mode-restore-empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = FakeCloudKVStore()
        cloud.set("intensive", forKey: "review_settings_mode")
        cloud.set(
            "{\"initialIntervalHours\":30,\"rememberedMultiplier\":2.2,\"forgotMultiplier\":0.4,\"minimumIntervalHours\":8,\"maximumIntervalHours\":1500}",
            forKey: "review_settings_custom_params"
        )
        cloud.set(100.0, forKey: "review_settings_mode_updated_at")

        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        let baseline = ReviewSettings.default
        store.restoreModeState(
            ReviewModeState(
                mode: baseline.mode,
                customInitialIntervalHours: baseline.customInitialIntervalHours,
                customRememberedMultiplier: baseline.customRememberedMultiplier,
                customForgotMultiplier: baseline.customForgotMultiplier,
                customMinimumIntervalHours: baseline.customMinimumIntervalHours,
                customMaximumIntervalHours: baseline.customMaximumIntervalHours,
                updatedAt: nil
            )
        )

        let rebuilt = ReviewSettingsStore(defaults: defaults, cloud: cloud)

        #expect(rebuilt.settings.mode == .relaxed)
        #expect(rebuilt.settings.customInitialIntervalHours == baseline.customInitialIntervalHours)
        #expect(rebuilt.settings.customRememberedMultiplier == baseline.customRememberedMultiplier)
        #expect(rebuilt.settings.customForgotMultiplier == baseline.customForgotMultiplier)
        #expect(rebuilt.settings.customMinimumIntervalHours == baseline.customMinimumIntervalHours)
        #expect(rebuilt.settings.customMaximumIntervalHours == baseline.customMaximumIntervalHours)
        #expect(cloud.string(forKey: "review_settings_mode") == "relaxed")
        #expect(cloud.double(forKey: "review_settings_mode_updated_at") == 0)
    }

    @Test func accountScopedReviewSettingsDoNotCrossReadOrWrite() {
        let suite = "test.settings-review-account-scope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let cloud = FakeCloudKVStore()

        let accountA = ReviewSettingsStore(defaults: defaults, cloud: cloud, accountID: "account-a")
        var settingsA = accountA.settings
        settingsA.mode = .intensive
        settingsA.isProgressPaused = true
        settingsA.progressPausedAt = Date(timeIntervalSince1970: 1_700_000_000)
        accountA.update(settingsA)

        let accountB = ReviewSettingsStore(defaults: defaults, cloud: cloud, accountID: "account-b")
        #expect(accountB.settings == ReviewSettings.default)

        var settingsB = accountB.settings
        settingsB.mode = .custom
        settingsB.customInitialIntervalHours = 48
        accountB.update(settingsB)

        let restoredA = ReviewSettingsStore(defaults: defaults, cloud: cloud, accountID: "account-a")
        #expect(restoredA.settings.mode == .intensive)
        #expect(restoredA.settings.isProgressPaused)
        #expect(restoredA.settings.progressPausedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(restoredA.settings.customInitialIntervalHours == ReviewSettings.default.customInitialIntervalHours)
    }
}
