import SwiftUI

/// 頂端 pill 的單則通知。pill **只負責通知**，刻意沒有動作按鈕：需要使用者決定或
/// 操作的狀態放在畫面內面板（規範見 docs/sop/ui-design.md「暫時性提示」）。
struct AppToastItem: Identifiable, Equatable {
    let id = UUID()
    /// 事件身分。同 key = 同一事件（就地取代、重設計時）；不同 key = 不同事件（排隊）。
    /// 預設由 style + message 推導，所以重複的同一則提示自然合併；文案會變的同一事件
    /// （例如進度數字）由呼叫端給穩定的 key。
    let key: String
    let message: String
    let systemImage: String
    let style: Style

    enum Style {
        case success, info, warning, error

        var defaultImage: String {
            switch self {
            case .success: "checkmark"
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.circle"
            }
        }

        /// 佇列滿時的去留依據：錯誤 > 警告 > 一般（成功／資訊）。
        var severity: Int {
            switch self {
            case .success, .info: 0
            case .warning: 1
            case .error: 2
            }
        }

        fileprivate var keyComponent: String {
            switch self {
            case .success: "success"
            case .info: "info"
            case .warning: "warning"
            case .error: "error"
            }
        }
    }

    var duration: TimeInterval {
        switch style {
        case .success, .info: 2.5
        case .warning, .error: 4.0
        }
    }

    init(message: String, systemImage: String? = nil, style: Style, key: String? = nil) {
        self.message = message
        self.systemImage = systemImage ?? style.defaultImage
        self.style = style
        self.key = key ?? "\(style.keyComponent)|\(message)"
    }

    // MARK: - Copy budget

    /// 單行文案上限，以「欄」計：全形字（中日韓）2 欄、其餘 1 欄。40 欄 = 20 個全形字
    /// 或 40 個半形字元，約為 iPhone SE 寬度下 caption 字級單行可容納量。超過時 pill
    /// 仍維持單行（先縮小、再尾端截斷），但較長的說明應改放面板。
    static let copyBudgetColumns = 40

    static func exceedsCopyBudget(_ message: String) -> Bool {
        displayWidth(of: message) > copyBudgetColumns
    }

    static func displayWidth(of text: String) -> Int {
        text.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    private static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x115F,   // Hangul Jamo
                 0x2E80...0xA4CF,   // CJK radicals … Yi（含 CJK 標點、假名、注音、漢字）
                 0xAC00...0xD7A3,   // Hangul syllables
                 0xF900...0xFAFF,   // CJK compatibility ideographs
                 0xFE30...0xFE4F,   // CJK compatibility forms
                 0xFF00...0xFF60,   // Fullwidth forms
                 0xFFE0...0xFFE6:
                return true
            default:
                return false
            }
        }
    }
}

/// pill 佇列的純狀態機（無時鐘）。計時、動畫與 VoiceOver 由 `AppToastCoordinator` 負責。
///
/// 規則（docs/sop/ui-design.md「暫時性提示」）：
/// - 同一事件（同 key）→ 就地取代，不疊第二則；
/// - 不同事件 → 排隊，最多同時持有 `capacity` 則（顯示中 1 + 等待 1）；
/// - 佇列滿 → 留下較嚴重的那則（同級留最新），顯示中那則不被擠掉；
/// - 下一則只在前一則退場後才進場（`isHandingOff`），兩則 pill 不會原地換字。
struct AppToastQueue: Equatable {
    static let capacity = 2

    private(set) var current: AppToastItem?
    private(set) var pending: [AppToastItem] = []
    /// 前一則正在退場、下一則尚未進場的讓位期間。
    private(set) var isHandingOff = false

    enum Outcome: Equatable {
        /// 成為顯示中（需排程自動消失）。
        case presented
        /// 同一事件取代顯示中那則（需重設計時）。
        case replacedCurrent
        /// 同一事件取代等待中那則。
        case replacedPending
        /// 不同事件進入等待；`evicted` 是佇列滿時被擠掉的較不重要通知。
        case queued(evicted: AppToastItem?)
        /// 佇列滿且新通知比等待中的都不重要。
        case dropped
    }

    private var heldCount: Int { (current == nil ? 0 : 1) + pending.count }

    mutating func receive(_ item: AppToastItem) -> Outcome {
        if current?.key == item.key {
            current = item
            return .replacedCurrent
        }
        if let index = pending.firstIndex(where: { $0.key == item.key }) {
            pending[index] = item
            return .replacedPending
        }
        if current == nil && !isHandingOff {
            current = item
            return .presented
        }
        if heldCount < Self.capacity {
            pending.append(item)
            return .queued(evicted: nil)
        }
        // 滿了：等待中最不嚴重、同級中最舊的那則讓位；新通知更不重要就丟掉新通知。
        guard let victimIndex = pending.indices.min(by: {
            pending[$0].style.severity < pending[$1].style.severity
        }) else {
            return .dropped
        }
        let victim = pending[victimIndex]
        guard item.style.severity >= victim.style.severity else { return .dropped }
        pending.remove(at: victimIndex)
        pending.append(item)
        return .queued(evicted: victim)
    }

    /// 顯示中那則結束（逾時或使用者上滑）。回傳 `true` 表示有下一則在等，
    /// 呼叫端需在退場動畫結束後呼叫 `completeHandoff()`。
    @discardableResult
    mutating func retireCurrent() -> Bool {
        guard current != nil else { return false }
        current = nil
        guard !pending.isEmpty else { return false }
        isHandingOff = true
        return true
    }

    /// 讓位結束，讓下一則進場；回傳新的顯示中通知。
    mutating func completeHandoff() -> AppToastItem? {
        guard isHandingOff else { return nil }
        isHandingOff = false
        guard !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        current = next
        return next
    }
}

/// `AppToastCoordinator` 的計時 seam：`delay` 後在 main actor 執行 `action`。
/// 生產走 `AppToastTaskScheduler`（`Task.sleep`）；測試注入手動推進的假時間，
/// 不必真的等待計時器。
protocol AppToastScheduler {
    /// 回傳的 handle 被 `cancel()` 後，`action` 不再執行。
    @MainActor
    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> AppToastScheduledAction
}

/// 已排程的動作。`cancel()` 對已執行或已取消的動作是 no-op。
@MainActor
struct AppToastScheduledAction {
    private let cancelAction: @MainActor () -> Void

    init(cancel: @escaping @MainActor () -> Void) {
        cancelAction = cancel
    }

    func cancel() {
        cancelAction()
    }
}

/// 生產用計時：每個動作一個 `Task`，取消即取消該 `Task`。
struct AppToastTaskScheduler: AppToastScheduler {
    func schedule(
        after delay: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> AppToastScheduledAction {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return AppToastScheduledAction { task.cancel() }
    }
}

@Observable @MainActor
final class AppToastCoordinator {
    /// 前一則退場動畫（`AppMotion.panelState`，response 0.3）的讓位時間：
    /// 下一則在它離場後才進場，避免兩則 pill 交疊或原地跳字。
    static let handoffDelay: Duration = .milliseconds(350)
    /// 展開後的自動收起下限（#2862）：展開的目的就是讀完整文案，不得在讀完前消失。
    static let expandedDismissFloor: Duration = .seconds(8)

    /// 顯示中那則是否展開成完整多行文案。狀態在 coordinator 上，root 與 sheet 內的
    /// 兩個 overlay 共用同一份，才不會各自展開。
    private(set) var isExpanded = false

    private var queue = AppToastQueue()
    private let scheduler: any AppToastScheduler
    @ObservationIgnored private var dismissTimer: AppToastScheduledAction?
    @ObservationIgnored private var handoffTimer: AppToastScheduledAction?

    init(scheduler: any AppToastScheduler = AppToastTaskScheduler()) {
        self.scheduler = scheduler
    }

    var current: AppToastItem? { queue.current }
    var pending: [AppToastItem] { queue.pending }

    func show(_ item: AppToastItem) {
        #if DEBUG
        if AppToastItem.exceedsCopyBudget(item.message) {
            AppLog.app.debug("toast copy exceeds single-line budget (\(AppToastItem.displayWidth(of: item.message)) cols): move details into an in-screen panel")
        }
        #endif
        let outcome = withAnimation(AppMotion.panelState) {
            queue.receive(item)
        }
        switch outcome {
        case .presented, .replacedCurrent:
            present(item)
        case .replacedPending, .queued, .dropped:
            break
        }
    }

    /// 使用者上滑或呼叫端主動收起顯示中那則；有等待中的通知會在讓位後接著顯示。
    func dismiss() {
        retire(id: nil)
    }

    /// 點擊截斷的 pill 切換展開／收合（收合不關閉通知）。沒有顯示中的通知時為 no-op；展開時
    /// 重排自動消失計時（至少 `expandedDismissFloor`），收合時回到該則的正常時長。
    func toggleExpanded(animation: Animation = AppMotion.panelState) {
        guard let visible = queue.current else { return }
        withAnimation(animation) {
            isExpanded.toggle()
        }
        scheduleDismiss(for: visible)
    }

    func success(_ message: String, key: String? = nil) {
        show(AppToastItem(message: message, style: .success, key: key))
    }

    func info(_ message: String, key: String? = nil) {
        show(AppToastItem(message: message, style: .info, key: key))
    }

    func warning(_ message: String, key: String? = nil) {
        show(AppToastItem(message: message, style: .warning, key: key))
    }

    func error(_ message: String, key: String? = nil) {
        show(AppToastItem(message: message, style: .error, key: key))
    }

    // MARK: - Lifecycle

    private func present(_ item: AppToastItem) {
        // Announce for VoiceOver (side effect only). The auto-dismiss MUST still
        // be scheduled regardless — otherwise the toast never clears when
        // VoiceOver is on, leaving `current` stuck forever.
        _ = PlatformAccessibility.announceIfVoiceOver(item.message)
        scheduleDismiss(for: item)
    }

    private func scheduleDismiss(for item: AppToastItem) {
        dismissTimer?.cancel()
        let normal = Duration.seconds(item.duration)
        let delay = isExpanded ? max(normal, Self.expandedDismissFloor) : normal
        let id = item.id
        dismissTimer = scheduler.schedule(after: delay) { [weak self] in
            self?.retire(id: id)
        }
    }

    /// `id == nil`：收起目前顯示的那則；否則只在它仍是顯示中那則時才收起
    /// （被同一事件取代後，舊計時器不得收掉新那則）。
    private func retire(id: AppToastItem.ID?) {
        guard let visible = queue.current, id == nil || visible.id == id else { return }
        dismissTimer?.cancel()
        dismissTimer = nil
        let needsHandoff = withAnimation(AppMotion.panelState) {
            isExpanded = false
            return queue.retireCurrent()
        }
        guard needsHandoff else { return }
        handoffTimer?.cancel()
        handoffTimer = scheduler.schedule(after: Self.handoffDelay) { [weak self] in
            self?.completeHandoff()
        }
    }

    private func completeHandoff() {
        handoffTimer = nil
        let next = withAnimation(AppMotion.panelState) {
            queue.completeHandoff()
        }
        if let next {
            present(next)
        }
    }
}
