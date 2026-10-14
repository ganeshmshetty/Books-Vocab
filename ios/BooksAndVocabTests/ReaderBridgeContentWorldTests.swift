//
//  ReaderBridgeContentWorldTests.swift
//  Books & Vocab Tests
//
//  Spec: the reader bridge (message handlers + injected user script) lives in a
//  dedicated WKContentWorld, never `.page`, and only main-frame messages from
//  that world are accepted. Configuration-level tests; no web view is started.
//

#if os(iOS)
import Foundation
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

    @Test func installInjectsTheScriptIntoTheBridgeWorldForTheMainFrameOnly() {
        let registrar = RecordingRegistrar()
        ReaderBridgeContentWorld.install(on: registrar, handler: NoopHandler(), scriptSource: "/* bridge */")

        #expect(registrar.scripts.count == 1)
        #expect(registrar.scripts.first?.source == "/* bridge */")
        #expect(registrar.scripts.first?.world == ReaderBridgeContentWorld.world)
        #expect(registrar.scripts.first?.mainFrameOnly == true)
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

    @Test func onlyMainFrameMessagesFromTheBridgeWorldAreAccepted() {
        let world = ReaderBridgeContentWorld.world
        #expect(ReaderBridgeContentWorld.accepts(isMainFrame: true, world: world))
        #expect(!ReaderBridgeContentWorld.accepts(isMainFrame: false, world: world))
        #expect(!ReaderBridgeContentWorld.accepts(isMainFrame: true, world: .page))
        #expect(!ReaderBridgeContentWorld.accepts(isMainFrame: false, world: .page))
    }
}
#endif
