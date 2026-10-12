import XCTest

/// #2043: the link strip's "+N" is a control — it expands the group in place to
/// show every link and collapses it again. The multi-notebook deck's first card
/// has four links in one group, so two sit behind "+2".
final class TodayReviewLinkOverflowUITests: UITestCase {
    private static let group = "shares_usage"
    private static let linkPrefix = "multinb-"

    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 180
    }

    @MainActor
    private func revealedReview(_ app: XCUIApplication) -> TodayReviewPage? {
        let notebook = AppPage(app: app).goToNotebooks()
        guard notebook.reviewCTAButton.waitUntilExists(timeout: 10) else {
            captureStep("no-review-cta", app: app)
            XCTFail("fixture 有到期卡片，複習 CTA 必須出現")
            return nil
        }
        let review = notebook.startReview()
        guard review.progressLabel.waitUntilExists(timeout: 10),
              review.waitForFeedbackControls(timeout: 5) else {
            captureStep("review-not-started", app: app)
            XCTFail("tap CTA 後必須進入複習 session")
            return nil
        }
        review.flipCard()
        guard review.cardBack.waitUntilExists(timeout: 5) else {
            captureStep("card-back-missing", app: app)
            XCTFail("翻卡後必須看到背面")
            return nil
        }
        return review
    }

    @MainActor
    private func waitForDrawnLinkCount(
        _ review: TodayReviewPage,
        _ expected: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if review.drawnLinks(cardIDPrefix: Self.linkPrefix).count == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return review.drawnLinks(cardIDPrefix: Self.linkPrefix).count == expected
    }

    @MainActor
    func testPlusNExpandsEveryLinkAndCollapsesBack() throws {
        let app = launchIsolatedApp(fixtures: [.notebookReviewDeckMultiNotebook], perfLog: "review")
        guard let review = revealedReview(app) else { return }

        let toggle = review.linkOverflowToggle(group: Self.group)
        guard toggle.waitUntilExists(timeout: 10) else {
            captureStep("overflow-toggle-missing", app: app)
            XCTFail("四個連結、每組只顯示兩個 → 「+2」必須是可點的控制項")
            return
        }
        XCTAssertEqual(toggle.value as? String, "collapsed")
        XCTAssertEqual(toggle.label, "+2", "收合時顯示被藏起來的連結數")
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44, "收合控制項的觸控高度必須 >= 44pt (#3114)")
        XCTAssertTrue(waitForDrawnLinkCount(review, 2), "收合時組名旁只有兩個連結")
        captureStep("link-overflow-collapsed", app: app)

        toggle.tapWhenReady()
        XCTAssertTrue(waitForDrawnLinkCount(review, 4), "展開後四個連結都在畫面上")
        XCTAssertEqual(toggle.value as? String, "expanded")
        XCTAssertNotEqual(toggle.label, "+2", "展開後控制項改為收合文案")
        captureStep("link-overflow-expanded", app: app)

        toggle.tapWhenReady()
        XCTAssertTrue(waitForDrawnLinkCount(review, 2), "再點一次回到兩個連結")
        XCTAssertEqual(toggle.value as? String, "collapsed")
        XCTAssertEqual(toggle.label, "+2")
    }

    @MainActor
    func testExpansionDoesNotSurviveLeavingTheCard() throws {
        let app = launchIsolatedApp(fixtures: [.notebookReviewDeckMultiNotebook], perfLog: "review")
        guard let review = revealedReview(app) else { return }

        let toggle = review.linkOverflowToggle(group: Self.group)
        guard toggle.waitUntilExists(timeout: 10) else {
            XCTFail("「+2」控制項必須存在")
            return
        }
        toggle.tapWhenReady()
        XCTAssertTrue(waitForDrawnLinkCount(review, 4), "展開後四個連結都在畫面上")

        // Answering moves to the next card; the expansion belongs to the old one.
        review.tapRemembered()
        XCTAssertTrue(
            review.linkOverflowToggle(group: Self.group).waitUntilGone(timeout: 5),
            "下一張卡沒有連結，不能留著上一張的展開控制項"
        )
        XCTAssertEqual(review.drawnLinks(cardIDPrefix: Self.linkPrefix).count, 0)
    }
}
