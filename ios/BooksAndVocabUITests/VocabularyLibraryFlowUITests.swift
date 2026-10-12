import XCTest

/// P11 acceptance flow: the report baseline injects 644 ordinary reviewable
/// rows. Its review buckets are 14/503/127 and its CTA is 517.
final class VocabularyLibraryFlowUITests: UITestCase {
    private static let notebookID = "ui-p11-644-review-mix-notebook"
    private static let addLinkNotebookID = "ui-vocab-linked-cards-notebook"

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCUIDevice.shared.orientation = .portrait
        // The canonical 644-row UI World is intentionally a large-data
        // acceptance path; its measured cold launch and AX queries exceed the
        // generic smoke allowance. The allowance belongs to XCTest itself.
        executionTimeAllowance = 360
    }

    @MainActor
    func testRichWorldProjectsReviewSearchAndCTAConsistently() throws {
        let app = launchIsolatedApp(
            extraArgs: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibility3",
            ],
            fixtures: [.vocabularyLibraryP11ReviewMix],
            extraEnvironment: [
                "KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"
            ],
            perfLog: "vocabulary-filter-rich"
        )
        captureStep("launch", app: app)

        let shell = AppPage(app: app)
        let notebooks = shell.goToNotebooks()
        guard notebooks.notebookCard(id: Self.notebookID).waitUntilExists(timeout: 10) else {
            captureStep("no-rich-notebook", app: app)
            XCTFail("rich vocabulary UI World 必須種出 notebook \(Self.notebookID)")
            return
        }
        captureStep("notebook-ready", app: app)

        notebooks.notebookCard(id: Self.notebookID).tapWhenReady()
        let page = VocabularySearchPage(app: app)
        // The direct count probe avoids an O(N) accessibility-tree query for a
        // 644-row LazyVStack. Individual rows are asserted after each
        // projection where their lazy materialization is deterministic.
        guard page.visibleCount.waitUntilExists(timeout: 20) else {
            captureStep("no-rich-vocabulary-rows", app: app)
            XCTFail("rich fixture 必須渲染 vocabulary rows")
            return
        }
        captureStep("vocabulary-list-open", app: app)
        XCTAssertTrue(page.visibleCount.waitUntilExists(timeout: 5))
        captureStep("all-644-rows", app: app)
        page.assertVisibleCount(644, message: "review-state projection must show 644 visible rows")
        XCTAssertTrue(page.reviewCTA.waitUntilExists(timeout: 5), "report baseline CTA must be visible")
        XCTAssertEqual(page.reviewCTAValue, 517, "report baseline CTA must be exactly 517")
        XCTAssertTrue(page.sortMenu.waitUntilExists(timeout: 5), "sort control must remain a separate semantic control")
        XCTAssertEqual(page.reviewStateCount("unlearned", labelPrefix: "未學習"), 14)
        XCTAssertEqual(page.reviewStateCount("due", labelPrefix: "待複習"), 503)
        XCTAssertEqual(page.reviewStateCount("reviewed", labelPrefix: "已複習"), 127)
        XCTAssertTrue(page.reviewCTA.isHittable, "CTA must remain hittable at accessibility3")
        XCTAssertTrue(page.sortMenu.isHittable, "sort must remain hittable at accessibility3")
        captureStep("dynamic-type", app: app)
        captureStep("cta", app: app)

        try step("review-state", app: app) {
            XCTAssertTrue(page.reviewStateControls.waitUntilExists(timeout: 5))
            page.assertVisibleCount(644, message: "review-state projection must show all ordinary cards")
            XCTAssertTrue(page.reviewStateOption("unlearned", labelPrefix: "未學習").waitUntilExists(timeout: 5))
            XCTAssertTrue(page.reviewStateOption("due", labelPrefix: "待複習").waitUntilExists(timeout: 5))
            XCTAssertTrue(page.reviewStateOption("reviewed", labelPrefix: "已複習").waitUntilExists(timeout: 5))
            XCTAssertEqual(page.reviewStateCount("unlearned", labelPrefix: "未學習"), 14)
            XCTAssertEqual(page.reviewStateCount("due", labelPrefix: "待複習"), 503)
            XCTAssertEqual(page.reviewStateCount("reviewed", labelPrefix: "已複習"), 127)
            captureStep("review-state-filter-open", app: app)
            page.selectReviewState("unlearned", labelPrefix: "未學習")
            page.assertVisibleCount(14)
            XCTAssertTrue(page.row(word: "p11-review-word-001").waitUntilExists(timeout: 5))
            XCTAssertTrue(page.row(word: "p11-review-word-015").waitUntilGone(timeout: 5))
            page.selectReviewState("due", labelPrefix: "待複習")
            page.assertVisibleCount(517, message: "multi-select must union 14 unlearned and 503 due rows")
            XCTAssertTrue(
                page.reviewStateOption("unlearned", labelPrefix: "未學習").isSelected,
                "union must retain the unlearned review-state selection"
            )
            XCTAssertTrue(
                page.reviewStateOption("due", labelPrefix: "待複習").isSelected,
                "union must add the due review-state selection"
            )
            page.search("p11-review-word-001")
            page.assertVisibleCount(1, message: "union must retain an unlearned row")
            XCTAssertTrue(page.waitForRowMaterialized(word: "p11-review-word-001"))
            page.clearSearch()
            page.assertVisibleCount(517)
            page.search("p11-review-word-015")
            page.assertVisibleCount(1, message: "union must include a due row")
            XCTAssertTrue(page.waitForRowMaterialized(word: "p11-review-word-015"))
            page.clearSearch()
            page.assertVisibleCount(517)
        }

        try step("reviewed-scope", app: app) {
            page.clearReviewStates()
            page.selectReviewState("reviewed", labelPrefix: "已複習")
            page.assertVisibleCount(127)
            page.search("p11-review-word-518")
            page.assertVisibleCount(1, message: "reviewed facet must project a reviewed row")
            XCTAssertTrue(page.waitForRowMaterialized(word: "p11-review-word-518"))
            page.clearSearch()
            page.assertVisibleCount(127)
        }

        try step("search-within-projection", app: app) {
            page.clearReviewStates()
            page.search("p11-review-word-001")
            page.assertVisibleCount(1, message: "search visible count must be independent from facet counts")
            XCTAssertTrue(page.waitForRowMaterialized(word: "p11-review-word-001"))
            XCTAssertTrue(page.row(word: "p11-review-word-015").waitUntilGone(timeout: 5))
            XCTAssertEqual(page.reviewStateCount("unlearned", labelPrefix: "未學習"), 14)
            XCTAssertEqual(page.reviewStateCount("due", labelPrefix: "待複習"), 503)
            XCTAssertEqual(page.reviewStateCount("reviewed", labelPrefix: "已複習"), 127)
            page.clearSearch()
            page.assertVisibleCount(644)
            // Clearing a query restores the full projection without resetting
            // LazyVStack's scroll position. Assert the projection count and a
            // materialized non-query row instead of assuming row 015 is in the
            // current viewport.
            XCTAssertTrue(
                page.anyRowNotContaining("p11-review-word-001").waitUntilExists(timeout: 5),
                "clearing search must materialize a row outside the previous query"
            )
        }

        captureStep("rich-projection-verified", app: app)
    }

    @MainActor
    func testAddLinkDetailMaterializationEvidenceMatrix() throws {
        let app = launchIsolatedApp(
            fixtures: [.vocabulary("vocabLinkedCards")],
            extraEnvironment: [
                // AddLink candidate materialization is local; keep the test
                // hermetic and never attempt the network mutation path.
                "KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"
            ],
            perfLog: "vocabulary-add-link"
        )
        captureStep("add-link-launch", app: app)

        let notebooks = AppPage(app: app).goToNotebooks()
        guard notebooks.waitForNotebookCard(id: Self.addLinkNotebookID, timeout: 10) else {
            captureStep("add-link-notebook-missing", app: app)
            XCTFail("AddLink fixture 必須種出 notebook " + Self.addLinkNotebookID)
            return
        }
        notebooks.notebookCard(id: Self.addLinkNotebookID).tapWhenReady()
        XCTAssertTrue(app.waitForNavigationToSettle())

        let page = VocabularySearchPage(app: app)
        guard page.searchField.waitUntilExists(timeout: 10) else {
            captureStep("add-link-vocabulary-list-missing", app: app)
            XCTFail("AddLink fixture 必須渲染 vocabulary search field")
            return
        }
        page.search("serendipity")
        guard page.waitForRowMaterialized(word: "serendipity", timeout: 10) else {
            captureStep("add-link-source-row-missing", app: app)
            XCTFail("AddLink fixture 必須 materialize source row serendipity")
            return
        }
        page.row(word: "serendipity").tapWhenReady()
        guard page.detailHeroWord.waitUntilExists(timeout: 10) else {
            captureStep("add-link-detail-missing", app: app)
            XCTFail("AddLink source row 必須開啟 word detail")
            return
        }
        XCTAssertEqual(page.detailHeroWord.label, "serendipity")
        captureStep("add-link-source-detail", app: app)

        func addLinkTriggerQuery() -> XCUIElementQuery {
            app.buttons.matching(NSPredicate(format: "label == %@", "新增知識連結"))
        }

        // Candidate rows only: the create entry (`addLink.create`) stays listed next
        // to partial matches and its sentence repeats the typed word (#2030/#2037).
        // A row is one body button (word, POS, meaning); its 新增連結 / 打開卡片 buttons carry
        // no word, so one row per word stays one match (#2407, #3111).
        func candidateQuery(for word: String) -> XCUIElementQuery {
            app.buttons.matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ AND identifier != %@",
                    word,
                    "addLink.create"
                )
            )
        }

        func waitUntilEmpty(_ query: XCUIElementQuery, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if query.count == 0 { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            return query.count == 0
        }

        // Collapsed candidates expose only one line; detail assertions below run after the
        // row body is tapped, which expands it (#2407, #3111).
        func expandCandidate(_ detailID: String, named: String) -> Bool {
            guard let row = app.buttons
                .matching(identifier: detailID)
                .exactlyOneElement(timeout: 5, named: named) else { return false }
            row.scrollIntoView()
            row.tapWhenReady()
            return true
        }

        func openAddLinkSheet() -> Bool {
            guard let trigger = addLinkTriggerQuery().exactlyOneElement(
                timeout: 5,
                named: "AddLink detail trigger"
            ) else {
                return false
            }
            trigger.tapWhenReady()
            return app.textFields["addLink.searchField"].waitUntilExists(timeout: 5)
        }

        func closeAddLinkSheet() -> Bool {
            guard let cancel = app.buttons.matching(identifier: "addLink.cancel")
                .exactlyOneElement(timeout: 5, named: "AddLink cancel") else {
                return false
            }
            cancel.tapWhenReady()
            return app.textFields["addLink.searchField"].waitUntilGone(timeout: 5)
        }

        guard openAddLinkSheet() else {
            captureStep("add-link-sheet-missing", app: app)
            XCTFail("word detail 必須 materialize AddLink sheet")
            return
        }
        guard let emptyMarker = app.descendants(matching: .any)
            .matching(identifier: "addLink.local.empty")
            .exactlyOneElement(timeout: 5, named: "AddLink empty marker") else {
            captureStep("add-link-empty-missing", app: app)
            return
        }
        XCTAssertEqual(emptyMarker.label, "輸入單字名稱來建立連結")
        captureStep("add-link-empty", app: app)

        let searchField = app.textFields["addLink.searchField"]
        searchField.tapWhenReady()
        searchField.typeText("fort")
        guard candidateQuery(for: "fortuitous").exactlyOneElement(
            timeout: 5,
            named: "AddLink fortuitous candidate"
        ) != nil,
        candidateQuery(for: "fortunate").exactlyOneElement(
            timeout: 5,
            named: "AddLink fortunate candidate"
        ) != nil else {
            captureStep("add-link-word-candidates-missing", app: app)
            return
        }
        XCTAssertTrue(
            waitUntilEmpty(candidateQuery(for: "happy accident")),
            "query fort 必須排除不匹配的 happy accident candidate"
        )
        captureStep("add-link-word-candidates", app: app)

        let fortuitousDetailID = "addLink.local.result.vocab-linked-fortuitous"
        guard expandCandidate(fortuitousDetailID, named: "AddLink fortuitous expand") else {
            captureStep("add-link-fortuitous-expand-missing", app: app)
            XCTFail("AddLink fortuitous expand control must exist before its detail is asserted")
            return
        }
        guard let fortuitousState = app.descendants(matching: .any)
            .matching(identifier: "\(fortuitousDetailID).state")
            .exactlyOneElement(timeout: 5, named: "AddLink fortuitous detail state") else {
            captureStep("add-link-fortuitous-detail-state-missing", app: app)
            return
        }
        XCTAssertEqual(
            fortuitousState.value as? String,
            "ready-senses-2|senses=2",
            "fortuitous must expose both dictionary senses"
        )
        guard let firstSense = app.descendants(matching: .any)
            .matching(identifier: "\(fortuitousDetailID).sense.1")
            .exactlyOneElement(timeout: 5, named: "AddLink fortuitous first sense"),
            let secondSense = app.descendants(matching: .any)
            .matching(identifier: "\(fortuitousDetailID).sense.2")
            .exactlyOneElement(timeout: 5, named: "AddLink fortuitous second sense"),
            let secondExample = app.descendants(matching: .any)
            .matching(identifier: "\(fortuitousDetailID).sense.2.example.1")
            .exactlyOneElement(timeout: 5, named: "AddLink fortuitous second example"),
            let forms = app.descendants(matching: .any)
            .matching(identifier: "\(fortuitousDetailID).forms")
            .exactlyOneElement(timeout: 5, named: "AddLink fortuitous forms"),
            let provenanceSource = app.descendants(matching: .any)
            .matching(identifier: "\(fortuitousDetailID).provenance.source")
            .exactlyOneElement(timeout: 5, named: "AddLink fortuitous source provenance"),
            let provenanceChapter = app.descendants(matching: .any)
            .matching(identifier: "\(fortuitousDetailID).provenance.chapter")
            .exactlyOneElement(timeout: 5, named: "AddLink fortuitous chapter provenance"),
            let provenanceContext = app.descendants(matching: .any)
            .matching(identifier: "\(fortuitousDetailID).provenance.context")
            .exactlyOneElement(timeout: 5, named: "AddLink fortuitous context provenance") else {
            captureStep("add-link-fortuitous-detail-hierarchy-missing", app: app)
            return
        }
        XCTAssertTrue(
            firstSense.label.contains("complete definition remains available"),
            "first sense must retain its complete long definition"
        )
        XCTAssertTrue(
            secondSense.label.contains("second sense preserved as a separate hierarchy node"),
            "second sense must remain a separate hierarchy node"
        )
        XCTAssertTrue(
            secondExample.label.contains("enough time to notice the pattern"),
            "second sense example must remain attached to that sense"
        )
        XCTAssertTrue(
            forms.label.contains("fortuitously") && forms.label.contains("fortuitousness"),
            "inflected forms must remain visible"
        )
        XCTAssertEqual(provenanceSource.label, "來源: The Weight of Words")
        XCTAssertEqual(provenanceChapter.label, "Linked Cards")
        XCTAssertTrue(
            provenanceContext.label.contains("fortuitous delay"),
            "context provenance must remain visible"
        )

        let fortunateDetailID = "addLink.local.result.vocab-linked-fortunate"
        guard expandCandidate(fortunateDetailID, named: "AddLink fortunate expand") else {
            captureStep("add-link-fortunate-expand-missing", app: app)
            XCTFail("AddLink fortunate expand control must exist before its detail is asserted")
            return
        }
        guard let fortunateState = app.descendants(matching: .any)
            .matching(identifier: "\(fortunateDetailID).state")
            .exactlyOneElement(timeout: 5, named: "AddLink fortunate detail state"),
            let missingExample = app.descendants(matching: .any)
            .matching(identifier: "\(fortunateDetailID).sense.1.example.missing")
            .exactlyOneElement(timeout: 5, named: "AddLink fortunate missing example") else {
            captureStep("add-link-fortunate-missing-example-missing", app: app)
            return
        }
        XCTAssertEqual(
            fortunateState.value as? String,
            "missing-example-senses-1|senses=1",
            "fortunate must expose its missing-example state"
        )
        XCTAssertEqual(missingExample.value as? String, "missing")
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "\(fortunateDetailID).sense.1.example.1").count,
            0,
            "missing-example state must not fabricate an example"
        )
        captureStep("add-link-detail-multi-sense-missing-example", app: app)
        guard closeAddLinkSheet() else {
            captureStep("add-link-close-after-word-query-failed", app: app)
            XCTFail("AddLink sheet 必須可取消回到 word detail")
            return
        }

        guard openAddLinkSheet() else {
            captureStep("add-link-reopen-failed", app: app)
            XCTFail("word detail 必須可重新開啟 AddLink sheet")
            return
        }
        let reloadedSearchField = app.textFields["addLink.searchField"]
        reloadedSearchField.tapWhenReady()
        reloadedSearchField.typeText("happy accident")
        guard candidateQuery(for: "happy accident").exactlyOneElement(
            timeout: 5,
            named: "AddLink happy accident candidate"
        ) != nil else {
            captureStep("add-link-multiword-candidate-missing", app: app)
            return
        }
        XCTAssertTrue(
            waitUntilEmpty(candidateQuery(for: "fortuitous")),
            "query happy accident 必須排除 fortuitous candidate"
        )
        captureStep("add-link-multiword-candidate", app: app)
        guard closeAddLinkSheet() else {
            captureStep("add-link-close-after-multiword-query-failed", app: app)
            XCTFail("AddLink sheet 必須可取消回到 word detail")
            return
        }

        guard openAddLinkSheet() else {
            captureStep("add-link-reopen-for-provider-error-failed", app: app)
            XCTFail("word detail 必須可重新開啟 AddLink sheet 以驗證 provider recovery")
            return
        }
        let providerErrorSearchField = app.textFields["addLink.searchField"]
        providerErrorSearchField.tapWhenReady()
        providerErrorSearchField.typeText("revelation")
        guard candidateQuery(for: "revelation").exactlyOneElement(
            timeout: 5,
            named: "AddLink revelation candidate"
        ) != nil else {
            captureStep("add-link-provider-error-candidate-missing", app: app)
            return
        }
        let revelationDetailID = "addLink.local.result.vocab-linked-revelation"
        // The decode-error message and its retry live only in the expanded detail (#3111), so the
        // row is expanded before the provider state is asserted.
        guard expandCandidate(revelationDetailID, named: "AddLink revelation expand") else {
            captureStep("add-link-revelation-expand-missing", app: app)
            XCTFail("AddLink revelation expand control must exist before its detail is asserted")
            return
        }
        guard let providerErrorState = app.descendants(matching: .any)
            .matching(identifier: "\(revelationDetailID).state")
            .exactlyOneElement(timeout: 5, named: "AddLink provider decode-error state"),
            let providerError = app.descendants(matching: .any)
            .matching(identifier: "\(revelationDetailID).provider.error")
            .exactlyOneElement(timeout: 5, named: "AddLink provider decode-error message"),
            let providerRetry = app.descendants(matching: .any)
            .matching(identifier: "\(revelationDetailID).provider.retry")
            .exactlyOneElement(timeout: 5, named: "AddLink provider decode-error retry") else {
            captureStep("add-link-provider-error-state-missing", app: app)
            return
        }
        XCTAssertEqual(
            providerErrorState.value as? String,
            "provider-decode-error-retryable|senses=0"
        )
        XCTAssertFalse(providerError.label.isEmpty)
        providerRetry.tapWhenReady()
        XCTAssertTrue(
            providerErrorState.waitUntilValueEquals("recovered-senses-1|senses=1", timeout: 5),
            "provider retry must recover to a deterministic local detail"
        )
        XCTAssertTrue(providerError.waitUntilGone(timeout: 5))
        guard let recoveredSense = app.descendants(matching: .any)
            .matching(identifier: "\(revelationDetailID).sense.1")
            .exactlyOneElement(timeout: 5, named: "AddLink recovered revelation sense"),
            let recoveredExample = app.descendants(matching: .any)
            .matching(identifier: "\(revelationDetailID).sense.1.example.1")
            .exactlyOneElement(timeout: 5, named: "AddLink recovered revelation example") else {
            captureStep("add-link-provider-recovery-detail-missing", app: app)
            return
        }
        XCTAssertTrue(recoveredSense.label.contains("揭示；驚人的新發現"))
        XCTAssertTrue(recoveredExample.label.contains("quiet revelation"))
        captureStep("add-link-provider-decode-error-recovery", app: app)
        guard closeAddLinkSheet() else {
            captureStep("add-link-close-after-provider-recovery-failed", app: app)
            XCTFail("AddLink sheet 必須可取消回到 word detail")
            return
        }

        guard openAddLinkSheet() else {
            captureStep("add-link-reopen-for-empty-result-failed", app: app)
            XCTFail("word detail 必須可再次開啟 AddLink sheet")
            return
        }
        let emptyResultSearchField = app.textFields["addLink.searchField"]
        emptyResultSearchField.tapWhenReady()
        emptyResultSearchField.typeText("zzqxv")
        guard let createAffordance = app.buttons
            .matching(identifier: "addLink.create")
            .exactlyOneElement(timeout: 5, named: "AddLink missing-target create affordance") else {
            captureStep("add-link-create-affordance-missing", app: app)
            return
        }
        XCTAssertEqual(
            emptyResultSearchField.value as? String,
            "zzqxv",
            "AddLink missing-target query must remain visible without tapping create"
        )
        XCTAssertTrue(
            createAffordance.label.contains("zzqxv"),
            "AddLink create affordance must preserve the missing target query"
        )
        // #2037: the entry says the whole action (new word + source word) and the
        // notebook the new card lands in; each line is readable on its own id.
        let createTitle = app.descendants(matching: .any)
            .matching(identifier: "addLink.create.title").firstMatch
        let createNotebook = app.descendants(matching: .any)
            .matching(identifier: "addLink.create.notebook").firstMatch
        XCTAssertTrue(createTitle.waitUntilExists(timeout: 5), "create entry must expose addLink.create.title")
        XCTAssertTrue(createNotebook.waitUntilExists(timeout: 5), "create entry must expose addLink.create.notebook")
        let titleText = createTitle.value as? String ?? ""
        XCTAssertTrue(titleText.contains("zzqxv"), "create title must name the new word, got: \(titleText)")
        XCTAssertTrue(titleText.contains("serendipity"), "create title must name the source word, got: \(titleText)")
        XCTAssertFalse((createNotebook.value as? String ?? "").isEmpty, "create entry must name the target notebook")
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "沒有結果")).count,
            0,
            "missing-target AddLink must expose create, not the legacy no-results state"
        )
        XCTAssertTrue(waitUntilEmpty(candidateQuery(for: "fortuitous")))
        XCTAssertTrue(waitUntilEmpty(candidateQuery(for: "happy accident")))
        captureStep("add-link-missing-target-create", app: app)
    }

    @MainActor
    func testAddLinkLookupEvidenceMatrix() throws {
        let app = launchIsolatedApp(
            fixtures: [.vocabulary("vocabLinkedCards")],
            extraEnvironment: [
                "KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"
            ],
            perfLog: "vocabulary-add-link-lookup"
        )
        captureStep("add-link-lookup-launch", app: app)

        let notebooks = AppPage(app: app).goToNotebooks()
        guard notebooks.waitForNotebookCard(id: Self.addLinkNotebookID, timeout: 10) else {
            XCTFail("AddLink lookup fixture 必須種出 notebook " + Self.addLinkNotebookID)
            return
        }
        notebooks.notebookCard(id: Self.addLinkNotebookID).tapWhenReady()
        XCTAssertTrue(app.waitForNavigationToSettle())

        let page = VocabularySearchPage(app: app)
        guard page.searchField.waitUntilExists(timeout: 10) else {
            XCTFail("AddLink lookup flow 必須渲染 vocabulary search field")
            return
        }
        page.search("serendipity")
        guard page.waitForRowMaterialized(word: "serendipity", timeout: 10) else {
            XCTFail("AddLink lookup fixture 必須 materialize source row serendipity")
            return
        }
        page.row(word: "serendipity").tapWhenReady()
        guard page.detailHeroWord.waitUntilExists(timeout: 10) else {
            XCTFail("AddLink lookup source detail 必須存在")
            return
        }

        let addLinkTrigger = app.buttons.matching(
            NSPredicate(format: "label == %@", "新增知識連結")
        )
        guard let trigger = addLinkTrigger.exactlyOneElement(
            timeout: 10,
            named: "AddLink lookup detail trigger"
        ) else {
            return
        }
        trigger.tapWhenReady()

        let lookupState = app.descendants(matching: .any)
            .matching(identifier: "addLink.lookup.state")
        guard lookupState.exactlyOneElement(
            timeout: 5,
            named: "AddLink lookup state marker"
        ) != nil else {
            XCTFail("AddLink lookup 必須暴露唯一 state marker")
            return
        }
        XCTAssertTrue(lookupState.firstMatch.waitUntilValueEquals("idle", timeout: 5))
        captureStep("add-link-lookup-idle", app: app)

        let searchField = app.textFields["addLink.searchField"]
        searchField.tapWhenReady()
        searchField.typeText("fort")
        XCTAssertTrue(lookupState.firstMatch.waitUntilValueEquals("results-2", timeout: 5))

        // Select the row by identifier: a word-label query would also match its expand toggle (#2407).
        guard let fortuitous = app.descendants(matching: .any)
            .matching(identifier: "addLink.local.result.vocab-linked-fortuitous")
            .exactlyOneElement(timeout: 5, named: "AddLink fortuitous row") else {
            XCTFail("AddLink lookup 必須顯示 fortuitous candidate")
            return
        }
        // Collapsed row: the visible first sense and the verdict only. The example and provenance
        // stay hidden until the row is expanded, so the row value must not name them (#2407).
        let rowSummary = fortuitous.value as? String ?? ""
        XCTAssertTrue(rowSummary.contains("pos=adj."))
        XCTAssertTrue(rowSummary.contains("expansion=collapsed"))
        XCTAssertFalse(rowSummary.contains("sense="))
        XCTAssertTrue(rowSummary.contains("detail.state=ready-senses-2"))
        XCTAssertFalse(
            rowSummary.contains("example=The fortuitous meeting"),
            "collapsed row must not name the example hidden until expansion"
        )
        XCTAssertFalse(
            rowSummary.contains("source=The Weight of Words"),
            "collapsed row must not name provenance hidden until expansion"
        )
        captureStep("add-link-lookup-results", app: app)

        let cancel = app.buttons.matching(identifier: "addLink.cancel")
        guard let cancelButton = cancel.exactlyOneElement(
            timeout: 5,
            named: "AddLink lookup cancel after results"
        ) else {
            return
        }
        cancelButton.tapWhenReady()
        XCTAssertTrue(searchField.waitUntilGone(timeout: 5))
        guard let reopenedTrigger = addLinkTrigger.exactlyOneElement(
            timeout: 5,
            named: "AddLink lookup reopened detail trigger"
        ) else {
            return
        }
        reopenedTrigger.tapWhenReady()
        let emptySearchField = app.textFields["addLink.searchField"]
        XCTAssertTrue(emptySearchField.waitUntilExists(timeout: 5))
        emptySearchField.tapWhenReady()
        emptySearchField.typeText("zzqxv")
        XCTAssertTrue(lookupState.firstMatch.waitUntilValueEquals("empty", timeout: 5))
        guard let createAffordance = app.buttons
            .matching(identifier: "addLink.create")
            .exactlyOneElement(timeout: 5, named: "AddLink lookup create affordance") else {
            return
        }
        createAffordance.tapWhenReady()

        let progress = app.descendants(matching: .any)
            .matching(identifier: "addLink.creation.progress")
            .firstMatch
        XCTAssertTrue(progress.waitUntilValueEquals("attempt-1", timeout: 5))
        XCTAssertTrue(
            lookupState.firstMatch.waitUntilValueContains("error-attempt-1", timeout: 30)
        )
        captureStep("add-link-lookup-error", app: app)

        let retry = app.buttons["addLink.creation.retry"]
        guard retry.waitUntilExists(timeout: 5) else {
            XCTFail("AddLink lookup failure 必須保留 retry")
            return
        }
        retry.tapWhenReady()
        XCTAssertTrue(progress.waitUntilValueEquals("attempt-2", timeout: 5))
        XCTAssertTrue(
            lookupState.firstMatch.waitUntilValueContains("retry-attempt-2", timeout: 2)
                || lookupState.firstMatch.waitUntilValueContains("error-attempt-2", timeout: 30),
            "retry 必須先暴露 retry 或最終 error state"
        )
        captureStep("add-link-lookup-retry", app: app)
    }

    @MainActor
    func testAddLinkCreationFailureRemainsRetryable() throws {
        let app = launchIsolatedApp(
            fixtures: [.vocabulary("vocabLinkedCards")],
            extraEnvironment: [
                // Keep the production-mode creation path hermetic and force a
                // retryable transport failure without changing the fixture.
                "KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"
            ],
            perfLog: "vocabulary-add-link-retry"
        )
        captureStep("add-link-retry-launch", app: app)

        let notebooks = AppPage(app: app).goToNotebooks()
        guard notebooks.waitForNotebookCard(id: Self.addLinkNotebookID, timeout: 10) else {
            captureStep("add-link-retry-notebook-missing", app: app)
            XCTFail("AddLink fixture 必須種出 notebook " + Self.addLinkNotebookID)
            return
        }
        notebooks.notebookCard(id: Self.addLinkNotebookID).tapWhenReady()
        XCTAssertTrue(app.waitForNavigationToSettle())

        let page = VocabularySearchPage(app: app)
        guard page.searchField.waitUntilExists(timeout: 10) else {
            captureStep("add-link-retry-vocabulary-list-missing", app: app)
            XCTFail("AddLink fixture 必須渲染 vocabulary search field")
            return
        }
        page.search("serendipity")
        guard page.waitForRowMaterialized(word: "serendipity", timeout: 10) else {
            captureStep("add-link-retry-source-row-missing", app: app)
            XCTFail("AddLink fixture 必須 materialize source row serendipity")
            return
        }
        page.row(word: "serendipity").tapWhenReady()

        let addLinkTrigger = app.buttons.matching(
            NSPredicate(format: "label == %@", "新增知識連結")
        )
        guard let trigger = addLinkTrigger.exactlyOneElement(
            timeout: 10,
            named: "AddLink retry detail trigger"
        ) else {
            captureStep("add-link-retry-trigger-missing", app: app)
            return
        }
        trigger.tapWhenReady()

        let searchField = app.textFields["addLink.searchField"]
        guard searchField.waitUntilExists(timeout: 10) else {
            captureStep("add-link-retry-sheet-missing", app: app)
            XCTFail("AddLink retry flow 必須開啟 sheet")
            return
        }
        searchField.tapWhenReady()
        searchField.typeText("zzqxv")

        guard let createAffordance = app.buttons
            .matching(identifier: "addLink.create")
            .exactlyOneElement(timeout: 10, named: "AddLink retry create affordance") else {
            captureStep("add-link-retry-create-missing", app: app)
            return
        }
        XCTAssertEqual(searchField.value as? String, "zzqxv")
        createAffordance.tapWhenReady()

        let progress = app.descendants(matching: .any)
            .matching(identifier: "addLink.creation.progress")
            .firstMatch
        let errorQuery = app.descendants(matching: .any)
            .matching(identifier: "addLink.creation.error")
        let retryQuery = app.descendants(matching: .any)
            .matching(identifier: "addLink.creation.retry")

        guard let firstError = errorQuery.exactlyOneElement(
            timeout: 30,
            named: "AddLink first creation error"
        ), let firstRetry = retryQuery.exactlyOneElement(
            timeout: 5,
            named: "AddLink first creation retry"
        ) else {
            captureStep("add-link-retry-first-failure-missing", app: app)
            return
        }
        XCTAssertTrue(progress.waitUntilExists(timeout: 5))
        XCTAssertTrue(
            progress.waitUntilValueEquals("attempt-1", timeout: 5),
            "first failure must expose the first creation attempt"
        )
        XCTAssertFalse(firstError.frame.isEmpty, "creation error must be visible")
        XCTAssertTrue(firstRetry.isHittable, "creation retry must be actionable")
        XCTAssertEqual(errorQuery.count, 1, "creation error identifier must be unique")
        XCTAssertEqual(retryQuery.count, 1, "creation retry identifier must be unique")
        XCTAssertEqual(app.buttons.matching(identifier: "addLink.cancel").count, 1, "sheet must remain open")
        XCTAssertEqual(app.buttons.matching(identifier: "addLink.create").count, 0, "failed surface must replace create affordance")
        // #2030: the failure names a classified reason and offers a way back to search.
        let reason = app.descendants(matching: .any).matching(identifier: "addLink.error.reason").firstMatch
        XCTAssertTrue(reason.waitUntilExists(timeout: 5), "failure must expose addLink.error.reason")
        XCTAssertFalse((reason.value as? String ?? "").isEmpty, "failure reason must carry a code")
        XCTAssertTrue(
            app.buttons["addLink.creation.backToSearch"].waitUntilExists(timeout: 5),
            "failed surface must offer back-to-search"
        )
        captureStep("add-link-retry-first-failure", app: app)

        firstRetry.tapWhenReady()
        // Port 9 can reject in the same run-loop turn, so the attempt marker
        // proves the retry action re-entered the production start path without
        // depending on a transient running snapshot.
        XCTAssertTrue(
            progress.waitUntilValueEquals("attempt-2", timeout: 5),
            "retry must start a new AddLink creation attempt"
        )
        guard let secondError = errorQuery.exactlyOneElement(
            timeout: 30,
            named: "AddLink second creation error"
        ), let secondRetry = retryQuery.exactlyOneElement(
            timeout: 5,
            named: "AddLink second creation retry"
        ) else {
            captureStep("add-link-retry-second-failure-missing", app: app)
            return
        }
        XCTAssertTrue(progress.waitUntilExists(timeout: 5))
        XCTAssertFalse(secondError.frame.isEmpty, "second creation error must be visible")
        XCTAssertTrue(secondRetry.isHittable, "second creation retry must be actionable")
        XCTAssertEqual(errorQuery.count, 1, "second creation error identifier must be unique")
        XCTAssertEqual(retryQuery.count, 1, "second creation retry identifier must be unique")
        XCTAssertEqual(app.buttons.matching(identifier: "addLink.cancel").count, 1, "sheet must remain open after retry")
        XCTAssertEqual(app.buttons.matching(identifier: "addLink.create").count, 0, "retry failure must not restore create affordance")
        captureStep("add-link-retry-second-failure", app: app)
    }

    @MainActor
    func testAddLinkCreationWarningKeepsSheetUntilDone() throws {
        // #2030 C11: only a full success closes on its own; a warning keeps the
        // sheet open with retry + done, and only "done" closes it.
        let sheetSource = try AddLinkWarningSourceContract.source(
            relativePath: "ios/BooksAndVocab/Views/Vocabulary/Scenes/AddLinkSheet.swift"
        )
        let progressSource = try AddLinkWarningSourceContract.source(
            relativePath: "ios/BooksAndVocab/Views/Vocabulary/Scenes/AddLinkCreationProgressView.swift"
        )

        let visibilityStart = try XCTUnwrap(
            sheetSource.range(of: "private var showsCreationProgress: Bool {")
        )
        let visibilityEnd = try XCTUnwrap(
            sheetSource.range(
                of: "var body: some View",
                range: visibilityStart.upperBound..<sheetSource.endIndex
            )
        )
        let visibilitySource = String(
            sheetSource[visibilityStart.lowerBound..<visibilityEnd.lowerBound]
        )
        XCTAssertTrue(
            visibilitySource.contains("creationCoordinator.phase == .succeededWithWarnings"),
            "warning terminal state must keep the creation progress surface mounted"
        )
        XCTAssertTrue(
            sheetSource.contains("if showsCreationProgress {\n                    AddLinkCreationProgressView("),
            "the progress surface must be gated by showsCreationProgress"
        )

        let handlerStart = try XCTUnwrap(
            sheetSource.range(of: ".onChange(of: creationCoordinator.phase)")
        )
        let handlerEnd = try XCTUnwrap(
            sheetSource.range(
                of: ".onDisappear",
                range: handlerStart.upperBound..<sheetSource.endIndex
            )
        )
        let handlerSource = String(sheetSource[handlerStart.lowerBound..<handlerEnd.lowerBound])
        XCTAssertTrue(
            handlerSource.contains("guard phase == .succeeded, !didCompleteCreation"),
            "only a full success may close the Add Link sheet on its own"
        )
        XCTAssertFalse(
            handlerSource.contains(".succeededWithWarnings"),
            "a warning must not auto-dismiss the sheet"
        )
        XCTAssertTrue(
            handlerSource.contains("didCompleteCreation = true"),
            "terminal completion must latch before invoking the callback"
        )
        XCTAssertTrue(handlerSource.contains("onLinked()"), "terminal completion must notify the owner")
        XCTAssertTrue(handlerSource.contains("dismiss()"), "full success must dismiss the sheet")
        XCTAssertTrue(
            sheetSource.contains("@State private var didCompleteCreation = false"),
            "completion latch must survive SwiftUI rerenders within the sheet"
        )

        let doneStart = try XCTUnwrap(sheetSource.range(of: "private func finishWithWarnings()"))
        let doneEnd = try XCTUnwrap(
            sheetSource.range(of: "private func startCreation()", range: doneStart.upperBound..<sheetSource.endIndex)
        )
        let doneSource = String(sheetSource[doneStart.lowerBound..<doneEnd.lowerBound])
        XCTAssertTrue(doneSource.contains("creationCoordinator.acknowledge()"), "done must retire the warning job")
        XCTAssertTrue(doneSource.contains("onLinked()"), "done must notify the owner")
        XCTAssertTrue(doneSource.contains("dismiss()"), "done is the only way a warning closes the sheet")
        XCTAssertTrue(
            sheetSource.contains("onDone: finishWithWarnings"),
            "the warning surface must be wired to the done action"
        )
        XCTAssertTrue(
            sheetSource.contains("creationCoordinator.retryWarnings()"),
            "retry on a warning must re-run the unfinished parts, not create again"
        )
        for identifier in [
            "addLink.creation.retry",
            "addLink.creation.warning.done",
            "addLink.creation.backToSearch",
            "addLink.error.reason",
        ] {
            XCTAssertTrue(progressSource.contains(identifier), "progress surface must expose \(identifier)")
        }

        let messageStart = try XCTUnwrap(
            progressSource.range(of: "if let message = coordinator.message")
        )
        let panelStart = try XCTUnwrap(
            progressSource.range(
                of: "SettingsSyncProgressPanel(",
                range: messageStart.upperBound..<progressSource.endIndex
            )
        )
        let messageSource = String(progressSource[messageStart.lowerBound..<panelStart.lowerBound])
        XCTAssertTrue(
            messageSource.contains("coordinator.phase == .succeededWithWarnings"),
            "warning message must use the visible creation status surface"
        )
        XCTAssertTrue(
            messageSource.contains("addLink.creation.warning"),
            "warning status must expose a deterministic accessibility identifier"
        )
    }

    @MainActor
    func testWordDetailShowsFourCardManagementControlsAndDeleteWarning() throws {
        let app = launchIsolatedApp(
            fixtures: [.vocabulary("vocabLinkedCards")],
            extraEnvironment: [
                "KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"
            ],
            perfLog: "word-detail-card-management"
        )

        let notebooks = AppPage(app: app).goToNotebooks()
        XCTAssertTrue(
            notebooks.waitForNotebookCard(id: Self.addLinkNotebookID, timeout: 10),
            "word detail control fixture 必須種出 notebook"
        )
        notebooks.notebookCard(id: Self.addLinkNotebookID).tapWhenReady()

        let page = VocabularySearchPage(app: app)
        XCTAssertTrue(page.searchField.waitUntilExists(timeout: 10))
        page.search("serendipity")
        XCTAssertTrue(page.waitForRowMaterialized(word: "serendipity", timeout: 10))
        page.row(word: "serendipity").tapWhenReady()

        let archive = app.buttons["wordDetail.action.archive"]
        let delete = app.buttons["wordDetail.action.delete"]
        let readerHidden = app.descendants(matching: .any)
            .matching(identifier: "wordDetail.toggle.readerHidden").firstMatch
        let reviewExcluded = app.descendants(matching: .any)
            .matching(identifier: "wordDetail.toggle.reviewExcluded").firstMatch
        for control in [archive, delete, readerHidden, reviewExcluded] {
            XCTAssertTrue(control.waitUntilExists(timeout: 10), "Word Detail 四項控制必須存在")
            XCTAssertTrue(control.isHittable, "Word Detail 控制必須可見且可操作")
            XCTAssertTrue(control.isEnabled, "synced card 的 Word Detail 控制必須可操作")
        }
        XCTAssertFalse((readerHidden.value as? String ?? "").isEmpty)
        XCTAssertFalse((reviewExcluded.value as? String ?? "").isEmpty)

        XCTAssertLessThan(archive.frame.minY, delete.frame.minY)
        XCTAssertLessThan(delete.frame.minY, readerHidden.frame.minY)
        XCTAssertLessThan(readerHidden.frame.minY, reviewExcluded.frame.minY)
        captureStep("word-detail-four-controls", app: app)

        delete.tapWhenReady()
        XCTAssertTrue(
            app.alerts.firstMatch.waitUntilExists(timeout: 5),
            "刪除必須先顯示警訊確認視窗"
        )
        app.buttons["取消"].tapWhenReady()
        captureStep("word-detail-delete-warning", app: app)
    }

    /// #2427: the selection-toolbar trash only asks. Cancel keeps the word and
    /// selection; only the destructive dialog action removes it.
    @MainActor
    func testBatchDeleteRequiresConfirmationBeforeRemovingWord() throws {
        let app = launchIsolatedApp(
            fixtures: [.vocabulary("vocabLinkedCards")],
            extraEnvironment: [
                "KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"
            ],
            perfLog: "vocabulary-batch-delete-confirm"
        )
        captureStep("batch-delete-launch", app: app)

        let notebooks = AppPage(app: app).goToNotebooks()
        guard notebooks.waitForNotebookCard(id: Self.addLinkNotebookID, timeout: 10) else {
            XCTFail("batch delete fixture 必須種出 notebook " + Self.addLinkNotebookID)
            return
        }
        notebooks.notebookCard(id: Self.addLinkNotebookID).tapWhenReady()
        XCTAssertTrue(app.waitForNavigationToSettle())

        let page = VocabularySearchPage(app: app)
        guard page.searchField.waitUntilExists(timeout: 10) else {
            XCTFail("batch delete flow 必須渲染 vocabulary search field")
            return
        }
        page.search("serendipity")
        guard page.waitForRowMaterialized(word: "serendipity", timeout: 10) else {
            XCTFail("batch delete fixture 必須 materialize source row serendipity")
            return
        }

        // Put the search keyboard away first: it must not cover the selection toolbar
        // or the confirmation alert presented by the trash button.
        app.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 5), "搜尋後鍵盤必須收起，才不遮住選取工具列與確認視窗")
        page.row(word: "serendipity").press(forDuration: 1.0)
        let trash = app.buttons["刪除"]
        XCTAssertTrue(trash.waitUntilExists(timeout: 5), "長按後必須進入選取模式並顯示刪除按鈕")
        XCTAssertTrue(trash.isEnabled, "選取一筆後刪除按鈕必須可用")
        captureStep("batch-delete-selected", app: app)

        // The batch-delete confirmation is an alert (KGVocabView). Scope every button
        // lookup to it, because "取消" also exists in the selection toolbar.
        trash.tapWhenReady()
        let dialog = app.alerts.firstMatch
        XCTAssertTrue(dialog.waitUntilExists(timeout: 5), "刪除按鈕必須先顯示破壞性確認視窗")
        XCTAssertTrue(page.row(word: "serendipity").exists, "確認前單字不可被刪除")
        captureStep("batch-delete-dialog", app: app)

        dialog.buttons["取消"].tapWhenReady()
        XCTAssertTrue(dialog.waitUntilGone(timeout: 5), "取消後確認視窗必須關閉")
        XCTAssertTrue(page.row(word: "serendipity").exists, "取消後單字必須保留")
        XCTAssertTrue(trash.isEnabled, "取消後選取狀態必須保留")
        captureStep("batch-delete-cancelled", app: app)

        trash.tapWhenReady()
        let confirmDialog = app.alerts.firstMatch
        XCTAssertTrue(confirmDialog.waitUntilExists(timeout: 5), "再次刪除必須重新顯示確認視窗")
        confirmDialog.buttons["刪除"].tapWhenReady()
        XCTAssertTrue(
            page.row(word: "serendipity").waitUntilGone(timeout: 10),
            "確認刪除後單字必須移除"
        )
        captureStep("batch-delete-confirmed", app: app)
    }
}

private enum AddLinkWarningSourceContract {
    static func source(relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
