//
//  ToastPillMigrationUITests.swift
//  Books & Vocab UI Tests
//
//  #2047：暫時性提示改頂端 pill、承載操作的狀態留在畫面內面板（docs/sop/ui-design.md
//  「暫時性提示」）。這裡鎖住「進頁自動載入失敗只顯示面板、不彈 pill」：面板就是第一眼，
//  pill 若每次進頁重複出現就是噪音。使用者操作後的失敗 pill 由 AddLinkSheetUXUITests 覆蓋。
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
}
