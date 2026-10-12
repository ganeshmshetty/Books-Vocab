import StoreKit

extension SubscriptionManager {
    func syncTransaction(
        _ transaction: Transaction,
        signedTransactionInfo: String?,
        product: Product?,
        using kgService: any KGServing
    ) async throws {
        // 同步請求屬於發出當下的帳號；回應只能套用於該帳號（#2592）
        let owner = _authManager?.userId
        let environment = appStoreEnvironment(for: transaction)
        let willAutoRenew = await queryWillAutoRenew() ?? entitlements.pro.will_renew
        let snapshot = KGAppStoreSubscriptionSyncRequest(
            product_id: transaction.productID,
            transaction_id: String(transaction.id),
            original_transaction_id: String(transaction.originalID),
            environment: environment,
            status: inferredStatus(for: product),
            is_trial: entitlements.pro.is_trial,
            expires_at: transaction.expirationDate?.ISO8601Format(),
            will_renew: willAutoRenew,
            price_display: product?.displayPrice,
            signed_transaction_info: environment == "xcode" ? nil : signedTransactionInfo
        )
        try await applySyncRequest(owner: owner) { try await kgService.syncAppStoreSubscription(snapshot) }
    }

    /// 發出 App Store 同步請求並套用回應。請求於發出時標記世代：發出後的本地寫入（登出、樂觀更新）使此回應失效；
    /// refresh GET 不影響（#2800）。失敗只在本請求仍是最新發出者時寫入 `lastError`：較新的請求已在途或已套用時，
    /// 本次失敗已被取代；若本次是最新者，只寫 log 會讓 paywall 沒有重試入口（#3223）。
    func applySyncRequest(owner: String?, _ send: () async throws -> KGEntitlements) async throws {
        let generation = claimEntitlementsGeneration()
        let response: KGEntitlements
        do {
            response = try await send()
        } catch {
            if !(error is CancellationError), generation == entitlementsGeneration {
                lastError = error.localizedDescription
            }
            throw error
        }
        applySyncResponse(response, requestedAt: generation, owner: owner)
    }

    func syncCurrentEntitlements(using kgService: any KGServing) async {
        for await result in Transaction.currentEntitlements {
            guard
                let transaction = try? checkVerified(result),
                transaction.productID == Self.proProductID
            else { continue }

            let product = proProduct
            do {
                try await syncTransaction(
                    transaction,
                    signedTransactionInfo: result.jwsRepresentation,
                    product: product,
                    using: kgService
                )
                AppLog.subscription.info("currentEntitlements sync succeeded")
            } catch {
                AppLog.subscription.warning("currentEntitlements sync failed: \(error.localizedDescription)")
            }
            return
        }
        AppLog.subscription.warning("No current entitlement found for \(Self.proProductID)")
    }

    /// 從 StoreKit 2 的 Product.SubscriptionInfo 查詢真實的自動續訂狀態
    /// 回傳 nil 表示無法確定（product 未載入或 StoreKit 查詢失敗），呼叫端應信任後端值
    func queryWillAutoRenew() async -> Bool? {
        guard let product = proProduct, let subscription = product.subscription else {
            AppLog.subscription.warning("queryWillAutoRenew: no product/subscription info")
            return nil
        }
        do {
            let statuses = try await subscription.status
            AppLog.subscription.debug("queryWillAutoRenew: \(statuses.count) status(es)")
            // 優先從 active 狀態取
            for status in statuses where status.state == .subscribed || status.state == .inGracePeriod {
                if let renewalInfo = try? checkVerified(status.renewalInfo) {
                    AppLog.subscription.debug("Active state=\(String(describing: status.state)), willAutoRenew=\(renewalInfo.willAutoRenew)")
                    return renewalInfo.willAutoRenew
                }
            }
            // 沒有 active 狀態，從 expired/revoked 取（sandbox 快速過期常見）
            for status in statuses where status.state != .subscribed && status.state != .inGracePeriod {
                if let renewalInfo = try? checkVerified(status.renewalInfo) {
                    AppLog.subscription.debug("Fallback state=\(String(describing: status.state)), willAutoRenew=\(renewalInfo.willAutoRenew)")
                    return renewalInfo.willAutoRenew
                }
            }
            AppLog.subscription.warning("queryWillAutoRenew: no verified renewalInfo found")
        } catch {
            AppLog.subscription.warning("queryWillAutoRenew failed: \(error.localizedDescription)")
        }
        return nil
    }

    func appStoreEnvironment(for transaction: Transaction) -> String {
        switch transaction.environment {
        case .sandbox:
            return "sandbox"
        case .xcode:
            return "xcode"
        default:
            return "production"
        }
    }
}
