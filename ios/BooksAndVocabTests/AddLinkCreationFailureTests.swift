import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

// Issue #2030 (Add Link P1): failure classification, interrupted/timeout/404,
// warnings that keep the sheet open, linking state, and target normalization.

/// Monotonic fake clock: every injected sleep advances it by exactly the
/// requested duration, so a 90 s timeout runs in microseconds.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: UInt64 = 1_000
    var now: UInt64 { lock.withLock { _now } }
    func advance(_ nanoseconds: UInt64) { lock.withLock { _now += nanoseconds } }
}

private enum P1Fixtures {
    static let second: UInt64 = 1_000_000_000

    static func environment(
        interval: UInt64 = 7,
        timeout: UInt64 = 90 * second,
        clock: ManualClock = ManualClock(),
        recorder: SleepRecorder = SleepRecorder(),
        keys: KeySequence = KeySequence()
    ) -> AddLinkCreationEnvironment {
        AddLinkCreationEnvironment(
            pollIntervalNanoseconds: interval,
            sleep: { nanoseconds in
                recorder.record(nanoseconds)
                clock.advance(nanoseconds)
                await Task.yield()
            },
            makeIdempotencyKey: { keys.next() },
            pollTimeoutNanoseconds: timeout,
            now: { clock.now }
        )
    }

    @MainActor
    static func start(
        _ coordinator: AddLinkCreationCoordinator,
        word: String = "luminous",
        source: VocabularyEntry,
        allEntries: [VocabularyEntry]? = nil,
        service: ScriptedCreationService,
        container: ModelContainer
    ) {
        coordinator.start(
            word: word,
            sourceEntry: source,
            allEntries: allEntries ?? [source],
            operationService: service,
            syncService: service,
            container: container
        )
    }
}

// MARK: - Classification table (B9)

@Suite("Add Link creation failure classification")
struct AddLinkCreationFailureClassificationTests {
    @Test("every backend error code maps to its own kind and retry policy")
    func backendCodes() {
        let table: [(String, AddLinkCreationFailure.Kind, Bool)] = [
            ("quota_exhausted", .quotaExhausted, false),
            ("source_unavailable", .sourceUnavailable, false),
            ("target_archived", .targetArchived, false),
            ("target_is_source", .targetIsSource, false),
            ("translation_failed", .translationFailed, true),
            ("translate_unavailable", .serviceUnavailable, true),
            ("create_card_unavailable", .serviceUnavailable, true),
            ("create_link_unavailable", .serviceUnavailable, true),
            ("target_unavailable", .generic, true),
            ("card_creation_failed", .generic, true),
            ("link_creation_failed", .generic, true),
            ("operation_failed", .generic, true),
            ("interrupted", .interrupted, true),
            ("cancelled", .interrupted, true),
        ]
        for (code, kind, retryable) in table {
            let failure = AddLinkCreationFailure(reason: code)
            #expect(failure.reason == code)
            #expect(failure.kind == kind, "\(code)")
            #expect(failure.isRetryable == retryable, "\(code)")
        }
    }

    @Test("enrichment_failed is a warning, never a dedicated failure kind")
    func enrichmentIsNotAFailure() {
        #expect(AddLinkCreationFailure(reason: "enrichment_failed").kind == .generic)
        #expect(AddLinkCreationWarning.parse(["enrichment_failed"]) == [.enrichmentIncomplete])
    }

    @Test("missing code is unknown and generic")
    func missingCode() {
        #expect(AddLinkCreationFailure(reason: nil).reason == "unknown")
        #expect(AddLinkCreationFailure(reason: "  ").kind == .generic)
    }

    @Test("client failures classify transport, auth and 404 separately")
    func clientErrors() {
        #expect(AddLinkCreationFailure(error: KGError.offline).kind == .offline)
        #expect(AddLinkCreationFailure(error: KGError.unauthorized).kind == .notAuthenticated)
        #expect(!AddLinkCreationFailure(error: KGError.notAuthenticated).isRetryable)
        #expect(
            AddLinkCreationFailure(error: KGError.httpError(statusCode: 404, detail: "gone")).kind
                == .operationNotFound
        )
        #expect(AddLinkCreationFailure(error: KGError.httpError(statusCode: 500, detail: "x")).kind == .generic)
    }

    @Test("user-distinguishable kinds never share one message")
    func distinctMessages() {
        let codes = [
            "quota_exhausted", "source_unavailable", "target_archived", "target_is_source",
            "translation_failed", "translate_unavailable", "interrupted", "timed_out",
            "operation_not_found", "offline", "not_authenticated", "operation_failed",
        ]
        let messages = codes.map { AddLinkCreationFailure(reason: $0).message }
        #expect(Set(messages).count == codes.count)
    }

    @Test("warnings parse in a stable order and ignore unknown codes")
    func warningParse() {
        #expect(
            AddLinkCreationWarning.parse(["link_projection_pending", "zzz", "enrichment_failed"])
                == [.enrichmentIncomplete, .linkProjectionPending]
        )
    }
}

// MARK: - Coordinator phase transitions

@Suite("Add Link creation P1 coordinator", .serialized)
@MainActor
struct AddLinkCreationP1CoordinatorTests {
    @Test("backend target_archived fails with its own reason and no retry")
    func archivedTargetFailure() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "failed", sequence: 1, errorCode: "target_archived") },
            onFetch: { _, id in CreationFixtures.status(id, "failed", sequence: 2) }
        )
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())
        P1Fixtures.start(coordinator, source: CreationFixtures.entry("source", cardID: "src"),
                         service: service, container: try CreationFixtures.container())

        #expect(await CreationFixtures.eventually { coordinator.phase == .failed })
        #expect(coordinator.failure?.kind == .targetArchived)
        #expect(coordinator.failure?.isRetryable == false)
        #expect(coordinator.message == AddLinkCreationFailure(reason: "target_archived").message)
    }

    @Test("interrupted operation is classified as interrupted and retried with a fresh key")
    func interruptedRetriesFresh() async throws {
        let keys = KeySequence()
        let service = ScriptedCreationService(
            onStart: { ordinal, _ in
                ordinal == 1
                    ? CreationFixtures.status("op-1", "running", sequence: 1)
                    : CreationFixtures.status("op-2", "succeeded", sequence: 1)
            },
            onFetch: { _, id in
                CreationFixtures.status(id, "interrupted", sequence: 2, errorCode: "interrupted")
            }
        )
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment(keys: keys))

        P1Fixtures.start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .failed })
        #expect(coordinator.failure?.kind == .interrupted)
        #expect(coordinator.failure?.isRetryable == true)
        #expect(coordinator.fraction < 1.0)
        #expect(coordinator.operationTerminal)

        P1Fixtures.start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })
        #expect(service.startKeys == ["key-1", "key-2"])
    }

    @Test("legacy cancelled code is treated as interrupted, not a generic failure")
    func legacyCancelled() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "interrupted", sequence: 1, errorCode: "cancelled") },
            onFetch: { _, id in CreationFixtures.status(id, "interrupted", sequence: 2) }
        )
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())
        P1Fixtures.start(coordinator, source: CreationFixtures.entry("source", cardID: "src"),
                         service: service, container: try CreationFixtures.container())
        #expect(await CreationFixtures.eventually { coordinator.phase == .failed })
        #expect(coordinator.failure?.kind == .interrupted)
    }

    @Test("C17: polling a never-finishing operation times out after 90 s as a retryable error")
    func pollingTimesOut() async throws {
        let recorder = SleepRecorder()
        let keys = KeySequence()
        let service = ScriptedCreationService(
            onStart: { ordinal, _ in
                ordinal == 1
                    ? CreationFixtures.status("op-1", "running", sequence: 1)
                    : CreationFixtures.status("op-2", "succeeded", sequence: 1)
            },
            onFetch: { ordinal, id in CreationFixtures.status(id, "running", sequence: ordinal + 1) }
        )
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment(
            interval: 30 * P1Fixtures.second, recorder: recorder, keys: keys
        ))

        P1Fixtures.start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .failed })
        #expect(coordinator.failure?.kind == .timedOut)
        #expect(coordinator.fraction < 1.0)
        #expect(coordinator.failure?.isRetryable == true)
        // Polls at t=30 s and t=60 s; the wake-up at t=90 s hits the deadline.
        #expect(service.fetchedOperationIds == ["op-1", "op-1"])
        #expect(recorder.durations.count == 3)

        // The stuck operation is abandoned: retry POSTs with a new key.
        P1Fixtures.start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })
        #expect(service.startKeys == ["key-1", "key-2"])
    }

    @Test("C17: an operation the server no longer knows (404) has its own message and a fresh retry")
    func operationNotFound() async throws {
        let service = ScriptedCreationService(
            onStart: { ordinal, _ in
                ordinal == 1
                    ? CreationFixtures.status("op-1", "running", sequence: 1)
                    : CreationFixtures.status("op-2", "succeeded", sequence: 1)
            },
            onFetch: { _, _ in throw KGError.httpError(statusCode: 404, detail: "operation not found") }
        )
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())

        P1Fixtures.start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .failed })
        #expect(coordinator.failure?.kind == .operationNotFound)
        #expect(coordinator.operationTerminal)

        P1Fixtures.start(coordinator, source: source, service: service, container: container)
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })
        #expect(service.startKeys.count == 2)
        #expect(service.startKeys[0] != service.startKeys[1])
    }

    @Test("C11: full success ends in succeeded with no warnings")
    func fullSuccess() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 1) },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 2) }
        )
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())
        P1Fixtures.start(coordinator, source: CreationFixtures.entry("source", cardID: "src"),
                         service: service, container: try CreationFixtures.container())
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })
        #expect(coordinator.warnings.isEmpty)
        #expect(coordinator.failure == nil)
    }

    @Test("#3115: an existing (.active) target enters the operation pipeline instead of being blocked")
    func existingTargetEntersPipeline() async throws {
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        let target = CreationFixtures.entry("target", cardID: "tgt")
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 1) },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 2) }
        )
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())
        P1Fixtures.start(coordinator, word: "target", source: source, allEntries: [source, target],
                         service: service, container: container)

        // Before #3115 the .active guard blocked here with addLink.target.linkable and no POST.
        #expect(coordinator.phase != .blocked)
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })
        #expect(service.startKeys.count == 1, "an existing word posts exactly one ensure-target operation")
    }

    @Test("C11: server warnings end in succeededWithWarnings naming each missing part")
    func serverWarnings() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in
                CreationFixtures.status("op-1", "succeeded_with_warnings", sequence: 1,
                                        warnings: ["enrichment_failed"])
            },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded_with_warnings", sequence: 2) }
        )
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())
        P1Fixtures.start(coordinator, source: CreationFixtures.entry("source", cardID: "src"),
                         service: service, container: try CreationFixtures.container())
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeededWithWarnings })
        #expect(coordinator.warnings == [.enrichmentIncomplete])
        #expect(coordinator.message == L10n.string("addLink.creation.warning.summary"))
    }

    @Test("C11: a failed local pull is a localSync warning, not a silent success")
    func localPullWarning() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 1) },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 2) }
        )
        service.onPull = { throw KGError.offline }
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())
        P1Fixtures.start(coordinator, source: CreationFixtures.entry("source", cardID: "src"),
                         service: service, container: try CreationFixtures.container())
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeededWithWarnings })
        #expect(coordinator.warnings == [.localSyncIncomplete])
    }

    @Test("C11: warning retry re-runs the local pull (and re-queues enrichment) without a new POST")
    func warningRetryResolves() async throws {
        let pulls = SleepRecorder()
        let service = ScriptedCreationService(
            onStart: { _, _ in
                CreationFixtures.status("op-1", "succeeded_with_warnings", sequence: 1,
                                        warnings: ["enrichment_failed"])
            },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded_with_warnings", sequence: 2) }
        )
        service.onPull = {
            pulls.record(1)
            if pulls.durations.count == 1 { throw KGError.offline }
            return KGPullOutcome(pipelinePending: false, inserted: 1)
        }
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())
        P1Fixtures.start(coordinator, source: CreationFixtures.entry("source", cardID: "src"),
                         service: service, container: try CreationFixtures.container())
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeededWithWarnings })
        #expect(coordinator.warnings == [.enrichmentIncomplete, .localSyncIncomplete])

        coordinator.retryWarnings()
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })
        #expect(coordinator.warnings.isEmpty)
        #expect(service.startKeys.count == 1)
        #expect(service.pullCount == 2)
        #expect(service.pipelineNotebookIds == ["nb"])
    }

    @Test("C11: a warning retry whose pull fails again keeps the warning visible")
    func warningRetryStillFailing() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 1) },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 2) }
        )
        service.onPull = { throw KGError.offline }
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())
        P1Fixtures.start(coordinator, source: CreationFixtures.entry("source", cardID: "src"),
                         service: service, container: try CreationFixtures.container())
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeededWithWarnings })

        coordinator.retryWarnings()
        #expect(await CreationFixtures.eventually { service.pullCount == 2 })
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeededWithWarnings })
        #expect(coordinator.warnings == [.localSyncIncomplete])
    }

    @Test("acknowledge returns a finished or failed attempt to idle (back to search / done)")
    func acknowledgeReturnsToIdle() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "failed", sequence: 1, errorCode: "operation_failed") },
            onFetch: { _, id in CreationFixtures.status(id, "failed", sequence: 2) }
        )
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())
        P1Fixtures.start(coordinator, source: CreationFixtures.entry("source", cardID: "src"),
                         service: service, container: try CreationFixtures.container())
        #expect(await CreationFixtures.eventually { coordinator.phase == .failed })

        coordinator.acknowledge()
        #expect(coordinator.phase == .idle)
        #expect(coordinator.failure == nil)
        #expect(coordinator.message == nil)
    }

    @Test("local guard blocks archived/source targets with the backend's own messages")
    func localGuardMessages() throws {
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        let archived = CreationFixtures.entry("frozen", cardID: "c-frozen")
        archived.isArchived = true
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("x", "running") },
            onFetch: { _, _ in CreationFixtures.status("x", "running") }
        )
        let coordinator = AddLinkCreationCoordinator(environment: P1Fixtures.environment())

        P1Fixtures.start(coordinator, word: "Frozen.", source: source, allEntries: [source, archived],
                         service: service, container: container)
        #expect(coordinator.phase == .blocked)
        #expect(coordinator.message == AddLinkCreationFailure(reason: "target_archived").message)

        P1Fixtures.start(coordinator, word: "source!", source: source, allEntries: [source, archived],
                         service: service, container: container)
        #expect(coordinator.message == AddLinkCreationFailure(reason: "target_is_source").message)
        #expect(service.startKeys.isEmpty)
    }
}

// MARK: - Target normalization and create entry (A7 + B10)

@Suite("Add Link target state")
@MainActor
struct AddLinkTargetStateTests {
    @Test("canonical word mirrors backend _clean_content + NFC lower")
    func canonicalWord() {
        let table: [(String, String)] = [
            ("apple.", "apple"),
            ("  Apple!? ", "apple"),
            ("run;", "run"),
            ("NASA", "nasa"),
            ("caf\u{0065}\u{0301}", "caf\u{00E9}"),
        ]
        for (input, expected) in table {
            #expect(AddLinkCreationCoordinator.canonicalWord(input) == expected, "\(input)")
        }
    }

    @Test("trailing punctuation resolves to the existing card, as the backend does")
    func punctuationMatchesExisting() {
        let source = CreationFixtures.entry("source", cardID: "src")
        let apple = CreationFixtures.entry("apple", cardID: "c-apple")
        #expect(
            AddLinkCreationCoordinator.localTargetState(query: "apple.", sourceEntry: source, allEntries: [source, apple])
                == .active
        )
    }

    @Test("diacritics are significant: café does not resolve to cafe")
    func diacriticsAreSignificant() {
        let source = CreationFixtures.entry("source", cardID: "src")
        let cafe = CreationFixtures.entry("cafe", cardID: "c-cafe")
        #expect(
            AddLinkCreationCoordinator.localTargetState(query: "café", sourceEntry: source, allEntries: [source, cafe])
                == .missing
        )
    }

    @Test("an existing target the source already links to is .linked, not .active")
    func linkedTarget() {
        let source = CreationFixtures.entry("source", cardID: "src")
        let target = CreationFixtures.entry("apple", cardID: "c-apple")
        source.graphLinksByKind = ["shares_usage": [
            KGCardLinkSummary(id: "l1", cardId: "c-apple", word: "apple", kind: "shares_usage",
                              label: "x", confidence: 1, reason: "r"),
        ]]
        #expect(
            AddLinkCreationCoordinator.localTargetState(query: "Apple", sourceEntry: source, allEntries: [source, target])
                == .linked
        )
    }

    @Test("create entry stays visible while partial-match candidates are listed")
    func createEntryWithCandidates() {
        let source = CreationFixtures.entry("source", cardID: "src")
        let running = CreationFixtures.entry("running", cardID: "c-running")
        let all = [source, running]
        func snapshot(_ query: String) -> AddLinkSearchSnapshot {
            AddLinkSearchSnapshot.make(query: query, sourceEntry: source, allEntries: all)
        }
        // The sheet offers "create" exactly when the snapshot's exact state is .missing.
        let partial = snapshot("run")
        #expect(!partial.candidates.isEmpty, "the partial match is listed")
        #expect(partial.exactTargetState == .missing, "and `run` can still be created")
        #expect(snapshot("running").exactTargetState == .active, "an exact existing word is not created again")
        #expect(snapshot("  ").exactTargetState == nil)
        #expect(snapshot("?!").exactTargetState == nil, "punctuation alone has no word to create")
        #expect(snapshot("source").exactTargetState == .source)
    }

    @Test("trailing punctuation is cleaned like the backend before searching")
    func candidatesIgnoreTrailingPunctuation() {
        let source = CreationFixtures.entry("source", cardID: "src")
        let run = CreationFixtures.entry("run", cardID: "c-run")
        let all = [source, run]
        for typed in ["run", "run.", "run?!", " run, "] {
            #expect(
                AddLinkCoordinator.localCandidates(query: typed, sourceEntry: source, allEntries: all).map(\.id)
                    == [run.id],
                "\(typed)"
            )
        }
        #expect(AddLinkCoordinator.localCandidates(query: "?!", sourceEntry: source, allEntries: all).isEmpty)
    }
}

// MARK: - Hub keeps warnings (C11, sheet already closed)

@Suite("Add Link creation hub P1", .serialized)
@MainActor
struct AddLinkCreationHubP1Tests {
    private struct Rig {
        let hub: AddLinkCreationHub
        let store: EphemeralPendingLinkCreationStore
        let projection: PendingLinkProjection
        let container: ModelContainer
        let source: VocabularyEntry
    }

    private func makeRig(records: [PendingLinkCreationRecord] = []) throws -> Rig {
        let store = EphemeralPendingLinkCreationStore(records: records)
        let projection = PendingLinkProjection()
        let hub = AddLinkCreationHub(
            store: store, projection: projection, environment: P1Fixtures.environment(), userIDProvider: { nil }
        )
        let container = try CreationFixtures.container()
        let source = CreationFixtures.entry("source", cardID: "src")
        container.mainContext.insert(source)
        try container.mainContext.save()
        return Rig(hub: hub, store: store, projection: projection, container: container, source: source)
    }

    private func startAndAbandon(_ rig: Rig, service: ScriptedCreationService) {
        let coordinator = rig.hub.makeCoordinator()
        coordinator.start(
            word: "luminous",
            sourceEntry: rig.source,
            allEntries: [rig.source],
            operationService: service,
            syncService: service,
            container: rig.container
        )
    }

    @Test("a warning outcome stays on the source card with its warnings until the user acts")
    func warningIsKeptOnCard() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in
                CreationFixtures.status("op-1", "succeeded_with_warnings", sequence: 1,
                                        warnings: ["enrichment_failed"])
            },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded_with_warnings", sequence: 2) }
        )
        let rig = try makeRig()
        startAndAbandon(rig, service: service)

        #expect(await CreationFixtures.eventually {
            rig.projection.links(forSourceCardID: "src").first?.pendingCreationState == .warning
        })
        let record = try #require(rig.store.records.first)
        #expect(record.state == .warning)
        #expect(record.warnings == ["enrichment_failed"])
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.hub.jobs.count == 1, "a warning must never disappear on its own")

        rig.hub.dismiss(jobKey: record.jobKey)
        #expect(rig.hub.jobs.isEmpty)
        #expect(rig.projection.links(forSourceCardID: "src").isEmpty)
    }

    @Test("retrying a warning from the card resolves it and the item leaves the card")
    func warningRetryFromCard() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 1) },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 2) }
        )
        let failOnce = SleepRecorder()
        service.onPull = {
            failOnce.record(1)
            if failOnce.durations.count == 1 { throw KGError.offline }
            return KGPullOutcome(pipelinePending: false, inserted: 1)
        }
        let rig = try makeRig()
        startAndAbandon(rig, service: service)
        #expect(await CreationFixtures.eventually { rig.store.records.first?.state == .warning })
        let jobKey = try #require(rig.hub.jobs.keys.first)

        #expect(rig.hub.retry(jobKey: jobKey))
        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
        #expect(service.startKeys.count == 1, "warning retry must not POST again")
    }

    @Test("dismissing a warning while its retry is in flight does not bring the job back")
    func dismissDuringWarningRetryStaysDismissed() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "succeeded", sequence: 1) },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded", sequence: 2) }
        )
        let gate = Gate()
        let pulls = SleepRecorder()
        service.onPull = {
            pulls.record(1)
            if pulls.durations.count > 1 { await gate.wait() }
            throw KGError.offline
        }
        let rig = try makeRig()
        startAndAbandon(rig, service: service)
        #expect(await CreationFixtures.eventually { rig.store.records.first?.state == .warning })
        let jobKey = try #require(rig.hub.jobs.keys.first)

        #expect(rig.hub.retry(jobKey: jobKey))
        #expect(await CreationFixtures.eventually { service.pullCount == 2 })
        #expect(rig.hub.job(forJobKey: jobKey)?.coordinator?.isRetryingWarnings == true)

        rig.hub.dismiss(jobKey: jobKey)
        #expect(rig.hub.jobs.isEmpty)

        // The retry now ends with a warning again; it must stay dismissed.
        await gate.release()
        try await Task.sleep(for: .milliseconds(80))
        #expect(rig.hub.jobs.isEmpty)
        #expect(rig.store.records.isEmpty)
        #expect(rig.projection.links(forSourceCardID: "src").isEmpty)
    }

    @Test("a restored warning record regains a working retry after resume")
    func restoredWarningRetry() async throws {
        let record = PendingLinkCreationRecord(
            jobKey: AddLinkCreationCoordinator.jobKey(sourceCardID: "src", word: "luminous"),
            word: "luminous", sourceCardID: "src", notebookId: "nb",
            idempotencyKey: "k", operationId: "op-1", operationTerminal: true,
            state: .warning, message: "m", createdAt: Date(timeIntervalSince1970: 1),
            failureReason: nil, warnings: ["local_projection_failed"]
        )
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("never", "failed") },
            onFetch: { _, id in CreationFixtures.status(id, "succeeded") }
        )
        let rig = try makeRig(records: [record])
        #expect(rig.projection.links(forSourceCardID: "src").first?.pendingCreationState == .warning)

        rig.hub.resume(services: AddLinkCreationServices(
            operationService: service, syncService: service, container: rig.container
        ))
        #expect(service.fetchedOperationIds.isEmpty, "resume must not re-poll a finished operation")
        #expect(rig.hub.retry(jobKey: record.jobKey))
        #expect(await CreationFixtures.eventually { rig.hub.jobs.isEmpty })
        #expect(service.pullCount == 1)
        #expect(service.startKeys.isEmpty)
    }

    @Test("a failed record keeps its failure reason so the card can classify it")
    func failedRecordKeepsReason() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "failed", sequence: 1, errorCode: "target_is_source") },
            onFetch: { _, id in CreationFixtures.status(id, "failed", sequence: 2) }
        )
        let rig = try makeRig()
        startAndAbandon(rig, service: service)
        #expect(await CreationFixtures.eventually { rig.store.records.first?.state == .failed })
        let record = try #require(rig.store.records.first)
        #expect(record.failureReason == "target_is_source")
        #expect(record.failure?.isRetryable == false)
    }

    @Test("going back to search from a failure removes the failed job (explicit user action)")
    func acknowledgeRemovesJob() async throws {
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "failed", sequence: 1, errorCode: "operation_failed") },
            onFetch: { _, id in CreationFixtures.status(id, "failed", sequence: 2) }
        )
        let rig = try makeRig()
        let coordinator = rig.hub.makeCoordinator()
        coordinator.start(word: "luminous", sourceEntry: rig.source, allEntries: [rig.source],
                          operationService: service, syncService: service, container: rig.container)
        #expect(await CreationFixtures.eventually { rig.hub.jobs.count == 1 && coordinator.phase == .failed })

        coordinator.acknowledge()
        #expect(rig.hub.jobs.isEmpty)
        #expect(rig.store.records.isEmpty)
    }

    @Test("records written before #2030 (no reason/warnings keys) still decode")
    func legacyRecordDecodes() throws {
        let json = """
        [{"jobKey":"src|lum","word":"lum","sourceCardID":"src","notebookId":"nb",
          "idempotencyKey":"k","operationTerminal":false,"state":"creating","createdAt":0}]
        """
        let records = try JSONDecoder().decode([PendingLinkCreationRecord].self, from: Data(json.utf8))
        #expect(records.first?.failureReason == nil)
        #expect(records.first?.warnings == nil)
    }
}

// MARK: - Existing-target path (B8 linking state, B9 messages)

@Suite("Add Link existing-target P1", .serialized)
@MainActor
struct AddLinkExistingTargetP1Tests {
    @Test("each action error has its own reason; only transient ones are retryable")
    func actionErrorTable() {
        let all: [AddLinkActionError] = [
            .missingSourceCard, .missingTargetCard, .duplicateLink, .missingLink,
            .invalidLink, .existingLinkRefreshFailed, .existingLinkFailed,
        ]
        #expect(Set(all.map(\.reason)).count == all.count)
        #expect(!AddLinkActionError.missingSourceCard.isRetryable)
        #expect(!AddLinkActionError.missingTargetCard.isRetryable)
        #expect(AddLinkActionError.existingLinkFailed.isRetryable)
        #expect(AddLinkActionError.existingLinkRefreshFailed.isRetryable)
        #expect(AddLinkActionError.existingLinkRefreshFailed.message != AddLinkActionError.existingLinkFailed.message)
        #expect(AddLinkActionError.missingSourceCard.message != AddLinkActionError.existingLinkFailed.message)
    }

    @Test("B8: the selected row is marked linking and a second tap does not resend")
    func doubleTapIsIgnored() async throws {
        let schema = Schema([VocabularyEntry.self, ReviewRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let source = CreationFixtures.entry("source", cardID: "source")
        let target = CreationFixtures.entry("target", cardID: "target")
        let other = CreationFixtures.entry("other", cardID: "other")
        context.insert(source)
        context.insert(target)
        context.insert(other)
        try context.save()

        let service = GatedGraphService()
        let coordinator = AddLinkCoordinator()
        coordinator.startLinkExisting(target: target, sourceEntry: source, using: service)
        #expect(coordinator.linkingTargetCardID == "target")
        coordinator.startLinkExisting(target: target, sourceEntry: source, using: service)
        coordinator.startLinkExisting(target: other, sourceEntry: source, using: service)
        #expect(coordinator.linkingTargetCardID == "target")

        #expect(await CreationFixtures.eventually { service.createCallCount == 1 })
        service.release()
        #expect(await CreationFixtures.eventually { coordinator.actionPhase == .succeeded })
        #expect(coordinator.linkingTargetCardID == nil)
        #expect(service.createCallCount == 1)
    }

    @Test("B9: a failed existing link can be retried from the banner")
    func retryLastAction() async throws {
        let schema = Schema([VocabularyEntry.self, ReviewRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let source = CreationFixtures.entry("source", cardID: "source")
        let target = CreationFixtures.entry("target", cardID: "target")
        context.insert(source)
        context.insert(target)
        try context.save()

        let service = GatedGraphService(failFirst: true)
        service.release()
        let coordinator = AddLinkCoordinator()
        coordinator.startLinkExisting(target: target, sourceEntry: source, using: service)
        #expect(await CreationFixtures.eventually { coordinator.actionPhase == .failed })
        #expect(coordinator.actionError == .existingLinkFailed)
        #expect(coordinator.canRetryLastAction)

        coordinator.retryLastAction()
        #expect(await CreationFixtures.eventually { coordinator.actionPhase == .succeeded })
        #expect(service.createCallCount == 2)
    }
}

@MainActor
private final class GatedGraphService: GraphServing {
    private(set) var createCallCount = 0
    private let failFirst: Bool
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func pullGraphLinks() async throws -> [KGGraphLink] { [] }

    func createManualLink(fromId: String, toId: String, notebookId: String) async throws -> KGGraphLink {
        createCallCount += 1
        let call = createCallCount
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        if failFirst && call == 1 { throw KGError.serverError("temporary") }
        return KGGraphLink(id: "link-\(call)", fromId: fromId, toId: toId, kind: "related", confidence: 1, reason: "r")
    }

    func deleteLink(linkId: String, notebookId: String) async throws {}
    func hideLink(linkId: String, notebookId: String) async throws {}
    func unhideLink(linkId: String, notebookId: String) async throws {}
}

// Issue #2047 (phase C): user-triggered Add Link outcomes surface as one top
// pill each, keyed so a repeated event replaces instead of stacking.
@Suite("AddLinkToastEvent")
@MainActor
struct AddLinkToastEventTests {
    @Test func actionFailureIsErrorPillWithStableKey() {
        let item = AddLinkToastEvent.actionFailed(.existingLinkFailed)
        #expect(item.style == .error)
        #expect(item.key == AddLinkToastEvent.actionFailedKey)
        #expect(item.message == AddLinkActionError.existingLinkFailed.message)
    }

    @Test func creationFailureIsErrorPillWithStableKey() {
        let item = AddLinkToastEvent.creationFailed(message: "failed copy")
        #expect(item.style == .error)
        #expect(item.key == AddLinkToastEvent.creationFailedKey)
        #expect(item.message == "failed copy")
    }

    @Test func creationWarningIsWarningPillWithStableKey() {
        let item = AddLinkToastEvent.creationWarning(message: "warning copy")
        #expect(item.style == .warning)
        #expect(item.key == AddLinkToastEvent.creationWarningKey)
    }

    @Test func blockedIsWarningPillWithStableKey() {
        let item = AddLinkToastEvent.blocked(message: "blocked copy")
        #expect(item.style == .warning)
        #expect(item.key == AddLinkToastEvent.blockedKey)
    }

    /// The same event twice collapses into the visible pill (no stacked duplicate).
    @Test func repeatedActionFailureReplacesInsteadOfStacking() {
        var queue = AppToastQueue()
        _ = queue.receive(AddLinkToastEvent.actionFailed(.existingLinkFailed))
        let outcome = queue.receive(AddLinkToastEvent.actionFailed(.existingLinkFailed))
        #expect(outcome == .replacedCurrent)
        #expect(queue.pending.isEmpty)
    }
}
