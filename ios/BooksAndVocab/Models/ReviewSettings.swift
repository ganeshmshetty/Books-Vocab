import Foundation
import CryptoKit
import Observation
import SwiftUI

enum ReviewSettingsMode: String, CaseIterable, Codable, Hashable, Sendable {
    case relaxed
    case intensive
    case custom

    var displayName: String {
        switch self {
        case .relaxed: return L10n.string("寬鬆")
        case .intensive: return L10n.string("密集")
        case .custom: return L10n.string("自訂")
        }
    }

    var icon: String {
        switch self {
        case .relaxed: return "heart"
        case .intensive: return "bolt"
        case .custom: return "gearshape"
        }
    }
}

enum AutoplaySpeed: String, CaseIterable, Hashable, Sendable {
    case slow
    case normal
    case fast

    var displayName: String {
        switch self {
        case .slow: return L10n.string("慢")
        case .normal: return L10n.string("正常")
        case .fast: return L10n.string("快")
        }
    }

    /// 卡片正面停留時間（翻面前的等待）
    var revealDelay: Duration {
        switch self {
        case .slow: return .seconds(4)
        case .normal: return .seconds(2)
        case .fast: return .seconds(1)
        }
    }

    /// 卡片背面停留時間（翻到下一張前的等待）
    var stayDelay: Duration {
        switch self {
        case .slow: return .seconds(8)
        case .normal: return .seconds(4)
        case .fast: return .seconds(2)
        }
    }

    var next: AutoplaySpeed {
        switch self {
        case .slow: return .normal
        case .normal: return .fast
        case .fast: return .slow
        }
    }
}

struct ReviewSettings: Equatable, Sendable {
    var mode: ReviewSettingsMode
    var customInitialIntervalHours: Double
    var customRememberedMultiplier: Double
    var customForgotMultiplier: Double
    var customMinimumIntervalHours: Double
    var customMaximumIntervalHours: Double
    var isProgressPaused: Bool = false
    var progressPausedAt: Date? = nil
    var autoplaySpeed: AutoplaySpeed = .normal
    var autoplaySoundEnabled: Bool = true

    static let `default` = ReviewSettings(
        mode: .relaxed,
        customInitialIntervalHours: 12,
        customRememberedMultiplier: 1.9,
        customForgotMultiplier: 0.45,
        customMinimumIntervalHours: 6,
        customMaximumIntervalHours: 1440,
        autoplaySpeed: .normal,
        autoplaySoundEnabled: true
    )

    var effectiveInitialIntervalHours: Double {
        switch mode {
        case .relaxed: return 24
        case .intensive: return 8
        case .custom: return customInitialIntervalHours
        }
    }

    var effectiveRememberedMultiplier: Double {
        switch mode {
        case .relaxed: return 2.5
        case .intensive: return 1.4
        case .custom: return customRememberedMultiplier
        }
    }

    var effectiveForgotMultiplier: Double {
        switch mode {
        case .relaxed: return 0.5
        case .intensive: return 0.35
        case .custom: return customForgotMultiplier
        }
    }

    var effectiveMinimumIntervalHours: Double {
        switch mode {
        case .relaxed: return 6
        case .intensive: return 4
        case .custom: return customMinimumIntervalHours
        }
    }

    var effectiveMaximumIntervalHours: Double {
        switch mode {
        case .relaxed: return 1440
        case .intensive: return 1440
        case .custom: return customMaximumIntervalHours
        }
    }

    func reviewReferenceDate(now: Date = Date()) -> Date {
        guard isProgressPaused else { return now }
        return progressPausedAt ?? now
    }

    mutating func pauseProgress(at date: Date = Date()) {
        isProgressPaused = true
        progressPausedAt = progressPausedAt ?? date
    }

    mutating func resumeProgress() {
        isProgressPaused = false
        progressPausedAt = nil
    }
}

// MARK: - Pause clock cross-device sync (Phase 2)

/// iCloud KVS 抽象 seam(pause clock 的 Double + review mode 的 String get/set),讓
/// `ReviewSettingsStore` 可注入 fake 測 LWW。`CloudPreferencesSync` 已提供這四個方法,空 extension conform。
protocol CloudKeyValueStore {
    func double(forKey key: String) -> Double?
    func set(_ value: Double, forKey key: String)
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func removeObject(forKey key: String)
    func allKeys() -> [String]
}

extension CloudPreferencesSync: CloudKeyValueStore {}

/// pause 時鐘的跨裝置狀態快照:`isPaused` + `pausedAt` 複合,共用單一 `updatedAt` 時戳。
struct PauseClockState: Equatable {
    var isPaused: Bool
    var pausedAt: Date?
    var updatedAt: Double?   // LWW timestamp(秒, since 1970);nil = 從未寫過
}

/// Last-write-wins 決議:取 `updatedAt` 較新的**整組**。兩欄位共用一個時戳確保整組
/// 原子收斂(絕不讓 isPaused 取一邊、pausedAt 取另一邊)。雙方皆無時戳則保留 local
/// (可能是 default)。pause 時鐘錯誤會讓跨裝置算出不同的 reviewReferenceDate → due 量不一致。
enum ReviewClockLWW {
    static func resolve(local: PauseClockState, cloud: PauseClockState) -> PauseClockState {
        switch (local.updatedAt, cloud.updatedAt) {
        case let (l?, c?): return c > l ? cloud : local
        case (nil, _?): return cloud
        case (_?, nil): return local
        case (nil, nil): return local
        }
    }
}

/// 複習模式 + 自訂 SRS 參數的跨裝置狀態快照:`mode` + 5 個 custom 參數複合,
/// 共用單一
/// `updatedAt` 時戳。custom 參數只在 `.custom` 模式生效,但即使非 custom 仍保存使用者調過的值。
struct ReviewModeState: Equatable {
    var mode: ReviewSettingsMode
    var customInitialIntervalHours: Double
    var customRememberedMultiplier: Double
    var customForgotMultiplier: Double
    var customMinimumIntervalHours: Double
    var customMaximumIntervalHours: Double
    var updatedAt: Double?   // LWW timestamp(秒, since 1970);nil = 從未寫過
}

/// Last-write-wins 決議:取 `updatedAt` 較新的**整組**(mode + 5 custom 共用一個時戳,確保
/// 原子收斂,絕不讓 mode 取一邊、custom 參數取另一邊)。雙方皆無時戳則保留 local(可能是
/// default)。mode/custom 不一致會讓跨裝置算出不同 SRS 間隔 → 複習排程漂移。
enum ReviewModeLWW {
    static func resolve(local: ReviewModeState, cloud: ReviewModeState) -> ReviewModeState {
        switch (local.updatedAt, cloud.updatedAt) {
        case let (l?, c?): return c > l ? cloud : local
        case (nil, _?): return cloud
        case (_?, nil): return local
        case (nil, nil): return local
        }
    }
}

/// Account-scoped preference keys keep the existing UserDefaults/iCloud
/// storage layers while preventing an opaque account identifier from becoming
/// part of either key. `nil` deliberately retains the legacy guest/preview
/// namespace for callers that have not entered an authenticated account.
enum AccountPreferenceNamespace {
    private static let prefix = "kg.account."

    static func normalizedAccountID(_ accountID: String?) -> String? {
        guard let accountID else { return nil }
        let normalized = accountID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        return normalized.isEmpty ? nil : normalized
    }

    static func key(_ key: String, accountID: String?) -> String {
        guard let normalizedAccountID = normalizedAccountID(accountID) else { return key }
        return "\(accountPrefix(normalizedAccountID))\(key)"
    }

    private static func accountPrefix(_ normalizedAccountID: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedAccountID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)\(digest)."
    }

    static func legacyMigrationMarker(feature: String) -> String {
        "\(prefix)legacy-migration.\(feature).v1"
    }

    /// delete_account 專用：僅移除「被刪除帳號」在本機與 iCloud KVS 內的命名空間偏好
    /// （`kg.account.<digest>.*`）。其他帳號在同裝置上的偏好保持不動。
    /// legacy-migration marker 不屬於任何帳號 digest，故天然保留，避免之後的帳號重新領養
    /// pre-account raw 值。
    static func purgeNamespacedPreferences(
        accountID: String,
        defaults: UserDefaults,
        cloud: CloudKeyValueStore
    ) {
        guard let normalizedAccountID = normalizedAccountID(accountID) else { return }
        let accountPrefix = accountPrefix(normalizedAccountID)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(accountPrefix) {
            defaults.removeObject(forKey: key)
        }
        for key in cloud.allKeys() where key.hasPrefix(accountPrefix) {
            cloud.removeObject(forKey: key)
        }
    }

    /// Migrate the pre-account raw preference namespace exactly once per
    /// preference family. The marker is deliberately global to the device/
    /// Apple-ID store: legacy values describe the one existing local user and
    /// must never be copied into every account that signs in afterwards.
    static func migrateLegacyIfNeeded(
        accountID: String?,
        defaults: UserDefaults,
        feature: String,
        migration: () -> Void
    ) {
        guard normalizedAccountID(accountID) != nil else { return }
        let marker = legacyMigrationMarker(feature: feature)
        guard !defaults.bool(forKey: marker) else { return }
        migration()
        defaults.set(true, forKey: marker)
    }

    static func copyLegacyObject(
        _ key: String,
        defaults: UserDefaults,
        accountID: String?
    ) {
        let namespacedKey = self.key(key, accountID: accountID)
        guard defaults.object(forKey: namespacedKey) == nil,
              let value = defaults.object(forKey: key)
        else { return }
        defaults.set(value, forKey: namespacedKey)
    }

    static func copyLegacyCloudString(
        _ key: String,
        cloud: CloudKeyValueStore,
        accountID: String?
    ) {
        let namespacedKey = self.key(key, accountID: accountID)
        guard cloud.string(forKey: namespacedKey) == nil,
              let value = cloud.string(forKey: key)
        else { return }
        cloud.set(value, forKey: namespacedKey)
    }

    static func copyLegacyCloudDouble(
        _ key: String,
        cloud: CloudKeyValueStore,
        accountID: String?
    ) {
        let namespacedKey = self.key(key, accountID: accountID)
        guard cloud.double(forKey: namespacedKey) == nil,
              let value = cloud.double(forKey: key)
        else { return }
        cloud.set(value, forKey: namespacedKey)
    }
}

@Observable
final class ReviewSettingsStore {
    static let shared = ReviewSettingsStore()

    private enum Keys {
        static let mode = "review_settings_mode"
        static let customParams = "review_settings_custom_params"
        static let modeUpdatedAt = "review_settings_mode_updated_at"
        static let isProgressPaused = "review_settings_progress_paused"
        static let progressPausedAt = "review_settings_progress_paused_at"
        static let progressUpdatedAt = "review_settings_progress_updated_at"
        static let autoplaySpeed = "review_settings_autoplay_speed"
        static let autoplaySoundEnabled = "review_settings_autoplay_sound_enabled"
    }

    private let defaults: UserDefaults
    private let cloud: CloudKeyValueStore
    private var accountID: String?
    private var isAccountBoundarySuspended = false
    private(set) var settings: ReviewSettings

    convenience init() {
        self.init(defaults: .standard)
    }

    init(
        defaults: UserDefaults,
        cloud: CloudKeyValueStore = CloudPreferencesSync.shared,
        accountID: String? = nil
    ) {
        let normalizedAccountID = AccountPreferenceNamespace.normalizedAccountID(accountID)
        if let normalizedAccountID {
            Self.migrateLegacyPreferences(
                defaults: defaults,
                cloud: cloud,
                accountID: normalizedAccountID
            )
        }
        self.defaults = defaults
        self.cloud = cloud
        self.accountID = normalizedAccountID
        // mode + 自訂 SRS 參數三層 LWW:本地(UserDefaults)與雲端(iCloud KVS)各取一組,
        // 比 updatedAt 取較新整組 → 跨裝置 SRS 間隔一致(否則各裝置複習排程不同)。
        // pause clock 三層 LWW:本地(UserDefaults)與雲端(iCloud KVS)各取一組,比
        // updatedAt 取較新整組 → 跨裝置複習基準一致(否則各裝置算出不同 due 量)。
        self.settings = Self.loadSettings(
            defaults: defaults,
            cloud: cloud,
            accountID: normalizedAccountID
        )
    }

    /// Switch the shared store to one authenticated account. The in-memory
    /// projection is replaced before any server await, and only that account's
    /// local/iCloud keys are read.
    func activateAccount(_ accountID: String?) {
        let normalizedAccountID = AccountPreferenceNamespace.normalizedAccountID(accountID)
        if let normalizedAccountID {
            Self.migrateLegacyPreferences(
                defaults: defaults,
                cloud: cloud,
                accountID: normalizedAccountID
            )
        }
        self.accountID = normalizedAccountID
        isAccountBoundarySuspended = false
        settings = Self.loadSettings(defaults: defaults, cloud: cloud, accountID: self.accountID)
    }

    /// Hide the previous account's projection while AuthManager/Settings starts
    /// the next account. This is intentionally non-persistent; the account's
    /// namespaced cloud value remains available on its next activation.
    func suspendForAccountBoundary() {
        accountID = nil
        isAccountBoundarySuspended = true
        settings = .default
    }

    private func storageKey(_ key: String) -> String {
        AccountPreferenceNamespace.key(key, accountID: accountID)
    }

    private static func migrateLegacyPreferences(
        defaults: UserDefaults,
        cloud: CloudKeyValueStore,
        accountID: String
    ) {
        AccountPreferenceNamespace.migrateLegacyIfNeeded(
            accountID: accountID,
            defaults: defaults,
            feature: "review-settings"
        ) {
            for key in [
                Keys.mode,
                Keys.customParams,
                Keys.modeUpdatedAt,
                Keys.isProgressPaused,
                Keys.progressPausedAt,
                Keys.progressUpdatedAt,
                Keys.autoplaySpeed,
                Keys.autoplaySoundEnabled,
            ] {
                AccountPreferenceNamespace.copyLegacyObject(
                    key,
                    defaults: defaults,
                    accountID: accountID
                )
            }
            for key in [Keys.mode, Keys.customParams] {
                AccountPreferenceNamespace.copyLegacyCloudString(
                    key,
                    cloud: cloud,
                    accountID: accountID
                )
            }
            for key in [
                Keys.modeUpdatedAt,
                Keys.isProgressPaused,
                Keys.progressPausedAt,
                Keys.progressUpdatedAt,
            ] {
                AccountPreferenceNamespace.copyLegacyCloudDouble(
                    key,
                    cloud: cloud,
                    accountID: accountID
                )
            }
        }
    }

    private static func loadSettings(
        defaults: UserDefaults,
        cloud: CloudKeyValueStore,
        accountID: String?
    ) -> ReviewSettings {
        let resolvedMode = ReviewModeLWW.resolve(
            local: readLocalModeState(defaults, accountID: accountID),
            cloud: readCloudModeState(cloud, accountID: accountID)
        )
        let resolvedPause = ReviewClockLWW.resolve(
            local: readLocalPauseState(defaults, accountID: accountID),
            cloud: readCloudPauseState(cloud, accountID: accountID)
        )
        let autoplaySpeedRaw = defaults.string(forKey: AccountPreferenceNamespace.key(Keys.autoplaySpeed, accountID: accountID))
        let autoplaySpeed = autoplaySpeedRaw.flatMap(AutoplaySpeed.init(rawValue:)) ?? .normal
        let autoplaySoundEnabled = defaults.object(
            forKey: AccountPreferenceNamespace.key(Keys.autoplaySoundEnabled, accountID: accountID)
        ) as? Bool ?? true

        return ReviewSettings(
            mode: resolvedMode.mode,
            customInitialIntervalHours: resolvedMode.customInitialIntervalHours,
            customRememberedMultiplier: resolvedMode.customRememberedMultiplier,
            customForgotMultiplier: resolvedMode.customForgotMultiplier,
            customMinimumIntervalHours: resolvedMode.customMinimumIntervalHours,
            customMaximumIntervalHours: resolvedMode.customMaximumIntervalHours,
            isProgressPaused: resolvedPause.isPaused,
            progressPausedAt: resolvedPause.pausedAt,
            autoplaySpeed: autoplaySpeed,
            autoplaySoundEnabled: autoplaySoundEnabled
        )
    }

    func update(_ settings: ReviewSettings) {
        guard !isAccountBoundarySuspended else { return }
        let pauseChanged = settings.isProgressPaused != self.settings.isProgressPaused
            || settings.progressPausedAt != self.settings.progressPausedAt
        let modeChanged = settings.mode != self.settings.mode
            || settings.customInitialIntervalHours != self.settings.customInitialIntervalHours
            || settings.customRememberedMultiplier != self.settings.customRememberedMultiplier
            || settings.customForgotMultiplier != self.settings.customForgotMultiplier
            || settings.customMinimumIntervalHours != self.settings.customMinimumIntervalHours
            || settings.customMaximumIntervalHours != self.settings.customMaximumIntervalHours
        self.settings = settings
        let modeState = Self.currentModeState(settings, updatedAt: nil)
        // mode + 自訂 SRS 參數本地層:總是寫(冪等,與既有行為一致)。
        writeLocalMode(modeState)
        // mode/custom 雲端層 + LWW 時戳:只在 mode 或 custom 真變動時推進 updatedAt 並
        // 整組寫 iCloud(改 pause/autoplay 不該動 mode 的 LWW clock,否則跨裝置誤判較新)。
        if modeChanged {
            let ts = Date().timeIntervalSince1970
            defaults.set(ts, forKey: storageKey(Keys.modeUpdatedAt))
            writeCloudMode(modeState, timestamp: ts)
        }
        // pause clock 本地層:總是寫(冪等,與既有行為一致)。
        writeLocalPause(settings.isProgressPaused, settings.progressPausedAt)
        // pause clock 雲端層 + LWW 時戳:只在 pause 真的變動時推進 updatedAt 並寫
        // iCloud(改 mode/autoplay 不該動 pause 時鐘的 LWW clock,否則跨裝置誤判較新)。
        if pauseChanged {
            let ts = Date().timeIntervalSince1970
            defaults.set(ts, forKey: storageKey(Keys.progressUpdatedAt))
            cloud.set(settings.isProgressPaused ? 1.0 : 0.0, forKey: storageKey(Keys.isProgressPaused))
            // resume(無錨點)時寫 0 sentinel:KVS 無 removeObject,讀取端把 0 視為 nil。
            cloud.set(settings.progressPausedAt?.timeIntervalSince1970 ?? 0, forKey: storageKey(Keys.progressPausedAt))
            cloud.set(ts, forKey: storageKey(Keys.progressUpdatedAt))
        }
        defaults.set(settings.autoplaySpeed.rawValue, forKey: storageKey(Keys.autoplaySpeed))
        defaults.set(settings.autoplaySoundEnabled, forKey: storageKey(Keys.autoplaySoundEnabled))
    }

    // MARK: - Pause clock layer reads (LWW inputs)

    static func readLocalPauseState(_ defaults: UserDefaults) -> PauseClockState {
        readLocalPauseState(defaults, accountID: nil)
    }

    private static func readLocalPauseState(
        _ defaults: UserDefaults,
        accountID: String?
    ) -> PauseClockState {
        PauseClockState(
            isPaused: defaults.bool(forKey: AccountPreferenceNamespace.key(Keys.isProgressPaused, accountID: accountID)),
            pausedAt: (defaults.object(
                forKey: AccountPreferenceNamespace.key(Keys.progressPausedAt, accountID: accountID)
            ) as? Double)
                .map(Date.init(timeIntervalSince1970:)),
            updatedAt: defaults.object(
                forKey: AccountPreferenceNamespace.key(Keys.progressUpdatedAt, accountID: accountID)
            ) as? Double
        )
    }

    static func readCloudPauseState(_ cloud: CloudKeyValueStore) -> PauseClockState {
        readCloudPauseState(cloud, accountID: nil)
    }

    private static func readCloudPauseState(
        _ cloud: CloudKeyValueStore,
        accountID: String?
    ) -> PauseClockState {
        let pausedAtRaw = cloud.double(forKey: AccountPreferenceNamespace.key(Keys.progressPausedAt, accountID: accountID))
        return PauseClockState(
            isPaused: (cloud.double(
                forKey: AccountPreferenceNamespace.key(Keys.isProgressPaused, accountID: accountID)
            ) ?? 0) != 0,
            // 0 是 resume 時寫的 sentinel(KVS 無 removeObject),視為無錨點。
            pausedAt: pausedAtRaw.flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: $0) },
            updatedAt: cloud.double(
                forKey: AccountPreferenceNamespace.key(Keys.progressUpdatedAt, accountID: accountID)
            )
        )
    }

    // MARK: - Review mode layer reads (LWW inputs)

    static func readLocalModeState(_ defaults: UserDefaults) -> ReviewModeState {
        readLocalModeState(defaults, accountID: nil)
    }

    private static func readLocalModeState(
        _ defaults: UserDefaults,
        accountID: String?
    ) -> ReviewModeState {
        let mode = defaults.string(forKey: AccountPreferenceNamespace.key(Keys.mode, accountID: accountID))
            .flatMap(ReviewSettingsMode.init(rawValue:)) ?? .relaxed
        return Self.modeState(
            mode: mode,
            params: Self.decodeCustomParams(
                defaults.data(forKey: AccountPreferenceNamespace.key(Keys.customParams, accountID: accountID))
            ),
            updatedAt: defaults.object(
                forKey: AccountPreferenceNamespace.key(Keys.modeUpdatedAt, accountID: accountID)
            ) as? Double
        )
    }

    static func readCloudModeState(_ cloud: CloudKeyValueStore) -> ReviewModeState {
        readCloudModeState(cloud, accountID: nil)
    }

    private static func readCloudModeState(
        _ cloud: CloudKeyValueStore,
        accountID: String?
    ) -> ReviewModeState {
        let mode = cloud.string(forKey: AccountPreferenceNamespace.key(Keys.mode, accountID: accountID))
            .flatMap(ReviewSettingsMode.init(rawValue:)) ?? .relaxed
        return Self.modeState(
            mode: mode,
            params: Self.decodeCustomParams(
                cloud.string(forKey: AccountPreferenceNamespace.key(Keys.customParams, accountID: accountID))?
                    .data(using: .utf8)
            ),
            updatedAt: cloud.double(
                forKey: AccountPreferenceNamespace.key(Keys.modeUpdatedAt, accountID: accountID)
            )
        )
    }

    /// 把 customParams(local data 或 cloud string 解碼後的 dict)套 `ReviewSettings.default`
    /// 缺值回退,組成 `ReviewModeState`。local 與 cloud 共用,保證兩層解析語意一致。
    private static func modeState(
        mode: ReviewSettingsMode, params: [String: Double]?, updatedAt: Double?
    ) -> ReviewModeState {
        ReviewModeState(
            mode: mode,
            customInitialIntervalHours: params?["initialIntervalHours"]
                ?? ReviewSettings.default.customInitialIntervalHours,
            customRememberedMultiplier: params?["rememberedMultiplier"]
                ?? ReviewSettings.default.customRememberedMultiplier,
            customForgotMultiplier: params?["forgotMultiplier"]
                ?? ReviewSettings.default.customForgotMultiplier,
            customMinimumIntervalHours: params?["minimumIntervalHours"]
                ?? ReviewSettings.default.customMinimumIntervalHours,
            customMaximumIntervalHours: params?["maximumIntervalHours"]
                ?? ReviewSettings.default.customMaximumIntervalHours,
            updatedAt: updatedAt
        )
    }

    private static func decodeCustomParams(_ data: Data?) -> [String: Double]? {
        guard let data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        else { return nil }
        return dict
    }

    // MARK: - Review mode layer writes

    /// 從完整 `ReviewSettings` 取出 mode 三層子狀態(`updatedAt` 由呼叫端決定:
    /// update 寫入時為 nil 佔位,push/rollback 帶實際時戳)。
    private static func currentModeState(_ settings: ReviewSettings, updatedAt: Double?) -> ReviewModeState {
        ReviewModeState(
            mode: settings.mode,
            customInitialIntervalHours: settings.customInitialIntervalHours,
            customRememberedMultiplier: settings.customRememberedMultiplier,
            customForgotMultiplier: settings.customForgotMultiplier,
            customMinimumIntervalHours: settings.customMinimumIntervalHours,
            customMaximumIntervalHours: settings.customMaximumIntervalHours,
            updatedAt: updatedAt
        )
    }

    private static func encodeCustomParams(_ state: ReviewModeState) -> Data? {
        let dict: [String: Double] = [
            "initialIntervalHours": state.customInitialIntervalHours,
            "rememberedMultiplier": state.customRememberedMultiplier,
            "forgotMultiplier": state.customForgotMultiplier,
            "minimumIntervalHours": state.customMinimumIntervalHours,
            "maximumIntervalHours": state.customMaximumIntervalHours,
        ]
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    /// 寫 mode 三層的本地層(mode + customParams,冪等總是寫)。
    private func writeLocalMode(_ state: ReviewModeState) {
        defaults.set(state.mode.rawValue, forKey: storageKey(Keys.mode))
        if let data = Self.encodeCustomParams(state) {
            defaults.set(data, forKey: storageKey(Keys.customParams))
        }
    }

    /// 整組寫雲端(mode + customParams + updatedAt 一起),確保跨裝置「整組原子」不半寫。
    /// customParams 對固定 5 個 Double 的 dict 序列化不會失敗;萬一失敗,讀取端缺 key
    /// 經 `modeState` 回退 default 仍整組收斂(不會殘留他欄位的舊值)。
    private func writeCloudMode(_ state: ReviewModeState, timestamp: Double) {
        cloud.set(state.mode.rawValue, forKey: storageKey(Keys.mode))
        if let json = Self.encodeCustomParams(state).flatMap({ String(data: $0, encoding: .utf8) }) {
            cloud.set(json, forKey: storageKey(Keys.customParams))
        }
        cloud.set(timestamp, forKey: storageKey(Keys.modeUpdatedAt))
    }

    // MARK: - Review mode push/rollback support (Phase A3)

    /// 當前 mode 三層的 LWW 快照(rollback 前取;updatedAt 取本地層)。
    var reviewModeSnapshot: ReviewModeState {
        Self.currentModeState(settings, updatedAt: Self.readLocalModeState(defaults, accountID: accountID).updatedAt)
    }

    /// 遠端 push 失敗時還原 mode 三層到快照(含原 updatedAt),使回滾值不會被 iCloud LWW
    /// 當成比其他裝置並發寫更新。對標 `restorePauseState`。
    func restoreModeState(_ snapshot: ReviewModeState) {
        var s = settings
        s.mode = snapshot.mode
        s.customInitialIntervalHours = snapshot.customInitialIntervalHours
        s.customRememberedMultiplier = snapshot.customRememberedMultiplier
        s.customForgotMultiplier = snapshot.customForgotMultiplier
        s.customMinimumIntervalHours = snapshot.customMinimumIntervalHours
        s.customMaximumIntervalHours = snapshot.customMaximumIntervalHours
        settings = s
        writeLocalMode(snapshot)
        if let ts = snapshot.updatedAt {
            defaults.set(ts, forKey: storageKey(Keys.modeUpdatedAt))
            writeCloudMode(snapshot, timestamp: ts)
        } else {
            // 先前從未寫過:清本地時戳並還原整組 cloud payload;KVS 無 removeObject,
            // timestamp 寫 0 讓其他裝置真寫(ts>0)勝出。
            defaults.removeObject(forKey: storageKey(Keys.modeUpdatedAt))
            writeCloudMode(snapshot, timestamp: 0.0)
        }
    }

    /// Server review-mode projection 的本地 LWW 寫入 seam。較新的本機 timestamp
    /// 保留；server projection 不回寫 iCloud，避免把讀取結果誤當成另一台裝置的 edit。
    @discardableResult
    func applyServerModeState(_ state: ReviewModeState) -> Bool {
        guard let serverUpdatedAt = state.updatedAt else { return false }
        if let localUpdatedAt = reviewModeSnapshot.updatedAt,
           serverUpdatedAt <= localUpdatedAt {
            return false
        }

        var s = settings
        s.mode = state.mode
        s.customInitialIntervalHours = state.customInitialIntervalHours
        s.customRememberedMultiplier = state.customRememberedMultiplier
        s.customForgotMultiplier = state.customForgotMultiplier
        s.customMinimumIntervalHours = state.customMinimumIntervalHours
        s.customMaximumIntervalHours = state.customMaximumIntervalHours
        settings = s
        writeLocalMode(state)
        defaults.set(serverUpdatedAt, forKey: storageKey(Keys.modeUpdatedAt))
        return true
    }

    // MARK: - Pause clock push/rollback support (Phase 3)

    /// 當前 pause 三層的 LWW 快照(rollback 前取;updatedAt 取本地層)。
    var pauseClockSnapshot: PauseClockState {
        PauseClockState(
            isPaused: settings.isProgressPaused,
            pausedAt: settings.progressPausedAt,
            updatedAt: Self.readLocalPauseState(defaults, accountID: accountID).updatedAt
        )
    }

    /// 遠端 push 失敗時還原 pause 三層到快照(含原 updatedAt),使回滾值不會被 iCloud
    /// LWW 當成比其他裝置並發寫更新。對標 TranslationLanguage.restore。
    func restorePauseState(_ snapshot: PauseClockState) {
        var s = settings
        s.isProgressPaused = snapshot.isPaused
        s.progressPausedAt = snapshot.pausedAt
        settings = s
        writeLocalPause(snapshot.isPaused, snapshot.pausedAt)
        if let ts = snapshot.updatedAt {
            defaults.set(ts, forKey: storageKey(Keys.progressUpdatedAt))
            cloud.set(snapshot.isPaused ? 1.0 : 0.0, forKey: storageKey(Keys.isProgressPaused))
            cloud.set(snapshot.pausedAt?.timeIntervalSince1970 ?? 0, forKey: storageKey(Keys.progressPausedAt))
            cloud.set(ts, forKey: storageKey(Keys.progressUpdatedAt))
        } else {
            // 先前從未寫過:清本地時戳;KVS 無 removeObject,寫 0 讓他裝置真寫(ts>0)勝出。
            defaults.removeObject(forKey: storageKey(Keys.progressUpdatedAt))
            cloud.set(0.0, forKey: storageKey(Keys.isProgressPaused))
            cloud.set(0.0, forKey: storageKey(Keys.progressPausedAt))
            cloud.set(0.0, forKey: storageKey(Keys.progressUpdatedAt))
        }
    }

    /// Server pause-clock projection 的本地 LWW 寫入 seam。較新的本機 timestamp
    /// 保留；server projection 不回寫 iCloud，避免把讀取結果誤當成另一台裝置的 edit。
    @discardableResult
    func applyServerPauseState(isPaused: Bool, pausedAt: Date?, updatedAt: Double?) -> Bool {
        guard let serverUpdatedAt = updatedAt else { return false }
        if let localUpdatedAt = pauseClockSnapshot.updatedAt,
           serverUpdatedAt <= localUpdatedAt {
            return false
        }

        var s = settings
        s.isProgressPaused = isPaused
        s.progressPausedAt = pausedAt
        settings = s
        writeLocalPause(isPaused, pausedAt)
        defaults.set(serverUpdatedAt, forKey: storageKey(Keys.progressUpdatedAt))
        return true
    }

    private func writeLocalPause(_ isPaused: Bool, _ pausedAt: Date?) {
        defaults.set(isPaused, forKey: storageKey(Keys.isProgressPaused))
        if let at = pausedAt {
            defaults.set(at.timeIntervalSince1970, forKey: storageKey(Keys.progressPausedAt))
        } else {
            defaults.removeObject(forKey: storageKey(Keys.progressPausedAt))
        }
    }

    init(previewSettings: ReviewSettings) {
        self.defaults = .standard
        self.cloud = CloudPreferencesSync.shared
        self.accountID = nil
        self.isAccountBoundarySuspended = false
        self.settings = previewSettings
    }
}

protocol AccountPreferenceLifecycle {
    func activate(accountID: String?)
    func suspend()
}

struct AccountPreferenceLifecycleCoordinator: AccountPreferenceLifecycle {
    var layoutStore: ReviewCardLayoutStore = .shared

    func activate(accountID: String?) {
        layoutStore.activateAccount(accountID)
        ReviewSettingsStore.shared.activateAccount(accountID)
        ActiveNotebookStore.shared.activateAccount(accountID)
        TranslationLanguage.activateAccount(accountID)
    }

    func suspend() {
        layoutStore.suspendForAccountBoundary()
        ReviewSettingsStore.shared.suspendForAccountBoundary()
        ActiveNotebookStore.shared.suspendForAccountBoundary()
        TranslationLanguage.suspendForAccountBoundary()
    }
}

/// The translation-language slice of `AccountPreferenceLifecycleCoordinator`,
/// for callers (`SettingsCoordinator`) that move the review/notebook stores
/// themselves but still need the translation namespace behind an injectable seam.
struct TranslationAccountPreferenceLifecycle: AccountPreferenceLifecycle {
    func activate(accountID: String?) {
        TranslationLanguage.activateAccount(accountID)
    }

    func suspend() {
        TranslationLanguage.suspendForAccountBoundary()
    }
}

private struct ReviewSettingsStoreKey: EnvironmentKey {
    static let defaultValue: ReviewSettingsStore = .shared
}

extension EnvironmentValues {
    var reviewSettingsStore: ReviewSettingsStore {
        get { self[ReviewSettingsStoreKey.self] }
        set { self[ReviewSettingsStoreKey.self] = newValue }
    }
}
