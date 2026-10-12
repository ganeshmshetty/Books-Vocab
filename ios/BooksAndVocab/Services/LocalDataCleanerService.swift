import Foundation
import SwiftData

final class LocalDataCleanerService: LocalDataClearing {
    /// SettingsCoordinator 以此 reason 呼叫 logout，觸發帳號偏好整體 purge。
    static let deleteAccountReason = "delete_account"

    typealias RowWipe = @Sendable (ModelContainer, String) async throws -> Void

    /// Owner (userId, "" when unknown) of the rows a failed wipe left in the store. Its presence is the
    /// pending-wipe marker. It outlives the process, and sign-in refuses to complete while it is set,
    /// so no account can write into those rows before the wipe succeeds (#2717).
    static let pendingWipeOwnerKey = "kg_pending_local_wipe_owner"

    private let wipeRows: RowWipe
    private let defaults: UserDefaults
    private let derivedRoots: DerivedLocalStateRoots

    init(
        wipeRows: @escaping RowWipe = { container, reason in
            try await BackgroundSyncActor(modelContainer: container).clearUserData(reason: reason)
        },
        defaults: UserDefaults = .standard,
        derivedRoots: DerivedLocalStateRoots = .production
    ) {
        self.wipeRows = wipeRows
        self.defaults = defaults
        self.derivedRoots = derivedRoots
    }

    static func persistedPendingWipeOwner(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: pendingWipeOwnerKey)
    }

    var pendingLocalWipeOwner: String? { Self.persistedPendingWipeOwner(defaults: defaults) }

    func clearLocalData(container: ModelContainer, reason: String, deletedAccountID: String?) async {
        _ = await clearLocalDataReportingFailure(
            container: container,
            reason: reason,
            owner: "",
            deletedAccountID: deletedAccountID
        )
    }

    /// `false` = the row wipe failed: the failure is reported, sync cursors are kept and the pending
    /// wipe is recorded under `owner` so `retryPendingLocalWipe` can finish the job.
    func clearLocalDataReportingFailure(
        container: ModelContainer,
        reason: String,
        owner: String,
        deletedAccountID: String?
    ) async -> Bool {
        AppLog.sync.info("clearLocalData requested. reason=\(reason)")
        let wiped = await wipeRowsRecordingFailure(container: container, reason: reason, owner: owner)
        if wiped { clearSyncState() }
        ActiveNotebookStore.shared.clear()
        defaults.removeObject(forKey: NotebookFilter.storageKey)
        // iCloud KVS 的 CloudPreferencesSync 只能在 main thread 存取（見該類別宣告）。
        await MainActor.run {
            Self.purgeAccountPreferences(
                deletedAccountID: deletedAccountID,
                defaults: UserDefaults.standard,
                cloud: CloudPreferencesSync.shared
            )
        }
        await Self.purgeDerivedLocalState(roots: derivedRoots)
        return wiped
    }

    /// On-disk locations the derived-state purge touches. Production uses `.production`; tests inject
    /// temp dirs so no run can reach the real Documents tree.
    struct DerivedLocalStateRoots: Sendable {
        var notebookCovers: URL?
        var podcastCovers: URL?
        var podcastDownloads: URL?

        static let production = DerivedLocalStateRoots(notebookCovers: nil, podcastCovers: nil, podcastDownloads: nil)
    }

    /// The state every reset path drops besides SwiftData rows, sync cursors and account preferences:
    /// the review snapshot, Add Link jobs, quota, podcast/notebook files, the iCloud directory cache.
    /// Logout, account switch (both via `clearLocalDataReportingFailure`) and Settings reset
    /// (`KGService.clearLocalData`) all call it, so the step list cannot drift between them (#2721).
    static func purgeDerivedLocalState(roots: DerivedLocalStateRoots = .production) async {
        // Today-review session snapshots are keyed per-user in a single
        // UserDefaults blob. Logout and account-switch both route through here,
        // so clear every user's snapshot to prevent a stale session from being
        // restored on re-login (or surviving until the 7-day maxAge expiry).
        TodayReviewSessionSnapshotStore.clear(for: nil)
        // Pending Add Link creations persist the typed word and the operation keys of
        // the account that started them. Drop them (and cancel the live ones) so
        // neither a later account nor the previous one's re-login sees or resumes them.
        await MainActor.run { AddLinkCreationHub.shared.clearAll() }
        // QuotaStore is a process-wide singleton holding account A's remaining quota.
        // clearUserData drops SwiftData rows but never touches it, so after an
        // account-switch account B briefly sees A's quota number until the next
        // response header overwrites it. Reset on the main actor (where the
        // @Observable mutation is observed, matching KGService+Health's update hop).
        await MainActor.run { QuotaStore.shared.reset() }
        #if os(iOS)
        // Downloaded podcast .mp3s live on disk under Documents/podcast-downloads/,
        // not in SwiftData — clearUserData drops the rows but leaves the audio.
        // Purge the whole tree so a reused remoteId can't surface account A's
        // audio under account B after a switch (#726 follow-up).
        PodcastDownloadManager.purgeDownloads(root: roots.podcastDownloads ?? PodcastDownloadManager.downloadsRoot())
        // Downloaded podcast series covers live under Documents/podcast-covers/
        // (written by PodcastSyncService.cacheCoverIfNeeded), not in SwiftData.
        // Purge so a reused remoteId can't surface account A's cover under B.
        purgePodcastCovers(root: roots.podcastCovers ?? PodcastSyncService.coversRoot())
        // User-uploaded notebook covers live on disk under Documents/NotebookCovers/
        // (written by NotebookEditSheet), not in SwiftData. clearUserData drops the
        // Notebook rows but leaves the .jpg files as orphans, so they survive an
        // account-switch and accumulate on disk. Purge the whole tree (every cover
        // is necessarily orphaned once its owning row is gone). Books/Originals are
        // deliberately NOT touched here — book files have no server backing and
        // deleting them would permanently lose the user's library (#758 follow-up).
        purgeNotebookCovers(root: roots.notebookCovers ?? coversRoot())
        #endif
        // iCloud 目錄快取以 Apple ID 為準；帳號切換後須重取，否則路徑指向舊帳號容器。
        // 通知讓 ICloudDownloadManager 重設 fileStates + 重啟 NSMetadataQuery。
        Book.clearICloudDirectoryCache()
        NotificationCenter.default.post(name: .localUserDataDidClear, object: nil)
    }

    /// Finishes a pending wipe. The rows still belong to the pending owner only while nobody else is
    /// signed in: `signedInUserId` must be nil or that owner. Any other signed-in account may already
    /// hold unsynced rows, so the wipe is refused (fail closed) and the marker stays.
    func retryPendingLocalWipe(container: ModelContainer, signedInUserId: String?) async -> Bool {
        guard let owner = pendingLocalWipeOwner else { return true }
        guard signedInUserId == nil || signedInUserId == owner else {
            AppLog.sync.error("pending local wipe refused: a different account is signed in")
            return false
        }
        AppLog.sync.warning("retrying previously failed local wipe")
        guard await wipeRowsRecordingFailure(container: container, reason: "retry_pending_local_wipe", owner: owner) else {
            return false
        }
        clearSyncState()
        return true
    }

    /// Drops the marker of a wipe whose account switch was refused. The failed wipe committed nothing
    /// (one final save), so the still-signed-in account keeps its rows and sync cursors unchanged.
    func discardPendingLocalWipe() {
        defaults.removeObject(forKey: Self.pendingWipeOwnerKey)
    }

    private func wipeRowsRecordingFailure(container: ModelContainer, reason: String, owner: String) async -> Bool {
        do {
            try await wipeRows(container, reason)
            defaults.removeObject(forKey: Self.pendingWipeOwnerKey)
            return true
        } catch {
            AppLog.sync.error("clearUserData failed: \(error.localizedDescription)")
            AppCrashReporting.record(error, context: "kg.local.clear")
            defaults.set(owner, forKey: Self.pendingWipeOwnerKey)
            return false
        }
    }

    /// Only after the rows are really gone: a kept cursor beside surviving rows is what makes the
    /// retry safe, a cleared cursor beside surviving rows would hide them from the next sync.
    private func clearSyncState() {
        // 用 KGService.SyncKeys 常數，與 sync 路徑單一真相對齊（勿用 magic string）。
        defaults.removeObject(forKey: KGService.SyncKeys.incrementalBoundary)
        defaults.removeObject(forKey: KGService.SyncKeys.payloadVersion)
        // 漏清會讓 account-switch 後 B 沿用 A 的 review-event pull cursor，
        // incremental pull 可能漏抓 B 在該 cursor 之前的 review events。
        defaults.removeObject(forKey: KGService.SyncKeys.reviewEventPullBoundary)
        // 「上次同步時間」跨登出殘留會讓帳號 B 冷啟動看到 A 的 synced 時間（#2424）。
        KGService.persistLastSyncDate(nil, defaults: defaults)
    }

    /// 帳號偏好 purge（#2434 / #2556）。登出只丟 pre-account raw 已領養的本機副本（KVS raw
    /// 刻意保留，見 `ReviewCardLayoutStore.purgeAdoptedLegacyRawLayout`）；delete_account 另外
    /// 清空「被刪除帳號」的命名空間。注入 defaults／cloud，讓測試不碰共享單例。
    static func purgeAccountPreferences(
        deletedAccountID: String?,
        defaults: UserDefaults,
        cloud: CloudKeyValueStore
    ) {
        ReviewCardLayoutStore.purgeAdoptedLegacyRawLayout(defaults: defaults)
        if let deletedAccountID {
            AccountPreferenceNamespace.purgeNamespacedPreferences(
                accountID: deletedAccountID,
                defaults: defaults,
                cloud: cloud
            )
        }
    }

    #if os(iOS)
    static func coversRoot() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotebookCovers", isDirectory: true)
    }

    /// Wipe the entire on-disk notebook-cover tree. Called on logout /
    /// account-switch so a residual `<uuid>.jpg` can't leak into another account
    /// or linger as a disk-space orphan after its Notebook row is dropped.
    ///
    /// `static` with an injectable `root` so tests can target a temp directory.
    /// Idempotent: a missing directory is a clean no-op, not an error — and the
    /// `catch` only logs (matching the podcast purge / `clearUserData failed`
    /// fault tolerance), never throwing into the logout/switch path.
    static func purgeNotebookCovers(root: URL = LocalDataCleanerService.coversRoot()) {
        guard FileManager.default.fileExists(atPath: root.path) else {
            AppLog.sync.info("purgeNotebookCovers: no NotebookCovers dir, nothing to remove")
            return
        }
        do {
            try FileManager.default.removeItem(at: root)
            AppLog.sync.info("purgeNotebookCovers: removed NotebookCovers tree at \(root.path, privacy: .public)")
        } catch {
            AppLog.sync.error("purgeNotebookCovers failed: \(error.localizedDescription)")
        }
    }

    /// Wipe the downloaded podcast-cover cache (`Documents/podcast-covers/`).
    /// Mirrors `purgeNotebookCovers` fault tolerance: missing dir = clean no-op,
    /// `catch` only logs — never throws into the logout/switch path.
    static func purgePodcastCovers(root: URL = PodcastSyncService.coversRoot()) {
        NotebookCoverImageCache.removeAll()
        guard FileManager.default.fileExists(atPath: root.path) else {
            AppLog.sync.info("purgePodcastCovers: no podcast-covers dir, nothing to remove")
            return
        }
        do {
            try FileManager.default.removeItem(at: root)
            AppLog.sync.info("purgePodcastCovers: removed podcast-covers tree at \(root.path, privacy: .public)")
        } catch {
            AppLog.sync.error("purgePodcastCovers failed: \(error.localizedDescription)")
        }
    }
    #endif
}
