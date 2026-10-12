#if os(iOS)
import Foundation
import SwiftUI
import Testing
@testable import BooksAndVocab

/// Pins `StatsPresentation.buildSummary` — the pure-function seam behind the
/// `StatsPresenter` SwiftUI scene. The view itself is `@Query`-driven and
/// `@Environment`-coupled, so it cannot be exercised outside the SwiftUI
/// runtime; `buildSummary` is where every displayed number is computed, so
/// that is the contract this suite locks down.
///
/// Coverage:
///  - card totals: synced filter, delete exclusion, pending exclusion
///  - forecast: bucketing, overdue-collapses-to-today, dueToday, day count
///  - streaks / reviewedToday / activity wiring (via ReviewActivityLog)
///  - adaptive heatmap thresholds (< 4 non-zero days → fallback, else p25/50/75)
///  - the `isSummaryEmpty` invariant that drives the scene's `.empty` phase
///  - boundary inputs: empty data, single record
///
/// All dates are built relative to the review clock decoded from the committed
/// generated UI World. The projection must never silently switch to the host
/// wall clock or a hand-written epoch.
private enum StatsPresenterFixtureData {
    static var marketingDemoData: Data {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // BooksAndVocabTests
                .deletingLastPathComponent() // ios
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("ops/fixtures/ui_worlds/marketing_demo.json")
            return try Data(contentsOf: url)
        }
    }
}
struct StatsPresenterTests {

    // MARK: - Helpers

    fileprivate static let canonicalClock: ReviewCalendarClock = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BooksAndVocabTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("ops/demo/generated/ios_fixture_dataset.json")
        let data = try! Data(contentsOf: url)
        let document = try! FixtureDatasetStore.decode(data)
        let seed = document.scenarioContext!.reviewClock!
        return ReviewCalendarClock.fromFixture(seed, fixtureID: "StatsPresenterTests")
    }()

    private static let calendar = canonicalClock.calendar

    /// A date `offset` days from now (negative = past), normalized to noon so
    /// `+12h` / `-12h` jitter inside `buildSummary` never crosses a day key.
    private func day(_ offset: Int) -> Date {
        let base = Self.calendar.date(
            byAdding: .day,
            value: offset,
            to: Self.canonicalClock.now
        ) ?? Self.canonicalClock.now
        return Self.calendar.date(
            bySettingHour: 12, minute: 0, second: 0, of: base
        ) ?? base
    }

    private func dayKey(_ offset: Int) -> String {
        Self.canonicalClock.dayKey(for: day(offset))
    }

    /// A synced vocabulary entry whose `nextReviewAt` lands on `dueOffset`
    /// days from today. New `VocabularyEntry` rows default to `syncStatus=0`
    /// (pending), so `buildSummary`'s synced filter would drop them — this
    /// helper flips `syncStatus` to 1 explicitly.
    private func syncedEntry(dueOffset: Int) -> VocabularyEntry {
        let e = VocabularyEntry(
            word: "w\(dueOffset)",
            translation: "t",
            context: "c",
            bookTitle: "B"
        )
        e.syncStatus = 1
        e.reviewCount = 1
        e.nextReviewAt = day(dueOffset)
        return e
    }

    @Test func forecast_ignoresNewAndReviewExcludedCards() {
        let due = syncedEntry(dueOffset: 0)
        let fresh = syncedEntry(dueOffset: 0)
        fresh.reviewCount = 0
        let excluded = syncedEntry(dueOffset: 0)
        excluded.isReviewExcluded = true

        let s = StatsPresentation.buildSummary(
            from: [due, fresh, excluded], reviewRecords: [], clock: Self.canonicalClock
        )

        #expect(s.totalCards == 3)
        #expect(s.dueToday == 1)
        #expect(s.forecast.map(\.count).reduce(0, +) == 1)
    }

    /// Pins the edge-day bucket the Overview UI oracle mirrors (#2920): at the
    /// last forecast day only reviewed, non-excluded cards count; new cards
    /// (reviewCount == 0) and excluded cards landing on the same day do not.
    @Test func forecast_edgeDayBucketCountsOnlyReviewedCards() {
        let reviewed = syncedEntry(dueOffset: 13)
        let fresh = syncedEntry(dueOffset: 13)
        fresh.reviewCount = 0
        let excluded = syncedEntry(dueOffset: 13)
        excluded.isReviewExcluded = true

        let s = StatsPresentation.buildSummary(
            from: [reviewed, fresh, excluded], reviewRecords: [], clock: Self.canonicalClock
        )

        let edge = s.forecast.first { $0.id == dayKey(13) }
        #expect(edge?.count == 1)
        #expect(s.dueToday == 0)
    }

    private func review(dayOffset: Int) -> ReviewRecord {
        ReviewRecord(word: "x", entryID: nil, feedback: 1, reviewedAt: day(dayOffset))
    }

    // MARK: - Empty / boundary inputs

    @Test func emptyInput_producesAllZeroSummary() {
        let summary = StatsPresentation.buildSummary(from: [], reviewRecords: [], clock: Self.canonicalClock)

        #expect(summary.totalCards == 0)
        #expect(summary.reviewedToday == 0)
        #expect(summary.dueToday == 0)
        #expect(summary.currentStreak == 0)
        #expect(summary.longestStreak == 0)
        #expect(summary.activity.isEmpty)
    }

    /// Mirrors `StatsPresenter.isSummaryEmpty` — an all-zero summary is what
    /// drives the scene into its `.empty` phase. If `buildSummary` ever stopped
    /// producing this shape for empty input, the empty state would never show.
    @Test func emptyInput_satisfiesSceneEmptyInvariant() {
        let s = StatsPresentation.buildSummary(from: [], reviewRecords: [], clock: Self.canonicalClock)
        let isEmpty = s.totalCards == 0
            && s.activity.values.allSatisfy { $0 == 0 }
            && s.currentStreak == 0
            && s.longestStreak == 0
        #expect(isEmpty, "empty data must satisfy the scene's `.empty` phase predicate")
    }

    @Test func emptyInput_forecastStillHasDefaultDayCount() {
        let summary = StatsPresentation.buildSummary(from: [], reviewRecords: [], clock: Self.canonicalClock)
        // forecastDays defaults to 14 — the forecast array is always fully
        // populated even with no data, so the chart never collapses.
        #expect(summary.forecast.count == 14)
        #expect(summary.forecast.allSatisfy { $0.count == 0 })
    }

    @Test func graphThumbnailBody_usesInlineEmptyAfterLinksLoadWithNoNodes() {
        #expect(
            StatsPresentation.graphThumbnailBodyKind(linksLoaded: true, nodeCount: 0) == .empty,
            "loaded graph links with zero renderable nodes must use the inline empty body, not a nested state card"
        )
    }

    @Test func graphThumbnailBody_distinguishesLoadingEmptyAndGraph() {
        #expect(StatsPresentation.graphThumbnailBodyKind(linksLoaded: false, nodeCount: 0) == .loading)
        #expect(StatsPresentation.graphThumbnailBodyKind(linksLoaded: true, nodeCount: 1) == .graph)
    }

    // MARK: - Graph card state matrix (#2860)

    @Test func graphCard_noCacheWithFailure_isErrorPanelWithReasonForEachFailureKind() {
        let cases: [Error] = [
            KGError.httpError(statusCode: 500, detail: "boom"),
            KGError.offline,
            URLError(.notConnectedToInternet),
            KGError.httpError(statusCode: 404, detail: "nope"),
            KGError.decodingError(underlying: URLError(.cannotParseResponse)),
        ]
        for error in cases {
            let reason = SyncFailurePresentation.reason(for: error)
            #expect(
                StatsPresentation.graphCardState(
                    linksLoaded: false, nodeCount: 0, failureReason: reason, paintTimedOut: false
                ) == .failed(reason: reason),
                "no cached links + \(error) must surface the error panel with its reason, never an endless spinner"
            )
            #expect(!reason.isEmpty)
        }
    }

    @Test func graphCard_failureReasonsAreDistinguishable() {
        let server = SyncFailurePresentation.reason(for: KGError.httpError(statusCode: 500, detail: ""))
        let offline = SyncFailurePresentation.reason(for: URLError(.notConnectedToInternet))
        let rejected = SyncFailurePresentation.reason(for: KGError.httpError(statusCode: 404, detail: ""))
        #expect(Set([server, offline, rejected]).count == 3)
    }

    /// Pins the per-kind copy the error panel shows, not just that a reason exists.
    @Test func graphCard_failureReasonCopyIsSpecificPerKind() {
        let language = AppLanguage.english
        #expect(SyncFailurePresentation.reason(
            for: KGError.httpError(statusCode: 500, detail: "boom"), language: language
        ) == "Server temporarily unavailable")
        #expect(SyncFailurePresentation.reason(
            for: KGError.offline, language: language
        ) == "No internet connection")
        #expect(SyncFailurePresentation.reason(
            for: URLError(.notConnectedToInternet), language: language
        ) == "No internet connection")
        #expect(SyncFailurePresentation.reason(
            for: KGError.httpError(statusCode: 404, detail: "nope"), language: language
        ) == "Server rejected the request (HTTP 404)")
        #expect(SyncFailurePresentation.reason(
            for: KGError.decodingError(underlying: URLError(.cannotParseResponse)), language: language
        ) == "Data format mismatch")
    }

    @Test func graphCard_cachedLinksWithFailure_keepGraphAndAddStaleRow() {
        #expect(
            StatsPresentation.graphCardState(
                linksLoaded: true, nodeCount: 3, failureReason: "r", paintTimedOut: false
            ) == .content(body: .graph, notice: .stale(reason: "r"))
        )
        #expect(
            StatsPresentation.graphCardState(
                linksLoaded: true, nodeCount: 0, failureReason: "r", paintTimedOut: false
            ) == .content(body: .empty, notice: .stale(reason: "r"))
        )
    }

    @Test func graphCard_successClearsNoticeAndPendingIsLoading() {
        #expect(
            StatsPresentation.graphCardState(
                linksLoaded: true, nodeCount: 3, failureReason: nil, paintTimedOut: false
            ) == .content(body: .graph, notice: nil)
        )
        #expect(
            StatsPresentation.graphCardState(
                linksLoaded: false, nodeCount: 0, failureReason: nil, paintTimedOut: false
            ) == .loading
        )
    }

    /// A thumbnail that misses its first paint must not keep the blank web view
    /// as the body: the body becomes the neutral `.unpainted` text and the
    /// `.rendering` row carries the retry.
    @Test func graphCard_paintTimeoutReplacesUnpaintedThumbnailBody() {
        #expect(
            StatsPresentation.graphCardState(
                linksLoaded: true, nodeCount: 3, failureReason: nil, paintTimedOut: true
            ) == .content(body: .unpainted, notice: .rendering),
            "a thumbnail that never reported first paint must not remain as a blank square"
        )
        #expect(
            StatsPresentation.graphCardState(
                linksLoaded: true, nodeCount: 3, failureReason: nil, paintTimedOut: false
            ) == .content(body: .graph, notice: nil),
            "before the watchdog fires the thumbnail keeps its normal body"
        )
        #expect(
            StatsPresentation.graphCardState(
                linksLoaded: true, nodeCount: 0, failureReason: nil, paintTimedOut: true
            ) == .content(body: .empty, notice: nil),
            "the empty body paints natively, so a paint timeout is irrelevant"
        )
    }

    /// A failed pull over an unpainted cached graph keeps the stale reason and
    /// also replaces the blank thumbnail; the stale row stays the only notice.
    @Test func graphCard_paintTimeoutWithCachedFailureReplacesBodyAndKeepsStaleReason() {
        #expect(
            StatsPresentation.graphCardState(
                linksLoaded: true, nodeCount: 3, failureReason: "r", paintTimedOut: true
            ) == .content(body: .unpainted, notice: .stale(reason: "r"))
        )
    }

    @Test func metricValueLayout_keepsNumericValueAndUnitOnOneLine() {
        #expect(StatsMetricValueLayout.maximumLines == 1)
        #expect(StatsMetricValueLayout.minimumScaleFactor == 0.72)
        #expect(StatsMetricValueLayout.allowsTightening)
        #expect(StatsMetricValueLayout.unitIsFixedWidth)
    }

    @Test func singleCard_singleReview_countsAsOne() {
        let summary = StatsPresentation.buildSummary(
            from: [syncedEntry(dueOffset: 0)],
            reviewRecords: [review(dayOffset: 0)],
            clock: Self.canonicalClock
        )
        #expect(summary.totalCards == 1)
        #expect(summary.reviewedToday == 1)
        #expect(summary.dueToday == 1)
        #expect(summary.currentStreak == 1)
        #expect(summary.longestStreak == 1)
    }

    // MARK: - totalCards filter

    @Test func totalCards_excludesPendingEntries() {
        let pending = VocabularyEntry(word: "p", translation: "t", context: "c", bookTitle: "B")
        // syncStatus left at default 0 → not synced → excluded
        let summary = StatsPresentation.buildSummary(
            from: [pending, syncedEntry(dueOffset: 1)],
            reviewRecords: [],
            clock: Self.canonicalClock
        )
        #expect(summary.totalCards == 1, "only synced entries contribute to totalCards")
    }

    @Test func totalCards_excludesDeleteActionEntries() {
        let toDelete = syncedEntry(dueOffset: 1)
        toDelete.actionType = "delete"
        let summary = StatsPresentation.buildSummary(
            from: [toDelete, syncedEntry(dueOffset: 2)],
            reviewRecords: [],
            clock: Self.canonicalClock
        )
        #expect(summary.totalCards == 1, "synced entries pending deletion must not be counted")
    }

    @Test func totalCards_countsAllSyncedNonDeleteEntries() {
        let entries = (0..<5).map { syncedEntry(dueOffset: $0) }
        let summary = StatsPresentation.buildSummary(from: entries, reviewRecords: [], clock: Self.canonicalClock)
        #expect(summary.totalCards == 5)
    }

    // MARK: - Forecast bucketing

    @Test func forecast_dueToday_countsTodayBucket() {
        let summary = StatsPresentation.buildSummary(
            from: [syncedEntry(dueOffset: 0), syncedEntry(dueOffset: 0)],
            reviewRecords: [],
            clock: Self.canonicalClock
        )
        #expect(summary.dueToday == 2)
        #expect(summary.forecast.first?.count == 2)
    }

    @Test func forecast_overdueEntriesCollapseIntoToday() {
        // nextReviewAt in the past → key <= todayKey → folded into today's bucket
        let summary = StatsPresentation.buildSummary(
            from: [syncedEntry(dueOffset: -3), syncedEntry(dueOffset: -10)],
            reviewRecords: [],
            clock: Self.canonicalClock
        )
        #expect(summary.dueToday == 2, "overdue cards must roll forward into today, not vanish")
        #expect(summary.forecast.first?.count == 2)
    }

    @Test func forecast_futureEntryLandsInCorrectBucket() {
        let summary = StatsPresentation.buildSummary(
            from: [syncedEntry(dueOffset: 3)],
            reviewRecords: [],
            forecastDays: 14,
            clock: Self.canonicalClock
        )
        let targetKey = dayKey(3)
        let bucket = summary.forecast.first { $0.id == targetKey }
        #expect(bucket?.count == 1)
        #expect(summary.dueToday == 0, "a card due in 3 days is not due today")
    }

    @Test func forecast_entryBeyondHorizonIsNotBucketed() {
        // Due in 30 days but forecast window is only 7 — it should appear in
        // no bucket, and dueToday stays 0.
        let summary = StatsPresentation.buildSummary(
            from: [syncedEntry(dueOffset: 30)],
            reviewRecords: [],
            forecastDays: 7,
            clock: Self.canonicalClock
        )
        #expect(summary.forecast.count == 7)
        #expect(summary.forecast.allSatisfy { $0.count == 0 })
        #expect(summary.dueToday == 0)
    }

    @Test func forecast_respectsForecastDaysParameter() {
        for days in [7, 14, 30] {
            let summary = StatsPresentation.buildSummary(
                from: [], reviewRecords: [], forecastDays: days,
                clock: Self.canonicalClock
            )
            #expect(summary.forecast.count == days, "forecast length must equal forecastDays=\(days)")
        }
    }

    @Test func forecast_firstTwoBucketsLabeledTodayAndTomorrow() {
        let summary = StatsPresentation.buildSummary(
            from: [], reviewRecords: [], forecastDays: 14,
            clock: Self.canonicalClock
        )
        #expect(summary.forecast[0].label == "今天".localized)
        #expect(summary.forecast[1].label == "明天".localized)
    }

    @Test func forecast_bucketIdsAreDistinctDayKeys() {
        let summary = StatsPresentation.buildSummary(
            from: [], reviewRecords: [], forecastDays: 14,
            clock: Self.canonicalClock
        )
        let ids = Set(summary.forecast.map(\.id))
        #expect(ids.count == 14, "each forecast bucket must have a unique day-key id")
    }

    // MARK: - reviewedToday

    @Test func reviewedToday_countsOnlyTodayRecords() {
        let summary = StatsPresentation.buildSummary(
            from: [],
            reviewRecords: [
                review(dayOffset: 0),
                review(dayOffset: 0),
                review(dayOffset: -1),
                review(dayOffset: -5),
            ],
            clock: Self.canonicalClock
        )
        #expect(summary.reviewedToday == 2, "only records with today's dayKey count")
    }

    @Test func pausedClock_activityUsesWallClockWhileDueUsesFrozenReference() throws {
        var settings = ReviewSettings.default
        let wall = Self.canonicalClock.now
        let pausedAt = day(-3)
        settings.pauseProgress(at: pausedAt)
        let clock = ReviewCalendarClock.live(
            settings: settings, timeZone: Self.canonicalClock.timeZone, wallClockNow: wall
        )
        let due = syncedEntry(dueOffset: -3)

        let summary = StatsPresentation.buildSummary(
            from: [due],
            reviewRecords: (0..<20).map { _ in review(dayOffset: 0) } + [review(dayOffset: -1)],
            clock: clock
        )

        #expect(summary.reviewedToday == 20, "manual reviews at wall-clock today count while paused")
        #expect(summary.currentStreak == 2, "streak anchors on wall-clock today, not the pause date")
        #expect(summary.dueToday == 1, "due projection stays on the frozen reference")
        #expect(summary.forecast.first?.id == Self.canonicalClock.dayKey(pausedAt))
    }

    // MARK: - Streaks

    @Test func currentStreak_countsConsecutiveDaysEndingToday() {
        let summary = StatsPresentation.buildSummary(
            from: [],
            reviewRecords: [
                review(dayOffset: 0),
                review(dayOffset: -1),
                review(dayOffset: -2),
            ],
            clock: Self.canonicalClock
        )
        #expect(summary.currentStreak == 3)
        #expect(summary.longestStreak == 3)
    }

    @Test func currentStreak_survivesMissingTodayButCountsYesterday() {
        // No review today, but yesterday + day-before form a streak. The
        // `offset == 0 → continue` branch lets a not-yet-reviewed today pass.
        let summary = StatsPresentation.buildSummary(
            from: [],
            reviewRecords: [
                review(dayOffset: -1),
                review(dayOffset: -2),
            ],
            clock: Self.canonicalClock
        )
        #expect(summary.currentStreak == 2, "today not yet reviewed must not reset an active streak")
    }

    @Test func currentStreak_breaksOnGap() {
        // Today + a 2-day gap then older reviews → current streak is just today.
        let summary = StatsPresentation.buildSummary(
            from: [],
            reviewRecords: [
                review(dayOffset: 0),
                review(dayOffset: -3),
                review(dayOffset: -4),
            ],
            clock: Self.canonicalClock
        )
        #expect(summary.currentStreak == 1)
        #expect(summary.longestStreak == 2, "the older 2-day block is the longest run")
    }

    @Test func longestStreak_picksLongestRunNotMostRecent() {
        let summary = StatsPresentation.buildSummary(
            from: [],
            reviewRecords: [
                review(dayOffset: 0),                       // recent run: 1 day
                review(dayOffset: -10),
                review(dayOffset: -11),
                review(dayOffset: -12),
                review(dayOffset: -13),                     // old run: 4 days
            ],
            clock: Self.canonicalClock
        )
        #expect(summary.currentStreak == 1)
        #expect(summary.longestStreak == 4)
    }

    @Test func streaks_multipleReviewsSameDayStillCountAsOneDay() {
        let summary = StatsPresentation.buildSummary(
            from: [],
            reviewRecords: [
                review(dayOffset: 0),
                review(dayOffset: 0),
                review(dayOffset: 0),
            ],
            clock: Self.canonicalClock
        )
        #expect(summary.currentStreak == 1, "a streak counts distinct days, not record volume")
        #expect(summary.reviewedToday == 3, "reviewedToday counts records, not days")
    }

    // MARK: - Explicit clock propagation
    //
    // Every downstream query receives the same explicit clock. This keeps the
    // test anchored to the canonical generated fixture instead of a wall clock.

    @Test func reviewedToday_countsRelativeToInjectedClock() {
        let anchor = day(-400)
        let clock = ReviewCalendarClock(
            now: anchor,
            timeZone: Self.canonicalClock.timeZone,
            provenance: "test.explicit"
        )
        let records = [ReviewRecord(word: "x", entryID: nil, feedback: 1, reviewedAt: anchor)]

        #expect(ReviewActivityLog.reviewedToday(records: records, clock: clock) == 1)
    }

    @Test func dayKeyOverloads_matchRecordOverloads() {
        let anchor = day(-400)
        let clock = ReviewCalendarClock(
            now: anchor,
            timeZone: Self.canonicalClock.timeZone,
            provenance: "test.explicit"
        )
        let records = [0, -1, -1, -2, -5].map {
            ReviewRecord(word: "x", entryID: nil, feedback: 1, reviewedAt: Calendar.current.date(byAdding: .day, value: $0, to: anchor) ?? anchor)
        }
        let keys = records.map { clock.dayKey($0.reviewedAt) }

        #expect(ReviewActivityLog.activity(for: 180, dayKeys: keys, clock: clock)
            == ReviewActivityLog.activity(for: 180, records: records, clock: clock))
        #expect(ReviewActivityLog.reviewedToday(dayKeys: keys, clock: clock)
            == ReviewActivityLog.reviewedToday(records: records, clock: clock))
        let a = ReviewActivityLog.streaks(dayKeys: keys, clock: clock)
        let b = ReviewActivityLog.streaks(records: records, clock: clock)
        #expect(a.current == b.current && a.longest == b.longest)
    }

    @Test func streaks_currentStreakAnchorsOnInjectedClock() {
        let anchor = day(-400)
        let clock = ReviewCalendarClock(
            now: anchor,
            timeZone: Self.canonicalClock.timeZone,
            provenance: "test.explicit"
        )
        let records = [
            ReviewRecord(word: "a", entryID: nil, feedback: 1, reviewedAt: anchor),
            ReviewRecord(
                word: "b", entryID: nil, feedback: 1,
                reviewedAt: Self.calendar.date(byAdding: .day, value: -1, to: anchor) ?? anchor
            ),
        ]

        let frozen = ReviewActivityLog.streaks(records: records, clock: clock)
        #expect(frozen.current == 2)
        #expect(frozen.longest == 2)
    }

    @Test func activity_cutoffAnchorsOnInjectedClock() {
        let anchor = day(-400)
        let clock = ReviewCalendarClock(
            now: anchor,
            timeZone: Self.canonicalClock.timeZone,
            provenance: "test.explicit"
        )
        let records = [ReviewRecord(word: "x", entryID: nil, feedback: 1, reviewedAt: anchor)]

        let frozen = ReviewActivityLog.activity(for: 180, records: records, clock: clock)
        #expect(frozen.values.reduce(0, +) == 1)
    }

    @Test func buildSummary_threadsClockIntoActivityLog() {
        let anchor = day(-400)
        let clock = ReviewCalendarClock(
            now: anchor,
            timeZone: Self.canonicalClock.timeZone,
            provenance: "test.explicit"
        )
        let records = [ReviewRecord(word: "x", entryID: nil, feedback: 1, reviewedAt: anchor)]

        let summary = StatsPresentation.buildSummary(from: [], reviewRecords: records, clock: clock)
        #expect(summary.reviewedToday == 1)
        #expect(summary.currentStreak == 1)
        #expect(summary.activity.values.reduce(0, +) == 1)
    }

    // MARK: - Activity map

    @Test func activity_aggregatesRecordsByDayKey() {
        let summary = StatsPresentation.buildSummary(
            from: [],
            reviewRecords: [
                review(dayOffset: 0),
                review(dayOffset: 0),
                review(dayOffset: -1),
            ],
            clock: Self.canonicalClock
        )
        #expect(summary.activity[dayKey(0)] == 2)
        #expect(summary.activity[dayKey(-1)] == 1)
    }

    // MARK: - Heatmap thresholds (adaptive percentiles)

    @Test func heatmapThresholds_fallbackWhenFewerThanFourNonZeroDays() {
        // Only 3 distinct review days → fewer than 4 non-zero counts → fallback.
        let summary = StatsPresentation.buildSummary(
            from: [],
            reviewRecords: [
                review(dayOffset: 0),
                review(dayOffset: -1),
                review(dayOffset: -2),
            ],
            clock: Self.canonicalClock
        )
        #expect(summary.heatmapThresholds == [1, 2, 3], "sparse data must use the simple fallback ramp")
    }

    @Test func heatmapThresholds_emptyInputUsesFallback() {
        let summary = StatsPresentation.buildSummary(from: [], reviewRecords: [], clock: Self.canonicalClock)
        #expect(summary.heatmapThresholds == [1, 2, 3])
    }

    @Test func heatmapThresholds_computedFromPercentilesWithEnoughDays() {
        // 8 distinct days with ascending volume 1..8. sorted non-zero counts:
        // [1,2,3,4,5,6,7,8]. p25 = idx 8/4=2 → 3, p50 = idx 4 → 5, p75 = idx 6 → 7.
        var records: [ReviewRecord] = []
        for dayOffset in 0..<8 {
            let volume = dayOffset + 1
            for _ in 0..<volume {
                records.append(review(dayOffset: -dayOffset))
            }
        }
        let summary = StatsPresentation.buildSummary(from: [], reviewRecords: records, clock: Self.canonicalClock)
        #expect(summary.heatmapThresholds == [3, 5, 7],
                "with >= 4 non-zero days the ramp must come from p25/p50/p75 of the sorted counts")
    }

    @Test func heatmapThresholds_areNonDescending() {
        // Property check across an irregular distribution.
        var records: [ReviewRecord] = []
        let volumes = [1, 9, 2, 7, 4, 1, 6]
        for (dayOffset, volume) in volumes.enumerated() {
            for _ in 0..<volume { records.append(review(dayOffset: -dayOffset)) }
        }
        let summary = StatsPresentation.buildSummary(from: [], reviewRecords: records, clock: Self.canonicalClock)
        let t = summary.heatmapThresholds
        #expect(t.count == 3)
        #expect(t[0] <= t[1] && t[1] <= t[2], "percentile thresholds must be monotonically non-descending")
    }

    // MARK: - Combined / non-empty scene invariant

    @Test func nonEmptyData_failsSceneEmptyInvariant() {
        // A populated summary must NOT satisfy the `.empty` predicate, so the
        // scene resolves to `.content`.
        let s = StatsPresentation.buildSummary(
            from: [syncedEntry(dueOffset: 0)],
            reviewRecords: [review(dayOffset: 0)],
            clock: Self.canonicalClock
        )
        let isEmpty = s.totalCards == 0
            && s.activity.values.allSatisfy { $0 == 0 }
            && s.currentStreak == 0
            && s.longestStreak == 0
        #expect(!isEmpty, "any card or review activity must push the scene into `.content`")
    }

    // MARK: - P10 projection contract

    @Test func projection_usesOneInjectedClockForForecastAndActivity() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let anchor = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2030,
            month: 1,
            day: 10,
            hour: 12
        )))
        let clock = StatsProjectionClock(now: anchor, calendar: calendar)
        let entry = syncedEntry(dueOffset: 0)
        entry.nextReviewAt = anchor
        let record = ReviewRecord(word: "x", entryID: nil, feedback: 1, reviewedAt: anchor)

        let projection = StatsPresentation.project(
            entries: [entry],
            reviewRecords: [record],
            forecastDays: 1,
            clock: clock
        )

        #expect(projection.totalCards == 1)
        #expect(projection.reviewedToday == 1)
        #expect(projection.dueToday == 1)
        #expect(projection.forecast.first?.id == clock.dayKey(anchor))
        #expect(projection.activity[clock.dayKey(anchor)] == 1)
    }

    @Test func projection_countsZeroAndLargeForecastWithoutWallClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let anchor = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2030,
            month: 1,
            day: 10,
            hour: 12
        )))
        let clock = StatsProjectionClock(now: anchor, calendar: calendar)
        let entries = (0..<1_234).map { index -> VocabularyEntry in
            let entry = VocabularyEntry(
                word: "large-\(index)",
                translation: "t",
                context: "c",
                bookTitle: "B"
            )
            entry.syncStatus = 1
            entry.reviewCount = 1
            entry.nextReviewAt = anchor
            return entry
        }

        let projection = StatsPresentation.project(
            entries: entries,
            reviewRecords: [],
            forecastDays: 1,
            clock: clock
        )

        #expect(projection.totalCards == 1_234)
        #expect(projection.forecast.first?.count == 1_234)
        #expect(projection.formattedCount(projection.totalCards) == "1,234")
        #expect(projection.formattedCount(0) == "0")
    }

    @Test @MainActor func projection_fixtureLongUsesCanonicalSeedForOverdueAndFutureZero() throws {
        try FixtureDatasetStore.withTestingData(StatsPresenterFixtureData.marketingDemoData) {
            let fixtureID: UIWorldVocabularyFixtureID = .vocabListLong
            let seed = FixtureDatasetStore.requireVocabularySeed(for: fixtureID)
            let entries = seed.entries.map {
                UITestFixtureSeed.makeVocabularyEntry(from: $0, notebookId: seed.notebookRemoteId)
            }
            let entriesByWord = Dictionary(uniqueKeysWithValues: entries.map { ($0.word, $0) })
            let reviewRecords = try seed.reviewHistory.map { history -> ReviewRecord in
                let entry = try #require(entriesByWord[history.word])
                let record = ReviewRecord(
                    word: history.word,
                    entryID: entry.id,
                    feedback: history.feedback,
                    reviewedAt: history.reviewedAt,
                    kgCardId: entry.kgCardId
                )
                record.notebookId = seed.notebookRemoteId
                return record
            }
            let clock = UITestFixtureSeed.makeStatsProjectionClock(
                for: fixtureID
            )
            let visibleEntries = entries.filter { $0.shouldAppearInReview && $0.reviewCount > 0 }
            let todayKey = clock.dayKey(clock.now)
            let expectedDueToday = visibleEntries.filter {
                clock.dayKey($0.nextReviewAt) <= todayKey
            }.count
            let expectedFutureCards = visibleEntries.filter {
                clock.dayKey($0.nextReviewAt) > todayKey
            }.count

            let projection = StatsPresentation.project(
                entries: entries,
                reviewRecords: reviewRecords,
                forecastDays: 14,
                clock: clock
            )

            #expect(projection.totalCards == visibleEntries.count)
            #expect(projection.dueToday == expectedDueToday)
            #expect(projection.forecast.first?.id == todayKey)
            #expect(projection.forecast.first?.count == expectedDueToday)
            #expect(projection.forecast.dropFirst().reduce(0) { $0 + $1.count } == expectedFutureCards)
            #expect(projection.forecast.dropFirst().allSatisfy { $0.count == 0 })
        }
    }
}

#if DEBUG && canImport(Playbook)
/// Pins `StatsViewTime.clock` — the catalog Stats View frozen "today" must be
/// derived from the seed's latest review event (寫死日期會讓「複習預測/今日到期」
/// 在 seed 錨日移動後恆 0)。
@Suite struct StatsViewSceneTimeTests {
    @Test func anchorDerivesNoonOfLatestReviewedAt() throws {
        let calendar = StatsViewTime.calendar
        let latest = try #require(calendar.date(
            byAdding: .minute,
            value: -42,
            to: StatsPresenterTests.canonicalClock.now
        ))

        let clock = StatsViewTime.clock(latestReviewedAt: latest, calendar: calendar)

        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: clock.now)
        let expectedDay = calendar.dateComponents([.year, .month, .day], from: latest)
        #expect(comps.year == expectedDay.year)
        #expect(comps.month == expectedDay.month)
        #expect(comps.day == expectedDay.day)
        #expect(comps.hour == 12)
        #expect(comps.minute == 0)
        #expect(clock.calendar.timeZone == calendar.timeZone)
        #expect(clock.dayKey(clock.now) == clock.dayKey(latest))
    }

    @Test func anchorFallsBackDeterministicallyForEmptySeeds() {
        let calendar = StatsViewTime.calendar
        let clock = StatsViewTime.clock(latestReviewedAt: nil, calendar: calendar)

        #expect(clock.now == StatsViewTime.emptySeedFallback)
        #expect(clock.calendar.timeZone == calendar.timeZone)
    }

    @Test @MainActor func longFixtureClockFoldsCanonicalDueDateIntoToday() throws {
        try FixtureDatasetStore.withTestingData(StatsPresenterFixtureData.marketingDemoData) {
            let seed = FixtureDatasetStore.requireVocabularySeed(for: .vocabListLong)
            let clock = UITestFixtureSeed.makeStatsProjectionClock(
                for: .vocabListLong
            )
            let dueDate = try #require(seed.entries.compactMap(\.nextReviewAt).min())

            #expect(clock == ReviewCalendarClock.uiWorldOrLive())
            #expect(clock.dayKey(clock.now) > clock.dayKey(dueDate))
        }
    }
}
/// #2859: the Overview metric block is a two-column grid at standard Dynamic Type
/// sizes and reflows to one column at accessibility sizes. Pins the pure policy.
@Suite struct StatsMetricsColumnPolicyTests {
    @Test func standardSizes_useTwoColumns() {
        #expect(VocabStatTileLayout.columnCount(for: .large) == 2)
        #expect(VocabStatTileLayout.columnCount(for: .xxxLarge) == 2)
    }

    @Test func accessibilitySizes_reflowToOneColumn() {
        #expect(VocabStatTileLayout.columnCount(for: .accessibility1) == 1)
        #expect(VocabStatTileLayout.columnCount(for: .accessibility3) == 1)
    }
}
#endif
#endif
