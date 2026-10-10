#if os(iOS)
import Foundation
import SwiftData
import TipKit
import os

@MainActor protocol BookshelfCoordinating: AnyObject, Observable {
    var isImporting: Bool { get set }
    var isLoading: Bool { get }
    var loadingMessage: String { get }
    /// 目前匯入的進度（0.0–1.0）；nil 表示未知或尚未取得（顯示 indeterminate spinner）。
    var loadingProgress: Double? { get }
    var errorMessage: String? { get }
    var errorDiagnosis: String? { get }
    var showError: Bool { get set }
    var showSettings: Bool { get set }
    func presentImporter()
    func presentSettings()
    /// 關閉即時 alert，但保留 errorMessage / errorDiagnosis 供 inline banner 持續顯示
    func dismissError()
    /// 完全清掉 inline error 狀態（由 banner 的 dismiss CTA 呼叫）
    func clearError()
    func handleFileImport(_ result: Result<[URL], Error>, modelContext: ModelContext, importService: any BookshelfImporting, toastCoordinator: AppToastCoordinator)
    func deleteBook(_ book: Book, modelContext: ModelContext, fileManager: any BookFileManaging, toastCoordinator: AppToastCoordinator)
    func sync(container: ModelContainer, kgService: any BackgroundSyncing, isLoggedIn: Bool, isDemoMode: Bool, toastCoordinator: AppToastCoordinator) async
}

@Observable @MainActor
final class BookshelfCoordinator: BookshelfCoordinating {
    var isImporting = false
    var isLoading = false
    var loadingMessage = ""
    var loadingProgress: Double?
    var errorMessage: String?
    var errorDiagnosis: String?
    var showError = false
    var showSettings = false

    // Tracks the in-flight batch-import loop. Held so a new batch cancels a
    // stale one (no two loops racing on loadingProgress/isLoading) and so the
    // session can be torn down. The loop is [weak self] + checks Task.isCancelled
    // per file, so a cancelled import stops promptly instead of running every
    // remaining file to completion and mutating state on a dead coordinator.
    private var importTask: Task<Void, Never>?

    // Monotonically bumped per batch. The progress callback hops to the
    // MainActor via an unstructured Task that does NOT inherit importTask's
    // cancellation, so a late progress Task from batch A could land after
    // batch B already reset loadingProgress = 0 (the monotonic max guard
    // can't catch this — max(0, ratioA) still writes ratioA). Each batch
    // captures its generation; a stale write is dropped on gen mismatch.
    private var importGeneration = 0

    // Files of the current batch that have not started yet. A superseding batch
    // inherits them (ahead of its own files) so queued files are imported instead
    // of being silently dropped with the cancelled loop.
    private var unstartedImportURLs: [URL] = []

    func presentImporter() {
        // 匯入進行中不開啟選檔：否則新批次會取消進行中的批次（見 performBatchImport）。
        guard !isLoading else { return }
        // 新一輪匯入觸發前清掉殘留的 inline error，避免持續顯示已過期的失敗訊息
        clearError()
        isImporting = true
    }

    func presentSettings() {
        showSettings = true
    }

    func dismissError() {
        // 只關 alert；errorMessage / errorDiagnosis 由 inline banner 接手呈現持續性錯誤
        showError = false
    }

    func clearError() {
        errorMessage = nil
        errorDiagnosis = nil
        showError = false
    }

    func handleFileImport(
        _ result: Result<[URL], Error>,
        modelContext: ModelContext,
        importService: any BookshelfImporting,
        toastCoordinator: AppToastCoordinator
    ) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            performBatchImport(
                urls: urls,
                modelContext: modelContext,
                importService: importService,
                toastCoordinator: toastCoordinator
            )
        case .failure(let error):
            guard !Self.isFileImporterCancellation(error) else { return }
            let typed = BookshelfImportError.classify(error)
            errorMessage = typed.errorDescription
            errorDiagnosis = typed.diagnosisLabel
            showError = true
        }
    }

    private static func isFileImporterCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.Code.userCancelled.rawValue
    }

    /// Resolve the appropriate import method for a given file extension.
    /// Returns nil if the extension is not supported.
    /// 回傳的 closure 接受 URL + 進度 callback；callback 由背景執行緒呼叫。
    private func importMethod(
        for ext: String,
        using service: any BookshelfImporting
    ) -> ((URL, @escaping @Sendable (Double) -> Void) async throws -> ImportedBookDraft)? {
        switch ext {
        case "epub": return { try await service.importBook(from: $0, progress: $1) }
        case "txt":  return { try await service.importTXT(from: $0, progress: $1) }
        case "md":   return { try await service.importMD(from: $0, progress: $1) }
        case "pdf":  return { try await service.importPDF(from: $0, progress: $1) }
        default:     return nil
        }
    }

    func deleteBook(
        _ book: Book,
        modelContext: ModelContext,
        fileManager: any BookFileManaging,
        toastCoordinator: AppToastCoordinator
    ) {
        // 刪除是「刪檔 → 暫存 DB 變更 → save」：檔案刪除失敗時 DB 與單字連結完全沒被碰過
        // （若先 save 再刪檔，失敗時 row 已沒、檔案還在，使用者看到「已刪除」後
        // AppOrphanBookRecovery 又讓書復活）。刻意不用「先暫存、失敗再 rollback()」來還原：
        // CI（Xcode 26.5、iOS 26.4 simulator）實測 rollback() 之後，已載入的 VocabularyEntry
        // 實例 bookId 仍是暫存的 nil（持久層正確、記憶體實例不一致，hasChanges 卻是 false），
        // 書架 UI 讀的正是這些實例。rollback() 會丟棄 context 內**所有**未存變更，故先把既有 pending 變更
        // （autosave 尚未落盤者）沖掉，讓 save 失敗時的 rollback 只涵蓋本次刪除。
        if modelContext.hasChanges {
            guard modelContext.safeSaveWithToast(toastCoordinator) else { return }
        }

        let bookId = book.id
        let fileName = book.epubFileName  // 先捕捉：row 刪除後再讀 property 可能已 fault
        do {
            try fileManager.deleteBookFile(named: fileName)
        } catch {
            AppLog.book.error("delete book: file removal failed, keeping book and links bookId=\(bookId): \(error.localizedDescription)")
            toastCoordinator.error(L10n.string("刪除失敗，書籍檔案無法移除"))
            return
        }

        // Manual cascade: clear bookId on related vocabulary entries
        var descriptor = FetchDescriptor<VocabularyEntry>()
        descriptor.predicate = #Predicate<VocabularyEntry> { $0.bookId == bookId }
        do {
            let entries = try modelContext.fetch(descriptor)
            for entry in entries {
                entry.bookId = nil
            }
        } catch {
            AppLog.book.error("delete cascade: vocab fetch failed for bookId=\(bookId): \(error.localizedDescription)")
        }

        modelContext.delete(book)
        // save 失敗（罕見）：檔案已刪但 row 回滾保留、manifest 不動 → metadata 不遺失，
        // 再刪一次即可完成（缺檔不算刪除失敗）。持久層無損；已載入單字實例的 bookId 可能
        // 仍是暫存的 nil（見上），重啟後以持久層為準，此罕見路徑不另行補還原。
        guard modelContext.safeSaveWithToast(toastCoordinator) else {
            modelContext.rollback()
            return
        }
        BookManifestStore().delete(bookId: bookId)
        toastCoordinator.success("已刪除".localized)
    }

    // 顯式同步重入守衛 — 只保護**經本 coordinator 的路徑**：Mac toolbar 鈕連點 +
    // iOS pull-to-refresh（後者 `.refreshable` 本就序列化，故實質主要防 toolbar 連點）。
    // ⌘R menu 路徑直呼 `ExplicitSync.run`、不經本 coordinator，故**不**受此守衛保護，
    // 僅靠底層 `claimBackgroundSync()` 網路層互斥；其殘留為極端連點時可能多彈一次成功
    // toast，無資料風險（要統一須把守衛上移為共享狀態，但會與並行測試衝突，不划算）。
    // 為何需要本層守衛：claim 失敗時 `backgroundSync` 早退（見 `KGService+Sync`）而
    // `lastBackgroundSyncError` 已在 claim 後被重置為 nil → 第二個 Task 的
    // `ExplicitSync.run` 會讀到 nil 誤彈「同步完成」(該輪根本沒跑)。守衛在抵達
    // `claimBackgroundSync()` 前就擋掉重入。對齊 `SettingsCoordinator.resync` 的 `isResyncing`。
    private var isSyncing = false

    func sync(
        container: ModelContainer,
        kgService: any BackgroundSyncing,
        isLoggedIn: Bool,
        isDemoMode: Bool,
        toastCoordinator: AppToastCoordinator
    ) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await ExplicitSync.run(
            kgService: kgService,
            isLoggedIn: isLoggedIn,
            isDemoMode: isDemoMode,
            container: container,
            toastCoordinator: toastCoordinator
        )
    }

    private func performBatchImport(
        urls requested: [URL],
        modelContext: ModelContext,
        importService: any BookshelfImporting,
        toastCoordinator: AppToastCoordinator
    ) {
        // Files the superseded batch never started come first, so they are imported
        // rather than dropped. The in-flight file is still discarded by its loop.
        let urls = unstartedImportURLs + requested
        unstartedImportURLs = []

        // Cancel any prior in-flight batch so two loops can't race on shared
        // loading state.
        importTask?.cancel()

        // New batch generation — late progress callbacks from the prior batch
        // captured the old value and will be dropped (see onProgress below).
        importGeneration += 1
        let generation = importGeneration

        // 新一輪批次開始前清掉前次失敗殘留的 inline error，否則全成功時只發
        // 成功 toast、舊 error banner 仍掛著會誤導使用者以為這次也沒匯成功。
        clearError()

        isLoading = true
        loadingProgress = nil
        let total = urls.count
        loadingMessage = total > 1
            ? L10n.format("正在匯入 %@ / %@...", "1", String(total))
            : L10n.string("正在匯入...")

        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = 0
            var failures: [(name: String, diagnosed: BookshelfImportError)] = []

            for (index, url) in urls.enumerated() {
                // Stop promptly if the import was cancelled (new batch / teardown)
                // instead of running every remaining file and mutating dead state.
                guard self.isCurrentImport(generation) else { return }
                self.unstartedImportURLs = Array(urls.dropFirst(index + 1))
                if total > 1 {
                    loadingMessage = L10n.format("正在匯入 %@ / %@...", String(index + 1), String(total))
                }
                loadingProgress = 0.0

                let ext = url.pathExtension.lowercased()
                guard let method = importMethod(for: ext, using: importService) else {
                    failures.append((url.lastPathComponent, .unsupportedExtension(ext)))
                    continue
                }

                // 背景 callback hop 回 MainActor 更新 UI。
                // 多個 detached Task 的 MainActor 執行順序不保證 → 高 ratio 可能先寫、
                // 低 ratio 後到致進度條倒退。以 monotonic guard 取 max 防回退。
                // reset（loadingProgress = 0.0，:142）是同步直接賦值、不走此 guard，
                // 故跨檔換檔時新檔的 0 起點不會被舊檔高值卡住。
                let onProgress: @Sendable (Double) -> Void = { ratio in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Drop writes from a superseded batch: a late callback
                        // would otherwise overwrite the fresh batch's reset-to-0.
                        guard generation == self.importGeneration else { return }
                        self.loadingProgress = max(self.loadingProgress ?? 0, ratio)
                    }
                }

                do {
                    AppLog.book.info("BookshelfCoordinator: starting import from \(url)")
                    let draft = try await method(url, onProgress)
                    // An importer may ignore cancellation and complete after a newer
                    // batch has started. Never let that stale result reach SwiftData,
                    // and drop the file it already wrote so it isn't orphaned.
                    // This is the only await-adjacent guard: everything below runs
                    // synchronously on MainActor until the save, so generation can't change.
                    guard self.isCurrentImport(generation) else {
                        try? LocalBookFileManager(recordsTombstone: false).deleteBookFile(named: draft.fileName)
                        return
                    }
                    AppLog.book.info("Import succeeded: \(draft.fileName)")
                    AppLog.book.info("Book draft: title=\(draft.title), author=\(draft.author), coverBytes=\(draft.coverImageData?.count ?? 0)")

                    let book = Book(
                        title: draft.title,
                        author: draft.author,
                        coverImageData: draft.coverImageData,
                        fileName: draft.fileName,
                        format: draft.format
                    )
                    modelContext.insert(book)
                    if modelContext.safeSaveWithToast(toastCoordinator) {
                        BookManifestStore().writeBestEffort(book: book, originalFileName: url.lastPathComponent)
                        AppLog.book.info("Book saved: \(book.title)")
                        succeeded += 1
                    } else {
                        // Save failed: unstage the Book and drop the imported file so a
                        // later successful save can't resurrect a "failed" import.
                        modelContext.delete(book)
                        try? LocalBookFileManager(recordsTombstone: false).deleteBookFile(named: draft.fileName)
                        failures.append((url.lastPathComponent, .unknown(underlying: "儲存失敗".localized)))
                    }
                } catch is CancellationError {
                    // Cancellation is a control-flow result, not an import failure.
                    // A superseded/cancelled task leaves final state to its successor.
                    guard generation == self.importGeneration, !Task.isCancelled else { return }
                    unstartedImportURLs = []
                    isLoading = false
                    loadingMessage = ""
                    loadingProgress = nil
                    return
                } catch {
                    guard self.isCurrentImport(generation) else { return }
                    AppLog.book.error("BookshelfCoordinator import error: \(error.localizedDescription)")
                    AppLog.book.error("Error type: \(String(describing: type(of: error)))")
                    let diagnosed = BookshelfImportError.classify(error, sourceURL: url)
                    failures.append((url.lastPathComponent, diagnosed))
                }
            }

            // If cancelled mid-loop, leave the final result reporting to whoever
            // cancelled (e.g. the superseding batch) rather than overwriting it.
            guard self.isCurrentImport(generation) else { return }

            unstartedImportURLs = []
            isLoading = false
            loadingMessage = ""
            loadingProgress = nil

            if succeeded > 0 {
                EPUBGuideTip().invalidate(reason: .actionPerformed)
            }

            // 結果回報：依成功/失敗組合決定 toast vs alert
            switch (succeeded, failures.count) {
            case (let s, 0) where s == 1:
                toastCoordinator.success("已匯入".localized)
            case (let s, 0):
                toastCoordinator.success(L10n.format("已匯入 %@ 本", String(s)))
            case (0, 1):
                let f = failures[0]
                errorMessage = f.diagnosed.errorDescription ?? f.name
                errorDiagnosis = f.diagnosed.diagnosisLabel
                showError = true
            case (0, let n):
                errorMessage = batchFailureMessage(failures: failures)
                errorDiagnosis = L10n.format("%@ 本匯入失敗", String(n))
                showError = true
            case (let s, let n):
                toastCoordinator.warning(L10n.format("已匯入 %@ 本，%@ 本失敗", String(s), String(n)))
                errorMessage = batchFailureMessage(failures: failures)
                errorDiagnosis = "部分匯入失敗".localized
                showError = true
            }
        }
    }

    private func isCurrentImport(_ generation: Int) -> Bool {
        generation == importGeneration && !Task.isCancelled
    }

    private func batchFailureMessage(failures: [(name: String, diagnosed: BookshelfImportError)]) -> String {
        failures
            .map { "・\($0.name)：\($0.diagnosed.diagnosisLabel)" }
            .joined(separator: "\n")
    }
}
#endif
