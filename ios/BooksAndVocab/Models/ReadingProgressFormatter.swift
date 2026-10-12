import Foundation

/// 閱讀進度的唯一顯示格式：整數百分比、四捨五入、依 locale 排版。
/// 閱讀器（底部進度列）與書架（BookCard）都走這裡，避免同一本書兩處數字不一致。
enum ReadingProgressFormatter {
    static func percentText(_ progression: Double, locale: Locale = .current) -> String {
        let clamped = min(max(progression, 0), 1)
        return clamped.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}
