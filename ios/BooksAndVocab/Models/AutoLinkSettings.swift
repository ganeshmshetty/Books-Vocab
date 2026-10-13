import Foundation
import Observation
import SwiftUI

/// Per-user 自動連結（backend judge pipeline）開關的本地快取。執行語意的權威在
/// 後端 user config 的 `auto_link` group（pipeline 讀它決定是否跑 judge）；本地
/// 只負責 UI 顯示與離線快取。與 translation / review_* 家族不同：無 iCloud KV 層，
/// 跨裝置一致性靠後端 `updated_at` 真 LWW（新 group 無 cold-start-only 歷史包袱，
/// server 較新即套用）。
///
/// 偏好以帳號命名空間儲存（`AccountPreferenceNamespace`，與 review_* 同一邊界）：
/// 帳號 A 關閉的值不得在帳號 B 登入後顯示（#3415）。登出／換帳號由
/// `AutoLinkAccountPreferenceLifecycle` 經 `AccountPreferenceLifecycleCoordinator` 驅動。
@Observable
final class AutoLinkSettingsStore {
    static let shared = AutoLinkSettingsStore()

    private enum Keys {
        static let enabled = "auto_link_enabled"
        static let updatedAt = "auto_link_updated_at"
        static let legacyFeature = "auto-link"
    }

    private let defaults: UserDefaults
    private var accountID: String?
    private(set) var isEnabled: Bool = true
    /// 本地最後寫入時戳（epoch 秒）。nil = 本機從未寫過（server 值可無條件套用）。
    private(set) var updatedAt: Double?

    init(defaults: UserDefaults = .standard, accountID: String? = nil) {
        self.defaults = defaults
        let normalizedAccountID = AccountPreferenceNamespace.normalizedAccountID(accountID)
        self.accountID = normalizedAccountID
        Self.migrateLegacyIfNeeded(accountID: normalizedAccountID, defaults: defaults)
        reloadProjection()
    }

    /// 切換到單一帳號命名空間；投影於任何 server await 前替換，且只讀該帳號的 key。
    func activateAccount(_ accountID: String?) {
        let normalizedAccountID = AccountPreferenceNamespace.normalizedAccountID(accountID)
        Self.migrateLegacyIfNeeded(accountID: normalizedAccountID, defaults: defaults)
        self.accountID = normalizedAccountID
        reloadProjection()
    }

    /// 帳號邊界：隱藏上一帳號的投影（回到缺省開啟）；其持久值留在該帳號命名空間內。
    func suspendForAccountBoundary() {
        accountID = nil
        isEnabled = true
        updatedAt = nil
    }

    func setEnabled(_ value: Bool, updatedAt: Double = Date().timeIntervalSince1970) {
        isEnabled = value
        persist(enabled: value, updatedAt: updatedAt)
    }

    /// Server 值套用（真 LWW）：本機從未寫過、或 server 時戳較新才套。
    /// server `updated_at == nil`（從未有 client 寫過）不能蓋掉本地已寫的值。
    func applyServer(enabled: Bool, updatedAt serverUpdatedAt: Double?) {
        if let local = updatedAt {
            guard let serverTs = serverUpdatedAt, serverTs > local else { return }
        }
        isEnabled = enabled
        persist(enabled: enabled, updatedAt: serverUpdatedAt)
    }

    /// Rollback 用：還原值「與原時戳」。時戳必須一起還原，否則 LWW 會把
    /// rollback 誤判成比其他裝置的並發寫入更新。
    func restore(enabled: Bool, updatedAt: Double?) {
        isEnabled = enabled
        persist(enabled: enabled, updatedAt: updatedAt)
    }

    private func storageKey(_ key: String) -> String {
        AccountPreferenceNamespace.key(key, accountID: accountID)
    }

    /// 缺省開啟，對齊後端缺省語意（config 無 auto_link group 視同開啟）。
    private func reloadProjection() {
        isEnabled = defaults.object(forKey: storageKey(Keys.enabled)) as? Bool ?? true
        updatedAt = defaults.object(forKey: storageKey(Keys.updatedAt)) as? Double
    }

    /// 舊版未分帳號的 raw 值只由第一個登入帳號領養一次（全域 marker，與 review_* 相同政策）。
    private static func migrateLegacyIfNeeded(accountID: String?, defaults: UserDefaults) {
        AccountPreferenceNamespace.migrateLegacyIfNeeded(
            accountID: accountID,
            defaults: defaults,
            feature: Keys.legacyFeature
        ) {
            AccountPreferenceNamespace.copyLegacyObject(Keys.enabled, defaults: defaults, accountID: accountID)
            AccountPreferenceNamespace.copyLegacyObject(Keys.updatedAt, defaults: defaults, accountID: accountID)
        }
    }

    private func persist(enabled: Bool, updatedAt: Double?) {
        self.updatedAt = updatedAt
        defaults.set(enabled, forKey: storageKey(Keys.enabled))
        if let updatedAt {
            defaults.set(updatedAt, forKey: storageKey(Keys.updatedAt))
        } else {
            defaults.removeObject(forKey: storageKey(Keys.updatedAt))
        }
    }
}

/// 自動連結偏好的帳號邊界 seam，供 `AccountPreferenceLifecycleCoordinator` 組合（#3415）。
struct AutoLinkAccountPreferenceLifecycle {
    var store: AutoLinkSettingsStore = .shared

    func activate(accountID: String?) {
        store.activateAccount(accountID)
    }

    func suspend() {
        store.suspendForAccountBoundary()
    }
}

// MARK: - Environment

private struct AutoLinkSettingsStoreKey: EnvironmentKey {
    static let defaultValue: AutoLinkSettingsStore = .shared
}

extension EnvironmentValues {
    var autoLinkSettingsStore: AutoLinkSettingsStore {
        get { self[AutoLinkSettingsStoreKey.self] }
        set { self[AutoLinkSettingsStoreKey.self] = newValue }
    }
}
