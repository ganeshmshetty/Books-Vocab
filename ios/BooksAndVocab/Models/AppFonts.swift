//
//  AppFonts.swift
//  Books & Vocab
//
//  統一的字體排印 (Design System Tokens)
//  Serif:  Crimson Pro (EN) + STSongti-TC (CJK cascade)  — 標題用
//  Sans:   ElmsSans (EN) + PingFang TC (CJK cascade)  — 內文用
//  Mono:   ElmsSans (EN) + system monospaced (CJK fallback)
//

import SwiftUI
import UIKit
import CoreText

extension Notification.Name {
    static let serifCJKFontDidBecomeAvailable = Notification.Name("serifCJKFontDidBecomeAvailable")
}

@Observable
final class FontAvailabilityTracker {
    var serifCJKVersion: Int = 0

    private var observer: Any?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .serifCJKFontDidBecomeAvailable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            AppSkin.invalidateTypographyCache()
            self?.serifCJKVersion += 1
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

enum AppFonts {

    // MARK: - Font Builders

    /// Dynamic Type 縮放後的 point size。RED 階段：尚未套用縮放。
    static func scaledPointSize(_ size: CGFloat, compatibleWith traits: UITraitCollection? = nil) -> CGFloat {
        size
    }

    private static func platformFont(descriptor: PlatformFontDescriptor, size: CGFloat) -> PlatformFont {
        PlatformFont(descriptor: descriptor, size: size)
    }

    private static let cascadeListKey = PlatformFontDescriptor.AttributeName(
        rawValue: "NSCTFontCascadeListAttribute"
    )

    // MARK: - Per-Locale CJK Cascade
    //
    // The CJK fallback font for the Latin primary varies by effective language:
    // - en / zh-Hant → PingFang TC / STSongti-TC (TC glyph variants)
    // - zh-Hans → PingFang SC / STSongti-SC (simplified variants)
    // - ja → Hiragino Sans / Hiragino Mincho (proper kanji glyphs)
    // - ko → Apple SD Gothic Neo (sans + serif both — iOS lacks a built-in
    //         Korean serif distinct enough to warrant a separate cascade)
    //
    // Tests can call these via `cjkSansFallbackName` / `cjkSerifFallbackName`
    // directly without touching font construction.

    static func cjkSansFallbackName(bold: Bool) -> String {
        switch AppLanguageStore.shared.effectiveLanguage {
        case .simplifiedChinese:
            return bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        case .japanese:
            return bold ? "HiraginoSans-W6" : "HiraginoSans-W3"
        case .korean:
            return bold ? "AppleSDGothicNeo-Bold" : "AppleSDGothicNeo-Regular"
        case .english, .traditionalChinese, .system:
            return bold ? "PingFangTC-Semibold" : "PingFangTC-Regular"
        }
    }

    static func cjkSerifFallbackName(bold: Bool) -> String {
        switch AppLanguageStore.shared.effectiveLanguage {
        case .simplifiedChinese:
            return bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular"
        case .japanese:
            return bold ? "HiraMinProN-W6" : "HiraMinProN-W3"
        case .korean:
            // iOS lacks a widely-available Korean serif — reuse sans for legibility.
            return bold ? "AppleSDGothicNeo-Bold" : "AppleSDGothicNeo-Regular"
        case .english, .traditionalChinese, .system:
            return bold ? "STSongti-TC-Bold" : "STSongti-TC-Regular"
        }
    }

    /// Serif: Crimson Pro + per-locale CJK serif cascade
    static func serif(size: CGFloat, bold: Bool = false) -> Font {
        let primary = bold ? "CrimsonProRoman-Bold" : "CrimsonProRoman-Regular"
        let fallback = cjkSerifFallbackName(bold: bold)
        let base = PlatformFontDescriptor(fontAttributes: [.name: primary])
        let cjk = PlatformFontDescriptor(fontAttributes: [.name: fallback])
        let descriptor = base.addingAttributes([cascadeListKey: [cjk]])
        return Font(platformFont(descriptor: descriptor, size: size) as CTFont)
    }

    /// Sans: ElmsSans + per-locale CJK sans cascade
    static func sans(size: CGFloat, bold: Bool = false) -> Font {
        let primary = bold ? "ElmsSans-Bold" : "ElmsSans-Regular"
        let fallback = cjkSansFallbackName(bold: bold)
        let base = PlatformFontDescriptor(fontAttributes: [.name: primary])
        let cjk = PlatformFontDescriptor(fontAttributes: [.name: fallback])
        let descriptor = base.addingAttributes([cascadeListKey: [cjk]])
        return Font(platformFont(descriptor: descriptor, size: size) as CTFont)
    }

    /// Mono: ElmsSans + system monospaced cascade
    static func mono(size: CGFloat, bold: Bool = false) -> Font {
        let primary = bold ? "ElmsSans-Bold" : "ElmsSans-Regular"
        let sysMono = PlatformFont.monospacedSystemFont(
            ofSize: size, weight: bold ? .bold : .regular
        ).fontDescriptor
        let base = PlatformFontDescriptor(fontAttributes: [.name: primary])
        let descriptor = base.addingAttributes([cascadeListKey: [sysMono]])
        return Font(platformFont(descriptor: descriptor, size: size) as CTFont)
    }

    /// Serif Italic: CormorantGaramond + per-locale CJK serif cascade — 例句強調渲染
    static func serifItalic(size: CGFloat, bold: Bool = false) -> Font {
        let primary = bold ? "CormorantGaramond-BoldItalic" : "CormorantGaramond-Italic"
        let fallback = cjkSerifFallbackName(bold: bold)
        let base = PlatformFontDescriptor(fontAttributes: [.name: primary])
        let cjk = PlatformFontDescriptor(fontAttributes: [.name: fallback])
        let descriptor = base.addingAttributes([cascadeListKey: [cjk]])
        return Font(platformFont(descriptor: descriptor, size: size) as CTFont)
    }

    /// System Mono: SF Mono — 單字渲染專用（需系統等寬的字面對齊感）
    static func systemMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// SF Symbol 字型 — symbol 一律以系統字繪製，此 builder 收斂散落的 .system(design:.default)
    static func symbol(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // MARK: - Type Scale (字級 ramp — 正式 scale)
    //
    // 以下 7 階構成 app 的正式文字 type scale。新元件字級一律從語意 helper
    // （hero / h1 / h2 / body / subhead / caption / caption2）取用；需 raw
    // size 餵給 builder 時取 `TypeScale.*`。禁止自訂 scale 外字級。
    //
    // 既有 AppSkin.Typography 的 bespoke 字級（14 / 16 / 18 / 21 / 24 / 27 …）
    // 為此 ramp 形式化之前的既有 token，grandfather 保留、本次不 migrate。

    enum TypeScale {
        static let caption2: CGFloat = DesignTokens.Typography.Scale.caption2
        static let caption: CGFloat = DesignTokens.Typography.Scale.caption
        static let subhead: CGFloat = DesignTokens.Typography.Scale.subhead
        static let body: CGFloat = DesignTokens.Typography.Scale.body
        static let h2: CGFloat = DesignTokens.Typography.Scale.h2
        static let h1: CGFloat = DesignTokens.Typography.Scale.h1
        static let hero: CGFloat = DesignTokens.Typography.Scale.hero
    }

    // MARK: - 標題層級 (Headers) — serif

    /// 大型英雄標題 — 40pt serif
    static func hero(weight: Font.Weight = .semibold) -> Font {
        serif(size: TypeScale.hero, bold: weight.isBold)
    }

    /// 頁面主標題 — 28pt serif
    static func h1(weight: Font.Weight = .medium) -> Font {
        serif(size: TypeScale.h1, bold: weight.isBold)
    }

    /// 區塊標題 — 22pt serif
    static func h2(weight: Font.Weight = .medium) -> Font {
        serif(size: TypeScale.h2, bold: weight.isBold)
    }

    // MARK: - 內文層級 (Body) — sans

    /// 預設內文 — 17pt sans
    static func body(weight: Font.Weight = .regular) -> Font {
        sans(size: TypeScale.body, bold: weight.isBold)
    }

    /// 次要說明 — 15pt sans
    static func subhead(weight: Font.Weight = .regular) -> Font {
        sans(size: TypeScale.subhead, bold: weight.isBold)
    }

    // MARK: - 細節層級 (Caption & Mono) — sans

    /// 提示小字 — 12pt sans
    static func caption(weight: Font.Weight = .regular) -> Font {
        sans(size: TypeScale.caption, bold: weight.isBold)
    }

    /// 極小提示 — 11pt sans
    static func caption2(weight: Font.Weight = .regular) -> Font {
        sans(size: TypeScale.caption2, bold: weight.isBold)
    }

    /// 等寬內文 — 17pt ElmsSans mono（body 尺寸，用於音標、程式碼輸入等）
    static func mono() -> Font {
        mono(size: TypeScale.body)
    }

    /// 等寬數字 — ElmsSans mono
    static func monoNumbers(size: CGFloat = 14) -> Font {
        mono(size: size)
    }

    // MARK: - Tracking Tokens (letter-spacing)
    // 在 SwiftUI 用 `.tracking(AppFonts.Tracking.tight)` 套用
    // 數值單位 pt（絕對 letter-spacing）

    enum Tracking {
        /// Display / hero 緊縮 — 配大字級降低視覺鬆散
        /// 在 56pt 級距上約 -0.021em，符合慣例
        static let tight: CGFloat = DesignTokens.Typography.Tracking.tight
        /// H2 緊縮 — Mochi editorial heading（-0.024em 換算 pt）
        /// 在 27pt 級距上約 -0.65pt（27 × 0.024），符合 Mochi typography 規範
        /// 套 detailWord / 22pt h2 級標題；勿套 body 級字（會壓死可讀性）
        static let h2Tight: CGFloat = DesignTokens.Typography.Tracking.h2Tight
        /// 標準字距
        static let normal: CGFloat = DesignTokens.Typography.Tracking.normal
        /// Body / metadata 微放寬
        static let wide: CGFloat = DesignTokens.Typography.Tracking.wide
        /// uppercase metadata 標籤（如「NEW」「BETA」），約 +0.07em on 12pt
        static let uppercase: CGFloat = DesignTokens.Typography.Tracking.uppercase
    }

    // MARK: - Line Spacing Tokens
    // 在 SwiftUI 用 `.lineSpacing(AppFonts.LineSpacing.body)` 套用
    // 數值為 SwiftUI `.lineSpacing(x)`：每行之外額外加 x pt 行距，
    // 真實 leading = font.lineHeight + x，不是固定行高倍率。

    enum LineSpacing {
        /// Display / hero — 0 額外行距，靠字體預設緊湊 leading
        static let display: CGFloat = 0
        /// 標題 — 微寬
        static let heading: CGFloat = 2
        /// 內文 — 舒適閱讀
        static let body: CGFloat = 4
        /// 長文閱讀 — 寬鬆
        static let reading: CGFloat = 6
        /// Caption — 略緊
        static let caption: CGFloat = 1
    }

    // MARK: - UIKit Fonts (for Appearance API)

    #if os(iOS)
    /// UIKit serif font — Crimson Pro + STSongti-TC cascade
    static func uiSerif(size: CGFloat, bold: Bool = false) -> UIFont {
        let primary = bold ? "CrimsonProRoman-Bold" : "CrimsonProRoman-Regular"
        let fallback = bold ? "STSongti-TC-Bold" : "STSongti-TC-Regular"
        let base = UIFontDescriptor(fontAttributes: [.name: primary])
        let cjk = UIFontDescriptor(fontAttributes: [.name: fallback])
        let descriptor = base.addingAttributes([cascadeListKey: [cjk]])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// UIKit sans font — ElmsSans + PingFang TC cascade
    static func uiSans(size: CGFloat, bold: Bool = false) -> UIFont {
        let primary = bold ? "ElmsSans-Bold" : "ElmsSans-Regular"
        let fallback = bold ? "PingFangTC-Semibold" : "PingFangTC-Regular"
        let base = UIFontDescriptor(fontAttributes: [.name: primary])
        let cjk = UIFontDescriptor(fontAttributes: [.name: fallback])
        let descriptor = base.addingAttributes([cascadeListKey: [cjk]])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// 建立 serif 導航列 appearance（opaque + transparent pair）
    static func makeNavBarAppearances() -> (opaque: UINavigationBarAppearance, transparent: UINavigationBarAppearance) {
        let serifLarge = uiSerif(size: 34, bold: true)
        let serifInline = uiSerif(size: 17, bold: true)
        let largeTitleAttrs: [NSAttributedString.Key: Any] = [.font: serifLarge]
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: serifInline]

        let opaque = UINavigationBarAppearance()
        opaque.configureWithDefaultBackground()
        opaque.largeTitleTextAttributes = largeTitleAttrs
        opaque.titleTextAttributes = titleAttrs

        let transparent = UINavigationBarAppearance()
        transparent.configureWithTransparentBackground()
        transparent.largeTitleTextAttributes = largeTitleAttrs
        transparent.titleTextAttributes = titleAttrs

        return (opaque, transparent)
    }

    /// 設定 UINavigationBar + UITabBar 全域字體
    static func configureGlobalAppearance() {
        let (_, transparent) = makeNavBarAppearances()
        UINavigationBar.appearance().standardAppearance = transparent
        UINavigationBar.appearance().compactAppearance = transparent
        UINavigationBar.appearance().scrollEdgeAppearance = transparent
        UINavigationBar.appearance().compactScrollEdgeAppearance = transparent

        let tabFont = uiSans(size: 10)
        let tabItemAppearance = UITabBarItemAppearance()
        tabItemAppearance.normal.titleTextAttributes = [.font: tabFont]
        tabItemAppearance.selected.titleTextAttributes = [.font: tabFont]

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        tabAppearance.stackedLayoutAppearance = tabItemAppearance
        tabAppearance.inlineLayoutAppearance = tabItemAppearance
        tabAppearance.compactInlineLayoutAppearance = tabItemAppearance
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }
    #endif

    // MARK: - On-Demand Font Download

    /// 觸發 STSongti-TC 按需下載（系統字體，首次使用時需下載）
    /// 在 App 啟動時呼叫一次即可，已下載過則立即返回。
    static func ensureSerifCJKAvailable() {
        let fontNames = ["STSongti-TC-Regular", "STSongti-TC-Bold"]
        var descriptors: [PlatformFontDescriptor] = []

        for name in fontNames {
            let desc = PlatformFontDescriptor(fontAttributes: [.name: name])
            // 檢查是否已可用
            let ctDesc = desc as CTFontDescriptor
            if CTFontDescriptorCopyAttribute(ctDesc, kCTFontURLAttribute) != nil {
                continue  // 已存在，跳過
            }
            descriptors.append(desc)
        }

        guard !descriptors.isEmpty else { return }

        let cfArray = descriptors as CFArray
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler(cfArray, nil) { state, _ in
            switch state {
            case .didFinish:
                AppLog.fonts.info("STSongti-TC download completed")
                Task { @MainActor in
                    NotificationCenter.default.post(name: .serifCJKFontDidBecomeAvailable, object: nil)
                }
            case .didFailWithError:
                AppLog.fonts.error("STSongti-TC download failed")
            default:
                break
            }
            return true  // 繼續下載
        }
    }
}

private extension Font.Weight {
    var isBold: Bool {
        switch self {
        case .medium, .semibold, .bold, .heavy, .black:
            return true
        default:
            return false
        }
    }
}
