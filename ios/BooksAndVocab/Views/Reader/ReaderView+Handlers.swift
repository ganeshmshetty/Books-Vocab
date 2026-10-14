#if os(iOS)
import SwiftUI
import ReadiumShared

extension ReaderView {
    func handleLocationChange(_ locator: Locator) {
        if !readerState.isWebViewReady {
            withAnimation(AppMotion.contentFade) { readerState.isWebViewReady = true }
        }
        readerState.runtime.markReady()
        pageTurn.currentLocator = locator
        let locatorProgression = ReaderProgressState.validProgression(locator.locations.totalProgression)
        readerState.runtime.recordLocationProgression(locatorProgression)

        // 序列化失敗時**不覆寫**既有值（避免舊 `"{}"` 污染下次還原），整筆 persist
        // 一併跳過，保留上次有效的 locator/progression 快照不致 JSON 與進度錯配。
        guard let json = ReaderProgressSaver.encodedLocatorJSON(locator) else { return }
        let snapshot = ReaderProgressPersistenceSnapshot(
            progression: locatorProgression,
            clock: readerState.clock
        )

        // in-memory 寫入立即（panel 即時讀取），落盤經 debounce coalesce —— 對齊 PDF
        // 路徑的顯式 save，但避開每頁同步 I/O 卡頓。
        progressSaver.recordChange {
            snapshot.apply(to: book, locatorJSON: json)
        } save: { [book, modelContext] in
            if modelContext.safeSave() {
                BookManifestStore().writeBestEffort(book: book)
            }
        }
    }

    func handleWordSelected(_ word: String, _ context: String) {
        guard canUseProReaderFeature() else { return }
        handler.handleWordSelected(
            word: word,
            context: context,
            vocabularyContext: vocabularyContext
        )
        presentTranslationOverlay()
    }

    func handlePhraseSelected(_ phrase: String, _ context: String) {
        guard canUseProReaderFeature() else { return }
        handler.handlePhraseSelected(
            phrase: phrase,
            context: context,
            vocabularyContext: vocabularyContext
        )
        presentTranslationOverlay()
    }

    private func presentTranslationOverlay() {
        withAnimation(AppMotion.panelState) { chromeState.overlay = .translation }
    }

    func handleMarkingProgress(_ progress: Double) {
        guard !readerState.hasCompletedInitialMarking else { return }
        withAnimation(AppMotion.progressLinear) {
            readerState.underlineProgress = progress
        }
        if progress >= 1.0 {
            PerfLog.reader.mark("firstHighlightComplete")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(ReaderMetrics.firstHighlightFadeOutDelay))
                withAnimation(AppMotion.contentFade) {
                    readerState.underlineProgress = nil
                }
                readerState.hasCompletedInitialMarking = true
            }
        }
    }

    func showReaderSettingsPanel() {
        withAnimation(AppMotion.panelState) {
            chromeState.overlay = .settings
            chromeState.header = .compact
        }
    }

    func expandHeader() {
        withAnimation(AppMotion.headerState) {
            chromeState.header = .expanded
        }
    }

    func collapseHeader() {
        withAnimation(AppMotion.headerState) {
            chromeState.header = .compact
        }
    }

    func closeOverlay(_ overlay: ReaderChromeOverlay) {
        guard chromeState.overlay == overlay else { return }
        chromeState.overlay = .none
    }

    func handleWordDeselected() {
        // translation overlay 走 dismiss，自帶清除語意，不需另發清高亮信號；
        // 其餘情況（settings / 無 overlay）統一在分支前設一次 clearHighlightTrigger，
        // dedup 掉 <1% fast-tap race 下重複觸發。
        //
        // 跨 tap race 備註：本 teardown 無條件關閉當前 .translation panel。理論上
        // 「tap-1 的 deselect 晚於 tap-2 的 wordTap 抵達」會誤關 tap-2 的新 panel。
        // 真正的防護來自主執行緒 WKScriptMessage 的 FIFO 送達（非單次 click 路徑互斥）；
        // Swift 未契約保證獨立 Task 順序，屬極低機率 latent race，最壞僅 panel 閃爍
        // 可重 tap 恢復 — 評估後不加 sequence nonce（成本>收益）。
        if chromeState.overlay == .translation {
            withAnimation(AppMotion.panelState) {
                handler.dismiss()
                closeOverlay(.translation)
            }
        } else {
            if chromeState.overlay == .settings {
                withAnimation(AppMotion.panelState) {
                    closeOverlay(.settings)
                }
            }
            handler.clearHighlightTrigger = UUID()
        }
    }

    func canUseProReaderFeature() -> Bool {
        ReaderEntitlement.canUseProReaderFeature()
    }
}
#endif
