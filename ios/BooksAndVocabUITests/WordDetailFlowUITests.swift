import XCTest

final class WordDetailFlowUITests: UITestCase {
    private enum Fixture {
        static let notebookID = "ui-word-detail-notebook"
        static let word = "ephemeral"
        static let translation = "短暫的；轉瞬即逝的"
        static let explanation = "Lasting for a very short time; describes things that fade quickly, often with a wistful, literary tone."
        static let example = "The ephemeral beauty of cherry blossoms draws crowds each spring."
        static let rootForm = "ephemeral"
        static let bookTitle = "On Writing Well"
        static let chapterTitle = "· Chapter 3 · Simplicity"
        static let syncStatus = "已同步"
        static let editedTranslation = "brief"
        static let editedExplanation = "Updated detail from Word Detail edit."
        static let pendingStateIndicator = "待同步"
    }

    private enum Selector {
        static let translationEditor = "wordDetail.edit.translation"
        static let explanationEditor = "wordDetail.edit.explanation"
        static let saveButton = "wordDetail.edit.save"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 180
    }

    /// #3117: the Word Detail knowledge-link "+" must expose a >= 44pt
    /// accessibility frame. The glyph stays small; only the hit area grows.
    @MainActor
    func testWordDetailAddLinkExposesMinimumHitTarget() throws {
        let app = launchIsolatedApp(fixtures: [.vocabulary("wordDetail")])
        let notebooks = AppPage(app: app).goToNotebooks()

        guard notebooks.waitForNotebookCard(id: Fixture.notebookID, timeout: 10) else {
            XCTFail("Word Detail fixture must materialize its notebook")
            return
        }
        notebooks.notebookCard(id: Fixture.notebookID).tapWhenReady()
        XCTAssertTrue(app.waitForNavigationToSettle())

        let vocabulary = VocabularySearchPage(app: app)
        guard vocabulary.searchField.waitUntilExists(timeout: 10) else {
            XCTFail("Word Detail fixture must materialize the vocabulary search field")
            return
        }
        vocabulary.search(Fixture.word)
        guard vocabulary.waitForRowMaterialized(word: Fixture.word, timeout: 10) else {
            XCTFail("Word Detail fixture must materialize the target word row")
            return
        }
        vocabulary.row(word: Fixture.word).tapWhenReady()
        guard vocabulary.detailHeroWord.waitUntilExists(timeout: 10) else {
            XCTFail("Selecting the target word must open Word Detail")
            return
        }

        let addLink = app.descendants(matching: .any)
            .matching(identifier: "wordDetail.card.addLink").firstMatch
        guard addLink.waitUntilExists(timeout: 10) else {
            captureStep("word-detail-add-link-missing", app: app)
            XCTFail("Word Detail 必須有知識連結新增入口 wordDetail.card.addLink")
            return
        }
        XCTAssertGreaterThanOrEqual(
            addLink.frame.width, 44,
            "Word Detail add-link hit target 寬度必須 >= 44pt，實際 \(addLink.frame.width)"
        )
        XCTAssertGreaterThanOrEqual(
            addLink.frame.height, 44,
            "Word Detail add-link hit target 高度必須 >= 44pt，實際 \(addLink.frame.height)"
        )
    }

    @MainActor
    func testWordDetailHierarchyUsesStableSelectors() throws {
        let app = launchIsolatedApp(fixtures: [.vocabulary("wordDetail")])
        let notebooks = AppPage(app: app).goToNotebooks()

        guard notebooks.waitForNotebookCard(id: Fixture.notebookID, timeout: 10) else {
            XCTFail("Word Detail fixture must materialize its notebook")
            return
        }
        notebooks.notebookCard(id: Fixture.notebookID).tapWhenReady()
        XCTAssertTrue(app.waitForNavigationToSettle())

        let vocabulary = VocabularySearchPage(app: app)
        guard vocabulary.searchField.waitUntilExists(timeout: 10) else {
            XCTFail("Word Detail fixture must materialize the vocabulary search field")
            return
        }
        vocabulary.search(Fixture.word)
        guard vocabulary.waitForRowMaterialized(word: Fixture.word, timeout: 10) else {
            XCTFail("Word Detail fixture must materialize the target word row")
            return
        }
        vocabulary.row(word: Fixture.word).tapWhenReady()

        guard vocabulary.detailHeroWord.waitUntilExists(timeout: 10) else {
            XCTFail("Selecting the target word must open Word Detail")
            return
        }
        XCTAssertEqual(vocabulary.detailHeroWord.label, Fixture.word)

        guard let hierarchy = element(
            "wordDetail.content",
            in: app,
            named: "Word Detail content hierarchy"
        ) else {
            return
        }
        guard let document = element(
            "wordDetail.document",
            below: hierarchy,
            named: "Word Detail document hierarchy"
        ), let forms = element(
            "wordDetail.forms",
            below: hierarchy,
            named: "Word Detail forms hierarchy"
        ), let metadata = element(
            "wordDetail.metadata",
            below: hierarchy,
            named: "Word Detail metadata hierarchy"
        ) else {
            return
        }

        assertExactlyOneText(Fixture.word, in: document, named: "Word Detail word")
        assertExactlyOneText(Fixture.translation, in: document, named: "Word Detail translation")
        assertExactlyOneText(Fixture.explanation, in: document, named: "Word Detail meaning")
        assertExactlyOneText(Fixture.example, in: document, named: "Word Detail example")
        assertExactlyOneText(Fixture.bookTitle, in: document, named: "Word Detail provenance book")
        assertExactlyOneText(Fixture.chapterTitle, in: document, named: "Word Detail provenance chapter")
        assertExactlyOneText(Fixture.rootForm, in: forms, named: "Word Detail root form")
        assertExactlyOneText(Fixture.syncStatus, in: metadata, named: "Word Detail sync metadata")

        XCTAssertLessThan(
            document.frame.minY,
            forms.frame.minY,
            "Word Detail forms must follow the document content"
        )
        XCTAssertLessThan(
            forms.frame.minY,
            metadata.frame.minY,
            "Word Detail metadata must follow the forms section"
        )
        captureStep("word-detail-hierarchy", app: app)
    }

    @MainActor
    func testWordDetailEditRefreshesPresentationAndKeepsPendingStateIndicator() throws {
        let app = launchIsolatedApp(fixtures: [.vocabulary("wordDetail")])
        let notebooks = AppPage(app: app).goToNotebooks()

        guard notebooks.waitForNotebookCard(id: Fixture.notebookID, timeout: 10) else {
            XCTFail("Word Detail fixture must materialize its notebook")
            return
        }
        notebooks.notebookCard(id: Fixture.notebookID).tapWhenReady()
        XCTAssertTrue(app.waitForNavigationToSettle())

        let vocabulary = VocabularySearchPage(app: app)
        guard vocabulary.searchField.waitUntilExists(timeout: 10) else {
            XCTFail("Word Detail fixture must materialize the vocabulary search field")
            return
        }
        vocabulary.search(Fixture.word)
        guard vocabulary.waitForRowMaterialized(word: Fixture.word, timeout: 10) else {
            XCTFail("Word Detail fixture must materialize the target word row")
            return
        }
        vocabulary.row(word: Fixture.word).tapWhenReady()

        guard vocabulary.detailHeroWord.waitUntilExists(timeout: 10) else {
            XCTFail("Selecting the target word must open Word Detail")
            return
        }

        guard element("wordDetail.document", in: app, named: "Word Detail edit document") != nil else {
            return
        }
        guard let editButton = activeEditButton(in: app) else {
            return
        }
        editButton.tapWhenReady()

        guard let translationEditor = element(
            Selector.translationEditor,
            in: app,
            named: "Word Detail translation editor"
        ), let explanationEditor = element(
            Selector.explanationEditor,
            in: app,
            named: "Word Detail explanation editor"
        ) else {
            XCTFail("Word Detail edit sheet must expose translation and explanation editors")
            return
        }
        XCTAssertEqual(translationEditor.value as? String, Fixture.translation)
        XCTAssertEqual(explanationEditor.value as? String, Fixture.explanation)

        let typedTranslation = appendText(
            " \(Fixture.editedTranslation)",
            to: translationEditor
        )
        let typedExplanation = appendText(
            " \(Fixture.editedExplanation)",
            to: explanationEditor
        )
        XCTAssertTrue(typedTranslation.contains(Fixture.editedTranslation))
        XCTAssertTrue(typedExplanation.contains(Fixture.editedExplanation))

        // WordEditSheet persists trimmed editor values. Assert the rendered
        // presentation against that save contract, while keeping the input
        // assertions above on the raw editor values.
        let editedTranslation = typedTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedExplanation = typedExplanation.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let saveButton = activeIdentifiedElement(
            Selector.saveButton,
            in: app,
            named: "Word Detail edit save button"
        ) else {
            return
        }
        saveButton.tapWhenReady()
        XCTAssertTrue(translationEditor.waitUntilGone(timeout: 10))

        guard let refreshedDocument = element(
            "wordDetail.document",
            in: app,
            named: "Word Detail refreshed document"
        ), let metadata = element(
            "wordDetail.metadata",
            in: app,
            named: "Word Detail refreshed metadata"
        ) else {
            return
        }
        assertExactlyOneText(
            editedTranslation,
            in: refreshedDocument,
            named: "Word Detail refreshed translation"
        )
        assertExactlyOneText(
            editedExplanation,
            in: refreshedDocument,
            named: "Word Detail refreshed explanation"
        )
        // This is the existing local presentation indicator only; this test
        // does not claim that edit entered a sync transport.
        assertExactlyOneText(
            Fixture.pendingStateIndicator,
            in: metadata,
            named: "Word Detail existing pending-state indicator"
        )
        captureStep("word-detail-edit-refresh", app: app)
    }

    // MARK: - #2047 pill

    /// 卡片動作失敗是使用者剛觸發的一次性結果：頂端 error pill 承載通知（不放按鈕）。
    /// KG 伺服器不可達 → 同步卡的封存必然失敗 → 同一則 pill 只出現一次。
    @MainActor
    func testFailedArchivePostsOneErrorPill() throws {
        let app = launchIsolatedApp(
            fixtures: [.vocabulary("wordDetail")],
            extraEnvironment: ["KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"],
            perfLog: "word-detail-archive-failed-pill"
        )
        let notebooks = AppPage(app: app).goToNotebooks()
        guard notebooks.waitForNotebookCard(id: Fixture.notebookID, timeout: 10) else {
            XCTFail("Word Detail fixture must materialize its notebook")
            return
        }
        notebooks.notebookCard(id: Fixture.notebookID).tapWhenReady()
        XCTAssertTrue(app.waitForNavigationToSettle())

        let vocabulary = VocabularySearchPage(app: app)
        guard vocabulary.searchField.waitUntilExists(timeout: 10) else {
            XCTFail("Word Detail fixture must materialize the vocabulary search field")
            return
        }
        vocabulary.search(Fixture.word)
        guard vocabulary.waitForRowMaterialized(word: Fixture.word, timeout: 10) else {
            XCTFail("Word Detail fixture must materialize the target word row")
            return
        }
        vocabulary.row(word: Fixture.word).tapWhenReady()
        guard vocabulary.detailHeroWord.waitUntilExists(timeout: 10) else {
            XCTFail("Selecting the target word must open Word Detail")
            return
        }

        let archive = app.buttons["wordDetail.action.archive"]
        XCTAssertTrue(archive.waitUntilExists(timeout: 10), "Word Detail must expose the archive action")
        archive.tapWhenReady()

        let pill = app.descendants(matching: .any).matching(identifier: "app.toast").firstMatch
        XCTAssertTrue(pill.waitUntilExists(timeout: 10), "a failed card action must post a pill")
        XCTAssertEqual(pill.value as? String, "error", "the card action failure uses the error style")
        captureStep("word-detail-archive-failed-pill", app: app)
    }

    private func appendText(_ text: String, to editor: XCUIElement) -> String {
        editor.tapWhenReady()
        editor.typeText(text)
        return editor.value as? String ?? ""
    }

    private func activeEditButton(in app: XCUIApplication) -> XCUIElement? {
        // WordDetailPresenter owns this existing localized action outside this
        // lane and does not publish a dedicated identifier. Resolve the
        // semantic matches, then require exactly one active hittable element;
        // edit-sheet controls below use stable identifiers owned by this lane.
        let query = app.buttons.matching(NSPredicate(format: "label == %@", "編輯"))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let active = query.allElementsBoundByIndex.filter { $0.isHittable }
            if active.count == 1 {
                return active[0]
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let activeCount = query.allElementsBoundByIndex.filter { $0.isHittable }.count
        XCTFail(
            "Expected exactly one active Word Detail edit button, observed \(activeCount) active of \(query.count) semantic matches"
        )
        return nil
    }

    private func activeIdentifiedElement(
        _ identifier: String,
        in app: XCUIApplication,
        named name: String
    ) -> XCUIElement? {
        let query = app.buttons.matching(identifier: identifier)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let active = query.allElementsBoundByIndex.filter { $0.isHittable }
            if active.count == 1 {
                return active[0]
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let activeCount = query.allElementsBoundByIndex.filter { $0.isHittable }.count
        XCTFail(
            "Expected exactly one active \(name), observed \(activeCount) active of \(query.count) identified matches"
        )
        return nil
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication,
        named name: String
    ) -> XCUIElement? {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .exactlyOneElement(timeout: 10, named: name)
    }

    private func element(
        _ identifier: String,
        below parent: XCUIElement,
        named name: String
    ) -> XCUIElement? {
        parent.descendants(matching: .any)
            .matching(identifier: identifier)
            .exactlyOneElement(timeout: 10, named: name)
    }

    private func assertExactlyOneText(
        _ expected: String,
        in container: XCUIElement,
        named name: String
    ) {
        guard let text = container.staticTexts
            .matching(NSPredicate(format: "label == %@", expected))
            .exactlyOneElement(timeout: 10, named: name) else {
            return
        }
        XCTAssertEqual(text.label, expected, "(name) must expose the complete fixture value")
    }
}
