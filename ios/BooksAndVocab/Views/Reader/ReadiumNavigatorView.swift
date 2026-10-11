#if os(iOS)
//
//  ReadiumNavigatorView.swift
//  Books & Vocab
//
//  Created by 陳亮宇 on 2026/2/24.
//

import SwiftUI
import WebKit
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator
import os

/// Preference application is complete when Readium reports its resulting
/// presentation. Keeping this as a small state machine makes the readiness
/// contract deterministic and unit-testable without a wall-clock delay.
struct ReaderPreferencesApplyState: Equatable {
    private var nextGeneration: UInt = 0
    private(set) var pendingGeneration: UInt?

    var isApplying: Bool { pendingGeneration != nil }

    mutating func begin() -> UInt {
        nextGeneration &+= 1
        pendingGeneration = nextGeneration
        return nextGeneration
    }

    mutating func cancel(_ generation: UInt) {
        guard pendingGeneration == generation else { return }
        pendingGeneration = nil
    }

    mutating func invalidate() {
        pendingGeneration = nil
    }

    @discardableResult
    mutating func observeNavigatorPresentation() -> Bool {
        guard pendingGeneration != nil else { return false }
        pendingGeneration = nil
        return true
    }
}

/// Production accessibility receipt for the live EPUB navigator.
///
/// The settings are read from `EPUBNavigatorViewController.settings` after a
/// Readium delegate event. The receipt is therefore distinct from the
/// `ReaderSettings` request that caused the update.
struct ReaderNavigatorSettingsReceipt: Equatable {
    enum Phase: String {
        case pending
        case ready
    }

    enum Source: String {
        case presentationDidChange
        case locationDidChange
    }

    let navigatorID: UUID
    let phase: Phase
    let source: Source?
    let settings: ReaderSettingsBridgeState?

    static let pendingAccessibilityValue = "status=pending"

    static func pending(navigatorID: UUID) -> Self {
        .init(navigatorID: navigatorID, phase: .pending, source: nil, settings: nil)
    }

    static func ready(
        navigatorID: UUID,
        settings: ReaderSettingsBridgeState,
        source: Source
    ) -> Self {
        .init(navigatorID: navigatorID, phase: .ready, source: source, settings: settings)
    }

    var accessibilityValue: String {
        guard phase == .ready, let settings, let source else {
            return Self.pendingAccessibilityValue + ";navigator=\(navigatorID.uuidString)"
        }
        return [
            "status=\(phase.rawValue)",
            "navigator=\(navigatorID.uuidString)",
            "source=\(source.rawValue)",
            settings.accessibilityValue
        ].joined(separator: ";")
    }
}

// MARK: - SwiftUI Representable

struct ReadiumNavigatorView: UIViewControllerRepresentable {
    let publication: Publication
    let initialLocator: Locator?
    /// Recovery locators are applied after the host appears. Readium 2 can
    /// retain an invalid restore loading state when the same locator is passed
    /// during construction; an explicit `go(to:)` after appearance produces
    /// the real location event that closes that state.
    let recoveryLocator: Locator?
    let lookedUpWords: [String]
    let bookUniqueWords: Set<String>?
    let viewConfiguration: ReaderViewConfiguration
    let clearHighlightTrigger: UUID
    let removeWordTrigger: (word: String, id: UUID)?
    let navigateToLocator: (locator: Locator, id: UUID)?
    /// 當翻譯面板或其他覆蓋層開啟時設為 true，阻擋 WebView 接收觸控事件
    let isInteractionBlocked: Bool
    let onLocationChanged: (Locator) -> Void
    let onNavigatorSettingsReceipt: (ReaderNavigatorSettingsReceipt) -> Void
    let onWordSelected: (String, String) -> Void
    let onPhraseSelected: (String, String) -> Void
    let onExplainSelected: (String, String) -> Void
    let onWordDeselected: () -> Void
    var onMarkingProgress: ((Double) -> Void)?
    var onTOCNavigationEvent: (ReaderTOCNavigationEvent) -> Void = { _ in }

    struct BridgeSnapshot {
        let lookedUpWords: [String]
        let bookUniqueWords: Set<String>?
        let viewConfiguration: ReaderViewConfiguration
        let clearHighlightTrigger: UUID
        let removeWordTrigger: (word: String, id: UUID)?
        let navigateToLocator: (locator: Locator, id: UUID)?
        let isInteractionBlocked: Bool
    }

    var bridgeSnapshot: BridgeSnapshot {
        .init(
            lookedUpWords: lookedUpWords,
            bookUniqueWords: bookUniqueWords,
            viewConfiguration: viewConfiguration,
            clearHighlightTrigger: clearHighlightTrigger,
            removeWordTrigger: removeWordTrigger,
            navigateToLocator: navigateToLocator,
            isInteractionBlocked: isInteractionBlocked
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static func installLoadErrorLabel(on host: NavigatorHostViewController) {
        let errorLabel = UILabel()
        errorLabel.text = "無法開啟此書籍".localized
        errorLabel.textAlignment = .center
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: host.view.centerYAnchor),
        ])
    }

    private static func installInteractionBlocker(on host: NavigatorHostViewController, coordinator: Coordinator) {
        // 透明觸控攔截層：當翻譯面板開啟時覆蓋整個 WebView，阻止 click 穿透
        let blocker = UIView(frame: host.view.bounds)
        blocker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blocker.backgroundColor = .clear
        blocker.isUserInteractionEnabled = false // 預設關閉
        blocker.tag = 9001

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleBlockerTap(_:)))
        blocker.addGestureRecognizer(tap)

        host.view.addSubview(blocker)
    }

    func makeUIViewController(context: Context) -> NavigatorHostViewController {
        let host = NavigatorHostViewController()
        host.onWordSelected = onWordSelected
        host.onPhraseSelected = onPhraseSelected
        host.onExplainSelected = onExplainSelected

        let navigator: EPUBNavigatorViewController
        do {
            let aiSearchAction = EditingAction(
                title: "翻譯".localized,
                action: #selector(NavigatorHostViewController.aiSearch)
            )
            let aiExplainAction = EditingAction(
                title: "解釋".localized,
                action: #selector(NavigatorHostViewController.aiExplain)
            )

            navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: recoveryLocator == nil ? initialLocator : nil,
                config: .init(
                    preferences: viewConfiguration.epubPreferences,
                    defaults: EPUBDefaults(
                        scroll: false
                    ),
                    editingActions: [aiSearchAction, aiExplainAction, .copy, .lookup]
                )
            )
        } catch {
            AppLog.reader.error("Failed to create EPUBNavigatorViewController: \(error)")
            Self.installLoadErrorLabel(on: host)
            return host
        }

        context.coordinator.activateNavigator(navigator)
        navigator.delegate = context.coordinator
        host.epubNavigator = navigator

        host.addChild(navigator)
        navigator.view.frame = host.view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(navigator.view)
        navigator.didMove(toParent: host)

        if let recoveryLocator {
            context.coordinator.prepareRecovery(to: recoveryLocator)
            host.onFirstAppearance = { [weak coordinator = context.coordinator] in
                // Recovery is retried by Readium readiness/presentation events,
                // not by a wall-clock polling loop. This keeps the restore path
                // deterministic on device and observable in UI evidence.
                coordinator?.triggerRecoveryNavigation()
            }
        }

        // 將 UIKit 層背景設為紙色，避免 iOS 26 glass effect 取樣到
        // WKWebView 的原生深色背景（系統深色模式時 CSS 層與 UIKit 層不一致）
        let paperUIColor = UIColor(viewConfiguration.paperColor)
        host.view.backgroundColor = paperUIColor
        navigator.view.backgroundColor = paperUIColor

        Self.installInteractionBlocker(on: host, coordinator: context.coordinator)

        return host
    }

    static func dismantleUIViewController(_ uiViewController: NavigatorHostViewController, coordinator: Coordinator) {
        coordinator.deactivateNavigator()
        // 移除 WKUserContentController 對 Coordinator 的強引用，打斷 retain cycle
        if let controller = coordinator.registeredContentController {
            for name in Coordinator.registeredHandlerNames {
                controller.removeScriptMessageHandler(forName: name)
            }
            coordinator.registeredContentController = nil
        }
        coordinator.contentOffsetObserver = nil
        coordinator.activeTOCNavigationTask?.cancel()
        coordinator.activeTOCNavigationTask = nil
        coordinator.activeTOCTimeoutTask?.cancel()
        coordinator.activeTOCTimeoutTask = nil
        coordinator.tocNavigationGate.invalidate()
        coordinator.recoveryTask?.cancel()
        coordinator.recoveryTask = nil
        coordinator.pendingRecoveryLocator = nil
    }

    func updateUIViewController(_ uiViewController: NavigatorHostViewController, context: Context) {
        // 同步最新的 SwiftUI View 給 Coordinator，避免舊的 state capture 導致閉包操作拿不到最新的 bookUniqueWords
        context.coordinator.parent = self
        context.coordinator.sync(with: bridgeSnapshot, in: uiViewController)

        // 同步 UIKit 層背景色（使用者切換閱讀主題時紙色會變）
        let paperUIColor = UIColor(viewConfiguration.paperColor)
        uiViewController.view.backgroundColor = paperUIColor
        uiViewController.epubNavigator?.view.backgroundColor = paperUIColor
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, EPUBNavigatorDelegate {
        var parent: ReadiumNavigatorView
        weak var navigator: EPUBNavigatorViewController?
        private(set) var navigatorLifecycleGate = ReaderNavigatorLifecycleGate()
        var planner = BridgePlanner()
        var isApplyingPreferences = false
        var tocNavigationGate = ReaderTOCNavigationRequestGate()
        var activeTOCRequestID: UUID? { tocNavigationGate.activeRequestID }
        var activeTOCNavigationTask: Task<Void, Never>?
        var activeTOCTimeoutTask: Task<Void, Never>?
        var pendingRecoveryLocator: Locator?
        var recoveryAttemptCount = 0
        var recoveryTask: Task<Void, Never>?
        var activeRecoveryTaskID: UUID?
        var preferencesApplyState = ReaderPreferencesApplyState()
        var preferencesApplyTask: Task<Void, Never>?
        let navigatorID = UUID()
        var hasPublishedNavigatorSettingsReceipt = false
        let domExecutor = ReaderDOMExecutor()
        lazy var vocabMarks = VocabMarkScheduler(duration: ReaderMetrics.markVocabDebounceDuration) { [weak self] words in
            self?.emitMarkVocabWordsJS(words)
        }

        /// 記住 setupUserScripts 傳入的 controller，供 dismantle 時移除 handler 打斷 retain cycle
        weak var registeredContentController: WKUserContentController?
        static let registeredHandlerNames = ["wordTap", "wordDeselect", "selectionState", "markingProgress"]

        // 選取期間鎖定翻頁
        var selectionPageAnchor: CGPoint?
        var contentOffsetObserver: NSKeyValueObservation?

        init(parent: ReadiumNavigatorView) {
            self.parent = parent
        }

        func activateNavigator(_ navigator: EPUBNavigatorViewController) {
            preferencesApplyTask?.cancel()
            preferencesApplyTask = nil
            recoveryTask?.cancel()
            recoveryTask = nil
            activeRecoveryTaskID = nil
            preferencesApplyState.invalidate()
            _ = navigatorLifecycleGate.activate()
            self.navigator = navigator
            hasPublishedNavigatorSettingsReceipt = false
        }

        func deactivateNavigator() {
            preferencesApplyTask?.cancel()
            preferencesApplyTask = nil
            preferencesApplyState.invalidate()
            recoveryTask?.cancel()
            recoveryTask = nil
            activeRecoveryTaskID = nil
            navigatorLifecycleGate.deactivate()
            navigator?.delegate = nil
            navigator = nil
            hasPublishedNavigatorSettingsReceipt = false
        }

        func acceptsNavigator(_ candidate: any Navigator, generation: UInt) -> Bool {
            guard navigatorLifecycleGate.accepts(generation),
                  let current = navigator,
                  let candidate = candidate as? EPUBNavigatorViewController
            else { return false }
            return candidate === current
        }

        private static let maxRecoveryAttempts = 8

        func prepareRecovery(to locator: Locator) {
            recoveryTask?.cancel()
            recoveryTask = nil
            activeRecoveryTaskID = nil
            pendingRecoveryLocator = locator
            recoveryAttemptCount = 0
        }

        func triggerRecoveryNavigation() {
            guard recoveryTask == nil,
                  let locator = pendingRecoveryLocator,
                  let navigator else { return }
            let callbackGeneration = navigatorLifecycleGate.generation
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }

            recoveryAttemptCount += 1
            let attempt = recoveryAttemptCount
            let recoveryTaskID = UUID()
            activeRecoveryTaskID = recoveryTaskID
            recoveryTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                let accepted = await navigator.go(to: locator)
                guard let self else { return }
                guard
                    !Task.isCancelled,
                    self.activeRecoveryTaskID == recoveryTaskID,
                    self.acceptsNavigator(navigator, generation: callbackGeneration)
                else { return }
                self.activeRecoveryTaskID = nil
                self.recoveryTask = nil
                AppLog.reader.debug(
                    "Reader restore fallback navigation attempt=\(attempt, privacy: .public) accepted=\(String(describing: accepted), privacy: .public) href=\(locator.href.string, privacy: .public)"
                )
                if accepted == true {
                    self.pendingRecoveryLocator = nil
                    return
                }
                if attempt >= Self.maxRecoveryAttempts {
                    AppLog.reader.error(
                        "Reader restore fallback exhausted readiness attempts href=\(locator.href.string, privacy: .public)"
                    )
                    self.pendingRecoveryLocator = nil
                }
            }
        }

        // MARK: NavigatorDelegate

        func navigator(_ navigator: any Navigator, locationDidChange locator: Locator) {
            let callbackGeneration = navigatorLifecycleGate.generation
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }
            // Initial configuration is supplied to the navigator initializer.
            // If no preference command was needed, the first real location
            // event is the readiness boundary for the initial receipt.
            if
                !hasPublishedNavigatorSettingsReceipt,
                let epubNavigator = navigator as? EPUBNavigatorViewController
            {
                publishNavigatorSettingsReceipt(from: epubNavigator, source: .locationDidChange)
            }
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }
            let matchingTOCRequestID = activeTOCRequestID.flatMap { requestID in
                tocNavigationGate.matchesCurrent(
                    requestID,
                    locatorHref: locator.href.string,
                    locatorFragments: locator.locations.fragments
                )
                    ? requestID
                    : nil
            }
            parent.onLocationChanged(locator)
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }
            triggerRecoveryNavigation()
            if let requestID = matchingTOCRequestID,
               tocNavigationGate.finish(
                   requestID,
                   ifMatchingLocatorHref: locator.href.string,
                   locatorFragments: locator.locations.fragments
               ) {
                activeTOCNavigationTask?.cancel()
                activeTOCNavigationTask = nil
                activeTOCTimeoutTask?.cancel()
                activeTOCTimeoutTask = nil
                parent.onTOCNavigationEvent(
                    .locationDidChange(
                        requestID: requestID,
                        locatorHref: locator.href.string
                    )
                )
            }
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }

            // 翻頁後重新標記所有生字庫底線（設定調整期間跳過，避免卡頓）
            let words = parent.lookedUpWords
            if !words.isEmpty && !preferencesApplyState.isApplying {
                let validWords = filterValidWords(words, bookWords: parent.bookUniqueWords)
                self.markVocabWords(validWords)
            }
        }

        func navigator(_ navigator: any Navigator, presentError error: NavigatorError) {
            let callbackGeneration = navigatorLifecycleGate.generation
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }
            AppLog.reader.error("Navigator error: \(String(describing: error))")
        }

        // MARK: VisualNavigatorDelegate

        func navigator(_ navigator: any VisualNavigator, presentationDidChange presentation: VisualNavigatorPresentation) {
            let callbackGeneration = navigatorLifecycleGate.generation
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }
            _ = preferencesApplyState.observeNavigatorPresentation()
            guard let epubNavigator = navigator as? EPUBNavigatorViewController else { return }
            publishNavigatorSettingsReceipt(from: epubNavigator, source: .presentationDidChange)
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }
            triggerRecoveryNavigation()
        }

        // 注意：不在 didTapAt 呼叫 handleTap，因為注入的 JS click listener 已處理
        // 若在此也呼叫 handleTap 會和 JS toggle 邏輯衝突

        func navigator(_ navigator: any VisualNavigator, didTapAt point: CGPoint) {
            // 由注入的 JS click listener 處理，此處不做額外操作
        }

        // MARK: SelectableNavigatorDelegate

        func navigator(_ navigator: any SelectableNavigator, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
            true
        }

        func navigator(_ navigator: any SelectableNavigator, shouldShowMenuForSelection selection: Selection) -> Bool {
            true
        }

        // MARK: EPUBNavigatorDelegate — JS 注入

        func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
            let callbackGeneration = navigatorLifecycleGate.generation
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }
            registeredContentController = userContentController
            for name in Self.registeredHandlerNames {
                userContentController.add(self, name: name)
            }

            // ── 自訂字體 @font-face：主執行緒只讀快取（#2052）──
            // TTF → base64 由 `ReaderFontFaceCSSCache.prewarm()` 在背景 `.utility` 建好；
            // 這裡不做任何檔案 IO（極端 cold 時才走有 log 的單次同步 fallback）。
            let fontFaceCSS = ReaderFontFaceCSSCache.shared.css()

            // ★ 傳遞除錯模式開關
            let isDebugMode = (
                ReaderDebugTools.isAvailable && parent.viewConfiguration.showHitTestingDebug
            ) ? "true" : "false"
            let contentStyleCSS = parent.viewConfiguration.contentStyleCSS

            let js = ReadiumNavigatorJS.buildInjectionScript(
                fontFaceCSS: fontFaceCSS,
                contentStyleCSS: contentStyleCSS,
                underlineOpacity: parent.viewConfiguration.underlineOpacity,
                isDebugMode: isDebugMode
            )

            let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            userContentController.addUserScript(script)
            AppLog.reader.info("User scripts injected")
            PerfLog.reader.mark("userScriptsInjected")
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }
            triggerRecoveryNavigation()
            guard acceptsNavigator(navigator, generation: callbackGeneration) else { return }

            // Scripts 注入後重新標記所有生字（修復初始載入的 race condition）
            let words = parent.lookedUpWords
            if !words.isEmpty {
                let validWords = filterValidWords(words, bookWords: parent.bookUniqueWords)
                self.markVocabWords(validWords)
            }
        }

        private func publishNavigatorSettingsReceipt(
            from navigator: EPUBNavigatorViewController,
            source: ReaderNavigatorSettingsReceipt.Source
        ) {
            guard
                let settings = ReaderSettingsBridgeState(navigatorSettings: navigator.settings)
            else {
                AppLog.reader.error("Readium navigator settings receipt was unavailable")
                return
            }

            hasPublishedNavigatorSettingsReceipt = true
            parent.onNavigatorSettingsReceipt(
                .ready(
                    navigatorID: navigatorID,
                    settings: settings,
                    source: source
                )
            )
        }
    }
}
#endif
