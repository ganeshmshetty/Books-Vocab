//
//  AuthManager.swift
//  Books & Vocab
//
//  Created for Multi-User Apple Sign In
//

import SwiftUI
import Foundation
import GoogleSignIn
import SwiftData
import AuthenticationServices

@MainActor
@Observable
final class AuthManager: AuthManaging, AuthSessionProviding, SessionInvalidating {
    static let shared = AuthManager()

    @ObservationIgnored
    private let verifier: any AuthVerifying

    @ObservationIgnored
    private let localDataCleaner: any LocalDataClearing

    @ObservationIgnored
    private let sessionStore: any AuthSessionStoring

    @ObservationIgnored
    private let accountPreferenceLifecycle: any AccountPreferenceLifecycle

    @ObservationIgnored
    var appleSignInDelegate: AppleSignInDelegate?

    // Stored at app startup so any logout path can clear local data
    var modelContainer: ModelContainer?

    // Status flag published to observers
    var isLoggedIn: Bool = false

    // For UI display of the user id or simple states
    var userId: String?

    var displayName: String?

    var userEmail: String?

    var avatarURL: URL?

    // Secure token memory
    var token: String?

    // Auth error to surface in UI
    var authError: String?

    // True while Apple/Google sign-in + backend verify is in progress
    var isAuthenticating: Bool = false

    // Demo mode — unlocks UI without real auth
    var isDemoMode: Bool = false

    // True while the persisted token could not be read from the keychain (transient failure,
    // e.g. cold boot before first unlock). The session state is *unknown*, not logged-out —
    // `refreshSessionIfNeeded()` re-reads once the device is unlocked. Production observers
    // (e.g. scenePhase → .active) drive that re-read.
    var keychainReadPending: Bool = false

    init(
        verifier: any AuthVerifying = AuthBackendVerifier(),
        localDataCleaner: any LocalDataClearing = LocalDataCleanerService(),
        sessionStore: any AuthSessionStoring = AuthSessionStore.makeSessionStore(),
        accountPreferenceLifecycle: any AccountPreferenceLifecycle = AccountPreferenceLifecycleCoordinator()
    ) {
        self.verifier = verifier
        self.localDataCleaner = localDataCleaner
        self.sessionStore = sessionStore
        self.accountPreferenceLifecycle = accountPreferenceLifecycle
        applyPersistedSession(sessionStore.loadSession())
    }

    /// Maps a `PersistedAuthSession` onto the published auth state.
    ///
    /// The login decision is NOT simply `token != nil`. A transient keychain read failure
    /// (`keychainReadFailed`) yields a nil token for an *already-authenticated* user —
    /// treating that as logged-out silently signs the user out on a cold-boot launch.
    /// So when the read failed we keep the user logged in *if* there is profile evidence of
    /// a prior session (a persisted `userId`), mark the read as pending, and re-read later.
    /// Only a clean read with no token is a genuine logout. The result is deterministic —
    /// it never depends on the prior value of `isLoggedIn`.
    private func applyPersistedSession(_ persisted: PersistedAuthSession) {
        self.userId = persisted.userId
        self.displayName = persisted.displayName
        self.userEmail = persisted.userEmail
        self.avatarURL = persisted.avatarURL
        self.token = persisted.token

        if persisted.keychainReadFailed {
            // Unknown state: don't flip a logged-in user to logged-out. Keep them in only if
            // a prior session left a profile behind; never *fabricate* a login otherwise.
            self.keychainReadPending = true
            self.isLoggedIn = persisted.userId != nil
        } else {
            self.keychainReadPending = false
            self.isLoggedIn = persisted.token != nil
        }
        activateAccountPreferencesForCurrentSession()
    }

    /// Re-reads the persisted session if a prior read failed transiently. Intended to run
    /// when the app/scene becomes active (device now unlocked), resolving the unknown state:
    /// a recovered token confirms login, a clean "no token" performs the deferred logout.
    /// A no-op when no read was pending.
    func refreshSessionIfNeeded() {
        guard keychainReadPending else { return }
        applyPersistedSession(sessionStore.loadSession())
    }

    /// Composition-root hook used before the first view and before a scene's
    /// sync work. AuthManager also invokes it at every session transition so a
    /// Settings view is never the first component to choose an account namespace.
    func activateAccountPreferencesForCurrentSession() {
        guard isLoggedIn, !isDemoMode else {
            accountPreferenceLifecycle.suspend()
            return
        }
        accountPreferenceLifecycle.activate(accountID: userId)
    }

    func login(userId: String, token: String) {
        let userIdStr = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenStr = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userIdStr.isEmpty, !tokenStr.isEmpty else { return }
        // Fail closed (#2717): no account becomes current while a previous account's wipe is pending.
        // The async sign-in paths complete the wipe before reaching here; this guards direct callers.
        guard !localWipeRequiresRestart else {
            refuseSignInUntilRestart()
            return
        }
        guard !localDataCleaner.hasPendingLocalWipe else {
            refuseSignInUntilLocalWipeSucceeds()
            return
        }

        // Real login replaces demo mode — clean up demo data
        if isDemoMode, let container = modelContainer {
            DemoDataProvider.removeDemoEntries(from: container)
            isDemoMode = false
        }

        if let existing = self.userId, existing != userIdStr {
            AppLog.auth.info("Account switch detected, clearing sync + notebook state")
            let defaults = UserDefaults.standard
            // 用 KGService.SyncKeys 常數，與 LocalDataCleanerService / sync 路徑單一真相對齊。
            defaults.removeObject(forKey: KGService.SyncKeys.incrementalBoundary)
            defaults.removeObject(forKey: KGService.SyncKeys.payloadVersion)
            // 與 clearLocalData 對齊：漏清 review-event cursor 會讓經 login(customToken:)
            // 的手動帳號切換（SettingsCoordinator）讓 B 沿用 A 的 review pull cursor。
            defaults.removeObject(forKey: KGService.SyncKeys.reviewEventPullBoundary)
            accountPreferenceLifecycle.suspend()
            defaults.removeObject(forKey: NotebookFilter.storageKey)
            AppAnalytics.track(.accountSwitchDetected)
        }

        self.userId = userIdStr
        self.token = tokenStr
        accountPreferenceLifecycle.activate(accountID: userIdStr)
        sessionStore.persistProfile(
            userId: userIdStr,
            displayName: displayName,
            userEmail: userEmail,
            avatarURL: avatarURL
        )
        sessionStore.persistToken(tokenStr)
        self.isLoggedIn = true
        PerfLog.auth.mark("auth.state.login")
    }

    /// Manual/debug login via a raw custom token (userId == token), surfaced only in
    /// the DEBUG Settings account section. Mirrors `applyAuthenticatedUser`'s
    /// account-switch contract: when switching away from a prior user it clears that
    /// user's SwiftData (vocab/notebooks/review-records/books) *before* establishing
    /// the new session, so the manual-login path doesn't leave account A's rows
    /// visible under account B. `login(userId:token:)` then handles the UserDefaults
    /// sync-boundary + notebook-state reset. The empty-token guard mirrors
    /// `login(userId:token:)` so a blank token neither switches nor wipes.
    func login(customToken: String) async {
        let userIdStr = customToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userIdStr.isEmpty else { return }
        guard await completePreviousAccountWipe() else { return }
        if let existing = self.userId,
           existing != userIdStr,
           let container = self.modelContainer {
            AppLog.auth.info("Manual login account switch — clearing previous user's local data")
            accountPreferenceLifecycle.suspend()
            guard await clearPreviousAccountData(
                container: container,
                reason: "manual_login_account_switch",
                owner: existing,
                deletedAccountID: nil
            ) else {
                refuseAccountSwitch()
                return
            }
        }
        login(userId: customToken, token: customToken)
    }

    // logout 排程的本地清理 Task。fire-and-forget 但保留 handle：使用者在
    // cleanup 完成前快速重登時，post-login sync 必須先 await 它收尾，否則
    // sync 會搶用尚未被清的 sync boundary（incremental 跳過後端全部卡 →
    // 本地空庫但自認最新），且拉回的資料會被 resume 的 cleanup 再清一遍
    // （2026-06-09 000287 單字本事故根因）。
    @ObservationIgnored
    private(set) var pendingLocalDataCleanup: Task<Void, Never>?

    // 每次 logout 排程新 cleanup 時遞增。wait 以此偵測「懸掛期間又有新
    // logout」—— 單次 await 只跟得到進場當下的 handle（TOCTOU），舊 cleanup
    // 完成後 sync 即恢復、與 chain 出的新 cleanup 並行。
    @ObservationIgnored
    private var localDataCleanupGeneration = 0

    /// Set after a store rebuild (#3229). The container of this process still points at the deleted
    /// store files, so no account may become current until the app restarts.
    @ObservationIgnored
    private(set) var localWipeRequiresRestart = false

    /// Sync 開跑前的前置 gate — 等 logout 排程的本地清理收尾。
    /// 無 pending cleanup 時立即返回（正常冷啟登入不被拖慢）；
    /// 懸掛期間若又發生 logout，re-check 直到鏈上最後一個 cleanup 完成。
    ///
    /// Accepted residual：返回後 caller（非 MainActor 的 backgroundSync）resume
    /// 有一次 executor hop —— logout 落在 gate 通過後、sync 動工前仍會 sync 與
    /// 新 cleanup 並行。徹底閉合需 sync 內部 generation re-check/abort（另案）；
    /// 現靠空庫安全網 + 帳號切換清 boundary 緩解。
    func waitForPendingLocalDataCleanup() async {
        await awaitLogoutCleanupChain()
    }

    /// `false` while a previous account's wipe is outstanding: sync must not merge into those rows
    /// (#2717). Sign-in refuses while a wipe is pending, so this is a fail-closed check and never wipes.
    func waitForLocalDataCleanupGate() async -> Bool {
        await awaitLogoutCleanupChain()
        return !localDataCleaner.hasPendingLocalWipe && !localWipeRequiresRestart
    }

    private func awaitLogoutCleanupChain() async {
        while true {
            let generation = localDataCleanupGeneration
            guard let pending = pendingLocalDataCleanup else { return }
            await pending.value
            if localDataCleanupGeneration == generation { return }
        }
    }

    /// Sign-in boundary (#2717). A logout wipe still in flight finishes first. A wipe left pending by
    /// an earlier failure must then succeed before any account becomes current. `false` = fail closed.
    private func completePreviousAccountWipe() async -> Bool {
        await awaitLogoutCleanupChain()
        // The store was rebuilt in this process: the live container still points at the deleted files (#3229).
        guard !localWipeRequiresRestart else {
            refuseSignInUntilRestart()
            return false
        }
        guard localDataCleaner.hasPendingLocalWipe else { return true }
        // Past the retry cap another retry cannot succeed. Only the store rebuild may finish the wipe (#3229).
        guard !localDataCleaner.pendingWipeNeedsStoreRebuild else {
            refuseSignInUntilLocalWipeSucceeds()
            return false
        }
        if let container = modelContainer {
            let finished = await localDataCleaner.retryPendingLocalWipe(container: container, signedInUserId: userId)
            if finished { return true }
        }
        refuseSignInUntilLocalWipeSucceeds()
        return false
    }

    /// Store-rebuild recovery for a wipe stuck past the retry cap (#3229). Deletes the on-disk store and
    /// drops the pending marker. The live container still references the deleted files, so this process
    /// refuses every sign-in; the next launch builds a fresh store and admits sign-in normally.
    @discardableResult
    func recoverFromStuckLocalWipe() async -> Bool {
        guard await localDataCleaner.rebuildStoreAndDiscardPendingWipe() else { return false }
        localWipeRequiresRestart = true
        refuseSignInUntilRestart()
        return true
    }

    /// Wipes the rows of `owner`, the account they belong to. A failure is recorded by the cleaner;
    /// one immediate retry runs before the caller proceeds. `false` = still failing.
    private func clearPreviousAccountData(
        container: ModelContainer,
        reason: String,
        owner: String,
        deletedAccountID: String?
    ) async -> Bool {
        if await localDataCleaner.clearLocalDataReportingFailure(
            container: container,
            reason: reason,
            owner: owner,
            deletedAccountID: deletedAccountID
        ) {
            return true
        }
        AppLog.auth.error("local wipe failed (reason=\(reason)); retrying once before sign-in")
        return await localDataCleaner.retryPendingLocalWipe(container: container, signedInUserId: userId)
    }

    /// The switch wipe failed twice. The previous account stays signed in: its rows and cursors are
    /// intact because the failed wipe committed nothing, so the pending marker is dropped (#2717).
    private func refuseAccountSwitch() {
        localDataCleaner.discardPendingLocalWipe()
        activateAccountPreferencesForCurrentSession()
        refuseSignInUntilLocalWipeSucceeds()
    }

    private func refuseSignInUntilLocalWipeSucceeds() {
        // Past the retry cap, retrying cannot succeed: the only escape is a store rebuild, which has no
        // in-app entry yet. Telling the user to retry later would be a false promise (#3229).
        if localDataCleaner.pendingWipeNeedsStoreRebuild {
            AppLog.auth.error("sign-in refused: pending local wipe is stuck past the retry cap")
            authError = L10n.string("本機資料無法清除，請重新安裝 App 後再登入")
            return
        }
        AppLog.auth.error("sign-in refused: previous account's local wipe is still pending")
        authError = L10n.string("上一個帳號的本機資料尚未清除，請稍後再試登入")
    }

    private func refuseSignInUntilRestart() {
        AppLog.auth.error("sign-in refused: local store was rebuilt, restart required")
        authError = L10n.string("本機資料已重建，請重新啟動 App 後再登入")
    }

    func logout(modelContainer: ModelContainer? = nil, reason: String = "user_logout") {
        // Capture before the up-front teardown nils `userId`: a delete_account logout must scope the
        // account-preference purge to exactly this account (#2434), never to other accounts on the device.
        // Callers that await before logging out must use logoutAfterAccountDeletion with an ID captured
        // beforehand instead (#2556): a concurrent 401 teardown may already have nil'd `userId`.
        let deletedAccountID = reason == LocalDataCleanerService.deleteAccountReason ? userId : nil
        endSession(modelContainer: modelContainer, reason: reason, deletedAccountID: deletedAccountID)
    }

    /// delete_account 登出。`deletedAccountID` 必須是呼叫端於 `await DELETE` 之前擷取的帳號；
    /// 併發的 401 teardown 會先把 `userId` 清為 nil，之後再讀會跳過帳號偏好 purge（#2556）。
    func logoutAfterAccountDeletion(modelContainer: ModelContainer?, deletedAccountID: String?) {
        endSession(
            modelContainer: modelContainer,
            reason: LocalDataCleanerService.deleteAccountReason,
            deletedAccountID: deletedAccountID
        )
    }

    private func endSession(modelContainer: ModelContainer?, reason: String, deletedAccountID: String?) {
        AppAnalytics.track(.logoutPerformed(reason: reason))
        let container = modelContainer ?? self.modelContainer
        // Captured before teardown nils userId: the wipe belongs to this account's rows ("" if none).
        let previousUserId = self.userId ?? ""
        if reason == LocalDataCleanerService.deleteAccountReason, deletedAccountID == nil {
            AppLog.auth.warning("logout(delete_account): no account captured; account-preference purge skipped (#2434)")
        }
        accountPreferenceLifecycle.suspend()
        localDataCleanupGeneration += 1
        pendingLocalDataCleanup = Task { [previousCleanup = pendingLocalDataCleanup, previousUserId] in
            // Clear session state UP FRONT, before awaiting clearLocalData. The cleanup hops to
            // BackgroundSyncActor — a real suspension that yields the MainActor. Doing the nils
            // + clearSession() after that await (the old order) opened a TOCTOU window: a
            // login() in that window was unconditionally wiped back to nil on resume, kicking
            // the user out right after they signed back in. clearLocalData needs only the
            // container + reason (no userId/token), so front-loading is safe.
            GIDSignIn.sharedInstance.signOut()
            self.userId = nil
            self.token = nil
            self.displayName = nil
            self.userEmail = nil
            self.avatarURL = nil
            self.sessionStore.clearSession()
            self.isLoggedIn = false
            // 與 userId 清除同一同步區段：在途的權益請求此時必定看到帳號已變更，不會再寫回舊帳號權益（#2592, #3222）。
            SubscriptionManager.shared.resetForSessionEnd()
            PerfLog.auth.mark("auth.state.logout", "reason=\(reason)")

            // Chain：等前一次 logout 的 cleanup 收尾再動工。連續「登出→重登→登出」
            // 時兩個 cleanup 各持獨立 BackgroundSyncActor、零序列化 —— 並行互踩會
            // 讓後完成的把新 session 拉回的資料再清一遍（000287 同類事故）；chain 也
            // 讓 gate 只 await 最新 handle 即隱含前序 cleanup 全部收尾。
            await previousCleanup?.value

            // A failure stays recorded as pending; sign-in completes it before any account is admitted.
            if let container {
                _ = await clearPreviousAccountData(
                    container: container,
                    reason: reason,
                    owner: previousUserId,
                    deletedAccountID: deletedAccountID
                )
            }

            // Stale-guard (mirrors SubscriptionManager+Refresh requestUserId check), second line
            // of defence after the up-front teardown. The teardown left userId == nil; if a
            // login() interleaved during the await, userId is now non-nil — a fresh session we
            // must not touch. Should any post-cleanup teardown ever be added below, it stops
            // here in that race.
            guard self.userId == nil else {
                AppLog.auth.info("logout: session re-established during cleanup; skipping post-cleanup teardown")
                return
            }
        }
    }

    func applyAuthenticatedUser(
        userId: String,
        jwtToken: String,
        displayName: String?,
        email: String?,
        avatarURL: URL?,
        accountSwitchReason: String,
        modelContainer: ModelContainer?
    ) async {
        authError = nil
        // Profile fields are applied only once the sign-in is admitted, so a refused switch cannot
        // leave the still-signed-in previous account showing the new account's name/email (#2717).
        guard await completePreviousAccountWipe() else { return }

        let isAccountSwitch = self.userId != nil && self.userId != userId
        if isAccountSwitch, let container = modelContainer {
            AppLog.auth.info("Account switch — clearing previous user's local data")
            accountPreferenceLifecycle.suspend()
            guard await clearPreviousAccountData(
                container: container,
                reason: accountSwitchReason,
                owner: self.userId ?? "",
                deletedAccountID: nil
            ) else {
                refuseAccountSwitch()
                return
            }
        }
        if let displayName, !displayName.isEmpty { self.displayName = displayName }
        if let email, !email.isEmpty { self.userEmail = email }
        self.avatarURL = avatarURL
        login(userId: userId, token: jwtToken)
    }

    func enterDemoMode(modelContainer: ModelContainer) {
        accountPreferenceLifecycle.suspend()
        isDemoMode = true
        isLoggedIn = true
        displayName = "Demo"
        DemoDataProvider.injectDemoEntries(into: modelContainer)
    }

    func exitDemoMode(modelContainer: ModelContainer) {
        DemoDataProvider.removeDemoEntries(from: modelContainer)
        isDemoMode = false
        // Restore real auth state — `applyPersistedSession` handles a transient keychain
        // read failure (keeps a prior session logged in, marks the read pending).
        applyPersistedSession(sessionStore.loadSession())
    }

    func setAuthError(_ message: String) {
        authError = message
    }

    /// Classification of a backend-verification failure for UI + crash reporting.
    enum VerifyFailure: Equatable {
        case cancelled
        case offline
        case server
    }

    nonisolated static func classifyVerifyFailure(_ error: Error) -> VerifyFailure {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                return .offline
            default: return .server
            }
        }
        if case AuthVerificationError.offline = error { return .offline }
        if case KGError.offline = error { return .offline }
        return .server
    }

    /// Surfaces a verification failure; returns whether it is a genuine fault worth recording.
    @discardableResult
    func handleVerifyFailure(_ error: Error) -> Bool {
        switch Self.classifyVerifyFailure(error) {
        case .cancelled:
            return false
        case .offline:
            setAuthError(L10n.string("目前沒有網路連線"))
            return false
        case .server:
            setAuthError(L10n.string("伺服器驗證失敗，請稍後再試。"))
            return true
        }
    }

    func recordProviderAuthenticationFailure() {
        setAuthError(L10n.string("登入暫時失敗"))
    }

    #if targetEnvironment(simulator)
    func applyUITestPersistedSession(_ persisted: PersistedAuthSession) {
        applyPersistedSession(persisted)
    }
    #endif

    func verify(provider: String, token: String, email: String?) async throws -> AuthVerificationResult {
        try await verifier.verify(provider: provider, token: token, email: email)
    }
}
