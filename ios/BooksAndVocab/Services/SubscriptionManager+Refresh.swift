import Foundation

extension SubscriptionManager {
    func refresh(using kgService: any KGServing, authManager: any AuthManaging, force: Bool = false) async {
        await refreshEntitlements(using: kgService, authManager: authManager, force: force)
    }

    /// 核心 refresh 只需要 `fetchEntitlements`，依窄能力協定 `SubscriptionServing` 實作，
    /// 讓回應順序語義能以確定性替身測試（#2800）。
    func refreshEntitlements(using service: any SubscriptionServing, authManager: any AuthManaging, force: Bool) async {
        guard authManager.isLoggedIn else {
            entitlements = Self.defaultEntitlements
            lastError = nil
            expiryTimer?.cancel()
            expiryTimer = nil
            return
        }

        // Cooldown：防止短時間重複 refresh，force 可跳過
        if !force {
            let now = Date()
            if let last = lastRefreshTime, now.timeIntervalSince(last) < Self.refreshCooldown {
                return
            }
        }
        let previousRefreshTime = lastRefreshTime
        lastRefreshTime = Date()
        refreshGeneration += 1
        let generation = refreshGeneration

        // 記住發起 refresh 時的 userId，用於 async 返回後的一致性檢查
        let requestUserId = authManager.userId

        beginLoading()
        defer { endLoading() }

        do {
            var remote = try await service.fetchEntitlements()

            // 回應到達前已有更新的 refresh 發出：無論到達順序，本回應都已過期
            guard generation == refreshGeneration else {
                AppLog.subscription.debug("Discarding superseded refresh #\(generation), latest is #\(refreshGeneration)")
                return
            }

            // async 返回後帳號可能已切換，丟棄過期回應
            guard authManager.userId == requestUserId else {
                AppLog.subscription.warning("Discarding stale refresh: requested for \(requestUserId ?? "nil"), current is \(authManager.userId ?? "nil")")
                return
            }

            // 後端可能不知道用戶已在裝置端取消自動續訂，用 StoreKit 本地狀態覆寫
            if remote.pro.is_active, remote.pro.source != "admin" {
                if let willAutoRenew = await queryWillAutoRenew(),
                   remote.pro.will_renew != willAutoRenew {
                    remote = KGEntitlements(
                        pro: merge(remote.pro, willRenew: willAutoRenew)
                    )
                }
                // 已過期 + 不續訂 → 本地直接降級，不等後端通知
                if !remote.pro.will_renew, remote.pro.isExpired {
                    AppLog.subscription.debug("Locally deactivating: expires_at=\(remote.pro.expires_at ?? "nil") already passed, will_renew=false")
                    remote = KGEntitlements(
                        pro: merge(remote.pro, status: "expired", isActive: false)
                    )
                }
            }
            // StoreKit 查詢也是 await 點，期間可能已有更新的 refresh 發出
            guard generation == refreshGeneration else { return }
            entitlements = remote
            lastError = nil
            scheduleExpiryRefresh(for: remote.pro)
        } catch is CancellationError {
            // 被取消（如 .task(id:) 重啟）不是失敗；還原冷卻時間避免擋住下一次 refresh。
            // 過期請求不得還原，否則會蓋掉較新請求寫入的冷卻時間。
            if generation == refreshGeneration { lastRefreshTime = previousRefreshTime }
        } catch {
            // 過期請求的錯誤不得蓋掉較新請求的狀態
            guard generation == refreshGeneration else { return }
            lastError = error.localizedDescription
        }
    }

    /// 從 Apple 訂閱管理頁返回後執行完整重新同步
    func resyncAfterManagement(using kgService: any KGServing, authManager: any AuthManaging) async {
        guard authManager.isLoggedIn else { return }
        beginLoading()
        defer { endLoading() }

        await syncCurrentEntitlements(using: kgService)
        await refresh(using: kgService, authManager: authManager, force: true)
    }

    /// 排程到期自動刷新：當訂閱即將到期（cancelled but active），在 expires_at 到達時自動 refresh
    func scheduleExpiryRefresh(for pro: KGSubscriptionStatus) {
        expiryTimer?.cancel()
        expiryTimer = nil

        guard pro.isCancelledButActive,
              let expiresAt = pro.expires_at, !expiresAt.isEmpty,
              let expiryDate = KGSubscriptionStatus.parseExpiryDate(expiresAt)
        else { return }

        let delay = expiryDate.timeIntervalSinceNow
        guard delay > 0 else { return }

        AppLog.subscription.debug("Scheduling expiry refresh in \(Int(delay))s")
        expiryTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 1))
            guard !Task.isCancelled, let self else { return }
            guard let kgService = self._kgService, let authManager = self._authManager else { return }
            AppLog.subscription.debug("Expiry timer fired, refreshing...")
            await self.refresh(using: kgService, authManager: authManager, force: true)
        }
    }
}
