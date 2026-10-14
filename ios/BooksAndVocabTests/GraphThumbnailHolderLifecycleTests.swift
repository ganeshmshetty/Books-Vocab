#if DEBUG
import Foundation
import Testing
@testable import BooksAndVocab

/// Pins the lazy contract of `GraphThumbnailHolder` (#3819).
///
/// `StatsPresenter` declares `@State private var graphHolder = GraphThumbnailHolder()`.
/// SwiftUI evaluates a `@State` default on every presenter init, so an eager
/// WKWebView in the holder init created and discarded one web view (plus a
/// graph.html load) per re-evaluation of `OverviewTab.body`.
@MainActor
struct GraphThumbnailHolderLifecycleTests {
    @Test("constructing StatsPresenter creates no WKWebView")
    func presenterInitCreatesNoWebView() {
        let before = GraphThumbnailHolder.webViewCreationCount
        for _ in 0..<5 {
            _ = StatsPresenter(filter: NotebookFilter(), reviewClock: nil)
        }
        #expect(GraphThumbnailHolder.webViewCreationCount == before)
    }

    @Test("holder builds its WKWebView once, on first access, and reuses it")
    func holderBuildsWebViewOnceOnFirstAccess() {
        let before = GraphThumbnailHolder.webViewCreationCount
        let holder = GraphThumbnailHolder()
        #expect(GraphThumbnailHolder.webViewCreationCount == before)

        let first = holder.webView
        let second = holder.webView
        #expect(first === second)
        #expect(GraphThumbnailHolder.webViewCreationCount == before + 1)
    }
}
#endif
