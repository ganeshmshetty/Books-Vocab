//
//  VocabCalendarGrid.swift
//  Books & Vocab
//
//  月曆格子元件，顯示每日複習活動色階。
//

import SwiftUI

struct VocabCalendarGrid: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.statsProjectionClock) private var projectionClock

    let displayedMonth: Date
    let activityMap: [String: Int]
    @Binding var selectedDay: String?
    private let explicitProjectionClock: StatsProjectionClock?

    init(
        displayedMonth: Date,
        activityMap: [String: Int],
        selectedDay: Binding<String?>,
        clock: StatsProjectionClock? = nil
    ) {
        self.displayedMonth = displayedMonth
        self.activityMap = activityMap
        self._selectedDay = selectedDay
        self.explicitProjectionClock = clock
    }

    // Locale-aware, Monday-first (matches the Monday-start day grid below).
    private let weekdaySymbols = LocaleAwareFormatter.shared.mondayFirstWeekdaySymbols(short: true)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: AppSpacing.s1), count: 7)
    private var activeProjectionClock: StatsProjectionClock {
        explicitProjectionClock ?? projectionClock
    }

    private var todayKey: String { activeProjectionClock.dayKey(activeProjectionClock.now) }

    private var monthDays: [DayCell] {
        let cal = activeProjectionClock.calendar
        let comps = cal.dateComponents([.year, .month], from: displayedMonth)
        guard let firstOfMonth = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth) else { return [] }

        // Monday=1 ... Sunday=7 → offset
        let firstWeekday = cal.component(.weekday, from: firstOfMonth)
        // Convert to Monday-based: Mon=0, Tue=1, ..., Sun=6
        let mondayOffset = (firstWeekday + 5) % 7

        var cells: [DayCell] = []

        // Leading blanks
        for i in 0..<mondayOffset {
            cells.append(DayCell(id: "blank-\(i)", dayNumber: 0, dayKey: nil, isToday: false, isFuture: false))
        }

        for day in range {
            var dayComps = comps
            dayComps.day = day
            guard let date = cal.date(from: dayComps) else { continue }
            let key = activeProjectionClock.dayKey(date)
            cells.append(DayCell(
                id: key,
                dayNumber: day,
                dayKey: key,
                isToday: key == todayKey,
                isFuture: cal.startOfDay(for: date) > cal.startOfDay(for: activeProjectionClock.now)
            ))
        }
        return cells
    }

    var body: some View {
        VStack(spacing: appSkin.spacing.rowMicroGap) {
            // Weekday header
            LazyVGrid(columns: columns, spacing: AppSpacing.s1) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(appSkin.typography.monoLabel)
                        .foregroundStyle(appSkin.palette.quaternaryText)
                        .frame(maxWidth: .infinity)
                }
            }

            // Day grid
            LazyVGrid(columns: columns, spacing: AppSpacing.s1) {
                ForEach(monthDays) { cell in
                    if cell.dayNumber == 0 {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                    } else {
                        dayView(cell)
                    }
                }
            }
        }
        .enableInjection()
    }

    private func dayView(_ cell: DayCell) -> some View {
        let count = cell.dayKey.flatMap { activityMap[$0] } ?? 0
        let isSelected = cell.dayKey == selectedDay

        return Button {
            withAnimation(AppMotion.chipSelect) {
                selectedDay = cell.dayKey
            }
        } label: {
            // 方形尺寸由 Color.clear 底板決定（先 maxWidth 再 aspectRatio），內容以 overlay 疊上、
            // 不參與尺寸協商；否則 content-height 的 VStack 會讓各列高度漂移（#2861）。
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: 1) {
                        Text("\(cell.dayNumber)")
                            .font(appSkin.typography.caption)
                            .foregroundStyle(
                                cell.isToday ? AppColors.chartHighlight :
                                isSelected ? appSkin.palette.primaryText :
                                appSkin.palette.secondaryText
                            )

                        // Activity dot
                        Circle()
                            .fill(count > 0 ? dotColor(count) : Color.clear)
                            .frame(width: 5, height: 5)
                    }
                }
            // 日格是 aspectRatio(1) 的方形按鈕，7 欄下短邊 ≈47pt。
            // control 給 r≈7（改制前 6），是四階裡唯一貼合的；pill 會把日格變成圓形。
            .background(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .fill(isSelected ? appSkin.palette.mutedFill : (count > 0 ? cellFill(count) : Color.clear))
            )
            .overlay(
                AppRoundedRect(roundness: appSkin.roundness.control)
                    .stroke(appSkin.palette.cardBorder.opacity(0.5), lineWidth: 0.5)
            )
            // Unselected zero-activity cells paint only Color.clear fills, so
            // .plain hit-testing would fall through everywhere but the digits.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(cell.isFuture)
        .opacity(cell.isFuture ? 0.45 : 1)
        .accessibilityIdentifier(
            isSelected
                ? ReviewCalendarAccessibility.selectedDay
                : cell.dayKey.map { ReviewCalendarAccessibility.day($0) } ?? "calendar.day.blank"
        )
        .accessibilityValue(LocaleAwareFormatter.shared.string(from: NSNumber(value: count)))
    }

    private func dotColor(_ count: Int) -> Color {
        switch count {
        case 1...3: return AppColors.chartHighlight.opacity(0.5)
        case 4...7: return AppColors.chartHighlight.opacity(0.75)
        default: return AppColors.chartHighlight
        }
    }

    private func cellFill(_ count: Int) -> Color {
        // 提高低活動 cell 的 opacity（0.06 對米色卡片背景對比過低，
        // 導致連續低活動日視覺融合成 pill；intensity 由底部 dot 區分）
        switch count {
        case 1...3: return AppColors.chartHighlight.opacity(0.12)
        case 4...7: return AppColors.chartHighlight.opacity(0.16)
        case 8...14: return AppColors.chartHighlight.opacity(0.20)
        default: return AppColors.chartHighlight.opacity(0.26)
        }
    }
}

private struct DayCell: Identifiable {
    let id: String
    let dayNumber: Int
    let dayKey: String?
    let isToday: Bool
    let isFuture: Bool
}

private func makeVocabCalendarGridPreviewData(clock: StatsProjectionClock) -> [String: Int] {
    let month = clock.now
    var activity: [String: Int] = [:]
    if let firstOfMonth = clock.calendar.date(
        from: clock.calendar.dateComponents([.year, .month], from: month)
    ), let range = clock.calendar.range(of: .day, in: .month, for: firstOfMonth) {
        for day in range where day % 3 != 0 {
            var components = clock.calendar.dateComponents([.year, .month], from: month)
            components.day = day
            if let date = clock.calendar.date(from: components) {
                activity[clock.dayKey(date)] = (day % 11) + 1
            }
        }
    }
    return activity
}

private struct VocabCalendarGridPreview: View {
    @State private var selectedDay: String?
    private let clock: StatsProjectionClock
    private let activity: [String: Int]

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let clock = StatsProjectionClock(now: Date(timeIntervalSince1970: 1_780_300_800), calendar: calendar)
        self.clock = clock
        self.activity = makeVocabCalendarGridPreviewData(clock: clock)
    }

    var body: some View {
        AppThemeContainer {
            VocabCalendarGrid(
                displayedMonth: clock.now,
                activityMap: activity,
                selectedDay: $selectedDay
            )
            .padding()
        }
        .environmentObject(AppAppearanceStore.preview)
        .environment(\.statsProjectionClock, clock)
    }
}

#Preview("VocabCalendarGrid") {
    VocabCalendarGridPreview()
}
