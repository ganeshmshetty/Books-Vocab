import StoreKit

/// Copy for the post-purchase sync-pending state (#2746). The key names the
/// control the inactive paywall actually renders (恢復購買 → restorePurchases →
/// syncCurrentEntitlements), so the user is never sent to a missing 重新同步.
enum SubscriptionPurchaseCopy {
    static let backendSyncPendingKey = "Apple 購買成功，但後端同步尚未完成。請稍後點「恢復購買」。"
}

enum SubscriptionProductLoadState: Equatable {
    case loading
    case ready
    case retry
}

/// StoreKit 免費試用 intro offer 的資格與天數（paywall 試用宣稱的唯一來源）。
enum PaywallIntroOffer {
    /// 期間 → 天數（純函式）。value<=0 → nil。月／年採 30／365 近似，僅用於顯示。
    static func days(unit: Product.SubscriptionPeriod.Unit, value: Int) -> Int? {
        guard value > 0 else { return nil }
        switch unit {
        case .day: return value
        case .week: return value * 7
        case .month: return value * 30
        case .year: return value * 365
        @unknown default: return nil
        }
    }

    /// 商品有 `.freeTrial` intro offer 且使用者仍有資格 → 天數；否則 nil。
    static func eligibleFreeTrialDays(for product: Product?) async -> Int? {
        guard let subscription = product?.subscription,
              let offer = subscription.introductoryOffer,
              offer.paymentMode == .freeTrial,
              await subscription.isEligibleForIntroOffer
        else { return nil }
        return days(unit: offer.period.unit, value: offer.period.value)
    }
}

extension SubscriptionManager {
    static func productLoadState(
        isLoading: Bool,
        hasProduct: Bool,
        hasError: Bool
    ) -> SubscriptionProductLoadState {
        if hasProduct {
            return .ready
        }
        if isLoading || !hasError {
            return .loading
        }
        return .retry
    }

    func loadProducts() async {
        beginLoading()
        defer { endLoading() }
        lastError = nil
        for attempt in 1...Self.productRetryAttempts {
            do {
                let products = try await Product.products(for: [Self.proProductID])
                AppLog.subscription.debug("StoreKit attempt \(attempt): returned \(products.count) product(s) for '\(Self.proProductID)'")
                for p in products { AppLog.subscription.debug("StoreKit product: \(p.id) — \(p.displayPrice)") }
                if let product = products.first {
                    proProduct = product
                    if entitlements.pro.price_display == nil {
                        // 衍生欄位：只補 price_display、以當下已套用的值為基礎（同步執行，無 await），
                        // 不代表新的權威狀態，故不取世代；取世代會丟棄進行中的 refresh 回應（#2800）。
                        entitlements = KGEntitlements(
                            pro: merge(entitlements.pro, priceDisplay: product.displayPrice)
                        )
                    }
                    lastError = nil
                    return
                }
            } catch {
                AppLog.subscription.debug("StoreKit attempt \(attempt) error: \(error.localizedDescription)")
            }
            if attempt < Self.productRetryAttempts {
                try? await Task.sleep(nanoseconds: Self.productRetryDelay)
            }
        }
        // All retries exhausted — product still unavailable
        proProduct = nil
        lastError = L10n.string("尚未取得訂閱方案，請稍後再試。")
    }

    func purchasePro(using kgService: any KGServing, authManager: any AuthManaging) async {
        if proProduct == nil {
            await loadProducts()
        }
        guard let product = proProduct else {
            purchaseStatusMessage = L10n.string("尚未取得產品價格，請稍後再試。")
            return
        }
        guard authManager.isLoggedIn else {
            purchaseStatusMessage = L10n.string("請先登入，再開始免費試用或訂閱。")
            return
        }

        beginLoading()
        defer { endLoading() }

        do {
            let result = try await product.purchase(options: purchaseOptions(for: authManager.userId))
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                purchaseStatusMessage = L10n.string("購買成功，正在同步訂閱狀態⋯")
                commitEntitlements(optimisticEntitlements(from: product, status: inferredStatus(for: product)))
                do {
                    try await syncTransaction(
                        transaction,
                        signedTransactionInfo: verification.jwsRepresentation,
                        product: product,
                        using: kgService
                    )
                    AppLog.subscription.info("Sync succeeded")
                } catch {
                    AppLog.subscription.warning("Sync failed: \(error.localizedDescription)")
                    if !(error is CancellationError) {
                        AppCrashReporting.record(error, context: "subscription.purchase.sync")
                    }
                }
                await refresh(using: kgService, authManager: authManager, force: true)
                if hasProAccess {
                    purchaseStatusMessage = L10n.string("訂閱已啟用，感謝支持！")
                    scheduleClearPurchaseMessage()
                } else {
                    purchaseStatusMessage = L10n.string(SubscriptionPurchaseCopy.backendSyncPendingKey)
                }
            case .userCancelled:
                purchaseStatusMessage = L10n.string("已取消購買。")
            case .pending:
                purchaseStatusMessage = L10n.string("購買待確認，Apple 完成後會自動更新。")
            @unknown default:
                purchaseStatusMessage = L10n.string("購買結果未知，請稍後在設定頁重新整理。")
            }
        } catch {
            if !(error is CancellationError) {
                purchaseStatusMessage = L10n.format("購買失敗：%@", error.localizedDescription)
                lastError = error.localizedDescription
            }
            // Filter StoreKit user-cancel and offline: those are recoverable / user-driven
            if !(error is CancellationError),
               !(error is StoreKitError) {
                AppCrashReporting.record(error, context: "subscription.purchase")
            }
        }
    }

    func restorePurchases(using kgService: any KGServing, authManager: any AuthManaging) async {
        beginLoading()
        defer { endLoading() }

        do {
            try await AppStore.sync()
            await syncCurrentEntitlements(using: kgService)
            await refresh(using: kgService, authManager: authManager, force: true)
            if hasProAccess {
                purchaseStatusMessage = L10n.string("購買已恢復，Pro 已啟用。")
            } else {
                purchaseStatusMessage = L10n.string("已向 App Store 恢復購買，但後端尚未同步成功。請稍後再試。")
            }
            scheduleClearPurchaseMessage()
        } catch {
            if !(error is CancellationError) {
                purchaseStatusMessage = L10n.format("恢復失敗：%@", error.localizedDescription)
                lastError = error.localizedDescription
                AppCrashReporting.record(error, context: "subscription.restore")
            }
        }
    }
}
