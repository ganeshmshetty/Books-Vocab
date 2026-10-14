#if os(iOS)
import Foundation
import UIKit
import ReadiumNavigator
import os

extension ReadiumNavigatorView.Coordinator {
    @objc func handleBlockerTap(_ gesture: UITapGestureRecognizer) {
        AppLog.reader.debug("Blocker tapped, clearing selection...")
        Task { @MainActor in
            self.parent.onWordDeselected()
        }
    }

    func markVocabWords(_ words: [String]) {
        vocabMarks.schedule(words)
    }

    @MainActor
    func emitMarkVocabWordsJS(_ words: [String]) {
        guard let navigator = self.navigator else { return }

        let js = ReaderJSEval.markVocabWordsScript(words)

        Task { ReaderJSEval.log(await navigator.evaluateBridgeScript(js), "markVocabWords") }
        PerfLog.reader.mark("markVocabWords", "\(words.count)")
        AppLog.reader.debug("Marked \(words.count) vocab words")
    }

    private func invokeSingleWordBridge(_ word: String, jsFunction: String, label: StaticString, logMessage: String) {
        guard let navigator else { return }
        let js = ReaderJSEval.singleWordScript(function: jsFunction, word: word)
        Task { @MainActor in
            ReaderJSEval.log(await navigator.evaluateBridgeScript(js), label)
            AppLog.reader.debug("\(logMessage)")
        }
    }

    func markNewVocabWord(_ word: String) {
        invokeSingleWordBridge(word, jsFunction: "__markVocabWord", label: "markNewVocabWord", logMessage: "Marked new vocab: \(word)")
    }

    func clearAllVocabHighlights() {
        vocabMarks.discardAll()
        guard let navigator else { return }
        let js = """
        document.querySelectorAll('.vocab-word').forEach(function(el) {
            el.classList.remove('vocab-word', 'active-word');
            var parent = el.parentNode;
            if (parent) {
                while (el.firstChild) parent.insertBefore(el.firstChild, el);
                parent.removeChild(el);
                parent.normalize();
            }
        });
        """
        Task { @MainActor in
            ReaderJSEval.log(await navigator.evaluateBridgeScript(js), "clearAllVocabHighlights")
            AppLog.reader.debug("Cleared all vocab highlights")
        }
    }

    func removeVocabWord(_ word: String) {
        vocabMarks.discard(word: word)
        invokeSingleWordBridge(word, jsFunction: "__removeVocabWord", label: "removeVocabWord", logMessage: "Removed vocab underline: \(word)")
    }

    func clearActiveHighlight() {
        guard let navigator else { return }
        let js = """
        document.querySelectorAll('.active-word').forEach(function(el) {
            if (el.classList.contains('vocab-word')) {
                el.classList.remove('active-word');
                return;
            }
            var parent = el.parentNode;
            while (el.firstChild) parent.insertBefore(el.firstChild, el);
            parent.removeChild(el);
            parent.normalize();
        });
        """
        Task { @MainActor in
            ReaderJSEval.log(await navigator.evaluateBridgeScript(js), "clearActiveHighlight")
            navigator.clearSelection()
        }
    }
}
#endif
