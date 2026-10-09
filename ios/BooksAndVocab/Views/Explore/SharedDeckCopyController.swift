//
//  SharedDeckCopyController.swift
//  Books & Vocab
//
//  Explore 複製流程狀態機（idle/inflight/success/failure）+ idempotencyKey 穩定性。
//  擁有者 = `SharedDeckCopyRegistry`（依 deckId，跨 view pop/reopen；#2748）。純狀態 + 一支 async `copy`；網路只透過注入的
//  `any DeckCopying`（窄協定），故可完整單元測試（無 SwiftData / 無真實網路）。
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

    /// Test seam：注入決定性的 key 產生器。
    private let makeKey: () -> String

    init(makeKey: @escaping () -> String = { UUID().uuidString }) {
        self.makeKey = makeKey
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
        if let kg = error as? KGError, case .unauthorized = kg { return "unauthorized" }
        if isOffline(error) { return "offline" }
        return "generic"
    }

    /// 錯誤 → user-facing 訊息映射。以 error type 判別（不依賴 NetworkMonitor 單例，
    /// 保持可決定性測試）。
    static func message(for error: Error) -> String {
        if let kg = error as? KGError, case .unauthorized = kg {
            return L10n.string("explore.copy.error.unauthorized")
        }
        if isOffline(error) {
            return L10n.string("explore.copy.error.offline")
        }
        return L10n.string("explore.copy.error.generic")
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

/// 以 deckId 為鍵的 controller 註冊表（#2748）。`SharedDeckDetailView` 的 `@State`
/// 在 pop 時被丟棄，但 `performCopy` 的 unstructured `Task` 仍在跑、idempotencyKey 也
/// 需跨 reopen 保留；controller 因此改由行程級註冊表持有，view 只借用。
/// 只在上一個已成功（意圖達成）時才換新 controller；其餘（idle / inflight / failure）
/// 都原樣回傳，故 reopen 的 view 會接回 inflight 或仍持有 key 的 failure 態，且 View
/// init 被重複求值也不會把註冊表與 view 手上的 controller 拆開。
@MainActor
final class SharedDeckCopyRegistry {
    static let shared = SharedDeckCopyRegistry()

    private var controllers: [String: SharedDeckCopyController] = [:]

    func controller(for deckId: String) -> SharedDeckCopyController {
        if let existing = controllers[deckId], !existing.isSucceeded {
            return existing
        }
        let fresh = SharedDeckCopyController()
        controllers[deckId] = fresh
        return fresh
    }
}
