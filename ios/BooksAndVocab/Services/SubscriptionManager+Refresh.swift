import Foundation

extension SubscriptionManager {
    func refresh(using kgService: any KGServing, authManager: any AuthManaging, force: Bool = false) async {
        await refreshEntitlements(using: kgService, authManager: authManager, force: force)
    }

    /// 核心 refresh 只需要 `fetchEntitlements`，依窄能力協定 `SubscriptionServing` 實作，
    /// 讓回應順序語義能以確定性替身測試（#2800）。
    /// 回傳 `false` 僅表示本次 fetch 失敗或被取消；未發出請求的早退（登出、cooldown）與已被取代的回應皆回傳 `true`（#3418）。
    @discardableResult
    func refreshEntitlements(using service: any SubscriptionServing, authManager: any AuthManaging, force: Bool) async -> Bool {
        // 記住發起 refresh 時的 userId，用於 async 返回後的一致性檢查
        let requestUserId = authManager.userId

        guard authManager.isLoggedIn else {
            commitEntitlements(Self.defaultEntitlements)
            lastError = nil
            expiryTimer?.cancel()
            expiryTimer = nil
            return true
        }

        // 未經登出直接換成另一帳號：屬於前一帳號的權益不得沿用，且 refresh 失敗時也不得保留（#2592）。
        if let owner = entitlementsOwnerUserId, owner != requestUserId {
            AppLog.subscription.warning("Entitlements owner changed; discarding previous account's state")
            commitEntitlements(Self.defaultEntitlements)
            lastRefreshTime = nil
        }

        // Cooldown：防止短時間重複 refresh，force 可跳過
        if !force {
            let now = Date()
            if let last = lastRefreshTime, now.timeIntervalSince(last) < Self.refreshCooldown {
                return true
            }
        }
        let previousRefreshTime = lastRefreshTime
        lastRefreshTime = Date()
        let generation = claimEntitlementsGeneration()
        refreshRequestSequence += 1
        let refreshSequence = refreshRequestSequence

        beginLoading()
        defer { endLoading() }

        do {
            var remote = try await service.fetchEntitlements()

            // 已有更新的世代套用過（refresh 或樂觀／同步寫入）：本回應已過期（無論到達順序）
            guard generation > lastAppliedEntitlementsGeneration else {
                AppLog.subscription.debug("Discarding superseded refresh #\(generation), applied #\(self.lastAppliedEntitlementsGeneration)")
                return true
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
            // 所有 await（含上方 StoreKit 查詢）之後才判斷帳號：查詢期間可能已登出或切換帳號，
            // 而登出不取世代，僅靠 applyEntitlements 的世代守衛會把舊帳號的權益寫回。
            guard authManager.userId == requestUserId else {
                AppLog.subscription.warning("Discarding stale refresh: requested for \(requestUserId ?? "nil"), current is \(authManager.userId ?? "nil")")
                return true
            }
            // 期間可能已有更新的寫入發出；由 applyEntitlements 再守一次世代
            guard applyEntitlements(remote, generation: generation, owner: requestUserId) else { return true }
            lastError = nil
            scheduleExpiryRefresh(for: remote.pro)
            return true
        } catch is CancellationError {
            // 被取消（如 .task(id:) 重啟）不是失敗；還原冷卻時間避免擋住下一次 refresh。
            // 過期請求不得還原，否則會蓋掉較新請求寫入的冷卻時間。
            if refreshSequence == refreshRequestSequence { lastRefreshTime = previousRefreshTime }
            return false
        } catch {
            // 只有最新發出的 refresh 可寫入錯誤：較早 refresh 的失敗若較新 refresh 已發出，即已被取代，
            // 不得寫入 lastError（否則 paywall 會對已過時的請求顯示重試）。判斷只看 refresh 自己的序號：
            // 同步取號會推進共用世代，不得吞掉 refresh 自身的錯誤（#3233）。
            // 較新的請求（同步）已寫入的錯誤仍優先（#3223）。
            if refreshSequence == refreshRequestSequence,
               lastError == nil || generation > lastErrorGeneration {
                lastError = error.localizedDescription
                lastErrorGeneration = generation
            }
            return false
        }
    }

    /// 登入後的權益對帳（#3508）：先以 StoreKit currentEntitlements 補同步，再 refresh。
    /// 登出期間未 finish 的交易只能經此路徑送達後端；refresh 不觸及 currentEntitlements，順序不可對調。
    static func reconcileEntitlementsAfterLogin(
        syncCurrentEntitlements: () async -> CurrentEntitlementSyncOutcome,
        refresh: () async -> Void
    ) async {
        _ = await syncCurrentEntitlements()
        await refresh()
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
