//
//  VocabularyEntry.swift
//  Books & Vocab
//
//  Created by 陳亮宇 on 2026/2/24.
//

import Foundation
import SwiftData

enum VocabularySyncState: Int, Codable {
    case pending = 0
    case synced = 1
    case failed = 2
}

enum VocabularySyncAction: String, Codable {
    case add
    case delete
    case edit
}

/// 生詞條目 — 記錄使用者在閱讀中查詢的單字/短語
@Model
final class VocabularyEntry {
    #Index<VocabularyEntry>([\.notebookId], [\.word], [\.dateAdded])

    var id: UUID
    var word: String                // 原文單字或短語
    var translation: String         // 翻譯結果
    var context: String             // 來源句子（上下文）
    var explanation: String?        // AI 語境解釋
    var partOfSpeech: String?       // 詞性
    var bookTitle: String           // 來源書名
    var chapterTitle: String?       // 來源章節
    var dateAdded: Date

    // Inflection forms for underlining (e.g. "lay" → ["lay","lays","laid","laying","lain"])
    var rootForm: String?           // AI-determined lemma, sent to server on sync
    var inflections: [String] = []  // filled by server after sync

    // KG Integration
    var syncStatus: Int = 0         // 0=pending, 1=synced, 2=failed
    var kgCardId: String?           // KG 卡片 ID（同步後回填）
    /// 後端對 add 的確定性拒收原因（`rejected[].reason`，#2793）。非 nil 代表終態：
    /// `failed + add` 不再自動重送（否則每次 sync 都被同一原因拒收並重報錯誤）。
    /// 任何重新排入 add 的路徑（`restorePendingEntry`）或同步成功（`markSynced`）都清除。
    /// Optional，SwiftData lightweight migration 時既有 row 為 nil。
    var rejectedReason: String?
    /// 使用者把伺服器已持有的 note 清空、尚未同步（#2550）。`explanation` 此時為 nil，PATCH 須送明確的 ""
    /// 才會清除伺服器 note；nil 在 wire 上是「未變更」。`markSynced`（編輯成功）時清除。
    /// Lightweight migration：既有 row 預設 false。
    var explanationClearPending: Bool = false
    /// 送出 batchAdd 的時點（持久化，#3073）。送出後若回應未確認（取消、失敗），server 可能已建立此卡，
    /// 因此本地刪除必須排 server delete 而非硬刪，否則下一輪 pull 會復活卡片。server 確認（cardIds 命中、
    /// `markSynced`）後清除。Optional，lightweight migration 時既有 row 為 nil。
    var uploadSubmittedAt: Date?
    /// 排入刪除（`queueDelete`）前仍未送出的 edit 標記（rawValue `edit`，#3059 (5)）；其餘情況為 nil。
    /// 撤銷刪除時據此回到 pending edit 保留編輯內容，不得經 `markSynced` 丟掉。被 T12 拒收的 edit 不記錄（終態不復活）。
    /// 第二次 `queueDelete` 不覆寫此值。`markSynced`／`restorePendingEntry`／`restoreUnsentEdit` 清除。
    /// Optional，SwiftData lightweight migration 時既有 row 為 nil。
    var actionBeforeDeleteRaw: String?
    var difficultyTier: String?     // "core" / "intermediate" / "advanced" / "rare"
    var actionType: String = "add"  // "add" | "delete" | "edit"
    var reviewModeRaw: String = VocabularyCardMode.recognition.rawValue
    var reviewExamples: [String] = []
    var collocations: [String] = []
    var collocationExplanationsJSON: String = "{}"
    var graphLinksJSON: String = "{}"
    var isArchived: Bool = false
    var isReaderHidden: Bool = false
    var isReviewExcluded: Bool = false
    /// True from the moment the sync engine captures this entry until that sync returns. While true, a user
    /// delete queues a server delete instead of hard-deleting a row the sync still holds (#2733), and undo or a
    /// reader re-capture does not restore the row (I3, #2484). Transient: set only by the sync engine.
    @Transient var isUploadInFlight = false

    // Local spaced-review state
    var reviewIntervalHours: Double = VocabularyReviewPolicy.initialIntervalHours
    var nextReviewAt: Date = Date().addingTimeInterval(VocabularyReviewPolicy.initialIntervalHours * 3600)
    var lastReviewedAt: Date?
    var reviewCount: Int = 0
    var lapseCount: Int = 0
    var reviewStreak: Int = 0
    var lastReviewFeedbackRaw: Int = -1

    /// When this card's SRS state was last accepted by the backend.
    ///
    /// Without it the client had no way to tell "the server already has this
    /// schedule" from "this changed", so every sync re-sent every synced card's
    /// review state (644 cards in production) for the server to compare and
    /// mostly discard. Optional so existing rows arrive as `nil` and are sent
    /// once — the backend schedules from `next_review_at`, so a card it has
    /// never heard about must still be reported at least once.
    var reviewStateSyncedAt: Date?

    /// Whether the backend is missing this card's current SRS state.
    ///
    /// Compares against `lastReviewedAt ?? dateAdded`, the same instant the push
    /// payload sends as `last_reviewed_at`, so "what we told the server" and
    /// "what we compare against" cannot drift apart.
    var needsReviewStatePush: Bool {
        guard let syncedAt = reviewStateSyncedAt else { return true }
        return (lastReviewedAt ?? dateAdded) > syncedAt
    }

    /// 使用者在 app 內改了複習方向（#2042），尚未被 server 確認（preferences PATCH 的 `mode`）。
    /// 為真時 pull 不覆寫 `reviewMode` 與 SRS 狀態（本地意圖優先）；確認後由 `markReviewModePushed` 清除。
    /// Lightweight migration：既有 row 預設 false。
    var pendingReviewModePush: Bool = false
    /// 使用者重設進度（#2042）尚未被 server 確認。推送時帶 `override: true`，server 原樣寫入 counts（不取 max）。
    /// 為真時 pull 不 merge review state；確認（`markReviewStatesPushed` 且 `lastReviewedAt` 未再變動）後清除。
    /// Lightweight migration：既有 row 預設 false。
    var pendingReviewProgressReset: Bool = false

    var notebookId: String = "default"
    var bookId: UUID?
    var isDemoEntry: Bool = false

    // i18n: source/target language captured when this entry was created.
    // Optional for SwiftData lightweight migration — existing rows keep nil
    // until they're touched. Upload to server is gated by
    // `KGFeatureFlags.vocabularyLangPayloadEnabled` (backend currently has
    // `extra='ignore'` so the fields would be silently dropped today).
    var sourceLang: String?
    var targetLang: String?

    @Transient private var _graphLinksCache: [String: [KGCardLinkSummary]]?
    @Transient private var _graphLinksCacheKey: String?

    /// Sync status convenience
    var syncState: VocabularySyncState {
        get { VocabularySyncState(rawValue: syncStatus) ?? .pending }
        set { syncStatus = newValue.rawValue }
    }

    var syncAction: VocabularySyncAction {
        get { VocabularySyncAction(rawValue: actionType) ?? .add }
        set { actionType = newValue.rawValue }
    }

    var isFailed: Bool { syncState == .failed }
    var isSynced: Bool { syncState == .synced }
    var isPending: Bool { syncState == .pending }
    var isPendingAdd: Bool { syncState == .pending && syncAction == .add }
    var isPendingDelete: Bool { syncState == .pending && syncAction == .delete }
    var isPendingEdit: Bool { syncState == .pending && syncAction == .edit }
    var isFailedAdd: Bool { syncState == .failed && syncAction == .add }
    var isFailedDelete: Bool { syncState == .failed && syncAction == .delete }
    var isFailedEdit: Bool { syncState == .failed && syncAction == .edit }
    /// 後端拒收的 add（終態，見 `rejectedReason`）。
    var isRejectedAdd: Bool { isFailedAdd && rejectedReason != nil }
    /// 後端確定性拒收的 edit（4xx，見 T12）。
    var isRejectedEdit: Bool { isFailedEdit && rejectedReason != nil }
    var shouldUploadOnNextSync: Bool {
        isPendingAdd || isPendingDelete || isPendingEdit
            || (isFailedAdd && !isRejectedAdd) || isFailedDelete || (isFailedEdit && !isRejectedEdit)
    }
    var shouldAppearInReader: Bool { syncAction != .delete && !isArchived && !isReaderHidden }
    var shouldAppearInReview: Bool { shouldAppearInKnowledgeList && !isReviewExcluded }
    var shouldAppearInKnowledgeList: Bool { isSynced && syncAction != .delete && !isArchived }
    var shouldAppearInArchiveList: Bool { isSynced && syncAction != .delete && isArchived }
    var effectiveDateAdded: Date { dateAdded }

    /// Shared `#Predicate` for SwiftData `@Query` knowledge-list call sites.
    /// `#Predicate` can't reference the `shouldAppearInKnowledgeList` computed
    /// property (it needs stored keypaths), so the condition is expressed once
    /// here — keeping KGVocabView / NotebookListView from drifting. Pass
    /// `notebookId` to additionally scope to one notebook.
    static func knowledgeListPredicate(notebookId: String? = nil) -> Predicate<VocabularyEntry> {
        if let notebookId {
            return #Predicate {
                $0.syncStatus == 1 && $0.actionType != "delete" && $0.isArchived == false && $0.notebookId == notebookId
            }
        }
        return #Predicate {
            $0.syncStatus == 1 && $0.actionType != "delete" && $0.isArchived == false
        }
    }

    init(
        word: String,
        translation: String,
        context: String,
        explanation: String? = nil,
        partOfSpeech: String? = nil,
        bookTitle: String,
        chapterTitle: String? = nil,
        sourceLang: String? = nil,
        targetLang: String? = nil
    ) {
        self.id = UUID()
        self.word = word
        self.translation = translation
        self.context = context
        self.explanation = explanation
        self.partOfSpeech = partOfSpeech
        self.bookTitle = bookTitle
        self.chapterTitle = chapterTitle
        self.dateAdded = Date()
        // Default to the user's current translation language pair if caller
        // didn't override. Captured at creation time so future schema changes
        // can analyse per-locale usage without backfilling.
        self.sourceLang = sourceLang ?? TranslationLanguage.currentSource.rawValue
        self.targetLang = targetLang ?? TranslationLanguage.currentTarget.rawValue
    }
}

extension VocabularyEntry {
    /// 解析 notebookId 候選值，若不存在或已 soft-deleted → 回 "default"。
    ///
    /// 純函數。所有把使用者輸入 / 上層 binding 的 notebook id 寫入 `VocabularyEntry`
    /// 之前都應該走這裡，避免 race condition 把孤兒 entry 塞進已刪 notebook。
    /// 與 `SyncCoordinator.sanitizeOutbox` 形成 defense-in-depth。
    ///
    /// 「default」是 server-side sentinel，即使 local 出現 `Notebook(remoteId="default", isSoftDeleted=true)`
    /// 的損壞紀錄也必須回 "default" — 這是刻意的 short-circuit，don't "fix" it。
    ///
    /// **Cold-start guard**：若 local Notebook 表完全空（首次登入 / 尚未 reconcile），
    /// 直接回原候選值 — 此時無從判斷候選是否合法，誤判 fallback 到 default 會
    /// 永久污染 outbox。對齊 `ReaderView.sanitizeStaleBoundNotebook` 的「liveNotebooks
    /// 為空時 bail」契約。
    static func resolveNotebookId(
        _ candidate: String,
        in context: ModelContext
    ) -> String {
        if candidate.isEmpty || candidate == "default" { return "default" }

        // Cold-start guard: 表完全空 → 不夠資訊判斷，回原值
        let totalCount = (try? context.fetchCount(FetchDescriptor<Notebook>())) ?? 0
        guard totalCount > 0 else { return candidate }

        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.remoteId == candidate && !$0.isSoftDeleted }
        )
        let count = (try? context.fetchCount(descriptor)) ?? 0
        return count > 0 ? candidate : "default"
    }

    // MARK: Outbox 狀態機（sync lane 依賴的轉移；改任一轉移須同步檢查本段與 docs/reference/sync_lifecycle.md）
    //
    // 欄位：syncAction ∈ {add, edit, delete}、syncState ∈ {pending, synced, failed}、
    // kgCardId（只在 server 確認卡片存在後寫入：pull 命中、batchAdd cardIds 命中、edit 成功）、
    // isUploadInFlight（transient，自 sync 擷取起至 sync 返回為止）。
    //
    // I1  kgCardId 非空 ⇒ server 持有此卡。
    // I2  markSynced() 只在 server 已確認卡片時呼叫。撤銷刪除時 kgCardId 為空不得 markSynced（#2484）。
    // 推論：pending+delete 且 kgCardId 為空 ＝ 「server 可能沒有此卡」，不代表 server 有卡；
    //       交下一輪 batchDelete 收斂（deleted／not_found 本地移除，其餘 failed 重試）。
    // I3  isUploadInFlight 為真（sync 擷取起至返回）時，使用者的撤銷與閱讀器重新擷取不得改寫列的 syncAction；
    //     唯一允許的使用者轉移是 → delete（T1）。擷取時為 delete 的列，回應到達時仍為 delete，
    //     故 sync 的 post-await 只守 syncAction == .delete 與 in-flight，不需撤銷競態分支（#2484 r8）。
    //
    // T1 deleteLocally：synced ∨ in-flight ∨ kgCardId 非空 ∨ uploadSubmittedAt 非 nil → queueDelete（列保留）；其餘 → 硬刪。
    // T2 batchAdd cardIds 命中：寫 kgCardId、清 uploadSubmittedAt；action 為 add 才 markSynced，為 delete 則維持 pending delete。
    // T3 batchAdd rejected：markRejected → add+failed（rejectedReason 終態）；action 為 delete 則維持 pending delete。
    // T4 batchAdd 失敗：markSyncFailed（只改 syncState，被刪的 in-flight add 維持 delete；uploadSubmittedAt 保留，server 是否已建卡未知）。
    // T5 batchDelete resolvable（deleted／not_found）且 action 仍為 delete → 硬刪（I3 下恆成立，守門保留作防禦）。
    // T6 batchDelete 其餘 → markSyncFailed（delete+failed，重試）。
    // T7 undoQueuedDelete：in-flight → no-op（I3）；kgCardId 非空 → 排入前為未送出 edit 則 restoreUnsentEdit（edit+pending，保留編輯，#3059 (5)），否則 markSynced；為空 → restorePendingEntry（add+pending，下一輪上傳）。
    // T8 edit 成功：action 仍為 edit 且送出的 translation／note 與目前列相符才 markSynced（清除 explanationClearPending）；
    //     成功前被刪者維持 delete；送出後被改寫者維持 pending edit，交下一輪上傳較新內容（#3248）。
    // T9 pull 命中：delete 列與未同步的 edit 列保留本地意圖（不覆寫）；其餘 markSynced。
    // T10 restorePendingEntry（sanitize 收斂、非 in-flight 的撤銷與重新擷取）：add+pending，永不宣稱 synced。
    //     閱讀器重新擷取遇到 in-flight 的 delete 列時不呼叫它（I3），改新增一筆 add。
    // T11 NotebookReconciler cascade 的 queueDelete 可作用於 kgCardId 為空的 add：delete+pending，交 T5 以 not_found 收斂。
    // T12 edit 回 4xx（401／429 除外）：markEditRejected → edit+failed（rejectedReason 終態，不再納入 shouldUploadOnNextSync）；
    //     action 為 delete 則維持 pending delete（同 T3，#2733）。使用者再次編輯 → queueEdit 清除 rejectedReason 並重新 pending。
    //     5xx／網路錯誤維持 T4 的可重試 markSyncFailed。
    // T13 本地改複習方向（requestReviewMode）：只排 pendingReviewModePush；mode 確認後清除（#2042）。
    // T14 本地重設進度（resetReviewProgress）：counts 歸零、排 pendingReviewProgressReset，推送帶 override；確認後清除（#2042）。
    //     兩者 pending 期間 pull 不覆寫 reviewMode、不 mergeReviewState（本地意圖優先，#2042）。

    func queueDelete() {
        // 只記錄排入前仍未送出的 edit（pending 或可重試的 failed）。被 T12 拒收的 edit 是終態，不記錄，
        // 否則撤銷刪除會把已被 server 4xx 拒收的內容重新排入上傳。第二次 queueDelete 不覆寫（syncAction 已是 delete）。
        if syncAction != .delete {
            actionBeforeDeleteRaw = (syncAction == .edit && shouldUploadOnNextSync) ? VocabularySyncAction.edit.rawValue : nil
        }
        syncAction = .delete
        syncState = .pending
        rejectedReason = nil
    }

    /// A row whose server copy exists or is being created must not be hard-deleted locally:
    /// the server card would be re-pulled and resurrected (#2733).
    /// `hasServerCard`（kgCardId 非空）即代表 server 已有卡片；編輯 synced 卡會把 syncState 改為 pending+edit，
    /// 但 kgCardId 保留，因此不能只靠 `isSynced` 判斷。
    var hasServerCard: Bool { !(kgCardId ?? "").isEmpty }

    /// PATCH 的 note 欄位三態（#2550）：nil＝省略（伺服器值不變）；""＝明確清空；其餘＝設定值。
    var explanationUpdateValue: String? {
        explanationClearPending ? "" : explanation
    }

    /// `uploadSubmittedAt` 代表 add 已送出但未獲確認：server 可能持有此卡（#3073）。
    var requiresServerDelete: Bool { isSynced || isUploadInFlight || hasServerCard || uploadSubmittedAt != nil }

    /// Single local delete entry point for user-initiated deletes.
    func deleteLocally(in modelContext: ModelContext) {
        if requiresServerDelete {
            queueDelete()
        } else {
            modelContext.delete(self)
        }
    }

    /// 撤銷尚未送出的刪除（SyncView「還原」）。in-flight 時為 no-op（I3）：列的去留由進行中的 sync 回應決定，
    /// 撤銷會與回應競態（#2484 r8）；sync 返回後仍存在的 delete 列才可撤銷。
    /// 只有 server 確認持有卡片（`hasServerCard`）才能回到 synced 或未送出的 edit（T7）；否則 server 從未確認此卡，必須重新排入 pending add，由下一輪 batchAdd 建立（T7）。
    /// 無 kgCardId 卻 markSynced 會得到「synced 但 server 沒有」的列，full pull 的 orphan cleanup 會把它刪掉（#2484）。
    func undoQueuedDelete() {
        guard syncAction == .delete, !isUploadInFlight else { return }
        if hasServerCard {
            // 排入刪除前的未送出編輯：server 卡仍是編輯前的內容，回到 pending edit 待上傳（T7，#3059 (5)）。
            if actionBeforeDeleteRaw == VocabularySyncAction.edit.rawValue {
                restoreUnsentEdit()
            } else {
                markSynced()
            }
        } else {
            restorePendingEntry()
        }
    }

    func restorePendingEntry() {
        syncAction = .add
        syncState = .pending
        rejectedReason = nil
        actionBeforeDeleteRaw = nil
    }

    func restoreUnsentEdit() {
        syncAction = .edit
        syncState = .pending
        rejectedReason = nil
        actionBeforeDeleteRaw = nil
    }

    func markSynced() {
        syncAction = .add
        syncState = .synced
        rejectedReason = nil
        explanationClearPending = false
        uploadSubmittedAt = nil
        actionBeforeDeleteRaw = nil
    }

    func markSyncFailed() {
        syncState = .failed
    }

    /// 後端確定性拒收的 add：進終態，不再納入 `shouldUploadOnNextSync`。
    ///
    /// 例外：add 在 in-flight 期間被使用者刪除（`queueDelete` 已覆寫 syncAction）時，刪除意圖必須保留。
    /// server 從未建立該卡，下一輪 batchDelete 會回 not_found，由 `locallyResolvableDeletes` 本地移除（#2733）。
    /// 若這裡改寫成 terminal rejected add，SyncView 會永久顯示一筆使用者已刪除的字。
    func markRejected(reason: String) {
        guard syncAction != .delete else {
            syncState = .pending
            return
        }
        syncAction = .add
        syncState = .failed
        rejectedReason = reason
    }

    /// 後端確定性拒收的 edit（T12）：進終態，delete 在 in-flight 期間覆寫時保留 pending delete。
    func markEditRejected(reason: String) {
        guard syncAction != .delete else {
            syncState = .pending
            return
        }
        syncState = .failed
        rejectedReason = reason
    }

    /// 使用者再次編輯已同步或已拒收的卡：重新排入 pending edit，清除上次的拒收原因（T12）。
    func queueEdit() {
        syncAction = .edit
        syncState = .pending
        rejectedReason = nil
    }

    func prepareForRetryAttempt() {
        if isFailed && !isRejectedAdd && !isRejectedEdit {
            syncState = .pending
        }
    }

    var reviewMode: VocabularyCardMode {
        get { VocabularyCardMode(rawValue: reviewModeRaw) ?? .recognition }
        set { reviewModeRaw = newValue.rawValue }
    }

    /// 本地改複習方向（#2042）：SRS 狀態不動，只排入 mode 推送（T13）。
    func requestReviewMode(_ mode: VocabularyCardMode) {
        guard reviewMode != mode else { return }
        reviewMode = mode
        pendingReviewModePush = true
    }

    /// 本地重設進度（#2042）：counts 歸零、排程從 `now` 立即到期，排入 override 推送（T14）。
    /// `lastReviewedAt = now` 是本次重設的 sent-instant 基準，確認時以它對齊（見 `markReviewStatesPushed`）。
    /// server watermark 可能超前於裝置時鐘，故推送不靠 `needsReviewStatePush`，改由 `pendingReviewProgressReset` 保證送出。
    func resetReviewProgress(now: Date) {
        reviewIntervalHours = VocabularyReviewPolicy.initialIntervalHours
        nextReviewAt = now
        lastReviewedAt = now
        reviewCount = 0
        lapseCount = 0
        reviewStreak = 0
        lastReviewFeedbackRaw = -1
        pendingReviewProgressReset = true
    }

    var primaryReviewExample: String? {
        reviewExamples.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ??
        (context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : markWordInContext(context))
    }

    var allReviewExamples: [String] {
        let remoteExamples = reviewExamples.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if remoteExamples.isEmpty {
            let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [markWordInContext(trimmed)]
        }
        return remoteExamples
    }

    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func cachedRegex(pattern: String, options: NSRegularExpression.Options = .caseInsensitive) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

    /// 在 context 純文字中為 word 加上 **markdown** 標記（模擬 server 的 _build_example 邏輯）
    private func markWordInContext(_ text: String) -> String {
        // Whole-word boundaries, mirroring backend `_build_example` (#2725): try `[word, *inflections]`
        // in order so that e.g. "run" still bolds "runs" when the base form is absent.
        // 先 trim 再比對：未 trim 的 " runs " 會把前後空白一併加粗，且 (?<!\w)/(?!\w) 的詞界語意被破壞。
        let terms = ([word] + inflections).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for term in terms where !term.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let boundaryPat = "(?<!\\w)\(escaped)(?!\\w)"
            if let regex = Self.cachedRegex(pattern: boundaryPat),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let ns = text as NSString
                let matched = ns.substring(with: match.range)
                return ns.replacingCharacters(in: match.range, with: "**\(matched)**")
            }
        }
        // stem fallback: 前 4-6 字元
        let firstWord = word.components(separatedBy: " ").first ?? word
        if firstWord.count >= 4 {
            let stem = String(firstWord.prefix(min(firstWord.count, 6)))
            let stemEsc = NSRegularExpression.escapedPattern(for: stem)
            let stemPat = "(?<![\\w\\p{L}])\(stemEsc)\\w*(?![\\w\\p{L}])"
            if let stemRegex = Self.cachedRegex(pattern: stemPat),
               let match = stemRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let ns = text as NSString
                let matched = ns.substring(with: match.range)
                return ns.replacingCharacters(in: match.range, with: "**\(matched)**")
            }
        }
        return text
    }

    // MARK: - Link mutation helpers

    /// Finds a link by `id` across all kind-groups, applies `transform`, and returns the original.
    /// - If `transform` returns a new link → replaces in-place.
    /// - If `transform` returns `nil` → removes (and cleans up empty groups).
    /// - Returns `nil` when no link with the given `id` exists.
    @discardableResult
    func mutateLink(id linkId: String, _ transform: (KGCardLinkSummary) -> KGCardLinkSummary?) -> (kind: String, link: KGCardLinkSummary)? {
        var dict = graphLinksByKind
        for (kind, links) in dict {
            guard let idx = links.firstIndex(where: { $0.id == linkId }) else { continue }
            let original = links[idx]
            if let replacement = transform(original) {
                dict[kind]?[idx] = replacement
            } else {
                dict[kind]?.remove(at: idx)
                if dict[kind]?.isEmpty == true { dict[kind] = nil }
            }
            graphLinksByKind = dict
            return (kind: kind, link: original)
        }
        return nil
    }

    /// Re-inserts a link into a specific kind-group (used for rollback after delete).
    func insertLink(_ link: KGCardLinkSummary, kind: String) {
        var dict = graphLinksByKind
        dict[kind, default: []].append(link)
        graphLinksByKind = dict
    }

    var collocationExplanations: [String: String] {
        get {
            guard let data = collocationExplanationsJSON.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            collocationExplanationsJSON = (try? JSONEncoder().encode(newValue))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
    }

    var graphLinksByKind: [String: [KGCardLinkSummary]] {
        get {
            // Invalidate cache when underlying JSON changes (e.g. cross-context sync)
            if let cached = _graphLinksCache, _graphLinksCacheKey == graphLinksJSON {
                return cached
            }
            guard let data = graphLinksJSON.data(using: .utf8) else { return [:] }
            let decoded = (try? JSONDecoder().decode([String: [KGCardLinkSummary]].self, from: data)) ?? [:]
            _graphLinksCache = decoded
            _graphLinksCacheKey = graphLinksJSON
            return decoded
        }
        set {
            _graphLinksCache = newValue
            guard
                let data = try? JSONEncoder().encode(newValue),
                let json = String(data: data, encoding: .utf8)
            else {
                graphLinksJSON = "{}"
                _graphLinksCacheKey = "{}"
                return
            }
            graphLinksJSON = json
            _graphLinksCacheKey = json
        }
    }
}
