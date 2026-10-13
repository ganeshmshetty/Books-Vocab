//
//  AppSkin+BaseValues.swift
//  Books & Vocab
//
//  Token base 預設值 —— baseTypography / baseRadii / baseSpacing / baseMetrics。
//  與主檔 AppSkin.swift 分離以降低主檔噪音;typography cache 同檔放(private 不跨檔可見)。
//

import SwiftUI

extension AppSkin {
    // MARK: - Typography cache

    private static var _cachedTypography: Typography?

    static var baseTypography: Typography {
        if let cached = _cachedTypography { return cached }
        let t = buildTypography()
        _cachedTypography = t
        return t
    }

    static func invalidateTypographyCache() {
        _cachedTypography = nil
    }

    private static func buildTypography() -> Typography {
        Typography(
            // Serif tokens — 標題 (Crimson Pro + STSongti-TC)
            displayTitle: AppFonts.serif(size: 24, bold: true),
            sectionTitle: AppFonts.serif(size: 18, bold: true),
            detailWord: AppFonts.systemMono(size: 27, weight: .semibold),
            reviewWord: AppFonts.systemMono(size: 36, weight: .semibold),
            rowWord: AppFonts.systemMono(size: 18, weight: .semibold),
            translationTitle: AppFonts.serif(size: 21, bold: true),
            // Sans tokens — 內文 (ElmsSans + PingFang TC)
            body: AppFonts.sans(size: 15),
            cardExample: AppFonts.serifItalic(size: 20),
            detailExampleSerif: AppFonts.serifItalic(size: 22),
            detailExampleSerifStrong: AppFonts.serifItalic(size: 22, bold: true),
            caption: AppFonts.sans(size: 12, bold: true),
            // Mono tokens (ElmsSans + system monospaced)
            monoLabel: AppFonts.mono(size: 10, bold: true),
            monoBody: AppFonts.mono(size: 14),
            monoBodyStrong: AppFonts.mono(size: 14, bold: true),
            monoEmphasis: AppFonts.mono(size: 16, bold: true),
            numericHero: AppFonts.serif(size: 38, bold: true),
            // SF Symbols — 系統字繪製,走 AppFonts.symbol builder
            iconTiny: AppFonts.symbol(size: 10, weight: .thin),
            iconSmall: AppFonts.symbol(size: 12, weight: .medium),
            iconMedium: AppFonts.symbol(size: 14, weight: .medium),
            iconToolbar: AppFonts.symbol(size: 15, weight: .medium),
            iconNavigation: AppFonts.symbol(size: 16, weight: .thin),
            symbolLarge: AppFonts.symbol(size: 30, weight: .light),
            symbolHero: AppFonts.symbol(size: 44, weight: .light),
            symbolPlayback: AppFonts.symbol(size: 56, weight: .light),
            // Settings — mono (數值調控)
            settingsFontSizeDisplay: AppFonts.mono(size: 28, bold: true),
            settingsAdjustSmall: AppFonts.sans(size: 15, bold: true),
            settingsAdjustLarge: AppFonts.sans(size: 28, bold: true)
        )
    }

    // MARK: - Radii / Spacing / Metrics base values

    static let baseRoundness = Roundness(
        card: AppRoundness.card,
        control: AppRoundness.control,
        icon: AppRoundness.icon,
        pill: AppRoundness.pill
    )

    static let baseSpacing = Spacing(
        cardPadding: 18,
        sectionGap: 14,
        inlineGap: 8,
        rowPadding: 9,
        rowMicroGap: 6,
        chipHorizontalPadding: 10,
        chipVerticalPadding: 6,
        chipVerticalPaddingLoose: 8,
        prominentChipHorizontalPadding: 8,
        prominentChipVerticalPadding: 4,
        compactChipHorizontalPadding: 6,
        compactChipVerticalPadding: 3,
        compactRowVerticalPadding: 10,
        compactRowAccessoryTopInset: 2,
        heroDescriptionHorizontalInset: 40,
        actionButtonHorizontalPadding: 16,
        actionButtonVerticalPadding: 13,
        wordRowHorizontalGap: 10,
        wordRowVerticalGap: 4,
        wordRowBaselineGap: 6,
        metadataGap: 4,
        statusHeroGap: 12,
        timelineRowGap: 12,
        timelineDetailGap: 2,
        heroBaselineGap: 8,
        sourceMetadataGap: 6,
        blockGap: 12,
        chipHorizontalPaddingOuter: 12,
        sheetSectionSpacing: 20,
        sheetPadding: 24,
        sheetPaddingCompact: 20,
        controlGap: 10,
        rowContentSpacing: 12,
        controlVerticalPadding: 12,
        controlHorizontalPadding: 14,
        badgeHorizontalPadding: 9,
        tinyGap: 4,
        lineSpacingRelaxed: 6
    )

    static let baseMetrics = Metrics(
        pageHorizontalInset: AppShellMetrics.pageHorizontalPadding,
        pageTopInset: 16,
        pageBottomInset: 120,
        pageSectionVerticalInset: AppSpacing.s2,
        sectionHeaderGap: 10,
        listRowHorizontalInset: 16,
        listDividerInset: 16,
        heroSectionSpacing: 16,
        accessoryTopOffset: 10,
        overlayHorizontalInset: 20,
        syncOverlayInset: 32,
        statusIconColumn: 14,
        overlayVerticalInset: 20,
        summaryHorizontalInset: 24,
        chromeButtonSize: 32,
        overlayHeaderHorizontalInset: 16,
        overlayHeaderVerticalInset: 12,
        listCardHeaderTopInset: 14,
        listCardHeaderBottomInset: 12,
        overlayCompactDividerInset: 8,
        overlayDrawerHorizontalInset: 12,
        overlayDrawerBottomInset: 8,
        emptyStateOuterInset: 20,
        listEmptyStateVerticalInset: 24,
        cardBlockPadding: 24,
        cardBlockContentGap: 16,
        cardBlockInnerGap: 8,
        cardDividerHorizontalPadding: 24,
        linkRowVerticalPadding: 8,
        linkRowHorizontalGap: 8,
        linkDetailGap: 3,
        metadataFooterGap: 24,
        metadataFooterItemGap: 4,
        tabSelectorHeight: 32,
        progressBarWidth: 104,
        progressBarHeight: 5,
        paragraphLineSpacing: 4,
        detailLineSpacing: 5,
        exampleTruncateRadius: 5,
        labelTracking: 0.5,
        panelHandleOpacity: 0.24,
        graphDrawerBottomInset: 11
    )
}
