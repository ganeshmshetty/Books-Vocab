import XCTest

final class ReaderSettingsUITests: UITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Reader settings evidence opens a real Readium EPUB repeatedly and
        // includes dark/sepia viewport counterexamples. Keep the allowance
        // on the XCTest case, where it actually governs the test body.
        executionTimeAllowance = 360
    }

    @MainActor
    func testReaderThemeGlassPickerExposesThreeAdaptiveTiles() throws {
        let app = launchIsolatedApp(
            fixtures: [.readerRealBookLibrary],
            perfLog: "reader-settings-theme-glass-picker"
        )
        let bookshelf = AppPage(app: app).goToBookshelf()
        guard let bookCard = bookshelf.exactlyOneBookCard(timeout: 10) else {
            XCTFail("Reader UI World must materialize exactly one book before settings can be opened")
            return
        }
        bookCard.tapWhenReady()

        let reader = ReaderPage(app: app)
        guard reader.waitForContent(ReaderPage.seededContentMarker, timeout: 45) else {
            XCTFail("production Reader must render the seeded book content")
            return
        }
        reader.openSettings()
        guard reader.settingsPreviewElement(timeout: 5) != nil else {
            XCTFail("Reader settings must expose the preview before theme tiles are inspected")
            return
        }

        var tileWidths: [CGFloat] = []
        for theme in ["light", "sepia", "dark"] {
            XCTAssertTrue(reader.selectTheme(theme), "theme tile must remain addressable: \(theme)")
            let option = reader.themeOption(theme)
            tileWidths.append(option.frame.width)
            XCTAssertGreaterThanOrEqual(option.frame.height, 44, "theme tile must preserve the HIG hit target")
            XCTAssertTrue(option.isHittable, "theme tile must remain hittable: \(theme)")
            XCTAssertFalse(option.label.isEmpty, "theme tile must expose its localized label: \(theme)")
            XCTAssertTrue(option.isSelected, "selected theme tile must expose the selected state: \(theme)")
            captureStep("\(theme)-theme-tile", app: app)
        }
        if let firstTileWidth = tileWidths.first {
            for width in tileWidths.dropFirst() {
                XCTAssertEqual(width, firstTileWidth, accuracy: 1, "adaptive theme tiles must remain equal width")
            }
        }

        XCTAssertTrue(reader.closeSettings(), "Reader settings must close through the production Done action")
    }

    @MainActor
    func testReaderSettingsTypographyAndHighlightControlsExposeBoundedInputs() throws {
        // Pin English so the exact VoiceOver labels below are deterministic (#2752).
        let app = launchIsolatedApp(
            extraArgs: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            fixtures: [.readerRealBookLibrary],
            perfLog: "reader-settings-typography-highlight-controls"
        )
        let bookshelf = AppPage(app: app).goToBookshelf()
        guard let bookCard = bookshelf.exactlyOneBookCard(timeout: 10) else {
            XCTFail("Reader UI World must materialize exactly one book before settings can be opened")
            return
        }
        bookCard.tapWhenReady()

        let reader = ReaderPage(app: app)
        guard reader.waitForContent(ReaderPage.seededContentMarker, timeout: 45) else {
            XCTFail("production Reader must render the seeded book content")
            return
        }
        reader.openSettings()

        guard let fontRow = reader.fontSizeAdjustmentRowElement(timeout: 10) else {
            XCTFail("Reader settings must expose the unified font-size adjustment row")
            return
        }
        XCTAssertFalse(fontRow.label.isEmpty)
        XCTAssertFalse(String(describing: fontRow.value ?? "").isEmpty)
        XCTAssertTrue(reader.fontSizeDecrementButton.exists)
        XCTAssertTrue(reader.fontSizeIncrementButton.exists)
        XCTAssertEqual(
            reader.fontSizeDecrementButton.label,
            "Decrease Text Size",
            "icon-only font-size decrement must expose its localized VoiceOver label"
        )
        XCTAssertEqual(
            reader.fontSizeIncrementButton.label,
            "Increase Text Size",
            "icon-only font-size increment must expose its localized VoiceOver label"
        )
        XCTAssertGreaterThanOrEqual(reader.fontSizeIncrementButton.frame.height, 44)
        XCTAssertGreaterThanOrEqual(reader.fontSizeDecrementButton.frame.height, 44)

        guard let lineHeightRow = reader.lineHeightAdjustmentRowElement(timeout: 10) else {
            XCTFail("Reader settings must expose one line-height adjustment row")
            return
        }
        XCTAssertFalse(lineHeightRow.label.isEmpty)
        XCTAssertFalse(String(describing: lineHeightRow.value ?? "").isEmpty)
        XCTAssertEqual(
            reader.lineHeightAdjustmentRowCount,
            1,
            "Reader settings must expose exactly one line-height adjustment row"
        )
        XCTAssertEqual(
            reader.lineHeightNativeSliderCount,
            0,
            "Reader settings must not expose the obsolete native line-height slider"
        )
        guard let lineHeightDecrementButton = reader.lineHeightDecrementButtonElement(timeout: 5),
              let lineHeightIncrementButton = reader.lineHeightIncrementButtonElement(timeout: 5)
        else {
            XCTFail("Reader settings must expose exactly one decrement and increment button for line height")
            return
        }
        XCTAssertGreaterThanOrEqual(lineHeightIncrementButton.frame.height, 44)
        XCTAssertGreaterThanOrEqual(lineHeightDecrementButton.frame.height, 44)

        guard let letterSpacingRow = reader.letterSpacingAdjustmentRowElement(timeout: 10) else {
            XCTFail("Reader settings must expose one letter-spacing adjustment row")
            return
        }
        XCTAssertFalse(letterSpacingRow.label.isEmpty)
        XCTAssertFalse(String(describing: letterSpacingRow.value ?? "").isEmpty)
        XCTAssertEqual(
            reader.letterSpacingAdjustmentRowCount,
            1,
            "Reader settings must expose exactly one letter-spacing adjustment row"
        )
        guard let letterSpacingDecrementButton = reader.letterSpacingDecrementButtonElement(timeout: 5),
              let letterSpacingIncrementButton = reader.letterSpacingIncrementButtonElement(timeout: 5)
        else {
            XCTFail("Reader settings must expose exactly one decrement and increment button for letter spacing")
            return
        }
        XCTAssertGreaterThanOrEqual(letterSpacingIncrementButton.frame.height, 44)
        XCTAssertGreaterThanOrEqual(letterSpacingDecrementButton.frame.height, 44)

        XCTAssertTrue(reader.adjustLetterSpacing(toValue: "0.0"))
        XCTAssertFalse(letterSpacingDecrementButton.isEnabled, "letter-spacing decrement must disable at 0.0")
        XCTAssertTrue(letterSpacingIncrementButton.isEnabled, "letter-spacing increment must remain enabled above 0.0")
        XCTAssertTrue(reader.adjustLetterSpacing(toValue: "1.0"))
        XCTAssertTrue(letterSpacingDecrementButton.isEnabled, "letter-spacing decrement must remain enabled below 1.0")
        XCTAssertFalse(letterSpacingIncrementButton.isEnabled, "letter-spacing increment must disable at 1.0")

        XCTAssertTrue(reader.adjustLineHeight(toValue: "1.0"))
        XCTAssertFalse(lineHeightDecrementButton.isEnabled, "line-height decrement must disable at 1.0")
        XCTAssertTrue(lineHeightIncrementButton.isEnabled, "line-height increment must remain enabled above 1.0")
        XCTAssertTrue(reader.adjustLineHeight(toValue: "2.5"))
        XCTAssertTrue(lineHeightDecrementButton.isEnabled, "line-height decrement must remain enabled below 2.5")
        XCTAssertFalse(lineHeightIncrementButton.isEnabled, "line-height increment must disable at 2.5")
        captureStep("typography-adjustment-rows", app: app)

        guard reader.revealHighlightControls(timeout: 10),
              let opacity = reader.highlightOpacitySliderElement(timeout: 5),
              let custom = reader.highlightCustomColorPickerElement(timeout: 5)
        else {
            XCTFail("Reader settings must expose the opacity step slider and custom sRGB picker")
            return
        }
        XCTAssertFalse(opacity.label.isEmpty)
        XCTAssertNotNil(opacity.value)
        XCTAssertTrue(opacity.isHittable)
        XCTAssertFalse(custom.label.isEmpty)
        XCTAssertTrue(custom.isHittable)
        captureStep("highlight-custom-srgb-and-opacity", app: app)
        XCTAssertTrue(reader.closeSettings(), "Reader settings must close through the production Done action")
    }

    @MainActor
    func testProductionReaderSettingsRoundTripAfterReaderReopen() throws {
        let app = launchIsolatedApp(
            fixtures: [.readerRealBookLibrary],
            perfLog: "reader-settings-production-roundtrip"
        )
        captureStep("launch", app: app)

        let bookshelf = AppPage(app: app).goToBookshelf()
        guard let bookCard = bookshelf.exactlyOneBookCard(timeout: 10) else {
            XCTFail("Reader UI World must materialize exactly one book before settings can be opened")
            return
        }
        bookCard.tapWhenReady()

        let reader = ReaderPage(app: app)
        guard reader.waitForContent(ReaderPage.seededContentMarker, timeout: 45),
              let initialWebView = reader.webViewElement(timeout: 10)
        else {
            XCTFail("production Reader must render the real EPUB WebView before settings evidence")
            return
        }
        let initialWebViewSize = initialWebView.frame.size
        XCTAssertGreaterThan(initialWebViewSize.width, 0)
        XCTAssertGreaterThan(initialWebViewSize.height, 0)

        guard reader.waitForSettingsStateContaining(["status=ready"], timeout: 45),
              let initialState = reader.settingsStateValue(timeout: 5),
              let initialNavigatorID = stateField("navigator", in: initialState),
              let initialFont = stateField("font", in: initialState),
              let initialFontSize = stateField("fontSize", in: initialState),
              let initialReadingMode = stateField("readingMode", in: initialState)
        else {
            XCTFail("production Reader must publish a complete initial Readium settings receipt")
            return
        }

        reader.openSettings()
        guard let preview = reader.settingsPreviewElement(timeout: 10),
              let panel = reader.settingsPanelElement(),
              reader.lineHeightAdjustmentRowElement(timeout: 5) != nil
        else {
            XCTFail("production Reader settings sheet must expose exact panel, preview, and line-height controls")
            return
        }
        captureStep("settings-open", app: app)

        let initialPreviewHeight = preview.frame.height
        XCTAssertGreaterThan(preview.frame.width, 0)
        // The AX frame is the SwiftUI Form row/container, not the inner
        // ReaderSettingsPreviewCard viewport. The 164pt viewport contract is
        // covered by ReaderPreviewStyleSourceTests; here we verify the live
        // production element has stable, non-zero geometry across the round trip.
        XCTAssertGreaterThan(initialPreviewHeight, 0)
        XCTAssertTrue(panel.frame.contains(preview.frame), "preview must remain inside the settings sheet geometry")

        // Mutate real persisted Reader settings, not the DEBUG preview harness.
        XCTAssertTrue(reader.adjustLineHeight(toValue: "1.0"))
        XCTAssertTrue(reader.waitForLineHeightValue("1", timeout: 5))
        XCTAssertTrue(reader.adjustLetterSpacing(toValue: "0.5"))
        XCTAssertTrue(reader.waitForLetterSpacingValue("0.5", timeout: 5))
        XCTAssertTrue(reader.selectTheme("dark"), "production theme option must be addressable")
        XCTAssertTrue(reader.themeIsSelected("dark"))
        XCTAssertTrue(reader.selectHighlightColor("blue"), "production highlight color option must be addressable")
        captureStep("settings-changed", app: app)
        captureStep("change-theme", app: app)
        captureStep("change-highlight", app: app)
        XCTAssertTrue(reader.closeSettings(), "settings sheet must close through its production Done action")

        let expectedState = [
            "status=ready",
            "source=presentationDidChange",
            "font=\(initialFont)",
            "fontSize=\(initialFontSize)",
            "lineHeight=1.00",
            "letterSpacing=0.50",
            "readingMode=\(initialReadingMode)",
            "theme=dark"
        ]
        XCTAssertTrue(
            reader.waitForSettingsStateContaining(expectedState),
            "closed production Reader must expose the applied settings bridge state"
        )
        guard let changedState = reader.settingsStateValue(timeout: 5),
              let changedNavigatorID = stateField("navigator", in: changedState)
        else {
            XCTFail("closed production Reader must expose a parseable navigator receipt")
            return
        }
        XCTAssertEqual(changedNavigatorID, initialNavigatorID)

        // Dismantle the real Reader/WebView, then open the same book again.
        let reopenedBookshelf = reader.goBack()
        guard let reopenedBookCard = reopenedBookshelf.exactlyOneBookCard(timeout: 10) else {
            XCTFail("Reader close must return to a deterministic one-card bookshelf")
            return
        }
        reopenedBookCard.tapWhenReady()
        guard reader.waitForContent(ReaderPage.seededContentMarker, timeout: 45),
              let reopenedWebView = reader.webViewElement(timeout: 10)
        else {
            XCTFail("reopened production Reader must recreate the real EPUB WebView")
            return
        }

        XCTAssertEqual(reopenedWebView.frame.size.width, initialWebViewSize.width, accuracy: 1)
        XCTAssertEqual(reopenedWebView.frame.size.height, initialWebViewSize.height, accuracy: 1)
        XCTAssertTrue(
            reader.waitForSettingsStateContaining(expectedState),
            "reopened production WebView must receive the persisted settings/theme/line-spacing state"
        )
        guard let reopenedState = reader.settingsStateValue(timeout: 5),
              let reopenedNavigatorID = stateField("navigator", in: reopenedState)
        else {
            XCTFail("reopened production Reader must expose a parseable navigator receipt")
            return
        }
        XCTAssertNotEqual(
            reopenedNavigatorID,
            changedNavigatorID,
            "close/reopen must publish a new live Readium navigator identity"
        )

        reader.openSettings()
        guard let reopenedPreview = reader.settingsPreviewElement(timeout: 10) else {
            XCTFail("reopened Reader settings must expose the real preview")
            return
        }
        captureStep("settings-reopened", app: app)
        XCTAssertEqual(reopenedPreview.frame.height, initialPreviewHeight, accuracy: 1)
        XCTAssertTrue(reader.waitForLineHeightValue("1", timeout: 5))
        XCTAssertTrue(reader.waitForLetterSpacingValue("0.5", timeout: 5))
        XCTAssertTrue(reader.themeIsSelected("dark"))
        XCTAssertTrue(reader.resetReaderSettings(), "Reader settings must expose the production reset action")
        captureStep("reset", app: app)
    }

    private func stateField(_ key: String, in value: String) -> String? {
        value
            .split(separator: ";")
            .first(where: { $0.hasPrefix("\(key)=") })
            .map { String($0.dropFirst(key.count + 1)) }
    }

    @MainActor
    func testReaderPreviewKeepsViewportAcrossDarkAndSepiaCounterexamples() throws {
        let app = launchIsolatedApp(
            fixtures: [.readerRealBookLibrary],
            perfLog: "reader-settings-themes"
        )
        let bookshelf = AppPage(app: app).goToBookshelf()
        guard let bookCard = bookshelf.exactlyOneBookCard(timeout: 10) else {
            XCTFail("Reader UI World must materialize exactly one book before settings can be opened")
            return
        }
        bookCard.tapWhenReady()

        let reader = ReaderPage(app: app)
        guard reader.waitForContent(ReaderPage.seededContentMarker, timeout: 45) else {
            XCTFail("production Reader must render the seeded book content")
            return
        }
        XCTAssertTrue(
            reader.waitForSettingsStateContaining(["status=ready"], timeout: 45),
            "Dynamic Type Reader must expose the live navigator state receipt in AX"
        )
        reader.openSettings()

        guard reader.showPreview(), let initialPreview = reader.settingsPreviewElement(timeout: 5) else {
            XCTFail("Reader settings preview must be visible before theme counterexamples")
            return
        }
        guard let initialLineHeight = reader.lineHeightValue(timeout: 5) else {
            XCTFail("Reader preview must expose its initial numeric line-height value")
            return
        }
        // The canonical UI World explicitly seeds 2.1 in both UserDefaults and
        // iCloud KVS. Keep this assertion bound to that fixture contract; a
        // different value would make the test silently validate leaked
        // simulator state instead of the injected Reader world.
        XCTAssertEqual(initialLineHeight, 2.1, accuracy: 0.01)
        captureStep("preview-2.1", app: app)

        XCTAssertTrue(reader.adjustLineHeight(toValue: "1.0"))
        XCTAssertTrue(reader.waitForLineHeightValue("1", timeout: 5))
        captureStep("preview-1.0", app: app)
        captureStep("preview-1.0-counterexample", app: app)

        XCTAssertTrue(reader.adjustLineHeight(toValue: "1.2"))
        XCTAssertTrue(reader.waitForLineHeightValue("1.2", timeout: 5))
        captureStep("preview-1.2", app: app)

        // The shared adjustment row must commit its value into the production
        // Reader bridge, not merely expose a transient AX value. Re-open the
        // settings surface afterwards so the following endpoint/theme evidence
        // still exercises the same live Reader.
        XCTAssertTrue(reader.closeSettings(), "Reader settings must commit the semantic line-height change")
        XCTAssertTrue(
            reader.waitForSettingsStateContaining(["lineHeight=1.20"], timeout: 10),
            "Reader settings state must observe the committed 1.2 line-height value"
        )
        reader.openSettings()
        XCTAssertNotNil(reader.settingsPreviewElement(timeout: 5))

        XCTAssertTrue(reader.adjustLineHeight(toValue: "2.5"))
        XCTAssertTrue(reader.waitForLineHeightValue("2.5", timeout: 5))
        captureStep("preview-2.5", app: app)
        captureStep("preview-2.5-counterexample", app: app)

        XCTAssertTrue(reader.closeSettings(), "Reader settings must commit the shared adjustment-row endpoint")
        XCTAssertTrue(
            reader.waitForSettingsStateContaining(["lineHeight=2.50"], timeout: 10),
            "Reader settings state must observe the committed 2.5 adjustment-row endpoint"
        )
        reader.openSettings()
        XCTAssertTrue(
            reader.waitForLineHeightValue("2.5", timeout: 5),
            "reopened Reader settings must settle the committed adjustment-row endpoint"
        )
        guard let reopenedPreview = reader.settingsPreviewElement(timeout: 5) else {
            XCTFail("Reader settings must recreate its preview after the endpoint commit")
            return
        }

        // The AX node is the Form row/container, not the inner fixed viewport;
        // theme changes can legitimately reflow that outer proxy. The exact
        // 164pt viewport/fade contract is locked by ReaderPreviewStyleSourceTests.
        // Here the live UI must keep a visible, non-collapsed preview surface;
        // screenshots provide the visual proof for the bounded viewport.
        XCTAssertGreaterThan(reopenedPreview.frame.width, 0)
        XCTAssertGreaterThan(reopenedPreview.frame.height, 0)

        for theme in ["dark", "sepia"] {
            guard reader.selectTheme(theme), reader.showPreview(),
                  let preview = reader.settingsPreviewElement(timeout: 5)
            else {
                XCTFail("Reader theme option must remain reachable: \(theme)")
                return
            }
            captureStep("\(theme)-theme", app: app)
            XCTAssertGreaterThan(preview.frame.width, 0, "\(theme) preview must remain laid out")
            XCTAssertGreaterThan(preview.frame.height, 0, "\(theme) preview must remain visible")
            XCTAssertFalse(preview.label.isEmpty, "theme preview must retain its accessibility contract")
        }
        XCTAssertTrue(reader.closeSettings(), "Reader settings must close through the production Done action")
        XCTAssertTrue(reader.waitForContent(ReaderPage.seededContentMarker, timeout: 10))
        captureStep("reader-real-content", app: app)
    }

    @MainActor
    func testReaderSettingsDynamicTypeHasGeometryAndAccessibilityAssertions() throws {
        let app = launchIsolatedApp(
            extraArgs: [
                "-UIPreferredContentSizeCategory",
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
            ],
            fixtures: [.readerRealBookLibrary],
            perfLog: "reader-settings-dynamic-type"
        )
        let bookshelf = AppPage(app: app).goToBookshelf()
        guard let bookCard = bookshelf.exactlyOneBookCard(timeout: 10) else {
            XCTFail("Reader UI World must materialize exactly one book before settings can be opened")
            return
        }
        bookCard.tapWhenReady()

        let reader = ReaderPage(app: app)
        guard reader.waitForContent(ReaderPage.seededContentMarker, timeout: 45) else {
            XCTFail("production Reader must render the seeded book content")
            return
        }
        reader.openSettings()

        guard let panel = reader.settingsPanelElement(),
              let preview = reader.settingsPreviewElement(timeout: 10),
              let lineHeightRow = reader.lineHeightAdjustmentRowElement(timeout: 10),
              let done = reader.settingsDoneButtonElement(timeout: 10)
        else {
            XCTFail("Accessibility Dynamic Type must expose exact Reader settings controls")
            return
        }

        let appFrame = app.frame
        XCTAssertGreaterThan(panel.frame.width, 0)
        XCTAssertGreaterThan(panel.frame.height, 0)
        XCTAssertGreaterThan(preview.frame.width, 0)
        XCTAssertGreaterThan(preview.frame.height, 0)
        XCTAssertGreaterThan(lineHeightRow.frame.width, 100)
        XCTAssertGreaterThan(done.frame.height, 30)
        XCTAssertTrue(done.isHittable)
        XCTAssertTrue(appFrame.contains(done.frame), "Done must remain within the app viewport at accessibility size")
        XCTAssertFalse(preview.frame.intersects(done.frame), "preview and Done must not overlap at accessibility size")
        captureStep("dynamic-type", app: app)

        XCTAssertFalse(preview.label.isEmpty, "preview must expose a localized accessibility label")
        XCTAssertFalse(lineHeightRow.label.isEmpty, "line-height row must expose a localized accessibility label")
        XCTAssertNotNil(lineHeightRow.value, "line-height row must expose its actual numeric value")
        XCTAssertFalse(done.label.isEmpty, "Done must expose a localized accessibility label")
        XCTAssertTrue(reader.showPreview())

        let viewportHeight = preview.frame.height
        // Use the production semantic adjustment-row action at accessibility
        // Dynamic Type; the row owns the same bounded step contract.
        XCTAssertTrue(reader.adjustLineHeight(toValue: "2.5"))
        guard let resizedPreview = reader.settingsPreviewElement(timeout: 5) else {
            XCTFail("preview must remain in the accessibility tree after line-height change")
            return
        }
        XCTAssertEqual(
            resizedPreview.frame.height,
            viewportHeight,
            accuracy: 1,
            "Dynamic Type must not make line-height changes resize the fixed preview viewport"
        )

        for theme in ["light", "sepia", "dark"] {
            XCTAssertTrue(reader.selectTheme(theme), "Dynamic Type theme tile must remain addressable: \(theme)")
            let option = reader.themeOption(theme)
            XCTAssertGreaterThanOrEqual(option.frame.height, 44, "Dynamic Type tile must preserve the HIG hit target")
            XCTAssertTrue(option.isHittable, "Dynamic Type tile must remain hittable: \(theme)")
            XCTAssertTrue(option.isSelected, "Dynamic Type selected theme tile must expose selected state: \(theme)")
        }
        captureStep("dynamic-type-theme-tiles", app: app)
    }
}
