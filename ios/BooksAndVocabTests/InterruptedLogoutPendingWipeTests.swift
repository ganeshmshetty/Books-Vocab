import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// #3668: a logout killed mid-wipe must leave the owner's pending-wipe marker on disk before the session
/// is torn down. Otherwise the next sign-in sees no pending wipe and admits another account beside the
/// rows of the account that logged out.
@MainActor
struct InterruptedLogoutPendingWipeTests {

    /// Stands in for `BackgroundSyncActor.clearUserData`. It records the reason and the marker owner visible
    /// at the moment the wipe runs. A suspending probe holds the wipe open until `release()`, which models a
    /// process killed before the wipe's single `save()` commits.
    private final class WipeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let defaults: UserDefaults
        private let suspends: Bool
        private var hasStarted = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var gate: CheckedContinuation<Void, Never>?
        private var recorded: [(reason: String, markerOwner: String?)] = []

        init(defaults: UserDefaults, suspends: Bool) {
            self.defaults = defaults
            self.suspends = suspends
        }

        var calls: [(reason: String, markerOwner: String?)] { lock.withLock { recorded } }

        func wipe(reason: String) async {
            lock.withLock {
                recorded.append((reason: reason, markerOwner: defaults.string(forKey: LocalDataCleanerService.pendingWipeOwnerKey)))
            }
            guard suspends else { return }
            await withCheckedContinuation { (gateContinuation: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    gate = gateContinuation
                    hasStarted = true
                    startWaiter?.resume()
                    startWaiter = nil
                }
            }
        }

        func waitUntilStarted() async {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    if hasStarted {
                        waiter.resume()
                    } else {
                        startWaiter = waiter
                    }
                }
            }
        }

        func release() {
            lock.withLock {
                gate?.resume()
                gate = nil
            }
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

    private final class NoopVerifier: AuthVerifying {
        func verify(provider: String, token: String, email: String?) async throws -> AuthVerificationResult {
            throw CancellationError()
        }
    }

    private static let ownerKey = LocalDataCleanerService.pendingWipeOwnerKey
    private static let failureCountKey = LocalDataCleanerService.pendingWipeFailureCountKey

    private static func makeContainer() -> ModelContainer {
        // In-memory; the wipe is probed and never touches it. Any @Model satisfies the requirement.
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try! ModelContainer(for: Notebook.self, configurations: config)
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "kg.test.interrupted-logout.\(UUID().uuidString)")!
    }

    /// Derived-state roots in a temp tree, so the purge never reaches the real Documents directory.
    private static func makeDerivedFixture() throws -> (roots: LocalDataCleanerService.DerivedLocalStateRoots, sentinel: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("interrupted-logout-\(UUID().uuidString)", isDirectory: true)
        let downloads = base.appendingPathComponent("downloads", isDirectory: true)
        let covers = base.appendingPathComponent("covers", isDirectory: true)
        let notebookCovers = base.appendingPathComponent("notebook-covers", isDirectory: true)
        for directory in [downloads, covers, notebookCovers] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let sentinel = downloads.appendingPathComponent("episode.mp3")
        try Data("A".utf8).write(to: sentinel)
        let roots = LocalDataCleanerService.DerivedLocalStateRoots(
            notebookCovers: notebookCovers,
            podcastCovers: covers,
            podcastDownloads: downloads
        )
        return (roots, sentinel)
    }

    private static func makeCleaner(
        probe: WipeProbe,
        defaults: UserDefaults,
        roots: LocalDataCleanerService.DerivedLocalStateRoots
    ) -> LocalDataCleanerService {
        LocalDataCleanerService(
            wipeRows: { _, reason in await probe.wipe(reason: reason) },
            defaults: defaults,
            derivedRoots: roots,
            storeRebuild: { false }
        )
    }

    private func makeManager(
        priorUserId: String?,
        cleaner: any LocalDataClearing,
        container: ModelContainer
    ) -> AuthManager {
        let manager = AuthManager(
            verifier: NoopVerifier(),
            localDataCleaner: cleaner,
            sessionStore: FixedSessionStore(userId: priorUserId),
            accountPreferenceLifecycle: NoopAccountPreferenceLifecycle()
        )
        manager.modelContainer = container
        return manager
    }

    /// The marker must exist while the wipe is still in flight. Only then can a killed logout leave it behind.
    @Test func interrupted_logout_records_owner_before_the_wipe_suspends() async throws {
        let fixture = try Self.makeDerivedFixture()
        let defaults = Self.makeDefaults()
        let probe = WipeProbe(defaults: defaults, suspends: true)
        let manager = makeManager(
            priorUserId: "user-a",
            cleaner: Self.makeCleaner(probe: probe, defaults: defaults, roots: fixture.roots),
            container: Self.makeContainer()
        )

        manager.logout(reason: "user_logout")
        await probe.waitUntilStarted()

        // Simulated kill: the wipe never commits, so only the marker written before teardown can survive it.
        #expect(defaults.string(forKey: Self.ownerKey) == "user-a")
        #expect(defaults.integer(forKey: Self.failureCountKey) == 0, "an interrupted wipe is not a failed wipe (#3229)")
        probe.release()
        await manager.pendingLocalDataCleanup?.value
    }

    /// A relaunch on the same defaults finishes A's wipe before B is admitted, and the derived state goes with it.
    @Test func next_sign_in_finishes_the_interrupted_wipe_before_admitting_the_next_account() async throws {
        let fixture = try Self.makeDerivedFixture()
        let defaults = Self.makeDefaults()
        let container = Self.makeContainer()

        // Process 1: the logout whose wipe is killed mid-flight. The manager and its task are abandoned.
        let killedProbe = WipeProbe(defaults: defaults, suspends: true)
        let killed = makeManager(
            priorUserId: "user-a",
            cleaner: Self.makeCleaner(probe: killedProbe, defaults: defaults, roots: fixture.roots),
            container: container
        )
        killed.logout(reason: "user_logout")
        await killedProbe.waitUntilStarted()

        // Process 2 (relaunch): nobody is signed in, and the defaults survived the kill.
        let relaunchProbe = WipeProbe(defaults: defaults, suspends: false)
        let relaunched = makeManager(
            priorUserId: nil,
            cleaner: Self.makeCleaner(probe: relaunchProbe, defaults: defaults, roots: fixture.roots),
            container: container
        )
        await relaunched.applyAuthenticatedUser(
            userId: "user-b",
            jwtToken: "tok.user-b",
            displayName: nil,
            email: nil,
            avatarURL: nil,
            accountSwitchReason: "account_switch_test",
            modelContainer: container
        )

        #expect(relaunchProbe.calls.map { $0.reason } == ["retry_pending_local_wipe"])
        #expect(relaunchProbe.calls.first?.markerOwner == "user-a", "A's rows are wiped while the marker still names A, before B is admitted")
        #expect(relaunched.userId == "user-b")
        #expect(defaults.string(forKey: Self.ownerKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.sentinel.path), "A's downloads must not outlive the finished wipe")
        killedProbe.release()
        await killed.pendingLocalDataCleanup?.value
    }

    /// Regression pin: an uninterrupted logout clears the marker and leaves the failure counter at zero.
    @Test func uninterrupted_logout_clears_the_marker_and_leaves_no_failures() async throws {
        let fixture = try Self.makeDerivedFixture()
        let defaults = Self.makeDefaults()
        let probe = WipeProbe(defaults: defaults, suspends: false)
        let manager = makeManager(
            priorUserId: "user-a",
            cleaner: Self.makeCleaner(probe: probe, defaults: defaults, roots: fixture.roots),
            container: Self.makeContainer()
        )

        manager.logout(reason: "user_logout")
        await manager.pendingLocalDataCleanup?.value

        #expect(probe.calls.count == 1)
        #expect(defaults.string(forKey: Self.ownerKey) == nil)
        #expect(defaults.integer(forKey: Self.failureCountKey) == 0)
    }
}
