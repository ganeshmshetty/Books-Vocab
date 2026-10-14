import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Pins the *pure logic* seams of the `SubscriptionManager` family — the billing core
/// (`SubscriptionManager` + `+Purchase`/`+Refresh`/`+StoreKit`/`+Helpers`).
///
/// Honesty note — what is NOT covered, and why:
///
/// - StoreKit-bound paths (`loadProducts`, `purchasePro`, `restorePurchases`,
///   `syncTransaction`, `syncCurrentEntitlements`, `queryWillAutoRenew`,
///   `appStoreEnvironment(for:)`, `checkVerified(_:)`, `optimisticEntitlements(from:)`)
///   require `Product`, `Transaction`, `VerificationResult` — StoreKit types that
///   cannot be constructed in a unit-test process without a StoreKit testing session
///   and a real App Store / StoreKit configuration. There is no injection seam for
///   them, so they are deliberately left out rather than faked with tautologies.
///
/// - `refresh(...)` / `resyncAfterManagement(...)` interleave a `KGServing` network
///   call with StoreKit `queryWillAutoRenew()`. The network half is exercised through
///   the `SubscriptionServing` seam (`refreshEntitlements`, see the #2800 tests below);
///   the StoreKit half has no injection seam and is not covered. The *pure model logic* it depends on
///   (`KGSubscriptionStatus.isExpired` / `.isCancelledButActive` / `.parseExpiryDate`)
///   is what gates its branches — and that is fully covered below.
///
/// What IS covered: the deterministic, dependency-free seams —
/// `stableUUID(for:)`, `purchaseOptions(for:)`, `merge(...)`, `inferredStatus(for:)`,
/// and the `KGSubscriptionStatus` expiry/cancellation predicates that drive
/// local downgrade and expiry-timer scheduling.
@Suite(.serialized)
struct SubscriptionManagerTests {

    // MARK: - Fixtures

    /// A baseline subscription status; individual fields are overridden per test.
    private func status(
        isActive: Bool = false,
        productId: String? = nil,
        priceDisplay: String? = nil,
        status: String = "inactive",
        isTrial: Bool = false,
        willRenew: Bool = false,
        expiresAt: String? = nil,
        source: String = "app_store"
    ) -> KGSubscriptionStatus {
        KGSubscriptionStatus(
            is_active: isActive,
            product_id: productId,
            plan_name: "Books & Vocab Pro",
            price_display: priceDisplay,
            status: status,
            is_trial: isTrial,
            trial_days: 7,
            will_renew: willRenew,
            expires_at: expiresAt,
            source: source,
            last_synced_at: nil
        )
    }

    // MARK: - stableUUID: deterministic SHA256 → UUID derivation

    @MainActor
    @Test func stableUUID_is_deterministic_for_same_userId() {
        let mgr = SubscriptionManager.shared
        let a = mgr.stableUUID(for: "user-abc-123")
        let b = mgr.stableUUID(for: "user-abc-123")
        #expect(a != nil)
        #expect(a == b)
    }

    @MainActor
    @Test func stableUUID_differs_across_distinct_userIds() {
        let mgr = SubscriptionManager.shared
        let a = mgr.stableUUID(for: "user-one")
        let b = mgr.stableUUID(for: "user-two")
        #expect(a != nil)
        #expect(b != nil)
        #expect(a != b)
    }

    @MainActor
    @Test func stableUUID_handles_empty_and_unicode_userId() {
        // SHA256 always yields 32 bytes → prefix(16) always succeeds; never nil.
        let mgr = SubscriptionManager.shared
        #expect(mgr.stableUUID(for: "") != nil)
        #expect(mgr.stableUUID(for: "用戶-表情-🔑") != nil)
        // Determinism holds for unicode too.
        #expect(mgr.stableUUID(for: "用戶-表情-🔑") == mgr.stableUUID(for: "用戶-表情-🔑"))
    }

    @MainActor
    @Test func stableUUID_matches_known_sha256_prefix() {
        // Pin the exact derivation: SHA256("kg") prefix(16), uppercased, UUID-formatted.
        // SHA256("kg") = 131ed734290d30f32aedb3548cc92b42... — first 16 bytes form this UUID.
        let mgr = SubscriptionManager.shared
        let uuid = mgr.stableUUID(for: "kg")
        #expect(uuid != nil)
        // The first 16 hex-pairs of SHA256("kg"):
        // 13 1e d7 34 29 0d 30 f3 2a ed b3 54 8c c9 2b 42
        #expect(uuid?.uuidString == "131ED734-290D-30F3-2AED-B3548CC92B42")
    }

    // MARK: - purchaseOptions: appAccountToken gating

    @MainActor
    @Test func purchaseOptions_empty_when_userId_nil() {
        // No logged-in user → no appAccountToken attached to the purchase.
        let mgr = SubscriptionManager.shared
        #expect(mgr.purchaseOptions(for: nil).isEmpty)
    }

    @MainActor
    @Test func purchaseOptions_carries_single_option_for_valid_userId() {
        // A non-nil userId yields exactly one option (the appAccountToken).
        // The token value itself is StoreKit-opaque and not inspectable here.
        let mgr = SubscriptionManager.shared
        #expect(mgr.purchaseOptions(for: "user-xyz").count == 1)
    }

    @MainActor
    @Test func purchaseOptions_handles_empty_string_userId() {
        // Empty string is still a non-nil userId → stableUUID succeeds → one option.
        let mgr = SubscriptionManager.shared
        #expect(mgr.purchaseOptions(for: "").count == 1)
    }

    // MARK: - merge: pure field-level overlay onto KGSubscriptionStatus

    @MainActor
    @Test func merge_with_no_overrides_is_identity() {
        let mgr = SubscriptionManager.shared
        let base = status(isActive: true, status: "active", willRenew: true)
        #expect(mgr.merge(base) == base)
    }

    @MainActor
    @Test func merge_overrides_only_specified_fields() {
        let mgr = SubscriptionManager.shared
        let base = status(
            isActive: false,
            productId: "old.id",
            priceDisplay: "NT$30",
            status: "inactive",
            isTrial: false,
            willRenew: false
        )
        let merged = mgr.merge(
            base,
            productId: "new.id",
            priceDisplay: "NT$90",
            status: "active",
            isActive: true,
            isTrial: true,
            willRenew: true
        )
        #expect(merged.product_id == "new.id")
        #expect(merged.price_display == "NT$90")
        #expect(merged.status == "active")
        #expect(merged.is_active == true)
        #expect(merged.is_trial == true)
        #expect(merged.will_renew == true)
        // Untouched fields are preserved verbatim.
        #expect(merged.plan_name == base.plan_name)
        #expect(merged.trial_days == base.trial_days)
        #expect(merged.expires_at == base.expires_at)
        #expect(merged.source == base.source)
        #expect(merged.last_synced_at == base.last_synced_at)
    }

    @MainActor
    @Test func merge_partial_override_keeps_rest_intact() {
        // Only `willRenew` flips — every other field must survive untouched.
        // This is the exact shape of the refresh.swift will_renew reconciliation.
        let mgr = SubscriptionManager.shared
        let base = status(isActive: true, productId: "p.id", status: "active", willRenew: true)
        let merged = mgr.merge(base, willRenew: false)
        #expect(merged.will_renew == false)
        #expect(merged.is_active == base.is_active)
        #expect(merged.product_id == base.product_id)
        #expect(merged.status == base.status)
    }

    @MainActor
    @Test func merge_can_express_local_expired_downgrade() {
        // The +Refresh.swift local-downgrade path: status→"expired", isActive→false.
        let mgr = SubscriptionManager.shared
        let base = status(isActive: true, status: "active", willRenew: false)
        let downgraded = mgr.merge(base, status: "expired", isActive: false)
        #expect(downgraded.is_active == false)
        #expect(downgraded.status == "expired")
        #expect(downgraded.will_renew == false) // unchanged
    }

    // MARK: - inferredStatus: trial-aware status string for sync snapshots

    @MainActor
    @Test func inferredStatus_falls_back_to_active_when_product_nil_and_not_trial() {
        // With a nil product and a non-trial entitlement the method returns "active".
        // Asserted against the shared singleton's default (non-trial) entitlements.
        let mgr = SubscriptionManager.shared
        // Sanity-pin the precondition this assertion depends on.
        #expect(mgr.entitlements.pro.is_trial == false)
        #expect(mgr.inferredStatus(for: nil) == "active")
    }

    // MARK: - KGSubscriptionStatus.parseExpiryDate (drives refresh + expiry timer)

    @Test func parseExpiryDate_accepts_fractional_seconds_iso8601() {
        let date = KGSubscriptionStatus.parseExpiryDate("2026-01-15T08:30:00.000Z")
        #expect(date != nil)
    }

    @Test func parseExpiryDate_accepts_plain_iso8601_without_fraction() {
        // The fallback formatter must catch non-fractional ISO-8601.
        let date = KGSubscriptionStatus.parseExpiryDate("2026-01-15T08:30:00Z")
        #expect(date != nil)
    }

    @Test func parseExpiryDate_rejects_garbage_and_empty() {
        #expect(KGSubscriptionStatus.parseExpiryDate("not-a-date") == nil)
        #expect(KGSubscriptionStatus.parseExpiryDate("") == nil)
        #expect(KGSubscriptionStatus.parseExpiryDate("2026/01/15") == nil)
    }

    // MARK: - KGSubscriptionStatus.isExpired (gates local downgrade in +Refresh)

    @Test func isExpired_true_for_past_expiry() {
        let past = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -3600))
        #expect(status(expiresAt: past).isExpired == true)
    }

    @Test func isExpired_false_for_future_expiry() {
        let future = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: 3600))
        #expect(status(expiresAt: future).isExpired == false)
    }

    @Test func isExpired_false_when_expiry_missing_or_empty() {
        // No expiry date → cannot prove expiry → must not downgrade.
        #expect(status(expiresAt: nil).isExpired == false)
        #expect(status(expiresAt: "").isExpired == false)
    }

    @Test func isExpired_false_when_expiry_unparseable() {
        // Garbage expiry string is treated as "unknown", never as expired.
        #expect(status(expiresAt: "garbage").isExpired == false)
    }

    // MARK: - KGSubscriptionStatus.isCancelledButActive (gates expiry-timer scheduling)

    @Test func isCancelledButActive_true_when_active_and_not_renewing() {
        // Active + will-not-renew + non-admin source → scheduled for expiry refresh.
        let s = status(isActive: true, willRenew: false, source: "app_store")
        #expect(s.isCancelledButActive == true)
    }

    @Test func isCancelledButActive_false_when_renewing() {
        let s = status(isActive: true, willRenew: true, source: "app_store")
        #expect(s.isCancelledButActive == false)
    }

    @Test func isCancelledButActive_false_when_inactive() {
        let s = status(isActive: false, willRenew: false, source: "app_store")
        #expect(s.isCancelledButActive == false)
    }

    @Test func isCancelledButActive_false_for_admin_grant() {
        // Admin-granted Pro never auto-renews but must NOT be treated as cancelled —
        // it has no App Store expiry to schedule against.
        let s = status(isActive: true, willRenew: false, source: "admin")
        #expect(s.isCancelledButActive == false)
    }

    // MARK: - KGSubscriptionStatus.formattedExpiry (display path)

    @Test func formattedExpiry_returns_placeholder_for_nil_and_empty() {
        let placeholder = L10n.string("未知時間")
        #expect(KGSubscriptionStatus.formattedExpiry(nil) == placeholder)
        #expect(KGSubscriptionStatus.formattedExpiry("") == placeholder)
    }

    @Test func formattedExpiry_passes_through_unparseable_string() {
        // An unrecognised string is echoed back rather than replaced — surfacing the
        // raw backend value instead of hiding it behind a placeholder.
        #expect(KGSubscriptionStatus.formattedExpiry("weird-value") == "weird-value")
    }

    @Test func formattedExpiry_renders_valid_iso8601_into_display_format() {
        // A valid ISO-8601 string must be reformatted (no longer equal to the input,
        // and no longer the placeholder).
        let rendered = KGSubscriptionStatus.formattedExpiry("2026-01-15T08:30:00.000Z")
        #expect(rendered != "2026-01-15T08:30:00.000Z")
        #expect(rendered != L10n.string("未知時間"))
        #expect(!rendered.isEmpty)
    }

    // MARK: - SubscriptionManager.defaultEntitlements (logged-out reset state)

    @MainActor
    @Test func defaultEntitlements_is_inactive_non_pro() {
        // `refresh` resets to this when the user is logged out — must grant no access.
        let def = SubscriptionManager.defaultEntitlements
        #expect(def.pro.is_active == false)
        #expect(def.pro.status == "inactive")
        #expect(def.pro.is_trial == false)
        #expect(def.pro.will_renew == false)
        #expect(def.pro.product_id == nil)
        #expect(def.pro.source == "app_store")
        // isExpired on the default must be false (no expiry date present).
        #expect(def.pro.isExpired == false)
        // And it must not look "cancelled but active".
        #expect(def.pro.isCancelledButActive == false)
    }

    // MARK: - Static configuration constants

    // MARK: - Product loading presentation state

    @MainActor
    @Test func productLoadState_distinguishes_loading_ready_and_retry() {
        #expect(
            SubscriptionManager.productLoadState(
                isLoading: true,
                hasProduct: false,
                hasError: false
            ) == .loading
        )
        #expect(
            SubscriptionManager.productLoadState(
                isLoading: false,
                hasProduct: false,
                hasError: false
            ) == .loading
        )
        #expect(
            SubscriptionManager.productLoadState(
                isLoading: false,
                hasProduct: true,
                hasError: false
            ) == .ready
        )
        #expect(
            SubscriptionManager.productLoadState(
                isLoading: false,
                hasProduct: false,
                hasError: true
            ) == .retry
        )
        #expect(
            SubscriptionManager.productLoadState(
                isLoading: true,
                hasProduct: true,
                hasError: true
            ) == .ready
        )
    }

    /// A product-load failure must keep the paywall on its retry affordance even when a later
    /// successful refresh clears the shared `lastError` (#3420).
    @MainActor
    @Test func productLoadFailure_survivesSuccessfulRefresh() async {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedOwner = mgr.entitlementsOwnerUserId
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        let savedLoadFailed = mgr.productLoadFailed
        let savedProduct = mgr.proProduct
        defer {
            mgr.entitlements = savedEntitlements
            mgr.entitlementsOwnerUserId = savedOwner
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
            mgr.productLoadFailed = savedLoadFailed
            mgr.proProduct = savedProduct
        }
        mgr.lastRefreshTime = nil
        // 共享單例可能被先前測試留下已載入的商品；本案例驗證「無商品」狀態，必須明確清空。
        mgr.proProduct = nil
        // loadProducts 耗盡重試後同時留下：無商品、lastError 與 productLoadFailed。
        mgr.lastError = "尚未取得訂閱方案，請稍後再試。"
        mgr.productLoadFailed = true

        // 之後的 refresh 成功並清除 lastError，但不得清除商品載入失敗狀態。
        let service = GatedSubscriptionService(responses: [1: KGEntitlements(pro: status())], suspended: [])
        let succeeded = await mgr.refreshEntitlements(using: service, authManager: RefreshOrderAuthStub(), force: true)
        #expect(succeeded)
        #expect(mgr.lastError == nil)
        #expect(
            SubscriptionManager.productLoadState(
                isLoading: false,
                hasProduct: mgr.proProduct != nil,
                hasError: mgr.productLoadFailed
            ) == .retry
        )
    }

    @MainActor
    @Test func proProductID_is_stable_and_exposed_via_instance() {
        // The product identifier is a release-critical constant; pin it and confirm
        // the instance accessor mirrors the type-level constant.
        #expect(SubscriptionManager.proProductID == BrandIdentity.proProductID)
        #expect(SubscriptionManager.shared.proProductIdentifier == SubscriptionManager.proProductID)
    }

    // MARK: - refresh response ordering (#2800)
    //
    // `source: "admin"` keeps the StoreKit `queryWillAutoRenew()` branch out of these
    // tests; the response-ordering contract lives entirely in the network half.

    @MainActor
    @Test func refresh_discards_older_response_arriving_after_newer_request() async throws {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }
        mgr.lastRefreshTime = nil

        // 1 = 非強制 launch refresh，掛起；2 = 較晚發出的強制 refresh，立即回 active。
        let service = GatedSubscriptionService(
            responses: [
                1: KGEntitlements(pro: status(status: "inactive")),
                2: KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin")),
            ],
            suspended: [1]
        )
        let auth = RefreshOrderAuthStub()

        let launch = Task { await mgr.refreshEntitlements(using: service, authManager: auth, force: false) }
        try #require(await service.waitUntilParked(1))

        await mgr.refreshEntitlements(using: service, authManager: auth, force: true)
        #expect(mgr.entitlements.pro.is_active)

        // 較早發出的 free 回應最後到達，必須被丟棄。
        service.release(1)
        await launch.value
        #expect(mgr.entitlements.pro.is_active)
    }

    @MainActor
    @Test func refresh_applies_older_valid_response_when_newer_request_fails() async throws {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }
        mgr.lastRefreshTime = nil
        mgr.lastError = nil

        // 1 = 非強制 launch refresh，掛起且回 active；2 = 較晚發出的強制 refresh，
        // 不在 responses 內，因此 fetch 拋錯（模擬網路錯誤）。
        let service = GatedSubscriptionService(
            responses: [1: KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin"))],
            suspended: [1]
        )
        let auth = RefreshOrderAuthStub()

        let launch = Task { await mgr.refreshEntitlements(using: service, authManager: auth, force: false) }
        try #require(await service.waitUntilParked(1))

        await mgr.refreshEntitlements(using: service, authManager: auth, force: true)
        #expect(mgr.lastError != nil)

        // 較早發出但有效的回應後到：尚未被套用過，必須套用並清除較新請求留下的錯誤。
        service.release(1)
        await launch.value
        #expect(mgr.entitlements.pro.is_active)
        #expect(mgr.lastError == nil)
    }

    @MainActor
    @Test func refresh_superseded_failure_does_not_write_error_while_newer_request_pending() async throws {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }
        mgr.lastRefreshTime = nil
        mgr.lastError = nil

        // 1 = 較早發出的非強制 refresh，掛起後因不在 responses 內而失敗；
        // 2 = 較晚發出的強制 refresh，同樣掛起，之後回 active。
        let service = GatedSubscriptionService(
            responses: [2: KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin"))],
            suspended: [1, 2]
        )
        let auth = RefreshOrderAuthStub()

        let older = Task { await mgr.refreshEntitlements(using: service, authManager: auth, force: false) }
        try #require(await service.waitUntilParked(1))
        let newer = Task { await mgr.refreshEntitlements(using: service, authManager: auth, force: true) }
        try #require(await service.waitUntilParked(2))

        // 較早請求失敗時，較新請求仍在途中：該失敗已被取代，不得寫入 lastError（否則 paywall 會顯示重試）。
        service.release(1)
        await older.value
        #expect(mgr.lastError == nil)

        // 較新請求成功後照常套用，並維持無錯誤狀態。
        service.release(2)
        await newer.value
        #expect(mgr.entitlements.pro.is_active)
        #expect(mgr.lastError == nil)
    }

    @MainActor
    @Test func refresh_applies_response_when_no_newer_request_exists() async {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }
        mgr.lastRefreshTime = nil
        mgr.entitlements = KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin"))

        // 對照組：沒有更新的請求時，唯一的回應必須照常套用（證明守衛不是無條件丟棄）。
        let service = GatedSubscriptionService(
            responses: [1: KGEntitlements(pro: status(status: "inactive"))],
            suspended: []
        )
        await mgr.refreshEntitlements(using: service, authManager: RefreshOrderAuthStub(), force: false)
        #expect(!mgr.entitlements.pro.is_active)
    }

    @MainActor
    @Test func refresh_discards_stale_free_response_after_optimistic_write() async throws {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }
        mgr.lastRefreshTime = nil
        mgr.lastError = nil

        // 1 = launch refresh 掛起，之後才回 free；2 = 強制 refresh，不在 responses 內 → 拋錯（模擬網路失敗）。
        let service = GatedSubscriptionService(
            responses: [1: KGEntitlements(pro: status(status: "inactive"))],
            suspended: [1]
        )
        let auth = RefreshOrderAuthStub()

        let launch = Task { await mgr.refreshEntitlements(using: service, authManager: auth, force: false) }
        try #require(await service.waitUntilParked(1))

        // 購買的樂觀寫入發生在 launch refresh 發出之後：必須使其回應失效。
        mgr.commitEntitlements(KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin")))

        await mgr.refreshEntitlements(using: service, authManager: auth, force: true)
        #expect(mgr.lastError != nil)
        #expect(mgr.hasProAccess)

        // 過期的 free 回應最後到達：不得把付費用戶降為 free。
        service.release(1)
        await launch.value
        #expect(mgr.hasProAccess)
    }

    @MainActor
    @Test func refresh_issued_after_optimistic_write_still_applies() async {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }
        mgr.lastRefreshTime = nil

        // 對照組：寫入之後才發出的 refresh 不受影響，必須照常套用（證明 funnel 不是無條件阻擋）。
        mgr.commitEntitlements(KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin")))
        let service = GatedSubscriptionService(
            responses: [1: KGEntitlements(pro: status(status: "inactive"))],
            suspended: []
        )
        await mgr.refreshEntitlements(using: service, authManager: RefreshOrderAuthStub(), force: false)
        #expect(!mgr.hasProAccess)
    }

    // MARK: - App Store sync response authority (#2800)
    //
    // 伺服器可能先處理較晚發出的 refresh GET（尚未含本次交易），該 GET 不得擋住同步回應。
    // `syncTransaction` 需要 StoreKit `Transaction`，無法在單元測試建構，因此決策拆為 `applySyncResponse` 直接測。

    @MainActor
    @Test func sync_response_applies_after_newer_refresh_already_applied() {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        defer { mgr.entitlements = savedEntitlements }

        // 同步請求先發出；較晚發出的 refresh GET 先回 free 並套用；同步回應（active）後到，必須套用。
        let syncGeneration = mgr.claimEntitlementsGeneration()
        let refreshGeneration = mgr.claimEntitlementsGeneration()
        mgr.applyEntitlements(KGEntitlements(pro: status(status: "inactive")), generation: refreshGeneration)
        #expect(!mgr.hasProAccess)

        let applied = mgr.applySyncResponse(
            KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin")),
            requestedAt: syncGeneration
        )
        #expect(applied)
        #expect(mgr.hasProAccess)
    }

    @MainActor
    @Test func sync_response_discarded_when_local_write_followed_request() {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        defer { mgr.entitlements = savedEntitlements }

        // 同步請求發出後發生本地決策寫入（登出／樂觀更新）：同步回應必須失效，不得寫回舊權益。
        let syncGeneration = mgr.claimEntitlementsGeneration()
        mgr.commitEntitlements(KGEntitlements(pro: status(status: "inactive")))

        let applied = mgr.applySyncResponse(
            KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin")),
            requestedAt: syncGeneration
        )
        #expect(!applied)
        #expect(!mgr.hasProAccess)
    }

    // MARK: - sync failure reporting (#3223)

    @MainActor
    @Test func failed_latest_sync_request_surfaces_error_over_superseded_refresh_failure() async throws {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }
        mgr.lastRefreshTime = nil
        mgr.lastError = nil

        // 1 = 較早發出的非強制 refresh，掛起後失敗；之後發出的 StoreKit 同步（最新請求）同樣失敗。
        let service = GatedSubscriptionService(responses: [:], suspended: [1])
        let auth = RefreshOrderAuthStub()
        let older = Task { await mgr.refreshEntitlements(using: service, authManager: auth, force: false) }
        try #require(await service.waitUntilParked(1))

        _ = try? await mgr.applySyncRequest(owner: "test_user") { throw UnexpectedSubscriptionCall() }
        #expect(mgr.lastError != nil)

        // 較早的 refresh 最後失敗：已被較新的同步取代，不得清除或覆寫其錯誤。
        service.release(1)
        await older.value
        #expect(mgr.lastError != nil)
    }

    @MainActor
    @Test func applied_sync_response_clears_stale_error_and_reschedules_expiry() {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.lastError = savedError
            mgr.expiryTimer?.cancel()
            mgr.expiryTimer = nil
        }
        mgr.lastError = "stale"

        // 已取消續訂但仍有效，到期時間為未來：套用後必須排程到期刷新。
        let expiry = Date().addingTimeInterval(3600).ISO8601Format()
        let pro = status(isActive: true, status: "active", willRenew: false, expiresAt: expiry, source: "app_store")
        let generation = mgr.claimEntitlementsGeneration()
        let applied = mgr.applySyncResponse(KGEntitlements(pro: pro), requestedAt: generation, owner: "test_user")

        #expect(applied)
        #expect(mgr.lastError == nil)
        #expect(mgr.expiryTimer != nil)
    }

    // MARK: - account switch ownership (#2592)

    @MainActor
    @Test func refresh_after_account_switch_drops_previous_account_pro_when_fetch_fails() async {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedOwner = mgr.entitlementsOwnerUserId
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.entitlementsOwnerUserId = savedOwner
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }
        mgr.lastRefreshTime = nil
        mgr.lastError = nil

        // 帳號 A 的 Pro 已綁定 A；未經登出，直接切換為 B，且 B 的 refresh 失敗。
        mgr.commitEntitlements(
            KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin")),
            owner: "A"
        )
        let auth = RefreshOrderAuthStub()
        auth.userId = "B"

        // responses 為空 → fetch 拋錯。B 不得沿用 A 的 Pro。
        let service = GatedSubscriptionService(responses: [:], suspended: [])
        await mgr.refreshEntitlements(using: service, authManager: auth, force: true)
        #expect(!mgr.hasProAccess)
        #expect(mgr.lastError != nil)
    }

    @MainActor
    @Test func refresh_keeps_same_account_pro_when_fetch_fails() async {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedOwner = mgr.entitlementsOwnerUserId
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.entitlementsOwnerUserId = savedOwner
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }
        mgr.lastRefreshTime = nil
        mgr.lastError = nil

        // 對照組：同一帳號的網路失敗不應清除既有權益（既有行為：只寫 lastError）。
        mgr.commitEntitlements(
            KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin")),
            owner: "test_user"
        )
        let service = GatedSubscriptionService(responses: [:], suspended: [])
        await mgr.refreshEntitlements(using: service, authManager: RefreshOrderAuthStub(), force: true)
        #expect(mgr.hasProAccess)
        #expect(mgr.lastError != nil)
    }

    // MARK: - session end (#2592, #3222)

    // MARK: - account binding of sync responses (#3232) and refresh error reporting (#3233)

    /// A sync response for account A that returns after the session moved to account B must not write
    /// A's entitlements into B. Switching accounts does not pass through logout, so no local write
    /// generation invalidates the request.
    @MainActor
    @Test func sync_response_for_previous_account_is_discarded_after_account_switch() async {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedAuth = mgr._authManager
        defer {
            mgr.entitlements = savedEntitlements
            mgr._authManager = savedAuth
        }
        mgr.commitEntitlements(SubscriptionManager.defaultEntitlements)

        let auth = RefreshOrderAuthStub()
        auth.userId = "test_user"
        mgr._authManager = auth

        _ = try? await mgr.applySyncRequest(owner: "test_user") {
            auth.userId = "other_user"
            return KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin"))
        }

        #expect(!mgr.hasProAccess, "A's response must not be written after the session switched to B")
    }

    @MainActor
    @Test func sync_response_for_current_account_still_applies() async throws {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedAuth = mgr._authManager
        defer {
            mgr.entitlements = savedEntitlements
            mgr._authManager = savedAuth
        }
        mgr.commitEntitlements(SubscriptionManager.defaultEntitlements)

        let auth = RefreshOrderAuthStub()
        auth.userId = "test_user"
        mgr._authManager = auth

        try await mgr.applySyncRequest(owner: "test_user") {
            KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin"))
        }

        #expect(mgr.hasProAccess)
    }

    /// The refresh's own network error must reach `lastError` even when a sync claimed the shared
    /// generation while the refresh was in flight. Only a newer refresh or a newer error may supersede it.
    @MainActor
    @Test func refresh_error_surfaces_when_a_sync_started_during_the_refresh() async throws {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }
        mgr.lastRefreshTime = nil
        mgr.lastError = nil

        let service = GatedSubscriptionService(responses: [:], suspended: [1])
        let auth = RefreshOrderAuthStub()
        let refresh = Task { await mgr.refreshEntitlements(using: service, authManager: auth, force: true) }
        try #require(await service.waitUntilParked(1))

        // 同步在 refresh GET 途中開始並取號（推進共用世代）；它本身沒有失敗，不應影響 refresh 的錯誤。
        _ = mgr.claimEntitlementsGeneration()

        service.release(1)
        await refresh.value
        #expect(mgr.lastError != nil, "a sync claiming the shared generation must not drop the refresh's own error")
    }

    @MainActor
    @Test func session_end_resets_pro_and_discards_sync_requested_before_logout() {
        let mgr = SubscriptionManager.shared
        let savedEntitlements = mgr.entitlements
        let savedRefreshTime = mgr.lastRefreshTime
        let savedError = mgr.lastError
        defer {
            mgr.entitlements = savedEntitlements
            mgr.lastRefreshTime = savedRefreshTime
            mgr.lastError = savedError
        }

        // 用戶 A 的 Pro 已套用；App Store 同步於登出前發出，回應尚未返回。
        mgr.commitEntitlements(KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin")))
        let syncGeneration = mgr.claimEntitlementsGeneration()

        mgr.resetForSessionEnd()
        #expect(!mgr.hasProAccess)

        // 登出後才到達的 A 同步回應（active）必須被丟棄，不得把 Pro 寫回。
        let applied = mgr.applySyncResponse(
            KGEntitlements(pro: status(isActive: true, status: "active", willRenew: true, source: "admin")),
            requestedAt: syncGeneration
        )
        #expect(!applied)
        #expect(!mgr.hasProAccess)
    }

    // MARK: - transaction settlement (#3421)

    private struct TransactionSyncStubError: Error {}

    /// 未登入時交易不得 finish（finish 後 StoreKit 不再重送，會永久丟失）；登入後重試須同步成功才 finish。
    @MainActor
    @Test func settle_loggedOutTransaction_staysUnfinishedUntilRetriedWhileLoggedIn() async {
        var events: [String] = []
        let loggedOut = await SubscriptionManager.settleVerifiedTransaction(
            "tx-1",
            isLoggedIn: false,
            sync: { _ in events.append("sync") },
            finish: { _ in events.append("finish") }
        )
        #expect(events.isEmpty)
        guard case .skippedNotLoggedIn = loggedOut else {
            Issue.record("expected skippedNotLoggedIn, got \(loggedOut)")
            return
        }

        let retried = await SubscriptionManager.settleVerifiedTransaction(
            "tx-1",
            isLoggedIn: true,
            sync: { _ in events.append("sync") },
            finish: { _ in events.append("finish") }
        )
        #expect(events == ["sync", "finish"])
        guard case .finished = retried else {
            Issue.record("expected finished, got \(retried)")
            return
        }
    }

    /// 登入使用者的同步失敗時交易必須保持未完成，讓 StoreKit 於之後重送，而不是先 finish 再同步。
    @MainActor
    @Test func settle_failedSyncForLoggedInUser_leavesTransactionUnfinished() async {
        var events: [String] = []
        let outcome = await SubscriptionManager.settleVerifiedTransaction(
            "tx-2",
            isLoggedIn: true,
            sync: { _ in
                events.append("sync")
                throw TransactionSyncStubError()
            },
            finish: { _ in events.append("finish") }
        )
        #expect(events == ["sync"])
        guard case .syncFailed = outcome else {
            Issue.record("expected syncFailed, got \(outcome)")
            return
        }
    }

    /// 後端以終局 403 拒絕（例如交易綁定其他帳號）：重送結果不會改變，必須 finish 以停止 StoreKit 重送（#3542）。
    @MainActor
    @Test func settle_backendRejected403_finishesAndReportsRejected() async {
        var events: [String] = []
        let outcome = await SubscriptionManager.settleVerifiedTransaction(
            "tx-4",
            isLoggedIn: true,
            sync: { _ in
                events.append("sync")
                throw KGError.httpError(statusCode: 403, detail: "")
            },
            finish: { _ in events.append("finish") }
        )
        #expect(events == ["sync", "finish"])
        guard case .rejected = outcome else {
            Issue.record("expected rejected, got \(outcome)")
            return
        }
    }

    /// 永久 4xx（非 401／408／429）同樣是終局拒絕，必須 finish，否則每次啟動重送、重 POST 並重報 Sentry（#3596）。
    @MainActor
    @Test func settle_permanentClientError_finishesAndReportsRejected() async {
        for status in [400, 404, 409, 422] {
            var events: [String] = []
            let outcome = await SubscriptionManager.settleVerifiedTransaction(
                "tx-6",
                isLoggedIn: true,
                sync: { _ in
                    events.append("sync")
                    throw KGError.httpError(statusCode: status, detail: "")
                },
                finish: { _ in events.append("finish") }
            )
            #expect(events == ["sync", "finish"], "status \(status)")
            guard case .rejected = outcome else {
                Issue.record("status \(status): expected rejected, got \(outcome)")
                return
            }
        }
    }

    /// 暫時錯誤（5xx、網路、401、408、429）必須維持未完成，交由 StoreKit 於之後重送。
    @MainActor
    @Test func settle_transientSyncFailure_staysUnfinished() async {
        let transient: [KGError] = [
            .httpError(statusCode: 401, detail: ""),
            .httpError(statusCode: 408, detail: ""),
            .httpError(statusCode: 429, detail: ""),
            .httpError(statusCode: 500, detail: ""),
            .networkError(underlying: URLError(.timedOut)),
        ]
        for error in transient {
            var events: [String] = []
            let outcome = await SubscriptionManager.settleVerifiedTransaction(
                "tx-5",
                isLoggedIn: true,
                sync: { _ in
                    events.append("sync")
                    throw error
                },
                finish: { _ in events.append("finish") }
            )
            #expect(events == ["sync"])
            guard case .syncFailed = outcome else {
                Issue.record("expected syncFailed, got \(outcome)")
                return
            }
        }
    }

    /// 成功路徑的順序必須是「同步成功後才 finish」。
    @MainActor
    @Test func settle_successfulSync_finishesOnlyAfterSync() async {
        var events: [String] = []
        let outcome = await SubscriptionManager.settleVerifiedTransaction(
            "tx-3",
            isLoggedIn: true,
            sync: { _ in events.append("sync") },
            finish: { _ in events.append("finish") }
        )
        #expect(events == ["sync", "finish"])
        guard case .finished = outcome else {
            Issue.record("expected finished, got \(outcome)")
            return
        }
    }

    // MARK: - undecodable success response (#3614)

    /// 2xx 同步已被後端接受、只是回應無法解碼：必須 finish。否則 StoreKit 每次啟動重送，重 POST 並重報 Sentry。
    @MainActor
    @Test func settle_undecodableSuccessResponse_finishesWithoutRetry() async {
        var events: [String] = []
        let outcome = await SubscriptionManager.settleVerifiedTransaction(
            "tx-7",
            isLoggedIn: true,
            sync: { _ in
                events.append("sync")
                throw KGError.decodingError(underlying: URLError(.cannotParseResponse))
            },
            finish: { _ in events.append("finish") }
        )
        #expect(events == ["sync", "finish"])
        guard case .acceptedUnreadableResponse = outcome else {
            Issue.record("expected acceptedUnreadableResponse, got \(outcome)")
            return
        }
    }

    /// 408 與 429 為暫時性錯誤，即使 P3 統一 4xx 判定後也不得被視為終局拒絕（#3614）。
    @MainActor
    @Test func isTerminalRejection_exemptsTransientStatuses() {
        #expect(!SubscriptionManager.isTerminalRejection(.httpError(statusCode: 408, detail: "")))
        #expect(!SubscriptionManager.isTerminalRejection(.httpError(statusCode: 429, detail: "")))
        #expect(!SubscriptionManager.isTerminalRejection(.httpError(statusCode: 401, detail: "")))
        #expect(SubscriptionManager.isTerminalRejection(.httpError(statusCode: 404, detail: "")))
    }

    // MARK: - post-login reconciliation (#3508)

    /// 登入後必須先以 StoreKit currentEntitlements 補同步，再 refresh：登出期間未 finish 的交易只能由此路徑送達後端，
    /// refresh 不觸及 currentEntitlements，因此順序不可對調或省略。
    @MainActor
    @Test func postLogin_syncsCurrentEntitlementsBeforeRefresh() async {
        var events: [String] = []
        await SubscriptionManager.reconcileEntitlementsAfterLogin(
            syncCurrentEntitlements: {
                events.append("sync")
                return .noEntitlement
            },
            refresh: { events.append("refresh") }
        )
        #expect(events == ["sync", "refresh"])
    }
}

/// 依呼叫序號回應；標記為 suspended 的呼叫會掛起，直到測試以 `release` 放行。
@MainActor
private final class GatedSubscriptionService: SubscriptionServing {
    private let responses: [Int: KGEntitlements]
    private let suspended: Set<Int>
    private var calls = 0
    private var parked: [Int: CheckedContinuation<KGEntitlements, Error>] = [:]

    init(responses: [Int: KGEntitlements], suspended: Set<Int>) {
        self.responses = responses
        self.suspended = suspended
    }

    func fetchEntitlements() async throws -> KGEntitlements {
        calls += 1
        let call = calls
        if suspended.contains(call) {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<KGEntitlements, Error>) in
                parked[call] = continuation
            }
        }
        return try response(for: call)
    }

    func syncAppStoreSubscription(_ snapshot: KGAppStoreSubscriptionSyncRequest) async throws -> KGEntitlements {
        throw UnexpectedSubscriptionCall()
    }

    func waitUntilParked(_ call: Int) async -> Bool {
        for _ in 0..<10_000 {
            if parked[call] != nil { return true }
            await Task.yield()
        }
        return false
    }

    func release(_ call: Int) {
        guard let continuation = parked.removeValue(forKey: call) else { return }
        continuation.resume(with: Result { try response(for: call) })
    }

    private func response(for call: Int) throws -> KGEntitlements {
        guard let value = responses[call] else { throw UnexpectedSubscriptionCall() }
        return value
    }
}

private struct UnexpectedSubscriptionCall: Error {}

private final class RefreshOrderAuthStub: AuthManaging {
    var isLoggedIn: Bool = true
    var userId: String? = "test_user"
    var token: String? = "test_token"
    var displayName: String?
    var userEmail: String?
    var avatarURL: URL?
    var authError: String?
    var isAuthenticating: Bool = false
    var isDemoMode: Bool = false

    func enterDemoMode(modelContainer: ModelContainer) {}
    func exitDemoMode(modelContainer: ModelContainer) {}
    func refreshSessionIfNeeded() {}
    func login(userId: String, token: String) {}
    func login(customToken: String) async {}
    func logout(modelContainer: ModelContainer?, reason: String) {}
    func logoutAfterAccountDeletion(modelContainer: ModelContainer?, deletedAccountID: String?) {}
    func loginWithGoogle(modelContainer: ModelContainer?) {}
    func loginWithApple(modelContainer: ModelContainer?) {}
}
