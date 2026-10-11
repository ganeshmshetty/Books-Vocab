import CoreGraphics

// MARK: - Deck Height Transition (卡片區高度過渡 — 純邏輯)
//
// 問題（#2026）：active slot 的 layout 高度是 `nil`（自然高度）、非 active slot
// cap 成固定值。`nil` ↔ 固定值不可插值，role 輪替瞬間卡片區高度硬切，連帶下方
// 「點一下展開」區位移。
//
// 解法：卡片區高度由**單一獨立的 CGFloat（`deckShellHeight`）**驅動，role 翻面時
// 以 `reviewNavigationSpring` 過渡一次；本檔只放「何時快閃、何時動畫、每個 slot
// 吃哪個高度」的純規則，view 組裝在 TodayReviewPresenter / TodayReviewSwipeDeck。
//
// 為何不是 `interpolated(from:to:progress:)` 這種「模型側插值」：重新指向（動畫
// 中途又換目標）時，@State 讀到的是 model 值（上一個目標），不是螢幕上的
// presentation 值；模型側插值會在中斷瞬間跳回舊目標。把單一 CGFloat 交給
// SwiftUI spring 才有速度連續的 retarget。純函數因此負責「規劃」而非「插值」。
//
// 單元測試：TodayReviewDeckHeightTests。

enum TodayReviewDeckHeight {

    /// 量測雜訊容忍（pt）。與既有 slotFrontHeights 去重門檻同值。
    static let epsilon: CGFloat = 0.5

    /// 一次目標變更的處置。
    enum Plan: Equatable {
        /// 已在目標（含：動畫中重新指向同一目標）—— 不做事。
        case hold
        /// 無動畫直接落到 `height`（啟動量測、答案已展開）。
        case snap(to: CGFloat)
        /// 以 spring 過渡到 `height`；起點永遠是螢幕上當下的高度（由 SwiftUI 保證）。
        case animate(to: CGFloat)
    }

    /// 規劃一次高度變更。
    ///
    /// 不變式（皆有單元測試）：
    /// - 同高（|Δ| ≤ ε）恆為 `.hold`（恆等）。
    /// - 終點恆等於 `target`（不會產生中間值；snap 與 animate 的終點都是 target）。
    /// - 啟動（displayed ≤ 0，尚無舊高度可插值）與目標無效（≤ 0）一律 snap。
    /// - 答案展開中不動畫（展開有自己的摺疊動畫，高度過渡與之打架）。
    static func plan(displayed: CGFloat, target: CGFloat, revealed: Bool) -> Plan {
        let t = max(target, 0)
        if abs(displayed - t) <= epsilon { return .hold }
        if revealed || displayed <= 0 || t <= 0 { return .snap(to: t) }
        return .animate(to: t)
    }

    /// 非 active slot 的 cap 與 depth-2 殼層吃的高度：過渡值；啟動期（過渡值尚未
    /// 建立）直接用量測目標，避免量測完成到 onChange 落地之間多出一幀 0 高。
    static func resolvedShell(shell: CGFloat, target: CGFloat) -> CGFloat {
        shell > 0 ? shell : max(target, 0)
    }

    /// slot 的 layout 高度（`nil` = 自然高度）。
    ///
    /// - 非 active：cap 到 `min(resolvedShell, target)`（FIX(review-flip-gap)：不撐高
    ///   ZStack；且從較高的舊高度收合時，背景卡不得比 active 卡更高而從底下探出）。
    /// - active：只有「過渡中」才釘成 `resolvedShell`；穩態與展開答案時回 `nil`，
    ///   自然高度負責摺疊增長。
    ///
    /// 恆有 cap(非 active) ≤ pin(active)：ZStack 高度永遠只由 active 決定。
    ///
    /// 「過渡中」= 動畫進行中（`inFlight`）**或** 模型值尚未追上目標
    /// （|shell − target| > ε，亦即剛翻 role、onChange 還沒啟動動畫的那一幀）。
    /// 後者保證 role 翻面當幀新 active 取的就是舊高度 → 零跳變。
    ///
    /// `settledBack`（展開離場）：展開卡的自然高度是背面總高，但 `target` 是正面高度、`shell`
    /// 停在正面。若預覽卡 cap 仍是正面高度，翻面當幀新 active 釘住背面高度時，其 frame 會由
    /// 正面值動畫到背面值，動畫第一幀卡片區即從背面高度硬切。故展開中（同一張卡仍 settle 展開，
    /// 由 `RevealLatch.survives` 決定）非 active cap 直接取背面總高，翻面前後 ZStack 高度一致。
    /// 展開中背面總高若變動（縮短／增長），cap 跟的是 `RevealLatch.tracking` 追蹤後的值，不是 settle 當下的快照。
    static func slotHeight(
        isActive: Bool,
        shell: CGFloat,
        target: CGFloat,
        inFlight: Bool,
        revealed: Bool,
        settledBack: CGFloat? = nil
    ) -> CGFloat? {
        let resolved = resolvedShell(shell: shell, target: target)
        guard isActive else {
            if let settledBack, settledBack > 0 { return settledBack }
            return target > 0 ? min(resolved, target) : resolved
        }
        if revealed || shell <= 0 { return nil }
        return isTransitioning(shell: shell, target: target, inFlight: inFlight) ? resolved : nil
    }

    /// 卡片區是否仍在過渡（#3110：點一下展開 hint 的隱藏判定，與 slot 釘高共用）。
    ///
    /// = 動畫進行中（`inFlight`）**或** 模型值尚未追上目標（|shell − target| > ε）。
    /// 只看 `inFlight` 會漏掉翻面當幀（onChange 尚未觸發），hint 會在舊 y 多亮一幀。
    static func isTransitioning(shell: CGFloat, target: CGFloat, inFlight: Bool) -> Bool {
        inFlight || abs(shell - target) > epsilon
    }

    // MARK: 背面離場接手（previous / shuffle / autoplay 不經 fling 的縫）

    /// 背面展開 settle 後記下的「卡片區總高」。fling 路徑有 `pinDeckHeight` 在推進前
    /// 釘住當下高度；但 previous / shuffle / next / autoplay 由 owner 的 state 直接推進，
    /// presenter 在 role 翻面「之前」沒有任何 hook —— 翻面當幀 `shell` 還是正面高度，
    /// 新 active 取到比螢幕上小得多的值，硬切。latch 把「離開前的畫面高度」預先備好，
    /// 翻面當幀即可當 `shell` 的接手值（零跳變），之後由 `plan` 從它動畫到新卡高度。
    ///
    /// 以 `cardKey`（非 slot index）識別：shuffle 可能讓同一 slot 換內容。
    struct RevealLatch: Equatable {
        let cardKey: String
        let height: CGFloat

        init?(cardKey: String, measured: CGFloat) {
            guard measured > 0 else { return nil }
            self.cardKey = cardKey
            self.height = measured
        }

        /// 已離開被展開的那張卡 → 接手起點；同一張卡（收合）→ nil，不干預。
        func handoffHeight(currentCardKey: String) -> CGFloat? {
            cardKey == currentCardKey ? nil : height
        }

        /// 只在「同一張卡仍展開」時保留；收合（同卡、已 front）或離場被消化後丟棄。
        func survives(currentCardKey: String, revealed: Bool) -> Bool {
            cardKey == currentCardKey && revealed
        }

        /// 展開中背面自然高度的追蹤（#2026 r7）：settle 後背面仍可能變高或變矮（「+N」展開知識連結、
        /// 背面量測補齊）。同一張卡仍展開、且新量測與記下的值差 > ε 才回傳新 latch，否則 nil（不寫）。
        /// 只追蹤不離開展開態；收合 / 換卡 / 無效量測一律 nil，交給既有的收合與接手規則。
        func tracking(measured: CGFloat, currentCardKey: String, revealed: Bool) -> RevealLatch? {
            guard survives(currentCardKey: currentCardKey, revealed: revealed),
                  let next = RevealLatch(cardKey: cardKey, measured: measured),
                  abs(next.height - height) > TodayReviewDeckHeight.epsilon
            else { return nil }
            return next
        }
    }

    /// 過渡值的有效起點：有接手高度就用它，否則用 `shell`。
    static func effectiveShell(shell: CGFloat, handoff: CGFloat?) -> CGFloat {
        handoff ?? shell
    }

    // MARK: 轉場期間的裁切

    /// slot 的裁切外擴量：`side` 用於上/左/右（保留陰影空間），`bottom` 用於底邊。
    struct ClipBleed: Equatable {
        let side: CGFloat
        let bottom: CGFloat
    }

    /// 外擴量夠大 = 實質不裁切（保留 appElevation 陰影）。
    static let openBleed: CGFloat = 3000

    /// - 非 active：硬裁切（超出 cap 的 fixedSize 內容不得溢出）。
    /// - active 穩態：不裁切（陰影）。
    /// - active 被釘高（過渡中）：只裁底邊 —— 變高時新卡自然高度 > 釘高，內容會越過
    ///   frame 底邊蓋住下方「點一下展開」區；上/左/右維持外擴，陰影不閃。
    static func clipBleed(isActive: Bool, pinned: Bool) -> ClipBleed {
        guard isActive else { return ClipBleed(side: 0, bottom: 0) }
        return ClipBleed(side: openBleed, bottom: pinned ? 0 : openBleed)
    }

    /// slot 實測高度的寫入判定：回傳要寫入的新值，或 nil（無效 / 在雜訊內）。
    /// 比對對象是 **slot 自己上次記的值**，不是卡片的量測快取 —— 同一張卡的快取
    /// 高度不變，但 slot 內容輪替後 slot 存的是別張卡的舊值（stale，第三種跳法）。
    static func slotHeightUpdate(stored: CGFloat, measured: CGFloat) -> CGFloat? {
        guard measured > 0, abs(stored - measured) > epsilon else { return nil }
        return measured
    }
}
