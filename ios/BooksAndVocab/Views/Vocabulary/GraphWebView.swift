import SwiftUI
import WebKit

// MARK: - GraphForces

struct GraphForces: Equatable, Encodable {
    let repel: Double
    let linkDistance: Double
    let linkStrength: Double
    let centerStrength: Double
    let baseNodeRadius: Double
    let collideRadius: Double
    let linkThickness: Double

    func toJSONString() -> String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}"
    }
}

// MARK: - GraphWebView

struct GraphWebView: UIViewRepresentable {
    let nodes: [KnowledgeGraphNode]
    let edges: [KnowledgeGraphEdge]
    let colorScheme: ColorScheme
    let backgroundHex: String
    let tierHexes: [String: String]
    let edgeHexes: [String: String]
    let labelHex: String
    let labelShadowHex: String
    let forces: GraphForces
    var onNodeTap: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNodeTap: onNodeTap)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = Self.createWebView(context: context)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        Self.updateWebView(context: context, nodes: nodes, edges: edges,
                           colorScheme: colorScheme, backgroundHex: backgroundHex,
                           tierHexes: tierHexes, edgeHexes: edgeHexes, labelHex: labelHex,
                           labelShadowHex: labelShadowHex, forces: forces, onNodeTap: onNodeTap)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        Self.dismantleWebView(webView, coordinator: coordinator)
    }
}

// MARK: - Shared implementation

extension GraphWebView {
    static func createWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "graphBridge")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        guard let htmlURL = Bundle.main.url(forResource: "graph", withExtension: "html") else {
            return webView
        }
        let bundleDir = htmlURL.deletingLastPathComponent()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: bundleDir)
        return webView
    }

    static func updateWebView(
        context: Context,
        nodes: [KnowledgeGraphNode], edges: [KnowledgeGraphEdge],
        colorScheme: ColorScheme, backgroundHex: String,
        tierHexes: [String: String], edgeHexes: [String: String],
        labelHex: String, labelShadowHex: String,
        forces: GraphForces, onNodeTap: @escaping (String) -> Void
    ) {
        let coord = context.coordinator
        coord.onNodeTap = onNodeTap
        let sig = themeSignature(colorScheme: colorScheme, backgroundHex: backgroundHex,
                                  labelHex: labelHex, labelShadowHex: labelShadowHex,
                                  tierHexes: tierHexes, edgeHexes: edgeHexes)
        let dataSig = dataSignature(nodes: nodes, edges: edges)
        let themeChanged = coord.lastThemeSignature != sig || coord.lastColorScheme != colorScheme
        // count-only diff missed per-node visual changes after a review (tier gray→gradient,
        // colorHex nil→cssHex) while node/edge counts stay constant — so the graph kept
        // rendering stale colors. Diff a content signature instead of counts.
        let dataChanged = coord.lastDataSignature != dataSig

        if themeChanged || dataChanged {
            coord.lastThemeSignature = sig
            coord.lastColorScheme = colorScheme
            coord.lastDataSignature = dataSig
            let payload = buildPayload(nodes: nodes, edges: edges, colorScheme: colorScheme,
                                        backgroundHex: backgroundHex, tierHexes: tierHexes,
                                        edgeHexes: edgeHexes, labelHex: labelHex,
                                        labelShadowHex: labelShadowHex, forces: forces)
            coord.sendInitGraph(payload)
        }

        coord.sendForces(forces)
    }

    static func dismantleWebView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "graphBridge")
        coordinator.onNodeTap = nil
    }

    // MARK: - Payload builder

    private static func buildPayload(
        nodes: [KnowledgeGraphNode], edges: [KnowledgeGraphEdge],
        colorScheme: ColorScheme, backgroundHex: String,
        tierHexes: [String: String], edgeHexes: [String: String],
        labelHex: String, labelShadowHex: String, forces: GraphForces
    ) -> String {
        let mode = colorScheme == .dark ? "dark" : "light"

        let tierNames = ["gray", "archived"]
        var colorsDict: [String: [String: String]] = [:]
        for tierName in tierNames {
            let hex = tierHexes[tierName] ?? "#888888" // token-allow: web graph payload fallback color
            colorsDict[tierName] = ["dark": hex, "light": hex]
        }

        struct NodePayload: Encodable {
            let id, word: String
            let tier: String
            let color: String?
            let ratio: Double?
            let degree: Int
            let badge: String?
        }
        struct LinkPayload: Encodable {
            let id, source, target, kind: String
        }
        struct TierPair: Encodable {
            let dark, light: String
        }
        struct ThemePayload: Encodable {
            let mode, background: String
            let colors: [String: TierPair]
            let edges: [String: String]
            let label: String
            let labelShadow: String
        }
        struct Payload: Encodable {
            let nodes: [NodePayload]
            let links: [LinkPayload]
            let forces: GraphForces
            let theme: ThemePayload
        }

        let nodePayloads = nodes.map {
            NodePayload(
                id: $0.id, word: $0.word, tier: $0.tier ?? "unknown",
                color: $0.colorHex, ratio: $0.ratio, degree: $0.degree,
                badge: $0.badgeSystemImage == nil ? nil : "▣"
            )
        }
        let linkPayloads = edges.map {
            LinkPayload(id: $0.id, source: $0.from, target: $0.to, kind: $0.kind)
        }
        let colorPairs = colorsDict.reduce(into: [String: TierPair]()) { partialResult, entry in
            let dark = entry.value["dark"] ?? "#888888" // token-allow: web graph payload fallback color
            let light = entry.value["light"] ?? dark
            partialResult[entry.key] = TierPair(dark: dark, light: light)
        }
        let theme = ThemePayload(mode: mode, background: backgroundHex, colors: colorPairs,
                                  edges: edgeHexes, label: labelHex, labelShadow: labelShadowHex)
        let payload = Payload(nodes: nodePayloads, links: linkPayloads, forces: forces, theme: theme)

        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static func themeSignature(
        colorScheme: ColorScheme, backgroundHex: String,
        labelHex: String, labelShadowHex: String,
        tierHexes: [String: String], edgeHexes: [String: String]
    ) -> String {
        let sortedTiers = tierHexes.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        let sortedEdges = edgeHexes.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        return "\(colorScheme)-\(backgroundHex)-\(labelHex)-\(labelShadowHex)-\(sortedTiers)-\(sortedEdges)"
    }

    /// Content signature over the node/edge fields that drive rendering.
    ///
    /// Invariant: stable when nothing visual changed (so identical input never triggers a
    /// redundant redraw / layout reset), but changes whenever a reviewed node's `tier` or
    /// `colorHex` shifts (gray→gradient, nil→cssHex) even though node/edge counts stay
    /// constant — which is exactly what the old count-only diff missed.
    ///
    /// `ratio` is deliberately excluded (matching `GraphThumbnailWebView.performUpdate`):
    /// it derives from `Date()` in `KnowledgeGraphPresentation.reviewRatio`, so it drifts on
    /// every SwiftUI `body` recomputation. Even `%.4f` formatting can't pin it — under the
    /// 6h SRS floor, ratio crosses a 0.0001 quantum roughly every ~2.2s, so any two updates
    /// >2s apart would flip the signature and force a spurious redraw + d3 layout reset (the
    /// very jitter this diff exists to prevent). `colorHex = ReviewGradient.cssHex(for: ratio)`
    /// already quantizes ratio to 8-bit RGB, so a review that changes the color necessarily
    /// changes `colorHex` and still triggers a redraw — raw `ratio` is redundant and toxic.
    static func dataSignature(
        nodes: [KnowledgeGraphNode], edges: [KnowledgeGraphEdge]
    ) -> String {
        let nodeSig = nodes.map { node -> String in
            "\(node.id)|\(node.word)|\(node.tier ?? "-")|\(node.colorHex ?? "-")|\(node.degree)|\(node.badgeSystemImage ?? "-")"
        }.joined(separator: ";")
        let edgeSig = edges.map { "\($0.id)|\($0.from)|\($0.to)|\($0.kind)" }
            .joined(separator: ";")
        return "N[\(nodeSig)]L[\(edgeSig)]"
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var graphBridgeReady = false
        weak var webView: WKWebView?
        var onNodeTap: ((String) -> Void)?

        var lastColorScheme: ColorScheme? = nil
        var lastThemeSignature: String? = nil
        var lastForces: GraphForces? = nil
        var lastDataSignature: String? = nil
        /// Last payload handed to the page. Replayed on every `ready`, because a reloaded
        /// page starts with no graph state after a WebContent termination (#3817).
        private(set) var lastPayload: String? = nil
        /// Test seam: receives each script instead of the live web view. Production leaves it nil.
        var evaluatedScripts: ((String) -> Void)?
        /// Web-content terminations since this view was built. Automatic reload stops at
        /// `maxAutomaticRecoveries`, so a page that dies on load cannot reload forever.
        private(set) var consecutiveTerminations = 0
        static let maxAutomaticRecoveries = 3

        init(onNodeTap: @escaping (String) -> Void) {
            self.onNodeTap = onNodeTap
        }

        func sendInitGraph(_ json: String) {
            lastPayload = json
            guard graphBridgeReady else { return }
            evaluate("initGraph('\(json.jsSingleQuoteEscaped)')")
        }

        /// `updateForces` is never sent before `ready`; the ready replay carries the latest forces (#3817).
        func sendForces(_ forces: GraphForces) {
            guard lastForces != forces else { return }
            lastForces = forces
            guard graphBridgeReady else { return }
            evaluate("updateForces(\(forces.toJSONString()))")
        }

        private func evaluate(_ script: String) {
            if let evaluatedScripts {
                evaluatedScripts(script)
                return
            }
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        /// Applies the page's `ready` handshake. Runs on first load and on every reload.
        func handleBridgeReady() {
            graphBridgeReady = true
            if let lastPayload {
                evaluate("initGraph('\(lastPayload.jsSingleQuoteEscaped)')")
            }
            if let lastForces {
                evaluate("updateForces(\(lastForces.toJSONString()))")
            }
        }

        /// The page lost its JS state, so it must handshake again before it can take scripts.
        func handleContentProcessTerminated() {
            graphBridgeReady = false
            guard consecutiveTerminations < Self.maxAutomaticRecoveries else { return }
            consecutiveTerminations += 1
            webView?.reload()
        }

        // MARK: WKNavigationDelegate

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            handleContentProcessTerminated()
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "graphBridge",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "ready":
                handleBridgeReady()
            case "nodeClick":
                if let nodeId = body["nodeId"] as? String {
                    DispatchQueue.main.async { [weak self] in
                        self?.onNodeTap?(nodeId)
                    }
                }
            default:
                break
            }
        }
    }
}
