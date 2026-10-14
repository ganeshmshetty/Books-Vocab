//
//  ReaderBridgeContentWorldTests.swift
//  Books & Vocab Tests
//
//  Spec: the reader bridge (message handlers + injected user script) lives in a
//  dedicated WKContentWorld, never `.page`. Its script runs in every frame of
//  that world (FXL pages are iframes) and only messages from that world are
//  accepted. Configuration-level tests; no web view is started. The eval body is
//  run as real JavaScript in JavaScriptCore against a mocked DOM.
//

#if os(iOS)
import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import BooksAndVocab

@MainActor
struct ReaderBridgeContentWorldTests {

    private final class RecordingRegistrar: ReaderBridgeUserContentRegistering {
        var handlers: [(name: String, world: WKContentWorld)] = []
        var removed: [(name: String, world: WKContentWorld)] = []
        var scripts: [(source: String, mainFrameOnly: Bool, world: WKContentWorld)] = []

        func registerBridgeHandler(_ handler: WKScriptMessageHandler, name: String, in world: WKContentWorld) {
            handlers.append((name, world))
        }

        func unregisterBridgeHandler(name: String, in world: WKContentWorld) {
            removed.append((name, world))
        }

        func injectBridgeScript(source: String, forMainFrameOnly: Bool, in world: WKContentWorld) {
            scripts.append((source, forMainFrameOnly, world))
        }
    }

    private final class NoopHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    @Test func bridgeWorldIsNamedAndNotThePageWorld() {
        #expect(ReaderBridgeContentWorld.name == "kg-reader-bridge")
        #expect(ReaderBridgeContentWorld.world.name == "kg-reader-bridge")
        #expect(ReaderBridgeContentWorld.world != WKContentWorld.page)
        #expect(ReaderBridgeContentWorld.world != WKContentWorld.defaultClient)
    }

    @Test func installRegistersEveryHandlerInTheBridgeWorld() {
        let registrar = RecordingRegistrar()
        ReaderBridgeContentWorld.install(on: registrar, handler: NoopHandler(), scriptSource: "/* bridge */")

        #expect(registrar.handlers.map(\.name) == ["wordTap", "wordDeselect", "selectionState", "markingProgress"])
        #expect(registrar.handlers.allSatisfy { $0.world == ReaderBridgeContentWorld.world })
        #expect(registrar.handlers.allSatisfy { $0.world != WKContentWorld.page })
    }

    @Test func installInjectsTheScriptIntoTheBridgeWorldForEveryFrame() {
        let registrar = RecordingRegistrar()
        ReaderBridgeContentWorld.install(on: registrar, handler: NoopHandler(), scriptSource: "/* bridge */")

        #expect(registrar.scripts.count == 1)
        #expect(registrar.scripts.first?.source == "/* bridge */")
        #expect(registrar.scripts.first?.world == ReaderBridgeContentWorld.world)
        // FXL 書文在 wrapper 的子 iframe 裡；只注入主 frame 會讓那些頁面收不到橋接。
        #expect(registrar.scripts.first?.mainFrameOnly == false)
    }

    @Test func uninstallRemovesHandlersFromTheSameWorld() {
        let registrar = RecordingRegistrar()
        ReaderBridgeContentWorld.uninstall(from: registrar)

        #expect(registrar.removed.map(\.name) == ReaderBridgeContentWorld.handlerNames)
        #expect(registrar.removed.allSatisfy { $0.world == ReaderBridgeContentWorld.world })
    }

    @Test func realControllerAcceptsInstallAndUninstall() {
        let controller = WKUserContentController()
        ReaderBridgeContentWorld.install(on: controller, handler: NoopHandler(), scriptSource: "/* bridge */")
        #expect(controller.userScripts.count == 1)
        ReaderBridgeContentWorld.uninstall(from: controller)
    }

    @Test func messagesFromTheBridgeWorldAreAcceptedFromAnyFrameAndPageWorldIsRejected() {
        let world = ReaderBridgeContentWorld.world
        #expect(ReaderBridgeContentWorld.accepts(world: world))
        #expect(!ReaderBridgeContentWorld.accepts(world: .page))
        #expect(!ReaderBridgeContentWorld.accepts(world: .defaultClient))
    }

    /// 以 JavaScriptCore 執行 `ReaderBridgeEvalScript.callBody`，DOM 以 mock 模擬（不啟動 web view）。
    /// `frames` 為 (iframe src, 標籤)；空陣列代表 reflowable（沒有頁面 iframe）。回傳「查詢與求值紀錄 => 回傳值」。
    private func runCallBody(frames: [(src: String, tag: String)]) -> String? {
        let frameLiterals = frames.map { frame in
            "{ src: '\(frame.src)', contentWindow: { eval: function (s) { log.push('\(frame.tag):' + s); return '\(frame.tag)'; } } }"
        }.joined(separator: ", ")
        let harness = """
        var log = [];
        var tap = function () { log.push('main:tap'); return 'main'; };
        var pageFrames = [\(frameLiterals)];
        var document = {
          querySelectorAll: function (selector) {
            log.push('query:' + selector);
            return selector === '\(ReaderBridgeEvalScript.pageFrameSelector)' ? pageFrames : [];
          }
        };
        var returned = (function (script) {
        \(ReaderBridgeEvalScript.callBody)
        })('tap()');
        log.join('|') + ' => ' + String(returned);
        """
        let context: JSContext? = JSContext()
        return context?.evaluateScript(harness)?.toString()
    }

    @Test func fixedLayoutBridgeEvalRunsInEveryLoadedPageFrameFromTheBridgeWorld() {
        #expect(
            runCallBody(frames: [("https://book/p1.xhtml", "left"), ("https://book/p2.xhtml", "right")])
                == "query:iframe[id^=page]|left:tap()|right:tap() => right"
        )
    }

    @Test func fixedLayoutBridgeEvalSkipsEmptyPagesAndStillReachesTheLoadedOne() {
        #expect(
            runCallBody(frames: [("about:blank", "left"), ("https://book/p2.xhtml", "right")])
                == "query:iframe[id^=page]|right:tap() => right"
        )
    }

    @Test func reflowableBridgeEvalRunsInTheMainFrameWhenThereAreNoPageFrames() {
        #expect(runCallBody(frames: []) == "query:iframe[id^=page]|main:tap => main")
    }
}
#endif
