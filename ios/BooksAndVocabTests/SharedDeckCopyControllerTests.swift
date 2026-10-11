//
//  SharedDeckCopyControllerTests.swift
//  Books & Vocab Tests
//
//  Explore 複製 controller —— 四態轉移 + idempotencyKey 穩定性契約。
//  核心不變式：一個「複製意圖」及其所有 retry 共用同一把 key（server 冪等短路，
//  絕不併發不同-key 打出重複 notebook）；key 只在觀察到成功時清除，一個新複製才生新 key。
//

#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

@Suite(.serialized)
@MainActor
struct SharedDeckCopyControllerTests {

    private func response(_ id: String = "nb1", already: Bool = false) -> DeckCopyResponse {
        DeckCopyResponse(
            notebookId: id, notebookName: "GRE 3000", deckId: "d1",
            sourceVersion: 2, cardCount: 42, alreadyCopied: already
        )
    }

    /// Scriptable `DeckCopying` fake: records every key it received, replays a
    /// per-call scripted outcome (last entry repeats).
    private final class FakeDeckCopier: DeckCopying {
        private(set) var receivedKeys: [String] = []
        private(set) var receivedNames: [String?] = []
        private var results: [Result<DeckCopyResponse, Error>]
        private var callCount = 0
        init(_ results: [Result<DeckCopyResponse, Error>]) { self.results = results }
        func copyDeck(deckId: String, idempotencyKey: String, notebookName: String?) async throws -> DeckCopyResponse {
            receivedKeys.append(idempotencyKey)
            receivedNames.append(notebookName)
            let r = results[min(callCount, results.count - 1)]
            callCount += 1
            return try r.get()
        }
    }

    private func controller() -> SharedDeckCopyController {
        var n = 0
        return SharedDeckCopyController(makeKey: { n += 1; return "key-\(n)" })
    }

    // MARK: - Success

    @Test func success_transitions_to_success_and_clears_key() async {
        let c = controller()
        let fake = FakeDeckCopier([.success(response(already: false))])
        await c.copy(deckId: "d1", notebookName: "GRE 3000", using: fake)

        #expect(c.state == .success(.init(notebookId: "nb1", notebookName: "GRE 3000", cardCount: 42, alreadyCopied: false)))
        #expect(fake.receivedKeys == ["key-1"])
        #expect(fake.receivedNames == ["GRE 3000"])
        #expect(c.currentIdempotencyKey == nil, "intent fulfilled → key cleared so a later copy is a new intent")
    }

    @Test func success_invokes_afterCopy_with_response() async {
        let c = controller()
        let fake = FakeDeckCopier([.success(response("nbX"))])
        var seen: DeckCopyResponse?
        await c.copy(deckId: "d1", notebookName: nil, using: fake) { resp in seen = resp }
        #expect(seen?.notebookId == "nbX")
    }

    // MARK: - Failure keeps the key for retry

    @Test func failure_transitions_and_retains_key() async {
        let c = controller()
        // Mirror the real `KGService.copyDeck` path: transport failures arrive
        // wrapped as `KGError.networkError`, never as a raw `URLError` (#2108).
        let fake = FakeDeckCopier([.failure(KGError.networkError(underlying: URLError(.timedOut)))])
        await c.copy(deckId: "d1", notebookName: "GRE 3000", using: fake)

        #expect(c.state == .failure(L10n.string("explore.copy.error.offline")))
        #expect(c.currentIdempotencyKey == "key-1", "a failed attempt keeps its key so retry reuses it")
    }

    // MARK: - Cancellation is a lifecycle outcome, not a copy failure

    @Test func cancellation_returns_to_idle_without_failure_observability() async {
        let c = controller()
        let deckId = "cancelled-deck-\(UUID().uuidString)"
        let fake = FakeDeckCopier([.failure(CancellationError())])
        let failureBreadcrumbsBefore = AppDiagnosticContext.shared.snapshot().observations
            .filter { $0 == "deck copy failed" }
            .count

        await c.copy(deckId: deckId, notebookName: "GRE 3000", using: fake)

        #expect(c.state == .idle, "cancellation is a lifecycle outcome, not a failure UI")
        #expect(c.currentIdempotencyKey == "key-1", "cancellation keeps the intent key for retry")
        #expect(fake.receivedKeys == ["key-1"])

        let observations = AppObservationStore.shared.preview(limit: 200).entries
        #expect(!observations.contains {
            $0.message.contains("event=deck_copy_failed deck_id=\(deckId)")
        })
        let failureBreadcrumbsAfter = AppDiagnosticContext.shared.snapshot().observations
            .filter { $0 == "deck copy failed" }
            .count
        #expect(failureBreadcrumbsAfter == failureBreadcrumbsBefore)
    }

    @Test func cancellation_retry_reuses_key_and_success_clears_it() async {
        let c = controller()
        let fake = FakeDeckCopier([
            .failure(CancellationError()),
            .success(response())
        ])

        await c.copy(deckId: "d1", notebookName: "GRE 3000", using: fake)
        await c.copy(deckId: "d1", notebookName: "GRE 3000", using: fake)

        #expect(fake.receivedKeys == ["key-1", "key-1"])
        if case .success = c.state {} else { Issue.record("expected .success after cancellation retry, got \(c.state)") }
        #expect(c.currentIdempotencyKey == nil)
    }

    // MARK: - Retry reuses the SAME key (the core anti-duplicate invariant)

    @Test func retry_reuses_same_idempotency_key() async {
        let c = controller()
        // First call fails, second (retry) succeeds.
        let fake = FakeDeckCopier([
            .failure(KGError.networkError(underlying: URLError(.networkConnectionLost))),
            .success(response())
        ])
        await c.copy(deckId: "d1", notebookName: "GRE 3000", using: fake)   // fails, key-1
        await c.copy(deckId: "d1", notebookName: "GRE 3000", using: fake)   // retry, MUST reuse key-1

        #expect(fake.receivedKeys == ["key-1", "key-1"], "retry must reuse the same key so the server short-circuits, never minting a duplicate")
        if case .success = c.state {} else { Issue.record("expected .success after retry, got \(c.state)") }
        #expect(c.currentIdempotencyKey == nil)
    }

    // MARK: - A fresh copy AFTER success is a NEW intent → new key

    @Test func copy_after_success_uses_fresh_key() async {
        let c = controller()
        let fake = FakeDeckCopier([.success(response())])
        await c.copy(deckId: "d1", notebookName: "GRE 3000", using: fake)   // key-1, success → cleared
        await c.copy(deckId: "d1", notebookName: "GRE 3000", using: fake)   // NEW intent → key-2

        #expect(fake.receivedKeys == ["key-1", "key-2"], "a new copy after success is a new intent and must mint a fresh key")
    }

    // MARK: - alreadyCopied surfaces on the outcome (idempotent replay recovery)

    @Test func alreadyCopied_response_surfaces_on_outcome() async {
        let c = controller()
        let fake = FakeDeckCopier([.success(response(already: true))])
        await c.copy(deckId: "d1", notebookName: nil, using: fake)
        if case .success(let outcome) = c.state {
            #expect(outcome.alreadyCopied == true)
        } else {
            Issue.record("expected .success, got \(c.state)")
        }
    }

    // MARK: - Error classification (#2108)

    /// Errors as `KGService` actually throws them: `currentAuthToken()` raises
    /// `.offline` when the connectivity gate is closed, and the request layer
    /// wraps every transport `URLError` in `.networkError(underlying:)`.
    enum ErrorCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case kgOffline
        case wrappedTimedOut
        case wrappedNotConnected
        case wrappedConnectionLost
        case wrappedCannotConnect
        case rawTimedOut
        case wrappedBadServerResponse
        case unauthorized
        case httpServerError

        var testDescription: String { rawValue }

        var error: Error {
            switch self {
            case .kgOffline: return KGError.offline
            case .wrappedTimedOut: return KGError.networkError(underlying: URLError(.timedOut))
            case .wrappedNotConnected: return KGError.networkError(underlying: URLError(.notConnectedToInternet))
            case .wrappedConnectionLost: return KGError.networkError(underlying: URLError(.networkConnectionLost))
            case .wrappedCannotConnect: return KGError.networkError(underlying: URLError(.cannotConnectToHost))
            case .rawTimedOut: return URLError(.timedOut)
            case .wrappedBadServerResponse: return KGError.networkError(underlying: URLError(.badServerResponse))
            case .unauthorized: return KGError.unauthorized
            case .httpServerError: return KGError.httpError(statusCode: 500, detail: "boom")
            }
        }

        var expectedReason: String {
            switch self {
            case .kgOffline, .wrappedTimedOut, .wrappedNotConnected,
                 .wrappedConnectionLost, .wrappedCannotConnect, .rawTimedOut:
                return "offline"
            case .unauthorized:
                return "unauthorized"
            case .wrappedBadServerResponse, .httpServerError:
                return "generic"
            }
        }

        var expectedMessageKey: String { "explore.copy.error.\(expectedReason)" }
    }

    @Test(arguments: ErrorCase.allCases)
    func failureReason_classifies_service_errors(_ errorCase: ErrorCase) {
        #expect(SharedDeckCopyController.failureReason(for: errorCase.error) == errorCase.expectedReason)
    }

    @Test(arguments: ErrorCase.allCases)
    func message_maps_service_errors(_ errorCase: ErrorCase) {
        #expect(SharedDeckCopyController.message(for: errorCase.error) == L10n.string(errorCase.expectedMessageKey))
    }

    // MARK: - Notebook name travels with the key (#2748)

    @Test func failed_copy_remembers_notebook_name_for_retry() async {
        let c = controller()
        let fake = FakeDeckCopier([.failure(URLError(.timedOut)), .success(response())])
        await c.copy(deckId: "d1", notebookName: "My Name", using: fake)
        #expect(c.lastNotebookName == "My Name")
        await c.copy(deckId: "d1", notebookName: c.lastNotebookName, using: fake)
        #expect(fake.receivedNames == ["My Name", "My Name"])
        #expect(c.lastNotebookName == nil, "intent fulfilled → name cleared with the key")
    }

    // MARK: - Registry (#2748: controller survives view pop/reopen)
    // View wiring (`State(initialValue: registry.controller(for:))` + `track` in
    // performCopy) is covered by review only; these tests pin the registry contract.

    @Test func registry_returns_same_controller_for_same_deck_while_key_held() async {
        let registry = SharedDeckCopyRegistry()
        let c1 = registry.controller(for: "d1", owner: "A")
        registry.track(c1, for: "d1")
        let fake = FakeDeckCopier([.failure(URLError(.timedOut))])
        await c1.copy(deckId: "d1", notebookName: nil, using: fake)
        let key = c1.currentIdempotencyKey
        #expect(key != nil)
        let c2 = registry.controller(for: "d1", owner: "A")
        #expect(c2 === c1, "reopen after failure must reuse the controller (and its idempotency key)")
        #expect(c2.currentIdempotencyKey == key)
        #expect(registry.controller(for: "d2", owner: "A") !== c1)
    }

    @Test func registry_returns_same_controller_while_inflight() async {
        let registry = SharedDeckCopyRegistry()
        let c1 = registry.controller(for: "d1", owner: "A")
        registry.track(c1, for: "d1")
        let gate = GatedCopier()
        let task = Task { await c1.copy(deckId: "d1", notebookName: nil, using: gate) }
        while !gate.hasStarted { await Task.yield() }
        #expect(registry.controller(for: "d1", owner: "A") === c1)
        gate.release(response())
        await task.value
    }

    @Test func registry_hands_out_fresh_controller_after_success() async {
        let registry = SharedDeckCopyRegistry()
        let c1 = registry.controller(for: "d1", owner: "A")
        registry.track(c1, for: "d1")
        await c1.copy(deckId: "d1", notebookName: nil, using: FakeDeckCopier([.success(response())]))
        let c2 = registry.controller(for: "d1", owner: "A")
        #expect(c2 !== c1)
        #expect(c2.state == .idle)
        #expect(registry.trackedDeckCount == 0, "succeeded entries are pruned on lookup")
    }

    @Test func registry_does_not_retain_controllers_that_never_started_a_copy() {
        let registry = SharedDeckCopyRegistry()
        _ = registry.controller(for: "d1", owner: "A")
        _ = registry.controller(for: "d2", owner: "A")
        #expect(registry.trackedDeckCount == 0)
    }

    /// 失敗卡與待確認的 notebook 名稱屬於帳號 A；帳號 B 看同一 deck 時不得看見，
    /// A 回來時仍接得回自己的意圖（key 不被別人的查詢清掉）。
    @Test func registry_does_not_hand_one_accounts_pending_copy_to_another() async {
        let registry = SharedDeckCopyRegistry()
        let a = registry.controller(for: "d1", owner: "A")
        registry.track(a, for: "d1")
        await a.copy(deckId: "d1", notebookName: "A private name", using: FakeDeckCopier([.failure(URLError(.timedOut))]))
        let b = registry.controller(for: "d1", owner: "B")
        #expect(b !== a)
        #expect(b.state == .idle)
        #expect(b.lastNotebookName == nil)
        #expect(registry.controller(for: "d1", owner: "A") === a, "A's own pending intent survives B's lookup")
    }

    /// `@MainActor` (nested types don't inherit the suite's isolation) so
    /// `continuation` is never touched off-main; `hasStarted` flips only once the
    /// continuation exists, so `release` cannot race ahead of it.
    @MainActor
    private final class GatedCopier: DeckCopying {
        private(set) var hasStarted = false
        private var continuation: CheckedContinuation<DeckCopyResponse, Error>?
        func copyDeck(deckId: String, idempotencyKey: String, notebookName: String?) async throws -> DeckCopyResponse {
            try await withCheckedThrowingContinuation {
                continuation = $0
                hasStarted = true
            }
        }
        func release(_ r: DeckCopyResponse) { continuation?.resume(returning: r) }
    }
}
#endif
