#if os(iOS)
import Foundation
@preconcurrency import WebKit
import os

extension ReadiumNavigatorView.Coordinator: WKScriptMessageHandler {
    func findWebView(in view: UIView?) -> WKWebView? {
        guard let view else { return nil }
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WKScriptMessage.body / .name are only valid during this synchronous
        // delegate callback. Capture them now before hopping to the MainActor;
        // reading them inside the Task would be a use-after-scope.
        let (name, body, isAccepted) = MainActor.assumeIsolated {
            (
                message.name,
                message.body,
                ReaderBridgeContentWorld.accepts(
                    isMainFrame: message.frameInfo.isMainFrame,
                    world: message.world
                )
            )
        }
        guard isAccepted else {
            AppLog.reader.debug("Ignored bridge message from outside the main frame / bridge world")
            return
        }
        Task { @MainActor in
            switch name {
            case "selectionState":
                self.handleSelectionStateMessage(body)
            case "markingProgress":
                self.handleMarkingProgressMessage(body)
            case "wordDeselect":
                AppLog.reader.debug("Word deselected (toggle off)")
                self.parent.onWordDeselected()
            case "wordTap":
                self.handleWordTapMessage(body)
            default:
                return
            }
        }
    }

    private func handleSelectionStateMessage(_ body: Any) {
        guard let isActive = body as? String,
              let webView = findWebView(in: navigator?.view) else { return }

        let scrollView = webView.scrollView
        if isActive == "active" {
            lockSelection(on: scrollView)
        } else {
            releaseSelectionLock(on: scrollView)
        }
        AppLog.reader.debug("Selection state: \(isActive)")
    }

    private func decodeJSONDictionary<Value>(from body: Any, valueType: Value.Type) -> [String: Value]? {
        guard let body = body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Value] else { return nil }
        return json
    }

    private func handleMarkingProgressMessage(_ body: Any) {
        guard let json = decodeJSONDictionary(from: body, valueType: Int.self),
              let done = json["done"],
              let total = json["total"],
              total > 0 else {
            AppLog.reader.debug("Ignored malformed markingProgress message from JS")
            return
        }

        let progress = Double(done) / Double(total)
        parent.onMarkingProgress?(progress)
    }

    private func handleWordTapMessage(_ body: Any) {
        guard let json = decodeJSONDictionary(from: body, valueType: String.self),
              let word = json["word"],
              let context = json["context"] else {
            AppLog.reader.debug("Ignored malformed wordTap message from JS")
            return
        }

        AppLog.reader.debug("Word from JS: \(word)")
        parent.onWordSelected(word, context)
    }

    private func lockSelection(on scrollView: UIScrollView) {
        let pageWidth = scrollView.bounds.width
        let anchorX: CGFloat
        if pageWidth > 0 {
            let page = (scrollView.contentOffset.x / pageWidth).rounded()
            anchorX = page * pageWidth
        } else {
            anchorX = scrollView.contentOffset.x
        }

        let anchor = CGPoint(x: anchorX, y: scrollView.contentOffset.y)
        selectionPageAnchor = anchor
        contentOffsetObserver = scrollView.observe(\.contentOffset, options: [.new]) { scrollView, _ in
            if abs(scrollView.contentOffset.x - anchor.x) > 1 {
                scrollView.contentOffset = anchor
            }
        }
    }

    private func releaseSelectionLock(on scrollView: UIScrollView) {
        contentOffsetObserver = nil
        selectionPageAnchor = nil

        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }

        let page = (scrollView.contentOffset.x / pageWidth).rounded()
        let snapX = page * pageWidth
        if abs(scrollView.contentOffset.x - snapX) > 1 {
            scrollView.setContentOffset(CGPoint(x: snapX, y: scrollView.contentOffset.y), animated: true)
        }
    }
}
#endif
