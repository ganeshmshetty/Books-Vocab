import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
struct BookLibraryReconcilerTests {
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

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookLibraryReconcilerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func sweepRemovesStaleImportTempButKeepsFreshAndUnrelatedHiddenFiles() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let now = Date()
        let stale = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fresh = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        let notUUID = root.appendingPathComponent(".notes.tmp")
        let book = root.appendingPathComponent("keep.epub")
        for url in [stale, fresh, notUUID, book] { try Data("x".utf8).write(to: url) }
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: stale.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: notUUID.path)

        let removed = BookLibraryReconciler.sweepStaleImportTemps(in: root, now: now)

        #expect(removed == 1)
        #expect(!fm.fileExists(atPath: stale.path))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: notUUID.path))
        #expect(fm.fileExists(atPath: book.path))
    }

    @Test func reconcileSweepsStaleImportTemp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        try Data("x".utf8).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)],
            ofItemAtPath: stale.path
        )

        _ = try BookLibraryReconciler(rootDirectory: root, legacyDirectories: []).reconcile(context: context)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func reconcileSweepsStaleImportTempsInEveryBooksDirectory() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let iCloudRoot = try makeTempRoot()
        let localRoot = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: iCloudRoot)
            try? FileManager.default.removeItem(at: localRoot)
        }
        let staleICloud = iCloudRoot.appendingPathComponent(".\(UUID().uuidString).tmp")
        let staleLocal = localRoot.appendingPathComponent(".\(UUID().uuidString).tmp")
        for url in [staleICloud, staleLocal] {
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-7200)],
                ofItemAtPath: url.path
            )
        }

        _ = try BookLibraryReconciler(
            rootDirectory: iCloudRoot,
            legacyDirectories: [],
            tempSweepDirectories: [iCloudRoot, localRoot]
        ).reconcile(context: context)

        #expect(!FileManager.default.fileExists(atPath: staleICloud.path))
        #expect(!FileManager.default.fileExists(atPath: staleLocal.path))
    }

    @Test func uniqueDirectoriesKeepsFirstOccurrenceByStandardizedPath() {
        let first = URL(fileURLWithPath: "/tmp/bav-x/Books")
        let duplicate = URL(fileURLWithPath: "/tmp/bav-x/./Books/")
        let other = URL(fileURLWithPath: "/tmp/bav-y/Books")

        #expect(BookLibraryReconciler.uniqueDirectories([first, duplicate, other]) == [first, other])
    }

    @Test func defaultTempSweepScopeIsRootOnlySoTestsNeverTouchRealBooksDirectories() {
        let root = URL(fileURLWithPath: "/tmp/bav-default-scope/Books")

        let reconciler = BookLibraryReconciler(rootDirectory: root, legacyDirectories: [])

        #expect(reconciler.tempSweepDirectories == [root])
    }

    @Test func productionTempSweepScopeCoversLocalAndICloudBooksDirectories() {
        let production = BookLibraryReconciler.productionTempSweepDirectories

        #expect(production.contains(Book.localBooksDirectory))
        if let iCloud = Book.iCloudBooksDirectory {
            #expect(production.contains(iCloud))
        }
    }

    @Test func reconcilerRebuildsMissingRowFromManifestAndFile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bookId = UUID()
        let fileName = "manifest-backed.epub"
        try Data("epub".utf8).write(to: root.appendingPathComponent(fileName))
        try BookManifestStore(rootDirectory: root).write(BookManifest(
            bookId: bookId,
            fileName: fileName,
            originalFileName: "Original.epub",
            title: "Manifest Backed",
            author: "Author",
            format: .epub,
            coverImageData: Data([9]),
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            dateLastRead: Date(timeIntervalSince1970: 1_700_000_100),
            progression: 0.5,
            lastReadLocatorJSON: #"{"href":"x"}"#,
            preferredNotebookId: "nb"
        ))

        let result = try BookLibraryReconciler(rootDirectory: root).reconcile(context: context)

        let book = try #require(try context.fetch(FetchDescriptor<Book>()).first)
        #expect(result.recoveredRows == 1)
        #expect(book.id == bookId)
        #expect(book.title == "Manifest Backed")
        #expect(book.author == "Author")
        #expect(book.coverImageData == Data([9]))
        #expect(book.epubFileName == fileName)
        #expect(book.format == .epub)
        #expect(book.dateLastRead == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(book.progression == 0.5)
        #expect(book.lastReadLocatorJSON == #"{"href":"x"}"#)
        #expect(book.preferredNotebookId == "nb")
    }

    @Test func reconcilerWritesMissingManifestForExistingRow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let book = Book(title: "Row Only", author: "", fileName: "row-only.pdf", format: .pdf)
        context.insert(book)
        try context.save()
        try Data("pdf".utf8).write(to: root.appendingPathComponent(book.epubFileName))

        let result = try BookLibraryReconciler(rootDirectory: root).reconcile(context: context)

        let manifest = try BookManifestStore(rootDirectory: root).read(bookId: book.id)
        #expect(result.writtenManifests == 1)
        #expect(manifest.bookId == book.id)
        #expect(manifest.fileName == "row-only.pdf")
        #expect(manifest.title == "Row Only")
        #expect(manifest.format == .pdf)
    }

    @Test func reconcilerBackfillsFallbackRowFromManifestMetadata() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileName = "F9634750-1CEE-4E8E-A7A7-13594801B886.epub"
        try Data("epub".utf8).write(to: root.appendingPathComponent(fileName))
        let bookId = UUID()
        let book = Book(title: "F9634750-1CEE-4E8E-A7A7-13594801B886", author: "", fileName: fileName, format: .epub)
        book.id = bookId
        context.insert(book)
        try context.save()
        try BookManifestStore(rootDirectory: root).write(BookManifest(
            bookId: bookId,
            fileName: fileName,
            originalFileName: "Real Book.epub",
            title: "Real Book",
            author: "Author",
            format: .epub,
            coverImageData: Data([4, 5, 6]),
            dateAdded: Date(timeIntervalSince1970: 1),
            dateLastRead: Date(timeIntervalSince1970: 2),
            progression: 0.33,
            lastReadLocatorJSON: #"{"href":"chapter"}"#,
            preferredNotebookId: "nb"
        ))

        let result = try BookLibraryReconciler(rootDirectory: root).reconcile(context: context)

        let saved = try #require(try context.fetch(FetchDescriptor<Book>()).first)
        #expect(result.updatedRows == 1)
        #expect(saved.title == "Real Book")
        #expect(saved.author == "Author")
        #expect(saved.coverImageData == Data([4, 5, 6]))
        #expect(saved.progression == 0.33)
        #expect(saved.lastReadLocatorJSON == #"{"href":"chapter"}"#)
        #expect(saved.preferredNotebookId == "nb")
    }

    @Test func reconcilerDoesNotPersistManifestForMetadataPoorFallbackRow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileName = "D8D20CE3-F60E-45E0-9410-12D0A5DCCD78.epub"
        try Data("epub".utf8).write(to: root.appendingPathComponent(fileName))
        let book = Book(title: "D8D20CE3-F60E-45E0-9410-12D0A5DCCD78", author: "", fileName: fileName, format: .epub)
        context.insert(book)
        try context.save()

        let result = try BookLibraryReconciler(rootDirectory: root).reconcile(context: context)

        #expect(result.writtenManifests == 0)
        let persistedManifest = try? BookManifestStore(rootDirectory: root).read(bookId: book.id)
        #expect(persistedManifest == nil)
    }

    @Test func reconcilerDoesNotCreateBareRowsDuringNormalCloudStartup() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("epub".utf8).write(to: root.appendingPathComponent("D8D20CE3-F60E-45E0-9410-12D0A5DCCD78.epub"))

        let result = try BookLibraryReconciler(rootDirectory: root).reconcile(context: context)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(result.recoveredRows == 0)
        #expect(books.isEmpty)
    }

    @Test func reconcilerRemovesDuplicateRowsForSameFileNameKeepingMetadataRichRow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileName = "7DB3287F-F3E0-4C76-BE97-AC150B8DD4BD.epub"
        try Data("epub".utf8).write(to: root.appendingPathComponent(fileName))

        let cloudBacked = Book(
            title: "Real Book Title",
            author: "Author",
            coverImageData: Data([1, 2, 3]),
            fileName: fileName,
            format: .epub
        )
        cloudBacked.progression = 0.4
        let recoveredBare = Book(
            title: "7DB3287F-F3E0-4C76-BE97-AC150B8DD4BD",
            author: "",
            fileName: fileName,
            format: .epub
        )
        context.insert(cloudBacked)
        context.insert(recoveredBare)
        try context.save()

        let result = try BookLibraryReconciler(rootDirectory: root).reconcile(context: context)

        let books = try context.fetch(FetchDescriptor<Book>())
        let book = try #require(books.first)
        #expect(result.duplicateRowsRemoved == 1)
        #expect(books.count == 1)
        #expect(book.id == cloudBacked.id)
        #expect(book.title == "Real Book Title")
        #expect(book.progression == 0.4)
    }

    @Test func reconcilerRemovesDuplicateRowsEvenWhenRowsShareDomainId() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileName = "F9634750-1CEE-4E8E-A7A7-13594801B886.epub"
        try Data("epub".utf8).write(to: root.appendingPathComponent(fileName))

        let sharedId = UUID()
        let metadataRich = Book(
            title: "Metadata Rich",
            author: "Author",
            coverImageData: Data([1, 2, 3]),
            fileName: fileName,
            format: .epub
        )
        metadataRich.id = sharedId
        metadataRich.progression = 0.75
        let staleDuplicate = Book(
            title: "F9634750-1CEE-4E8E-A7A7-13594801B886",
            author: "",
            fileName: fileName,
            format: .epub
        )
        staleDuplicate.id = sharedId
        context.insert(metadataRich)
        context.insert(staleDuplicate)
        try context.save()

        let result = try BookLibraryReconciler(rootDirectory: root).reconcile(context: context)

        let books = try context.fetch(FetchDescriptor<Book>())
        let book = try #require(books.first)
        #expect(result.duplicateRowsRemoved == 1)
        #expect(books.count == 1)
        #expect(book.title == "Metadata Rich")
        #expect(book.progression == 0.75)
    }

    @Test func reconcilerCollapsesMixedDuplicateRowsAndMergesReadingMetadata() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileName = "mixed-duplicate.epub"
        try Data("epub".utf8).write(to: root.appendingPathComponent(fileName))
        let sharedId = UUID()

        let keeperCandidate = Book(
            title: "Real Title",
            author: "Author",
            coverImageData: Data([7]),
            fileName: fileName,
            format: .epub
        )
        keeperCandidate.id = sharedId
        keeperCandidate.dateAdded = Date(timeIntervalSince1970: 20)
        keeperCandidate.progression = 0.2
        keeperCandidate.dateLastRead = Date(timeIntervalSince1970: 30)

        let sameIdDuplicateWithNewerPosition = Book(
            title: "mixed-duplicate",
            author: "",
            fileName: fileName,
            format: .epub
        )
        sameIdDuplicateWithNewerPosition.id = sharedId
        sameIdDuplicateWithNewerPosition.dateAdded = Date(timeIntervalSince1970: 10)
        sameIdDuplicateWithNewerPosition.progression = 0.9
        sameIdDuplicateWithNewerPosition.dateLastRead = Date(timeIntervalSince1970: 40)
        sameIdDuplicateWithNewerPosition.lastReadLocatorJSON = #"{"href":"late"}"#
        sameIdDuplicateWithNewerPosition.preferredNotebookId = "nb"

        let differentIdDuplicate = Book(
            title: "mixed-duplicate",
            author: "",
            fileName: fileName,
            format: .epub
        )
        context.insert(keeperCandidate)
        context.insert(sameIdDuplicateWithNewerPosition)
        context.insert(differentIdDuplicate)
        try context.save()

        let result = try BookLibraryReconciler(rootDirectory: root).reconcile(context: context)

        let books = try context.fetch(FetchDescriptor<Book>())
        let book = try #require(books.first)
        #expect(result.duplicateRowsRemoved == 2)
        #expect(books.count == 1)
        #expect(book.title == "Real Title")
        #expect(book.author == "Author")
        #expect(book.coverImageData == Data([7]))
        #expect(book.dateAdded == Date(timeIntervalSince1970: 10))
        #expect(book.progression == 0.9)
        #expect(book.dateLastRead == Date(timeIntervalSince1970: 40))
        #expect(book.lastReadLocatorJSON == #"{"href":"late"}"#)
        #expect(book.preferredNotebookId == "nb")
    }

    @Test func reconcilerToleratesDuplicateManifestsForSameFileName() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileName = "shared.epub"
        try Data("epub".utf8).write(to: root.appendingPathComponent(fileName))
        let store = BookManifestStore(rootDirectory: root)
        try store.write(BookManifest(
            bookId: UUID(),
            fileName: fileName,
            originalFileName: nil,
            title: "shared",
            author: "",
            format: .epub,
            coverImageData: nil,
            dateAdded: Date(timeIntervalSince1970: 1),
            dateLastRead: nil,
            progression: nil,
            lastReadLocatorJSON: nil,
            preferredNotebookId: nil
        ))
        try store.write(BookManifest(
            bookId: UUID(),
            fileName: fileName,
            originalFileName: nil,
            title: "Metadata Rich",
            author: "Author",
            format: .epub,
            coverImageData: Data([1]),
            dateAdded: Date(timeIntervalSince1970: 2),
            dateLastRead: Date(timeIntervalSince1970: 3),
            progression: 0.2,
            lastReadLocatorJSON: nil,
            preferredNotebookId: nil
        ))

        let result = try BookLibraryReconciler(rootDirectory: root).reconcile(context: context)

        let books = try context.fetch(FetchDescriptor<Book>())
        let book = try #require(books.first)
        #expect(result.recoveredRows == 1)
        #expect(books.count == 1)
        #expect(book.title == "Metadata Rich")
        #expect(book.author == "Author")
        #expect(book.progression == 0.2)
    }

    @Test func reconcilerDoesNotDeleteDistinctBooksWithEmptyFileName() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // 兩本不同的書，epubFileName 都還是預設 ""（模擬 CloudKit 部分同步中間態）
        let a = Book(title: "Book A", author: "", fileName: "", format: .epub)
        let b = Book(title: "Book B", author: "", fileName: "", format: .epub)
        context.insert(a)
        context.insert(b)
        try context.save()

        let result = try BookLibraryReconciler(rootDirectory: root).reconcile(context: context)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(result.duplicateRowsRemoved == 0)
        #expect(books.count == 2)
    }

    // MARK: - iCloud 不可用時刪除（#2750）

    private func makeTombstones() -> PendingBookDeletionStore {
        PendingBookDeletionStore(defaults: UserDefaults(suiteName: "PendingDeletion-\(UUID().uuidString)")!)
    }

    private func seedICloudBook(_ fileName: String, bookId: UUID, in icloud: URL) throws {
        try Data("epub".utf8).write(to: icloud.appendingPathComponent(fileName))
        try BookManifestStore(rootDirectory: icloud).write(BookManifest(
            bookId: bookId, fileName: fileName, originalFileName: nil, title: "Gone", author: "A",
            format: .epub, coverImageData: nil, dateAdded: Date(), dateLastRead: nil,
            progression: nil, lastReadLocatorJSON: nil, preferredNotebookId: nil
        ))
    }

    @Test func deleteWhileICloudUnavailableDoesNotResurrectAfterICloudReturns() throws {
        let context = ModelContext(try makeContainer())
        let local = try makeTempRoot()
        let icloud = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: icloud) }
        let bookId = UUID()
        let fileName = "\(UUID().uuidString).epub"
        try seedICloudBook(fileName, bookId: bookId, in: icloud)
        let tombstones = makeTombstones()

        // iCloud 關閉：只解析得到本機位置，刪檔「成功」但 iCloud 副本還在
        try LocalBookFileManager(locations: [local], pendingDeletions: tombstones, iCloudAvailable: { false })
            .deleteBookFile(named: fileName)
        #expect(tombstones.fileNames == [fileName])

        // iCloud 回來：reconcile 必須完成刪除而不是把書救回來
        let result = try BookLibraryReconciler(
            rootDirectory: icloud, legacyDirectories: [], pendingDeletions: tombstones, isICloudAvailable: { true }
        ).reconcile(context: context)

        #expect(result.recoveredRows == 0)
        #expect(try context.fetch(FetchDescriptor<Book>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: icloud.appendingPathComponent(fileName).path))
        #expect(!FileManager.default.fileExists(atPath: BookManifestStore(rootDirectory: icloud).url(for: bookId).path))
        #expect(tombstones.fileNames.isEmpty)
    }

    @Test func tombstoneSurvivesReconcileWhileICloudStillUnavailable() throws {
        let context = ModelContext(try makeContainer())
        let local = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: local) }
        let tombstones = makeTombstones()
        tombstones.insert("pending.epub")

        _ = try BookLibraryReconciler(
            rootDirectory: local, legacyDirectories: [], pendingDeletions: tombstones, isICloudAvailable: { false }
        ).reconcile(context: context)

        #expect(tombstones.fileNames == ["pending.epub"])
    }

    @Test func deleteWhileICloudAvailableRecordsNoTombstone() throws {
        let local = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: local) }
        let tombstones = makeTombstones()
        try LocalBookFileManager(locations: [local], pendingDeletions: tombstones, iCloudAvailable: { true })
            .deleteBookFile(named: "x.epub")
        #expect(tombstones.fileNames.isEmpty)
    }
}
