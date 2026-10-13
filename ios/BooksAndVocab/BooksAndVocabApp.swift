//
//  BooksAndVocabApp.swift
//  Books & Vocab
//
//  Created by 陳亮宇 on 2026/2/24.
//

import SwiftUI
import SwiftData
import TipKit

import GoogleSignIn

@main
struct BooksAndVocabApp: App {
    private let runtimeArguments = ProcessInfo.processInfo.arguments
    @StateObject private var appLanguage = AppLanguageStore.shared
    @StateObject private var appearanceStore = AppAppearanceStore.shared
    #if targetEnvironment(macCatalyst)
    // Catalyst 選單客製（移除衝突的系統 Find ⌘F）— 見 CatalystAppDelegate。
    @UIApplicationDelegateAdaptor(CatalystAppDelegate.self) private var catalystAppDelegate
    #endif
    @State var modelContainer: ModelContainer
    @State var startupFailure: AppStartupFailure?
    let authManager = AuthManager.shared
    let kgService = KGService()
    let subscriptionManager: any SubscriptionManaging
    #if os(iOS)
    let readiumService: any ReadiumServing = ReadiumService.shared
    let bookshelfImportService: any BookshelfImporting
    let bookMetadataRepairService: BookMetadataRepairService
    #endif
    let bookFileManager: any BookFileManaging
    let iCloudDownloadManager = ICloudDownloadManager()
    let networkMonitor = NetworkMonitor.shared
    let syncCoordinator = SyncCoordinator()
    let toastCoordinator = AppToastCoordinator()
    let appCommandCoordinator = AppCommandCoordinator()
    let localDataCleaner: any LocalDataClearing = LocalDataCleanerService()

    init() {
        // Initialize crash reporting first so any subsequent startup failure is captured.
        if !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: runtimeArguments) {
            AppCrashReporting.bootstrap()
        }

        #if targetEnvironment(simulator)
        if AppRuntimeOptions.isUITesting(arguments: runtimeArguments) {
            if runtimeArguments.contains("-seedFixture:entitlements:pro") {
                subscriptionManager = UITestSubscriptionManager.proAccess()
            } else if runtimeArguments.contains("-seedFixture:entitlements:free") {
                subscriptionManager = UITestSubscriptionManager.freeAccess()
            } else {
                subscriptionManager = SubscriptionManager.shared
            }
        } else {
            subscriptionManager = SubscriptionManager.shared
        }
        #else
        subscriptionManager = SubscriptionManager.shared
        #endif

        #if os(iOS)
        AppFonts.ensureSerifCJKAvailable()
        AppFonts.configureGlobalAppearance()
        #endif
        if !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: runtimeArguments) {
            NSUbiquitousKeyValueStore.default.synchronize()
        }
        #if os(iOS)
        bookshelfImportService = BookshelfImportService(readiumService: readiumService)
        bookMetadataRepairService = BookMetadataRepairService(
            extractor: ReadiumBookMetadataExtractor(readiumService: readiumService)
        )
        #endif
        bookFileManager = LocalBookFileManager()

        let outcome = AppBootstrap.run()
        _modelContainer = State(initialValue: outcome.container)
        _startupFailure = State(initialValue: outcome.failure)

        #if os(iOS)
        UITestFixtureSeed.injectIfNeeded(into: outcome.container, arguments: runtimeArguments)
        #endif

        // Orphan book recovery 不在 init 跑（#2107）：reconciler 預設 root 會在 main thread
        // 解析 iCloud 容器；改由 ContentView 的 .task 先背景暖快取再執行。

        #if os(iOS)
        // PodcastDownloadManager must hold a ModelContainer ref before any
        // background URLSession delegate callback can persist localAudioPath.
        // Internally no-ops when `KGFeatureFlags.podcastEnabled == false`
        // (Release) so the download data path stays inert.
        if !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: runtimeArguments) {
            PodcastDownloadManager.shared.configure(modelContainer: outcome.container)
        }
        #endif

        // AuthManager establishes the namespace during session construction;
        // reassert it at the composition root before any view/task can load
        // Settings so cold-start state never depends on SettingsView.
        authManager.activateAccountPreferencesForCurrentSession()
    }

    @Environment(\.scenePhase) private var scenePhase

    #if os(iOS)
    private static let fontObserver: Any? = NotificationCenter.default.addObserver(
        forName: .serifCJKFontDidBecomeAvailable,
        object: nil,
        queue: .main
    ) { _ in
        AppFonts.configureGlobalAppearance()
    }
    #endif

    @State private var showWelcome =
        !ProcessInfo.processInfo.arguments.contains("-skipWelcome") &&
        !UserDefaults.standard.bool(forKey: "hasSeenWelcome")
    @State private var showLoginFromWelcome = false

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator) && canImport(Playbook)
            if ProcessInfo.processInfo.arguments.contains("-catalog") {
                CatalogScene()
            } else {
                mainAppContent
            }
            #else
            mainAppContent
            #endif
        }
        .modelContainer(modelContainer)
        #if targetEnvironment(macCatalyst)
        .commands {
            MacMenuCommands(
                coordinator: appCommandCoordinator,
                kgService: kgService,
                modelContainer: modelContainer,
                toastCoordinator: toastCoordinator,
                authManager: authManager
            )
        }
        #endif
    }

    private var mainAppContent: some View {
        AppThemeContainer {
            rootView
                .environmentObject(appLanguage)
                .environment(\.reviewSettingsStore, ReviewSettingsStore.shared)
                .environment(\.feedbackSettingsStore, FeedbackSettingsStore.shared)
                .preferredColorScheme(appearanceStore.resolvedColorScheme)
                .environment(\.authManager, authManager)
                .environment(\.kgService, kgService)
                .environment(\.subscriptionManager, subscriptionManager)
                .environment(\.locale, appLanguage.locale)
                #if os(iOS)
                // UI World vocabulary fixtures derive a deterministic clock
                // from their canonical seed. Keep the production default
                // unchanged when no fixture selected one, but carry the
                // fixture clock through the real view environment so Overview,
                // heatmap, calendar, and forecast project the same day.
                .environment(
                    \.statsProjectionClock,
                    UITestFixtureSeed.statsProjectionClock
                        ?? StatsProjectionClock(
                            now: Date(timeIntervalSince1970: 0),
                            calendar: Calendar(identifier: .gregorian)
                        )
                )
                #endif
                // Why: L10n.string(_:) 是 non-reactive function;絕大多數 view 不訂閱
                // AppLanguageStore,切 selection 後 UI 中英混雜直到 navigation/redraw。
                // rootRefreshID 讓所有 L10n.string 重新計算；Settings 的 account-local
                // reset 可暫緩這次重建，避免終端狀態尚未被看見就銷毀 navigation。
                .id(appLanguage.rootRefreshID)
                // tint 由 AppThemeContainer 的 .tint(theme.palette.tint) 統一供給
                // （scheme-aware：light→tintLight、dark→tintDark 近白）。此處勿再寫死
                // .tint(AppColors.tintLight)——它離葉較近會覆蓋外層 scheme-aware tint，
                // 害 dark mode 下全 app 的 accent/tint 元件（tab bar 選中態、menu icon/
                // checkmark）以深灰疊深底、對比過低看不清。
                #if os(iOS)
                .environment(\.readiumService, readiumService)
                .environment(\.bookshelfImportService, bookshelfImportService)
                .environment(\.readerSettings, .shared)
                #endif
                .environment(\.bookFileManager, bookFileManager)
                .environment(\.iCloudDownloadManager, iCloudDownloadManager)
                .environment(\.syncCoordinator, syncCoordinator)
                .environment(\.quotaStore, QuotaStore.shared)
                .environment(\.speechService, SpeechService.shared)
                .environment(\.feedbackAudioService, FeedbackAudioService.shared)
                .environment(\.toastCoordinator, toastCoordinator)
                .environment(\.appCommandCoordinator, appCommandCoordinator)
                .modifier(
                    ReviewCardUITestDynamicTypeModifier(
                        size: AppRuntimeOptions.reviewCardDynamicType(arguments: runtimeArguments) == .accessibility3
                            ? .accessibility3
                            : nil
                    )
                )
                .toastOverlay()
                .appJobCapsuleOverlay()
                .onAppear {
                    // Completion notices of jobs no sheet shows go through the same pill (#3116).
                    AddLinkCreationHub.shared.outcomePoster = toastCoordinator
                }
        }
        .environmentObject(appearanceStore)
    }

    @ViewBuilder
    private var rootView: some View {
        if let startupFailure {
            AppStartupRecoveryView(
                failure: startupFailure,
                actions: makeStartupRecoveryActions()
            )
        } else if let reviewProbePlan = ReviewProbeOptions.active {
            // Today Review 自主量測 probe（-reviewProbe N）— root 直掛 review
            // 畫面跑 deterministic flip 迴圈。production 啟動恆為 nil。
            ReviewProbeScene(plan: reviewProbePlan)
        } else {
            ContentView()
                .modifier(AutoSyncMonitor())
                .macSettingsCommandSheet()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    // Always recover orphan book files (idempotent — skips files with existing records)
                    // -ui-testing 下跳過：它對「真實 Books 目錄」reconcile（manifest 有
                    // 磁碟寫入），且跑在 fixture seed 之後——會把真機使用者的真書/髒模擬器
                    // 殘留收編進 ephemeral 容器，破壞 fixture 決定性與截圖隱私。
                    guard !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: runtimeArguments),
                          !AppRuntimeOptions.isUITesting(arguments: runtimeArguments) else { return }
                    // 先在背景解析 iCloud 容器並暖 Book 快取，main actor 上的 reconciler
                    // 才不會在 ubiquity lookup 上阻塞（#2107）。@Query 書架會在 save 後刷新。
                    await Task.detached(priority: .utility) { _ = Book.iCloudBooksDirectory }.value
                    AppOrphanBookRecovery.run(container: modelContainer)
                }
                .task {
                    guard !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: runtimeArguments) else { return }
                    iCloudDownloadManager.startMonitoring()
                }
                #if os(iOS)
                .task {
                    guard !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: runtimeArguments) else { return }
                    // UI 掛載後從本機可讀 EPUB 重抽 metadata，修復被 UUID fallback
                    // 污染的書（title=UUID、cover=0）。不放進 init / 同步啟動路徑，
                    // 避免 Readium parsing 拖慢冷啟動。service 內建 in-flight guard +
                    // 候選門檻，語言切換重建 view tree 時對乾淨書庫近乎零成本。
                    // 先背景暖 iCloud 目錄快取：needsRepair 的 fileURL 解析與 manifest store 都在
                    // main actor 讀 Book 目錄，冷快取會在 main 上跑 ubiquity lookup（#2107）。
                    await Task.detached(priority: .utility) { _ = Book.iCloudBooksDirectory }.value
                    await bookMetadataRepairService.repairIfNeeded(context: modelContainer.mainContext)
                }
                #endif
                .task {
                    guard !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: runtimeArguments) else { return }
                    // A pending language switch wants the TipKit datastore wiped so
                    // cached tip text re-renders in the new language. TipKit only
                    // accepts resetDatastore() *before* configure(), so it is drained
                    // here and nowhere else; a failed drain keeps the flag for the
                    // next cold launch. See PendingTipsReset (APP-20260806-498c25).
                    PendingTipsReset.consume { try Tips.resetDatastore() }
                    try? Tips.configure()
                }
                .task {
                    guard !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: runtimeArguments) else { return }
                    if !authManager.isLoggedIn {
                        let actor = BackgroundSyncActor(modelContainer: modelContainer)
                        do {
                            try await actor.clearSyncedData()
                            // Force full sync on next login by clearing the incremental boundary.
                            // Without this, re-login after a Keychain-only wipe (e.g. Xcode rebuild)
                            // would do an incremental sync that skips already-deleted entries.
                            UserDefaults.standard.removeObject(forKey: "kg_last_incremental_sync")
                            UserDefaults.standard.removeObject(forKey: "kg_review_payload_version")
                        } catch {
                            AppLog.app.error("clearSyncedData failed: \(error.localizedDescription)")
                        }
                    }
                    subscriptionManager.listenForTransactionUpdates(using: kgService, authManager: authManager)
                    await subscriptionManager.loadProducts()
                    await subscriptionManager.refresh(using: kgService, authManager: authManager, force: false)
                }
                .onChange(of: authManager.isLoggedIn) { wasLoggedIn, isNowLoggedIn in
                    guard !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: runtimeArguments) else { return }
                    // Tag Sentry scope with user id (clear on logout) — runs on every transition.
                    AppCrashReporting.setUser(id: isNowLoggedIn ? authManager.userId : nil)
                    // Trigger sync immediately after login (scenePhase won't re-fire .active)
                    guard !wasLoggedIn, isNowLoggedIn, !authManager.isDemoMode else { return }
                    Task {
                        // logout-cleanup gate 在 KGService.backgroundSync 入口單點生效
                        // （四個 sync 觸發點共用），call site 不再各自 await。
                        AppLog.kg.info("Post-login sync triggered")
                        await kgService.backgroundSync(
                            container: modelContainer,
                            progress: PodcastBackgroundSyncStatusStore.report
                        )
                        await kgService.fetchQuota()
                        // 登入後立即以新帳號重新取得權益，不等待下一次 scenePhase／啟動 refresh（#2592）。
                        await subscriptionManager.refresh(using: kgService, authManager: authManager, force: true)
                        // Rebuild the Apple-ID-scoped book library on login. Books
                        // bind to the Apple ID (CloudStore/CloudKit + per-Apple-ID
                        // files), not the app account, so any prior logout that
                        // dropped rows — or a not-yet-synced CloudKit store — would
                        // otherwise leave the bookshelf empty until the next cold
                        // start. AppOrphanBookRecovery is idempotent (only files
                        // already on disk get rows; nothing is resurrected from a
                        // deleted file), so running it here is safe.
                        AppOrphanBookRecovery.run(container: modelContainer)
                        // No mainContext.save() "poke": @Query observes the background actor's
                        // save through the store (QueryPicksUpBackgroundSaveTests), and a main
                        // save here would flush half-edited UI state and swallow errors (#2051).
                        if let error = kgService.lastBackgroundSyncError {
                            toastCoordinator.warning(error)
                            kgService.lastBackgroundSyncError = nil
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard !AppRuntimeOptions.shouldSkipNonessentialStartupWork(arguments: runtimeArguments) else { return }
                    switch newPhase {
                    case .active:
                        AppAnalytics.track(.appSessionStarted)
                        // Device is now unlocked — retry any keychain token read that failed
                        // transiently at launch (cold boot), resolving the unknown auth state
                        // before the sync guards below evaluate `isLoggedIn`.
                        authManager.refreshSessionIfNeeded()
                        authManager.activateAccountPreferencesForCurrentSession()
                        // The server keeps creating a job while the app is suspended; a process
                        // killed mid-job is re-attached here and announced when it finishes (#3116).
                        AddLinkCreationHub.shared.resume(kgService: kgService, container: modelContainer)
                        Task {
                            await subscriptionManager.refresh(using: kgService, authManager: authManager)
                            guard authManager.isLoggedIn, !authManager.isDemoMode else { return }
                            AppAnalytics.track(.backgroundSyncTriggered)
                            let syncStart = Date()
                            await kgService.backgroundSync(
                                container: modelContainer,
                                progress: PodcastBackgroundSyncStatusStore.report
                            )
                            await kgService.fetchQuota()
                            let durationMs = Int(Date().timeIntervalSince(syncStart) * 1000)
                            let success = kgService.lastBackgroundSyncError == nil
                            AppAnalytics.track(.backgroundSyncCompleted(durationMs: durationMs, success: success))
                            if let error = kgService.lastBackgroundSyncError {
                                toastCoordinator.warning(error)
                                kgService.lastBackgroundSyncError = nil
                            }
                        }
                    case .background:
                        SessionMetrics.shared.snapshot().logSummary()
                        SessionMetrics.shared.reset()
                        AppAnalytics.track(.appEnteredBackground)
                        // Flush any debounced iCloud KVS write before the OS may suspend
                        // us — covers the normal exit path so the debounce window only
                        // risks loss on a foreground force-quit.
                        CloudPreferencesSync.shared.forceFlush()
                        Task {
                            guard authManager.isLoggedIn, !authManager.isDemoMode else { return }
                            await kgService.pushReviewQuietly(container: modelContainer)
                        }
                    default:
                        break
                    }
                }
                .alert(
                    L10n.string("登入已過期"),
                    isPresented: Binding(
                        get: { kgService.sessionExpiredReason != nil },
                        set: { if !$0 { kgService.sessionExpiredReason = nil } }
                    )
                ) {
                    Button(L10n.string("確定")) {
                        kgService.sessionExpiredReason = nil
                    }
                } message: {
                    if let reason = kgService.sessionExpiredReason {
                        Text(reason)
                    }
                }
                .platformFullScreenCover(isPresented: $showWelcome) {
                    WelcomeView(
                        onStart: {
                            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
                            showWelcome = false
                        },
                        onLogin: {
                            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
                            showWelcome = false
                            showLoginFromWelcome = true
                        },
                        onTryDemo: {
                            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
                            showWelcome = false
                            authManager.enterDemoMode(modelContainer: modelContainer)
                        }
                    )
                }
                .loginSheet(isPresented: $showLoginFromWelcome)
        }
    }

}

private struct ReviewCardUITestDynamicTypeModifier: ViewModifier {
    let size: DynamicTypeSize?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let size {
            content.environment(\.dynamicTypeSize, size)
        } else {
            content
        }
    }
}
