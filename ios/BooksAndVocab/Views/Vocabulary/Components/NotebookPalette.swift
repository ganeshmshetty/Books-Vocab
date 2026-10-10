import SwiftUI

extension Color {
    init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let int = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }
}

/// Morandi "Clearly Brighter" 12 色卡 — 與 cream paper ghost stack 同視覺族群。
/// HSB sat 13-30% / bright 67-86%，避免高飽和封面與 cream 內頁撕裂感。
///
/// 老 notebook 的 hex 仍存舊高飽和色；`color(for:)` 套 `legacyMigration`
/// render-time 轉換，零感知遷移、不寫 DB。
enum NotebookPalette {
    static let colors: [(name: String, hex: String)] = [
        ("森林", "#B1C5AE"), ("海洋", "#AFC2D3"), // token-allow: notebook palette data colors
        ("琥珀", "#DEC69C"), ("紫藤", "#C5B2D0"), // token-allow: notebook palette data colors
        ("珊瑚", "#DCABA4"), ("石墨", "#AFB2B7"), // token-allow: notebook palette data colors
        ("薄荷", "#B7D2C9"), ("靛藍", "#ADABCB"), // token-allow: notebook palette data colors
        ("玫瑰", "#DEBAC2"), ("焦糖", "#D2B69D"), // token-allow: notebook palette data colors
        ("天空", "#C5DAE2"), ("薰衣草", "#C3BCCF"), // token-allow: notebook palette data colors
    ]

    /// VoiceOver label for a swatch: `name` is a stable zh-Hant key resolved through L10n.
    static func localizedName(_ name: String) -> String { L10n.string(name) }
    static func localizedName(_ name: String, language: AppLanguage) -> String {
        L10n.string(name, language: language)
    }

    static let defaultHex = "#AFC2D3"  // token-allow: notebook palette default data color

    /// 老資料 hex → 新 Morandi hex 對照表。
    /// Render-time 套用，不寫 DB（user 下次 edit cover 時 UI 自然寫新 hex）。
    private static let legacyMigration: [String: String] = [
        "#5B8C5A": "#B1C5AE",  // token-allow: legacy notebook data color migration
        "#4A90D9": "#AFC2D3",  // token-allow: legacy notebook data color migration
        "#D4A843": "#DEC69C",  // token-allow: legacy notebook data color migration
        "#A855C7": "#C5B2D0",  // token-allow: legacy notebook data color migration
        "#D9534F": "#DCABA4",  // token-allow: legacy notebook data color migration
        "#6B7280": "#AFB2B7",  // token-allow: legacy notebook data color migration
        "#5CC6B0": "#B7D2C9",  // token-allow: legacy notebook data color migration
        "#4F46E5": "#ADABCB",  // token-allow: legacy notebook data color migration
        "#E8789A": "#DEBAC2",  // token-allow: legacy notebook data color migration
        "#B8763E": "#D2B69D",  // token-allow: legacy notebook data color migration
        "#7CB9E8": "#C5DAE2",  // token-allow: legacy notebook data color migration
        "#9B8EC4": "#C3BCCF",  // token-allow: legacy notebook data color migration
    ]

    static func color(for hex: String?) -> Color {
        guard let raw = hex else {
            return Color(hex: defaultHex) ?? .blue // token-allow: notebook palette data color
        }
        let mapped = legacyMigration[raw.uppercased()] ?? raw
        return Color(hex: mapped) ?? Color(hex: defaultHex) ?? .blue // token-allow: notebook palette data color
    }

    /// HSB brightness ×(1 - amount),hue / saturation 保持。
    /// 用於 cover hairline rule、active spine 等需要「同色族加深」的場景。
    /// amount 範圍 [0, 1];例:`darken(c, by: 0.3)` → brightness ×0.7。
    static func darken(_ color: Color, by amount: Double) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        NSColor(color).usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #endif
        return Color(
            hue: Double(h),
            saturation: Double(s),
            brightness: Double(b) * (1 - amount),
            opacity: Double(a)
        )
    }
}
