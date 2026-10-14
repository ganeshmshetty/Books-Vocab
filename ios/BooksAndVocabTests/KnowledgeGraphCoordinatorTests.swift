#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// #3818: `KnowledgeGraphView` restarts `loadGraphData` through `.task(id:)`, which
/// cancels the previous run. A superseded run's cancellation must not surface as
/// `errorMessage` nor reset `isLoading` while the latest run is still in flight.
@MainActor
@Suite("Knowledge graph coordinator load", .serialized)
struct KnowledgeGraphCoordinatorTests {

    @Test("a superseded run's cancellation after the latest run finished leaves no error")
    func supersededCancellationAfterLatestSuccessLeavesNoError() async {
        let service = ControlledGraphService()
        let coordinator = KnowledgeGraphCoordinator()

        let first = Task { await Self.load(coordinator, service) }
        await service.waitUntilEntered(1)
        let second = Task { await Self.load(coordinator, service) }
        await service.waitUntilEntered(2)

        service.succeed(call: 1, with: [Self.latestLink])
        await second.value
        service.fail(call: 0, with: CancellationError())
        await first.value

        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.isLoading == false)
        #expect(coordinator.links.map(\.id) == ["latest-link"])
    }

    @Test("a superseded run's cancellation does not clear loading while the latest run is in flight")
    func supersededCancellationKeepsLatestRunLoading() async {
        let service = ControlledGraphService()
        let coordinator = KnowledgeGraphCoordinator()

        let first = Task { await Self.load(coordinator, service) }
        await service.waitUntilEntered(1)
        let second = Task { await Self.load(coordinator, service) }
        await service.waitUntilEntered(2)

        service.fail(call: 0, with: CancellationError())
        await first.value

        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.isLoading == true)

        service.succeed(call: 1, with: [Self.latestLink])
        await second.value

        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.isLoading == false)
        #expect(coordinator.links.map(\.id) == ["latest-link"])
    }

    @Test("a single run cancelled by its own task leaves no error and stops loading")
    func singleCancellationLeavesNoError() async {
        let service = ControlledGraphService()
        let coordinator = KnowledgeGraphCoordinator()

        let run = Task { await Self.load(coordinator, service) }
        await service.waitUntilEntered(1)
        service.fail(call: 0, with: CancellationError())
        await run.value

        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.isLoading == false)
    }

    @Test("a genuine failure of the latest run still surfaces an error")
    func latestFailureStillSurfacesError() async {
        let service = ControlledGraphService()
        let coordinator = KnowledgeGraphCoordinator()

        let run = Task { await Self.load(coordinator, service) }
        await service.waitUntilEntered(1)
        service.fail(call: 0, with: KGError.offline)
        await run.value

        #expect(coordinator.errorMessage != nil)
        #expect(coordinator.isLoading == false)
    }

    // MARK: - Helpers

    private static let latestLink = KGGraphLink(
        id: "latest-link",
        fromId: "source",
        toId: "target",
        kind: "shares_usage",
        confidence: 1,
        reason: "latest"
    )

    private static func load(
        _ coordinator: KnowledgeGraphCoordinator,
        _ service: ControlledGraphService
    ) async {
        await coordinator.loadGraphData(
            authManager: LoggedInGraphAuth(),
            kgService: service,
            notebookIDs: ["nb"]
        )
    }
}

/// `pullGraphLinks(notebookId:)` suspends until the test resolves that call by index,
/// so the test controls the exact interleaving of superseded and latest runs.
@MainActor
private final class ControlledGraphService: GraphServing {
    private var continuations: [CheckedContinuation<[KGGraphLink], any Error>] = []
    private(set) var enteredCount = 0

    func waitUntilEntered(_ count: Int) async {
        for _ in 0..<10_000 where enteredCount < count {
            await Task.yield()
        }
        #expect(enteredCount >= count, "expected \(count) pull calls to start")
    }

    func succeed(call index: Int, with links: [KGGraphLink]) {
        continuations[index].resume(returning: links)
    }

    func fail(call index: Int, with error: any Error) {
        continuations[index].resume(throwing: error)
    }

    func pullGraphLinks(notebookId: String) async throws -> [KGGraphLink] {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            enteredCount += 1
        }
    }

    func pullGraphLinks() async throws -> [KGGraphLink] { [] }

    func createManualLink(fromId: String, toId: String, notebookId: String) async throws -> KGGraphLink {
        throw KGError.offline
    }

    func deleteLink(linkId: String, notebookId: String) async throws {}
    func hideLink(linkId: String, notebookId: String) async throws {}
    func unhideLink(linkId: String, notebookId: String) async throws {}
}

@MainActor
private final class LoggedInGraphAuth: AuthManaging {
    var isLoggedIn: Bool = true
    var userId: String? = "account-a"
    var token: String? = "test_token"
    var displayName: String?
    var userEmail: String?
    var avatarURL: URL?
    var authError: String?
    var isAuthenticating: Bool = false
    var isDemoMode: Bool = false

    func enterDemoMode(modelContainer: ModelContainer) {}
    func exitDemoMode(modelContainer: ModelContainer) {}
    func refreshSessionIfNeeded() {}
    func login(userId: String, token: String) {}
    func login(customToken: String) async {}
    func logout(modelContainer: ModelContainer?, reason: String) {}
    func logoutAfterAccountDeletion(modelContainer: ModelContainer?, deletedAccountID: String?) {}
    func loginWithGoogle(modelContainer: ModelContainer?) {}
    func loginWithApple(modelContainer: ModelContainer?) {}
}
#endif
