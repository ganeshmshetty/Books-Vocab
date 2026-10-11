import Foundation
import Testing
@testable import BooksAndVocab

/// 計數 spy：`clearLocalCache` 注入點的呼叫次數即刪檔次數。
@MainActor
private final class ClearLocalCacheSpy {
    private(set) var calls = 0
    let result: Bool

    init(result: Bool = true) {
        self.result = result
    }

    func clear() async -> Bool {
        calls += 1
        return result
    }
}

/// #2743 — clearing the local cache in startup recovery deletes LocalStore files that may hold
/// unsynced rows, so the button must only present confirmation; the destructive action runs only
/// from the confirmed dialog path.
@MainActor
struct AppStartupRecoveryViewTests {
    @Test func clearCacheButtonOnlyPresentsConfirmation() {
        var gate = AppStartupClearCacheGate()
        #expect(!gate.isPresented)
        #expect(gate.tap() == .presentConfirmation)
        #expect(gate.isPresented)
    }

    @Test func clearCacheButtonNeverReturnsClearEffect() {
        var gate = AppStartupClearCacheGate()
        #expect(gate.tap() != .clearLocalCache)
        #expect(gate.tap() != .clearLocalCache)
    }

    @Test func confirmIsTheOnlyPathToClearEffect() {
        var gate = AppStartupClearCacheGate()
        _ = gate.tap()
        #expect(gate.confirm() == .clearLocalCache)
        #expect(!gate.isPresented)
    }

    @Test func cancelHidesConfirmationWithoutClearing() {
        var gate = AppStartupClearCacheGate()
        _ = gate.tap()
        #expect(gate.cancel() == AppStartupClearCacheGate.Effect.none)
        #expect(!gate.isPresented)
    }

    /// 按鈕行為守護：點按鈕只能呈現確認，注入的 clearLocalCache 必須 0 次呼叫。
    /// 清除入口只有 `confirmDialog()` 一條（view 不再持有 clearLocalCache），因此「按鈕直接清除」
    /// 的回歸必須經由 `confirmDialog()` 接線才可能發生；view 接線本身無單元測試可觀察。
    @Test func tappingClearCacheButtonNeverInvokesClearLocalCache() {
        let spy = ClearLocalCacheSpy()
        let flow = AppStartupClearCacheFlow(clearLocalCache: { await spy.clear() })
        flow.tapButton()
        flow.tapButton()
        #expect(flow.isPresented)
        #expect(spy.calls == 0)
    }

    @Test func confirmingDialogInvokesClearLocalCacheExactlyOnce() async {
        let spy = ClearLocalCacheSpy()
        let flow = AppStartupClearCacheFlow(clearLocalCache: { await spy.clear() })
        flow.tapButton()
        let cleared = await flow.confirmDialog()
        #expect(cleared == true)
        #expect(spy.calls == 1)
        #expect(!flow.isPresented)
    }

    @Test func dismissingDialogNeverInvokesClearLocalCache() {
        let spy = ClearLocalCacheSpy()
        let flow = AppStartupClearCacheFlow(clearLocalCache: { await spy.clear() })
        flow.tapButton()
        flow.dismissDialog()
        #expect(!flow.isPresented)
        #expect(spy.calls == 0)
    }

    @Test func failedClearIsReportedFromConfirmedPath() async {
        let spy = ClearLocalCacheSpy(result: false)
        let flow = AppStartupClearCacheFlow(clearLocalCache: { await spy.clear() })
        flow.tapButton()
        let cleared = await flow.confirmDialog()
        #expect(cleared == false)
        #expect(spy.calls == 1)
    }

    /// 每個 shipped locale 必須自己持有這些鍵。走 `L10n.string` 會回落到 en，缺譯的 ja/ko/zh-Hans
    /// 會假綠，故用 `fallback: nil`（同 NotebookPaletteTests 的嚴格契約）。zh-Hant 以原文為鍵，不在此檢查。
    @Test func confirmationCopyResolvesInEveryShippedLocaleWithoutEnglishFallback() {
        let keys = [
            AppStartupClearCacheGate.titleKey,
            AppStartupClearCacheGate.messageKey,
            AppStartupClearCacheGate.confirmKey,
            AppStartupFailure.clearCacheRecoveryStepKey
        ]
        for language in AppLanguage.allCases where language != .system && language != .traditionalChinese {
            let bundle = AppLanguageStore.shared.stringBundle(for: language)
            for key in keys {
                #expect(L10n.lookup(key, in: bundle, fallback: nil) != key, "untranslated \(key) for \(language.rawValue)")
            }
        }
    }

    /// 文案必須涵蓋 `AppBootstrap.purgeStoreFiles` 實際刪除的全部未同步本機資料：LocalStore 整檔
    /// （單字、筆記本、複習紀錄、播客、共享牌組、設定投影）與 CloudStore 內未同步的列（書籍、播客進度）。
    /// 只點名部分類型會讓使用者低估風險。每個 marker 是該語系獨有的譯文片段，英文回落無法滿足。
    @Test func confirmationCopyCoversAllUnsyncedLocalData() {
        let scopeMarkers: [AppLanguage: String] = [
            .english: "All local data that has not synced",
            .japanese: "クラウドに同期されていないすべてのローカルデータ",
            .korean: "클라우드에 동기화되지 않은 모든 로컬 데이터",
            .simplifiedChinese: "所有尚未同步到云端的本机数据",
            .traditionalChinese: "所有尚未同步到雲端的本機資料"
        ]
        for (language, marker) in scopeMarkers {
            #expect(
                L10n.string(AppStartupClearCacheGate.messageKey, language: language).contains(marker),
                "\(language.rawValue) confirmation message does not cover all unsynced local data"
            )
            #expect(
                L10n.string(AppStartupFailure.clearCacheRecoveryStepKey, language: language).contains(marker),
                "\(language.rawValue) recovery step does not cover all unsynced local data"
            )
        }
        #expect(L10n.string(AppStartupClearCacheGate.messageKey, language: .traditionalChinese).contains("書籍與播客"))
    }

    @Test func recoveryStepWarnsBeforeTapAboutPermanentLoss() {
        let failure = AppStartupFailure.storageInitialization(error: NSError(domain: "test", code: 1))
        #expect(failure.recoverySteps.contains(L10n.string(AppStartupFailure.clearCacheRecoveryStepKey)))
        #expect(L10n.string(AppStartupFailure.clearCacheRecoveryStepKey, language: .traditionalChinese).contains("永久刪除"))
    }
}
