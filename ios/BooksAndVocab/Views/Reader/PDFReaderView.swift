#if os(iOS)
//
//  PDFReaderView.swift
//  Books & Vocab
//
//  PDFKit 原生渲染 + 詞彙捕捉整合
//

import SwiftUI
import SwiftData
import PDFKit

// MARK: - Progress Persistence

private struct PDFPosition: Codable {
    let pageIndex: Int
}

/// Per-page progress recording for the PDF reader (#2471). In-memory fields
/// update immediately; the SwiftData save + manifest rewrite is debounced via
/// `ReaderProgressSaver`, matching the EPUB path.
@MainActor
struct PDFProgressRecorder {
    let book: Book
    let saver: ReaderProgressSaver
    let persist: @MainActor () -> Void
    var now: () -> Date = Date.init

    func pageChanged(pageIndex: Int, pageCount: Int) {
        // 空文件沒有可記錄的位置；guard 放在可測試的 recorder 而非 Coordinator。
        guard pageCount > 0 else { return }
        let book = book
        let date = now()
        saver.recordChange(apply: {
            if let data = try? JSONEncoder().encode(PDFPosition(pageIndex: pageIndex)),
               let json = String(data: data, encoding: .utf8) {
                book.lastReadLocatorJSON = json
            } else {
                AppLog.reader.warning("PDF position encode failed (pageIndex=\(pageIndex))")
            }
            // Progression: 0.0 ~ 1.0
            book.progression = pageCount > 1
                ? Double(pageIndex) / Double(pageCount - 1)
                : 1.0
            book.dateLastRead = date
        }, save: persist)
    }
}

// MARK: - PDFReaderView

struct PDFReaderView: View {
    let book: Book

    @Environment(\.modelContext) private var modelContext
    @Environment(\.authManager) private var authManager
    @Environment(\.toastCoordinator) private var toastCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @Query(
        filter: #Predicate<VocabularyEntry> { $0.actionType != "delete" }
    )
    private var allVocabulary: [VocabularyEntry]

    @State private var pdfDocument: PDFDocument?
    @State private var loadError: String?
    @State private var handler = ReaderTranslationHandler()
    @State private var showTranslation = false
    @State private var loginGate = LoginGateState()
    @State private var detailEntry: VocabularyEntry?
    @State private var progressSaver = ReaderProgressSaver()

    private var vocabularyContext: ReaderVocabularyContext {
        ReaderVocabularyContext(
            vocabulary: allVocabulary,
            modelContext: modelContext,
            book: book,
            currentLocator: nil,
            notebookId: book.resolvedNotebookId,
            toastCoordinator: toastCoordinator
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let document = pdfDocument {
                    PDFKitRepresentable(
                        document: document,
                        book: book,
                        modelContext: modelContext,
                        progressSaver: progressSaver,
                        onWordSelected: { word, context in
                            guard canUseProReaderFeature() else { return }
                            handler.handleWordSelected(
                                word: word,
                                context: context,
                                vocabularyContext: vocabularyContext
                            )
                            presentTranslationPanel()
                        },
                        onPhraseSelected: { phrase, context in
                            guard canUseProReaderFeature() else { return }
                            handler.handlePhraseSelected(
                                phrase: phrase,
                                context: context,
                                vocabularyContext: vocabularyContext
                            )
                            presentTranslationPanel()
                        },
                        onExplainSelected: { text, context in
                            guard canUseProReaderFeature() else { return }
                            handler.handleExplainSelected(text: text, context: context)
                            presentTranslationPanel()
                        }
                    )
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
                } else if let error = loadError {
                    errorView(error)
                } else {
                    loadingView
                }
            }

            translationPanelOverlay
        }
        .task { loadDocument() }
        .onDisappear {
            // dismiss / pop 時取消 in-flight 翻譯 task，避免網路 Task
            // 續跑到完成後寫回已棄置的 handler（多餘網路/寫入）。
            // 用 onDisappear 而非 @MainActor @Observable 的 deinit
            // （時序與 actor 隔離易出錯）。
            handler.cancelCurrentTranslationTask()
            progressSaver.flush()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { progressSaver.flush() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .macReaderImmersion()
        .loginGateSheet($loginGate)
        .toastSheet(item: $detailEntry) { entry in
            WordDetailSheet(entry: entry, allEntries: allVocabulary)
        }
    }

    // MARK: - Loading

    private func loadDocument() {
        let url = book.fileURL
        let fm = FileManager.default
        if !fm.isReadableFile(atPath: url.path) {
            // iCloud 占位符 / 未下載：給較具體的提示
            loadError = "PDF 檔案尚未從 iCloud 下載完成或已被移除。請確認檔案可在「檔案」App 中開啟後再試一次。".localized
            AppLog.reader.error("PDF unreadable at: \(url.lastPathComponent)")
            return
        }
        guard let document = PDFDocument(url: url) else {
            loadError = "無法載入 PDF 檔案。檔案可能已損毀，或格式不受支援。".localized
            AppLog.reader.error("PDF load failed: \(url.lastPathComponent)")
            return
        }
        // PDFDocument(url:) 對結構完整但 0 頁的損毀 PDF 仍回非 nil,會通過上面的 guard
        // 後渲染空白 PDFView 而無任何提示。明確擋掉 0 頁,走既有 error 呈現路徑。
        guard document.pageCount > 0 else {
            loadError = "這份 PDF 沒有任何可顯示的頁面，檔案可能已損毀或不完整。".localized
            AppLog.reader.error("PDF has zero pages: \(url.lastPathComponent)")
            return
        }
        loadError = nil
        pdfDocument = document

        // Record the open like EPUB does on initial locationDidChange: bump
        // dateLastRead so a PDF opened-but-not-paged still surfaces in
        // continue-reading. Position/progression are left to pageDidChange
        // (persisted debounced via ReaderProgressSaver).
        book.dateLastRead = Date()
        if modelContext.safeSave() {
            BookManifestStore().writeBestEffort(book: book)
        }
    }

    private func retryLoad() {
        loadError = nil
        pdfDocument = nil
        loadDocument()
    }

    /// Parity hook with the EPUB path — both readers gate vocabulary capture
    /// through the shared `ReaderEntitlement` so a future entitlement check lands
    /// in exactly one place instead of letting the PDF reader silently bypass it.
    private func canUseProReaderFeature() -> Bool {
        ReaderEntitlement.canUseProReaderFeature()
    }

    private func presentTranslationPanel() {
        withAnimation(AppMotion.panelState) {
            showTranslation = true
        }
    }

    // MARK: - State Views

    @ViewBuilder private var translationPanelOverlay: some View {
        if showTranslation, let selection = handler.wordSelection {
            // 與 EPUB 同樣快取一次詞庫查找,避免 body 重算時重複 O(n) 掃描。
            let existingDetailEntry = vocabularyContext.existingEntry(matching: selection.word)
            makeTranslationPanel(selection: selection, existingDetailEntry: existingDetailEntry)
        }
    }

    @ViewBuilder
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
                    handler.deleteFromVocabulary(
                        selection.word, context: vocabularyContext
                    )
                    withAnimation(AppMotion.panelState) {
                        showTranslation = false
                    }
                },
                // 與 EPUB 對齊:已在詞庫的詞才顯示「查看詳情」(entry 為 nil 時
                // TranslationPanel 由 `if let onShowDetail` 隱藏該按鈕),點擊以
                // toastSheet 呈現 WordDetailSheet。
                onShowDetail: existingDetailEntry != nil ? {
                    if let entry = existingDetailEntry {
                        detailEntry = entry
                    }
                } : nil,
                onDismiss: {
                    handler.dismiss()
                    withAnimation(AppMotion.panelState) {
                        showTranslation = false
                    }
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
            .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)
            .transition(.readerPanelReveal)
    }

    private var loadingView: some View {
        AppStateMessageCard(
            title: L10n.string("reader.pdf.loading.title"),
            systemImage: "doc.richtext",
            description: L10n.string("reader.pdf.loading.description")
        ) {
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.s6)
    }

    private func errorView(_ message: String) -> some View {
        ScrollView {
            VStack {
                Spacer(minLength: AppSpacing.s7)

                AppEmptyStateCard(
                    title: "無法開啟 PDF".localized,
                    systemImage: "exclamationmark.triangle",
                    description: message,
                    action: AppEmptyStateAction(
                        title: "重試載入".localized,
                        systemImage: "arrow.clockwise",
                        handler: retryLoad
                    )
                )
                .padding(.horizontal, AppShellMetrics.pageHorizontalPadding)

                Spacer(minLength: AppSpacing.s7)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - PDFKitRepresentable

private struct PDFKitRepresentable: UIViewRepresentable {
    let document: PDFDocument
    let book: Book
    let modelContext: ModelContext
    let progressSaver: ReaderProgressSaver
    let onWordSelected: (String, String) -> Void
    let onPhraseSelected: (String, String) -> Void
    let onExplainSelected: (String, String) -> Void

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical

        // Restore last read position
        restorePosition(in: pdfView)

        registerObservers(for: pdfView, coordinator: context.coordinator)
        let menuInteraction = installEditMenu(on: pdfView, coordinator: context.coordinator)
        context.coordinator.pdfView = pdfView
        context.coordinator.menuInteraction = menuInteraction

        return pdfView
    }

    private func registerObservers(for pdfView: PDFView, coordinator: Coordinator) {
        // Page change notification for progress saving
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.pageDidChange(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        // Listen for selection changes to show menu
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.selectionDidChange(_:)),
            name: .PDFViewSelectionChanged,
            object: pdfView
        )
    }

    private func installEditMenu(on pdfView: PDFView, coordinator: Coordinator) -> UIEditMenuInteraction {
        // Add edit menu interaction for vocabulary capture
        let menuInteraction = UIEditMenuInteraction(delegate: coordinator)
        pdfView.addInteraction(menuInteraction)
        return menuInteraction
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        // No dynamic updates needed
    }

    static func dismantleUIView(_ pdfView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            book: book,
            modelContext: modelContext,
            progressSaver: progressSaver,
            onWordSelected: onWordSelected,
            onPhraseSelected: onPhraseSelected,
            onExplainSelected: onExplainSelected
        )
    }

    private func restorePosition(in pdfView: PDFView) {
        guard let json = book.lastReadLocatorJSON,
              let data = json.data(using: .utf8),
              let position = try? JSONDecoder().decode(PDFPosition.self, from: data),
              let page = document.page(at: position.pageIndex)
        else {
            AppLog.reader.debug("PDF position restore skipped (no/invalid saved position)")
            return
        }
        pdfView.go(to: page)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UIEditMenuInteractionDelegate {
        let book: Book
        let modelContext: ModelContext
        let progressSaver: ReaderProgressSaver
        let onWordSelected: (String, String) -> Void
        let onPhraseSelected: (String, String) -> Void
        let onExplainSelected: (String, String) -> Void
        weak var pdfView: PDFView?
        weak var menuInteraction: UIEditMenuInteraction?

        init(
            book: Book,
            modelContext: ModelContext,
            progressSaver: ReaderProgressSaver,
            onWordSelected: @escaping (String, String) -> Void,
            onPhraseSelected: @escaping (String, String) -> Void,
            onExplainSelected: @escaping (String, String) -> Void
        ) {
            self.book = book
            self.modelContext = modelContext
            self.progressSaver = progressSaver
            self.onWordSelected = onWordSelected
            self.onPhraseSelected = onPhraseSelected
            self.onExplainSelected = onExplainSelected
        }

        // MARK: - Progress Saving

        @objc func pageDidChange(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document,
                  let pageIndex = document.index(for: currentPage) as Int?
            else { return }

            let book = book
            let modelContext = modelContext
            PDFProgressRecorder(
                book: book,
                saver: progressSaver,
                persist: {
                    if modelContext.safeSave() {
                        BookManifestStore().writeBestEffort(book: book)
                    }
                }
            ).pageChanged(pageIndex: pageIndex, pageCount: document.pageCount)
        }

        // MARK: - Selection → Vocabulary

        @objc func selectionDidChange(_ notification: Notification) {
            guard let pdfView,
                  let selection = pdfView.currentSelection,
                  let text = selection.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }

            // Show edit menu near selection
            if let page = selection.pages.first,
               let menuInteraction {
                let selectionBounds = selection.bounds(for: page)
                let viewRect = pdfView.convert(selectionBounds, from: page)
                let config = UIEditMenuConfiguration(
                    identifier: "vocabMenu" as NSString,
                    sourcePoint: CGPoint(
                        x: viewRect.midX,
                        y: viewRect.minY
                    )
                )
                menuInteraction.presentEditMenu(with: config)
            }
        }

        // MARK: - UIEditMenuInteractionDelegate

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            let translateAction = UIAction(
                title: "翻譯".localized,
                image: UIImage(systemName: "character.book.closed")
            ) { [weak self] _ in
                self?.triggerTranslate()
            }
            let explainAction = UIAction(
                title: "解釋".localized,
                image: UIImage(systemName: "text.bubble")
            ) { [weak self] _ in
                self?.triggerExplain()
            }

            // Keep system actions (Copy, etc.) and prepend our vocab actions,
            // mirroring EPUB's edit-menu「翻譯」/「解釋」pair.
            return UIMenu(children: [translateAction, explainAction] + suggestedActions)
        }

        /// 「翻譯」:依選取的 token 數分流 —— 單詞走 word path(sanitize + 詞庫
        /// dedup/儲存,plain context);多詞走 phrase path(marked context),
        /// 對齊 EPUB 的 tap=word / selection=phrase 語意。
        private func triggerTranslate() {
            guard let pdfView,
                  let selection = pdfView.currentSelection,
                  let raw = selection.string
            else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            if ReaderWordCapture.isPhraseSelection(raw) {
                let context = extractContext(for: selection, in: pdfView, marked: true)
                pdfView.clearSelection()
                Task { @MainActor in onPhraseSelected(trimmed, context) }
            } else {
                guard let word = ReaderWordCapture.sanitizeSelectedWord(raw) else { return }
                let context = extractContext(for: selection, in: pdfView, marked: false)
                pdfView.clearSelection()
                Task { @MainActor in onWordSelected(word, context) }
            }
        }

        /// 「解釋」:對單詞或片語皆送 marked context 給 explanation flow
        /// (不入詞庫),對齊 EPUB 的 aiExplain。
        private func triggerExplain() {
            guard let pdfView,
                  let selection = pdfView.currentSelection,
                  let raw = selection.string
            else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let context = extractContext(for: selection, in: pdfView, marked: true)
            pdfView.clearSelection()
            Task { @MainActor in onExplainSelected(trimmed, context) }
        }

        private func extractContext(
            for selection: PDFSelection,
            in pdfView: PDFView,
            marked: Bool
        ) -> String {
            guard let page = selection.pages.first,
                  let pageText = page.string
            else { return selection.string ?? "" }

            // 用 PDFKit 提供的「實際選取字元範圍」定位上下文,而非以
            // selection.string 在頁面字串中 range(of:) 抓首個 match。
            // 後者對頁面中後段重複出現的常見詞(如 "the")會取到頁首
            // 的上下文造成偏移。rangeAtIndex:onPage: 回傳的 NSRange 是
            // 對 page.string 的字元索引,與這裡用的 pageText 一致。
            guard let selectionRange = pageTextRange(for: selection, on: page, in: pageText) else {
                // Fallback:API 取不到範圍(極少數情況)時退回字串搜尋,
                // 仍優於回傳裸選取詞。
                return fallbackContext(selectedText: selection.string ?? "", in: pageText, marked: marked)
            }

            return PDFReaderContext.window(around: selectionRange, in: pageText, marked: marked)
        }

        /// 將 PDFSelection 在指定 page 上的實際字元範圍(NSRange,對 page.string)
        /// 轉成 Swift `Range<String.Index>`。多段選取時取「最前 lowerBound ~
        /// 最後 upperBound」的涵蓋範圍,使上下文窗以實際選取位置為中心。
        private func pageTextRange(
            for selection: PDFSelection,
            on page: PDFPage,
            in pageText: String
        ) -> Range<String.Index>? {
            let rangeCount = selection.numberOfTextRanges(on: page)
            guard rangeCount > 0 else { return nil }

            var minLocation = Int.max
            var maxEnd = Int.min
            for index in 0..<rangeCount {
                let nsRange = selection.range(at: index, on: page)
                guard nsRange.location != NSNotFound, nsRange.length >= 0 else { continue }
                minLocation = min(minLocation, nsRange.location)
                maxEnd = max(maxEnd, nsRange.location + nsRange.length)
            }
            guard minLocation != Int.max, maxEnd >= minLocation else { return nil }

            // NSRange 對的是 NSString(UTF-16)索引,轉回 Swift String.Index
            // 需經 UTF-16 視圖,避免 emoji / 組合字偏移。
            let coveringNSRange = NSRange(location: minLocation, length: maxEnd - minLocation)
            return Range(coveringNSRange, in: pageText)
        }

        private func fallbackContext(selectedText: String, in pageText: String, marked: Bool) -> String {
            guard !selectedText.isEmpty, let range = pageText.range(of: selectedText) else {
                return selectedText
            }
            return PDFReaderContext.window(around: range, in: pageText, marked: marked)
        }
    }
}

// MARK: - Preview

#Preview("PDF Reader — Loading") {
    AppThemeContainer {
        PDFReaderView(book: .init(title: "Sample PDF", author: "Author", fileName: "sample.pdf", format: .pdf))
            .modelContainer(for: [Book.self, VocabularyEntry.self], inMemory: true)
    }
    .environmentObject(AppAppearanceStore.preview)
}
#endif
