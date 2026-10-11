import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Pins `AuthManager`'s handling of a *transient* Keychain read failure.
///
/// Root cause (PR #529 follow-up): on a cold-boot device that has not been unlocked,
/// `loadSession()` returns a `PersistedAuthSession` with `token == nil` even though the
/// token is physically present — the read failed with `errSecInteractionNotAllowed`.
/// `AuthManager.init` then evaluated `isLoggedIn = token != nil` → `false`, silently
/// logging out an already-authenticated user.
///
/// The fix: `loadSession()` now also carries `keychainReadFailed`. When that is true the
/// session state is *unknown*, not logged-out — `AuthManager` keeps the user logged in if
/// there is profile evidence of a prior session, and re-reads when the device unlocks.
@MainActor
struct AuthManagerKeychainTests {

    /// A scripted `AuthSessionStoring` whose `loadSession()` return value the test controls,
    /// including the per-call sequence so a "first read fails, second succeeds" cold-boot
    /// → unlock transition can be reproduced.
    private final class FakeSessionStore: AuthSessionStoring {
        /// FIFO of sessions handed out by successive `loadSession()` calls. The last entry
        /// is reused once exhausted, so a single-element queue yields a stable result.
        var sessionQueue: [PersistedAuthSession]
        private(set) var loadCount = 0
        private(set) var clearCount = 0

        init(_ sessions: [PersistedAuthSession]) {
            precondition(!sessions.isEmpty)
            self.sessionQueue = sessions
        }

        func loadSession() -> PersistedAuthSession {
            loadCount += 1
            if sessionQueue.count > 1 {
                return sessionQueue.removeFirst()
            }
            return sessionQueue[0]
        }
        func persistProfile(userId: String?, displayName: String?, userEmail: String?, avatarURL: URL?) {}
        func persistToken(_ token: String?) {}
        func clearSession() { clearCount += 1 }
    }

    private func session(
        userId: String? = nil,
        token: String? = nil,
        keychainReadFailed: Bool = false
    ) -> PersistedAuthSession {
        PersistedAuthSession(
            userId: userId,
            displayName: nil,
            userEmail: nil,
            avatarURL: nil,
            token: token,
            keychainReadFailed: keychainReadFailed
        )
    }

    private func makeManager(_ store: FakeSessionStore) -> AuthManager {
        AuthManager(
            verifier: NoopVerifier(),
            localDataCleaner: NoopCleaner(),
            sessionStore: store,
            accountPreferenceLifecycle: NoopAccountPreferenceLifecycle()
        )
    }

    private final class NoopVerifier: AuthVerifying {
        func verify(provider: String, token: String, email: String?) async throws -> AuthVerificationResult {
            throw CancellationError()
        }
    }
    private final class NoopCleaner: LocalDataClearing {
        func clearLocalData(container: ModelContainer, reason: String, deletedAccountID: String?) async {}
    }

    /// Records the account ID that `logout` hands to the cleaner, so the
    /// delete-account wiring (#2434) can be asserted without touching SwiftData.
    private final class RecordingCleaner: LocalDataClearing, @unchecked Sendable {
        @MainActor private(set) var deletedAccountIDs: [String?] = []

        func clearLocalData(container: ModelContainer, reason: String, deletedAccountID: String?) async {
            await MainActor.run { deletedAccountIDs.append(deletedAccountID) }
        }
    }

    /// A cleaner that relinquishes the MainActor mid-clear (mirroring the real service's hop to
    /// `BackgroundSyncActor`) and runs an injected hook during that suspension window. The hook
    /// reproduces the logout-vs-login TOCTOU race: an interleaved `login()` lands while
    /// `logout()` is awaiting cleanup. Runs exactly once; `didRun` lets the test detect the
    /// window has been traversed.
    /// Nonisolated to satisfy the nonisolated `LocalDataClearing` requirement (mirrors
    /// `NoopCleaner`); the actual hook + flag mutation hop onto the MainActor explicitly.
    private final class RaceCleaner: LocalDataClearing, @unchecked Sendable {
        private let onSuspend: @MainActor () -> Void
        @MainActor private(set) var didRun = false

        init(onSuspend: @escaping @MainActor () -> Void) {
            self.onSuspend = onSuspend
        }

        func clearLocalData(container: ModelContainer, reason: String, deletedAccountID: String?) async {
            // Real suspension that yields the MainActor — same window production opens when it
            // awaits the background actor.
            await Task.yield()
            await MainActor.run {
                if !didRun {
                    didRun = true
                    onSuspend()  // interleaved login() lands here, mid-logout
                }
            }
        }
    }

    @MainActor
    private static func makeContainer() -> ModelContainer {
        // In-memory container; schema content is irrelevant — the cleaner is mocked and never
        // touches it. Any @Model satisfies the container requirement.
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try! ModelContainer(for: Notebook.self, configurations: config)
    }

    // MARK: - (d) logout must not clobber a session that lands during its async cleanup

    /// Race (the bug): token expiry fires `logout()`, whose unstructured `Task` awaits
    /// `clearLocalData`, relinquishing the MainActor. In that window the user re-authenticates
    /// — `login()` writes a fresh session. When the logout Task resumes, its `defer` must NOT
    /// wipe the just-written session back to nil + clear the keychain. Pre-fix it did,
    /// unconditionally → user kicked out immediately after logging back in (red here).
    @Test func logout_does_not_clobber_session_written_during_cleanup() async {
        let store = FakeSessionStore([session(userId: "old-user", token: "old.jwt", keychainReadFailed: false)])
        // `weakRacing` lets the suspension hook re-login on the very manager under test, landing
        // a fresh session mid-logout.
        var weakRacing: AuthManager?
        let raceCleaner = RaceCleaner(onSuspend: {
            weakRacing?.login(userId: "new-user", token: "new.jwt")
        })
        let racing = AuthManager(
            verifier: NoopVerifier(),
            localDataCleaner: raceCleaner,
            sessionStore: store,
            accountPreferenceLifecycle: NoopAccountPreferenceLifecycle()
        )
        racing.modelContainer = Self.makeContainer()
        weakRacing = racing
        #expect(racing.isLoggedIn == true)

        racing.logout(reason: "token_expired")

        // Await the detached logout Task (incl. its post-cleanup stale-guard `defer`) to
        // completion instead of guessing with a fixed yield margin.
        await racing.waitForPendingLocalDataCleanup()
        #expect(raceCleaner.didRun)

        // The fresh session survives: user stays logged in with the NEW credentials and the
        // keychain is not cleared out from under them.
        #expect(racing.isLoggedIn == true)
        #expect(racing.userId == "new-user")
        #expect(racing.token == "new.jwt")
    }

    // MARK: - (e) delete_account hands the deleted account to the cleaner (#2434)

    /// Production wiring: SettingsCoordinator logs out with `deleteAccountReason`, and only that
    /// reason may scope the cleaner's account-preference purge to the account being deleted.
    /// Any other logout must pass nil so other accounts' preferences are never touched.
    @Test func deleteAccountLogoutHandsDeletedAccountIDToCleaner() async {
        #expect(LocalDataCleanerService.deleteAccountReason == "delete_account")
        let cleaner = RecordingCleaner()
        let store = FakeSessionStore([session(userId: "account-a", token: "a.jwt", keychainReadFailed: false)])
        let manager = AuthManager(
            verifier: NoopVerifier(),
            localDataCleaner: cleaner,
            sessionStore: store,
            accountPreferenceLifecycle: NoopAccountPreferenceLifecycle()
        )
        manager.modelContainer = Self.makeContainer()
        manager.logout(reason: LocalDataCleanerService.deleteAccountReason)
        await manager.waitForPendingLocalDataCleanup()
        #expect(cleaner.deletedAccountIDs == ["account-a"])

        let logoutCleaner = RecordingCleaner()
        let logoutManager = AuthManager(
            verifier: NoopVerifier(),
            localDataCleaner: logoutCleaner,
            sessionStore: FakeSessionStore([session(userId: "account-a", token: "a.jwt", keychainReadFailed: false)]),
            accountPreferenceLifecycle: NoopAccountPreferenceLifecycle()
        )
        logoutManager.modelContainer = Self.makeContainer()
        logoutManager.logout(reason: "user_logout")
        await logoutManager.waitForPendingLocalDataCleanup()
        #expect(logoutCleaner.deletedAccountIDs == [nil])
    }

    /// #2556: SettingsCoordinator captures the account BEFORE awaiting `DELETE /api/user/account`.
    /// A concurrent in-flight request can get 401 first, and its teardown nils `userId` before the
    /// delete logout runs. The delete logout must purge the captured account, not re-read `userId`.
    /// Pre-fix the delete logout re-read the cleared `userId` and passed nil, skipping the purge.
    @Test func deleteAccountPurgeTargetSurvivesConcurrent401Teardown() async {
        let cleaner = RecordingCleaner()
        let store = FakeSessionStore([session(userId: "account-a", token: "a.jwt", keychainReadFailed: false)])
        let manager = AuthManager(
            verifier: NoopVerifier(),
            localDataCleaner: cleaner,
            sessionStore: store,
            accountPreferenceLifecycle: NoopAccountPreferenceLifecycle()
        )
        manager.modelContainer = Self.makeContainer()

        let capturedAccountID = manager.userId
        manager.logout(reason: "token_expired")
        await manager.waitForPendingLocalDataCleanup()
        #expect(manager.userId == nil)

        manager.logoutAfterAccountDeletion(
            modelContainer: manager.modelContainer,
            deletedAccountID: capturedAccountID
        )
        await manager.waitForPendingLocalDataCleanup()
        #expect(cleaner.deletedAccountIDs == [nil, "account-a"])
    }

    // MARK: - (a) transient read failure must NOT log the user out

    @Test func transient_read_failure_with_prior_profile_keeps_user_logged_in() {
        // Cold-boot: token unreadable, but a persisted userId proves a prior session existed.
        let store = FakeSessionStore([session(userId: "u-1", token: nil, keychainReadFailed: true)])
        let manager = makeManager(store)
        // The user must NOT be shown as logged out — state is unknown, pending re-read.
        #expect(manager.isLoggedIn == true)
        #expect(manager.keychainReadPending == true)
    }

    // MARK: - (b) genuine logged-out state still routes to logout

    @Test func itemNotFound_with_no_profile_is_a_normal_logged_out_launch() {
        // No token, no profile, no read failure — a legitimately signed-out user.
        let store = FakeSessionStore([session(userId: nil, token: nil, keychainReadFailed: false)])
        let manager = makeManager(store)
        #expect(manager.isLoggedIn == false)
        #expect(manager.keychainReadPending == false)
    }

    @Test func valid_token_is_logged_in_with_no_pending_reread() {
        let store = FakeSessionStore([session(userId: "u-1", token: "jwt.alive", keychainReadFailed: false)])
        let manager = makeManager(store)
        #expect(manager.isLoggedIn == true)
        #expect(manager.keychainReadPending == false)
    }

    /// Defensive: a read failure with *no* profile evidence (never logged in on this device)
    /// must not fabricate a logged-in state — there is nothing to restore.
    @Test func transient_read_failure_without_profile_does_not_fake_login() {
        let store = FakeSessionStore([session(userId: nil, token: nil, keychainReadFailed: true)])
        let manager = makeManager(store)
        #expect(manager.isLoggedIn == false)
        // Still pending: a re-read after unlock is harmless and may yet surface a token.
        #expect(manager.keychainReadPending == true)
    }

    // MARK: - (c) re-read after unlock resolves the unknown state

    @Test func refresh_after_unlock_restores_token_and_clears_pending() {
        // First load fails (cold boot); second load succeeds (device now unlocked).
        let store = FakeSessionStore([
            session(userId: "u-1", token: nil, keychainReadFailed: true),
            session(userId: "u-1", token: "jwt.recovered", keychainReadFailed: false)
        ])
        let manager = makeManager(store)
        #expect(manager.keychainReadPending == true)
        #expect(manager.token == nil)

        manager.refreshSessionIfNeeded()

        #expect(manager.keychainReadPending == false)
        #expect(manager.isLoggedIn == true)
        #expect(manager.token == "jwt.recovered")
    }

    @Test func refresh_after_unlock_revealing_no_token_logs_user_out() {
        // The read recovers, but there genuinely is no token — the user is logged out.
        let store = FakeSessionStore([
            session(userId: "u-1", token: nil, keychainReadFailed: true),
            session(userId: nil, token: nil, keychainReadFailed: false)
        ])
        let manager = makeManager(store)
        #expect(manager.isLoggedIn == true)  // unknown → optimistically logged in

        manager.refreshSessionIfNeeded()

        #expect(manager.keychainReadPending == false)
        #expect(manager.isLoggedIn == false)
        #expect(manager.token == nil)
    }

    @Test func refresh_is_a_noop_when_no_read_was_pending() {
        let store = FakeSessionStore([session(userId: "u-1", token: "jwt.alive", keychainReadFailed: false)])
        let manager = makeManager(store)
        let loadsAfterInit = store.loadCount

        manager.refreshSessionIfNeeded()

        // No pending read → no second loadSession call, state unchanged.
        #expect(store.loadCount == loadsAfterInit)
        #expect(manager.isLoggedIn == true)
        #expect(manager.token == "jwt.alive")
    }

    @Test func refresh_keeps_pending_when_keychain_still_locked() {
        // Device still locked on the next active transition — stay pending, retry later.
        let store = FakeSessionStore([
            session(userId: "u-1", token: nil, keychainReadFailed: true),
            session(userId: "u-1", token: nil, keychainReadFailed: true)
        ])
        let manager = makeManager(store)
        manager.refreshSessionIfNeeded()
        #expect(manager.keychainReadPending == true)
        #expect(manager.isLoggedIn == true)
    }
}
