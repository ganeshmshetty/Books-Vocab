#if os(iOS)
import SwiftUI
import TipKit
import os

extension ReaderTranslationHandler {
    private func resetTranslationFields() {
        translationResult = nil
        isSaved = false
        isExpanded = false
        isPanelLarge = false
        explanationText = nil
        isLoadingExplanation = false
        explanationStatus = nil
        translationErrorMessage = nil
        explanationErrorMessage = nil
    }

    private func handleTranslationFailure(_ error: Error, log: Bool) {
        if log {
            AppLog.reader.error("翻譯錯誤: \(error.localizedDescription)")
        }
        translationResult = nil
        isTranslating = false
        translationStatus = nil
        translationErrorMessage = L10n.format("翻譯失敗：%@", error.localizedDescription)
    }

    func handleWordSelected(
        word: String,
        context: String,
        vocabularyContext: any VocabularyContextProtocol
    ) {
        cancelCurrentTranslationTask()
        let normalizedWord = normalizeWord(word)
        let selection = WordSelection(word: normalizedWord, context: context, position: .zero)
        wordSelection = selection
        lastLookup = LastLookup(kind: .word, text: word, context: context)

        if let existing = vocabularyContext.existingEntry(matching: normalizedWord),
           existing.syncAction != .delete {
            withAnimation(AppMotion.panelState) {
                translationResult = TranslationResult(
                    translation: existing.translation,
                    partOfSpeech: nil,
                    explanation: nil
                )
                isSaved = true
                isTranslating = false
                isExpanded = false
                isPanelLarge = false
                explanationText = nil
                explanationStatus = nil
                translationErrorMessage = nil
                explanationErrorMessage = nil
            }
            PerfLog.reader.mark("reader.translation.shown", "source=library")
            AppLog.reader.debug("從生詞庫載入: \(normalizedWord) → \(existing.word)")
            return
        }

        if !authManager.isLoggedIn {
            withAnimation(AppMotion.panelState) {
                isTranslating = false
                resetTranslationFields()
            }
            guestSaveToVocabulary(
                selection: selection,
                context: vocabularyContext
            )
            return
        }

        withAnimation(AppMotion.panelState) {
            isTranslating = true
            resetTranslationFields()
        }

        runLookupTask(
            statusChannel: .translation,
            operation: { [translationService] onRetry in
                try await translationService.translateQuick(
                    word: word,
                    context: context,
                    onRetry: onRetry
                )
            },
            onSuccess: { [self] result in
                withAnimation(AppMotion.feedbackPulse) {
                    translationResult = result
                    isTranslating = false
                    translationStatus = nil
                    translationErrorMessage = nil
                }
                PerfLog.reader.mark("reader.translation.shown", "source=network")
                await Task.yield()
                autoSaveToVocabulary(
                    selection: selection,
                    result: result,
                    context: vocabularyContext
                )
                await LongPressTip.wordLookedUp.donate()
                LongPressTip().invalidate(reason: .actionPerformed)
            },
            onFailure: { [self] error in
                handleTranslationFailure(error, log: true)
            }
        )
    }

    func handlePhraseSelected(
        phrase: String,
        context: String,
        vocabularyContext: (any VocabularyContextProtocol)? = nil
    ) {
        cancelCurrentTranslationTask()
        let selection = WordSelection(word: phrase, context: context, position: .zero)
        wordSelection = selection
        lastLookup = LastLookup(kind: .phrase, text: phrase, context: context)

        // Mirrors handleWordSelected: a guest cannot translate, so the phrase is
        // saved locally instead of calling the API (which would fail and leave
        // the guest card stuck on「正在記錄…」).
        if !authManager.isLoggedIn {
            withAnimation(AppMotion.panelState) {
                isTranslating = false
                resetTranslationFields()
            }
            if let vocabularyContext {
                guestSaveToVocabulary(selection: selection, context: vocabularyContext)
            }
            return
        }

        withAnimation(AppMotion.panelState) {
            isTranslating = true
            resetTranslationFields()
        }

        runLookupTask(
            statusChannel: .translation,
            operation: { [translationService] onRetry in
                let translation = try await translationService.translatePhrase(
                    phrase: phrase,
                    context: context,
                    onRetry: onRetry
                )
                return TranslationResult(
                    translation: translation,
                    partOfSpeech: nil,
                    explanation: nil
                )
            },
            onSuccess: { [self] result in
                withAnimation(AppMotion.feedbackPulse) {
                    translationResult = result
                    isTranslating = false
                    translationStatus = nil
                    translationErrorMessage = nil
                }
                await Task.yield()
                if let vocabularyContext {
                    autoSaveToVocabulary(
                        selection: selection,
                        result: result,
                        context: vocabularyContext
                    )
                }
            },
            onFailure: { [self] error in
                handleTranslationFailure(error, log: true)
            }
        )
    }

    func handleExplainSelected(text: String, context: String) {
        cancelCurrentTranslationTask()
        let selection = WordSelection(word: text, context: context, position: .zero)
        wordSelection = selection
        lastLookup = LastLookup(kind: .explain, text: text, context: context)

        withAnimation(AppMotion.panelState) {
            isTranslating = false
            translationResult = nil
            isSaved = false
            isExpanded = true
            isPanelLarge = true
            isLoadingExplanation = true
            explanationText = nil
            translationStatus = nil
            translationErrorMessage = nil
            explanationErrorMessage = nil
        }

        runLookupTask(
            statusChannel: .explanation,
            operation: { [translationService] onRetry in
                try await translationService.fetchExplanation(
                    word: text,
                    context: context,
                    onRetry: onRetry
                )
            },
            onSuccess: { [self] explanation, _ in
                withAnimation(AppMotion.feedbackPulse) {
                    explanationText = explanation
                    isLoadingExplanation = false
                    explanationStatus = nil
                    explanationErrorMessage = nil
                }
            },
            onFailure: { [self] error in
                AppLog.reader.error("解釋錯誤: \(error.localizedDescription)")
                explanationText = nil
                isLoadingExplanation = false
                explanationStatus = nil
                explanationErrorMessage = L10n.format("載入失敗：%@", error.localizedDescription)
            }
        )
    }

    /// 重試最近一次失敗的翻譯／解釋。等同於使用者再點一次原本的單字／片語／explain。
    /// 注意：phrase 與 word 都需要 `vocabularyContext` 才能 autoSave；如未提供則僅執行翻譯但不存庫。
    func retryLastLookup(vocabularyContext: (any VocabularyContextProtocol)? = nil) {
        guard let last = lastLookup else { return }
        switch last.kind {
        case .word:
            // 解釋失敗（翻譯已成功）→ 只重跑解釋，保持大卡展開；不重走整個查詞流程。
            if explanationErrorMessage != nil, translationErrorMessage == nil,
               authManager.isLoggedIn, let selection = wordSelection {
                withAnimation(AppMotion.panelState) {
                    isExpanded = true
                    isPanelLarge = true
                }
                loadExplanation(for: selection)
                return
            }
            guard let ctx = vocabularyContext else { return }
            handleWordSelected(word: last.text, context: last.context, vocabularyContext: ctx)
        case .phrase:
            handlePhraseSelected(phrase: last.text, context: last.context, vocabularyContext: vocabularyContext)
        case .explain:
            handleExplainSelected(text: last.text, context: last.context)
        }
    }

    /// 單字模式：展開／收合語境解釋。展開＝放大成大卡並抓取語境解釋，收合＝縮回小卡。
    /// panel 高度與 `isExpanded` 連動（語意統一為「看更多＝變大」）。
    func handleExpand() {
        withAnimation(AppMotion.panelState) {
            isExpanded.toggle()
            isPanelLarge = isExpanded
        }

        guard authManager.isLoggedIn, isExpanded, !isLoadingExplanation,
              let selection = wordSelection else { return }

        loadExplanation(for: selection)
    }

    private func loadExplanation(for selection: WordSelection) {
        explanationText = nil
        isLoadingExplanation = true
        translationStatus = nil
        explanationStatus = nil
        explanationErrorMessage = nil

        runLookupTask(
            statusChannel: .explanation,
            operation: { [translationService] onRetry in
                try await translationService.fetchExplanation(
                    word: selection.word,
                    context: selection.context,
                    onRetry: onRetry
                )
            },
            onSuccess: { [self] explanation, latency in
                withAnimation(AppMotion.feedbackPulse) {
                    explanationText = explanation
                    isLoadingExplanation = false
                    explanationStatus = nil
                    explanationErrorMessage = nil
                    if var updatedResult = translationResult {
                        updatedResult.latency = latency
                        translationResult = updatedResult
                    }
                }
            },
            onFailure: { [self] error in
                AppLog.reader.error("解釋錯誤: \(error.localizedDescription)")
                explanationText = nil
                isLoadingExplanation = false
                explanationStatus = nil
                explanationErrorMessage = L10n.format("載入失敗：%@", error.localizedDescription)
            }
        )
    }

    /// 句子（explanationOnly）模式：純粹切換面板高度（大卡 ⇄ 小卡），
    /// 不觸碰 `isExpanded`，以免 `isExplanationOnly` 判定塌陷成空狀態。
    func togglePanelHeight() {
        withAnimation(AppMotion.panelState) {
            isPanelLarge.toggle()
        }
    }
}
#endif
