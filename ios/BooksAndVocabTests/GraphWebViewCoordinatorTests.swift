#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

/// Pins the full-screen graph bridge state machine (#3817).
///
/// The page loses its JS state when WebKit terminates the WebContent process, and it
/// posts `ready` again after the reload. The coordinator must replay the last payload
/// and the latest forces on every `ready`, and must not send `updateForces` before the
/// page is ready. A unit test has no live WKWebView, so scripts go through the
/// `evaluatedScripts` seam.
@MainActor
struct GraphWebViewCoordinatorTests {
    private final class ScriptLog {
        var scripts: [String] = []
    }

    private func makeCoordinator() -> (GraphWebView.Coordinator, ScriptLog) {
        let coordinator = GraphWebView.Coordinator(onNodeTap: { _ in })
        let log = ScriptLog()
        coordinator.evaluatedScripts = { log.scripts.append($0) }
        return (coordinator, log)
    }

    private func forces(repel: Double) -> GraphForces {
        GraphForces(
            repel: repel, linkDistance: 12, linkStrength: 1.8,
            centerStrength: 0.2, baseNodeRadius: 4, collideRadius: 0, linkThickness: 0.8
        )
    }

    @Test("sendInitGraph before ready is deferred, and ready evaluates initGraph once")
    func initGraphIsEvaluatedOnceOnReady() {
        let (coordinator, log) = makeCoordinator()

        coordinator.sendInitGraph("P1")
        #expect(log.scripts.isEmpty)

        coordinator.handleBridgeReady()
        #expect(log.scripts == ["initGraph('P1')"])
    }

    @Test("a second ready without new data replays the same payload")
    func secondReadyReplaysLastPayload() {
        let (coordinator, log) = makeCoordinator()
        coordinator.sendInitGraph("P1")
        coordinator.handleBridgeReady()

        coordinator.handleBridgeReady()

        #expect(log.scripts == ["initGraph('P1')", "initGraph('P1')"])
    }

    @Test("forces changed before ready are not evaluated, and ready replays the latest forces")
    func forcesBeforeReadyReplayOnReady() {
        let (coordinator, log) = makeCoordinator()
        coordinator.sendInitGraph("P1")
        coordinator.sendForces(forces(repel: 12))
        let latest = forces(repel: 30)
        coordinator.sendForces(latest)
        #expect(log.scripts.isEmpty)

        coordinator.handleBridgeReady()

        #expect(log.scripts == [
            "initGraph('P1')",
            "updateForces(\(latest.toJSONString()))",
        ])
    }

    @Test("content process termination clears ready, and the next ready replays lastPayload")
    func terminationThenReadyReplaysPayload() {
        let (coordinator, log) = makeCoordinator()
        coordinator.sendInitGraph("P1")
        coordinator.handleBridgeReady()
        log.scripts.removeAll()

        coordinator.handleContentProcessTerminated()
        #expect(coordinator.graphBridgeReady == false)

        coordinator.handleBridgeReady()
        #expect(log.scripts == ["initGraph('P1')"])
    }
}
#endif
