#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

struct SettingsDeleteAccountCopyTests {

    @Test func deleteButtonTitle_handlesDeletingCountdownAndDefaultStates() {
        #expect(
            SettingsDeleteAccountCopy.deleteButtonTitle(
                isDeleting: true,
                countdownRemaining: 3,
                isReadyForCountdown: true
            ) == L10n.string("刪除中…")
        )
        #expect(
            SettingsDeleteAccountCopy.deleteButtonTitle(
                isDeleting: false,
                countdownRemaining: 3,
                isReadyForCountdown: true
            ) == L10n.format("等候 %@ 秒…", "3")
        )
        #expect(
            SettingsDeleteAccountCopy.deleteButtonTitle(
                isDeleting: false,
                countdownRemaining: 0,
                isReadyForCountdown: true
            ) == L10n.string("永久刪除帳號")
        )
    }

    @Test func destructiveCopy_staysStable() {
        #expect(SettingsDeleteAccountCopy.navigationTitle == L10n.string("確認刪除帳號"))
        #expect(SettingsDeleteAccountCopy.heroTitle == L10n.string("此操作不可復原"))
        #expect(SettingsDeleteAccountCopy.consequencesTitle == L10n.string("將被永久刪除的資料"))
        #expect(SettingsDeleteAccountCopy.acknowledgementsTitle == L10n.string("請確認你已知悉"))
        #expect(SettingsDeleteAccountCopy.confirmationTitle == L10n.string("輸入確認字串"))
        #expect(SettingsDeleteAccountCopy.cancelTitle == L10n.string("取消"))
    }

    /// Delete wipes only the server-side `users/<uid>/library.db`; the local Book rows and files
    /// are kept (BackgroundSyncActor), so the copy must scope the bookshelf and progress to cloud.
    @Test func consequenceRowsScopeReadingProgressAndBookshelfToCloud() {
        let rows = SettingsDeleteAccountCopy.consequenceRows.map(\.text)
        #expect(rows.contains(L10n.string("雲端閱讀進度與書架")))
        #expect(!rows.contains(L10n.string("閱讀進度與書架")))
        #expect(
            SettingsDeleteAccountCopy.heroDescription
                == L10n.string("刪除後將立即移除你的帳號、雲端生詞、雲端閱讀進度與書架、訂閱記錄。請仔細確認下列項目後才能繼續。")
        )
    }

    @Test func consequenceAndAcknowledgementLists_keepExpectedItems() {
        #expect(SettingsDeleteAccountCopy.consequenceRows.count == 5)
        #expect(SettingsDeleteAccountCopy.acknowledgementRows.count == 3)
        #expect(SettingsDeleteAccountCopy.consequenceRows[0].text == L10n.string("帳號資訊與登入記錄"))
        #expect(SettingsDeleteAccountCopy.acknowledgementRows[2] == L10n.string("我了解資料一旦刪除即無法經由客服救回"))
        #expect(
            SettingsDeleteAccountCopy.confirmationPrompt(phrase: "DELETE")
                == L10n.format("為避免誤觸，請輸入 %@ 後繼續：", "DELETE")
        )
    }

    /// #2556 acceptance 3: the sheet's cloud-scope promise must match what delete_account purges,
    /// not only the copy strings. The deleted account's namespaced preferences disappear from both
    /// UserDefaults and KVS, another account's copy survives, and the copy declares the cloud scope.
    @Test func deleteAccountPurge_matchesTheCloudScopeTheCopyDeclares() {
        let suite = "test.delete-copy-scope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let cloud = DeleteScopeCloudSpy()
        let features = ["review_settings_mode", ReviewCardLayoutStore.storageKey]
        for feature in features {
            let deleted = AccountPreferenceNamespace.key(feature, accountID: "account-b")
            let kept = AccountPreferenceNamespace.key(feature, accountID: "account-a")
            defaults.set("deleted", forKey: deleted)
            cloud.set("deleted", forKey: deleted)
            defaults.set("kept", forKey: kept)
            cloud.set("kept", forKey: kept)
        }

        LocalDataCleanerService.purgeAccountPreferences(
            deletedAccountID: "account-b", defaults: defaults, cloud: cloud
        )

        for feature in features {
            let deleted = AccountPreferenceNamespace.key(feature, accountID: "account-b")
            let kept = AccountPreferenceNamespace.key(feature, accountID: "account-a")
            #expect(defaults.object(forKey: deleted) == nil)
            #expect(cloud.string(forKey: deleted) == nil)
            #expect(defaults.string(forKey: kept) == "kept")
            #expect(cloud.string(forKey: kept) == "kept")
        }
        let rows = SettingsDeleteAccountCopy.consequenceRows.map(\.text)
        #expect(rows.contains(L10n.string("雲端閱讀進度與書架")))
        #expect(!rows.contains(L10n.string("閱讀進度與書架")))
    }
}

private final class DeleteScopeCloudSpy: CloudKeyValueStore {
    var values: [String: String] = [:]

    func double(forKey key: String) -> Double? { nil }
    func set(_ value: Double, forKey key: String) {}
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    func allKeys() -> [String] { Array(values.keys) }
}
#endif
