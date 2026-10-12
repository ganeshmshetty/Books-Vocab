//
//  LocaleAwareFormatter.swift
//  Books & Vocab
//
//  AppLanguage-aware date / relative / number formatter cache.
//
//  Thread-safety model: DateFormatter / RelativeDateTimeFormatter are NOT
//  thread-safe per Apple docs. This type's public API does ALL formatting
//  inside an `OSAllocatedUnfairLock`, so callers never touch the underlying
//  Foundation instances. The cache stores fully-configured formatters keyed
//  by (locale, format/template/style); cache is invalidated when
//  AppLanguageStore.selection changes.
//
//  Why not @MainActor: background actors (BackgroundSyncActor, audio engine)
//  format date/number for user-visible payload. Lock-backed @unchecked Sendable
//  storage avoids actor-isolation friction.
//

import Foundation
import Combine
import os

final class LocaleAwareFormatter: @unchecked Sendable {
    static let shared = LocaleAwareFormatter()

    private struct Storage {
        var dateFormatters: [String: DateFormatter] = [:]
        /// Locale-neutral `yyyy-MM-dd` formatters keyed by time-zone identifier (hot path: no key building).
        var machineFormatters: [String: DateFormatter] = [:]
        var templateFormatters: [String: DateFormatter] = [:]
        var styleFormatters: [String: DateFormatter] = [:]
        var relativeFormatters: [RelativeDateTimeFormatter.UnitsStyle: RelativeDateTimeFormatter] = [:]
        var numberFormatters: [NumberFormatter.Style: NumberFormatter] = [:]
        var weekdaySymbols: [String: [String]] = [:]
    }

    private let lock = OSAllocatedUnfairLock<Storage>(initialState: Storage())
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = AppLanguageStore.shared.$selection
            .dropFirst()
            .sink { [weak self] _ in self?.invalidate() }
    }

    private func invalidate() {
        lock.withLock { $0 = Storage() }
    }

    // MARK: - String-returning API (thread-safe)

    /// Format a date using a fixed `dateFormat` pattern (`"yyyy-MM-dd"` etc.).
    /// Use for machine-style patterns where you want the exact format string.
    func string(from date: Date, format: String) -> String {
        string(from: date, format: format, timeZone: .current)
    }

    /// Format a date using a fixed pattern and an explicit timezone.
    func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        let locale = AppLanguageStore.shared.formatLocale
        let cacheKey = "\(locale.identifier)|\(format)|\(timeZone.identifier)"
        return lock.withLock { storage in
            let formatter: DateFormatter
            if let cached = storage.dateFormatters[cacheKey] {
                formatter = cached
            } else {
                let f = DateFormatter()
                f.dateFormat = format
                f.locale = locale
                f.timeZone = timeZone
                storage.dateFormatters[cacheKey] = f
                formatter = f
            }
            return formatter.string(from: date)
        }
    }

    /// Format a date using a locale-aware template (e.g. `"Md"`, `"yMMMM"`).
    /// ICU produces native ordering per locale: en `"May 22"`, ja `"5月22日"`,
    /// ko `"5월 22일"`. The template is applied via
    /// `setLocalizedDateFormatFromTemplate` ONCE at cache fill time.
    func string(from date: Date, template: String) -> String {
        string(from: date, template: template, timeZone: .current)
    }

    /// Format a localized date template with an explicit timezone.
    func string(from date: Date, template: String, timeZone: TimeZone) -> String {
        let locale = AppLanguageStore.shared.formatLocale
        let cacheKey = "TPL|\(locale.identifier)|\(template)|\(timeZone.identifier)"
        return lock.withLock { storage in
            let formatter: DateFormatter
            if let cached = storage.templateFormatters[cacheKey] {
                formatter = cached
            } else {
                let f = DateFormatter()
                f.locale = locale
                f.timeZone = timeZone
                f.setLocalizedDateFormatFromTemplate(template)
                storage.templateFormatters[cacheKey] = f
                formatter = f
            }
            return formatter.string(from: date)
        }
    }

    /// Locale-neutral day key for projections that explicitly inject a timezone.
    func machineDayKey(from date: Date, timeZone: TimeZone) -> String {
        let cacheKey = timeZone.identifier
        return lock.withLock { storage in
            let formatter: DateFormatter
            if let cached = storage.machineFormatters[cacheKey] {
                formatter = cached
            } else {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = timeZone
                storage.machineFormatters[cacheKey] = f
                formatter = f
            }
            return formatter.string(from: date)
        }
    }

    /// Format a date using style-based DateFormatter (medium/short etc.).
    func string(from date: Date, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> String {
        let locale = AppLanguageStore.shared.formatLocale
        let cacheKey = "STYLE|\(locale.identifier)|\(dateStyle.rawValue)|\(timeStyle.rawValue)"
        return lock.withLock { storage in
            let formatter: DateFormatter
            if let cached = storage.styleFormatters[cacheKey] {
                formatter = cached
            } else {
                let f = DateFormatter()
                f.dateStyle = dateStyle
                f.timeStyle = timeStyle
                f.locale = locale
                f.timeZone = .current
                storage.styleFormatters[cacheKey] = f
                formatter = f
            }
            return formatter.string(from: date)
        }
    }

    /// Relative description ("in 3 days" / "3 日前" / "3일 전"), thread-safe.
    func relativeString(for date: Date, relativeTo reference: Date = Date(),
                        style: RelativeDateTimeFormatter.UnitsStyle = .full) -> String {
        let locale = AppLanguageStore.shared.formatLocale
        return lock.withLock { storage in
            let formatter: RelativeDateTimeFormatter
            if let cached = storage.relativeFormatters[style], cached.locale == locale {
                formatter = cached
            } else {
                let f = RelativeDateTimeFormatter()
                f.locale = locale
                f.unitsStyle = style
                storage.relativeFormatters[style] = f
                formatter = f
            }
            return formatter.localizedString(for: date, relativeTo: reference)
        }
    }

    /// Format a number, thread-safe.
    func string(from number: NSNumber, style: NumberFormatter.Style = .decimal) -> String {
        let locale = AppLanguageStore.shared.formatLocale
        return lock.withLock { storage in
            let formatter: NumberFormatter
            if let cached = storage.numberFormatters[style], cached.locale == locale {
                formatter = cached
            } else {
                let f = NumberFormatter()
                f.numberStyle = style
                f.locale = locale
                storage.numberFormatters[style] = f
                formatter = f
            }
            return formatter.string(from: number) ?? ""
        }
    }

    // MARK: - Weekday symbols (locale-aware, Monday-first)

    /// Locale-aware weekday symbols rotated to Monday-first order
    /// (`[Mon, Tue, Wed, Thu, Fri, Sat, Sun]`), following AppLanguage.
    ///
    /// Apple's `veryShortWeekdaySymbols` / `shortWeekdaySymbols` are always
    /// Sunday-indexed (index 0 = Sunday) regardless of calendar `firstWeekday`,
    /// so we rotate by moving Sunday (index 0) to the tail. Callers render a
    /// fixed Monday-start grid, so we rotate deterministically rather than by
    /// locale `firstWeekday`.
    ///
    /// - Parameter short: `true` → single-glyph `veryShortWeekdaySymbols`
    ///   (zh `一`, en `M`); `false` → `shortWeekdaySymbols` (en `Mon`).
    func mondayFirstWeekdaySymbols(short: Bool = true) -> [String] {
        let locale = AppLanguageStore.shared.formatLocale
        let cacheKey = "WD|\(short ? "vs" : "s")|\(locale.identifier)"
        return lock.withLock { storage in
            if let cached = storage.weekdaySymbols[cacheKey] { return cached }
            let f = DateFormatter()
            f.locale = locale
            let sundayFirst = (short ? f.veryShortWeekdaySymbols : f.shortWeekdaySymbols) ?? []
            // Rotate Sunday (index 0) to the end → Monday-first.
            let mondayFirst = sundayFirst.count == 7
                ? Array(sundayFirst[1...]) + [sundayFirst[0]]
                : sundayFirst
            storage.weekdaySymbols[cacheKey] = mondayFirst
            return mondayFirst
        }
    }

    // MARK: - Date.FormatStyle (modern value-type API — safe by construction)

    /// `Date.FormatStyle` is a value type — return a locale-bound copy of the input.
    /// No locking needed; the value is copied per call.
    func dateStyle(_ base: Date.FormatStyle) -> Date.FormatStyle {
        base.locale(AppLanguageStore.shared.formatLocale)
    }
}
