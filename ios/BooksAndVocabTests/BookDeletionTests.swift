import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// 書籍刪除的誠實性（#2054）：檔案刪除失敗不得回報成功、不得讓書狀態分裂
/// （row 消失但檔案還在 → 下次 reconcile 讓書「復活」且使用者已看過「已刪除」）。
struct LocalBookFileManagerDeletionTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDir(_ name: String, in root: URL) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 還原權限後才能刪 temp root，否則測試殘留 read-only 目錄。
    private func cleanUp(_ root: URL) {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try? fm.removeItem(at: root)
    }

    @Test func removesFileFromEveryLocation() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let a = try makeDir("a", in: root)
        let b = try makeDir("b", in: root)
        try Data("x".utf8).write(to: a.appendingPathComponent("book.epub"))
        try Data("x".utf8).write(to: b.appendingPathComponent("book.epub"))

        try LocalBookFileManager(locations: [a, b]).deleteBookFile(named: "book.epub")

        #expect(!FileManager.default.fileExists(atPath: a.appendingPathComponent("book.epub").path))
        #expect(!FileManager.default.fileExists(atPath: b.appendingPathComponent("book.epub").path))
    }

    @Test func missingFileIsNotAnError() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let a = try makeDir("a", in: root)

        // 檔案本來就不在（只存在於其中一個位置是常態）→ 已達成「不存在」，不是失敗
        try LocalBookFileManager(locations: [a]).deleteBookFile(named: "never-there.epub")
    }

    // MARK: - Originals copy（#2440）

    private func writeBook(_ stem: String, originalExt: String?, in dir: URL) throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent("\(stem).epub"))
        guard let originalExt else { return }
        let originals = try makeDir("Originals", in: dir)
        try Data("src".utf8).write(to: originals.appendingPathComponent("\(stem).\(originalExt)"))
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test(arguments: ["txt", "md"])
    func deletingBookAlsoRemovesItsOriginalsCopy(ext: String) throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let a = try makeDir("a", in: root)
        try writeBook("book-X", originalExt: ext, in: a)

        try LocalBookFileManager(locations: [a]).deleteBookFile(named: "book-X.epub")

        #expect(!exists(a.appendingPathComponent("book-X.epub")))
        #expect(!exists(a.appendingPathComponent("Originals/book-X.\(ext)")))
    }

    @Test func missingOriginalsCopyIsNotAnError() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let a = try makeDir("a", in: root)
        try writeBook("book-Y", originalExt: nil, in: a)

        try LocalBookFileManager(locations: [a]).deleteBookFile(named: "book-Y.epub")

        #expect(!exists(a.appendingPathComponent("book-Y.epub")))
    }

    @Test func deletingOneBookKeepsAnotherBooksOriginalsWithSameSourceName() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let a = try makeDir("a", in: root)
        try writeBook("uuid1_notes", originalExt: "txt", in: a)
        try writeBook("uuid2_notes", originalExt: "txt", in: a)

        try LocalBookFileManager(locations: [a]).deleteBookFile(named: "uuid1_notes.epub")

        #expect(!exists(a.appendingPathComponent("Originals/uuid1_notes.txt")))
        #expect(exists(a.appendingPathComponent("Originals/uuid2_notes.txt")))
        #expect(exists(a.appendingPathComponent("uuid2_notes.epub")))
    }

    // MARK: - iCloud 已驅逐的 placeholder（#2723）

    @Test func deletingEvictedBookRemovesItsIcloudPlaceholdersAndReconcilerDoesNotResurrect() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let a = try makeDir("a", in: root)
        let originals = try makeDir("Originals", in: a)
        let placeholder = a.appendingPathComponent(".book-Z.epub.icloud")
        let txtPlaceholder = originals.appendingPathComponent(".book-Z.txt.icloud")
        let mdPlaceholder = originals.appendingPathComponent(".book-Z.md.icloud")
        for url in [placeholder, txtPlaceholder, mdPlaceholder] {
            try Data("x".utf8).write(to: url)
        }
        #expect(BookLibraryReconciler.normalizedBookFileName(from: placeholder) == "book-Z.epub")

        try LocalBookFileManager(locations: [a]).deleteBookFile(named: "book-Z.epub")

        #expect(!exists(placeholder))
        #expect(!exists(txtPlaceholder))
        #expect(!exists(mdPlaceholder))
    }

    @Test func emptyFileNameNeverTouchesTheDirectoryItself() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let a = try makeDir("a", in: root)
        try Data("x".utf8).write(to: a.appendingPathComponent("keep.epub"))

        try LocalBookFileManager(locations: [a]).deleteBookFile(named: "")

        #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("keep.epub").path))
    }

    @Test func removalFailureIsThrownAndOtherLocationsStillCleaned() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let locked = try makeDir("locked", in: root)
        let open = try makeDir("open", in: root)
        try Data("x".utf8).write(to: locked.appendingPathComponent("book.epub"))
        try Data("x".utf8).write(to: open.appendingPathComponent("book.epub"))
        // 父目錄唯讀 → removeItem 對其中的檔案回 EACCES（真實 removeItem 失敗，非 mock）
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        #expect(throws: BookFileDeletionError.self) {
            try LocalBookFileManager(locations: [locked, open]).deleteBookFile(named: "book.epub")
        }

        // 失敗不應中斷其他位置的清理（盡力刪完再整體回報）
        #expect(FileManager.default.fileExists(atPath: locked.appendingPathComponent("book.epub").path))
        #expect(!FileManager.default.fileExists(atPath: open.appendingPathComponent("book.epub").path))
    }

    // MARK: - tombstone 只在成功時記錄（#2750）

    private func makeStore() -> PendingBookDeletionStore {
        PendingBookDeletionStore(defaults: UserDefaults(suiteName: "BookDeletionTombstone-\(UUID().uuidString)")!)
    }

    @Test func failedRemovalRecordsNoTombstone() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let locked = try makeDir("locked", in: root)
        try Data("x".utf8).write(to: locked.appendingPathComponent("book.epub"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let store = makeStore()

        #expect(throws: BookFileDeletionError.self) {
            try LocalBookFileManager(locations: [locked], pendingDeletions: store, iCloudAvailable: { false })
                .deleteBookFile(named: "book.epub")
        }

        #expect(store.fileNames.isEmpty)
    }

    @Test func deleteBookFileNeverRecordsTombstoneByItself() throws {
        // tombstone 只能在書列刪除 save 成功後由 coordinator 記錄（見 recordPendingICloudDeletion），不得由檔案刪除提前落地。
        let root = try makeRoot()
        defer { cleanUp(root) }
        let a = try makeDir("a", in: root)
        let store = makeStore()

        try LocalBookFileManager(locations: [a], pendingDeletions: store, iCloudAvailable: { false })
            .deleteBookFile(named: "book.epub")

        #expect(store.fileNames.isEmpty)
    }

    @Test func recordWhileICloudUnavailableRecordsTombstone() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let a = try makeDir("a", in: root)
        let store = makeStore()
        let files = LocalBookFileManager(locations: [a], pendingDeletions: store, iCloudAvailable: { false })

        try files.deleteBookFile(named: "book.epub")
        files.recordPendingICloudDeletion(named: "book.epub")

        #expect(store.fileNames == ["book.epub"])
    }

    @Test func tombstoneStoreKeepsOnlyNewestEntries() {
        let store = makeStore()
        let total = PendingBookDeletionStore.maxEntries + 5
        for index in 0..<total { store.insert("\(index).epub") }

        #expect(store.fileNames.count == PendingBookDeletionStore.maxEntries)
        #expect(!store.fileNames.contains("0.epub"))
        #expect(store.fileNames.contains("\(total - 1).epub"))
    }
}

#if os(iOS)
@MainActor
struct BookshelfDeleteBookTests {
    private struct DeletionFailure: Error {}

    private final class SpyFileManager: BookFileManaging {
        let failure: Error?
        private(set) var requested: [String] = []
        private(set) var recorded: [String] = []
        init(failure: Error? = nil) { self.failure = failure }
        func deleteBookFile(named fileName: String) throws {
            requested.append(fileName)
            if let failure { throw failure }
        }
        func recordPendingICloudDeletion(named fileName: String) {
            recorded.append(fileName)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Book.self,
            VocabularyEntry.self,
            ReviewRecord.self,
            Notebook.self,
            PodcastSeries.self,
            PodcastEpisode.self,
            PodcastProgress.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func seed(_ container: ModelContainer) throws -> (book: Book, entry: VocabularyEntry) {
        let context = container.mainContext
        let book = Book(title: "Deletable", author: "A", fileName: "\(UUID().uuidString)_deletable.epub")
        let entry = VocabularyEntry(word: "w", translation: "字", context: "c", bookTitle: "Deletable")
        entry.bookId = book.id
        context.insert(book)
        context.insert(entry)
        try context.save()
        return (book, entry)
    }

    @Test func fileRemovalFailureShowsErrorNotSuccessAndKeepsBookConsistent() throws {
        let container = try makeContainer()
        let (book, entry) = try seed(container)
        let bookId = book.id
        let fileName = book.epubFileName
        let toast = AppToastCoordinator()
        let files = SpyFileManager(failure: DeletionFailure())

        BookshelfCoordinator().deleteBook(
            book,
            modelContext: container.mainContext,
            fileManager: files,
            toastCoordinator: toast
        )

        #expect(files.requested == [fileName])
        #expect(files.recorded.isEmpty)
        #expect(toast.current?.style == .error)
        #expect(toast.current?.message != "已刪除".localized)

        // 狀態一致：持久層書仍在、單字的 bookId 連結未被清掉
        let fresh = ModelContext(container)
        let books = try fresh.fetch(FetchDescriptor<Book>())
        #expect(books.map(\.id) == [bookId])
        let entries = try fresh.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(entries.first?.bookId == bookId)

        // UI 所讀的 mainContext 也不得殘留未存的刪除（否則書架上書消失、重啟又回來）
        let main = container.mainContext
        #expect(!main.hasChanges)
        #expect(try main.fetch(FetchDescriptor<Book>()).map(\.id) == [bookId])
        #expect(entry.bookId == bookId)
    }

    @Test func successfulDeletionRemovesBookClearsLinksAndShowsSuccess() throws {
        let container = try makeContainer()
        let (book, _) = try seed(container)
        let fileName = book.epubFileName
        let toast = AppToastCoordinator()
        let files = SpyFileManager()

        BookshelfCoordinator().deleteBook(
            book,
            modelContext: container.mainContext,
            fileManager: files,
            toastCoordinator: toast
        )

        #expect(files.requested == [fileName])
        #expect(files.recorded == [fileName])
        #expect(toast.current?.style == .success)
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<Book>()).isEmpty)
        let entries = try fresh.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(entries.map(\.bookId) == [nil])
    }

    /// #2750 r2（P1）：書列 save 失敗（回滾保留）時不得留下 tombstone。否則 iCloud 回來後 reconcile 會刪掉仍在庫書的 iCloud 副本與 manifest，書永久遺失。
    @Test func saveFailureWhileICloudUnavailableRecordsNoTombstoneAndICloudCopySurvivesReconcile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let local = dir.appendingPathComponent("local", isDirectory: true)
        let icloud = dir.appendingPathComponent("icloud", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: icloud, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("store.sqlite")
        let schema = Schema([
            Book.self, VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            PodcastSeries.self, PodcastEpisode.self, PodcastProgress.self
        ])

        // 可寫 store：種一本書，iCloud 副本與 manifest 都在
        let writable = try ModelContainer(for: schema, configurations: [ModelConfiguration(url: storeURL, cloudKitDatabase: .none)])
        let fileName = "\(UUID().uuidString)_kept.epub"
        let book = Book(title: "Kept", author: "A", fileName: fileName)
        writable.mainContext.insert(book)
        try writable.mainContext.save()
        try Data("epub".utf8).write(to: icloud.appendingPathComponent(fileName))
        try BookManifestStore(rootDirectory: icloud).write(BookManifest(
            bookId: book.id, fileName: fileName, originalFileName: nil, title: "Kept", author: "A",
            format: .epub, coverImageData: nil, dateAdded: Date(), dateLastRead: nil,
            progression: nil, lastReadLocatorJSON: nil, preferredNotebookId: nil
        ))

        // 唯讀 store：刪除的 save 必定失敗，走 rollback 分支
        let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(url: storeURL, allowsSave: false, cloudKitDatabase: .none)])
        let target = try #require(try readOnly.mainContext.fetch(FetchDescriptor<Book>()).first)
        let tombstones = PendingBookDeletionStore(defaults: UserDefaults(suiteName: "BookDeletionSaveFailure-\(UUID().uuidString)")!)
        let files = LocalBookFileManager(locations: [local], pendingDeletions: tombstones, iCloudAvailable: { false })
        let toast = AppToastCoordinator()

        BookshelfCoordinator().deleteBook(
            target,
            modelContext: readOnly.mainContext,
            fileManager: files,
            toastCoordinator: toast
        )

        #expect(toast.current?.style == .error)
        #expect(tombstones.fileNames.isEmpty)

        // iCloud 回來後 reconcile：書列仍在，iCloud 副本與 manifest 不得被刪
        let context = ModelContext(writable)
        _ = try BookLibraryReconciler(
            rootDirectory: icloud, legacyDirectories: [], pendingDeletions: tombstones, isICloudAvailable: { true }
        ).reconcile(context: context)

        #expect(FileManager.default.fileExists(atPath: icloud.appendingPathComponent(fileName).path))
        #expect(FileManager.default.fileExists(atPath: BookManifestStore(rootDirectory: icloud).url(for: book.id).path))
        #expect(try context.fetch(FetchDescriptor<Book>()).map(\.id) == [book.id])
    }
}
#endif
