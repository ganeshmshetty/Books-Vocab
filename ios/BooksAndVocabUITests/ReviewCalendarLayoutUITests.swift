//
//  ReviewCalendarLayoutUITests.swift
//  Books & Vocab UI Tests
//
//  Layout contract for the Review Calendar month grid (#2861): every day
//  cell must be the same square frame. A content-height label under a
//  maxWidth frame lets rows drift in height, so this asserts geometry rather
//  than appearance.
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
        let app = launchIsolatedApp(fixtures: [.authSignedIn, .reviewCalendarDense])
        let overview = AppPage(app: app).goToOverview()
        XCTAssertTrue(app.waitForNavigationToSettle())
        overview.scrollToReviewCalendarButton()
        overview.reviewCalendarButton.tapWhenReady()

        let calendar = ReviewCalendarPage(app: app)
        XCTAssertTrue(
            calendar.monthHeader.waitUntilExists(timeout: 10),
            "Review Calendar must open before measuring day cells"
        )

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
}
