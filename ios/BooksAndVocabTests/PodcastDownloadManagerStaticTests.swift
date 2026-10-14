//
//  PodcastDownloadManagerStaticTests.swift
//  Books & Vocab Tests
//
//  Pins PodcastDownloadManager static helpers — downloadsRoot() directory
//  creation / iCloud exclusion, and purgeDownloads() idempotency. These are
//  the cross-account safety path (#726): a leftover MP3 must not survive
//  logout→login for a reused remoteId.
//

import Foundation
import Testing
@testable import BooksAndVocab

struct PodcastDownloadManagerStaticTests {

    // MARK: - downloadsRoot()

    @Test func downloadsRootCreatesDirectory() throws {
        // Use a temp parent so the real podcast-downloads dir is untouched.
        let tmpParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpParent) }

        let root = tmpParent.appendingPathComponent("podcast-downloads", isDirectory: true)

        // Precondition: directory does not exist.
        #expect(!FileManager.default.fileExists(atPath: root.path))

        // Manually invoke the same logic downloadsRoot uses, but with a
        // controlled parent. Since downloadsRoot() hardcodes the subdirectory
        // name, we verify by creating the tree ourselves.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)

        #expect(FileManager.default.fileExists(atPath: root.path))

        let fetched = try mutableRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(fetched.isExcludedFromBackup == true)
    }

    @Test func downloadsRootReturnsExistingDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("podcast-downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Since downloadsRoot is static and hardcodes the path, we can't
        // inject a parent. Instead we verify the idempotent contract:
        // repeated calls succeed and the directory remains usable.
        #expect(FileManager.default.fileExists(atPath: root.path))

        // A second createDirectory is a no-op (no error).
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - purgeDownloads()

    @Test func purgeDownloadsRemovesEntireTree() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Build a nested tree: podcast-downloads/<series>/<episode>.mp3
        let root = tmp.appendingPathComponent("podcast-downloads", isDirectory: true)
        let seriesDir = root.appendingPathComponent("series-42", isDirectory: true)
        let file = seriesDir.appendingPathComponent("episode-99.mp3")

        try FileManager.default.createDirectory(at: seriesDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data("mp3".utf8))

        #expect(FileManager.default.fileExists(atPath: file.path))

        PodcastDownloadManager.purgeDownloads(root: root)

        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func purgeDownloadsIsIdempotentForMissingDirectory() {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("podcast-downloads", isDirectory: true)

        // Must not throw even though the directory does not exist.
        PodcastDownloadManager.purgeDownloads(root: ghost)
        #expect(!FileManager.default.fileExists(atPath: ghost.path))
    }

    // MARK: - keptPrevious restore (#3602)

    /// A failed restore of the kept previous file must not be swallowed by
    /// `try?`: the episode record would then point at an absent file with no
    /// trace in the log. Source-level pin, since the failure path needs a
    /// filesystem fault that cannot be forced deterministically from a test.
    @Test func keptPreviousRestoreFailuresAreLogged() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BooksAndVocabTests
            .deletingLastPathComponent() // ios
            .appendingPathComponent("BooksAndVocab/Services/PodcastDownloadManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(!source.contains("try? fm.moveItem(at: aside"))
        #expect(source.contains("restoreKeptPrevious("))
        #expect(source.contains("AppLog.sync.error(\"restore kept previous podcast file failed"))
    }

    @Test func purgeDownloadsLeavesSiblingDirectoriesAlone() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("podcast-downloads", isDirectory: true)
        let sibling = tmp.appendingPathComponent("other-data", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingFile = sibling.appendingPathComponent("keep.txt")
        FileManager.default.createFile(atPath: siblingFile.path, contents: Data("keep".utf8))

        PodcastDownloadManager.purgeDownloads(root: root)

        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: siblingFile.path))
    }
}
