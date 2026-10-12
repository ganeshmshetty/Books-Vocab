//
//  ActiveNotebookStore.swift
//  Books & Vocab
//

import Foundation

/// active notebook 的跨裝置狀態快照：id + updatedAt 驅動 LWW。
struct ActiveNotebookState: Equatable {
    var activeNotebookId: String
    var updatedAt: Double?   // LWW timestamp（秒, since 1970）；nil = 從未寫過
}

/// Last-write-wins 決議：取 `updatedAt` 較新者；雙方皆無時戳則保留 local（可能是
/// default）。對齊 `ReviewModeLWW` / `ReviewClockLWW`。active notebook 不一致會讓跨裝置
/// 新選詞歸進不同本子。
enum ActiveNotebookLWW {
    static func resolve(local: ActiveNotebookState, cloud: ActiveNotebookState) -> ActiveNotebookState {
        switch (local.updatedAt, cloud.updatedAt) {
        case let (l?, c?): return c > l ? cloud : local
        case (nil, _?): return cloud
        case (_?, nil): return local
        case (nil, nil): return local
        }
    }
}

/// 全域 active notebook 游標的單一存取點（三層：UserDefaults 本地 + iCloud KVS 跨 Apple
/// 裝置 + backend sync/push）。「active notebook」= 決定新選詞預設歸進哪一本的全域
/// 指標（per-book `Book.preferredNotebookId` 走 CloudKit，不在此）。對齊
/// `ReviewSettingsStore` 的 LWW 機制（本地 vs iCloud KVS 比 updatedAt 取較新整組）。
///
/// 刻意**非 @Observable**：無 View 觀察 store 的 in-memory 狀態 —— NotebookListView 用
/// @AppStorage 觀察同一 UserDefaults key、Reader / Podcast capture 透過此 store 讀取。
/// 故為 thread-safe wrapper over UserDefaults + iCloud KVS，清除點在背景 service thread
/// 也安全。init 把 LWW resolved 值寫回本地，使 consumer 看到跨裝置收斂後的值。
///
/// backend 層提供 server sync + best-effort push（讓 chrome / web 能讀）；iCloud KVS
/// 仍負責 Apple 裝置間的 local projection 收斂。
final class ActiveNotebookStore {
    static let shared = ActiveNotebookStore()

    /// 無綁定 notebook 時的系統預設本 id（對齊 `Book.resolvedNotebookId` fallback）。
    static let defaultNotebookId = "default"

    private enum Keys {
        static let activeId = "activeNotebookId"
        static let updatedAt = "active_notebook_updated_at"
    }

    private let defaults: UserDefaults
    private let cloud: CloudKeyValueStore
    private var accountID: String?
    private var isAccountBoundarySuspended = false

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
        // 三層 LWW：本地 vs iCloud KVS 取較新整組，寫回本地讓 capture consumer 看到
        // resolved 值（cloud 較新時不讀到舊 local）。
        //
        // 僅在 resolved 帶有效 updatedAt 時寫回：雙方皆未寫過（updatedAt 皆 nil）時
        // resolved 是 (default, nil)，若寫回會把本地 activeId key 實體化成 "default"，
        // 破壞 `activeNotebookIdIfSet` 的「未設定回 nil」短路語意（reconcile 會對從未
        // 設定者做多餘清理）。
        reloadProjection()
    }

    /// Switch the shared cursor to one authenticated account. The compatibility
    /// raw key is only the current in-memory/UI projection; durable local and
    /// iCloud state uses the account namespace.
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
        reloadProjection()
    }

    /// Remove the visible cursor during an account boundary without deleting
    /// the previous account's namespaced iCloud state.
    func suspendForAccountBoundary() {
        isAccountBoundarySuspended = true
        accountID = nil
        defaults.removeObject(forKey: Keys.activeId)
        defaults.removeObject(forKey: Keys.updatedAt)
    }

    private func storageKey(_ key: String) -> String {
        AccountPreferenceNamespace.key(key, accountID: accountID)
    }

    private func reloadProjection() {
        let resolved = ActiveNotebookLWW.resolve(
            local: Self.readLocalState(defaults, accountID: accountID),
            cloud: Self.readCloudState(cloud, accountID: accountID)
        )
        defaults.removeObject(forKey: Keys.activeId)
        defaults.removeObject(forKey: Keys.updatedAt)
        // 無 timestamp 但非 default 的 id（pre-LWW 殘留 / guest）須保留；(default, nil) 維持不實體化。
        if resolved.updatedAt != nil || resolved.activeNotebookId != Self.defaultNotebookId {
            writeLocalState(resolved)
        }
    }

    private static func migrateLegacyPreferences(
        defaults: UserDefaults,
        cloud: CloudKeyValueStore,
        accountID: String
    ) {
        AccountPreferenceNamespace.migrateLegacyIfNeeded(
            accountID: accountID,
            defaults: defaults,
            cloud: cloud,
            feature: "active-notebook"
        ) {
            for key in [Keys.activeId, Keys.updatedAt] {
                AccountPreferenceNamespace.copyLegacyObject(
                    key,
                    defaults: defaults,
                    accountID: accountID
                )
                AccountPreferenceNamespace.copyLegacyCloudString(
                    key,
                    cloud: cloud,
                    accountID: accountID
                )
                AccountPreferenceNamespace.copyLegacyCloudDouble(
                    key,
                    cloud: cloud,
                    accountID: accountID
                )
            }
        }
    }

    /// 當前全域 active notebook id；未設定時回 `defaultNotebookId`。直讀本地層
    /// （已被 init / setActive 維護成 LWW resolved 值）。
    var activeNotebookId: String {
        guard !isAccountBoundarySuspended else { return Self.defaultNotebookId }
        return defaults.string(forKey: storageKey(Keys.activeId)) ?? Self.defaultNotebookId
    }

    /// 本地 key 已設定時的 id（未設回 nil）。供 reconcile 還原「key 未設不處理」短路語意，
    /// 避免對從未設定的 default 做多餘清理 / 推時戳。
    var activeNotebookIdIfSet: String? {
        guard !isAccountBoundarySuspended else { return nil }
        return defaults.string(forKey: storageKey(Keys.activeId))
    }

    /// 使用者切換 active notebook，或刪除後 fallback 指派。推進 updatedAt + 寫本地 + iCloud
    /// （整組原子：id 與 updatedAt 一起寫，跨裝置 LWW 取較新整組）。
    func setActive(_ id: String) {
        guard !isAccountBoundarySuspended else { return }
        let ts = Date().timeIntervalSince1970
        let state = ActiveNotebookState(activeNotebookId: id, updatedAt: ts)
        writeLocalState(state)
        writeCloudState(state)
    }

    /// active notebook 指向的本子已不可見（跨裝置刪除 / 孤兒回收）時回退 default。
    /// 寫回 default + 推進 updatedAt 以跨裝置同步此重置（他裝置也收斂到 default，不再
    /// 停在死 id）。
    func clearStale() {
        setActive(Self.defaultNotebookId)
    }

    /// 清除相容用的 raw projection，不刪 account namespace。登出／帳號切換的
    /// account-local active notebook 仍須在重新登入該帳號時恢復；因此所有
    /// generic local-data cleanup 都只能移除目前 UI projection。
    func clear() {
        defaults.removeObject(forKey: Keys.activeId)
        defaults.removeObject(forKey: Keys.updatedAt)
    }

    // MARK: - Layer reads / writes (LWW inputs)

    static func readLocalState(_ defaults: UserDefaults) -> ActiveNotebookState {
        readLocalState(defaults, accountID: nil)
    }

    private static func readLocalState(
        _ defaults: UserDefaults,
        accountID: String?
    ) -> ActiveNotebookState {
        ActiveNotebookState(
            activeNotebookId: defaults.string(
                forKey: AccountPreferenceNamespace.key(Keys.activeId, accountID: accountID)
            ) ?? defaultNotebookId,
            updatedAt: defaults.object(
                forKey: AccountPreferenceNamespace.key(Keys.updatedAt, accountID: accountID)
            ) as? Double
        )
    }

    static func readCloudState(_ cloud: CloudKeyValueStore) -> ActiveNotebookState {
        readCloudState(cloud, accountID: nil)
    }

    private static func readCloudState(
        _ cloud: CloudKeyValueStore,
        accountID: String?
    ) -> ActiveNotebookState {
        ActiveNotebookState(
            activeNotebookId: cloud.string(
                forKey: AccountPreferenceNamespace.key(Keys.activeId, accountID: accountID)
            ) ?? defaultNotebookId,
            updatedAt: cloud.double(
                forKey: AccountPreferenceNamespace.key(Keys.updatedAt, accountID: accountID)
            )
        )
    }

    static func writeLocalState(_ state: ActiveNotebookState, into defaults: UserDefaults) {
        defaults.set(state.activeNotebookId, forKey: Keys.activeId)
        if let ts = state.updatedAt {
            defaults.set(ts, forKey: Keys.updatedAt)
        }
    }

    private func writeLocalState(_ state: ActiveNotebookState) {
        defaults.set(state.activeNotebookId, forKey: storageKey(Keys.activeId))
        if let ts = state.updatedAt {
            defaults.set(ts, forKey: storageKey(Keys.updatedAt))
        }
        // NotebookListView observes the legacy raw key. Keep it as a
        // current-account projection while never using it as account storage.
        if accountID != nil {
            defaults.set(state.activeNotebookId, forKey: Keys.activeId)
            if let ts = state.updatedAt {
                defaults.set(ts, forKey: Keys.updatedAt)
            }
        }
    }

    /// 整組寫雲端（id + updatedAt 一起）。updatedAt nil 時寫 0 sentinel（KVS 無 removeObject，
    /// 讀取端 0 視為「無有效時戳」由 LWW 比較處理）。
    private func writeCloudState(_ state: ActiveNotebookState) {
        cloud.set(state.activeNotebookId, forKey: storageKey(Keys.activeId))
        cloud.set(state.updatedAt ?? 0, forKey: storageKey(Keys.updatedAt))
    }

    // MARK: - Backend sync / push support

    /// 當前 LWW 快照（push 帶 updatedAt 用；取本地層）。
    var snapshot: ActiveNotebookState {
        guard !isAccountBoundarySuspended else {
            return ActiveNotebookState(activeNotebookId: Self.defaultNotebookId, updatedAt: nil)
        }
        return Self.readLocalState(defaults, accountID: accountID)
    }

    /// Apply a server projection only when its group timestamp is newer than the
    /// local projection. The accepted state stays local-only; a user selection
    /// remains the operation that publishes a new iCloud value.
    @discardableResult
    func syncActiveNotebookFromServer(_ state: ActiveNotebookState) -> Bool {
        guard let serverUpdatedAt = state.updatedAt else { return false }
        guard !state.activeNotebookId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if let localUpdatedAt = snapshot.updatedAt, serverUpdatedAt <= localUpdatedAt {
            return false
        }
        guard !isAccountBoundarySuspended else { return false }
        writeLocalState(state)
        return true
    }
}
