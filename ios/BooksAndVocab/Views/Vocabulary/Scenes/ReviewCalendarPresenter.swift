//
//  ReviewCalendarPresenter.swift
//  Books & Vocab
//
//  完整日曆詳情頁：月曆 + 選中日期的複習紀錄列表。
//

import SwiftUI
import SwiftData

struct ReviewCalendarClock: Equatable {
    static let historyPlanSource = "history_plan.anchor_day"
    static let liveSource = "live.Date()"
    static let explicitSource = "explicit"

    /// Wall-clock "today": activity (reviewedToday, streaks, heatmap) and the
    /// calendar's today/selection. Manual reviews are stamped with real time.
    let now: Date
    let timeZone: TimeZone
    let provenance: String
    /// Frozen reference for due/forecast projections while progress is paused;
    /// nil means "same as `now`".
    let dueReference: Date?

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    init(
        now: Date,
        timeZone: TimeZone,
        provenance: String = ReviewCalendarClock.explicitSource,
        dueReference: Date? = nil
    ) {
        self.now = now
        self.timeZone = timeZone
        self.provenance = provenance
        self.dueReference = dueReference
    }

    init(
        now: Date,
        calendar: Calendar,
        provenance: String = ReviewCalendarClock.explicitSource
    ) {
        self.init(now: now, timeZone: calendar.timeZone, provenance: provenance)
    }

    func dayKey(for date: Date) -> String {
        LocaleAwareFormatter.shared.machineDayKey(from: date, timeZone: timeZone)
    }

    // StatsProjectionClock compatibility surface. Keep the P9 clock as the
    // canonical provenance-bearing value while allowing P10 projection code
    // to use the shorter method spellings.
    func dayKey(_ date: Date) -> String { dayKey(for: date) }

    func date(byAdding component: Calendar.Component, value: Int, to date: Date) -> Date? {
        calendar.date(byAdding: component, value: value, to: date)
    }

    /// Production composition boundary. All calendar/statistics projections
    /// below consume the returned value; callers that need deterministic UI
    /// state pass an explicit `ReviewCalendarClock` instead.
    static func live(
        settings: ReviewSettings = .default,
        timeZone: TimeZone = .current,
        wallClockNow: Date = Date()
    ) -> Self {
        return Self(
            now: wallClockNow,
            timeZone: timeZone,
            provenance: Self.liveSource,
            dueReference: settings.reviewReferenceDate(now: wallClockNow)
        )
    }

    /// Production composition boundary for UI World and normal app launches.
    /// A loaded UI World must provide the canonical history-plan clock; it is
    /// never silently downgraded to `Date()`. Ordinary launches without a UI
    /// World retain the explicit live production behavior.
    static func uiWorldOrLive(settings: ReviewSettings = .default) -> Self {
        guard let context = FixtureDatasetStore.scenarioContext() else {
            return .live(settings: settings)
        }
        guard let seed = context.reviewClock else {
            preconditionFailure(
                "UI World scenarioContext.reviewClock is required by the stats/review-calendar composition"
            )
        }
        return fromFixture(seed, fixtureID: "production composition")
    }

    static func fromFixture(
        _ seed: FixtureReviewClockSeed,
        fixtureID: String
    ) -> Self {
        guard let now = seed.now,
              let frozenEpoch = seed.frozenEpoch,
              let anchorDay = seed.anchorDay,
              let source = seed.source,
              source == Self.historyPlanSource,
              let timeZoneIdentifier = seed.timeZone,
              let timeZone = TimeZone(identifier: timeZoneIdentifier),
              let parsedNow = parseISO8601(now)
        else {
            preconditionFailure(
                "UI World review clock must declare valid now, frozenEpoch, anchorDay, timeZone, and source=\(Self.historyPlanSource) for \(fixtureID)"
            )
        }

        let epochNow = Date(timeIntervalSince1970: TimeInterval(frozenEpoch))
        guard abs(parsedNow.timeIntervalSince1970 - epochNow.timeIntervalSince1970) < 0.5 else {
            preconditionFailure("UI World review clock now/frozenEpoch drift for \(fixtureID)")
        }

        let clock = Self(now: epochNow, timeZone: timeZone, provenance: source)
        guard clock.dayKey(for: clock.now) == anchorDay else {
            preconditionFailure(
                "UI World review clock anchorDay does not match frozen now in \(timeZoneIdentifier) for \(fixtureID)"
            )
        }
        return clock
    }

    var provenanceSelector: String {
        switch provenance {
        case Self.historyPlanSource:
            return ReviewCalendarAccessibility.clockHistoryPlan
        case Self.liveSource:
            return ReviewCalendarAccessibility.clockLive
        default:
            return ReviewCalendarAccessibility.clockExplicit
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
            ?? {
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: value)
            }()
    }

    var startOfToday: Date {
        calendar.startOfDay(for: now)
    }

    /// Reference for due/forecast projections.
    var dueNow: Date { dueReference ?? now }

    func cutoff(days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: startOfToday) ?? startOfToday
    }

    func cutoff(months: Int) -> Date {
        calendar.date(byAdding: .month, value: -months, to: startOfToday) ?? startOfToday
    }
}

/// Shared clock contract for Stats forecast and Review Calendar projections.
/// Keeping the alias at the composition boundary prevents the two surfaces
/// from acquiring independent date sources.
typealias StatsProjectionClock = ReviewCalendarClock

enum ReviewCalendarAccessibility {
    static let open = "reviewCalendar.open"
    static let monthHeader = "reviewCalendar.monthHeader"
    static let previousMonth = "reviewCalendar.previousMonth"
    static let nextMonth = "reviewCalendar.nextMonth"
    static let selectedDay = "reviewCalendar.selectedDay"
    static let emptyDayDetail = "reviewCalendar.emptyDayDetail"
    static let emptyDaySummary = "reviewCalendar.emptyDaySummary"
    static let populatedDayDetail = "reviewCalendar.populatedDayDetail"
    static let populatedDaySummary = "reviewCalendar.populatedDaySummary"
    static let clockHistoryPlan = "reviewCalendar.clock.history_plan.anchor_day"
    static let clockLive = "reviewCalendar.clock.live"
    static let clockExplicit = "reviewCalendar.clock.explicit"
    static let installedFixture = "reviewCalendar.installedFixture"
    static let runtimeGeometry = "reviewCalendar.runtimeGeometry"

    static func day(_ key: String) -> String {
        "reviewCalendar.day.\(key)"
    }

    /// Monday-first weekday header column, index 0 = Monday.
    static func weekday(_ index: Int) -> String {
        "reviewCalendar.weekday.\(index)"
    }
}

enum ReviewCalendarPresentation {
    enum DayState: Equatable {
        case empty
        case populated(total: Int, remembered: Int, forgot: Int)
    }

    static func filteredRecords(_ records: [ReviewRecord], filter: NotebookFilter) -> [ReviewRecord] {
        filter.isFiltered ? records.filter { filter.matches($0.notebookId) } : records
    }

    static func calendarActivity(
        records: [ReviewRecord],
        clock: ReviewCalendarClock
    ) -> [String: Int] {
        // Month paging is unbounded, so the map must be too (no day window).
        var result: [String: Int] = [:]
        for record in records {
            result[clock.dayKey(record.reviewedAt), default: 0] += 1
        }
        return result
    }

    static func dayKey(for date: Date, clock: ReviewCalendarClock) -> String {
        clock.dayKey(for: date)
    }

    static func records(
        for dayKey: String,
        from records: [ReviewRecord],
        clock: ReviewCalendarClock
    ) -> [ReviewRecord] {
        records
            .filter { clock.dayKey(for: $0.reviewedAt) == dayKey }
            .sorted {
                if $0.reviewedAt != $1.reviewedAt {
                    return $0.reviewedAt > $1.reviewedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    static func records(
        inLastMonths months: Int,
        from records: [ReviewRecord],
        clock: ReviewCalendarClock
    ) -> [ReviewRecord] {
        let cutoff = clock.cutoff(months: months)
        return records.filter { $0.reviewedAt >= cutoff }
    }

    static func activity(
        for days: Int = 365,
        records: [ReviewRecord],
        clock: ReviewCalendarClock
    ) -> [String: Int] {
        ReviewActivityLog.activity(for: days, records: records, clock: clock)
    }

    static func dayState(for records: [ReviewRecord]) -> DayState {
        guard !records.isEmpty else { return .empty }
        let remembered = records.filter { $0.feedback == 1 }.count
        return .populated(
            total: records.count,
            remembered: remembered,
            forgot: records.count - remembered
        )
    }
}

struct ReviewCalendarPresenter: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.dismiss) private var dismiss
    @Environment(\.statsProjectionClock) private var injectedClock

    let filter: NotebookFilter
    private let explicitClock: ReviewCalendarClock?
    @Query var allRecords: [ReviewRecord]

    init(
        filter: NotebookFilter = NotebookFilter(),
        clock: ReviewCalendarClock? = nil
    ) {
        self.filter = filter
        self.explicitClock = clock
        self.installedFixtureProof = FixtureDatasetStore.preparedEvidenceFixtureProofValue()
        _allRecords = Query(
            sort: \ReviewRecord.reviewedAt,
            order: .reverse
        )
        _displayedMonth = State(initialValue: clock?.now ?? .distantPast)
        _selectedDay = State(initialValue: clock.map { $0.dayKey(for: $0.now) })
    }

    @State private var displayedMonth: Date
    @State private var selectedDay: String?
    private let installedFixtureProof: String?

    private var clock: ReviewCalendarClock {
        explicitClock ?? injectedClock
    }

    private static func formattedMonth(_ date: Date, clock: ReviewCalendarClock) -> String {
        // template "yMMMM" → en "May 2026" / ja "2026年5月" / ko "2026년 5월"
        LocaleAwareFormatter.shared.string(from: date, template: "yMMMM", timeZone: clock.timeZone)
    }

    private var activityMap: [String: Int] {
        ReviewCalendarPresentation.calendarActivity(records: filteredRecords, clock: clock)
    }

    private var filteredRecords: [ReviewRecord] {
        ReviewCalendarPresentation.filteredRecords(allRecords, filter: filter)
    }

    private var selectedDayRecords: [ReviewRecord] {
        guard let day = selectedDay else { return [] }
        return ReviewCalendarPresentation.records(for: day, from: filteredRecords, clock: clock)
    }

    private var selectedDaySummary: (total: Int, remembered: Int, forgot: Int) {
        switch ReviewCalendarPresentation.dayState(for: selectedDayRecords) {
        case .empty:
            return (0, 0, 0)
        case let .populated(total, remembered, forgot):
            return (total, remembered, forgot)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: appSkin.spacing.sectionGap) {
                    calendarSection
                    if selectedDay != nil {
                        dayDetailSection
                    }
                    if let installedFixtureProof {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityIdentifier(ReviewCalendarAccessibility.installedFixture)
                            .accessibilityValue(installedFixtureProof)
                    }
                }
                .padding(.horizontal, appSkin.metrics.pageHorizontalInset)
                .padding(.top, appSkin.metrics.pageTopInset)
                .padding(.bottom, appSkin.metrics.pageBottomInset)
            }
            .vocabCanvasBackground()
            .navigationTitle("學習日曆".localized)
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成".localized) { dismiss() }
                        .font(appSkin.typography.caption)
                }
            }
        }
        .enableInjection()
        .task {
            guard displayedMonth == .distantPast else { return }
            displayedMonth = clock.now
            selectedDay = clock.dayKey(for: clock.now)
        }
        .accessibilityIdentifier(clock.provenanceSelector)
    }

    // MARK: - Calendar

    private var calendarSection: some View {
        VStack(spacing: appSkin.spacing.inlineGap) {
            // Month navigation
            HStack {
                Button { changeMonth(by: -1) } label: {
                    Image(systemName: "chevron.left")
                        .font(appSkin.typography.iconMedium)
                        .foregroundStyle(appSkin.palette.secondaryText)
                }
                .accessibilityIdentifier(ReviewCalendarAccessibility.previousMonth)
                .accessibilityLabel(L10n.string("calendar.month.previous"))

                Spacer()

                Text(Self.formattedMonth(displayedMonth, clock: clock))
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.primaryText)
                    .accessibilityIdentifier(ReviewCalendarAccessibility.monthHeader)

                Spacer()

                Button { changeMonth(by: 1) } label: {
                    Image(systemName: "chevron.right")
                        .font(appSkin.typography.iconMedium)
                        .foregroundStyle(canGoForward ? appSkin.palette.secondaryText : appSkin.palette.quaternaryText)
                }
                .disabled(!canGoForward)
                .accessibilityIdentifier(ReviewCalendarAccessibility.nextMonth)
                .accessibilityLabel(L10n.string("calendar.month.next"))
            }
            .padding(.horizontal, appSkin.spacing.rowMicroGap)

            VocabCalendarGrid(
                displayedMonth: displayedMonth,
                activityMap: activityMap,
                selectedDay: $selectedDay,
                clock: clock
            )
        }
        .vocabCardBackground()
        // Keep the card-level geometry receipt without collapsing the month
        // header and day buttons into one accessibility element.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ReviewCalendarAccessibility.runtimeGeometry)
    }

    // MARK: - Day Detail

    private var dayDetailSection: some View {
        Group {
            if case .empty = ReviewCalendarPresentation.dayState(for: selectedDayRecords) {
                ZStack(alignment: .topLeading) {
                    VocabStateMessageCard(
                        title: dayDisplayTitle,
                        systemImage: "calendar.badge.exclamationmark",
                        description: "這天沒有複習紀錄".localized
                    )
                    // The zero count is a semantic state receipt, not a
                    // second visible label. Keep it queryable for UI World
                    // evidence without changing the empty-state composition.
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityIdentifier(ReviewCalendarAccessibility.emptyDaySummary)
                        .accessibilityValue("0")
                }
                // Keep the empty-state receipt on the card container. Without
                // containment, SwiftUI projects the same identifier onto the
                // image and text descendants, making the state non-unique.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(ReviewCalendarAccessibility.emptyDayDetail)
            } else {
                populatedDayDetailSection
            }
        }
        .animateContentFade(selectedDay)
    }

    private var populatedDayDetailSection: some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.inlineGap) {
            VStack(alignment: .leading, spacing: AppSpacing.microGap) {
                Text(dayDisplayTitle)
                    .font(appSkin.typography.caption)
                    .foregroundStyle(appSkin.palette.primaryText)

                if case .empty = ReviewCalendarPresentation.dayState(for: selectedDayRecords) {
                    Text("這天沒有複習紀錄".localized)
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.quaternaryText)
                        .accessibilityIdentifier(ReviewCalendarAccessibility.emptyDaySummary)
                        .accessibilityValue("0")
                } else {
                    let s = selectedDaySummary
                    Text(L10n.format("已複習 %@ 張 ・ 記得 %@ ・ 忘記 %@", "\(s.total)", "\(s.remembered)", "\(s.forgot)"))
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.tertiaryText)
                        .accessibilityIdentifier(ReviewCalendarAccessibility.populatedDaySummary)
                        .accessibilityValue("\(s.total)")
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(selectedDayRecords.enumerated()), id: \.element.id) { index, record in
                    if index > 0 {
                        Divider()
                            .foregroundStyle(appSkin.palette.divider)
                            .padding(.leading, AppSpacing.s7 - AppSpacing.s1)
                    }
                    recordRow(record)
                }
            }
        }
        .vocabCardBackground()
        // The state receipt belongs to the detail card; its summary and rows
        // remain independently addressable for UI World evidence.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ReviewCalendarAccessibility.populatedDayDetail)
    }

    private func recordRow(_ record: ReviewRecord) -> some View {
        HStack(spacing: appSkin.spacing.inlineGap) {
            Image(systemName: record.feedback == 1 ? "checkmark" : "xmark")
                .font(appSkin.typography.iconSmall)
                .foregroundStyle(record.feedback == 1 ? appSkin.palette.success : appSkin.palette.destructive)
                .frame(width: 20)

            Text(record.word)
                .font(appSkin.typography.monoBody)
                .foregroundStyle(appSkin.palette.primaryText)
                .lineLimit(1)

            Spacer()

            Text(record.feedback == 1 ? "記得".localized : "忘記".localized)
                .font(appSkin.typography.monoLabel)
                .foregroundStyle(record.feedback == 1 ? appSkin.palette.success : appSkin.palette.destructive)

            Text(LocaleAwareFormatter.shared.string(
                from: record.reviewedAt,
                format: "HH:mm",
                timeZone: clock.timeZone
            ))
                .font(appSkin.typography.monoLabel)
                .foregroundStyle(appSkin.palette.quaternaryText)
        }
        .padding(.vertical, appSkin.spacing.rowMicroGap)
    }

    // MARK: - Helpers

    private var dayDisplayTitle: String {
        guard let day = selectedDay else { return "" }
        let todayKey = clock.dayKey(for: clock.now)
        if day == todayKey { return day + "（今天）".localized }
        return day
    }

    private var canGoForward: Bool {
        let cal = clock.calendar
        let nextMonth = cal.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
        let nowComps = cal.dateComponents([.year, .month], from: clock.now)
        let nextComps = cal.dateComponents([.year, .month], from: nextMonth)
        guard let nextYear = nextComps.year, let nextMonth = nextComps.month,
              let nowYear = nowComps.year, let nowMonth = nowComps.month else { return false }
        return (nextYear, nextMonth) <= (nowYear, nowMonth)
    }

    private func changeMonth(by offset: Int) {
        withAnimation(AppMotion.phaseChange) {
            displayedMonth = clock.calendar.date(
                byAdding: .month, value: offset, to: displayedMonth
            ) ?? displayedMonth
            selectedDay = nil
        }
    }
}
