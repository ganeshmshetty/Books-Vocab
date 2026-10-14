#if os(iOS)
import Foundation
import UIKit
import ReadiumShared
import ReadiumNavigator
import os

/// Globally debounces high-frequency navigator operations across instances.
actor GlobalDebouncer {
    static let shared = GlobalDebouncer()

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func debounce(key: String, duration: TimeInterval, action: @escaping @Sendable () async -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await action()
            tasks[key] = nil
        }
    }
}

/// Words awaiting the debounced `markVocabWords` JS emit. Kept outside the
/// debouncer closure so removal / clear-all can synchronously drop entries
/// during the debounce window (#2437) instead of racing a stale captured list.
final class PendingVocabMarks: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [String] = []

    func enqueue(_ new: [String]) {
        lock.lock(); defer { lock.unlock() }
        for word in new where !words.contains(word) { words.append(word) }
    }

    func discard(word: String) {
        lock.lock(); defer { lock.unlock() }
        let target = word.lowercased()
        words.removeAll { $0.lowercased() == target }
    }

    func discardAll() {
        lock.lock(); defer { lock.unlock() }
        words.removeAll()
    }

    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        defer { words.removeAll() }
        return words
    }
}

/// Per-coordinator debounce + pending store for `markVocabWords`. Owning the
/// pending list here (not a singleton) means it dies with its coordinator, and
/// drain + emit run together on the main actor so main-thread removals cannot
/// interleave between them (#2437).
final class VocabMarkScheduler: @unchecked Sendable {
    private let pending = PendingVocabMarks()
    private let duration: TimeInterval
    private let key = "markVocabWords-\(UUID().uuidString)"
    private let emit: @MainActor @Sendable ([String]) -> Void

    init(duration: TimeInterval, emit: @escaping @MainActor @Sendable ([String]) -> Void) {
        self.duration = duration
        self.emit = emit
    }

    func schedule(_ words: [String]) {
        guard !words.isEmpty else { return }
        pending.enqueue(words)
        let key = key, duration = duration
        Task {
            await GlobalDebouncer.shared.debounce(key: key, duration: duration) { [weak self] in
                await MainActor.run {
                    guard let self else { return }
                    let words = self.pending.drain()
                    guard !words.isEmpty else { return }
                    self.emit(words)
                }
            }
        }
    }

    func discard(word: String) { pending.discard(word: word) }
    func discardAll() { pending.discardAll() }
}

final class NavigatorHostViewController: UIViewController {
    var onWordSelected: ((String, String) -> Void)?
    var onPhraseSelected: ((String, String) -> Void)?
    var onExplainSelected: ((String, String) -> Void)?
    weak var epubNavigator: EPUBNavigatorViewController?
    private var hasAppeared = false
    var onFirstAppearance: (() -> Void)? {
        didSet { invokeAppearanceCallbackIfReady() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        invokeAppearanceCallbackIfReady()
    }

    private func invokeAppearanceCallbackIfReady() {
        guard hasAppeared, let callback = onFirstAppearance else { return }
        onFirstAppearance = nil
        // A callback assigned after UIKit's first appearance can otherwise
        // race the Readium child before its WebView has entered the hierarchy.
        // Defer one main-queue turn so both assignment orders share the same
        // post-appearance contract.
        DispatchQueue.main.async(execute: callback)
    }

    @objc func aiSearch() {
        performActiveSelectionAction(label: "aiSearch", logPrefix: "AI Search", callback: onPhraseSelected)
    }

    @objc func aiExplain() {
        performActiveSelectionAction(label: "aiExplain", logPrefix: "AI Explain", callback: onExplainSelected)
    }

    private func performActiveSelectionAction(
        label: StaticString,
        logPrefix: String,
        callback: ((String, String) -> Void)?
    ) {
        guard let navigator = epubNavigator else { return }
        guard let selection = navigator.currentSelection else { return }

        let highlight = selection.locator.text.highlight ?? ""
        guard !highlight.isEmpty else { return }

        let context = buildMarkedContext(selection.locator.text)
        AppLog.reader.debug("\(logPrefix): \(highlight)")

        Task { @MainActor in
            ReaderJSEval.log(await navigator.evaluateBridgeScript(activeSelectionWrapScript), label)
            navigator.clearSelection()
        }

        callback?(highlight, context)
    }
}

private func buildMarkedContext(_ text: Locator.Text) -> String {
    let before = text.before ?? ""
    let highlight = text.highlight ?? ""
    let after = text.after ?? ""
    return "\(before)**\(highlight)**\(after)"
}

func filterValidWords(_ words: some Collection<String>, bookWords: Set<String>?) -> [String] {
    guard let bookWords else { return Array(words) }
    return words.filter { $0.contains(" ") || bookWords.contains($0) }
}

private let activeSelectionWrapScript = """
(function() {
    document.querySelectorAll('.active-word').forEach(function(el) {
        var parent = el.parentNode;
        while (el.firstChild) parent.insertBefore(el.firstChild, el);
        parent.removeChild(el);
        parent.normalize();
    });
    var sel = window.getSelection();
    if (sel.rangeCount > 0) {
        try {
            var range = sel.getRangeAt(0);
            var span = document.createElement('span');
            span.className = 'active-word';
            range.surroundContents(span);
        } catch(e) {}
    }
})();
"""
#endif
