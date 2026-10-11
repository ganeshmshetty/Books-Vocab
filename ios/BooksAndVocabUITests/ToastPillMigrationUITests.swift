//
//  ToastPillMigrationUITests.swift
//  Books & Vocab UI Tests
//
//  #2047：暫時性提示改頂端 pill、承載操作的狀態留在畫面內面板（docs/sop/ui-design.md
//  「暫時性提示」）。這裡鎖住「進頁自動載入失敗只顯示面板、不彈 pill」：面板就是第一眼，
//  pill 若每次進頁重複出現就是噪音。使用者操作後的失敗 pill：AddLink 由 AddLinkSheetUXUITests、
//  WordDetail 封存由 WordDetailFlowUITests、單字本手動重試由本檔的第二則覆蓋。
//

import XCTest

final class ToastPillMigrationUITests: UITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 120
    }

    @MainActor
    func testPassiveExploreSyncFailureShowsRetryPanelWithoutPill() throws {
        let app = launchIsolatedApp(
            fixtures: [.explore("partial")],
            perfLog: "toast-pill-explore-partial"
        )
        app.tabBars.buttons
            .matching(identifier: "tab.explore.button")
            .firstMatch
            .tapWhenReady(timeout: 10)

        let page = AppPage(app: app)
        XCTAssertTrue(
            page.explorePartialState.waitUntilExists(timeout: 10),
            "a passive sync failure with cached decks renders the partial panel"
        )
        let retry = app.descendants(matching: .any)
            .matching(identifier: "explore.partialState.retry")
            .firstMatch
        XCTAssertTrue(retry.waitUntilExists(timeout: 5), "the panel keeps its retry action")

        let pill = app.descendants(matching: .any).matching(identifier: "app.toast").firstMatch
        XCTAssertFalse(
            pill.waitUntilExists(timeout: 2),
            "an automatic load failure must not post a pill; the panel is the only surface"
        )
        captureStep("toast-pill-explore-partial", app: app)
    }

    /// 單字本的自動載入失敗只留面板（可重試）；使用者按面板的重試、重試仍失敗，才另彈
    /// 一則 warning pill（KGVocabBanner.pill：refreshWasExplicit）。
    @MainActor
    func testExplicitVocabRetryFailurePostsWarningPillAfterSilentAutoLoad() throws {
        let app = launchIsolatedApp(
            fixtures: [.vocabulary("vocabLinkedCards")],
            extraEnvironment: ["KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"],
            perfLog: "toast-pill-vocab-retry"
        )
        let notebooks = AppPage(app: app).goToNotebooks()
        XCTAssertTrue(
            notebooks.waitForNotebookCard(id: Self.linkedCardsNotebookID, timeout: 10),
            "vocab linked-cards fixture must materialize its notebook"
        )
        notebooks.notebookCard(id: Self.linkedCardsNotebookID).tapWhenReady()

        let panel = app.descendants(matching: .any)
            .matching(identifier: "vocab.statusPanel").firstMatch
        XCTAssertTrue(
            panel.waitUntilExists(timeout: 15),
            "the automatic load failure keeps its retry panel (positive control)"
        )
        let pill = app.descendants(matching: .any).matching(identifier: "app.toast").firstMatch
        XCTAssertFalse(
            pill.waitUntilExists(timeout: 2),
            "an automatic load failure must not post a pill"
        )

        let retry = app.descendants(matching: .any)
            .matching(identifier: "vocab.statusPanel.retry").firstMatch
        XCTAssertTrue(retry.waitUntilExists(timeout: 5), "the panel keeps its retry action")
        retry.tapWhenReady()

        XCTAssertTrue(
            pill.waitUntilExists(timeout: 10),
            "a user-triggered retry that fails again must post a pill"
        )
        XCTAssertEqual(pill.value as? String, "warning", "the refresh failure pill uses the warning style")
        XCTAssertTrue(panel.waitUntilExists(timeout: 5), "the pill does not replace the retry panel")
        captureStep("toast-pill-vocab-retry", app: app)
    }

    private static let linkedCardsNotebookID = "ui-vocab-linked-cards-notebook"
}
