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
    /// with what reason — an account switch triggered the SwiftData purge. Models the
    /// pending-wipe marker (#2717): a failed clear records its owner until a retry succeeds.
    /// Mirrors the real retry guard: the wipe only runs while nobody else is signed in.
    private final class RecordingCleaner: LocalDataClearing, @unchecked Sendable {
        private(set) var clearCount = 0
        private(set) var reasons: [String] = []
        private(set) var owners: [String] = []
        private(set) var retrySignedInUsers: [String?] = []
        private(set) var discardCount = 0
        var failClear = false
        var failRetry = false
        var pendingLocalWipeOwner: String?
        func clearLocalData(container: ModelContainer, reason: String, deletedAccountID: String?) async {
            clearCount += 1
            reasons.append(reason)
        }
        func clearLocalDataReportingFailure(
            container: ModelContainer,
            reason: String,
            owner: String,
            deletedAccountID: String?
        ) async -> Bool {
            await clearLocalData(container: container, reason: reason, deletedAccountID: deletedAccountID)
            owners.append(owner)
            pendingLocalWipeOwner = failClear ? owner : nil
            return !failClear
        }
        func retryPendingLocalWipe(container: ModelContainer, signedInUserId: String?) async -> Bool {
            retrySignedInUsers.append(signedInUserId)
            guard let owner = pendingLocalWipeOwner else { return true }
            guard signedInUserId == nil || signedInUserId == owner else { return false }
            guard !failRetry else { return false }
            pendingLocalWipeOwner = nil
            return true
        }
        func discardPendingLocalWipe() {
            discardCount += 1
            pendingLocalWipeOwner = nil
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

    /// #2717: a switch wipe that fails is retried right away, before B is admitted, so B normally
    /// never sees A's rows. The retry runs while A (the owner) is still the signed-in account.
    @Test func failed_account_switch_wipe_is_retried_before_admitting_next_account() async {
        let cleaner = RecordingCleaner()
        cleaner.failClear = true
        let manager = makeManager(priorUserId: "old-user", cleaner: cleaner)

        await manager.login(customToken: "new-user")

        #expect(cleaner.retrySignedInUsers == ["old-user"])
        #expect(cleaner.pendingLocalWipeOwner == nil)
        #expect(manager.userId == "new-user")
    }

    /// #2717: when the switch wipe still fails after the retry, account B is not admitted and A keeps
    /// its session. Admitting B would let B write into A's leftover rows, which a later retry then
    /// wipes together with B's unsynced data (the P1 data-loss path).
    @Test func failed_account_switch_refuses_next_account_and_keeps_previous_session() async {
        let cleaner = RecordingCleaner()
        cleaner.failClear = true
        cleaner.failRetry = true
        let manager = makeManager(priorUserId: "old-user", cleaner: cleaner)

        await manager.login(customToken: "new-user")

        #expect(manager.userId == "old-user")
        #expect(manager.isLoggedIn == true)
        #expect(manager.authError != nil)
        #expect(cleaner.discardCount == 1, "A's rows are intact, so the marker is dropped")
        #expect(cleaner.pendingLocalWipeOwner == nil)
        #expect(await manager.waitForLocalDataCleanupGate() == true)
    }

    /// #2717: a wipe left pending by a logout must finish before the next sign-in is admitted, and the
    /// retry runs while nobody is signed in, so it can only touch the owner's rows.
    @Test func pending_logout_wipe_completes_before_next_sign_in() async {
        let cleaner = RecordingCleaner()
        cleaner.pendingLocalWipeOwner = "user-a"
        let manager = makeManager(priorUserId: nil, cleaner: cleaner)

        await manager.login(customToken: "user-b")

        #expect(cleaner.retrySignedInUsers == [nil])
        #expect(cleaner.pendingLocalWipeOwner == nil)
        #expect(manager.userId == "user-b")
    }

    /// #2717: a pending logout wipe that still fails refuses the sign-in (fail closed). No account
    /// may become current, so nothing can be written into the owner's leftover rows.
    @Test func pending_logout_wipe_still_failing_refuses_sign_in() async {
        let cleaner = RecordingCleaner()
        cleaner.pendingLocalWipeOwner = "user-a"
        cleaner.failRetry = true
        let manager = makeManager(priorUserId: nil, cleaner: cleaner)

        await manager.login(customToken: "user-b")

        #expect(manager.userId == nil)
        #expect(manager.isLoggedIn == false)
        #expect(manager.authError != nil)
        #expect(cleaner.pendingLocalWipeOwner == "user-a", "the owner's marker survives for the next attempt")
    }

    /// #2717: the sync gate only reports the pending state. It never runs the wipe, because the
    /// gate can run under an account that did not own the leftover rows.
    @Test func sync_gate_reports_pending_wipe_without_wiping() async {
        let cleaner = RecordingCleaner()
        cleaner.pendingLocalWipeOwner = "user-a"
        let manager = makeManager(priorUserId: nil, cleaner: cleaner)

        #expect(await manager.waitForLocalDataCleanupGate() == false)
        #expect(cleaner.retrySignedInUsers.isEmpty)
        #expect(cleaner.pendingLocalWipeOwner == "user-a")
    }

    /// #2717: the direct `login(userId:token:)` entry is fail closed too while a wipe is pending.
    @Test func direct_login_is_refused_while_a_wipe_is_pending() {
        let cleaner = RecordingCleaner()
        cleaner.pendingLocalWipeOwner = "user-a"
        let manager = makeManager(priorUserId: nil, cleaner: cleaner)

        manager.login(userId: "user-b", token: "token-b")

        #expect(manager.userId == nil)
        #expect(manager.authError != nil)
    }

    /// #2717: while the previous account's wipe is still pending, the switch must keep the sync
    /// cursors. Clearing them would make B's first sync a seamless incremental over A's rows.
    @Test func failed_switch_wipe_keeps_sync_cursors_for_the_retry() async {
        let defaults = UserDefaults.standard
        let key = KGService.SyncKeys.incrementalBoundary
        defaults.set("cursor-of-old-user", forKey: key)
        defer { defaults.removeObject(forKey: key) }
        let cleaner = RecordingCleaner()
        cleaner.failClear = true
        cleaner.failRetry = true
        let manager = makeManager(priorUserId: "old-user", cleaner: cleaner)

        await manager.login(customToken: "new-user")

        #expect(defaults.string(forKey: key) == "cursor-of-old-user")
    }
}
