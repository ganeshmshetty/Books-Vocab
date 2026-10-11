//
//  ActiveNotebookStoreTests.swift
//  Books & Vocab Tests
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@Suite("ActiveNotebookLWW")
@MainActor
struct ActiveNotebookLWWTests {
    @Test func cloudNewerWins() {
        let local = ActiveNotebookState(activeNotebookId: "a", updatedAt: 100)
        let cloud = ActiveNotebookState(activeNotebookId: "b", updatedAt: 200)
        #expect(ActiveNotebookLWW.resolve(local: local, cloud: cloud).activeNotebookId == "b")
    }

    @Test func localNewerWins() {
        let local = ActiveNotebookState(activeNotebookId: "a", updatedAt: 300)
        let cloud = ActiveNotebookState(activeNotebookId: "b", updatedAt: 200)
        #expect(ActiveNotebookLWW.resolve(local: local, cloud: cloud).activeNotebookId == "a")
    }

    @Test func cloudWinsWhenLocalNil() {
        let local = ActiveNotebookState(activeNotebookId: "a", updatedAt: nil)
        let cloud = ActiveNotebookState(activeNotebookId: "b", updatedAt: 1)
        #expect(ActiveNotebookLWW.resolve(local: local, cloud: cloud).activeNotebookId == "b")
    }

    @Test func localWinsWhenCloudNil() {
        let local = ActiveNotebookState(activeNotebookId: "a", updatedAt: 1)
        let cloud = ActiveNotebookState(activeNotebookId: "b", updatedAt: nil)
        #expect(ActiveNotebookLWW.resolve(local: local, cloud: cloud).activeNotebookId == "a")
    }

    @Test func bothNilKeepsLocal() {
        let local = ActiveNotebookState(activeNotebookId: "a", updatedAt: nil)
        let cloud = ActiveNotebookState(activeNotebookId: "b", updatedAt: nil)
        #expect(ActiveNotebookLWW.resolve(local: local, cloud: cloud).activeNotebookId == "a")
    }
}

@Suite("ActiveNotebookStore")
@MainActor
struct ActiveNotebookStoreTests {

    /// Keeps the test's remote-response handshake off the MainActor. The
    /// coordinator itself is MainActor-bound, so keeping both continuations on
    /// that executor can starve the producer under a parallel full-suite run.
    private actor DeferredUserConfigGate {
        private var hasStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var resultContinuation: CheckedContinuation<Void, Never>?
        private var responseReleased = false

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func awaitResponseRelease() async {
            hasStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }

            guard !responseReleased else { return }
            await withCheckedContinuation { resultContinuation = $0 }
        }

        func releaseResponse() {
            responseReleased = true
            resultContinuation?.resume()
            resultContinuation = nil
        }
    }

    private final class TestAuth: AuthManaging {
        var isLoggedIn = true
        var userId: String? = "account-a"
        var token: String? = "token-a"
        var displayName: String?
        var userEmail: String?
        var avatarURL: URL?
        var authError: String?
        var isAuthenticating = false
        var isDemoMode = false

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

    private final class DeferredUserConfigService: UserConfigFetching {
        let config: KGUserConfig
        private let gate = DeferredUserConfigGate()

        init(config: KGUserConfig) {
            self.config = config
        }

        func fetchUserConfig() async throws -> KGUserConfig {
            await gate.awaitResponseRelease()
            return config
        }

        func waitUntilStarted() async {
            await gate.waitUntilStarted()
        }

        func resume() async {
            await gate.releaseResponse()
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ActiveNotebookStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("未設定時回 default，activeNotebookIdIfSet 為 nil")
    func defaultsWhenUnset() {
        let store = ActiveNotebookStore(defaults: makeDefaults(), cloud: FakeCloudKVStore())
        #expect(store.activeNotebookId == "default")
        #expect(store.activeNotebookIdIfSet == nil)
    }

    @Test("setActive 寫本地 + iCloud + updatedAt 三層")
    func setActiveWritesAllLayers() {
        let d = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ActiveNotebookStore(defaults: d, cloud: cloud)
        store.setActive("nb-42")
        #expect(store.activeNotebookId == "nb-42")
        #expect(d.string(forKey: "activeNotebookId") == "nb-42")
        #expect(d.object(forKey: "active_notebook_updated_at") as? Double != nil)
        #expect(cloud.string(forKey: "activeNotebookId") == "nb-42")
        #expect(cloud.double(forKey: "active_notebook_updated_at") != nil)
    }

    @Test("init：cloud 較新時套 cloud 並寫回本地（直讀者一致）")
    func initAppliesCloudWhenNewer() {
        let d = makeDefaults()
        d.set("local-nb", forKey: "activeNotebookId")
        d.set(100.0, forKey: "active_notebook_updated_at")
        let cloud = FakeCloudKVStore()
        cloud.set("cloud-nb", forKey: "activeNotebookId")
        cloud.set(200.0, forKey: "active_notebook_updated_at")
        let store = ActiveNotebookStore(defaults: d, cloud: cloud)
        #expect(store.activeNotebookId == "cloud-nb")
        #expect(d.string(forKey: "activeNotebookId") == "cloud-nb")  // 寫回本地
    }

    @Test("init：local 較新時保留 local")
    func initKeepsLocalWhenNewer() {
        let d = makeDefaults()
        d.set("local-nb", forKey: "activeNotebookId")
        d.set(300.0, forKey: "active_notebook_updated_at")
        let cloud = FakeCloudKVStore()
        cloud.set("cloud-nb", forKey: "activeNotebookId")
        cloud.set(200.0, forKey: "active_notebook_updated_at")
        let store = ActiveNotebookStore(defaults: d, cloud: cloud)
        #expect(store.activeNotebookId == "local-nb")
    }

    @Test("init：無 timestamp 的非 default 本地 id 不被清除（#2726）")
    func initKeepsTimestamplessNonDefaultLocalId() {
        let d = makeDefaults()
        d.set("nb-42", forKey: "activeNotebookId")
        let store = ActiveNotebookStore(defaults: d, cloud: FakeCloudKVStore())
        #expect(store.activeNotebookId == "nb-42")
        #expect(store.activeNotebookIdIfSet == "nb-42")
    }

    @Test("clearStale 寫回 default 並推進 updatedAt（跨裝置同步重置）")
    func clearStaleResetsWithTimestamp() {
        let d = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ActiveNotebookStore(defaults: d, cloud: cloud)
        store.setActive("nb-9")
        store.clearStale()
        #expect(store.activeNotebookId == "default")
        #expect(cloud.string(forKey: "activeNotebookId") == "default")
        #expect(cloud.double(forKey: "active_notebook_updated_at") != nil)
    }

    @Test("clear 只清本地，不碰 iCloud（Apple-ID scope）")
    func clearOnlyLocal() {
        let d = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ActiveNotebookStore(defaults: d, cloud: cloud)
        store.setActive("nb-9")
        store.clear()
        #expect(store.activeNotebookIdIfSet == nil)
        #expect(d.object(forKey: "active_notebook_updated_at") == nil)
        #expect(cloud.string(forKey: "activeNotebookId") == "nb-9")  // iCloud 不被清
    }

    @Test func accountScopedClearKeepsDurableActiveNotebook() {
        let d = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ActiveNotebookStore(defaults: d, cloud: cloud, accountID: "account-a")
        store.setActive("account-a-nb")

        store.clear()

        #expect(store.activeNotebookId == "account-a-nb")
        #expect(store.activeNotebookIdIfSet == "account-a-nb")
    }

    @Test("server 較新時套用 non-default active notebook，只寫本地層")
    func syncActiveNotebookFromServerAcceptsNewerNonDefault() {
        let d = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ActiveNotebookStore(defaults: d, cloud: cloud)
        let accepted = store.syncActiveNotebookFromServer(
            ActiveNotebookState(activeNotebookId: "srv-non-default", updatedAt: 500)
        )
        #expect(accepted)
        #expect(store.activeNotebookId == "srv-non-default")
        #expect(d.object(forKey: "active_notebook_updated_at") as? Double == 500)
        // Server projection 不回寫 iCloud KVS，避免與其他 Apple 裝置的 local write 競爭。
        #expect(cloud.string(forKey: "activeNotebookId") == nil)
        #expect(cloud.double(forKey: "active_notebook_updated_at") == nil)
    }

    @Test func serverActiveNotebookIgnoredWhenLocalTimestampIsNewer() {
        let d = makeDefaults()
        d.set("local-nb", forKey: "activeNotebookId")
        d.set(300.0, forKey: "active_notebook_updated_at")
        let store = ActiveNotebookStore(defaults: d, cloud: FakeCloudKVStore())

        let accepted = store.syncActiveNotebookFromServer(
            ActiveNotebookState(activeNotebookId: "server-nb", updatedAt: 200)
        )

        #expect(!accepted)
        #expect(store.activeNotebookId == "local-nb")
        #expect(store.snapshot.updatedAt == 300)
    }

    @Test func serverActiveNotebookWithoutTimestampIsRejected() {
        let d = makeDefaults()
        let store = ActiveNotebookStore(defaults: d, cloud: FakeCloudKVStore())

        let accepted = store.syncActiveNotebookFromServer(
            ActiveNotebookState(activeNotebookId: "server-nb", updatedAt: nil)
        )

        #expect(!accepted)
        #expect(store.activeNotebookIdIfSet == nil)
    }

    @Test func serverActiveNotebookWithBlankIdentifierIsRejected() {
        let d = makeDefaults()
        let store = ActiveNotebookStore(defaults: d, cloud: FakeCloudKVStore())

        let accepted = store.syncActiveNotebookFromServer(
            ActiveNotebookState(activeNotebookId: " \t\n ", updatedAt: 500)
        )

        #expect(!accepted)
        #expect(store.activeNotebookIdIfSet == nil)
    }

    @Test func accountSwitchDoesNotReusePreviousActiveNotebook() {
        let d = makeDefaults()
        let cloud = FakeCloudKVStore()
        let store = ActiveNotebookStore(defaults: d, cloud: cloud)
        store.setActive("account-a-nb")

        // AuthManager clears the local projection before establishing account B.
        store.clear()
        #expect(store.activeNotebookIdIfSet == nil)
        #expect(store.activeNotebookId == ActiveNotebookStore.defaultNotebookId)

        let accepted = store.syncActiveNotebookFromServer(
            ActiveNotebookState(activeNotebookId: "account-b-nb", updatedAt: 500)
        )

        #expect(accepted)
        #expect(store.activeNotebookId == "account-b-nb")
        #expect(cloud.string(forKey: "activeNotebookId") == "account-a-nb")
    }

    @Test func accountScopedActiveNotebookRestoresOnlyItsOwnNamespace() {
        let d = makeDefaults()
        let cloud = FakeCloudKVStore()
        let accountA = ActiveNotebookStore(defaults: d, cloud: cloud, accountID: "account-a")
        accountA.setActive("account-a-nb")

        let accountB = ActiveNotebookStore(defaults: d, cloud: cloud, accountID: "account-b")
        #expect(accountB.activeNotebookId == ActiveNotebookStore.defaultNotebookId)
        #expect(accountB.activeNotebookIdIfSet == nil)
        accountB.setActive("account-b-nb")

        let restoredA = ActiveNotebookStore(defaults: d, cloud: cloud, accountID: "account-a")
        #expect(restoredA.activeNotebookId == "account-a-nb")
        #expect(restoredA.activeNotebookIdIfSet == "account-a-nb")
    }

    @Test func firstAccountActivationMigratesLegacyActiveNotebookOnlyOnce() {
        let suite = "ActiveNotebookLegacyMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let cloud = FakeCloudKVStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("legacy-notebook", forKey: "activeNotebookId")
        defaults.set(100.0, forKey: "active_notebook_updated_at")
        cloud.set("legacy-notebook", forKey: "activeNotebookId")
        cloud.set(100.0, forKey: "active_notebook_updated_at")

        let accountA = ActiveNotebookStore(defaults: defaults, cloud: cloud, accountID: "account-a")
        #expect(accountA.activeNotebookId == "legacy-notebook")
        #expect(
            defaults.string(
                forKey: AccountPreferenceNamespace.key("activeNotebookId", accountID: "account-a")
            ) == "legacy-notebook"
        )

        let accountB = ActiveNotebookStore(defaults: defaults, cloud: cloud, accountID: "account-b")
        #expect(accountB.activeNotebookId == ActiveNotebookStore.defaultNotebookId)
        #expect(accountB.activeNotebookIdIfSet == nil)
    }

    @Test func staleUserConfigResponseIsDiscardedAfterAccountSwitch() async {
        let d = makeDefaults()
        let store = ActiveNotebookStore(defaults: d, cloud: FakeCloudKVStore())
        let auth = TestAuth()
        let service = DeferredUserConfigService(
            config: KGUserConfig(
                translation: nil,
                review_clock: nil,
                review_mode: nil,
                vocab_ui: KGVocabUIConfig(active_notebook_id: "account-a-nb", updated_at: 500),
                auto_link: nil
            )
        )
        let coordinator = NotebookListCoordinator()

        let task = Task { @MainActor in
            await coordinator.syncActiveNotebookFromServer(
                authManager: auth,
                kgService: service,
                store: store
            )
        }
        await service.waitUntilStarted()
        auth.userId = "account-b"
        auth.token = "token-b"
        await service.resume()
        await task.value

        #expect(store.activeNotebookIdIfSet == nil)
    }

    @Test func serverRequestIdentityRejectsAccountOrCredentialChanges() {
        let auth = TestAuth()
        #expect(
            NotebookListCoordinator.acceptsServerResponse(
                authManager: auth,
                requestedUserId: "account-a",
                requestedToken: "token-a"
            )
        )

        auth.userId = "account-b"
        #expect(
            !NotebookListCoordinator.acceptsServerResponse(
                authManager: auth,
                requestedUserId: "account-a",
                requestedToken: "token-a"
            )
        )

        auth.userId = "account-a"
        auth.token = "token-b"
        #expect(
            !NotebookListCoordinator.acceptsServerResponse(
                authManager: auth,
                requestedUserId: "account-a",
                requestedToken: "token-a"
            )
        )
    }

    @Test("snapshot 讀本地層")
    func snapshotReadsLocal() {
        let store = ActiveNotebookStore(defaults: makeDefaults(), cloud: FakeCloudKVStore())
        #expect(store.snapshot.updatedAt == nil)
        store.setActive("nb-1")
        #expect(store.snapshot.updatedAt != nil)
        #expect(store.snapshot.activeNotebookId == "nb-1")
    }
}
