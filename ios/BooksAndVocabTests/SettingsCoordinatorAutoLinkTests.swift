//
//  SettingsCoordinatorAutoLinkTests.swift
//  Books & Vocab Tests
//
//  #3503 回歸測試：`SettingsCoordinator.updateAutoLink` 在 `await` 期間若發生
//  account boundary（`accountGeneration` 遞增），遠端失敗的 rollback 不得把
//  `AutoLinkSettingsStore` 還原成上一帳號的值（會蓋掉新帳號已套用的 server 值，
//  且時戳被倒回）。對齊 `updateReviewClock` 的 generation／requestedUserID 守門。
//
//  測試用真實 `KGService`，只替換遠端 client 與 auth session，讓失敗路徑走完整
//  `performUserConfigRequest` → `updateAutoLinkConfig` 的真實 throw 傳遞。
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
private final class AutoLinkTestAuth: AuthManaging {
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

@MainActor
private final class AutoLinkTestSession: AuthSessionProviding {
    let isLoggedIn = true
    let token: String? = "test_token"
}

@MainActor
private final class AutoLinkTestInvalidator: SessionInvalidating {
    func logout(modelContainer: ModelContainer?, reason: String) {}
    func waitForPendingLocalDataCleanup() async {}
}

private struct AutoLinkRemoteFailure: Error {}

/// 讓測試精準控制「遠端 push 已送出、尚未回應」的時點。
private actor AutoLinkRemoteGate {
    private var hasEntered = false
    private var hasReleased = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        hasEntered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !hasReleased else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        hasReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

/// `updateAutoLinkConfig` 會先掛在 gate 上，放行後一律失敗（模擬 push 被拒）。
private final class AutoLinkFailingUserConfigClient: KGUserConfigRemoteHandling {
    let gate = AutoLinkRemoteGate()

    func fetchUserConfig(baseURL: URL, token: String) async throws -> KGUserConfig {
        throw AutoLinkRemoteFailure()
    }

    func updateTranslationConfig(baseURL: URL, token: String, translation: KGTranslationConfig) async throws -> KGUserConfig {
        throw AutoLinkRemoteFailure()
    }

    func updateReviewClockConfig(baseURL: URL, token: String, reviewClock: KGReviewClockConfig) async throws -> KGUserConfig {
        throw AutoLinkRemoteFailure()
    }

    func updateReviewModeConfig(baseURL: URL, token: String, reviewMode: KGReviewModeConfig) async throws -> KGUserConfig {
        throw AutoLinkRemoteFailure()
    }

    func updateVocabUIConfig(baseURL: URL, token: String, vocabUI: KGVocabUIConfig) async throws -> KGUserConfig {
        throw AutoLinkRemoteFailure()
    }

    func updateAutoLinkConfig(baseURL: URL, token: String, autoLink: KGAutoLinkConfig) async throws -> KGUserConfig {
        await gate.enterAndWait()
        throw AutoLinkRemoteFailure()
    }
}

@Suite(.serialized)
@MainActor
struct SettingsCoordinatorAutoLinkTests {

    private func makeStore() -> AutoLinkSettingsStore {
        let suite = "test-settings-auto-link-\(UUID().uuidString)"
        return AutoLinkSettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    private func makeService(remote: AutoLinkFailingUserConfigClient) -> KGService {
        KGService(
            authSession: AutoLinkTestSession(),
            sessionInvalidator: AutoLinkTestInvalidator(),
            userConfigClient: remote,
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
    }

    /// 同帳號失敗：仍須 rollback 回原值與原時戳（既有行為，防守迴歸）。
    @Test func sameAccountFailureRollsBackToPreviousValueAndTimestamp() async {
        let store = makeStore()
        let remote = AutoLinkFailingUserConfigClient()
        let service = makeService(remote: remote)
        let coordinator = SettingsCoordinator(translationLifecycle: NoopAccountPreferenceLifecycle())

        let task = Task { @MainActor in
            await coordinator.updateAutoLink(
                enabled: false,
                autoLinkStore: store,
                authManager: AutoLinkTestAuth(),
                kgService: service,
                toastCoordinator: AppToastCoordinator()
            )
        }
        await remote.gate.waitUntilEntered()
        await remote.gate.release()
        _ = await task.value

        #expect(store.isEnabled == true)
        #expect(store.updatedAt == nil)
    }

    /// #3503：await 期間發生 account boundary，遠端失敗後不得 restore 上一帳號的值。
    /// 新帳號已套用的 server 值（enabled=false, updated_at=4e9）必須保留。
    @Test func staleFailureAfterAccountBoundaryDoesNotRestorePreviousAccountValue() async {
        let store = makeStore()
        let remote = AutoLinkFailingUserConfigClient()
        let service = makeService(remote: remote)
        let coordinator = SettingsCoordinator(translationLifecycle: NoopAccountPreferenceLifecycle())
        let auth = AutoLinkTestAuth()

        let task = Task { @MainActor in
            await coordinator.updateAutoLink(
                enabled: false,
                autoLinkStore: store,
                authManager: auth,
                kgService: service,
                toastCoordinator: AppToastCoordinator()
            )
        }
        await remote.gate.waitUntilEntered()

        auth.userId = "account-b"
        coordinator.resetForAccountBoundary()
        store.applyServer(enabled: false, updatedAt: 4_000_000_000)

        await remote.gate.release()
        _ = await task.value

        #expect(store.isEnabled == false)
        #expect(store.updatedAt == 4_000_000_000)
    }
}
