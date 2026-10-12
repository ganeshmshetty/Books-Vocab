//
//  OverviewFlowUITests.swift
//  Books & Vocab UI Tests
//
//  Focused Overview flow: proves the stats tab renders real seeded content,
//  and that leaving/re-entering the tab keeps the content surface alive.
//

import Foundation
import XCTest

private struct OverviewFixtureProjection {
    private struct Dataset: Decodable {
        struct Preferences: Decodable {
            struct Defaults: Decodable {
                let appLanguageSelection: String

                enum CodingKeys: String, CodingKey {
                    case appLanguageSelection = "app_language_selection"
                }
            }

            let userDefaults: Defaults
        }

        struct Vocabulary: Decodable {
            struct Entry: Decodable {
                let word: String
                let syncStatus: Int
                let actionType: String
                let isArchived: Bool
                let nextReviewAt: Date?
                let reviewCount: Int?
                let isReviewExcluded: Bool?
            }

            struct EntryOverride: Decodable {
                let word: String
                let nextReviewAt: Date
                let reviewCount: Int?
            }

            struct Review: Decodable {
                let reviewedAt: Date
            }

            let entries: [Entry]
            let reviewHistory: [Review]
            // Resolved materialization treats an absent override list as empty.
            let entryOverrides: [EntryOverride]?
        }

        let preferences: Preferences
        let vocabulary: [String: Vocabulary]

        struct ScenarioContext: Decodable {
            struct ReviewClock: Decodable {
                let frozenEpoch: Int
                let anchorDay: String
                let timeZone: String
            }

            let reviewClock: ReviewClock
        }

        let scenarioContext: ScenarioContext?
    }

    let totalCards: Int
    let reviewedToday: Int
    let dueToday: Int
    let activityIsEmpty: Bool
    let clockNow: Date
    let forecastDayKey: String
    let forecastDayKeys: [String]
    private let forecastCounts: [String: Int]
    private let languageCode: String
    private let systemLocaleIdentifier: String
    private let formatLocaleIdentifier: String

    /// The app's LocaleAwareFormatter follows AppLanguageStore.formatLocale.
    /// The UI World pins app_language_selection, while these launch arguments
    /// make the system fallback deterministic if the app selection is absent.
    var localeLaunchArguments: [String] {
        [
            "-AppleLanguages",
            "(\(languageCode))",
            "-AppleLocale",
            systemLocaleIdentifier,
        ]
    }

    func formattedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: formatLocaleIdentifier)
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func forecastCount(for dayKey: String) -> Int {
        forecastCounts[dayKey] ?? 0
    }

    static func fromRunner(fixtureID: String) throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        let data: Data
        if let deflateB64 = environment["KG_FIXTURE_DATASET_DEFLATE_B64"], !deflateB64.isEmpty {
            guard let compressed = Data(base64Encoded: deflateB64) else {
                throw NSError(domain: "OverviewFixtureProjection", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "KG_FIXTURE_DATASET_DEFLATE_B64 is not valid base64",
                ])
            }
            data = try (compressed as NSData).decompressed(using: .zlib) as Data
        } else if let base64 = environment["KG_FIXTURE_DATASET_B64"], !base64.isEmpty {
            guard let decoded = Data(base64Encoded: base64) else {
                throw NSError(domain: "OverviewFixtureProjection", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "KG_FIXTURE_DATASET_B64 is not valid base64",
                ])
            }
            data = decoded
        } else {
            throw NSError(domain: "OverviewFixtureProjection", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "marketing_demo UI World is missing from the runner",
            ])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Dataset.self, from: data)
        let localeContract: (languageCode: String, systemLocaleIdentifier: String, formatLocaleIdentifier: String)
        switch document.preferences.userDefaults.appLanguageSelection {
        case "english":
            localeContract = ("en", "en_US_POSIX", "en")
        case "traditionalChinese":
            localeContract = ("zh-Hant", "zh_TW", "zh-Hant")
        case "simplifiedChinese":
            localeContract = ("zh-Hans", "zh_CN", "zh-Hans")
        case "japanese":
            localeContract = ("ja", "ja_JP", "ja")
        case "korean":
            localeContract = ("ko", "ko_KR", "ko")
        case "system":
            throw NSError(domain: "OverviewFixtureProjection", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Overview UI World must pin a concrete app language for AX count assertions",
            ])
        default:
            throw NSError(domain: "OverviewFixtureProjection", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported Overview UI World app language: \(document.preferences.userDefaults.appLanguageSelection)",
            ])
        }
        guard let seed = document.vocabulary[fixtureID] else {
            throw NSError(domain: "OverviewFixtureProjection", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "\(fixtureID) is missing from the injected UI World",
            ])
        }

        guard let reviewClock = document.scenarioContext?.reviewClock,
              let timeZone = TimeZone(identifier: reviewClock.timeZone)
        else {
            throw NSError(domain: "OverviewFixtureProjection", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "marketing_demo.scenarioContext.reviewClock is missing",
            ])
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // OverviewTab and every child projection consume the canonical
        // scenarioContext clock. Decode the same frozen epoch here for both
        // populated and empty vocabulary seeds; fixture-local latest-review
        // heuristics would diverge from the production composition boundary.
        let clockNow = Date(timeIntervalSince1970: TimeInterval(reviewClock.frozenEpoch))

        func dayKey(_ date: Date) -> String {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            return String(
                format: "%04d-%02d-%02d",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
        }

        let todayKey = dayKey(clockNow)
        let visibleEntries = seed.entries.filter {
            $0.syncStatus == 1 && $0.actionType != "delete" && !$0.isArchived
        }
        // Vocabulary materialization applies entryOverrides before Overview
        // projects scheduling state. Keep the test projection on that same
        // resolved seed rather than reading the base entry rows only; the P11
        // 644-card fixture intentionally stores its due mix in overrides.
        let nextReviewAtOverrides = Dictionary(
            uniqueKeysWithValues: (seed.entryOverrides ?? []).map { ($0.word, $0.nextReviewAt) }
        )
        let reviewCountOverrides = Dictionary(
            uniqueKeysWithValues: (seed.entryOverrides ?? []).map { ($0.word, $0.reviewCount) }
        )
        // Production (StatsPresentation.project) forecasts and dueToday count
        // only review-queue cards: shouldAppearInReview && reviewCount > 0.
        // Never-reviewed placeholders carry a nextReviewAt but are not due.
        func isForecastEligible(_ entry: Dataset.Vocabulary.Entry) -> Bool {
            let overrideCount: Int? = reviewCountOverrides[entry.word] ?? nil
            let reviewCount = overrideCount ?? entry.reviewCount ?? 0
            return reviewCount > 0 && entry.isReviewExcluded != true
        }
        let forecastEntries = visibleEntries.filter(isForecastEligible)
        var forecastCounts: [String: Int] = [:]
        for entry in forecastEntries {
            guard let nextReviewAt = nextReviewAtOverrides[entry.word] ?? entry.nextReviewAt else {
                continue
            }
            let key = dayKey(nextReviewAt)
            let projectedKey = key <= todayKey ? todayKey : key
            forecastCounts[projectedKey, default: 0] += 1
        }
        let forecastDayKeys = (0..<30).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: clockNow) else {
                return nil
            }
            return dayKey(date)
        }
        // Matches production dueToday == forecastMap[todayKey]: overdue eligible
        // cards fold into today, so the due count is the eligible subset <= today.
        let dueToday = forecastEntries.filter {
            guard let nextReviewAt = nextReviewAtOverrides[$0.word] ?? $0.nextReviewAt else {
                return false
            }
            return dayKey(nextReviewAt) <= todayKey
        }.count
        let reviewedToday = seed.reviewHistory.filter { dayKey($0.reviewedAt) == todayKey }.count

        return Self(
            totalCards: visibleEntries.count,
            reviewedToday: reviewedToday,
            dueToday: dueToday,
            activityIsEmpty: seed.reviewHistory.isEmpty,
            clockNow: clockNow,
            forecastDayKey: todayKey,
            forecastDayKeys: forecastDayKeys,
            forecastCounts: forecastCounts,
            languageCode: localeContract.languageCode,
            systemLocaleIdentifier: localeContract.systemLocaleIdentifier,
            formatLocaleIdentifier: localeContract.formatLocaleIdentifier
        )
    }

}

final class OverviewFlowUITests: UITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // This suite launches both the populated and large-text counterexample
        // worlds and captures ten evidence steps. Keep the allowance explicit;
        // XCTest's default is too short for the complete bounded projection.
        executionTimeAllowance = 420
    }

    /// #2736: the heatmap must open scrolled to the latest week. The 52-week override
    /// (`KG_UI_TEST_HEATMAP_WEEKS`) overflows the viewport on every device, so the premise
    /// is deterministic; without the scroll position the strip opens at the oldest week.
    @MainActor
    func testActivityHeatmapOpensOnLatestWeek() throws {
        let expected = try OverviewFixtureProjection.fromRunner(fixtureID: "statsPopulated")
        let app = launchIsolatedApp(
            extraArgs: expected.localeLaunchArguments,
            fixtures: [.vocabulary("statsPopulated")],
            extraEnvironment: ["KG_UI_TEST_HEATMAP_WEEKS": "52"],
            perfLog: "overview"
        )
        let shell = AppPage(app: app)
        let overview = shell.goToOverview()
        XCTAssertTrue(app.waitForNavigationToSettle())
        overview.scrollToReviewCalendarButton()
        overview.calendar.assertExists(timeout: 10)

        // The probe sits on the horizontal ScrollView viewport (value derived from real scroll
        // geometry), not on per-day cells: the heatmap lives inside a Button label.
        func probeValue() -> String {
            let viewport = app.descendants(matching: .any)
                .matching(identifier: "calendar.heatmap.viewport").firstMatch
            return viewport.exists ? (viewport.value as? String ?? "") : "<probe missing>"
        }
        func waitForProbe(containing needle: String, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if probeValue().contains(needle) { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return probeValue().contains(needle)
        }

        // Wait until the strip reaches the trailing edge (or time out), then read the probe once.
        // Precondition and behavior below judge this same snapshot, so they cannot disagree.
        _ = waitForProbe(containing: "trailing=1", timeout: 10)
        let probe = probeValue()
        // Precondition (test premise): the 52-week grid must overflow the viewport,
        // otherwise "latest week visible" holds trivially without any scroll fix.
        XCTAssertTrue(
            probe.contains("overflow=1"),
            "precondition failed: 52-week heatmap did not overflow its viewport (probe=\(probe))"
        )
        // The assertion under test: the overflowing strip rests on the trailing (latest) edge.
        XCTAssertTrue(
            probe.contains("trailing=1"),
            "heatmap did not open scrolled to the latest week (probe=\(probe))"
        )

        // AX contract: the calendar opener stays one labelled, hittable Button after the heatmap
        // change, and tapping it opens Review Calendar. Cells live inside the heatmap Button label,
        // so the opener is the only addressable calendar entry point.
        let openers = app.buttons.matching(identifier: "reviewCalendar.open")
        XCTAssertEqual(openers.count, 1, "reviewCalendar.open must match exactly one Button")
        let opener = openers.element(boundBy: 0)
        XCTAssertFalse(opener.label.isEmpty, "reviewCalendar.open must keep its localized label")
        XCTAssertTrue(opener.isHittable, "reviewCalendar.open must stay hittable with the heatmap present")
        opener.tapWhenReady()
        XCTAssertTrue(
            ReviewCalendarPage(app: app).monthHeader.waitUntilExists(timeout: 10),
            "tapping reviewCalendar.open must open Review Calendar"
        )
    }

    @MainActor
    func testOverviewStatsRenderFromSeededReviewHistory() throws {
        let expected = try OverviewFixtureProjection.fromRunner(fixtureID: "statsPopulated")
        let app = launchIsolatedApp(
            extraArgs: expected.localeLaunchArguments,
            fixtures: [.vocabulary("statsPopulated")],
            perfLog: "overview"
        )
        captureStep("launch", app: app)

        let shell = AppPage(app: app)
        let overview = try step("overview", app: app) {
            let page = shell.goToOverview()
            XCTAssertTrue(app.waitForNavigationToSettle())
            return page
        }
        try step("metrics", app: app) {
            overview.assertIsActive()
            overview.assertOverviewAccessibilityHierarchy()
            overview.assertMetric("totalCards", value: expected.formattedCount(expected.totalCards))
            overview.assertMetric("reviewedToday", value: expected.formattedCount(expected.reviewedToday))
            overview.assertMetric("dueToday", value: expected.formattedCount(expected.dueToday))
            overview.assertMetricCardsHaveUniformGeometry()
            XCTAssertTrue(shell.overviewTab.isSelected, "總覽 tab did not become selected")
        }

        try step("calendar", app: app) {
            overview.calendar.assertExists(timeout: 10)
        }

        try step("forecast-zero", app: app) {
            overview.scrollToForecastRange(14)
            overview.selectForecastRange(14)
            overview.scrollToForecastBucket(expected.forecastDayKey)
            overview.assertUniqueForecastContract()
            assertForecastProjection(expected, days: 14, on: overview)
        }

        try step("notebook-detour", app: app) {
            let notebooks = shell.goToNotebooks()
            notebooks.assertIsActive()
            XCTAssertTrue(shell.notebookTab.isSelected, "單字本 tab did not become selected")
        }

        try step("overview-reentry", app: app) {
            _ = shell.goToOverview()
            overview.assertMetric("totalCards", value: expected.formattedCount(expected.totalCards))
            XCTAssertTrue(shell.overviewTab.isSelected, "總覽 tab did not become selected on re-entry")
        }

        let counterexampleExpected = try Self.p11ReviewMixProjection()
        let counterexampleApp = launchIsolatedApp(
            extraArgs: counterexampleExpected.localeLaunchArguments + [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ],
            fixtures: [.vocabulary("p11.644.reviewMix")],
            perfLog: "overview-counterexamples"
        )
        captureStep("large-text-counterexample", app: counterexampleApp)
        attachText(
            "fixture=marketing_demo.p11.644.reviewMix\n"
                + "clock=\(counterexampleExpected.clockNow.ISO8601Format())\n"
                + "clockSource=UITestFixtureSeed.makeStatsProjectionClock\n"
                + "clockRule=UTC noon on day after canonical earliest nextReviewAt\n"
                + "dateFallback=none",
            named: "Overview Clock Provenance"
        )
        let counterexampleOverview = try step("large-counts", app: counterexampleApp) {
            let page = AppPage(app: counterexampleApp).goToOverview()
            XCTAssertTrue(counterexampleApp.waitForNavigationToSettle())
            return page
        }
        try step("large-counts-projection", app: counterexampleApp) {
            counterexampleOverview.assertOverviewAccessibilityHierarchy()
            counterexampleOverview.assertMetric(
                "totalCards",
                value: counterexampleExpected.formattedCount(counterexampleExpected.totalCards)
            )
            counterexampleOverview.assertMetric(
                "reviewedToday",
                value: counterexampleExpected.formattedCount(counterexampleExpected.reviewedToday)
            )
            counterexampleOverview.assertMetric(
                "dueToday",
                value: counterexampleExpected.formattedCount(counterexampleExpected.dueToday)
            )
            counterexampleOverview.assertMetricCardsHaveUniformGeometry(twoColumns: false)
            counterexampleOverview.calendar.assertExists(timeout: 10)
            counterexampleOverview.scrollToForecastRange(14)
            counterexampleOverview.selectForecastRange(14)
            counterexampleOverview.assertUniqueForecastContract()
            assertForecastProjection(counterexampleExpected, days: 14, on: counterexampleOverview)
        }
    }

    @MainActor
    func testOverviewForecastRangeSwitchKeepsChartLive() throws {
        let expected = try OverviewFixtureProjection.fromRunner(fixtureID: "statsPopulated")
        let app = launchIsolatedApp(
            extraArgs: expected.localeLaunchArguments,
            fixtures: [.vocabulary("statsPopulated")],
            perfLog: "overview-forecast-range"
        )
        let overview = try step("forecast-range-overview", app: app) {
            let page = AppPage(app: app).goToOverview()
            XCTAssertTrue(app.waitForNavigationToSettle())
            return page
        }

        try step("forecast-range-14", app: app) {
            overview.scrollToForecastRange(14)
            overview.selectForecastRange(14)
            overview.assertUniqueForecastContract()
            assertForecastProjection(expected, days: 14, on: overview)
        }

        try step("forecast-range-7", app: app) {
            overview.selectForecastRange(7)
            overview.assertUniqueForecastContract()
            assertForecastProjection(expected, days: 7, on: overview)
        }

        try step("forecast-range-30", app: app) {
            overview.selectForecastRange(30)
            overview.assertUniqueForecastContract()
            assertForecastProjection(expected, days: 30, on: overview)
        }

        try step("forecast-range-7-reentry", app: app) {
            overview.selectForecastRange(7)
            overview.assertUniqueForecastContract()
            assertForecastProjection(expected, days: 7, on: overview)
        }
    }

    @MainActor
    func testOverviewEmptyForecastCounterexampleIsVisible() throws {
        let expected = try OverviewFixtureProjection.fromRunner(fixtureID: "statsEmpty")
        let app = launchIsolatedApp(
            extraArgs: expected.localeLaunchArguments,
            fixtures: [.vocabulary("statsEmpty")],
            perfLog: "overview-empty-forecast"
        )
        let overview = try step("overview-empty", app: app) {
            let page = AppPage(app: app).goToOverview()
            XCTAssertTrue(app.waitForNavigationToSettle())
            return page
        }

        try step("forecast-zero-counterexample", app: app) {
            overview.assertOverviewAccessibilityHierarchy()
            overview.assertMetric("totalCards", value: expected.formattedCount(0))
            overview.assertMetric("reviewedToday", value: expected.formattedCount(0))
            overview.assertMetric("dueToday", value: expected.formattedCount(0))
            overview.calendar.assertExists(timeout: 10)
            overview.scrollToForecastRange(14)
            overview.selectForecastRange(14)
            overview.scrollToForecastBucket(expected.forecastDayKey)
            overview.assertUniqueForecastContract()
            assertForecastProjection(expected, days: 14, on: overview)

            let zeroCounterexample = app.descendants(matching: .any)
                .matching(identifier: "forecast-zero-counterexample")
            XCTAssertEqual(
                zeroCounterexample.count,
                1,
                "forecast-zero-counterexample must be a unique live AX element"
            )
            XCTAssertEqual(
                zeroCounterexample.element.value as? String,
                expected.formattedCount(0),
                "forecast-zero-counterexample must expose the formatted zero value"
            )
        }
    }

    private static func p11ReviewMixProjection() throws -> OverviewFixtureProjection {
        try OverviewFixtureProjection.fromRunner(fixtureID: "p11.644.reviewMix")
    }

    private func assertForecastProjection(
        _ expected: OverviewFixtureProjection,
        days: Int,
        on overview: OverviewPage,
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) {
        XCTAssertEqual(
            expected.forecastDayKeys.count,
            30,
            "fixture projection must expose the complete 30-day forecast horizon",
            file: file,
            line: line
        )
        // The production forecast is one fixed-height chart, not a vertical
        // list of rows. Scroll the chart into view once; repeatedly swiping
        // for each bucket can move the entire chart out of the viewport and
        // makes a valid accessibility projection appear to disappear.
        overview.scrollToForecastBucket(expected.forecastDayKey, file: file, line: line)
        for dayKey in expected.forecastDayKeys.prefix(days) {
            let bucket = overview.forecastBucket(dayKey, file: file, line: line)
            bucket.assertExists(timeout: 10, file: file, line: line)
            XCTAssertTrue(
                (bucket.value as? String)?.contains(
                    expected.formattedCount(expected.forecastCount(for: dayKey))
                ) == true,
                "forecast.bucket.\(dayKey) must expose its deterministic projected count",
                file: file,
                line: line
            )
        }
    }

}
