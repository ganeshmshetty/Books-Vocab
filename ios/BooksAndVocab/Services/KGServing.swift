import Foundation
import SwiftData

/// 一次 `pullCardsToLocal` 的結果。
///
/// 取代原本的裸 `Bool`（只表達 pipeline pending），因為呼叫端需要區分的其實是兩件
/// 獨立的事：**伺服器還在算嗎**（決定要不要再輪詢）與 **本地單字庫真的變了嗎**
/// （決定要不要跟使用者說「已更新」）。裸 `Bool` 表達不了後者，於是 UI 只能無條件
/// 報「單字庫已更新」——每次進單字本都彈一次、即使那輪 merge 是 no-op。
struct KGPullOutcome: Sendable, Equatable {
    /// 伺服器 `X-Pipeline-Pending: true` — AI pipeline 仍在處理，值得稍後再拉一次。
    var pipelinePending: Bool
    /// 這輪 merge 實際新增的詞條數。
    var inserted: Int = 0
    /// 這輪 merge 實際更新（使用者可見內容真的不同）的詞條數；**不含複習狀態**。
    var updated: Int = 0
    /// 這輪 merge 實際刪除（remote soft-delete 或 orphan cleanup）的詞條數。
    var deleted: Int = 0

    /// 使用者可感知的變動筆數。
    var changedEntryCount: Int { inserted + updated + deleted }
    var hasChanges: Bool { changedEntryCount > 0 }

    static let unchanged = KGPullOutcome(pipelinePending: false)
}

/// 背景同步能力（窄協定）— 供顯式同步 UI（書架 pull-to-refresh / Mac toolbar /
/// ⌘R menu）依賴與 mock。比照 `LocalDataClearing` 的能力切分：consumer 只需這兩個
/// 成員，無謂背 `KGServing` 全表。`KGServing` 細化此協定，故 `any KGServing` 可直接
/// 傳入需要 `any BackgroundSyncing` 之處（existential upcast）。
protocol BackgroundSyncing: AnyObject {
    /// 最近一次背景同步失敗訊息（nil = 成功）。為跨 trigger 共享全域欄位，顯式同步
    /// consumer 須 read-then-clear（見 `ExplicitSync` / `BooksAndVocabApp` scenePhase）。
    var lastBackgroundSyncError: String? { get set }
    func backgroundSync(container: ModelContainer) async
    /// 逐步回報版本。`progress` 收到的事件描述「哪一步、走到哪」，供設定頁把單一
    /// 「同步中…」攤成逐步清單 + 進度條。
    ///
    /// 之所以是**額外一支**而不是給既有那支加參數：加參數會讓每個 mock 都得改
    /// 簽名，而它們一個都不關心進度。下面的預設實作把 reporter 丟掉並轉呼無參數
    /// 版，所以既有 conformance 零改動；只有真的會回報的 `KGService` 自己覆寫。
    ///
    /// 回傳 `SyncRoundOutcome` 是因為「這一輪發生了什麼」不能從
    /// `lastBackgroundSyncError` 讀——那是四個 trigger 共用的全域欄位，理由見該型別。
    @discardableResult
    func backgroundSync(container: ModelContainer, progress: SyncProgressReporting?) async -> SyncRoundOutcome

    /// Queue a foreground/settings request behind an already-running sync.
    /// The ordinary entry point intentionally returns `.didNotRun` when a
    /// trigger is already active; an explicit account-boundary request must
    /// not silently inherit that result from the previous account.
    @discardableResult
    func backgroundSyncWhenAvailable(
        container: ModelContainer,
        progress: SyncProgressReporting?
    ) async -> SyncRoundOutcome
}

extension BackgroundSyncing {
    @discardableResult
    func backgroundSync(container: ModelContainer, progress: SyncProgressReporting?) async -> SyncRoundOutcome {
        await backgroundSync(container: container)
        return .completed
    }

    @discardableResult
    func backgroundSyncWhenAvailable(
        container: ModelContainer,
        progress: SyncProgressReporting?
    ) async -> SyncRoundOutcome {
        await backgroundSync(container: container, progress: progress)
    }
}

/// 共享牌組複製能力（窄協定）— 供 Explore 複製流程（`SharedDeckCopyController`）依賴
/// 與 mock，比照 `BackgroundSyncing` 的能力切分。`KGServing` 細化此協定，故 `any
/// KGServing` 可直接當 `any DeckCopying` 傳入複製 controller。
protocol DeckCopying: AnyObject {
    /// `POST /api/decks/{deckId}/copy`（需登入 CurrentUser）。`idempotencyKey` 讓
    /// transport retry 安全 —— 同 key 永遠短路回同一 notebook，絕不重複複製。
    /// `notebookName` 非 nil 時覆寫 server 自動命名（server 仍保證與活躍 notebook 名唯一）。
    func copyDeck(deckId: String, idempotencyKey: String, notebookName: String?) async throws -> DeckCopyResponse
}

/// 認證 token 讀取能力。需要 token 的 leaf consumer 不應依賴整張 KG service。
protocol AuthTokenProviding: AnyObject {
    func currentAuthToken() async throws -> String
    func authTokenWithoutInvalidation() async -> String?
    /// 伺服器真實 401 時呼叫（#2806：本地時鐘判斷不得觸發登出）。
    func handleUnauthorized(modelContainer: ModelContainer?, reason: String) async
}

/// 後端健康狀態檢查能力。
protocol HealthChecking: AnyObject {
    func healthCheck() async
}

/// Notebook CRUD 能力。
protocol NotebookServing: AnyObject {
    func fetchNotebooks() async throws -> [KGNotebook]
    func createNotebook(name: String, color: String?, coverPattern: String?) async throws -> KGNotebook
    func updateNotebook(id: String, name: String?, color: String?, coverPattern: String?) async throws -> KGNotebook
    func updateNotebookSettings(
        id: String,
        reviewPolicy: KGNotebookSettingsPatchGroup<KGNotebookReviewPolicy>?,
        cardLayout: KGNotebookSettingsPatchGroup<KGNotebookCardLayout>?
    ) async throws -> KGNotebook
    func deleteNotebook(id: String) async throws
}

extension NotebookServing {
    /// Older fixture services can keep their metadata-only notebook contract;
    /// the settings screen treats this as a best-effort remote capability and
    /// retains the local projection when the server does not implement it.
    func updateNotebookSettings(
        id: String,
        reviewPolicy: KGNotebookSettingsPatchGroup<KGNotebookReviewPolicy>?,
        cardLayout: KGNotebookSettingsPatchGroup<KGNotebookCardLayout>?
    ) async throws -> KGNotebook {
        throw URLError(.unsupportedURL)
    }
}

/// 使用者設定讀取能力。
protocol UserConfigFetching: AnyObject {
    func fetchUserConfig() async throws -> KGUserConfig
}

/// 使用者設定讀寫能力。
protocol UserConfigServing: UserConfigFetching {
    func updateTranslationConfig(_ translationConfig: KGTranslationConfig) async throws -> KGUserConfig
    func updateReviewClockConfig(_ reviewClock: KGReviewClockConfig) async throws -> KGUserConfig
    func updateReviewModeConfig(_ reviewMode: KGReviewModeConfig) async throws -> KGUserConfig
    func updateVocabUIConfig(_ vocabUI: KGVocabUIConfig) async throws -> KGUserConfig
    func updateAutoLinkConfig(_ autoLink: KGAutoLinkConfig) async throws -> KGUserConfig
}

/// 學習卡刪除能力。
protocol VocabularyDeleting: AnyObject {
    func deleteCard(word: String, notebookId: String) async throws
    func batchDeleteCards(words: [String], notebookId: String) async throws -> KGBatchDeleteResponse
}

/// 單張學習卡封存能力。
protocol CardArchiving: AnyObject {
    func archiveCard(word: String, archived: Bool, notebookId: String) async throws
}

/// 學習詞彙同步與 CRUD 能力。
protocol VocabularySyncServing: VocabularyDeleting, CardArchiving {
    func batchAdd(entries: [VocabularyEntry], notebookId: String) async throws -> KGAddResponse
    func triggerPipeline(notebookId: String) async throws
    @discardableResult
    func pullCardsToLocal(container: ModelContainer, progress: ((String, Int, Int) -> Void)?, notebookId: String?) async throws -> KGPullOutcome
    func batchArchiveCards(words: [String], archived: Bool, notebookId: String) async throws -> KGBatchArchiveResponse
}

/// 知識圖譜連結能力。
protocol GraphServing: AnyObject {
    func pullGraphLinks() async throws -> [KGGraphLink]
    func pullGraphLinks(notebookId: String) async throws -> [KGGraphLink]
    func createManualLink(fromId: String, toId: String, notebookId: String) async throws -> KGGraphLink
    func deleteLink(linkId: String, notebookId: String) async throws
    func hideLink(linkId: String, notebookId: String) async throws
    func unhideLink(linkId: String, notebookId: String) async throws
}

extension GraphServing {
    /// Backwards-compatible default for fixture and lightweight test services.
    /// Production `KGService` overrides this to preserve notebook isolation.
    func pullGraphLinks(notebookId: String) async throws -> [KGGraphLink] {
        try await pullGraphLinks()
    }

    /// Fans out one request per notebook and merges the results (de-duplicated
    /// by link id). The backend endpoint is per notebook, so all-/multi-notebook
    /// graphs must not rely on `pullGraphLinks()` (default notebook only).
    /// A 403 means the notebook was deleted or is not ours and is skipped; any
    /// other error propagates so a partial graph is never shown as complete.
    func pullGraphLinks(notebookIDs: [String]) async throws -> [KGGraphLink] {
        var seen = Set<String>()
        var merged: [KGGraphLink] = []
        for id in notebookIDs {
            let links: [KGGraphLink]
            do {
                links = try await pullGraphLinks(notebookId: id)
            } catch KGError.httpError(let code, _) where code == 403 {
                continue
            }
            for link in links where seen.insert(link.id).inserted {
                merged.append(link)
            }
        }
        return merged
    }
}

/// 複習同步能力。
protocol ReviewSyncServing: AnyObject {
    func pushReviewStates(container: ModelContainer) async throws -> (updated: Int, skipped: Int)
    func pushReviewEvents(container: ModelContainer) async throws -> (inserted: Int, skipped: Int)
    func pullReviewEvents(container: ModelContainer) async throws
    func pushReviewQuietly(container: ModelContainer) async
}

/// 額度讀取能力。
protocol QuotaServing: AnyObject {
    func fetchQuota() async
}

/// 帳號刪除能力。
protocol AccountErasing: AnyObject {
    func deleteAccount() async throws
}

/// Pro-only external API key management. The app uses the normal JWT-authenticated
/// KG service for these management calls; the returned plaintext secret is never
/// persisted by the client and is absent from list/revoke responses.
protocol ExternalAPIKeyManaging: AnyObject {
    func fetchExternalAPIKeys() async throws -> [KGExternalAPIKey]
    func createExternalAPIKey(label: String) async throws -> KGExternalAPIKey
    func revokeExternalAPIKey(id: String) async throws -> KGExternalAPIKey
}

/// Local reset capability exposed to Settings. The throwing contract is
/// intentional: a terminal success must mean the backing cleanup completed.
protocol LocalDataResetting: AnyObject {
    func clearLocalData(container: ModelContainer, reason: String) async throws
}

/// 訂閱與 entitlement 能力。
protocol SubscriptionServing: AnyObject {
    func fetchEntitlements() async throws -> KGEntitlements
    func syncAppStoreSubscription(_ snapshot: KGAppStoreSubscriptionSyncRequest) async throws -> KGEntitlements
}

/// KGService 的完整組合契約；leaf consumer 應依賴上面的最小能力協定。
protocol KGServing:
    BackgroundSyncing,
    DeckCopying,
    AuthTokenProviding,
    HealthChecking,
    NotebookServing,
    UserConfigServing,
    VocabularySyncServing,
    GraphServing,
    ReviewSyncServing,
    QuotaServing,
    AccountErasing,
    ExternalAPIKeyManaging,
    SubscriptionServing,
    LocalDataResetting
{
    var serverURL: String { get set }
    var isConnected: Bool { get }
    var lastSyncDate: Date? { get }
    var serverCardCount: Int { get }
    var sessionExpiredReason: String? { get set }

    /// 複製成功後把新 notebook + 其卡片針對性拉回本地。回傳 notebook 列表對帳是否完整成功
    /// （`true` 才可據以確證「目標已不在 server」；見 `KGService.pullCopiedDeck`）。
    @discardableResult
    func pullCopiedDeck(container: ModelContainer, notebookId: String) async -> Bool
}
