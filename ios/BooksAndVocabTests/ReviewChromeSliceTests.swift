import Foundation
import Testing
@testable import BooksAndVocab

/// Chrome Equatable 切片契約（settle 白工 Phase 2）。
///
/// ReviewTopBar / ReviewToolbarControls 的 `==` 只比較 `model`；契約是
/// 「所有影響渲染的值都收進 model（synthesized == 全欄位）、其餘 stored
/// property 只能是 intent 閉包或 @Environment/@State 動態 wrapper（自帶
/// 失效通道）」。若未來有人加了一個裸值欄位卻沒進 model，Equatable skip
/// 會讓 UI 不更新——本 suite 用 Mirror 把這種欄位擋在編譯後第一道。
@MainActor
struct ReviewChromeSliceTests {
    private static let topBarModel = ReviewTopBarModel(
        progressText: "1 / 8",
        canShuffle: true,
        canAutoplay: true,
        isAutoPlaying: false,
        isCardInteractive: true
    )

    private static let toolbarModel = ReviewToolbarModel(
        showsAnswer: false,
        isAutoPlaying: false,
        isAutoPlayPaused: false,
        autoplaySoundEnabled: true,
        autoplaySpeedName: "1×",
        autoplayProgress: 0,
        progressText: "1 / 8",
        gradeHints: nil,
        canGoPrevious: false,
        canGoNext: true,
        isCardInteractive: true,
        swipeIntensity: 0
    )

    private static let readerChromeModel = ReaderTopChromeModel(
        isExpanded: true,
        bookTitle: "Moby-Dick",
        totalProgression: 0.562,
        progressState: .middle(0.562),
        titleMaxWidth: 160
    )

    private static func makeReaderTopChrome(model: ReaderTopChromeModel = readerChromeModel,
                                            onDismiss: @escaping () -> Void = {}) -> ReaderTopChrome {
        ReaderTopChrome(model: model, onDismiss: onDismiss,
                        onShowTableOfContents: {}, onShowReaderSettings: {},
                        onShowNotebookPicker: {}, onCollapseHeader: {}, onExpandHeader: {})
    }

    private static func makeTopBar(model: ReviewTopBarModel = topBarModel,
                                   onShuffle: @escaping () -> Void = {},
                                   onAdjustLayout: @escaping () -> Void = {}) -> ReviewTopBar {
        ReviewTopBar(model: model, onShuffle: onShuffle,
                     onToggleAutoPlay: {}, onAdjustLayout: onAdjustLayout,
                     onToggleHelp: {}, onClose: {})
    }

    private static func makeControls(model: ReviewToolbarModel = toolbarModel,
                                     onForgotTap: @escaping () -> Void = {}) -> ReviewToolbarControls {
        ReviewToolbarControls(model: model, onForgotTap: onForgotTap,
                              onRememberedTap: {}, onPrevious: {}, onNext: {},
                              onToggleAutoPlayPause: {}, onToggleAutoPlaySound: {},
                              onChangeAutoPlaySpeed: {})
    }

    /// 非 model 的 stored property 只允許閉包（"(Function)"/含 "->"）或
    /// `_` 前綴的動態 property wrapper（@Environment/@State，自帶失效通道）。
    private func expectOnlyModelClosuresAndWrappers(_ subject: Any) {
        for child in Mirror(reflecting: subject).children {
            guard let label = child.label else { continue }
            if label == "model" || label.hasPrefix("_") { continue }
            let typeDescription = String(describing: type(of: child.value))
            #expect(
                typeDescription.contains("->"),
                "stored property `\(label)`（\(typeDescription)）不是閉包也不在 model——Equatable skip 會吃掉它的更新"
            )
        }
    }

    @Test func topBarStoredStateIsModelClosuresOrWrappers() {
        expectOnlyModelClosuresAndWrappers(Self.makeTopBar())
    }

    @Test func toolbarControlsStoredStateIsModelClosuresOrWrappers() {
        expectOnlyModelClosuresAndWrappers(Self.makeControls())
    }

    /// The layout-editor entry is an intent closure, so it must not participate in
    /// `==` — and its gate (`isCardInteractive`) must already be a model field, or
    /// the button would keep an interactive state the chrome skipped re-rendering.
    @Test func layoutEditorActionStaysOutsideTheEqualitySlice() {
        #expect(Self.makeTopBar() == Self.makeTopBar(onAdjustLayout: { _ = 1 }))

        var locked = Self.topBarModel
        locked.isCardInteractive = false
        #expect(Self.makeTopBar() != Self.makeTopBar(model: locked))
        expectOnlyModelClosuresAndWrappers(Self.makeTopBar(onAdjustLayout: { _ = 1 }))
    }

    @Test func readerTopChromeStoredStateIsModelClosuresOrWrappers() {
        expectOnlyModelClosuresAndWrappers(Self.makeReaderTopChrome())
    }

    /// Reader chrome 沿用同一契約：它疊在 WKWebView 上、翻頁與拖曳期間都在畫面上，
    /// 一個裸值欄位漏進去就是每幀重新求值整條 header。
    @Test func readerTopChromeEqualityComparesModelAndIgnoresClosures() {
        var collapsed = Self.readerChromeModel
        collapsed.isExpanded = false
        #expect(Self.makeReaderTopChrome() == Self.makeReaderTopChrome(onDismiss: { _ = 1 }))
        #expect(Self.makeReaderTopChrome() != Self.makeReaderTopChrome(model: collapsed))
    }

    @Test func equalityComparesModelAndIgnoresClosures() {
        var changed = Self.topBarModel
        changed.canShuffle = false
        #expect(Self.makeTopBar() == Self.makeTopBar(onShuffle: { _ = 1 }))
        #expect(Self.makeTopBar() != Self.makeTopBar(model: changed))

        var hinted = Self.toolbarModel
        hinted.gradeHints = ReviewGradeIntervalHints(
            baseline: .init(reviewIntervalHours: 24, nextReviewAt: .distantPast, lastReviewedAt: nil, reviewCount: 2, lapseCount: 0, reviewStreak: 2, lastReviewFeedbackRaw: 1),
            settings: .default
        )
        #expect(Self.makeControls() == Self.makeControls(onForgotTap: { _ = 1 }))
        #expect(Self.makeControls() != Self.makeControls(model: hinted))
    }
}
