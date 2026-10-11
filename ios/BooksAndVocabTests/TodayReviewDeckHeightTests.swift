import CoreGraphics
import Testing
@testable import BooksAndVocab

/// #2026：卡片區高度過渡的純規則。
/// 不變式：同高恆等、終點 = 新高度、啟動 / 展開中 snap、role 翻面當幀零跳變、
/// 非 active slot 恆 cap（FIX(review-flip-gap)）。
struct TodayReviewDeckHeightTests {

    private typealias H = TodayReviewDeckHeight

    // MARK: plan

    @Test func sameHeightIsIdentity() {
        for h: CGFloat in [1, 120, 240.4, 480] {
            #expect(H.plan(displayed: h, target: h, revealed: false) == .hold)
            #expect(H.plan(displayed: h, target: h + H.epsilon, revealed: false) == .hold)
            #expect(H.plan(displayed: h, target: h - H.epsilon, revealed: true) == .hold)
        }
    }

    @Test func differingHeightAnimatesToTheNewHeight() {
        // 終點恆等於新高度（不產生中間值），起點由 SwiftUI 取螢幕當下值。
        for (from, to): (CGFloat, CGFloat) in [(120, 360), (360, 120), (200, 200.6), (200.6, 200)] {
            #expect(H.plan(displayed: from, target: to, revealed: false) == .animate(to: to))
        }
    }

    @Test func bootstrapAndInvalidTargetSnap() {
        #expect(H.plan(displayed: 0, target: 240, revealed: false) == .snap(to: 240))
        #expect(H.plan(displayed: 240, target: 0, revealed: false) == .snap(to: 0))
        #expect(H.plan(displayed: 240, target: -5, revealed: false) == .snap(to: 0))
    }

    @Test func revealedNeverAnimates() {
        #expect(H.plan(displayed: 120, target: 360, revealed: true) == .snap(to: 360))
    }

    @Test func planIsMonotoneInDirection() {
        // 規劃的終點與 target 同向：target 越大，終點越大；與 displayed 無關。
        let targets: [CGFloat] = [100, 150, 220, 340, 500]
        for displayed: CGFloat in [90, 260, 700] {
            var last: CGFloat = 0
            for target in targets {
                guard case .animate(let end) = H.plan(displayed: displayed, target: target, revealed: false) else {
                    Issue.record("expected animate for \(displayed)->\(target)")
                    continue
                }
                #expect(end == target)
                #expect(end > last)
                last = end
            }
        }
    }

    // MARK: resolvedShell

    @Test func resolvedShellFallsBackToTargetOnlyBeforeBootstrap() {
        #expect(H.resolvedShell(shell: 0, target: 240) == 240)
        #expect(H.resolvedShell(shell: 180, target: 240) == 180)
        #expect(H.resolvedShell(shell: 0, target: -1) == 0)
    }

    // MARK: slotHeight

    @Test func nonActiveSlotsAlwaysCapToTheShell() {
        for inFlight in [false, true] {
            for revealed in [false, true] {
                #expect(H.slotHeight(isActive: false, shell: 200, target: 200, inFlight: inFlight, revealed: revealed) == 200)
                #expect(H.slotHeight(isActive: false, shell: 200, target: 320, inFlight: inFlight, revealed: revealed) == 200)
                #expect(H.slotHeight(isActive: false, shell: 0, target: 320, inFlight: inFlight, revealed: revealed) == 320)
            }
        }
    }

    /// 從較高的舊高度（例如背面展開後的總高）收合：背景卡 cap 在新卡高度，不比 active 高。
    @Test func shrinkingNeverLetsBackgroundCardsExceedTheTarget() {
        #expect(H.slotHeight(isActive: false, shell: 400, target: 200, inFlight: true, revealed: false) == 200)
    }

    /// 窮舉：任何狀態下 cap(非 active) ≤ pin(active) —— ZStack 高度只由 active 決定。
    @Test func capNeverExceedsTheActivePin() {
        let values: [CGFloat] = [0, 120, 200, 200.4, 360, 480]
        for shell in values {
            for target in values {
                for inFlight in [false, true] {
                    for revealed in [false, true] {
                        let cap = H.slotHeight(isActive: false, shell: shell, target: target, inFlight: inFlight, revealed: revealed)
                        guard let pin = H.slotHeight(isActive: true, shell: shell, target: target, inFlight: inFlight, revealed: revealed) else { continue }
                        #expect(cap! <= pin, "shell=\(shell) target=\(target) inFlight=\(inFlight) revealed=\(revealed)")
                    }
                }
            }
        }
    }

    @Test func settledActiveSlotUsesNaturalHeight() {
        #expect(H.slotHeight(isActive: true, shell: 200, target: 200, inFlight: false, revealed: false) == nil)
        #expect(H.slotHeight(isActive: true, shell: 200, target: 200.4, inFlight: false, revealed: false) == nil)
        // 啟動期（shell 尚未建立）也不釘高。
        #expect(H.slotHeight(isActive: true, shell: 0, target: 240, inFlight: false, revealed: false) == nil)
    }

    /// 核心：role 翻面當幀（shell 仍是舊高度、target 已是新卡高度），新 active 取舊高度，
    /// 與翻面前 ZStack 的高度（= shell）相同 → 零跳變。
    @Test func roleFlipFrameKeepsTheOldHeight() {
        for (old, new): (CGFloat, CGFloat) in [(120, 360), (360, 120), (200, 201)] {
            let flipFrame = H.slotHeight(isActive: true, shell: old, target: new, inFlight: false, revealed: false)
            #expect(flipFrame == old)
        }
    }

    @Test func activeStaysPinnedWhileTheAnimationIsInFlight() {
        // 動畫中 model 值已等於 target，但仍在飛 → 不得回 nil（否則 layout 立刻跳到自然高度）。
        #expect(H.slotHeight(isActive: true, shell: 360, target: 360, inFlight: true, revealed: false) == 360)
    }

    @Test func revealedActiveReleasesToNaturalHeightForTheFold() {
        #expect(H.slotHeight(isActive: true, shell: 200, target: 200, inFlight: true, revealed: true) == nil)
        #expect(H.slotHeight(isActive: true, shell: 200, target: 360, inFlight: false, revealed: true) == nil)
    }

    // MARK: slotHeightUpdate

    @Test func slotHeightUpdateComparesAgainstTheSlotNotTheCardCache() {
        // slot 存別張卡的舊值 300；回收回來的卡量到 200 → 必須寫入。
        #expect(H.slotHeightUpdate(stored: 300, measured: 200) == 200)
        #expect(H.slotHeightUpdate(stored: 200, measured: 200.3) == nil)
        #expect(H.slotHeightUpdate(stored: 200, measured: 0) == nil)
        #expect(H.slotHeightUpdate(stored: 0, measured: 120) == 120)
    }

    // MARK: 背面離場接手（previous / shuffle / autoplay，#2026 leftover A）

    @Test func latchRejectsInvalidMeasurements() {
        #expect(H.RevealLatch(cardKey: "a", measured: 0) == nil)
        #expect(H.RevealLatch(cardKey: "a", measured: -3) == nil)
        #expect(H.RevealLatch(cardKey: "a", measured: 480)?.height == 480)
    }

    /// 離開被展開的那張卡（currentCardKey 已換）→ 接手起點 = 背面總高；同一張卡
    /// （收合）或沒有 latch → nil，不干預既有流程。
    @Test func handoffAppliesOnlyWhenLeavingTheLatchedCard() {
        let latch = H.RevealLatch(cardKey: "a", measured: 480)!
        #expect(latch.handoffHeight(currentCardKey: "b") == 480)
        #expect(latch.handoffHeight(currentCardKey: "a") == nil)
    }

    @Test func latchSurvivesOnlyWhileTheSameCardStaysRevealed() {
        let latch = H.RevealLatch(cardKey: "a", measured: 480)!
        #expect(latch.survives(currentCardKey: "a", revealed: true))
        #expect(!latch.survives(currentCardKey: "a", revealed: false))   // 收合
        #expect(!latch.survives(currentCardKey: "b", revealed: false))   // 離場已被消化
        #expect(!latch.survives(currentCardKey: "b", revealed: true))
    }

    @Test func effectiveShellPrefersTheHandoff() {
        #expect(H.effectiveShell(shell: 200, handoff: nil) == 200)
        #expect(H.effectiveShell(shell: 200, handoff: 480) == 480)
    }

    /// 核心：背面（總高 480）→ 較矮的新卡（front 200）。接手當幀新 active 釘 480、
    /// 背景 slot cap 在 200（不得探出）；之後 plan 從 480 動畫到 200。
    @Test func leavingARevealedCardKeepsTheBackHeightOnTheFlipFrame() {
        let latch = H.RevealLatch(cardKey: "a", measured: 480)!
        let shell = H.effectiveShell(shell: 200, handoff: latch.handoffHeight(currentCardKey: "b"))
        #expect(H.slotHeight(isActive: true, shell: shell, target: 200, inFlight: false, revealed: false) == 480)
        #expect(H.slotHeight(isActive: false, shell: shell, target: 200, inFlight: false, revealed: false) == 200)
        #expect(H.plan(displayed: shell, target: 200, revealed: false) == .animate(to: 200))
    }

    // MARK: 展開背面離場的翻面當幀（previous / next / shuffle / autoplay 從展開卡離開）

    /// SwiftUI frame 動畫模型（本測試的前提，裝置簽核實機確認）：固定值 → 固定值 從變更前的值
    /// 開始插值；nil（自然高度）↔ 固定值 無法插值，該幀直接取變更後的值。卡片區高度 = 各 slot
    /// frame 的最大值，所以動畫第一幀的卡片區高度必須等於翻面前的高度，否則即硬切。
    private struct FlipSlot {
        let natural: CGFloat
        let before: CGFloat?
        let after: CGFloat?
    }

    private func stackHeight(_ slots: [FlipSlot]) -> CGFloat {
        slots.map { $0.before ?? $0.natural }.max() ?? 0
    }

    private func firstAnimatedFrame(_ slots: [FlipSlot]) -> CGFloat {
        slots.map { slot -> CGFloat in
            if let before = slot.before, slot.after != nil { return before }
            return slot.after ?? slot.natural
        }.max() ?? 0
    }

    /// 背面（back）→ 較矮的新卡（next）。翻面前預覽卡的 cap 必須已是展開背面高度，翻面當幀
    /// 新 active 才能釘在同一值；否則預覽卡的 frame 由正面高度動畫到背面高度，動畫第一幀
    /// 卡片區從 back 硬切到 front／next。新卡不矮於背面（next ≥ back）時 outgoing cap 本來
    /// 就撐住 ZStack，故此處涵蓋 next < back 的情況。
    @Test func revealedDepartureKeepsTheStackHeightOnTheFirstAnimatedFrame() {
        let cases: [(back: CGFloat, front: CGFloat, next: CGFloat)] = [
            (480, 200, 120), (480, 200, 200), (480, 200, 360), (480, 200, 470), (480, 200, 480), (480, 200, 600),
            (300, 180, 120), (300, 180, 250), (300, 180, 420),
            (600, 240, 180), (600, 240, 599), (600, 240, 700),
        ]
        for c in cases {
            let latch = H.RevealLatch(cardKey: "a", measured: c.back)!
            // 翻面前（展開中、同一張卡）：預覽卡 cap ＝ 已 settle 的背面高度。
            let preflipCap = H.slotHeight(
                isActive: false, shell: c.front, target: c.front,
                inFlight: false, revealed: true, settledBack: latch.height
            )
            // 翻面當幀：接手值 = 離場卡背面高度；新 active 釘在它，舊卡 cap 到新目標。
            let shell = H.effectiveShell(shell: c.front, handoff: latch.handoffHeight(currentCardKey: "b"))
            let outgoing = H.slotHeight(isActive: false, shell: shell, target: c.next, inFlight: false, revealed: false)
            let incoming = H.slotHeight(isActive: true, shell: shell, target: c.next, inFlight: false, revealed: false)
            let slots = [
                FlipSlot(natural: c.back, before: nil, after: outgoing),
                FlipSlot(natural: c.next, before: preflipCap, after: incoming),
                FlipSlot(natural: c.front, before: preflipCap, after: outgoing),
            ]
            #expect(preflipCap == c.back, "preflip cap back=\(c.back) next=\(c.next)")
            #expect(stackHeight(slots) == c.back, "preflip stack back=\(c.back) next=\(c.next)")
            #expect(firstAnimatedFrame(slots) == c.back, "first frame back=\(c.back) next=\(c.next)")
        }
    }

    // MARK: 展開中背面高度變動（背面縮短 / 增長，#2026 r7）

    /// settle 後背面自然高度仍會變（「+N」展開知識連結、背面量測補齊）。latch 若凍結在 settle 當下
    /// 的值，非 active cap 會停在舊高度：背面縮短後卡片區比卡片高，收合時即 H-H' 縫。展開中 active
    /// 的量測須追蹤進 latch；收合、換卡、雜訊、無效量測一律不寫（交給既有收合 / 接手規則）。
    @Test func expandedLatchTracksTheActiveBackHeight() {
        let latch = H.RevealLatch(cardKey: "a", measured: 480)!
        #expect(latch.tracking(measured: 360, currentCardKey: "a", revealed: true)?.height == 360)
        #expect(latch.tracking(measured: 600, currentCardKey: "a", revealed: true)?.height == 600)
        #expect(latch.tracking(measured: 480.3, currentCardKey: "a", revealed: true) == nil)
        #expect(latch.tracking(measured: 0, currentCardKey: "a", revealed: true) == nil)
        #expect(latch.tracking(measured: 360, currentCardKey: "a", revealed: false) == nil)
        #expect(latch.tracking(measured: 360, currentCardKey: "b", revealed: true) == nil)
    }

    /// 背面由 480 縮成 360 後：非 active cap 取追蹤後的 360，與 active 自然高度相等，
    /// 卡片區 = 背面實高、不留 120 的縫。
    @Test func shrunkBackFaceKeepsTheCapEqualToTheActiveHeightWhileExpanded() {
        let tracked = H.RevealLatch(cardKey: "a", measured: 480)!
            .tracking(measured: 360, currentCardKey: "a", revealed: true)!
        let cap = H.slotHeight(
            isActive: false, shell: 200, target: 200,
            inFlight: false, revealed: true, settledBack: tracked.height
        )
        #expect(cap == 360)
    }

    // MARK: 轉場期間的裁切（leftover B：變高時內容溢出到展開區）

    @Test func nonActiveSlotsAlwaysHardClip() {
        for pinned in [false, true] {
            #expect(H.clipBleed(isActive: false, pinned: pinned) == H.ClipBleed(side: 0, bottom: 0))
        }
    }

    @Test func settledActiveSlotNeverClipsSoTheShadowSurvives() {
        let bleed = H.clipBleed(isActive: true, pinned: false)
        #expect(bleed.side > 0 && bleed.bottom > 0)
    }

    /// 轉場中 active 被釘高：內容（新卡自然高度 > 釘高）不得越過 frame 底邊蓋住展開區；
    /// 上/左/右仍保留陰影空間。
    @Test func pinnedActiveSlotClipsOnlyTheBottomEdge() {
        let bleed = H.clipBleed(isActive: true, pinned: true)
        #expect(bleed.bottom == 0)
        #expect(bleed.side > 0)
    }

    // MARK: 過渡判定（#3110：點一下展開 hint 的隱藏時機，與 slot 釘高共用同一判定）

    /// role 翻面當幀：模型值已到目標、但 shell 仍是舊高度，onChange 尚未啟動動畫。
    @Test func flipFrameIsTransitioningBeforeTheSpringStarts() {
        #expect(H.isTransitioning(shell: 360, target: 120, inFlight: false))
    }

    @Test func settledDeckIsNotTransitioning() {
        #expect(!H.isTransitioning(shell: 120, target: 120, inFlight: false))
    }

    /// 動畫進行中即使模型值已追上目標，畫面仍在飛。
    @Test func inFlightIsTransitioningEvenWhenTheModelHasCaughtUp() {
        #expect(H.isTransitioning(shell: 120, target: 120, inFlight: true))
    }

    /// 量測雜訊（|Δ| ≤ ε）不算過渡，否則 hint 會在穩態被無謂地隱藏。
    @Test func subEpsilonNoiseIsNotTransitioning() {
        #expect(!H.isTransitioning(shell: 120, target: 120 + H.epsilon, inFlight: false))
        #expect(!H.isTransitioning(shell: 120 + H.epsilon, target: 120, inFlight: false))
    }

    /// 啟動期 shell 尚未建立（0）：沒有待過渡的值，hint 不得因此永久隱藏（直到翻面）。
    @Test func unsetShellIsNotTransitioning() {
        #expect(!H.isTransitioning(shell: 0, target: 120, inFlight: false))
    }

    /// 與 slotHeight 的 active 分支必須同一判定：過渡中釘高，穩態回自然高度。
    @Test func slotHeightPinsExactlyWhenTheTransitionPredicateHolds() {
        let cases: [(shell: CGFloat, target: CGFloat, inFlight: Bool)] = [
            (360, 120, false), (120, 120, false), (120, 120, true), (120, 120.2, false),
            (0, 120, false),
        ]
        for c in cases {
            let pinned = H.slotHeight(
                isActive: true, shell: c.shell, target: c.target,
                inFlight: c.inFlight, revealed: false
            ) != nil
            #expect(pinned == H.isTransitioning(shell: c.shell, target: c.target, inFlight: c.inFlight))
        }
    }

    // MARK: 點一下展開 hint 的動效選擇（#3110，與 main 的翻面彈簧對齊）

    /// 答案揭示／收合走 reviewRevealSpring：zone 離開 front 時必須用彈簧淡出，不可 snap。
    @Test func revealHideKeepsTheRevealSpring() {
        #expect(H.expandZoneMotion(zoneActive: false, deckIsTransitioning: false) == .revealSpring)
        #expect(H.expandZoneMotion(zoneActive: false, deckIsTransitioning: true) == .revealSpring)
    }

    /// 卡片區飛行中（zone 仍 active）隱藏：瞬間 snap，不沿彈簧上飄。
    @Test func deckFlightHideSnaps() {
        #expect(H.expandZoneMotion(zoneActive: true, deckIsTransitioning: true) == .snap)
    }

    /// 飛行結束後的淡入走 contentFade。
    @Test func settledFrontFadesIn() {
        #expect(H.expandZoneMotion(zoneActive: true, deckIsTransitioning: false) == .contentFade)
    }
}
