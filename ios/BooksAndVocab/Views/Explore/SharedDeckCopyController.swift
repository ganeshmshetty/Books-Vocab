//
//  SharedDeckCopyController.swift
//  Books & Vocab
//
//  Explore 複製流程狀態機（idle/inflight/success/failure）+ idempotencyKey 穩定性。
//  擁有者 = `SharedDeckCopyRegistry`（依 deckId + 帳號 owner，跨 view pop/reopen；#2748）。
//  純狀態 + 一支 async `copy`；網路只透過注入的 `any DeckCopying`（窄協定），
//  故可完整單元測試（無 SwiftData / 無真實網路）。
//

import Foundation

@MainActor
@Observable
final class SharedDeckCopyController {

    /// 一次複製的成功結果（供 success 態渲染）。
    struct Outcome: Equatable {
        let notebookId: String
        let notebookName: String
        let cardCount: Int
        /// server 依 idempotencyKey 短路回既有 notebook（retry / 遺失回應復原），非新複製。
        let alreadyCopied: Bool
    }

    enum CopyState: Equatable {
        case idle
        case inflight
        case success(Outcome)
        case failure(String)   // user-facing 訊息（已 i18n）
    }

    private(set) var state: CopyState = .idle

    /// 當前「複製意圖」的 idempotencyKey。第一次 inflight 時生成一把，該意圖的**每次
    /// retry 都沿用同一把**（server 冪等短路 → 回同一 notebook，絕不併發不同-key 打出
    /// 重複本），只在**觀察到成功時清除** —— 成功後再複製即新意圖、生新 key。跨 failure
    /// 與 dismiss/reopen 保留是刻意的：讓「回應遺失但 server 已成功」的複製在下次嘗試
    /// 自癒（server replay `alreadyCopied`）。
    private var idempotencyKey: String?

    /// 當前意圖的目標 notebook 名稱；與 key 同生命週期（成功時一併清除），讓 pop/reopen
    /// 後的「重試」沿用使用者當初確認的名稱，而非退回 deck 標題（#2748）。
    private(set) var lastNotebookName: String?

    /// 當前意圖的首次落盤時間；與 key 同生命週期。retry 沿用原值（不重置年齡），到期判定才有效（#3501）。
    private var intentCreatedAt: Date?

    /// 擁有此意圖的帳號（登入 userId；未登入為 nil）。registry 只把同帳號的 controller
    /// 交回，避免帳號 B 看見帳號 A 的失敗卡與 notebook 名稱（#2748）。
    let owner: String?

    /// Test seam：注入決定性的 key 產生器。
    private let makeKey: () -> String

    /// 待完成意圖的落盤處（#3423）：inflight 時寫入、成功時清除，行程重啟後由 registry 以 `restored` 接回。
    private let intents: any SharedDeckCopyIntentStoring

    /// `restored` 為行程重啟後接回的待完成意圖：沿用其 key 與名稱，retry 即同一把 key。
    init(
        owner: String? = nil,
        makeKey: @escaping () -> String = { UUID().uuidString },
        intents: any SharedDeckCopyIntentStoring = EphemeralSharedDeckCopyIntentStore(),
        restored: PendingDeckCopyIntent? = nil
    ) {
        self.owner = owner
        self.makeKey = makeKey
        self.intents = intents
        if let restored {
            idempotencyKey = restored.idempotencyKey
            lastNotebookName = restored.notebookName
            intentCreatedAt = restored.createdAt
        }
    }

    var isSucceeded: Bool {
        if case .success = state { return true }
        return false
    }

    var isInflight: Bool {
        if case .inflight = state { return true }
        return false
    }

    /// 當前意圖的 key（首次嘗試前為 nil）。供測試斷言 retry 沿用同一把。
    var currentIdempotencyKey: String? { idempotencyKey }

    // NOTE: 失敗後的復原走 failure 卡的「重試」按鈕 —— 它直接以沿用的同把 key 再打
    // 一次 `copy`（server 回 `alreadyCopied` 自癒遺失回應），故不需要獨立的 reset-to-idle
    // 入口。若日後在 failure 卡加「取消」affordance 才需要，屆時再引入。

    /// 執行複製。`afterCopy` 在收到 server 成功回應後、標記 success 前 await —— 供
    /// caller 掛針對性 pull（2c-2）。`afterCopy` 不 throw（pull 自我防禦），故不影響
    /// 複製本身的成敗判定。
    func copy(
        deckId: String,
        notebookName: String?,
        using service: any DeckCopying,
        afterCopy: (DeckCopyResponse) async -> Void = { _ in }
    ) async {
        // Re-entry guard：inflight 期間再呼叫直接忽略，杜絕併發不同-key（View 亦
        // disable 按鈕，此為第二道防線）。
        guard !isInflight else { return }
        let key = idempotencyKey ?? makeKey()
        idempotencyKey = key
        lastNotebookName = notebookName
        // 先落盤再送出：回應前行程被殺，重啟後仍以同一把 key 重試（失敗時此筆已持久化，不需另寫）。
        let createdAt = intentCreatedAt ?? Date()
        intentCreatedAt = createdAt
        intents.upsert(PendingDeckCopyIntent(
            owner: owner, deckId: deckId, idempotencyKey: key, notebookName: notebookName, createdAt: createdAt
        ))
        state = .inflight
        let startedAt = Date()
        AppCrashReporting.addBreadcrumb(
            category: "explore",
            message: "deck copy started",
            data: ["deck_id": deckId, "named_destination": notebookName != nil]
        )
        do {
            let resp = try await service.copyDeck(
                deckId: deckId, idempotencyKey: key, notebookName: notebookName
            )
            await afterCopy(resp)
            idempotencyKey = nil   // 意圖已達成 → 下一次複製為新意圖
            lastNotebookName = nil
            intentCreatedAt = nil
            intents.remove(owner: owner, deckId: deckId)
            state = .success(Outcome(
                notebookId: resp.notebookId,
                notebookName: resp.notebookName,
                cardCount: resp.cardCount,
                alreadyCopied: resp.alreadyCopied
            ))
            AppAnalytics.track(.deckCopyCompleted(
                deckId: deckId,
                cardCount: resp.cardCount,
                alreadyCopied: resp.alreadyCopied,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
            ))
        } catch is CancellationError {
            state = .idle
        } catch {
            AppLog.kg.warning("[Explore] deck copy failed for \(deckId): \(error.localizedDescription)")
            state = .failure(Self.message(for: error))
            // reason 是**錯誤分類**（非 localized 訊息、非 error 內容），故可 `.public`
            // 進 log 與 Sentry；使用者資料與 token 不在其中。
            let reason = Self.failureReason(for: error)
            AppAnalytics.track(.deckCopyFailed(deckId: deckId, reason: reason))
            AppCrashReporting.addBreadcrumb(
                category: "explore",
                message: "deck copy failed",
                level: .warning,
                data: ["deck_id": deckId, "reason": reason]
            )
        }
    }

    /// 錯誤 → 穩定的分類字串。與 `message(for:)` 的使用者訊息平行但**刻意分開**：
    /// 一個給人看（已 i18n、會隨文案改動），一個給 telemetry 聚合（ASCII、穩定、
    /// 可跨版本比對）。共用同一組判別條件。
    static func failureReason(for error: Error) -> String {
        if isSessionExpired(error) { return "unauthorized" }
        if isOffline(error) { return "offline" }
        return "generic"
    }

    /// 錯誤 → user-facing 訊息映射。以 error type 判別（不依賴 NetworkMonitor 單例，
    /// 保持可決定性測試）。
    static func message(for error: Error) -> String {
        if isSessionExpired(error) {
            return L10n.string("explore.copy.error.unauthorized")
        }
        if isOffline(error) {
            return L10n.string("explore.copy.error.offline")
        }
        return L10n.string("explore.copy.error.generic")
    }

    /// 登入態失效的唯一判別（`message` / `failureReason` 共用）。`KGSessionPendingError`
    /// 是 keychain token 尚未載入的空窗（#2714），對使用者等同需要重新登入，故與 `.unauthorized` 同類。
    private static func isSessionExpired(_ error: Error) -> Bool {
        if let kg = error as? KGError, case .unauthorized = kg { return true }
        return error is KGSessionPendingError
    }

    private static let offlineURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost
    ]

    /// 連線類失敗的唯一判別（`message` / `failureReason` 共用）。`KGService.copyDeck`
    /// 走 `authenticatedDecode`：connectivity gate 關閉時丟 `KGError.offline`，transport
    /// `URLError` 一律被包成 `KGError.networkError(underlying:)`，**不會**丟出裸 `URLError`
    /// （#2108）。裸 `URLError` 仍接受，供其他 `DeckCopying` 實作。
    private static func isOffline(_ error: Error) -> Bool {
        if let kg = error as? KGError {
            switch kg {
            case .offline: return true
            case .networkError(let underlying): return isOffline(underlying)
            default: return false
            }
        }
        if let urlError = error as? URLError {
            return offlineURLErrorCodes.contains(urlError.code)
        }
        return false
    }
}

/// 以 (帳號 owner, deckId) 為鍵的 controller 註冊表（#2748）。`SharedDeckDetailView` 的 `@State`
/// 在 pop 時被丟棄，但 `performCopy` 的 unstructured `Task` 仍在跑、idempotencyKey 也
/// 需跨 reopen 保留；有進行中／失敗／已成功意圖的 controller 因此由行程級註冊表持有，view 只借用。
/// 只有複製真的開始（`track`）才登記，故單純瀏覽 deck 不會累積條目。
///
/// **生命週期（reopen 時由 `resolve` 決定）**：
/// - inflight／failure：原樣接回（續用同一把 key 與名稱，失敗卡可重試）。
/// - success 且目標 notebook 仍在本機：原樣接回，顯示「已複製」、不給再複製鈕。
/// - success 但目標 notebook 已不在本機：先重拉一次。只有**重拉完整成功且目標仍不在**才確證
///   已刪除，條目清除、回傳新 idle controller；重拉失敗（離線等）無法分辨「已刪」與「未落地」，
///   維持 success（不可重複複製，server 已有一本）。
///   新複製必生新 key（server 的 key 永久冪等，沿用舊 key 只會回傳已刪的舊 notebook）。
/// 條目以帳號 owner 隔離：登出後換帳號不會看見前一個帳號的失敗卡，且兩帳號對同一 deck 的
/// 登記互不覆寫；前一帳號的條目保留，該帳號再登入時仍接得回自己的意圖、key 與成功態。
@MainActor
final class SharedDeckCopyRegistry {
    static let shared = SharedDeckCopyRegistry(intents: SharedDeckCopyIntentStores.makeDefault())

    private struct Key: Hashable {
        let owner: String?
        let deckId: String
    }

    private let intents: any SharedDeckCopyIntentStoring
    private var controllers: [Key: SharedDeckCopyController] = [:]

    /// 待完成意圖在行程重啟後仍可接回的最長年齡（#3501）。server 的 idempotencyKey 永久冪等，
    /// 超過此期限的舊 key 重放只會回傳使用者可能已刪除的舊 notebook，故不接回並清除條目。
    static let restoredIntentMaxAge: TimeInterval = 24 * 60 * 60

    /// 行程啟動時接回仍待完成的複製意圖（#3423）：inflight／failure 在上次行程被殺前落盤者，
    /// 以原 key 與名稱登記，reopen 即可 retry 同一把 key，不因重啟重複複製。
    /// 無年齡證明（舊版落盤、無 `createdAt`）或已超過 `restoredIntentMaxAge` 者不接回，並自儲存移除（#3501）。
    init(
        intents: any SharedDeckCopyIntentStoring = EphemeralSharedDeckCopyIntentStore(),
        now: Date = Date()
    ) {
        self.intents = intents
        let pendings = intents.load()
        let restorable = pendings.filter { Self.isRestorable($0, now: now) }
        if restorable.count != pendings.count { intents.save(restorable) }
        for pending in restorable {
            controllers[Key(owner: pending.owner, deckId: pending.deckId)] =
                SharedDeckCopyController(owner: pending.owner, intents: intents, restored: pending)
        }
    }

    private static func isRestorable(_ intent: PendingDeckCopyIntent, now: Date) -> Bool {
        guard let createdAt = intent.createdAt else { return false }
        return now.timeIntervalSince(createdAt) <= restoredIntentMaxAge
    }

    /// 已登記（複製已開始）的 (帳號, deck) 數；供測試斷言不累積。
    var trackedDeckCount: Int { controllers.count }

    /// 同帳號已登記的 controller 原樣回傳；否則給一個**尚未登記**的新 controller。純查詢，不套生命週期。
    func controller(for deckId: String, owner: String?) -> SharedDeckCopyController {
        if let existing = controllers[Key(owner: owner, deckId: deckId)] {
            return existing
        }
        return SharedDeckCopyController(owner: owner, intents: intents)
    }

    /// reopen／帳號切換時決定接回哪個 controller（見型別註解的生命週期）。
    /// - Parameters:
    ///   - destinationExists: 目標 notebook（server id）是否仍在本機可見。
    ///   - refreshDestination: success 條目的目標不在本機時呼叫一次。回傳重拉是否**完整成功**
    ///     （authoritative notebook 列表已對帳）；false 代表無法確證狀態，條目不得退場。
    func resolve(
        deckId: String,
        owner: String?,
        destinationExists: (String) -> Bool,
        refreshDestination: (String) async -> Bool
    ) async -> SharedDeckCopyController {
        let key = Key(owner: owner, deckId: deckId)
        guard let existing = controllers[key] else {
            return SharedDeckCopyController(owner: owner, intents: intents)
        }
        guard case .success(let outcome) = existing.state else { return existing }
        if destinationExists(outcome.notebookId) { return existing }
        let refreshCompleted = await refreshDestination(outcome.notebookId)
        // await 期間登記可能已被並行 adopt 換掉：以當前登記為準，絕不清除別人的條目。
        guard controllers[key] === existing else {
            return controllers[key] ?? SharedDeckCopyController(owner: owner, intents: intents)
        }
        if !refreshCompleted || destinationExists(outcome.notebookId) { return existing }
        // 意圖已結束（重拉完整成功後使用者的 notebook 確實不在）：清除條目，新複製即新意圖。
        controllers[key] = nil
        return SharedDeckCopyController(owner: owner, intents: intents)
    }

    /// 複製開始時登記（以 controller 自身的 owner 定位），讓 pop/reopen 的 view 接回同一 controller。
    func track(_ controller: SharedDeckCopyController, for deckId: String) {
        controllers[Key(owner: controller.owner, deckId: deckId)] = controller
    }

    func removeAll() {
        controllers.removeAll()
    }
}
