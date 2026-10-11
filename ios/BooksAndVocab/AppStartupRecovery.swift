//
//  AppStartupRecovery.swift
//  Books & Vocab
//
//  Startup 失敗後使用者出口：retry / clearLocalCache / supportMail。
//  與 Views/Startup/AppStartupRecoveryView.swift 對稱（後者是 UI，本檔是 actions）。
//

import Foundation
import SwiftData

enum AppStartupRecovery {
    static func composeSupportMailURL(for failure: AppStartupFailure) -> URL? {
        let recipient = BrandIdentity.supportEmail
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "-"
        let bundleId = Bundle.main.bundleIdentifier ?? "-"

        let subject = L10n.string("[Books & Vocab] 啟動保護模式 — 需要技術協助")
        let bodyLines = [
            L10n.string("您好，我的 App 在啟動時觸發保護模式，需要技術協助。"),
            "",
            L10n.string("--- 請保留以下技術資訊 ---"),
            "Bundle: \(bundleId)",
            "Version: \(version) (\(build))",
            "Failure: \(failure.title)",
            "Detail: \(failure.technicalDetails)"
        ]
        let body = bodyLines.joined(separator: "\n")

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}

extension BooksAndVocabApp {
    @MainActor
    func makeStartupRecoveryActions() -> AppStartupRecoveryActions {
        AppStartupRecoveryActions(
            retry: { @MainActor in
                AppLog.app.info("AppStartupRecoveryView: retry requested")
                let outcome = AppBootstrap.run()
                if outcome.failure == nil {
                    // 重建成功 — 替換 container 並關閉 recovery 畫面。SwiftUI 會以新 container 重掛 view tree。
                    modelContainer = outcome.container
                    startupFailure = nil
                    #if os(iOS)
                    // init 當時 configure 的是 in-memory fallback 容器；不重綁的話 commit 會在舊容器
                    // 找不到 PodcastEpisode 而刪掉已下載的 mp3。與 init 套同一個 skip 條件。
                    if !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: ProcessInfo.processInfo.arguments) {
                        PodcastDownloadManager.shared.configure(modelContainer: outcome.container)
                    }
                    #endif
                    // 先在背景暖 iCloud 目錄快取，reconciler 才不會在 main actor 上做 ubiquity lookup（#2107）。
                    await Task.detached(priority: .utility) { _ = Book.iCloudBooksDirectory }.value
                    AppOrphanBookRecovery.run(container: outcome.container)
                    AppLog.app.info("AppStartupRecoveryView: retry succeeded — switching to main UI")
                    return true
                }
                AppLog.app.warning("AppStartupRecoveryView: retry failed — still in recovery mode")
                return false
            },
            clearLocalCache: { @MainActor [localDataCleaner, modelContainer] in
                AppLog.app.info("AppStartupRecoveryView: clearLocalCache requested")
                // LocalDataCleanerService 透過 BackgroundSyncActor 清 in-memory fallback container 內的
                // VocabularyEntry / ReviewRecord / Notebook，以及與同步相關的 UserDefaults 標記。
                // 對 in-memory store 而言主要效果是清 UserDefaults — 為下次 retry 移除可能造成
                // migration crash 的殘留狀態。雲端資料不受影響（remote 仍保留，登入後會 re-sync）。
                await localDataCleaner.clearLocalData(
                    container: modelContainer,
                    reason: "startup-recovery",
                    deletedAccountID: nil
                )
                // 額外清除 store 檔案以便下一次 retry 走「全新建立」路徑。
                let storeFilesRemoved = AppBootstrap.purgeStoreFiles()
                AppCrashReporting.record(
                    NSError(
                        domain: "AppStartupRecovery",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "User cleared local cache from startup recovery view"]
                    ),
                    context: "startup-recovery-clear-cache"
                )
                return storeFilesRemoved
            },
            supportMailURL: { failure in
                AppStartupRecovery.composeSupportMailURL(for: failure)
            }
        )
    }
}
