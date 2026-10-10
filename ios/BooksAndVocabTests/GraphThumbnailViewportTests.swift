#if DEBUG
import Foundation
import Testing
import WebKit
@testable import BooksAndVocab

/// Locks the viewport contract used by the persistent overview thumbnail.
///
/// The holder is created before SwiftUI gives it a non-zero frame, so the HTML
/// can observe a provisional viewport and later receive a larger one. Every
/// real size change must translate the existing layout by the center delta;
/// otherwise the settled cloud remains stranded in the old upper-left region.
@MainActor
struct GraphThumbnailViewportTests {
    private struct JSError: Error, CustomStringConvertible {
        let description: String
    }

    private func makeGraphWebView() throws -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        guard let htmlURL = Bundle.main.url(forResource: "graph", withExtension: "html") else {
            throw JSError(description: "graph.html missing from host app bundle")
        }
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        return webView
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func waitForGraphRuntime(in webView: WKWebView) async throws {
        for _ in 0..<200 {
            let loaded = try? await evaluate(
                "typeof window.initGraph === 'function' && typeof d3 !== 'undefined'",
                in: webView
            )
            if loaded as? Bool == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw JSError(description: "graph.html runtime did not become ready within 10s")
    }

    @Test func viewportGrowth_translatesExistingNodesByCenterDelta() async throws {
        let webView = try makeGraphWebView()
        try await waitForGraphRuntime(in: webView)

        guard let result = try await evaluate(
            """
            (() => {
              nodes = [{x: 0, y: 0}, {x: 10, y: 20}, {x: 20, y: 40}];
              sim = null;
              W = 100;
              H = 80;
              const before = { width: W, height: H, nodes: nodes.map(node => [node.x, node.y]) };
              window.reconcileGraphViewport(before.width + 80, before.height + 40);
              return JSON.stringify({ before, after: { width: W, height: H, nodes: nodes.map(node => [node.x, node.y]) } });
            })()
            """,
            in: webView
        ) as? String,
        let data = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
        let before = data["before"] as? [String: Any],
        let after = data["after"] as? [String: Any],
        let beforeWidth = before["width"] as? Double,
        let beforeHeight = before["height"] as? Double,
        let afterWidth = after["width"] as? Double,
        let afterHeight = after["height"] as? Double,
        let beforeNodes = before["nodes"] as? [[Double]],
        let afterNodes = after["nodes"] as? [[Double]]
        else {
            throw JSError(description: "viewport reconciliation result was unreadable")
        }

        #expect(afterWidth == beforeWidth + 80)
        #expect(afterHeight == beforeHeight + 40)
        #expect(afterNodes.count == beforeNodes.count)
        for (beforeNode, afterNode) in zip(beforeNodes, afterNodes) {
            #expect(abs((afterNode[0] - beforeNode[0]) - 40) < 0.001)
            #expect(abs((afterNode[1] - beforeNode[1]) - 20) < 0.001)
        }
    }

    @Test func provisionalThenFinalViewport_translatesOncePerRealSizeChange() async throws {
        let webView = try makeGraphWebView()
        try await waitForGraphRuntime(in: webView)

        guard let result = try await evaluate(
            """
            (() => {
              nodes = [{x: 0, y: 0}];
              sim = null;
              W = 0;
              H = 0;
              const first = window.reconcileGraphViewport(100, 80);
              const afterFirst = { width: W, height: H, node: [nodes[0].x, nodes[0].y] };
              const duplicate = window.reconcileGraphViewport(100, 80);
              const afterDuplicate = { width: W, height: H, node: [nodes[0].x, nodes[0].y] };
              const final = window.reconcileGraphViewport(180, 120);
              return JSON.stringify({ first, duplicate, final, afterFirst, afterDuplicate, afterFinal: { width: W, height: H, node: [nodes[0].x, nodes[0].y] } });
            })()
            """,
            in: webView
        ) as? String,
        let data = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
        let afterFirst = data["afterFirst"] as? [String: Any],
        let afterDuplicate = data["afterDuplicate"] as? [String: Any],
        let afterFinal = data["afterFinal"] as? [String: Any],
        let first = data["first"] as? Bool,
        let duplicate = data["duplicate"] as? Bool,
        let final = data["final"] as? Bool,
        let firstNode = afterFirst["node"] as? [Double],
        let duplicateNode = afterDuplicate["node"] as? [Double],
        let finalNode = afterFinal["node"] as? [Double]
        else {
            throw JSError(description: "provisional viewport reconciliation result was unreadable")
        }

        #expect(first)
        #expect(!duplicate)
        #expect(final)
        #expect(firstNode == [50, 40])
        #expect(duplicateNode == firstNode)
        #expect(finalNode == [90, 60])
    }

    /// #2860: the Overview card needs a first-paint signal so a thumbnail that
    /// never becomes visible can fall back to a status row instead of a blank body.
    @Test func thumbnailReportsPaintedExactlyWhenCanvasBecomesVisible() async throws {
        let webView = try makeGraphWebView()
        try await waitForGraphRuntime(in: webView)

        guard let result = try await evaluate(
            """
            (() => {
              const sent = [];
              postBridge = (obj) => sent.push(obj.type);
              nodes = [];
              links = [];
              isThumbnail = true;
              canvas.style.opacity = '0';
              sim = { alpha: () => 0.9 };
              draw();
              const whileHot = { sent: sent.slice(), opacity: canvas.style.opacity };
              sim = { alpha: () => 0.05 };
              draw();
              return JSON.stringify({ whileHot, converged: { sent: sent.slice(), opacity: canvas.style.opacity } });
            })()
            """,
            in: webView
        ) as? String,
        let data = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
        let hot = data["whileHot"] as? [String: Any],
        let converged = data["converged"] as? [String: Any]
        else {
            throw JSError(description: "painted-signal result was unreadable")
        }

        #expect(hot["sent"] as? [String] == [])
        #expect(hot["opacity"] as? String == "0")
        #expect(converged["sent"] as? [String] == ["painted"])
        #expect(converged["opacity"] as? String == "1")
    }

    /// #2860: retry on an unpainted thumbnail rebuilds the bridge state and
    /// re-arms the payload, so a successful retry is not left blank.
    /// `webView` stays nil: the test exercises state transitions only, not a page load.
    @Test func coordinatorRecover_resetsBridgeAndPaintAndReplaysLastPayload() {
        let coordinator = GraphThumbnailCoordinator()
        let payload = "{\"nodes\":[]}"

        coordinator.sendInitGraph(payload, webView: WKWebView(frame: .zero))
        coordinator.receiveBridgeEvent("ready")
        coordinator.receiveBridgeEvent("painted")
        #expect(coordinator.graphBridgeReady)
        #expect(coordinator.hasPainted)

        coordinator.recover()

        #expect(!coordinator.graphBridgeReady)
        #expect(!coordinator.hasPainted)
        #expect(coordinator.pendingPayload == payload)
        #expect(coordinator.lastPayload == payload)
    }

    @Test func coordinatorRecover_beforePaintKeepsBridgeReplayable() {
        let coordinator = GraphThumbnailCoordinator()

        coordinator.recover()

        #expect(!coordinator.graphBridgeReady)
        #expect(!coordinator.hasPainted)
        #expect(coordinator.pendingPayload == nil)
        #expect(coordinator.lastPayload == nil)
    }
}
#endif
