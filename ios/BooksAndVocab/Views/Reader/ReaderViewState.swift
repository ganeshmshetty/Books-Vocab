#if os(iOS)
import Foundation
import SwiftUI
import ReadiumShared

enum ReaderTOCNavigationPhase: Equatable {
    case idle
    case loading
    case success
    case failure
    case missingDestination
}

enum ReaderTOCNavigationFailure: Equatable, Sendable {
    case navigatorRejected
    case navigatorUnavailable
    case timedOut
    case cancelled
    case locatorMismatch
    case missingDestination
}

enum ReaderTOCNavigationEvent: Equatable, Sendable {
    case goAccepted(requestID: UUID, locatorHref: String)
    case goRejected(requestID: UUID)
    case navigatorUnavailable(requestID: UUID)
    case locationDidChange(requestID: UUID, locatorHref: String)
    case timedOut(requestID: UUID)
    case cancelled(requestID: UUID)
    case missingDestination(requestID: UUID)

    var requestID: UUID {
        switch self {
        case .goAccepted(let requestID, _),
             .goRejected(let requestID),
             .navigatorUnavailable(let requestID),
             .locationDidChange(let requestID, _),
             .timedOut(let requestID),
             .cancelled(let requestID),
             .missingDestination(let requestID):
            return requestID
        }
    }
}

/// Owns the single live TOC request token. A cancelled navigation may still
/// finish inside Readium, so its completion must never mutate a replacement
/// request.
struct ReaderTOCNavigationRequestGate: Equatable, Sendable {
    private(set) var activeRequestID: UUID?
    private(set) var activeExpectedLocatorHref: String?
    private(set) var activeExpectedFragments: [String] = []
    /// Set once Readium's `go(to:)` returned true for the active request.
    private(set) var isNavigationAccepted = false

    /// `expectedFragments` are the anchors the TOC entry targets inside
    /// `expectedLocatorHref`. Empty means resource-level expectation only.
    mutating func begin(
        _ requestID: UUID,
        expectedLocatorHref: String? = nil,
        expectedFragments: [String] = []
    ) {
        activeRequestID = requestID
        activeExpectedLocatorHref = expectedLocatorHref
        activeExpectedFragments = expectedFragments
        isNavigationAccepted = false
    }

    mutating func invalidate() {
        activeRequestID = nil
        activeExpectedLocatorHref = nil
        activeExpectedFragments = []
        isNavigationAccepted = false
    }

    func isCurrent(_ requestID: UUID) -> Bool {
        activeRequestID == requestID
    }

    /// Records that Readium accepted the jump for `requestID`. From this point
    /// on, a location callback may be attributed to the request. Readium
    /// reports idle locations without request identity, so a callback emitted
    /// before the jump began must not complete it.
    @discardableResult
    mutating func markNavigationAccepted(_ requestID: UUID) -> Bool {
        guard isCurrent(requestID) else { return false }
        isNavigationAccepted = true
        return true
    }

    func matchesCurrent(
        _ requestID: UUID,
        locatorHref: String,
        locatorFragments: [String] = []
    ) -> Bool {
        isCurrent(requestID)
            && isNavigationAccepted
            && activeExpectedLocatorHref == locatorHref
            && Self.fragmentsAccept(
                expected: activeExpectedFragments,
                reported: locatorFragments
            )
    }

    /// Readium 3.11 idle location callbacks carry empty `locations.fragments`
    /// (positions and resource-level fallback locators have none), so an
    /// empty report is attributed by ordering alone (`markNavigationAccepted`).
    /// A report that names an anchor can only be Readium's pending-jump locator
    /// of some request, so it must name the active request's anchor. Both sides
    /// are percent-decoded first, so an encoded TOC href and a decoded callback
    /// fragment still match.
    static func fragmentsAccept(expected: [String], reported: [String]) -> Bool {
        guard !reported.isEmpty else { return true }
        let normalized: (String) -> String = { $0.removingPercentEncoding ?? $0 }
        return !Set(expected.map(normalized)).isDisjoint(with: reported.map(normalized))
    }

    @discardableResult
    mutating func finish(_ requestID: UUID) -> Bool {
        guard isCurrent(requestID) else { return false }
        invalidate()
        return true
    }

    /// A Readium location callback has no request ID. It may be a late event
    /// from a cancelled request, so only a callback observed after the active
    /// request was accepted, for its expected href and a compatible anchor, may
    /// consume the token.
    @discardableResult
    mutating func finish(
        _ requestID: UUID,
        ifMatchingLocatorHref locatorHref: String,
        locatorFragments: [String] = []
    ) -> Bool {
        guard matchesCurrent(
            requestID,
            locatorHref: locatorHref,
            locatorFragments: locatorFragments
        ) else {
            return false
        }
        invalidate()
        return true
    }
}

/// Rejects delegate callbacks from a dismantled or replaced Readium navigator.
/// Readium may deliver a queued callback after SwiftUI has torn down the
/// representable, so a request token alone is not a sufficient lifecycle fence.
struct ReaderNavigatorLifecycleGate: Equatable, Sendable {
    private(set) var generation: UInt = 0
    private(set) var isActive = false

    @discardableResult
    mutating func activate() -> UInt {
        generation &+= 1
        isActive = true
        return generation
    }

    mutating func deactivate() {
        generation &+= 1
        isActive = false
    }

    func accepts(_ callbackGeneration: UInt) -> Bool {
        isActive && generation == callbackGeneration
    }
}

@MainActor
protocol ReaderNavigatorDriving: AnyObject {
    func go(to locator: Locator) async -> Bool?
}

@MainActor
final class ReaderTOCNavigationBridge {
    private let navigator: ReaderNavigatorDriving?
    private let timeoutNanoseconds: UInt64
    private let beforeContinuationInstall: (() -> Void)?

    init(
        navigator: ReaderNavigatorDriving?,
        timeoutNanoseconds: UInt64,
        beforeContinuationInstall: (() -> Void)? = nil
    ) {
        self.navigator = navigator
        self.timeoutNanoseconds = timeoutNanoseconds
        self.beforeContinuationInstall = beforeContinuationInstall
    }

    func navigate(requestID: UUID, locator: Locator) async -> ReaderTOCNavigationEvent {
        let race = ReaderTOCNavigationRace(requestID: requestID)
        let navigator = self.navigator
        let timeoutNanoseconds = self.timeoutNanoseconds

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<ReaderTOCNavigationEvent, Never>) in
                beforeContinuationInstall?()
                race.setContinuation(continuation)

                let navigationTask: Task<Void, Never> = Task { @MainActor in
                    guard let navigator else {
                        race.finish(.navigatorUnavailable(requestID: requestID))
                        return
                    }
                    guard !Task.isCancelled else {
                        race.finish(.cancelled(requestID: requestID))
                        return
                    }
                    guard let accepted = await navigator.go(to: locator) else {
                        race.finish(.navigatorUnavailable(requestID: requestID))
                        return
                    }
                    race.finish(
                        accepted
                            ? .goAccepted(requestID: requestID, locatorHref: locator.href.string)
                            : .goRejected(requestID: requestID)
                    )
                }
                let timeoutTask: Task<Void, Never> = Task.detached {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    race.finish(.timedOut(requestID: requestID))
                }
                race.setTasks(navigationTask: navigationTask, timeoutTask: timeoutTask)
            }
        }, onCancel: {
            race.finish(.cancelled(requestID: requestID))
        })
    }
}

private final class ReaderTOCNavigationRace: @unchecked Sendable {
    private let requestID: UUID
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ReaderTOCNavigationEvent, Never>?
    private var terminalEvent: ReaderTOCNavigationEvent?
    private var finished = false
    private var navigationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(requestID: UUID) {
        self.requestID = requestID
    }

    func setContinuation(
        _ continuation: CheckedContinuation<ReaderTOCNavigationEvent, Never>
    ) {
        lock.lock()
        if let terminalEvent {
            lock.unlock()
            continuation.resume(returning: terminalEvent)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(
        navigationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        lock.lock()
        if finished {
            lock.unlock()
            navigationTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.navigationTask = navigationTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func finish(_ event: ReaderTOCNavigationEvent) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        terminalEvent = event
        let continuation = self.continuation
        self.continuation = nil
        let navigationTask = self.navigationTask
        let timeoutTask = self.timeoutTask
        self.navigationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        navigationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(returning: event)
    }
}

// The deadline belongs to the TOC navigation state machine, not the
// preference command source. Preference application completes only from the
// navigator presentation event; this independent deadline covers the separate
// case where Readium accepted a TOC command but never emits the resulting
// location callback.
extension ReadiumNavigatorView.Coordinator {
    func beginTOCTimeout(for requestID: UUID) {
        guard tocNavigationGate.isCurrent(requestID) else { return }
        activeTOCTimeoutTask?.cancel()
        activeTOCTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: ReaderMetrics.tocNavigationTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self, self.tocNavigationGate.finish(requestID) else { return }
            self.activeTOCNavigationTask?.cancel()
            self.activeTOCNavigationTask = nil
            self.activeTOCTimeoutTask = nil
            self.parent.onTOCNavigationEvent(.timedOut(requestID: requestID))
        }
    }
}

enum ReaderTOCEvidenceHref {
    static func isSafeRelative(_ href: String) -> Bool {
        guard !href.isEmpty,
              href == href.trimmingCharacters(in: .whitespacesAndNewlines),
              !href.hasPrefix("/"),
              !href.hasPrefix("\\"),
              !href.contains("\\"),
              href.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              }),
              let url = URL(string: href),
              url.scheme == nil,
              url.host == nil,
              let decoded = href.removingPercentEncoding else {
            return false
        }

        let path = decoded.split(whereSeparator: { $0 == "?" || $0 == "#" }).first
            ?? Substring(decoded)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

struct ReaderTOCNavigationState: Equatable {
    private(set) var phase: ReaderTOCNavigationPhase = .idle
    private(set) var selectedPath: [Int]?
    private(set) var selectedTitle: String?
    private(set) var errorMessage: String?
    private(set) var destinationHref: String?
    private(set) var observedLocatorHref: String?
    private(set) var failureReason: ReaderTOCNavigationFailure?
    private(set) var activeRequestID: UUID?
    private(set) var expectedLocatorHref: String?

    var canDismissSheet: Bool {
        phase == .idle || phase == .success
    }

    var canRetry: Bool {
        phase == .failure || phase == .missingDestination
    }

    /// Stable, machine-readable accessibility receipt for the TOC navigation
    /// state machine. The visual loading/success affordances are intentionally
    /// transient; this receipt lets UI automation attest the transition even
    /// when a local EPUB resolves within one render cycle.
    var accessibilityValue: String {
        let phaseValue: String
        switch phase {
        case .idle: phaseValue = "idle"
        case .loading: phaseValue = "loading"
        case .success: phaseValue = "success"
        case .failure: phaseValue = "failure"
        case .missingDestination: phaseValue = "missingDestination"
        }
        let selected = selectedTitle ?? ""
        // `expected` is the resource href (fragment stripped), not the requested
        // TOC href; UI automation must compare against the resource part.
        let expected = expectedLocatorHref ?? ""
        let destination = destinationHref ?? ""
        return "phase=\(phaseValue);selected=\(selected);expected=\(expected);destination=\(destination)"
    }

    /// Starts a TOC navigation request. `expectedHref` may carry a `#fragment`;
    /// the stored expectation is the resource href only (see `resourceHref`),
    /// so callers must not expect `expectedLocatorHref` to equal the input.
    @discardableResult
    mutating func beginSelection(
        path: [Int],
        title: String,
        expectedHref: String,
        requestID: UUID = UUID()
    ) -> UUID {
        selectedPath = path
        selectedTitle = title
        errorMessage = nil
        destinationHref = nil
        observedLocatorHref = nil
        failureReason = nil
        activeRequestID = requestID
        expectedLocatorHref = Self.resourceHref(expectedHref)
        phase = .loading
        return requestID
    }

    /// TOC hrefs may carry a `#fragment` section anchor, but Readium locators
    /// report only the resource href, so compare against the resource part.
    static func resourceHref(_ href: String) -> String {
        guard let hash = href.firstIndex(of: "#") else { return href }
        return String(href[..<hash])
    }

    @discardableResult
    mutating func beginRetry(requestID: UUID = UUID()) -> UUID {
        guard selectedPath != nil else { return requestID }
        errorMessage = nil
        destinationHref = nil
        observedLocatorHref = nil
        failureReason = nil
        activeRequestID = requestID
        phase = .loading
        return requestID
    }

    mutating func apply(_ event: ReaderTOCNavigationEvent) {
        guard phase == .loading, activeRequestID == event.requestID else { return }

        switch event {
        case .goAccepted:
            // Readium's go() result only acknowledges that navigation was
            // requested. The delegate callback is the sole success signal.
            break
        case .locationDidChange(_, let locatorHref):
            guard locatorHref == expectedLocatorHref else {
                fail(
                    reason: .locatorMismatch,
                    message: L10n.string("章節無法開啟，請重試。")
                )
                return
            }
            observedLocatorHref = locatorHref
            destinationHref = locatorHref
            errorMessage = nil
            failureReason = nil
            phase = .success
        case .goRejected:
            fail(
                reason: .navigatorRejected,
                message: L10n.string("章節無法開啟，請重試。")
            )
        case .navigatorUnavailable:
            fail(
                reason: .navigatorUnavailable,
                message: L10n.string("章節無法開啟，請重試。")
            )
        case .timedOut:
            fail(
                reason: .timedOut,
                message: L10n.string("章節無法開啟，請重試。")
            )
        case .cancelled:
            fail(
                reason: .cancelled,
                message: L10n.string("章節無法開啟，請重試。")
            )
        case .missingDestination:
            errorMessage = L10n.string("找不到章節位置")
            destinationHref = nil
            observedLocatorHref = nil
            failureReason = .missingDestination
            phase = .missingDestination
        }
    }

    mutating func reset() {
        phase = .idle
        selectedPath = nil
        selectedTitle = nil
        errorMessage = nil
        destinationHref = nil
        observedLocatorHref = nil
        failureReason = nil
        activeRequestID = nil
        expectedLocatorHref = nil
    }

    private mutating func fail(
        reason: ReaderTOCNavigationFailure,
        message: String
    ) {
        errorMessage = message
        failureReason = reason
        destinationHref = nil
        observedLocatorHref = nil
        phase = .failure
    }
}

struct ReaderTOCEvidenceContext: Codable, Equatable {
    struct Invocation: Codable, Equatable {
        let verdictFile: String
    }

    static let schema = "kg.ui.perf.evidence.context.v1"
    let schema: String
    let invocation: Invocation
    var selectors: [String]
    let screenshotDirectory: String
    var screenshotPath: String
    var entries: [ReaderTOCEvidenceEntry]

    var validationErrors: [String] {
        var errors: [String] = []
        if schema != Self.schema { errors.append("schema") }
        if invocation.verdictFile.isEmpty || !invocation.verdictFile.hasPrefix("/") {
            errors.append("invocation.verdictFile")
        }
        if selectors.isEmpty || selectors.contains(where: { $0.isEmpty }) {
            errors.append("selectors")
        }
        if screenshotDirectory.isEmpty || !screenshotDirectory.hasPrefix("/") {
            errors.append("screenshotDirectory")
        }
        if screenshotPath.isEmpty || !screenshotPath.hasPrefix("/") {
            errors.append("screenshotPath")
        }
        errors.append(contentsOf: ReaderTOCEvidenceEntry.validationErrors(for: entries))
        return errors
    }

    var completeValidationErrors: [String] {
        var errors = validationErrors
        let required = entries.filter { $0.partition == "required" }
        let counterexamples = entries.filter { $0.partition == "counterexample" }
        if required.count != 1 { errors.append("partitions.required.count") }
        if counterexamples.count != 2 { errors.append("partitions.counterexample.count") }
        if entries.contains(where: { !["required", "counterexample"].contains($0.partition) }) {
            errors.append("partitions.disjoint")
        }
        if !Set(required.map(\.label)).intersection(Set(counterexamples.map(\.label))).isEmpty {
            errors.append("partitions.labelsOverlap")
        }
        if !Set(required.map(\.fixtureID)).intersection(Set(counterexamples.map(\.fixtureID))).isEmpty {
            errors.append("partitions.fixturesOverlap")
        }
        if !Set(required.map { $0.asset.assetID }).intersection(Set(counterexamples.map { $0.asset.assetID })).isEmpty {
            errors.append("partitions.assetsOverlap")
        }
        return errors
    }
}

struct ReaderTOCEvidenceAsset: Codable, Equatable {
    let assetID: String
    let installedPath: String
    let expectedSHA256: String
    let expectedByteSize: Int
    let actualSHA256: String
    let actualByteSize: Int
}

struct ReaderTOCEvidenceSelectedRow: Codable, Equatable {
    let path: [Int]
    let href: String
    let title: String
}

struct ReaderTOCEvidenceObservation: Codable, Equatable {
    let requestedHref: String
    let observedLocatorHref: String?
    let observedContent: String?
    let contentSelector: String?
}

struct ReaderTOCEvidenceEntry: Codable, Equatable {
    let label: String
    let partition: String
    let fixtureID: String
    let asset: ReaderTOCEvidenceAsset
    let path: [Int]
    let selectedRow: ReaderTOCEvidenceSelectedRow
    let observation: ReaderTOCEvidenceObservation

    static func validationErrors(for entries: [ReaderTOCEvidenceEntry]) -> [String] {
        var errors: [String] = []
        for (index, entry) in entries.enumerated() {
            let prefix = "entries[\(index)]"
            if entry.label.isEmpty { errors.append("\(prefix).label") }
            if !["required", "counterexample"].contains(entry.partition) {
                errors.append("\(prefix).partition")
            }
            if entry.fixtureID.isEmpty { errors.append("\(prefix).fixtureID") }
            if !entry.asset.assetID.hasPrefix("books.") { errors.append("\(prefix).asset.assetID") }
            if entry.asset.installedPath.isEmpty || !entry.asset.installedPath.hasPrefix("/") {
                errors.append("\(prefix).asset.installedPath")
            }
            if entry.asset.expectedSHA256.count != 64 { errors.append("\(prefix).asset.expectedSHA256") }
            if entry.asset.actualSHA256.count != 64 { errors.append("\(prefix).asset.actualSHA256") }
            if !entry.asset.expectedSHA256.allSatisfy(\.isHexDigit) {
                errors.append("\(prefix).asset.expectedSHA256")
            }
            if !entry.asset.actualSHA256.allSatisfy(\.isHexDigit) {
                errors.append("\(prefix).asset.actualSHA256")
            }
            if entry.asset.expectedByteSize <= 0 { errors.append("\(prefix).asset.expectedByteSize") }
            if entry.asset.actualByteSize <= 0 { errors.append("\(prefix).asset.actualByteSize") }
            if entry.asset.expectedSHA256 != entry.asset.actualSHA256 {
                errors.append("\(prefix).asset.sha256Mismatch")
            }
            if entry.asset.expectedByteSize != entry.asset.actualByteSize {
                errors.append("\(prefix).asset.byteSizeMismatch")
            }
            if entry.path.contains(where: { $0 < 0 }) { errors.append("\(prefix).path") }
            if entry.selectedRow.path != entry.path {
                errors.append("\(prefix).selectedRow.pathMismatch")
            }
            if entry.selectedRow.href.isEmpty || entry.selectedRow.href != entry.observation.requestedHref {
                errors.append("\(prefix).selectedRow.hrefMismatch")
            }
            if entry.selectedRow.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("\(prefix).selectedRow.title")
            }
            if entry.observation.requestedHref.isEmpty {
                errors.append("\(prefix).observation.requestedHref")
            }
            if !ReaderTOCEvidenceHref.isSafeRelative(entry.observation.requestedHref) {
                errors.append("\(prefix).observation.unsafeHref")
            }
            switch entry.partition {
            case "required":
                if entry.observation.observedLocatorHref != ReaderTOCNavigationState.resourceHref(entry.observation.requestedHref) {
                    errors.append("\(prefix).observation.locatorMismatch")
                }
                if entry.observation.contentSelector?.isEmpty != false
                    || entry.observation.observedContent?.isEmpty != false {
                    errors.append("\(prefix).observation.content")
                }
            case "counterexample":
                if entry.observation.observedLocatorHref == nil
                    || entry.observation.observedLocatorHref == ReaderTOCNavigationState.resourceHref(entry.observation.requestedHref) {
                    errors.append("\(prefix).observation.counterexampleLocator")
                }
                if entry.observation.contentSelector != nil || entry.observation.observedContent != nil {
                    errors.append("\(prefix).observation.counterexampleContent")
                }
            default:
                break
            }
        }
        return errors
    }
}

struct ReaderTOCItem: Identifiable {
    let id: String
    let path: [Int]
    let depth: Int
    let title: String
    let href: String
    let link: ReadiumShared.Link
}

enum ReaderTOCHierarchy {
    static func flatten(_ links: [ReadiumShared.Link]) -> [ReaderTOCItem] {
        var items: [ReaderTOCItem] = []

        func append(_ links: [ReadiumShared.Link], parentPath: [Int], depth: Int) {
            for (index, link) in links.enumerated() {
                let path = parentPath + [index]
                items.append(
                    ReaderTOCItem(
                        id: path.map(String.init).joined(separator: "."),
                        path: path,
                        depth: depth,
                        title: link.title?.isEmpty == false ? link.title! : L10n.string("目錄"),
                        href: link.url().string,
                        link: link
                    )
                )
                append(link.children, parentPath: path, depth: depth + 1)
            }
        }

        append(links, parentPath: [], depth: 0)
        return items
    }
}

/// 閱讀器 UI 狀態容器，整合原本散落在 ReaderView 的 @State 屬性
@Observable
@MainActor
final class ReaderViewState {
    let runtime: ReaderRuntimeState
    let clock: ReaderRuntimeClock

    init(
        runtimeSelection: ReaderRuntimeSelection = ReaderRuntimeFixtureAdapter.selection(scenario: nil),
        initialProgression: Double? = nil,
        clock: ReaderRuntimeClock = .live
    ) {
        runtime = ReaderRuntimeState(
            selection: runtimeSelection,
            initialProgression: initialProgression
        )
        self.clock = clock
    }

    // Loading
    var isWebViewReady = false
    var isLoading: Bool { runtime.isLoading }
    private(set) var loadingPhaseOverride: String?
    var loadingPhase: String { loadingPhaseOverride ?? runtime.loadingPhase }
    var errorMessage: String? { runtime.errorMessage }
    var loadingState: ReaderLoadingState { runtime.loadingState }

    func updateLoadingPhase(_ phase: String) {
        loadingPhaseOverride = phase
    }

    func resetLoadingPhase() {
        loadingPhaseOverride = nil
    }

    // Progress
    var progressState: ReaderProgressState { runtime.progressState }
    var underlineProgress: Double?
    var hasCompletedInitialMarking = false

    // Navigation
    var showTableOfContents = false
    var showSubscriptionPaywall = false
    var detailEntry: VocabularyEntry?
}
#endif
