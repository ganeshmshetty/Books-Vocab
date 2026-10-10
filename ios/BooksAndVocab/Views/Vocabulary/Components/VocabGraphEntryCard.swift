import SwiftUI

/// Overview 關聯圖入口卡。狀態矩陣由 `StatsPresentation.graphCardState` 決定（#2860）：
/// 載入中、無快取失敗（錯誤面板＋原因＋重試）、有快取失敗或縮圖未繪出
/// （卡內常駐狀態列＋原因＋重試）。任何失敗都不會留下空白卡身。
struct VocabGraphEntryCard<Destination: View>: View {
    @ObserveInjection private var inject
    @Environment(\.appSkin) private var appSkin
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let linksLoaded: Bool
    let linkCount: Int
    let nodes: [KnowledgeGraphNode]
    let edges: [KnowledgeGraphEdge]
    /// `SyncFailurePresentation.reason(for:)` of the latest failed load.
    let failureReason: String?
    let holder: GraphThumbnailHolder
    let onRetry: () -> Void
    @ViewBuilder let destination: () -> Destination

    @State private var paintTimedOut = false
    @State private var paintTimerGeneration = 0

    /// Bounded wait for the web thumbnail's first paint before the card
    /// exposes the status row instead of a blank body.
    static var paintTimeout: Duration { .seconds(8) }

    private var state: StatsPresentation.GraphCardState {
        StatsPresentation.graphCardState(
            linksLoaded: linksLoaded,
            nodeCount: nodes.count,
            failureReason: failureReason,
            paintTimedOut: paintTimedOut
        )
    }

    var body: some View {
        let current = state
        Group {
            if case .failed(let reason) = current {
                errorCard(reason: reason)
            } else {
                contentCard(state: current)
            }
        }
        .animation(reduceMotion ? nil : AppMotion.panelState, value: current)
        .task(id: paintTimerKey(current)) { await runPaintTimer(current) }
        .onAppear {
            holder.coordinator.onPainted = { paintTimedOut = false }
        }
        .enableInjection()
    }

    // MARK: Error panel (no cached links)

    private func errorCard(reason: String) -> some View {
        VocabCard(padding: 0) {
            VStack(spacing: 0) {
                header(showsChevron: false)
                    .padding(appSkin.metrics.cardBlockPadding)
                VStack(spacing: appSkin.spacing.inlineGap) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(appSkin.typography.iconMedium)
                        .foregroundStyle(appSkin.palette.warning)
                    Text(StatsCopy.graphErrorTitle)
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.primaryText)
                    Text(reason)
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.tertiaryText)
                        .multilineTextAlignment(.center)
                    retryButton
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("overview.graph.error")
                .frame(maxWidth: .infinity)
                .padding(appSkin.metrics.cardBlockPadding)
                // An error state is an inline recovery affordance, not a
                // square graph canvas (keeps the zero forecast reachable).
                .frame(minHeight: 164)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.graph")
    }

    // MARK: Content card (links present)

    private func contentCard(state: StatsPresentation.GraphCardState) -> some View {
        // The status row's retry Button must stay outside any NavigationLink:
        // a link label collapses to one accessibility element, which would
        // hide the retry from VoiceOver and UI tests. The card is therefore
        // two link regions (header, thumbnail) around the status row.
        VocabCard(padding: 0) {
            VStack(spacing: 0) {
                NavigationLink(destination: destination) {
                    header(showsChevron: true)
                        .padding(appSkin.metrics.cardBlockPadding)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.liftable)

                if case .content(_, let notice?) = state {
                    statusRow(notice: notice)
                        .padding(.horizontal, appSkin.metrics.cardBlockPadding)
                        .padding(.bottom, appSkin.metrics.cardBlockPadding)
                        .transition(.opacity)
                }

                NavigationLink(destination: destination) {
                    VStack(spacing: 0) {
                        thumbnailBody(kind: bodyKind(of: state))
                            .aspectRatio(1, contentMode: .fit)

                        if let avgRatio = averageRatio() {
                            healthBar(ratio: avgRatio)
                                .padding(.horizontal, appSkin.metrics.cardBlockPadding)
                                .padding(.bottom, AppSpacing.s2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.liftable)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.graph")
    }

    private func bodyKind(of state: StatsPresentation.GraphCardState) -> StatsPresentation.GraphThumbnailBodyKind? {
        if case .content(let body, _) = state { return body }
        return nil
    }

    private func statusRow(notice: StatsPresentation.GraphCardNotice) -> some View {
        // Only a failed load is a freshness warning; an unpainted thumbnail is
        // neutral progress with the same retry.
        let isStale: Bool
        let title: String
        switch notice {
        case .stale: isStale = true; title = StatsCopy.staleDataTitle
        case .rendering: isStale = false; title = StatsCopy.renderingTitle
        }
        return HStack(spacing: appSkin.spacing.inlineGap) {
                Image(systemName: isStale ? "exclamationmark.triangle" : "hourglass")
                    .font(appSkin.typography.iconSmall)
                    .foregroundStyle(isStale ? appSkin.palette.warning : appSkin.palette.tertiaryText)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(appSkin.typography.caption)
                        .foregroundStyle(appSkin.palette.primaryText)
                    if let reason = notice.reason {
                        Text(reason)
                            .font(appSkin.typography.caption)
                            .foregroundStyle(appSkin.palette.tertiaryText)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: appSkin.spacing.inlineGap)
                retryButton
            }
            .padding(.leading, appSkin.spacing.inlineGap)
            .background(
                isStale ? appSkin.palette.warningBg : Color.clear,
                in: AppRoundedRect(roundness: AppRoundness.control)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("overview.graph.status")
    }

    private var retryButton: some View {
        Button {
            retry()
        } label: {
            HStack(spacing: appSkin.spacing.rowMicroGap) {
                Image(systemName: "arrow.clockwise")
                    .font(appSkin.typography.iconSmall)
                Text(StatsCopy.retryTitle)
                    .font(appSkin.typography.caption)
            }
            .padding(.horizontal, appSkin.spacing.inlineGap)
            .frame(minHeight: AppBannerMetrics.actionHitTarget)
            .foregroundStyle(appSkin.palette.warning)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("overview.graph.retry")
    }

    private func retry() {
        // Paint state, not the failure reason, decides whether the web view must
        // be rebuilt: a cached-link failure can coexist with an unpainted thumbnail.
        if !holder.coordinator.hasPainted {
            holder.coordinator.recover()
            paintTimedOut = false
            paintTimerGeneration &+= 1
        }
        onRetry()
    }

    // MARK: Header / body

    private func header(showsChevron: Bool) -> some View {
        HStack(spacing: appSkin.spacing.inlineGap) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(appSkin.typography.iconMedium)
                .foregroundStyle(AppColors.chartHighlight)
            Text(StatsCopy.graphTitle)
                .font(appSkin.typography.caption)
                .foregroundStyle(appSkin.palette.primaryText)
            Spacer()
            if linksLoaded, linkCount > 0 {
                Text(L10n.format(
                    "%@ · %@",
                    L10n.format("vocab_graph_node_count_plural", Int64(nodes.count)),
                    L10n.format("vocab_graph_link_count_plural", Int64(linkCount))
                ))
                    .font(appSkin.typography.monoLabel)
                    .foregroundStyle(appSkin.palette.quaternaryText)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(appSkin.typography.iconSmall)
                    .foregroundStyle(appSkin.palette.quaternaryText)
            }
        }
    }

    @ViewBuilder
    private func thumbnailBody(kind: StatsPresentation.GraphThumbnailBodyKind?) -> some View {
        switch kind ?? .loading {
        case .loading:
            AppLoadingStateCard(
                title: StatsCopy.loadingTitle,
                systemImage: "chart.bar",
                visualStyle: .vocab
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            AppStateMessageContent(
                title: StatsCopy.graphEmptyTitle,
                systemImage: "point.3.connected.trianglepath.dotted",
                style: .vocab(appSkin)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(appSkin.metrics.cardBlockPadding)
        case .graph:
            GraphThumbnailWebView(
                holder: holder,
                nodes: nodes,
                edges: edges,
                theme: KnowledgeGraphPresentation.theme(for: appSkin),
                colorScheme: colorScheme
            )
        }
    }

    // MARK: First-paint watchdog

    private func paintTimerKey(_ state: StatsPresentation.GraphCardState) -> Int {
        var hasher = Hasher()
        hasher.combine(bodyKind(of: state) == .graph)
        hasher.combine(paintTimerGeneration)
        return hasher.finalize()
    }

    private func runPaintTimer(_ state: StatsPresentation.GraphCardState) async {
        guard bodyKind(of: state) == .graph, !holder.coordinator.hasPainted else { return }
        try? await Task.sleep(for: Self.paintTimeout)
        guard !Task.isCancelled, !holder.coordinator.hasPainted else { return }
        paintTimedOut = true
    }

    // MARK: Health bar

    private func averageRatio() -> Double? {
        let ratios = nodes.compactMap(\.ratio)
        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / Double(ratios.count)
    }

    private func healthBar(ratio: Double) -> some View {
        let stops: [Gradient.Stop] = [
            0, 0.15, 0.30, 0.45, 0.60, 0.72, 0.85, 1.0, 1.3, 2.0, 3.0
        ].map { r in
            Gradient.Stop(
                color: ReviewGradient.color(for: r),
                location: CGFloat(min(r / 3.0, 1.0))
            )
        }
        let position = CGFloat(min(max(ratio, 0), 3.0) / 3.0)

        return VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    AppRoundedRect(roundness: AppRoundness.pill)
                        .fill(LinearGradient(
                            stops: stops,
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(height: 2)

                    GraphHealthTriangle()
                        .fill(appSkin.palette.primaryText)
                        .frame(width: 6, height: 5)
                        .offset(
                            x: geo.size.width * position - 3,
                            y: -4
                        )
                }
            }
            .frame(height: 7)
        }
    }
}

private struct GraphHealthTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.minX, y: 0))
        p.closeSubpath()
        return p
    }
}
