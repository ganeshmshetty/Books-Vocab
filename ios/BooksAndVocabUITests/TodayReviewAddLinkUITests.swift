import XCTest

/// Review-mode Add Link: the sheet is bound to the card it was opened on (A1)
/// and a creation outlives its sheet as a pending item on the source card (C14).
///
/// The server URL points at a closed port so the flow stays hermetic. That makes
/// the creation fail fast, which exercises the *failed* pending item (visible,
/// retryable, removable only by the user). The `creating` -> real-link
/// transition needs a live operation and is covered by `AddLinkCreationHubTests`
/// at the hub level.
final class TodayReviewAddLinkUITests: UITestCase {
    private static let notebookCardID = "ui-review-notebook"
    private static let missingWord = "zzqxv"

    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 180
    }

    @MainActor
    private func startReview(_ app: XCUIApplication) -> TodayReviewPage? {
        let notebook = AppPage(app: app).goToNotebooks()
        guard notebook.notebookCard(id: Self.notebookCardID).waitUntilExists(timeout: 10) else {
            captureStep("no-notebook-card", app: app)
            XCTFail("varied review deck fixture 應種出單字本卡片 \(Self.notebookCardID)")
            return nil
        }
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
        return review
    }

    @MainActor
    private func openAddLinkSheet(_ app: XCUIApplication, review: TodayReviewPage) -> Bool {
        guard review.addLinkButton.waitUntilExists(timeout: 10) else { return false }
        review.addLinkButton.tapWhenReady()
        return app.textFields["addLink.searchField"].waitUntilExists(timeout: 10)
    }

    private func sourceWordLabel(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(identifier: "addLink.sourceWord").firstMatch.label
    }

    /// A1: autoplay must not advance the card under the sheet, and the sheet
    /// must keep naming the card it was opened on.
    @MainActor
    func testAddLinkSheetStaysBoundToOpenedCardWhileAutoplayIsPaused() throws {
        let app = launchIsolatedApp(
            fixtures: [.notebookReviewDeckVaried],
            extraEnvironment: ["KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"],
            perfLog: "review"
        )
        guard let review = startReview(app) else { return }
        guard review.waitForUnique("todayReview.autoplayToggle", timeout: 5) else {
            captureStep("autoplay-toggle-missing", app: app)
            XCTFail("autoplay toggle 必須存在")
            return
        }
        review.autoplayToggleButton.tap()
        guard review.waitForUnique("todayReview.autoplay.playing", timeout: 3) else {
            captureStep("autoplay-not-started", app: app)
            XCTFail("autoplay 必須進入播放狀態")
            return
        }

        guard openAddLinkSheet(app, review: review) else {
            captureStep("add-link-sheet-not-open", app: app)
            XCTFail("autoplay 翻到背面後必須能開啟 AddLink sheet")
            return
        }
        let openedLabel = sourceWordLabel(app)
        let openedProgress = review.progressText
        XCTAssertFalse(openedLabel.isEmpty, "sheet 必須顯示來源單字 (addLink.sourceWord)")
        captureStep("add-link-opened", app: app)

        // Longer than one autoplay advance interval: unpaused autoplay would have
        // moved to another card (and, before the fix, swapped the sheet's source).
        RunLoop.current.run(until: Date().addingTimeInterval(7))
        XCTAssertEqual(sourceWordLabel(app), openedLabel, "sheet 的來源單字不得隨 autoplay 改變")

        app.buttons["addLink.cancel"].tapWhenReady()
        XCTAssertTrue(app.textFields["addLink.searchField"].waitUntilGone(timeout: 5))
        XCTAssertTrue(
            review.waitForUnique("todayReview.autoplay.paused", timeout: 5),
            "開 sheet 必須暫停 autoplay，關閉後維持暫停"
        )
        XCTAssertEqual(review.progressText, openedProgress, "sheet 開著期間卡片不得前進")
        captureStep("add-link-closed-paused", app: app)
    }

    /// C14: closing the sheet mid-creation leaves a visible pending item on the
    /// source card; it opens a detail, can be retried, and is removed only by the
    /// user.
    @MainActor
    func testClosingSheetLeavesPendingItemThatSurvivesUntilUserRemovesIt() throws {
        let app = launchIsolatedApp(
            fixtures: [.notebookReviewDeckVaried],
            extraEnvironment: ["KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"],
            perfLog: "review"
        )
        guard let review = startReview(app) else { return }
        review.flipCard()
        guard review.cardBack.waitUntilExists(timeout: 5) else {
            captureStep("flip-no-back", app: app)
            XCTFail("翻卡後背面必須掛載")
            return
        }
        guard openAddLinkSheet(app, review: review) else {
            captureStep("add-link-sheet-not-open", app: app)
            XCTFail("背面必須能開啟 AddLink sheet")
            return
        }

        let searchField = app.textFields["addLink.searchField"]
        searchField.tapWhenReady()
        searchField.typeText(Self.missingWord)
        guard let create = app.buttons.matching(identifier: "addLink.create")
            .exactlyOneElement(timeout: 10, named: "AddLink create affordance") else {
            captureStep("create-missing", app: app)
            return
        }
        create.tapWhenReady()

        // Close without waiting for the outcome: the sheet no longer owns the job.
        app.buttons["addLink.cancel"].tapWhenReady()
        XCTAssertTrue(searchField.waitUntilGone(timeout: 5))

        let pending = review.pendingLink(word: Self.missingWord)
        guard pending.waitUntilExists(timeout: 10) else {
            captureStep("pending-item-missing", app: app)
            XCTFail("關閉 sheet 後來源卡必須出現 todayReview.card.link.pending.<word>")
            return
        }
        // Closed port: the operation fails fast, but it must stay visible as failed.
        XCTAssertTrue(
            review.pendingLinkStripStatus("failed").waitUntilExists(timeout: 30),
            "建立失敗時項目必須以 identifier 暴露失敗狀態，不得無聲消失"
        )
        // The strip item must not expose a raw English state token to VoiceOver.
        XCTAssertNotEqual(pending.value as? String, "failed", "strip 項目不得以原始英文 token 作為 accessibilityValue")
        captureStep("pending-item-failed", app: app)

        pending.tapWhenReady()
        guard review.pendingLinkDetail.waitUntilExists(timeout: 5) else {
            captureStep("pending-detail-missing", app: app)
            XCTFail("點擊建立中項目必須顯示說明，而不是靜默無反應")
            return
        }
        XCTAssertTrue(review.pendingLinkDetailStatus("failed").waitUntilExists(timeout: 3), "失敗狀態必須以 identifier 暴露")
        XCTAssertTrue(review.pendingLinkRetryButton.waitUntilExists(timeout: 3), "失敗必須有重試入口")
        captureStep("pending-detail-failed", app: app)

        review.pendingLinkRetryButton.tapWhenReady()
        // The retry re-enters the creation path; against a closed port it fails again.
        XCTAssertTrue(
            review.pendingLinkDetailStatus("failed").waitUntilExists(timeout: 30),
            "重試後仍失敗時必須回到失敗狀態，並保留重試入口"
        )

        review.pendingLinkDismissButton.tapWhenReady()
        XCTAssertTrue(review.pendingLinkDetail.waitUntilGone(timeout: 5))
        XCTAssertTrue(
            pending.waitUntilGone(timeout: 5),
            "只有使用者按「移除」才可讓失敗項目消失"
        )
    }
}
