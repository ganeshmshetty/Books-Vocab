import Foundation
import Testing
@testable import BooksAndVocab

/// #3676：自訂封面以檔名持久化；舊版絕對路徑（含已失效的 container UUID）
/// 讀取與刪除都必須解析到目前的 `Documents/NotebookCovers`。
@MainActor
struct NotebookCoverStoreTests {

    private static let oldContainerDirectory =
        "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/NotebookCovers/"
    private static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])

    private func writeCurrentCover(named name: String) throws -> URL {
        guard let dir = NotebookCoverStore.directoryURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Self.jpegBytes.write(to: url)
        return url
    }

    @Test func legacyAbsolutePathFromOldContainerLoadsCurrentContainerFile() throws {
        let name = "legacy-\(UUID().uuidString).jpg"
        let file = try writeCurrentCover(named: name)
        defer { try? FileManager.default.removeItem(at: file) }

        let legacy = Self.oldContainerDirectory + name
        #expect(NotebookCoverStore.resolvePath(legacy) == file.path)
        #expect(NotebookCoverStore.loadData(legacy) == Self.jpegBytes, "舊容器路徑須映射到目前 container 的同名檔")
    }

    @Test func persistedBareFileNameLoadsCurrentContainerFile() throws {
        let name = "bare-\(UUID().uuidString).jpg"
        let file = try writeCurrentCover(named: name)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(NotebookCoverStore.loadData(name) == Self.jpegBytes)
    }

    @Test func replacingLegacyCoverDeletesCurrentContainerFile() throws {
        let name = "replace-\(UUID().uuidString).jpg"
        let file = try writeCurrentCover(named: name)
        defer { try? FileManager.default.removeItem(at: file) }

        let plan = NotebookCoverCommit.plan(
            staged: "notebook_cover_new.jpg",
            original: Self.oldContainerDirectory + name
        )
        NotebookCoverCommit.removeStaleFile(plan)

        #expect(!FileManager.default.fileExists(atPath: file.path), "換圖後舊封面檔須被刪除，即使 stored 是失效的絕對路徑")
    }

    @Test func unchangedLegacyCoverIsNotDeletedWhenNameMatches() throws {
        let name = "same-\(UUID().uuidString).jpg"
        let file = try writeCurrentCover(named: name)
        defer { try? FileManager.default.removeItem(at: file) }

        let plan = NotebookCoverCommit.plan(
            staged: name,
            original: Self.oldContainerDirectory + name
        )
        NotebookCoverCommit.removeStaleFile(plan)

        #expect(plan.fileToRemove == nil, "同一檔案（僅容器前綴不同）視為未換圖")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
