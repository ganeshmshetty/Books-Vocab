#if DEBUG && canImport(Playbook)
import Playbook
import SwiftUI

/// Catalog scenarios for `VocabCalendarGrid`.
///
/// The grid is a pure presentational component: it takes a displayed month,
/// a `[dayKey: activityCount]` map, and a selected-day binding. All fixtures
/// here are synthetic so Catalog / Snapshot stay deterministic regardless of
/// the real review history. Day keys and "today" are produced from the same
/// injected UTC projection clock as the component, so future-cell handling
/// cannot fall back to the epoch environment default.
enum VocabCalendarGridScenarios {
    static let projectionClock: StatsProjectionClock = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 1,
            hour: 12
        )
        guard let now = calendar.date(from: components) else {
            preconditionFailure("VocabCalendarGridScenarios requires a valid fixed UTC anchor")
        }
        return StatsProjectionClock(now: now, calendar: calendar)
    }()

    static func register(in playbook: Playbook) {
        playbook.addScenarios(of: "Vocab Calendar") {
            // 一個月份的密集活動：覆蓋全部 intensity 階梯（dot + cellFill），
            // 證明色階分層與 Monday-first 排版。
            Scenario("Active month", layout: .fillH) {
                VocabCalendarGridScene(fixture: .activeMonth)
            }
            // 選中某一天：驗證 selected cell 的 mutedFill 背景與 primaryText。
            Scenario("Day selected", layout: .fillH) {
                VocabCalendarGridScene(fixture: .daySelected)
            }
            // 高強度壓力：所有天都是 15+ 活動，逼出最深的 cellFill / dot。
            Scenario("Heavy intensity", layout: .fillH) {
                VocabCalendarGridScene(fixture: .heavyIntensity)
            }
            // 空月份：沒有任何活動，只有日期數字與格線（empty state）。
            Scenario("No activity", layout: .fillH) {
                VocabCalendarGridScene(fixture: .noActivity)
            }
            // 含 today 的當月：驗證 today cell 的 chartHighlight 文字色。
            Scenario("Current month with today", layout: .fillH) {
                VocabCalendarGridScene(fixture: .currentMonth)
            }
            // 前導空白 3 的 2026-10（#2861 原始範圍）：3/8/9 有活動，驗證 row-1 空白格之後的日格仍落在正確欄位。
            // 注意：固定 projection clock 為 2026-06-01，10 月整月在未來，日格會 disabled 並 opacity 0.45，
            // 此場景只用於幾何結構檢視，不代表一般日格外觀；六種 offset 的對齊由 UITest 逐月走訪驗證。
            Scenario("Leading blanks (2026-10)", layout: .fillH) {
                VocabCalendarGridScene(fixture: .monthWithActivityDays(year: 2026, month: 10, days: [3, 8, 9]))
            }
        }
    }
}

private struct VocabCalendarGridScene: View {
    enum Fixture {
        case activeMonth
        case daySelected
        case heavyIntensity
        case noActivity
        case currentMonth
        case monthWithActivityDays(year: Int, month: Int, days: [Int])
    }

    let fixture: Fixture

    @State private var selectedDay: String?

    private static var projectionClock: StatsProjectionClock { VocabCalendarGridScenarios.projectionClock }
    private static var calendar: Calendar { projectionClock.calendar }

    var body: some View {
        let config = makeConfig()
        return AppThemeContainer {
            VocabCalendarGrid(
                displayedMonth: config.month,
                activityMap: config.activity,
                selectedDay: $selectedDay
            )
            .padding()
        }
        .environmentObject(AppAppearanceStore.preview)
        .environment(\.statsProjectionClock, Self.projectionClock)
        .onAppear { selectedDay = config.initialSelection }
    }

    private struct Config {
        let month: Date
        let activity: [String: Int]
        let initialSelection: String?
    }

    private func makeConfig() -> Config {
        switch fixture {
        case .activeMonth:
            let month = Self.fixedMonth()
            return Config(month: month, activity: Self.gradientActivity(in: month), initialSelection: nil)
        case .daySelected:
            let month = Self.fixedMonth()
            let activity = Self.gradientActivity(in: month)
            return Config(month: month, activity: activity, initialSelection: Self.dayKey(in: month, day: 15))
        case .heavyIntensity:
            let month = Self.fixedMonth()
            return Config(month: month, activity: Self.constantActivity(in: month, count: 20), initialSelection: nil)
        case .noActivity:
            let month = Self.fixedMonth()
            return Config(month: month, activity: [:], initialSelection: nil)
        case .currentMonth:
            let month = Self.projectionClock.now
            return Config(month: month, activity: Self.gradientActivity(in: month), initialSelection: nil)
        case let .monthWithActivityDays(year, month, days):
            let displayed = Self.month(year: year, month: month)
            var activity: [String: Int] = [:]
            for day in days {
                if let key = Self.dayKey(in: displayed, day: day) { activity[key] = 3 }
            }
            return Config(month: displayed, activity: activity, initialSelection: nil)
        }
    }

    /// Deterministic month (2024-03) so snapshots are stable across runs.
    private static func fixedMonth() -> Date {
        var comps = DateComponents(calendar: calendar, timeZone: calendar.timeZone)
        comps.year = 2024
        comps.month = 3
        comps.day = 1
        guard let month = calendar.date(from: comps) else {
            preconditionFailure("VocabCalendarGridScenarios requires a valid fixed month")
        }
        return month
    }

    /// Parameterized variant of `fixedMonth()` for the leading-blank scenarios.
    private static func month(year: Int, month: Int) -> Date {
        var comps = DateComponents(calendar: calendar, timeZone: calendar.timeZone)
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let date = calendar.date(from: comps) else {
            preconditionFailure("VocabCalendarGridScenarios requires a valid fixed month")
        }
        return date
    }

    private static func dayKey(in month: Date, day: Int) -> String? {
        var comps = calendar.dateComponents([.year, .month], from: month)
        comps.day = day
        return calendar.date(from: comps).map { projectionClock.dayKey($0) }
    }

    /// Spreads counts across every intensity band (1-3, 4-7, 8-14, 15+),
    /// skipping every fourth day so empty cells are also represented.
    private static func gradientActivity(in month: Date) -> [String: Int] {
        var map: [String: Int] = [:]
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return map }
        for day in range where day % 4 != 0 {
            if let key = dayKey(in: month, day: day) {
                map[key] = ((day * 2) % 18) + 1
            }
        }
        return map
    }

    private static func constantActivity(in month: Date, count: Int) -> [String: Int] {
        var map: [String: Int] = [:]
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return map }
        for day in range {
            if let key = dayKey(in: month, day: day) {
                map[key] = count
            }
        }
        return map
    }
}

#endif
