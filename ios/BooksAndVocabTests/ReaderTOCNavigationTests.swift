#if os(iOS)
import Foundation
import ReadiumShared
import Testing
@testable import BooksAndVocab

struct ReaderTOCNavigationTests {
    @Test
    func navigatorLifecycleGateRejectsDismantledAndOlderCallbacks() {
        var gate = ReaderNavigatorLifecycleGate()
        let firstGeneration = gate.activate()

        #expect(gate.accepts(firstGeneration))

        gate.deactivate()
        #expect(!gate.accepts(firstGeneration))

        let replacementGeneration = gate.activate()
        #expect(replacementGeneration != firstGeneration)
        #expect(!gate.accepts(firstGeneration))
        #expect(gate.accepts(replacementGeneration))
    }

    @Test
    func staleNavigationCompletionCannotFinishReplacementRequest() {
        let firstRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(firstRequest)
        gate.begin(replacementRequest)

        #expect(!gate.isCurrent(firstRequest))
        let staleFinished = gate.finish(firstRequest)
        #expect(!staleFinished)
        #expect(gate.isCurrent(replacementRequest))
        let replacementFinished = gate.finish(replacementRequest)
        #expect(replacementFinished)
        #expect(gate.activeRequestID == nil)
    }

    @Test
    func staleLocationCallbackCannotFinishReplacementRequest() {
        let firstRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(firstRequest, expectedLocatorHref: "OEBPS/chapter-a.xhtml")
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-b.xhtml")

        let staleLocationFinished = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-a.xhtml"
        )
        #expect(!staleLocationFinished)
        #expect(gate.isCurrent(replacementRequest))
        #expect(gate.activeExpectedLocatorHref == "OEBPS/chapter-b.xhtml")
        let replacementLocationFinished = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-b.xhtml"
        )
        #expect(replacementLocationFinished)
        #expect(gate.activeRequestID == nil)
        #expect(gate.activeExpectedLocatorHref == nil)
    }

    @Test
    func invalidatingNavigationGateRejectsLateTeardownCompletion() {
        let requestID = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(requestID)
        gate.invalidate()

        #expect(!gate.isCurrent(requestID))
        let lateFinished = gate.finish(requestID)
        #expect(!lateFinished)
    }

    @Test @MainActor
    func navigatorTrueIsTheFirstSuccessfulNavigationSignal() async throws {
        let requestID = UUID()
        let locator = try Self.locator(href: "OEBPS/chapter-b.xhtml")
        let navigator = FakeReaderNavigator(outcome: .accepted)
        let bridge = ReaderTOCNavigationBridge(
            navigator: navigator,
            timeoutNanoseconds: 50_000_000
        )

        let event = await bridge.navigate(requestID: requestID, locator: locator)

        #expect(event == .goAccepted(requestID: requestID, locatorHref: "OEBPS/chapter-b.xhtml"))
        #expect(navigator.requestedLocator?.href.string == "OEBPS/chapter-b.xhtml")
    }

    @Test @MainActor
    func acceptedNavigationRemainsPendingUntilMatchingLocationCallback() throws {
        let requestID = UUID()
        var state = ReaderTOCNavigationState()
        _ = state.beginSelection(
            path: [1],
            title: "Chapter B",
            expectedHref: "OEBPS/chapter-b.xhtml",
            requestID: requestID
        )

        state.apply(
            .goAccepted(
                requestID: requestID,
                locatorHref: "OEBPS/chapter-b.xhtml"
            )
        )

        #expect(state.phase == .loading)
        #expect(state.destinationHref == nil)
        #expect(!state.canDismissSheet)
        #expect(state.accessibilityValue.contains("phase=loading"))

        state.apply(
            .locationDidChange(
                requestID: requestID,
                locatorHref: "OEBPS/chapter-b.xhtml"
            )
        )

        #expect(state.phase == .success)
        #expect(state.destinationHref == "OEBPS/chapter-b.xhtml")
        #expect(state.accessibilityValue.contains("phase=success"))
    }

    @Test @MainActor
    func fragmentBearingTOCHrefMatchesFragmentFreeNavigatorLocation() {
        let requestID = UUID()
        var state = ReaderTOCNavigationState()
        _ = state.beginSelection(
            path: [0, 0],
            title: "Section 1",
            expectedHref: "OEBPS/chapter-a.xhtml#section-1",
            requestID: requestID
        )

        state.apply(
            .goAccepted(
                requestID: requestID,
                locatorHref: "OEBPS/chapter-a.xhtml"
            )
        )
        state.apply(
            .locationDidChange(
                requestID: requestID,
                locatorHref: "OEBPS/chapter-a.xhtml"
            )
        )

        #expect(state.phase == .success)
        #expect(state.failureReason == nil)
        #expect(state.destinationHref == "OEBPS/chapter-a.xhtml")
    }

    @Test @MainActor
    func fragmentBearingTOCHrefStillRejectsDifferentResourceLocation() {
        let requestID = UUID()
        var state = ReaderTOCNavigationState()
        _ = state.beginSelection(
            path: [0, 0],
            title: "Section 1",
            expectedHref: "OEBPS/chapter-a.xhtml#section-1",
            requestID: requestID
        )

        state.apply(
            .locationDidChange(
                requestID: requestID,
                locatorHref: "OEBPS/chapter-b.xhtml"
            )
        )

        #expect(state.phase == .failure)
        #expect(state.failureReason == .locatorMismatch)
    }

    @Test @MainActor
    func acceptedWrongLocatorAndMissingCallbackCannotCloseSheet() throws {
        let requestID = UUID()
        var state = ReaderTOCNavigationState()
        _ = state.beginSelection(
            path: [1],
            title: "Chapter B",
            expectedHref: "OEBPS/chapter-b.xhtml",
            requestID: requestID
        )

        state.apply(
            .goAccepted(
                requestID: requestID,
                locatorHref: "OEBPS/chapter-a.xhtml"
            )
        )
        #expect(state.phase == .loading)
        #expect(state.destinationHref == nil)
        #expect(!state.canDismissSheet)

        state.apply(
            .locationDidChange(
                requestID: requestID,
                locatorHref: "OEBPS/chapter-a.xhtml"
            )
        )
        #expect(state.phase == .failure)
        #expect(state.failureReason == .locatorMismatch)
        #expect(state.canRetry)
    }

    @Test @MainActor
    func navigatorFalseLeavesSelectionRetryable() async throws {
        let requestID = UUID()
        let locator = try Self.locator(href: "OEBPS/chapter-b.xhtml")
        let event = await ReaderTOCNavigationBridge(
            navigator: FakeReaderNavigator(outcome: .rejected),
            timeoutNanoseconds: 50_000_000
        ).navigate(requestID: requestID, locator: locator)

        var state = ReaderTOCNavigationState()
        _ = state.beginSelection(
            path: [1],
            title: "Chapter B",
            expectedHref: "OEBPS/chapter-b.xhtml",
            requestID: requestID
        )
        state.apply(event)

        #expect(event == .goRejected(requestID: requestID))
        #expect(state.phase == .failure)
        #expect(state.canRetry)
        #expect(!state.canDismissSheet)
    }

    @Test @MainActor
    func missingNavigatorIsNotASuccessSignal() async throws {
        let requestID = UUID()
        let locator = try Self.locator(href: "OEBPS/chapter-b.xhtml")
        let event = await ReaderTOCNavigationBridge(
            navigator: nil,
            timeoutNanoseconds: 50_000_000
        ).navigate(requestID: requestID, locator: locator)

        #expect(event == .navigatorUnavailable(requestID: requestID))
    }

    @Test @MainActor
    func matchingLocationCallbackOwnsSuccessForTheRequestToken() throws {
        let requestID = UUID()
        var state = ReaderTOCNavigationState()
        _ = state.beginSelection(
            path: [1],
            title: "Chapter B",
            expectedHref: "OEBPS/chapter-b.xhtml",
            requestID: requestID
        )

        state.apply(
            .locationDidChange(
                requestID: requestID,
                locatorHref: "OEBPS/chapter-b.xhtml"
            )
        )

        #expect(state.phase == .success)
        #expect(state.destinationHref == "OEBPS/chapter-b.xhtml")
        #expect(state.observedLocatorHref == "OEBPS/chapter-b.xhtml")
        #expect(state.canDismissSheet)
    }

    @Test @MainActor
    func timeoutAndCancellationRemainRetryable() throws {
        let requestID = UUID()
        var state = ReaderTOCNavigationState()
        _ = state.beginSelection(
            path: [1],
            title: "Chapter B",
            expectedHref: "OEBPS/chapter-b.xhtml",
            requestID: requestID
        )

        state.apply(.timedOut(requestID: requestID))
        #expect(state.phase == .failure)
        #expect(state.failureReason == .timedOut)
        #expect(state.canRetry)

        _ = state.beginRetry(requestID: requestID)
        state.apply(.cancelled(requestID: requestID))
        #expect(state.phase == .failure)
        #expect(state.failureReason == .cancelled)
        #expect(state.canRetry)
    }

    @Test @MainActor
    func hangingNavigatorIsActuallyInvokedAndHardTimeoutDoesNotWaitForIt() async throws {
        let requestID = UUID()
        let locator = try Self.locator(href: "OEBPS/chapter-b.xhtml")
        let navigator = FakeReaderNavigator(outcome: .hanging)
        let bridge = ReaderTOCNavigationBridge(
            navigator: navigator,
            timeoutNanoseconds: 50_000_000
        )
        let start = ContinuousClock.now

        let event = await bridge.navigate(requestID: requestID, locator: locator)
        let elapsed = start.duration(to: .now)

        #expect(event == .timedOut(requestID: requestID))
        #expect(navigator.requestedLocator?.href.string == "OEBPS/chapter-b.xhtml")
        #expect(elapsed < .milliseconds(500))
    }

    @Test @MainActor
    func preCancelledNavigationPreservesRequestIdentity() async throws {
        let requestID = UUID()
        let locator = try Self.locator(href: "OEBPS/chapter-b.xhtml")
        let taskBox = ReaderNavigationTaskBox()
        let bridge = ReaderTOCNavigationBridge(
            navigator: FakeReaderNavigator(outcome: .hanging),
            timeoutNanoseconds: 50_000_000,
            beforeContinuationInstall: {
                taskBox.task?.cancel()
            }
        )

        let task = Task { @MainActor in
            await bridge.navigate(requestID: requestID, locator: locator)
        }
        taskBox.task = task

        let event = await task.value
        #expect(event == .cancelled(requestID: requestID))
    }

    @Test @MainActor
    func locatorMismatchAndStaleCallbackCannotCloseSheet() throws {
        let requestID = UUID()
        var state = ReaderTOCNavigationState()
        _ = state.beginSelection(
            path: [1],
            title: "Chapter B",
            expectedHref: "OEBPS/chapter-b.xhtml",
            requestID: requestID
        )

        state.apply(
            .locationDidChange(
                requestID: requestID,
                locatorHref: "OEBPS/chapter-a.xhtml"
            )
        )
        #expect(state.phase == .failure)
        #expect(state.failureReason == .locatorMismatch)
        #expect(state.canRetry)

        _ = state.beginRetry(requestID: requestID)
        state.apply(
            .locationDidChange(
                requestID: UUID(),
                locatorHref: "OEBPS/chapter-b.xhtml"
            )
        )
        #expect(state.phase == .loading)
        #expect(!state.canDismissSheet)
    }

    @Test @MainActor
    func invalidPublicationDestinationIsMissingAndRetryable() throws {
        let requestID = UUID()
        var state = ReaderTOCNavigationState()
        _ = state.beginSelection(
            path: [2],
            title: "Missing Chapter",
            expectedHref: "OEBPS/missing.xhtml",
            requestID: requestID
        )

        state.apply(.missingDestination(requestID: requestID))

        #expect(state.phase == .missingDestination)
        #expect(state.failureReason == .missingDestination)
        #expect(state.canRetry)
        #expect(!state.canDismissSheet)
    }

    @Test
    func evidenceContextBindsPreRunInvocationAndCanonicalScreenshotIdentity() {
        let required = Self.evidenceEntry(
            label: "reader-toc-required",
            partition: "required",
            path: [1],
            rowPath: [1],
            href: "OEBPS/chapter2.xhtml",
            observedLocator: "OEBPS/chapter2.xhtml",
            content: "Chapter Two",
            contentSelector: "Chapter Two"
        )
        let counterexample = Self.evidenceEntry(
            label: "reader-toc-counterexample-failure",
            partition: "counterexample",
            path: [1],
            rowPath: [1],
            href: "OEBPS/missing.xhtml",
            observedLocator: "OEBPS/chapter1.xhtml",
            content: nil,
            contentSelector: nil
        )
        let retry = Self.evidenceEntry(
            label: "reader-toc-counterexample-retry",
            partition: "counterexample",
            path: [1],
            rowPath: [1],
            href: "OEBPS/missing.xhtml",
            observedLocator: "OEBPS/chapter1.xhtml",
            content: nil,
            contentSelector: nil
        )
        let context = ReaderTOCEvidenceContext(
            schema: ReaderTOCEvidenceContext.schema,
            invocation: ReaderTOCEvidenceContext.Invocation(
                verdictFile: "/tmp/kg-verdict-123"
            ),
            selectors: [
                "ReaderFlow/testReaderTOCRequiredRealBookSelectionClosesOnlyAfterSuccess",
                "ReaderFlow/testReaderTOCInvalidRealBookKeepsSheetOpenAndRetryable"
            ],
            screenshotDirectory: "/tmp/kg-ui-screenshots",
            screenshotPath: "/tmp/kg-ui-screenshots/01-toc-navigation-result.png",
            entries: [required, counterexample, retry]
        )

        #expect(context.validationErrors.isEmpty)
        #expect(context.completeValidationErrors.isEmpty)
        #expect(context.invocation.verdictFile == "/tmp/kg-verdict-123")
        #expect(context.screenshotPath.hasPrefix(context.screenshotDirectory + "/"))
    }

    @Test
    func evidenceContractBindsSelectedRowHrefContentAndLocator() {
        let entry = Self.evidenceEntry(
            label: "reader-toc-required",
            partition: "required",
            path: [1],
            rowPath: [0],
            href: "OEBPS/chapter2.xhtml",
            observedLocator: "OEBPS/chapter2.xhtml",
            content: "Chapter Two",
            contentSelector: "Chapter Two"
        )

        let errors = ReaderTOCEvidenceEntry.validationErrors(for: [entry])

        #expect(errors.contains("entries[0].selectedRow.pathMismatch"))
    }

    @Test
    func evidenceContractRejectsUnsafeRelativeHref() {
        let entry = Self.evidenceEntry(
            label: "reader-toc-counterexample-failure",
            partition: "counterexample",
            path: [1],
            rowPath: [1],
            href: "../outside.xhtml",
            observedLocator: "OEBPS/chapter1.xhtml",
            content: nil,
            contentSelector: nil
        )

        let errors = ReaderTOCEvidenceEntry.validationErrors(for: [entry])

        #expect(errors.contains("entries[0].observation.unsafeHref"))
    }

    @Test
    func tocHierarchyKeepsStableNestedPaths() {
        let links = [
            Link(
                href: "chapter-1.xhtml",
                title: "Chapter 1",
                children: [
                    Link(href: "chapter-1.xhtml#section-1", title: "Section 1")
                ]
            ),
            Link(href: "chapter-2.xhtml", title: "Chapter 2")
        ]

        let items = ReaderTOCHierarchy.flatten(links)

        #expect(items.map(\.id) == ["0", "0.0", "1"])
        #expect(items.map(\.path) == [[0], [0, 0], [1]])
        #expect(items.map(\.depth) == [0, 1, 0])
        #expect(items.map(\.title) == ["Chapter 1", "Section 1", "Chapter 2"])
        #expect(items.map(\.href) == [
            "chapter-1.xhtml",
            "chapter-1.xhtml#section-1",
            "chapter-2.xhtml"
        ])
        #expect(items.map { $0.link.url().string } == items.map(\.href))
    }

    @Test
    func productionTOCInputDoesNotCreateSyntheticFragmentDestination() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tocSource = try String(
            contentsOf: rootURL.appendingPathComponent(
                "ios/BooksAndVocab/Views/Reader/TOCView.swift"
            ),
            encoding: .utf8
        )
        let readerSource = try String(
            contentsOf: rootURL.appendingPathComponent(
                "ios/BooksAndVocab/Views/Reader/ReaderView.swift"
            ),
            encoding: .utf8
        )

        #expect(!tocSource.contains("href: \"#\""))
        #expect(!readerSource.contains("readerTOCInjectLocateFailureOnce"))
        #expect(!readerSource.contains("consumeTOCInjection"))
    }

    private static func locator(href: String) throws -> Locator {
        let mediaType = try #require(MediaType("application/xhtml+xml"))
        let url = try #require(AnyURL(path: href))
        return Locator(href: url, mediaType: mediaType)
    }

    private static func evidenceEntry(
        label: String,
        partition: String,
        path: [Int],
        rowPath: [Int],
        href: String,
        observedLocator: String?,
        content: String?,
        contentSelector: String?
    ) -> ReaderTOCEvidenceEntry {
        ReaderTOCEvidenceEntry(
            label: label,
            partition: partition,
            fixtureID: partition == "required"
                ? "reader.realBookLibrary"
                : "reader.invalidDestinationLibrary",
            asset: ReaderTOCEvidenceAsset(
                assetID: partition == "required"
                    ? "books.reader_real_book_epub"
                    : "books.reader_invalid_destination_epub",
                installedPath: "/tmp/\(label).epub",
                expectedSHA256: String(repeating: "a", count: 64),
                expectedByteSize: 10,
                actualSHA256: String(repeating: "a", count: 64),
                actualByteSize: 10
            ),
            path: path,
            selectedRow: ReaderTOCEvidenceSelectedRow(
                path: rowPath,
                href: href,
                title: partition == "required" ? "Chapter Two" : "Missing Destination"
            ),
            observation: ReaderTOCEvidenceObservation(
                requestedHref: href,
                observedLocatorHref: observedLocator,
                observedContent: content,
                contentSelector: contentSelector
            )
        )
    }

}

@MainActor
private final class ReaderNavigationTaskBox {
    var task: Task<ReaderTOCNavigationEvent, Never>?
}

@MainActor
private final class FakeReaderNavigator: ReaderNavigatorDriving {
    enum Outcome {
        case accepted
        case rejected
        case hanging
    }

    let outcome: Outcome
    private(set) var requestedLocator: Locator?

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func go(to locator: Locator) async -> Bool? {
        requestedLocator = locator
        switch outcome {
        case .accepted:
            return true
        case .rejected:
            return false
        case .hanging:
            // Deliberately never resume or honor cancellation: this fake
            // proves the bridge has a hard deadline independent of navigator
            // cooperation.
            return await withUnsafeContinuation { (_: UnsafeContinuation<Bool?, Never>) in }
        }
    }
}
#endif
