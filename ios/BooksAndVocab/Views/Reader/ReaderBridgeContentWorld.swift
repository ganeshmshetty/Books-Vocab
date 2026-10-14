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

    /// 橋接注入每個 frame（FXL 書文在 wrapper 的子 iframe 裡，見 `ReaderBridgeEvalScript`）。
    /// 接受與否只看 world：`.page` 的 script 碰不到這個 world，frame 本身不是邊界。
    static func accepts(world messageWorld: WKContentWorld) -> Bool {
        messageWorld == world
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
        controller.injectBridgeScript(source: scriptSource, forMainFrameOnly: false, in: world)
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

/// 橋接 script 的求值位置。reflowable 的書文在 wrapper 本身（主 frame）；FXL 的每一頁是 Readium
/// wrapper 裡的 iframe（`page`，雙頁為 `page-left`／`page-right`／`page-center`），書文與
/// `window.__markVocabWords` 等橋接函式都在那些 iframe 的 window 裡。
enum ReaderBridgeEvalScript {
    /// Readium FXL wrapper 的頁面 iframe id 慣例。
    static let pageFrameSelector = "iframe[id^=page]"

    /// `callAsyncJavaScript` 的 function body，於橋接 world 的主 frame 執行。script 以 `arguments` 的 `script` 傳入、不做字串插值。
    ///
    /// 選目標與求值在同一次呼叫完成：DOM 在各 world 間共用，所以這裡查得到頁面 iframe。
    /// 不能另用 Readium 的 `evaluateJavaScript` 探測頁面數：那段 script 會經 `spread.eval` 跑進 book iframe，
    /// 查不到 wrapper 的 iframe 而永遠選到主 frame。
    static let callBody = """
    const pageFrames = document.querySelectorAll('\(pageFrameSelector)');
    if (pageFrames.length === 0) return eval(script);
    let result;
    for (const frame of pageFrames) {
      // 與 Readium `FixedPage.eval` 相同：尚未載入資源（about:blank）的頁面略過。
      if (!frame.src || frame.src === 'about:blank' || !frame.contentWindow) continue;
      result = frame.contentWindow.eval(script);
    }
    return result;
    """
}

extension EPUBNavigatorViewController {
    /// 在橋接 world 求值（`window.__markVocabWords` 等函式只存在那裡）。
    ///
    /// Readium 的 `evaluateJavaScript` 只會在 `.page` world 執行，所以這裡只借它當「目前 spread 已載入完成」的
    /// 等待點（失敗為 `.spreadNotLoaded`，`ReaderJSEval.classify` 語意不變）；求值本身在可見 web view 的橋接 world 內一次完成。
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
                ReaderBridgeEvalScript.callBody,
                arguments: ["script": script],
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
