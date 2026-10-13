#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Account-switch / logout must wipe on-disk podcast audio, not just the
/// SwiftData rows. A residual .mp3 keyed by a reused remoteId could otherwise
/// be served to a different account (#726 reviewer follow-up).
struct PodcastDownloadCleanupTests {

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("podcast-cleanup-test-\(UUID().uuidString)", isDirectory: true)
        let seriesDir = root.appendingPathComponent("series-A", isDirectory: true)
        try FileManager.default.createDirectory(at: seriesDir, withIntermediateDirectories: true)
        let mp3 = seriesDir.appendingPathComponent("ep-1.mp3")
        try Data([0x49, 0x44, 0x33]).write(to: mp3) // fake ID3 header
        return root
    }

    @Test func purgeRemovesEntireDownloadsTree() throws {
        let root = try makeTempRoot()
        #expect(FileManager.default.fileExists(atPath: root.path))

        PodcastDownloadManager.purgeDownloads(root: root)

        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func purgeIsIdempotentOnMissingRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("podcast-cleanup-absent-\(UUID().uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        // Must not throw / crash when the directory was never created.
        PodcastDownloadManager.purgeDownloads(root: root)

        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// #3427: a failed save after the stash was moved into place must not leave
    /// an orphaned mp3 or a dangling `localAudioPath` behind.
    @MainActor
    @Test func failedSaveAfterMoveRemovesFileAndRestoresEpisodePath() async throws {
        let container = try ModelContainer(
            for: PodcastEpisode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let remoteId = "cleanup-save-fail-\(UUID().uuidString)_ep_01"
        let episode = PodcastEpisode(remoteId: remoteId, episodeNumber: 1, title: "Pilot", durationSec: 42)
        container.mainContext.insert(episode)
        try container.mainContext.save()

        let manager = PodcastDownloadManager()
        manager.configure(modelContainer: container, podcastEnabled: true)
        manager.saveContext = { _ in throw CocoaError(.fileWriteUnknown) }

        let taskId = 920_301
        let task = CleanupStubDownloadTask(identifier: taskId)
        manager.beginTracking(task, remoteId: remoteId)

        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-location-\(UUID().uuidString).tmp")
        try Data([0x49, 0x44, 0x33]).write(to: location)

        // Episode without a series is filed under `unknown/` by commit.
        let finalURL = PodcastDownloadManager.downloadsRoot()
            .appendingPathComponent("unknown", isDirectory: true)
            .appendingPathComponent("\(remoteId).mp3")
        defer { try? FileManager.default.removeItem(at: finalURL) }

        manager.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: location)
        var remaining = 200
        while manager.failed[remoteId] == nil, remaining > 0 {
            await Task.yield()
            remaining -= 1
        }

        #expect(manager.failed[remoteId] != nil)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path))
        #expect(episode.localAudioPath == nil)
    }
}

/// Minimal `URLSessionDownloadTask` stub: nil response is treated as usable
/// audio by the manager, and only `taskIdentifier` is read.
private final class CleanupStubDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    private let stubIdentifier: Int

    init(identifier: Int) {
        stubIdentifier = identifier
        super.init()
    }

    override var taskIdentifier: Int { stubIdentifier }
}
#endif
