import XCTest

/// Flip-gap investigation (`debug/review-flip-gap`).
///
/// Reproduces + measures the reported bug: after some flips the card detaches
/// from the bottom "tap to expand" zone, leaving a large vertical gap that
/// persists across flips and only resets on shuffle. Two hypotheses, both a
/// consequence of the Phase-4 resident-slot ZStack taking its layout height
/// from the TALLEST of its three slots:
///   - H1 (content height): a taller background card (preview / underPreview)
///     inflates the region and pushes the expand zone down. Repro signature =
///     gap appears at a SHORT active card that has a TALL neighbour in its
///     preview window.
///   - H2 (stuck answer): a recycled slot's answer surface fails to collapse to
///     height 0 after grading. Repro signature = gap appears even when the whole
///     preview window is short (e.g. `gapshort2`, whose window is 3 short cards).
///
/// The deck (`notebook:reviewDeckVaried`) is deliberately height-varied so both
/// signatures are observable in one run. The on-screen gap is measured directly
/// as `expandZone.minY − cardFront.maxY`. The DEBUG `gap.geom` PerfLog emits only
/// per-slot (`kind=slot`) and deck (`kind=deck`) layout heights today; it
/// attributes the inflating slot but does not measure the answer surface, so
/// it cannot by itself give a decisive H1-vs-H2 verdict.
final class TodayReviewGapUITests: UITestCase {
    private static let notebookCardID = "ui-review-notebook"
    private static let deckSize = 8
    /// Healthy gap = card-bottom inset + micro offsets (tens of pt). A tall
    /// background slot inflates it by the card-height delta (100pt+), so a
    /// generous 44pt threshold cleanly separates healthy from bug.
    private static let gapThreshold: CGFloat = 44
    /// The grading toolbar is the last sibling in the full-screen review
    /// column. A collapsed root column leaves this much more space below the
    /// buttons than the safe-area/home-indicator inset should allow.
    private static let toolbarBottomSlackThreshold: CGFloat = 120

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 8 cards × (reveal + grade) springs push this past the 60s default.
        executionTimeAllowance = 240
    }

    private struct GapSample {
        let index: Int
        let word: String
        let gap: CGFloat
        let cardHeight: CGFloat
        let cardMaxY: CGFloat
        let zoneMinY: CGFloat
    }

    private struct ToolbarSample {
        let index: Int
        let face: String
        let word: String
        let buttonMaxY: CGFloat
        let appMaxY: CGFloat

        var bottomSlack: CGFloat { appMaxY - buttonMaxY }
    }

    @MainActor
    func testCardStaysAttachedToExpandZoneAcrossVariedDeck() throws {
        let app = launchIsolatedApp(
            fixtures: [.notebookReviewDeckVaried],
            perfLog: "review"
        )
        captureStep("launch", app: app)

        let notebook = AppPage(app: app).goToNotebooks()
        guard notebook.notebookCard(id: Self.notebookCardID).waitUntilExists(timeout: 10) else {
            captureStep("no-notebook-card", app: app)
            XCTFail("varied review deck fixture 應種出單字本卡片 \(Self.notebookCardID)")
            return
        }
        guard notebook.reviewCTAButton.waitUntilExists(timeout: 10) else {
            captureStep("no-review-cta", app: app)
            XCTFail("varied deck 有未學卡片，複習 CTA 必須出現")
            return
        }
        let review = notebook.startReview()
        guard review.progressLabel.waitUntilExists(timeout: 10) else {
            captureStep("review-not-started", app: app)
            XCTFail("tap CTA 後必須進入複習 session；progress label 缺席")
            return
        }

        var samples: [GapSample] = []

        for i in 0..<Self.deckSize {
            // Settle before reading frames (grading fling + advance spring).
            _ = review.cardFront.waitUntilExists(timeout: 8)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            guard review.cardFront.exists, review.expandZone.exists else {
                captureStep("card-\(i)-missing-elements", app: app)
                XCTFail("card \(i) 缺 cardFront/expandZone，無法量到版面")
                break
            }

            let word = review.frontWord
            let cardFrame = review.cardFront.frame
            let zoneFrame = review.expandZone.frame
            let gap = zoneFrame.minY - cardFrame.maxY
            samples.append(GapSample(
                index: i,
                word: word,
                gap: gap,
                cardHeight: cardFrame.height,
                cardMaxY: cardFrame.maxY,
                zoneMinY: zoneFrame.minY
            ))

            // 逐張截圖：gap 斷言是數值 guard，截圖是視覺證據（此 bug 有視覺成分——
            // 被 cap 的較高背景卡若溢出會顯示在 expand zone 區）。命名含 gap 值。
            captureStep("card-\(i)-\(word)-gap\(Int(gap))", app: app)

            // Advance: reveal + grade (exercises the answer-collapse path, H2).
            guard i < Self.deckSize - 1 else { break }
            review.flipCard()
            _ = review.cardBack.waitUntilExists(timeout: 5)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            review.tapRemembered()
            _ = review.waitForProgress("\(i + 2) / \(Self.deckSize)")
            _ = review.cardBack.waitUntilGone(timeout: 5)
        }

        // Full table → offline correlation with the gap.geom per-slot PerfLog.
        let table = samples.map { s in
            String(
                format: "  [%d] %@ gap=%.1f cardH=%.1f cardMaxY=%.1f zoneMinY=%.1f",
                s.index, s.word, s.gap, s.cardHeight, s.cardMaxY, s.zoneMinY
            )
        }.joined(separator: "\n")
        let tableAttachment = XCTAttachment(string: table)
        tableAttachment.name = "gap-samples"
        add(tableAttachment)

        XCTAssertEqual(
            samples.count, Self.deckSize,
            "樣本數必須等於牌組大小，否則表示中途量測中斷"
        )
        let offenders = samples.filter { $0.gap >= Self.gapThreshold }
        XCTAssertTrue(
            offenders.isEmpty,
            "卡片與 expand zone 出現大縫隙（gap >= \(Self.gapThreshold)pt）:\n"
                + offenders.map {
                    "  card[\($0.index)] \($0.word) gap=\(String(format: "%.1f", $0.gap))pt"
                        + " (cardH=\(String(format: "%.1f", $0.cardHeight)))"
                }.joined(separator: "\n")
                + "\n全表:\n" + table
        )
    }

    /// #3117: the fold chevron must expose a >= 44pt accessibility frame. The
    /// visual stays 48×30; the hit area grows only vertically (7pt per side),
    /// never wider than the pill. The band stays inside the 28pt face padding
    /// (ReviewFoldChevronHitBandTests pins that geometry), and the front flip is
    /// disabled whenever the band is live, so the band never competes with a flip.
    /// The hero speaker lives on the word detail document, covered in
    /// WordDetailFlowUITests (review backs no longer mount CardDocumentView).
    @MainActor
    func testFoldChevronExposesMinimumHitTarget() throws {
        let app = launchIsolatedApp(
            fixtures: [.notebookReviewDeckVaried],
            perfLog: "review"
        )
        let notebook = AppPage(app: app).goToNotebooks()
        guard notebook.notebookCard(id: Self.notebookCardID).waitUntilExists(timeout: 10) else {
            captureStep("hit-target-no-notebook-card", app: app)
            XCTFail("varied review deck fixture 應種出單字本卡片 \(Self.notebookCardID)")
            return
        }
        guard notebook.reviewCTAButton.waitUntilExists(timeout: 10) else {
            captureStep("hit-target-no-review-cta", app: app)
            XCTFail("varied deck 有未學卡片，複習 CTA 必須出現")
            return
        }
        let review = notebook.startReview()
        guard review.progressLabel.waitUntilExists(timeout: 10) else {
            captureStep("hit-target-review-not-started", app: app)
            XCTFail("tap CTA 後必須進入複習 session；progress label 缺席")
            return
        }
        _ = review.cardFront.waitUntilExists(timeout: 8)
        _ = review.flipCard()
        _ = review.cardBack.waitUntilExists(timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        captureStep("hit-target-back", app: app)

        assertMinimumHitTarget(review.foldCollapseButton, name: "fold chevron")
        // Bound the hit band: it may extend vertically past the 30pt visual,
        // but must never exceed the 48pt pill width (no sideways card intrusion).
        let fold = review.foldCollapseButton.frame
        XCTAssertLessThanOrEqual(
            fold.width, 48,
            "fold chevron hit 寬度不得超過 48pt pill，實際 \(fold.width)"
        )
        XCTAssertLessThanOrEqual(
            fold.height, 44,
            "fold chevron hit 高度應只向上下各外擴 7pt（<=44），實際 \(fold.height)"
        )
        // A tap inside the enlarged band but above the 48×30 visual (4pt below the
        // frame top sits ~18pt above the seam) is the chevron's own target and must
        // collapse the answer.
        review.foldCollapseButton
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 4.0 / 44.0))
            .tap()
        XCTAssertTrue(
            review.cardBack.waitUntilGone(timeout: 5),
            "點在命中帶上緣（pill 外、44pt 框內）必須收合答案"
        )
    }

    @MainActor
    private func assertMinimumHitTarget(
        _ element: XCUIElement,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("\(name) 必須存在於複習畫面", file: file, line: line)
            return
        }
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(
            frame.width, 44,
            "\(name) hit target 寬度必須 >= 44pt，實際 \(frame.width)",
            file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.height, 44,
            "\(name) hit target 高度必須 >= 44pt，實際 \(frame.height)",
            file: file, line: line
        )
    }

    /// Regression for the reported screenshot: after a reveal/advance cycle,
    /// the outer review column can be recomputed at intrinsic content height.
    /// The card and grading toolbar then move upward together, leaving a large
    /// empty area below the buttons. Assert the toolbar in both face states so
    /// a fix cannot only mask the front-stage transition.
    @MainActor
    func testGradingToolbarRemainsAttachedToBottomAcrossFaceTransitions() throws {
        let app = launchIsolatedApp(
            fixtures: [.notebookReviewDeckVaried],
            perfLog: "review"
        )
        captureStep("launch", app: app)

        let notebook = AppPage(app: app).goToNotebooks()
        guard notebook.notebookCard(id: Self.notebookCardID).waitUntilExists(timeout: 10),
              notebook.reviewCTAButton.waitUntilExists(timeout: 10) else {
            captureStep("review-not-ready", app: app)
            XCTFail("varied review deck 應能進入 Today Review")
            return
        }
        let review = notebook.startReview()
        guard review.progressLabel.waitUntilExists(timeout: 10) else {
            captureStep("review-not-started", app: app)
            XCTFail("Today Review progress label 缺席")
            return
        }

        var samples: [ToolbarSample] = []
        for i in 0..<Self.deckSize {
            guard review.cardFront.waitUntilExists(timeout: 8),
                  review.rememberedButton.waitUntilExists(timeout: 8) else {
                captureStep("front-\(i)-missing", app: app)
                XCTFail("front \(i) 的 card/toolbar 必須存在")
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            samples.append(
                ToolbarSample(
                    index: i,
                    face: "front",
                    word: review.frontWord,
                    buttonMaxY: review.rememberedButton.frame.maxY,
                    appMaxY: app.frame.maxY
                )
            )

            guard i < Self.deckSize - 1 else { break }
            review.flipCard()
            guard review.cardBack.waitUntilExists(timeout: 5) else {
                captureStep("back-\(i)-missing", app: app)
                XCTFail("front \(i) 翻面後 back 必須存在")
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            samples.append(
                ToolbarSample(
                    index: i,
                    face: "back",
                    word: review.frontWord,
                    buttonMaxY: review.rememberedButton.frame.maxY,
                    appMaxY: app.frame.maxY
                )
            )

            review.tapRemembered()
            _ = review.waitForProgress("\(i + 2) / \(Self.deckSize)")
            _ = review.cardBack.waitUntilGone(timeout: 5)
        }

        let table = samples.map { sample in
            String(
                format: "  [%d] %@ %@ buttonMaxY=%.1f appMaxY=%.1f bottomSlack=%.1f",
                sample.index,
                sample.face,
                sample.word,
                sample.buttonMaxY,
                sample.appMaxY,
                sample.bottomSlack
            )
        }.joined(separator: "\n")
        let tableAttachment = XCTAttachment(string: table)
        tableAttachment.name = "toolbar-bottom-samples"
        add(tableAttachment)

        let offenders = samples.filter {
            $0.bottomSlack > Self.toolbarBottomSlackThreshold
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "評分按鈕底下出現異常大空白（bottomSlack > \(Self.toolbarBottomSlackThreshold)pt）:\n"
                + offenders.map {
                    "  [\($0.index)] \($0.face) \($0.word) bottomSlack=\(String(format: "%.1f", $0.bottomSlack))pt"
                }.joined(separator: "\n")
                + "\n全表:\n" + table
        )
    }
}
