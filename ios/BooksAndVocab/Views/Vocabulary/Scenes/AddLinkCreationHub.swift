import Foundation
import Observation
import SwiftData

/// Long-lived owner of missing-target Add Link jobs.
///
/// The sheet only *starts* a creation; the hub keeps the coordinator alive after
/// the sheet closes, mirrors every job into a durable record (so an app kill
/// can be resumed) and into `PendingLinkProjection` (so the source card shows a
/// "creating" link immediately). A job leaves the hub only when it fully
/// succeeds, the user dismisses a failure or a partial (warning) result, or its
/// source card no longer exists.
@Observable @MainActor
final class AddLinkCreationHub: AddLinkCreationObserving {
    static let shared = AddLinkCreationHub()

    struct Job {
        var record: PendingLinkCreationRecord
        /// Nil for jobs restored from disk that have not been relaunched yet.
        var coordinator: AddLinkCreationCoordinator?
        var context: AddLinkCreationContext?
    }

    private(set) var jobs: [String: Job] = [:]
    /// Bumps whenever a job appears, changes visible state, or disappears.
    private(set) var revision = 0

    @ObservationIgnored private var dirtySourceCardIDs: Set<String> = []
    @ObservationIgnored private let store: any PendingLinkCreationStoring
    @ObservationIgnored private let projection: PendingLinkProjection
    @ObservationIgnored private let environment: AddLinkCreationEnvironment
    /// The signed-in account, read when a job is stamped and when stored jobs are
    /// resumed (never cached: an account switch changes it under a long-lived hub).
    @ObservationIgnored private let userIDProvider: @MainActor () -> String?
    /// Receives the completion notice of a job no sheet shows (#3116). Weak: the app
    /// root owns the toast coordinator for its whole life.
    @ObservationIgnored weak var outcomePoster: (any AddLinkJobOutcomePosting)?
    /// Coordinators whose sheet is on screen; their own pill or panel carries the outcome.
    /// Weak, never raw `ObjectIdentifier`: a freed coordinator's address can be reused by a
    /// later job, which would then have its completion notice silenced (#3116).
    @ObservationIgnored private var presentingCoordinators: [WeakCoordinator] = []
    /// Warning jobs whose `retry(jobKey:)` is still running. The publish that settles
    /// such a retry is a new outcome; a plain re-publish of the same phase is not (#3393).
    @ObservationIgnored private var warningRetriesInFlight: Set<String> = []
    /// Pending-link detail sheets on screen, counted per job. Such a sheet shows its job's
    /// outcome itself, whichever coordinator runs the job, so the hub posts no notice (#3512).
    @ObservationIgnored private var presentedDetailJobCounts: [String: Int] = [:]

    init(
        store: any PendingLinkCreationStoring = PendingLinkCreationStores.makeDefault(),
        projection: PendingLinkProjection = .shared,
        environment: AddLinkCreationEnvironment = .live,
        userIDProvider: @escaping @MainActor () -> String? = { AuthManager.shared.userId }
    ) {
        self.store = store
        self.projection = projection
        self.environment = environment
        self.userIDProvider = userIDProvider
        for record in store.load() {
            jobs[record.jobKey] = Job(record: record, coordinator: nil, context: nil)
        }
        publishProjection()
    }

    func makeCoordinator() -> AddLinkCreationCoordinator {
        AddLinkCreationCoordinator(environment: environment, observer: self)
    }

    func job(forJobKey jobKey: String) -> Job? { jobs[jobKey] }

    /// Jobs still creating, oldest first: what the job capsule represents (#3116).
    var runningJobs: [Job] {
        jobs.values
            .filter { $0.record.state == .creating }
            .sorted { $0.record.createdAt < $1.record.createdAt }
    }

    /// The sheet that owns `coordinator` is on screen. Its own pill or panel carries
    /// the outcome, so the hub posts nothing for that job (#3116).
    func sheetDidAppear(_ coordinator: AddLinkCreationCoordinator) {
        prunePresentingCoordinators()
        guard !isPresenting(coordinator) else { return }
        presentingCoordinators.append(WeakCoordinator(value: coordinator))
    }

    func sheetDidDisappear(_ coordinator: AddLinkCreationCoordinator) {
        presentingCoordinators.removeAll { $0.value == nil || $0.value === coordinator }
    }

    /// A pending-link detail sheet for `jobKey` is on screen. It is keyed by job, not by
    /// coordinator: a warning retry from that sheet may create its coordinator only now (#3512).
    func detailSheetDidAppear(jobKey: String) {
        presentedDetailJobCounts[jobKey, default: 0] += 1
    }

    func detailSheetDidDisappear(jobKey: String) {
        guard let count = presentedDetailJobCounts[jobKey] else { return }
        presentedDetailJobCounts[jobKey] = count > 1 ? count - 1 : nil
    }

    /// Source card ids whose cached card must be rebuilt because their pending
    /// links changed. Consumed by the review screen that owns the card cache.
    func takeDirtySourceCardIDs() -> Set<String> {
        defer { dirtySourceCardIDs.removeAll() }
        return dirtySourceCardIDs
    }

    // MARK: - AddLinkCreationObserving

    func creationDidChange(_ coordinator: AddLinkCreationCoordinator) {
        guard let state = coordinator.jobState else { return }
        let retryEnded = settleWarningRetry(for: state, coordinator: coordinator)
        let notice = unattendedNotice(for: state, coordinator: coordinator, retryEnded: retryEnded)
        switch state.phase {
        case .running:
            upsert(from: state, coordinator: coordinator, recordState: .creating)
        case .failed:
            upsert(from: state, coordinator: coordinator, recordState: .failed)
        case .succeededWithWarnings:
            // The link exists, but part of it did not complete: keep it on the
            // source card (with retry) until the user retries or dismisses it.
            upsert(from: state, coordinator: coordinator, recordState: .warning)
        case .succeeded:
            guard owns(coordinator, jobKey: state.jobKey) else { return }
            remove(jobKey: state.jobKey)
        case .cancelled, .idle:
            // A restart cancels first; only the coordinator that owns the job may
            // retire it, otherwise a stale sheet could erase a live retry.
            // `.idle` is the user acknowledging a warning or a failure.
            guard owns(coordinator, jobKey: state.jobKey) else { return }
            remove(jobKey: state.jobKey)
        case .blocked:
            break
        }
        if let notice { outcomePoster?.postJobOutcome(notice) }
    }

    func creationIsActive(jobKey: String, excluding coordinator: AddLinkCreationCoordinator) -> Bool {
        guard let live = jobs[jobKey]?.coordinator else { return false }
        return live !== coordinator && live.phase == .running
    }

    // MARK: - User actions on a pending item

    /// Retries a failed job with the key policy of `AddLinkCreationRetryPlan`,
    /// or re-runs the unfinished parts of a warning job (no new POST).
    @discardableResult
    func retry(jobKey: String) -> Bool {
        guard let job = jobs[jobKey] else { return false }
        switch job.record.state {
        case .creating:
            return false
        case .failed:
            guard job.record.failure?.isRetryable != false, let context = job.context else { return false }
            let coordinator = makeCoordinator()
            coordinator.relaunch(
                word: job.record.word,
                sourceEntry: context.sourceEntry,
                services: context.services,
                plan: job.record.retryPlan,
                idempotencyKey: job.record.idempotencyKey
            )
            return true
        case .warning:
            warningRetriesInFlight.insert(jobKey)
            if let live = job.coordinator, live.phase == .succeededWithWarnings {
                live.retryWarnings()
                if !live.isRetryingWarnings { warningRetriesInFlight.remove(jobKey) }
                return true
            }
            guard let context = job.context else {
                warningRetriesInFlight.remove(jobKey)
                return false
            }
            let coordinator = makeCoordinator()
            coordinator.relaunchWarningRetry(record: job.record, context: context)
            if !coordinator.isRetryingWarnings { warningRetriesInFlight.remove(jobKey) }
            return true
        }
    }

    /// The user gives up on a failed job or accepts a partial one; neither may
    /// disappear on its own. A warning retry may still be in flight: it is
    /// cancelled first (its generation bump silences every later callback), or
    /// its eventual `.succeededWithWarnings` / `.failed` publish would upsert the
    /// dismissed job straight back onto the source card.
    func dismiss(jobKey: String) {
        guard let job = jobs[jobKey], job.record.state != .creating else { return }
        cancelRetired(job.coordinator)
        remove(jobKey: jobKey)
    }

    // MARK: - Account boundary

    /// Logout / account switch: forget every job, in memory and on disk. Live
    /// coordinators are cancelled (the hub no longer owns them, so their
    /// `.cancelled` callback is ignored) and the pending placeholders leave the
    /// projection, so nothing the previous account typed survives the boundary.
    func clearAll() {
        let coordinators = jobs.values.compactMap(\.coordinator)
        let sourceCardIDs = jobs.values.map(\.record.sourceCardID)
        jobs.removeAll()
        warningRetriesInFlight.removeAll()
        for coordinator in coordinators { cancelRetired(coordinator) }
        store.save([])
        publishProjection()
        dirtySourceCardIDs.formUnion(sourceCardIDs)
        revision += 1
    }

    // MARK: - Resume after relaunch

    /// Re-attaches every durable job that has no live coordinator. A job that
    /// was still creating is relaunched (resume polling by operation id, or
    /// resend with the same key when the POST never answered); a failed or
    /// warning one only regains the context its retry button needs. Jobs whose source card is
    /// gone (account switch, deletion) are dropped.
    func resume(services: AddLinkCreationServices) {
        dropJobsOfOtherAccounts()
        let context = services.container.mainContext
        for (jobKey, job) in jobs where job.coordinator == nil {
            guard let source = Self.sourceEntry(cardID: job.record.sourceCardID, in: context) else {
                remove(jobKey: jobKey)
                continue
            }
            let restored = AddLinkCreationContext(services: services, sourceEntry: source)
            jobs[jobKey]?.context = restored
            guard job.record.state == .creating else { continue }
            let coordinator = makeCoordinator()
            coordinator.relaunch(
                word: job.record.word,
                sourceEntry: source,
                services: services,
                plan: job.record.retryPlan,
                idempotencyKey: job.record.idempotencyKey
            )
        }
    }

    /// Convenience for screens that only hold the app's service: resumes with the
    /// operation API when the service offers it (previews / fakes do not).
    func resume(kgService: any KGServing, container: ModelContainer) {
        guard let operationService = kgService as? any AddLinkOperationServing else { return }
        resume(services: AddLinkCreationServices(
            operationService: operationService,
            syncService: kgService,
            container: container
        ))
    }

    // MARK: - Internals

    /// A stored job belongs to the account that started it; whatever another
    /// account (or an older, unstamped record) left behind is discarded, never resumed.
    private func dropJobsOfOtherAccounts() {
        let owner = userIDProvider()
        let foreign = jobs.filter { $0.value.record.userId != owner }.map(\.key)
        for jobKey in foreign {
            cancelRetired(jobs[jobKey]?.coordinator)
            remove(jobKey: jobKey)
        }
    }

    /// Cancels the coordinator of a job the hub is retiring. The hub detaches first: a
    /// cancelled warning retry publishes its state, and that publish must not upsert the
    /// job back onto its source card or post a notice for a job the hub already removed.
    private func cancelRetired(_ coordinator: AddLinkCreationCoordinator?) {
        coordinator?.observer = nil
        coordinator?.cancel()
    }

    private func owns(_ coordinator: AddLinkCreationCoordinator, jobKey: String) -> Bool {
        guard let live = jobs[jobKey]?.coordinator else { return false }
        return live === coordinator
    }

    private func isPresenting(_ coordinator: AddLinkCreationCoordinator) -> Bool {
        presentingCoordinators.contains { $0.value === coordinator }
    }

    private func prunePresentingCoordinators() {
        presentingCoordinators.removeAll { $0.value == nil }
    }

    /// The completion notice for a job that was running, is still owned by
    /// `coordinator`, and has no sheet on screen. Read before the upsert/remove so
    /// the previous record state still says "running" (#3116).
    private func unattendedNotice(
        for state: AddLinkCreationJobState,
        coordinator: AddLinkCreationCoordinator,
        retryEnded: Bool
    ) -> AppToastItem? {
        guard let recordState = jobs[state.jobKey]?.record.state,
              Self.completesUnattended(recordState: recordState, phase: state.phase, retryEnded: retryEnded),
              owns(coordinator, jobKey: state.jobKey),
              !isPresenting(coordinator),
              presentedDetailJobCounts[state.jobKey] == nil else { return nil }
        return AddLinkJobNotice.item(
            phase: state.phase,
            jobKey: state.jobKey,
            word: state.word,
            message: state.message
        )
    }

    /// Whether a job's transition is an unattended completion worth a notice. A
    /// `.creating` job may reach any terminal phase. A `.warning` job settles from a
    /// warning retry (`retryWarnings()` has no `.running` phase): `.succeeded`, or
    /// `.succeededWithWarnings` when the retry ends still partial (`retryEnded`).
    /// Other `.succeededWithWarnings` re-publishes are not new outcomes (#3380, #3393).
    private static func completesUnattended(
        recordState: PendingLinkCreationRecord.State,
        phase: AddLinkCreationPhase,
        retryEnded: Bool
    ) -> Bool {
        switch recordState {
        case .creating:
            return true
        case .warning:
            return phase == .succeeded || (retryEnded && phase == .succeededWithWarnings)
        case .failed:
            return false
        }
    }

    /// Whether a warning retry for this job has settled, consuming its in-flight
    /// mark. The coordinator clears `isRetryingWarnings` before its settling publish,
    /// so the mark is only consumed by that publish, never by the retry's start.
    private func settleWarningRetry(
        for state: AddLinkCreationJobState,
        coordinator: AddLinkCreationCoordinator
    ) -> Bool {
        guard owns(coordinator, jobKey: state.jobKey),
              warningRetriesInFlight.contains(state.jobKey),
              !coordinator.isRetryingWarnings else { return false }
        warningRetriesInFlight.remove(state.jobKey)
        return true
    }

    private func upsert(
        from state: AddLinkCreationJobState,
        coordinator: AddLinkCreationCoordinator,
        recordState: PendingLinkCreationRecord.State
    ) {
        let existing = jobs[state.jobKey]
        let record = PendingLinkCreationRecord(
            jobKey: state.jobKey,
            word: state.word,
            sourceCardID: state.sourceCardID,
            notebookId: state.notebookId,
            idempotencyKey: state.idempotencyKey,
            operationId: state.operationId,
            operationTerminal: state.operationTerminal,
            state: recordState,
            message: recordState == .creating ? nil : state.message,
            createdAt: existing?.record.createdAt ?? Date(),
            failureReason: recordState == .failed ? state.failureReason : nil,
            warnings: recordState == .warning ? state.warnings.map(\.rawValue) : nil,
            userId: existing?.record.userId ?? userIDProvider()
        )
        let visibleChange = existing?.record.state != recordState
            || existing?.record.word != record.word
        let recordChanged = existing?.record != record

        jobs[state.jobKey] = Job(record: record, coordinator: coordinator, context: coordinator.context)
        if recordChanged { persist() }
        if visibleChange {
            publishProjection()
            markChanged(sourceCardID: state.sourceCardID)
        }
    }

    private func remove(jobKey: String) {
        warningRetriesInFlight.remove(jobKey)
        guard let job = jobs.removeValue(forKey: jobKey) else { return }
        persist()
        publishProjection()
        markChanged(sourceCardID: job.record.sourceCardID)
    }

    private func markChanged(sourceCardID: String) {
        dirtySourceCardIDs.insert(sourceCardID)
        revision += 1
    }

    private func persist() {
        store.save(jobs.values.map(\.record).sorted { $0.createdAt < $1.createdAt })
    }

    private func publishProjection() {
        var links: [String: [KGCardLinkSummary]] = [:]
        for job in jobs.values.sorted(by: { $0.record.createdAt < $1.record.createdAt }) {
            let state: KGCardLinkSummary.CreationState
            switch job.record.state {
            case .creating: state = .creating
            case .failed: state = .failed
            case .warning: state = .warning
            }
            links[job.record.sourceCardID, default: []].append(
                .pendingCreation(jobKey: job.record.jobKey, word: job.record.word, state: state)
            )
        }
        projection.replaceAll(with: links)
    }

    private static func sourceEntry(cardID: String, in context: ModelContext) -> VocabularyEntry? {
        let target: String? = cardID
        var descriptor = FetchDescriptor<VocabularyEntry>(
            predicate: #Predicate { $0.kgCardId == target }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// Holds a sheet's coordinator without keeping it alive (#3116).
private struct WeakCoordinator {
    weak var value: AddLinkCreationCoordinator?
}

/// Where a completion notice goes. `AppToastCoordinator` is the production sink.
@MainActor
protocol AddLinkJobOutcomePosting: AnyObject {
    func postJobOutcome(_ item: AppToastItem)
}

extension AppToastCoordinator: AddLinkJobOutcomePosting {
    func postJobOutcome(_ item: AppToastItem) {
        show(item)
    }
}

/// Completion copy for a job that finished while no sheet shows it (#3116). The key
/// is stable per job, so one job never stacks two pills.
enum AddLinkJobNotice {
    static func key(jobKey: String) -> String {
        "addLink.job.notice|\(jobKey)"
    }

    static func item(
        phase: AddLinkCreationPhase,
        jobKey: String,
        word: String,
        message: String?
    ) -> AppToastItem? {
        let key = key(jobKey: jobKey)
        switch phase {
        case .succeeded:
            return AppToastItem(
                message: L10n.format("addLink.job.notice.succeeded", word),
                style: .success,
                key: key
            )
        case .failed:
            return AppToastItem(message: message ?? L10n.string("新增連結失敗"), style: .error, key: key)
        case .succeededWithWarnings:
            return AppToastItem(
                message: message ?? L10n.string("addLink.creation.warning.summary"),
                style: .warning,
                key: key
            )
        case .idle, .running, .cancelled, .blocked:
            return nil
        }
    }
}
