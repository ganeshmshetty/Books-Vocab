import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

// MARK: - Test doubles

/// Scripted `AddLinkOperationServing` + `VocabularySyncServing`.
///
/// Every behavior is a closure over the call ordinal so a test states the
/// server's story ("POST times out once, then answers") in one place.
final class ScriptedCreationService: AddLinkOperationServing, VocabularySyncServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _startKeys: [String] = []
    private var _fetchedOperationIds: [String] = []
    private var _pullCount = 0
    private var _pipelineNotebookIds: [String] = []

    var onStart: @Sendable (Int, String) async throws -> KGAddLinkOperationStatus
    var onFetch: @Sendable (Int, String) async throws -> KGAddLinkOperationStatus
    var onPull: @Sendable () async throws -> KGPullOutcome = { KGPullOutcome(pipelinePending: false, inserted: 1) }
    var onTriggerPipeline: @Sendable () async throws -> Void = {}

    init(
        onStart: @escaping @Sendable (Int, String) async throws -> KGAddLinkOperationStatus,
        onFetch: @escaping @Sendable (Int, String) async throws -> KGAddLinkOperationStatus
    ) {
        self.onStart = onStart
        self.onFetch = onFetch
    }

    var startKeys: [String] { lock.withLock { _startKeys } }
    var fetchedOperationIds: [String] { lock.withLock { _fetchedOperationIds } }
    var pullCount: Int { lock.withLock { _pullCount } }
    var pipelineNotebookIds: [String] { lock.withLock { _pipelineNotebookIds } }

    func startAddLinkOperation(
        request: KGAddLinkOperationRequest,
        notebookId: String,
        idempotencyKey: String
    ) async throws -> KGAddLinkOperationStatus {
        let ordinal = lock.withLock { () -> Int in
            _startKeys.append(idempotencyKey)
            return _startKeys.count
        }
        return try await onStart(ordinal, idempotencyKey)
    }

    func fetchAddLinkOperation(operationId: String) async throws -> KGAddLinkOperationStatus {
        let ordinal = lock.withLock { () -> Int in
            _fetchedOperationIds.append(operationId)
            return _fetchedOperationIds.count
        }
        return try await onFetch(ordinal, operationId)
    }

    func pullCardsToLocal(
        container: ModelContainer,
        progress: ((String, Int, Int) -> Void)?,
        notebookId: String?
    ) async throws -> KGPullOutcome {
        lock.withLock { _pullCount += 1 }
        return try await onPull()
    }

    func batchAdd(entries: [VocabularyEntry], notebookId: String) async throws -> KGAddResponse {
        fatalError("not used")
    }
    func triggerPipeline(notebookId: String) async throws {
        lock.withLock { _pipelineNotebookIds.append(notebookId) }
        try await onTriggerPipeline()
    }
    func batchArchiveCards(words: [String], archived: Bool, notebookId: String) async throws -> KGBatchArchiveResponse {
        fatalError("not used")
    }
    func deleteCard(word: String, notebookId: String) async throws {}
    func batchDeleteCards(words: [String], notebookId: String) async throws -> KGBatchDeleteResponse {
        fatalError("not used")
    }
    func archiveCard(word: String, archived: Bool, notebookId: String) async throws {}
}

/// Manual gate: lets a test hold the server "mid-operation" and release it.
actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [UInt64] = []
    var durations: [UInt64] { lock.withLock { _durations } }
    func record(_ value: UInt64) { lock.withLock { _durations.append(value) } }
}

enum CreationFixtures {
    static func status(
        _ operationId: String = "op-1",
        _ status: String,
        sequence: Int = 0,
        errorCode: String? = nil,
        warnings: [String] = []
    ) -> KGAddLinkOperationStatus {
        KGAddLinkOperationStatus(
            operationId: operationId,
            notebookId: "nb",
            status: status,
            sequence: sequence,
            steps: [],
            targetCardId: nil,
            linkId: nil,
            warnings: warnings,
            errorCode: errorCode
        )
    }

    @MainActor
    static func container() throws -> ModelContainer {
        let schema = Schema([
            VocabularyEntry.self, ReviewRecord.self, Notebook.self, Book.self,
            PodcastSeries.self, PodcastEpisode.self, PodcastProgress.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
    }

    @MainActor
    static func entry(_ word: String, cardID: String?, notebook: String = "nb") -> VocabularyEntry {
        let value = VocabularyEntry(word: word, translation: word, context: "ctx", bookTitle: "Book")
        value.kgCardId = cardID
        value.notebookId = notebook
        // A card the server already knows: synced, not a pending local add.
        if cardID != nil { value.syncState = .synced }
        return value
    }

    /// Instant clock + sequential keys, recording every requested sleep.
    static func environment(
        recorder: SleepRecorder = SleepRecorder(),
        keys: KeySequence = KeySequence()
    ) -> AddLinkCreationEnvironment {
        AddLinkCreationEnvironment(
            pollIntervalNanoseconds: 7,
            sleep: { nanoseconds in
                recorder.record(nanoseconds)
                await Task.yield()
            },
            makeIdempotencyKey: { keys.next() }
        )
    }

    @MainActor
    static func eventually(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

final class KeySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private(set) var issued: [String] = []
    func next() -> String {
        lock.withLock {
            counter += 1
            let key = "key-\(counter)"
            issued.append(key)
            return key
        }
    }
}

// MARK: - Retry plan (C16 policy table)

@Suite("Add Link creation retry plan")
struct AddLinkCreationRetryPlanTests {
    @Test("unacknowledged POST resends with the same key")
    func unacknowledgedPost() {
        #expect(
            AddLinkCreationRetryPlan.make(operationId: nil, operationTerminal: false, idempotencyKey: "k")
                == .resendWithSameKey("k")
        )
    }

    @Test("terminal failure retries with a fresh key")
    func terminalFailure() {
        #expect(
            AddLinkCreationRetryPlan.make(operationId: "op", operationTerminal: true, idempotencyKey: "k")
                == .fresh
        )
    }

    @Test("lost transport on a live operation resumes polling instead of re-creating")
    func transportLoss() {
        #expect(
            AddLinkCreationRetryPlan.make(operationId: "op", operationTerminal: false, idempotencyKey: "k")
                == .resumePolling(operationId: "op")
        )
    }
}

// MARK: - Coordinator seam + C16

@Suite("Add Link creation coordinator seam", .serialized)
@MainActor
struct AddLinkCreationCoordinatorSeamTests {
    private func start(
        _ coordinator: AddLinkCreationCoordinator,
        word: String = "luminous",
        source: VocabularyEntry,
        service: ScriptedCreationService,
        container: ModelContainer
    ) {
        coordinator.start(
            word: word,
            sourceEntry: source,
            allEntries: [source],
            operationService: service,
            syncService: service,
            container: container
        )
    }

    @Test("polling waits on the injected clock and projects locally on success")
    func injectedClockDrivesPolling() async throws {
        let recorder = SleepRecorder()
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "running", sequence: 1) },
            onFetch: { ordinal, _ in
                CreationFixtures.status("op-1", ordinal < 2 ? "running" : "succeeded", sequence: ordinal + 1)
            }
        )
        let container = try CreationFixtures.container()
        let coordinator = AddLinkCreationCoordinator(
            environment: CreationFixtures.environment(recorder: recorder)
        )
        start(coordinator, source: CreationFixtures.entry("source", cardID: "src"), service: service, container: container)

        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })
        #expect(recorder.durations == [7, 7])
        #expect(service.pullCount == 1)
    }

    @Test("C16: a POST that never answered is resent with the same idempotency key")
    func unacknowledgedPostReusesKey() async throws {
        let keys = KeySequence()
        let service = ScriptedCreationService(
            onStart: { ordinal, _ in
                if ordinal == 1 { throw KGError.offline }
                return CreationFixtures.status("op-1", "succeeded", sequence: 1)
            },
            onFetch: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 2) }
        )
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        let coordinator = AddLinkCreationCoordinator(environment: CreationFixtures.environment(keys: keys))

        start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .failed })
        start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })

        #expect(service.startKeys == ["key-1", "key-1"])
        #expect(keys.issued == ["key-1"])
    }

    @Test("C16: after the operation failed terminally the retry uses a new key")
    func terminalFailureRetryUsesFreshKey() async throws {
        let keys = KeySequence()
        let service = ScriptedCreationService(
            onStart: { ordinal, _ in
                CreationFixtures.status("op-\(ordinal)", ordinal == 1 ? "failed" : "succeeded", sequence: 1,
                                        errorCode: ordinal == 1 ? "translation_failed" : nil)
            },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 2) }
        )
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        let coordinator = AddLinkCreationCoordinator(environment: CreationFixtures.environment(keys: keys))

        start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .failed })
        start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })

        #expect(service.startKeys == ["key-1", "key-2"])
    }

    @Test("transport loss while polling resumes the same operation, no second POST")
    func transportLossResumesOperation() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "running", sequence: 1) },
            onFetch: { ordinal, _ in
                if ordinal == 1 { throw KGError.offline }
                return CreationFixtures.status("op-1", "succeeded", sequence: 5)
            }
        )
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        let coordinator = AddLinkCreationCoordinator(environment: CreationFixtures.environment())

        start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .failed })
        start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })

        #expect(service.startKeys.count == 1)
        #expect(service.fetchedOperationIds == ["op-1", "op-1"])
    }

    @Test("a different word never inherits the previous attempt's key")
    func differentWordGetsFreshKey() async throws {
        let service = ScriptedCreationService(
            onStart: { ordinal, _ in
                if ordinal == 1 { throw KGError.offline }
                return CreationFixtures.status("op-2", "succeeded", sequence: 1)
            },
            onFetch: { _, _ in CreationFixtures.status("op-2", "succeeded", sequence: 2) }
        )
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        let coordinator = AddLinkCreationCoordinator(environment: CreationFixtures.environment())

        start(coordinator, word: "alpha", source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .failed })
        start(coordinator, word: "beta", source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })

        #expect(service.startKeys == ["key-1", "key-2"])
    }
}

// MARK: - Hub (C14)

@Suite("Add Link creation hub", .serialized)
@MainActor
struct AddLinkCreationHubTests {
    /// The "signed-in account" the hub reads; tests flip it to simulate a switch.
    private final class UserBox {
        var id: String?
        init(_ id: String? = nil) { self.id = id }
    }

    private struct Rig {
        let user: UserBox
        let hub: AddLinkCreationHub
        let store: EphemeralPendingLinkCreationStore
        let projection: PendingLinkProjection
        let service: ScriptedCreationService
        let container: ModelContainer
        let source: VocabularyEntry
    }

    private func makeRig(
        service: ScriptedCreationService,
        records: [PendingLinkCreationRecord] = [],
        user: String? = nil
    ) throws -> Rig {
        let userBox = UserBox(user)
        let store = EphemeralPendingLinkCreationStore(records: records)
        let projection = PendingLinkProjection()
        let hub = AddLinkCreationHub(
            store: store, projection: projection, environment: CreationFixtures.environment(), userIDProvider: { userBox.id }
        )
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        container.mainContext.insert(source)
        try container.mainContext.save()
        return Rig(user: userBox, hub: hub, store: store, projection: projection, service: service, container: container, source: source)
    }

    /// Starts a creation and drops every reference to the coordinator, the way
    /// closing the sheet does. Only the hub can keep it alive after this.
    private func startAndAbandon(_ rig: Rig, word: String = "luminous") {
        let coordinator = rig.hub.makeCoordinator()
        coordinator.start(
            word: word,
            sourceEntry: rig.source,
            allEntries: [rig.source],
            operationService: rig.service,
            syncService: rig.service,
            container: rig.container
        )
    }

    private func record(
        state: PendingLinkCreationRecord.State = .creating,
        operationId: String? = nil,
        terminal: Bool = false,
        key: String = "persisted-key",
        userId: String? = nil
    ) -> PendingLinkCreationRecord {
        PendingLinkCreationRecord(
            jobKey: AddLinkCreationCoordinator.jobKey(sourceCardID: "src", word: "luminous"),
            word: "luminous",
            sourceCardID: "src",
            notebookId: "nb",
            idempotencyKey: key,
            operationId: operationId,
            operationTerminal: terminal,
            state: state,
            message: state == .failed ? "failed message" : nil,
            createdAt: Date(timeIntervalSince1970: 1),
            userId: userId
        )
    }

    @Test("closing the sheet does not cancel: the hub finishes the operation and the local pull")
    func survivesSheetClose() async throws {
        let gate = Gate()
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "running", sequence: 1) },
            onFetch: { _, _ in
                await gate.wait()
                return CreationFixtures.status("op-1", "succeeded", sequence: 3)
            }
        )
        let rig = try makeRig(service: service)

        startAndAbandon(rig)
        #expect(await CreationFixtures.eventually { rig.hub.jobs.count == 1 })
        #expect(service.pullCount == 0)

        await gate.release()
        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
        #expect(service.pullCount == 1)
        #expect(rig.store.records.isEmpty)
    }

    @Test("a running job shows up on the source card at once and leaves when it completes")
    func pendingItemLifecycle() async throws {
        let gate = Gate()
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "running", sequence: 1) },
            onFetch: { _, _ in
                await gate.wait()
                return CreationFixtures.status("op-1", "succeeded", sequence: 3)
            }
        )
        let rig = try makeRig(service: service)

        startAndAbandon(rig)
        #expect(await CreationFixtures.eventually { !rig.projection.links(forSourceCardID: "src").isEmpty })
        let item = try #require(rig.projection.links(forSourceCardID: "src").first)
        #expect(item.word == "luminous")
        #expect(item.isPending)
        #expect(item.pendingCreationState == .creating)
        #expect(item.cardId.isEmpty)
        #expect(rig.hub.takeDirtySourceCardIDs() == ["src"])

        await gate.release()
        #expect(await CreationFixtures.eventually { rig.projection.links(forSourceCardID: "src").isEmpty })
        // Completion must also ask the screen to rebuild the card.
        #expect(rig.hub.takeDirtySourceCardIDs() == ["src"])
    }

    @Test("the operation id is persisted as soon as the server acknowledges")
    func persistsOperationId() async throws {
        let gate = Gate()
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-9", "running", sequence: 1) },
            onFetch: { _, _ in
                await gate.wait()
                return CreationFixtures.status("op-9", "succeeded", sequence: 3)
            }
        )
        let rig = try makeRig(service: service)

        startAndAbandon(rig)
        #expect(await CreationFixtures.eventually { rig.store.records.first?.operationId == "op-9" })
        let saved = try #require(rig.store.records.first)
        #expect(saved.state == .creating)
        #expect(saved.sourceCardID == "src")
        #expect(saved.word == "luminous")
        #expect(saved.idempotencyKey == "key-1")
        await gate.release()
        #expect(await CreationFixtures.eventually { rig.store.records.isEmpty })
    }

    // MARK: Account boundary (#2132)

    @Test("a job is stamped with the account that started it")
    func recordsAreStampedWithTheAccount() async throws {
        let gate = Gate()
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "running", sequence: 1) },
            onFetch: { _, _ in
                await gate.wait()
                return CreationFixtures.status("op-1", "succeeded", sequence: 3)
            }
        )
        let rig = try makeRig(service: service, user: "user-a")

        startAndAbandon(rig)
        #expect(await CreationFixtures.eventually { rig.store.records.first?.userId == "user-a" })
        await gate.release()
        #expect(await CreationFixtures.eventually { rig.store.records.isEmpty })
    }

    @Test("resume never touches another account's job: no poll, no POST, record erased")
    func resumeDropsOtherAccountsJobs() throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("x", "running") },
            onFetch: { _, _ in CreationFixtures.status("x", "running") }
        )
        // A record written before accounts were stamped has no owner either.
        var legacy = record(operationId: "op-legacy")
        legacy.jobKey = AddLinkCreationCoordinator.jobKey(sourceCardID: "src", word: "legacy")
        legacy.word = "legacy"
        let rig = try makeRig(
            service: service,
            records: [record(operationId: "op-7", userId: "user-a"), legacy],
            user: "user-b"
        )

        rig.hub.resume(services: AddLinkCreationServices(
            operationService: service, syncService: service, container: rig.container
        ))

        #expect(rig.hub.jobs.isEmpty)
        #expect(rig.store.records.isEmpty, "the previous account's typed word must not stay on disk")
        #expect(rig.projection.links(forSourceCardID: "src").isEmpty)
        #expect(service.fetchedOperationIds.isEmpty)
        #expect(service.startKeys.isEmpty)
    }

    @Test("resume still continues the signed-in account's own job")
    func resumeKeepsOwnAccountsJobs() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("never", "failed") },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 9) }
        )
        let rig = try makeRig(
            service: service,
            records: [record(operationId: "op-7", userId: "user-a")],
            user: "user-a"
        )

        rig.hub.resume(services: AddLinkCreationServices(
            operationService: service, syncService: service, container: rig.container
        ))

        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
        #expect(service.fetchedOperationIds.first == "op-7")
    }

    @Test("clearAll (logout / account switch) drops live and stored jobs and cancels the live one")
    func clearAllDropsEverything() async throws {
        let gate = Gate()
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "running", sequence: 1) },
            onFetch: { _, _ in
                await gate.wait()
                return CreationFixtures.status("op-1", "succeeded", sequence: 3)
            }
        )
        let rig = try makeRig(service: service, user: "user-a")
        startAndAbandon(rig)
        #expect(await CreationFixtures.eventually { rig.hub.jobs.count == 1 })
        _ = rig.hub.takeDirtySourceCardIDs()
        let revisionBefore = rig.hub.revision

        rig.hub.clearAll()

        #expect(rig.hub.jobs.isEmpty)
        #expect(rig.store.records.isEmpty)
        #expect(rig.projection.links(forSourceCardID: "src").isEmpty)
        #expect(rig.hub.takeDirtySourceCardIDs() == ["src"], "screens holding that card must rebuild it")
        #expect(rig.hub.revision > revisionBefore)

        // The cancelled operation finishing late must neither resurrect the job
        // nor pull data into the next account's store.
        await gate.release()
        try await Task.sleep(for: .milliseconds(80))
        #expect(rig.hub.jobs.isEmpty)
        #expect(rig.store.records.isEmpty)
        #expect(service.pullCount == 0)
    }

    @Test("failure keeps a failed item with its message; retry uses a fresh key and recovers")
    func failureThenRetry() async throws {
        let service = ScriptedCreationService(
            onStart: { ordinal, _ in
                ordinal == 1
                    ? CreationFixtures.status("op-1", "failed", sequence: 1, errorCode: "translation_failed")
                    : CreationFixtures.status("op-2", "succeeded", sequence: 1)
            },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 2) }
        )
        let rig = try makeRig(service: service)

        startAndAbandon(rig)
        #expect(await CreationFixtures.eventually {
            rig.projection.links(forSourceCardID: "src").first?.pendingCreationState == .failed
        })
        let failed = try #require(rig.store.records.first)
        #expect(failed.state == .failed)
        #expect(failed.operationTerminal)
        #expect(failed.message?.isEmpty == false)

        #expect(rig.hub.retry(jobKey: failed.jobKey))
        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
        #expect(service.startKeys == ["key-1", "key-2"])
    }

    @Test("a failed job never vanishes on its own, only when the user removes it")
    func failedJobIsRemovedOnlyByUser() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "failed", sequence: 1, errorCode: "quota_exhausted") },
            onFetch: { _, id in CreationFixtures.status(id, "failed", sequence: 2) }
        )
        let rig = try makeRig(service: service)
        startAndAbandon(rig)
        #expect(await CreationFixtures.eventually {
            rig.projection.links(forSourceCardID: "src").first?.pendingCreationState == .failed
        })
        try await Task.sleep(for: .milliseconds(50))
        let jobKey = try #require(rig.hub.jobs.keys.first)
        #expect(rig.hub.jobs.count == 1)

        rig.hub.dismiss(jobKey: jobKey)
        #expect(rig.hub.jobs.isEmpty)
        #expect(rig.store.records.isEmpty)
        #expect(rig.projection.links(forSourceCardID: "src").isEmpty)
    }

    @Test("a second start for the same job is blocked while the first is running")
    func duplicateStartIsBlocked() async throws {
        let gate = Gate()
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "running", sequence: 1) },
            onFetch: { _, _ in
                await gate.wait()
                return CreationFixtures.status("op-1", "succeeded", sequence: 3)
            }
        )
        let rig = try makeRig(service: service)

        startAndAbandon(rig)
        #expect(await CreationFixtures.eventually { rig.hub.jobs.count == 1 })
        // The hub registers the job synchronously, but the POST only goes out when the
        // coordinator's task gets its first main-actor turn. Without waiting for it,
        // `startKeys.count == 1` below cannot tell "second start blocked" from "first POST
        // not sent yet" (it read 0), and a wrongly launched second POST would not have
        // reached the service yet either.
        #expect(await CreationFixtures.eventually { service.startKeys.count == 1 })

        let second = rig.hub.makeCoordinator()
        second.start(
            word: "Luminous",
            sourceEntry: rig.source,
            allEntries: [rig.source],
            operationService: service,
            syncService: service,
            container: rig.container
        )
        #expect(second.phase == .blocked)
        // Same grace the dismissal test above uses: let a leaked second launch run before asserting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(service.startKeys.count == 1)
        await gate.release()
        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
    }

    @Test("records survive a relaunch: the pending item is back before anything is resumed")
    func restoredRecordsProjectImmediately() throws {
        let rig = try makeRig(
            service: ScriptedCreationService(
                onStart: { _, _ in CreationFixtures.status("x", "running") },
                onFetch: { _, _ in CreationFixtures.status("x", "running") }
            ),
            records: [record(operationId: "op-7")]
        )
        let item = try #require(rig.projection.links(forSourceCardID: "src").first)
        #expect(item.pendingCreationState == .creating)
        #expect(item.word == "luminous")
    }

    @Test("resume polls the persisted operation by id and completes it; no new POST")
    func resumePollsPersistedOperation() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("never", "failed") },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 9) }
        )
        let rig = try makeRig(service: service, records: [record(operationId: "op-7")])

        rig.hub.resume(services: AddLinkCreationServices(
            operationService: service, syncService: service, container: rig.container
        ))

        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
        #expect(service.startKeys.isEmpty)
        #expect(service.fetchedOperationIds.first == "op-7")
        #expect(service.pullCount == 1)
        #expect(rig.store.records.isEmpty)
    }

    @Test("resume re-sends the same key when the POST never answered before the kill")
    func resumeResendsSameKey() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 1) },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 2) }
        )
        let rig = try makeRig(service: service, records: [record(operationId: nil, key: "persisted-key")])

        rig.hub.resume(services: AddLinkCreationServices(
            operationService: service, syncService: service, container: rig.container
        ))

        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
        #expect(service.startKeys == ["persisted-key"])
    }

    @Test("resume drops jobs whose source card no longer exists")
    func resumeDropsOrphans() throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("x", "running") },
            onFetch: { _, _ in CreationFixtures.status("x", "running") }
        )
        var orphan = record(operationId: "op-7")
        orphan.sourceCardID = "gone"
        orphan.jobKey = AddLinkCreationCoordinator.jobKey(sourceCardID: "gone", word: "luminous")
        let rig = try makeRig(service: service, records: [orphan])

        rig.hub.resume(services: AddLinkCreationServices(
            operationService: service, syncService: service, container: rig.container
        ))

        #expect(rig.hub.jobs.isEmpty)
        #expect(rig.store.records.isEmpty)
        #expect(service.fetchedOperationIds.isEmpty)
    }

    @Test("a failed job restored from disk can be retried after resume re-attaches its context")
    func restoredFailedJobIsRetryable() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-2", "succeeded", sequence: 1) },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 2) }
        )
        let failed = record(state: .failed, operationId: "op-1", terminal: true, key: "old-key")
        let rig = try makeRig(service: service, records: [failed])

        #expect(!rig.hub.retry(jobKey: failed.jobKey), "no context before resume")
        rig.hub.resume(services: AddLinkCreationServices(
            operationService: service, syncService: service, container: rig.container
        ))
        #expect(rig.hub.jobs[failed.jobKey]?.record.state == .failed)

        #expect(rig.hub.retry(jobKey: failed.jobKey))
        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
        #expect(service.startKeys.count == 1)
        #expect(service.startKeys.first != "old-key")
    }
}

// MARK: - Projection / presentation

@Suite("Pending link projection", .serialized)
@MainActor
struct PendingLinkProjectionTests {
    @Test("pending-creation placeholders are regular pending links with a job identity")
    func placeholderIdentity() {
        let link = KGCardLinkSummary.pendingCreation(jobKey: "src|lum", word: "lum", state: .failed)
        #expect(link.isPending)
        #expect(link.isPendingCreation)
        #expect(link.pendingCreationJobKey == "src|lum")
        #expect(link.pendingCreationState == .failed)

        let regular = KGCardLinkSummary(
            id: "l1", cardId: "c1", word: "w", kind: "shares_usage", label: "x", confidence: 1, reason: "r"
        )
        #expect(!regular.isPendingCreation)
        #expect(regular.pendingCreationState == nil)
        #expect(!KGCardLinkSummary.pending(id: "pending-1", cardId: "c", word: "w").isPendingCreation)
    }

    @Test("card presentation lists pending items first and keeps the real group label")
    func presentationMergesPending() {
        let entry = CreationFixtures.entry("source", cardID: "src")
        entry.graphLinksByKind = ["shares_usage": [
            KGCardLinkSummary(id: "l1", cardId: "c1", word: "alpha", kind: "shares_usage",
                              label: "共用用法", confidence: 1, reason: "r"),
        ]]
        let pending = KGCardLinkSummary.pendingCreation(jobKey: "src|lum", word: "lum", state: .creating)

        let card = CardPresentation(entry: entry, pendingLinks: [pending])
        let group = card.activeLinkGroups.first { $0.id == "shares_usage" }

        #expect(group?.items.map(\.word) == ["lum", "alpha"])
        #expect(group?.label == "共用用法")
    }

    @Test("a card with no links at all still gets a group for its pending item")
    func presentationCreatesGroupForPending() {
        let entry = CreationFixtures.entry("source", cardID: "src")
        let pending = KGCardLinkSummary.pendingCreation(jobKey: "src|lum", word: "lum", state: .creating)

        let card = CardPresentation(entry: entry, pendingLinks: [pending])

        #expect(card.activeLinkGroups.map(\.id) == ["shares_usage"])
        #expect(card.totalLinkCount == 1)
    }

    @Test("pending items are never pushed into the overflow of the compact strip")
    func pendingSurvivesShuffleAndLimit() {
        let pending = KGCardLinkSummary.pendingCreation(jobKey: "k", word: "lum", state: .creating)
        let secondPending = KGCardLinkSummary.pendingCreation(jobKey: "k2", word: "lux", state: .failed)
        let normals = (0..<5).map {
            KGCardLinkSummary(id: "l\($0)", cardId: "c\($0)", word: "w\($0)", kind: "shares_usage",
                              label: "x", confidence: 1, reason: "r")
        }
        let allPresentations: [ReviewCardLayoutSolver.GraphLinkPresentation] = [.twoPerGroup, .onePerGroup, .summary]

        for pendingItems in [[pending], [pending, secondPending]] {
            let group = CardLinkGroupPresentation(id: "shares_usage", label: "x", items: normals + pendingItems)
            for _ in 0..<50 {
                // The prepared card keeps every link; the strip cuts per presentation.
                let ordered = group.shuffled().pendingFirst()
                let prepared = ReviewCardLinkGroup(id: ordered.id, label: ordered.label, items: ordered.items, overflowCount: 0)
                for presentation in allPresentations {
                    let row = ReviewCardLinkStripLayout.row(for: prepared, presentation: presentation, isExpanded: false)
                    let leadingIDs = Set(row.leading.map(\.id))
                    for item in pendingItems {
                        #expect(leadingIDs.contains(item.id), "\(presentation): pending \(item.word) hidden behind +N")
                    }
                    // Only real links are counted in "+N"; nothing is lost or duplicated.
                    #expect(row.leading.count + row.overflowCount == normals.count + pendingItems.count)
                }
            }
        }
    }

    @Test("a pending item stays visible even when the caller did not order it first")
    func pendingLeadsWithoutPendingFirst() {
        let pending = KGCardLinkSummary.pendingCreation(jobKey: "k", word: "lum", state: .creating)
        let normals = (0..<4).map {
            KGCardLinkSummary(id: "l\($0)", cardId: "c\($0)", word: "w\($0)", kind: "shares_usage",
                              label: "x", confidence: 1, reason: "r")
        }
        let group = ReviewCardLinkGroup(id: "shares_usage", label: "x", items: normals + [pending], overflowCount: 0)
        let summary = ReviewCardLinkStripLayout.row(for: group, presentation: .summary, isExpanded: false)
        #expect(summary.leading.map(\.id) == [pending.id])
        #expect(summary.overflowCount == normals.count)
        #expect(summary.isExpandable)
    }

    @Test("projection is a plain replace-all store keyed by source card")
    func projectionReplaceAll() {
        let projection = PendingLinkProjection()
        let link = KGCardLinkSummary.pendingCreation(jobKey: "a|b", word: "b", state: .creating)
        projection.replaceAll(with: ["a": [link]])
        #expect(projection.links(forSourceCardID: "a") == [link])
        #expect(projection.links(forSourceCardID: "other").isEmpty)
        #expect(projection.links(forSourceCardID: nil).isEmpty)
        projection.replaceAll(with: [:])
        #expect(projection.links(forSourceCardID: "a").isEmpty)
    }

    @Test("records round-trip through UserDefaults storage")
    func storeRoundTrip() throws {
        let suite = "AddLinkCreationHubTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPendingLinkCreationStore(defaults: defaults)
        let record = PendingLinkCreationRecord(
            jobKey: "src|lum", word: "lum", sourceCardID: "src", notebookId: "nb",
            idempotencyKey: "k", operationId: "op", operationTerminal: false,
            state: .creating, message: nil, createdAt: Date(timeIntervalSince1970: 5)
        )
        store.save([record])
        #expect(store.load() == [record])
        store.save([])
        #expect(store.load().isEmpty)
    }
}

// MARK: - Completion notices for unattended jobs (#3116)

@MainActor
final class RecordingOutcomePoster: AddLinkJobOutcomePosting {
    private(set) var items: [AppToastItem] = []
    func postJobOutcome(_ item: AppToastItem) { items.append(item) }
}

@Suite("Add Link job notice copy (#3116)")
struct AddLinkJobNoticeCopyTests {
    @Test("only terminal outcomes produce a notice")
    @MainActor
    func onlyTerminalOutcomes() {
        #expect(AddLinkJobNotice.item(phase: .running, jobKey: "k", word: "w", message: nil) == nil)
        #expect(AddLinkJobNotice.item(phase: .idle, jobKey: "k", word: "w", message: nil) == nil)
        #expect(AddLinkJobNotice.item(phase: .cancelled, jobKey: "k", word: "w", message: nil) == nil)
        #expect(AddLinkJobNotice.item(phase: .blocked, jobKey: "k", word: "w", message: nil) == nil)
        #expect(AddLinkJobNotice.item(phase: .succeeded, jobKey: "k", word: "w", message: nil)?.style == .success)
        #expect(AddLinkJobNotice.item(phase: .failed, jobKey: "k", word: "w", message: nil)?.style == .error)
        #expect(AddLinkJobNotice.item(phase: .succeededWithWarnings, jobKey: "k", word: "w", message: nil)?.style == .warning)
    }

    @Test("the notice key is stable per job, so one job never stacks two pills")
    @MainActor
    func stableKeyPerJob() {
        let first = AddLinkJobNotice.item(phase: .failed, jobKey: "k", word: "w", message: "a")
        let second = AddLinkJobNotice.item(phase: .failed, jobKey: "k", word: "w", message: "b")
        #expect(first?.key == second?.key)
        #expect(first?.key != AddLinkJobNotice.item(phase: .failed, jobKey: "other", word: "w", message: "a")?.key)
    }
}

@Suite("Add Link job completion notices (#3116)", .serialized)
@MainActor
struct AddLinkJobCompletionNoticeTests {
    private struct Rig {
        let hub: AddLinkCreationHub
        let poster: RecordingOutcomePoster
        let service: ScriptedCreationService
        let container: ModelContainer
        let source: VocabularyEntry
    }

    private let jobKey = AddLinkCreationCoordinator.jobKey(sourceCardID: "src", word: "luminous")

    private func makeRig(
        service: ScriptedCreationService,
        records: [PendingLinkCreationRecord] = []
    ) throws -> Rig {
        let hub = AddLinkCreationHub(
            store: EphemeralPendingLinkCreationStore(records: records),
            projection: PendingLinkProjection(),
            environment: CreationFixtures.environment(),
            userIDProvider: { nil }
        )
        let poster = RecordingOutcomePoster()
        hub.outcomePoster = poster
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        container.mainContext.insert(source)
        try container.mainContext.save()
        return Rig(hub: hub, poster: poster, service: service, container: container, source: source)
    }

    /// Starts a creation. `presented` mirrors the sheet that owns the coordinator.
    @discardableResult
    private func start(_ rig: Rig, presented: Bool = false) -> AddLinkCreationCoordinator {
        let coordinator = rig.hub.makeCoordinator()
        if presented { rig.hub.sheetDidAppear(coordinator) }
        coordinator.start(
            word: "luminous",
            sourceEntry: rig.source,
            allEntries: [rig.source],
            operationService: rig.service,
            syncService: rig.service,
            container: rig.container
        )
        return coordinator
    }

    private func gatedSuccess(_ gate: Gate) -> ScriptedCreationService {
        ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "running", sequence: 1) },
            onFetch: { _, _ in
                await gate.wait()
                return CreationFixtures.status("op-1", "succeeded", sequence: 3)
            }
        )
    }

    @Test("a job that finishes after its sheet closed posts exactly one success notice")
    func successAfterCloseNoticesOnce() async throws {
        let gate = Gate()
        let rig = try makeRig(service: gatedSuccess(gate))
        start(rig)
        #expect(await CreationFixtures.eventually { rig.hub.runningJobs.count == 1 })
        #expect(rig.poster.items.isEmpty)

        await gate.release()
        #expect(await CreationFixtures.eventually { rig.poster.items.count == 1 })
        for _ in 0..<5 { await Task.yield() }
        #expect(rig.poster.items.count == 1)
        let item = try #require(rig.poster.items.first)
        #expect(item.style == .success)
        #expect(item.key == AddLinkJobNotice.key(jobKey: jobKey))
        #expect(item.message.contains("luminous"))
    }

    @Test("a job that finishes while its sheet is presented posts nothing: the sheet shows the outcome")
    func presentedSheetStaysSilent() async throws {
        let gate = Gate()
        let rig = try makeRig(service: gatedSuccess(gate))
        start(rig, presented: true)
        #expect(await CreationFixtures.eventually { rig.hub.runningJobs.count == 1 })

        await gate.release()
        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
        for _ in 0..<5 { await Task.yield() }
        #expect(rig.poster.items.isEmpty)
    }

    @Test("a sheet that presented and then disappeared no longer silences its job")
    func disappearedSheetNoticesOnce() async throws {
        let gate = Gate()
        let rig = try makeRig(service: gatedSuccess(gate))
        let coordinator = start(rig, presented: true)
        #expect(await CreationFixtures.eventually { rig.hub.runningJobs.count == 1 })
        rig.hub.sheetDidDisappear(coordinator)

        await gate.release()
        #expect(await CreationFixtures.eventually { rig.poster.items.count == 1 })
        for _ in 0..<5 { await Task.yield() }
        #expect(rig.poster.items.count == 1)
    }

    @Test("a presented sheet for another coordinator does not silence this job")
    func otherSheetDoesNotSilence() async throws {
        let gate = Gate()
        let rig = try makeRig(service: gatedSuccess(gate))
        // Held for the whole test, so the other sheet is genuinely on screen while the job runs.
        let otherSheet = rig.hub.makeCoordinator()
        rig.hub.sheetDidAppear(otherSheet)
        start(rig)
        #expect(await CreationFixtures.eventually { rig.hub.runningJobs.count == 1 })

        await gate.release()
        #expect(await CreationFixtures.eventually { rig.poster.items.count == 1 })
        withExtendedLifetime(otherSheet) {}
    }

    @Test("a sheet freed without disappearing cannot silence a later job")
    func freedSheetDoesNotSilence() async throws {
        let gate = Gate()
        let rig = try makeRig(service: gatedSuccess(gate))
        // Freed at the end of this statement and never disappears: its stale entry must not
        // match the coordinator of the job started below, even if the address is reused.
        rig.hub.sheetDidAppear(rig.hub.makeCoordinator())
        start(rig)
        #expect(await CreationFixtures.eventually { rig.hub.runningJobs.count == 1 })

        await gate.release()
        #expect(await CreationFixtures.eventually { rig.poster.items.count == 1 })
    }

    @Test("a failure after close posts one error notice and keeps the failed job on its card")
    func failureAfterCloseNoticesOnce() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in
                CreationFixtures.status("op-1", "failed", sequence: 1, errorCode: "translation_failed")
            },
            onFetch: { _, _ in
                CreationFixtures.status("op-1", "failed", sequence: 2, errorCode: "translation_failed")
            }
        )
        let rig = try makeRig(service: service)
        start(rig)
        #expect(await CreationFixtures.eventually { rig.poster.items.count == 1 })
        for _ in 0..<5 { await Task.yield() }
        #expect(rig.poster.items.count == 1)
        #expect(rig.poster.items.first?.style == .error)
        #expect(rig.hub.job(forJobKey: jobKey)?.record.state == .failed)
        #expect(rig.hub.runningJobs.isEmpty)
    }

    @Test("a partial result after close posts one warning notice and keeps the job for retry")
    func warningAfterCloseNoticesOnce() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in
                CreationFixtures.status("op-1", "succeeded_with_warnings", sequence: 1,
                                        warnings: [AddLinkCreationWarning.enrichmentIncomplete.rawValue])
            },
            onFetch: { _, _ in
                CreationFixtures.status("op-1", "succeeded_with_warnings", sequence: 2,
                                        warnings: [AddLinkCreationWarning.enrichmentIncomplete.rawValue])
            }
        )
        let rig = try makeRig(service: service)
        start(rig)
        #expect(await CreationFixtures.eventually { rig.poster.items.count == 1 })
        for _ in 0..<5 { await Task.yield() }
        #expect(rig.poster.items.count == 1)
        #expect(rig.poster.items.first?.style == .warning)
        #expect(rig.hub.job(forJobKey: jobKey)?.record.state == .warning)
    }

    @Test("a job resumed after relaunch and finished in the background posts its notice once")
    func resumedJobNoticesOnce() async throws {
        let gate = Gate()
        let service = gatedSuccess(gate)
        let record = PendingLinkCreationRecord(
            jobKey: jobKey,
            word: "luminous",
            sourceCardID: "src",
            notebookId: "nb",
            idempotencyKey: "persisted-key",
            operationId: "op-1",
            operationTerminal: false,
            state: .creating,
            message: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            userId: nil
        )
        let rig = try makeRig(service: service, records: [record])
        rig.hub.resume(services: AddLinkCreationServices(
            operationService: service,
            syncService: service,
            container: rig.container
        ))
        #expect(await CreationFixtures.eventually { rig.hub.runningJobs.count == 1 })
        #expect(rig.poster.items.isEmpty)

        await gate.release()
        #expect(await CreationFixtures.eventually { rig.poster.items.count == 1 })
        for _ in 0..<5 { await Task.yield() }
        #expect(rig.poster.items.count == 1)
        #expect(rig.poster.items.first?.style == .success)
    }

    /// `retryWarnings()` settles straight from `.succeededWithWarnings` to `.succeeded`
    /// without a `.running` phase, so the record stays `.warning` on completion (#3380).
    @Test("a warning retry that completes after close posts one success notice (#3380)")
    func warningRetryAfterCloseNoticesOnce() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 1) },
            onFetch: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 2) }
        )
        let record = PendingLinkCreationRecord(
            jobKey: jobKey,
            word: "luminous",
            sourceCardID: "src",
            notebookId: "nb",
            idempotencyKey: "persisted-key",
            operationId: "op-1",
            operationTerminal: true,
            state: .warning,
            message: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            warnings: [AddLinkCreationWarning.enrichmentIncomplete.rawValue],
            userId: nil
        )
        let rig = try makeRig(service: service, records: [record])
        rig.hub.resume(services: AddLinkCreationServices(
            operationService: service,
            syncService: service,
            container: rig.container
        ))
        #expect(rig.hub.retry(jobKey: jobKey))
        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
        #expect(await CreationFixtures.eventually { rig.poster.items.count == 1 })
        for _ in 0..<5 { await Task.yield() }
        #expect(rig.poster.items.count == 1)
        #expect(rig.poster.items.first?.style == .success)
        #expect(rig.poster.items.first?.key == AddLinkJobNotice.key(jobKey: jobKey))
    }

    /// A warning retry that settles back on `.succeededWithWarnings` (the pipeline
    /// still has not written the explanation) is a new outcome, not a re-publish:
    /// the user asked for the retry with the sheet closed, so it must notice (#3393).
    @Test("a warning retry that still ends partial after close posts one warning notice (#3393)")
    func warningRetryEndingPartialNoticesOnce() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 1) },
            onFetch: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 2) }
        )
        service.onTriggerPipeline = { throw URLError(.notConnectedToInternet) }
        let record = PendingLinkCreationRecord(
            jobKey: jobKey,
            word: "luminous",
            sourceCardID: "src",
            notebookId: "nb",
            idempotencyKey: "persisted-key",
            operationId: "op-1",
            operationTerminal: true,
            state: .warning,
            message: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            warnings: [AddLinkCreationWarning.enrichmentIncomplete.rawValue],
            userId: nil
        )
        let rig = try makeRig(service: service, records: [record])
        rig.hub.resume(services: AddLinkCreationServices(
            operationService: service,
            syncService: service,
            container: rig.container
        ))
        #expect(rig.hub.retry(jobKey: jobKey))
        #expect(await CreationFixtures.eventually { rig.poster.items.count == 1 })
        for _ in 0..<5 { await Task.yield() }
        #expect(rig.poster.items.count == 1)
        #expect(rig.poster.items.first?.style == .warning)
        #expect(rig.poster.items.first?.key == AddLinkJobNotice.key(jobKey: jobKey))
        #expect(rig.hub.job(forJobKey: jobKey)?.record.state == .warning)

        // A plain re-publish of the same partial outcome, with no retry running, stays silent.
        let live = try #require(rig.hub.jobs[jobKey]?.coordinator)
        rig.hub.creationDidChange(live)
        for _ in 0..<5 { await Task.yield() }
        #expect(rig.poster.items.count == 1)
    }
}
