import Foundation

struct BookManifest: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var bookId: UUID
    var fileName: String
    var originalFileName: String?
    var title: String
    var author: String
    var format: BookFormat
    var coverImageData: Data?
    var dateAdded: Date
    var dateLastRead: Date?
    var progression: Double?
    var lastReadLocatorJSON: String?
    var preferredNotebookId: String?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        bookId: UUID,
        fileName: String,
        originalFileName: String?,
        title: String,
        author: String,
        format: BookFormat,
        coverImageData: Data?,
        dateAdded: Date,
        dateLastRead: Date?,
        progression: Double?,
        lastReadLocatorJSON: String?,
        preferredNotebookId: String?
    ) {
        self.schemaVersion = schemaVersion
        self.bookId = bookId
        self.fileName = fileName
        self.originalFileName = originalFileName
        self.title = title
        self.author = author
        self.format = format
        self.coverImageData = coverImageData
        self.dateAdded = dateAdded
        self.dateLastRead = dateLastRead
        self.progression = progression
        self.lastReadLocatorJSON = lastReadLocatorJSON
        self.preferredNotebookId = preferredNotebookId
    }

    init(book: Book, originalFileName: String? = nil) {
        self.init(
            bookId: book.id,
            fileName: book.epubFileName,
            originalFileName: originalFileName,
            title: book.title,
            author: book.author,
            format: book.format,
            coverImageData: book.coverImageData,
            dateAdded: book.dateAdded,
            dateLastRead: book.dateLastRead,
            progression: book.progression,
            lastReadLocatorJSON: book.lastReadLocatorJSON,
            preferredNotebookId: book.preferredNotebookId
        )
    }
}

enum BookManifestStoreError: Error {
    /// 既有 manifest 的 schemaVersion 比本 app 版本新——讀得懂結構但不該以舊語意覆蓋。
    case unsupportedSchemaVersion(Int)
}

struct BookManifestStore {
    let rootDirectory: URL

    var metadataDirectory: URL {
        rootDirectory.appendingPathComponent(".metadata", isDirectory: true)
    }

    init(rootDirectory: URL = Book.booksDirectory) {
        self.rootDirectory = rootDirectory
    }

    func url(for bookId: UUID) -> URL {
        metadataDirectory.appendingPathComponent("\(bookId.uuidString).json")
    }

    func write(_ manifest: BookManifest) throws {
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(manifest)
        try data.write(to: url(for: manifest.bookId), options: [.atomic])
    }

    /// 從 Book 寫 manifest，但與既有 manifest 合併以防固化髒 metadata。
    ///
    /// reader progress / notebook 綁定的落盤都走這條路；若當下 row 仍是 fallback
    /// （UUID title、空 author、nil cover），既有 manifest 的乾淨值不會被覆蓋。
    /// 閱讀位置 / 日期 / notebook 等則一律採 row 的當前值（那正是這次寫入的目的）。
    func write(book: Book, originalFileName: String? = nil) throws {
        let incoming = BookManifest(book: book, originalFileName: originalFileName)
        try write(Self.merged(incoming: incoming, existing: try existingManifestForMerge(bookId: book.id)))
    }

    /// 合併前讀既有 manifest。把「檔案不存在」與「manifest 損毀」視為無既有
    /// （正常新書 / 需重建）；其他 I/O 錯誤（如 iCloud eviction、暫時讀失敗）往上拋，
    /// 讓 `writeBestEffort` 這次跳過——寧可漏寫一次（下次 progress / reconcile 會補），
    /// 也不要在讀失敗時用 fallback row 蓋掉還在磁碟上的乾淨 manifest。
    ///
    /// 額外守衛：既有 manifest 的 `schemaVersion` 比本版本新（舊 app 讀到新 app 寫的檔）
    /// 時，往上拋讓本次寫入跳過——不可用舊 schema 的理解去覆蓋讀不懂但更新的檔。
    /// （未來新增 manifest 欄位請一律 optional + 提供 default，讓舊 app 仍能 decode，
    /// 才不會落入「decode 失敗→視為無既有→覆蓋」的盲區。）
    private func existingManifestForMerge(bookId: UUID) throws -> BookManifest? {
        do {
            let manifest = try read(bookId: bookId)
            if manifest.schemaVersion > BookManifest.currentSchemaVersion {
                throw BookManifestStoreError.unsupportedSchemaVersion(manifest.schemaVersion)
            }
            return manifest
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch is DecodingError {
            return nil
        }
    }

    /// 合併策略：incoming 為主，但 fallback/空/nil 的識別性欄位讓位給既有乾淨值。
    static func merged(incoming: BookManifest, existing: BookManifest?) -> BookManifest {
        guard let existing else { return incoming }
        var result = incoming
        if BookMetadataHeuristics.looksLikeFallbackTitle(incoming.title, fileName: incoming.fileName),
           !BookMetadataHeuristics.looksLikeFallbackTitle(existing.title, fileName: existing.fileName) {
            result.title = existing.title
        }
        if BookMetadataHeuristics.looksLikeFallbackAuthor(incoming.author),
           !BookMetadataHeuristics.looksLikeFallbackAuthor(existing.author) {
            result.author = existing.author
        }
        if incoming.coverImageData == nil, let cover = existing.coverImageData {
            result.coverImageData = cover
        }
        if incoming.originalFileName == nil, let original = existing.originalFileName {
            result.originalFileName = original
        }
        // 保留既有 dateAdded；只有 existing 完全缺值時才用 incoming（新書首寫）。
        result.dateAdded = existing.dateAdded
        return result
    }

    func writeBestEffort(book: Book, originalFileName: String? = nil) {
        do {
            try write(book: book, originalFileName: originalFileName)
        } catch {
            AppLog.book.warning("Book manifest write failed (\(book.epubFileName)): \(error.localizedDescription)")
        }
    }

    func read(bookId: UUID) throws -> BookManifest {
        let data = try Data(contentsOf: url(for: bookId))
        return try Self.decoder.decode(BookManifest.self, from: data)
    }

    func readAll() -> [BookManifest] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                do {
                    return try Self.decoder.decode(BookManifest.self, from: Data(contentsOf: url))
                } catch {
                    // 容錯跳過損壞 / 半寫 / 未來版本的 manifest，但**不靜默**：reconcile 完全
                    // 依賴 readAll 作為恢復權威，少一筆 = 該書 metadata 救援能力消失，必須可診斷
                    // （例如除錯「重啟後書名變了」）。
                    AppLog.book.warning("Book manifest skipped (unreadable \(url.lastPathComponent, privacy: .public)): \(error.localizedDescription)")
                    return nil
                }
            }
    }

    /// 只在書籍檔案已刪除後呼叫；manifest 單獨殘留不會讓書復活（reconcile 以磁碟上的書檔為起點），
    /// 故失敗只記 log、不打斷刪除流程。
    func delete(bookId: UUID) {
        let target = url(for: bookId)
        do {
            try FileManager.default.removeItem(at: target)
        } catch where LocalBookFileManager.isFileAbsent(error) {
            return
        } catch {
            AppLog.book.warning("Book manifest delete failed (\(target.lastPathComponent, privacy: .public)): \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// iCloud 不可用時刪除的書（#2750）：此時 `defaultLocations()` 解析不到 iCloud 目錄，
/// 刪檔會「成功」但 iCloud 的檔案與 manifest 還在，iCloud 回來後 reconcile 會把書救回。
/// 這裡在**本機**記下待補刪的檔名（UserDefaults，不進 iCloud），由 reconciler 在 iCloud 可用時完成刪除。
struct PendingBookDeletionStore {
    private static let key = "pendingBookDeletionFileNames"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static var standard: PendingBookDeletionStore { PendingBookDeletionStore() }

    /// 上限：不以 iCloud 登入狀態把關（見 `LocalBookFileManager.deleteBookFile`），沒用 iCloud 的人永遠不會消耗 tombstone，
    /// 以此封頂（保留最新的，檔名是 UUID 不會誤刪在庫書）。
    static let maxEntries = 200

    private var ordered: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    var fileNames: Set<String> { Set(ordered) }

    func insert(_ fileName: String) {
        let kept = ordered.filter { $0 != fileName } + [fileName]
        defaults.set(Array(kept.suffix(Self.maxEntries)), forKey: Self.key)
    }

    func remove(_ fileName: String) {
        defaults.set(ordered.filter { $0 != fileName }, forKey: Self.key)
    }
}
