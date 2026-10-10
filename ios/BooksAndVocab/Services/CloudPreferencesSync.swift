import Foundation

/// iCloud Key-Value Store 同步管理器
/// 負責封裝 NSUbiquitousKeyValueStore 讀寫，並監聽外部變更通知。
///
/// 並發契約：所有公開 API 設計為在 main thread 呼叫（設定 UI 寫入、KVS
/// `didChangeExternallyNotification` observer 皆為 main queue）。debounce 的
/// pending flush 排程與取消亦固定走 main queue，避免 `DispatchWorkItem` 的
/// cancel/reschedule 競態。
final class CloudPreferencesSync {
    static let shared = CloudPreferencesSync()

    /// 把 debounced flush 的 `work` 排到 `delay` 秒後的 main queue 執行。
    /// 取消一律走 `DispatchWorkItem.cancel()`，已取消的 `work` 不得執行。
    typealias FlushScheduler = (_ delay: TimeInterval, _ work: DispatchWorkItem) -> Void

    private let kvs = NSUbiquitousKeyValueStore.default

    /// debounce 視窗：連續寫入在此窗口內 coalesce 成單次 `synchronize()`。
    private let flushDelay: TimeInterval
    /// debounce 計時 seam（預設 `DispatchQueue.main.asyncAfter`，測試可注入假時間）。
    private let scheduleFlushWork: FlushScheduler
    /// 實際執行 flush 的副作用 seam（預設打 KVS，測試可注入計數器）。
    private let flushAction: () -> Void
    /// pending 的 debounced flush；nil 表示無待執行。固定在 main thread 存取。
    private var pendingFlush: DispatchWorkItem?

    private init() {
        self.flushDelay = 0.5
        self.scheduleFlushWork = CloudPreferencesSync.scheduleOnMainQueue
        self.flushAction = { NSUbiquitousKeyValueStore.default.synchronize() }
    }

    /// 測試用初始化：注入 debounce 窗口、計時 seam 與可觀測的 flush seam。
    /// 生產不使用此 path（`shared` 走 `init()`）。
    init(
        flushDelay: TimeInterval,
        scheduler: @escaping FlushScheduler = CloudPreferencesSync.scheduleOnMainQueue,
        flushAction: @escaping () -> Void
    ) {
        self.flushDelay = flushDelay
        self.scheduleFlushWork = scheduler
        self.flushAction = flushAction
    }

    /// 生產用 `FlushScheduler`。
    static func scheduleOnMainQueue(_ delay: TimeInterval, _ work: DispatchWorkItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Read

    func string(forKey key: String) -> String? {
        kvs.string(forKey: key)
    }

    func double(forKey key: String) -> Double? {
        let value = kvs.double(forKey: key)
        guard kvs.object(forKey: key) != nil else { return nil }
        return value
    }

    // MARK: - Write

    /// 寫入 KVS 並排一個 debounced `synchronize()`。
    ///
    /// PR #625 起每次 `set` 都立即 `synchronize()`，但 `ReaderSettingsPanel`
    /// lineHeight `Slider(step: 0.1)` 是連續綁定源，單次拖曳可爆發 ~15 次
    /// synchronize，違反 Apple「synchronize 不應高頻」指引。改為 debounce：
    /// 連續寫入只在窗口尾端 flush 一次，coalesce 風暴。force-quit 丟資料的兜底
    /// 改由 `BooksAndVocabApp` scenePhase `.background` 呼叫 `forceFlush()` 覆蓋
    /// 正常退出路徑，僅前景強殺極端 case 會丟失 debounce 窗口內的寫入。
    func set(_ value: String, forKey key: String) {
        kvs.set(value, forKey: key)
        scheduleFlush()
    }

    func set(_ value: Double, forKey key: String) {
        kvs.set(value, forKey: key)
        scheduleFlush()
    }

    func removeObject(forKey key: String) {
        kvs.removeObject(forKey: key)
        scheduleFlush()
    }

    /// 列出 KVS 內所有 key（帳號偏好 purge 用）。
    func allKeys() -> [String] {
        Array(kvs.dictionaryRepresentation.keys)
    }

    // MARK: - Sync

    /// 立即 `synchronize()` 並取消任何 pending debounced flush。
    /// 供 scenePhase `.background` 兜底，確保退背景時 pending 寫入落地。
    func forceFlush() {
        pendingFlush?.cancel()
        pendingFlush = nil
        flushAction()
    }

    // MARK: - Debounce

    /// 取消前一個 pending flush、排一個新的 `flushDelay` 秒後執行。
    /// 固定在 main queue 排程/取消以保證 cancel/reschedule 執行緒安全。
    private func scheduleFlush() {
        if Thread.isMainThread {
            scheduleFlushOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in self?.scheduleFlushOnMain() }
        }
    }

    private func scheduleFlushOnMain() {
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFlush = nil
            self.flushAction()
        }
        pendingFlush = work
        scheduleFlushWork(flushDelay, work)
    }
}
