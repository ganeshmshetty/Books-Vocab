import Foundation
import SwiftUI
import Testing
@testable import BooksAndVocab

@MainActor
struct ReviewCardLayoutProfileTests {
    @Test func fieldsAreExactlyTheSixOptionalReviewSections() {
        #expect(ReviewCardField.allCases == [
            .partOfSpeech,
            .difficultyTier,
            .example,
            .explanation,
            .collocations,
            .graphLinks,
        ])
    }

    @Test func defaultsMatchTheExistingRecognitionAndProductionCards() {
        let profile = ReviewCardLayoutProfile.default

        #expect(profile.recognition == .standard)
        #expect(profile.production == .standard)
        #expect(profile.layout(for: .recognition).front == [.partOfSpeech])
        #expect(profile.layout(for: .production).front == [.partOfSpeech, .example])
        #expect(profile.layout(for: .recognition).back == [
            .difficultyTier, .graphLinks, .example, .explanation, .collocations,
        ])
        #expect(profile.layout(for: .production).back == [
            .difficultyTier, .graphLinks, .example, .explanation, .collocations,
        ])
    }

    @Test func compactDropsExampleExplanationAndCollocations() {
        for mode in VocabularyCardMode.allCases {
            let layout = ReviewCardLayoutPreset.compact.layout(for: mode)
            #expect(layout.front == [.partOfSpeech])
            #expect(layout.back == [.difficultyTier, .graphLinks])
        }
    }

    /// 搬遷：舊形狀（自由欄位陣列）必須映到最接近的 preset，而不是靜靜變成預設。
    @Test func legacyFieldArraysMigrateToTheClosestPreset() throws {
        let json = """
        {
          "recognition": {
            "front": ["partOfSpeech"],
            "back": ["difficultyTier", "graphLinks", "example", "explanation", "collocations"]
          },
          "production": {
            "front": ["unknown", "partOfSpeech"],
            "back": ["graphLinks", "futureField", "difficultyTier"]
          }
        }
        """

        let decoded = try JSONDecoder().decode(
            ReviewCardLayoutProfile.self,
            from: Data(json.utf8)
        )

        // 逐字等於舊 default 的那一面 → 正常。
        #expect(decoded.recognition == .standard)
        // 只剩難度 + 知識連結（unknown rawValue 丟掉）→ 精簡。
        #expect(decoded.production == .compact)
    }

    /// 缺的那一面沿用 standard 的同一面後再比距離；空陣列離 standard 更近時取
    /// standard（平手也取 standard）—— 這裡的期望值是照 closest 的規則算出來的，
    /// 不是憑感覺寫的：production 空正面對 standard 差 2、對 compact 差 1，
    /// back 缺席補成 standard 的 back 後對 standard 差 0、對 compact 差 3 →
    /// standard 總距離 2 < compact 總距離 4。
    @Test func missingSidesFallBackToStandardBeforeMeasuringDistance() throws {
        let json = """
        {
          "recognition": {},
          "production": { "front": [] }
        }
        """

        let decoded = try JSONDecoder().decode(
            ReviewCardLayoutProfile.self,
            from: Data(json.utf8)
        )

        #expect(decoded.recognition == .standard)
        #expect(decoded.production == .standard)
    }

    @Test func presetsRoundTripThroughTheNewShape() throws {
        let profile = ReviewCardLayoutProfile(recognition: .compact, production: .standard)
        let data = try JSONEncoder().encode(profile)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"recognition\":\"compact\""))
        #expect(try JSONDecoder().decode(ReviewCardLayoutProfile.self, from: data) == profile)
    }
}

@MainActor
struct ReviewCardLayoutStoreTests {
    private let key = "review_card_layout_profile_v1"
    private let maximumSupportedUnixTimestamp: TimeInterval = 253_402_300_800
    private let maximumLegacyUnixTimestamp: TimeInterval =
        253_402_300_800 - (366 * 24 * 60 * 60)
    private let maximumV2UnixTimestamp: TimeInterval =
        253_402_300_800 - (24 * 60 * 60)

    private func makeDefaults() -> UserDefaults {
        let suite = "test.review-card-layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func encodedEnvelope(
        profile: ReviewCardLayoutProfile,
        updatedAt: TimeInterval,
        version: Int = 1
    ) throws -> String {
        let object: [String: Any] = [
            "version": version,
            "updatedAt": updatedAt,
            "profile": try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(profile)
            ),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    /// 非預設 profile。舊 helper 以「哪個欄位開著」區分兩份 profile；新模型只有
    /// 三個非預設值（兩個方向 × 兩個 preset，扣掉 default），所以把六個欄位攤到
    /// 那三個值上。分配是**刻意排過的**：每一個「local vs remote / before vs after」
    /// 的配對都落在不同的值上，否則 LWW 測試會變成兩邊相等的空斷言。
    private func customProfile(_ field: ReviewCardField) -> ReviewCardLayoutProfile {
        switch field {
        case .example, .collocations:
            ReviewCardLayoutProfile(recognition: .compact, production: .standard)
        case .graphLinks, .difficultyTier:
            ReviewCardLayoutProfile(recognition: .standard, production: .compact)
        case .explanation, .partOfSpeech:
            ReviewCardLayoutProfile(recognition: .compact, production: .compact)
        }
    }

    @Test func cloudNewerWinsWithoutColdStartWriteback() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let local = customProfile(.example)
        let remote = customProfile(.graphLinks)
        defaults.set(try encodedEnvelope(profile: local, updatedAt: 100), forKey: key)
        cloud.values[key] = try encodedEnvelope(profile: remote, updatedAt: 200)

        let store = ReviewCardLayoutStore(defaults: defaults, cloud: cloud)

        #expect(store.profile == remote)
        #expect(cloud.setCalls.isEmpty)
        let originalLocalEnvelope = try encodedEnvelope(profile: local, updatedAt: 100)
        #expect(defaults.string(forKey: key) == originalLocalEnvelope)
    }

    @Test func localNewerWins() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let local = customProfile(.explanation)
        let remote = customProfile(.collocations)
        defaults.set(try encodedEnvelope(profile: local, updatedAt: 300), forKey: key)
        cloud.values[key] = try encodedEnvelope(profile: remote, updatedAt: 200)

        let store = ReviewCardLayoutStore(defaults: defaults, cloud: cloud)

        #expect(store.profile == local)
        #expect(cloud.setCalls.isEmpty)
    }

    @Test func timestampTieGoesToCloud() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let local = customProfile(.difficultyTier)
        let remote = customProfile(.partOfSpeech)
        defaults.set(try encodedEnvelope(profile: local, updatedAt: 500), forKey: key)
        cloud.values[key] = try encodedEnvelope(profile: remote, updatedAt: 500)

        let store = ReviewCardLayoutStore(defaults: defaults, cloud: cloud)

        #expect(store.profile == remote)
    }

    @Test func corruptAndUnknownVersionsFallBackWithoutStartupOverwrite() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        defaults.set("not-json", forKey: key)
        cloud.values[key] = try encodedEnvelope(
            profile: customProfile(.example),
            updatedAt: 100,
            version: 99
        )

        let store = ReviewCardLayoutStore(defaults: defaults, cloud: cloud)

        #expect(store.profile == .default)
        #expect(defaults.string(forKey: key) == "not-json")
        #expect(cloud.setCalls.isEmpty)
    }

    @Test func greatestFiniteCloudTimestampFallsBackThenUpdateRepairsBothLayers() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        cloud.values[key] = try encodedEnvelope(
            profile: customProfile(.graphLinks),
            updatedAt: .greatestFiniteMagnitude
        )
        let store = ReviewCardLayoutStore(
            defaults: defaults,
            cloud: cloud,
            now: { Date(timeIntervalSince1970: 800) }
        )

        #expect(store.profile == .default)

        let changed = customProfile(.explanation)
        store.update(changed)

        let localJSON = try #require(defaults.string(forKey: key))
        #expect(cloud.values[key] == localJSON)
        #expect(store.profile == changed)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(localJSON.utf8)) as? [String: Any]
        )
        let timestamp = try #require(object["updatedAt"] as? Double)
        #expect(timestamp.isFinite)
        #expect(timestamp >= 0)
        #expect(timestamp < maximumSupportedUnixTimestamp)
    }

    @Test func invalidCloudTimestampDoesNotBeatValidLocalAndResetRepairsBothLayers() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let local = customProfile(.collocations)
        defaults.set(try encodedEnvelope(profile: local, updatedAt: 600), forKey: key)
        cloud.values[key] = try encodedEnvelope(
            profile: customProfile(.graphLinks),
            updatedAt: .greatestFiniteMagnitude
        )
        let store = ReviewCardLayoutStore(
            defaults: defaults,
            cloud: cloud,
            now: { Date(timeIntervalSince1970: 700) }
        )

        #expect(store.profile == local)

        store.resetAll()

        let localJSON = try #require(defaults.string(forKey: key))
        #expect(cloud.values[key] == localJSON)
        #expect(store.profile == .default)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(localJSON.utf8)) as? [String: Any]
        )
        let timestamp = try #require(object["updatedAt"] as? Double)
        #expect(timestamp.isFinite)
        #expect(timestamp < maximumSupportedUnixTimestamp)
    }

    @Test func v2ExtremeCloudTimestampFallsBackThenUpdateRepairsBothLayers() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        cloud.values[key] = try encodedEnvelope(
            profile: customProfile(.graphLinks),
            updatedAt: maximumSupportedUnixTimestamp.nextDown,
            version: 2
        )
        let store = ReviewCardLayoutStore(
            defaults: defaults,
            cloud: cloud,
            now: { Date(timeIntervalSince1970: 850) }
        )

        #expect(store.profile == .default)

        let changed = customProfile(.explanation)
        store.update(changed)

        let localJSON = try #require(defaults.string(forKey: key))
        #expect(cloud.values[key] == localJSON)
        #expect(store.profile == changed)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(localJSON.utf8)) as? [String: Any]
        )
        let timestamp = try #require(object["updatedAt"] as? Double)
        #expect(object["version"] as? Int == 2)
        #expect(timestamp.isFinite)
        #expect(timestamp == 850)
        #expect(timestamp < maximumV2UnixTimestamp)
    }

    @Test func negativeTimestampIsCorruptAndDoesNotOverwriteOnStartup() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let invalidEnvelope = try encodedEnvelope(
            profile: customProfile(.difficultyTier),
            updatedAt: -1
        )
        cloud.values[key] = invalidEnvelope

        let store = ReviewCardLayoutStore(defaults: defaults, cloud: cloud)

        #expect(store.profile == .default)
        #expect(defaults.string(forKey: key) == nil)
        #expect(cloud.values[key] == invalidEnvelope)
        #expect(cloud.setCalls.isEmpty)
    }

    @Test func unsupportedEdgeTimestampCannotOverwriteRepairWhenCloudReplaysIt() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let center = NotificationCenter()
        let edgeTimestamp = maximumSupportedUnixTimestamp.nextDown.nextDown
        let edgeEnvelope = try encodedEnvelope(
            profile: customProfile(.example),
            updatedAt: edgeTimestamp
        )
        cloud.values[key] = edgeEnvelope
        let store = ReviewCardLayoutStore(
            defaults: defaults,
            cloud: cloud,
            now: { Date(timeIntervalSince1970: 900) },
            notificationCenter: center,
            cloudNotificationObject: nil
        )
        #expect(store.profile == .default)

        let changed = customProfile(.partOfSpeech)
        store.update(changed)

        let localJSON = try #require(defaults.string(forKey: key))
        #expect(cloud.values[key] == localJSON)
        #expect(store.profile == changed)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(localJSON.utf8)) as? [String: Any]
        )
        #expect(object["updatedAt"] as? Double == 900)

        cloud.values[key] = edgeEnvelope
        center.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: [key]]
        )

        #expect(store.profile == changed)
        #expect(defaults.string(forKey: key) == localJSON)
    }

    @Test func supportedNearCeilingBumpsRemainMonotonicAndReloadable() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let nearCeiling = maximumLegacyUnixTimestamp.nextDown
        cloud.values[key] = try encodedEnvelope(
            profile: customProfile(.example),
            updatedAt: nearCeiling
        )
        let store = ReviewCardLayoutStore(
            defaults: defaults,
            cloud: cloud,
            now: { Date(timeIntervalSince1970: 900) }
        )
        #expect(store.profile == customProfile(.example))

        let changed = customProfile(.partOfSpeech)
        store.update(changed)

        let localJSON = try #require(defaults.string(forKey: key))
        #expect(cloud.values[key] == localJSON)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(localJSON.utf8)) as? [String: Any]
        )
        let repairedTimestamp = try #require(object["updatedAt"] as? Double)
        #expect(object["version"] as? Int == 2)
        #expect(repairedTimestamp > nearCeiling)
        #expect(repairedTimestamp == maximumLegacyUnixTimestamp)
        #expect(repairedTimestamp < maximumSupportedUnixTimestamp)

        let reloaded = ReviewCardLayoutStore(
            defaults: defaults,
            cloud: cloud,
            now: { Date(timeIntervalSince1970: 900) }
        )
        #expect(reloaded.profile == changed)

        let changedAgain = customProfile(.difficultyTier)
        reloaded.update(changedAgain)

        let twiceUpdatedJSON = try #require(defaults.string(forKey: key))
        #expect(cloud.values[key] == twiceUpdatedJSON)
        let twiceUpdatedObject = try #require(
            JSONSerialization.jsonObject(with: Data(twiceUpdatedJSON.utf8)) as? [String: Any]
        )
        let twiceUpdatedTimestamp = try #require(twiceUpdatedObject["updatedAt"] as? Double)
        #expect(twiceUpdatedObject["version"] as? Int == 2)
        #expect(twiceUpdatedTimestamp > repairedTimestamp)
        #expect(twiceUpdatedTimestamp < maximumSupportedUnixTimestamp)

        let reloadedAgain = ReviewCardLayoutStore(
            defaults: defaults,
            cloud: cloud,
            now: { Date(timeIntervalSince1970: 900) }
        )
        #expect(reloadedAgain.profile == changedAgain)
    }

    @Test func updateWritesOneIdenticalVersionedEnvelopeToEachLayer() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let store = ReviewCardLayoutStore(
            defaults: defaults,
            cloud: cloud,
            now: { Date(timeIntervalSince1970: 700) }
        )
        let changed = customProfile(.collocations)

        store.update(changed)

        let localJSON = try #require(defaults.string(forKey: key))
        #expect(cloud.setCalls == [key])
        #expect(cloud.values[key] == localJSON)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(localJSON.utf8)) as? [String: Any]
        )
        #expect(object["version"] as? Int == 2)
        #expect(object["updatedAt"] as? Double == 700)
        #expect(object["profile"] != nil)
    }

    @Test func externalCloudUpdateAppliesOnlyWhenItWinsLWW() throws {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let center = NotificationCenter()
        let initial = customProfile(.example)
        let newer = customProfile(.graphLinks)
        defaults.set(try encodedEnvelope(profile: initial, updatedAt: 100), forKey: key)
        let store = ReviewCardLayoutStore(
            defaults: defaults,
            cloud: cloud,
            notificationCenter: center,
            cloudNotificationObject: nil
        )

        cloud.values[key] = try encodedEnvelope(profile: newer, updatedAt: 200)
        center.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: [key]]
        )
        #expect(store.profile == newer)

        cloud.values[key] = try encodedEnvelope(profile: initial, updatedAt: 150)
        center.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: [NSUbiquitousKeyValueStoreChangedKeysKey: [key]]
        )
        #expect(store.profile == newer)
    }

    @Test func setPresetTouchesOnlyOneDirectionThenResetAllRestoresEverything() {
        let store = ReviewCardLayoutStore.inMemory(profile: customProfile(.explanation))
        let originalProduction = store.profile.production

        store.setPreset(.standard, for: .recognition)

        #expect(store.profile.recognition == .standard)
        #expect(store.profile.production == originalProduction)
        #expect(store.profile != .default)

        store.resetAll()
        #expect(store.profile == .default)
    }

    @Test func inMemoryStoreMutatesWithoutPersistence() {
        let changed = customProfile(.difficultyTier)
        let store = ReviewCardLayoutStore.inMemory()

        store.update(changed)

        #expect(store.profile == changed)
    }

    @Test func environmentValuesSupportsStoreInjection() {
        let store = ReviewCardLayoutStore.inMemory(profile: customProfile(.graphLinks))
        var values = EnvironmentValues()

        values.reviewCardLayoutStore = store

        #expect(values.reviewCardLayoutStore === store)
    }
}

private final class ReviewCardLayoutCloudSpy: CloudKeyValueStore {
    var values: [String: String] = [:]
    var setCalls: [String] = []
    var removedKeys: [String] = []

    func double(forKey key: String) -> Double? { nil }
    func set(_ value: Double, forKey key: String) {}
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) {
        values[key] = value
        setCalls.append(key)
    }
    func removeObject(forKey key: String) {
        values[key] = nil
        removedKeys.append(key)
    }
    func allKeys() -> [String] { Array(values.keys) }
}

@MainActor
struct ReviewCardLayoutStoreAccountScopeTests {
    private let rawKey = ReviewCardLayoutStore.storageKey

    private func makeDefaults() -> UserDefaults {
        let suite = "test.review-card-layout-account.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(
        _ defaults: UserDefaults,
        _ cloud: ReviewCardLayoutCloudSpy
    ) -> ReviewCardLayoutStore {
        ReviewCardLayoutStore(defaults: defaults, cloud: cloud, notificationCenter: NotificationCenter())
    }

    @Test func accountBStartsWithDefaultAndAccountARestoresOwnLayout() {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let store = makeStore(defaults, cloud)
        let custom = ReviewCardLayoutProfile(recognition: .compact, production: .compact)

        store.activateAccount("account-a")
        store.update(custom)
        #expect(defaults.string(forKey: rawKey) == nil)
        #expect(cloud.values[rawKey] == nil)

        store.suspendForAccountBoundary()
        #expect(store.profile == .default)
        store.activateAccount("account-b")
        #expect(store.profile == .default)

        store.activateAccount("account-a")
        #expect(store.profile == custom)
    }

    @Test func suspendedStoreIgnoresWritesAndKeepsRawLocalKey() {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let store = makeStore(defaults, cloud)
        store.update(ReviewCardLayoutProfile(recognition: .compact, production: .standard))
        #expect(defaults.string(forKey: rawKey) != nil)

        store.suspendForAccountBoundary()
        #expect(defaults.string(forKey: rawKey) != nil)
        let writes = cloud.setCalls.count
        store.update(ReviewCardLayoutProfile(recognition: .compact, production: .compact))
        #expect(cloud.setCalls.count == writes)
        #expect(store.profile == .default)
    }

    @Test func legacyRawLayoutMigratesOnceIntoFirstAccountOnly() {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let legacy = makeStore(defaults, cloud)
        let custom = ReviewCardLayoutProfile(recognition: .standard, production: .compact)
        legacy.update(custom)

        let store = makeStore(defaults, cloud)
        store.activateAccount("account-a")
        #expect(store.profile == custom)
        store.activateAccount("account-b")
        #expect(store.profile == .default)
    }

    @Test func suspendBeforeActivationStillMigratesLegacyRawLayout() {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let custom = ReviewCardLayoutProfile(recognition: .compact, production: .standard)
        makeStore(defaults, cloud).update(custom)

        let store = makeStore(defaults, cloud)
        store.suspendForAccountBoundary()
        #expect(store.profile == .default)
        store.activateAccount("account-a")
        #expect(store.profile == custom)
        store.activateAccount("account-b")
        #expect(store.profile == .default)
    }

    /// #2434: sign-out must drop the adopted pre-account raw layout from both
    /// UserDefaults and the iCloud KVS copy, while the account's own namespaced
    /// layout survives so re-login still restores it.
    @Test func signOutCleanupRemovesAdoptedRawLayoutFromDefaultsAndKVS() {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        let custom = ReviewCardLayoutProfile(recognition: .standard, production: .compact)
        makeStore(defaults, cloud).update(custom)

        let store = makeStore(defaults, cloud)
        store.activateAccount("account-a")
        #expect(store.profile == custom)
        #expect(defaults.string(forKey: rawKey) != nil)
        #expect(cloud.values[rawKey] != nil)

        ReviewCardLayoutStore.purgeAdoptedLegacyRawLayout(defaults: defaults, cloud: cloud)

        #expect(defaults.string(forKey: rawKey) == nil)
        #expect(cloud.values[rawKey] == nil)
        #expect(cloud.removedKeys.contains(rawKey))

        store.activateAccount("account-a")
        #expect(store.profile == custom)
    }

    /// Until legacy migration has adopted the raw layout, it is the only copy
    /// of the pre-account data and must survive a cleanup.
    @Test func signOutCleanupKeepsUnadoptedRawLayout() {
        let defaults = makeDefaults()
        let cloud = ReviewCardLayoutCloudSpy()
        makeStore(defaults, cloud).update(ReviewCardLayoutProfile(recognition: .compact, production: .standard))

        ReviewCardLayoutStore.purgeAdoptedLegacyRawLayout(defaults: defaults, cloud: cloud)

        #expect(defaults.string(forKey: rawKey) != nil)
        #expect(cloud.values[rawKey] != nil)
        #expect(cloud.removedKeys.isEmpty)
    }

    @Test func coordinatorForwardsToSharedLayoutStore() {
        let store = makeStore(makeDefaults(), ReviewCardLayoutCloudSpy())
        let coordinator = AccountPreferenceLifecycleCoordinator(layoutStore: store)
        coordinator.suspend()
        #expect(store.isAccountBoundarySuspended)
        coordinator.activate(accountID: nil)
        #expect(!store.isAccountBoundarySuspended)
    }
}
