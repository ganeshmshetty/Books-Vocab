#if os(iOS)
import Foundation
import SwiftData
import Observation

/// Drives podcast episode downloads via a system background URLSession so they
/// continue across app suspension.
///
/// Why a background URLSession (vs `URLSession.shared`):
///   • Suspended-app continuation — user can lock screen and the MP3 keeps
///     downloading; with `.default` config every task aborts the moment the
///     app suspends.
///   • System-managed retry on transient network drops (cell ↔ wifi handoff
///     during a commute).
///
/// What's intentionally NOT here (deferred follow-ups):
///   • `application(_:handleEventsForBackgroundURLSession:)` rehydration —
///     downloads that *complete while the app is terminated* won't surface
///     until the next foreground launch's `getAllTasks` reconciliation.
///   • Resume from `resumeData` after manual cancel.
///   • Concurrent-download cap / queue ordering.
///
/// Storage layout: `Documents/podcast-downloads/<seriesRemoteId>/<episodeRemoteId>.mp3`
/// — matches the existing `PodcastEpisode.localAudioPath` schema field that's
/// been waiting for a writer.
@MainActor
@Observable
final class PodcastDownloadManager: NSObject {
    static let shared = PodcastDownloadManager()

    /// Active download fraction keyed by episode.remoteId (0.0 ... 1.0).
    /// Absent → not downloading.
    private(set) var progress: [String: Double] = [:]
    /// Last error string keyed by episode.remoteId. Cleared on retry.
    private(set) var failed: [String: String] = [:]

    @ObservationIgnored
    private var modelContainer: ModelContainer?
    /// Persists the episode write made by `commit`. Production uses the
    /// context's own save; tests swap it to force the save-failure branch (#3427).
    @ObservationIgnored
    var saveContext: (ModelContext) throws -> Void = { try $0.save() }
    @ObservationIgnored
    private var taskToRemoteId: [Int: String] = [:]
    @ObservationIgnored
    private var remoteIdToTask: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored
    private var lastProgressUpdate: [String: Date] = [:]

    @ObservationIgnored
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "tw.kg.podcast.background-download"
        )
        config.isDiscretionary = false       // user explicitly tapped — don't defer
        config.allowsCellularAccess = true   // podcast.audio is the user's goal
        config.sessionSendsLaunchEvents = false  // app-relaunch hook is a follow-up
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Whether `configure` has taken effect (delegate callbacks can persist).
    /// Exposed for the feature-gate tests; production code never branches on it.
    var isConfigured: Bool { modelContainer != nil }

    /// Call once from app launch — required before any startDownload call.
    /// Persists the container reference so background delegate callbacks
    /// can update SwiftData without piping it through every API call.
    ///
    /// Podcast gate: when `KGFeatureFlags.podcastEnabled == false`（Release）
    /// the manager must stay inert — refuse the container so the download
    /// data path is dead end-to-end (`startDownload` is unreachable anyway
    /// because the UI is gated, and `commit` drops stashes without a
    /// container). `podcastEnabled` 參數化僅供測試；production 走預設值。
    func configure(
        modelContainer: ModelContainer,
        podcastEnabled: Bool = KGFeatureFlags.podcastEnabled
    ) {
        guard podcastEnabled else { return }
        self.modelContainer = modelContainer
    }

    func isDownloading(remoteId: String) -> Bool {
        progress[remoteId] != nil
    }

    /// Kicks off the download. Caller supplies a fresh auth token so the
    /// manager doesn't have to take a dependency on KGService.
    func startDownload(episode: PodcastEpisode, authToken: String) {
        guard
            let urlStr = episode.audioURL,
            let url = URL(string: urlStr)
        else {
            failed[episode.remoteId] = L10n.string("無音訊 URL")
            return
        }
        if remoteIdToTask[episode.remoteId] != nil { return }
        failed.removeValue(forKey: episode.remoteId)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let task = session.downloadTask(with: request)
        beginTracking(task, remoteId: episode.remoteId)
        task.resume()
    }

    /// Binds a download task to the episode it fetches — the single
    /// bookkeeping entry point every delegate callback resolves through.
    /// Internal (not private) so delegate tests can drive callbacks with a
    /// stub task instead of a live background session.
    func beginTracking(_ task: URLSessionDownloadTask, remoteId: String) {
        taskToRemoteId[task.taskIdentifier] = remoteId
        remoteIdToTask[remoteId] = task
        progress[remoteId] = 0
    }

    /// Why a finished download must not become the episode's audio.
    enum DownloadRejection: Equatable {
        /// Non-2xx status: the body is an error page (401 token expired
        /// mid-download, 403, 404, 5xx / CDN error), not audio.
        case httpStatus(Int)
        /// 2xx but the body is a structured/text error payload.
        case unexpectedContentType(String)
    }

    /// Validates the response of a finished download task. `nil` = usable.
    ///
    /// Content type is a denylist of error-body types (JSON / XML / text)
    /// rather than an `audio/*` allowlist: the backend serves `audio/mpeg`,
    /// but a storage redirect may legitimately answer with
    /// `application/octet-stream` and must not be rejected. A missing
    /// response (non-HTTP) is accepted.
    nonisolated static func downloadRejection(for response: URLResponse?) -> DownloadRejection? {
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            return .httpStatus(http.statusCode)
        }
        guard let mime = http.mimeType?.lowercased() else { return nil }
        let isErrorBody = mime.hasPrefix("text/")
            || mime == "application/json"
            || mime == "application/xml"
            || mime.hasSuffix("+json")
            || mime.hasSuffix("+xml")
        return isErrorBody ? .unexpectedContentType(mime) : nil
    }

    private static func message(for rejection: DownloadRejection) -> String {
        switch rejection {
        case .httpStatus(let status):
            return L10n.format("sync.failure.reason.serverRejectedCode", String(status))
        case .unexpectedContentType:
            return L10n.string("sync.failure.reason.serverRejected")
        }
    }

    func cancel(remoteId: String) {
        guard let task = remoteIdToTask[remoteId] else { return }
        task.cancel()
        // didCompleteWithError(.cancelled) cleans dicts.
    }

    /// Erase a previously-downloaded file. Idempotent — silently no-ops if
    /// the file or model field is already gone.
    func deleteLocal(episode: PodcastEpisode) {
        guard let path = episode.localAudioPath else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        episode.localAudioPath = nil
        // Save on the episode's own context so the mutation persists —
        // creating a fresh ModelContext wouldn't see this object's edits.
        // safeSave logs on failure so a stuck localAudioPath (UI shows
        // "deleted" but the record still points at a removed file) is visible.
        episode.modelContext?.safeSave()
    }

    // nonisolated: pure FileManager path math, no actor state. Lets the
    // nonisolated `purgeDownloads` default argument and the cross-platform
    // cleaner evaluate it without a MainActor hop.
    nonisolated static func downloadsRoot() -> URL {
        var dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("podcast-downloads", isDirectory: true)
        // Ensure directory exists and is excluded from iCloud Backup
        // (re-downloadable cache, not user data). Do this here so every
        // caller gets the guarantee without separate bookkeeping.
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? dir.setResourceValues(resourceValues)
        }
        return dir
    }

    /// Wipe the entire on-disk podcast download tree. Called on logout /
    /// account-switch so a residual `<series>/<episode>.mp3` can't be served
    /// to a different account when a remoteId is reused (#726 follow-up).
    ///
    /// `nonisolated static` so the cross-platform `LocalDataCleanerService`
    /// (not `@MainActor`) can call it without an actor hop, and so tests can
    /// inject a temp `root`. Idempotent: a missing directory is a clean no-op,
    /// not an error.
    nonisolated static func purgeDownloads(root: URL = PodcastDownloadManager.downloadsRoot()) {
        guard FileManager.default.fileExists(atPath: root.path) else {
            AppLog.sync.info("purgeDownloads: no podcast-downloads dir, nothing to remove")
            return
        }
        do {
            try FileManager.default.removeItem(at: root)
            AppLog.sync.info("purgeDownloads: removed podcast-downloads tree at \(root.path, privacy: .public)")
        } catch {
            AppLog.sync.error("purgeDownloads failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension PodcastDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        let taskId = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let remoteId = self.taskToRemoteId[taskId] else { return }
            // High-frequency nonisolated callbacks hop to MainActor out of order:
            // a stale lower fraction can land after a newer higher one and visibly
            // rewind the progress bar. Monotonic guard — never move backward.
            let clamped = max(self.progress[remoteId] ?? 0, fraction)
            guard clamped != self.progress[remoteId] else { return }
            // Throttle: skip updates within 100ms of the last one to avoid
            // excessive actor hops and view rebuilds during fast downloads.
            let now = Date()
            if let last = self.lastProgressUpdate[remoteId], now.timeIntervalSince(last) < 0.1 {
                return
            }
            self.lastProgressUpdate[remoteId] = now
            self.progress[remoteId] = clamped
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession calls this for ANY completed response, including 4xx/5xx
        // whose body is an error page. Reject before stashing so an error body
        // never lands as `<remoteId>.mp3` / `localAudioPath` (#2104).
        if let rejection = Self.downloadRejection(for: downloadTask.response) {
            try? FileManager.default.removeItem(at: location)
            let taskId = downloadTask.taskIdentifier
            Task { @MainActor in
                self.markFailed(taskId: taskId, message: Self.message(for: rejection))
            }
            return
        }
        // didFinishDownloadingTo's URL is valid only inside this callback —
        // copy to a temp file we control before hopping to MainActor.
        let tempDir = FileManager.default.temporaryDirectory
        let stash = tempDir.appendingPathComponent(
            "podcast-download-\(downloadTask.taskIdentifier).mp3"
        )
        try? FileManager.default.removeItem(at: stash)
        do {
            try FileManager.default.moveItem(at: location, to: stash)
        } catch {
            let taskId = downloadTask.taskIdentifier
            Task { @MainActor in
                self.markFailed(taskId: taskId, message: error.localizedDescription)
            }
            return
        }
        let taskId = downloadTask.taskIdentifier
        Task { @MainActor in
            self.commit(taskId: taskId, stashedAt: stash)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsErr = error as NSError
        let taskId = task.taskIdentifier
        // User-initiated cancel surfaces here as NSURLErrorCancelled;
        // treat as clean cleanup, not a failure the UI should announce.
        if nsErr.code == NSURLErrorCancelled {
            Task { @MainActor in
                guard let remoteId = self.taskToRemoteId[taskId] else { return }
                self.cleanup(taskId: taskId, remoteId: remoteId)
            }
            return
        }
        let message = nsErr.localizedDescription
        Task { @MainActor in
            self.markFailed(taskId: taskId, message: message)
        }
    }

    @MainActor
    private func commit(taskId: Int, stashedAt stash: URL) {
        guard
            let remoteId = taskToRemoteId[taskId],
            let container = modelContainer
        else {
            try? FileManager.default.removeItem(at: stash)
            return
        }
        // Reuse mainContext so @Query observers pick up the localAudioPath
        // write immediately without waiting for SwiftData's cross-context
        // notification round-trip.
        let context = container.mainContext
        let descriptor = FetchDescriptor<PodcastEpisode>(
            predicate: #Predicate { $0.remoteId == remoteId }
        )
        guard let episode = try? context.fetch(descriptor).first else {
            try? FileManager.default.removeItem(at: stash)
            cleanup(taskId: taskId, remoteId: remoteId)
            return
        }
        let seriesKey = episode.series?.remoteId ?? "unknown"
        let dir = Self.downloadsRoot().appendingPathComponent(seriesKey, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let finalURL = dir.appendingPathComponent("\(remoteId).mp3")
        let fm = FileManager.default
        let previousPath = episode.localAudioPath
        // The persisted record may still point at finalURL (re-download). Keep
        // that file aside instead of deleting it, so each failure below can put
        // it back and disk keeps agreeing with the stored path (#3502).
        let aside = finalURL.appendingPathExtension("prev")
        try? fm.removeItem(at: aside)
        var keptPrevious = false
        if previousPath == finalURL.path {
            keptPrevious = (try? fm.moveItem(at: finalURL, to: aside)) != nil
        }
        try? fm.removeItem(at: finalURL)
        do {
            try fm.moveItem(at: stash, to: finalURL)
        } catch {
            // moveItem failed → stash still on disk; clear it so it doesn't
            // accumulate across retries, and restore the kept previous file.
            try? fm.removeItem(at: stash)
            if keptPrevious { restoreKeptPrevious(aside, to: finalURL, fm: fm, remoteId: remoteId) }
            failed[remoteId] = error.localizedDescription
            cleanup(taskId: taskId, remoteId: remoteId)
            return
        }
        episode.localAudioPath = finalURL.path
        do {
            try saveContext(context)
            try? fm.removeItem(at: aside)
            cleanup(taskId: taskId, remoteId: remoteId)
        } catch {
            // Save failed after the move: drop the new file, restore the kept
            // previous one, and revert the in-memory field so disk and the
            // persisted record agree and no orphaned mp3 remains (#3427, #3502).
            try? fm.removeItem(at: finalURL)
            if keptPrevious { restoreKeptPrevious(aside, to: finalURL, fm: fm, remoteId: remoteId) }
            episode.localAudioPath = previousPath == finalURL.path && !keptPrevious ? nil : previousPath
            failed[remoteId] = error.localizedDescription
            cleanup(taskId: taskId, remoteId: remoteId)
        }
    }

    /// Puts the kept previous file back at `finalURL`. A failure is logged,
    /// not swallowed: the episode record may still point at `finalURL`, so
    /// the log is the only trace of the disk/record mismatch (#3602).
    private func restoreKeptPrevious(_ aside: URL, to finalURL: URL, fm: FileManager, remoteId: String) {
        do {
            try fm.moveItem(at: aside, to: finalURL)
        } catch {
            AppLog.sync.error("restore kept previous podcast file failed remoteId=\(remoteId): \(error.localizedDescription)")
        }
    }

    @MainActor
    private func markFailed(taskId: Int, message: String) {
        guard let remoteId = taskToRemoteId[taskId] else { return }
        failed[remoteId] = message
        cleanup(taskId: taskId, remoteId: remoteId)
    }

    @MainActor
    private func cleanup(taskId: Int, remoteId: String) {
        taskToRemoteId.removeValue(forKey: taskId)
        remoteIdToTask.removeValue(forKey: remoteId)
        progress.removeValue(forKey: remoteId)
        lastProgressUpdate.removeValue(forKey: remoteId)
    }
}
#endif
