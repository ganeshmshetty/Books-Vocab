import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// `backgroundSync` 的進度回報縫，以及它底下那段從來沒有測試守著的失敗分類。
///
/// 兩件事被釘在這裡：
///
/// 1. **事件對映是純函式。** 每一列的終態（done / skipped / error）與說明文字都由
///    `KGService` 的 static helper 決定，測試直接餵 `Result` 進去看事件出來，
///    不必跑一輪真同步。這也是唯一能窮舉「取消不畫紅叉」這類分支的辦法。
/// 2. **`processSyncPhase` 的三條分支**——401 短路、取消不算失敗、部分失敗聚合——
///    在此之前一個測試都沒有。它決定使用者看到「登入已過期」、「背景同步部分失敗」
///    還是什麼都不看到，卻只靠人眼守著。
@MainActor
struct KGServiceSyncReportingTests {

    private final class RecordingInvalidator: SessionInvalidating {
        private(set) var events: [String] = []
        func logout(modelContainer: ModelContainer?, reason: String) {
            events.append("logout_\(reason)")
        }
        func waitForPendingLocalDataCleanup() async {
            events.append("wait_for_cleanup")
        }
    }

    private final class NilTokenSession: AuthSessionProviding {
        var isLoggedIn: Bool { true }
        var token: String? { nil }
    }

    /// 空 in-memory 容器：push payload 為空不打網路；pull 在取得 token 前就因
    /// nil token 走 unauthorized 早退 —— 全程無真網路呼叫。
    private static func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try! ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            PodcastSeries.self, PodcastEpisode.self,
            configurations: config
        )
    }

    private static func makeService() -> (KGService, RecordingInvalidator) {
        let invalidator = RecordingInvalidator()
        let service = KGService(authSession: NilTokenSession(), sessionInvalidator: invalidator)
        return (service, invalidator)
    }

    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    // MARK: - 步驟宣告

    @Test("宣告的步驟清單與實際會跑的段落一致，podcast 只在 flag 開時出現")
    func stepIDsFollowFeatureFlag() {
        #expect(KGService.syncStepIDs(podcastEnabled: false) == [.push, .pull, .reviewEvents])
        #expect(KGService.syncStepIDs(podcastEnabled: true) == [.push, .pull, .reviewEvents, .podcast])
    }

    @Test("宣告清單不含 .status —— 那一列由設定頁的 resync 自己補，不屬於 backgroundSync")
    func stepIDsExcludeStatusLeg() {
        #expect(!KGService.syncStepIDs(podcastEnabled: true).contains(.status))
    }

    // MARK: - 說明文字

    @Test("無變更時明講「已是最新」，不留白")
    func pullDetailSpellsOutNoChange() {
        #expect(KGService.pullDetail(inserted: 0, updated: 0, deleted: 0) == L10n.string("已是最新"))
    }

    @Test("有變更時三種變動一起計數")
    func pullDetailCountsEveryKindOfChange() {
        let detail = KGService.pullDetail(inserted: 2, updated: 3, deleted: 1)
        #expect(detail == L10n.format("同步 %@ 筆", "6"))
        #expect(detail != L10n.string("已是最新"))
    }

    @Test("push 的筆數含 skipped —— 只算 updated/inserted 的話，伺服器全判重複的重送會顯示 0 筆")
    func pushDetailCountsSkippedToo() {
        // 複習紀錄重送那個 bug 的真實形狀：送出 9,580 筆，伺服器全部去重。
        let repush = KGService.pushDetail(states: (updated: 0, skipped: 0), events: (inserted: 0, skipped: 9580))
        #expect(repush == L10n.format("已送出 %@ 筆", "9580"),
                "這一列的存在意義就是讓這種重送現形")
        #expect(KGService.pushDetail(states: (updated: 4, skipped: 1), events: (inserted: 7, skipped: 2))
            == L10n.format("已送出 %@ 筆", "14"))
    }

    // MARK: - 事件對映

    @Test("成功 → done")
    func successMapsToDone() {
        let event = KGService.legFinishedEvent(.reviewEvents, result: .success(()), detail: "d")
        #expect(event == .finished(.reviewEvents, status: .done, detail: "d"))
    }

    @Test("取消 → skipped，不畫紅叉")
    func cancellationMapsToSkipped() {
        let event = KGService.legFinishedEvent(
            .reviewEvents, result: Result<Void, Error>.failure(CancellationError()), detail: "d"
        )
        #expect(event == .finished(.reviewEvents, status: .skipped, detail: ""))
    }

    @Test("真失敗 → error，並帶上錯誤描述")
    func failureMapsToError() {
        let event = KGService.legFinishedEvent(
            .reviewEvents, result: Result<Void, Error>.failure(Boom()), detail: "d"
        )
        // 期望值寫成 L10n key 的值而不是 `reason(for:)` 的回傳——後者兩邊呼叫同一支，
        // 那支回空字串或原始 key 時測試照樣綠。Boom 是未知型別 → reason.unknown。
        #expect(event == .finished(.reviewEvents, status: .error,
                                   detail: L10n.string("sync.failure.reason.unknown")),
                "detail 必須走本地化的 reason，不是 error.localizedDescription（那會吐英文系統字串）")
    }

    @Test("push 兩腿都成功才寫筆數")
    func pushFinishedCountsOnlyWhenBothSucceed() {
        let event = KGService.pushFinishedEvent(
            states: .success((updated: 2, skipped: 0)),
            events: .success((inserted: 5, skipped: 1))
        )
        #expect(event == .finished(.push, status: .done, detail: L10n.format("已送出 %@ 筆", "8")))
    }

    @Test("push 任一腿失敗就整列失敗——兩個位置分別驗，避免只守住其中一個")
    func pushFinishedFailsWhenEitherLegFails() {
        let statesFailed = KGService.pushFinishedEvent(
            states: .failure(Boom()),
            events: .success((inserted: 5, skipped: 0))
        )
        #expect(statesFailed == .finished(.push, status: .error,
                                          detail: L10n.string("sync.failure.reason.unknown")))

        let eventsFailed = KGService.pushFinishedEvent(
            states: .success((updated: 2, skipped: 0)),
            events: .failure(Boom())
        )
        #expect(eventsFailed == .finished(.push, status: .error,
                                          detail: L10n.string("sync.failure.reason.unknown")))
    }

    @Test("podcast 四種結果各自對映；flag 關著（nil）不得畫成失敗")
    func podcastOutcomeMapping() {
        #expect(KGService.podcastFinishedEvent(.completed) == .finished(.podcast, status: .done, detail: ""))
        #expect(KGService.podcastFinishedEvent(nil) == .finished(.podcast, status: .done, detail: ""))
        #expect(KGService.podcastFinishedEvent(.cancelled) == .finished(.podcast, status: .skipped, detail: ""))
        #expect(KGService.podcastFinishedEvent(.listFetchFailed)
            == .finished(.podcast, status: .error, detail: L10n.string("目錄讀取失敗")))
    }

    @Test("podcast background progress exposes running and list-fetch warning")
    func podcastBackgroundProgressMapsToUserVisibleStatus() {
        let store = PodcastBackgroundSyncStatusStore()

        store.apply(.started(.podcast))
        #expect(store.status == .running)

        store.apply(.finished(.podcast, status: .error, detail: L10n.string("目錄讀取失敗")))
        #expect(store.status == .warning(L10n.string("目錄讀取失敗")))
    }

    @Test("a new background sync round clears the previous podcast warning")
    func newBackgroundSyncRoundClearsPreviousPodcastWarning() {
        let store = PodcastBackgroundSyncStatusStore()

        store.apply(.started(.podcast))
        store.apply(.finished(.podcast, status: .error, detail: L10n.string("目錄讀取失敗")))
        store.apply(.started(.push))

        #expect(store.status == .idle)
    }

    // MARK: - processSyncPhase：401 / 取消 / 部分失敗

    @Test("401 回 nil 通知 caller 直接 return，並把訊息換成「登入已過期」")
    func unauthorizedShortCircuits() async {
        let (service, _) = Self.makeService()
        let outcome = await service.processSyncPhase(
            results: [.failure(KGError.unauthorized)],
            labels: ["pull"],
            container: Self.makeContainer()
        )
        #expect(outcome == nil, "401 必須讓 backgroundSync 立刻 return，而不是繼續跑後面的 phase")
        #expect(service.lastBackgroundSyncError == L10n.string("登入已過期"))
    }

    @Test("取消不算失敗，但也不算成功：記在 cancelled、不進 failures")
    func cancellationIsNeitherSuccessNorFailure() async {
        let (service, _) = Self.makeService()
        let outcome = await service.processSyncPhase(
            results: [.failure(CancellationError())],
            labels: ["pull"],
            container: Self.makeContainer()
        )
        #expect(outcome?.cancelled == true)
        #expect(outcome?.failures.isEmpty == true, "取消若被計為失敗，離開畫面就會彈「背景同步部分失敗」")
        #expect(service.lastBackgroundSyncError == nil)
    }

    @Test("部分失敗只收真正失敗的那幾腿，成功的不入列")
    func partialFailureAggregatesOnlyRealFailures() async {
        let (service, _) = Self.makeService()
        let outcome = await service.processSyncPhase(
            results: [.success(()), .failure(Boom()), .failure(CancellationError())],
            labels: ["pushReview", "pull", "pullReviewEvents"],
            container: Self.makeContainer()
        )
        #expect(outcome?.failures.map(\.label) == ["pull"])
        // reason 只帶「為什麼失敗」，不帶操作名前綴；彙總時操作名由 label 另外組。
        #expect(outcome?.failures.map(\.reason) == [SyncFailurePresentation.reason(for: Boom())])
        #expect(outcome?.cancelled == true)
    }

    @Test("部分失敗的 production 組裝點：兩腿同原因只說一次，且不寫死 ASCII \", \"")
    func partialFailureComposesSameReasonOnceAtProductionSite() {
        let (service, _) = Self.makeService()
        let language = AppLanguage.traditionalChinese
        let reason = SyncFailurePresentation.reason(
            for: KGError.httpError(statusCode: 503, detail: ""),
            language: language
        )
        let failures = [
            KGService.SyncPhaseFailure(label: "pushReview", reason: reason),
            KGService.SyncPhaseFailure(label: "pushReviewEvents", reason: reason),
        ]
        service.recordPartialFailure(failures, language: language)

        let expected = SyncFailurePresentation.partialFailureSummary(
            failures.map { (label: $0.label, reason: $0.reason) },
            language: language
        )
        #expect(service.lastBackgroundSyncError == expected)
        #expect(service.lastBackgroundSyncError?.components(separatedBy: reason).count == 2,
                "同一原因重複列出：\(service.lastBackgroundSyncError ?? "nil")")
        #expect(service.lastBackgroundSyncError?.contains(", ") == false,
                "仍用 ASCII 逗號分隔：\(service.lastBackgroundSyncError ?? "nil")")
    }

    @Test("401 壓過同一批裡的其他失敗——先看到的失敗不得讓 401 被吞掉")
    func unauthorizedWinsOverOtherFailures() async {
        let (service, _) = Self.makeService()
        let outcome = await service.processSyncPhase(
            results: [.failure(Boom()), .failure(KGError.unauthorized)],
            labels: ["pushReview", "pull"],
            container: Self.makeContainer()
        )
        #expect(outcome == nil)
        #expect(service.lastBackgroundSyncError == L10n.string("登入已過期"))
    }

    // MARK: - 端到端：縫真的接上了

    @Test("未登入跑一輪：reporter 收到開場與終態事件，順序與實際執行一致")
    func reporterReceivesEventsFromARealRound() async throws {
        // `backgroundSync` 在離線時什麼事件都不發就 return（那是刻意的：離線不該
        // 產生錯誤日誌）。斷網的 runner 上這條測試會穩定失敗而且看起來像真 bug，
        // 所以明講前提而不是假裝沒有。本測試零網路呼叫——`currentAuthToken()` 在
        // 組出任何 URLRequest 之前就因 nil token 丟 unauthorized，兩條 push 腿也
        // 因空 payload 早退——它只需要 reachability 是 true。
        try #require(NetworkMonitor.shared.isConnected, "此測試需要 reachability 為 true（不打網路，只是 backgroundSync 的離線 guard 會先擋下整輪）")
        let (service, _) = Self.makeService()
        // reporter 從非結構化 Task 被呼叫，收集器必須自帶同步。
        let collector = EventCollector()
        await service.backgroundSync(container: Self.makeContainer()) { event in
            collector.record(event)
        }
        let events = collector.snapshot()

        #expect(events.first == .started(.push), "第一件事必須是 push 開跑，實際：\(events)")
        #expect(events.contains(.started(.pull)))
        #expect(events.contains(.started(.reviewEvents)))
        // nil token → pull 走 unauthorized；.pull 必須拿到終態，
        // 否則該列會永遠停在轉圈。
        #expect(events.contains { if case .finished(.pull, .error, _) = $0 { return true }; return false },
                "pull 失敗後沒有補發終態，UI 會卡在 running：\(events)")
        // podcast 這一輪不該有任何事件。擋住它的**不是** 401 早退（那條腿現在從
        // 整輪最前面就起跑），而是 runPodcastLeg 自己的 token guard——NilTokenSession
        // 沒有 token。這也是本測試零網路的原因；有人日後給這個 harness 一個真 token，
        // 它就會開始打真的 GET /api/podcasts。
        #expect(!events.contains { if case .started(.podcast) = $0 { return true }; return false })
    }

    @Test("只實作單參數版的既有 conformer，經協定呼叫雙參數版仍會被叫到")
    func legacyConformerStillReceivesTheCall() async {
        // 這是「縫的形狀」唯一會無聲壞掉的環節：若日後把雙參數版移出協定，
        // 呼叫會靜態綁到 extension default，所有只實作單參數版的 mock 就此收不到
        // ——而每個 mock 的 body 都是空的，沒有任何測試會變紅。
        final class OneArgOnly: BackgroundSyncing {
            var lastBackgroundSyncError: String?
            private(set) var calls = 0
            func backgroundSync(container: ModelContainer) async { calls += 1 }
        }
        let legacy = OneArgOnly()
        let syncing: any BackgroundSyncing = legacy
        await syncing.backgroundSync(container: Self.makeContainer(), progress: { _ in })
        #expect(legacy.calls == 1, "protocol extension 的預設實作必須轉呼單參數版")
    }

    @Test("不傳 reporter 的既有 caller 一切照舊")
    func legacyCallerStillWorksWithoutReporter() async {
        let (service, invalidator) = Self.makeService()
        await service.backgroundSync(container: Self.makeContainer())
        #expect(invalidator.events.first == "wait_for_cleanup")
    }
}

/// `backgroundSync` 的 reporter 會從多個 child task 呼叫。用鎖包住陣列，
/// 否則這個測試自己就是 data race——而 race 的測試會以「偶爾綠」的形式說謊。
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SyncProgressEvent] = []

    func record(_ event: SyncProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [SyncProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
