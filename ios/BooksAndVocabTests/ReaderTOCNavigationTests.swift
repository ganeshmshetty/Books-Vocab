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
        #expect(gate.markNavigationAccepted(replacementRequest))
        let replacementLocationFinished = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-b.xhtml"
        )
        #expect(replacementLocationFinished)
        #expect(gate.activeRequestID == nil)
        #expect(gate.activeExpectedLocatorHref == nil)
    }

    /// Readium 3.11 idle location callbacks carry empty `locations.fragments`.
    /// A named anchor of another TOC entry must not complete this request, even
    /// after acceptance. An anchorless report after acceptance does complete it;
    /// see the anchorless-completion test below.
    @Test
    func lateSameResourceCallbackNamingEarlierAnchorCannotCompleteLaterRequest() {
        let firstRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        // Two TOC entries share one XHTML resource but target different anchors.
        gate.begin(firstRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])

        // An idle callback of the first jump, delivered before Readium accepted
        // the replacement, carries no anchor and must not complete the replacement.
        let lateFirstFinished = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!lateFirstFinished)
        #expect(gate.isCurrent(replacementRequest))
        #expect(gate.activeExpectedFragments == ["b"])

        #expect(gate.markNavigationAccepted(replacementRequest))

        // The first request's pending-jump locator names its own anchor.
        let pendingFirstFinished = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: ["a"]
        )
        #expect(!pendingFirstFinished)
        #expect(gate.isCurrent(replacementRequest))

        let replacementFinished = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: ["b"]
        )
        #expect(replacementFinished)
        #expect(gate.activeRequestID == nil)
    }

    /// Readium names no anchor in its idle callbacks, so an accepted anchored
    /// request completes on the resource report. Requiring the anchor would time
    /// out every fragment TOC tap. Before acceptance the same report is refused.
    @Test
    func anchoredRequestCompletesOnAnchorlessCallbackAfterAcceptance() {
        let requestID = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(requestID, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        let beforeAcceptance = gate.finish(
            requestID,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!beforeAcceptance)
        #expect(gate.markNavigationAccepted(requestID))

        let anchorlessFinished = gate.finish(
            requestID,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(anchorlessFinished)
        #expect(gate.activeRequestID == nil)
    }

    /// Two anchored TOC entries in one resource. The first jump was accepted and
    /// then replaced before it settled. Readium names no request and no anchor
    /// in its idle callbacks, so the superseded jump's late anchorless report is
    /// owed and is consumed first. The replacement's own anchorless report then
    /// completes it; refusing it would time out every replaced anchored tap.
    @Test
    func supersededJumpAnchorlessReportIsConsumedBeforeAnchoredReplacementCompletes() {
        let replacedRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(replacedRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        #expect(gate.markNavigationAccepted(replacedRequest))
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        #expect(gate.markNavigationAccepted(replacementRequest))
        #expect(gate.owedSupersededHrefs == ["OEBPS/chapter-1.xhtml"])

        let supersededReport = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!supersededReport)
        #expect(gate.owedSupersededHrefs.isEmpty)
        #expect(gate.isCurrent(replacementRequest))

        let ownArrival = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(ownArrival)
        #expect(gate.activeRequestID == nil)
    }

    /// The replaced jump was never accepted, yet Readium may already have been
    /// asked to perform it, so its report is still owed to the resource.
    @Test
    func unacceptedSupersededJumpStillOwesItsAnchorlessReport() {
        let replacedRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(replacedRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        #expect(gate.owedSupersededHrefs == ["OEBPS/chapter-1.xhtml"])
        #expect(gate.markNavigationAccepted(replacementRequest))

        let supersededReport = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!supersededReport)
        #expect(gate.isCurrent(replacementRequest))

        let ownArrival = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(ownArrival)
    }

    /// Readium may deliver the superseded jump's report before it accepts the
    /// replacement. Acceptance follows the jump, so that early report is the
    /// superseded jump's and is consumed without arming the replacement.
    @Test
    func supersededReportBeforeReplacementAcceptanceIsConsumed() {
        let replacedRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(replacedRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])

        let earlyReport = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!earlyReport)
        #expect(gate.owedSupersededHrefs.isEmpty)
        #expect(gate.markNavigationAccepted(replacementRequest))

        let ownArrival = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(ownArrival)
    }

    /// Every superseded live jump owes one report. A chain of replacements
    /// therefore consumes one anchorless report per superseded jump.
    @Test
    func chainOfSupersededJumpsOwesOneReportEach() {
        let firstRequest = UUID()
        let secondRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(firstRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        gate.begin(secondRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["c"])
        #expect(gate.owedSupersededHrefs.count == 2)
        #expect(gate.markNavigationAccepted(replacementRequest))

        let firstOwed = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!firstOwed)
        let secondOwed = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!secondOwed)
        #expect(gate.owedSupersededHrefs.isEmpty)

        let ownArrival = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(ownArrival)
    }

    /// A superseded jump in another resource owes its report to that resource
    /// only. It must not delay an anchored replacement in this resource.
    @Test
    func supersededJumpInOtherResourceDoesNotDelayAnchoredReplacement() {
        let replacedRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(replacedRequest, expectedLocatorHref: "OEBPS/chapter-2.xhtml", expectedFragments: ["a"])
        #expect(gate.markNavigationAccepted(replacedRequest))
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        #expect(gate.markNavigationAccepted(replacementRequest))

        let finished = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(finished)
        #expect(gate.activeRequestID == nil)
    }

    /// Owed reports are scoped to one live request. Once the replacement
    /// settles, a later anchored request in the same resource is not delayed
    /// by reports of jumps that were superseded earlier.
    @Test
    func owedSupersededReportsAreClearedWhenReplacementSettles() {
        let replacedRequest = UUID()
        let replacementRequest = UUID()
        let nextRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(replacedRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        #expect(gate.markNavigationAccepted(replacementRequest))

        // Readium never reports the superseded jump, so the replacement's own
        // report is consumed as owed and only the next report completes it.
        let consumedAsOwed = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!consumedAsOwed)
        let completed = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(completed)
        #expect(gate.owedSupersededHrefs.isEmpty)

        gate.begin(nextRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["c"])
        #expect(gate.markNavigationAccepted(nextRequest))
        let nextFinished = gate.finish(
            nextRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(nextFinished)
    }

    /// A resource-level replacement owes nothing to an anchor of its own, but the
    /// superseded anchored jump still owes its anchorless report to the same
    /// resource. That report cannot be told apart from the replacement's own, so
    /// it is consumed first; completing on it would finish the replacement before
    /// its own jump reports.
    @Test
    func resourceLevelReplacementConsumesSupersededReportBeforeCompleting() {
        let replacedRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(replacedRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml")
        #expect(gate.owedSupersededHrefs == ["OEBPS/chapter-1.xhtml"])
        #expect(gate.markNavigationAccepted(replacementRequest))

        let supersededReport = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!supersededReport)
        #expect(gate.owedSupersededHrefs.isEmpty)
        #expect(gate.isCurrent(replacementRequest))

        let ownReport = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(ownReport)
        #expect(gate.activeRequestID == nil)
    }

    /// Readium refused the superseded jump, so it performed nothing and owes no
    /// report. The replacement's first anchorless report is its own and completes
    /// it, rather than waiting for a report that never comes.
    @Test
    func refusedSupersededJumpOwesNoReport() {
        let replacedRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(replacedRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        #expect(gate.owedSupersededHrefs == ["OEBPS/chapter-1.xhtml"])

        // go(to:) for the superseded jump resolves as refused after the replacement began.
        gate.jumpRefused(replacedRequest)
        #expect(gate.owedSupersededHrefs.isEmpty)
        #expect(gate.markNavigationAccepted(replacementRequest))

        let ownReport = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(ownReport)
        #expect(gate.activeRequestID == nil)
    }

    /// The refusal can reach the gate while the refused request is still the live
    /// one, before its replacement begins. It then owes no report either.
    @Test
    func jumpRefusedBeforeReplacementBeginsOwesNoReport() {
        let refusedRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(refusedRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        gate.jumpRefused(refusedRequest)
        #expect(gate.isCurrent(refusedRequest))

        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        #expect(gate.owedSupersededHrefs.isEmpty)
        #expect(gate.markNavigationAccepted(replacementRequest))

        let ownReport = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(ownReport)
    }

    /// Re-issuing the active request is not a replacement of it.
    @Test
    func reissuingActiveRequestIsNotAReplacement() {
        let requestID = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(requestID, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        gate.begin(requestID, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        #expect(gate.owedSupersededHrefs.isEmpty)
        #expect(gate.markNavigationAccepted(requestID))

        let finished = gate.finish(
            requestID,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(finished)
    }

    @Test
    func anchoredRequestCompletesOnItsOwnAnchorAfterAcceptance() {
        let requestID = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(requestID, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])
        #expect(gate.markNavigationAccepted(requestID))

        let finished = gate.finish(
            requestID,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: ["b"]
        )
        #expect(finished)
        #expect(gate.activeRequestID == nil)
    }

    @Test
    func resourceLevelRequestStillCompletesOnAnchorlessCallback() {
        let requestID = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        // A TOC entry without a fragment expects the resource only. Readium
        // idle callbacks carry no anchor, so once the jump is accepted the
        // anchorless callback must still complete it (no refused legitimate
        // taps).
        gate.begin(requestID, expectedLocatorHref: "OEBPS/chapter-1.xhtml")
        #expect(gate.markNavigationAccepted(requestID))

        let finished = gate.finish(
            requestID,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(finished)
        #expect(gate.activeRequestID == nil)
    }

    @Test
    func staleAcceptanceCannotArmReplacementRequest() {
        let replacedRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(replacedRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["b"])

        #expect(!gate.markNavigationAccepted(replacedRequest))
        #expect(!gate.isNavigationAccepted)
        let finished = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!finished)
    }

    @Test
    func encodedAnchorMatchesDecodedCallbackFragment() {
        // Readium may report an anchor percent-encoded (TOC href) while the
        // location callback reports it decoded, or the reverse. Both sides are
        // normalized, so a legitimate tap is not refused until timeout.
        #expect(ReaderTOCNavigationRequestGate.fragmentsAccept(
            expected: ["caf%C3%A9"],
            reported: ["café"]
        ))
        #expect(ReaderTOCNavigationRequestGate.fragmentsAccept(
            expected: ["café"],
            reported: ["caf%C3%A9"]
        ))
        #expect(!ReaderTOCNavigationRequestGate.fragmentsAccept(
            expected: ["caf%C3%A9"],
            reported: ["cafe"]
        ))
    }

    /// An anchorless request must not accept a report that names another
    /// request's anchor of the same resource.
    @Test
    func anchorlessLaterRequestRefusesEarlierAnchorCallback() {
        let firstRequest = UUID()
        let replacementRequest = UUID()
        var gate = ReaderTOCNavigationRequestGate()

        gate.begin(firstRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: ["a"])
        gate.begin(replacementRequest, expectedLocatorHref: "OEBPS/chapter-1.xhtml", expectedFragments: [])
        #expect(gate.markNavigationAccepted(replacementRequest))

        let lateFirstFinished = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: ["a"]
        )
        #expect(!lateFirstFinished)
        #expect(gate.isCurrent(replacementRequest))

        // The superseded anchored jump owes its anchorless report to the resource;
        // only the report after it completes the resource-level replacement.
        let supersededReport = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(!supersededReport)
        let resourceFinished = gate.finish(
            replacementRequest,
            ifMatchingLocatorHref: "OEBPS/chapter-1.xhtml",
            locatorFragments: []
        )
        #expect(resourceFinished)
        #expect(gate.activeRequestID == nil)
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
    func acceptanceHookRunsBeforeNavigateReturnsOnlyForAcceptedJump() async throws {
        let locator = try Self.locator(href: "OEBPS/chapter-b.xhtml")
        let acceptedRequestID = UUID()
        let accepted = AcceptanceCounter()
        let acceptedEvent = await ReaderTOCNavigationBridge(
            navigator: FakeReaderNavigator(outcome: .accepted),
            timeoutNanoseconds: 50_000_000
        ).navigate(requestID: acceptedRequestID, locator: locator, onAccepted: { accepted.count += 1 })

        // The gate must already be armed when the caller resumes, so a
        // location callback delivered right after acceptance is not dropped.
        #expect(accepted.count == 1)
        #expect(acceptedEvent == .goAccepted(requestID: acceptedRequestID, locatorHref: "OEBPS/chapter-b.xhtml"))

        let rejected = AcceptanceCounter()
        _ = await ReaderTOCNavigationBridge(
            navigator: FakeReaderNavigator(outcome: .rejected),
            timeoutNanoseconds: 50_000_000
        ).navigate(requestID: UUID(), locator: locator, onAccepted: { rejected.count += 1 })
        #expect(rejected.count == 0)
    }

    /// A refused jump is reported through the hook even though the race settles
    /// with goRejected, so a superseded request can release the report it owed.
    @Test @MainActor
    func refusalHookRunsOnlyForRefusedJump() async throws {
        let locator = try Self.locator(href: "OEBPS/chapter-b.xhtml")
        let refusedRequestID = UUID()
        let refused = RefusalCounter()
        let rejectedEvent = await ReaderTOCNavigationBridge(
            navigator: FakeReaderNavigator(outcome: .rejected),
            timeoutNanoseconds: 50_000_000
        ).navigate(requestID: refusedRequestID, locator: locator, onRefused: { refused.count += 1 })

        #expect(refused.count == 1)
        #expect(rejectedEvent == .goRejected(requestID: refusedRequestID))

        let accepted = RefusalCounter()
        _ = await ReaderTOCNavigationBridge(
            navigator: FakeReaderNavigator(outcome: .accepted),
            timeoutNanoseconds: 50_000_000
        ).navigate(requestID: UUID(), locator: locator, onRefused: { accepted.count += 1 })
        #expect(accepted.count == 0)
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

    /// Same contract as the gate: an accepted anchored request completes on a
    /// resource report that names no anchor (ReaderTOCNavigationRequestGate).
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
    func sameResourceFragmentTOCItemsEachReachSuccessOnOneState() {
        var state = ReaderTOCNavigationState()
        for (index, fragment) in ["section-1", "section-2"].enumerated() {
            let requestID = UUID()
            _ = state.beginSelection(
                path: [0, index],
                title: fragment,
                expectedHref: "OEBPS/chapter-a.xhtml#\(fragment)",
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
        }
    }

    @Test @MainActor
    func fragmentBearingEvidenceEntryValidatesAgainstResourceLocator() {
        let hash = String(repeating: "a", count: 64)
        let asset = ReaderTOCEvidenceAsset(
            assetID: "books.fixture",
            installedPath: "/tmp/fixture.epub",
            expectedSHA256: hash,
            expectedByteSize: 1,
            actualSHA256: hash,
            actualByteSize: 1
        )
        let row = ReaderTOCEvidenceSelectedRow(
            path: [0, 0],
            href: "OEBPS/chapter-a.xhtml#section-1",
            title: "Section 1"
        )
        let required = ReaderTOCEvidenceEntry(
            label: "fragment-required",
            partition: "required",
            fixtureID: "fixture",
            asset: asset,
            path: [0, 0],
            selectedRow: row,
            observation: ReaderTOCEvidenceObservation(
                requestedHref: "OEBPS/chapter-a.xhtml#section-1",
                observedLocatorHref: "OEBPS/chapter-a.xhtml",
                observedContent: "content",
                contentSelector: "selector"
            )
        )
        let counterexample = ReaderTOCEvidenceEntry(
            label: "fragment-counterexample",
            partition: "counterexample",
            fixtureID: "fixture",
            asset: asset,
            path: [0, 0],
            selectedRow: row,
            observation: ReaderTOCEvidenceObservation(
                requestedHref: "OEBPS/chapter-a.xhtml#section-1",
                observedLocatorHref: "OEBPS/chapter-b.xhtml",
                observedContent: nil,
                contentSelector: nil
            )
        )

        #expect(ReaderTOCEvidenceEntry.validationErrors(for: [required, counterexample]).isEmpty)
    }

    /// Pins the app-side half of the resource-href contract. The UI-test helper
    /// keeps a byte-identical copy (ReaderTOCEvidenceHref) that this target cannot
    /// import, so drift there is only caught by the UI evidence run.
    @Test
    func resourceHrefStripsOnlyTheFragmentSection() {
        let cases: [(input: String, expected: String)] = [
            ("OEBPS/chapter-a.xhtml", "OEBPS/chapter-a.xhtml"),
            ("OEBPS/chapter-a.xhtml#section-1", "OEBPS/chapter-a.xhtml"),
            ("OEBPS/chapter-a.xhtml#", "OEBPS/chapter-a.xhtml"),
            ("OEBPS/chapter-a.xhtml#a#b", "OEBPS/chapter-a.xhtml"),
            ("#section-1", ""),
            ("", ""),
        ]
        for testCase in cases {
            #expect(ReaderTOCNavigationState.resourceHref(testCase.input) == testCase.expected)
        }
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
private final class AcceptanceCounter {
    var count = 0
}
private final class RefusalCounter {
    var count = 0
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
