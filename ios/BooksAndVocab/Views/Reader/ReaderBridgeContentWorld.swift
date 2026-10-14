#if os(iOS)
import Foundation
@preconcurrency import WebKit
import ReadiumNavigator

/// App 端閱讀橋接（選字、生字標記、進度）專用的 `WKContentWorld`。
///
/// 橋接 script 與 message handler 都只存在這個隔離 world；出版品自己的 script
/// 跑在 `.page`，看不到 `window.webkit.messageHandlers` 的這些項目，也讀不到
/// `window.__markVocabWords` 等橋接函式。DOM 與 event 在各 world 之間共用，
/// 所以橋接仍可讀取選取範圍與點擊目標。
///
/// app 對橋接函式的所有求值都必須走同一個 world（見
/// `EPUBNavigatorViewController.evaluateBridgeScript`）。
enum ReaderBridgeContentWorld {
    static let name = "kg-reader-bridge"
    static let world = WKContentWorld.world(name: name)
    static let handlerNames = ["wordTap", "wordDeselect", "selectionState", "markingProgress"]

    /// 橋接只在主 frame 注入，且只接受主 frame、橋接 world 送出的訊息。
    static let injectsIntoMainFrameOnly = true

    static func accepts(isMainFrame: Bool, world messageWorld: WKContentWorld) -> Bool {
        isMainFrame && messageWorld == world
    }

    @MainActor
    static func install(
        on controller: some ReaderBridgeUserContentRegistering,
        handler: WKScriptMessageHandler,
        scriptSource: String
    ) {
        for name in handlerNames {
            controller.registerBridgeHandler(handler, name: name, in: world)
        }
        controller.injectBridgeScript(
            source: scriptSource,
            forMainFrameOnly: injectsIntoMainFrameOnly,
            in: world
        )
    }

    @MainActor
    static func uninstall(from controller: some ReaderBridgeUserContentRegistering) {
        for name in handlerNames {
            controller.unregisterBridgeHandler(name: name, in: world)
        }
    }

    /// 導覽區裡實際可見的 spread web view（與可視區重疊面積最大者）。
    @MainActor
    static func visibleWebView(in root: UIView?) -> WKWebView? {
        guard let root else { return nil }
        var best: (view: WKWebView, area: CGFloat)?
        var stack: [UIView] = [root]
        while let current = stack.popLast() {
            if let webView = current as? WKWebView {
                let visible = webView.convert(webView.bounds, to: root).intersection(root.bounds)
                let area = visible.isNull ? 0 : visible.width * visible.height
                if best == nil || area > best!.area { best = (webView, area) }
                continue
            }
            stack.append(contentsOf: current.subviews)
        }
        return best?.view
    }
}

/// `WKUserContentController` 的最小註冊面，讓 world 設定可以不啟動 web view 就被測試。
@MainActor
protocol ReaderBridgeUserContentRegistering {
    func registerBridgeHandler(_ handler: WKScriptMessageHandler, name: String, in world: WKContentWorld)
    func unregisterBridgeHandler(name: String, in world: WKContentWorld)
    func injectBridgeScript(source: String, forMainFrameOnly: Bool, in world: WKContentWorld)
}

extension WKUserContentController: ReaderBridgeUserContentRegistering {
    func registerBridgeHandler(_ handler: WKScriptMessageHandler, name: String, in world: WKContentWorld) {
        add(handler, contentWorld: world, name: name)
    }

    func unregisterBridgeHandler(name: String, in world: WKContentWorld) {
        removeScriptMessageHandler(forName: name, contentWorld: world)
    }

    func injectBridgeScript(source: String, forMainFrameOnly: Bool, in world: WKContentWorld) {
        addUserScript(
            WKUserScript(
                source: source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: forMainFrameOnly,
                in: world
            )
        )
    }
}

enum ReaderBridgeEvalError: Error {
    case webViewUnavailable
}

extension EPUBNavigatorViewController {
    /// 在橋接 world 求值（`window.__markVocabWords` 等函式只存在那裡）。
    ///
    /// Readium 的 `evaluateJavaScript` 只會在 `.page` world 執行，所以這裡先用它
    /// 當「目前 spread 已載入完成」的等待點（結果與 `.spreadNotLoaded` 語意不變），
    /// 再把真正的 script 送進可見 web view 的橋接 world。
    @MainActor
    func evaluateBridgeScript(_ script: String) async -> Result<Any, Error> {
        if case .failure(let error) = await evaluateJavaScript("void 0;") {
            return .failure(error)
        }
        guard let webView = ReaderBridgeContentWorld.visibleWebView(in: view) else {
            return .failure(ReaderBridgeEvalError.webViewUnavailable)
        }
        do {
            let value = try await webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                contentWorld: ReaderBridgeContentWorld.world
            )
            return .success(value ?? ())
        } catch {
            return .failure(error)
        }
    }
}
#endif
