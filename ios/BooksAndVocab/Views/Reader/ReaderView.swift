#if os(iOS)
//
//  ReaderView.swift
//  Books & Vocab
//
//  Created by 陳亮宇 on 2026/2/24.
//

import SwiftUI
import SwiftData
import TipKit
import ReadiumShared
import ReadiumNavigator
import os

/// 翻頁狀態（#3824）。`currentLocator` 獨立成 observable：每頁翻頁只失效讀取它的 leaf，
/// 不使 `ReaderView.body` 重新求值（否則每頁都重跑高亮 revision 與 presenter 狀態）。
@Observable
@MainActor
final class ReaderPageTurnState {
    var currentLocator: Locator?
}

/// 閱讀器主介面（Readium 版）
struct ReaderView: View {
    @ObserveInjection private var inject
    @Bindable var book: Book
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readiumService) var readiumService
    @Environment(\.iCloudDownloadManager) private var downloadManager
    // PERF: 詞彙量超過 5000 時考慮改為按書篩選
    @Query(
        filter: #Predicate<VocabularyEntry> { $0.actionType != "delete" }
    )
    var allVocabulary: [VocabularyEntry]  // 全域生詞（跨書）

    // 用於 seed 與 onChange：目前可用的 notebook
    @Query(filter: #Predicate<Notebook> { !$0.isSoftDeleted })
    private var liveNotebooks: [Notebook]
    // 用於 stale 綁定判定：含 tombstone，才能分辨「已刪除」與「尚未 reconcile 的遠端新建」（#3674）
    @Query private var allNotebookRows: [Notebook]

    @State var publication: Publication?
    @State var readerState: ReaderViewState
    @State var tocNavigationState = ReaderTOCNavigationState()
    /// Readiness/settings receipt emitted by the live Readium navigator.
    /// `nil` is intentionally exposed as a pending state until the navigator
    /// reports its initial presentation.
    @State var navigatorSettingsReceipt: ReaderNavigatorSettingsReceipt?

    // 翻譯 handler（封裝所有翻譯狀態與詞庫邏輯）
    @State var handler = ReaderTranslationHandler()

    // 觸發導航
    @State var navigateToLocator: (locator: Locator, id: UUID)? = nil

    // Readium current location（#3824：獨立 observable，見 `ReaderPageTurnState`）
    @State var pageTurn = ReaderPageTurnState()
    /// 首次載入後固化的 restore locator（#3824：不在每次 body 求值時重新解碼 lastReadLocatorJSON）。
    @State var restoredInitialLocator: Locator?
    /// Invalid persisted locators must not be passed to Readium as `nil`.
    /// The first reading-order resource becomes a real recovery destination
    /// after publication loading, and the navigator's location event remains
    /// the source of truth for the recovered progression.
    @State var restoreFallbackLocator: Locator?

    // 閱讀殼層狀態：集中 header / overlay / blocker 的控制面
    @State var chromeState = ReaderChromeState()

    // 單字本選擇
    @State private var showNotebookPicker = false
    @State var loginGate = LoginGateState()
    /// retry 重新載入的 in-flight handle。`.task` 走結構化作用域隨 view 自動取消，
    /// 但 retry 是手動觸發的非結構化 Task — 持 handle 以便 onDisappear 一併取消，
    /// 否則 retry 載入中途 dismiss 仍會 fire-and-forget 寫回已棄置的 handler。
    @State private var retryLoadTask: Task<Void, Never>?
    @State private var tocNavigationTask: Task<Void, Never>?
    @State private var tocNavigationDismissTask: Task<Void, Never>?
    /// Retry/disappear generation owner: a late publication result must not
    /// write into a newer Reader view after its request has been superseded.
    @State private var publicationLoadCoordinator = ReaderPublicationLoadCoordinator()

    @Environment(\.authManager) var authManager
    @Environment(\.toastCoordinator) var toastCoordinator
    @Environment(\.readerSettings) var settings

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// EPUB 翻頁進度落盤器：in-memory 寫入立即、`save()` debounce coalesce，
    /// `onDisappear` / scenePhase `.background` 兜底 flush。對齊 PDF 路徑的顯式 save。
    @State var progressSaver = ReaderProgressSaver()

    var viewConfiguration: ReaderViewConfiguration {
        settings.viewConfiguration(systemColorScheme: colorScheme)
    }

    init(book: Book, readerRuntimeClock: ReaderRuntimeClock = .live) {
        // 字體 CSS（~4.5 MB base64）在背景預熱；navigator delegate 只讀快取（#2052）。
        // 書架可更早呼叫同一個 idempotent `prewarm()`。
        ReaderFontFaceCSSCache.shared.prewarm()
        self._book = Bindable(book)
        let runtimeSelection = ReaderRuntimeFixtureAdapter.selection(
            arguments: ProcessInfo.processInfo.arguments,
            dataset: FixtureDatasetStore.readerProvenance()
        ) ?? ReaderRuntimeFixtureAdapter.selection(scenario: nil, dataset: FixtureDatasetStore.readerProvenance())
        self._readerState = State(
            initialValue: ReaderViewState(
                runtimeSelection: runtimeSelection,
                initialProgression: book.progression,
                clock: readerRuntimeClock
            )
        )
    }

    var body: some View {
        ReaderPresenterHost(
            readerState: readerState,
            chromeState: chromeState,
            paperColor: viewConfiguration.paperColor,
            bookTitle: book.title,
            hasPublication: publication != nil,
            onDismiss: { dismiss() },
            onShowTableOfContents: {
                tocNavigationState.reset()
                readerState.showTableOfContents = true
            },
            onShowReaderSettings: showReaderSettingsPanel,
            onShowNotebookPicker: { showNotebookPicker = true },
            onExpandHeader: expandHeader,
            onCollapseHeader: collapseHeader,
            onResolveSlowLoading: resolveSlowLoading
        ) {
            readerMainContent
        } translationPanel: {
            translationPanelContent
        }
        // 閱讀設定改由系統 sheet 呈現（APP-20260808-240a94）：detents 與
        // drag indicator 由平台提供，取代原本自繪的底部 overlay 卡片 + handle。
        // `appAppearanceScheme()`：這一頁的主題選擇器寫的是**整個 app** 的外觀，
        // 而 sheet 呈現後不會再跟著 root 換 —— 少了它，選深色的當下原生 Form 會
        // 留在淺色，section header 直接消失（APP-20260809-f1b8cb）。
        .sheet(isPresented: isReaderSettingsPresented) {
            settingsPanelContent.appAppearanceScheme()
        }
        .safeAreaInset(edge: .top) {
            TipView(LongPressTip())
                .padding(.horizontal)
        }
        .tint(.secondary)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .macReaderImmersion()
        .toastSheet(isPresented: tableOfContentsPresentation) {
            tableOfContentsSheet
        }
        .task {
            sanitizeStaleBoundNotebook()
            seedNotebookBindingIfNeeded()
            prepareRestoreState()
            await loadPublication()
        }
        .onAppear {
            // 閱讀頁面文字是整頁全出血，沒有安全的帶狀區給背景工作膠囊（#3116）。
            AppJobCapsuleSuppression.shared.setHeld(true, by: "reader")
        }
        .onDisappear {
            AppJobCapsuleSuppression.shared.setHeld(false, by: "reader")
            // dismiss / pop 時取消 in-flight 翻譯 task，避免網路 Task
            // 續跑到完成後寫回已棄置的 handler（多餘網路/寫入）。
            // 用 onDisappear 而非 @MainActor @Observable 的 deinit
            // （時序與 actor 隔離易出錯）。
            handler.cancelCurrentTranslationTask()
            // retry 走非結構化 Task，不隨 view 生命週期自動取消 —
            // 在此一併取消其 in-flight extractUniqueWords，避免寫回已棄置的 handler。
            retryLoadTask?.cancel()
            publicationLoadCoordinator.cancelAndInvalidate()
            tocNavigationTask?.cancel()
            tocNavigationDismissTask?.cancel()
            // dismiss / pop 時若 debounce 窗口未到期，flush 最後一次翻頁進度，
            // 避免 debounce 反而丟最後位置。
            progressSaver.flush()
            navigatorSettingsReceipt = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 退背景時 flush debounced 進度，覆蓋正常退出路徑；僅前景強殺極端
            // case 會丟失 debounce 窗口內的最後翻頁（對齊 CloudPreferencesSync 兜底）。
            if newPhase == .background { progressSaver.flush() }
        }
        .onChange(of: liveNotebooks.map(\.remoteId)) { _, _ in
            sanitizeStaleBoundNotebook()
            // notebooks settle 後補 seed：.task 當下 liveNotebooks 可能尚未 settle 而跳過。
            seedNotebookBindingIfNeeded()
        }
        .onChange(of: VocabularyHighlightSignature.revision(
            entries: allVocabulary,
            notebookId: book.resolvedNotebookId
        )) { _, _ in
            handler.loadLookedUpWords(
                from: allVocabulary,
                notebookId: book.resolvedNotebookId
            )
        }
        .onChange(of: book.resolvedNotebookId) { _, notebookId in
            handler.loadLookedUpWords(
                from: allVocabulary,
                notebookId: notebookId
            )
        }
        .onChange(of: authManager.isLoggedIn) { _, loggedIn in
            // 登出時立刻清空底線，不等 SwiftData async clear 通知
            if !loggedIn {
                handler.lookedUpWords = []
                handler.bookUniqueWords = nil
                handler.clearHighlightTrigger = UUID()
            }
        }
        .subscriptionPaywallSheet(isPresented: Binding(get: { readerState.showSubscriptionPaywall }, set: { readerState.showSubscriptionPaywall = $0 }))
        .toastSheet(item: Binding(get: { readerState.detailEntry }, set: { readerState.detailEntry = $0 })) { entry in
            WordDetailSheet(entry: entry, allEntries: allVocabulary)
        }
        .toastSheet(isPresented: $showNotebookPicker) {
            ReaderNotebookPicker(book: book)
                .appSheet(.adaptive)
        }
        .loginGateSheet($loginGate)
        .enableInjection()
    }

    /// `chromeState.overlay` 仍是唯一真相（swipe-to-dismiss / 選字 teardown 都走
    /// `closeOverlay(.settings)`），這裡只是把它投影成系統 sheet 要的 `Bool` binding。
    private var isReaderSettingsPresented: Binding<Bool> {
        Binding(
            get: { chromeState.overlay == .settings },
            set: { isPresented in
                if !isPresented { closeOverlay(.settings) }
            }
        )
    }

    @ViewBuilder private var tableOfContentsSheet: some View {
        if let publication {
            TOCView(
                publication: publication,
                currentLocatorHref: pageTurn.currentLocator?.href.string,
                navigationState: $tocNavigationState,
                onSelect: { item in handleTOCSelection(item, in: publication) }
            )
            .appSheet(.adaptive)
        }
    }

    private var tableOfContentsPresentation: Binding<Bool> {
        Binding(
            get: { readerState.showTableOfContents },
            set: { isPresented in
                guard isPresented || tocNavigationState.canDismissSheet else { return }
                readerState.showTableOfContents = isPresented
            }
        )
    }

    private func handleTOCSelection(_ item: ReaderTOCItem, in publication: Publication) {
        tocNavigationTask?.cancel()
        tocNavigationDismissTask?.cancel()
        let requestID = tocNavigationState.beginSelection(
            path: item.path,
            title: item.title,
            expectedHref: item.href
        )
        AppLog.reader.debug("TOC selected: \(item.title)")
        tocNavigationTask = Task { @MainActor in
            let locator = await publication.locate(item.link)
            guard !Task.isCancelled else {
                tocNavigationState.apply(.cancelled(requestID: requestID))
                return
            }
            guard let locator else {
                tocNavigationState.apply(.missingDestination(requestID: requestID))
                AppLog.reader.error("TOC navigation missing destination: \(item.title)")
                return
            }
            AppLog.reader.debug("Navigating to valid locator: \(String(describing: locator.href))")
            navigateToLocator = (locator: locator, id: requestID)
        }
    }

    func handleTOCNavigationEvent(_ event: ReaderTOCNavigationEvent) {
        let wasLoading = tocNavigationState.phase == .loading
        tocNavigationState.apply(event)
        if wasLoading && tocNavigationState.phase == .success {
            // A local EPUB can resolve immediately. Keep the success state
            // observable for a bounded render window, then dismiss only after
            // the state machine has already reached success. Failure and
            // missing-destination paths remain open and retryable.
            tocNavigationDismissTask?.cancel()
            tocNavigationDismissTask = Task { @MainActor in
                do {
                    try await Task.sleep(
                        nanoseconds: ReaderMetrics.tocNavigationMinimumLoadingNanoseconds
                    )
                } catch {
                    return
                }
                guard tocNavigationState.phase == .success else { return }
                readerState.showTableOfContents = false
            }
        }
    }

    /// 若 book.preferredNotebookId 有本機刪除證據（tombstone 或已回收的 local-* 占位）才清除綁定，
    /// 避免新單字存入孤兒 notebook。僅「不在本機列表」不構成刪除證據，不清（見 `Book.sanitizeAction`）。
    private func sanitizeStaleBoundNotebook() {
        let action = Book.sanitizeActionWithLedger(
            bound: book.preferredNotebookId,
            localNotebookIds: Set(allNotebookRows.map(\.remoteId)),
            tombstonedNotebookIds: Set(allNotebookRows.filter(\.isSoftDeleted).map(\.remoteId))
        )
        guard action == .clear else { return }
        book.preferredNotebookId = nil
    }

    /// 強制綁定 seed：書未綁定時（新書 / 剛被 sanitize 清掉 stale 綁定）以最近使用的
    /// 真實單字本（全域 active）固化綁定並持久化。固化後此書的 highlight / 查詢 / autoSave
    /// scope 一律認綁定本、不再隨全域 active 漂移（決策 B：種子綁定 + 之後 picker 乾淨切換）。
    private func seedNotebookBindingIfNeeded() {
        guard book.preferredNotebookId == nil else { return }
        let seed = ActiveNotebookStore.shared.activeNotebookId
        // 只在 seed 指向已 settle 的真實 notebook 時固化，避免凍結離線占位 / 未同步的
        // sentinel；liveNotebooks 尚未 settle 時跳過，待 settle 的 onChange 再 seed。
        guard Book.canSeedBinding(
            seed: seed,
            liveNotebookIds: Set(liveNotebooks.map(\.remoteId))
        ) else { return }
        book.ensureBoundNotebook(seed: seed)
        if modelContext.safeSave() {
            BookManifestStore().writeBestEffort(book: book)
        }
    }

    // MARK: - 載入 Publication

    /// 從錯誤狀態回到 loading 並重新呼叫 `loadPublication()`。
    /// 在 error overlay 上的「重試載入」按鈕觸發。
    @MainActor
    func retryLoadPublication() {
        _ = readerState.runtime.retry()
        readerState.resetLoadingPhase()
        readerState.isWebViewReady = false
        publicationLoadCoordinator.cancelAndInvalidate()
        publication = nil
        restoredInitialLocator = nil
        restoreFallbackLocator = nil
        pageTurn.currentLocator = nil
        // 持 handle：retry 為非結構化 Task，需 onDisappear 顯式取消（見 retryLoadTask 宣告）。
        // 重入先取消舊 retry，避免連點時舊 in-flight 載入洩漏（與 onDisappear 對稱）。
        retryLoadTask?.cancel()
        retryLoadTask = Task { await loadPublication() }
    }

    @MainActor
    private func resolveSlowLoading() {
        guard readerState.runtime.releaseSlowLoading() else { return }
        readerState.resetLoadingPhase()
        readerState.isWebViewReady = false
        retryLoadTask?.cancel()
        publicationLoadCoordinator.cancelAndInvalidate()
        retryLoadTask = Task { await loadPublication() }
    }

    @MainActor
    private func loadPublication() async {
        guard !Task.isCancelled else { return }
        let request = publicationLoadCoordinator.beginRequest()
        switch readerState.runtime.beginLoadAttempt() {
        case .holdSlow:
            readerState.isWebViewReady = false
            return
        case .failed:
            readerState.isWebViewReady = true
            return
        case .empty:
            readerState.isWebViewReady = true
            return
        case .proceed:
            readerState.resetLoadingPhase()
        }

        let loader = ReaderPublicationLoader(
            readiumService: readiumService,
            downloadManager: downloadManager
        )
        await publicationLoadCoordinator.load(
            request: request,
            book: book,
            loader: loader,
            onPhase: { phase in
                readerState.updateLoadingPhase(phase)
            },
            onPublication: { loadedPublication in
                publication = loadedPublication
                if book.lastReadLocatorJSON != nil, initialLocator == nil {
                    restoreFallbackLocator = loadedPublication.readingOrder.compactMap { link in
                        guard let mediaType = link.mediaType else { return nil }
                        return Locator(href: link.url(), mediaType: mediaType)
                    }.first
                    readerState.runtime.markRestoreFailure()
                }
                restoredInitialLocator = initialLocator
                readerState.runtime.markReady()
                PerfLog.reader.mark("reader.opened", "title=\(book.title)")
                handler.loadLookedUpWords(
                    from: allVocabulary,
                    notebookId: book.resolvedNotebookId
                )
            },
            onUniqueWords: { uniqueWords in
                handler.bookUniqueWords = uniqueWords
            },
            onError: { error in
                AppLog.reader.error("Publication load failed (book=\(book.title)): \(error.localizedDescription, privacy: .public)")
                readerState.runtime.fail(.openFailed, message: error.localizedDescription)
                readerState.isWebViewReady = true  // 顯示錯誤畫面
            }
        )
    }
}

/// Presenter 的 leaf 包裝（#3824）。進度／runtime 讀取與 main／translation content 都在本 view 的
/// body 求值，而不是 `ReaderView.body`：每頁翻頁只失效本 leaf，owner 不再重跑高亮 revision。
private struct ReaderPresenterHost<MainContent: View, TranslationPanelContent: View>: View {
    let readerState: ReaderViewState
    let chromeState: ReaderChromeState
    let paperColor: SwiftUI.Color
    let bookTitle: String
    let hasPublication: Bool
    let onDismiss: () -> Void
    let onShowTableOfContents: () -> Void
    let onShowReaderSettings: () -> Void
    let onShowNotebookPicker: () -> Void
    let onExpandHeader: () -> Void
    let onCollapseHeader: () -> Void
    let onResolveSlowLoading: () -> Void
    let mainContent: () -> MainContent
    let translationPanel: () -> TranslationPanelContent

    init(
        readerState: ReaderViewState,
        chromeState: ReaderChromeState,
        paperColor: SwiftUI.Color,
        bookTitle: String,
        hasPublication: Bool,
        onDismiss: @escaping () -> Void,
        onShowTableOfContents: @escaping () -> Void,
        onShowReaderSettings: @escaping () -> Void,
        onShowNotebookPicker: @escaping () -> Void,
        onExpandHeader: @escaping () -> Void,
        onCollapseHeader: @escaping () -> Void,
        onResolveSlowLoading: @escaping () -> Void,
        @ViewBuilder mainContent: @escaping () -> MainContent,
        @ViewBuilder translationPanel: @escaping () -> TranslationPanelContent
    ) {
        self.readerState = readerState
        self.chromeState = chromeState
        self.paperColor = paperColor
        self.bookTitle = bookTitle
        self.hasPublication = hasPublication
        self.onDismiss = onDismiss
        self.onShowTableOfContents = onShowTableOfContents
        self.onShowReaderSettings = onShowReaderSettings
        self.onShowNotebookPicker = onShowNotebookPicker
        self.onExpandHeader = onExpandHeader
        self.onCollapseHeader = onCollapseHeader
        self.onResolveSlowLoading = onResolveSlowLoading
        self.mainContent = mainContent
        self.translationPanel = translationPanel
    }

    var body: some View {
        ReaderViewPresenter(
            state: .init(
                paperColor: paperColor,
                isWebViewReady: readerState.isWebViewReady,
                loadingPhase: readerState.loadingPhase,
                underlineProgress: readerState.underlineProgress,
                chrome: chromeState,
                totalProgression: readerState.runtime.visibleTotalProgression(hasPublication: hasPublication),
                bookTitle: bookTitle,
                progressState: readerState.runtime.visibleProgressState(hasPublication: hasPublication),
                loadingState: readerState.loadingState,
                runtimeStateAccessibilityValue: readerState.runtime.runtimeStateAccessibilityValue(
                    hasPublication: hasPublication
                ),
                canResolveSlowLoading: readerState.runtime.selection.loadMode == .slow
                    && readerState.loadingState == .loading(.slow)
            ),
            onDismiss: onDismiss,
            onShowTableOfContents: onShowTableOfContents,
            onShowReaderSettings: onShowReaderSettings,
            onShowNotebookPicker: onShowNotebookPicker,
            onExpandHeader: onExpandHeader,
            onCollapseHeader: onCollapseHeader,
            onResolveSlowLoading: onResolveSlowLoading
        ) {
            mainContent()
        } translationPanel: {
            translationPanel()
        }
    }
}
#endif
