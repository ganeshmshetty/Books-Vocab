import XCTest

/// Add Link sheet UX contracts (#2031, #2037, #2038, #2039) on the
/// `vocabLinkedCards` UI World: source `serendipity`, linkable `epiphany`,
/// `fortuitous`, `fortunate`, `revelation`, `happy accident`.
///
/// The server is the unreachable port-9 default, so any network mutation the
/// sheet starts fails fast and deterministically; tests assert on which
/// mutation started, never on a success the backend would have to provide.
final class AddLinkSheetUXUITests: UITestCase {
    private static let notebookID = "ui-vocab-linked-cards-notebook"

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - #2031

    @MainActor
    func testAddLinkSearchFieldIsFocusedWhenSheetOpens() throws {
        guard let app = openAddLinkSheet(perfLog: "add-link-autofocus") else { return }
        let searchField = app.textFields["addLink.searchField"]

        XCTAssertTrue(
            searchField.waitUntilValue(hasKeyboardFocus: true, timeout: 5),
            "opening Add Link must focus the search field without an extra tap"
        )
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilExists(timeout: 5), "keyboard must be up")
        // Typing without tapping the field proves the focus is real.
        app.typeText("fort")
        XCTAssertEqual(searchField.value as? String, "fort")
        XCTAssertTrue(lookupState(in: app).waitUntilValueEquals("results-2", timeout: 5))
        captureStep("add-link-autofocus", app: app)
    }

    // MARK: - #2038 Return key

    /// Nothing in the notebook has the word: Return puts the keyboard away and
    /// flashes the create entry, but never starts a creation.
    @MainActor
    func testReturnOnUnknownWordRevealsCreateAndNeverCreates() throws {
        guard let app = openAddLinkSheet(perfLog: "add-link-return-unknown") else { return }
        let searchField = app.textFields["addLink.searchField"]
        XCTAssertTrue(searchField.waitUntilValue(hasKeyboardFocus: true, timeout: 5))
        app.typeText("zzqxv")
        guard app.buttons.matching(identifier: "addLink.create")
            .exactlyOneElement(timeout: 5, named: "AddLink create entry") != nil else { return }
        XCTAssertTrue(
            marker("addLink.return.action", in: app).waitUntilValueEquals("revealCreate", timeout: 5),
            "an unknown word must announce Return as reveal-create, never create"
        )

        app.typeText("\n")
        // The flash lasts ~1.4s but XCUITest's idle wait plus a snapshot take longer
        // on a loaded simulator (#2885), so assert the latched pulse count, not "on".
        XCTAssertTrue(
            marker("addLink.create.highlightPulses", in: app).waitUntilValueEquals("1", timeout: 5),
            "Return on an unknown word must point at the create entry"
        )
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "Return must put the keyboard away")
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "addLink.creation.progress").count,
            0,
            "Return must never start a creation"
        )
        XCTAssertEqual(searchField.value as? String, "zzqxv", "the typed word stays")
        XCTAssertTrue(
            marker("addLink.create.highlight", in: app).waitUntilValueEquals("off", timeout: 5),
            "the highlight is brief"
        )
        captureStep("add-link-return-unknown", app: app)
    }

    /// Partial matches (even when several): Return only dismisses the keyboard;
    /// nothing is linked or created.
    @MainActor
    func testReturnOnPartialMatchesOnlyDismissesKeyboard() throws {
        guard let app = openAddLinkSheet(perfLog: "add-link-return-partial") else { return }
        XCTAssertTrue(app.textFields["addLink.searchField"].waitUntilValue(hasKeyboardFocus: true, timeout: 5))
        app.typeText("fort")
        XCTAssertTrue(lookupState(in: app).waitUntilValueEquals("results-2", timeout: 5))
        XCTAssertTrue(
            marker("addLink.return.action", in: app).waitUntilValueEquals("dismissKeyboard", timeout: 5),
            "partial matches must announce Return as dismiss-keyboard"
        )

        app.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "Return must put the keyboard away")
        XCTAssertTrue(lookupState(in: app).waitUntilValueEquals("results-2", timeout: 5), "the list stays")
        XCTAssertEqual(marker("addLink.row.returnHint", in: app).exists, false, "no row is singled out")
        XCTAssertEqual(marker("addLink.error.reason", in: app).exists, false, "nothing was sent")
        XCTAssertEqual(marker("addLink.creation.progress", in: app).exists, false)
    }

    /// An exactly-typed linkable word shows the ↵ hint on its row and Return
    /// links it. The unreachable server fails the link, so the existing-word
    /// failure banner is the evidence that THIS path (not creation) ran.
    @MainActor
    func testReturnOnExactWordLinksThatWord() throws {
        guard let app = openAddLinkSheet(perfLog: "add-link-return-exact") else { return }
        XCTAssertTrue(app.textFields["addLink.searchField"].waitUntilValue(hasKeyboardFocus: true, timeout: 5))
        app.typeText("epiphany")
        XCTAssertTrue(
            marker("addLink.row.returnHint", in: app).waitUntilExists(timeout: 5),
            "the row Return will link shows the ↵ hint"
        )
        XCTAssertTrue(
            marker("addLink.return.action", in: app).waitUntilValueEquals("linkExact", timeout: 5),
            "the exact word must announce Return as link-exact"
        )

        app.typeText("\n")
        XCTAssertTrue(
            marker("addLink.error.reason", in: app).waitUntilExists(timeout: 10),
            "Return on the exact word starts the existing-word link"
        )
        XCTAssertTrue(
            marker("addLink.creation.progress", in: app).waitUntilExists(timeout: 5),
            "linking an existing word runs under the creation progress pipeline (#3115)"
        )
        captureStep("add-link-return-exact", app: app)
    }

    // MARK: - #2047 pill + panel

    /// A failed link is an outcome the user just caused: the panel keeps the retry
    /// action, one error pill announces it, and a retry that fails again replaces
    /// that pill rather than stacking a second one.
    @MainActor
    func testFailedLinkPostsOneErrorPillAndKeepsRetryPanel() throws {
        guard let app = openAddLinkSheet(perfLog: "add-link-failed-pill") else { return }
        XCTAssertTrue(app.textFields["addLink.searchField"].waitUntilValue(hasKeyboardFocus: true, timeout: 5))
        app.typeText("epiphany")
        XCTAssertTrue(marker("addLink.row.returnHint", in: app).waitUntilExists(timeout: 5))
        app.typeText("\n")
        XCTAssertTrue(
            marker("addLink.error.reason", in: app).waitUntilExists(timeout: 10),
            "Return on the exact word fails against the unreachable server"
        )

        let pill = app.descendants(matching: .any).matching(identifier: "app.toast").firstMatch
        XCTAssertTrue(pill.waitUntilExists(timeout: 5), "a user-triggered link failure must post a pill")
        XCTAssertEqual(pill.value as? String, "error", "the failure pill uses the error style")

        let retry = marker("addLink.creation.retry", in: app)
        XCTAssertTrue(retry.waitUntilExists(timeout: 5), "the failure panel keeps the retry action")
        retry.tapWhenReady()
        XCTAssertTrue(marker("addLink.error.reason", in: app).waitUntilExists(timeout: 10))
        XCTAssertLessThanOrEqual(
            app.descendants(matching: .any).matching(identifier: "app.toast").count,
            1,
            "a repeated failure replaces the pill, never stacks"
        )
        captureStep("add-link-failed-pill", app: app)
    }

    // MARK: - #3111 打開卡片 return path

    /// 打開卡片 presents the word detail over the sheet (#3111), so the query and
    /// its result list must survive the round trip back.
    @MainActor
    func testOpenCardReturnKeepsAddLinkQuery() throws {
        guard let app = openAddLinkSheet(perfLog: "add-link-open-card-return") else { return }
        let searchField = app.textFields["addLink.searchField"]
        XCTAssertTrue(searchField.waitUntilValue(hasKeyboardFocus: true, timeout: 5))
        app.typeText("fort")
        XCTAssertTrue(lookupState(in: app).waitUntilValueEquals("results-2", timeout: 5))

        // The serendipity detail that opened this sheet stays beneath it and keeps its hero in the
        // AX tree, so existence proves nothing: the presentation is a +1 step in the hero count.
        let heroBaseline = heroWordCount(in: app)
        let openCard = app.buttons
            .matching(NSPredicate(format: "label == %@", "打開卡片"))
            .firstMatch
        XCTAssertTrue(openCard.waitUntilExists(timeout: 5), "a collapsed row must expose 打開卡片")
        openCard.tapWhenReady()
        XCTAssertTrue(
            waitUntilHeroWordCount(heroBaseline + 1, in: app, timeout: 10),
            "打開卡片 must present the word detail over the sheet"
        )

        // The detail is the topmost sheet; its close control is the last hittable 關閉.
        let close = topmostHittableClose(in: app, timeout: 5)
        XCTAssertNotNil(close, "the presented word detail must expose a hittable 關閉")
        close?.tap()
        XCTAssertTrue(
            waitUntilHeroWordCount(heroBaseline, in: app, timeout: 10),
            "closing the detail must return to the sheet"
        )

        XCTAssertTrue(app.textFields["addLink.searchField"].waitUntilExists(timeout: 5))
        XCTAssertEqual(searchField.value as? String, "fort", "the query must survive 打開卡片 and return")
        XCTAssertTrue(
            lookupState(in: app).waitUntilValueEquals("results-2", timeout: 5),
            "the result list must survive 打開卡片 and return"
        )
        captureStep("add-link-open-card-return", app: app)
    }

    // MARK: - Helpers

    /// Launches the linked-cards world, opens `serendipity`'s detail and its
    /// Add Link sheet. Returns nil after recording a failure.
    @MainActor
    func openAddLinkSheet(
        extraEnvironment: [String: String] = [:],
        perfLog: String
    ) -> XCUIApplication? {
        let app = launchIsolatedApp(
            fixtures: [.vocabulary("vocabLinkedCards")],
            extraEnvironment: extraEnvironment,
            perfLog: perfLog
        )
        let notebooks = AppPage(app: app).goToNotebooks()
        guard notebooks.waitForNotebookCard(id: Self.notebookID, timeout: 10) else {
            XCTFail("AddLink fixture 必須種出 notebook " + Self.notebookID)
            return nil
        }
        notebooks.notebookCard(id: Self.notebookID).tapWhenReady()
        XCTAssertTrue(app.waitForNavigationToSettle())

        let page = VocabularySearchPage(app: app)
        guard page.searchField.waitUntilExists(timeout: 10) else {
            XCTFail("AddLink fixture 必須渲染 vocabulary search field")
            return nil
        }
        page.search("serendipity")
        guard page.waitForRowMaterialized(word: "serendipity", timeout: 10) else {
            XCTFail("AddLink fixture 必須 materialize source row serendipity")
            return nil
        }
        page.row(word: "serendipity").tapWhenReady()

        guard let trigger = app.buttons
            .matching(NSPredicate(format: "identifier == %@", "wordDetail.card.addLink"))
            .exactlyOneElement(timeout: 10, named: "AddLink detail trigger") else {
            return nil
        }
        trigger.tapWhenReady()
        guard app.textFields["addLink.searchField"].waitUntilExists(timeout: 5) else {
            XCTFail("word detail 必須開啟 AddLink sheet")
            return nil
        }
        return app
    }

    func lookupState(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "addLink.lookup.state").firstMatch
    }

    func marker(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Word-detail heroes in the AX tree. Count them: a stacked detail keeps its hero alive beneath.
    func heroWordCount(in app: XCUIApplication) -> Int {
        app.staticTexts.matching(identifier: "cardDocument.hero.word").count
    }

    func waitUntilHeroWordCount(_ expected: Int, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if heroWordCount(in: app) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return heroWordCount(in: app) == expected
    }

    /// The topmost sheet's 關閉 is the last hittable one; it can trail the hero while the sheet animates in.
    func topmostHittableClose(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidate = app.buttons
                .matching(NSPredicate(format: "label == %@", "關閉"))
                .allElementsBoundByIndex
                .last(where: { $0.exists && $0.isHittable })
            if let candidate { return candidate }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }
}

private extension XCUIElement {
    /// `hasKeyboardFocus` is the XCUIElement attribute XCTest itself uses to
    /// route `typeText`; polling it avoids a fixed sleep.
    func waitUntilValue(hasKeyboardFocus expected: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, (value(forKey: "hasKeyboardFocus") as? Bool) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return exists && (value(forKey: "hasKeyboardFocus") as? Bool) == expected
    }
}
