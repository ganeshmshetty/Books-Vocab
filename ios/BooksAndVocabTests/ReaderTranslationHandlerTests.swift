#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Behavior tests for `ReaderTranslationHandler` — exercising the synchronous
/// helpers (`autoSaveToVocabulary`, `guestSaveToVocabulary`, `normalizeWord`,
/// `deleteFromVocabulary`) and the async `handleWordSelected` flow with an
/// injected mock service. The async paths are awaited via the handler's
/// `currentTranslationTask` so assertions run after the task settles.
@MainActor
struct ReaderTranslationHandlerTests {

    // MARK: - Mocks

    private final class MockTranslating: Translating {
        var quickResult: Result<TranslationResult, Error> = .failure(MockError.notConfigured)
        var phraseResult: Result<String, Error> = .failure(MockError.notConfigured)
        var explanationResult: Result<(String, TimeInterval), Error> = .failure(MockError.notConfigured)
        var quickCalls = 0
        var phraseCalls = 0
        var explanationCalls = 0
        var triggerQuickRetry = false
        var beforeQuickRetry: (() async -> Void)?
        var afterQuickRetry: (() async -> Void)?
        var beforeExplanation: (() async -> Void)?

        func translateQuick(word: String, context: String, onRetry: (@Sendable (Int, Int) async -> Void)?) async throws -> TranslationResult {
            quickCalls += 1
            if triggerQuickRetry {
                await beforeQuickRetry?()
                await onRetry?(1, 3)
                await afterQuickRetry?()
            }
            return try quickResult.get()
        }
        func translatePhrase(phrase: String, context: String, onRetry: (@Sendable (Int, Int) async -> Void)?) async throws -> String {
            phraseCalls += 1
            return try phraseResult.get()
        }
        func fetchExplanation(word: String, context: String, onRetry: (@Sendable (Int, Int) async -> Void)?) async throws -> (explanation: String, latency: TimeInterval) {
            explanationCalls += 1
            await beforeExplanation?()
            return try explanationResult.get()
        }
    }

    @MainActor
    private final class MockAuth: AuthManaging {
        var isLoggedIn: Bool
        init(isLoggedIn: Bool) { self.isLoggedIn = isLoggedIn }

        var userId: String? = nil
        var token: String? = nil
        var displayName: String? = nil
        var userEmail: String? = nil
        var avatarURL: URL? = nil
        var authError: String? = nil
        var isAuthenticating: Bool = false
        var isDemoMode: Bool = false

        func enterDemoMode(modelContainer: ModelContainer) {}
        func exitDemoMode(modelContainer: ModelContainer) {}
        func refreshSessionIfNeeded() {}
        func login(userId: String, token: String) {}
        func login(customToken: String) async {}
        func logout(modelContainer: ModelContainer?, reason: String) {}
        func logoutAfterAccountDeletion(modelContainer: ModelContainer?, deletedAccountID: String?) {}
        func loginWithGoogle(modelContainer: ModelContainer?) {}
        func loginWithApple(modelContainer: ModelContainer?) {}
    }

    @MainActor
    private final class MockVocabContext: VocabularyContextProtocol {
        var notebookId: String = "test_nb"
        var existing: VocabularyEntry?
        var existingResolver: ((String) -> VocabularyEntry?)?
        var savedSelections: [WordSelection] = []
        var savedTranslations: [String] = []
        var savedRootForms: [String?] = []
        var deletedWords: [String] = []
        var saveReturn: Bool = true

        func existingEntry(matching word: String) -> VocabularyEntry? {
            if let existingResolver {
                return existingResolver(word)
            }
            return existing
        }
        func deleteEntry(matching word: String) { deletedWords.append(word) }
        func saveEntry(selection: WordSelection, translation: String, rootForm: String?) -> Bool {
            savedSelections.append(selection)
            savedTranslations.append(translation)
            savedRootForms.append(rootForm)
            return saveReturn
        }
    }

    private enum MockError: Error, LocalizedError {
        case notConfigured
        case canned(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "mock not configured"
            case .canned(let s): return s
            }
        }
    }

    // MARK: - Helpers

    private func makeHandler(
        loggedIn: Bool = true,
        service: MockTranslating = MockTranslating(),
        retryStatusFormatter: ((Int, Int) -> String)? = nil
    ) -> ReaderTranslationHandler {
        ReaderTranslationHandler(
            translationService: service,
            authManager: MockAuth(isLoggedIn: loggedIn),
            retryStatusFormatter: retryStatusFormatter
        )
    }

    /// Drives the handler's most-recent in-flight task to completion before
    /// asserting. Returns once the task has finished (or immediately if none).
    private func drain(_ handler: ReaderTranslationHandler) async {
        await handler.currentTranslationTask?.value
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool, maxYields: Int = 1_000) async -> Bool {
        for _ in 0..<maxYields {
            if predicate() {
                return true
            }
            await Task.yield()
        }
        return predicate()
    }

    // MARK: - normalizeWord

    @Test func normalizeWord_trimsWhitespaceAndPrecomposesCompat() {
        let handler = makeHandler()
        #expect(handler.normalizeWord("  hello  ") == "hello")
        #expect(handler.normalizeWord("\nworld\t") == "world")
        // ﬃ (U+FB03) precomposes/decomposes to "ffi" under compatibility mapping.
        #expect(handler.normalizeWord("oﬃce") == "office")
    }

    // Capture-normalize contract: trailing sentence punctuation `.,;:!?` is
    // stripped at selection time (podcast UITextView / PDF PDFKit both keep it
    // raw), matching backend `_clean_content`. Word-internal punctuation and
    // letter case are preserved; leading punctuation is left untouched.
    @Test func normalizeWord_stripsTrailingSentencePunctuation() {
        let handler = makeHandler()
        #expect(handler.normalizeWord("code.") == "code")
        #expect(handler.normalizeWord("end?!") == "end")
        #expect(handler.normalizeWord("really,") == "really")
        #expect(handler.normalizeWord("wait;") == "wait")
        #expect(handler.normalizeWord("note:") == "note")
        #expect(handler.normalizeWord("  spaced.  ") == "spaced", "trailing punctuation strip composes with whitespace trim")
        // Preserved: word-internal punctuation, case, leading punctuation.
        #expect(handler.normalizeWord("don't") == "don't")
        #expect(handler.normalizeWord("well-known,") == "well-known")
        #expect(handler.normalizeWord("Code.") == "Code", "case is NOT folded — lowercasing is backend dedup's job")
    }

    // MARK: - autoSaveToVocabulary

    @Test func autoSaveToVocabulary_skipsSaveWhenEntryExistsAndNotDeleted() {
        let handler = makeHandler()
        let ctx = MockVocabContext()
        ctx.existing = VocabularyEntry(
            word: "alpha",
            translation: "已存在",
            context: "",
            explanation: nil,
            partOfSpeech: nil,
            bookTitle: "B",
            chapterTitle: "C"
        )

        handler.autoSaveToVocabulary(
            selection: WordSelection(word: "alpha", context: "ctx", position: .zero),
            result: TranslationResult(translation: "new", partOfSpeech: nil, explanation: nil),
            context: ctx
        )

        #expect(ctx.savedSelections.isEmpty, "existing non-deleted entry must NOT trigger another save")
        #expect(handler.isSaved == true)
        #expect(handler.lookedUpWords.contains("alpha"), "even on existing entry, the word should be tracked as looked-up")
    }

    @Test func autoSaveToVocabulary_callsSaveWhenNoExisting_andRecordsRootForm() {
        let handler = makeHandler()
        let ctx = MockVocabContext()
        var result = TranslationResult(translation: "新", partOfSpeech: nil, explanation: nil)
        result.rootForm = "rooted"

        handler.autoSaveToVocabulary(
            selection: WordSelection(word: "Beta", context: "ctx", position: .zero),
            result: result,
            context: ctx
        )

        #expect(ctx.savedSelections.count == 1)
        #expect(ctx.savedTranslations.first == "新")
        #expect(ctx.savedRootForms.first == "rooted")
        #expect(handler.isSaved == true)
        #expect(handler.lookedUpWords.contains("beta"), "looked-up tracking must be lowercased")
    }

    // MARK: - guestSaveToVocabulary

    @Test func guestSaveToVocabulary_passesEmptyTranslationAndMarksSaved() {
        let handler = makeHandler(loggedIn: false)
        let ctx = MockVocabContext()
        handler.guestSaveToVocabulary(
            selection: WordSelection(word: "gamma", context: "ctx", position: .zero),
            context: ctx
        )
        #expect(ctx.savedSelections.count == 1)
        #expect(ctx.savedTranslations.first == "", "guest path must save with empty translation — server fills it on login")
        #expect(handler.isSaved == true)
    }

    // MARK: - handleWordSelected — existing entry fast path

    @Test func handleWordSelected_loadsFromExistingEntryWithoutCallingService() async {
        let service = MockTranslating()
        let handler = makeHandler(service: service)
        let ctx = MockVocabContext()
        ctx.existing = VocabularyEntry(
            word: "delta",
            translation: "預存翻譯",
            context: "",
            explanation: nil,
            partOfSpeech: nil,
            bookTitle: "B",
            chapterTitle: "C"
        )

        handler.handleWordSelected(word: "delta", context: "some ctx", vocabularyContext: ctx)
        // No task is spawned on the fast path; drain is a no-op.
        await drain(handler)

        #expect(service.quickCalls == 0, "existing entry must short-circuit before hitting the translation service")
        #expect(handler.translationResult?.translation == "預存翻譯")
        #expect(handler.isSaved == true)
        #expect(handler.isTranslating == false)
        // Full state-reset contract: fast path must clear ANY prior expanded /
        // explanation / error state so the panel renders cleanly.
        #expect(handler.isExpanded == false)
        #expect(handler.explanationText == nil)
        #expect(handler.translationErrorMessage == nil)
        #expect(handler.explanationErrorMessage == nil)
    }

    @Test func handleWordSelected_normalizesBeforeExistingEntryLookup() async {
        let service = MockTranslating()
        let handler = makeHandler(service: service)
        let ctx = MockVocabContext()
        ctx.existingResolver = { word in
            guard word == "delta" else { return nil }
            return VocabularyEntry(
                word: "delta",
                translation: "預存翻譯",
                context: "",
                explanation: nil,
                partOfSpeech: nil,
                bookTitle: "B",
                chapterTitle: "C"
            )
        }

        handler.handleWordSelected(word: "delta.", context: "some ctx", vocabularyContext: ctx)
        await drain(handler)

        #expect(service.quickCalls == 0, "normalized existing entry must still short-circuit before hitting the translation service")
        #expect(handler.translationResult?.translation == "預存翻譯")
        #expect(handler.wordSelection?.word == "delta", "selection should store the normalized word for downstream save/delete flows")
    }

    // MARK: - handleWordSelected — guest path

    @Test func handleWordSelected_guestPath_savesViaContextWhenNotLoggedIn() async {
        let service = MockTranslating()
        let handler = makeHandler(loggedIn: false, service: service)
        let ctx = MockVocabContext()

        handler.handleWordSelected(word: "epsilon", context: "ctx", vocabularyContext: ctx)
        await drain(handler)

        #expect(service.quickCalls == 0, "guest tap must NOT hit the translation service")
        #expect(service.phraseCalls == 0, "guest tap must NOT hit phrase service either")
        #expect(service.explanationCalls == 0, "guest tap must NOT prefetch explanation")
        #expect(ctx.savedSelections.count == 1)
        #expect(ctx.savedTranslations.first == "")
        #expect(handler.isSaved == true)
        #expect(handler.lookedUpWords.contains("epsilon"), "guest save must still track looked-up state for reader underlining")
    }

    // MARK: - handleWordSelected — fresh translate + autoSave

    @Test func handleWordSelected_freshTranslate_autoSavesOnSuccess() async {
        let service = MockTranslating()
        service.quickResult = .success(TranslationResult(translation: "rendered", partOfSpeech: nil, explanation: nil))
        let handler = makeHandler(service: service)
        let ctx = MockVocabContext()

        handler.handleWordSelected(word: "zeta", context: "ctx", vocabularyContext: ctx)
        await drain(handler)

        #expect(service.quickCalls == 1)
        #expect(handler.translationResult?.translation == "rendered")
        #expect(handler.isTranslating == false)
        #expect(handler.translationErrorMessage == nil)
        #expect(ctx.savedTranslations.first == "rendered", "fresh translate path must auto-save through the protocol")
        #expect(handler.isSaved == true, "autoSave must flip isSaved so the panel renders the saved state")
        #expect(handler.lookedUpWords.contains("zeta"), "fresh save must also track looked-up state for reader underlining")
    }

    @Test func handleWordSelected_selectionChangedDuringYield_savesCapturedSelectionOnly() async {
        let service = MockTranslating()
        service.quickResult = .success(TranslationResult(translation: "A-translation", partOfSpeech: nil, explanation: nil))
        let handler = makeHandler(service: service)
        let ctx = MockVocabContext()

        handler.handleWordSelected(word: "alpha", context: "ctx", vocabularyContext: ctx)
        let shown = await waitUntil { handler.translationResult != nil }
        #expect(shown)
        // Task is parked on its post-success yield; user taps word B now.
        handler.wordSelection = WordSelection(word: "bravo", context: "ctx", position: .zero)
        await drain(handler)

        #expect(!ctx.savedSelections.contains { $0.word == "bravo" }, "A's translation must never be saved against B's selection")
        #expect(ctx.savedSelections.map(\.word) == ["alpha"])
        #expect(ctx.savedTranslations == ["A-translation"])
    }

    @Test func handleWordSelected_clearsPreviousExplanationLoadingState() async {
        let service = MockTranslating()
        service.explanationResult = .success(("explanation", 0.1))
        service.quickResult = .success(TranslationResult(translation: "translation", partOfSpeech: nil, explanation: nil))
        var releaseExplanation: CheckedContinuation<Void, Never>?
        service.beforeExplanation = {
            await withCheckedContinuation { continuation in
                releaseExplanation = continuation
            }
        }
        let handler = makeHandler(service: service)
        let ctx = MockVocabContext()

        handler.handleExplainSelected(text: "a sentence", context: "ctx")
        #expect(await waitUntil { releaseExplanation != nil })

        handler.handleWordSelected(word: "fresh", context: "ctx", vocabularyContext: ctx)

        #expect(handler.isLoadingExplanation == false,
                "switching selection must not leave the new word blocked by the previous explanation request")
        #expect(handler.isTranslating == true)

        releaseExplanation?.resume()
        await drain(handler)

        #expect(handler.translationResult?.translation == "translation")
        #expect(handler.isLoadingExplanation == false)
    }

    @Test func handleWordSelected_retryStatus_surfacesWhileTaskIsActive() async {
        let service = MockTranslating()
        service.triggerQuickRetry = true
        service.quickResult = .success(TranslationResult(translation: "rendered", partOfSpeech: nil, explanation: nil))
        var releaseRetry: CheckedContinuation<Void, Never>?
        var releaseResult: CheckedContinuation<Void, Never>?
        service.beforeQuickRetry = {
            await withCheckedContinuation { continuation in
                releaseRetry = continuation
            }
        }
        service.afterQuickRetry = {
            await withCheckedContinuation { continuation in
                releaseResult = continuation
            }
        }
        let handler = makeHandler(
            service: service,
            retryStatusFormatter: { attempt, total in "retry-status-\(attempt)-of-\(total)" }
        )
        let ctx = MockVocabContext()

        handler.handleWordSelected(word: "retry", context: "ctx", vocabularyContext: ctx)
        #expect(await waitUntil { releaseRetry != nil })
        releaseRetry?.resume()
        #expect(await waitUntil { handler.statusMessage == "retry-status-1-of-3" })

        #expect(handler.statusMessage == "retry-status-1-of-3")
        #expect(await waitUntil { releaseResult != nil })
        releaseResult?.resume()
        await drain(handler)
    }

    @Test func retryStatusCopy_usesExplicitLanguageWithoutMutatingGlobalSelection() {
        #expect(
            ReaderTranslationCopy.retryStatus(
                attempt: 1,
                total: 3,
                language: .traditionalChinese
            ) == "正在重試 (1/3)..."
        )
    }

    @Test func handleWordSelected_cancelledRetry_doesNotWriteStatus() async {
        let service = MockTranslating()
        service.triggerQuickRetry = true
        service.quickResult = .success(TranslationResult(translation: "rendered", partOfSpeech: nil, explanation: nil))
        var releaseRetry: CheckedContinuation<Void, Never>?
        service.beforeQuickRetry = {
            await withCheckedContinuation { continuation in
                releaseRetry = continuation
            }
        }
        let handler = makeHandler(service: service)
        let ctx = MockVocabContext()

        handler.handleWordSelected(word: "cancel", context: "ctx", vocabularyContext: ctx)
        #expect(await waitUntil { releaseRetry != nil })
        let task = handler.currentTranslationTask
        handler.cancelCurrentTranslationTask()
        releaseRetry?.resume()
        await task?.value

        #expect(handler.statusMessage == nil)
    }

    // MARK: - handleWordSelected — failure path

    @Test func handleWordSelected_setsErrorMessageOnTranslationFailure() async {
        let service = MockTranslating()
        service.quickResult = .failure(MockError.canned("boom"))
        let handler = makeHandler(service: service)
        let ctx = MockVocabContext()

        handler.handleWordSelected(word: "eta", context: "ctx", vocabularyContext: ctx)
        await drain(handler)

        #expect(service.quickCalls == 1, "failure must have come from the awaited service call, not a setup short-circuit")
        #expect(handler.translationResult == nil)
        #expect(handler.isTranslating == false)
        #expect(handler.translationErrorMessage != nil)
        #expect(handler.translationErrorMessage?.contains("boom") == true,
                "failure message must surface the underlying error description")
        #expect(ctx.savedSelections.isEmpty, "failed translate must NOT auto-save anything")
    }

    // MARK: - handlePhraseSelected — success

    @Test func handlePhraseSelected_freshTranslate_autoSavesWhenContextProvided() async {
        let service = MockTranslating()
        service.phraseResult = .success("片語譯文")
        let handler = makeHandler(service: service)
        let ctx = MockVocabContext()

        handler.handlePhraseSelected(phrase: "in due course", context: "...", vocabularyContext: ctx)
        await drain(handler)

        #expect(service.phraseCalls == 1)
        #expect(service.quickCalls == 0, "phrase tap must NOT hit the single-word path")
        #expect(handler.translationResult?.translation == "片語譯文")
        #expect(handler.isTranslating == false)
        #expect(handler.translationErrorMessage == nil)
        #expect(ctx.savedSelections.count == 1)
        #expect(ctx.savedSelections.first?.word == "in due course",
                "phrase WordSelection must preserve the full phrase text (no normalization)")
        #expect(ctx.savedTranslations.first == "片語譯文")
        #expect(handler.isSaved == true)
    }

    @Test func handlePhraseSelected_skipsAutoSaveWhenContextOmitted() async {
        let service = MockTranslating()
        service.phraseResult = .success("translated")
        let handler = makeHandler(service: service)

        // Nil vocabularyContext — phrase translation must still render, but
        // there is nowhere to save it.
        handler.handlePhraseSelected(phrase: "ad hoc", context: "...", vocabularyContext: nil)
        await drain(handler)

        #expect(service.phraseCalls == 1)
        #expect(handler.translationResult?.translation == "translated")
        #expect(handler.isSaved == false,
                "no vocabContext provided → no autoSave path → isSaved must remain false")
    }

    @Test func retryLastLookup_afterExplanationFailure_retriesOnlyExplanationAndStaysExpanded() async {
        let service = MockTranslating()
        service.quickResult = .success(TranslationResult(translation: "t", partOfSpeech: nil, explanation: nil))
        service.explanationResult = .failure(MockError.canned("boom"))
        let handler = makeHandler(service: service)
        let ctx = MockVocabContext()

        handler.handleWordSelected(word: "eta", context: "ctx", vocabularyContext: ctx)
        await drain(handler)
        handler.handleExpand()
        await drain(handler)
        #expect(handler.explanationErrorMessage != nil)
        #expect(service.explanationCalls == 1)

        service.explanationResult = .success(("explained", 0.1))
        handler.retryLastLookup(vocabularyContext: ctx)
        #expect(handler.isExpanded == true, "retry must not collapse the panel")
        await drain(handler)

        #expect(service.quickCalls == 1, "retry must not re-run the word translation")
        #expect(service.explanationCalls == 2)
        #expect(handler.isExpanded == true)
        #expect(handler.explanationText == "explained")
        #expect(handler.explanationErrorMessage == nil)
    }

    // MARK: - deleteFromVocabulary

    @Test func deleteFromVocabulary_callsContextDeleteAndDismisses() {
        let handler = makeHandler()
        let ctx = MockVocabContext()
        // Pre-populate selection so we can verify dismiss() clears it.
        handler.wordSelection = WordSelection(word: "theta", context: "ctx", position: .zero)
        handler.isSaved = true

        handler.deleteFromVocabulary("theta", context: ctx)

        #expect(ctx.deletedWords == ["theta"])
        #expect(handler.wordSelection == nil, "delete must trigger dismiss()")
        #expect(handler.isSaved == false)
    }
}
#endif
