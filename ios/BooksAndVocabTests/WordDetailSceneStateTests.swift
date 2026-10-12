import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
struct WordDetailSceneStateTests {

    @Test func refreshPresentation_buildsPresenterState() {
        let entry = makeEntry(cardId: "root-card", word: "meticulous")
        let peer = makeEntry(cardId: "peer-card", word: "precise")
        entry.insertLink(
            KGCardLinkSummary(
                id: "link-1",
                cardId: "peer-card",
                word: "precise",
                kind: "shares_usage",
                label: "相關",
                confidence: 0.8,
                reason: "seed"
            ),
            kind: "shares_usage"
        )

        let state = WordDetailSceneState()
        state.refreshPresentation(for: entry, in: [entry, peer])

        #expect(state.presenterState?.title == "meticulous")
        #expect(state.presenterState?.navigableLinkCardIDs == ["peer-card"])
    }

    @Test func refreshPresentation_usesPausedReviewClockForStatusAndProgress() {
        let now = Date()
        let pausedAt = now.addingTimeInterval(-2 * 60 * 60)
        let entry = makeEntry(cardId: "root-card", word: "meticulous")
        entry.syncStatus = VocabularySyncState.synced.rawValue
        entry.reviewCount = 1
        entry.lastReviewedAt = pausedAt
        entry.nextReviewAt = now.addingTimeInterval(-60 * 60)

        let store = ReviewSettingsStore.shared
        store.activateAccount(nil)
        let originalPause = store.pauseClockSnapshot
        defer { store.restorePauseState(originalPause) }

        var pausedSettings = store.settings
        pausedSettings.isProgressPaused = true
        pausedSettings.progressPausedAt = pausedAt
        store.update(pausedSettings)

        #expect(store.settings.isProgressPaused)
        #expect(store.settings.progressPausedAt == pausedAt)
        #expect(store.settings.reviewReferenceDate(now: now) == pausedAt)

        let state = WordDetailSceneState()
        state.refreshPresentation(for: entry, in: [entry])

        #expect(state.presenterState?.reviewProgress?.statusLabel == L10n.string("已複習"))
        #expect(state.presenterState?.reviewProgress?.ratio == 0)
    }

    @Test func linkedEntry_resolvesPeerFromAllEntries() {
        let entry = makeEntry(cardId: "root-card", word: "meticulous")
        let peer = makeEntry(cardId: "peer-card", word: "precise")
        let link = KGCardLinkSummary(
            id: "link-1",
            cardId: "peer-card",
            word: "precise",
            kind: "shares_usage",
            label: "相關",
            confidence: 0.8,
            reason: "seed"
        )

        let state = WordDetailSceneState()
        let resolved = state.linkedEntry(for: link, from: entry, in: [entry, peer])

        #expect(resolved === peer)
    }

    @Test func dismissActionError_clearsBannerState() {
        let state = WordDetailSceneState()
        state.actionError = "error"

        state.dismissActionError()

        #expect(state.actionError == nil)
    }

    // MARK: - Archive

    @Test func setArchived_flipsEntryAndCallsServiceWithNotebookScope() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        context.insert(entry)

        let spy = SpyKGService()
        let state = WordDetailSceneState()

        await state.setArchived(true, for: entry, kgService: spy, modelContext: context)

        #expect(entry.isArchived)
        #expect(spy.archiveCalls == [.init(word: "abate", archived: true, notebookId: "nb-1")])
        #expect(state.actionError == nil)
        #expect(context.hasChanges == false, "成功路徑要把樂觀值落磁碟")
    }

    /// 共用 banner 只寫不清，失敗訊息會活過後續的成功動作：封存失敗 → 再按一次成功 →
    /// 圖示已翻成已封存，banner 卻還掛著「封存失敗」。
    @Test func setArchived_clearsPreviousErrorOnRetrySuccess() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        context.insert(entry)

        let spy = SpyKGService()
        spy.archiveCardHandler = { _ in throw TestFailure.offline }
        let state = WordDetailSceneState()

        await state.setArchived(true, for: entry, kgService: spy, modelContext: context)
        #expect(state.actionError != nil)

        spy.archiveCardHandler = { _ in }
        await state.setArchived(true, for: entry, kgService: spy, modelContext: context)

        #expect(entry.isArchived)
        #expect(state.actionError == nil, "成功後必須清掉上一次的失敗訊息")
    }

    /// `guard previous != archived` 是一句行為宣告，沒有測試釘住就只是註解。
    @Test func setArchived_noopsWhenAlreadyInTargetState() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        entry.isArchived = true
        context.insert(entry)

        let spy = SpyKGService()
        let state = WordDetailSceneState()

        await state.setArchived(true, for: entry, kgService: spy, modelContext: context)

        #expect(spy.archiveCalls.isEmpty, "已在目標狀態不該打伺服器")
        #expect(entry.isArchived)
    }

    @Test func setArchived_false_unarchivesTheEntry() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        entry.isArchived = true
        context.insert(entry)

        let spy = SpyKGService()
        let state = WordDetailSceneState()

        await state.setArchived(false, for: entry, kgService: spy, modelContext: context)

        #expect(entry.isArchived == false)
        #expect(spy.archiveCalls == [.init(word: "abate", archived: false, notebookId: "nb-1")])
    }

    /// 封存需連線。伺服器拒絕時，樂觀翻轉必須完整回捲——否則本機顯示「已封存」
    /// 但伺服器上沒有，下次 pull 會把它翻回來，使用者看到卡片自己復活。
    @Test func setArchived_rollsBackAndReportsWhenServiceFails() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        context.insert(entry)

        let spy = SpyKGService()
        spy.archiveCardHandler = { _ in throw TestFailure.offline }
        let state = WordDetailSceneState()

        await state.setArchived(true, for: entry, kgService: spy, modelContext: context)

        // archiveCalls 的斷言不可省：少了它，這個測試對一個「從不做樂觀翻轉、也從不呼叫
        // 伺服器，只負責寫 actionError」的實作同樣會綠——因為期望的終態剛好等於初始態。
        #expect(spy.archiveCalls == [.init(word: "abate", archived: true, notebookId: "nb-1")])
        #expect(entry.isArchived == false)
        #expect(state.actionError != nil)
    }

    @Test func setArchived_rollsBackToArchivedWhenUnarchiveFails() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        entry.isArchived = true
        context.insert(entry)

        let spy = SpyKGService()
        spy.archiveCardHandler = { _ in throw TestFailure.offline }
        let state = WordDetailSceneState()

        await state.setArchived(false, for: entry, kgService: spy, modelContext: context)

        #expect(spy.archiveCalls == [.init(word: "abate", archived: false, notebookId: "nb-1")])
        #expect(entry.isArchived)
        #expect(state.actionError != nil)
    }

    /// CAS 的「不回捲」分支：await 期間背景 pull 帶回權威值（值已不等於我們的樂觀寫入），
    /// 此時回捲會用舊值蓋掉新鮮值且不再推送。用 handler 在拋錯前改值即可確定性驅動。
    @Test func setArchived_doesNotRollBackWhenValueChangedDuringFlight() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        context.insert(entry)

        let spy = SpyKGService()
        spy.archiveCardHandler = { _ in
            // 模擬背景 pull 在 in-flight 期間寫入權威值 false
            entry.isArchived = false
            throw TestFailure.offline
        }
        let state = WordDetailSceneState()

        await state.setArchived(true, for: entry, kgService: spy, modelContext: context)

        #expect(entry.isArchived == false, "值已被他人改動時不可回捲")
        #expect(state.actionError != nil)
    }

    /// CAS 的「要回捲」分支，並補上 commit message 稱為「載重側」的持久化斷言。
    @Test func setArchived_rollbackPersistsWhenValueUntouched() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        context.insert(entry)

        let spy = SpyKGService()
        spy.archiveCardHandler = { _ in throw TestFailure.offline }
        let state = WordDetailSceneState()

        await state.setArchived(true, for: entry, kgService: spy, modelContext: context)

        #expect(entry.isArchived == false)
        #expect(context.hasChanges == false, "回捲側要把樂觀值從磁碟撤下來")
    }

    /// 跨領域：連結操作留下的錯誤**不可**被一次成功的封存抹掉——連結失敗會靜靜回捲，
    /// 那則訊息是使用者唯一的解釋；封存的成功則自帶圖示回饋。
    @Test func setArchived_successDoesNotClearLinkError() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        context.insert(entry)

        let spy = SpyKGService()
        let state = WordDetailSceneState()
        state.actionError = "刪除連結失敗"   // 模擬 link writer 留下的訊息（kind = nil，非 .archive）

        await state.setArchived(true, for: entry, kgService: spy, modelContext: context)

        #expect(entry.isArchived)
        #expect(state.actionError == "刪除連結失敗", "封存成功不得吃掉別類動作的錯誤")
    }

    // MARK: - Per-card preferences

    @Test func setCardPreferences_updatesBothFlagsWithoutChangingReviewState() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        entry.markSynced()
        entry.reviewCount = 4
        entry.reviewStreak = 3
        let originalNextReview = entry.nextReviewAt
        context.insert(entry)

        let spy = PreferenceSpy()
        let state = WordDetailSceneState()

        await state.setCardPreferences(
            readerHidden: true,
            reviewExcluded: true,
            for: entry,
            kgService: spy,
            modelContext: context
        )

        #expect(spy.calls == [.init(word: "abate", readerHidden: true, reviewExcluded: true, notebookId: "nb-1")])
        #expect(entry.isReaderHidden)
        #expect(entry.isReviewExcluded)
        #expect(entry.reviewCount == 4)
        #expect(entry.reviewStreak == 3)
        #expect(entry.nextReviewAt == originalNextReview)
        #expect(state.actionError == nil)
        #expect(context.hasChanges == false)
    }

    @Test func setCardPreferences_rollsBackUntouchedOptimisticValuesOnFailure() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.markSynced()
        context.insert(entry)

        let spy = PreferenceSpy()
        spy.error = TestFailure.offline
        let state = WordDetailSceneState()

        await state.setCardPreferences(
            readerHidden: true,
            reviewExcluded: nil,
            for: entry,
            kgService: spy,
            modelContext: context
        )

        #expect(entry.isReaderHidden == false)
        #expect(entry.isReviewExcluded == false)
        #expect(state.actionError != nil)
        #expect(context.hasChanges == false)
    }

    @Test func setCardPreferences_doesNotRollbackValueChangedDuringRequest() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.markSynced()
        context.insert(entry)

        let spy = PreferenceSpy()
        spy.beforeFailure = { entry.isReaderHidden = false }
        spy.error = TestFailure.offline
        let state = WordDetailSceneState()

        await state.setCardPreferences(
            readerHidden: true,
            reviewExcluded: nil,
            for: entry,
            kgService: spy,
            modelContext: context
        )

        #expect(entry.isReaderHidden == false, "背景 pull 改過的值不可被舊 request 回捲")
        #expect(state.actionError != nil)
    }

    @Test func setCardPreferences_doesNotProjectUnchangedFieldFromFullResponse() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.markSynced()
        entry.isReviewExcluded = true
        context.insert(entry)

        let spy = PreferenceSpy()
        // The server response is a full card, but this reader-only request must
        // not project a stale review preference over the local value.
        spy.responseReviewExcluded = false
        let state = WordDetailSceneState()

        await state.setCardPreferences(
            readerHidden: true,
            reviewExcluded: nil,
            for: entry,
            kgService: spy,
            modelContext: context
        )

        #expect(entry.isReaderHidden)
        #expect(entry.isReviewExcluded, "an independent preference must not be overwritten by a stale full-card response")
    }

    @Test func setCardPreferences_doesNotProjectStaleSameFieldResponseAfterPull() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.markSynced()
        context.insert(entry)

        let spy = PreferenceSpy()
        spy.responseReaderHidden = true
        // Simulate a pull installing a newer value while the request is in flight.
        spy.beforeResponse = { entry.isReaderHidden = false }
        let state = WordDetailSceneState()

        await state.setCardPreferences(
            readerHidden: true,
            reviewExcluded: nil,
            for: entry,
            kgService: spy,
            modelContext: context
        )

        #expect(entry.isReaderHidden == false, "a newer pull value must not be overwritten by the stale response")
    }

    // MARK: - In-flight hooks must stay on the main thread (#2166)

    /// 這條家族的 hook 會在 in-flight 期間改 `@Model` 實體（模擬背景 pull）。hook 若跑在
    /// cooperative pool 執行緒，就是跨執行緒寫 SwiftData 物件，與 main thread 上並行測試的
    /// `VocabularyEntry` 建立競爭，造成偶發 `Already have an objectID registered` trap。
    /// 競態本身不可確定性重現，所以釘住它的**前提**：hook 一律在 main thread 執行。
    @Test func setCardPreferences_inFlightHooksRunOnMainThread() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.markSynced()
        context.insert(entry)

        var hookThreads: [Bool] = []
        let spy = PreferenceSpy()
        spy.beforeFailure = { hookThreads.append(Thread.isMainThread) }
        spy.beforeResponse = { hookThreads.append(Thread.isMainThread) }
        let state = WordDetailSceneState()

        await state.setCardPreferences(
            readerHidden: true,
            reviewExcluded: nil,
            for: entry,
            kgService: spy,
            modelContext: context
        )

        #expect(hookThreads == [true, true], "in-flight hook 必須在 main thread 跑，才不會跨執行緒碰 SwiftData 物件")
    }

    @Test func setArchived_inFlightHandlerRunsOnMainThread() async throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "abate")
        entry.notebookId = "nb-1"
        context.insert(entry)

        var handlerThreads: [Bool] = []
        let spy = SpyKGService()
        spy.archiveCardHandler = { _ in handlerThreads.append(Thread.isMainThread) }
        let state = WordDetailSceneState()

        await state.setArchived(true, for: entry, kgService: spy, modelContext: context)

        #expect(handlerThreads == [true], "in-flight handler 必須在 main thread 跑，才不會跨執行緒碰 SwiftData 物件")
    }

    // MARK: - Helpers

    private enum TestFailure: Error {
        case offline
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Book.self,
            VocabularyEntry.self,
            ReviewRecord.self,
            Notebook.self,
            PodcastSeries.self,
            PodcastEpisode.self,
            PodcastProgress.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    /// #3125: Word Detail must show the collocation explanations written in review.
    @Test func refreshPresentation_exposesCollocationExplanations() {
        let entry = makeEntry(cardId: "root-card", word: "meticulous")
        entry.collocationExplanations = ["take shape": "become clear gradually"]

        let state = WordDetailSceneState()
        state.refreshPresentation(for: entry, in: [entry])

        #expect(state.presenterState?.collocationExplanations == ["take shape": "become clear gradually"])
    }

    /// #3125: 解釋 on Word Detail persists through the same field review writes.
    @Test func updateCollocationExplanation_persistsAndClearsOnEntry() throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "meticulous")
        context.insert(entry)

        let state = WordDetailSceneState()
        state.updateCollocationExplanation("be precise", for: "take shape", entry: entry, modelContext: context)
        #expect(entry.collocationExplanations["take shape"] == "be precise")

        state.updateCollocationExplanation(nil, for: "take shape", entry: entry, modelContext: context)
        #expect(entry.collocationExplanations["take shape"] == nil)
    }

    @Test func updateCollocationExplanation_restoresPreviousValueWhenSaveFails() throws {
        let context = try makeContext()
        let entry = makeEntry(cardId: "root-card", word: "meticulous")
        entry.collocationExplanations = ["take shape": "舊解釋"]
        context.insert(entry)

        let state = WordDetailSceneState()
        state.updateCollocationExplanation(
            "新解釋",
            for: "take shape",
            entry: entry,
            modelContext: context,
            save: { _ in false }
        )

        #expect(entry.collocationExplanations["take shape"] == "舊解釋", "存檔失敗後不可保留未存的新解釋")
        #expect(state.actionError != nil)
    }

    @Test func metadataLinkCount_usesPluralKey() {
        let entry = makeEntry(cardId: "root-card", word: "meticulous")
        entry.insertLink(
            KGCardLinkSummary(
                id: "link-1",
                cardId: "peer-card",
                word: "precise",
                kind: "shares_usage",
                label: "相關",
                confidence: 0.8,
                reason: "seed"
            ),
            kind: "shares_usage"
        )

        let state = WordDetailPresentation.state(for: entry, in: [entry], lookup: [:], now: Date())

        let expected = L10n.format("vocab_graph_link_count_plural", Int64(1))
        #expect(state.metadataItems.contains { $0.text == expected })
        #expect(!state.metadataItems.contains { $0.text == L10n.format("%@ 個連結", "1") })
    }

    private func makeEntry(cardId: String, word: String) -> VocabularyEntry {
        let entry = VocabularyEntry(
            word: word,
            translation: "\(word)-translation",
            context: "\(word) context",
            bookTitle: "Book"
        )
        entry.kgCardId = cardId
        return entry
    }
}

/// `@MainActor` 是載重的（#2166）：`beforeFailure` / `beforeResponse` 會在 in-flight 期間改動
/// `@Model` 實體以模擬背景 pull。若此類別是非隔離的，`async` 方法會被 hop 到 global executor，
/// hook 就在 cooperative pool 執行緒上寫 SwiftData 物件，與 main thread 上其他測試建立
/// `VocabularyEntry` 競爭 temporary identifier 註冊表，偶發
/// `SwiftData/ModelCoders.swift:723: Fatal error: Already have an objectID registered`（signal trap）。
@MainActor
private final class PreferenceSpy: CardPreferenceUpdating {
    struct Call: Equatable {
        let word: String
        let readerHidden: Bool?
        let reviewExcluded: Bool?
        let notebookId: String
    }

    private(set) var calls: [Call] = []
    var error: Error?
    var beforeFailure: (() -> Void)?
    var beforeResponse: (() -> Void)?
    var responseReaderHidden: Bool?
    var responseReviewExcluded: Bool?

    func updateCardPreferences(
        word: String,
        readerHidden: Bool?,
        reviewExcluded: Bool?,
        notebookId: String
    ) async throws -> KGCard {
        calls.append(.init(
            word: word,
            readerHidden: readerHidden,
            reviewExcluded: reviewExcluded,
            notebookId: notebookId
        ))
        if let beforeFailure { beforeFailure() }
        if let error { throw error }
        beforeResponse?()

        let json = """
        {"id":"card-1","content":"\(word)","meaning":"meaning","mode":"recognition",
         "isDeleted":false,"isArchived":false,
        "isReaderHidden":\(responseReaderHidden ?? readerHidden ?? false),"isReviewExcluded":\(responseReviewExcluded ?? reviewExcluded ?? false)}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(KGCard.self, from: json)
    }
}
