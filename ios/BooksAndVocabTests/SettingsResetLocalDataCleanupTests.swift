//
//  SettingsResetLocalDataCleanupTests.swift
//  Books & Vocab Tests
//
//  Pins #2721: Settings reset (KGService.clearLocalData) and logout / account switch
//  (LocalDataCleanerService) must drop the same derived local state. Before the fix the
//  Settings path left podcast downloads, covers, notebook covers, the review snapshot and
//  Add Link jobs behind while the UI reported a full reset. Roots are injected, so no run
//  touches the real Documents tree.
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

struct SettingsResetLocalDataCleanupTests {

    private struct Fixture {
        let base: URL
        let roots: LocalDataCleanerService.DerivedLocalStateRoots
        let notebookCover: URL
        let podcastCover: URL
        let podcastEpisode: URL
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let covers = base.appendingPathComponent("NotebookCovers", isDirectory: true)
        let podcastCovers = base.appendingPathComponent("podcast-covers", isDirectory: true)
        let downloads = base.appendingPathComponent("podcast-downloads", isDirectory: true)
        let series = downloads.appendingPathComponent("series-1", isDirectory: true)
        for dir in [covers, podcastCovers, series] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let notebookCover = covers.appendingPathComponent("n.jpg")
        let podcastCover = podcastCovers.appendingPathComponent("p.jpg")
        let podcastEpisode = series.appendingPathComponent("e.mp3")
        for file in [notebookCover, podcastCover, podcastEpisode] {
            FileManager.default.createFile(atPath: file.path, contents: Data([1, 2, 3]))
        }
        let roots = LocalDataCleanerService.DerivedLocalStateRoots(
            notebookCovers: covers,
            podcastCovers: podcastCovers,
            podcastDownloads: downloads
        )
        return Fixture(
            base: base,
            roots: roots,
            notebookCover: notebookCover,
            podcastCover: podcastCover,
            podcastEpisode: podcastEpisode
        )
    }

    private func makeReviewSnapshot(userId: String) -> TodayReviewSessionSnapshotStore.Snapshot {
        TodayReviewSessionSnapshotStore.Snapshot(
            userId: userId,
            sessionStartTime: Date(),
            currentIndex: 0,
            queue: [],
            submissions: [:],
            updatedAt: Date()
        )
    }

    private func makeEmptyContainer() throws -> ModelContainer {
        try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    /// Settings reset path: the shared purge removes every derived file and the review snapshot.
    @Test func sharedDerivedPurgeRemovesFilesAndReviewSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let userId = "settings-reset-\(UUID().uuidString)"
        TodayReviewSessionSnapshotStore.save(makeReviewSnapshot(userId: userId))
        #expect(TodayReviewSessionSnapshotStore.load(for: userId) != nil, "precondition: snapshot saved")

        await LocalDataCleanerService.purgeDerivedLocalState(roots: fixture.roots)

        #expect(!FileManager.default.fileExists(atPath: fixture.notebookCover.path), "notebook covers purged")
        #expect(!FileManager.default.fileExists(atPath: fixture.podcastCover.path), "podcast covers purged")
        #expect(!FileManager.default.fileExists(atPath: fixture.podcastEpisode.path), "podcast downloads purged")
        #expect(TodayReviewSessionSnapshotStore.load(for: userId) == nil, "review snapshot cleared")
    }

    /// Logout / account-switch path runs the same derived purge: its step list must not diverge
    /// from the Settings reset path (#2721).
    @Test func logoutPathRemovesTheSameDerivedState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let suite = "settings-reset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let userId = "logout-\(UUID().uuidString)"
        TodayReviewSessionSnapshotStore.save(makeReviewSnapshot(userId: userId))

        let cleaner = LocalDataCleanerService(
            wipeRows: { _, _ in },
            defaults: defaults,
            derivedRoots: fixture.roots
        )
        await cleaner.clearLocalData(container: try makeEmptyContainer(), reason: "user_logout", deletedAccountID: nil)

        #expect(!FileManager.default.fileExists(atPath: fixture.notebookCover.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.podcastCover.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.podcastEpisode.path))
        #expect(TodayReviewSessionSnapshotStore.load(for: userId) == nil)
    }
}
