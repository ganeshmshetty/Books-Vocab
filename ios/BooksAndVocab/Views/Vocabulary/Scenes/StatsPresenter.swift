//
//  StatsPresenter.swift
//  Books & Vocab
//
//  學習統計儀表板場景。
//

import SwiftUI
import SwiftData

/// Layout contract for the large number and its unit in an Overview metric.
/// The number may shrink to preserve the card row, but neither side may wrap
/// onto a second line and the unit must keep its intrinsic width.
enum StatsMetricValueLayout {
    static let maximumLines = 1
    static let minimumScaleFactor: CGFloat = 0.72
    static let allowsTightening = true
    static let unitIsFixedWidth = true
}

enum StatsScenePhase: Equatable {
    case loading
    case empty
    case content

    static func resolve(hasSummary: Bool, isEmpty: Bool) -> Self {
        guard hasSummary else { return .loading }
        return isEmpty ? .empty : .content
    }
}

struct StatsPresenter: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.kgService) private var kgService
    @Environment(\.authManager) private var authManager
    @Environment(\.statsProjectionClock) private var projectionClock

    let filter: NotebookFilter

    @Query(filter: #Predicate<VocabularyEntry> {
        $0.syncStatus == 1 &&
        $0.actionType != "delete"
    })
    private var syncedEntries: [VocabularyEntry]

    /// The projection owns its time-window filtering; keeping the query clock-free
    /// prevents a static wall-clock cutoff from escaping into the view path.
    @Query var reviewRecords: [ReviewRecord]

    @AppStorage("stats_forecast_days") private var forecastDays = 14

    @State private var summary: StatsPresentation.Summary?
    @State private var showCalendar = false
    @State private var contentReady = false
    @State private var graphLinks: [KGGraphLink]?
    @State private var graphHolder = GraphThumbnailHolder()
    /// `SyncFailurePresentation.reason` of the latest failed graph pull; nil when the last pull succeeded.
    @State private var graphFailureReason: String?
    @State private var retryToken: Int = 0

    /// Whether the graph `.task` may fetch links (demo/remote). Always true in
    /// production; the DEBUG catalog init disables it and injects links
    /// directly (mirrors `KnowledgeGraphView`'s DEBUG entry point).
    private let shouldLoadGraphData: Bool
    /// P9 callers may still provide the canonical fixture clock explicitly;
    /// ordinary composition injects the same value through the environment.
    private let explicitProjectionClock: StatsProjectionClock?

    init(
        filter: NotebookFilter = NotebookFilter(),
        initialSummary: StatsPresentation.Summary? = nil,
        reviewClock: StatsProjectionClock? = nil
    ) {
        self.filter = filter
        self.shouldLoadGraphData = true
        self.explicitProjectionClock = reviewClock
        _summary = State(initialValue: initialSummary)
        _contentReady = State(initialValue: initialSummary != nil)
        _reviewRecords = Query(
            sort: \ReviewRecord.reviewedAt,
            order: .reverse
        )
    }

#if DEBUG
    /// Catalog/preview-only entry: injects the 關聯圖 card's links directly
    /// (UI World manifest-derived) and disables the remote graph `.task`, so
    /// snapshots never depend on network, demo mode, or auth session state.
    /// `injectedGraphFailure` seeds the latest failed pull (5xx／offline) so the
    /// card's failure states render without a live request; nil links with no
    /// failure render the loading state.
    init(
        filter: NotebookFilter = NotebookFilter(),
        initialSummary: StatsPresentation.Summary? = nil,
        initialGraphLinks: [KGGraphLink]?,
        shouldLoadGraphData: Bool,
        reviewClock: StatsProjectionClock? = nil,
        injectedGraphFailure: Error? = nil
    ) {
        self.filter = filter
        self.shouldLoadGraphData = shouldLoadGraphData
        self.explicitProjectionClock = reviewClock
        _summary = State(initialValue: initialSummary)
        _contentReady = State(initialValue: initialSummary != nil)
        _graphLinks = State(initialValue: initialGraphLinks)
        _graphFailureReason = State(initialValue: injectedGraphFailure.map {
            SyncFailurePresentation.reason(for: $0)
        })
        _reviewRecords = Query(
            sort: \ReviewRecord.reviewedAt,
            order: .reverse
        )
    }
#endif

    var body: some View {
        VocabSceneShell(phase: currentPhase) {
            if let summary {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: appSkin.spacing.sectionGap) {
                            graphEntrySection
                            metricsSection(summary)
                            heatmapSection(summary)
                            forecastSection(summary)
                        }
                        .padding(.horizontal, appSkin.metrics.pageHorizontalInset)
                        .padding(.top, appSkin.metrics.pageTopInset)
                        .padding(.bottom, appSkin.metrics.pageBottomInset)
                    }
                    .vocabCanvasBackground()
                    .accessibilityIdentifier("overview.statsContent")
                    .opacity(contentReady ? 1 : 0)
                    .scaleEffect(contentReady ? 1 : 0.98)
                    .onAppear {
#if KG_RUN_CATALOG_SNAPSHOTS
                        contentReady = true
#else
                        withAnimation(AppMotion.contentReveal) {
                            contentReady = true
                        }
#endif
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("overview")
            }
        }
        .animatePhaseChange(summary != nil)
        .task(id: summaryKey) {
            let entries = filteredEntries
            let records = filteredReviewRecords
            let inputs = StatsPresentation.Inputs(
                entries: entries,
                reviewRecords: records,
                forecastDays: forecastDays,
                clock: activeProjectionClock
            )
            summary = StatsPresentation.project(inputs)
        }
        .task(id: graphKey) {
            // Fetches links per notebook in scope and merges them. Re-runs only when graphKey
            // changes (auth state, request scope, graph-link revision, or
            // retryToken bump from the inline error retry button), NOT on every
            // view appearance —
            // appearance ≠ staleness. The graph-link revision keeps a local
            // hide/unhide mutation observable even when entries.count is stable.
            // Long-term, KGGraphLink could become an @Model so @Query observers
            // across stats/graph/word-detail views refresh from one source.
            guard shouldLoadGraphData else { return }
            await loadGraphLinks()
        }
        .toastSheet(isPresented: $showCalendar) {
            ReviewCalendarPresenter(filter: filter, clock: activeProjectionClock)
        }
        .enableInjection()
    }

    // MARK: - Filtered Data

    private var filteredEntries: [VocabularyEntry] {
        filter.isFiltered
            ? syncedEntries.filter { filter.matches($0.notebookId) }
            : syncedEntries
    }

    private var filteredReviewRecords: [ReviewRecord] {
        filter.isFiltered
            ? reviewRecords.filter { filter.matches($0.notebookId) }
            : reviewRecords
    }

    private var activeProjectionClock: StatsProjectionClock {
        explicitProjectionClock ?? projectionClock
    }

    private func loadGraphLinks() async {
        if authManager.isDemoMode {
            graphLinks = DemoDataProvider.demoGraphLinks
            graphFailureReason = nil
            return
        }
        guard authManager.isLoggedIn else {
            graphLinks = []
            graphFailureReason = nil
            return
        }
        do {
            graphLinks = try await kgService.pullGraphLinks(
                notebookIDs: KnowledgeGraphNotebookScope.notebookIDs(for: filter, entries: filteredEntries)
            )
            graphFailureReason = nil
        } catch {
            // A superseded task (graphKey changed) is not a failure.
            if Task.isCancelled || error is CancellationError { return }
            // Failure is scoped to the graph card only — summary is built from
            // local syncedEntries and never fails. If we have cached links,
            // keep showing them with the card's visible status row (reason + retry).
            // If we have nothing yet, surface error inside the graph body
            // (not page-level).
            graphFailureReason = SyncFailurePresentation.reason(for: error)
        }
    }

    // MARK: - Phase Resolution

    private var currentPhase: VocabScenePhase {
        // Note: no page-level .error phase. `summary` is computed from local
        // `syncedEntries` (a SwiftData @Query) and cannot fail — so the only
        // failure mode is `pullGraphLinks`, which is scoped to the graph card
        // (handled inline via graphFailureReason + VocabGraphEntryCard).
        guard let summary else {
            return .loading(
                title: StatsCopy.loadingTitle,
                systemImage: "chart.bar"
            )
        }
        // An unfiltered account with no cards still owns the Overview surface:
        // render zero-valued metrics, calendar, and forecast so the user can
        // understand the destination and its next action. Reserve the page-
        // level empty state for a filtered projection with no matches; that is
        // the only case where the whole Overview surface is intentionally
        // replaced by a filter-recovery message.
        if filter.isFiltered && isSummaryEmpty(summary) {
            let title = filter.isFiltered
                ? L10n.string("目前沒有符合篩選條件的單字")
                : StatsCopy.emptyTitle
            let description = filter.isFiltered
                ? L10n.string("試試其他關鍵字，或取消部分篩選條件。")
                : StatsCopy.emptyDescription
            return .empty(
                title: title,
                systemImage: "chart.bar.xaxis",
                description: description
            )
        }
        return .content
    }

    private func isSummaryEmpty(_ summary: StatsPresentation.Summary) -> Bool {
        summary.totalCards == 0
            && summary.activity.values.allSatisfy { $0 == 0 }
            && summary.currentStreak == 0
            && summary.longestStreak == 0
    }

    private func retryGraphLoad() {
        graphFailureReason = nil
        retryToken &+= 1
    }

    private struct SummaryKey: Hashable {
        let projection: StatsPresentation.ProjectionKey
        let selectedNotebookIDs: Set<String>
    }

    private var summaryKey: SummaryKey {
        let inputs = StatsPresentation.Inputs(
            entries: filteredEntries,
            reviewRecords: filteredReviewRecords,
            forecastDays: forecastDays,
            clock: activeProjectionClock
        )
        return SummaryKey(
            projection: StatsPresentation.projectionKey(for: inputs),
            selectedNotebookIDs: filter.selectedIds
        )
    }

    /// Graph thumbnail refresh trigger. A single notebook filter changes the
    /// request scope and must invalidate this cache; links are fetched per
    /// notebook in scope and merged, so the key hashes the full scope. `forecastDays` is irrelevant. Auth
    /// toggles and entries.count (new cards may trigger backend link
    /// generation) trigger a re-pull; `retryToken` is bumped by the inline
    /// retry button so users can re-fetch after a network failure without
    /// changing other state.
    private var graphKey: Int {
        var hasher = Hasher()
        hasher.combine(syncedEntries.count)
        hasher.combine(KnowledgeGraphNotebookScope.linksRevision(of: syncedEntries))
        hasher.combine(KnowledgeGraphNotebookScope.requestKey(for: filter, entries: filteredEntries))
        hasher.combine(authManager.isLoggedIn)
        hasher.combine(authManager.isDemoMode)
        hasher.combine(retryToken)
        return hasher.finalize()
    }

    private var selectedNotebookId: String? {
        KnowledgeGraphNotebookScope.notebookID(for: filter)
    }

    // MARK: - Graph Entry
    private var graphEntrySection: some View {
        let nodes = graphThumbnailNodes
        let nodeIDs = Set(nodes.map(\.id))
        let edges = graphLinks.map {
            KnowledgeGraphPresentation.edges(from: $0, validNodeIDs: nodeIDs)
        } ?? []
        return VocabGraphEntryCard(
            linksLoaded: graphLinks != nil,
            linkCount: graphLinks?.count ?? 0,
            nodes: nodes,
            edges: edges,
            failureReason: graphFailureReason,
            holder: graphHolder,
            onRetry: retryGraphLoad
        ) {
            KnowledgeGraphView(
                allEntries: filteredEntries,
                notebookId: selectedNotebookId
            )
        }
    }

    private var graphThumbnailNodes: [KnowledgeGraphNode] {
        guard let graphLinks else { return [] }
        return KnowledgeGraphPresentation.nodes(
            from: filteredEntries,
            links: graphLinks,
            showIsolatedNodes: false,
            now: activeProjectionClock.dueNow
        )
    }

    // MARK: - Sections

    private func metricsSection(_ summary: StatsPresentation.Summary) -> some View {
        VStack(spacing: appSkin.spacing.sectionGap) {
            VocabStatHeroSurface {
                VStack(spacing: 0) {
                    VocabStatReadout(
                        title: StatsCopy.dueTodayTitle,
                        value: summary.formattedCount(summary.dueToday),
                        unit: StatsCopy.cardUnit,
                        systemImage: "clock",
                        identifier: "overview.metric.dueToday",
                        isHero: true
                    )
                    AppAirDivider()
                    VocabStatReadout(
                        title: StatsCopy.reviewedTodayTitle,
                        value: summary.formattedCount(summary.reviewedToday),
                        unit: StatsCopy.cardUnit,
                        systemImage: "checkmark.circle",
                        identifier: "overview.metric.reviewedToday"
                    )
                }
            }
            metricGrid(summary)
        }
        // Keep the section anchor while preserving the metric readouts as live
        // descendants in the iOS 26 accessibility tree. A bare identifier on
        // the VStack can collapse its children, leaving the rendered numbers
        // visible but making overview.metric.* unqueryable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("metrics")
        .background {
            if summary.totalCards >= 40 {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("large-counts")
                    .accessibilityValue(summary.formattedCount(summary.totalCards))
            }
        }
    }

    /// Two columns share one stack, so their edges align by construction (#2859).
    /// Dynamic Type's accessibility sizes swap the same children into one column.
    private func metricGrid(_ summary: StatsPresentation.Summary) -> some View {
        let layout = VocabStatTileLayout.columnCount(for: dynamicTypeSize) == 2
            ? AnyLayout(HStackLayout(alignment: .top, spacing: appSkin.spacing.sectionGap))
            : AnyLayout(VStackLayout(spacing: appSkin.spacing.sectionGap))
        return layout {
            VocabStatSurface {
                VocabStatReadout(
                    title: StatsCopy.totalCardsTitle,
                    value: summary.formattedCount(summary.totalCards),
                    unit: StatsCopy.cardUnit,
                    systemImage: "rectangle.stack",
                    identifier: "overview.metric.totalCards"
                )
            }
            VocabStatSurface {
                VStack(spacing: 0) {
                    VocabStatReadout(
                        title: StatsCopy.currentStreakTitle,
                        value: summary.formattedCount(summary.currentStreak),
                        unit: StatsCopy.dayUnit,
                        systemImage: "flame",
                        identifier: "overview.metric.currentStreak"
                    )
                    AppAirDivider()
                    VocabStatReadout(
                        title: StatsCopy.longestStreakTitle,
                        value: summary.formattedCount(summary.longestStreak),
                        unit: StatsCopy.dayUnit,
                        systemImage: "trophy",
                        identifier: "overview.metric.longestStreak"
                    )
                }
            }
        }
    }

    /// 20 weeks in production. Already overflows the heatmap viewport: the probe measured
    /// the container at ~163pt while 20 weeks need ≥325pt of content. UI tests may override
    /// the week count (`KG_UI_TEST_HEATMAP_WEEKS`) to pin a deterministic overflow for the
    /// open-on-latest-week check (#2736), independent of device width.
    private static var heatmapWeeks: Int {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["KG_UI_TEST_HEATMAP_WEEKS"],
           let weeks = Int(raw), (1...104).contains(weeks) {
            return weeks
        }
        #endif
        return 20
    }

    private func heatmapSection(_ summary: StatsPresentation.Summary) -> some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.inlineGap) {
            Button { showCalendar = true } label: {
                HStack(spacing: appSkin.spacing.rowMicroGap) {
                    sectionHeader(title: StatsCopy.calendarTitle, systemImage: "calendar")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(appSkin.typography.iconSmall)
                        .foregroundStyle(appSkin.palette.quaternaryText)
                }
                // .plain hit-testing falls through the Spacer gap between the
                // header and the chevron — same dead zone as SettingsNavigationRow.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(ReviewCalendarAccessibility.open)

            Button { showCalendar = true } label: {
                VocabCard {
                    VocabActivityHeatmap(
                        activity: summary.activity,
                        thresholds: summary.heatmapThresholds,
                        weeks: Self.heatmapWeeks,
                        clock: activeProjectionClock
                    )
                }
            }
            .buttonStyle(.liftable)
        }
        // Keep the section's projection separate from its actionable opener.
        // Without containment, SwiftUI propagates `calendar` to descendants
        // and shadows `reviewCalendar.open` in the runtime AX tree.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar")
        .accessibilityValue(summary.activity.values.reduce(0, +) == 0 ? "0" : "populated")
    }

    private func forecastSection(_ summary: StatsPresentation.Summary) -> some View {
        VStack(alignment: .leading, spacing: appSkin.spacing.inlineGap) {
            HStack {
                sectionHeader(title: StatsCopy.forecastTitle, systemImage: "chart.bar")
                Spacer()
                VocabTabSelector(
                    options: [
                        VocabTabOption(
                            id: 7,
                            title: L10n.string("7天"),
                            accessibilityIdentifier: "overview.forecast.range.7"
                        ),
                        VocabTabOption(
                            id: 14,
                            title: L10n.string("14天"),
                            accessibilityIdentifier: "overview.forecast.range.14"
                        ),
                        VocabTabOption(
                            id: 30,
                            title: L10n.string("30天"),
                            accessibilityIdentifier: "overview.forecast.range.30"
                        ),
                    ],
                    selection: $forecastDays
                )
            }

            VocabCard {
                VStack(spacing: 0) {
                    VocabForecastChart(buckets: summary.forecast)
                        .frame(height: 160)
                        // Keep the chart anchor while exposing each bar's
                        // live AX identifier through the nested GeometryReader.
                        // Without containment, iOS 26 can render the chart but
                        // omit forecast.bucket.* descendants from the snapshot.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("overview.forecast.chart")
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier(
                            summary.forecast.allSatisfy { $0.count == 0 } ? "forecast-zero" : "forecast"
                        )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("overview.forecast.card")
            .background {
                if summary.forecast.allSatisfy({ $0.count == 0 }) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("forecast-zero-counterexample")
                        .accessibilityValue(summary.formattedCount(0))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.forecast")
    }

    private func sectionHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: appSkin.spacing.rowMicroGap) {
            Image(systemName: systemImage)
                .font(appSkin.typography.iconSmall)
            Text(title)
                .font(appSkin.typography.caption)
        }
        .foregroundStyle(appSkin.palette.tertiaryText)
    }
}
