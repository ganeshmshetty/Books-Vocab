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

    /// #3226：「+N」的命中帶不得與任何已畫出的連結 accessibility frame 相交（換行後會壓到上一列）。
    @MainActor
    private func assertToggleClearsDrawnLinks(
        _ toggle: XCUIElement,
        _ review: TodayReviewPage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for link in review.drawnLinks(cardIDPrefix: Self.linkPrefix).allElementsBoundByIndex where link.exists {
            XCTAssertFalse(
                toggle.frame.intersects(link.frame),
                "「+N」命中帶不得蓋到連結 \(link.identifier)",
                file: file,
                line: line
            )
        }
    }

    /// #3227：收合時 VoiceOver 讀「顯示其餘 N 個連結」，不讀符號「+N」。文案隨語系變動，只釘住隱藏數 N。
    @MainActor
    private func assertCollapsedLabelAnnouncesHidden(
        _ toggle: XCUIElement,
        _ hidden: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotEqual(toggle.label, "+\(hidden)", "收合時 VoiceOver 不讀符號「+N」(#3227)", file: file, line: line)
        XCTAssertTrue(toggle.label.contains("\(hidden)"), "收合時 a11y label 必須帶隱藏連結數 \(hidden)", file: file, line: line)
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
        assertCollapsedLabelAnnouncesHidden(toggle, 2)
        // #3226/#3253：命中帶不得越過列距（4pt），否則會蓋到上一列的連結。
        XCTAssertLessThanOrEqual(toggle.frame.height, 32, "命中帶高度由列距決定，不再是 44pt (#3226)")
        XCTAssertTrue(waitForDrawnLinkCount(review, 2), "收合時組名旁只有兩個連結")
        assertToggleClearsDrawnLinks(toggle, review)
        captureStep("link-overflow-collapsed", app: app)

        toggle.tapWhenReady()
        XCTAssertTrue(waitForDrawnLinkCount(review, 4), "展開後四個連結都在畫面上")
        assertToggleClearsDrawnLinks(toggle, review)
        XCTAssertEqual(toggle.value as? String, "expanded")
        XCTAssertNotEqual(toggle.label, "+2", "展開後控制項改為收合文案")
        captureStep("link-overflow-expanded", app: app)

        toggle.tapWhenReady()
        XCTAssertTrue(waitForDrawnLinkCount(review, 2), "再點一次回到兩個連結")
        XCTAssertEqual(toggle.value as? String, "collapsed")
        assertCollapsedLabelAnnouncesHidden(toggle, 2)
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
