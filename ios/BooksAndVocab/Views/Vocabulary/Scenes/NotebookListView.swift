//
//  NotebookListView.swift
//  Books & Vocab
//
//  單字本書架 — 生詞庫 tab 的入口頁

import SwiftUI
import SwiftData
import TipKit

enum NotebookListPhase: Equatable {
    case loading
    case error
    case empty
    case partial
    case content

    static func resolve(
        notebookCount: Int,
        hasLoadedOnce: Bool,
        isLoggedIn: Bool,
        hasError: Bool
    ) -> Self {
        if notebookCount == 0 && !hasLoadedOnce && isLoggedIn { return .loading }
        if notebookCount == 0 && hasError { return .error }
        if notebookCount == 0 { return .empty }
        return hasError ? .partial : .content
    }
}

/// 薄殼：唯一持有 `DetailRouter` 並呈現 detail/review cover 的層，**刻意不含 `@Query`**。
///
/// 複習翻卡的背景 DB 寫入只會失效 `NotebookListContent` 的 `@Query`、不會觸及本層，
/// 因此 cover 的 content closure 不再隨翻卡重跑 → 不再重建「建完即丟」的
/// `TodayReviewState`（這是翻卡落定後主線凍結的 Cost B 來源）。cover 的複習資料走
/// `detailState.contextEntries` 快照（`showReview` 當下擷取），故本層傳 `allEntries: []` 安全。
struct NotebookListView: View {
    @ObserveInjection private var inject
    @Environment(\.authManager) private var authManager
    @State private var detailState = DetailRouter()

    var body: some View {
        // Phase-1 probe: the shell owns the cover. If `shell.body` fires per flip, the
        // shell (or its upstream) is re-evaluating → it rebuilds NotebookDetailPresentation
        // → cover content closure re-runs → throwaway TodayReviewState. This is the
        // first-hand signal that replaces inferring the mechanism from `state.init`.
        // NOTE: during pure flipping no source file is saved, so `@ObserveInjection`
        // cannot fire here — any per-flip `shell.body` is real, not an Inject artifact.
        let _ = PerfLog.review.mark("shell.body")
        return NotebookListContent(detailState: detailState)
            .environment(\.detailRouter, detailState)
            .modifier(NotebookDetailPresentation(
                detailState: detailState,
                allEntries: [],
                currentUserID: authManager.userId
            ))
            .enableInjection()
    }
}

/// 生詞庫 tab 的列表內容（持 `@Query` + 全部列表 UI 狀態），由 `NotebookListView` 薄殼
/// 注入 `detailState`。複習中（被 cover 蓋住）body 跳過 `stats`/`filtered`/`sort` 重算
/// （見 body 內 `covered` gate）——這些值的消費者此刻全不可見、不可互動（Cost A）。
struct NotebookListContent: View {
    @ObserveInjection private var inject
    @Query(filter: #Predicate<Notebook> { !$0.isSoftDeleted }, sort: \Notebook.sortOrder)
    private var notebooks: [Notebook]
    @Query private var allEntries: [VocabularyEntry]
    @Query private var pendingEntries: [VocabularyEntry]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.kgService) private var kgService
    @Environment(\.authManager) private var authManager
    @Environment(\.appSkin) private var skin
    @Environment(\.toastCoordinator) private var toastCoordinator
    @Environment(\.reviewSettingsStore) private var reviewSettingsStore
    @Environment(\.catalogTaskPolicy) private var catalogTaskPolicy
    @State private var coordinator = NotebookListCoordinator()
    let detailState: DetailRouter
    @State private var loginGate = LoginGateState()

    init(detailState: DetailRouter) {
        self.detailState = detailState
        _allEntries = Query(filter: VocabularyEntry.knowledgeListPredicate(), sort: \.dateAdded, order: .reverse)
        _pendingEntries = Query(filter: #Predicate<VocabularyEntry> { $0.syncStatus != 1 })
    }

    @State private var showCreateSheet = false
    @State private var editingNotebook: Notebook?
    @AppStorage("activeNotebookId") private var activeNotebookId: String = "default"
    @AppStorage(NotebookSortOption.storageKey) private var sortOptionRaw: String = NotebookSortOption.manual.rawValue
    @State private var reviewFilter = NotebookFilter.load()
    @State private var activeReviewSession: TodayReviewSession?
    @State private var notebookToDelete: Notebook?
    @State private var showArchiveList = false
    @State private var showFilterSheet = false
    @State private var navigationPath = NavigationPath()

    /// A boolean login flag does not change for an A→B account switch. Include
    /// identity and demo state so the server projection task restarts at every
    /// account boundary.
    private var accountTaskID: String {
        "\(authManager.isLoggedIn ? "logged-in" : "logged-out"):\(authManager.userId ?? "none"):\(authManager.isDemoMode)"
    }

    private var sortOption: NotebookSortOption {
        NotebookSortOption(rawValue: sortOptionRaw) ?? .manual
    }

    private var liveNotebookIDs: Set<String> {
        Set(notebooks.filter { !$0.isSoftDeleted }.map(\.remoteId))
    }

    /// 列表 body 所需的衍生資料（每本 notebook 統計 + 篩選後到期/未學集合 + 排序）。
    private struct ListModel {
        var stats: [String: NotebookStats] = [:]
        var due: [VocabularyEntry] = []
        var unlearned: [VocabularyEntry] = []
        var sortedNotebooks: [Notebook] = []
        var totalDue: Int = 0
        var totalUnlearned: Int = 0
    }

    struct ReviewProjection {
        let stats: [String: NotebookStats]
        let due: [VocabularyEntry]
        let unlearned: [VocabularyEntry]
    }

    static func makeReviewProjection(
        allEntries: [VocabularyEntry],
        pendingEntries: [VocabularyEntry],
        notebooks: [Notebook],
        reviewFilter: NotebookFilter,
        now: Date
    ) -> ReviewProjection {
        let stats = NotebookStatsCalculator.compute(
            allEntries,
            pendingEntries: pendingEntries,
            now: now
        )
        // The filter pill only renders with ≥2 notebooks. If a user filtered then deleted
        // notebooks down to <2, the persisted filter must NOT keep silently hiding entries
        // with no UI to clear it — apply an unfiltered view while keeping reviewFilter intact.
        let effectiveFilter = notebooks.count >= 2 ? reviewFilter : NotebookFilter()
        let filtered = NotebookStatsCalculator.filtered(
            allEntries,
            filter: effectiveFilter,
            now: now
        )
        return ReviewProjection(stats: stats, due: filtered.due, unlearned: filtered.unlearned)
    }

    /// 計算 `ListModel`。被 detail/review cover 蓋住時（`covered`）回空結果，跳過 636-entry
    /// 的 `compute`/`filtered`/`sort`（Cost A，~80ms）。抽成獨立 method 讓 body 維持平凡
    /// 賦值——既好讀，也避開 Inject 熱重載對「@ViewBuilder body 內三元套 trailing-closure
    /// + `.value`」符號解析吐野指標而崩潰（dev-tool bug，非 production）。
    private func computeListModel(covered: Bool, reviewNow: Date) -> ListModel {
        guard !covered else { return ListModel() }
        let projection = PerfLog.review.measure("notebookList.stats", "n=\(allEntries.count)") {
            Self.makeReviewProjection(
                allEntries: allEntries,
                pendingEntries: pendingEntries,
                notebooks: notebooks,
                reviewFilter: reviewFilter,
                now: reviewNow
            )
        }.value
        return ListModel(
            stats: projection.stats,
            due: projection.due,
            unlearned: projection.unlearned,
            sortedNotebooks: sortOption.sort(notebooks, stats: projection.stats),
            totalDue: projection.stats.values.reduce(0) { $0 + $1.dueCount },
            totalUnlearned: projection.stats.values.reduce(0) { $0 + $1.unlearnedCount }
        )
    }

    var body: some View {
        let _bodyStart = DispatchTime.now()
        let _ = PerfLog.review.tick("notebookList.body", "entries=\(allEntries.count)")
        // While a review is presented (cover over this list), this list should NOT
        // need to re-evaluate. If it does, the flip's background DB write invalidated
        // our @Query → host re-render → the cover's content closure re-runs →
        // throwaway TodayReviewState rebuild. One-shot mark times each such re-eval
        // against the fling timeline.
        let _ = { if detailState.activeReviewSession != nil {
            PerfLog.review.mark("notebookList.reeval", "duringReview")
        } }()
        let reviewNow = reviewSettingsStore.settings.reviewReferenceDate()
        // GATE (Cost A): while a detail/review cover is presented this list is fully
        // obscured and non-interactive — every consumer below (NotebookReviewActionBar,
        // notebook grid ForEach, Mac ⌘⏎ menu) is hidden. The flip's background DB write
        // invalidates our @Query and forces a body re-eval anyway; the heavy 636-entry
        // stats/filtered/sort recompute (~80ms, the落定後 freeze) is skipped inside
        // `computeListModel` when covered. On cover dismiss `covered` flips false and a
        // single body eval recomputes the real grid in one pass (no empty-state flash).
        let covered = detailState.activeReviewSession != nil
        let model = computeListModel(covered: covered, reviewNow: reviewNow)
        let stats = model.stats
        let filteredDueEntries = model.due
        let filteredUnlearnedEntries = model.unlearned
        let totalDueCount = model.totalDue
        let totalUnlearnedCount = model.totalUnlearned
        let sortedNotebooks = model.sortedNotebooks
        let listPhase = NotebookListPhase.resolve(
            notebookCount: notebooks.count,
            hasLoadedOnce: coordinator.hasLoadedOnce,
            isLoggedIn: authManager.isLoggedIn,
            hasError: coordinator.reconcileError != nil
        )

        // Editorial tight overrides — 全 app token (`pageHorizontalPadding = s5 = 32pt` /
        // `sectionSpacing = s6 = 48pt` / `sectionGap = 14` / `pageTopInset = 16`) 對
        // Notebooks editorial 太鬆。本地降到 editorial 緊版,不動共用 token。
        let editorialHorizontal: CGFloat = AppSpacing.s3   // 12pt (was 32pt)
        let editorialSectionGap: CGFloat = AppSpacing.s1   // 4pt  (was 8pt — user feedback 緊湊)
        let editorialGridSpacing: CGFloat = AppSpacing.s1  // 4pt  (was 8pt — 卡片之間更貼)
        let editorialTopInset: CGFloat = AppSpacing.zero   // 0    (was 4pt — 頂部不留 inset)

        // Synchronous compute cost of the let-chain above (stats + filtered + sort
        // over 636 entries) before any view-tree construction. If this stays small
        // while settle.frames maxGap is ~140ms, the freeze is NOT this compute — it's
        // the @Query refetch (pre-body) + SwiftUI tree rebuild, both downstream of the
        // same review-write invalidation.
        let _ = PerfLog.review.mark("notebookList.letchain", "\(PerfChannel.ms(since: _bodyStart))ms")

        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: editorialSectionGap) {
                    if listPhase == .partial, let message = coordinator.reconcileError {
                        reconcileErrorBanner(message: message)
                            .padding(.horizontal, editorialHorizontal)
                            .transition(.statusRowReveal)
                    }

                    if listPhase == .partial || listPhase == .content {
                        if !pendingEntries.isEmpty {
                            TipView(SyncPendingTip())
                                .padding(.horizontal, editorialHorizontal)
                        }

                        // D4 — Today Review action bar：title + 三 pill 包進 mutedFill capsule 容器,
                        // 容器 1pt cardBorder 微粗淡 hairline 框、灰填底比框線更淡。
                        // 三 pill (CTA / filter / plus) 統一規格走 NotebookHeaderPillLabel,
                        // 差別僅在「長度 + 填色」— user feedback iteration。
                        NotebookReviewActionBar(
                            dueCount: filteredDueEntries.count,
                            unlearnedCount: filteredUnlearnedEntries.count,
                            hasReviewItems: totalDueCount > 0 || totalUnlearnedCount > 0,
                            notebookCount: notebooks.count,
                            isFiltered: reviewFilter.isFiltered,
                            canCreate: authManager.isLoggedIn,
                            onReviewAll: { startReview(with: filteredDueEntries + filteredUnlearnedEntries) },
                            onReviewDue: { startReview(with: filteredDueEntries) },
                            onReviewUnlearned: { startReview(with: filteredUnlearnedEntries) },
                            onFilter: { showFilterSheet = true },
                            onCreate: { showCreateSheet = true }
                        )
                        .padding(.horizontal, editorialHorizontal)
                    }

                    // 北極星二:pill cluster ↔ notebook list 之間靠 AppAirDivider
                    // 分區。dividerAirMargin 已全域收緊 32 → 16 (user feedback)。
                    if !notebooks.isEmpty {
                        AppAirDivider()
                            .padding(.horizontal, editorialHorizontal)
                    }

                    switch listPhase {
                    case .loading:
                        // 首次 reconcile 完成前不顯示 empty state — 否則 logged-in users
                        // 啟動瞬間會閃過「還沒有單字本」誤導 copy。骨架沿用 VocabSceneShell。
                        loadingPlaceholder
                    case .error:
                        syncErrorState
                    case .empty:
                        emptyState
                    case .partial, .content:
                        // Editorial row list — 每本 notebook 一條 full-width row,書背隱喻。
                        // 取代舊 grid + hero 分支(grid 在小卡片下擠破,hero 浪費版面)。
                        LazyVStack(spacing: editorialGridSpacing) {
                            ForEach(sortedNotebooks) { notebook in
                                let s = stats[notebook.remoteId] ?? NotebookStats()
                                notebookActivationSurface(for: notebook) {
                                    NotebookCard(
                                        data: notebookCardData(for: notebook, stats: s),
                                        style: .grid,
                                        actions: notebookCardActions(for: notebook)
                                    )
                                }
                                .accessibilityIdentifier("notebook.card.\(notebook.remoteId)")
                                .transition(.listSwap)
                            }
                        }
                        .padding(.horizontal, editorialHorizontal)
                    }
                }
                .padding(.top, editorialTopInset)
            }
            .background(skin.palette.pageBackground)
            .navigationTitle(NotebookListCopy.navigationTitle)
            .largeNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                        .disabled(notebooks.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showArchiveList = true
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .accessibilityLabel(L10n.string("notebook.toolbar.archive"))
                }
            }
            .navigationDestination(for: String.self) { notebookId in
                VocabularyListView(notebookId: notebookId)
            }
            .toastSheet(isPresented: $showCreateSheet) {
                NotebookEditSheet(mode: .create) { appearance in
                    Task { @MainActor in
                        await coordinator.createNotebook(
                            name: appearance.name,
                            color: appearance.color,
                            coverPattern: appearance.coverPattern,
                            coverImagePath: appearance.coverImagePath,
                            modelContext: modelContext,
                            kgService: kgService,
                            toastCoordinator: toastCoordinator
                        )
                    }
                }
            }
            .toastSheet(item: $editingNotebook) { notebook in
                NotebookEditSheet(
                    mode: .edit(
                        name: notebook.name,
                        color: notebook.color,
                        coverPattern: notebook.coverPattern,
                        coverImagePath: notebook.coverImagePath
                    )
                ) { appearance in
                    // coverImagePath 的落地 + 舊圖刪除延到 updateNotebook API 成功後，
                    // 由 coordinator 統一處理（全有或全無），避免 API 失敗時「新封面 +
                    // server 舊欄位」drift 且舊封面回不去（track-23）。
                    Task { @MainActor in
                        await coordinator.updateNotebook(
                            notebook,
                            name: appearance.name,
                            color: appearance.color,
                            coverPattern: appearance.coverPattern,
                            stagedCoverImagePath: appearance.coverImagePath,
                            originalCoverImagePath: appearance.originalCoverImagePath,
                            modelContext: modelContext,
                            kgService: kgService,
                            toastCoordinator: toastCoordinator
                        )
                    }
                }
            }
            .onChange(of: activeReviewSession) { _, session in
                if let session {
                    detailState.showReview(session, allEntries: allEntries)
                    activeReviewSession = nil
                }
            }
            .toastSheet(isPresented: $showArchiveList) {
                ArchivedVocabSheet()
            }
            .toastSheet(isPresented: $showFilterSheet) {
                NotebookFilterPickerSheet(
                    filter: $reviewFilter,
                    notebooks: notebooks.filter { !$0.isSoftDeleted }
                )
            }
            .toastSheet(item: $coordinator.exportURL) { url in
                PlatformShareView(url: url)
                    .onDisappear { VocabularyExporter.cleanup(url) }
            }
            .onChange(of: accountTaskID) { _, _ in
                reviewFilter.resetForAccountChange()
            }
            .onAppear { reviewFilter.reloadFromStorage() }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                reviewFilter.reloadFromStorage()
            }
            .onChange(of: liveNotebookIDs, initial: true) { _, ids in
                reviewFilter.reconcile(with: ids)
            }
            .task(id: accountTaskID) {
                guard catalogTaskPolicy.runsTasks else { return }
                await coordinator.reconcileNotebooks(
                    authManager: authManager,
                    currentNotebooks: notebooks,
                    allEntries: allEntries,
                    modelContext: modelContext,
                    kgService: kgService
                )
                await coordinator.syncActiveNotebookFromServer(
                    authManager: authManager,
                    kgService: kgService
                )
            }
            .confirmationDialog(
                NotebookListCopy.deleteTitle,
                isPresented: Binding(
                    get: { notebookToDelete != nil },
                    set: { if !$0 { notebookToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(NotebookListCopy.deleteButtonTitle, role: .destructive) {
                    if let notebook = notebookToDelete {
                        Task { @MainActor in
                            await coordinator.deleteNotebook(
                                notebook,
                                isActive: activeNotebookId == notebook.remoteId,
                                availableNotebooks: notebooks,
                                allEntries: allEntries,
                                modelContext: modelContext,
                                kgService: kgService,
                                toastCoordinator: toastCoordinator,
                                setActiveNotebook: { setActiveNotebook($0) }
                            )
                        }
                        notebookToDelete = nil
                    }
                }
            } message: {
                Text(NotebookListCopy.deleteMessage)
            }
        }
        // detail/review cover 與 detailRouter 注入已上移至 NotebookListView 薄殼，
        // 使其脫離本 view 的 @Query — 翻卡寫入不再透過本層重跑 cover content closure。
        // 新增單字本 ⌘N(Mac menu)— 未登入不 publish → menu 自動 disable(對應 view 內 .disabled(!isLoggedIn))。
        .focusedSceneValue(
            \.newNotebook,
            authManager.isLoggedIn ? NewNotebookAction { showCreateSheet = true } : nil
        )
        // 開始今日複習 ⌘⏎(Mac menu)— 預設「全部」模式;無可複習項不 publish → menu disable。
        .focusedSceneValue(
            \.startReview,
            (filteredDueEntries + filteredUnlearnedEntries).isEmpty
                ? nil
                : StartReviewAction { startReview(with: filteredDueEntries + filteredUnlearnedEntries) }
        )
        .enableInjection()
    }

    // MARK: - Notebook card builders

    /// 把 `Notebook` model 收斂成 view-only `NotebookCardData`，
    /// 隔離 model → view 的對應，避免 init 區塊內聯在 list 迴圈裡。
    private func notebookCardData(for notebook: Notebook, stats s: NotebookStats) -> NotebookCardData {
        NotebookCardData(
            name: notebook.name,
            color: notebook.color,
            coverPattern: notebook.coverPattern,
            coverImagePath: notebook.coverImagePath,
            cardCount: s.cardCount,
            dueCount: s.dueCount,
            unlearnedCount: s.unlearnedCount,
            reviewedCount: s.reviewedCount,
            pendingCount: s.pendingCount,
            lastActivity: s.lastActivity,
            isActive: notebook.remoteId == activeNotebookId
        )
    }

    private func notebookCardActions(for notebook: Notebook) -> NotebookCardActions {
        NotebookCardActions(
            setActive: { setActiveNotebook(notebook.remoteId) },
            rename: { editingNotebook = notebook },
            editCover: { editingNotebook = notebook },
            export: { format in exportNotebook(notebook, format: format) },
            delete: { notebookToDelete = notebook },
            canDelete: !notebook.isDefault
        )
    }

    @ViewBuilder
    private func notebookActivationSurface<Content: View>(
        for notebook: Notebook,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // 單欄收斂後 notebook row 一律 drill-down：走 NavigationLink(value:) →
        // navigationDestination(for: String.self) push VocabularyListView。
        NavigationLink(value: notebook.remoteId) {
            content()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sort Menu

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { sortOption },
                set: { newValue in
                    withAnimation(AppMotion.standardSpring) {
                        sortOptionRaw = newValue.rawValue
                    }
                }
            )) {
                ForEach(NotebookSortOption.allCases) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            } label: {
                Text(NotebookListCopy.sortMenuTitle)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .accessibilityLabel(NotebookListCopy.sortAccessibilityLabel)
        }
    }

    // MARK: - Export Menu

    private func exportNotebook(_ notebook: Notebook, format: NotebookExportFormat) {
        let entries = allEntries.filter { $0.notebookId == notebook.remoteId }
        let exporterFormat: VocabularyExportFormat
        switch format {
        case .csv: exporterFormat = .csv
        case .json: exporterFormat = .json
        case .anki: exporterFormat = .anki
        }
        switch VocabularyExporter.export(entries: entries, format: exporterFormat) {
        case .success(let url):
            coordinator.exportURL = url
        case .failure(.empty):
            toastCoordinator.error(NotebookListCopy.exportEmpty)
        case .failure(.writeFailed):
            toastCoordinator.error(NotebookListCopy.exportFailure)
        }
    }

    // MARK: - Reconcile Error Banner

    /// 同步失敗時的 inline 錯誤橫幅：清單仍顯示本地資料，並提醒可手動重試。
    /// 對齊 `ui_state_matrix.md` 的「partial failure → 明確 inline error」方向，
    /// 不沉默吞掉 fetchNotebooks 錯誤。
    @ViewBuilder
    private func reconcileErrorBanner(message: String) -> some View {
        AppStateMessageCard(
            title: NotebookListCopy.reconcileErrorTitle,
            systemImage: "exclamationmark.triangle",
            description: message
        ) {
            Button(NotebookListCopy.retryTitle, action: retryReconcile)
            .buttonStyle(.appCompactAction(.primary))
        }
    }

    private func retryReconcile() {
        Task { @MainActor in
            await coordinator.reconcileNotebooks(
                authManager: authManager,
                currentNotebooks: notebooks,
                allEntries: allEntries,
                modelContext: modelContext,
                kgService: kgService
            )
        }
    }

    // MARK: - Loading Placeholder

    /// 首次 reconcile 尚未完成時顯示，避免 logged-in users 啟動瞬間誤看到 empty-state copy。
    /// 鏡像 PR #603 Podcast `.loading` 處理 — `loadingSkeleton` 比裸 spinner 更貼近最終 list 版面。
    @ViewBuilder
    private var loadingPlaceholder: some View {
        VocabSceneShell(phase: .loadingSkeleton(rowCount: 3)) {
            EmptyView()
        }
    }

    @ViewBuilder
    private var syncErrorState: some View {
        VocabSceneShell(
            phase: .error(
                title: NotebookListCopy.reconcileErrorTitle,
                systemImage: "exclamationmark.icloud",
                description: coordinator.reconcileError,
                retryAction: retryReconcile
            )
        ) {
            EmptyView()
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        let copy = NotebookListCopy.emptyState(isLoggedIn: authManager.isLoggedIn)
        if authManager.isLoggedIn {
            VocabSceneShell(phase: .empty(
                title: copy.title,
                systemImage: "books.vertical",
                description: copy.description,
                action: .init(
                    title: copy.actionTitle,
                    systemImage: copy.actionSystemImage,
                    handler: { showCreateSheet = true }
                )
            )) {
                EmptyView()
            }
        } else {
            VocabSceneShell(phase: .empty(
                title: copy.title,
                systemImage: "books.vertical",
                description: copy.description,
                action: .init(title: copy.actionTitle, systemImage: copy.actionSystemImage, handler: { loginGate.presentLogin() })
            )) {
                EmptyView()
            }
            .loginGateSheet($loginGate)
        }
    }

    // MARK: - Review Helpers

    private func startReview(with entries: [VocabularyEntry]) {
        // 空 entries 不再靜默吞掉：交給 TodayReviewPhaseView 落入 .empty 分支，
        // 提供明確回饋（active filter 下 filtered 集合可能為空，但 banner 仍顯示）。
        activeReviewSession = TodayReviewSession(entries: entries)
    }

    private func setActiveNotebook(_ id: String) {
        // 寫入收斂到 ActiveNotebookStore（本地 + iCloud KVS LWW）；@AppStorage 仍綁同一
        // UserDefaults key，透過 KVO 同步顯示。best-effort push 後端讓 chrome / web 能讀
        // （失敗不 rollback：iCloud KVS 已是 Apple 裝置跨裝置權威，backend 為補充橋樑）。
        ActiveNotebookStore.shared.setActive(id)
        // 同步捕捉 setActive 剛寫入的時戳，與 id 一起傳給 best-effort push（避免快速連續
        // 切換時 detached task 讀到後一次切換的時戳，push 出 id/時戳不一致對）。
        let updatedAt = ActiveNotebookStore.shared.snapshot.updatedAt
        guard authManager.isLoggedIn,
              !authManager.isDemoMode,
              let requestedUserId = authManager.userId,
              let requestedToken = authManager.token
        else { return }
        Task { @MainActor in
            await coordinator.pushActiveNotebook(
                id,
                updatedAt: updatedAt,
                requestedUserId: requestedUserId,
                requestedToken: requestedToken,
                authManager: authManager,
                kgService: kgService
            )
        }
    }
}
