//
//  KGService+Sync.swift
//  Books & Vocab
//

import Foundation
import SwiftData

enum PodcastBackgroundSyncStatus: Equatable, Sendable {
    case idle
    case running
    case warning(String)
}

/// Bridges the automatic app-level sync reporter to the Podcast home.
///
/// This is intentionally separate from `SyncProgressStore`: the latter belongs to
/// the user-initiated Settings sync sheet, while this small status is the only
/// state the Podcast tab needs from post-login/scenePhase syncs.
@Observable
final class PodcastBackgroundSyncStatusStore: @unchecked Sendable {
    static let shared = PodcastBackgroundSyncStatusStore()

    private(set) var status: PodcastBackgroundSyncStatus = .idle

    @MainActor
    func apply(_ event: SyncProgressEvent) {
        switch event {
        case .started(.push):
            // A new round supersedes a previous catalog warning. The Podcast leg
            // may still be waiting for its turn, so keep the tab otherwise quiet.
            status = .idle
        case .started(.podcast):
            status = .running
        case .finished(.podcast, let stepStatus, let detail):
            switch stepStatus {
            case .error:
                status = .warning(detail.isEmpty ? L10n.string("同步失敗") : detail)
            default:
                status = .idle
            }
        default:
            break
        }
    }

    /// Reporter passed only by automatic app-level sync triggers. The main-actor
    /// hop keeps `@Observable` mutation out of the sync executor.
    static let report: SyncProgressReporting = { event in
        Task { @MainActor in
            shared.apply(event)
        }
    }
}

#if DEBUG
private enum SettingsResetFailureInjector {
    // Scope the once-token to this app process. A persistent fixed key made a
    // later UI run skip the injector after an earlier run had consumed it.
    private static let consumedKey = "kg.ui.test.settings.reset.\(ProcessInfo.processInfo.globallyUniqueString)"

    static func consumeIfRequested(reason: String) -> Bool {
        guard reason == "settings_reset_local_data",
              ProcessInfo.processInfo.environment["KG_UI_TEST_SETTINGS_RESET_FAIL_ONCE"] == "1",
              !UserDefaults.standard.bool(forKey: consumedKey)
        else { return false }

        UserDefaults.standard.set(true, forKey: consumedKey)
        return true
    }
}

private struct SettingsResetInjectedFailure: LocalizedError {
    var errorDescription: String? { "UI test injected local reset failure" }
}
#endif

// MARK: - Sync

extension KGService {


    // MARK: - Push Review State

    func pushReviewStates(container: ModelContainer) async throws -> (updated: Int, skipped: Int) {
        let actor = BackgroundSyncActor(modelContainer: container)
        // Captured before the payload is built so a review landing mid-request
        // stays dirty rather than being acknowledged as already-sent.
        let boundary = Date()
        let payload = try await actor.buildReviewStatePushPayload()
        guard !payload.isEmpty else { return (0, 0) }

        struct PushResponse: Decodable {
            let updated: Int
            let skipped: Int
        }
        let result = try await authenticatedDecode(
            PushResponse.self,
            path: "api/vocab/review",
            method: "PATCH",
            body: try JSONSerialization.data(withJSONObject: ["entries": payload])
        )
        try await actor.markReviewStatesPushed(upTo: boundary)
        AppLog.kg.info("pushReviewStates: sent=\(payload.count), updated=\(result.updated), skipped=\(result.skipped)")
        return (result.updated, result.skipped)
    }

    // MARK: - Offline KG Sync logic

    /// Pull server cards into the local store, serialized against other pulls.
    ///
    /// Two properties this wrapper buys, both of which the bare implementation
    /// lacked:
    ///
    /// 1. **Serialization.** A pull waits for any pull already in flight before
    ///    issuing its own `GET /api/vocab`, so no two requests go out carrying
    ///    the same `?since=` cursor and the same payload is never merged twice.
    ///    Every caller still gets its own request — see `KGService.enqueuePull`
    ///    for why sharing one response would be wrong.
    ///
    /// 2. **Immunity to view lifecycle.** The work runs in an unstructured `Task`,
    ///    which inherits priority and actor context but *not* cancellation. A pull
    ///    started from `.task`/`.refreshable` therefore survives the view being
    ///    torn down or re-rendered mid-flight. That teardown used to cancel the
    ///    in-flight `URLSession` request, surface `-999` as "網路錯誤：已取消", and
    ///    throw away a sync that had already paid for its round trip.
    ///
    /// The caller's own cancellation is honoured at the boundary instead: callers
    /// that go away stop waiting (see the `Task.checkCancellation` in
    /// `KGVocabCoordinator`), while the sync itself runs to completion.
    ///
    /// `notebookId` picks one of two different operations:
    /// - `nil` — the global sync: owns `SyncKeys.incrementalBoundary` and the
    ///   payload-version upgrade, and a full sync reaps orphans.
    /// - non-nil — a notebook-scoped projection (AddLink): a drained read of that
    ///   notebook merged without orphan cleanup, never reading or writing the
    ///   global cursor. See `performNotebookScopedPull` (#2102).
    @discardableResult
    func pullCardsToLocal(container: ModelContainer, progress: ((String, Int, Int) -> Void)? = nil, notebookId: String? = nil) async throws -> KGPullOutcome {
        try await pullCardsToLocal(
            container: container, progress: progress, notebookId: notebookId, reporter: nil
        )
    }

    /// `pullCardsToLocal` 加上逐步進度回報。
    ///
    /// `reporter` 沒有預設值：它與上面那支三參數版構成 overload，給了預設值會讓
    /// 兩者在只傳 container 時互相打架。`defaults` 是 sync cursor 的存放處，只有
    /// 測試會換掉它（隔離 `.standard`）。
    @discardableResult
    func pullCardsToLocal(
        container: ModelContainer,
        progress: ((String, Int, Int) -> Void)?,
        notebookId: String?,
        reporter: SyncProgressReporting?,
        defaults: UserDefaults = .standard
    ) async throws -> KGPullOutcome {
        let task = enqueuePull { predecessor, pullID in
            Task {
                defer { self.finishPull(id: pullID) }
                // Wait out the predecessor, but never inherit its fate: a failed
                // or cancelled earlier pull must not fail this one. `result`
                // swallows both outcomes by construction.
                _ = await predecessor?.result
                if let notebookId {
                    return try await self.performNotebookScopedPull(
                        container: container, progress: progress,
                        notebookId: notebookId, reporter: reporter, defaults: defaults
                    )
                }
                return try await self.performPullCardsToLocal(
                    container: container, progress: progress,
                    reporter: reporter, defaults: defaults
                )
            }
        }
        return try await task.value
    }

    /// Notebook-scoped projection (#2102): a drained full read of one notebook,
    /// merged through `mergeNotebookScopedCards`, so orphan cleanup never runs —
    /// one notebook's cards are not authoritative for the whole store.
    ///
    /// It touches no global sync state. The incremental boundary is the global
    /// pull's cursor: borrowing it as `since` and writing it back left other
    /// notebooks' newer server changes unreachable. The payload version stays
    /// too — marking it current here would cancel the full re-sync a pending
    /// upgrade owes every notebook.
    ///
    /// `defaults` is deliberately never read or written. It is threaded through
    /// only so a test's key-recording spy is the object this path would touch:
    /// without it, a regression that reaches for the cursor keys would hit
    /// `.standard` and the spy would stay silent.
    private func performNotebookScopedPull(
        container: ModelContainer,
        progress: ((String, Int, Int) -> Void)?,
        notebookId: String,
        reporter: SyncProgressReporting?,
        defaults: UserDefaults
    ) async throws -> KGPullOutcome {
        progress?(L10n.string("正在下載單字..."), 0, 0)
        let pages = try await fetchAllVocabPages(query: [URLQueryItem(name: "notebook_id", value: notebookId)])

        progress?(L10n.string("解析資料..."), 0, 0)
        let result = try await Self.mergeNotebookScopedCards(
            pages.cards,
            notebookId: notebookId,
            container: container,
            progress: { detail, current, total in
                progress?(detail, current, total)
            }
        )

        reporter?(.finished(.pull, status: .done, detail: Self.pullDetail(
            inserted: result.inserted, updated: result.updated, deleted: result.deleted
        )))
        return KGPullOutcome(
            pipelinePending: pages.pipelinePending,
            inserted: result.inserted,
            updated: result.updated,
            deleted: result.deleted
        )
    }

    private func performPullCardsToLocal(
        container: ModelContainer,
        progress: ((String, Int, Int) -> Void)?,
        reporter: SyncProgressReporting?,
        defaults: UserDefaults
    ) async throws -> KGPullOutcome {
        progress?(L10n.string("正在下載單字..."), 0, 0)

        let storedPayloadVersion = defaults.integer(forKey: SyncKeys.payloadVersion)
        if storedPayloadVersion < SyncKeys.currentPayloadVersion {
            defaults.removeObject(forKey: SyncKeys.incrementalBoundary)
            progress?(L10n.string("升級卡片資料格式，重新同步全部卡片..."), 0, 0)
        }

        var lastSyncMillis = defaults.double(forKey: SyncKeys.incrementalBoundary)
        // Safety: if boundary exists but local store is empty, force full sync.
        // This handles Xcode rebuild (clears SQLite but not UserDefaults),
        // interrupted syncs, or any other boundary/data mismatch.
        if lastSyncMillis > 0 {
            let actor = BackgroundSyncActor(modelContainer: container)
            let localCount = try await actor.syncedEntryCount()
            if localCount == 0 {
                AppLog.kg.warning("Incremental boundary exists but local store is empty — forcing full sync")
                defaults.removeObject(forKey: SyncKeys.incrementalBoundary)
                lastSyncMillis = 0
            }
        }
        let isIncremental = lastSyncMillis > 0

        var queryItems: [URLQueryItem] = []
        if isIncremental {
            let dateString = AppDateFormatters.iso8601.string(from: Date(timeIntervalSince1970: lastSyncMillis))
            queryItems.append(URLQueryItem(name: "since", value: dateString))
            AppLog.kg.info("Performing incremental sync since: \(dateString)")
        } else {
            AppLog.kg.info("Performing full sync")
        }

        // Bug A fix: 記錄邊界在發起請求前，避免 pull 期間新增的卡片被跳過。
        // The device clock is only a reference: the boundary is later compared with the
        // server's `updated_at`, so it is anchored to the earlier of this sample and the
        // server's own `Date` header (see `incrementalBoundary`).
        let pullStart = Date().timeIntervalSince1970

        // Drain every page before touching the store: the merge's orphan
        // cleanup and the boundary below are only sound against the server's
        // complete set (#2101).
        let pages = try await fetchAllVocabPages(query: queryItems)

        progress?(L10n.string("解析資料..."), 0, 0)
        let actor = BackgroundSyncActor(modelContainer: container)
        let pullResult = try await actor.pullCardsToLocal(
            fetchedCards: pages.cards,
            isIncremental: isIncremental,
            progress: { detail, current, total in
                progress?(detail, current, total)
            },
            notebookId: "default"
        )

        reporter?(.finished(.pull, status: .done, detail: Self.pullDetail(
            inserted: pullResult.inserted, updated: pullResult.updated, deleted: pullResult.deleted
        )))

        // Orphan cleanup leak fix: when a full sync's orphan cleanup was
        // blocked by the mass-deletion safety valve, the local store still
        // holds ghost entries. Advancing the boundary here would lock all
        // future syncs into incremental mode — which never runs cleanup —
        // so the ghosts would never be reaped. Instead, clear the boundary
        // so the next sync runs a full sync again and retries the cleanup.
        if pullResult.orphanCleanupBlocked {
            defaults.removeObject(forKey: SyncKeys.incrementalBoundary)
            AppLog.kg.warning("Incremental boundary NOT advanced: orphan cleanup was blocked — next sync will retry full sync")
        } else {
            let boundary = Self.incrementalBoundary(clientStart: pullStart, serverDate: pages.serverDate)
            defaults.set(boundary, forKey: SyncKeys.incrementalBoundary)
        }
        defaults.set(SyncKeys.currentPayloadVersion, forKey: SyncKeys.payloadVersion)

        return KGPullOutcome(
            pipelinePending: pages.pipelinePending,
            inserted: pullResult.inserted,
            updated: pullResult.updated,
            deleted: pullResult.deleted
        )
    }

    /// Every card one `GET /api/vocab` scope holds, in server order.
    struct VocabPages {
        var cards: [KGCard] = []
        /// `X-Pipeline-Pending` of the last page — the freshest observation.
        var pipelinePending = false
        /// The `Date` header of the first page: the server's clock when the drain began.
        var serverDate: Date?
    }

    /// Safety margin under the pull's clock reference. Rows the server stamps just
    /// before the read can commit behind the cursor, so the next incremental pull
    /// re-reads that window. The merge is idempotent, so the overlap is harmless.
    static let incrementalBoundaryMargin: TimeInterval = 60

    /// Boundary for the next incremental pull, in seconds since 1970.
    ///
    /// The cursor is compared with the server's `updated_at`, so it must not run
    /// ahead of server time. Anchoring to the earlier of the device clock and the
    /// server `Date` covers both skews: a device ahead of the server (boundary
    /// follows the server) and a device behind it (boundary follows the device).
    static func incrementalBoundary(clientStart: TimeInterval, serverDate: Date?) -> TimeInterval {
        let reference = min(clientStart, serverDate?.timeIntervalSince1970 ?? clientStart)
        return reference - incrementalBoundaryMargin
    }

    /// Parses an RFC 7231 `Date` header (IMF-fixdate). Pinned to GMT and a POSIX
    /// locale so device region or calendar settings cannot shift the result.
    static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: value)
    }

    /// Upper bound on pages one drain may follow (see `fetchAllVocabPages`).
    static let maxVocabPages = 200

    /// Read `GET /api/vocab` to the end by following `X-Next-Cursor`.
    ///
    /// The server returns at most `limit` (default 5,000) rows per page,
    /// ordered by `(updated_at, id)`, and puts the next keyset position in
    /// `X-Next-Cursor`; a page without it is the last. The cursor is bound to
    /// the request scope (`notebook_id` + `since`), so every page re-sends
    /// `query` verbatim plus the cursor.
    ///
    /// Throws on any failed, undecodable, or non-advancing page, and when the
    /// drain would need more than `maxVocabPages` pages (a server that keeps
    /// minting fresh cursors must not hang the sync or grow memory without
    /// bound; 200 pages x 5,000 rows is far beyond any real library). A caller must
    /// commit nothing it derives from completeness — orphan cleanup, the
    /// incremental boundary — unless this returns: a truncated read is
    /// indistinguishable from "the server no longer has these cards".
    func fetchAllVocabPages(query: [URLQueryItem]) async throws -> VocabPages {
        var pages = VocabPages()
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            var pageQuery = query
            if let cursor { pageQuery.append(URLQueryItem(name: "cursor", value: cursor)) }
            let (data, httpResponse) = try await authenticatedRequest(
                path: "api/vocab",
                queryItems: pageQuery.isEmpty ? nil : pageQuery
            )
            guard httpResponse.statusCode == 200 else {
                throw KGError.httpError(statusCode: httpResponse.statusCode, detail: "GET api/vocab failed")
            }
            do {
                pages.cards.append(contentsOf: try JSONDecoder().decode([KGCard].self, from: data))
            } catch {
                AppLog.kg.error("Failed to decode KG cards: \(error.localizedDescription)")
                throw KGError.serverError("Parse error: \(error.localizedDescription)")
            }
            if pages.serverDate == nil, let header = httpResponse.value(forHTTPHeaderField: "Date") {
                pages.serverDate = Self.parseHTTPDate(header)
            }
            pages.pipelinePending = httpResponse.value(forHTTPHeaderField: "X-Pipeline-Pending") == "true"
            cursor = httpResponse.value(forHTTPHeaderField: "X-Next-Cursor").flatMap { $0.isEmpty ? nil : $0 }
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw KGError.serverError("GET api/vocab returned a non-advancing cursor")
            }
            if cursor != nil, seenCursors.count >= Self.maxVocabPages {
                throw KGError.serverError("GET api/vocab exceeded \(Self.maxVocabPages) pages")
            }
        } while cursor != nil
        if !seenCursors.isEmpty {
            // A card edited mid-drain can surface on two pages; keep the last
            // (freshest) copy so counts and the cleanup ratio stay honest.
            var lastIndex: [String: Int] = [:]
            for (index, card) in pages.cards.enumerated() { lastIndex[card.id] = index }
            pages.cards = pages.cards.enumerated().filter { lastIndex[$0.element.id] == $0.offset }.map(\.element)
            AppLog.kg.info("GET api/vocab drained \(seenCursors.count + 1) pages, \(pages.cards.count) cards")
        }
        return pages
    }

    func clearLocalData(container: ModelContainer, reason: String = "unspecified") async throws {
        let actor = BackgroundSyncActor(modelContainer: container)
        AppLog.kg.info("clearLocalData requested. reason=\(reason)")

        #if DEBUG
        if SettingsResetFailureInjector.consumeIfRequested(reason: reason) {
            try await actor.clearFirstUserDataForInjectedFailure()
            AppLog.kg.warning("clearLocalData: injecting one UI-test failure")
            throw SettingsResetInjectedFailure()
        }
        #endif

        do {
            try await actor.clearUserData(reason: reason)
        } catch {
            AppLog.kg.error("clearUserData failed: \(error.localizedDescription)")
            AppCrashReporting.record(error, context: "kg.local.clear")
            throw error
        }

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SyncKeys.incrementalBoundary)
        defaults.removeObject(forKey: SyncKeys.reviewEventPullBoundary)
        defaults.removeObject(forKey: SyncKeys.payloadVersion)
        ActiveNotebookStore.shared.clear()
        defaults.removeObject(forKey: NotebookFilter.storageKey)
        lastSyncDate = nil
        Self.persistLastSyncDate(nil)
        serverCardCount = 0
    }

    // MARK: - Background Sync (輕量：push review + pull)

    /// 將一個可拋錯的 async 操作包成 `Result`，供 `async let` 並行收集 —
    /// 取代各 phase 重複的 do/catch 立即執行閉包，保留 child task 並行語意。
    ///
    /// 泛型化（原本固定 `Void`）是為了讓進度回報拿得到各步驟的筆數：一列寫
    /// 「已送出 0 筆」與寫「已送出 47 筆」的資訊量差距，正是複習紀錄重送那個 bug
    /// 當初沒被任何人看見的原因。`processSyncPhase` 仍只吃 `Result<Void, Error>`，
    /// 呼叫端用 `.map { _ in () }` 抹掉型別後交進去。
    private static func captureResult<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    /// 這一輪 `backgroundSync` 會回報的步驟，順序即 UI 顯示順序。
    ///
    /// 由服務自己宣告而不是讓 UI 猜：UI 必須先知道完整清單才畫得出「還沒輪到」的
    /// 灰列與正確的進度條分母，而唯一知道自己會跑哪幾段的是這裡。清單與實作因此
    /// 只有一個真相；`podcastEnabled` 參數化只供測試釘語意，production 走預設值。
    static func syncStepIDs(
        podcastEnabled: Bool = KGFeatureFlags.podcastEnabled
    ) -> [SyncStepID] {
        var ids: [SyncStepID] = [.push, .pull, .reviewEvents]
        if podcastEnabled { ids.append(.podcast) }
        return ids
    }

    /// `.pull` 完成列的說明文字。無變更時明講「已是最新」——留白會讓使用者以為
    /// 那一步沒跑完。用「同步」而不是「更新」：這個數字含新增與刪除，只刪了 3 張卡
    /// 的一輪寫「更新 3 筆」是錯的。
    static func pullDetail(inserted: Int, updated: Int, deleted: Int) -> String {
        let changed = inserted + updated + deleted
        guard changed > 0 else { return L10n.string("已是最新") }
        return L10n.format("同步 %@ 筆", "\(changed)")
    }

    /// `.push` 完成列的說明文字。
    ///
    /// **兩腿都含 `skipped`。** 伺服器端去重把重複的算 skipped，只看
    /// updated / inserted 的話，複習紀錄重送那個 bug（每輪重推 9,580 筆、伺服器全判
    /// 重複）會顯示「已送出 0 筆」——跟修好之前一模一樣，這一列就白加了。
    ///
    /// 誠實的邊界：這是**伺服器回報的帳**，不是本機 payload 的筆數。
    /// `pushReviewEvents` 兩者相等（它自己 assert `inserted + skipped ==
    /// batch.count`）；`pushReviewStates` 沒有那道 assert，伺服器若靜默丟棄列，
    /// 這個數字會少報。另外 `pushReviewEvents` 在 `claimReviewEventPush()` 失敗時
    /// 回 `(0, 0)`——那是「延後」不是「沒東西可送」，這一列會寫 0 筆。
    /// 兩者都不值得為了顯示而改動 push 的回傳契約。
    static func pushDetail(states: (updated: Int, skipped: Int), events: (inserted: Int, skipped: Int)) -> String {
        let sent = states.updated + states.skipped + events.inserted + events.skipped
        return L10n.format("已送出 %@ 筆", "\(sent)")
    }

    /// 一般單腿的收尾事件：成功 `.done`、取消 `.skipped`、其餘 `.error`。
    ///
    /// 取消刻意不畫紅叉——使用者離開畫面把 task 收掉不是錯誤，畫紅的只會讓下一次
    /// 有人來問「同步壞了嗎」。這與 `processSyncPhase` 對 `CancellationError`
    /// 的處置同義（那裡也不計入 failures）。
    static func legFinishedEvent<T>(
        _ id: SyncStepID,
        result: Result<T, Error>,
        detail: String
    ) -> SyncProgressEvent {
        switch result {
        case .success:
            return .finished(id, status: .done, detail: detail)
        case .failure(let error) where error is CancellationError:
            return .finished(id, status: .skipped, detail: "")
        case .failure(let error):
            return .finished(id, status: .error, detail: SyncFailurePresentation.reason(for: error))
        }
    }

    /// push 那一列的收尾。兩腿併發、共用一列，所以任一腿失敗即整列失敗；
    /// 兩腿都成功才把筆數寫進 detail。
    static func pushFinishedEvent(
        states: Result<(updated: Int, skipped: Int), Error>,
        events: Result<(inserted: Int, skipped: Int), Error>
    ) -> SyncProgressEvent {
        guard case .success(let s) = states else {
            return legFinishedEvent(.push, result: states, detail: "")
        }
        guard case .success(let e) = events else {
            return legFinishedEvent(.push, result: events, detail: "")
        }
        return .finished(.push, status: .done, detail: pushDetail(states: s, events: e))
    }

    /// podcast 那一列的收尾。
    ///
    /// `nil` = feature flag 關著，這一步根本沒被宣告，回一個對未宣告步驟的事件
    /// （store 會丟棄）比回 `.skipped` 誠實——Release 使用者的清單裡沒有這一列。
    ///
    /// **`.listFetchFailed` 只染紅這一列，不進 `failures`。** 那個欄位會
    /// 讓整輪判定為部分失敗、`lastSyncDate` 不前進、設定頁彈出「背景同步部分失敗」。
    /// 讓 podcast 目錄的一次 hiccup 把「上次同步時間」凍住，對使用者是明確的退步；
    /// 而現在有了逐步清單，那一列自己會紅——可見性已經拿到了，不需要再借用一個
    /// 語意更重的欄位。
    static func podcastFinishedEvent(
        _ outcome: PodcastSyncService.SyncOutcome?
    ) -> SyncProgressEvent {
        switch outcome {
        case .completed, .none:
            return .finished(.podcast, status: .done, detail: "")
        case .cancelled:
            return .finished(.podcast, status: .skipped, detail: "")
        case .listFetchFailed:
            return .finished(.podcast, status: .error, detail: L10n.string("目錄讀取失敗"))
        }
    }

    /// 處理單一 backgroundSync phase 的並行結果，統一處理 401 / log / Sentry /
    /// CancellationError 過濾。回傳該 phase 的 failure label + UI message；若遇到 401
    /// 則登出已由真實 401 來源完成（#2806），此處只設 lastBackgroundSyncError 並回傳 nil
    /// 以通知 caller 直接 return。
    /// internal（原本 private）純粹是為了讓測試看得到。這三個型別 + `processSyncPhase`
    /// 是 backgroundSync 唯一的失敗分類邏輯——401 短路、取消不算失敗、部分失敗聚合——
    /// 在此之前**一個測試都沒有**，而它決定使用者看到「登入已過期」還是「部分失敗」
    /// 還是什麼都不看到。經 `backgroundSync` 端到端反推這三條分支需要真網路，
    /// 那才是真正的壞主意。
    struct SyncPhaseFailure {
        let label: String
        let reason: String
    }

    /// Outcome of one `backgroundSync` phase. `cancelled` is tracked separately
    /// from `failures` because a cancelled leg is neither a success nor a
    /// failure — see `backgroundSync`'s terminal handling.
    struct SyncPhaseOutcome {
        var failures: [SyncPhaseFailure] = []
        var cancelled = false
    }

    func processSyncPhase(
        results: [Result<Void, Error>],
        labels: [String],
        container: ModelContainer
    ) async -> SyncPhaseOutcome? {
        var outcome = SyncPhaseOutcome()
        for (result, label) in zip(results, labels) {
            guard case .failure(let error) = result else { continue }
            // A cancelled leg is not a failed leg — reporting it would put
            // "背景同步部分失敗" in front of a user whose only crime was leaving the
            // screen. But it is not a *successful* leg either, so it is recorded
            // rather than dropped: the caller must not go on to claim the round
            // succeeded (that would toast「同步完成」for work that never ran).
            if error is CancellationError {
                AppLog.kg.info("backgroundSync \(label) cancelled")
                outcome.cancelled = true
                continue
            }
            // token 還在從 keychain 載入（#2714）：這輪沒做事，不是 401，不可登出也不算失敗。
            if error is KGSessionPendingError {
                AppLog.kg.info("backgroundSync \(label) skipped: session token pending")
                outcome.cancelled = true
                continue
            }
            if error is KGError, case KGError.unauthorized = error {
                // 登出已在真實 401 來源（authenticatedRequest／authedResponseData）完成，這裡不重複登出。
                lastBackgroundSyncError = L10n.string("登入已過期")
                return nil
            }
            AppLog.kg.warning("backgroundSync \(label) failed: \(error.localizedDescription)")
            if Self.shouldRecordSyncFailure(error) {
                AppCrashReporting.record(error, context: "kg.sync.\(label)")
            }
            outcome.failures.append(SyncPhaseFailure(
                label: label,
                reason: SyncFailurePresentation.reason(for: error)
            ))
        }
        return outcome
    }

    func backgroundSync(container: ModelContainer) async {
        await backgroundSync(container: container, progress: nil)
    }

    @discardableResult
    func backgroundSync(container: ModelContainer, progress: SyncProgressReporting?) async -> SyncRoundOutcome {
        // 防止併發：快速前景/背景切換可能觸發多個 sync task
        guard claimBackgroundSync() else {
            // **這條出口在 `lastBackgroundSyncError` 被重置之前**，所以呼叫端若去讀
            // 那個全域欄位，讀到的是上一輪的殘值。回 `.didNotRun` 是唯一誠實的答案。
            AppLog.kg.info("backgroundSync skipped: already in progress")
            return .didNotRun
        }
        return await performBackgroundSync(container: container, progress: progress)
    }

    @discardableResult
    func backgroundSyncWhenAvailable(
        container: ModelContainer,
        progress: SyncProgressReporting?
    ) async -> SyncRoundOutcome {
        guard await claimBackgroundSyncWhenAvailable() else {
            AppLog.kg.info("backgroundSyncWhenAvailable cancelled while waiting")
            return .didNotRun
        }
        return await performBackgroundSync(container: container, progress: progress)
    }

    private func performBackgroundSync(
        container: ModelContainer,
        progress: SyncProgressReporting?
    ) async -> SyncRoundOutcome {
        defer { releaseBackgroundSync() }

        // 每輪開始即重置 error-tracking 欄位：四個 trigger（post-login / scenePhase
        // / ⌘R menu / Settings 手動）共用此全域欄位，read-then-clear consumer 有
        // 三處（App 層 scenePhase 兩處 + ExplicitSync）。claim 鎖已序列化整段
        // （同時間僅一輪執行），於 claim 成功後、
        // cleanup gate 懸掛前清空 —— gate 可懸掛數秒，期間被 skip 的 trigger 會立即
        // read-then-clear，必須讀不到上一輪 stale 值（典型：logout-401 留下的「登入
        // 已過期」在重登成功後反彈成過期 toast）。失敗時下方會再 set 為本輪正確值。
        lastBackgroundSyncError = nil

        // 先等 logout 排程的本地清理收尾，再動任何 sync 工作。否則快速
        // 「登出→重登」會讓 sync 搶用尚未被清的 sync boundary（incremental
        // 跳過後端全部卡 → 本地空庫但自認最新），且拉回的資料會被 resume 的
        // cleanup 再清一遍 —— 2026-06-09 000287 單字本事故根因。放在入口
        // 單點守住全部四個觸發點（post-login / scenePhase / ⌘R / Settings）。
        await sessionInvalidator.waitForPendingLocalDataCleanup()

        // 離線時跳過整個背景同步，不產生無意義的錯誤日誌
        guard connectivityGate.isConnected else {
            AppLog.kg.info("backgroundSync skipped: offline")
            lastBackgroundSyncError = L10n.string("目前沒有網路連線，背景同步已跳過")
            return .didNotRun
        }

        AppCrashReporting.addBreadcrumb(category: "sync", message: "sync.start")
        var failures: [SyncPhaseFailure] = []
        var wasCancelled = false

        // Podcast catalog 從整輪的最前面就起跑，與底下整條 vocab 管線併行。
        //
        // 它以前排在最後、序列執行，而 2026-08-06 的量測說那是整輪 7.55s 裡的
        // 6.08s（81%）——同時資料量只有約 7 KB。貴的是往返次數不是位元組，而那些
        // 往返完全不需要等 vocab。兩邊零欄位重疊（PodcastSeries/Episode/Progress
        // vs VocabularyEntry/ReviewRecord），沒有任何理由讓它們互等。
        //
        // **那筆 6.08s 目前只有開發者在付。** 這條腿受 `KGFeatureFlags.podcastEnabled`
        // 管，Release 是 false，所以上架版本從來沒付過、也不會因此變快。修它的理由
        // 是：它污染我們自己的量測與 debug 體感，而且 podcast 一旦開放就直接變成
        // 使用者問題。
        //
        // 用 `async let` 而不是 Task：早退路徑（401 / cancelled）離開 scope 時，
        // 結構化併發會自動取消並等待這個 child，不會留下背景在跑的孤兒。
        async let podcastLeg = Self.runPodcastLeg(
            container: container, kgService: self, progress: progress
        )

        // Phase 1: push review states & review events in parallel
        progress?(.started(.push))
        async let pushReviewResult = Self.captureResult { try await self.pushReviewStates(container: container) }
        async let pushEventsResult = Self.captureResult { try await self.pushReviewEvents(container: container) }

        let pushStates = await pushReviewResult
        let pushEvents = await pushEventsResult
        let pushResults = [pushStates.map { _ in () }, pushEvents.map { _ in () }]
        progress?(Self.pushFinishedEvent(states: pushStates, events: pushEvents))
        if let pushOutcome = await processSyncPhase(
            results: pushResults, labels: ["pushReview", "pushReviewEvents"], container: container
        ) {
            failures.append(contentsOf: pushOutcome.failures)
            wasCancelled = wasCancelled || pushOutcome.cancelled
        } else {
            return .failed  // 401：processSyncPhase 已設「登入已過期」
        }

        // Phase 2: pull cards & review events in parallel (after push completes)
        //
        // **push → pull 必須序列。** pull 會把伺服器的 `lastReviewedAt` 寫回本地；
        // 先拉再送會讓「還沒送出」的基準被覆蓋掉（7a8352f27 有測試釘住）。
        //
        progress?(.started(.pull))
        progress?(.started(.reviewEvents))
        // `progress:` 這條線一直都在（`pullCardsToLocal` 從第一天就收 progress
        // 閉包），只是 backgroundSync 一直傳 nil —— 線留著沒接。接上它，`.pull`
        // 那一列才有真實的 current/total，進度條在整段同步最長的一步裡才會動。
        async let pullCardsResult = Self.captureResult {
            try await self.pullCardsToLocal(
                container: container,
                progress: { detail, current, total in
                    progress?(.advanced(.pull, current: current, total: total, detail: detail))
                },
                notebookId: nil,
                reporter: progress
            )
        }
        async let pullEventsResult = Self.captureResult { try await self.pullReviewEvents(container: container) }

        let pullCards = await pullCardsResult
        let pullEvents = await pullEventsResult
        let pullResults = [pullCards.map { _ in () }, pullEvents.map { _ in () }]
        // 失敗時 `.pull` 停在 running（內部的收尾事件沒走到），這裡補一個終態。
        //
        // **取消也要補。** `KGService+Request` 會把 URLError -999 轉成
        // `CancellationError`，所以 `api/vocab` 這個 GET 真的產得出取消；漏掉這條
        // 分支的話 `.pull` 會停在轉圈，而 `wasCancelled` 早退後再也不會有事件來救它。
        //
        if case .failure(let error) = pullCards {
            progress?(error is CancellationError
                ? .finished(.pull, status: .skipped, detail: "")
                : .finished(.pull, status: .error, detail: SyncFailurePresentation.reason(for: error)))
        }
        progress?(Self.legFinishedEvent(.reviewEvents, result: pullEvents, detail: ""))
        if let pullOutcome = await processSyncPhase(
            results: pullResults, labels: ["pull", "pullReviewEvents"], container: container
        ) {
            failures.append(contentsOf: pullOutcome.failures)
            wasCancelled = wasCancelled || pullOutcome.cancelled
        } else {
            return .failed  // 401：同上
        }

        // Cancelled = the round never finished, so it is neither success nor
        // failure. Returning here keeps `lastSyncDate` where it was and leaves
        // `lastBackgroundSyncError` nil; `ExplicitSync` reads `Task.isCancelled`
        // to know it must stay silent rather than toast「同步完成」for a sync that
        // was abandoned. Nothing is lost — a cancelled pull never advanced its
        // cursor, so the next round redoes exactly this work.
        if wasCancelled {
            AppLog.kg.info("backgroundSync ended cancelled — lastSyncDate not advanced")
            AppCrashReporting.addBreadcrumb(
                category: "sync", message: "sync.end.cancelled", level: .info
            )
            return .didNotRun
        }

        // 收 podcast 那條併行的腿。它從整輪最前面就在跑（見上方 `async let`），
        // 到這裡多半早就結束了 —— 這行只是把它的結果取回來畫那一列。
        //
        // 為什麼 podcast 屬於 backgroundSync 而不是書架自己的 .task：它要共用全部
        // 四個既有觸發（post-login / scenePhase→active / ⌘R menu / Settings 手動），
        // 補上「Mac Catalyst 下 .refreshable 不可用、BookshelfView .task 每 view
        // identity 只跑一次」造成的、書架 podcast 區塊一旦沒載入就無法復原的缺口。
        //
        // syncAll 自我防禦（list fetch 失敗即 skip、空回傳不刪 series），不 throw。
        await podcastLeg
        // 早退路徑（401 / wasCancelled）不會走到這裡，那時 `async let` 的隱式取消
        // 會把這條腿收掉——podcast 目錄同步是冪等的，取消一次沒有任何後果。

        if failures.isEmpty {
            lastBackgroundSyncError = nil
            let syncedAt = Date()
            lastSyncDate = syncedAt
            Self.persistLastSyncDate(syncedAt)
            AppCrashReporting.addBreadcrumb(category: "sync", message: "sync.end.success")
            return .completed
        } else {
            recordPartialFailure(failures)
            AppCrashReporting.addBreadcrumb(
                category: "sync",
                message: "sync.end.partial",
                level: .warning,
                data: ["failures": failures.map(\.label)]
            )
            return .failed
        }
    }

    /// 部分失敗時的使用者文案組裝點。獨立成方法，讓測試直接釘住 production 的
    /// 組裝路徑（回退成寫死的 ", " 會在這裡被抓到），不必打網路跑完整一輪。
    func recordPartialFailure(
        _ failures: [SyncPhaseFailure],
        language: AppLanguage = AppLanguageStore.shared.selection
    ) {
        lastBackgroundSyncError = SyncFailurePresentation.partialFailureSummary(
            failures.map { (label: $0.label, reason: $0.reason) },
            language: language
        )
    }

    /// 併行的 podcast 目錄腿：開場事件 → 同步 → 收尾事件，整包給一個 `async let`。
    ///
    /// `PodcastSyncService.syncAll` 是 `@MainActor`，需以 main-actor `ModelContext`
    /// 呼叫（沿用 `BookshelfView` 既有契約：傳 mainContext，upsert 在 main actor、
    /// @Query 直接拿到更新）。整段標 `@MainActor` 使 `container.mainContext` 合法。
    ///
    /// 為什麼是 `static` 且顯式收 `kgService`：`async let` 的 initializer 會被當成
    /// `@Sendable` 閉包檢查，隱式捕捉 `self` 會把整個 `KGService` 拖進去。
    ///
    /// Release（`podcastEnabled == false`）連 `.started` 都不發 —— 那一列根本不在
    /// `syncStepIDs()` 宣告的清單裡，發了 store 也會丟棄，但不發更誠實。
    @MainActor
    private static func runPodcastLeg(
        container: ModelContainer,
        kgService: KGService,
        progress: SyncProgressReporting?
    ) async {
        guard KGFeatureFlags.podcastEnabled else { return }
        // 沒有**有效** session 就不抓目錄。以前這條腿排在 vocab pull 的 401 早退
        // 之後，等於被那個 return 順手擋掉；現在它跑在最前面，就得自己擋。
        //
        // 只擋「沒有 token」（keychain 尚未載入，#2714）。**不以本地時鐘判斷過期**（#2806）：
        // 本地時鐘偏移時，過期判斷會讓整條 podcast 腿靜默跳過。目錄 browse 走
        // `optionallyAuthedData`，它對本地過期 token 以 guest 身分送出（不登出、不 wipe）；
        // 真的過期由伺服器 401（authedResponseData）決定。
        guard kgService.authSession.token != nil else { return }
        progress?(.started(.podcast))
        // 儀器必須放在 service 內，不能掛在 `progress` 上：冷啟動路徑傳的是
        // `progress: nil`，而 `SyncProgress` 是純 UI store（零 AppLog／零
        // AppAnalytics）。掛在那裡的儀器對這條腿最需要被量的那一次完全沉默。
        // 兩道 early return（podcastEnabled / JWT 過期）刻意留在這行之前：
        // Release 零 podcast 足跡是既有不變式，加儀器不得破壞它。
        AppAnalytics.track(.podcastCatalogSyncStarted)
        let legStart = Date()
        let outcome = await runPodcastCatalogSyncIfEnabled {
            await PodcastSyncService(kgService: kgService).syncAll(context: container.mainContext)
        }
        progress?(podcastFinishedEvent(outcome))
        // `SyncOutcome` 沒有 rawValue（`enum SyncOutcome: Equatable`），顯式映射。
        // `.none` = feature flag 關；上面的 guard 已擋掉，留著只為窮舉。
        let outcomeLabel: String
        switch outcome {
        case .none: outcomeLabel = "disabled"
        case .completed: outcomeLabel = "completed"
        case .cancelled: outcomeLabel = "cancelled"
        case .listFetchFailed: outcomeLabel = "listFetchFailed"
        }
        AppAnalytics.track(.podcastCatalogSyncCompleted(
            durationMs: Int(Date().timeIntervalSince(legStart) * 1000),
            outcome: outcomeLabel
        ))
    }

    /// Feature-gate seam for the podcast catalog leg of `backgroundSync`.
    /// Release（`KGFeatureFlags.podcastEnabled == false`）必須零 podcast 網路/磁碟
    /// 足跡：catalog list fetch + 封面下載在建構 `PodcastSyncService` 之前就短路。
    /// `podcastEnabled` 參數化僅供測試鎖語意；production 一律走預設值。
    @MainActor
    static func runPodcastCatalogSyncIfEnabled(
        podcastEnabled: Bool = KGFeatureFlags.podcastEnabled,
        sync: @MainActor () async -> PodcastSyncService.SyncOutcome
    ) async -> PodcastSyncService.SyncOutcome? {
        guard podcastEnabled else { return nil }
        return await sync()
    }

    func pushReviewQuietly(container: ModelContainer) async {
        guard connectivityGate.isConnected else {
            AppLog.kg.info("pushReviewQuietly skipped: offline")
            return
        }

        do {
            _ = try await pushReviewStates(container: container)
        } catch {
            AppLog.kg.warning("pushReviewQuietly failed: \(error.localizedDescription)")
            if Self.shouldRecordSyncFailure(error) {
                AppCrashReporting.record(error, context: "kg.sync.push_review_states")
            }
        }
        do {
            _ = try await pushReviewEvents(container: container)
        } catch {
            AppLog.kg.warning("pushReviewQuietly pushReviewEvents failed: \(error.localizedDescription)")
            if Self.shouldRecordSyncFailure(error) {
                AppCrashReporting.record(error, context: "kg.sync.push_review_events")
            }
        }
    }

    /// Sentry filter for background sync failures, mirroring
    /// `TranslationService.recordTranslationFailureIfNeeded`: offline/network
    /// blips, cancellation and auth expiry are user-recoverable noise; server,
    /// decoding and unexpected failures are actionable and get recorded.
    nonisolated static func shouldRecordSyncFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is KGSessionPendingError { return false }
        if let kgError = error as? KGError {
            switch kgError {
            case .offline, .networkError, .unauthorized, .notAuthenticated:
                return false
            case .httpError, .decodingError, .serverError:
                return true
            }
        }
        if let urlError = error as? URLError,
           urlError.code == .cancelled || urlError.code == .notConnectedToInternet {
            return false
        }
        return true
    }
}
