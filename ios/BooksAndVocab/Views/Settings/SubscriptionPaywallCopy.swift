//
//  SubscriptionPaywallCopy.swift
//  Books & Vocab
//
//  SubscriptionPaywallSheet 的純文案解析 — 對齊既有 SubscriptionPresentation 模式
//  (static func over KGSubscriptionStatus)。把帳單金額 / 試用 / CTA / footer 等
//  App Store 3.1.2(c) 合規敏感字串從 View computed property 抽出，成為可單元測試的
//  單一真相（見 SubscriptionPaywallCopyTests）。productDisplayPrice 以 String? 傳入
//  而非 StoreKit Product，使解析完全脫離 StoreKit、可在測試構造。
//

import Foundation

enum SubscriptionPaywallCopy {

    static func isAdminGranted(_ status: KGSubscriptionStatus) -> Bool {
        status.is_active && status.source == "admin"
    }

    static func activeSummary(_ status: KGSubscriptionStatus) -> String {
        if isAdminGranted(status) {
            return L10n.string("目前帳號已由管理員授權為 Pro。")
        }
        if status.isCancelledButActive {
            return L10n.format("你已取消自動續訂。Pro 功能可使用至 %@。", status.formattedExpiryDate)
        }
        return L10n.string("感謝支持！所有進階功能已解鎖。")
    }

    static let marketingSummary = L10n.string("解鎖閱讀器 AI、雲端同步、關聯圖與內建複習。免費試用與價格會直接來自 App Store。")

    /// 帳單金額（最突出的定價元素 — 3.1.2(c) 合規）。
    static func billedAmount(_ status: KGSubscriptionStatus, productDisplayPrice: String?) -> String {
        if isAdminGranted(status) {
            if let expiresAt = status.expires_at, !expiresAt.isEmpty {
                return L10n.format("管理員授權 · 有效至 %@", status.formattedExpiryDate)
            }
            return L10n.string("管理員授權")
        }
        if let price = productDisplayPrice {
            return L10n.format("%@ / month", price)
        }
        if let remotePrice = status.price_display, !remotePrice.isEmpty {
            return remotePrice
        }
        return L10n.string("載入 App Store 價格中…")
    }

    /// 試用資訊（次要位置，字級小於帳單金額）。`introTrialDays` 僅來自 StoreKit
    /// 對「此使用者」有資格的免費試用 intro offer（見 PaywallIntroOffer）；
    /// 後端 trial_days 不參與試用宣稱。admin、無資格、無 offer 或 <=0 → nil。
    static func trialInfo(_ status: KGSubscriptionStatus, introTrialDays: Int?) -> String? {
        guard !isAdminGranted(status) else { return nil }
        guard let days = introTrialDays, days > 0 else { return nil }
        return L10n.format("包含 %@ 天免費試用", "\(days)")
    }

    /// 已啟用狀態使用的完整價格行（金額 · 試用）。
    static func priceLine(_ status: KGSubscriptionStatus, productDisplayPrice: String?, introTrialDays: Int?) -> String {
        let amount = billedAmount(status, productDisplayPrice: productDisplayPrice)
        if isAdminGranted(status) {
            return amount
        }
        if let trialLine = trialInfo(status, introTrialDays: introTrialDays) {
            return "\(amount) · \(trialLine)"
        }
        return amount
    }

    /// CTA 按鈕標題（包含價格 — 3.1.2(c) 合規）。productDisplayPrice nil → 中性「訂閱」。
    static func ctaButtonTitle(_ status: KGSubscriptionStatus, productDisplayPrice: String?, introTrialDays: Int?) -> String {
        if let price = productDisplayPrice {
            if let days = introTrialDays, days > 0 {
                return L10n.format("免費試用 %@ 天，之後 %@/月", "\(days)", price)
            }
            return L10n.format("訂閱 — %@/月", price)
        }
        return L10n.string("訂閱")
    }

    /// 權限來源標籤。注意：僅看 `source == "admin"`，不檢查 is_active（與 isAdminGranted 不同）。
    static func entitlementSource(_ status: KGSubscriptionStatus) -> String {
        switch status.source {
        case "admin":
            return L10n.string("管理員授權")
        default:
            return L10n.string("App Store 訂閱")
        }
    }

    static func primaryActionTitle(_ status: KGSubscriptionStatus) -> String {
        if isAdminGranted(status) {
            return L10n.string("重新整理權限狀態")
        }
        return L10n.string("重新同步訂閱狀態")
    }

    static func footerNote(_ status: KGSubscriptionStatus) -> String {
        if isAdminGranted(status) {
            return L10n.string("此帳號目前由管理員授權為 Pro；若需延長、撤銷或調整，請聯絡管理員。")
        }
        if status.isCancelledButActive {
            return L10n.string("到期後將回到免費方案。如需繼續使用 Pro，可重新訂閱。")
        }
        return L10n.string("價格與免費試用長度會以 App Store 與你的地區顯示為準。")
    }
}
