#if os(iOS)
import Foundation
import ReadiumShared

/// EPUB 閱讀進度落盤器。
///
/// 背景：`ReaderView.handleLocationChange` 每次翻頁都更新 `Book` 的
/// `lastReadLocatorJSON` / `dateLastRead` / `progression`，但**從不** `save()`，
/// 仰賴 SwiftData 非確定性 autosave。若 crash / OOM 發生於 flush 之前，最後位置會遺失。
/// PDF 路徑（`PDFReaderView` 經 `PDFProgressRecorder` 委派）共用同一個 saver 與 debounce 窗口，
/// 兩條閱讀器的落盤語意一致。
///
/// 修法：在記憶體寫入後**顯式** `save()`，但翻頁高頻 → 用 debounce 把連續翻頁
/// coalesce 成窗口尾端單次落盤，避免每頁同步 I/O 卡頓。退出 / 退背景時 `flush()`
/// 兜底，確保 debounce 窗口內未落盤的最後一次寫入不遺失。
///
/// 並發契約：mirror `CloudPreferencesSync` — 所有公開 API 設計為 main thread 呼叫
/// （`onLocationChange` / `onDisappear` / scenePhase observer 皆 main queue），
/// pending flush 的排程/取消固定走 main queue，避免 `DispatchWorkItem` cancel/
/// reschedule 競態。
@MainActor
protocol ReaderProgressDebouncing: AnyObject {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class SystemReaderProgressDebouncer: ReaderProgressDebouncing {
    private let clock = ContinuousClock()
    private var pendingTask: Task<Void, Never>?

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
            self.pendingTask = nil
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}

@MainActor
final class ReaderProgressSaver {
    /// debounce 視窗：連續翻頁在此窗口內 coalesce 成單次落盤。
    private let flushDelay: TimeInterval
    /// 可替換的 debounce clock/scheduler；測試不依賴 wall clock。
    private let debouncer: any ReaderProgressDebouncing
    /// 最近一次排程時帶入的落盤副作用（最新 save closure），供 `flush()` 直接執行。
    private var latestSave: (() -> Void)?

    /// 預設生產窗口 1.2s — 翻頁停止後才落盤。
    init(
        flushDelay: TimeInterval = ReaderMetrics.progressFlushDelay,
        debouncer: (any ReaderProgressDebouncing)? = nil
    ) {
        self.flushDelay = flushDelay
        self.debouncer = debouncer ?? SystemReaderProgressDebouncer()
    }

    /// 將 `locator` 序列化為 Readium Locator JSON。
    ///
    /// 失敗回 `nil`（呼叫端據此**跳過寫入**，保留既有有效值），而非舊行為的 `"{}"`
    /// 字面值 —— `Locator(jsonString:"{}")` 可能 decode 成空 locator 污染下次還原。
    static func encodedLocatorJSON(_ locator: Locator) -> String? {
        do {
            return try locator.jsonString()
        } catch {
            // Serialization of a structured Readium Locator effectively never
            // fails — but if it does, surface it instead of silently returning
            // nil, so the skipped-persist path (ReaderView+Handlers) is diagnosable.
            AppLog.reader.warning("Locator JSON serialize failed (href=\(String(describing: locator.href), privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 記錄一次翻頁：`apply` 立即執行（in-memory model 寫入，供 panel 即時讀取），
    /// 隨後排一個 debounced `save`。`save` 為最新值，窗口內多次 record 只保留尾端。
    func recordChange(apply: () -> Void, save: @escaping () -> Void) {
        apply()
        latestSave = save
        scheduleFlush()
    }

    /// 立即落盤並取消任何 pending flush。
    /// 供 `onDisappear` / scenePhase `.background` 兜底，確保 debounce 窗口未到期
    /// 即退出時最後一次寫入仍落地。無 pending 則 no-op。
    func flush() {
        guard let save = latestSave else { return }
        debouncer.cancel()
        latestSave = nil
        save()
    }

    // MARK: - Debounce

    private func scheduleFlush() {
        debouncer.cancel()
        debouncer.schedule(after: flushDelay) { [weak self] in
            guard let self else { return }
            let save = self.latestSave
            self.latestSave = nil
            save?()
        }
    }
}
#endif
