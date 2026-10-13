#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

/// Pins `SubscriptionPaywallCopy` — the pure paywall copy resolver behind
/// SubscriptionPaywallSheet. These strings are App Store 3.1.2(c) pricing-
/// disclosure sensitive, so the branch logic (admin grant vs App Store vs
/// remote price vs loading; trial inclusion; CTA price embedding) is locked
/// here rather than left in untestable View computed properties.
struct SubscriptionPaywallCopyTests {

    /// Builds a `KGSubscriptionStatus` with paywall-relevant fields; the rest
    /// default to inert values.
    private func status(
        isActive: Bool = false,
        source: String = "appstore",
        trialDays: Int? = nil,
        expiresAt: String? = nil,
        priceDisplay: String? = nil
    ) -> KGSubscriptionStatus {
        KGSubscriptionStatus(
            is_active: isActive,
            product_id: nil,
            plan_name: nil,
            price_display: priceDisplay,
            status: isActive ? "active" : "free",
            is_trial: false,
            trial_days: trialDays,
            will_renew: true,
            expires_at: expiresAt,
            source: source,
            last_synced_at: nil
        )
    }

    // MARK: - Admin gate

    @Test func isAdminGranted_requiresActiveAndAdminSource() {
        #expect(SubscriptionPaywallCopy.isAdminGranted(status(isActive: true, source: "admin")))
        #expect(!SubscriptionPaywallCopy.isAdminGranted(status(isActive: false, source: "admin")))
        #expect(!SubscriptionPaywallCopy.isAdminGranted(status(isActive: true, source: "appstore")))
    }

    /// entitlementSource keys on `source == "admin"` ALONE (no is_active check) —
    /// distinct from isAdminGranted. Pin so the two don't get conflated.
    @Test func entitlementSource_keysOnSourceOnly() {
        let adminActive = SubscriptionPaywallCopy.entitlementSource(status(isActive: true, source: "admin"))
        let adminInactive = SubscriptionPaywallCopy.entitlementSource(status(isActive: false, source: "admin"))
        let appstore = SubscriptionPaywallCopy.entitlementSource(status(source: "appstore"))
        #expect(adminActive == adminInactive)   // both → 管理員授權
        #expect(adminActive != appstore)
    }

    // MARK: - Trial info (StoreKit intro offer is the only source)

    @Test func trialInfo_usesOfferDaysIgnoringBackendTrialDays() {
        for backend in [nil, 14, 0] as [Int?] {
            let s = status(trialDays: backend)
            #expect(SubscriptionPaywallCopy.trialInfo(s, introTrialDays: 7)?.contains("7") == true)
            #expect(SubscriptionPaywallCopy.trialInfo(s, introTrialDays: 3)?.contains("3") == true)
            #expect(SubscriptionPaywallCopy.trialInfo(s, introTrialDays: 3)?.contains("14") == false)
        }
    }

    @Test func trialInfo_nilWhenIneligibleNoOfferZeroOrAdmin() {
        #expect(SubscriptionPaywallCopy.trialInfo(status(trialDays: 7), introTrialDays: nil) == nil)
        #expect(SubscriptionPaywallCopy.trialInfo(status(trialDays: 7), introTrialDays: 0) == nil)
        #expect(SubscriptionPaywallCopy.trialInfo(status(isActive: true, source: "admin"), introTrialDays: 7) == nil)
    }

    // MARK: - Intro offer period -> days

    @Test func introTrialDays_mapsPeriodUnits() {
        #expect(PaywallIntroOffer.days(unit: .day, value: 3) == 3)
        #expect(PaywallIntroOffer.days(unit: .week, value: 1) == 7)
        #expect(PaywallIntroOffer.days(unit: .week, value: 2) == 14)
        #expect(PaywallIntroOffer.days(unit: .month, value: 1) == 30)
        #expect(PaywallIntroOffer.days(unit: .year, value: 1) == 365)
        #expect(PaywallIntroOffer.days(unit: .day, value: 0) == nil)
    }

    // MARK: - Billed amount precedence

    @Test func billedAmount_adminWithExpiry() {
        let s = status(isActive: true, source: "admin", expiresAt: "2026-12-31")
        let line = SubscriptionPaywallCopy.billedAmount(s, productDisplayPrice: "$4.99")
        #expect(line.contains("2026-12-31"))
        #expect(!line.contains("$4.99"))   // admin branch wins over product price
    }

    /// #2430: "%1$@ · … %@" mixed numbered and unnumbered specs, so the second
    /// argument was dropped and the price printed twice instead of the expiry date.
    @Test(arguments: [AppLanguage.english, .traditionalChinese, .simplifiedChinese, .japanese, .korean])
    func priceExpiryLine_showsPriceOnceAndExpiry(language: AppLanguage) {
        let line = L10n.format("%@ · 到期 %@", language: language, "NT$170", "2026-12-31")
        #expect(line.contains("2026-12-31"))
        #expect(line.components(separatedBy: "NT$170").count == 2)   // price exactly once
    }

    @Test func billedAmount_productPriceWinsOverRemote() {
        let s = status(priceDisplay: "NT$170")
        let line = SubscriptionPaywallCopy.billedAmount(s, productDisplayPrice: "$4.99")
        #expect(line.contains("$4.99"))
        #expect(!line.contains("NT$170"))
    }

    @Test func billedAmount_remotePriceWhenNoProduct() {
        let s = status(priceDisplay: "NT$170")
        #expect(SubscriptionPaywallCopy.billedAmount(s, productDisplayPrice: nil) == "NT$170")
    }

    @Test func billedAmount_loadingWhenNothing() {
        let a = SubscriptionPaywallCopy.billedAmount(status(), productDisplayPrice: nil)
        let b = SubscriptionPaywallCopy.billedAmount(status(priceDisplay: "NT$170"), productDisplayPrice: "$4.99")
        #expect(a != b)   // loading placeholder is distinct from a real price line
    }

    // MARK: - CTA title price embedding

    @Test func ctaButtonTitle_embedsPriceAndOfferTrial() {
        let withTrial = SubscriptionPaywallCopy.ctaButtonTitle(status(trialDays: 14), productDisplayPrice: "$4.99", introTrialDays: 3)
        #expect(withTrial.contains("$4.99"))
        #expect(withTrial.contains("3"))
        #expect(!withTrial.contains("14"))

        // Ineligible / no offer: neutral subscribe CTA, backend trial_days ignored.
        for backend in [nil, 7] as [Int?] {
            let neutral = SubscriptionPaywallCopy.ctaButtonTitle(status(trialDays: backend), productDisplayPrice: "$4.99", introTrialDays: nil)
            #expect(neutral.contains("$4.99"))
            #expect(!neutral.contains("免費試用"))
            #expect(!neutral.contains("7"))
        }

        // No product price → neutral fallback, no price/trial embedded.
        let noPrice = SubscriptionPaywallCopy.ctaButtonTitle(status(trialDays: 7), productDisplayPrice: nil, introTrialDays: 7)
        #expect(!noPrice.contains("$"))
    }

    // MARK: - priceLine composition

    @Test func priceLine_appendsTrialOnlyForOffer() {
        let s = status(trialDays: 7, priceDisplay: "NT$170")
        let line = SubscriptionPaywallCopy.priceLine(s, productDisplayPrice: nil, introTrialDays: 7)
        #expect(line.contains("NT$170"))
        #expect(line.contains("·"))   // amount · trial

        let ineligible = SubscriptionPaywallCopy.priceLine(s, productDisplayPrice: nil, introTrialDays: nil)
        #expect(ineligible == "NT$170")
        #expect(!ineligible.contains("免費試用"))

        // Admin path never appends trial.
        let admin = SubscriptionPaywallCopy.priceLine(status(isActive: true, source: "admin"), productDisplayPrice: nil, introTrialDays: 7)
        #expect(!admin.contains("·"))
    }

    // MARK: - Post-purchase sync-pending message (#2746)

    /// The message must name the control the inactive paywall renders (恢復購買,
    /// localized label) and never the 重新同步 control that only the active layout shows.
    @Test(arguments: [AppLanguage.english, .traditionalChinese, .simplifiedChinese, .japanese, .korean])
    func purchaseSyncPendingMessage_pointsToRestoreNotResync(language: AppLanguage) {
        let text = L10n.string(SubscriptionPurchaseCopy.backendSyncPendingKey, language: language)
        let restoreLabel = L10n.string("恢復購買", language: language)
        let resyncLabel = L10n.string("重新同步訂閱狀態", language: language)
        #expect(text.contains(restoreLabel))
        #expect(!text.contains(resyncLabel))
    }

    // MARK: - Purchase outcome message (#3418)

    /// Optimistic Pro committed before the backend sync must never be reported as success
    /// when the sync did not apply, even if the follow-up refresh still reports Pro.
    @Test(arguments: [true, false])
    func purchaseOutcome_optimisticProWithoutBackendSyncIsPending(refreshApplied: Bool) {
        let key = SubscriptionPurchaseCopy.purchaseOutcomeMessage(
            syncApplied: false,
            refreshApplied: refreshApplied,
            hasProAccess: true
        )
        #expect(key == SubscriptionPurchaseCopy.backendSyncPendingKey)
    }

    @Test func purchaseOutcome_successOnlyWhenSyncRefreshAndProAllApply() {
        #expect(
            SubscriptionPurchaseCopy.purchaseOutcomeMessage(syncApplied: true, refreshApplied: true, hasProAccess: true)
                == SubscriptionPurchaseCopy.activatedKey
        )
        #expect(
            SubscriptionPurchaseCopy.purchaseOutcomeMessage(syncApplied: true, refreshApplied: false, hasProAccess: true)
                == SubscriptionPurchaseCopy.backendSyncPendingKey
        )
        #expect(
            SubscriptionPurchaseCopy.purchaseOutcomeMessage(syncApplied: true, refreshApplied: true, hasProAccess: false)
                == SubscriptionPurchaseCopy.backendSyncPendingKey
        )
    }

    // MARK: - Restore outcome message (#3419)

    /// A missing StoreKit entitlement and a backend 403 (transaction bound to another account)
    /// must not collapse into the transient "backend sync failed, retry" copy.
    @Test func restoreOutcome_noEntitlementAndRejectedDoNotShowRetryCopy() {
        let retry = SubscriptionPurchaseCopy.restoreOutcomeMessage(result: .failed, hasProAccess: false)
        let none = SubscriptionPurchaseCopy.restoreOutcomeMessage(result: .noEntitlement, hasProAccess: false)
        let rejected = SubscriptionPurchaseCopy.restoreOutcomeMessage(result: .rejected, hasProAccess: false)
        #expect(retry == SubscriptionPurchaseCopy.restoreSyncRetryKey)
        #expect(none != retry)
        #expect(rejected != retry)
        #expect(none != rejected)
    }

    @Test func restoreOutcome_proAccessAlwaysReportsRestored() {
        for result in [CurrentEntitlementSyncOutcome.noEntitlement, .synced, .rejected, .failed] {
            #expect(
                SubscriptionPurchaseCopy.restoreOutcomeMessage(result: result, hasProAccess: true)
                    == SubscriptionPurchaseCopy.restoredKey
            )
        }
    }

    // MARK: - SubscriptionPresentation has no backend-derived trial claim

    @Test func presentation_detailAndCtaMakeNoTrialClaim() {
        let s = status(trialDays: 14, priceDisplay: "NT$170")
        let detail = SubscriptionPresentation.detail(for: s, proProduct: nil)
        #expect(!detail.contains("14"))
        #expect(!detail.contains("免費試用"))
        #expect(!SubscriptionPresentation.ctaTitle(for: s).contains("免費試用"))
    }
}
#endif
