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

    @MainActor
    func testCalendarDayCellsAlignUnderWeekdayHeaders() throws {
        try assertDayCellsAlignUnderWeekdayHeaders(extraArgs: [])
    }

    /// Accessibility3 text sizes are where the leading-blank row and the
    /// content-driven height both break first, so the same contract runs
    /// at the largest accessibility category.
    @MainActor
    func testCalendarDayCellsAlignUnderWeekdayHeadersAtAccessibility3() throws {
        try assertDayCellsAlignUnderWeekdayHeaders(extraArgs: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ])
    }

    @MainActor
    private func assertDayCellsAlignUnderWeekdayHeaders(extraArgs: [String]) throws {
        let calendar = try openReviewCalendar(extraArgs: extraArgs)

        let headers = calendar.weekdayHeaderFrames()
        XCTAssertEqual(headers.count, 7, "weekday header must expose all seven columns (found \(headers.count))")
        let columnCenters = headers.map(\.midX)

        let frames = calendar.dayCellFrames()
        XCTAssertGreaterThanOrEqual(frames.count, 28, "calendar must expose every day cell (found \(frames.count))")

        var distinctCenters: [CGFloat] = []
        for (index, frame) in frames.enumerated() {
            let nearest = try XCTUnwrap(
                columnCenters.min(by: { abs($0 - frame.midX) < abs($1 - frame.midX) }),
                "no weekday column centers available"
            )
            XCTAssertEqual(
                frame.midX, nearest, accuracy: tolerance,
                "day cell \(index) midX must sit under a weekday column (frame=\(frame), columns=\(columnCenters))"
            )
            if !distinctCenters.contains(where: { abs($0 - frame.midX) <= tolerance }) {
                distinctCenters.append(frame.midX)
            }
        }
        XCTAssertEqual(
            distinctCenters.count, 7,
            "day cells must occupy exactly seven columns (distinct midX=\(distinctCenters.sorted()))"
        )

        // Cells in the same row must not overlap at larger text sizes.
        for (index, frame) in frames.enumerated() {
            for (otherIndex, other) in frames.enumerated() where otherIndex > index {
                let intersection = frame.intersection(other)
                XCTAssertTrue(
                    intersection.isNull || intersection.width * intersection.height <= tolerance,
                    "day cells \(index) and \(otherIndex) overlap (frames=\(frame), \(other))"
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
