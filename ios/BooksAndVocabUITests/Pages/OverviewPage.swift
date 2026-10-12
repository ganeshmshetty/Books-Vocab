import XCTest

/// Page Object for the Overview (Stats) tab.
struct OverviewPage {
    let app: XCUIApplication

    private func elements(identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    private func element(identifier: String) -> XCUIElement {
        elements(identifier: identifier).element(boundBy: 0)
    }

    // MARK: - Content

    /// Calendar entry point. This deliberately uses the stable identifier
    /// rather than the localized section title.
    var reviewCalendarButton: XCUIElement {
        exactlyOne(app.buttons.matching(identifier: "reviewCalendar.open"), "reviewCalendar.open")
    }

    /// Region of the Overview ScrollView not covered by the navigation bar or tab bar.
    /// Caller must ensure the ScrollView exists (property access on a missing element throws).
    private func actionableBand(scrollView: XCUIElement) -> CGRect {
        let frame = scrollView.frame
        var top = frame.minY
        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists, !navigationBar.frame.isEmpty {
            top = max(top, navigationBar.frame.maxY)
        }
        var bottom = frame.maxY
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, !tabBar.frame.isEmpty {
            bottom = min(bottom, tabBar.frame.minY)
        }
        return CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, bottom - top))
    }

    /// Drag the Overview ScrollView so the opener's centre moves toward the middle of the
    /// actionable band (#2886). Element-relative swipes start and end at fixed fractions of the
    /// ScrollView frame, which extends under the navigation bar and tab bar, so a gesture can be
    /// consumed by a bar and never scroll, or fling past the band in one step. This drag has both
    /// endpoints inside the band, caps the travel at half the band height, and holds before release
    /// so no fling momentum carries content out of the band.
    private func dragOverviewContent(scrollView: XCUIElement, band: CGRect, openerMidY: CGFloat) {
        // UIKit does not begin scrolling for drags shorter than its pan slop.
        let minimumTravel: CGFloat = 24
        let maximumTravel = band.height * 0.5
        let needed = band.midY - openerMidY
        let magnitude = min(max(abs(needed), minimumTravel), maximumTravel)
        // Positive travel moves the finger down, which moves content down.
        let travel = needed < 0 ? -magnitude : magnitude
        let origin = scrollView.coordinate(withNormalizedOffset: .zero)
        let x = band.midX - scrollView.frame.minX
        let start = origin.withOffset(CGVector(dx: x, dy: band.midY - travel / 2 - scrollView.frame.minY))
        let end = origin.withOffset(CGVector(dx: x, dy: band.midY + travel / 2 - scrollView.frame.minY))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Move the real Overview ScrollView until the calendar opener is both
    /// visible and hittable. The opener is below the first viewport in the
    /// production layout; existence alone is therefore not an actionable
    /// readiness condition.
    func scrollToReviewCalendarButton(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) {
        let query = app.buttons.matching(identifier: "reviewCalendar.open")
        let scrollQuery = app.scrollViews.matching(identifier: "overview.statsContent")
        let scrollView = scrollQuery.element(boundBy: 0)
        let deadline = Date().addingTimeInterval(timeout)
        var swipes = 0

        while Date() < deadline {
            if query.count == 1 {
                let button = query.element(boundBy: 0)
                // The actionable band is the part of the ScrollView that is not covered by the
                // large navigation bar (which overlays content while scrolling) or the tab bar.
                let band = scrollQuery.count == 1 && scrollView.exists
                    ? actionableBand(scrollView: scrollView)
                    : CGRect.null
                if button.exists,
                   !button.frame.isEmpty,
                   scrollQuery.count == 1,
                   scrollView.exists,
                   scrollView.frame.intersects(button.frame),
                   band.contains(button.frame),
                   button.isHittable {
                    return
                }

                if scrollQuery.count == 1, scrollView.exists, !button.frame.isEmpty, band.height > 0 {
                    dragOverviewContent(scrollView: scrollView, band: band, openerMidY: button.frame.midY)
                } else if scrollQuery.count == 1, scrollView.exists {
                    scrollView.swipeUp(velocity: .slow)
                } else {
                    app.swipeUp(velocity: .slow)
                }
            } else {
                app.swipeUp(velocity: .slow)
            }
            swipes += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        XCTAssertEqual(query.count, 1, "reviewCalendar.open must remain unique after scrolling", file: file, line: line)
        // Exhaustion evidence (#2886): the failure message carries the opener frame, the
        // Overview ScrollView frame and the swipe count, so the CI log alone shows whether the
        // opener sat outside the scroll viewport (scroll never reached it) or inside it but
        // not hittable (occlusion or gesture capture). Read only when the element exists:
        // XCUIElement property access on a missing element throws instead of reporting.
        let opener = query.element(boundBy: 0)
        let openerExists = opener.exists
        let openerState = openerExists
            ? "frame=\(opener.frame) hittable=\(opener.isHittable)"
            : "missing"
        let scrollState = scrollQuery.count == 1 && scrollView.exists
            ? "scrollFrame=\(scrollView.frame)"
            : "scrollView=\(scrollQuery.count)"
        XCTAssertTrue(
            openerExists && opener.isHittable,
            "reviewCalendar.open must be hittable after scrolling the production Overview ScrollView "
                + "(\(openerState), \(scrollState), swipes=\(swipes))",
            file: file,
            line: line
        )
    }

    /// Materialize a forecast bucket inside the production Overview
    /// ScrollView before asserting its value. The chart is below the graph,
    /// metrics, and calendar on compact screens; querying an offscreen SwiftUI
    /// child can legitimately return zero until the real scroll position brings
    /// it into the accessibility snapshot.
    func scrollToForecastBucket(
        _ dayKey: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) {
        let query = app.descendants(matching: .any)
            .matching(identifier: "forecast.bucket.\(dayKey)")
        let scrollQuery = app.scrollViews.matching(identifier: "overview.statsContent")
        let scrollView = scrollQuery.element(boundBy: 0)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if query.count == 1 {
                let bucket = query.element(boundBy: 0)
                if bucket.exists,
                   !bucket.frame.isEmpty,
                   scrollQuery.count == 1,
                   scrollView.exists,
                   scrollView.frame.intersects(bucket.frame),
                   bucket.isHittable {
                    return
                }
            }
            if scrollQuery.count == 1, scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        XCTAssertEqual(query.count, 1, "forecast.bucket.\(dayKey) must materialize after scrolling", file: file, line: line)
        XCTAssertTrue(
            query.element(boundBy: 0).exists && query.element(boundBy: 0).isHittable,
            "forecast.bucket.\(dayKey) must be hittable after scrolling the production Overview ScrollView",
            file: file,
            line: line
        )
    }

    var overview: XCUIElement { element(identifier: "overview") }
    var calendar: XCUIElement { element(identifier: "calendar") }
    var forecast: XCUIElement { element(identifier: "overview.forecast") }
    var forecastCard: XCUIElement { element(identifier: "overview.forecast.card") }

    func metric(_ name: String) -> XCUIElement {
        element(identifier: "overview.metric.\(name)")
    }

    private func forecastBucketQuery(_ dayKey: String) -> XCUIElementQuery {
        forecastCard
            .descendants(matching: .any)
            .matching(identifier: "forecast.bucket.\(dayKey)")
    }

    func forecastBucket(
        _ dayKey: String,
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) -> XCUIElement {
        let query = forecastBucketQuery(dayKey)
        XCTAssertEqual(
            query.count,
            1,
            "forecast.bucket.\(dayKey) must resolve to exactly one live AX element",
            file: file,
            line: line
        )
        return query.element
    }

    func assertOverviewAccessibilityHierarchy(
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) {
        let overviewQuery = elements(identifier: "overview")
        // Do not call the exact-one page getter before the container has been
        // materialized. SwiftUI can publish the Overview identifier between
        // accessibility snapshots; waiting on the query-bound element keeps
        // this readiness check side-effect free and lets cardinality be
        // asserted against the fresh query afterwards.
        let overviewElement = overviewQuery.element(boundBy: 0)
        XCTAssertTrue(
            overviewElement.waitForExistence(timeout: 10),
            "overview must materialize before hierarchy assertions",
            file: file,
            line: line
        )
        XCTAssertEqual(overviewQuery.count, 1, "overview must be a unique live AX ancestor", file: file, line: line)
    }

    func assertUniqueForecastContract(
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) {
        for (identifier, element) in [
            ("overview.forecast", forecast),
            ("overview.forecast.card", forecastCard),
        ] {
            XCTAssertEqual(elements(identifier: identifier).count, 1, "\(identifier) must be unique", file: file, line: line)
            element.assertExists(timeout: 10, file: file, line: line)
        }

        let bucketQuery = forecastCard
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH[c] %@", "forecast.bucket."))
        XCTAssertGreaterThan(bucketQuery.count, 0, "forecast must expose at least one bucket", file: file, line: line)
        for bucket in bucketQuery.allElementsBoundByIndex {
            XCTAssertEqual(
                elements(identifier: bucket.identifier).count,
                1,
                "\(bucket.identifier) must be globally unique",
                file: file,
                line: line
            )
        }
    }

    func assertForecastContainsCount(
        _ count: String,
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) {
        let buckets = forecastCard
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH[c] %@", "forecast.bucket."))
            .allElementsBoundByIndex
        XCTAssertTrue(
            buckets.contains { ($0.value as? String)?.contains(count) == true },
            "forecast must expose a bucket with count \(count)",
            file: file,
            line: line
        )
    }

    func assertMetric(_ name: String, value: String, file: StaticString = #filePath, line: UInt = UInt(#line)) {
        let query = elements(identifier: "overview.metric.\(name)")
        let element = metric(name)
        element.assertExists(timeout: 10, file: file, line: line)
        XCTAssertEqual(query.count, 1, "overview.metric.\(name) must be globally unique", file: file, line: line)
        XCTAssertEqual(
            overview.descendants(matching: .any).matching(identifier: "overview.metric.\(name)").count,
            1,
            "overview.metric.\(name) must be a live descendant of overview",
            file: file,
            line: line
        )
        XCTAssertEqual(element.value as? String, value, file: file, line: line)
    }

    func assertMetricCardsHaveUniformGeometry(
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) {
        let cards = ["totalCards", "reviewedToday", "dueToday"].map { metric($0) }
        for (name, card) in zip(["totalCards", "reviewedToday", "dueToday"], cards) {
            card.assertExists(timeout: 10, file: file, line: line)
            XCTAssertFalse(card.frame.isEmpty, "overview.metric.\(name) must expose a rendered frame", file: file, line: line)
        }

        let heights = cards.map { $0.frame.height }
        let tops = cards.map { $0.frame.minY }
        XCTAssertLessThan(
            (heights.max() ?? 0) - (heights.min() ?? 0),
            1,
            "overview metric cards must share one row height; a wrapped number changes the card geometry",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            (tops.max() ?? 0) - (tops.min() ?? 0),
            1,
            "overview metric cards must share one top edge",
            file: file,
            line: line
        )
    }

    func forecastRange(_ days: Int) -> XCUIElement {
        element(identifier: "overview.forecast.range.\(days)")
    }

    func scrollToForecastRange(
        _ days: Int,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) {
        let query = elements(identifier: "overview.forecast.range.\(days)")
        let scrollQuery = app.scrollViews.matching(identifier: "overview.statsContent")
        let scrollView = scrollQuery.element(boundBy: 0)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if query.count == 1 {
                let range = query.element(boundBy: 0)
                if range.exists,
                   !range.frame.isEmpty,
                   scrollQuery.count == 1,
                   scrollView.exists,
                   scrollView.frame.intersects(range.frame),
                   range.isHittable {
                    return
                }
            }
            if scrollQuery.count == 1, scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        XCTAssertEqual(query.count, 1, "overview.forecast.range.\(days) must materialize after scrolling", file: file, line: line)
        XCTAssertTrue(
            query.element(boundBy: 0).exists && query.element(boundBy: 0).isHittable,
            "overview.forecast.range.\(days) must be hittable after scrolling",
            file: file,
            line: line
        )
    }

    @discardableResult
    func selectForecastRange(
        _ days: Int,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) -> Self {
        forecastRange(days).tapWhenReady(file: file, line: line)
        XCTAssertTrue(
            waitUntilForecastRangeSelected(days, timeout: timeout),
            "overview.forecast.range.\(days) must expose selected state after selection",
            file: file,
            line: line
        )
        return self
    }

    /// SwiftUI may publish the chip's `.isSelected` trait after its state
    /// mutation has already made the button hittable. Re-resolve the AX query
    /// on every poll so this helper never asserts against a stale snapshot.
    @discardableResult
    private func waitUntilForecastRangeSelected(
        _ days: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let query = elements(identifier: "overview.forecast.range.\(days)")
            if query.count == 1 {
                let candidate = query.element(boundBy: 0)
                if candidate.exists, candidate.isHittable, candidate.isSelected {
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let query = elements(identifier: "overview.forecast.range.\(days)")
        guard query.count == 1 else { return false }
        let candidate = query.element(boundBy: 0)
        return candidate.exists && candidate.isHittable && candidate.isSelected
    }

    var metrics: XCUIElement { element(identifier: "metrics") }
    var statsContent: XCUIElement { element(identifier: "overview.statsContent") }
    var forecastChart: XCUIElement { element(identifier: "overview.forecast.chart") }
    var forecastZero: XCUIElement { element(identifier: "forecast-zero") }
    var forecastZeroCounterexample: XCUIElement { element(identifier: "forecast-zero-counterexample") }
    var largeCounts: XCUIElement { element(identifier: "large-counts") }

    func assertStatsAccessibilityHierarchy(
        file: StaticString = #filePath,
        line: UInt = UInt(#line)
    ) {
        let statsQuery = elements(identifier: "overview.statsContent")
        statsContent.assertExists(timeout: 10, file: file, line: line)
        XCTAssertEqual(statsQuery.count, 1, "overview.statsContent must be unique", file: file, line: line)
        XCTAssertEqual(
            overview.descendants(matching: .any).matching(identifier: "overview.statsContent").count,
            1,
            "overview.statsContent must be a descendant of overview",
            file: file,
            line: line
        )
    }

    func assertIsActive(file: StaticString = #filePath, line: UInt = UInt(#line)) {
        let navBar = exactlyOne(app.navigationBars, "overview navigation bar", file: file, line: line)
        navBar.assertExists(timeout: 3, file: file, line: line)
    }
}


/// Page Object for Review Calendar. All selectors are identifiers owned by
/// the app surface; no localized labels are used for navigation or assertions.
struct ReviewCalendarPage {
    let app: XCUIApplication

    var monthHeader: XCUIElement {
        // SwiftUI may materialize the identifier-bearing Text as `Other`
        // inside the calendar composition; the identifier is the stable
        // contract, not the UIKit-backed accessibility type.
        exactlyOne(
            app.descendants(matching: .any).matching(identifier: "reviewCalendar.monthHeader"),
            "reviewCalendar.monthHeader"
        )
    }

    var previousMonthButton: XCUIElement {
        exactlyOne(app.buttons.matching(identifier: "reviewCalendar.previousMonth"), "reviewCalendar.previousMonth")
    }

    var nextMonthButton: XCUIElement {
        exactlyOne(app.buttons.matching(identifier: "reviewCalendar.nextMonth"), "reviewCalendar.nextMonth")
    }

    var selectedDay: XCUIElement {
        exactlyOne(app.buttons.matching(identifier: "reviewCalendar.selectedDay"), "reviewCalendar.selectedDay")
    }

    var emptyDayDetail: XCUIElement {
        exactlyOne(
            app.descendants(matching: .any).matching(identifier: "reviewCalendar.emptyDayDetail"),
            "reviewCalendar.emptyDayDetail"
        )
    }

    var emptyDaySummary: XCUIElement {
        exactlyOne(
            app.descendants(matching: .any).matching(identifier: "reviewCalendar.emptyDaySummary"),
            "reviewCalendar.emptyDaySummary"
        )
    }

    var populatedDayDetail: XCUIElement {
        exactlyOne(
            app.descendants(matching: .any).matching(identifier: "reviewCalendar.populatedDayDetail"),
            "reviewCalendar.populatedDayDetail"
        )
    }

    var populatedDaySummary: XCUIElement {
        exactlyOne(
            app.descendants(matching: .any).matching(identifier: "reviewCalendar.populatedDaySummary"),
            "reviewCalendar.populatedDaySummary"
        )
    }

    var installedFixtureProof: XCUIElement {
        exactlyOne(
            app.descendants(matching: .any).matching(identifier: "reviewCalendar.installedFixture"),
            "reviewCalendar.installedFixture"
        )
    }

    var runtimeGeometry: XCUIElement {
        exactlyOne(
            app.descendants(matching: .any).matching(identifier: "reviewCalendar.runtimeGeometry"),
            "reviewCalendar.runtimeGeometry"
        )
    }

    func day(_ key: String) -> XCUIElement {
        exactlyOne(
            app.buttons.matching(identifier: "reviewCalendar.day.\(key)"),
            "reviewCalendar.day.\(key)"
        )
    }
}

private func exactlyOne(
    _ query: XCUIElementQuery,
    _ label: String,
    file: StaticString = #filePath,
    line: UInt = UInt(#line)
) -> XCUIElement {
    let element = query.element(boundBy: 0)
    _ = element.waitUntilExists(timeout: 5)
    XCTAssertEqual(
        query.count,
        1,
        "\(label) must resolve exactly one element; duplicates are invalid",
        file: file,
        line: line
    )
    return element
}
