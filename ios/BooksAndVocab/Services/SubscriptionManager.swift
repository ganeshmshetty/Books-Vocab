import Foundation
import StoreKit

enum SubscriptionPurchaseError: LocalizedError {
    case unverifiedTransaction
    case productNotFound(productID: String)

    var errorDescription: String? {
        switch self {
        case .unverifiedTransaction:
            return L10n.string("無法驗證 App Store 交易。")
        case .productNotFound(let productID):
            return L10n.format("App Store 找不到商品 %@。請確認 App Store Connect 的訂閱 Product ID、Bundle ID 與目前測試環境是否一致。", productID)
        }
    }
}

enum PaywallSource: String {
    case settings
    case sync
    case graph
    case reader
    case knowledge
    case podcast
}

@MainActor
protocol SubscriptionManaging: AnyObject {
    var entitlements: KGEntitlements { get }
    var isLoading: Bool { get }
    var lastError: String? { get }
    var productLoadFailed: Bool { get }
    var activePaywallSource: PaywallSource? { get set }
    var proProduct: Product? { get }
    var proProductIdentifier: String { get }
    var purchaseStatusMessage: String? { get }
    var hasProAccess: Bool { get }

    func refresh(using kgService: any KGServing, authManager: any AuthManaging, force: Bool) async
    func resyncAfterManagement(using kgService: any KGServing, authManager: any AuthManaging) async
    func loadProducts() async
    func purchasePro(using kgService: any KGServing, authManager: any AuthManaging) async
    func restorePurchases(using kgService: any KGServing, authManager: any AuthManaging) async
    func listenForTransactionUpdates(using kgService: any KGServing, authManager: any AuthManaging)
}

extension SubscriptionManaging {
    func refresh(using kgService: any KGServing, authManager: any AuthManaging) async {
        await refresh(using: kgService, authManager: authManager, force: false)
    }
}

@Observable
@MainActor
final class SubscriptionManager: SubscriptionManaging {
    static let shared = SubscriptionManager()
    static let proProductID = BrandIdentity.proProductID

    var entitlements = KGEntitlements(
        pro: KGSubscriptionStatus(
            is_active: false,
            product_id: nil,
            plan_name: "Books & Vocab Pro",
            price_display: nil,
            status: "inactive",
            is_trial: false,
            trial_days: 7,
            will_renew: false,
            expires_at: nil,
            source: "app_store",
            last_synced_at: nil
        )
    )
    /// In-flight operation count; overlapping ops (purchase + settings refresh) must not clear each other.
    private(set) var loadingDepth = 0
    var isLoading: Bool { loadingDepth > 0 }

    func beginLoading() { loadingDepth += 1 }
    func endLoading() { loadingDepth = max(0, loadingDepth - 1) }
    var lastError: String?
    /// 商品載入是否已耗盡重試仍失敗。只由 loadProducts 設定／清除；refresh 寫入的 `lastError = nil`
    /// 不得清掉它，否則 paywall 會從重試回到永久載入中（#3420）。
    var productLoadFailed = false
    var activePaywallSource: PaywallSource?
    var proProduct: Product?
    var proProductIdentifier: String { Self.proProductID }
    var purchaseStatusMessage: String?
    var hasProAccess: Bool {
        entitlements.pro.is_active
    }

    var lastRefreshTime: Date?
    /// `entitlements` 寫入世代（#2800）。會寫入狀態的請求（refresh、StoreKit 同步）於發出時取號，
    /// 同步寫入（樂觀更新、登出）亦取號；回應到達時只有號碼新於已套用世代者可寫入。
    var entitlementsGeneration = 0
    /// 已真正套用到 `entitlements` 的最新世代。以「已套用」而非「已發出」判斷，
    /// 較新請求失敗時較早但有效的回應仍可套用。
    var lastAppliedEntitlementsGeneration = 0
    /// 最近一次本地決策寫入（樂觀更新、登出）的世代。只有它會使較早發出的 App Store 同步回應失效（#2800）。
    var lastLocalWriteGeneration = 0
    /// `entitlements` 所屬的帳號。nil 代表未綁定（預設值，或無法確定歸屬）；帳號切換時不得沿用他人的權益（#2592）。
    var entitlementsOwnerUserId: String?
    /// refresh 自己的請求序號（#3233）。只有最新發出的 refresh 可寫入錯誤或還原冷卻；共用世代會被 StoreKit 同步取號推進，
    /// 不能用來判斷 refresh 自身的失敗是否過期。
    var refreshRequestSequence = 0
    /// 寫入 `lastError` 的請求世代。較早 refresh 的失敗不得覆寫較新請求已寫入的錯誤（#3223）。
    var lastErrorGeneration = 0
    static let refreshCooldown: TimeInterval = 2.0

    var transactionListener: Task<Void, Never>?
    var expiryTimer: Task<Void, Never>?

    /// refresh 需要的外部依賴，由 listenForTransactionUpdates 設定
    weak var _kgService: (any KGServing)?
    weak var _authManager: (any AuthManaging)?

    static let productRetryAttempts = 3
    static let productRetryDelay: UInt64 = 2_000_000_000 // 2s

    private init() {}

    static var defaultEntitlements: KGEntitlements {
        KGEntitlements(
            pro: KGSubscriptionStatus(
                is_active: false,
                product_id: nil,
                plan_name: "Books & Vocab Pro",
                price_display: nil,
                status: "inactive",
                is_trial: false,
                trial_days: 7,
                will_renew: false,
                expires_at: nil,
                source: "app_store",
                last_synced_at: nil
            )
        )
    }

    /// 取得下一個寫入世代。請求於「發出」時呼叫，回應到達後以 `applyEntitlements` 套用（#2800）。
    func claimEntitlementsGeneration() -> Int {
        entitlementsGeneration += 1
        return entitlementsGeneration
    }

    /// 只有 `generation` 仍新於已套用世代時才寫入，回傳是否套用；過期回應不論到達順序一律丟棄（#2800）。
    @discardableResult
    func applyEntitlements(_ value: KGEntitlements, generation: Int, owner: String? = nil) -> Bool {
        guard generation > lastAppliedEntitlementsGeneration else { return false }
        entitlements = value
        entitlementsOwnerUserId = owner
        lastAppliedEntitlementsGeneration = generation
        return true
    }

    /// 本地決策寫入（樂觀更新、登出）：取新世代並立即套用，使此前發出、尚未返回的請求全部失效（#2800）。
    func commitEntitlements(_ value: KGEntitlements, owner: String? = nil) {
        let generation = claimEntitlementsGeneration()
        lastLocalWriteGeneration = generation
        applyEntitlements(value, generation: generation, owner: owner)
    }

    /// 登出（含 delete_account、401 teardown）：權益回到預設，並以本地寫入世代使所有在途請求失效，
    /// 包括登出前發出、尚未返回的 App Store 同步回應（#2592, #3222）。
    func resetForSessionEnd() {
        commitEntitlements(Self.defaultEntitlements)
        lastError = nil
        lastRefreshTime = nil
        expiryTimer?.cancel()
        expiryTimer = nil
    }

    /// App Store 同步回應是伺服器對本次交易的權威結果。較晚發出的 refresh GET 可能先被伺服器處理（尚未含本次交易），
    /// 不得擋住它；只有發出後發生的本地寫入（登出、樂觀更新）才使其失效。回傳是否套用（#2800）。
    @discardableResult
    func applySyncResponse(_ value: KGEntitlements, requestedAt generation: Int, owner: String? = nil) -> Bool {
        guard lastLocalWriteGeneration < generation else { return false }
        guard applyEntitlements(value, generation: claimEntitlementsGeneration(), owner: owner) else { return false }
        // 已套用的權威結果取代先前的失敗訊息，並依新權益重建到期排程（#3223）
        lastError = nil
        scheduleExpiryRefresh(for: value.pro)
        return true
    }

    /// 已驗證交易的結算結果（#3421）。
    enum TransactionSettlement {
        /// 後端已同步且交易已 finish；StoreKit 不會再重送。
        case finished
        /// 未登入：未 finish，交由 StoreKit 於之後重送。
        case skippedNotLoggedIn
        /// 後端以永久 4xx 拒絕（重送結果不變）：已 finish 以停止 StoreKit 重送（#3542、#3596）。
        case rejected(Error)
        /// 後端同步失敗：未 finish，交由 StoreKit 於之後重送。
        case syncFailed(Error)
    }

    /// 決定已驗證交易何時 finish（#3421）。finish 等於告知 StoreKit「不再重送」，因此只能在後端同步成功後執行；
    /// 未登入或同步失敗則保留未完成，StoreKit 會於之後再次送出。泛型化是為了讓測試能注入假交易，
    /// 因為 `Transaction` 無法於測試程序中建構。
    static func settleVerifiedTransaction<T>(
        _ transaction: T,
        isLoggedIn: Bool,
        sync: (T) async throws -> Void,
        finish: (T) async -> Void
    ) async -> TransactionSettlement {
        // 只有在使用者已登入時才同步至後端，避免用錯誤帳號的 auth 送出交易
        guard isLoggedIn else { return .skippedNotLoggedIn }
        do {
            try await sync(transaction)
        } catch let error as KGError where Self.isTerminalRejection(error) {
            await finish(transaction)
            return .rejected(error)
        } catch {
            return .syncFailed(error)
        }
        await finish(transaction)
        return .finished
    }

    /// 後端的永久 4xx（例如 403：交易綁定其他帳號）：同一筆交易重送結果不會改變（#3542、#3596）。
    /// 401 由請求層登出並於重新登入後重送；408、429 為暫時性，維持未完成以待重試。
    static func isTerminalRejection(_ error: KGError) -> Bool {
        guard case .httpError(let status, _) = error else { return false }
        return (400...499).contains(status) && ![401, 408, 429].contains(status)
    }

    /// 在 app 啟動時呼叫，持續監聽 Transaction.updates 以捕捉中斷購買、續訂等事件
    func listenForTransactionUpdates(using kgService: any KGServing, authManager: any AuthManaging) {
        _kgService = kgService
        _authManager = authManager
        transactionListener?.cancel()
        transactionListener = Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                guard let transaction = try? self.checkVerified(result) else { continue }

                let product = self.proProduct
                let settlement = await Self.settleVerifiedTransaction(
                    transaction,
                    isLoggedIn: authManager.isLoggedIn,
                    sync: { transaction in
                        try await self.syncTransaction(
                            transaction,
                            signedTransactionInfo: result.jwsRepresentation,
                            product: product,
                            using: kgService
                        )
                    },
                    finish: { transaction in await transaction.finish() }
                )
                switch settlement {
                case .skippedNotLoggedIn:
                    AppLog.subscription.warning("Transaction update received but no user logged in; leaving it unfinished for StoreKit redelivery")
                    continue
                case .rejected(let error):
                    // 終局拒絕已 finish，不記 Sentry：每次啟動重送的是同一筆無法成功的交易，不是待修的錯誤
                    AppLog.subscription.warning("syncTransaction rejected by backend, transaction finished: \(error.localizedDescription)")
                case .syncFailed(let error):
                    AppLog.subscription.error("syncTransaction failed: \(error.localizedDescription)")
                    if !(error is CancellationError) {
                        AppCrashReporting.record(error, context: "subscription.sync.transaction")
                    }
                case .finished:
                    break
                }
                await self.refresh(using: kgService, authManager: authManager, force: true)
            }
        }
    }
}
