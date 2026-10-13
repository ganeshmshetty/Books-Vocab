import Foundation
import Testing
@testable import BooksAndVocab

@Suite("AutoLinkSettingsStore")
struct AutoLinkSettingsTests {
    @Test func defaultIsEnabled() {
        // 對齊後端缺省語意：config 無 auto_link group 視同開啟。
        let store = AutoLinkSettingsStore(defaults: .makeSuite())
        #expect(store.isEnabled == true)
        #expect(store.updatedAt == nil)
    }

    @Test func togglePersistsWithTimestamp() {
        let defaults = UserDefaults.makeSuite()
        let store = AutoLinkSettingsStore(defaults: defaults)
        store.setEnabled(false, updatedAt: 100.0)
        #expect(store.isEnabled == false)
        #expect(store.updatedAt == 100.0)

        let store2 = AutoLinkSettingsStore(defaults: defaults)
        #expect(store2.isEnabled == false)
        #expect(store2.updatedAt == 100.0)
    }

    @Test func applyServerWhenNeverWrittenLocally() {
        let store = AutoLinkSettingsStore(defaults: .makeSuite())
        store.applyServer(enabled: false, updatedAt: 50.0)
        #expect(store.isEnabled == false)
        #expect(store.updatedAt == 50.0)
    }

    @Test func applyServerNewerWins() {
        let store = AutoLinkSettingsStore(defaults: .makeSuite())
        store.setEnabled(false, updatedAt: 100.0)
        store.applyServer(enabled: true, updatedAt: 200.0)
        #expect(store.isEnabled == true)
        #expect(store.updatedAt == 200.0)
    }

    @Test func applyServerOlderIsIgnored() {
        let store = AutoLinkSettingsStore(defaults: .makeSuite())
        store.setEnabled(false, updatedAt: 300.0)
        store.applyServer(enabled: true, updatedAt: 200.0)
        #expect(store.isEnabled == false)
        #expect(store.updatedAt == 300.0)
    }

    @Test func applyServerNilTimestampIsIgnoredAfterLocalWrite() {
        // server 從未寫過（updated_at=nil）不能蓋掉本地已寫的值。
        let store = AutoLinkSettingsStore(defaults: .makeSuite())
        store.setEnabled(false, updatedAt: 300.0)
        store.applyServer(enabled: true, updatedAt: nil)
        #expect(store.isEnabled == false)
        #expect(store.updatedAt == 300.0)
    }

    @Test func applyServerNilTimestampAppliesWhenLocalNeverWritten() {
        // local 從未寫過 + server 也從未寫過（ts nil）→ 套值、時戳維持 nil
        // （之後任何帶時戳的 server 值仍可套用）。
        let store = AutoLinkSettingsStore(defaults: .makeSuite())
        store.applyServer(enabled: false, updatedAt: nil)
        #expect(store.isEnabled == false)
        #expect(store.updatedAt == nil)
    }

    @Test func applyServerEqualTimestampIsIgnored() {
        // tie（serverTs == local）→ 本地留（嚴格大於才套）。
        let store = AutoLinkSettingsStore(defaults: .makeSuite())
        store.setEnabled(false, updatedAt: 300.0)
        store.applyServer(enabled: true, updatedAt: 300.0)
        #expect(store.isEnabled == false)
        #expect(store.updatedAt == 300.0)
    }

    @Test func restoreRevertsValueAndTimestamp() {
        // rollback 不可被當成新寫入（時戳必須還原，否則 LWW 會誤判 rollback 較新）。
        let defaults = UserDefaults.makeSuite()
        let store = AutoLinkSettingsStore(defaults: defaults)
        store.setEnabled(false, updatedAt: 100.0)
        store.setEnabled(true, updatedAt: 200.0)
        store.restore(enabled: false, updatedAt: 100.0)
        #expect(store.isEnabled == false)
        #expect(store.updatedAt == 100.0)

        let store2 = AutoLinkSettingsStore(defaults: defaults)
        #expect(store2.isEnabled == false)
        #expect(store2.updatedAt == 100.0)
    }

    @Test func restoreToNeverWritten() {
        let defaults = UserDefaults.makeSuite()
        let store = AutoLinkSettingsStore(defaults: defaults)
        store.setEnabled(false, updatedAt: 100.0)
        store.restore(enabled: true, updatedAt: nil)
        #expect(store.isEnabled == true)
        #expect(store.updatedAt == nil)

        let store2 = AutoLinkSettingsStore(defaults: defaults)
        #expect(store2.isEnabled == true)
        #expect(store2.updatedAt == nil)
    }
}

private extension UserDefaults {
    static func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "test-auto-link-\(UUID().uuidString)")!
    }
}

extension AutoLinkSettingsTests {
    @Test func accountNamespaceKeepsGuestKeysUntouched() {
        let defaults = UserDefaults.makeSuite()
        let store = AutoLinkSettingsStore(defaults: defaults, accountID: "account-a")
        store.setEnabled(false, updatedAt: 100.0)
        #expect(defaults.object(forKey: "auto_link_enabled") == nil)

        let reopened = AutoLinkSettingsStore(defaults: defaults, accountID: "account-a")
        #expect(reopened.isEnabled == false)
        #expect(reopened.updatedAt == 100.0)
    }
}
