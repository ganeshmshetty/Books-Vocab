import StoreKit

/// `syncCurrentEntitlements` 的結果，供還原購買區分「沒有交易」「後端拒絕」與「暫時失敗」（#3419）。
enum CurrentEntitlementSyncOutcome: Equatable {
    /// StoreKit 沒有本 app 的 Pro 交易可同步。
    case noEntitlement
    /// 後端已接受並套用。
    case synced
    /// 後端 403：交易綁定其他帳號，重試不會成功。
    case rejected
    /// 其他錯誤（網路、5xx 等），可重試。
    case failed
}

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
                lastErrorGeneration = generation
            }
            throw error
        }
        // 回應屬於發出時的帳號。切換帳號不經登出，不會取得本地寫入世代，因此等待期間若已換帳號，
        // 此回應不得寫入新帳號的權益（#3232）。
        guard _authManager?.userId == owner else {
            AppLog.subscription.warning("Discarding sync response: account changed while the request was in flight")
            return
        }
        applySyncResponse(response, requestedAt: generation, owner: owner)
    }

    @discardableResult
    func syncCurrentEntitlements(using kgService: any KGServing) async -> CurrentEntitlementSyncOutcome {
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
                return .synced
            } catch {
                AppLog.subscription.warning("currentEntitlements sync failed: \(error.localizedDescription)")
                if case .httpError(statusCode: 403, _)? = error as? KGError {
                    return .rejected
                }
                return .failed
            }
        }
        AppLog.subscription.warning("No current entitlement found for \(Self.proProductID)")
        return .noEntitlement
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
