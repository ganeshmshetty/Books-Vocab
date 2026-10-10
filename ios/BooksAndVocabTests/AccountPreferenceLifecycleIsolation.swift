import Foundation
import Testing
@testable import BooksAndVocab

/// An `AccountPreferenceLifecycle` that touches no process-wide state.
///
/// `AuthManager.init` activates the persisted account's preferences, and every
/// login/logout suspends or re-activates them. With the default
/// `AccountPreferenceLifecycleCoordinator` that reaches
/// `TranslationLanguage.activateAccount` / `suspendForAccountBoundary`, which
/// flips the account namespace under `TranslationLanguageTests` (serialized
/// only within its own suite tree) when parallel testing is on (#2117). Every
/// test-side `AuthManager` and `SettingsCoordinator` therefore injects this
/// instead.
final class NoopAccountPreferenceLifecycle: AccountPreferenceLifecycle {
    func activate(accountID: String?) {}
    func suspend() {}
}

/// Guards the convention above: a test that builds an `AuthManager` or a
/// `SettingsCoordinator` with the default lifecycle would silently reintroduce
/// the cross-suite race. `SettingsCoordinator` reaches the same
/// `TranslationLanguage` namespace through `loadData` / `resetForAccountBoundary`
/// and is injected via its `translationLifecycle:` seam (#2117).
struct AccountPreferenceLifecycleIsolationTests {
    @Test func everyTestAuthManagerInjectsAnAccountPreferenceLifecycle() throws {
        let scan = try Self.scanTestSources(constructor: "AuthManager" + "(", requiredLabel: "accountPreferenceLifecycle:")
        // Positive control: the scan really sees the known construction sites.
        #expect(scan.constructions >= 5, "scan found only \(scan.constructions) AuthManager constructions")
        #expect(scan.offenders.isEmpty, "AuthManager built with the default (global-state) lifecycle in: \(scan.offenders)")
    }

    @Test func everyTestSettingsCoordinatorInjectsATranslationLifecycle() throws {
        let scan = try Self.scanTestSources(constructor: "SettingsCoordinator" + "(", requiredLabel: "translationLifecycle:")
        #expect(scan.constructions >= 10, "scan found only \(scan.constructions) SettingsCoordinator constructions")
        #expect(scan.offenders.isEmpty, "SettingsCoordinator built with the default (global-state) translation lifecycle in: \(scan.offenders)")
    }

    private static func scanTestSources(
        constructor: String,
        requiredLabel: String
    ) throws -> (constructions: Int, offenders: [String]) {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let ownName = URL(fileURLWithPath: #filePath).lastPathComponent
        let files = try FileManager.default.contentsOfDirectory(
            at: testsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" && $0.lastPathComponent != ownName }
        #expect(!files.isEmpty)

        var constructions = 0
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for call in calls(of: constructor, in: source) {
                constructions += 1
                if !call.contains(requiredLabel) { offenders.append(file.lastPathComponent) }
            }
        }
        return (constructions, offenders)
    }

    /// Source text of each `constructor` call (through its balanced closing
    /// paren), skipping comment lines and longer identifiers such as
    /// `TestAuthManager(`.
    private static func calls(of constructor: String, in source: String) -> [String] {
        var results: [String] = []
        var searchStart = source.startIndex
        while let range = source.range(of: constructor, range: searchStart..<source.endIndex) {
            searchStart = range.upperBound
            if range.lowerBound > source.startIndex {
                let previous = source[source.index(before: range.lowerBound)]
                if previous.isLetter || previous.isNumber || previous == "_" { continue }
            }
            let lineStart = source[..<range.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
            if source[lineStart..<range.lowerBound].trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            var depth = 1
            var cursor = range.upperBound
            while cursor < source.endIndex, depth > 0 {
                if source[cursor] == "(" { depth += 1 } else if source[cursor] == ")" { depth -= 1 }
                cursor = source.index(after: cursor)
            }
            results.append(String(source[range.lowerBound..<cursor]))
        }
        return results
    }
}

/// #2556: delete_account purges every account-namespaced preference from
/// UserDefaults and the iCloud KVS, but keeps the legacy-migration markers so a
/// later account cannot re-adopt the pre-account raw values.
struct AccountPreferenceNamespacePurgeTests {
    private final class PurgeCloudSpy: CloudKeyValueStore {
        var values: [String: String] = [:]

        func double(forKey key: String) -> Double? { nil }
        func set(_ value: Double, forKey key: String) {}
        func string(forKey key: String) -> String? { values[key] }
        func set(_ value: String, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
        func allKeys() -> [String] { Array(values.keys) }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "test.account-namespace-purge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func deleteAccountPurgesNamespacedKeysInBothLayersAndKeepsMarkersAndLegacyKeys() {
        let defaults = makeDefaults()
        let cloud = PurgeCloudSpy()
        let namespaced = AccountPreferenceNamespace.key("review_settings_mode", accountID: "account-a")
        let marker = AccountPreferenceNamespace.legacyMigrationMarker(feature: "review-card-layout")
        defaults.set("compact", forKey: namespaced)
        defaults.set(true, forKey: marker)
        defaults.set("legacy", forKey: "review_settings_mode")
        cloud.set("cloud-a", forKey: namespaced)
        cloud.set("cloud-legacy", forKey: "review_settings_mode")

        AccountPreferenceNamespace.purgeNamespacedPreferences(accountID: "account-a", defaults: defaults, cloud: cloud)

        #expect(defaults.object(forKey: namespaced) == nil)
        #expect(cloud.string(forKey: namespaced) == nil)
        #expect(defaults.bool(forKey: marker))
        #expect(defaults.string(forKey: "review_settings_mode") == "legacy")
        #expect(cloud.string(forKey: "review_settings_mode") == "cloud-legacy")
    }

    @Test func purgeIsIdempotentOnAnEmptyDevice() {
        let defaults = makeDefaults()
        let cloud = PurgeCloudSpy()
        AccountPreferenceNamespace.purgeNamespacedPreferences(accountID: "account-a", defaults: defaults, cloud: cloud)
        AccountPreferenceNamespace.purgeNamespacedPreferences(accountID: "account-a", defaults: defaults, cloud: cloud)
        #expect(cloud.values.isEmpty)
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("kg.account.") })
    }

    /// #2434: deleting account B must not erase account A's preferences on the
    /// same device (local defaults and iCloud KVS).
    @Test func deleteAccountLeavesOtherAccountsNamespacedPreferencesIntact() {
        let defaults = makeDefaults()
        let cloud = PurgeCloudSpy()
        let keyA = AccountPreferenceNamespace.key("review_settings_mode", accountID: "account-a")
        let keyB = AccountPreferenceNamespace.key("review_settings_mode", accountID: "account-b")
        defaults.set("compact", forKey: keyA)
        defaults.set("standard", forKey: keyB)
        cloud.set("cloud-a", forKey: keyA)
        cloud.set("cloud-b", forKey: keyB)

        AccountPreferenceNamespace.purgeNamespacedPreferences(accountID: "account-b", defaults: defaults, cloud: cloud)

        #expect(defaults.object(forKey: keyB) == nil)
        #expect(cloud.string(forKey: keyB) == nil)
        #expect(defaults.string(forKey: keyA) == "compact")
        #expect(cloud.string(forKey: keyA) == "cloud-a")
    }
}

/// #2434: the logout / delete_account cleanup must reach the account-preference purge
/// through `LocalDataCleanerService.purgeAccountPreferences`, which takes injected stores
/// so the test never touches the shared singletons or the real Documents tree.
struct LocalDataCleanerAccountPreferenceTests {
    private final class CleanerCloudSpy: CloudKeyValueStore {
        var values: [String: String] = [:]

        func double(forKey key: String) -> Double? { nil }
        func set(_ value: Double, forKey key: String) {}
        func string(forKey key: String) -> String? { values[key] }
        func set(_ value: String, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
        func allKeys() -> [String] { Array(values.keys) }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "test.local-data-cleaner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func deleteAccountPurgesOnlyTheDeletedAccountNamespace() {
        let defaults = makeDefaults()
        let cloud = CleanerCloudSpy()
        let keyA = AccountPreferenceNamespace.key("review_settings_mode", accountID: "account-a")
        let keyB = AccountPreferenceNamespace.key("review_settings_mode", accountID: "account-b")
        defaults.set("compact", forKey: keyA)
        defaults.set("standard", forKey: keyB)
        cloud.set("cloud-b", forKey: keyB)

        LocalDataCleanerService.purgeAccountPreferences(
            deletedAccountID: "account-b", defaults: defaults, cloud: cloud
        )

        #expect(defaults.object(forKey: keyB) == nil)
        #expect(cloud.string(forKey: keyB) == nil)
        #expect(defaults.string(forKey: keyA) == "compact")
    }

    /// Sign-out (no deleted account) drops only the adopted local raw layout; the KVS raw
    /// key and the namespaced layout survive.
    @Test func signOutPurgeDropsAdoptedRawLocalCopyOnly() {
        let defaults = makeDefaults()
        let cloud = CleanerCloudSpy()
        let rawKey = ReviewCardLayoutStore.storageKey
        let marker = AccountPreferenceNamespace.legacyMigrationMarker(feature: "review-card-layout")
        let namespaced = AccountPreferenceNamespace.key(rawKey, accountID: "account-a")
        defaults.set("raw", forKey: rawKey)
        defaults.set(true, forKey: marker)
        defaults.set("own", forKey: namespaced)
        cloud.set("raw-cloud", forKey: rawKey)

        LocalDataCleanerService.purgeAccountPreferences(
            deletedAccountID: nil, defaults: defaults, cloud: cloud
        )

        #expect(defaults.object(forKey: rawKey) == nil)
        #expect(cloud.string(forKey: rawKey) == "raw-cloud")
        #expect(defaults.string(forKey: namespaced) == "own")
        #expect(defaults.bool(forKey: marker))
    }
}
