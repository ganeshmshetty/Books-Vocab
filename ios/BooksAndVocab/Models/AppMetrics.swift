//
//  AppMetrics.swift
//  Books & Vocab
//
//  統一的間距、圓角與陰影參數 (Design System Tokens)
//

import SwiftUI
import UIKit

enum AppMetrics {
    // ── Divider / Separator ───────────────────────────────────────────────────
    static let dividerThin: CGFloat = 0.5
    static let dividerStandard: CGFloat = 1
    /// 「呼吸式」群組分節 — Mochi-borrowed（北極星二：border 退場、divider 進場）。
    /// 配 `AppAirDivider` 使用，給 list / 群組之間的軟分隔，不靠卡片邊框。
    /// 原值 32pt 對應 Mochi `<hr style="margin:32px 0">` long-form editorial；
    /// 2026-05 user feedback 收緊到 16pt — iPhone 列表頁 32pt 過鬆。
    static let dividerAirMargin: CGFloat = DesignTokens.Space.Semantic.dividerAir

    // ── Control Dimensions ──────────────────────────────────────────────────────
    static let iconButtonSize: CGFloat = 52

    // ── Loading Indicator ─────────────────────────────────────────────────
    static let loadingIndicatorScaleMedium: CGFloat = 0.8
    static let loadingIndicatorScaleSmall: CGFloat = 0.7
}

enum AppMotion {
    static let quickEaseOut = Animation.easeOut(duration: DesignTokens.Motion.Duration.quick)
    static let controlEaseOut = Animation.easeOut(duration: DesignTokens.Motion.Duration.control)
    static let progressLinear = Animation.linear(duration: DesignTokens.Motion.Duration.progress)
    static let standardSpring = Animation.spring(response: DesignTokens.Motion.Spring.Standard.response, dampingFraction: DesignTokens.Motion.Spring.Standard.damping)
    static let emphasizedSpring = Animation.spring(response: DesignTokens.Motion.Spring.Emphasized.response, dampingFraction: DesignTokens.Motion.Spring.Emphasized.damping)
    static let relaxedSpring = Animation.spring(response: DesignTokens.Motion.Spring.Relaxed.response, dampingFraction: DesignTokens.Motion.Spring.Relaxed.damping)
    static let systemSpring = Animation.spring()
    static let modalSwapSpring = Animation.spring(response: DesignTokens.Motion.Spring.ModalSwap.response, dampingFraction: DesignTokens.Motion.Spring.ModalSwap.damping)
    static let buttonSpring = Animation.spring(response: DesignTokens.Motion.Spring.Button.response, dampingFraction: DesignTokens.Motion.Spring.Button.damping, blendDuration: 0)
    static let breathing = Animation.easeInOut(duration: DesignTokens.Motion.Duration.breathing).repeatForever(autoreverses: true)
    static let reviewRevealSpring = Animation.spring(response: DesignTokens.Motion.Spring.ReviewReveal.response, dampingFraction: DesignTokens.Motion.Spring.ReviewReveal.damping)
    static let reviewNavigationSpring = Animation.spring(response: DesignTokens.Motion.Spring.ReviewNavigation.response, dampingFraction: DesignTokens.Motion.Spring.ReviewNavigation.damping)

    // Swipe gesture
    static let swipeSnapBackSpring = Animation.spring(response: DesignTokens.Motion.Spring.SwipeSnapBack.response, dampingFraction: DesignTokens.Motion.Spring.SwipeSnapBack.damping)

    // MARK: - Micro-interaction Springs
    /// 卡片甩出畫面（臨界阻尼、極短時長 — 瞬間飛離，露出已預渲染的下一張，消除中間等待）
    static let swipeFlingSpring = Animation.spring(response: DesignTokens.Motion.Spring.SwipeFling.response, dampingFraction: DesignTokens.Motion.Spring.SwipeFling.damping)
    /// 同一條 swipeFling 曲線（臨界阻尼 = bounce 0），時長由 `TodayReviewFling.plan` 依
    /// 牌堆升頂剩餘量決定（#2027：swipe 放手與按鈕共用）；duration == SwipeFling.response
    /// 時與 `swipeFlingSpring` 等價。
    static func swipeFling(duration: Double) -> Animation {
        .spring(duration: duration, bounce: 0)
    }
    /// 回饋按鈕跟隨 swipe 強度（快速貼合手勢）
    static let feedbackButtonSpring = Animation.spring(response: DesignTokens.Motion.Spring.FeedbackButton.response, dampingFraction: DesignTokens.Motion.Spring.FeedbackButton.damping)
    /// 拖拽中卡片跟手（極低延遲、高阻尼，貼合手指）
    static let swipeTrackingSpring = Animation.interactiveSpring(response: DesignTokens.Motion.Spring.SwipeTracking.response, dampingFraction: DesignTokens.Motion.Spring.SwipeTracking.damping)

    // --- Visual polish tokens ---
    static let pressFeedback: Animation = .spring(response: DesignTokens.Motion.Spring.Press.response, dampingFraction: DesignTokens.Motion.Spring.Press.damping)
    static let contentReveal: Animation = .spring(response: DesignTokens.Motion.Spring.ContentReveal.response, dampingFraction: DesignTokens.Motion.Spring.ContentReveal.damping)
    static let celebrationBounce: Animation = .spring(response: DesignTokens.Motion.Spring.CelebrationBounce.response, dampingFraction: DesignTokens.Motion.Spring.CelebrationBounce.damping)
    static let sheetContentAppear: Animation = .spring(response: DesignTokens.Motion.Spring.SheetContentAppear.response, dampingFraction: DesignTokens.Motion.Spring.SheetContentAppear.damping)

    // Semantic motion tokens for shared interaction patterns.
    // 每個語意 token 對應唯一一條曲線，不設同值別名。
    static let panelState = standardSpring
    static let headerState = relaxedSpring
    static let phaseChange = emphasizedSpring
    /// 同步完成/失敗的面板收尾：比一般 phase change 更明確地讓終態看得見，
    /// 再由 `syncCompletionHold` 留出讀取時間。
    static let syncCompletion = Animation.timingCurve(
        0.22,
        0.8,
        0.26,
        1.0,
        duration: DesignTokens.Motion.Duration.indicator
    )
    // Keep terminal sync feedback readable even when a retry hits the local
    // fixture/cache path and completes within a single run-loop turn. The
    // panel is a user-facing result, not a transient spinner.
    static let syncCompletionHold: Duration = .milliseconds(1500)
    static let feedbackPulse = systemSpring
    static let contentFade = quickEaseOut
    static let chipSelect = Animation.easeOut(duration: DesignTokens.Motion.Duration.chip)

    // MARK: - Asymmetric Emphasized Easing
    // Material Design 3 / Apple HIG 非對稱曲線：進場慢出（觀眾還在看）、退場快進（觀眾已轉移注意）。
    // 是「絲滑感」與「Things 3 / Linear 質感」的核心曲線。

    /// 進場曲線 — 緩入快出，配 sheet / panel / overlay reveal
    /// timingCurve(0.05, 0.7, 0.1, 1.0, duration: 0.4) — 標準 Material decelerate
    static let emphasizedDecelerate = Animation.timingCurve(0.05, 0.7, 0.1, 1.0, duration: 0.4)

    /// Continuous follow-scroll glide for the podcast transcript: one animated
    /// `scrollTo(.center)` per sentence boundary. Springs and `.smooth` start from
    /// rest but front-load their velocity, so the move still feels fast at the
    /// instant a sentence flips. This timing curve pins BOTH control points hard
    /// against the rest states (P1 high-x/zero-y = very slow start, P2 low-x/one-y
    /// = very slow finish) so the scroll eases in and out gently — a soft drag, no
    /// snap. The long duration lets adjacent sentence moves overlap into one
    /// continuous glide (tuned on device).
    static let podcastFollowScroll = Animation.timingCurve(0.65, 0.0, 0.35, 1.0, duration: 0.9)

    /// Step indicator / pagination indicator 寬度切換
    /// 配 onboarding capsule 寬度由 inactive → active 過渡，須線性短促不彈跳
    static let indicatorTransition = Animation.easeOut(duration: DesignTokens.Motion.Duration.indicator)

    // MARK: - Continuous / Loading Motion

    /// 微脈動 — 用於 empty state、loading 等需要「呼吸感」但不搶焦的元素
    static let subtleBreath = Animation.easeInOut(duration: DesignTokens.Motion.Duration.subtleBreath).repeatForever(autoreverses: true)

    // MARK: - Tap Feedback Triplet (scale + opacity + haptic)
    // 「按下去」物理感的三件套常量，供 PressableInteraction / ButtonStyle 內部使用

    enum TapFeedback {
        /// 按下時的縮放比例
        static let scaleDown: CGFloat = DesignTokens.Motion.TapFeedback.scaleDown
        /// 按下時的透明度（opacity dip）
        static let opacityDip: Double = DesignTokens.Motion.TapFeedback.opacityDip
        /// 對應的動畫曲線
        static let animation = Animation.interactiveSpring(response: DesignTokens.Motion.Spring.TapFeedback.response, dampingFraction: DesignTokens.Motion.Spring.TapFeedback.damping)
    }
}

/// Reduce Motion 下 review 動效的唯一解析點（#3128）。依 `docs/sop/ui-design.md` Motion Contract：
/// 位移／縮放動畫改為瞬間（`nil`），揭示／切換／完成只保留 opacity cross-fade。
/// 關閉 Reduce Motion 時每個語意都保留原 spring，行為不變。
enum AppMotionResolver {
    enum ReviewKind: Equatable {
        case reveal
        case navigation
        case celebration
        case fling(duration: Double)
        case snapBack
        case tracking
    }

    enum Resolved: Equatable {
        case spring(ReviewKind)
        case crossFade
        case instant
    }

    static func resolve(_ kind: ReviewKind, reduceMotion: Bool) -> Resolved {
        guard reduceMotion else { return .spring(kind) }
        switch kind {
        case .reveal, .navigation, .celebration:
            return .crossFade
        case .fling, .snapBack, .tracking:
            return .instant
        }
    }

    static func animation(_ kind: ReviewKind, reduceMotion: Bool) -> Animation? {
        switch resolve(kind, reduceMotion: reduceMotion) {
        case .spring(let springKind):
            return springAnimation(for: springKind)
        case .crossFade:
            return AppMotion.quickEaseOut
        case .instant:
            return nil
        }
    }

    /// 非 View 呼叫點（TodayReviewState）在動作當下讀取系統設定；View 內請傳入 `\.accessibilityReduceMotion`。
    static func systemAnimation(_ kind: ReviewKind) -> Animation? {
        animation(kind, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    private static func springAnimation(for kind: ReviewKind) -> Animation {
        switch kind {
        case .reveal: return AppMotion.reviewRevealSpring
        case .navigation: return AppMotion.reviewNavigationSpring
        case .celebration: return AppMotion.celebrationBounce
        case .fling(let duration): return AppMotion.swipeFling(duration: duration)
        case .snapBack: return AppMotion.swipeSnapBackSpring
        case .tracking: return AppMotion.swipeTrackingSpring
        }
    }
}

extension AnyTransition {
    static let overlayFade = AnyTransition.opacity
    static let readerPanelReveal = AnyTransition.move(edge: .bottom).combined(with: .opacity)
    static let feedbackBadge = AnyTransition.scale(scale: 0.8).combined(with: .opacity)
    static let linkedOverlayCard = AnyTransition.scale(scale: 0.96).combined(with: .opacity)
    static let modalSwap = AnyTransition.asymmetric(
        insertion: .scale(scale: 0.97).combined(with: .opacity),
        removal: .opacity
    )
    static let statusRowReveal = AnyTransition.move(edge: .top).combined(with: .opacity)
    /// 內容替換（適用於 list item、card 內容切換）
    static let contentSwap: AnyTransition = .opacity.combined(with: .scale(scale: 0.97))
    /// Banner / toast 從頂部滑入
    static let bannerReveal: AnyTransition = .move(edge: .top).combined(with: .opacity)
    /// 書架卡片進出（微縮放 + 淡出）
    static let bookshelfCard: AnyTransition = .opacity.combined(with: .scale(scale: 0.96))
    /// 列表項目簡潔過渡
    static let listItemFade: AnyTransition = .opacity.animation(AppMotion.contentFade)
    static let listInsert: AnyTransition = .opacity.combined(with: .offset(y: 8))
    /// 列表內容批次替換（insert + remove asymmetric 包裝）
    static let listSwap: AnyTransition = .asymmetric(insertion: .listInsert, removal: .opacity)
    /// 抽屜 / drawer 從右側滑入並淡入
    static let drawerReveal: AnyTransition = .move(edge: .trailing).combined(with: .opacity)
    /// Sync phase 切換（blur replace）
    static let phaseBlurSwap: AnyTransition = .init(.blurReplace)
    /// 選取模式 checkbox 顯現
    static let selectionReveal: AnyTransition = .scale.combined(with: .opacity)
}

// MARK: - 8pt grid spacing / radius scale / elevation language
// 所有元件一律使用此 namespace（AppSpacing / AppRoundness / AppElevation）。

/// 8pt grid spacing scale。一律以 4 的倍數為節奏，2/3pt 為例外 hairline 用途。
enum AppSpacing {
    static let zero: CGFloat = 0
    /// hairline — 僅用於 divider / progress / 微縫隙
    static let hairline: CGFloat = DesignTokens.Space.Scale.hairline
    /// 2pt 微縫隙 — 8pt grid 例外，僅限極小貼合間距
    /// `AppSpacing.microGap` is the 2pt scale alias; keep it distinct from `AppSkin.Spacing.rowMicroGap`.
    static let microGap: CGFloat = DesignTokens.Space.Scale.micro
    /// 3pt 微縫隙 — 8pt grid 例外
    static let tinyGap: CGFloat = DesignTokens.Space.Scale.tiny
    static let s1: CGFloat = DesignTokens.Space.Scale.s1
    static let s2: CGFloat = DesignTokens.Space.Scale.s2
    static let s3: CGFloat = DesignTokens.Space.Scale.s3
    static let s4: CGFloat = DesignTokens.Space.Scale.s4
    static let s5: CGFloat = DesignTokens.Space.Scale.s5
    static let s6: CGFloat = DesignTokens.Space.Scale.s6
    static let s7: CGFloat = DesignTokens.Space.Scale.s7
    static let s8: CGFloat = DesignTokens.Space.Scale.s8
    static let s9: CGFloat = DesignTokens.Space.Scale.s9
    static let s10: CGFloat = DesignTokens.Space.Scale.s10

    /// Card 雙層 padding — 外緣比內項大，形成呼吸層次（Linear / Notion pattern）
    static let cardOuterPadding: CGFloat = s6  // 24
    static let cardInnerGap: CGFloat = s4      // 16
    static let cardSectionGap: CGFloat = s3    // 12
    static let cardPadding: CGFloat = DesignTokens.Space.Semantic.cardPadding
    static let sectionGap: CGFloat = DesignTokens.Space.Semantic.sectionGap
    static let chipPaddingHorizontal: CGFloat = DesignTokens.Space.Semantic.chipPaddingH
    static let chipPaddingVertical: CGFloat = DesignTokens.Space.Semantic.chipPaddingV
    static let actionButtonVerticalPadding: CGFloat = 13
}

/// Roundness scale —— 全 app 圓角的唯一參數面。
///
/// 值是**無因次**的圓度 `t ∈ [0, 1]`，不是長度。實際半徑由 `AppRoundedRect`
/// 在 render 當下從元件自己的 box 導出：`r = t · min(W, H) / 2`。
///
/// 只有五個名字，刻意不再細分：`0 / .15 / .30 / .45 / 1`。
/// 三個等距 0.15 階之後直接跳到端點，是為了讓整個系統背得起來。
///
/// 三個校準點來自現況實測，不是配出來的數字：
/// - `card` 0.15 → 書封短邊是 grid 欄寬（`.adaptive(150...200)`），iPhone 實測
///   155–165pt，得 r ≈ 11.7–12.3。舊值是絕對 10pt，所以**比舊的圓約 20%**，不是等值
/// - `control` 0.30 → 搜尋框 39pt 高得到 r=5.9（舊 `AppRadius.sm` = 6）
/// - `icon` 0.45 → `AppHeroIcon` 80×80 得到 r=18（舊 `AppRadius.appIcon` = 18），
///   同時等於 Apple app icon 的 22.5% 邊長比，也是 web `site.css` 用的值
enum AppRoundness {
    /// 直角
    static let none: CGFloat = DesignTokens.Roundness.Scale.none
    /// 卡片 / 清單 / 面板 / sheet / 書封
    static let card: CGFloat = DesignTokens.Roundness.Scale.card
    /// 按鈕 / 輸入框 / 列選取 / tab / toolbar
    static let control: CGFloat = DesignTokens.Roundness.Scale.control
    /// app icon / 方形頭像 / glyph tile
    static let icon: CGFloat = DesignTokens.Roundness.Scale.icon
    /// chip / tag / badge / toast / 進度條 / skeleton bar。
    /// t=1 端點刻意**不**退化成正圓或圓弧膠囊——曲率全程 `.continuous`，端點是方圓。
    static let pill: CGFloat = DesignTokens.Roundness.Scale.pill
}

/// Elevation language — z0 flush ← → z4 modal，跨元件統一深度層級。
/// 全 app 唯一的 shadow 系統 — 所有投影一律走 `.appElevation(.zN)`。
enum AppElevation {
    case z0  // flush
    case z1  // resting card / list row
    case z2  // raised / hover / pressed up
    case z3  // overlay (sheet, drawer, popover)
    case z4  // modal / fullscreen overlay

    // Notion-inspired：表面靠 border 分層，shadow 僅做極輕的浮起暗示。
    // resting card（z1）幾乎無陰影；明顯陰影保留給 overlay / modal。
    var opacity: Double {
        switch self {
        case .z0: return DesignTokens.Elevation.Steps.Z0.opacity
        case .z1: return DesignTokens.Elevation.Steps.Z1.opacity
        case .z2: return DesignTokens.Elevation.Steps.Z2.opacity
        case .z3: return DesignTokens.Elevation.Steps.Z3.opacity
        case .z4: return DesignTokens.Elevation.Steps.Z4.opacity
        }
    }

    var radius: CGFloat {
        switch self {
        case .z0: return DesignTokens.Elevation.Steps.Z0.blur
        case .z1: return DesignTokens.Elevation.Steps.Z1.blur
        case .z2: return DesignTokens.Elevation.Steps.Z2.blur
        case .z3: return DesignTokens.Elevation.Steps.Z3.blur
        case .z4: return DesignTokens.Elevation.Steps.Z4.blur
        }
    }

    var y: CGFloat {
        switch self {
        case .z0: return DesignTokens.Elevation.Steps.Z0.y
        case .z1: return DesignTokens.Elevation.Steps.Z1.y
        case .z2: return DesignTokens.Elevation.Steps.Z2.y
        case .z3: return DesignTokens.Elevation.Steps.Z3.y
        case .z4: return DesignTokens.Elevation.Steps.Z4.y
        }
    }
}

/// Elevation 投影方向 — `.down` 標準下投（卡片浮起），`.up` 向上投影（底部 toolbar / panel）。
enum ElevationDirection {
    case down
    case up
}

/// Theme-aware elevation modifier — 在 dark mode 自動加強陰影 opacity
/// 否則黑底加黑影完全不可見，導致 elevation 語意失效。
private struct AppElevationModifier: ViewModifier {
    let z: AppElevation
    var direction: ElevationDirection = .down
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        // dark mode 上 black shadow 與 dark background 對比不足，
        // 提高 opacity 至 1.8x 補回視覺層次（Material Dark Elevation pattern）
        let darkBoost: Double = colorScheme == .dark ? 1.8 : 1.0
        // `.up` 將投影方向翻轉為向上（底部浮動 bar / panel）
        let offsetY = direction == .up ? -z.y : z.y
        return content.shadow(
            color: .black.opacity(z.opacity * darkBoost),
            radius: z.radius,
            y: offsetY
        )
    }
}

extension View {
    /// Apply elevation shadow token。使用 `.appElevation(.z2)` 取代 raw `.shadow(...)`。
    /// 自動感知 light / dark mode 並調整 shadow 強度，dark mode 上會加強至 1.8x opacity。
    /// `direction: .up` 用於底部 toolbar / panel 的向上投影。
    func appElevation(_ z: AppElevation, direction: ElevationDirection = .down) -> some View {
        modifier(AppElevationModifier(z: z, direction: direction))
    }
}

// MARK: - AppMotion Convenience Modifiers
extension View {
    func animatePhaseChange<V: Equatable>(_ value: V) -> some View {
        animation(AppMotion.phaseChange, value: value)
    }
    func animateSpring<V: Equatable>(_ value: V) -> some View {
        animation(AppMotion.standardSpring, value: value)
    }
    func animateContentFade<V: Equatable>(_ value: V) -> some View {
        animation(AppMotion.contentFade, value: value)
    }
    func animateControl<V: Equatable>(_ value: V) -> some View {
        animation(AppMotion.controlEaseOut, value: value)
    }
}
