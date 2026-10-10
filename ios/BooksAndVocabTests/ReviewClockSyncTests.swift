//
//  ReviewClockSyncTests.swift
//  Books & Vocab Tests
//
//  Spec for pause-clock 後端化 Phase 2: pause review clock 從純 UserDefaults
//  升級為三層(UserDefaults + iCloud KVS + 單一 updated_at LWW)。is_paused 與
//  paused_at 為複合原子狀態,共用一個 updated_at 時戳 → 跨裝置整組收斂。
//

import Foundation
import Testing
@testable import BooksAndVocab

/// LWW 決議純函數:取 updatedAt 較新的整組 (isPaused, pausedAt)。
/// 純函數,不碰 KVS,涵蓋四象限 + 雙 nil fallback。
@MainActor
struct ReviewClockLWWTests {

    @Test func cloudNewerWins() {
        let local = PauseClockState(isPaused: false, pausedAt: nil, updatedAt: 100)
        let cloud = PauseClockState(isPaused: true, pausedAt: Date(timeIntervalSince1970: 5), updatedAt: 200)
        #expect(ReviewClockLWW.resolve(local: local, cloud: cloud) == cloud)
    }

    @Test func localNewerWins() {
        let local = PauseClockState(isPaused: true, pausedAt: Date(timeIntervalSince1970: 5), updatedAt: 300)
        let cloud = PauseClockState(isPaused: false, pausedAt: nil, updatedAt: 200)
        #expect(ReviewClockLWW.resolve(local: local, cloud: cloud) == local)
    }

    @Test func onlyCloudHasTimestamp() {
        let local = PauseClockState(isPaused: false, pausedAt: nil, updatedAt: nil)
        let cloud = PauseClockState(isPaused: true, pausedAt: Date(timeIntervalSince1970: 5), updatedAt: 50)
        #expect(ReviewClockLWW.resolve(local: local, cloud: cloud) == cloud)
    }

    @Test func onlyLocalHasTimestamp() {
        let local = PauseClockState(isPaused: true, pausedAt: Date(timeIntervalSince1970: 5), updatedAt: 50)
        let cloud = PauseClockState(isPaused: false, pausedAt: nil, updatedAt: nil)
        #expect(ReviewClockLWW.resolve(local: local, cloud: cloud) == local)
    }

    @Test func bothNilFallsBackToLocal() {
        let local = PauseClockState(isPaused: false, pausedAt: nil, updatedAt: nil)
        let cloud = PauseClockState(isPaused: true, pausedAt: Date(timeIntervalSince1970: 5), updatedAt: nil)
        #expect(ReviewClockLWW.resolve(local: local, cloud: cloud) == local)
    }
}

/// dict-backed fake，注入 ReviewSettingsStore 取代真 NSUbiquitousKeyValueStore。
@MainActor
final class FakeCloudKVStore: CloudKeyValueStore {
    private var doubles: [String: Double] = [:]
    private var strings: [String: String] = [:]
    func double(forKey key: String) -> Double? { doubles[key] }
    func set(_ value: Double, forKey key: String) { doubles[key] = value }
    func string(forKey key: String) -> String? { strings[key] }
    func set(_ value: String, forKey key: String) { strings[key] = value }
    func removeObject(forKey key: String) {
        doubles[key] = nil
        strings[key] = nil
    }
    func allKeys() -> [String] { Array(doubles.keys) + Array(strings.keys) }
}

@MainActor
struct ReviewSettingsStorePauseSyncTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "test.reviewclock.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func pauseWritesAllThreeLayers() {
        let defaults = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        var s = store.settings
        s.pauseProgress(at: Date(timeIntervalSince1970: 1000))
        store.update(s)
        // iCloud KVS 三鍵都寫入
        #expect(cloud.double(forKey: "review_settings_progress_paused") == 1.0)
        #expect(cloud.double(forKey: "review_settings_progress_paused_at") == 1000)
        #expect(cloud.double(forKey: "review_settings_progress_updated_at") != nil)
        // 本地 LWW 時戳也推進
        #expect(defaults.object(forKey: "review_settings_progress_updated_at") != nil)
    }

    @Test func resumeSetsPausedFalseAcrossLayers() {
        let defaults = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        var s = store.settings
        s.pauseProgress(at: Date(timeIntervalSince1970: 1000)); store.update(s)
        s.resumeProgress(); store.update(s)
        #expect(cloud.double(forKey: "review_settings_progress_paused") == 0.0)
        #expect(store.settings.isProgressPaused == false)
    }

    @Test func initAppliesCloudWhenCloudTimestampNewer() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "review_settings_progress_paused")
        defaults.set(100.0, forKey: "review_settings_progress_updated_at")
        let cloud = FakeCloudKVStore()
        cloud.set(1.0, forKey: "review_settings_progress_paused")
        cloud.set(2000.0, forKey: "review_settings_progress_paused_at")
        cloud.set(200.0, forKey: "review_settings_progress_updated_at")   // cloud 較新
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        #expect(store.settings.isProgressPaused == true)
        #expect(store.settings.progressPausedAt == Date(timeIntervalSince1970: 2000))
    }

    @Test func initKeepsLocalWhenLocalTimestampNewer() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "review_settings_progress_paused")
        defaults.set(3000.0, forKey: "review_settings_progress_paused_at")
        defaults.set(500.0, forKey: "review_settings_progress_updated_at")   // local 較新
        let cloud = FakeCloudKVStore()
        cloud.set(0.0, forKey: "review_settings_progress_paused")
        cloud.set(200.0, forKey: "review_settings_progress_updated_at")
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        #expect(store.settings.isProgressPaused == true)
        #expect(store.settings.progressPausedAt == Date(timeIntervalSince1970: 3000))
    }

    @Test func restorePauseStateRevertsAllLayers() {
        let defaults = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        var s = store.settings
        s.pauseProgress(at: Date(timeIntervalSince1970: 1000)); store.update(s)
        // rollback 到「resume + 舊時戳 50」
        store.restorePauseState(PauseClockState(isPaused: false, pausedAt: nil, updatedAt: 50))
        #expect(store.settings.isProgressPaused == false)
        #expect(cloud.double(forKey: "review_settings_progress_paused") == 0.0)
        #expect(cloud.double(forKey: "review_settings_progress_updated_at") == 50)
        #expect(defaults.object(forKey: "review_settings_progress_updated_at") as? Double == 50)
    }

    @Test func applyServerPauseStateColdStartNoCloudWriteback() {
        let defaults = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        store.applyServerPauseState(isPaused: true, pausedAt: Date(timeIntervalSince1970: 2000), updatedAt: 300)
        #expect(store.settings.isProgressPaused == true)
        #expect(store.settings.progressPausedAt == Date(timeIntervalSince1970: 2000))
        #expect(defaults.object(forKey: "review_settings_progress_updated_at") as? Double == 300)
        // cold-start 不回寫 iCloud
        #expect(cloud.double(forKey: "review_settings_progress_updated_at") == nil)
    }

    @Test func restorePauseStateNilSnapshotClearsTimestampWithSentinel() {
        let defaults = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ReviewSettingsStore(defaults: defaults, cloud: cloud)
        var s = store.settings
        s.pauseProgress(at: Date(timeIntervalSince1970: 1000)); store.update(s)
        // rollback 到「從未寫過」(updatedAt=nil):清本地時戳 + cloud 寫 0 sentinel,
        // 讓他裝置的真寫(ts>0)經 LWW 勝出。
        store.restorePauseState(PauseClockState(isPaused: false, pausedAt: nil, updatedAt: nil))
        #expect(store.settings.isProgressPaused == false)
        #expect(defaults.object(forKey: "review_settings_progress_updated_at") == nil)
        #expect(cloud.double(forKey: "review_settings_progress_updated_at") == 0.0)
    }
}
