//
//  ReviewSettingsStoreModeSnapshotTests.swift
//  Books & Vocab Tests
//
//  Spec for review-mode 後端化 Phase A3: mode snapshot / restore / server cold-start.
//  Complements ReviewModeSyncTests (LWW + init + update) without overlap.
//  Shares FakeCloudKVStore from ReviewClockSyncTests.
//

import Foundation
import Testing
@testable import BooksAndVocab

@MainActor
struct ReviewSettingsStoreModeSnapshotTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "test.reviewmode.snapshot.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - reviewModeSnapshot

    @Test func snapshotCapturesCurrentModeAndCustomParams() {
        let defaults = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        var s = store.settings
        s.mode = .custom
        s.customInitialIntervalHours = 48
        s.customRememberedMultiplier = 3.0
        store.update(s)

        let snapshot = store.reviewModeSnapshot
        #expect(snapshot.mode == .custom)
        #expect(snapshot.customInitialIntervalHours == 48)
        #expect(snapshot.customRememberedMultiplier == 3.0)
    }

    @Test func snapshotIncludesLocalUpdatedAt() {
        let defaults = makeDefaults()
        defaults.set("intensive", forKey: "review_settings_mode")
        defaults.set(500.0, forKey: "review_settings_mode_updated_at")
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)

        let snapshot = store.reviewModeSnapshot
        #expect(snapshot.updatedAt == 500)
    }

    // MARK: - restoreModeState

    @Test func restoreModeStateRevertsAllLayers() {
        let defaults = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        var s = store.settings
        s.mode = .intensive
        store.update(s)

        let snapshot = ReviewModeState(
            mode: .relaxed,
            customInitialIntervalHours: 24,
            customRememberedMultiplier: 2.5,
            customForgotMultiplier: 0.5,
            customMinimumIntervalHours: 6,
            customMaximumIntervalHours: 1440,
            updatedAt: 100
        )
        store.restoreModeState(snapshot)

        #expect(store.settings.mode == .relaxed)
        #expect(store.settings.customInitialIntervalHours == 24)
        #expect(cloud.string(forKey: "review_settings_mode") == "relaxed")
        #expect(cloud.double(forKey: "review_settings_mode_updated_at") == 100)
        #expect(defaults.object(forKey: "review_settings_mode_updated_at") as? Double == 100)
    }

    @Test func restoreModeStateNilSnapshotClearsTimestampWithSentinel() {
        let defaults = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        var s = store.settings
        s.mode = .intensive
        store.update(s)

        let snapshot = ReviewModeState(
            mode: .relaxed,
            customInitialIntervalHours: ReviewSettings.default.customInitialIntervalHours,
            customRememberedMultiplier: ReviewSettings.default.customRememberedMultiplier,
            customForgotMultiplier: ReviewSettings.default.customForgotMultiplier,
            customMinimumIntervalHours: ReviewSettings.default.customMinimumIntervalHours,
            customMaximumIntervalHours: ReviewSettings.default.customMaximumIntervalHours,
            updatedAt: nil
        )
        store.restoreModeState(snapshot)

        #expect(store.settings.mode == .relaxed)
        #expect(defaults.object(forKey: "review_settings_mode_updated_at") == nil)
        #expect(cloud.double(forKey: "review_settings_mode_updated_at") == 0.0)
    }

    // MARK: - applyServerModeState

    @Test func applyServerModeStateColdStartNoCloudWriteback() {
        let defaults = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)

        let serverState = ReviewModeState(
            mode: .custom,
            customInitialIntervalHours: 48,
            customRememberedMultiplier: 3.0,
            customForgotMultiplier: 0.3,
            customMinimumIntervalHours: 12,
            customMaximumIntervalHours: 2000,
            updatedAt: 300
        )
        store.applyServerModeState(serverState)

        #expect(store.settings.mode == .custom)
        #expect(store.settings.customInitialIntervalHours == 48)
        #expect(store.settings.customMaximumIntervalHours == 2000)
        #expect(defaults.object(forKey: "review_settings_mode_updated_at") as? Double == 300)
        // cold-start 不回寫 iCloud
        #expect(cloud.double(forKey: "review_settings_mode_updated_at") == nil)
        #expect(cloud.string(forKey: "review_settings_mode") == nil)
    }

    /// #3172: the review-settings migration must publish its adoption marker to iCloud KVS and
    /// check it. Device X adopts the legacy cloud mode for account A; never-adopted device Y must
    /// not copy that legacy mode into account B (its settings must equal a fresh default store).
    @Test func unadoptedDeviceDoesNotReAdoptLegacyReviewModeAdoptedElsewhere() {
        let cloud = FakeCloudKVStore()
        let marker = AccountPreferenceNamespace.legacyMigrationMarker(feature: "review-settings")
        cloud.set("intensive", forKey: "review_settings_mode")
        cloud.set(100.0, forKey: "review_settings_mode_updated_at")

        let adopting = ReviewSettingsStore(defaults: makeDefaults(), cloud: cloud, accountID: "account-a")
        #expect(adopting.settings.mode == .intensive)
        #expect(cloud.string(forKey: marker) != nil)

        let accountBOnY = ReviewSettingsStore(defaults: makeDefaults(), cloud: cloud, accountID: "account-b")
        let fresh = ReviewSettingsStore(defaults: makeDefaults(), cloud: FakeCloudKVStore(), accountID: "account-b")
        #expect(accountBOnY.settings == fresh.settings)
    }
}
