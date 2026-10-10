import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Pins the manual/debug login path (`login(customToken:)`, surfaced only in the
/// DEBUG Settings account section) to the same account-isolation contract as the
/// OAuth path (`applyAuthenticatedUser`): switching to a *different* user must clear
/// the previous user's local SwiftData before establishing the new session.
///
/// Root cause (PR #858 B3): `login(customToken:)` delegated straight to
/// `login(userId:token:)`, which resets UserDefaults sync boundaries + notebook
/// state but never calls `clearLocalData`. So a manual account switch left account
/// A's vocab/notebooks/review-records/books in the store, visible under account B —
/// a real isolation gap during dogfooding (the only path that exercises it).
@MainActor
struct AuthManagerAccountSwitchTests {

    private enum PreferenceEvent: Equatable {
        case activate(String?)
        case suspend
    }

    private final class RecordingPreferenceLifecycle: AccountPreferenceLifecycle {
        var events: [PreferenceEvent] = []

        func activate(accountID: String?) {
            events.append(.activate(accountID))
        }

        func suspend() {
            events.append(.suspend)
        }
    }

    private final class FixedSessionStore: AuthSessionStoring {
        let session: PersistedAuthSession
        init(userId: String?) {
            self.session = PersistedAuthSession(
                userId: userId,
                displayName: nil,
                userEmail: nil,
                avatarURL: nil,
                token: userId == nil ? nil : "tok.\(userId!)",
                keychainReadFailed: false
            )
        }
        func loadSession() -> PersistedAuthSession { session }
        func persistProfile(userId: String?, displayName: String?, userEmail: String?, avatarURL: URL?) {}
        func persistToken(_ token: String?) {}
        func clearSession() {}
    }

    /// Records every `clearLocalData` invocation so a test can assert whether — and
    /// with what reason — an account switch triggered the SwiftData purge.
    private final class RecordingCleaner: LocalDataClearing, @unchecked Sendable {
        @MainActor private(set) var clearCount = 0
        @MainActor private(set) var reasons: [String] = []
        func clearLocalData(container: ModelContainer, reason: String, deletedAccountID: String?) async {
            await MainActor.run {
                clearCount += 1
                reasons.append(reason)
            }
        }
    }

    private final class NoopVerifier: AuthVerifying {
        func verify(provider: String, token: String, email: String?) async throws -> AuthVerificationResult {
            throw CancellationError()
        }
    }

    @MainActor
    private static func makeContainer() -> ModelContainer {
        // In-memory; the cleaner is mocked and never touches it. Any @Model satisfies the requirement.
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try! ModelContainer(for: Notebook.self, configurations: config)
    }

    private func makeManager(
        priorUserId: String?,
        cleaner: RecordingCleaner,
        lifecycle: RecordingPreferenceLifecycle? = nil
    ) -> AuthManager {
        let manager = AuthManager(
            verifier: NoopVerifier(),
            localDataCleaner: cleaner,
            sessionStore: FixedSessionStore(userId: priorUserId),
            accountPreferenceLifecycle: lifecycle ?? RecordingPreferenceLifecycle()
        )
        manager.modelContainer = Self.makeContainer()
        return manager
    }

    @Test func coldStartActivatesPersistedAccountBeforeSettingsLoads() {
        let lifecycle = RecordingPreferenceLifecycle()
        _ = makeManager(
            priorUserId: "cold-start-account",
            cleaner: RecordingCleaner(),
            lifecycle: lifecycle
        )

        #expect(lifecycle.events == [.activate("cold-start-account")])
    }

    @Test func switchingAccountsSuspendsPreviousNamespaceBeforeActivatingNext() {
        let lifecycle = RecordingPreferenceLifecycle()
        let manager = makeManager(
            priorUserId: "account-a",
            cleaner: RecordingCleaner(),
            lifecycle: lifecycle
        )
        lifecycle.events.removeAll()

        manager.login(userId: "account-b", token: "token-b")

        #expect(lifecycle.events == [.suspend, .activate("account-b")])
    }

    @Test func emptyColdStartSuspendsAccountNamespace() {
        let lifecycle = RecordingPreferenceLifecycle()
        _ = makeManager(
            priorUserId: nil,
            cleaner: RecordingCleaner(),
            lifecycle: lifecycle
        )

        #expect(lifecycle.events == [.suspend])
    }

    @Test func manual_login_switching_account_clears_previous_user_data() async {
        let cleaner = RecordingCleaner()
        let manager = makeManager(priorUserId: "old-user", cleaner: cleaner)
        #expect(manager.userId == "old-user")

        await manager.login(customToken: "new-user")

        #expect(cleaner.clearCount == 1)
        #expect(cleaner.reasons == ["manual_login_account_switch"])
        #expect(manager.userId == "new-user")
        #expect(manager.isLoggedIn == true)
    }

    @Test func manual_login_same_account_does_not_clear() async {
        let cleaner = RecordingCleaner()
        let manager = makeManager(priorUserId: "same-user", cleaner: cleaner)

        await manager.login(customToken: "same-user")

        #expect(cleaner.clearCount == 0)
        #expect(manager.userId == "same-user")
        #expect(manager.isLoggedIn == true)
    }

    @Test func first_manual_login_with_no_prior_user_does_not_clear() async {
        let cleaner = RecordingCleaner()
        let manager = makeManager(priorUserId: nil, cleaner: cleaner)
        #expect(manager.userId == nil)

        await manager.login(customToken: "first-user")

        #expect(cleaner.clearCount == 0)
        #expect(manager.userId == "first-user")
        #expect(manager.isLoggedIn == true)
    }

    /// A whitespace-only token is a no-op login — it must NOT wipe the prior user's
    /// data (the switch detection requires a non-empty new id, matching
    /// `login(userId:token:)`'s own empty-guard).
    @Test func manual_login_with_blank_token_does_not_clear_or_switch() async {
        let cleaner = RecordingCleaner()
        let manager = makeManager(priorUserId: "old-user", cleaner: cleaner)

        await manager.login(customToken: "   ")

        #expect(cleaner.clearCount == 0)
        #expect(manager.userId == "old-user")
    }
}
