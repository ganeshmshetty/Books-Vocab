#if os(iOS)
import Foundation
import SwiftUI
import ReadiumShared

extension ReaderView {
    var vocabularyContext: ReaderVocabularyContext {
        ReaderVocabularyContext(
            vocabulary: allVocabulary,
            modelContext: modelContext,
            book: book,
            currentLocator: pageTurn.currentLocator,
            notebookId: book.resolvedNotebookId,
            toastCoordinator: toastCoordinator
        )
    }

    var initialLocator: Locator? {
        guard let json = book.lastReadLocatorJSON else { return nil }
        do {
            let locator = try Locator(jsonString: json)
            guard let publication else { return locator }
            let readingOrderHrefs = Set(publication.readingOrder.map { $0.url().string })
            guard readingOrderHrefs.contains(locator.href.string) else {
                AppLog.reader.error(
                    "Saved locator is outside the loaded publication reading order: \(locator.href.string, privacy: .public)"
                )
                return restoreFallbackLocator
            }
            return locator
        } catch {
            AppLog.reader.error("Failed to restore saved locator: \(error.localizedDescription, privacy: .public)")
            return restoreFallbackLocator
        }
    }

    func prepareRestoreState() {
        guard book.lastReadLocatorJSON != nil, initialLocator == nil else { return }
        readerState.runtime.markRestoreFailure()
    }

    var readerMainContentState: ReaderMainContentState {
        ReaderMainContentState.resolve(
            hasPublication: publication != nil,
            errorMessage: readerState.errorMessage,
            loadingState: readerState.loadingState
        )
    }

    @ViewBuilder
    var readerMainContent: some View {
        switch readerMainContentState {
        case .content:
            if let publication {
            ReadiumNavigatorView(
                publication: publication,
                initialLocator: restoreFallbackLocator == nil ? restoredInitialLocator : nil,
                recoveryLocator: restoreFallbackLocator,
                lookedUpWords: handler.lookedUpWords,
                bookUniqueWords: handler.bookUniqueWords,
                viewConfiguration: viewConfiguration,
                clearHighlightTrigger: handler.clearHighlightTrigger,
                removeWordTrigger: handler.removeWordTrigger,
                navigateToLocator: navigateToLocator,
                isInteractionBlocked: chromeState.blocksReaderInteraction,
                onLocationChanged: handleLocationChange,
                onNavigatorSettingsReceipt: { receipt in
                    navigatorSettingsReceipt = receipt
                },
                onWordSelected: handleWordSelected,
                onPhraseSelected: handlePhraseSelected,
                onExplainSelected: { text, context in
                    guard canUseProReaderFeature() else { return }
                    handler.handleExplainSelected(text: text, context: context)
                    withAnimation(AppMotion.panelState) { chromeState.overlay = .translation }
                },
                onWordDeselected: handleWordDeselected,
                onMarkingProgress: handleMarkingProgress,
                onTOCNavigationEvent: handleTOCNavigationEvent
            )
            // A persisted locator can fail to decode only after the
            // publication has loaded. The recovery locator is therefore a
            // real state transition, not merely a changed representable input:
            // rebuild the navigator so Readium receives it in its initializer
            // instead of retaining the first nil `initialLocation`.
            .id(restoreFallbackLocator?.href.string ?? "reader.navigator.default")
            .overlay(alignment: .bottom) {
                tocNavigationSuccessOverlay
            }
            .overlay(alignment: .topLeading) {
                readerTOCEvidenceLocator
            }
            .overlay(alignment: .topTrailing) {
                readerTOCEvidenceAsset
            }
            .ignoresSafeArea(edges: [.horizontal, .bottom])
            // Keep the real navigator geometry untouched. This accessibility
            // container is the production state receipt for close/reopen UI
            // evidence; it is not a zero-size visual/layout probe.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader.webView.settingsState")
            .accessibilityLabel(L10n.string("reader.settings.webView.state"))
            .accessibilityValue(
                navigatorSettingsReceipt?.accessibilityValue
                    ?? ReaderNavigatorSettingsReceipt.pendingAccessibilityValue
            )
            } else {
                readerEmptyState()
            }
        case .error:
            readerErrorState(
                readerState.errorMessage
                    ?? L10n.string("請重試載入這本書。")
            )
        case .loading:
            EmptyView()
        case .empty:
            readerEmptyState()
        }
    }

    func readerEmptyState() -> some View {
        ScrollView {
            VStack {
                Spacer(minLength: ReaderPresentationMetrics.Preview.topInset)
                AppEmptyStateCard(
                    title: L10n.string("閱讀內容尚未載入"),
                    systemImage: "book.closed",
                    description: L10n.string("請重試載入這本書。"),
                    action: AppEmptyStateAction(
                        title: L10n.string("重試載入"),
                        systemImage: "arrow.clockwise",
                        accessibilityIdentifier: "reader.retry",
                        handler: { retryLoadPublication() }
                    )
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("reader.empty")
                .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)
                Spacer(minLength: ReaderPresentationMetrics.Preview.bottomInset)
            }
            .frame(maxWidth: .infinity)
        }
        .background(viewConfiguration.paperColor.ignoresSafeArea())
    }

    @ViewBuilder
    private var tocNavigationSuccessOverlay: some View {
        if let destinationHref = tocNavigationState.destinationHref,
           let selectedTitle = tocNavigationState.selectedTitle {
            VStack(alignment: .leading, spacing: AppSpacing.s1) {
                Text(L10n.string("章節已開啟"))
                    .font(AppFonts.caption())
                    .accessibilityIdentifier("reader.toc.readerOverlay.result.success")
                Text(selectedTitle)
                    .font(AppFonts.body())
                    .lineLimit(1)
                    .accessibilityIdentifier("reader.toc.readerOverlay.destination")
                    .accessibilityValue(destinationHref)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader.toc.readerOverlay")
            .padding(AppSpacing.s3)
            .background(.thinMaterial)
            .clipShape(AppRoundedRect(roundness: AppRoundness.card))
            .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)
            .padding(.bottom, AppSpacing.s3)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var readerTOCEvidenceLocator: some View {
        if let currentLocator = pageTurn.currentLocator {
            Text(currentLocator.href.string)
                .accessibilityIdentifier("reader.currentLocator")
                .accessibilityValue(currentLocator.href.string)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var readerTOCEvidenceAsset: some View {
        #if DEBUG
        let proof = readerTOCEvidenceAssetProof()
        Text(proof.accessibilityDescriptor)
            .accessibilityIdentifier("reader.evidence.asset")
            .accessibilityValue(proof.accessibilityDescriptor)
            .opacity(0.01)
            .allowsHitTesting(false)
        #endif
    }

    private func readerTOCEvidenceAssetProof() -> FixtureInstalledAssetProof {
        do {
            return try FixtureDatasetStore.readerAssetProof(
                forInstalledFileName: book.epubFileName
            )
        } catch {
            fatalError("Reader evidence asset proof unavailable: \(error)")
        }
    }

    func readerErrorState(_ error: String) -> some View {
        let presentation = readerErrorPresentation(for: error)
        return ScrollView {
            VStack {
                Spacer(minLength: ReaderPresentationMetrics.Preview.topInset)

                AppEmptyStateCard(
                    title: presentation.title,
                    systemImage: presentation.systemImage,
                    description: presentation.description,
                    action: AppEmptyStateAction(
                        title: L10n.string("重試載入"),
                        systemImage: "arrow.clockwise",
                        accessibilityIdentifier: "reader.retry",
                        handler: { retryLoadPublication() }
                    )
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("reader.error.\(readerState.loadingState.accessibilityIdentifier)")
                .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)

                Spacer(minLength: ReaderPresentationMetrics.Preview.bottomInset)
            }
            .frame(maxWidth: .infinity)
        }
        .background(viewConfiguration.paperColor.ignoresSafeArea())
    }

    /// 根據錯誤訊息與當前網路狀態，挑選合適的圖示／標題／敘述。
    /// 不解析後端錯誤碼，僅作字串啟發式分類，足以服務「等 iCloud / 離線 / 一般失敗」三種主場景。
    private func readerErrorPresentation(for error: String) -> ReaderErrorPresentation {
        let offline = !NetworkMonitor.shared.isConnected
        let lower = error.lowercased()
        if lower.contains("icloud") {
            return ReaderErrorPresentation(
                title: L10n.string("iCloud 下載失敗"),
                systemImage: "icloud.slash",
                description: error
            )
        }
        if offline || lower.contains("offline") || lower.contains("internet") || lower.contains("network") {
            return ReaderErrorPresentation(
                title: L10n.string("目前無法連線"),
                systemImage: "wifi.slash",
                description: L10n.string("請確認網路或 iCloud 同步狀態後再試一次。\n\n") + error
            )
        }
        return ReaderErrorPresentation(
            title: L10n.string("無法開啟書籍"),
            systemImage: "exclamationmark.triangle",
            description: error
        )
    }

    @ViewBuilder
    var settingsPanelContent: some View {
        ReaderSettingsPanelSheet(
            settings: settings,
            onDone: {
                closeOverlay(.settings)
            }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    var translationPanelContent: some View {
        if let selection = handler.wordSelection {
            // 快取一次詞庫查找，避免 body 重算時 existingEntry() 在 nil 檢查與
            // closure 內各掃一次（1000+ 詞庫下為 O(n)×2 線性掃 + lowercased）。
            let existingDetailEntry = vocabularyContext.existingEntry(matching: selection.word)
            makeTranslationPanel(selection: selection, existingDetailEntry: existingDetailEntry)
        }
    }

    private func makeTranslationPanel(selection: WordSelection, existingDetailEntry: VocabularyEntry?) -> some View {
        TranslationPanel(
                word: selection.word,
                result: handler.translationResult,
                isLoading: handler.isTranslating,
                isSaved: handler.isSaved,
                isLoggedIn: authManager.isLoggedIn,
                isExpanded: handler.isExpanded,
                explanation: handler.explanationText,
                isLoadingExplanation: handler.isLoadingExplanation,
                statusMessage: handler.statusMessage,
                isExplanationOnly: handler.isExplanationOnly,
                translationErrorMessage: handler.translationErrorMessage,
                explanationErrorMessage: handler.explanationErrorMessage,
                onExpand: { handler.handleExpand() },
                onDelete: {
                    handler.deleteFromVocabulary(selection.word, context: vocabularyContext)
                    closeOverlay(.translation)
                },
                onShowDetail: existingDetailEntry != nil ? {
                    if let entry = existingDetailEntry {
                        readerState.detailEntry = entry
                    }
                } : nil,
                onDismiss: {
                    handler.dismiss()
                    closeOverlay(.translation)
                },
                onLogin: authManager.isLoggedIn ? nil : { loginGate.presentLogin() },
                onRetryTranslation: (handler.translationErrorMessage != nil && handler.lastLookup != nil)
                    ? { handler.retryLastLookup(vocabularyContext: vocabularyContext) }
                    : nil,
                onRetryExplanation: (handler.explanationErrorMessage != nil && handler.lastLookup != nil)
                    ? { handler.retryLastLookup(vocabularyContext: vocabularyContext) }
                    : nil,
                isPanelLarge: handler.isPanelLarge,
                onToggleHeight: { handler.togglePanelHeight() }
        )
    }
}

/// Reader 載入失敗時，UI 呈現所需的 三元組（title / 圖示 / 敘述）。
struct ReaderErrorPresentation {
    let title: String
    let systemImage: String
    let description: String
}
#endif
