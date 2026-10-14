import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

// Issue #3811: the Add Link poller must back off between polls and must not
// treat a rate-limited (429) or transient poll failure as a terminal error.
// A 500 ms fixed cadence issues ~170 GETs for an 85 s operation and trips the
// shared `/api/operations` rate limit; the fix keeps the poll load bounded.

private enum PollingFixtures {
    static let second: UInt64 = 1_000_000_000

    static func environment(
        clock: ManualClock,
        recorder: SleepRecorder,
        keys: KeySequence = KeySequence()
    ) -> AddLinkCreationEnvironment {
        AddLinkCreationEnvironment(
            pollIntervalNanoseconds: 500_000_000,
            sleep: { nanoseconds in
                recorder.record(nanoseconds)
                clock.advance(nanoseconds)
                await Task.yield()
            },
            makeIdempotencyKey: { keys.next() },
            pollTimeoutNanoseconds: 90 * second,
            now: { clock.now }
        )
    }
}

@Suite("Add Link polling backoff and rate limiting (#3811)")
struct AddLinkCreationPollingTests {
    @Test("an 85 s operation is polled with a growing backoff, not every 500 ms")
    func backoffBoundsPollCount() async throws {
        let clock = ManualClock()
        let recorder = SleepRecorder()
        let startedAt = clock.now
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "running", sequence: 1) },
            onFetch: { _, id in
                let elapsed = clock.now - startedAt
                let done = elapsed >= 85 * PollingFixtures.second
                return CreationFixtures.status(id, done ? "succeeded" : "running", sequence: 2)
            }
        )
        let coordinator = AddLinkCreationCoordinator(
            environment: PollingFixtures.environment(clock: clock, recorder: recorder)
        )

        coordinator.start(
            word: "luminous",
            sourceEntry: CreationFixtures.entry("source", cardID: "src"),
            allEntries: [CreationFixtures.entry("source", cardID: "src")],
            operationService: service,
            syncService: service,
            container: try CreationFixtures.container()
        )
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })

        // Fixed 500 ms polling would issue ~170 fetches here; backoff stays near 15.
        #expect(service.fetchedOperationIds.count <= 40)
        let sleeps = recorder.durations
        #expect(sleeps.count >= 2)
        #expect(sleeps.first! < sleeps.last!)
        #expect(sleeps.first == 500_000_000)
        #expect(sleeps.allSatisfy { $0 <= 8 * PollingFixtures.second })
    }

    @Test("a 429 during polling is retried on the next tick instead of failing the job")
    func rateLimitedPollKeepsPolling() async throws {
        let clock = ManualClock()
        let recorder = SleepRecorder()
        let startedAt = clock.now
        let service = ScriptedCreationService(
            onStart: { _, _ in CreationFixtures.status("op-1", "running", sequence: 1) },
            onFetch: { ordinal, id in
                if ordinal == 2 {
                    throw KGError.httpError(statusCode: 429, detail: "rate limited")
                }
                let done = clock.now - startedAt >= 3 * PollingFixtures.second
                return CreationFixtures.status(id, done ? "succeeded" : "running", sequence: ordinal + 1)
            }
        )
        let coordinator = AddLinkCreationCoordinator(
            environment: PollingFixtures.environment(clock: clock, recorder: recorder)
        )

        coordinator.start(
            word: "luminous",
            sourceEntry: CreationFixtures.entry("source", cardID: "src"),
            allEntries: [CreationFixtures.entry("source", cardID: "src")],
            operationService: service,
            syncService: service,
            container: try CreationFixtures.container()
        )
        #expect(await CreationFixtures.eventually { coordinator.phase == .succeeded })
        #expect(coordinator.failure == nil)
        #expect(service.fetchedOperationIds.count >= 3)
    }
}
