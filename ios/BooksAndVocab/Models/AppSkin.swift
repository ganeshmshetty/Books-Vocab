//
//  AppSkin.swift
//  Books & Vocab
//
//  全 app 共用的 feature-level UI Token 層（顏色、字型、圓角、間距、metrics）。
//  ─────────────────────────────────────────────────────────────────────
//  定位：AppSkin 是 AppTheme 的 feature 擴充層 —— Palette facade（passthrough
//  AppTheme.Palette + feature 色）＋ Typography / Radii / Spacing / Metrics。
//  涵蓋範圍不限 Vocabulary：Reader / Settings / Podcast 等 feature 皆透過
//  @Environment(\.appSkin) 取用（前身為 VocabSkin，已正名以符實際 scope）。
//
//  使用方式：
//    組件透過 @Environment(\.appSkin) 讀取，不應直接用 AppColors 或硬編碼色彩。
//
//  組裝來源有兩種：
//    1. AppSkin.themed(appTheme)  — 由 AppTheme（Light/Dark）組裝，
//       99% 情況下使用這個，可隨系統深淺色模式自動切換。
//    2. AppSkin.previewNeutral   — 由 themed(.light) 組裝的固定淺色 skin，
//       僅用於 SwiftUI Preview 或特定固定場景，不受系統深淺色影響。
//
//  設計哲學：Notion-inspired 紙本排版
//    純淨表面、border 分層，typography 以 monospaced 為主視覺重心。
//  ─────────────────────────────────────────────────────────────────────

import SwiftUI

/// AppSkin 專屬色票 —— `AppTheme.Palette` 未涵蓋的 feature 色。
/// 與 `AppColors`（Reader + 全域）分離：此 enum 僅供 `AppSkin.themed()` 組裝取用。
/// scheme-aware 色給 light/dark 一對；固定色（不隨深淺色）為單值。
enum AppSkinColors {
    // ── 連結文字（Morandi grey-blue，與 AppColors.accent 一致）──
    static let linkLight = Color(red: 0.302, green: 0.451, blue: 0.588)
    static let linkDark  = Color(red: 0.522, green: 0.643, blue: 0.761)

    // ── 翻譯文字（栗棕）──
    static let translationLight = Color(red: 0.54, green: 0.50, blue: 0.44)
    static let translationDark  = Color(red: 0.80, green: 0.72, blue: 0.64)

    // ── 難度 Tier（固定色，不隨系統深淺色 — 與 themed() 既有行為一致）──
    static let tierIntermediate = Color(red: 0.72, green: 0.63, blue: 0.36)
    static let tierAdvanced     = Color(red: 0.84, green: 0.54, blue: 0.28)

    // ── 重試提示（琥珀）──
    static let retryLight = Color(hue: 0.08, saturation: 0.55, brightness: 0.68)
    static let retryDark  = Color(hue: 0.08, saturation: 0.45, brightness: 0.78)

    // ── 逾期（霧紫）──
    static let overdueLight = Color(red: 0.56, green: 0.40, blue: 0.66)
    static let overdueDark  = Color(red: 0.62, green: 0.48, blue: 0.72)

    // ── 例句高光（紙感螢光筆）──
    static let highlightMarkLight = Color(red: 0.90, green: 0.84, blue: 0.57)
    static let highlightMarkDark  = Color(red: 0.73, green: 0.66, blue: 0.33)
}

struct AppSkin {
    /// Vocabulary skin 色票 —— facade 結構，非平行設計系統。
    /// - 與 `AppTheme.Palette` 同義的欄位為 computed forwarder，唯一真相在 `base`：
    ///   AppTheme 改色自動穿透，不可能漂移。
    /// - feature-own 色（tier / link / retry / overdue / highlightMark / translation
    ///   / readerThemeSwatch）為 stored，由 `themed()` 注入。
    /// - 衍生欄位（*Muted / *Faint / *Subtle）為 computed，不另存複本。
    struct Palette {
        /// 全域 AppTheme 色票 —— 所有 passthrough 欄位的唯一真相。
        let base: AppTheme.Palette

        // ── feature-own stored 色 ──
        let translationText: Color
        let tierIntermediate: Color
        let tierAdvanced: Color
        let retry: Color
        let overdue: Color
        let highlightMark: Color
        let link: Color

        // ── passthrough forwarder（唯一真相 = base）──
        var pageBackground: Color { base.pageBackground }
        var stageBackground: Color { base.stageBackground }
        var cardBackground: Color { base.cardBackground }
        var cardBorder: Color { base.cardBorder }
        var borderStrong: Color { base.borderStrong }
        var divider: Color { base.divider }
        var shadow: Color { base.shadow }
        var primaryText: Color { base.primaryText }
        var secondaryText: Color { base.secondaryText }
        var tertiaryText: Color { base.tertiaryText }
        var quaternaryText: Color { base.quaternaryText }
        var accent: Color { base.accent }
        var brandHero: Color { base.brandHero }
        var accentSubtle: Color { base.accentSubtle }
        var success: Color { base.success }
        var successBg: Color { base.successBg }
        var warning: Color { base.warning }
        var warningBg: Color { base.warningBg }
        var info: Color { base.info }
        var infoBg: Color { base.infoBg }
        var destructive: Color { base.destructive }
        var destructiveBg: Color { base.destructiveBg }
        var mutedFill: Color { base.mutedFill }
        var overlayScrim: Color { base.scrim }
        var overlayFill: Color { base.overlayFill }
        var progressBarBackground: Color { base.progressBarBackground }
        var buttonIdleFill: Color { base.buttonIdleFill }
        var buttonPressedFill: Color { base.buttonPressedFill }

        // ── 衍生欄位（由 base / feature 色計算，不另存）──
        var primaryTextMuted: Color { base.primaryText.opacity(0.84) }
        var quaternaryTextFaint: Color { base.quaternaryText.opacity(0.14) }
        var highlightMarkSubtle: Color { highlightMark.opacity(0.68) }
    }

    struct Typography {
        let displayTitle: Font
        let sectionTitle: Font
        let detailWord: Font
        let reviewWord: Font
        let rowWord: Font
        let translationTitle: Font
        let body: Font
        /// 書摘卡（#3113）：Linked Card、Word Detail、複習卡背面共用的例句字級。
        let cardExample: Font
        let caption: Font
        let monoLabel: Font
        let monoBody: Font
        let monoBodyStrong: Font
        let monoEmphasis: Font
        let numericHero: Font
        let iconTiny: Font
        let iconSmall: Font
        let iconMedium: Font
        let iconToolbar: Font
        let iconNavigation: Font
        let symbolLarge: Font
        let symbolHero: Font
        let symbolPlayback: Font
        let settingsFontSizeDisplay: Font
        let settingsAdjustSmall: Font
        let settingsAdjustLarge: Font
    }

    /// 圓角語意 token —— 值一律取自 `AppRoundness` scale。
    ///
    /// 存的是**無因次**圓度 `t ∈ [0, 1]`，不是長度；實際半徑由 `AppRoundedRect`
    /// 在 render 當下算出（`r = t · min(W, H) / 2`）。四個語意名對應四個 t：
    /// card=.15 / control=.30 / icon=.45 / pill=1。
    ///
    /// 舊的 `Radii`（card·overlay / control·chip·tiny）已收斂：overlay 併入 card、
    /// chip·tiny 併入 pill——實測顯示它們的實際圓度本來就分別落在同一階。
    struct Roundness {
        let card: CGFloat
        let control: CGFloat
        let icon: CGFloat
        let pill: CGFloat
    }

    struct Spacing {
        let cardPadding: CGFloat
        let sectionGap: CGFloat
        let inlineGap: CGFloat
        let rowPadding: CGFloat
        let rowMicroGap: CGFloat
        let chipHorizontalPadding: CGFloat
        let chipVerticalPadding: CGFloat
        let chipVerticalPaddingLoose: CGFloat
        let prominentChipHorizontalPadding: CGFloat
        let prominentChipVerticalPadding: CGFloat
        let compactChipHorizontalPadding: CGFloat
        let compactChipVerticalPadding: CGFloat
        let compactRowVerticalPadding: CGFloat
        let compactRowAccessoryTopInset: CGFloat
        let heroDescriptionHorizontalInset: CGFloat
        let actionButtonHorizontalPadding: CGFloat
        let actionButtonVerticalPadding: CGFloat
        let wordRowHorizontalGap: CGFloat
        let wordRowVerticalGap: CGFloat
        let wordRowBaselineGap: CGFloat
        let metadataGap: CGFloat
        let statusHeroGap: CGFloat
        let timelineRowGap: CGFloat
        let timelineDetailGap: CGFloat
        let heroBaselineGap: CGFloat
        let sourceMetadataGap: CGFloat
        let blockGap: CGFloat
        let chipHorizontalPaddingOuter: CGFloat
        // Settings sheet
        let sheetSectionSpacing: CGFloat
        let sheetPadding: CGFloat
        let sheetPaddingCompact: CGFloat
        let controlGap: CGFloat
        let rowContentSpacing: CGFloat
        let controlVerticalPadding: CGFloat
        let controlHorizontalPadding: CGFloat
        let badgeHorizontalPadding: CGFloat
        let tinyGap: CGFloat
        let lineSpacingRelaxed: CGFloat
    }

    struct Metrics {
        let pageHorizontalInset: CGFloat
        let pageTopInset: CGFloat
        let pageBottomInset: CGFloat
        let pageSectionVerticalInset: CGFloat
        let sectionHeaderGap: CGFloat
        let listRowHorizontalInset: CGFloat
        let listDividerInset: CGFloat
        let heroSectionSpacing: CGFloat
        let accessoryTopOffset: CGFloat
        let overlayHorizontalInset: CGFloat
        let syncOverlayInset: CGFloat
        /// 狀態符號欄的固定寬度。六種同步步驟符號寬度不一（`ProgressView` 尤其），
        /// 固定欄寬才能讓它們對齊同一條軸線。這是**尺寸**不是間距，所以住在 metrics。
        let statusIconColumn: CGFloat
        let overlayVerticalInset: CGFloat
        let summaryHorizontalInset: CGFloat
        let chromeButtonSize: CGFloat
        let overlayHeaderHorizontalInset: CGFloat
        let overlayHeaderVerticalInset: CGFloat
        let listCardHeaderTopInset: CGFloat
        let listCardHeaderBottomInset: CGFloat
        let overlayCompactDividerInset: CGFloat
        let overlayDrawerHorizontalInset: CGFloat
        let overlayDrawerBottomInset: CGFloat
        let emptyStateOuterInset: CGFloat
        let listEmptyStateVerticalInset: CGFloat
        let cardBlockPadding: CGFloat
        let cardBlockContentGap: CGFloat
        let cardBlockInnerGap: CGFloat
        let cardDividerHorizontalPadding: CGFloat
        let linkRowVerticalPadding: CGFloat
        let linkRowHorizontalGap: CGFloat
        let linkDetailGap: CGFloat
        let metadataFooterGap: CGFloat
        let metadataFooterItemGap: CGFloat
        let tabSelectorHeight: CGFloat
        let progressBarWidth: CGFloat
        let progressBarHeight: CGFloat
        let paragraphLineSpacing: CGFloat
        let detailLineSpacing: CGFloat
        let exampleTruncateRadius: Int
        let labelTracking: CGFloat
        let panelHandleOpacity: Double
        let graphDrawerBottomInset: CGFloat
    }

    /// 統一的字詞高光樣式配置（例句中 `**word**` 的視覺呈現）
    struct HighlightConfig {
        let backgroundOpacity: Double
        let underlineOpacity: Double
        let showBackground: Bool
        let showUnderline: Bool
        let fontWeight: Font.Weight

        static let `default` = HighlightConfig(
            backgroundOpacity: 0.22,
            underlineOpacity: 0.68,
            showBackground: true,
            showUnderline: false,
            fontWeight: .semibold
        )
    }

    let palette: Palette
    let typography: Typography
    let roundness: Roundness
    let spacing: Spacing
    let metrics: Metrics
    let highlight: HighlightConfig

    func tierColor(for tier: String?) -> Color {
        switch tier {
        case "core":
            return palette.success
        case "intermediate":
            return palette.tierIntermediate
        case "advanced":
            return palette.tierAdvanced
        case "rare":
            return palette.destructive
        default:
            return palette.secondaryText
        }
    }

    func tierLabel(for tier: String?) -> String {
        switch tier {
        case "core":
            return "core"
        case "intermediate":
            return "intermediate"
        case "advanced":
            return "advanced"
        case "rare":
            return "rare"
        default:
            return tier ?? ""
        }
    }
}

extension AppSkin {
    /// 由 AppTheme 組裝的 AppSkin，隨系統深淺色模式自動切換。
    /// 這是正常使用的工廠方法，請在注入 @Environment(\.appSkin) 時呼叫此方法。
    static func themed(_ theme: AppTheme) -> AppSkin {
        let isDark = theme.colorScheme == .dark

        return AppSkin(
            palette: .init(
                base: theme.palette,
                translationText: isDark ? AppSkinColors.translationDark : AppSkinColors.translationLight,
                tierIntermediate: AppSkinColors.tierIntermediate,
                tierAdvanced: AppSkinColors.tierAdvanced,
                retry: isDark ? AppSkinColors.retryDark : AppSkinColors.retryLight,
                overdue: isDark ? AppSkinColors.overdueDark : AppSkinColors.overdueLight,
                highlightMark: isDark ? AppSkinColors.highlightMarkDark : AppSkinColors.highlightMarkLight,
                link: isDark ? AppSkinColors.linkDark : AppSkinColors.linkLight
            ),
            typography: baseTypography,
            roundness: baseRoundness,
            spacing: baseSpacing,
            metrics: baseMetrics,
            highlight: .default
        )
    }

    /// 固定淺色 skin，不受系統深淺色模式影響。
    /// 僅用於 SwiftUI Preview 或特定固定呈現場景，正常業務請改用 themed()。
    /// 由 themed(.light) 組裝 — 與正式 light skin 單一真相，消除硬編碼複本漂移。
    static let previewNeutral = AppSkin.themed(.light)
}
