import SwiftUI

/// Today Review 功能專用版面參數（摺頁卡片、字數徽章、swipe hint）。
enum TodayReviewMetrics {
    // ── Stack 動畫 ──────────────────────────────────────────────────
    /// 卡片升起時的 Y 偏移（promote 動畫）
    static let promoteYOffset: CGFloat = 22
    /// 卡片升起時的縮放比例
    static let promoteScale: CGFloat = 0.96

    // ── 展開提示 ───────────────────────────────────────────────────
    /// 展開提示出現時，卡片右側的內縮量（為提示圖示騰出空間）
    static let expandHintTrailingPadding: CGFloat = 40

    // ── Tag / Chip ──────────────────────────────────────────────────
    /// 字數徽章水平 padding（對齊 AppTagMetrics）
    static let tagHorizontalPadding: CGFloat = AppTagMetrics.horizontalPadding
    /// 字數徽章垂直 padding（對齊 AppTagMetrics）
    static let tagVerticalPadding: CGFloat = AppTagMetrics.verticalPadding

    // ── Opacity ─────────────────────────────────────────────────────
    /// 卡片邊框線條透明度（idle 狀態）
    static let cardBorderOpacity: Double = 0.45
    /// 卡片邊框線條透明度（fold 狀態 / active）
    static let cardBorderActiveOpacity: Double = 0.72
    /// 淡化文字透明度（quaternaryText 用）
    static let dimTextOpacity: Double = 0.72
    /// 填充色透明度（divider 用）
    static let dividerFillOpacity: Double = 0.85

    // ── Font Size ───────────────────────────────────────────────────
    /// 字數 > 20 時的字體大小
    static let counterFontSizeCompact: CGFloat = 22
    /// 字數 > 12 時的字體大小
    static let counterFontSizeMedium: CGFloat = 26
    /// 字數 ≤ 12 時的字體大小（最大）
    static let counterFontSizeLarge: CGFloat = 28
    /// 複習卡正面單字 ≤ 12 字時的字體大小
    static let counterFontSizeXLarge: CGFloat = 30

    // ── Swipe Hint ──────────────────────────────────────────────────
    /// Swipe hint 標籤字體大小（忘記/記得）
    static let swipeHintFontSize: CGFloat = 34

    // ── Fold Geometry ──────────────────────────────────────────────
    /// 摺頁接合處的圓度（非首尾段的內側圓角）—— 無因次 t，非 pt。
    ///
    /// 刻意綁在 `card` 的一半：接縫是「同一張紙被摺過」的暗示，必須比外緣**明顯更方**
    /// 才讀得出層次，但兩者要一起隨卡片尺寸縮放，否則卡一高就失去比例關係。
    /// 綁定而非另取一個獨立常數，是為了讓外緣圓度日後調整時接縫自動跟上。
    static let foldJoinRoundness: CGFloat = AppRoundness.card / 2
    /// 摺頁卡四個角的共用基準（pt）。摺頁卡橫跨 front / answer 兩個 layout box，
    /// 高度不同，所以圓角基準必須來自「這張卡」而不是「這一段」——否則同一條接縫的
    /// 上下緣會算出不同半徑。取 front 段的設計高度（`frontMinHeight`）當代表尺度。
    ///
    /// 這個值曾在 a5885e228 刪掉 `frontMinHeight` 時被原值內聯（120）以維持逐像素
    /// 相同；常數回來之後改綁回去，**值不變**（改了會動摺頁圓角，屬另一件事）。
    static let foldRoundnessBasis: CGFloat = frontMinHeight
    /// 摺頁動畫的 Y 軸偏移量
    static let paperFoldOffsetY: CGFloat = 12

    // ── Micro Adjustment ────────────────────────────────────────────
    /// 卡片疊層微調（消除 1pt 視覺縫隙）
    static let stackLayerMicroOffset: CGFloat = -1
    /// 答案展開提示區塊的頂部微調
    static let answerHintTopPadding: CGFloat = 2

    // ── 從 AppSkin.Metrics 遷出(Phase 4 of boundary rectify)─────────

    // MARK: Progress(in原 baseSpacing,搬入此 feature)
    static let progressBarGap: CGFloat = 5

    // MARK: Card layout(不與既有 cardBorderOpacity / cardBorderActiveOpacity 合併語意)
    static let cardHorizontalInset: CGFloat = AppSpacing.s2
    static let cardTopInset: CGFloat = AppSpacing.s2
    static let cardBottomInset: CGFloat = AppSpacing.s2

    // MARK: TopBar
    static let topBarHorizontalInset: CGFloat = 20
    static let topBarTopInset: CGFloat = 10
    static let topBarBottomInset: CGFloat = 6

    // MARK: Toolbar
    static let toolbarHorizontalInset: CGFloat = 20
    static let toolbarVerticalInset: CGFloat = 12

    // MARK: Fold layout(不與既有 foldJoinRoundness / paperFoldOffsetY 幾何欄位合併)
    static let foldPadding: CGFloat = 28
    /// 正面右上角 chrome：無框字形到卡片頂／右緣的視覺距離（#3112）。
    static let chromeCornerInset: CGFloat = AppSpacing.s3
    /// 44pt 觸控框相對 14pt 字形每側多出的量 = (44 − 14) / 2（#3112）。
    static let chromeHitOverhang: CGFloat = 15
    static let foldSectionSpacing: CGFloat = 24
    /// 精簡流程最後一階：section 間距降到此值（`ReviewCardLayoutSolver` 算、
    /// 卡片正反面畫，共用同一顆 token）。
    static let foldSectionSpacingCompact: CGFloat = AppSpacing.s2
    static let foldHintBottomInset: CGFloat = 22
    /// 單字本標示（#2040）畫在正面 `foldPadding + foldHintBottomInset` 這條既有頂部
    /// 留白裡、以 overlay 疊上，不參與版面——出現與否都不改卡片高度。
    static let notebookBadgeTopInset: CGFloat = AppSpacing.s4
    static let notebookBadgeDotSize: CGFloat = 6
    /// 卡內「＋」新增連結的可點範圍下限（HIG 44pt，#2044）。只擴可點範圍，不擴版面。
    static let addLinkHitTarget: CGFloat = AppFloatingChromeMetrics.hitTarget
    /// 摺頁 chevron 的命中下限（HIG 44pt，#3117）。命中帶以摺線為中心，半高 = 此值 / 2 = 22，
    /// 必須小於正反面共用的 `ReviewCardChrome.padding`（28），帶子才只落在空白 padding 內。
    static let chevronHitTarget: CGFloat = AppFloatingChromeMetrics.hitTarget
    /// 複習卡解釋段落的行距。等同 `CardDocumentMeaningBlock(compact: true)` 一直
    /// 在畫的值 —— 預設佈局要重現目前畫面，這顆就必須是同一個數字。
    static let foldMeaningLineSpacing: CGFloat = 5

    // MARK: Card / Action min size
    /// 正面段的高度地板。正面**貼合內容**（一個單字的卡不該佔滿整份預算），這是它縮到
    /// 最小時的下限，也是摺頁圓角的共用基準 `foldRoundnessBasis`。a5885e228 把正面的
    /// `.frame(minHeight:)` 換成貪婪的 `.frame(maxHeight:)` 時把這顆常數一起刪了。
    static let frontMinHeight: CGFloat = 120
    static let answerMinHeight: CGFloat = 188
    static let actionMinWidth: CGFloat = 92
    static let chevronButtonSize: CGFloat = 30

    // MARK: Height ratio / Swipe geometry
    static let frontHeightRatio: CGFloat = 0.22
    /// 「點一下展開」區塊的高度下限。它是**卡片下方的 layout 兄弟**，正面階段
    /// 恆佔這麼多空間 —— `ReviewCardViewport` 用同一顆 token 從正面預算扣掉它，
    /// 所以 solver 相信的高度就是畫面真的讓出來的高度。
    static let revealZoneMinHeight: CGFloat = 180
    static let swipeThreshold: CGFloat = 100
    static let swipeMaxRotation: Double = 12
    static let swipeOpacityFloor: Double = 0.3
    /// 卡片方向標記（#2045）：靜態傾角（記得往左傾、忘記往右傾，跟著卡片旋轉）、
    /// 與卡片上緣 / 側緣的內距、外框線寬、底色不透明度（壓在卡片內容上仍可讀）。
    static let swipeMarkerTilt: Double = 12
    static let swipeMarkerInset: CGFloat = AppSpacing.s4
    static let swipeMarkerBorderWidth: CGFloat = 2
    static let swipeMarkerFillOpacity: Double = 0.85

    // MARK: Autoplay player
    static let autoplayProgressBarHeight: CGFloat = 4
    static let autoplayProgressBarBottomGap: CGFloat = AppSpacing.s2
    static let autoplaySpeedPillHeight: CGFloat = 28
    static let autoplaySpeedPillHorizontalPadding: CGFloat = AppSpacing.s3
}
