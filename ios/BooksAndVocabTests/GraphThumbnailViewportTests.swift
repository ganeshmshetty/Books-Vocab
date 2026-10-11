#if DEBUG
import Foundation
import SwiftUI
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
    /// A real WKWebView is attached so `ready` actually drains the pending payload.
    @Test func coordinatorRecover_resetsBridgeAndPaintAndReplaysLastPayload() {
        let coordinator = GraphThumbnailCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView
        let payload = "{\"nodes\":[]}"

        coordinator.sendInitGraph(payload, webView: webView)
        #expect(coordinator.pendingPayload == payload)

        coordinator.receiveBridgeEvent("ready")
        coordinator.receiveBridgeEvent("painted")
        #expect(coordinator.pendingPayload == nil)
        #expect(coordinator.graphBridgeReady)
        #expect(coordinator.hasPainted)

        coordinator.recover()

        #expect(!coordinator.graphBridgeReady)
        #expect(!coordinator.hasPainted)
        #expect(coordinator.pendingPayload == payload)
        #expect(coordinator.lastPayload == payload)
    }

    /// Automatic recovery after web-content termination is capped at three
    /// consecutive terminations without a paint. The fourth leaves the page dead
    /// but not painted, so the watchdog shows the status row and Retry rebuilds it.
    @Test func webContentTermination_autoRecoversAtMostThreeTimesUntilPaint() {
        let coordinator = GraphThumbnailCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView
        let payload = "{\"nodes\":[]}"
        coordinator.sendInitGraph(payload, webView: webView)
        coordinator.receiveBridgeEvent("ready")

        for _ in 0..<3 {
            coordinator.webViewWebContentProcessDidTerminate(webView)
            #expect(!coordinator.graphBridgeReady)
            coordinator.receiveBridgeEvent("ready")
            #expect(coordinator.graphBridgeReady)
        }

        coordinator.webViewWebContentProcessDidTerminate(webView)
        #expect(coordinator.graphBridgeReady, "fourth termination must not auto-recover")
        #expect(coordinator.pendingPayload == nil)
        #expect(!coordinator.hasPainted, "a dead page must not keep looking painted")
        #expect(coordinator.needsRebuildOnRetry(paintTimedOut: false), "manual Retry must rebuild a page lost after ready")

        coordinator.receiveBridgeEvent("painted")
        #expect(!coordinator.needsRebuildOnRetry(paintTimedOut: false), "a paint clears the lost-page state")
        coordinator.webViewWebContentProcessDidTerminate(webView)
        #expect(!coordinator.graphBridgeReady, "a paint resets the termination budget")
    }

    /// A payload sent after a paint is hidden again by graph.html, so the old
    /// `painted` must not satisfy the watchdog for the new graph.
    @Test func newPayload_requiresFreshPaintAfterEarlierPaint() {
        let coordinator = GraphThumbnailCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView
        coordinator.sendInitGraph("{\"nodes\":[]}", webView: webView)
        coordinator.receiveBridgeEvent("ready")
        coordinator.receiveBridgeEvent("painted")
        #expect(coordinator.hasPainted)

        coordinator.sendInitGraph("{\"nodes\":[1]}", webView: webView)
        #expect(!coordinator.hasPainted, "the re-rendered graph starts hidden; the earlier paint no longer covers it")

        coordinator.receiveBridgeEvent("painted")
        #expect(coordinator.hasPainted)
    }

    /// Recovery owes the card a fresh paint. The card re-arms its watchdog
    /// through `onRepaintExpected`; without that a rebuilt page that never
    /// repaints would stay blank with no status row.
    @Test func recover_notifiesCardToRearmPaintWatchdog() {
        let coordinator = GraphThumbnailCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView
        coordinator.sendInitGraph("{\"nodes\":[]}", webView: webView)
        coordinator.receiveBridgeEvent("ready")
        coordinator.receiveBridgeEvent("painted")

        var expectations = 0
        coordinator.onRepaintExpected = { expectations += 1 }

        coordinator.recover()
        #expect(expectations == 1)
    }

    /// Retry reloads a stuck page: one that never reported `ready`, or one that
    /// reported `ready` but whose first paint timed out (#2860). Inside the
    /// watchdog window a ready page is slow, not stuck, so Retry must not restart
    /// its render. Before the fix a timed-out ready page was never reloaded, so
    /// Retry re-armed the watchdog and the same blank page timed out again.
    @Test func retryRebuild_stuckOrPaintTimedOutOnly() {
        let coordinator = GraphThumbnailCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView
        coordinator.sendInitGraph("{\"nodes\":[]}", webView: webView)

        #expect(coordinator.needsRebuildOnRetry(paintTimedOut: false), "a page that never reported ready is stuck and must be rebuilt")

        coordinator.receiveBridgeEvent("ready")
        #expect(!coordinator.needsRebuildOnRetry(paintTimedOut: false), "a ready page inside the watchdog window is slow; retry must not restart its render")
        #expect(coordinator.needsRebuildOnRetry(paintTimedOut: true), "a ready page whose first paint timed out must be reloaded, or Retry leaves it blank")

        coordinator.receiveBridgeEvent("painted")
        #expect(!coordinator.needsRebuildOnRetry(paintTimedOut: true), "a painted page never needs a rebuild")
    }

    @Test func coordinatorRecover_beforePaintKeepsBridgeReplayable() {
        let coordinator = GraphThumbnailCoordinator()

        coordinator.recover()

        #expect(!coordinator.graphBridgeReady)
        #expect(!coordinator.hasPainted)
        #expect(coordinator.pendingPayload == nil)
        #expect(coordinator.lastPayload == nil)
    }

    /// The card's watchdog wiring must route paint and repaint events into its
    /// `@State` bindings, so a painted graph clears the status row and a rebuilt
    /// page re-arms the watchdog.
    @Test func paintWatchdogBinding_routesPaintAndRepaintIntoCardState() {
        let sink = PaintWatchdogSink()
        let coordinator = GraphThumbnailCoordinator()
        coordinator.bindPaintWatchdog(timedOut: sink.timedOutBinding, generation: sink.generationBinding)

        sink.timedOut = true
        coordinator.receiveBridgeEvent("painted")
        #expect(!sink.timedOut, "a paint must clear the timed-out state")

        coordinator.recover()
        #expect(sink.generation == 1, "a repaint expectation must re-arm the watchdog")
        #expect(!sink.timedOut)
    }

    /// Regression for the card retain cycle (#2860): binding the card must not
    /// keep its holder, and so its web view and WebContent process, alive after
    /// the owner releases them. Holder deinit removes the script message handler.
    @Test func paintWatchdogBinding_doesNotRetainHolder() {
        let probe = holderWithPaintWatchdogBoundThenDropped()
        #expect(probe.holder == nil, "binding the card must not close a retain cycle through the holder")
    }

    @MainActor
    private final class PaintWatchdogSink {
        var timedOut = false
        var generation = 0

        var timedOutBinding: Binding<Bool> {
            Binding(get: { self.timedOut }, set: { self.timedOut = $0 })
        }

        var generationBinding: Binding<Int> {
            Binding(get: { self.generation }, set: { self.generation = $0 })
        }
    }

    private final class WeakHolderProbe {
        weak var holder: GraphThumbnailHolder?
    }

    /// Returns a weak probe after every strong reference to the holder is gone
    /// (the function frame holds the only one until it returns).
    private func holderWithPaintWatchdogBoundThenDropped() -> WeakHolderProbe {
        let sink = PaintWatchdogSink()
        let holder = GraphThumbnailHolder()
        holder.coordinator.bindPaintWatchdog(timedOut: sink.timedOutBinding, generation: sink.generationBinding)
        let probe = WeakHolderProbe()
        probe.holder = holder
        return probe
    }
}
#endif
