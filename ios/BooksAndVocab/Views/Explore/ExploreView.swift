//
//  ExploreView.swift
//  Books & Vocab
//
//  Explore（共享牌組庫）頂層 section —— 唯讀官方牌組瀏覽（Phase 1b-iii，無複製鈕）。
//
//  鏡射 PodcastHomeView 的殼：自有 NavigationStack(path:)、guest-tolerant 目錄同步
//  `.task`、四態（loading/error/empty/content）。牌組來自獨立 `SharedDeck @Model` 的
//  `@Query`（型別層與私人 Notebook 隔離）。搜尋 + 分類/語言/官方/排序篩選在本機套用
//  於已同步目錄（Phase 1：官方目錄量小、離線友善；server-side q/cursor 分頁為後續）。
//

import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

/// 唯讀目錄的展示相位。內容為主（有牌組即 content），其餘退回 loading/error/空。
enum ExplorePhase: Equatable {
    case loading
    case error
    /// 真空 —— 目錄尚無牌組（非篩選造成）。
    case empty
    /// 有目錄但當前 search/filter 無結果。
    case noResults
    /// 目錄有本機快取，但最新同步失敗；保留內容並明示資料可能過期。
    case partial
    case content

    static func resolve(
        isSyncing: Bool, syncFailed: Bool,
        totalDeckCount: Int, filteredCount: Int,
        isFilteringOrSearching: Bool
    ) -> ExplorePhase {
        if isSyncing && totalDeckCount == 0 { return .loading }
        if syncFailed && totalDeckCount == 0 { return .error }
        if totalDeckCount == 0 { return .empty }
        if filteredCount == 0 && isFilteringOrSearching { return .noResults }
        if syncFailed { return .partial }
        if filteredCount > 0 { return .content }
        return .empty
    }
}

/// 目錄同步的狀態機（#3682）。每次 run 以 `begin()` 取得遞增的 generation；只有**最新** run 的結果
/// 才能寫入 `isSyncing`／`syncFailed`，較舊的 overlapping run 結束時不得改寫（否則會關掉仍在跑的新 run 的 loading）。
/// 取消（`.cancelled`）代表沒有成功也沒有失敗，保留既有失敗態，不得把它清成「無失敗」。
struct ExploreSyncState: Equatable {
    private(set) var isSyncing = false
    private(set) var syncFailed = false
    private var latestGeneration = 0

    /// 開始一次 run，回傳該 run 的 generation。
    mutating func begin() -> Int {
        latestGeneration += 1
        isSyncing = true
        return latestGeneration
    }

    mutating func apply(outcome: SharedDeckCatalogService.SyncOutcome, generation: Int) {
        guard generation == latestGeneration else { return }
        isSyncing = false
        guard outcome != .cancelled else { return }
        syncFailed = outcome.failure != nil
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Deterministic UI World evidence node. Once a fixture is selected, every
/// asset lookup/decode failure is a fixture contract failure, never an empty
/// branch that lets a screenshot pass without its proof.
private struct ExploreFixtureAssetProof: View {
    let assetID: String

    var body: some View {
        let snapshot = Self.requireSnapshot(ref: assetID)
        guard let image = UIImage(contentsOfFile: snapshot.url.path) else {
            preconditionFailure(
                "Explore fixture asset \(assetID) could not decode at \(snapshot.url.path)"
            )
        }
        return Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 48, height: 48)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(UIWorldExploreFixtureID.assetSelector(for: assetID))
            .accessibilityLabel(assetID)
            .accessibilityValue(
                "sha256:\(snapshot.sha256); bytes:\(snapshot.byteSize); path:\(snapshot.url.path)"
            )
            .allowsHitTesting(false)
    }

    private static func requireSnapshot(ref: String) -> UIWorldInstalledAsset {
        do {
            return try FixtureDatasetStore.installedAssetSnapshot(ref: ref)
        } catch {
            preconditionFailure(
                "Explore fixture asset \(ref) has no valid installed snapshot: \(error)"
            )
        }
    }
}
#endif

/// Explore 導航路由（value-based push；freeze 契約鏡射 PodcastNavRoute）。
enum ExploreNavRoute: Hashable {
    case deck(deckId: String)
}

struct ExploreView: View {
    @ObserveInjection private var inject
    @Environment(\.appTheme) private var appTheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(\.toastCoordinator) private var toastCoordinator
    @Environment(\.kgService) private var kgService
    @Environment(\.authManager) private var authManager
    @Environment(\.catalogTaskPolicy) private var catalogTaskPolicy

#if DEBUG && targetEnvironment(simulator)
    private let catalogPreview: ExploreCatalogPreview?
    private let catalogServiceOverride: (any SharedDeckCatalogServicing)?
#endif

    @Query(filter: #Predicate<SharedDeck> { !$0.isSoftDeleted }, sort: \.sortOrder)
    private var decks: [SharedDeck]

    @State private var navigationPath = NavigationPath()
    @State private var syncState = ExploreSyncState()
    @State private var filter = ExploreFilter()
#if DEBUG && targetEnvironment(simulator)
    init(
        catalogPreview: ExploreCatalogPreview? = ExploreCatalogPreview.fromLaunchArguments(),
        catalogService: (any SharedDeckCatalogServicing)? = nil
    ) {
        self.catalogPreview = catalogPreview
        if let catalogService {
            self.catalogServiceOverride = catalogService
        } else if let catalogPreview {
            self.catalogServiceOverride = ExploreUIWorldCatalogService(
                fixtureID: catalogPreview.fixtureID,
                initialCacheFixtureID: catalogPreview.initialCacheFixtureID
            )
        } else {
            self.catalogServiceOverride = nil
        }
    }
#else
    init() {}
#endif

    private var layoutMode: LayoutMode { LayoutMode(horizontalSizeClass: sizeClass) }
    private var columns: [GridItem] { [layoutMode.bookshelfGridItem] }
    private var coverHeight: CGFloat { layoutMode.bookshelfCoverHeight }

    private var filteredDecks: [SharedDeck] {
        let byId = Dictionary(decks.map { ($0.remoteId, $0) }, uniquingKeysWith: { first, _ in first })
        return filter.apply(to: decks.map(\.projection)).compactMap { byId[$0.remoteId] }
    }

    private var availableCategories: [String] {
        Array(Set(decks.compactMap(\.category))).sorted()
    }

    private var availableLanguagePairs: [String] {
        Array(Set(decks.compactMap(\.languagePair))).sorted()
    }

    private var phase: ExplorePhase {
        return ExplorePhase.resolve(
            isSyncing: syncState.isSyncing, syncFailed: syncState.syncFailed,
            totalDeckCount: decks.count, filteredCount: filteredDecks.count,
            isFilteringOrSearching: filter.isSearching || filter.hasActiveFilters
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                appTheme.palette.pageBackground.ignoresSafeArea()
                switch phase {
                case .loading: loadingState
                case .error: errorState
                case .empty: emptyState
                case .noResults: noResultsState
                case .partial: content
                case .content: content
                }
            }
            .navigationTitle(L10n.string("app.section.explore"))
            .largeNavigationBarTitle()
            .searchable(
                text: $filter.searchText,
                prompt: L10n.string("explore.search.prompt")
            )
            #if targetEnvironment(macCatalyst)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { Task { await refreshCatalog() } }) {
                        AppToolbarGlyph(systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel(L10n.string("explore.refresh"))
                    .accessibilityIdentifier("explore.refreshButton")
                    .help(L10n.string("explore.refresh"))
                }
            }
            #endif
            .navigationDestination(for: ExploreNavRoute.self) { route in
                switch route {
                case .deck(let deckId):
                    SharedDeckDetailView(deckId: deckId)
                }
            }
            .task(id: authManager.isLoggedIn) {
                guard shouldRunCatalogTask else { return }
                await syncCatalog(showToastOnFailure: false)
            }
        }
        .enableInjection()
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.s3) {
                if syncState.syncFailed {
                    syncFailurePanel
                        .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)
                        .transition(.statusRowReveal)
                }
                filterBar
                deckGrid
            }
            .padding(.top, AppSpacing.s2)
            // 失敗面板進出要順滑，不得跳變。
            .animation(AppMotion.phaseChange, value: syncState.syncFailed)
            .animateContentFade(filteredDecks.count)
        }
        #if !targetEnvironment(macCatalyst)
        .refreshable { await refreshCatalog() }
        #endif
        // Keep the state marker on one semantic container; without `.contain`
        // SwiftUI propagates the identifier onto every rendered child.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.loadedState")
    }

    private var deckGrid: some View {
        LazyVGrid(columns: columns, spacing: AppShellMetrics.sectionSpacing) {
            ForEach(filteredDecks) { deck in
#if DEBUG && targetEnvironment(simulator)
                let assetSelector = deck.coverAssetID
                    .map(UIWorldExploreFixtureID.assetSelector(for:))
#else
                let assetSelector: String? = nil
#endif
                NavigationLink(value: ExploreNavRoute.deck(deckId: deck.remoteId)) {
                    ExploreDeckCard(
                        deck: deck,
                        coverHeight: coverHeight,
                        assetAccessibilityIdentifier: assetSelector
                    )
                }
                .buttonStyle(.bookshelfCard)
                .accessibilityIdentifier("explore.deck.\(deck.remoteId)")
                .transition(.bookshelfCard)
            }
        }
        .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)
    }

    // MARK: - Filter bar

    @ViewBuilder
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: AppSpacing.s2) {
                HStack(spacing: AppSpacing.s2) {
                    sortMenu
                    if !availableCategories.isEmpty {
                        ForEach(availableCategories, id: \.self) { category in
                            ExploreFilterChip(
                                title: SharedDeckFormat.categoryDisplayName(category),
                                isSelected: filter.category == category
                            ) {
                                filter.category = (filter.category == category) ? nil : category
                            }
                        }
                    }
                    if !availableLanguagePairs.isEmpty {
                        ForEach(availableLanguagePairs, id: \.self) { pair in
                            ExploreFilterChip(
                                title: pair,   // 語言對代碼（如 en-zh）；render-safe，非 i18n key
                                isSelected: filter.languagePair == pair
                            ) {
                                filter.languagePair = (filter.languagePair == pair) ? nil : pair
                            }
                        }
                    }
                }
                .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)
            }
        }
        .accessibilityIdentifier("explore.filterBar")
    }

    private var sortMenu: some View {
        Menu {
            Picker(L10n.string("explore.sort.label"), selection: $filter.sort) {
                ForEach(ExploreSort.allCases) { option in
                    Text(L10n.string(option.titleKey)).tag(option)
                }
            }
        } label: {
            ExploreFilterChipLabel(
                title: L10n.string(filter.sort.titleKey),
                systemImage: "arrow.up.arrow.down",
                isSelected: false
            )
        }
        .accessibilityLabel(L10n.string("explore.sort.label"))
        .accessibilityIdentifier("explore.sortMenu")
    }

    // MARK: - States

    private var emptyState: some View {
        stateScroll {
            VStack(spacing: AppSpacing.s2) {
                AppEmptyStateContent(
                    title: L10n.string("explore.empty.title"),
                    systemImage: "sparkles",
                    description: L10n.string("explore.empty.description"),
                    guidanceText: L10n.string("explore.empty.guidance"),
                    style: .bookshelf(appTheme)
                )
                fixtureAssetProof
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.emptyState")
    }

    private var noResultsState: some View {
        stateScroll {
            VStack(spacing: AppSpacing.s2) {
                if syncState.syncFailed {
                    syncFailurePanel
                        .transition(.statusRowReveal)
                }
                AppEmptyStateContent(
                    title: L10n.string("explore.noResults.title"),
                    systemImage: "magnifyingglass",
                    description: L10n.string("explore.noResults.description"),
                    action: AppEmptyStateAction(
                        title: L10n.string("explore.noResults.clear"),
                        systemImage: "xmark.circle",
                        handler: { filter = ExploreFilter() }
                    ),
                    style: .bookshelf(appTheme)
                )
            }
            .animation(AppMotion.phaseChange, value: syncState.syncFailed)
        }
    }

    /// 目錄有快取但最新同步失敗：持續狀態且需要使用者操作（重試），所以是畫面內
    /// 面板而非 pill（docs/sop/ui-design.md「暫時性提示」）。手動重新整理失敗時另由
    /// `syncCatalog(showToastOnFailure: true)` 彈一則 pill。
    private var syncFailurePanel: some View {
        AppStateMessageCard(
            title: L10n.string("explore.error.title"),
            systemImage: "exclamationmark.icloud",
            description: L10n.string("explore.error.description")
        ) {
            Button(L10n.string("explore.retry")) {
                Task { await refreshCatalog() }
            }
            .buttonStyle(.appCompactAction(.primary))
            .accessibilityIdentifier("explore.partialState.retry")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.partialState")
    }

    private var errorState: some View {
        stateScroll {
            VStack(spacing: AppSpacing.s2) {
                AppEmptyStateContent(
                    title: L10n.string("explore.error.title"),
                    systemImage: "exclamationmark.triangle",
                    description: L10n.string("explore.error.description"),
                    guidanceText: L10n.string("explore.error.guidance"),
                    action: AppEmptyStateAction(
                        title: L10n.string("explore.retry"),
                        systemImage: "arrow.clockwise",
                        accessibilityIdentifier: "explore.retryButton",
                        handler: { Task { await refreshCatalog() } }
                    ),
                    style: .bookshelf(appTheme)
                )
                fixtureAssetProof
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.errorState")
    }

    @ViewBuilder
    private var fixtureAssetProof: some View {
#if DEBUG && targetEnvironment(simulator)
        if let catalogPreview {
            ExploreFixtureAssetProof(assetID: catalogPreview.evidenceAssetID)
        }
#else
        EmptyView()
#endif
    }

    private var loadingState: some View {
        VStack(spacing: AppSpacing.s2) {
            Spacer()
            AppLoadingStateCard(
                title: L10n.string("explore.loading.title"),
                systemImage: "arrow.triangle.2.circlepath",
                description: L10n.string("explore.loading.description"),
                visualStyle: .app
            )
            .frame(maxWidth: 420)
            fixtureAssetProof
            Spacer()
        }
        .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.loadingState")
    }

    @ViewBuilder
    private func stateScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: AppSpacing.s4) {
                Spacer(minLength: 120)
                content()
                Spacer(minLength: 120)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)
        }
        #if !targetEnvironment(macCatalyst)
        .refreshable { await refreshCatalog() }
        #endif
    }

    // MARK: - Sync

    private var shouldRunCatalogTask: Bool {
        guard catalogTaskPolicy.runsTasks else { return false }
#if DEBUG && targetEnvironment(simulator)
        if catalogServiceOverride != nil { return true }
#endif
        return !AppRuntimeOptions.isUITesting()
    }

    @MainActor
    private func syncCatalog(showToastOnFailure: Bool) async {
        let generation = syncState.begin()
        let service: any SharedDeckCatalogServicing
#if DEBUG && targetEnvironment(simulator)
        service = catalogServiceOverride ?? SharedDeckCatalogService(kgService: kgService)
#else
        service = SharedDeckCatalogService(kgService: kgService)
#endif
        let outcome = await service.syncAll(context: modelContext)
        syncState.apply(outcome: outcome, generation: generation)
        if outcome.failure != nil && showToastOnFailure {
            toastCoordinator.warning(L10n.string("explore.error.title"))
        }
        // 取消 = 畫面被換掉或登入態切換，使用者沒看到目錄 → 不計入漏斗分母。browse 是
        // 分母，灌水會直接壓低 browse→preview 轉換率。與 `SharedDeckDetailView.load()`
        // 對 CancellationError 的處置同一條線。
        guard outcome != .cancelled else { return }
        // `deckCount` 取 **server 回的目錄大小**，不是 `filteredDecks.count`：後者讀
        // `@Query`，而 `syncAll` 回來到 `@Query` 重新求值之間沒有 await point，冷啟動
        // 時會系統性讀到同步前的 0——正是新用戶 session 最需要準確的地方。fetch 失敗
        // 走這裡時為 0（畫面是 error 態或本機快取），分析端據此區分。
        // 搜尋字串內容絕不上報，只上報「有沒有在搜」。
        let catalogCount: Int
        if case .completed(let count) = outcome { catalogCount = count } else { catalogCount = 0 }
        AppAnalytics.track(.deckBrowsed(
            deckCount: catalogCount,
            hasQuery: filter.isSearching,
            isFiltered: filter.hasActiveFilters
        ))
    }

    @MainActor
    private func refreshCatalog() async {
        await syncCatalog(showToastOnFailure: true)
    }
}
