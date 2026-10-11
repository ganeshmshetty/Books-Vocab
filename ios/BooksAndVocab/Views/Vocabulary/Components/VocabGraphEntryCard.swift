import SwiftUI

/// Overview 關聯圖入口卡。狀態矩陣由 `StatsPresentation.graphCardState` 決定（#2860）：
/// 載入中、無快取失敗（錯誤面板＋原因＋重試）、有快取失敗（卡內狀態列＋原因＋重試，
/// 快取圖保留）、縮圖逾時未繪出（卡身改為說明文字，狀態列＋重試）。卡身只會是
/// 載入佔位、錯誤面板、empty 卡身、快取圖或逾時說明；縮圖在首次繪製時限內可能暫時
/// 留白，逾時後一律改為說明文字，不會永久留下空白方塊。
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

    // Explicit init: the stored `@State private` members would otherwise make
    // the synthesized memberwise initializer private to this file.
    init(
        linksLoaded: Bool,
        linkCount: Int,
        nodes: [KnowledgeGraphNode],
        edges: [KnowledgeGraphEdge],
        failureReason: String?,
        holder: GraphThumbnailHolder,
        onRetry: @escaping () -> Void,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.linksLoaded = linksLoaded
        self.linkCount = linkCount
        self.nodes = nodes
        self.edges = edges
        self.failureReason = failureReason
        self.holder = holder
        self.onRetry = onRetry
        self.destination = destination
    }

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
        // A new payload makes graph.html hide and repaint the canvas. The watchdog
        // restarts here; the coordinator resets `hasPainted` when it sends the payload.
        .onChange(of: thumbnailSignature) { _, _ in rearmPaintWatchdog() }
        .onAppear {
            holder.coordinator.bindPaintWatchdog(timedOut: $paintTimedOut, generation: $paintTimerGeneration)
        }
        .enableInjection()
    }

    private var thumbnailSignature: String {
        GraphThumbnailWebView.signature(nodes: nodes, edges: edges, colorScheme: colorScheme)
    }

    private func rearmPaintWatchdog() {
        paintTimedOut = false
        paintTimerGeneration &+= 1
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
        // The retry Button must stay outside any NavigationLink: a link label
        // collapses to one accessibility element, which would hide the retry
        // from VoiceOver and UI tests. So the status row is a link beside its
        // retry button, and the header and thumbnail are links of their own.
        VocabCard(padding: 0) {
            VStack(spacing: 0) {
                NavigationLink {
                    destination()
                } label: {
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

                NavigationLink {
                    destination()
                } label: {
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
        // Everything except the retry button navigates, per the card contract.
        return HStack(spacing: appSkin.spacing.inlineGap) {
            NavigationLink {
                destination()
            } label: {
                HStack(spacing: appSkin.spacing.inlineGap) {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, appSkin.spacing.inlineGap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.liftable)
            retryButton
        }
        .padding(.trailing, appSkin.spacing.inlineGap)
        .background(
            isStale ? appSkin.palette.warningBg : Color.clear,
            in: AppRoundedRect(roundness: AppRoundness.control)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isStale ? "overview.graph.stale" : "overview.graph.rendering")
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
        // The error panel never built a thumbnail, so it has no web view to rebuild.
        // A `.unpainted` body means the watchdog fired, so a ready page is reloaded.
        let body = bodyKind(of: state)
        if body == .graph || body == .unpainted,
           holder.coordinator.needsRebuildOnRetry(paintTimedOut: body == .unpainted) {
            holder.coordinator.recover()
        }
        if body == .graph || body == .unpainted, !holder.coordinator.hasPainted {
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
        case .unpainted:
            // Replaces the web view while the paint watchdog has fired; the
            // status row below carries the retry. The web view is detached in
            // this state, so a late paint is not relied on: Retry reloads the
            // page (`recover`), reattaches it and re-arms the watchdog. Unverified
            // on device (#2860 stays Refs until a fault-injection run confirms it).
            AppStateMessageContent(
                title: StatsCopy.graphUnpaintedTitle,
                systemImage: "hourglass",
                style: .vocab(appSkin)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(appSkin.metrics.cardBlockPadding)
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
        // No `hasPainted` check before the wait: a new payload resets it on the
        // update pass, which can land after this task starts. Only the state
        // after the bounded wait decides whether the page is unpainted.
        guard bodyKind(of: state) == .graph else { return }
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
