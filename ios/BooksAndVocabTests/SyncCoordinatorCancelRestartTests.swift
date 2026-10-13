import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// #3407：`cancelSync()` 立即把 phase 設為 `.failed`，因此新的 `startSync` 可在上一輪仍於 executor
/// 內 unwind 時開始。契約：兩輪必須序列化（新一輪等上一輪返回才 execute）；cancel 必須抵達
/// 目前這一輪的 task（不被上一輪的收尾清掉 handle）；被取消且尚未開始的排隊輪次不得 execute。
@Suite("SyncCoordinator cancel and restart")
@MainActor
struct SyncCoordinatorCancelRestartTests {

    /// 可控的 executor：每次 execute 記錄 start，阻塞到測試釋放，返回時記錄是否已被取消。
    @MainActor
    private final class GatedExecutor: VocabularySyncExecuting {
        private(set) var log: [String] = []
        private var runCount = 0
        private var blocked: [CheckedContinuation<Void, Never>] = []

        func execute(
            pendingEntries: [VocabularyEntry],
            modelContext: ModelContext,
            service: any VocabularySyncEngineServing,
            emit: @escaping (VocabularySyncEvent) -> Void
        ) async -> VocabularySyncResult {
            runCount += 1
            let run = runCount
            log.append("start\(run)")
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                blocked.append(continuation)
            }
            let cancelled = Task.isCancelled
            log.append(cancelled ? "end\(run)-cancelled" : "end\(run)")
            return VocabularySyncResult(terminalOutcome: cancelled ? .keepCancelled : .partial, durationMs: 0)
        }

        /// 釋放最早一個仍阻塞中的 execute（即最早啟動、尚未返回的那一輪）。
        func releaseOldest() {
            guard !blocked.isEmpty else { return }
            blocked.removeFirst().resume()
        }
    }

    private func makeStore() throws -> ModelContainer {
        try ModelContainer(
            for: VocabularyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func makeService() -> KGService {
        KGService(
            authSession: PullTestAuthSession(),
            sessionInvalidator: PullTestSessionInvalidator(),
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
    }

    /// 讓 MainActor 上已排程的 Task 有機會執行，用於斷言「某事沒有發生」。
    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    /// 等待條件成立（有上限，避免測試掛住）。
    private func waitUntil(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 1000 {
            await Task.yield()
            spins += 1
        }
    }

    @Test("cancel 後的新一輪必須等上一輪返回才 execute，且 cancel 新一輪能實際取消它")
    func restartWaitsForCancelledRunAndCancelReachesNewRun() async throws {
        let container = try makeStore()
        let context = ModelContext(container)
        let executor = GatedExecutor()
        let coordinator = SyncCoordinator(executor: executor)
        let service = makeService()

        coordinator.startSync(pendingEntries: [], modelContext: context, kgService: service)
        await waitUntil { executor.log == ["start1"] }

        coordinator.cancelSync()
        coordinator.startSync(pendingEntries: [], modelContext: context, kgService: service)
        await settle()
        #expect(executor.log == ["start1"], "run 2 must wait for the cancelled run 1 to return before it executes")

        executor.releaseOldest()
        await waitUntil { executor.log.count == 3 }
        #expect(executor.log == ["start1", "end1-cancelled", "start2"])

        coordinator.cancelSync()
        executor.releaseOldest()
        await waitUntil { executor.log.count == 4 }
        #expect(
            executor.log == ["start1", "end1-cancelled", "start2", "end2-cancelled"],
            "cancelSync during run 2 must reach run 2's task, not be lost to run 1's teardown"
        )
        #expect(coordinator.phase == .failed)
        #expect(coordinator.failureKind == .cancelled)
    }

    @Test("排隊中的新一輪若在上一輪返回前已被取消，不得 execute")
    func cancelledQueuedRunNeverExecutes() async throws {
        let container = try makeStore()
        let context = ModelContext(container)
        let executor = GatedExecutor()
        let coordinator = SyncCoordinator(executor: executor)
        let service = makeService()

        coordinator.startSync(pendingEntries: [], modelContext: context, kgService: service)
        await waitUntil { executor.log == ["start1"] }

        coordinator.cancelSync()
        coordinator.startSync(pendingEntries: [], modelContext: context, kgService: service)
        coordinator.cancelSync()

        executor.releaseOldest()
        await settle()
        #expect(executor.log == ["start1", "end1-cancelled"], "a queued run cancelled before it starts must not touch the outbox")
        #expect(coordinator.phase == .failed)
        #expect(coordinator.failureKind == .cancelled)
    }
}
