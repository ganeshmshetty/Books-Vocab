import Testing
@testable import BooksAndVocab

/// #2743 — clearing the local cache in startup recovery deletes LocalStore files that may hold
/// unsynced rows, so the button must only request confirmation; the destructive action runs after confirm.
@MainActor
struct AppStartupRecoveryViewTests {
    @Test func requestDoesNotRunUntilConfirmed() {
        var gate = AppStartupClearCacheGate()
        #expect(!gate.isPresented)
        gate.request()
        #expect(gate.isPresented)
        let confirmed = gate.confirm()
        #expect(confirmed)
        #expect(!gate.isPresented)
    }

    @Test func confirmWithoutRequestIsRejected() {
        var gate = AppStartupClearCacheGate()
        let confirmed = gate.confirm()
        #expect(!confirmed)
    }

    @Test func cancelDismissesWithoutRunning() {
        var gate = AppStartupClearCacheGate()
        gate.request()
        gate.cancel()
        #expect(!gate.isPresented)
        let confirmed = gate.confirm()
        #expect(!confirmed)
    }

    @Test func confirmationCopyIsLocalizedAndWarnsAboutUnsyncedData() {
        for language in AppLanguage.allCases where language != .system && language != .traditionalChinese {
            for key in [AppStartupClearCacheGate.titleKey, AppStartupClearCacheGate.messageKey, AppStartupClearCacheGate.confirmKey] {
                #expect(L10n.string(key, language: language) != key, "untranslated \(key) for \(language.rawValue)")
            }
        }
        #expect(L10n.string(AppStartupClearCacheGate.messageKey, language: .traditionalChinese).contains("尚未同步"))
    }
}
