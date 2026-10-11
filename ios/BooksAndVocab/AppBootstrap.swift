//
//  AppBootstrap.swift
//  Books & Vocab
//
//  SwiftData ModelContainer bootstrap + 失敗恢復路徑。
//  從 BooksAndVocabApp 拆出 — 集中管理 store schema、fallback、explicit purge。
//

import Foundation
import os
import SwiftData

enum AppBootstrap {
    struct Outcome {
        let container: ModelContainer
        let failure: AppStartupFailure?
    }

    struct PersistentStoreLocations {
        let local: URL
        let cloud: URL
    }

    /// 完整 store schema 的唯一真相 — 新增 @Model 時只改這裡，
    /// 避免 6 處重複的型別清單彼此 drift。
    static let fullModelTypes: [any PersistentModel.Type] = [
        Book.self, VocabularyEntry.self, ReviewRecord.self, Notebook.self,
        NotebookSettingsProjection.self,
        PodcastSeries.self, PodcastEpisode.self, PodcastProgress.self,
        SharedDeck.self
    ]

    @MainActor
    static func run(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        persistentStoreLocations: PersistentStoreLocations? = nil,
        persistentContainerFactory: (() throws -> ModelContainer)? = nil,
        iCloudMigrationFileOps: ICloudEPUBMigration.FileOps = .live
    ) -> Outcome {
        // UI-test / probe 隔離（2026-06-10 事故）：fixture 會 wipe+seed
        // VocabularyEntry，掛真用戶 on-disk store 等於清掉整個本地單字庫；
        // CloudKit 一併斷開，真機跑 probe 不得污染 iCloud。fixture seed 端
        // 另有 in-memory guard（UITestFixtureSeed），雙層互為防線。
        // arguments 注入縫供單元測試釘住這一層（預設讀真實 ProcessInfo）。
        if AppRuntimeOptions.isUITesting(arguments: arguments) {
            let ephemeral = makeFallbackModelContainer()
            AuthManager.shared.modelContainer = ephemeral
            CloudKitMirroringMonitor.shared.configure(cloudKitEnabled: false)
            AppLog.app.info("UI-testing: ephemeral in-memory ModelContainer (no CloudKit)")
            return Outcome(container: ephemeral, failure: nil)
        }

        // 一次性自癒：清除舊版寫入的非法 review-event pull watermark，避免後端 400
        // 造成的背景同步死鎖（必須早於任何 sync 觸發）。
        KGService.migrateReviewEventBoundaryIfNeeded()

        // #2552：清掉上次 session 殘留的匯出暫存（含個人單字資料）；純 file I/O，不阻塞啟動。
        Task.detached(priority: .utility) { VocabularyExporter.purgeStaleExports() }

        let localSchema = Schema([
            VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            NotebookSettingsProjection.self,
            PodcastSeries.self, PodcastEpisode.self, SharedDeck.self,
        ])
        let cloudSchema = Schema([Book.self, PodcastProgress.self])
        let localConfig: ModelConfiguration
        let cloudConfig: ModelConfiguration
        if let persistentStoreLocations {
            localConfig = ModelConfiguration(
                "LocalStore",
                schema: localSchema,
                url: persistentStoreLocations.local,
                cloudKitDatabase: .none
            )
            cloudConfig = ModelConfiguration(
                "CloudStore",
                schema: cloudSchema,
                url: persistentStoreLocations.cloud,
                cloudKitDatabase: .automatic
            )
        } else {
            localConfig = ModelConfiguration(
                "LocalStore",
                schema: localSchema,
                cloudKitDatabase: .none
            )
            cloudConfig = ModelConfiguration(
                "CloudStore",
                schema: cloudSchema,
                cloudKitDatabase: .automatic
            )
        }

        do {
            let container: ModelContainer
            if let persistentContainerFactory {
                container = try persistentContainerFactory()
            } else {
                container = try ModelContainer(
                    for: Schema(fullModelTypes),
                    configurations: localConfig, cloudConfig
                )
            }
            AuthManager.shared.modelContainer = container
            CloudKitMirroringMonitor.shared.configure(cloudKitEnabled: true)
            CloudKitMirroringMonitor.shared.start()
            // #2107：ubiquity lookup 與 EPUB 複製全是 file I/O，不碰 SwiftData，
            // 丟到 detached task；App.init 不等它。
            ICloudEPUBMigration.schedule(fileOps: iCloudMigrationFileOps)
            AppLog.app.info("ModelContainer initialized — models: \(fullModelTypes.map { String(describing: $0) }.joined(separator: ", "))")
            return Outcome(container: container, failure: nil)
        } catch {
            // A persistent-store initialization error can be a migration or
            // CloudKit failure. Never turn that signal into an automatic
            // destructive reset: pending local cards may not exist remotely.
            // Keep the files intact and let the explicit recovery UI own purge.
            AppLog.app.error("ModelContainer init failed: \(error.localizedDescription) — preserving stores and entering recovery")
            let fallback = makeFallbackModelContainer()
            // 仍把 fallback 交給 AuthManager，使降級後的記憶體 store 在帳號切換時
            // 一樣可被 clearLocalData 清除（與上方兩條成功路徑對齊，避免 nil 時靜默跳過清理）。
            AuthManager.shared.modelContainer = fallback
            CloudKitMirroringMonitor.shared.configure(cloudKitEnabled: false)
            return Outcome(
                container: fallback,
                failure: AppStartupFailure.storageInitialization(error: error)
            )
        }
    }

    private static func makeFallbackModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(
                for: Schema(fullModelTypes),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            )
        } catch {
            // Fail-soft: 最小 schema in-memory container 讓 AppStartupRecoveryView 仍可顯示而不直接 crash。
            AppLog.app.critical("Fallback ModelContainer init failed: \(error.localizedDescription); attempting minimal schema")
            if let minimal = try? ModelContainer(
                for: Notebook.self, NotebookSettingsProjection.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ) {
                return minimal
            }
            AppLog.app.critical("Minimal ModelContainer init also failed: \(error.localizedDescription)")
            fatalError("Cannot create any ModelContainer: \(error)")
        }
    }

    static func storeArtifactURLs(for storeURL: URL) -> [URL] {
        ["", "-shm", "-wal"].map { suffix in
            URL(fileURLWithPath: storeURL.path + suffix)
        }
    }

    /// Explicit recovery action only. Returns false when any existing SQLite
    /// artifact could not be removed, so the UI does not report a false reset.
    @discardableResult
    static func purgeStoreFiles(at storeURLs: [URL]? = nil) -> Bool {
        let resolvedStoreURLs: [URL]
        if let storeURLs {
            resolvedStoreURLs = storeURLs
        } else {
            let localURL = ModelConfiguration(
                "LocalStore",
                schema: Schema([Notebook.self]),
                cloudKitDatabase: .none
            ).url
            let cloudURL = ModelConfiguration(
                "CloudStore",
                schema: Schema([Book.self]),
                cloudKitDatabase: .automatic
            ).url
            resolvedStoreURLs = [localURL, cloudURL]
        }

        var succeeded = true
        for storeURL in resolvedStoreURLs {
            for artifactURL in storeArtifactURLs(for: storeURL) {
                guard FileManager.default.fileExists(atPath: artifactURL.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: artifactURL)
                } catch {
                    succeeded = false
                    AppLog.app.error("purgeStoreFiles failed for \(artifactURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            AppLog.app.info("purgeStoreFiles: processed \(storeURL.lastPathComponent)")
        }
        return succeeded
    }
}

/// 一次性「本機 EPUB → iCloud Books 目錄」複製（#2107）。
///
/// - 只做 file I/O，永遠在 detached task 執行（`run` 開頭 assert 非 main thread）。
/// - Resumable／idempotent：每本先 copy 到 staging，再以 rename 原子落到 iCloud 目的地，
///   中斷時目的地不會留下半份檔；下次啟動略過已存在的目的地、清掉殘留 staging 後重做其餘。
/// - Completion key 只在「每本都已在 iCloud 目的地」時寫入；iCloud 不可用或任一本失敗
///   都不寫，留待下次啟動重試。
enum ICloudEPUBMigration {
    /// v2：v1 只搬 .epub 就寫完成旗標，留在本機的 .pdf 永遠不會上 iCloud；
    /// 換 key 讓已完成的使用者再跑一次（目的地已存在者會略過，idempotent）。
    static let completionKey = "iCloudDataMigrationCompleted_v2"

    /// 匯入後會留在本機 Books 目錄、屬於 iCloud 書庫的格式（txt/md 匯入時已轉成 epub）。
    static let migratedExtensions: Set<String> = ["epub", "pdf"]

    /// File-ops seam；每個成員都在背景執行緒被呼叫。
    struct FileOps: Sendable {
        /// 同一 key 同時只允許一個 run（App.init 與 startup-recovery 重試可能重疊）。
        var lockKey: String
        var iCloudBooksDirectory: @Sendable () -> URL?
        var localBooksDirectory: @Sendable () -> URL
        var stagingDirectory: @Sendable () -> URL
        var contentsOfDirectory: @Sendable (URL) throws -> [URL]
        var fileExists: @Sendable (URL) -> Bool
        var createDirectory: @Sendable (URL) throws -> Void
        var copyItem: @Sendable (_ from: URL, _ to: URL) throws -> Void
        var moveItem: @Sendable (_ from: URL, _ to: URL) throws -> Void
        var removeItem: @Sendable (URL) throws -> Void
        var isCompleted: @Sendable () -> Bool
        var markCompleted: @Sendable () -> Void

        static let live = FileOps(
            lockKey: ICloudEPUBMigration.completionKey,
            iCloudBooksDirectory: { Book.iCloudBooksDirectory },
            localBooksDirectory: { Book.localBooksDirectory },
            stagingDirectory: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("iCloudEPUBMigration", isDirectory: true)
            },
            contentsOfDirectory: {
                try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
            },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            createDirectory: {
                try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
            },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            isCompleted: { UserDefaults.standard.bool(forKey: ICloudEPUBMigration.completionKey) },
            markCompleted: { UserDefaults.standard.set(true, forKey: ICloudEPUBMigration.completionKey) }
        )
    }

    enum RunResult: Equatable {
        case alreadyCompleted
        case alreadyRunning
        case deferredICloudUnavailable
        case deferredLocalListingFailed
        case completed(copied: Int, total: Int)
        case incomplete(failed: Int, total: Int)
    }

    private static let inFlight = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// 背景啟動 migration，立即返回。回傳的 task 供測試 await。
    @discardableResult
    static func schedule(
        fileOps: FileOps = .live,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) -> Task<RunResult, Never> {
        Task.detached(priority: .utility) {
            ICloudEPUBMigration.run(fileOps: fileOps, progress: progress)
        }
    }

    static func run(
        fileOps: FileOps,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) -> RunResult {
        assert(!Thread.isMainThread, "ICloudEPUBMigration must run off the main thread (#2107)")
        guard !fileOps.isCompleted() else { return .alreadyCompleted }
        let claimed = inFlight.withLock { $0.insert(fileOps.lockKey).inserted }
        guard claimed else { return .alreadyRunning }
        defer { _ = inFlight.withLock { $0.remove(fileOps.lockKey) } }

        guard let iCloudDir = fileOps.iCloudBooksDirectory() else {
            AppLog.app.info("iCloud not available, deferring book migration")
            return .deferredICloudUnavailable
        }

        let localBooksDir = fileOps.localBooksDirectory()
        let files: [URL]
        do {
            files = try fileOps.contentsOfDirectory(localBooksDir)
        } catch {
            if !fileOps.fileExists(localBooksDir) {
                // 沒有本機 Books 目錄 = 沒有書要搬，視為完成。
                fileOps.markCompleted()
                return .completed(copied: 0, total: 0)
            }
            AppLog.app.warning("Cannot list local books for migration: \(error.localizedDescription) — will retry next launch")
            return .deferredLocalListingFailed
        }

        let books = files.filter { migratedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let staging = fileOps.stagingDirectory()
        var copied = 0
        var failed = 0
        for (index, file) in books.enumerated() {
            defer { progress?(index + 1, books.count) }
            let dest = iCloudDir.appendingPathComponent(file.lastPathComponent)
            if fileOps.fileExists(dest) { continue }
            let staged = staging.appendingPathComponent(file.lastPathComponent)
            do {
                try fileOps.createDirectory(staging)
                // 上次中斷殘留的半份 staging 檔：丟掉重做。
                if fileOps.fileExists(staged) { try fileOps.removeItem(staged) }
                try fileOps.copyItem(file, staged)
                do {
                    try fileOps.moveItem(staged, dest)
                    copied += 1
                } catch {
                    // 並行寫入者（或 iCloud 同步）已先落地：保留目的地，不重複；否則算失敗。
                    guard fileOps.fileExists(dest) else { throw error }
                    try? fileOps.removeItem(staged)
                }
            } catch {
                failed += 1
                try? fileOps.removeItem(staged)
                AppLog.app.error("iCloud book copy failed (\(file.lastPathComponent)): \(error.localizedDescription)")
            }
            AppLog.app.debug("iCloud book migration progress: \(index + 1)/\(books.count)")
        }

        if failed == 0 {
            fileOps.markCompleted()
            AppLog.app.info("iCloud book migration completed: \(copied) copied, \(books.count) total")
            return .completed(copied: copied, total: books.count)
        }
        AppLog.app.warning("iCloud book migration incomplete: \(failed)/\(books.count) failed, will retry next launch")
        return .incomplete(failed: failed, total: books.count)
    }
}
