import Foundation
import SwiftData

@MainActor
protocol AuthSessionProviding: AnyObject {
    var isLoggedIn: Bool { get }
    var token: String? { get }
}

@MainActor
protocol SessionInvalidating: AnyObject {
    func logout(modelContainer: ModelContainer?, reason: String)
    /// logout 排程的本地清理（SwiftData + sync boundary）收尾 gate。
    /// sync 開跑前必先 await，避免搶用尚未被清的 boundary（000287 事故）。
    /// 無 pending cleanup 時立即返回。
    func waitForPendingLocalDataCleanup() async
    /// 同一道 gate，但回報是否可以開跑 sync：`false` = 上一帳號的列清除仍失敗（#2717），
    /// sync 不得以殘留的 boundary 做 incremental。
    func waitForLocalDataCleanupGate() async -> Bool
}

extension SessionInvalidating {
    func waitForLocalDataCleanupGate() async -> Bool {
        await waitForPendingLocalDataCleanup()
        return true
    }
}

protocol LocalDataClearing: AnyObject {
    /// `deletedAccountID` is non-nil only for a delete_account logout: it names the account whose
    /// namespaced preferences (local + iCloud KVS) must be purged. Every other caller passes nil.
    func clearLocalData(container: ModelContainer, reason: String, deletedAccountID: String?) async
    /// Same wipe, but `false` when the row wipe failed. The implementation keeps sync cursors and
    /// records the pending wipe under `owner` (the account whose rows remain; "" when unknown, #2717).
    func clearLocalDataReportingFailure(
        container: ModelContainer,
        reason: String,
        owner: String,
        deletedAccountID: String?
    ) async -> Bool
    /// Finishes the pending wipe. Refused (`false`) unless `signedInUserId` is nil or the pending owner,
    /// because another signed-in account may already hold unsynced rows (#2717).
    func retryPendingLocalWipe(container: ModelContainer, signedInUserId: String?) async -> Bool
    /// Drops the pending wipe of a refused account switch. The failed wipe committed nothing.
    func discardPendingLocalWipe()
    /// Owner recorded by the outstanding failed wipe; nil when none is pending.
    var pendingLocalWipeOwner: String? { get }
}

extension LocalDataClearing {
    func clearLocalDataReportingFailure(
        container: ModelContainer,
        reason: String,
        owner: String,
        deletedAccountID: String?
    ) async -> Bool {
        await clearLocalData(container: container, reason: reason, deletedAccountID: deletedAccountID)
        return true
    }

    func retryPendingLocalWipe(container: ModelContainer, signedInUserId: String?) async -> Bool { true }

    func discardPendingLocalWipe() {}

    var pendingLocalWipeOwner: String? { nil }

    var hasPendingLocalWipe: Bool { pendingLocalWipeOwner != nil }
}

/// AuthManager 的行為契約，供 View / Handler 依賴，方便替換 Mock 進行測試
@MainActor
protocol AuthManaging: AnyObject {
    var isLoggedIn: Bool { get }
    var userId: String? { get }
    var token: String? { get }
    var displayName: String? { get }
    var userEmail: String? { get }
    var avatarURL: URL? { get }
    var authError: String? { get }
    var isAuthenticating: Bool { get }
    var isDemoMode: Bool { get }

    func enterDemoMode(modelContainer: ModelContainer)
    func exitDemoMode(modelContainer: ModelContainer)
    /// Re-reads the persisted session when a prior keychain read failed transiently
    /// (cold-boot, pre-first-unlock). Call when the app/scene becomes active.
    func refreshSessionIfNeeded()
    func login(userId: String, token: String)
    func login(customToken: String) async
    func logout(modelContainer: ModelContainer?, reason: String)
    /// delete_account 登出；`deletedAccountID` 須於 `await` 前擷取，見 `AuthManager.logoutAfterAccountDeletion`。
    func logoutAfterAccountDeletion(modelContainer: ModelContainer?, deletedAccountID: String?)
    func loginWithGoogle(modelContainer: ModelContainer?)
    func loginWithApple(modelContainer: ModelContainer?)
}
