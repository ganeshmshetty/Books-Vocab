import SwiftUI
import WebKit

// MARK: - Persistent holder — survives tab switches

final class GraphThumbnailHolder {
    let webView: WKWebView
    let coordinator: GraphThumbnailCoordinator

    init() {
        let coordinator = GraphThumbnailCoordinator()
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "graphBridge")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.backgroundColor = .clear
        coordinator.webView = webView
        webView.navigationDelegate = coordinator

        self.webView = webView
        self.coordinator = coordinator

        if let htmlURL = Bundle.main.url(forResource: "graph", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "graphBridge")
    }
}

// MARK: - Coordinator (message handler + signature dedup)

final class GraphThumbnailCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var graphBridgeReady = false
    var pendingPayload: String?
    var lastSignature: String?
    /// Last payload handed to the page, replayed after the web content process dies or `recover()`.
    private(set) var lastPayload: String?
    /// True once graph.html reported that the thumbnail canvas is visible (#2860).
    private(set) var hasPainted = false
    var onPainted: (() -> Void)?
    /// Fired when the page owes a fresh first paint (rebuilt, or lost after the
    /// automatic recoveries ran out). The card re-arms its paint watchdog here.
    var onRepaintExpected: (() -> Void)?
    weak var webView: WKWebView?
    /// Web-content terminations since the last paint. Automatic recovery stops
    /// once this reaches `maxAutomaticRecoveries`, so a page that crashes while
    /// loading cannot reload forever.
    private(set) var consecutiveTerminations = 0
    /// True once automatic recovery is spent on a dead page. The next Retry
    /// rebuilds it; a ready-handshake check alone would not, because a page lost
    /// after `ready` still reports `graphBridgeReady`.
    private(set) var pageLost = false
    static let maxAutomaticRecoveries = 3

    /// Routes this coordinator's paint events into a card's watchdog state.
    /// Captures only the two bindings, never the card value: the card owns the
    /// holder and the holder owns this coordinator, so a card capture closes a
    /// retain cycle that keeps the web view and its WebContent process alive
    /// after their owner is gone (#2860).
    @MainActor
    func bindPaintWatchdog(timedOut: Binding<Bool>, generation: Binding<Int>) {
        onPainted = { timedOut.wrappedValue = false }
        onRepaintExpected = {
            timedOut.wrappedValue = false
            generation.wrappedValue &+= 1
        }
    }

    func sendInitGraph(_ json: String, webView: WKWebView) {
        lastPayload = json
        // graph.html hides the canvas on every thumbnail init and reports `painted`
        // again once the simulation converges, so a previous paint no longer covers
        // this payload. The paint watchdog must see a fresh `painted`.
        hasPainted = false
        guard graphBridgeReady else { pendingPayload = json; return }
        webView.evaluateJavaScript("initGraph('\(json.jsSingleQuoteEscaped)')", completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "graphBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        receiveBridgeEvent(type)
    }

    /// Applies one graph.html bridge event. Split from the script-message entry
    /// point so the bridge state machine is unit-testable without WebKit.
    func receiveBridgeEvent(_ type: String) {
        guard ["ready", "painted"].contains(type) else { return }
        if type == "painted" {
            hasPainted = true
            consecutiveTerminations = 0
            pageLost = false
            onPainted?()
            return
        }
        graphBridgeReady = true
        if let pending = pendingPayload, let wv = webView {
            pendingPayload = nil
            sendInitGraph(pending, webView: wv)
        }
    }

    /// Retry rebuilds a page that never completed its `ready` handshake, or one
    /// lost after automatic recovery ran out. A page that is ready but still
    /// drawing is slow, not stuck; rebuilding it
    /// would restart the layout and can keep a large graph from ever painting.
    var needsRebuildOnRetry: Bool { pageLost || (!hasPainted && !graphBridgeReady) }

    /// Rebuilds the page and replays the last payload. Used when the web content
    /// process was terminated or the thumbnail never painted; without it
    /// `graphBridgeReady`/`lastSignature` would block any re-send forever.
    func recover() {
        graphBridgeReady = false
        hasPainted = false
        pageLost = false
        pendingPayload = lastPayload
        if let webView, let htmlURL = Bundle.main.url(forResource: "graph", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }
        onRepaintExpected?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard consecutiveTerminations < Self.maxAutomaticRecoveries else {
            // Automatic recovery is spent. The dead page must not keep looking
            // painted: clear the paint state so the watchdog shows the status row,
            // and its Retry rebuilds the page (`needsRebuildOnRetry`).
            pageLost = true
            hasPainted = false
            onRepaintExpected?()
            return
        }
        consecutiveTerminations += 1
        recover()
    }
}

// MARK: - SwiftUI representable (reuses holder's WKWebView)

struct GraphThumbnailWebView: UIViewRepresentable {
    let holder: GraphThumbnailHolder
    let nodes: [KnowledgeGraphNode]
    let edges: [KnowledgeGraphEdge]
    let theme: KnowledgeGraphTheme
    let colorScheme: ColorScheme

    func makeCoordinator() -> GraphThumbnailCoordinator { holder.coordinator }

    func makeUIView(context: Context) -> WKWebView { holder.webView }

    func updateUIView(_ webView: WKWebView, context: Context) {
        Self.performUpdate(webView, coordinator: holder.coordinator, nodes: nodes, edges: edges, theme: theme, colorScheme: colorScheme)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: GraphThumbnailCoordinator) {
        // No-op: holder owns the webview lifecycle
    }
}

// MARK: - Shared update + payload

extension GraphThumbnailWebView {
    /// Payload identity shared by `performUpdate` (re-init dedup) and the card
    /// (paint watchdog re-arm), so both agree on when a new payload exists.
    static func signature(nodes: [KnowledgeGraphNode], edges: [KnowledgeGraphEdge],
                          colorScheme: ColorScheme) -> String {
        // Signature uses discrete visual features only. `n.ratio` is excluded
        // because it derives from `Date()` in KnowledgeGraphPresentation.nodes
        // and drifts on every body recomputation, causing spurious re-inits
        // that reset the d3 simulation. colorHex rounds to 8-bit RGB
        // (#RRGGBB) in ReviewGradient.cssHex, so sub-second ratio drift
        // produces identical strings and visual meaning is preserved.
        // Reuses GraphWebView.dataSignature so thumbnail and full graph share one diff
        // (covers node word and edge id/from/to/kind, not just edge count).
        GraphWebView.dataSignature(nodes: nodes, edges: edges) + (colorScheme == .dark ? "D" : "L")
    }

    static func performUpdate(_ webView: WKWebView, coordinator: GraphThumbnailCoordinator,
                               nodes: [KnowledgeGraphNode], edges: [KnowledgeGraphEdge],
                               theme: KnowledgeGraphTheme, colorScheme: ColorScheme) {
        let sig = signature(nodes: nodes, edges: edges, colorScheme: colorScheme)
        guard coordinator.lastSignature != sig else { return }
        coordinator.lastSignature = sig
        coordinator.sendInitGraph(buildPayload(nodes: nodes, edges: edges, theme: theme, colorScheme: colorScheme), webView: webView)
    }

    private static func buildPayload(nodes: [KnowledgeGraphNode], edges: [KnowledgeGraphEdge],
                                      theme: KnowledgeGraphTheme, colorScheme: ColorScheme) -> String {
        struct NodePayload: Encodable {
            let id: String; let word: String; let tier: String
            let color: String?; let ratio: Double?; let degree: Int; let badge: String?
        }
        struct LinkPayload: Encodable {
            let id: String; let source: String; let target: String; let kind: String
        }
        struct TierPair: Encodable { let dark: String; let light: String }
        struct ThemePayload: Encodable {
            let mode: String; let background: String
            let colors: [String: TierPair]; let edges: [String: String]
            let label: String; let labelShadow: String
        }
        struct Payload: Encodable {
            let nodes: [NodePayload]; let links: [LinkPayload]
            let forces: GraphForces; let theme: ThemePayload; let thumbnail: Bool
        }

        let mode = colorScheme == .dark ? "dark" : "light"
        let nodePayloads = nodes.map {
            NodePayload(id: $0.id, word: $0.word, tier: $0.tier ?? "unknown",
                        color: $0.colorHex, ratio: $0.ratio, degree: $0.degree,
                        badge: $0.badgeSystemImage == nil ? nil : "▣")
        }
        let linkPayloads = edges.map {
            LinkPayload(id: $0.id, source: $0.from, target: $0.to, kind: $0.kind)
        }
        let tierNames = ["gray", "archived"]
        let colorPairs = tierNames.reduce(into: [String: TierPair]()) { result, name in
            let hex = theme.tierHexes[name] ?? "#888888" // token-allow: web graph payload fallback color
            result[name] = TierPair(dark: hex, light: hex)
        }
        let themePayload = ThemePayload(
            mode: mode, background: "transparent",
            colors: colorPairs, edges: theme.edgeHexes,
            label: theme.labelHex, labelShadow: theme.labelShadowHex
        )
        let forces = GraphForces(
            repel: 12, linkDistance: 12, linkStrength: 1.8,
            centerStrength: 0.2, baseNodeRadius: 4,
            collideRadius: 0, linkThickness: 0.8
        )
        let payload = Payload(
            nodes: nodePayloads, links: linkPayloads,
            forces: forces, theme: themePayload, thumbnail: true
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
