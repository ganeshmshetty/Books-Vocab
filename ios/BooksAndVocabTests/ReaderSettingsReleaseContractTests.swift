#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

struct ReaderSettingsReleaseContractTests {
    private static let debugDOMAPI = "window.__toggleDebugBoxes"

    @Test func hitTestingDebugAvailabilityFollowsBuildConfiguration() {
        #if DEBUG
        #expect(ReaderDebugTools.isAvailable)
        #else
        #expect(!ReaderDebugTools.isAvailable)
        #endif
    }

    @Test func productionReaderBundleExcludesDebugDOMSurface() throws {
        let navigatorSource = try String(
            contentsOf: Self.sourceURL(named: "ReadiumNavigatorJS.swift"),
            encoding: .utf8
        )
        let debugSource = try String(
            contentsOf: Self.sourceURL(named: "ReadiumNavigatorJS+Debug.swift"),
            encoding: .utf8
        )

        #expect(navigatorSource.contains("#if DEBUG"))
        #expect(debugSource.contains("#if os(iOS) && DEBUG"))

        let productionBundleSource = Self.releaseProjection(of: navigatorSource + "\n" + debugSource)
        #expect(
            !productionBundleSource.contains(Self.debugDOMAPI),
            "Release Reader injection must not contain the hit-testing DOM API"
        )
        #expect(
            !productionBundleSource.contains("buildDebugScript"),
            "Release Reader source must not reference the DEBUG-only script builder"
        )
    }

    @Test func preferenceApplyFinishesOnNavigatorReadinessEvent() {
        var state = ReaderPreferencesApplyState()
        let firstGeneration = state.begin()
        #expect(state.isApplying)
        let firstPresentationObserved = state.observeNavigatorPresentation()
        #expect(firstPresentationObserved)
        #expect(!state.isApplying)
        let unrelatedPresentationObserved = state.observeNavigatorPresentation()
        #expect(!unrelatedPresentationObserved, "an unrelated event must not create readiness")

        let latestGeneration = state.begin()
        state.cancel(firstGeneration)
        #expect(state.isApplying, "an obsolete task must not cancel the latest preference apply")
        let latestPresentationObserved = state.observeNavigatorPresentation()
        #expect(latestPresentationObserved)
        #expect(!state.isApplying)

        _ = state.begin()
        state.cancel(latestGeneration)
        #expect(state.isApplying, "cancelling an obsolete generation must leave the current apply pending")
    }

    @Test func preferenceApplyCanBeInvalidatedWithNavigatorTeardown() {
        var state = ReaderPreferencesApplyState()
        _ = state.begin()
        #expect(state.isApplying)

        state.invalidate()

        #expect(!state.isApplying)
    }

    @Test func productionReaderEvidenceUsesStateContractWithoutZeroHeightColorHook() throws {
        let panelSource = try String(
            contentsOf: Self.sourceURL(named: "ReaderView+Panels.swift"),
            encoding: .utf8
        )

        #expect(panelSource.contains("reader.webView.settingsState"))
        #expect(panelSource.contains("navigatorSettingsReceipt"))
        #expect(!panelSource.contains("viewConfiguration.settingsBridgeState"))
        #expect(!panelSource.contains("Color.clear.frame(height: 0)"))
        #expect(!panelSource.contains("Color.clear"))
    }

    @Test func productionStateReceiptUsesReadiumPresentationAndActualSettings() throws {
        let navigatorSource = try String(
            contentsOf: Self.sourceURL(named: "ReadiumNavigatorView.swift"),
            encoding: .utf8
        )

        #expect(navigatorSource.contains("presentationDidChange"))
        #expect(navigatorSource.contains("navigator.settings"))
        #expect(navigatorSource.contains("onNavigatorSettingsReceipt"))
        #expect(!navigatorSource.contains("Task.sleep"))
    }

    @Test func settingsBridgeStateMatchesActualNavigatorSettings() {
        let state = ReaderSettingsBridgeState(
            font: .mono,
            fontScale: 1.25,
            lineHeight: 2.1,
            letterSpacing: 0.4,
            scrollMode: true,
            theme: .dark
        )

        #expect(
            state.accessibilityValue
                == "font=Mono;fontSize=1.25;lineHeight=2.10;letterSpacing=0.40;readingMode=scroll;theme=dark"
        )
    }

    @Test func productionReaderReceiptCarriesReadinessAndNavigatorIdentity() {
        let navigatorID = UUID(uuidString: "D8A8F3A7-6A9E-4D43-BE87-5F2A3C2E8C11")!
        let state = ReaderNavigatorSettingsReceipt.ready(
            navigatorID: navigatorID,
            settings: ReaderSettingsBridgeState(
                font: .serif,
                fontScale: 1,
                lineHeight: 1.4,
                letterSpacing: 0,
                scrollMode: false,
                theme: .light
            ),
            source: .presentationDidChange
        )

        #expect(state.accessibilityValue.contains("status=ready"))
        #expect(state.accessibilityValue.contains("navigator=D8A8F3A7-6A9E-4D43-BE87-5F2A3C2E8C11"))
        #expect(state.accessibilityValue.contains("lineHeight=1.40"))
        #expect(state.accessibilityValue.contains("letterSpacing=0.00"))
    }

    @Test func readerPageNeverResolvesAnImplicitFirstMatch() throws {
        let pageSource = try String(
            contentsOf: Self.sourceURL(
                relativeToProject: "BooksAndVocabUITests/Pages/ReaderPage.swift"
            ),
            encoding: .utf8
        )

        #expect(pageSource.contains("exactlyOneElement"))
        #expect(!pageSource.contains("firstMatch"))
    }

    @Test func preferenceApplySourceContainsNoWallClockSleep() throws {
        let commandSource = try String(
            contentsOf: Self.sourceURL(named: "ReadiumNavigatorCoordinator+Commands.swift"),
            encoding: .utf8
        )
        #expect(!commandSource.contains("Task.sleep"))
    }

    @Test func readerSettingsControlsShareCanonicalTypographyAndHighlightSources() throws {
        let settingsSource = try String(
            contentsOf: Self.sourceURL(relativeToProject: "BooksAndVocab/Models/ReaderSettings.swift"),
            encoding: .utf8
        )
        let panelSource = try String(
            contentsOf: Self.sourceURL(named: "ReaderSettingsPanel.swift"),
            encoding: .utf8
        )
        let presenterSource = try String(
            contentsOf: Self.sourceURL(named: "ReaderSettingsPresenter+Vocab.swift"),
            encoding: .utf8
        )
        let preferencesSource = try String(
            contentsOf: Self.sourceURL(relativeToProject: "BooksAndVocab/Models/VocabHighlightPreferences.swift"),
            encoding: .utf8
        )
        let pickerSource = try String(
            contentsOf: Self.sourceURL(named: "VocabHighlightColorPresetPicker.swift"),
            encoding: .utf8
        )

        #expect(settingsSource.contains("ReaderTypographyMetrics"))
        #expect(panelSource.contains("ReaderTypographyMetrics.fontSizeRange"))
        #expect(panelSource.contains("ReaderTypographyMetrics.letterSpacingRange"))
        #expect(presenterSource.contains("ReaderTypographyAdjustmentRow"))
        #expect(presenterSource.contains("reader.settings.letterSpacing"))
        #expect(presenterSource.contains("VocabHighlightPreferences.opacityStep"))
        #expect(preferencesSource.contains("VocabHighlightSRGB"))
        #expect(pickerSource.contains("ColorPicker"))
        #expect(pickerSource.contains("supportsOpacity: false"))
    }

    @Test func typographyAdjustmentButtonsCarryDirectionalAccessibilityLabels() throws {
        let presenterSource = try String(
            contentsOf: Self.sourceURL(named: "ReaderSettingsPresenter+Vocab.swift"),
            encoding: .utf8
        )
        #expect(presenterSource.contains("accessibilityLabel(label)"))
        #expect(presenterSource.contains("reader.settings.adjust.decrease"))
        #expect(presenterSource.contains("reader.settings.adjust.increase"))
    }

    private static func sourceURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BooksAndVocab/Views/Reader/\(name)")
    }

    private static func sourceURL(relativeToProject path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    /// Static Release projection for the two Reader JS source files.  It keeps
    /// the contract test independent from whichever Xcode configuration runs
    /// the unit test target while modelling the conditions that matter here:
    /// `os(iOS)` is active and `DEBUG` is not.
    private static func releaseProjection(of source: String) -> String {
        struct ConditionalFrame {
            let parentActive: Bool
            var branchTaken: Bool
        }

        var frames: [ConditionalFrame] = []
        var active = true
        var output: [String] = []

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let directive = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if directive.hasPrefix("#if ") {
                let parentActive = active
                let branchActive = parentActive && releaseConditionIsActive(
                    String(directive.dropFirst(4))
                )
                frames.append(
                    ConditionalFrame(parentActive: parentActive, branchTaken: branchActive)
                )
                active = branchActive
            } else if directive.hasPrefix("#elseif ") {
                guard var frame = frames.popLast() else { continue }
                let branchActive = frame.parentActive
                    && !frame.branchTaken
                    && releaseConditionIsActive(String(directive.dropFirst(8)))
                frame.branchTaken = frame.branchTaken || branchActive
                frames.append(frame)
                active = branchActive
            } else if directive == "#else" {
                guard var frame = frames.popLast() else { continue }
                let branchActive = frame.parentActive && !frame.branchTaken
                frame.branchTaken = true
                frames.append(frame)
                active = branchActive
            } else if directive == "#endif" {
                active = frames.removeLast().parentActive
            } else if active {
                output.append(line)
            }
        }

        return output.joined(separator: "\n")
    }

    private static func releaseConditionIsActive(_ condition: String) -> Bool {
        let normalized = condition.replacingOccurrences(of: " ", with: "")
        if normalized == "DEBUG" || normalized.contains("&&DEBUG") {
            return false
        }
        return true
    }
}
#endif
