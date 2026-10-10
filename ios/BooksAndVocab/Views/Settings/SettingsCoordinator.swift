import Foundation
import SwiftData
import os

@MainActor
protocol SettingsSyncPersisting: AnyObject {
    func save(container: ModelContainer) throws
}

@MainActor
final class ModelContextSettingsSyncPersistence: SettingsSyncPersisting {
    func save(container: ModelContainer) throws {
        try container.mainContext.save()
    }
}

typealias SettingsSyncService = any BackgroundSyncing & HealthChecking & QuotaServing

private struct SettingsResetIncompleteError: LocalizedError {
    let snapshot: SettingsResetLifecycle.Snapshot

    var errorDescription: String? {
        L10n.string("重設完成狀態無法確認")
    }
}

private struct SettingsConfigurationPayloadError: LocalizedError {
    var errorDescription: String? {
        L10n.string("伺服器設定資料格式無法確認")
    }
}

@MainActor protocol SettingsCoordinating: AnyObject, Observable {
    var showSubscriptionPaywall: Bool { get set }
    var connectionPulse: Bool { get }
    var iconBreathing: Bool { get }
    var showDeleteAccountConfirm: Bool { get set }
    var isDeletingAccount: Bool { get }
    var deleteAccountError: String? { get }
    var configurationIssue: SettingsConfigurationIssue? { get }
    var resetLifecycle: SettingsResetLifecycle? { get }
    var translationSourceLang: TranslationLanguage { get set }
    var translationTargetLang: TranslationLanguage { get set }
    func handleAppear()
    func loadData(authManager: any AuthManaging, kgService: any HealthChecking & UserConfigFetching) async
    func requestDeleteAccount()
    func clearDeleteAccountError()
    func presentSubscriptionPaywall()
    func deleteAccount(authManager: any AuthManaging, kgService: any KGServing, modelContext: ModelContext) async
    func readResetSnapshot(
        authManager: any AuthManaging,
        modelContext: ModelContext
    ) -> SettingsResetLifecycle.Snapshot
    func resetLocalData(
        authManager: any AuthManaging,
        kgService: any LocalDataResetting & UserConfigServing,
        modelContext: ModelContext,
        acknowledgeUnsyncedLoss: Bool
    ) async
    func updateTranslationLanguage(source: TranslationLanguage, target: TranslationLanguage, authManager: any AuthManaging, kgService: any KGServing, toastCoordinator: AppToastCoordinator) async -> Bool
}

@Observable @MainActor
final class SettingsCoordinator: SettingsCoordinating {
    var showSubscriptionPaywall = false
    var connectionPulse = false
    var iconBreathing = false
    var showDeleteAccountConfirm = false
    var isDeletingAccount = false
    private(set) var syncLifecycle: SettingsSyncLifecycle = .idle
    private(set) var syncAttempt = 0
    private(set) var syncDataOutcome: SettingsSyncDataOutcome = .none
    private(set) var syncMessage: String?
    private(set) var syncEvidence: SettingsSyncLifecycleEvidence?
    var isManualLoggingIn = false
    var deleteAccountError: String?
    var configurationIssue: SettingsConfigurationIssue? = nil
    var resetLifecycle: SettingsResetLifecycle?
    /// Auth identity that produced `resetLifecycle`, so another account never
    /// inherits that account's terminal card or stale before-snapshot.
    private var resetOwnerUserID: String?
    var manualLoginUserId = ""
    var debugLocalServerURL = ""
    var observationPreviewLines: [String] = []
    var observationTotalCount = 0
    var translationSourceLang: TranslationLanguage = TranslationLanguage.currentSource
    var translationTargetLang: TranslationLanguage = TranslationLanguage.currentTarget
    /// Bumps whenever the Settings surface crosses an auth identity boundary.
    /// In-flight resync work is not structurally cancellable at the service
    /// boundary, so its late events must be rejected by this generation too.
    private var accountGeneration = 0
    /// Owner token for the currently running resync. Account generation alone
    /// protects identity changes; this token also prevents an older round's
    /// defer from clearing the flag belonging to a newer round.
    private var resyncRequestID = 0
    /// The Settings UI owns the foreground resync task so an account boundary
    /// can cancel the old round instead of merely ignoring its final state.
    /// A stale task must not keep polling for the shared sync lane and then
    /// perform writes after the next account has appeared.
    private var activeResyncTask: Task<Void, Never>?
    private var activeResyncTaskID = 0
    /// 這一輪同步的逐步進度。生命週期由 `syncLifecycle` 單一擁有，避免
    /// 進行中狀態與終態不另外漂移成兩份真相。
    private var reviewClockMutation = SettingsMutationGeneration()
    private var reviewModeMutation = SettingsMutationGeneration()
    /// Translation uses the same optimistic-write rollback contract as the
    /// review groups; this generation also invalidates a delayed failure when
    /// the Settings surface crosses an account boundary.
    private var translationMutation = SettingsMutationGeneration()
    let syncProgress = SyncProgressStore()
    private let resetStateStore: any SettingsResetStorePort
    private var settingsSyncService: SettingsSyncService?
    private let syncPersistence: any SettingsSyncPersisting
    /// The only seam through which this coordinator moves the process-wide
    /// `TranslationLanguage` account namespace. Tests inject a no-op so a
    /// Settings suite never flips the namespace under `TranslationLanguageTests`
    /// when parallel testing is on (#2117).
    private let translationLifecycle: any AccountPreferenceLifecycle
#if DEBUG
    private var settingsSyncFixtureSummary: SettingsFixtureSeed.SyncSummary?
    private var settingsSyncFixtureEvidenceSessionID: Int? = nil
#endif

    init(
        settingsSyncService: SettingsSyncService? = nil,
        syncPersistence: (any SettingsSyncPersisting)? = nil,
        resetStateStore: (any SettingsResetStorePort)? = nil,
        translationLifecycle: (any AccountPreferenceLifecycle)? = nil
    ) {
        // A default argument is evaluated before entering this @MainActor
        // initializer. Constructing the @MainActor persistence adapter there
        // is therefore a compile-time isolation violation. Resolve the default
        // after entering the actor instead of weakening the adapter's isolation.
        self.syncPersistence = syncPersistence ?? ModelContextSettingsSyncPersistence()
        self.resetStateStore = resetStateStore ?? LiveSettingsResetStore()
        self.translationLifecycle = translationLifecycle ?? TranslationAccountPreferenceLifecycle()

#if DEBUG
        var resolvedService = settingsSyncService
        var resolvedFixtureSummary: SettingsFixtureSeed.SyncSummary?
        if resolvedService == nil,
           FixtureDatasetStore.activeSettingsFixtureID == .syncTerminalErrorRetrySuccess,
           let fixtureID = FixtureDatasetStore.activeSettingsFixtureID {
            let seed = FixtureDatasetStore.requireSettingsSeed(for: fixtureID)
            guard let summary = seed.syncSummary else {
                preconditionFailure("UI World settings.\(fixtureID.rawValue) must declare syncSummary")
            }
            resolvedFixtureSummary = summary
            let transport = SettingsSyncFixtureTransport(summary: summary)
            resolvedService = KGService(
                transport: transport,
                connectivityGate: FixedConnectivityGate(isConnected: summary.isConnected)
            )
            settingsSyncFixtureEvidenceSessionID = transport.evidenceSessionID
        }
        self.settingsSyncService = resolvedService
        self.settingsSyncFixtureSummary = resolvedFixtureSummary
#else
        self.settingsSyncService = settingsSyncService
#endif

        #if DEBUG
        debugLocalServerURL = KGService.getDebugLocalServerURL()
        #endif
    }

    func handleAppear() {
        iconBreathing = true
        refreshObservationPreview()
    }

    /// Clear transient UI owned by the previous auth identity before loading
    /// the next one. Persistent preferences and server-backed settings are
    /// reloaded by `loadData`; only the leaf sync presentation belongs here.
    func resetForAccountBoundary(authManager: (any AuthManaging)? = nil) {
        if let authManager {
            reconcileResetLifecycle(currentUserID: authenticatedUserID(authManager))
        }
        activeResyncTask?.cancel()
        activeResyncTask = nil
        activeResyncTaskID &+= 1
        accountGeneration &+= 1
        resyncRequestID &+= 1
        _ = reviewClockMutation.begin()
        _ = reviewModeMutation.begin()
        _ = translationMutation.begin()
        ReviewSettingsStore.shared.suspendForAccountBoundary()
        ActiveNotebookStore.shared.suspendForAccountBoundary()
        translationLifecycle.suspend()
        translationSourceLang = TranslationLanguage.currentSource
        translationTargetLang = TranslationLanguage.currentTarget
        configurationIssue = nil
        // The generation/request tokens make any old async round stale; the
        // presentation state must be reset as well, otherwise a stale
        // `.syncing` lifecycle blocks the newly authenticated account at the
        // `isInFlight` guard and the next resync can never start.
        _ = syncLifecycle.reset()
        syncAttempt = 0
        syncDataOutcome = .none
        syncMessage = nil
        syncEvidence = nil
#if DEBUG
        if settingsSyncFixtureSummary != nil {
            // The old fixture transport may still finish after this boundary.
            // Drop its service and forget its evidence session so late events
            // cannot contaminate the newly authenticated account's proof. The
            // store is session-partitioned; do not globally clear it here.
            settingsSyncService = nil
            settingsSyncFixtureSummary = nil
            settingsSyncFixtureEvidenceSessionID = nil
        }
#endif
        syncProgress.reset()
    }

    /// A different signed-in account drops the previous account's reset card.
    /// A logout keeps it (the signed-out surface does not render it) but
    /// releases ownership, so any later sign-in, even the same account, starts
    /// from a fresh snapshot.
    private func reconcileResetLifecycle(currentUserID: String?) {
        guard resetLifecycle != nil else {
            resetOwnerUserID = nil
            return
        }
        guard let currentUserID else {
            resetOwnerUserID = nil
            return
        }
        if resetOwnerUserID != currentUserID {
            resetLifecycle = nil
            resetOwnerUserID = nil
        }
    }

    func loadData(
        authManager: any AuthManaging,
        kgService: any HealthChecking & UserConfigFetching
    ) async {
        let requestGeneration = accountGeneration
        let requestedUserId = authManager.userId
        activateAccountPreferences(for: authenticatedAccountID(authManager))
        refreshObservationPreview()
        await kgService.healthCheck()
        guard acceptsAccountRequest(
            generation: requestGeneration,
            requestedUserID: requestedUserId,
            authManager: authManager
        ) else { return }
        connectionPulse.toggle()

        guard authManager.isLoggedIn,
              !authManager.isDemoMode,
              let requestedUserId
        else {
            configurationIssue = nil
            return
        }

        do {
            let config = try await kgService.fetchUserConfig()
            // A request started for account A may finish after the UI has
            // crossed to account B. Never project that response into B.
            guard acceptsAccountRequest(
                generation: requestGeneration,
                requestedUserID: requestedUserId,
                authManager: authManager
            ), SettingsRemoteConfigPolicy.fetchDisposition(
                outcome: .success,
                isCancelled: Task.isCancelled,
                isLoggedIn: authManager.isLoggedIn,
                isDemoMode: authManager.isDemoMode,
                requestedUserID: requestedUserId,
                currentUserID: authManager.userId
            ) == .apply else { return }
            guard applyServerTranslationConfig(config.translation),
                  applyServerReviewClock(config.review_clock),
                  applyServerReviewMode(config.review_mode),
                  applyServerAutoLink(config.auto_link)
            else {
                throw SettingsConfigurationPayloadError()
            }
            applyServerActiveNotebook(config.vocab_ui, authManager: authManager)
            configurationIssue = nil
        } catch {
            guard acceptsAccountRequest(
                generation: requestGeneration,
                requestedUserID: requestedUserId,
                authManager: authManager
            ), SettingsRemoteConfigPolicy.fetchDisposition(
                outcome: .failure,
                isCancelled: Task.isCancelled,
                isLoggedIn: authManager.isLoggedIn,
                isDemoMode: authManager.isDemoMode,
                requestedUserID: requestedUserId,
                currentUserID: authManager.userId
            ) == .preserveLocalValues else { return }
            // Keep the local/iCloud value visible, but make the unavailable
            // server projection explicit instead of presenting a default as
            // if the live fetch had succeeded.
            configurationIssue = .init(
                surfaces: [.other, .translation],
                operation: .fetch,
                message: L10n.string("設定同步失敗，已保留目前本機值，請重試。")
            )
            AppLog.kg.warning("fetchUserConfig failed: \(error.localizedDescription)")
        }
    }

    /// Reconcile server-provided translation config with the local LWW cache.
    /// The model owns the timestamp comparison; a stale server response is a
    /// valid no-op rather than a malformed configuration.
    private func applyServerTranslationConfig(_ translation: KGTranslationConfig?) -> Bool {
        guard let translation else { return true }
        guard let ts = translation.updated_at else { return true }
        guard let src = translation.source_lang,
              let srcLang = TranslationLanguage(rawValue: src),
              let tgt = translation.target_lang,
              let tgtLang = TranslationLanguage(rawValue: tgt)
        else { return false }

        applyServerTranslationIfNewer(srcLang: srcLang, tgtLang: tgtLang, ts: ts)
        return true
    }

    private func applyServerTranslationIfNewer(
        srcLang: TranslationLanguage,
        tgtLang: TranslationLanguage,
        ts: TimeInterval
    ) {
        guard TranslationLanguage.applyServer(source: srcLang, target: tgtLang, serverUpdatedAt: ts) else { return }
        translationSourceLang = srcLang
        translationTargetLang = tgtLang
    }

    /// Reconcile the server vocab-ui projection only for a concrete KG account.
    /// Demo/guest sessions must not apply a server cursor to the local account.
    private func applyServerActiveNotebook(
        _ vocabUI: KGVocabUIConfig?,
        authManager: any AuthManaging
    ) {
        guard authManager.isLoggedIn,
              !authManager.isDemoMode,
              authManager.userId != nil,
              let vocabUI,
              let ts = vocabUI.updated_at,
              !vocabUI.active_notebook_id.isEmpty
        else { return }

        _ = ActiveNotebookStore.shared.syncActiveNotebookFromServer(
            ActiveNotebookState(activeNotebookId: vocabUI.active_notebook_id, updatedAt: ts)
        )
    }

    /// Reconcile server pause-clock with the local LWW timestamp. A stale server
    /// response is a valid no-op; malformed pause anchors remain configuration errors.
    private func applyServerReviewClock(_ clock: KGReviewClockConfig?) -> Bool {
        guard let clock else { return true }
        let store = ReviewSettingsStore.shared
        let pausedAt: Date?
        if let rawPausedAt = clock.paused_at {
            guard let parsedPausedAt = AppDateFormatters.parseISO8601(rawPausedAt) else {
                return false
            }
            pausedAt = parsedPausedAt
        } else {
            pausedAt = nil
        }
        _ = store.applyServerPauseState(
            isPaused: clock.is_paused,
            pausedAt: clock.is_paused ? pausedAt : nil,
            updatedAt: clock.updated_at
        )
        return true
    }

    /// Reconcile server review-mode with the local LWW timestamp. A stale server
    /// response is a valid no-op. The backend snake_case payload maps to one
    /// atomic `ReviewModeState` before the model applies it.
    /// 後端 snake_case wire(`KGReviewModeConfig`)→ iOS `ReviewModeState` 的轉換在此。
    private func applyServerReviewMode(_ mode: KGReviewModeConfig?) -> Bool {
        guard let mode else { return true }
        let store = ReviewSettingsStore.shared
        guard let reviewMode = ReviewSettingsMode(rawValue: mode.mode) else {
            return false
        }
        _ = store.applyServerModeState(
            ReviewModeState(
                mode: reviewMode,
                customInitialIntervalHours: mode.custom_initial_interval_hours,
                customRememberedMultiplier: mode.custom_remembered_multiplier,
                customForgotMultiplier: mode.custom_forgot_multiplier,
                customMinimumIntervalHours: mode.custom_minimum_interval_hours,
                customMaximumIntervalHours: mode.custom_maximum_interval_hours,
                updatedAt: mode.updated_at
            )
        )
        return true
    }

    /// Reconcile server auto-link 開關與本地快取。與 translation / review_* 的
    /// cold-start-only 政策不同:auto_link 是新 group、無 iCloud KV 層與歷史包袱,
    /// 直接走真 LWW(store.applyServer 內比較 updated_at,server 較新才套)。
    private func applyServerAutoLink(_ autoLink: KGAutoLinkConfig?) -> Bool {
        guard let autoLink else { return true }
        AutoLinkSettingsStore.shared.applyServer(
            enabled: autoLink.enabled,
            updatedAt: autoLink.updated_at
        )
        return true
    }

    /// 切換自動連結:樂觀寫本地,登入則 push 後端;push 失敗 rollback(含原時戳,
    /// 避免 rollback 被 LWW 當成新寫入)。回 true=已存(或免存的 guest),false=遠端失敗。
    @discardableResult
    func updateAutoLink(
        enabled: Bool,
        autoLinkStore: AutoLinkSettingsStore,
        authManager: any AuthManaging,
        kgService: any KGServing,
        toastCoordinator: AppToastCoordinator
    ) async -> Bool {
        let prevEnabled = autoLinkStore.isEnabled
        let prevUpdatedAt = autoLinkStore.updatedAt

        autoLinkStore.setEnabled(enabled)
        PerfLog.settings.mark("autoLink.toggled", "enabled=\(enabled)")

        guard authManager.isLoggedIn else { return true }

        do {
            _ = try await kgService.updateAutoLinkConfig(
                KGAutoLinkConfig(enabled: enabled, updated_at: autoLinkStore.updatedAt)
            )
            return true
        } catch {
            autoLinkStore.restore(enabled: prevEnabled, updatedAt: prevUpdatedAt)
            reportConfigSaveFailure(
                error,
                label: "updateAutoLinkConfig",
                surfaces: [.other],
                toastCoordinator: toastCoordinator
            )
            return false
        }
    }

    /// 切換複習時鐘暫停:樂觀寫本地+iCloud,登入則 push 後端;push 失敗 rollback 三層
    /// (對標 updateTranslationLanguage)。回 true=已存(或免存的 guest),false=遠端失敗。
    @discardableResult
    func updateReviewClock(
        isPaused: Bool,
        previousSnapshot: PauseClockState? = nil,
        reviewSettingsStore: ReviewSettingsStore,
        authManager: any AuthManaging,
        kgService: any KGServing,
        toastCoordinator: AppToastCoordinator
    ) async -> Bool {
        let requestGeneration = accountGeneration
        let requestedUserID = authenticatedUserID(authManager)
        let mutation = reviewClockMutation.begin()
        let snapshot = previousSnapshot ?? reviewSettingsStore.pauseClockSnapshot

        if previousSnapshot == nil {
            var s = reviewSettingsStore.settings
            if isPaused { s.pauseProgress() } else { s.resumeProgress() }
            reviewSettingsStore.update(s)
        }
        // Semantic perf mark: the optimistic local write is the moment the pause
        // state becomes effective for the UI (backend push is best-effort after).
        PerfLog.settings.mark("reviewClock.pause", "isPaused=\(isPaused)")

        guard authManager.isLoggedIn else { return true }

        let newSnapshot = reviewSettingsStore.pauseClockSnapshot
        let pausedAtISO = newSnapshot.pausedAt.map { AppDateFormatters.iso8601.string(from: $0) }
        do {
            _ = try await kgService.updateReviewClockConfig(
                KGReviewClockConfig(
                    is_paused: isPaused,
                    paused_at: pausedAtISO,
                    updated_at: newSnapshot.updatedAt
                )
            )
            return true
        } catch {
            guard acceptsAccountRequest(
                generation: requestGeneration,
                requestedUserID: requestedUserID,
                authManager: authManager
            ), SettingsRemoteConfigPolicy.acceptsMutationFailure(
                token: mutation,
                currentGeneration: reviewClockMutation.current
            ) else {
                AppLog.kg.debug("Ignoring stale review-clock failure")
                return true
            }
            reviewSettingsStore.restorePauseState(snapshot)
            reportConfigSaveFailure(
                error,
                label: "updateReviewClockConfig",
                surfaces: [.other],
                toastCoordinator: toastCoordinator
            )
            return false
        }
    }

    /// 更新複習模式 + 自訂 SRS 參數:樂觀寫本地+iCloud,登入則 push 後端;push 失敗 rollback
    /// 三層(對標 updateReviewClock)。回 true=已存(或免存的 guest),false=遠端失敗。
    /// iOS `ReviewSettings`(camelCase customParams)→ 後端 snake_case wire 的轉換在此。
    @discardableResult
    func updateReviewMode(
        _ newSettings: ReviewSettings,
        previousSnapshot: ReviewModeState? = nil,
        reviewSettingsStore: ReviewSettingsStore,
        authManager: any AuthManaging,
        kgService: any KGServing,
        toastCoordinator: AppToastCoordinator
    ) async -> Bool {
        let requestGeneration = accountGeneration
        let requestedUserID = authenticatedUserID(authManager)
        let mutation = reviewModeMutation.begin()
        let snapshot = previousSnapshot ?? reviewSettingsStore.reviewModeSnapshot
        if previousSnapshot == nil {
            reviewSettingsStore.update(newSettings)
        }
        PerfLog.settings.mark("reviewMode.changed", "mode=\(newSettings.mode.rawValue)")

        guard authManager.isLoggedIn else { return true }

        let newSnapshot = reviewSettingsStore.reviewModeSnapshot
        do {
            _ = try await kgService.updateReviewModeConfig(
                KGReviewModeConfig(
                    mode: newSnapshot.mode.rawValue,
                    custom_initial_interval_hours: newSnapshot.customInitialIntervalHours,
                    custom_remembered_multiplier: newSnapshot.customRememberedMultiplier,
                    custom_forgot_multiplier: newSnapshot.customForgotMultiplier,
                    custom_minimum_interval_hours: newSnapshot.customMinimumIntervalHours,
                    custom_maximum_interval_hours: newSnapshot.customMaximumIntervalHours,
                    updated_at: newSnapshot.updatedAt
                )
            )
            return true
        } catch {
            guard acceptsAccountRequest(
                generation: requestGeneration,
                requestedUserID: requestedUserID,
                authManager: authManager
            ), SettingsRemoteConfigPolicy.acceptsMutationFailure(
                token: mutation,
                currentGeneration: reviewModeMutation.current
            ) else {
                AppLog.kg.debug("Ignoring stale review-mode failure")
                return true
            }
            reviewSettingsStore.restoreModeState(snapshot)
            reportConfigSaveFailure(
                error,
                label: "updateReviewModeConfig",
                surfaces: [.other],
                toastCoordinator: toastCoordinator
            )
            return false
        }
    }

    private func reportConfigSaveFailure(
        _ error: Error,
        label: String,
        surfaces: Set<SettingsConfigurationIssue.Surface>,
        toastCoordinator: AppToastCoordinator
    ) {
        configurationIssue = .init(
            surfaces: surfaces,
            operation: .save,
            message: L10n.string("設定儲存失敗，已還原本機值，請重試。")
        )
        toastCoordinator.error("設定儲存失敗".localized)
        AppLog.kg.error("\(label) failed: \(error.localizedDescription)")
    }

    func refreshObservationPreview() {
        let preview = AppObservationStore.shared.preview()
        observationPreviewLines = preview.entries.map(\.previewLine)
        observationTotalCount = preview.totalCount
    }

    func requestDeleteAccount() {
        showDeleteAccountConfirm = true
    }

    func clearDeleteAccountError() {
        deleteAccountError = nil
    }

    func presentSubscriptionPaywall() {
        showSubscriptionPaywall = true
    }

    func deleteAccount(
        authManager: any AuthManaging,
        kgService: any KGServing,
        modelContext: ModelContext
    ) async {
        guard authManager.isLoggedIn, !isDeletingAccount else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        do {
            try await kgService.deleteAccount()
            // 成功後關閉 confirm sheet，再觸發 logout（logout 會清理 Settings 畫面）
            showDeleteAccountConfirm = false
            authManager.logout(modelContainer: modelContext.container, reason: LocalDataCleanerService.deleteAccountReason)
        } catch {
            deleteAccountError = L10n.format("無法刪除帳號：%@", SyncFailurePresentation.reason(for: error))
            // 失敗時關閉 confirm sheet，讓使用者看到錯誤 alert
            showDeleteAccountConfirm = false
        }
    }

    /// Reset only this account's local vocabulary and Settings-owned preferences.
    /// The signed-in session remains visible so the account danger group can show
    /// the terminal boundary instead of disappearing during logout cleanup.
    func resetLocalData(
        authManager: any AuthManaging,
        kgService: any LocalDataResetting & UserConfigServing,
        modelContext: ModelContext,
        acknowledgeUnsyncedLoss: Bool = false
    ) async {
        guard authManager.isLoggedIn,
              resetLifecycle?.phase != .resetting
        else { return }

        let requestGeneration = accountGeneration
        let ownerUserID = authenticatedUserID(authManager)
        // The unsynced gate always reads fresh: rows created after a failed
        // attempt must be acknowledged too. Only a failed retry keeps its
        // original `before` for the before/after display.
        let fresh = readResetSnapshot(authManager: authManager, modelContext: modelContext)
        let lifecycleBefore = resetLifecycle?.phase == .failed
            ? (resetLifecycle?.before ?? fresh)
            : fresh
        guard fresh.isReadable else {
            resetLifecycle = .preReset(before: fresh)
            resetOwnerUserID = ownerUserID
            return
        }
        if fresh.requiresUnsyncedAcknowledgement, !acknowledgeUnsyncedLoss {
            resetLifecycle = .blockedByUnsynced(before: fresh)
            resetOwnerUserID = ownerUserID
            return
        }
        let pending = SettingsResetLifecycle.preReset(before: lifecycleBefore).resetting()
        resetLifecycle = pending
        resetOwnerUserID = ownerUserID

        // Server first: a failed push aborts before any local mutation, so
        // there is nothing to roll back and a retry starts clean.
        if ownerUserID != nil {
            do {
                try await resetStateStore.pushDefaultPreferences(to: kgService)
            } catch {
                guard requestGeneration == accountGeneration else { return }
                AppLog.kg.error("Settings reset default-config push failed: \(error.localizedDescription)")
                resetLifecycle = pending.failed(
                    after: lifecycleBefore,
                    message: L10n.string("無法將預設設定同步到伺服器，請確認網路連線；本機資料未變動，請重試。")
                )
                return
            }
            guard requestGeneration == accountGeneration else { return }
        }

        do {
            try await kgService.clearLocalData(
                container: modelContext.container,
                reason: "settings_reset_local_data"
            )
            // Another account may own the preference namespaces by now.
            guard requestGeneration == accountGeneration else { return }
            resetStateStore.resetPreferences()
            let after = readResetSnapshot(authManager: authManager, modelContext: modelContext)
            guard after.isResetComplete else {
                throw SettingsResetIncompleteError(snapshot: after)
            }

            resetLifecycle = pending.succeeded(
                after: after,
                message: L10n.string("本機資料與設定已重設。")
            )
        } catch {
            guard requestGeneration == accountGeneration else { return }
            AppLog.kg.error("Settings local reset failed: \(error.localizedDescription)")
            let after: SettingsResetLifecycle.Snapshot
            if let incomplete = error as? SettingsResetIncompleteError {
                after = incomplete.snapshot
            } else {
                after = readResetSnapshot(authManager: authManager, modelContext: modelContext)
            }
            let message: String
            if after.localCardCountError != nil {
                message = L10n.string("本機資料重設失敗，清理結果無法讀取，請重試。")
            } else if !after.isResetComplete {
                message = L10n.string("本機資料重設未完成，仍有殘留資料，請重試。")
            } else {
                message = L10n.format("本機資料重設失敗：%@", error.localizedDescription)
            }
            resetLifecycle = pending.failed(
                after: after,
                message: message
            )
        }
    }

    func readResetSnapshot(
        authManager: any AuthManaging,
        modelContext: ModelContext
    ) -> SettingsResetLifecycle.Snapshot {
        resetStateStore.readSnapshot(authManager: authManager, modelContext: modelContext)
    }

    /// 回傳 true 代表已儲存（或免儲存的 guest 路徑），false 代表遠端 update 失敗。
    /// 失敗時除了回傳 false 也會顯示 toast，呼叫端可選擇額外 inline 反饋。
    /// 遠端失敗會 rollback UserDefaults / iCloud KV / in-memory state,避免
    /// 「本地已寫但 server / 其他裝置不知道」的分裂狀態。
    @discardableResult
    func updateTranslationLanguage(
        source: TranslationLanguage,
        target: TranslationLanguage,
        authManager: any AuthManaging,
        kgService: any KGServing,
        toastCoordinator: AppToastCoordinator
    ) async -> Bool {
        let requestGeneration = accountGeneration
        let requestedUserID = authenticatedUserID(authManager)
        let mutation = translationMutation.begin()
        // Snapshot previous values + their timestamps for rollback on remote failure.
        let prevSource = TranslationLanguage.currentSource
        let prevTarget = TranslationLanguage.currentTarget
        let prevSourceUpdatedAt = TranslationLanguage.sourceUpdatedAt
        let prevTargetUpdatedAt = TranslationLanguage.targetUpdatedAt

        translationSourceLang = source
        translationTargetLang = target
        TranslationLanguage.currentSource = source
        TranslationLanguage.currentTarget = target
        PerfLog.settings.mark("translation.changed", "source=\(source.rawValue) target=\(target.rawValue)")

        guard authManager.isLoggedIn else { return true }
        do {
            _ = try await kgService.updateTranslationConfig(
                KGTranslationConfig(
                    source_lang: source.rawValue,
                    target_lang: target.rawValue,
                    // 單一 group 時戳（設計 A）：source/target 剛由上方 setter 同刻寫入，
                    // 取兩者較新者作整組 LWW 時戳，push 給後端 vocab/web sync 用。
                    updated_at: [TranslationLanguage.sourceUpdatedAt, TranslationLanguage.targetUpdatedAt].compactMap { $0 }.max()
                )
            )
            return true
        } catch {
            // Rollback: restore values WITH their original timestamps so that
            // iCloud KV's LWW doesn't treat the rollback as "newer" than a
            // concurrent write from another device.
            guard acceptsAccountRequest(
                generation: requestGeneration,
                requestedUserID: requestedUserID,
                authManager: authManager
            ), SettingsRemoteConfigPolicy.acceptsMutationFailure(
                token: mutation,
                currentGeneration: translationMutation.current
            ) else {
                AppLog.kg.debug("Ignoring stale translation failure")
                return true
            }
            TranslationLanguage.restore(
                source: prevSource,
                sourceUpdatedAt: prevSourceUpdatedAt,
                target: prevTarget,
                targetUpdatedAt: prevTargetUpdatedAt
            )
            translationSourceLang = prevSource
            translationTargetLang = prevTarget
            reportConfigSaveFailure(
                error,
                label: "updateUserConfig (translation lang)",
                surfaces: [.translation],
                toastCoordinator: toastCoordinator
            )
            return false
        }
    }

    func handleManualLogin(authManager: any AuthManaging) {
        let id = manualLoginUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        // in-flight guard：login(customToken:) 現為 async，會 await clearLocalData；
        // 無 guard 時連點兩下會 spawn 兩個 Task，兩者都在第一個的 await 解開前讀到舊 userId
        // → 重複清理（第二次為 no-op 但多一次 BackgroundSyncActor purge）。
        guard !id.isEmpty, !isManualLoggingIn else { return }
        isManualLoggingIn = true
        Task {
            await authManager.login(customToken: id)
            isManualLoggingIn = false
        }
    }

    func dismissSyncStatus() {
        do {
            try syncLifecycle.transition(.dismiss)
        } catch {
            recordTransitionFailure(action: "dismiss", error: error)
        }
    }

    func resync(
        authManager: any AuthManaging,
        kgService: SettingsSyncService,
        modelContext: ModelContext
    ) async {
        guard authManager.isLoggedIn, !authManager.isDemoMode else { return }
        guard activeResyncTask == nil, !syncLifecycle.isInFlight else { return }

        activeResyncTaskID &+= 1
        let taskID = activeResyncTaskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performResync(
                authManager: authManager,
                kgService: kgService,
                modelContext: modelContext
            )
        }
        activeResyncTask = task
        await task.value
        if activeResyncTaskID == taskID {
            activeResyncTask = nil
        }
    }

    private func performResync(
        authManager: any AuthManaging,
        kgService: SettingsSyncService,
        modelContext: ModelContext
    ) async {
        // 資格 gate：demo 模式 `isLoggedIn == true` 但無真 token，同步會踩 `unauthorized`
        // → 誤彈「登入已過期」。與 `ExplicitSync` / 自動同步同政策：登出 / demo 一律 no-op。
        // （UI 已以 syncSummary 擋登出，此處 defense-in-depth 並補上 demo 漏洞。）
        guard authManager.isLoggedIn, !authManager.isDemoMode else { return }
        guard !syncLifecycle.isInFlight else { return }
        let requestGeneration = accountGeneration
        let requestUserID = authManager.userId
        resyncRequestID &+= 1
        let requestID = resyncRequestID

        let action: SettingsSyncLifecycle.Action
        if case .terminalError = syncLifecycle {
            action = .retry
        } else {
            action = .begin
        }
        do {
            try syncLifecycle.transition(action)
        } catch {
            recordTransitionFailure(action: "\(action)", error: error)
            refreshObservationPreview()
            return
        }

        syncAttempt += 1
        syncDataOutcome = .none
        syncMessage = nil
#if DEBUG
        syncPerfMarks = []
#endif
        markSync("settings.sync.lifecycle.started", "attempt=\(syncAttempt)")

        let activeSyncService = resolveSettingsSyncServiceIfNeeded() ?? kgService

        // 進度模型：宣告 backgroundSync 會跑的步驟 + 本函式自己收尾的那一列。
        // UI 必須先知道完整清單才畫得出「還沒輪到」的灰列與正確的進度條分母。
        syncProgress.begin(stepIDs: KGService.syncStepIDs() + [.status])

        // A fixture-backed retry can complete before SwiftUI renders the
        // intermediate `.running` state. Yield once and hold the declared
        // progress contract for a bounded frame so the progress panel is an
        // observable production state rather than a coalesced state mutation.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(200))

        // reporter 走 AsyncStream 而不是每個事件開一個 `Task { @MainActor in }`。
        // 後者**不保證順序**——事件從多條併行的腿發出，各自排進 MainActor 佇列後
        // 到達順序就散了，計數器會肉眼可見地彈回。store 內部雖有單調守衛擋著，
        // 但那是防線不是設計；`continuation.yield` 是 FIFO，讓「送出順序 = 套用
        // 順序」在正常路徑上就成立。
        let (events, continuation) = AsyncStream<SyncProgressEvent>.makeStream()
        let pump = Task { @MainActor [weak self, syncProgress] in
            for await event in events {
                guard let self,
                      self.isCurrentResync(
                          generation: requestGeneration,
                          requestID: requestID,
                          userID: requestUserID,
                          authManager: authManager
                      ) else {
                    break
                }
                syncProgress.apply(event)
            }
        }

        let outcome = await activeSyncService.backgroundSyncWhenAvailable(container: modelContext.container) { event in
            continuation.yield(event)
        }
        guard isCurrentResync(
            generation: requestGeneration,
            requestID: requestID,
            userID: requestUserID,
            authManager: authManager
        ) else {
            continuation.finish()
            await pump.value
            return
        }
        let saveSucceeded: Bool
        do {
            try syncPersistence.save(container: modelContext.container)
            saveSucceeded = true
            markSync("settings.sync.lifecycle.saveResult", "attempt=\(syncAttempt) result=success")
        } catch {
            saveSucceeded = false
            syncMessage = L10n.string("同步失敗")
            AppLog.kg.error("resync mainContext save failed: \(error.localizedDescription)")
            markSync("settings.sync.lifecycle.saveResult", "attempt=\(syncAttempt) result=failure")
        }

        // 額度與連線檢查併發。兩者都是唯讀 GET、彼此無依賴，序列跑純粹是多一趟
        // 往返的等待；它們寫的欄位互不相交（healthCheck → isConnected /
        // serverCardCount，fetchQuota → QuotaStore），所以這兩條併發是安全的。
        //
        // **但刻意不把它們再拉進 backgroundSync 一起三方併發。** 那時 `serverCardCount`
        // 會與 pull 撞在一起，而 `KGService` 是 `@Observable` 卻不是 `@MainActor`
        // ——為了省約 100ms 去換一個真實的 data race 不划算。這一輪真正的 6 秒在
        // podcast，那筆已經收掉了。
        continuation.yield(.started(.status))
        async let health: Void = activeSyncService.healthCheck()
        async let quota: Void = activeSyncService.fetchQuota()
        _ = await (health, quota)
        continuation.yield(.finished(.status, status: .done, detail: ""))

        continuation.finish()
        await pump.value

        guard isCurrentResync(
            generation: requestGeneration,
            requestID: requestID,
            userID: requestUserID,
            authManager: authManager
        ) else { return }

        // 終態取自這一輪自己的回報，**不是** `lastBackgroundSyncError`。那是四個
        // trigger 共用的全域欄位，對「被別的 round 佔著 claim 所以什麼都沒做」與
        // 「跑到一半被取消」這兩條路徑，它會讓面板宣稱 100% 完成。
        switch outcome {
        case .completed where saveSucceeded:
            syncDataOutcome = .complete
            syncProgress.finish(.completed)
            do {
                try syncLifecycle.transition(.succeed)
            } catch {
                recordTransitionFailure(action: "succeed", error: error)
            }
            markSync("settings.sync.lifecycle.serviceResult", "attempt=\(syncAttempt) result=completed")
        case .completed:
            syncDataOutcome = .partial
            syncProgress.finish(.failed)
            failSyncLifecycle(message: syncMessage ?? L10n.string("同步失敗"))
            markSync("settings.sync.lifecycle.serviceResult", "attempt=\(syncAttempt) result=saveFailure")
        case .failed:
            syncDataOutcome = dataOutcome(for: outcome)
            syncProgress.finish(.failed)
            failSyncLifecycle(message: syncMessage ?? syncFailureMessage())
            markSync("settings.sync.lifecycle.serviceResult", "attempt=\(syncAttempt) result=failed")
        case .didNotRun:
            syncDataOutcome = .none
            syncProgress.reset()
            do {
                try syncLifecycle.transition(.cancel)
            } catch {
                recordTransitionFailure(action: "cancel", error: error)
            }
            markSync("settings.sync.lifecycle.serviceResult", "attempt=\(syncAttempt) result=didNotRun")
        }

        markSync(
            "settings.sync.lifecycle.terminal",
            "attempt=\(syncAttempt) state=\(syncLifecycleName) data=\(syncDataOutcome.rawValue)"
        )
#if DEBUG
        syncEvidence = makeSyncEvidence(outcome: outcome, modelContext: modelContext)
#endif
        refreshObservationPreview()
    }

    private func isCurrentResync(
        generation: Int,
        requestID: Int,
        userID: String?,
        authManager: any AuthManaging
    ) -> Bool {
        SettingsRemoteConfigPolicy.acceptsResyncResult(
            request: SettingsRemoteConfigPolicy.ResyncRequest(
                accountGeneration: generation,
                requestID: requestID,
                userID: userID
            ),
            currentAccountGeneration: accountGeneration,
            currentRequestID: resyncRequestID,
            isCancelled: Task.isCancelled,
            isLoggedIn: authManager.isLoggedIn,
            isDemoMode: authManager.isDemoMode,
            currentUserID: authManager.userId
        )
    }

    private func authenticatedUserID(_ authManager: any AuthManaging) -> String? {
        guard authManager.isLoggedIn, !authManager.isDemoMode else { return nil }
        return authManager.userId
    }

    private func authenticatedAccountID(_ authManager: any AuthManaging) -> String? {
        AccountPreferenceNamespace.normalizedAccountID(authenticatedUserID(authManager))
    }

    private func activateAccountPreferences(for accountID: String?) {
        ReviewSettingsStore.shared.activateAccount(accountID)
        ActiveNotebookStore.shared.activateAccount(accountID)
        translationLifecycle.activate(accountID: accountID)
        translationSourceLang = TranslationLanguage.currentSource
        translationTargetLang = TranslationLanguage.currentTarget
    }

    private func acceptsAccountRequest(
        generation: Int,
        requestedUserID: String?,
        authManager: any AuthManaging
    ) -> Bool {
        guard generation == accountGeneration, !Task.isCancelled else { return false }
        let currentUserID = authManager.isLoggedIn && !authManager.isDemoMode
            ? authManager.userId
            : nil
        return currentUserID == requestedUserID
    }

    private func markSync(_ label: StaticString, _ detail: String) {
        PerfLog.sync.mark(label, detail)
#if DEBUG
        syncPerfMarks.append(SettingsSyncPerfRecord(label: label.description, detail: detail))
#endif
    }

    /// `SettingsView` can materialize its `@State` before the app's launch
    /// fixture router activates the requested Settings fixture. Resolve the
    /// fixture service at the first real sync action as well as in `init`, so
    /// early view construction cannot silently route this evidence flow to the
    /// production backend. The launch-argument fallback closes the other half
    /// of the startup race: if the view reaches the action before the router's
    /// activation is observable, re-use the canonical fixture router here.
    @MainActor
    private func resolveSettingsSyncServiceIfNeeded() -> SettingsSyncService? {
#if DEBUG
        guard settingsSyncFixtureSummary == nil else {
            return settingsSyncService
        }
        let fixtureID: SettingsFixtureID
        if let activeFixtureID = FixtureDatasetStore.activeSettingsFixtureID {
            guard activeFixtureID == .syncTerminalErrorRetrySuccess else {
                return settingsSyncService
            }
            fixtureID = activeFixtureID
        } else if ProcessInfo.processInfo.arguments.contains(where: {
            $0.contains("-seedFixture:settings:\(SettingsFixtureID.syncTerminalErrorRetrySuccess.rawValue)")
        }) || ProcessInfo.processInfo.environment["KG_SETTINGS_SYNC_FIXTURE"] ==
            SettingsFixtureID.syncTerminalErrorRetrySuccess.rawValue {
            FixtureDatasetStore.activateSettingsFixture(.syncTerminalErrorRetrySuccess)
            fixtureID = .syncTerminalErrorRetrySuccess
        } else {
            return settingsSyncService
        }
        let seed = FixtureDatasetStore.requireSettingsSeed(for: fixtureID)
        guard let summary = seed.syncSummary else {
            preconditionFailure("UI World settings.\(fixtureID.rawValue) must declare syncSummary")
        }
        settingsSyncFixtureSummary = summary
        let transport = SettingsSyncFixtureTransport(summary: summary)
        settingsSyncService = KGService(
            transport: transport,
            connectivityGate: FixedConnectivityGate(isConnected: summary.isConnected)
        )
        settingsSyncFixtureEvidenceSessionID = transport.evidenceSessionID
        return settingsSyncService
#else
        // Release has no fixture-only state; preserve dependency injection for
        // tests while keeping production on the caller-provided KG service.
        return settingsSyncService
#endif
    }

#if DEBUG
    private var syncPerfMarks: [SettingsSyncPerfRecord] = []

    private func makeSyncEvidence(
        outcome: SyncRoundOutcome,
        modelContext: ModelContext
    ) -> SettingsSyncLifecycleEvidence {
        let words: [String]
        do {
            words = try modelContext.fetch(FetchDescriptor<VocabularyEntry>())
                .map(\.word)
                .sorted()
        } catch {
            preconditionFailure("Settings sync evidence read-back failed: \(error)")
        }

        let previousResidual = syncEvidence?.residualWords ?? []
        let residualWords = outcome == .failed ? words : previousResidual
        let readBackWords = syncDataOutcome == .complete ? words : []
        let transportEvents = settingsSyncFixtureEvidenceSessionID.map {
            SettingsSyncFixtureEvidenceStore.shared.snapshot(sessionID: $0)
        } ?? []
        return SettingsSyncLifecycleEvidence(
            lifecycle: syncLifecycleName,
            attempt: syncAttempt,
            dataOutcome: syncDataOutcome,
            residualWords: residualWords,
            readBackWords: readBackWords,
            transportEvents: transportEvents,
            perfMarks: syncPerfMarks
        )
    }
#endif

    private func failSyncLifecycle(message: String) {
        syncMessage = message
        do {
            try syncLifecycle.transition(.fail(message: message))
        } catch {
            recordTransitionFailure(action: "fail", error: error)
        }
    }

    private func recordTransitionFailure(action: String, error: Error) {
        let message = L10n.string("同步失敗")
        syncMessage = message
        syncDataOutcome = .partial
        syncProgress.finish(.failed)
        if !syncLifecycle.isTerminal {
            // The state machine rejected the recovery transition. Keep the
            // production boundary fail-closed so a rejected transition cannot
            // leave the presenter claiming an in-flight or successful round.
            syncLifecycle = .terminalError(message: message)
        }
        AppLog.kg.error(
            "Settings sync transition rejected action=\(action): \(String(describing: error), privacy: .public)"
        )
        markSync(
            "settings.sync.lifecycle.transitionFailure",
            "action=\(action) error=\(String(describing: error))"
        )
    }

    private func dataOutcome(for outcome: SyncRoundOutcome) -> SettingsSyncDataOutcome {
        guard outcome == .failed else { return .none }
        let pullFinished = syncProgress.steps.contains {
            $0.id == SyncStepID.pull.rawValue && $0.status == .done
        }
        return pullFinished ? .partial : .none
    }

    private var syncLifecycleName: String {
        switch syncLifecycle {
        case .idle: return "idle"
        case .syncing: return "syncing"
        case .terminalSuccess: return "terminalSuccess"
        case .terminalError: return "terminalError"
        case .retry: return "retry"
        case .dismissed: return "dismissed"
        }
    }

    private func syncFailureMessage() -> String {
        #if DEBUG
        if let fixtureMessage = settingsSyncFixtureSummary?.message, !fixtureMessage.isEmpty {
            return fixtureMessage
        }
        #endif
        return syncProgress.steps.first(where: { $0.status == .error && !$0.detail.isEmpty })?.detail
            ?? L10n.string("同步失敗")
    }

    #if DEBUG
    func useProductionBackend(
        authManager: any AuthManaging,
        kgService: any KGServing
    ) async {
        KGService.useProductionServer()
        debugLocalServerURL = KGService.getDebugLocalServerURL()
        await loadData(authManager: authManager, kgService: kgService)
        refreshObservationPreview()
    }

    func useLocalBackend(
        authManager: any AuthManaging,
        kgService: any KGServing
    ) async {
        KGService.setDebugLocalServerURL(debugLocalServerURL)
        KGService.useLocalServer()
        debugLocalServerURL = KGService.getDebugLocalServerURL()
        await loadData(authManager: authManager, kgService: kgService)
        refreshObservationPreview()
    }
    #endif
}
