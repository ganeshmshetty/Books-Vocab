//
//  ReaderFlowUITests.swift
//  Books & Vocab UI Tests
//
//  Reader 核心 flow（docs/sop/ui_flow_evidence.md 六件套）— 真書 + 視覺證據。
//  Fixture（`-seedFixture:reader:realBookLibrary`）從 UI World `bookAssetRef`
//  安裝完整 EPUB 入庫，並在綁定單字本內種一筆真詞庫 entry（introduction →
//  引言；導論）。Flow：書架開書 → Readium 渲染真內容 → 選詞 → 翻譯面板
//  帶真內容（詞庫命中路徑，零網路）→ 翻頁進度真前進。
//
//  守門斷言戳破假測試：fixture 該有書卻書架空 = XCTFail（不是 skip）；
//  選詞後沒有面板/沒有內容 = XCTFail。
//

import XCTest

final class ReaderFlowUITests: UITestCase {
    /// 章首獨立成段的真實單字（fixture 詞庫 entry 的 word）。
    private static let seededWord = "Introduction"
    /// iOS 26.4 的 Readium AX bridge 會把正文的「Introduction — My Story」
    /// 拆成兩個 StaticText；這個後半片段在真實正文中唯一且可點擊，仍位於
    /// seeded-word context 內，避免用固定 index 假裝 selector 穩定。
    private static let seededContent = "— My Story"
    /// UI World 種入詞庫的真翻譯 — 斷言「翻譯 UI 帶內容」的內容本體。
    private static let seededTranslation = "引言"
    /// Required TOC fixture 的第二章完整正文 accessibility marker。Readium
    /// 暴露段落節點，而不是把章首標題拆成可查詢的單字節點。
    private static let secondChapterContent =
        "Chapter Two begins with a different question: what can be repeated when motivation is quiet?"
    private static let invalidDestinationAssetSHA256 = "89864813d0f197efe8f680287579d5a338f7611cdb88f2cf42ce8ea38cacc68f"

    private static let fixtureEnvironment: [String: String] = [
        // 詞庫命中路徑不需要網路；指向不可達位址確保任何意外請求
        // connection refused（而非真 backend 401 觸發 session 清除）。
        "KG_UI_TEST_SERVER_URL": "http://127.0.0.1:9"
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 開書（Readium openPublication + 首次 highlight）+ 選詞 + 翻頁，
        // 超過 harness 預設 60s allowance。
        // The progress matrix opens five isolated real-EPUB readers; on a
        // cold iOS 26.4 simulator the Readium WebKit teardown/restart cycle
        // legitimately exceeds two minutes. Keep the allowance above the
        // measured full-flow envelope so a product assertion is not followed
        // by a harness timeout that hides its evidence.
        executionTimeAllowance = 300
    }

    @MainActor
    func testReaderOpensRealBookShowsLibraryTranslationAndTurnsPages() throws {
        // authSignedIn 先行：翻譯面板對訪客刻意走 guest 模式（隱藏詞庫翻譯內容），
        // 詞庫命中路徑需要已登入 session（fixture 層解，不在測試裡點登入 —
        // docs/sop/ui_flow_evidence.md 已知 seam）。
        let app = launchIsolatedApp(
            fixtures: [.authSignedIn, .readerRealBookLibrary],
            extraEnvironment: Self.fixtureEnvironment,
            perfLog: "reader"
        )
        captureStep("launch", app: app)

        // ── 1. 書架必須渲染 fixture 種的真書 ────────────────────────────────
        let bookshelf = AppPage(app: app).goToBookshelf()
        guard let bookCard = bookshelf.exactlyOneBookCard(timeout: 10) else {
            captureStep("no-book-card", app: app)
            XCTFail("reader fixture (realBookLibrary) 應種出一本真書；書架空 = fixture 沒跑或轉檔失敗")
            return
        }
        try step("bookshelf-book-card", app: app) {
            XCTAssertTrue(
                bookCard.label.contains("Atomic Habits"),
                "書卡 label 應含 fixture 書名，got: \(bookCard.label)"
            )
        }

        // ── 2. 開書 → Readium 真的渲染章節原文 ──────────────────────────────
        let reader = ReaderPage(app: app)
        try step("book-opened", app: app) {
            bookCard.tapWhenReady()
        }
        guard reader.waitForContent(Self.seededContent, timeout: 45) else {
            captureStep("reader-content-missing", app: app)
            XCTFail("閱讀器必須渲染真章節文本（唯一正文段落「\(Self.seededContent)」）— 沒出現 = 開書失敗或內容是假的")
            return
        }
        captureStep("reader-content", app: app)
        captureStep("reader", app: app)
        captureStep("reader-load", app: app)

        // ── 3. 選詞 → 翻譯面板真的出現且帶內容（詞庫命中，零網路）──────────
        try step("word-tapped", app: app) {
            XCTAssertTrue(reader.tapContentText(Self.seededWord, nearestTo: Self.seededContent))
        }
        guard reader.waitForTranslationPanel(timeout: 5) else {
            captureStep("no-translation-panel", app: app)
            XCTFail("點擊單字後翻譯面板必須出現 — 沒出現 = 選詞橋接或 overlay 壞了")
            return
        }
        attachText(
            "translationPanelWordLabel=\(reader.translationWord.label)",
            named: "Reader Translation Panel Headword AX"
        )
        XCTAssertTrue(
            reader.translationWordContains(Self.seededWord, timeout: 5),
            "面板 headword 必須是被點的單字"
        )
        XCTAssertTrue(
            reader.translationTextContains(Self.seededTranslation, timeout: 5),
            "面板必須帶真翻譯內容（fixture 詞庫 entry）"
        )
        captureStep("translation-shown", app: app)

        // #3117: the panel's speaker glyph stays 10pt; its hit area must be >= 44pt.
        let speak = app.descendants(matching: .any)
            .matching(identifier: "reader.translationPanel.speak").firstMatch
        XCTAssertTrue(speak.waitUntilExists(timeout: 5), "翻譯面板必須有發音按鈕 reader.translationPanel.speak")
        XCTAssertGreaterThanOrEqual(speak.frame.width, 44, "Reader vocab speaker hit target 寬度必須 >= 44pt，實際 \(speak.frame.width)")
        XCTAssertGreaterThanOrEqual(speak.frame.height, 44, "Reader vocab speaker hit target 高度必須 >= 44pt，實際 \(speak.frame.height)")

        // ── 4. 關閉面板（真狀態收回）────────────────────────────────────────
        try step("translation-dismissed", app: app) {
            XCTAssertTrue(reader.dismissTranslation(), "點 dismiss 後翻譯面板必須收回")
        }

        // ── 5. 翻頁 → 進度徽章數值真前進 ────────────────────────────────────
        guard let initialProgress = reader.progressPercent() else {
            captureStep("progress-before-missing", app: app)
            XCTFail("翻頁前 header 進度徽章必須存在且可解析")
            return
        }
        try step("page-turned", app: app) {
            XCTAssertTrue(reader.swipeWebViewLeft())
            XCTAssertTrue(
                reader.waitUntilProgressExceeds(initialProgress, timeout: 10),
                """
                翻頁後 header 進度徽章必須顯示更高的 totalProgression \
                （before=\(initialProgress)%, after=\(reader.progressPercent().map(String.init(describing:)) ?? "<missing>")）\
                — 沒前進 = 只滑了手勢、頁面沒真的翻
                """
            )
        }
        guard let progressAfter = reader.progressPercent() else {
            captureStep("progress-after-missing", app: app)
            XCTFail("翻頁後 header 進度徽章必須存在且可解析")
            return
        }
        attachText(
            """
            fixtureDataset=marketing_demo
            readerFixture=realBookLibrary
            seededWord=\(Self.seededWord)
            seededContent=\(Self.seededContent)
            seededTranslation=\(Self.seededTranslation)
            progressBefore=\(initialProgress)
            progressAfter=\(progressAfter)
            """,
            named: "Reader Flow Metrics"
        )
    }

    @MainActor
    func testReaderTOCCurrentAccessibilityContract() throws {
        let app = launchIsolatedApp(
            fixtures: [.authSignedIn, .readerRealBookLibrary],
            extraEnvironment: Self.fixtureEnvironment,
            perfLog: "reader-toc-accessibility-contract"
        )
        let bookshelf = AppPage(app: app).goToBookshelf()
        XCTAssertTrue(bookshelf.anyBookCard.waitUntilExists(timeout: 10))

        let reader = ReaderPage(app: app)
        bookshelf.anyBookCard.tapWhenReady()
        XCTAssertTrue(reader.webView.waitUntilExists(timeout: 45))
        reader.expandHeaderButton.tapWhenReady()

        let tocButton = reader.tableOfContentsButton
        XCTAssertTrue(tocButton.waitUntilHittable(timeout: 10))
        XCTAssertFalse(tocButton.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        tocButton.tap()

        XCTAssertTrue(reader.waitUntilTableOfContentsSheetExists(timeout: 10))
        XCTAssertTrue(reader.tableOfContentsSheet.waitUntilExists(timeout: 10))

        XCTAssertTrue(reader.tocDone.waitUntilExists(timeout: 10))
        XCTAssertFalse(reader.tocDone.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(reader.tocDone.isEnabled)

        let idleState = "phase=idle;selected=;expected=;destination="
        XCTAssertTrue(reader.tocNavigationStateReceipt.waitUntilExists(timeout: 10))
        XCTAssertTrue(reader.tocNavigationStateReceipt.waitUntilValueEquals(idleState, timeout: 10))

        let chapterRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "reader.toc.chapter.")
        )
        XCTAssertEqual(chapterRows.count, 2)

        let introduction = reader.tocChapter(path: "0", label: "Introduction")
        let practice = reader.tocChapter(path: "1", label: "Chapter Two — Practice")
        XCTAssertTrue(introduction.waitUntilHittable(timeout: 10))
        XCTAssertTrue(practice.waitUntilHittable(timeout: 10))
        XCTAssertEqual(introduction.value as? String, "OEBPS/chapter1.xhtml")
        XCTAssertEqual(practice.value as? String, "OEBPS/chapter2.xhtml")
        XCTAssertFalse(introduction.isSelected)
        XCTAssertFalse(practice.isSelected)
        XCTAssertTrue(ReaderTOCEvidenceHref.isSafeRelative(introduction.value as? String ?? ""))
        XCTAssertTrue(ReaderTOCEvidenceHref.isSafeRelative(practice.value as? String ?? ""))

        practice.tapWhenReady()
        // The navigation-state receipt lives inside the TOC sheet and disappears
        // with it as soon as navigation succeeds, so it cannot be polled for a
        // transient success value.  Success is proven outside the sheet: the
        // reader overlay, the destination locator, and the sheet dismissing.
        XCTAssertTrue(reader.tocReaderOverlaySuccess.waitUntilExists(timeout: 15))
        guard reader.tocDestination.waitUntilExists(timeout: 10),
              let destinationHref = reader.tocDestination.value as? String
        else {
            XCTFail("valid Reader TOC navigation must expose a destination locator")
            return
        }
        XCTAssertEqual(destinationHref, "OEBPS/chapter2.xhtml")
        XCTAssertTrue(reader.waitUntilTableOfContentsSheetGone(timeout: 10))
    }

    @MainActor
    func testReaderTOCRequiredRealBookSelectionClosesOnlyAfterSuccess() throws {
        let app = launchIsolatedApp(
            fixtures: [.authSignedIn, .readerRealBookLibrary],
            extraEnvironment: Self.fixtureEnvironment,
            perfLog: "reader-toc-required"
        )
        let bookshelf = AppPage(app: app).goToBookshelf()
        XCTAssertTrue(bookshelf.anyBookCard.waitUntilExists(timeout: 10))

        let reader = ReaderPage(app: app)
        bookshelf.anyBookCard.tapWhenReady()
        XCTAssertTrue(reader.webView.waitUntilExists(timeout: 45))
        reader.assertReaderWebViewSurface()
        guard reader.currentLocator.waitUntilExists(timeout: 10) else {
            XCTFail("valid Reader fixture 必須暴露初始 locator")
            return
        }
        guard let initialHref = reader.currentLocator.value as? String else {
            XCTFail("valid Reader fixture 初始 locator 必須是非空字串")
            return
        }
        XCTAssertEqual(initialHref, "OEBPS/chapter1.xhtml")
        reader.expandHeaderButton.tapWhenReady()
        reader.tableOfContentsButton.tapWhenReady()
        XCTAssertTrue(reader.waitUntilTableOfContentsSheetExists(timeout: 10))
        XCTAssertTrue(reader.tocLoading.waitUntilGone(timeout: 10))
        let selectedChapter = reader.tocChapter("1")
        XCTAssertTrue(selectedChapter.waitUntilExists(timeout: 10))
        let selectedRowTitle = selectedChapter.label
        let selectedRowHref = try XCTUnwrap(selectedChapter.value as? String)
        XCTAssertEqual(selectedRowHref, "OEBPS/chapter2.xhtml")
        captureStep("toc-loaded", app: app)
        captureStep("toc-open", app: app)

        selectedChapter.tapWhenReady()
        // The iOS 26.4 AX bridge may fold SwiftUI ProgressView/Text children
        // out of the hierarchy during a fast Readium transition. The stable
        // contract is the sheet parent: a selection must not dismiss before
        // the production state machine reports success.
        XCTAssertTrue(reader.isTableOfContentsSheetPresent)
        captureStep("chapter-select", app: app)
        captureStep("toc-selection-loading", app: app)

        XCTAssertTrue(reader.tocReaderOverlaySuccess.waitUntilExists(timeout: 10))
        guard reader.tocDestination.waitUntilExists(timeout: 10) else {
            XCTFail("valid Reader TOC navigation 必須暴露 destination locator")
            return
        }
        guard let destinationHref = reader.tocDestination.value as? String else {
            XCTFail("valid Reader TOC destination locator 必須是非空字串")
            return
        }
        XCTAssertEqual(destinationHref, "OEBPS/chapter2.xhtml")
        guard reader.currentLocator.waitUntilExists(timeout: 10) else {
            XCTFail("valid Reader 翻頁後必須暴露 current locator")
            return
        }
        guard let finalHref = reader.currentLocator.value as? String else {
            XCTFail("valid Reader 翻頁後 locator 必須是非空字串")
            return
        }
        XCTAssertEqual(finalHref, "OEBPS/chapter2.xhtml")
        XCTAssertNotEqual(initialHref, finalHref)
        let destinationContent = reader.contentText(Self.secondChapterContent)
        guard destinationContent.waitUntilExists(timeout: 10) else {
            XCTFail("valid Reader TOC destination 必須暴露 Chapter Two 內容")
            return
        }
        let observedContent = destinationContent.label
        XCTAssertEqual(observedContent, Self.secondChapterContent)
        XCTAssertFalse(reader.contentText(Self.seededWord).exists)
        try writeReaderTOCEvidence(
            label: "reader-toc-required",
            partition: "required",
            fixtureID: "reader.realBookLibrary",
            assetID: "books.reader_real_book_epub",
            path: [1],
            href: "OEBPS/chapter2.xhtml",
            locatorHref: finalHref,
            destinationSelector: "reader.toc.readerOverlay.destination",
            contentSelector: Self.secondChapterContent,
            observedContent: observedContent,
            selectedRowObservation: ReaderTOCEvidenceSelectedRow(
                path: [1],
                href: selectedRowHref,
                title: selectedRowTitle
            )
        )
        // Readium can rebuild the WebKit AX subtree as a screenshot is taken;
        // persist the machine evidence while the just-asserted content node is
        // live, then capture the visual artifacts as a separate side effect.
        captureStep("toc-destination-content", app: app)
        captureStep("toc-navigation-result", app: app)
        XCTAssertTrue(reader.waitUntilTableOfContentsSheetGone(timeout: 10))
        reader.assertIsActive()
        captureStep("toc-navigation-success", app: app)
    }

    @MainActor
    func testReaderTOCInvalidRealBookKeepsSheetOpenAndRetryable() throws {
        let app = launchIsolatedApp(
            fixtures: [.authSignedIn, .readerInvalidDestinationLibrary],
            extraEnvironment: Self.fixtureEnvironment,
            perfLog: "reader-toc-invalid-destination"
        )
        captureStep("invalid-destination-launch", app: app)

        let bookshelf = AppPage(app: app).goToBookshelf()
        XCTAssertTrue(bookshelf.anyBookCard.waitUntilExists(timeout: 10))
        XCTAssertTrue(
            bookshelf.anyBookCard.label.contains("Reader Invalid Destination"),
            "invalid-destination fixture must materialize the real counterexample EPUB"
        )

        let reader = ReaderPage(app: app)
        bookshelf.anyBookCard.tapWhenReady()
        XCTAssertTrue(reader.webView.waitUntilExists(timeout: 45))
        reader.assertReaderWebViewSurface()
        captureStep("invalid-destination-reader-open", app: app)
        guard reader.currentLocator.waitUntilExists(timeout: 10) else {
            XCTFail("invalid Reader fixture 必須暴露初始 locator")
            return
        }
        guard let invalidInitialHref = reader.currentLocator.value as? String else {
            XCTFail("invalid Reader fixture 初始 locator 必須是非空字串")
            return
        }
        XCTAssertEqual(invalidInitialHref, "OEBPS/chapter1.xhtml")
        guard reader.contentText("Introduction").waitUntilExists(timeout: 10) else {
            XCTFail("invalid Reader fixture 必須暴露 Introduction 內容")
            return
        }
        guard reader.evidenceAsset.waitUntilExists(timeout: 10) else {
            XCTFail("invalid Reader fixture 必須暴露 asset integrity proof")
            return
        }
        reader.assertFixtureAsset(
            assetID: "books.reader_invalid_destination_epub",
            fileName: "reader-invalid-destination.epub",
            sha256: Self.invalidDestinationAssetSHA256,
            byteSize: 17344
        )

        reader.expandHeaderButton.tapWhenReady()
        reader.tableOfContentsButton.tapWhenReady()
        XCTAssertTrue(reader.waitUntilTableOfContentsSheetExists(timeout: 10))
        let invalidRow = reader.tocChapter("1")
        XCTAssertTrue(invalidRow.waitUntilExists(timeout: 10))
        guard let invalidHref = invalidRow.value as? String,
              ReaderTOCEvidenceHref.isSafeRelative(invalidHref) else {
            XCTFail("invalid Reader TOC row must expose a non-empty safe relative href")
            return
        }
        XCTAssertFalse(invalidHref.isEmpty)
        let canonicalInvalidRow = reader.tocChapter(path: "1", label: "Missing Destination")
        captureStep("invalid-destination-toc-loaded", app: app)

        // This is the actual Link produced by Readium from the invalid EPUB's
        // nav.xhtml. No command-line href, synthetic View link, or fake
        // navigator participates in this path.
        canonicalInvalidRow.tapWhenReady()
        XCTAssertTrue(reader.tocMissingDestination.waitUntilExists(timeout: 10))
        XCTAssertTrue(reader.tocRetry.waitUntilExists(timeout: 10))
        XCTAssertEqual(reader.tocMissingDestinationCount, 1)
        XCTAssertEqual(reader.tocRetryCount, 1)
        XCTAssertTrue(reader.isTableOfContentsSheetPresent)
        XCTAssertFalse(reader.tocDone.isEnabled)
        XCTAssertEqual(reader.currentLocator.value as? String, "OEBPS/chapter1.xhtml")
        reader.assertContentAbsent(Self.secondChapterContent)
        reader.assertFixtureAsset(
            assetID: "books.reader_invalid_destination_epub",
            fileName: "reader-invalid-destination.epub",
            sha256: Self.invalidDestinationAssetSHA256,
            byteSize: 17344
        )
        captureStep("invalid-destination-missing", app: app)
        captureStep("missing-chapter", app: app)
        try writeReaderTOCEvidence(
            label: "reader-toc-counterexample-failure",
            partition: "counterexample",
            fixtureID: "reader.invalidDestinationLibrary",
            assetID: "books.reader_invalid_destination_epub",
            path: [1],
            href: invalidHref,
            locatorHref: invalidInitialHref
        )

        reader.tocRetry.tapWhenReady()
        XCTAssertTrue(reader.tocMissingDestination.waitUntilExists(timeout: 10))
        XCTAssertTrue(reader.tocRetry.waitUntilExists(timeout: 10))
        XCTAssertEqual(reader.tocMissingDestinationCount, 1)
        XCTAssertEqual(reader.tocRetryCount, 1)
        XCTAssertTrue(reader.isTableOfContentsSheetPresent)
        XCTAssertFalse(reader.tocDone.isEnabled)
        reader.assertIsActive()
        XCTAssertEqual(reader.currentLocator.value as? String, "OEBPS/chapter1.xhtml")
        reader.assertContentAbsent(Self.secondChapterContent)
        reader.assertFixtureAsset(
            assetID: "books.reader_invalid_destination_epub",
            fileName: "reader-invalid-destination.epub",
            sha256: Self.invalidDestinationAssetSHA256,
            byteSize: 17344
        )
        captureStep("invalid-destination-retry-still-open", app: app)
        captureStep("navigation-failure", app: app)
        try writeReaderTOCEvidence(
            label: "reader-toc-counterexample-retry",
            partition: "counterexample",
            fixtureID: "reader.invalidDestinationLibrary",
            assetID: "books.reader_invalid_destination_epub",
            path: [1],
            href: invalidHref,
            locatorHref: invalidInitialHref
        )
        attachText(
            "fixture=reader.invalidDestinationLibrary\nasset=books.reader_invalid_destination_epub\n"
                + "expected=reader.toc.missingDestination + reader.toc.retry + sheet-open",
            named: "Reader Invalid Destination Metrics"
        )
    }

    @MainActor
    func testReaderRuntimeProgressStatesArePreciselySelectableWithProvenance() throws {
        let scenarios: [UITestReaderProgressScenario] = [
            .progressUnknown,
            .progressZero,
            .progressMiddle,
            .progressComplete,
            .progressRestoreFailure
        ]

        for scenario in scenarios {
            let app = launchIsolatedApp(
                fixtures: [.authSignedIn, .readerRealBookLibrary, .readerRuntime(scenario.runtimeScenario)],
                extraEnvironment: Self.fixtureEnvironment,
                perfLog: "reader"
            )
            let bookshelf = AppPage(app: app).goToBookshelf()
            XCTAssertTrue(bookshelf.anyBookCard.waitUntilExists(timeout: 10))
            bookshelf.anyBookCard.tapWhenReady()

            let reader = ReaderPage(app: app)
            XCTAssertTrue(reader.runtimeState.waitUntilExists(timeout: 5))
            XCTAssertEqual(reader.runtimeStateCount, 1, "Reader runtime state selector must resolve exactly one element")
            if scenario == .progressRestoreFailure {
                captureStep("restore-failure-counterexample", app: app)
                XCTAssertTrue(
                    reader.runtimeState.waitUntilValueContains("progress=restore-failure", timeout: 5),
                    "Restore-failure counterexample must expose the warning state before recovery"
                )
                XCTAssertTrue(
                    reader.currentLocator.waitUntilExists(timeout: 45),
                    "Restore-failure scenario must publish the recovered Readium locator"
                )
                XCTAssertEqual(
                    reader.currentLocator.value as? String,
                    "OEBPS/chapter1.xhtml",
                    "Restore-failure scenario must recover to the first real reading-order resource"
                )
                XCTAssertTrue(
                    reader.contentText("Introduction").waitUntilExists(timeout: 45),
                    "Restore-failure scenario must render real EPUB content after recovery"
                )
                XCTAssertTrue(
                    UITestWaits.wait(
                        for: NSPredicate(
                            format: "exists == true AND (value CONTAINS[c] %@ OR value CONTAINS[c] %@ OR value CONTAINS[c] %@)",
                            "progress=zero",
                            "progress=middle",
                            "progress=complete"
                        ),
                        on: reader.runtimeState,
                        timeout: 5
                    ),
                    "Restore-failure scenario must converge to a valid Readium progress state"
                )
            }
            let provenance = String(describing: reader.runtimeState.value ?? reader.runtimeState.label)
            XCTAssertTrue(provenance.contains("dataset=marketing_demo"), provenance)
            XCTAssertTrue(provenance.contains("scenario=\(scenario.rawValue)"), provenance)
            if scenario == .progressRestoreFailure {
                // The production restore warning is intentionally cleared by
                // the first valid Readium location. Assert its stable runtime
                // provenance here; the transition itself is covered by the
                // ReaderRuntimeState unit tests.
                XCTAssertTrue(provenance.contains("progress="), provenance)
            } else {
                XCTAssertTrue(
                    reader.progressState(scenario).waitUntilExists(timeout: 20),
                    "Reader progress state must expose exact identifier: \(scenario.rawValue)"
                )
                XCTAssertEqual(reader.progressStateCount(scenario), 1,
                               "Reader progress state selector must resolve exactly one element: \(scenario.rawValue)")
            }
            switch scenario {
            case .progressUnknown:
                captureStep("progress-zero-counterexample", app: app)
            case .progressZero:
                captureStep("progress-zero", app: app)
            case .progressMiddle:
                captureStep("progress-middle", app: app)
            case .progressComplete:
                captureStep("progress-complete", app: app)
            case .progressRestoreFailure:
                captureStep("restore-failure", app: app)
            }
            captureStep("loaded", app: app)
            app.terminate()
        }
    }

    @MainActor
    func testReaderRuntimeLoadingScenariosAreControllableAndRetryToSuccess() throws {
        for scenario in [
            UITestReaderRuntimeScenario.loadingSlow,
            .loadingMissing,
            .loadingErrorRetry,
            .loadingEmpty
        ] {
            let app = launchIsolatedApp(
                fixtures: [.authSignedIn, .readerRealBookLibrary, .readerRuntime(scenario)],
                extraEnvironment: Self.fixtureEnvironment,
                perfLog: "reader"
            )
            let bookshelf = AppPage(app: app).goToBookshelf()
            XCTAssertTrue(bookshelf.anyBookCard.waitUntilExists(timeout: 10))
            bookshelf.anyBookCard.tapWhenReady()

            let reader = ReaderPage(app: app)
            if scenario == .loadingEmpty {
                XCTAssertTrue(reader.emptyState.waitUntilExists(timeout: 10),
                               "Empty route must render a visible reader.empty card")
                XCTAssertEqual(reader.emptyStateCount, 1,
                               "Reader empty selector must resolve exactly one visible card")
                XCTAssertEqual(reader.retryButtonCount, 1,
                               "Reader empty route must expose exactly one retry CTA")
                captureStep("empty", app: app)
                app.terminate()
                continue
            }

            if scenario == .loadingSlow {
                XCTAssertTrue(reader.loadingState(scenario).waitUntilExists(timeout: 10))
                XCTAssertEqual(reader.loadingStateCount(scenario), 1,
                               "Reader loading selector must resolve exactly one element: \(scenario.rawValue)")
                captureStep("loading", app: app)
                captureStep("launch-loading", app: app)
                reader.slowLoadingResolveButton.tapWhenReady()
                XCTAssertTrue(reader.loadingState(scenario).waitUntilGone(timeout: 10),
                               "Resolved slow-loading overlay must disappear")
                captureStep("retry", app: app)
            } else {
                let error = reader.errorState(scenario)
                XCTAssertTrue(error.waitUntilExists(timeout: 10))
                XCTAssertEqual(reader.errorStateCount(scenario), 1,
                               "Reader error selector must resolve exactly one element: \(scenario.rawValue)")
                XCTAssertEqual(reader.retryButtonCount, 1,
                               "Reader retry selector must resolve exactly one button")
                if scenario == .loadingMissing {
                    captureStep("error", app: app)
                } else {
                    captureStep("error-variant", app: app)
                }
                if scenario == .loadingMissing {
                    captureStep("error-counterexample", app: app)
                }
                reader.retryButton.tapWhenReady()
                XCTAssertTrue(error.waitUntilGone(timeout: 10),
                              "Error card must disappear after retry")
                XCTAssertEqual(reader.errorStateCount(scenario), 0,
                               "Error selector must be absent after retry")
                XCTAssertEqual(reader.retryButtonCount, 0,
                               "Retry CTA must disappear after retry starts")
                captureStep("retry", app: app)
                if scenario == .loadingMissing {
                    captureStep("retry-success-counterexample", app: app)
                }
            }

            XCTAssertTrue(
                reader.contentText(Self.seededWord).waitUntilExists(timeout: 45),
                "Retry path must open the local fixture book for \(scenario.rawValue)"
            )
            XCTAssertEqual(reader.loadingOverlayCount, 0,
                           "Loading overlay must disappear after loaded content")
            XCTAssertEqual(reader.retryButtonCount, 0,
                           "Retry CTA must remain absent after loaded content")
            captureStep("loaded", app: app)
            if scenario == .loadingErrorRetry {
                captureStep("retry-success", app: app)
            }
            app.terminate()
        }
    }
}
