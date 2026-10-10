import Foundation

/// 至少一個位置的書籍檔案刪除失敗（「檔案本來就不在」不算失敗）。
struct BookFileDeletionError: Error, LocalizedError {
    let fileName: String
    let failures: [(url: URL, error: Error)]

    var errorDescription: String? {
        let detail = failures
            .map { "\($0.url.path): \($0.error.localizedDescription)" }
            .joined(separator: "; ")
        return "book file removal failed (\(fileName)): \(detail)"
    }
}

protocol BookFileManaging: AnyObject {
    /// 刪除書籍檔案；任一位置刪除失敗會在**嘗試完所有位置後**拋出 `BookFileDeletionError`。
    /// 呼叫端必須處理失敗——吞掉會讓 row 已消失、檔案還在，下次 reconcile 書又復活。
    func deleteBookFile(named fileName: String) throws
}

final class LocalBookFileManager: BookFileManaging {
    /// nil = 每次刪除時才解析預設位置：iCloud 目錄可能啟動時不可用、之後才可用
    /// （`Book.iCloudBooksDirectory` 刻意不快取 nil），且解析可能阻塞，不可在 init 固化。
    private let fixedLocations: [URL]?

    private let pendingDeletions: PendingBookDeletionStore?
    private let iCloudAvailable: () -> Bool

    private let recordsTombstone: Bool

    /// `pendingDeletions` 預設：用預設位置（正式路徑）時為 `.standard`，注入固定位置（測試）時為 nil。
    /// `recordsTombstone: false` 給「檔案不可能到過 iCloud」的呼叫端（匯入草稿清理），不留不必要的 tombstone。
    init(
        locations: [URL]? = nil,
        pendingDeletions: PendingBookDeletionStore? = nil,
        iCloudAvailable: @escaping () -> Bool = { Book.iCloudBooksDirectory != nil },
        recordsTombstone: Bool = true
    ) {
        self.fixedLocations = locations
        self.pendingDeletions = pendingDeletions ?? (locations == nil ? .standard : nil)
        self.iCloudAvailable = iCloudAvailable
        self.recordsTombstone = recordsTombstone
    }

    static func defaultLocations() -> [URL] {
        var urls: [URL] = []
        // 檔案可能在 iCloud 或本機（或兩者都有），同時清理
        if let iCloudDir = Book.iCloudBooksDirectory { urls.append(iCloudDir) }
        urls.append(Book.localBooksDirectory)
        // Legacy fallback: also check old EPUBs directory
        urls.append(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("EPUBs")
        )
        return urls
    }

    func deleteBookFile(named fileName: String) throws {
        // 空檔名會讓 appendingPathComponent 指回目錄本身 → removeItem 會整個目錄刪掉
        guard !fileName.isEmpty else { return }

        var failures: [(url: URL, error: Error)] = []
        for location in fixedLocations ?? Self.defaultLocations() {
            // 只存在於其中一個位置是常態；已達成「不存在」即視為成功。
            // 已被 iCloud 驅逐的書只剩隱藏的 .<name>.icloud placeholder，也必須一併移除（#2723），
            // 否則 reconciler 會把它還原成書、下載管理器再把檔案下載回每台裝置。
            Self.removeIfPresent(location.appendingPathComponent(fileName), label: "book file", failures: &failures)
            Self.removeIfPresent(location.appendingPathComponent(Self.icloudPlaceholderName(for: fileName)), label: "book placeholder", failures: &failures)
            Self.removeOriginals(forEpub: fileName, in: location, failures: &failures)
        }
        if !failures.isEmpty {
            throw BookFileDeletionError(fileName: fileName, failures: failures)
        }

        // iCloud 不可用時解析不到 iCloud 目錄，刪不到它的副本：記 tombstone，iCloud 回來時由 reconciler 補刪（#2750）。
        // 只在本機刪除全部成功（失敗時書列仍在，不可留下之後會刪掉在庫書的 tombstone）時記錄。
        // 不以 `ubiquityIdentityToken` 把關：iCloud Drive / App 開關關閉時該值是否為 nil 未經實機驗證，
        // 誤判會讓 #2750 失效；改由 `PendingBookDeletionStore.maxEntries` 限制未被消耗的 tombstone 數量。
        // 殘餘：iCloud 剛回來但檔案尚未同步時，補刪可能落空。
        guard recordsTombstone, let pendingDeletions, !iCloudAvailable() else { return }
        pendingDeletions.insert(fileName)
    }

    /// TXT/MD 匯入時保留的原始檔副本名稱：由 EPUB 檔名（含 UUID，天然唯一）推導，
    /// 讓匯入與刪除共用同一規則，不依賴會撞名的來源檔名（#2440）。
    static func originalCopyName(forEpub fileName: String, sourceExt: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        return "\(stem).\(sourceExt.lowercased())"
    }

    /// 刪除某位置下該書的 Originals 副本（txt / md）；不存在視為已達成。
    private static func removeOriginals(
        forEpub fileName: String,
        in location: URL,
        failures: inout [(url: URL, error: Error)]
    ) {
        let originals = location.appendingPathComponent("Originals", isDirectory: true)
        for ext in ["txt", "md"] {
            let url = originals.appendingPathComponent(originalCopyName(forEpub: fileName, sourceExt: ext))
            removeIfPresent(url, label: "book original", failures: &failures)
            removeIfPresent(
                url.deletingLastPathComponent().appendingPathComponent(icloudPlaceholderName(for: url.lastPathComponent)),
                label: "book original placeholder",
                failures: &failures
            )
        }
    }

    /// iCloud 驅逐後的 placeholder 名稱：`.<name>.icloud`（與 `Book.resolveFileURL`、reconciler 同規則）。
    static func icloudPlaceholderName(for fileName: String) -> String { ".\(fileName).icloud" }

    private static func removeIfPresent(_ url: URL, label: String, failures: inout [(url: URL, error: Error)]) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch where isFileAbsent(error) {
            return
        } catch {
            AppLog.book.error("\(label, privacy: .public) removal failed (\(url.path, privacy: .public)): \(error.localizedDescription)")
            failures.append((url, error))
        }
    }

    static func isFileAbsent(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isFileAbsent(underlying)
        }
        return false
    }
}
