import Foundation
import Observation
import SwiftData

enum AddLinkCreationPhase: Equatable {
    case idle
    case running
    case succeeded
    case succeededWithWarnings
    case failed
    case blocked
    case cancelled

    var isRunning: Bool { self == .running }
}

enum AddLinkLocalTargetState: Equatable {
    case missing
    case pending
    case failed
    case archived
    /// Exists in the notebook and can be linked from the candidate list.
    case active
    /// Exists and the source card already links to it.
    case linked
    case source
}

/// Injectable time and identity sources for the creation flow.
///
/// Production uses `.live`; tests inject a recording sleeper (no real 500 ms
/// waits), a fake monotonic clock (so the 90 s polling timeout runs instantly)
/// and a deterministic key factory so idempotency-key policy is observable.
struct AddLinkCreationEnvironment: Sendable {
    var pollIntervalNanoseconds: UInt64 = 500_000_000
    var sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    var makeIdempotencyKey: @Sendable () -> String = { UUID().uuidString.lowercased() }
    /// Total client budget for one attempt (POST + polling). The backend marks
    /// orphaned operations `interrupted` on restart, but an operation can still
    /// hang without one; the client must never poll forever.
    var pollTimeoutNanoseconds: UInt64 = 90_000_000_000
    /// Monotonic nanoseconds.
    var now: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    static let live = AddLinkCreationEnvironment()
}

/// What a retry of a failed/interrupted creation must send.
///
/// The backend dedupes on `(user_id, idempotency_key)` and a failed operation
/// is terminal, so reusing a key after a terminal failure would only replay the
/// old failure. The key is reused only when the POST never got an answer
/// (network-layer resend); an operation whose polling merely lost transport is
/// resumed by id instead of being re-created.
enum AddLinkCreationRetryPlan: Equatable {
    /// POST again with a brand-new key (business retry after terminal failure).
    case fresh
    /// POST again with the same key (the first POST was never acknowledged).
    case resendWithSameKey(String)
    /// Keep polling the existing operation (it is not known to be terminal).
    case resumePolling(operationId: String)

    static func make(
        operationId: String?,
        operationTerminal: Bool,
        idempotencyKey: String
    ) -> AddLinkCreationRetryPlan {
        guard let operationId else { return .resendWithSameKey(idempotencyKey) }
        return operationTerminal ? .fresh : .resumePolling(operationId: operationId)
    }
}

/// Collaborators needed to (re)launch a creation outside the sheet that began it.
struct AddLinkCreationServices {
    let operationService: any AddLinkOperationServing
    let syncService: any VocabularySyncServing
    let container: ModelContainer
}

/// Everything a long-lived owner needs to retry or resume a job.
struct AddLinkCreationContext {
    let services: AddLinkCreationServices
    let sourceEntry: VocabularyEntry
}

/// Immutable snapshot of a coordinator's durable-relevant state.
struct AddLinkCreationJobState: Equatable {
    var jobKey: String
    var word: String
    var sourceCardID: String
    var notebookId: String
    var idempotencyKey: String
    var operationId: String?
    var operationTerminal: Bool
    var phase: AddLinkCreationPhase
    var message: String?
    var failureReason: String?
    var warnings: [AddLinkCreationWarning]
}

@MainActor
protocol AddLinkCreationObserving: AnyObject {
    /// Called when phase, operation identity, or message changes (not per
    /// progress tick; observers read `steps`/`fraction` from the coordinator).
    func creationDidChange(_ coordinator: AddLinkCreationCoordinator)
    /// True when another coordinator already runs this job; a second start would
    /// race the first one for the same card.
    func creationIsActive(jobKey: String, excluding coordinator: AddLinkCreationCoordinator) -> Bool
}

/// Coordinates the client half of missing-target Add Link.
///
/// It never creates a local VocabularyEntry. The server operation is
/// authoritative; after the link commits, the existing serialized pull
/// projects the canonical card and graph state into SwiftData.
@Observable @MainActor
final class AddLinkCreationCoordinator {
    private(set) var phase: AddLinkCreationPhase = .idle
    private(set) var steps: [PipelineStep] = []
    private(set) var fraction: Double = 0
    private(set) var operationId: String?
    private(set) var message: String?
    /// Classified cause of the current `.failed` phase.
    private(set) var failure: AddLinkCreationFailure?
    /// What did not complete in the current `.succeededWithWarnings` phase.
    private(set) var warnings: [AddLinkCreationWarning] = []
    /// True while `retryWarnings()` re-runs the missing parts; the phase stays
    /// `.succeededWithWarnings` so the durable job never looks "creating" again.
    private(set) var isRetryingWarnings = false
    private(set) var idempotencyKey: String = ""
    private(set) var operationTerminal = false
    private(set) var context: AddLinkCreationContext?
    private(set) var jobKey: String?
    private(set) var targetWord: String = ""

    @ObservationIgnored weak var observer: (any AddLinkCreationObserving)?
    private let environment: AddLinkCreationEnvironment
    private var generation = 0
    private var lastSequence = -1
    private var pollingTask: Task<Void, Never>?

    init(
        environment: AddLinkCreationEnvironment = .live,
        observer: (any AddLinkCreationObserving)? = nil
    ) {
        self.environment = environment
        self.observer = observer
    }

    var jobState: AddLinkCreationJobState? {
        guard let jobKey, let context, let sourceCardID = context.sourceEntry.kgCardId else { return nil }
        return AddLinkCreationJobState(
            jobKey: jobKey,
            word: targetWord,
            sourceCardID: sourceCardID,
            notebookId: context.sourceEntry.notebookId,
            idempotencyKey: idempotencyKey,
            operationId: operationId,
            operationTerminal: operationTerminal,
            phase: phase,
            message: message,
            failureReason: failure?.reason,
            warnings: warnings
        )
    }

    /// Stable identity of "this source card gains a link to this word".
    nonisolated static func jobKey(sourceCardID: String, word: String) -> String {
        "\(sourceCardID)|\(normalizeWord(word))"
    }

    /// Trims whitespace and drops trailing `.,;:!?` — the backend's `_clean_content`.
    /// The candidate search uses it too, so `run.` finds the same words as `run`.
    nonisolated static func cleanedQuery(_ word: String) -> String {
        var cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cleaned.last, ".,;:!?".contains(last) {
            cleaned.removeLast()
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mirrors the backend's target resolution: `_clean_content` (trim, drop
    /// trailing `.,;:!?`) followed by `find_by_content`'s NFC + lowercase key.
    /// Diacritics stay significant, exactly as on the server.
    nonisolated static func canonicalWord(_ word: String) -> String {
        cleanedQuery(word).precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    nonisolated static func normalizeWord(_ word: String) -> String {
        canonicalWord(word)
    }

    nonisolated static func localTargetState(
        query: String,
        sourceEntry: VocabularyEntry,
        allEntries: [VocabularyEntry]
    ) -> AddLinkLocalTargetState {
        let normalizedQuery = normalizeWord(query)
        guard !normalizedQuery.isEmpty else { return .missing }
        if normalizeWord(sourceEntry.word) == normalizedQuery { return .source }

        guard let target = allEntries.first(where: {
            $0.id != sourceEntry.id
                && $0.notebookId == sourceEntry.notebookId
                && normalizeWord($0.word) == normalizedQuery
                && $0.syncAction != .delete
        }) else { return .missing }

        if target.isArchived { return .archived }
        if target.isFailedAdd || target.syncState == .failed { return .failed }
        if target.isPendingAdd || target.kgCardId == nil { return .pending }
        let linkedIDs = Set(sourceEntry.graphLinksByKind.values.flatMap { $0 }.map(\.cardId))
        if let targetCardID = target.kgCardId, linkedIDs.contains(targetCardID) { return .linked }
        return .active
    }

    func start(
        word: String,
        sourceEntry: VocabularyEntry,
        allEntries: [VocabularyEntry],
        operationService: any AddLinkOperationServing,
        syncService: any VocabularySyncServing,
        container: ModelContainer
    ) {
        // Capture the retry plan of the attempt being replaced before cancel()
        // can touch its state.
        let previousPlan = pendingRetryPlan(for: sourceEntry, word: word)
        cancel()
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty else {
            block(message: L10n.string("找不到符合的單字"))
            return
        }

        switch Self.localTargetState(query: trimmedWord, sourceEntry: sourceEntry, allEntries: allEntries) {
        case .missing, .active:
            // #3115: an existing word is one pipeline with a new word. The server resolves
            // it as existing_card (translate/create/enrich skipped), so the link runs under
            // the same progress panel, idempotency key and hub ownership.
            break
        case .pending, .failed:
            block(message: L10n.string("此單字尚未同步，無法建立連結"))
            return
        case .archived:
            block(message: AddLinkCreationFailure(reason: "target_archived").message)
            return
        case .active:
            block(message: L10n.string("addLink.target.linkable"))
            return
        case .linked:
            block(message: L10n.string("addLink.target.alreadyLinked"))
            return
        case .source:
            block(message: AddLinkCreationFailure(reason: "target_is_source").message)
            return
        }

        launch(
            word: trimmedWord,
            sourceEntry: sourceEntry,
            services: AddLinkCreationServices(
                operationService: operationService,
                syncService: syncService,
                container: container
            ),
            plan: previousPlan
        )
    }

    /// Relaunches a job outside the sheet that began it (retry from the card, or
    /// resume after an app kill). Skips the local-target guard: the caller
    /// already knows this word is a known job, and the server resolves an
    /// already-existing card idempotently.
    func relaunch(
        word: String,
        sourceEntry: VocabularyEntry,
        services: AddLinkCreationServices,
        plan: AddLinkCreationRetryPlan,
        idempotencyKey: String? = nil
    ) {
        cancel()
        launch(
            word: word.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceEntry: sourceEntry,
            services: services,
            plan: plan,
            forcedKey: idempotencyKey
        )
    }

    /// Re-runs only what a succeeded-with-warnings creation left undone: the
    /// link already exists on the server, so nothing is POSTed again. A missing
    /// explanation re-queues the notebook pipeline; then the canonical pull runs.
    func retryWarnings() {
        guard phase == .succeededWithWarnings, !isRetryingWarnings, let context else { return }
        generation += 1
        let currentGeneration = generation
        let pending = warnings
        pollingTask?.cancel()
        isRetryingWarnings = true
        publish()

        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = pending.filter { $0 == .enrichmentIncomplete }
            if !remaining.isEmpty {
                do {
                    try await context.services.syncService.triggerPipeline(
                        notebookId: context.sourceEntry.notebookId
                    )
                    remaining.removeAll()
                } catch {
                    // Still missing; the pull below runs anyway.
                }
            }
            guard self.isCurrent(currentGeneration) else { return }
            await self.projectLocally(
                remoteWarnings: remaining,
                serverReportedWarnings: false,
                syncService: context.services.syncService,
                container: context.services.container,
                notebookId: context.sourceEntry.notebookId,
                generation: currentGeneration
            )
            if self.generation == currentGeneration {
                self.isRetryingWarnings = false
                self.pollingTask = nil
            }
        }
    }

    /// `retryWarnings()` for a warning job restored from disk (no live
    /// coordinator survived the relaunch).
    func relaunchWarningRetry(record: PendingLinkCreationRecord, context restored: AddLinkCreationContext) {
        cancel()
        guard let sourceCardID = restored.sourceEntry.kgCardId, !sourceCardID.isEmpty else {
            block(message: L10n.string("此單字尚未同步，無法建立連結"))
            return
        }
        jobKey = Self.jobKey(sourceCardID: sourceCardID, word: record.word)
        targetWord = record.word
        context = restored
        idempotencyKey = record.idempotencyKey
        operationId = record.operationId
        operationTerminal = record.operationTerminal
        lastSequence = -1
        steps = Self.initialSteps().map { step in
            var step = step
            if step.id != "local_projection" { step.status = .done }
            return step
        }
        fraction = 0
        recomputeFraction()
        failure = nil
        warnings = AddLinkCreationWarning.parse(record.warnings ?? [])
        phase = .succeededWithWarnings
        message = L10n.string("addLink.creation.warning.summary")
        retryWarnings()
    }

    /// The user is done with a finished or failed attempt ("done" on a warning,
    /// "back to search" on a failure). Returns to `.idle`; the hub retires the
    /// job because this is an explicit user decision, never an automatic one.
    func acknowledge() {
        guard phase != .running else { return }
        generation += 1
        pollingTask?.cancel()
        pollingTask = nil
        isRetryingWarnings = false
        failure = nil
        warnings = []
        transition(.idle, message: nil)
    }

    func cancel() {
        generation += 1
        pollingTask?.cancel()
        pollingTask = nil
        isRetryingWarnings = false
        if phase == .running {
            transition(.cancelled, message: nil)
        }
    }

    private func block(message: String) {
        failure = nil
        warnings = []
        transition(.blocked, message: message)
    }

    /// Plan for a retry of the attempt this coordinator last ran for the same
    /// job. Anything else (first attempt, different word, previous attempt
    /// succeeded) starts clean with a new key.
    private func pendingRetryPlan(for sourceEntry: VocabularyEntry, word: String) -> AddLinkCreationRetryPlan {
        guard phase == .failed,
              let sourceCardID = sourceEntry.kgCardId,
              jobKey == Self.jobKey(sourceCardID: sourceCardID, word: word)
        else { return .fresh }
        return AddLinkCreationRetryPlan.make(
            operationId: operationId,
            operationTerminal: operationTerminal,
            idempotencyKey: idempotencyKey
        )
    }

    private func launch(
        word: String,
        sourceEntry: VocabularyEntry,
        services: AddLinkCreationServices,
        plan: AddLinkCreationRetryPlan,
        forcedKey: String? = nil
    ) {
        guard let sourceCardID = sourceEntry.kgCardId, !sourceCardID.isEmpty else {
            block(message: L10n.string("此單字尚未同步，無法建立連結"))
            return
        }
        let key = Self.jobKey(sourceCardID: sourceCardID, word: word)
        if observer?.creationIsActive(jobKey: key, excluding: self) == true {
            block(message: L10n.string("addLink.creation.alreadyRunning"))
            return
        }

        generation += 1
        let currentGeneration = generation
        jobKey = key
        targetWord = word
        context = AddLinkCreationContext(services: services, sourceEntry: sourceEntry)
        lastSequence = -1
        steps = Self.initialSteps()
        fraction = 0
        operationTerminal = false
        failure = nil
        warnings = []

        let sendPlan: SendPlan
        switch plan {
        case .fresh:
            let fresh = environment.makeIdempotencyKey()
            idempotencyKey = fresh
            operationId = nil
            sendPlan = .post(key: fresh)
        case .resendWithSameKey(let sameKey):
            idempotencyKey = sameKey
            operationId = nil
            sendPlan = .post(key: sameKey)
        case .resumePolling(let existingOperationId):
            idempotencyKey = forcedKey ?? idempotencyKey
            operationId = existingOperationId
            sendPlan = .poll(operationId: existingOperationId)
        }
        transition(.running, message: nil)

        let request = KGAddLinkOperationRequest(
            fromId: sourceCardID,
            targetWord: word,
            translation: nil,
            context: sourceEntry.context,
            source: Self.source(for: sourceEntry),
            sourceLang: sourceEntry.sourceLang,
            targetLang: sourceEntry.targetLang
        )

        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(
                request: request,
                notebookId: sourceEntry.notebookId,
                sendPlan: sendPlan,
                services: services,
                generation: currentGeneration
            )
            if self.generation == currentGeneration { self.pollingTask = nil }
        }
    }

    private enum SendPlan {
        case post(key: String)
        case poll(operationId: String)
    }

    private func run(
        request: KGAddLinkOperationRequest,
        notebookId: String,
        sendPlan: SendPlan,
        services: AddLinkCreationServices,
        generation: Int
    ) async {
        let operationService = services.operationService
        // One budget per attempt, POST included: an operation the server never
        // finishes (no restart to mark it `interrupted`) must not be polled forever.
        let deadline = environment.now() &+ environment.pollTimeoutNanoseconds
        do {
            let first: KGAddLinkOperationStatus
            switch sendPlan {
            case .post(let key):
                first = try await operationService.startAddLinkOperation(
                    request: request, notebookId: notebookId, idempotencyKey: key
                )
            case .poll(let existingOperationId):
                first = try await operationService.fetchAddLinkOperation(operationId: existingOperationId)
            }
            guard isCurrent(generation) else { return }
            // The server acknowledged: from here on `operationId` identifies the
            // job, and the key must never be reused for a business retry.
            operationId = first.operationId
            publish()
            apply(first, generation: generation)

            var current = first
            while !current.isTerminal {
                try await environment.sleep(environment.pollIntervalNanoseconds)
                try Task.checkCancellation()
                guard isCurrent(generation) else { return }
                if environment.now() >= deadline {
                    // Abandon the stuck operation: the retry must re-create, not resume.
                    operationTerminal = true
                    finishFailure(
                        AddLinkCreationFailure(reason: AddLinkCreationFailure.timedOutReason),
                        generation: generation
                    )
                    return
                }
                current = try await operationService.fetchAddLinkOperation(operationId: first.operationId)
                guard isCurrent(generation) else { return }
                apply(current, generation: generation)
            }

            guard isCurrent(generation) else { return }
            switch current.status {
            case "succeeded", "succeeded_with_warnings":
                await projectLocally(
                    remoteWarnings: AddLinkCreationWarning.parse(current.warnings),
                    serverReportedWarnings: current.completedWithWarnings,
                    syncService: services.syncService,
                    container: services.container,
                    notebookId: notebookId,
                    generation: generation
                )
            case "failed", "interrupted":
                operationTerminal = true
                let reason = current.errorCode ?? (current.status == "interrupted" ? "interrupted" : nil)
                finishFailure(AddLinkCreationFailure(reason: reason), generation: generation)
            default:
                operationTerminal = true
                finishFailure(AddLinkCreationFailure(reason: nil), generation: generation)
            }
        } catch is CancellationError {
            guard self.generation == generation else { return }
            transition(.cancelled, message: nil)
        } catch {
            guard isCurrent(generation) else { return }
            var failure = AddLinkCreationFailure(error: error)
            if failure.kind == .operationNotFound {
                if operationId == nil {
                    // A 404 on the POST is not "the operation vanished".
                    failure = AddLinkCreationFailure(reason: nil)
                } else {
                    // The server forgot the operation; only a new one can proceed.
                    operationTerminal = true
                }
            }
            fail(generation: generation, failure: failure)
        }
    }

    /// Single place that moves the phase, so observers (the durable hub) never
    /// miss a transition.
    private func transition(_ newPhase: AddLinkCreationPhase, message newMessage: String?) {
        phase = newPhase
        message = newMessage
        publish()
    }

    private func publish() {
        observer?.creationDidChange(self)
    }

    /// Pulls the canonical server state into SwiftData and settles the phase.
    /// `remoteWarnings` are the parts the server could not complete; a failed
    /// pull adds `.localSyncIncomplete`. Any warning keeps the sheet open.
    private func projectLocally(
        remoteWarnings: [AddLinkCreationWarning],
        serverReportedWarnings: Bool,
        syncService: any VocabularySyncServing,
        container: ModelContainer,
        notebookId: String,
        generation: Int
    ) async {
        guard isCurrent(generation) else { return }
        mutateStep("local_projection") { step in
            step.status = .running
            step.current = 0
            step.total = 0
            step.detail = L10n.string("同步中…")
        }

        var outcomeWarnings = remoteWarnings
        do {
            let outcome = try await syncService.pullCardsToLocal(
                container: container,
                progress: { [weak self] detail, current, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrent(generation) else { return }
                        self.mutateStep("local_projection") { step in
                            step.status = .running
                            step.current = current
                            step.total = total
                            if !detail.isEmpty { step.detail = detail }
                        }
                    }
                },
                notebookId: notebookId
            )
            guard isCurrent(generation) else { return }
            mutateStep("local_projection") { step in
                step.status = .done
                step.current = 1
                step.total = 1
                step.detail = outcome.hasChanges
                    ? L10n.format("同步 %@ 筆", String(outcome.changedEntryCount))
                    : L10n.string("已是最新")
            }
            // A successful pull carries any lagging link projection with it.
            outcomeWarnings.removeAll { $0 == .linkProjectionPending }
        } catch is CancellationError {
            guard self.generation == generation else { return }
            transition(.cancelled, message: nil)
            return
        } catch {
            guard isCurrent(generation) else { return }
            mutateStep("local_projection") { step in
                step.status = .error
                step.detail = L10n.string("同步失敗")
            }
            outcomeWarnings.append(.localSyncIncomplete)
        }
        recomputeFraction(forceTerminal: true)
        failure = nil
        warnings = AddLinkCreationWarning.allCases.filter(outcomeWarnings.contains)
        isRetryingWarnings = false
        if warnings.isEmpty && !serverReportedWarnings {
            transition(.succeeded, message: L10n.string("同步完成"))
        } else {
            transition(.succeededWithWarnings, message: L10n.string("addLink.creation.warning.summary"))
        }
    }

    private func apply(_ status: KGAddLinkOperationStatus, generation: Int) {
        guard isCurrent(generation), status.sequence >= lastSequence else { return }
        lastSequence = status.sequence
        operationId = status.operationId
        for remoteStep in status.steps where remoteStep.id != "local_projection" {
            mutateStep(remoteStep.id) { step in
                step.status = Self.stepStatus(for: remoteStep.status)
                step.current = max(0, remoteStep.current)
                step.total = max(0, remoteStep.total)
                step.detail = Self.detail(for: remoteStep)
            }
        }
        recomputeFraction()
    }

    private func finishFailure(_ failure: AddLinkCreationFailure, generation: Int) {
        guard isCurrent(generation) else { return }
        mutateStep("local_projection") { step in
            step.status = .skipped
            step.detail = L10n.string("已略過")
        }
        fail(generation: generation, failure: failure)
        recomputeFraction()
    }

    private func fail(generation: Int, failure: AddLinkCreationFailure) {
        guard isCurrent(generation) else { return }
        self.failure = failure
        warnings = []
        transition(.failed, message: failure.message)
    }

    private func mutateStep(_ id: String, _ mutation: (inout PipelineStep) -> Void) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        mutation(&steps[index])
        recomputeFraction()
    }

    private func recomputeFraction(forceTerminal: Bool = false) {
        let totalWeight = steps.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return }
        let earned = steps.reduce(0.0) { partial, step in
            let completion: Double
            switch step.status {
            case .done, .skipped: completion = 1
            case .waiting, .error: completion = 0
            case .running, .retry:
                guard step.total > 0 else { return partial + step.weight * 0.15 }
                completion = max(0.15, min(1, Double(step.current) / Double(step.total)))
            }
            return partial + step.weight * completion
        }
        fraction = max(fraction, min(1, earned / totalWeight))
        if forceTerminal { fraction = 1 }
    }

    private static func initialSteps() -> [PipelineStep] {
        [
            PipelineStep(id: AddLinkStep.resolveTarget.rawValue, label: AddLinkStep.resolveTarget.label, weight: 1),
            PipelineStep(id: AddLinkStep.translate.rawValue, label: AddLinkStep.translate.label, weight: 1),
            PipelineStep(id: AddLinkStep.createCard.rawValue, label: AddLinkStep.createCard.label, weight: 2),
            PipelineStep(id: AddLinkStep.enrich.rawValue, label: AddLinkStep.enrich.label, weight: 3),
            PipelineStep(id: AddLinkStep.createLink.rawValue, label: AddLinkStep.createLink.label, weight: 1),
            PipelineStep(id: AddLinkStep.localProjection.rawValue, label: AddLinkStep.localProjection.label, weight: 2),
        ]
    }

    private static func source(for entry: VocabularyEntry) -> KGVocabSource? {
        // 與 vocab add payload 共用 500 scalar 上限（#2793），超長會讓後端整筆拒收。
        let title = KGService.clampedSourceText(entry.bookTitle)
        guard !title.isEmpty else { return nil }
        let chapter = entry.chapterTitle.map(KGService.clampedSourceText)
        return .book(title: title, chapter: chapter?.isEmpty == false ? chapter : nil)
    }

    private static func stepStatus(for raw: String) -> PipelineStep.StepStatus {
        switch raw {
        case "running": return .running
        case "retry": return .retry
        case "done": return .done
        case "skipped": return .skipped
        case "warning", "error", "interrupted": return .error
        default: return .waiting
        }
    }

    private static func detail(for step: KGAddLinkOperationStep) -> String {
        switch step.detailCode {
        case "completed", "created": return L10n.string("已完成")
        case "existing_card": return L10n.string("已同步")
        case "provided": return L10n.string("已建立")
        case "retryable": return L10n.format("正在重試 (%@/%@)...", String(step.current), String(step.total))
        case "progress": return L10n.format("同步 %@ 筆", String(step.current))
        case "target_missing": return L10n.string("待同步")
        case "client_projection": return L10n.string("同步中…")
        case "interrupted", "cancelled": return L10n.string("addLink.error.interrupted")
        default:
            switch step.status {
            case "error", "warning": return L10n.string("建立失敗")
            case "skipped": return L10n.string("已略過")
            default: return ""
            }
        }
    }

    private func isCurrent(_ expectedGeneration: Int) -> Bool {
        generation == expectedGeneration && !Task.isCancelled
    }
}
