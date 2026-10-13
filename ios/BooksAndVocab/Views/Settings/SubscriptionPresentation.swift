//
//  SubscriptionPresentation.swift
//  Books & Vocab
//

import StoreKit

enum SubscriptionPresentation {

    static func badgeText(for status: KGSubscriptionStatus) -> String {
        if status.source == "admin", status.is_active {
            return "ADMIN"
        }
        if status.isCancelledButActive {
            return "EXPIRING"
        }
        switch status.status {
        case "active":
            return "ACTIVE"
        case "trial":
            return "TRIAL"
        case "grace_period":
            return "GRACE"
        default:
            return "FREE"
        }
    }

    static func badgeTone(for status: KGSubscriptionStatus) -> SubscriptionBadgeTone {
        if status.source == "admin", status.is_active {
            return .success
        }
        if status.isCancelledButActive {
            return .accent
        }
        switch status.status {
        case "active":
            return .success
        case "trial", "grace_period":
            return .accent
        default:
            return .neutral
        }
    }

    static func summary(
        for status: KGSubscriptionStatus,
        podcastEnabled: Bool = KGFeatureFlags.podcastEnabled
    ) -> String {
        if status.source == "admin", status.is_active {
            return L10n.string("你目前已由管理員授權為 Pro，可使用 AI 翻譯、雲端同步、知識圖譜與內建複習。")
        }
        if status.isCancelledButActive {
            return L10n.format("訂閱已取消，將於 %@ 到期。到期前仍可使用所有 Pro 功能。", status.formattedExpiryDate)
        }
        if status.status == "grace_period" {
            return L10n.string("訂閱目前在寬限期，請確認付款方式以維持存取。")
        }
        if status.is_trial {
            return L10n.string("免費試用中，期間可使用 AI 翻譯、雲端同步、知識圖譜與內建複習。")
        }
        if status.is_active {
            // Podcast is DEBUG-gated (`KGFeatureFlags.podcastEnabled`) — a hidden
            // feature must not be claimed as unlocked in Release copy.
            return podcastEnabled
                ? L10n.string("你目前已解鎖 AI 翻譯、雲端同步、知識圖譜、內建複習與 Podcast。")
                : L10n.string("你目前已解鎖 AI 翻譯、雲端同步、知識圖譜與內建複習。")
        }
        return L10n.string("升級後可使用 AI 翻譯、語境解釋、雲端同步、知識圖譜與內建複習。")
    }

    static func detail(for status: KGSubscriptionStatus, proProduct: Product?) -> String {
        if status.source == "admin", status.is_active {
            if let expiresAt = status.expires_at, !expiresAt.isEmpty {
                return L10n.format("來源：管理員授權 · 有效至 %@", status.formattedExpiryDate)
            }
            return L10n.string("來源：管理員授權")
        }
        if let price = proProduct?.displayPrice, !price.isEmpty, !status.is_active {
            return L10n.format("%@ / month", price)
        }
        if let price = status.price_display, !price.isEmpty {
            if let expiresAt = status.expires_at, !expiresAt.isEmpty {
                return L10n.format("%@ · 到期 %@", price, status.formattedExpiryDate)
            }
            return price
        }
        return L10n.string("價格與試用長度會以 App Store 顯示為準")
    }

    static func ctaTitle(for status: KGSubscriptionStatus) -> String {
        if status.source == "admin", status.is_active {
            return L10n.string("查看權限")
        }
        return status.is_active ? L10n.string("管理訂閱") : L10n.string("訂閱")
    }

    static func sourceLabel(for status: KGSubscriptionStatus) -> String {
        if status.source == "admin", status.is_active {
            return L10n.string("管理員授權")
        }
        return L10n.string("App Store 訂閱")
    }

    static func managementNote(for status: KGSubscriptionStatus) -> String {
        if status.source == "admin", status.is_active {
            return L10n.string("如需延長或調整，請聯絡管理員。")
        }
        if status.is_active {
            return L10n.string("可在訂閱頁重新同步或恢復購買，確認訂閱狀態。")
        }
        return L10n.string("價格、免費試用與續訂都以 App Store 顯示為準。")
    }

    static func pricingUnavailableMessage(for status: KGSubscriptionStatus, hasStorePrice: Bool) -> String? {
        if status.source == "admin", status.is_active {
            return nil
        }
        let hasRemotePrice = status.price_display?.isEmpty == false
        guard !hasStorePrice, !hasRemotePrice else { return nil }
        return L10n.string("App Store 價格載入中，稍後會自動更新。")
    }

    static func restoreLabel(for status: KGSubscriptionStatus) -> String {
        if status.source == "admin", status.is_active {
            return L10n.string("恢復購買不可用")
        }
        return L10n.string("可恢復購買")
    }

    static func restoreDescription(for status: KGSubscriptionStatus) -> String {
        if status.source == "admin", status.is_active {
            return L10n.string("這個帳號的 Pro 來自管理員授權；若需延長或撤銷，請由管理員處理。")
        }
        if status.is_active {
            return L10n.string("若裝置間狀態不同，可在訂閱頁使用恢復購買重新對齊 App Store。")
        }
        return L10n.string("若先前已訂閱但此處顯示未啟用，可在訂閱頁使用恢復購買。")
    }

    static func restoreAvailable(for status: KGSubscriptionStatus) -> Bool {
        !(status.source == "admin" && status.is_active)
    }

}
