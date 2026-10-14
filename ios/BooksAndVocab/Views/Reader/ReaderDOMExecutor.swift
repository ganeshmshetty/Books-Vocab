#if os(iOS)
import Foundation
import ReadiumNavigator

struct ReaderDOMExecutor {
    func execute(
        _ command: DOMCommand,
        navigator: EPUBNavigatorViewController?,
        clearActiveHighlight: @escaping () -> Void,
        clearAllVocabHighlights: @escaping () -> Void,
        markVocabWords: @escaping ([String]) -> Void,
        markNewVocabWord: @escaping (String) -> Void,
        removeVocabWord: @escaping (String) -> Void
    ) {
        switch command {
        case .clearActiveHighlight:
            clearActiveHighlight()
        case .clearAllVocabHighlights:
            clearAllVocabHighlights()
        case .markVocabWords(let words):
            markVocabWords(words)
        case .markNewVocabWord(let word):
            markNewVocabWord(word)
        case .removeVocabWord(let word):
            removeVocabWord(word)
        case .setUnderlineOpacity(let opacity):
            evaluateJavaScript(
                "document.documentElement.style.setProperty('--vocab-opacity', '\(opacity)');",
                "setUnderlineOpacity",
                navigator: navigator
            )
        case .setContentStyle(let css):
            let cssLiteral = ReaderJSEval.quotedLiteral(css)
            evaluateJavaScript(
                "if(window.__applyReaderContentStyle) window.__applyReaderContentStyle(\(cssLiteral));",
                "setContentStyle",
                navigator: navigator
            )
        case .setDebugMode(let isEnabled):
            guard ReaderDebugTools.isAvailable else { return }
            evaluateJavaScript(
                "if(window.__toggleDebugBoxes) window.__toggleDebugBoxes(\(isEnabled ? "true" : "false"));",
                "setDebugMode",
                navigator: navigator
            )
        }
    }

    private func evaluateJavaScript(
        _ script: String,
        _ label: StaticString,
        navigator: EPUBNavigatorViewController?
    ) {
        Task { @MainActor in
            guard let navigator else { return }
            ReaderJSEval.log(await navigator.evaluateBridgeScript(script), label)
        }
    }
}
#endif
