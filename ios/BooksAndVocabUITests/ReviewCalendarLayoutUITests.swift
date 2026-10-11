//
//  ReviewCalendarLayoutUITests.swift
//  Books & Vocab UI Tests
//
//  Layout contract for the Review Calendar month grid (#2861): every day
//  cell must be the same square frame, and each column must sit under its
//  weekday header. A content-height label under a maxWidth frame lets rows
//  drift in height, and a blank leading cell that shifts the grid breaks the
//  column alignment, so this asserts geometry rather than appearance.
//

import XCTest

final class ReviewCalendarLayoutUITests: UITestCase {
    /// Half a point absorbs sub-pixel rounding of SwiftUI layout frames.
    private let tolerance: CGFloat = 0.5

    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 240
    }

    @MainActor
    func testCalendarDayCellsShareOneSquareFrame() throws {
        let calendar = try openReviewCalendar(extraArgs: [])
        let frames = calendar.dayCellFrames()
        // A month has at least 28 days; fewer addressable cells means the grid did not render.
        XCTAssertGreaterThanOrEqual(frames.count, 28, "calendar must expose every day cell (found \(frames.count))")

        let reference = try XCTUnwrap(frames.first)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(
                frame.width, reference.width, accuracy: tolerance,
                "day cell \(index) width must match the grid (frame=\(frame), reference=\(reference))"
            )
            XCTAssertEqual(
                frame.height, reference.height, accuracy: tolerance,
                "day cell \(index) height must match the grid (frame=\(frame), reference=\(reference))"
            )
            XCTAssertEqual(
                frame.width, frame.height, accuracy: tolerance,
                "day cell \(index) must be square (frame=\(frame))"
            )
        }
    }

    /// Regression guard only: flush cells keep their column-centre midX even
    /// before the #2861 fix, so this is not the discriminating test for it
    /// (that is `testCalendarDayCellsShareOneSquareFrame`).
    @MainActor
    func testCalendarDayCellsAlignUnderWeekdayHeaders() throws {
        try assertDayCellsAlignUnderWeekdayHeaders(openReviewCalendar(extraArgs: []), context: "opening month")
    }

    /// Regression guard (see above) at the largest accessibility category,
    /// plus content containment: the day number and its 5pt activity dot
    /// must stay inside the square cell frame.
    @MainActor
    func testCalendarDayCellsAlignUnderWeekdayHeadersAtAccessibility3() throws {
        try assertDayCellsAlignUnderWeekdayHeaders(openReviewCalendar(extraArgs: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]), context: "opening month at AX3")
    }

    @MainActor
    func testCalendarDayContentFitsCellAtAccessibility3() throws {
        let calendar = try openReviewCalendar(extraArgs: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        let contents = calendar.dayCellContents()
        XCTAssertGreaterThanOrEqual(contents.count, 28, "calendar must expose every day cell (found \(contents.count))")
        // Dot is 5pt below a 1pt gap under the number; it is not addressable, so bound it by the text.
        let dotExtent: CGFloat = 6
        var textsSeen = 0
        for (index, content) in contents.enumerated() {
            let bounds = content.cell.insetBy(dx: -tolerance, dy: -tolerance)
            for text in content.texts {
                textsSeen += 1
                XCTAssertTrue(bounds.contains(text), "day number of cell \(index) overflows (text=\(text), cell=\(content.cell))")
                XCTAssertLessThanOrEqual(
                    text.maxY + dotExtent, bounds.maxY,
                    "activity dot of cell \(index) would overflow the cell (text=\(text), cell=\(content.cell))"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(textsSeen, 28, "day numbers must be addressable inside cells (found \(textsSeen))")
    }

    /// The leading-blank count (Monday-first offset 0...6) is the only thing
    /// that changes the grid's column phase, and the opening month fixes just
    /// one of those seven. Walk back month by month, checking each rendered
    /// grid, until every offset has been observed.
    @MainActor
    func testCalendarLeadingBlankOffsetsAlignForEveryMonthPhase() throws {
        let calendar = try openReviewCalendar(extraArgs: [])
        var observedOffsets = Set<Int>()
        for step in 0 ..< 24 {
            let offset = try XCTUnwrap(calendar.leadingBlankOffset(), "first day cell must be addressable at step \(step)")
            observedOffsets.insert(offset)
            assertDayCellsAlignUnderWeekdayHeaders(calendar, context: "month step \(step) offset \(offset)")
            if observedOffsets.count == 7 { break }

            let before = calendar.monthHeader.label
            _ = calendar.previousMonthButton.tapWhenReady()
            let changed = NSPredicate(format: "label != %@", before)
            let waiter = XCTNSPredicateExpectation(predicate: changed, object: calendar.monthHeader)
            XCTAssertEqual(XCTWaiter().wait(for: [waiter], timeout: 5), .completed, "month header must advance from \(before)")
        }
        XCTAssertEqual(observedOffsets, Set(0 ... 6), "walked months must cover every leading-blank offset")
    }

    @MainActor
    private func assertDayCellsAlignUnderWeekdayHeaders(_ calendar: ReviewCalendarPage, context: String) {
        let headers = calendar.weekdayHeaderFrames()
        XCTAssertEqual(headers.count, 7, "weekday header must expose all seven columns (found \(headers.count))")
        let columnCenters = headers.map(\.midX)

        let frames = calendar.dayCellFrames()
        XCTAssertGreaterThanOrEqual(frames.count, 28, "calendar must expose every day cell (found \(frames.count))")

        var distinctCenters: [CGFloat] = []
        for (index, frame) in frames.enumerated() {
            guard let nearest = columnCenters.min(by: { abs($0 - frame.midX) < abs($1 - frame.midX) }) else {
                XCTFail("no weekday column centers available (\(context))")
                return
            }
            XCTAssertEqual(
                frame.midX, nearest, accuracy: tolerance,
                "day cell \(index) midX must sit under a weekday column (\(context), frame=\(frame), columns=\(columnCenters))"
            )
            if !distinctCenters.contains(where: { abs($0 - frame.midX) <= tolerance }) {
                distinctCenters.append(frame.midX)
            }
        }
        XCTAssertEqual(
            distinctCenters.count, 7,
            "day cells must occupy exactly seven columns (\(context), distinct midX=\(distinctCenters.sorted()))"
        )

        // Cells in the same row must not overlap at larger text sizes.
        for (index, frame) in frames.enumerated() {
            for (otherIndex, other) in frames.enumerated() where otherIndex > index {
                let intersection = frame.intersection(other)
                XCTAssertTrue(
                    intersection.isNull || intersection.width * intersection.height <= tolerance,
                    "day cells \(index) and \(otherIndex) overlap (\(context), frames=\(frame), \(other))"
                )
            }
        }
    }

    @MainActor
    private func openReviewCalendar(extraArgs: [String]) throws -> ReviewCalendarPage {
        let app = launchIsolatedApp(extraArgs: extraArgs, fixtures: [.authSignedIn, .reviewCalendarDense])
        let overview = AppPage(app: app).goToOverview()
        XCTAssertTrue(app.waitForNavigationToSettle())
        overview.scrollToReviewCalendarButton()
        overview.reviewCalendarButton.tapWhenReady()

        let calendar = ReviewCalendarPage(app: app)
        XCTAssertTrue(
            calendar.monthHeader.waitUntilExists(timeout: 10),
            "Review Calendar must open before measuring day cells"
        )
        return calendar
    }
}
