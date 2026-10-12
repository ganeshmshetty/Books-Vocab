import Foundation

enum TranslationLanguage: String, CaseIterable, Identifiable, Codable {
    case en
    case zhHant = "zh-Hant"
    case zhHans = "zh-Hans"
    case ja
    case ko
    case fr
    case de
    case es

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .en: return "English"
        case .zhHant: return "繁體中文"  // i18n-allow: language-self-name
        case .zhHans: return "简体中文"  // i18n-allow: language-self-name
        case .ja: return "日本語"        // i18n-allow: language-self-name
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        }
    }

    var flagEmoji: String {
        switch self {
        case .en: return "🇺🇸"
        case .zhHant: return "🇹🇼"
        case .zhHans: return "🇨🇳"
        case .ja: return "🇯🇵"
        case .ko: return "🇰🇷"
        case .fr: return "🇫🇷"
        case .de: return "🇩🇪"
        case .es: return "🇪🇸"
        }
    }

    static var sourceLanguages: [TranslationLanguage] { [.en, .ja, .ko, .fr, .de, .es] }
    static var targetLanguages: [TranslationLanguage] { [.zhHant, .zhHans, .en, .ja, .ko] }

    // MARK: - System Locale Inference

    /// Walks `Locale.preferredLanguages` and returns the first entry that matches
    /// one of `allowed`. Script-aware: distinguishes `zh-Hans` from `zh-Hant` by
    /// the canonical script subtag instead of bare prefix match (which would
    /// always hit zh-Hant first because of alphabetic ordering).
    ///
    /// Internal scope: testable from BooksAndVocabTests.
    static func inferFromPreferredLanguages(
        allowed: [TranslationLanguage],
        preferred: [String] = Locale.preferredLanguages
    ) -> TranslationLanguage? {
        for code in preferred {
            let canonical = Locale(identifier: code)
            guard let lang = canonical.language.languageCode?.identifier else { continue }
            let script = canonical.language.script?.identifier

            if lang == "zh" {
                if code == "zh" {
                    return allowed.first(where: { $0 == .zhHant })
                }
                if script == "Hans", let hit = allowed.first(where: { $0 == .zhHans }) {
                    return hit
                }
                if let hit = allowed.first(where: { $0 == .zhHant }) {
                    return hit
                }
                continue
            }
            if let hit = allowed.first(where: { $0.rawValue.hasPrefix(lang) }) {
                return hit
            }
        }
        return nil
    }

    // MARK: - UserDefaults + iCloud KV persistence (with LWW timestamp)
    //
    // Storage layers:
    //   - UserDefaults (local truth, fastest read)
    //   - NSUbiquitousKeyValueStore via CloudPreferencesSync (cross-device LWW)
    //   - `*_updated_at` timestamps (Double, seconds since 1970) drive LWW
    //
    // Server responses and local writes share the translation group's
    // `updated_at` clock. Accepted server state updates the local cache only;
    // local/iCloud writes remain responsible for publishing user edits.

    private static let sourceKey = "translation_source_lang"
    private static let targetKey = "translation_target_lang"
    private static let sourceUpdatedAtKey = "translation_source_lang_updated_at"
    private static let targetUpdatedAtKey = "translation_target_lang_updated_at"

    private final class PersistenceContext {
        let lock = NSLock()
        var defaults: UserDefaults = .standard
        var cloud: CloudKeyValueStore = CloudPreferencesSync.shared
        var accountID: String?
        var isAccountBoundarySuspended = false
    }

    private static let persistence = PersistenceContext()

    /// Select the persistence namespace used by the process-wide language API.
    /// The existing nil namespace remains the guest/preview compatibility path.
    static func activateAccount(
        _ accountID: String?,
        defaults: UserDefaults = .standard,
        cloud: CloudKeyValueStore = CloudPreferencesSync.shared
    ) {
        withPersistence { context in
            let normalizedAccountID = AccountPreferenceNamespace.normalizedAccountID(accountID)
            if let normalizedAccountID {
                migrateLegacyPreferences(
                    defaults: defaults,
                    cloud: cloud,
                    accountID: normalizedAccountID
                )
            }
            context.defaults = defaults
            context.cloud = cloud
            context.accountID = normalizedAccountID
            context.isAccountBoundarySuspended = false
        }
    }

    /// Hide the previous account's pair until the next account is explicitly
    /// activated. No persistent value is removed.
    static func suspendForAccountBoundary() {
        withPersistence { context in
            context.accountID = nil
            context.isAccountBoundarySuspended = true
        }
    }

    static var currentSource: TranslationLanguage {
        get {
            withPersistence { context in
                guard !context.isAccountBoundarySuspended else { return resolveSourceDefault() }
                return readPersisted(
                    key: sourceKey,
                    updatedAtKey: sourceUpdatedAtKey,
                    defaults: context.defaults,
                    cloud: context.cloud,
                    accountID: context.accountID,
                    fallback: { resolveSourceDefault() }
                )
            }
        }
        set {
            withPersistence { context in
                guard !context.isAccountBoundarySuspended else { return }
                writePersisted(
                    value: newValue,
                    key: sourceKey,
                    updatedAtKey: sourceUpdatedAtKey,
                    defaults: context.defaults,
                    cloud: context.cloud,
                    accountID: context.accountID
                )
            }
        }
    }

    static var currentTarget: TranslationLanguage {
        get {
            withPersistence { context in
                guard !context.isAccountBoundarySuspended else { return resolveTargetDefault() }
                return readPersisted(
                    key: targetKey,
                    updatedAtKey: targetUpdatedAtKey,
                    defaults: context.defaults,
                    cloud: context.cloud,
                    accountID: context.accountID,
                    fallback: { resolveTargetDefault() }
                )
            }
        }
        set {
            withPersistence { context in
                guard !context.isAccountBoundarySuspended else { return }
                writePersisted(
                    value: newValue,
                    key: targetKey,
                    updatedAtKey: targetUpdatedAtKey,
                    defaults: context.defaults,
                    cloud: context.cloud,
                    accountID: context.accountID
                )
            }
        }
    }

    /// Timestamp (seconds since 1970) of the last local write, used for LWW.
    /// `nil` if the value has never been written on this device or via iCloud.
    static var sourceUpdatedAt: Double? {
        withPersistence { context in
            guard !context.isAccountBoundarySuspended else { return nil }
            return updatedAt(
                key: sourceUpdatedAtKey,
                defaults: context.defaults,
                cloud: context.cloud,
                accountID: context.accountID
            )
        }
    }

    static var targetUpdatedAt: Double? {
        withPersistence { context in
            guard !context.isAccountBoundarySuspended else { return nil }
            return updatedAt(
                key: targetUpdatedAtKey,
                defaults: context.defaults,
                cloud: context.cloud,
                accountID: context.accountID
            )
        }
    }

    // MARK: - Default resolution

    private static func resolveSourceDefault() -> TranslationLanguage {
        inferFromPreferredLanguages(allowed: sourceLanguages) ?? .en
    }

    private static func resolveTargetDefault() -> TranslationLanguage {
        inferFromPreferredLanguages(allowed: targetLanguages) ?? .zhHant
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
            feature: "translation-language"
        ) {
            for key in [sourceKey, targetKey, sourceUpdatedAtKey, targetUpdatedAtKey] {
                AccountPreferenceNamespace.copyLegacyObject(
                    key,
                    defaults: defaults,
                    accountID: accountID
                )
            }
            for key in [sourceKey, targetKey] {
                AccountPreferenceNamespace.copyLegacyCloudString(
                    key,
                    cloud: cloud,
                    accountID: accountID
                )
            }
            for key in [sourceUpdatedAtKey, targetUpdatedAtKey] {
                AccountPreferenceNamespace.copyLegacyCloudDouble(
                    key,
                    cloud: cloud,
                    accountID: accountID
                )
            }
        }
    }

    private static func readPersisted(
        key: String,
        updatedAtKey: String,
        defaults: UserDefaults,
        cloud: CloudKeyValueStore,
        accountID: String?,
        fallback: () -> TranslationLanguage
    ) -> TranslationLanguage {
        let localKey = AccountPreferenceNamespace.key(key, accountID: accountID)
        let updatedAtStorageKey = AccountPreferenceNamespace.key(updatedAtKey, accountID: accountID)
        let localRaw = defaults.string(forKey: localKey)
        let cloudRaw = cloud.string(forKey: localKey)
        let localUpdatedAt = defaults.object(forKey: updatedAtStorageKey) as? Double
        let cloudUpdatedAt = cloud.double(forKey: updatedAtStorageKey)

        let resolvedRaw: String?
        switch (localUpdatedAt, cloudUpdatedAt) {
        case let (local?, cloud?):
            resolvedRaw = local >= cloud ? (localRaw ?? cloudRaw) : (cloudRaw ?? localRaw)
        case (.some, nil):
            resolvedRaw = localRaw ?? cloudRaw
        case (nil, .some):
            resolvedRaw = cloudRaw ?? localRaw
        case (nil, nil):
            // Preserve the historical cloud-first fallback when neither layer
            // has an LWW clock to compare.
            resolvedRaw = cloudRaw ?? localRaw
        }

        if let resolvedRaw, let lang = TranslationLanguage(rawValue: resolvedRaw) {
            return lang
        }
        return fallback()
    }

    private static func updatedAt(
        key: String,
        defaults: UserDefaults,
        cloud: CloudKeyValueStore,
        accountID: String?
    ) -> Double? {
        let storageKey = AccountPreferenceNamespace.key(key, accountID: accountID)
        let local = defaults.object(forKey: storageKey) as? Double
        let cloudValue = cloud.double(forKey: storageKey)
        return [local, cloudValue].compactMap { $0 }.max()
    }

    private static func writePersisted(
        value: TranslationLanguage,
        key: String,
        updatedAtKey: String,
        defaults: UserDefaults,
        cloud: CloudKeyValueStore,
        accountID: String?
    ) {
        writePersisted(
            value: value,
            key: key,
            updatedAtKey: updatedAtKey,
            timestamp: Date().timeIntervalSince1970,
            defaults: defaults,
            cloud: cloud,
            accountID: accountID
        )
    }

    /// Write with an explicit timestamp. Used by `restore(source:target:withTimestamps:)`
    /// so a rollback doesn't advance the LWW clock past a remote write that's
    /// already in iCloud KV from another device.
    private static func writePersisted(
        value: TranslationLanguage,
        key: String,
        updatedAtKey: String,
        timestamp: TimeInterval,
        defaults: UserDefaults,
        cloud: CloudKeyValueStore,
        accountID: String?
    ) {
        let storageKey = AccountPreferenceNamespace.key(key, accountID: accountID)
        let updatedAtStorageKey = AccountPreferenceNamespace.key(updatedAtKey, accountID: accountID)
        defaults.set(value.rawValue, forKey: storageKey)
        defaults.set(timestamp, forKey: updatedAtStorageKey)
        cloud.set(value.rawValue, forKey: storageKey)
        cloud.set(timestamp, forKey: updatedAtStorageKey)
    }

    /// Applies a server translation group when its timestamp is newer than both
    /// locally observed source/target timestamps. The server projection writes
    /// UserDefaults only, so accepting a response cannot publish it as a new
    /// iCloud user edit. Returns `true` only when the group was accepted.
    @discardableResult
    static func applyServer(
        source: TranslationLanguage,
        target: TranslationLanguage,
        serverUpdatedAt: TimeInterval
    ) -> Bool {
        withPersistence { context in
            guard !context.isAccountBoundarySuspended else { return false }
            let localUpdatedAt = [
                updatedAt(
                    key: sourceUpdatedAtKey,
                    defaults: context.defaults,
                    cloud: context.cloud,
                    accountID: context.accountID
                ),
                updatedAt(
                    key: targetUpdatedAtKey,
                    defaults: context.defaults,
                    cloud: context.cloud,
                    accountID: context.accountID
                )
            ].compactMap { $0 }.max()
            if let localUpdatedAt, serverUpdatedAt <= localUpdatedAt {
                return false
            }

            context.defaults.set(
                source.rawValue,
                forKey: AccountPreferenceNamespace.key(sourceKey, accountID: context.accountID)
            )
            context.defaults.set(
                serverUpdatedAt,
                forKey: AccountPreferenceNamespace.key(sourceUpdatedAtKey, accountID: context.accountID)
            )
            context.defaults.set(
                target.rawValue,
                forKey: AccountPreferenceNamespace.key(targetKey, accountID: context.accountID)
            )
            context.defaults.set(
                serverUpdatedAt,
                forKey: AccountPreferenceNamespace.key(targetUpdatedAtKey, accountID: context.accountID)
            )
            return true
        }
    }

    /// Restore previously-snapshotted source/target with their original
    /// timestamps. Use this on remote-update rollback so the rolled-back
    /// values don't appear to be "newer than" concurrent writes from other
    /// devices in iCloud KV's LWW.
    /// `nil` timestamp means the snapshot was taken when no write had ever
    /// happened — in that case we clear the persistence layers entirely.
    static func restore(
        source: TranslationLanguage,
        sourceUpdatedAt: TimeInterval?,
        target: TranslationLanguage,
        targetUpdatedAt: TimeInterval?
    ) {
        withPersistence { context in
            guard !context.isAccountBoundarySuspended else { return }
            if let ts = sourceUpdatedAt {
                writePersisted(
                    value: source,
                    key: sourceKey,
                    updatedAtKey: sourceUpdatedAtKey,
                    timestamp: ts,
                    defaults: context.defaults,
                    cloud: context.cloud,
                    accountID: context.accountID
                )
            } else {
                // Best-effort: rollback when prev timestamp was nil means the user
                // was making their first-ever write to this setting and the remote
                // call failed. The setter already mirrored the failed value to
                // iCloud KV; we clear UserDefaults but cannot purge KV
                // (NSUbiquitousKeyValueStore has no removeObject API). We instead
                // write the resolved default back with timestamp=0 so any other
                // device with a real write (timestamp > 0) wins via LWW.
                context.defaults.removeObject(
                    forKey: AccountPreferenceNamespace.key(sourceKey, accountID: context.accountID)
                )
                context.defaults.removeObject(
                    forKey: AccountPreferenceNamespace.key(sourceUpdatedAtKey, accountID: context.accountID)
                )
                context.cloud.set(
                    source.rawValue,
                    forKey: AccountPreferenceNamespace.key(sourceKey, accountID: context.accountID)
                )
                context.cloud.set(
                    0.0,
                    forKey: AccountPreferenceNamespace.key(sourceUpdatedAtKey, accountID: context.accountID)
                )
            }
            if let ts = targetUpdatedAt {
                writePersisted(
                    value: target,
                    key: targetKey,
                    updatedAtKey: targetUpdatedAtKey,
                    timestamp: ts,
                    defaults: context.defaults,
                    cloud: context.cloud,
                    accountID: context.accountID
                )
            } else {
                context.defaults.removeObject(
                    forKey: AccountPreferenceNamespace.key(targetKey, accountID: context.accountID)
                )
                context.defaults.removeObject(
                    forKey: AccountPreferenceNamespace.key(targetUpdatedAtKey, accountID: context.accountID)
                )
                context.cloud.set(
                    target.rawValue,
                    forKey: AccountPreferenceNamespace.key(targetKey, accountID: context.accountID)
                )
                context.cloud.set(
                    0.0,
                    forKey: AccountPreferenceNamespace.key(targetUpdatedAtKey, accountID: context.accountID)
                )
            }
        }
    }

    private static func withPersistence<T>(_ operation: (PersistenceContext) -> T) -> T {
        persistence.lock.lock()
        defer { persistence.lock.unlock() }
        return operation(persistence)
    }
}
