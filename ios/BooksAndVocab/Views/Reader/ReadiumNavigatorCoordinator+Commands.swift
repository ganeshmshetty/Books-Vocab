#if os(iOS)
import Foundation
import ReadiumNavigator
import ReadiumShared

enum BridgeCommand {
    case host(HostCommand)
    case navigator(NavigatorCommand)
    case dom(DOMCommand)
}

enum HostCommand {
    case setInteractionBlocked(Bool)
}

enum NavigatorCommand {
    case navigate(Locator, requestID: UUID)
    case applyPreferences(EPUBPreferences)
}

enum DOMCommand {
    case clearActiveHighlight
    case clearAllVocabHighlights
    case markVocabWords([String])
    case markNewVocabWord(String)
    case removeVocabWord(String)
    case setContentStyle(String)
    case setUnderlineOpacity(Double)
    case setDebugMode(Bool)
}

@MainActor
final class ReadiumNavigatorDriver: ReaderNavigatorDriving {
    weak var navigator: EPUBNavigatorViewController?

    init(navigator: EPUBNavigatorViewController?) {
        self.navigator = navigator
    }

    func go(to locator: Locator) async -> Bool? {
        guard let navigator else { return nil }
        return await navigator.go(to: locator)
    }
}

extension ReadiumNavigatorView.Coordinator {
    func sync(
        with snapshot: ReadiumNavigatorView.BridgeSnapshot,
        in host: NavigatorHostViewController
    ) {
        apply(planner.makeCommands(from: snapshot), in: host)
    }

    func apply(_ commands: [BridgeCommand], in host: NavigatorHostViewController) {
        for command in commands {
            switch command {
            case .host(let hostCommand):
                apply(hostCommand, in: host)
            case .navigator(let navigatorCommand):
                apply(navigatorCommand, in: host)
            case .dom(let domCommand):
                apply(domCommand)
            }
        }
    }

    func apply(_ command: HostCommand, in host: NavigatorHostViewController) {
        switch command {
        case .setInteractionBlocked(let isBlocked):
            if let blocker = host.view.viewWithTag(9001) {
                blocker.isUserInteractionEnabled = isBlocked
            }
        }
    }

    func apply(_ command: NavigatorCommand, in host: NavigatorHostViewController) {
        switch command {
        case .navigate(let locator, let requestID):
            activeTOCNavigationTask?.cancel()
            activeTOCTimeoutTask?.cancel()
            activeTOCTimeoutTask = nil
            tocNavigationGate.begin(requestID, expectedLocatorHref: locator.href.string)
            let bridge = ReaderTOCNavigationBridge(
                navigator: ReadiumNavigatorDriver(navigator: navigator),
                timeoutNanoseconds: ReaderMetrics.tocNavigationTimeoutNanoseconds
            )
            activeTOCNavigationTask = Task { @MainActor [weak self] in
                AppLog.reader.debug("Attempting navigation to: \(String(describing: locator.href))")
                let event = await bridge.navigate(requestID: requestID, locator: locator)
                guard let self else { return }
                guard self.tocNavigationGate.isCurrent(requestID) else { return }
                if case .goAccepted = event {
                    // go() only acknowledges dispatch. Keep the request token
                    // alive until the navigator delegate reports the actual
                    // locator, with a bounded callback deadline.
                    self.activeTOCNavigationTask = nil
                    beginTOCTimeout(for: requestID)
                } else {
                    guard self.tocNavigationGate.finish(requestID) else { return }
                    self.activeTOCNavigationTask = nil
                }
                AppLog.reader.debug("Navigation result: \(String(describing: event))")
                parent.onTOCNavigationEvent(event)
            }
        case .applyPreferences(let preferences):
            let generation = preferencesApplyState.begin()
            preferencesApplyTask?.cancel()
            let navigatorGeneration = navigatorLifecycleGate.generation
            preferencesApplyTask = Task { @MainActor [weak self, weak host] in
                guard let self else { return }
                guard
                    let navigator = host?.epubNavigator,
                    !Task.isCancelled,
                    self.preferencesApplyState.pendingGeneration == generation,
                    self.acceptsNavigator(navigator, generation: navigatorGeneration)
                else {
                    self.preferencesApplyState.cancel(generation)
                    return
                }
                self.hasPublishedNavigatorSettingsReceipt = false
                self.parent.onNavigatorSettingsReceipt(.pending(navigatorID: self.navigatorID))
                guard
                    !Task.isCancelled,
                    self.preferencesApplyState.pendingGeneration == generation,
                    self.acceptsNavigator(navigator, generation: navigatorGeneration)
                else {
                    self.preferencesApplyState.cancel(generation)
                    return
                }
                navigator.submitPreferences(preferences)
            }
        }
    }

    func apply(_ command: DOMCommand) {
        domExecutor.execute(
            command,
            navigator: navigator,
            clearActiveHighlight: { [weak self] in self?.clearActiveHighlight() },
            clearAllVocabHighlights: { [weak self] in self?.clearAllVocabHighlights() },
            markVocabWords: { [weak self] words in self?.markVocabWords(words) },
            markNewVocabWord: { [weak self] word in self?.markNewVocabWord(word) },
            removeVocabWord: { [weak self] word in self?.removeVocabWord(word) }
        )
    }
}
#endif
