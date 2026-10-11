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
        if !userIdStr.isEmpty,
           let existing = self.userId,
           existing != userIdStr,
           let container = self.modelContainer {
            AppLog.auth.info("Manual login account switch — clearing previous user's local data")
            accountPreferenceLifecycle.suspend()
            await localDataCleaner.clearLocalData(container: container, reason: "manual_login_account_switch")
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

    /// Sync 開跑前的前置 gate — 等 logout 排程的本地清理收尾。
    /// 無 pending cleanup 時立即返回（正常冷啟登入不被拖慢）；
    /// 懸掛期間若又發生 logout，re-check 直到鏈上最後一個 cleanup 完成。
    ///
    /// Accepted residual：返回後 caller（非 MainActor 的 backgroundSync）resume
    /// 有一次 executor hop —— logout 落在 gate 通過後、sync 動工前仍會 sync 與
    /// 新 cleanup 並行。徹底閉合需 sync 內部 generation re-check/abort（另案）；
    /// 現靠空庫安全網 + 帳號切換清 boundary 緩解。
    func waitForPendingLocalDataCleanup() async {
        while true {
            let generation = localDataCleanupGeneration
            guard let pending = pendingLocalDataCleanup else { return }
            await pending.value
            if localDataCleanupGeneration == generation { return }
        }
    }

    func logout(modelContainer: ModelContainer? = nil, reason: String = "user_logout") {
        AppAnalytics.track(.logoutPerformed(reason: reason))
        let container = modelContainer ?? self.modelContainer
        accountPreferenceLifecycle.suspend()
        localDataCleanupGeneration += 1
        pendingLocalDataCleanup = Task { [previousCleanup = pendingLocalDataCleanup] in
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
            PerfLog.auth.mark("auth.state.logout", "reason=\(reason)")

            // Chain：等前一次 logout 的 cleanup 收尾再動工。連續「登出→重登→登出」
            // 時兩個 cleanup 各持獨立 BackgroundSyncActor、零序列化 —— 並行互踩會
            // 讓後完成的把新 session 拉回的資料再清一遍（000287 同類事故）；chain 也
            // 讓 gate 只 await 最新 handle 即隱含前序 cleanup 全部收尾。
            await previousCleanup?.value

            if let container {
                await localDataCleaner.clearLocalData(container: container, reason: reason)
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
        if let displayName, !displayName.isEmpty { self.displayName = displayName }
        if let email, !email.isEmpty { self.userEmail = email }
        self.avatarURL = avatarURL
        sessionStore.persistProfile(
            userId: self.userId,
            displayName: self.displayName,
            userEmail: self.userEmail,
            avatarURL: self.avatarURL
        )

        let isAccountSwitch = self.userId != nil && self.userId != userId
        if isAccountSwitch, let container = modelContainer {
            AppLog.auth.info("Account switch — clearing previous user's local data")
            accountPreferenceLifecycle.suspend()
            await localDataCleaner.clearLocalData(container: container, reason: accountSwitchReason)
        }
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
