import Foundation
import Observation
import SwiftUI

/// Optional content blocks that can be arranged around the review card's core
/// prompt and answer. The core prompt/answer are mode semantics and deliberately
/// do not participate in this persisted layout profile.
enum ReviewCardField: String, CaseIterable, Codable, Hashable, Sendable {
    case partOfSpeech
    case difficultyTier
    case example
    case explanation
    case collocations
    case graphLinks

    /// The single agreed row order — prompt/answer, then metadata, links, example,
    /// explanation, collocations. The editor lists rows in it and the card renders
    /// in it, so a face read in the editor is the face drawn on the card.
    static let canonicalOrder: [ReviewCardField] = [
        .partOfSpeech, .difficultyTier, .graphLinks, .example, .explanation, .collocations
    ]

    var titleKey: String {
        switch self {
        case .partOfSpeech: "reviewCardLayout.field.partOfSpeech"
        case .difficultyTier: "reviewCardLayout.field.difficultyTier"
        case .example: "reviewCardLayout.field.example"
        case .explanation: "reviewCardLayout.field.explanation"
        case .collocations: "reviewCardLayout.field.collocations"
        case .graphLinks: "reviewCardLayout.field.graphLinks"
        }
    }
}

/// 使用者實際能選的東西（APP-20260808-7f0f3a）。取代「六個欄位各自 on/off ×
/// 正反兩面」的 2^6 × 2^6 自由度：那個自由度絕大多數組合沒有意義，也沒有人
/// 知道該開哪個。每個方向只在「正常」與「精簡」之間選。
enum ReviewCardLayoutPreset: String, CaseIterable, Codable, Hashable, Sendable {
    /// 今天的預設，也就是重構前的畫面。
    case standard
    /// 拿掉例句、詳解、搭配詞 —— 正反面都不留。
    case compact

    var titleKey: String {
        switch self {
        case .standard: "reviewCardLayout.preset.standard"
        case .compact: "reviewCardLayout.preset.compact"
        }
    }

    /// 欄位清單是 preset 的**衍生值**，不是被持久化的東西。
    func layout(for mode: VocabularyCardMode) -> ReviewCardModeLayout {
        switch self {
        case .standard:
            ReviewCardModeLayout(
                front: mode == .production ? [.partOfSpeech, .example] : [.partOfSpeech],
                back: [.difficultyTier, .graphLinks, .example, .explanation, .collocations]
            )
        case .compact:
            ReviewCardModeLayout(
                front: [.partOfSpeech],
                back: [.difficultyTier, .graphLinks]
            )
        }
    }

    /// 舊資料（自由欄位陣列）搬遷用：取對稱差最小的 preset。平手取 `.standard`
    /// —— 它同時是預設值與重構前的畫面，所以「看不出使用者想要什麼」時保守回到它。
    static func closest(
        toFront front: [ReviewCardField],
        back: [ReviewCardField],
        for mode: VocabularyCardMode
    ) -> ReviewCardLayoutPreset {
        func distance(_ preset: ReviewCardLayoutPreset) -> Int {
            let layout = preset.layout(for: mode)
            return Set(front).symmetricDifference(layout.front).count
                + Set(back).symmetricDifference(layout.back).count
        }
        return distance(.compact) < distance(.standard) ? .compact : .standard
    }
}

/// Settings shows one word for a whole profile. Kept a pure function so the row
/// and its test read the same rule.
enum ReviewCardLayoutSummary {
    static func titleKey(for profile: ReviewCardLayoutProfile) -> String {
        guard profile.recognition == profile.production else {
            return "settings.reviewCardLayout.mixed"
        }
        switch profile.recognition {
        case .standard: return "settings.reviewCardLayout.standard"
        case .compact: return "settings.reviewCardLayout.compact"
        }
    }
}

/// preset → 欄位清單的載體。已不再被序列化，所以不需要 sanitize：能產生它的
/// 只有 `ReviewCardLayoutPreset.layout(for:)`，沒有重複值的來源。
struct ReviewCardModeLayout: Equatable {
    var front: [ReviewCardField]
    var back: [ReviewCardField]

    init(front: [ReviewCardField], back: [ReviewCardField]) {
        self.front = front
        self.back = back
    }
}

struct ReviewCardLayoutProfile: Equatable, Codable, Sendable {
    var recognition: ReviewCardLayoutPreset
    var production: ReviewCardLayoutPreset

    init(recognition: ReviewCardLayoutPreset, production: ReviewCardLayoutPreset) {
        self.recognition = recognition
        self.production = production
    }

    static let `default` = ReviewCardLayoutProfile(recognition: .standard, production: .standard)

    func preset(for mode: VocabularyCardMode) -> ReviewCardLayoutPreset {
        switch mode {
        case .recognition: recognition
        case .production: production
        }
    }

    mutating func setPreset(_ preset: ReviewCardLayoutPreset, for mode: VocabularyCardMode) {
        switch mode {
        case .recognition: recognition = preset
        case .production: production = preset
        }
    }

    /// 渲染端的接縫，刻意不改名：`ReviewCardRenderPlan.make` 與
    /// `TodayReviewPresenter+CardContent` 因此零改動。
    func layout(for mode: VocabularyCardMode) -> ReviewCardModeLayout {
        preset(for: mode).layout(for: mode)
    }

    private enum CodingKeys: String, CodingKey {
        case recognition
        case production
    }

    private enum ModeCodingKeys: String, CodingKey {
        case front
        case back
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recognition = Self.decodePreset(from: container, key: .recognition, mode: .recognition)
        production = Self.decodePreset(from: container, key: .production, mode: .production)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recognition, forKey: .recognition)
        try container.encode(production, forKey: .production)
    }

    /// 三段式：新形狀（preset 字串）→ 舊形狀（{front:[String],back:[String]}，
    /// 搬遷到最近的 preset）→ 都讀不到就 `.standard`。envelope（storageKey /
    /// schemaVersion / 時間戳天花板 / LWW）一層完全沒動，搬遷只發生在這裡。
    private static func decodePreset(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        mode: VocabularyCardMode
    ) -> ReviewCardLayoutPreset {
        guard container.contains(key) else { return .standard }
        if let preset = try? container.decode(ReviewCardLayoutPreset.self, forKey: key) {
            return preset
        }
        guard let nested = try? container.nestedContainer(keyedBy: ModeCodingKeys.self, forKey: key)
        else { return .standard }

        let fallback = ReviewCardLayoutPreset.standard.layout(for: mode)
        let front = decodeFields(from: nested, key: .front) ?? fallback.front
        let back = decodeFields(from: nested, key: .back) ?? fallback.back
        return ReviewCardLayoutPreset.closest(toFront: front, back: back, for: mode)
    }

    private static func decodeFields(
        from container: KeyedDecodingContainer<ModeCodingKeys>,
        key: ModeCodingKeys
    ) -> [ReviewCardField]? {
        guard container.contains(key),
              let rawValues = try? container.decode([String].self, forKey: key)
        else { return nil }

        var seen = Set<ReviewCardField>()
        return rawValues.compactMap(ReviewCardField.init(rawValue:)).filter {
            seen.insert($0).inserted
        }
    }
}

@Observable
final class ReviewCardLayoutStore {
    static let storageKey = "review_card_layout_profile_v1"
    static let shared = ReviewCardLayoutStore()

    /// JSON/Date hard bound (start of year 10000 UTC, exclusive).
    static let maximumSupportedUnixTimestamp: TimeInterval = 253_402_300_800
    /// Legacy v1 envelopes are only trusted through this lower ceiling. That
    /// leaves a practical year of timestamp headroom before the hard bound.
    static let maximumLegacyUnixTimestamp: TimeInterval =
        maximumSupportedUnixTimestamp - (366 * 24 * 60 * 60)
    /// v2 envelopes retain a smaller independent reserve so a corrupt v2
    /// clock cannot reach the JSON/Date hard bound and poison future writes.
    static let maximumV2UnixTimestamp: TimeInterval =
        maximumSupportedUnixTimestamp - (24 * 60 * 60)

    private static let legacySchemaVersion = 1
    private static let schemaVersion = 2

    private struct Envelope: Codable {
        let version: Int
        let updatedAt: TimeInterval
        let profile: ReviewCardLayoutProfile
    }

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let cloud: CloudKeyValueStore?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let notificationCenter: NotificationCenter?
    @ObservationIgnored private var cloudObserver: NSObjectProtocol?
    @ObservationIgnored private var resolvedUpdatedAt: TimeInterval?
    @ObservationIgnored private var accountID: String?
    private(set) var isAccountBoundarySuspended = false

    private(set) var profile: ReviewCardLayoutProfile

    convenience init() {
        self.init(defaults: .standard, cloud: CloudPreferencesSync.shared)
    }

    init(
        defaults: UserDefaults,
        cloud: CloudKeyValueStore = CloudPreferencesSync.shared,
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter = .default,
        cloudNotificationObject: Any? = NSUbiquitousKeyValueStore.default,
        accountID: String? = nil
    ) {
        let normalizedAccountID = AccountPreferenceNamespace.normalizedAccountID(accountID)
        if let normalizedAccountID {
            Self.migrateLegacyPreferences(defaults: defaults, cloud: cloud, accountID: normalizedAccountID)
        }
        self.accountID = normalizedAccountID
        self.defaults = defaults
        self.cloud = cloud
        self.now = now
        self.notificationCenter = notificationCenter

        let resolved = Self.readResolved(defaults: defaults, cloud: cloud, key: Self.namespacedKey(accountID: normalizedAccountID))
        self.profile = resolved?.profile ?? .default
        self.resolvedUpdatedAt = resolved?.updatedAt

        cloudObserver = notificationCenter.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudNotificationObject,
            queue: .main
        ) { [weak self] notification in
            self?.handleCloudChange(notification)
        }
    }

    private init(inMemoryProfile: ReviewCardLayoutProfile, now: @escaping () -> Date) {
        defaults = nil
        cloud = nil
        self.now = now
        notificationCenter = nil
        cloudObserver = nil
        resolvedUpdatedAt = nil
        profile = inMemoryProfile
    }

    deinit {
        if let cloudObserver, let notificationCenter {
            notificationCenter.removeObserver(cloudObserver)
        }
    }

    static func inMemory(
        profile: ReviewCardLayoutProfile = .default,
        now: @escaping () -> Date = Date.init
    ) -> ReviewCardLayoutStore {
        ReviewCardLayoutStore(inMemoryProfile: profile, now: now)
    }

    func update(_ profile: ReviewCardLayoutProfile) {
        guard !isAccountBoundarySuspended else { return }
        guard defaults != nil, cloud != nil else {
            self.profile = profile
            return
        }

        let timestamp = nextTimestamp()
        guard let encoded = Self.encodeEnvelope(profile: profile, updatedAt: timestamp) else {
            return
        }
        defaults?.set(encoded, forKey: storageKey)
        cloud?.set(encoded, forKey: storageKey)
        self.profile = profile
        resolvedUpdatedAt = timestamp
    }

    func setPreset(_ preset: ReviewCardLayoutPreset, for mode: VocabularyCardMode) {
        var changed = profile
        changed.setPreset(preset, for: mode)
        update(changed)
    }

    func resetAll() {
        update(.default)
    }

    /// Switch to one authenticated account. Durable local and iCloud state
    /// lives under the account namespace; the first activation adopts the
    /// pre-account raw layout once.
    func activateAccount(_ accountID: String?) {
        guard let defaults, let cloud else { return }
        let normalizedAccountID = AccountPreferenceNamespace.normalizedAccountID(accountID)
        if let normalizedAccountID {
            Self.migrateLegacyPreferences(defaults: defaults, cloud: cloud, accountID: normalizedAccountID)
        }
        self.accountID = normalizedAccountID
        isAccountBoundarySuspended = false
        let resolved = Self.readResolved(defaults: defaults, cloud: cloud, key: storageKey)
        profile = resolved?.profile ?? .default
        resolvedUpdatedAt = resolved?.updatedAt
    }

    /// Hide the previous account's layout during an account boundary without
    /// deleting anything: the pre-account raw key must survive until legacy
    /// migration has adopted it, and the write guard prevents leakage.
    func suspendForAccountBoundary() {
        isAccountBoundarySuspended = true
        accountID = nil
        profile = .default
        resolvedUpdatedAt = nil
    }

    /// Sign-out / delete cleanup for the pre-account raw layout (#2434). Only a
    /// local copy that legacy migration has already adopted is dropped; until the
    /// marker exists the raw key is the sole local copy of the pre-account layout.
    /// The iCloud KVS raw key is deliberately left alone: removing it would
    /// propagate to every device on the same Apple ID, including devices that
    /// have not adopted the layout yet (cross-device data loss).
    static func purgeAdoptedLegacyRawLayout(defaults: UserDefaults) {
        guard defaults.bool(forKey: AccountPreferenceNamespace.legacyMigrationMarker(feature: "review-card-layout"))
        else { return }
        defaults.removeObject(forKey: Self.storageKey)
    }

    private var storageKey: String { Self.namespacedKey(accountID: accountID) }

    private static func namespacedKey(accountID: String?) -> String {
        AccountPreferenceNamespace.key(storageKey, accountID: accountID)
    }

    private static func readResolved(defaults: UserDefaults, cloud: CloudKeyValueStore, key: String) -> Envelope? {
        resolve(
            local: decodeEnvelope(defaults.string(forKey: key)),
            cloud: decodeEnvelope(cloud.string(forKey: key))
        )
    }

    private static func migrateLegacyPreferences(defaults: UserDefaults, cloud: CloudKeyValueStore, accountID: String) {
        AccountPreferenceNamespace.migrateLegacyIfNeeded(
            accountID: accountID,
            defaults: defaults,
            feature: "review-card-layout"
        ) {
            AccountPreferenceNamespace.copyLegacyObject(storageKey, defaults: defaults, accountID: accountID)
            AccountPreferenceNamespace.copyLegacyCloudString(storageKey, cloud: cloud, accountID: accountID)
        }
    }

    private func nextTimestamp() -> TimeInterval {
        let rawCandidate = now().timeIntervalSince1970
        let candidate = Self.isSelfDecodableTimestamp(rawCandidate) ? rawCandidate : 0
        guard let resolvedUpdatedAt, candidate <= resolvedUpdatedAt else { return candidate }
        let bumped = resolvedUpdatedAt.nextUp
        // An exhausted v2 clock is only reachable after impractically many
        // writes. Prefer a finite repair over crashing; a stale high remote
        // value may still win LWW until the next normal timestamp overtakes it.
        return Self.isSelfDecodableTimestamp(bumped) ? bumped : candidate
    }

    private func handleCloudChange(_ notification: Notification) {
        guard !isAccountBoundarySuspended,
              let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
              keys.contains(storageKey),
              let remote = Self.decodeEnvelope(cloud?.string(forKey: storageKey))
        else { return }
        if let resolvedUpdatedAt, remote.updatedAt < resolvedUpdatedAt { return }

        profile = remote.profile
        resolvedUpdatedAt = remote.updatedAt
    }

    private static func resolve(local: Envelope?, cloud: Envelope?) -> Envelope? {
        switch (local, cloud) {
        case let (local?, cloud?):
            return cloud.updatedAt >= local.updatedAt ? cloud : local
        case let (local?, nil):
            return local
        case let (nil, cloud?):
            return cloud
        case (nil, nil):
            return nil
        }
    }

    private static func decodeEnvelope(_ string: String?) -> Envelope? {
        guard let string,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(string.utf8)),
              isAcceptedPersistedTimestamp(envelope.updatedAt, version: envelope.version)
        else { return nil }
        return envelope
    }

    private static func encodeEnvelope(
        profile: ReviewCardLayoutProfile,
        updatedAt: TimeInterval
    ) -> String? {
        guard isSelfDecodableTimestamp(updatedAt) else { return nil }
        let envelope = Envelope(
            version: schemaVersion,
            updatedAt: updatedAt,
            profile: profile
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isAcceptedPersistedTimestamp(
        _ timestamp: TimeInterval,
        version: Int
    ) -> Bool {
        switch version {
        case legacySchemaVersion:
            timestamp.isFinite
                && timestamp >= 0
                && timestamp <= maximumLegacyUnixTimestamp
        case schemaVersion:
            isSelfDecodableTimestamp(timestamp)
        default:
            false
        }
    }

    private static func isSelfDecodableTimestamp(_ timestamp: TimeInterval) -> Bool {
        timestamp.isFinite
            && timestamp >= 0
            && timestamp < maximumV2UnixTimestamp
    }
}

private struct ReviewCardLayoutStoreKey: EnvironmentKey {
    static let defaultValue: ReviewCardLayoutStore = .shared
}

extension EnvironmentValues {
    var reviewCardLayoutStore: ReviewCardLayoutStore {
        get { self[ReviewCardLayoutStoreKey.self] }
        set { self[ReviewCardLayoutStoreKey.self] = newValue }
    }
}
