import Testing
@testable import BooksAndVocab

/// #2743 — clearing the local cache in startup recovery deletes LocalStore files that may hold
/// unsynced rows, so the button must only present confirmation; the destructive action runs only
/// from the confirmed dialog path.
@MainActor
struct AppStartupRecoveryViewTests {
    @Test func clearCacheButtonOnlyPresentsConfirmation() {
        var gate = AppStartupClearCacheGate()
        #expect(!gate.isPresented)
        gate.request()
        #expect(gate.isPresented)
    }

    @Test func dismissHidesConfirmationWithoutRunning() {
        var gate = AppStartupClearCacheGate()
        gate.request()
        gate.dismiss()
        #expect(!gate.isPresented)
    }

    @Test func confirmationCopyIsLocalizedAndWarnsAboutUnsyncedData() {
        let keys = [
            AppStartupClearCacheGate.titleKey,
            AppStartupClearCacheGate.messageKey,
            AppStartupClearCacheGate.confirmKey,
            AppStartupFailure.clearCacheRecoveryStepKey
        ]
        for language in AppLanguage.allCases where language != .system && language != .traditionalChinese {
            for key in keys {
                #expect(L10n.string(key, language: language) != key, "untranslated \(key) for \(language.rawValue)")
            }
        }
        #expect(L10n.string(AppStartupClearCacheGate.messageKey, language: .traditionalChinese).contains("單字、筆記本與複習紀錄"))
        #expect(L10n.string(AppStartupFailure.clearCacheRecoveryStepKey, language: .traditionalChinese).contains("永久刪除"))
    }

    @Test func recoveryStepWarnsBeforeTapAboutPermanentLoss() {
        let failure = AppStartupFailure.storageInitialization(error: NSError(domain: "test", code: 1))
        #expect(failure.recoverySteps.contains(L10n.string(AppStartupFailure.clearCacheRecoveryStepKey)))
        #expect(L10n.string(AppStartupFailure.clearCacheRecoveryStepKey, language: .traditionalChinese).contains("永久刪除"))
    }
}
