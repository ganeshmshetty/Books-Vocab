import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// #3417: a 401 on `DELETE api/user/account` must not tear the session down before
/// `SettingsCoordinator.deleteAccount` can finish the account-scoped erase. The caller already
/// captured the account id, so the erase reaches `logoutAfterAccountDeletion` and purges that
/// account's namespaced preferences. A generic http_401 logout would skip that purge.
@MainActor
struct AccountDeletion401RegressionTests {
    @MainActor
    private final class DeletingAuthManager: AuthManaging, AuthSessionProviding {
        private(set) var userId: String?
        private(set) var deletedAccountIDs: [String?] = []

        init(userId: String) {
            self.userId = userId
        }

        var isLoggedIn: Bool { userId != nil }
        var token: String? { userId.map { "tok.\($0)" } }
        var displayName: String? { nil }
        var userEmail: String? { nil }
        var avatarURL: URL? { nil }
        var authError: String? { nil }
        var isAuthenticating: Bool { false }
        var isDemoMode: Bool { false }

        func enterDemoMode(modelContainer: ModelContainer) {}
        func exitDemoMode(modelContainer: ModelContainer) {}
        func refreshSessionIfNeeded() {}
        func login(userId: String, token: String) { self.userId = userId }
        func login(customToken: String) async {}
        func logout(modelContainer: ModelContainer?, reason: String) { userId = nil }
        func logoutAfterAccountDeletion(modelContainer: ModelContainer?, deletedAccountID: String?) {
            deletedAccountIDs.append(deletedAccountID)
            userId = nil
        }
        func loginWithGoogle(modelContainer: ModelContainer?) {}
        func loginWithApple(modelContainer: ModelContainer?) {}
    }

    @MainActor
    private final class RecordingSessionInvalidator: SessionInvalidating {
        private(set) var logoutReasons: [String] = []
        func logout(modelContainer: ModelContainer?, reason: String) { logoutReasons.append(reason) }
        func waitForPendingLocalDataCleanup() async {}
    }

    private final class FixedStatusTransport: KGHTTPTransport, @unchecked Sendable {
        let statusCode: Int
        init(statusCode: Int) { self.statusCode = statusCode }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://kg.test")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    }

    private static func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: Notebook.self, configurations: config)
    }

    private static func makeService(
        auth: DeletingAuthManager,
        invalidator: RecordingSessionInvalidator,
        statusCode: Int
    ) -> KGService {
        KGService(
            authSession: auth,
            sessionInvalidator: invalidator,
            transport: FixedStatusTransport(statusCode: statusCode),
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
    }

    @Test func unauthorizedAccountDeletionCompletesEraseWithTheCapturedAccount() async throws {
        let auth = DeletingAuthManager(userId: "account-b")
        let invalidator = RecordingSessionInvalidator()
        let service = Self.makeService(auth: auth, invalidator: invalidator, statusCode: 401)
        let coordinator = SettingsCoordinator(translationLifecycle: NoopAccountPreferenceLifecycle())
        let context = ModelContext(try Self.makeContainer())

        await coordinator.deleteAccount(authManager: auth, kgService: service, modelContext: context)

        #expect(auth.deletedAccountIDs == ["account-b"])
        #expect(invalidator.logoutReasons.isEmpty)
        #expect(service.sessionExpiredReason == nil)
        #expect(coordinator.deleteAccountError == nil)
    }

    /// Control: a non-401 failure still surfaces as a delete error and never reaches the erase.
    @Test func serverFailureOnAccountDeletionStillReportsAndDoesNotErase() async throws {
        let auth = DeletingAuthManager(userId: "account-b")
        let invalidator = RecordingSessionInvalidator()
        let service = Self.makeService(auth: auth, invalidator: invalidator, statusCode: 500)
        let coordinator = SettingsCoordinator(translationLifecycle: NoopAccountPreferenceLifecycle())
        let context = ModelContext(try Self.makeContainer())

        await coordinator.deleteAccount(authManager: auth, kgService: service, modelContext: context)

        #expect(auth.deletedAccountIDs.isEmpty)
        #expect(auth.isLoggedIn)
        #expect(coordinator.deleteAccountError != nil)
    }
}
