//
//  KGService+UserConfig.swift
//  Books & Vocab
//

import Foundation

// MARK: - Subscription & Billing Models

struct KGSubscriptionStatus: Codable, Equatable {
    let is_active: Bool
    let product_id: String?
    let plan_name: String?
    let price_display: String?
    let status: String
    let is_trial: Bool
    let trial_days: Int?
    let will_renew: Bool
    let expires_at: String?
    let source: String
    let last_synced_at: String?
}

extension KGSubscriptionStatus {
    var isCancelledButActive: Bool {
        is_active && !will_renew && source != "admin"
    }

    var formattedExpiryDate: String {
        Self.formattedExpiry(expires_at)
    }

    var isExpired: Bool {
        guard let expires_at, !expires_at.isEmpty,
              let date = Self.parseExpiryDate(expires_at) else { return false }
        return date < Date()
    }

    static func parseExpiryDate(_ isoString: String) -> Date? {
        expiryISO8601Formatter.date(from: isoString) ?? expiryISO8601FallbackFormatter.date(from: isoString)
    }

    private static let expiryISO8601Formatter = AppDateFormatters.iso8601
    private static let expiryISO8601FallbackFormatter = AppDateFormatters.iso8601Simple

    static func formattedExpiry(_ isoString: String?) -> String {
        guard let isoString, !isoString.isEmpty else {
            return L10n.string("未知時間")
        }
        if let date = expiryISO8601Formatter.date(from: isoString)
            ?? expiryISO8601FallbackFormatter.date(from: isoString) {
            return LocaleAwareFormatter.shared.string(from: date, format: "yyyy/MM/dd HH:mm")
        }
        return isoString
    }
}

struct KGEntitlements: Codable, Equatable {
    let pro: KGSubscriptionStatus
}

struct KGAppStoreSubscriptionSyncRequest: Codable {
    let product_id: String
    let transaction_id: String?
    let original_transaction_id: String?
    let environment: String
    let status: String
    let is_trial: Bool
    let expires_at: String?
    let will_renew: Bool
    let price_display: String?
    let signed_transaction_info: String?
}

// MARK: - User Configuration & Account

extension KGService {

    /// user-config 請求的 401 登出接線（#2806）。`KGUserConfigClient` 不持有 KGService，
    /// 故真實 401 在此接住並走與 `authenticatedRequest` 相同的 `handleUnauthorized`；
    /// 過期與否不由本地時鐘判斷，一律交給伺服器 401。
    private func performUserConfigRequest(
        _ send: (String) async throws -> KGUserConfig
    ) async throws -> KGUserConfig {
        let token = try await currentAuthToken()
        do {
            return try await send(token)
        } catch KGError.unauthorized {
            await handleUnauthorized(modelContainer: nil, reason: "http_401")
            throw KGError.unauthorized
        }
    }

    func fetchUserConfig() async throws -> KGUserConfig {
        let config = try await performUserConfigRequest { token in
            try await userConfigClient.fetchUserConfig(baseURL: baseURL, token: token)
        }
        AppLog.kg.info("Fetched config successfully")
        return config
    }

    func fetchEntitlements() async throws -> KGEntitlements {
        let result = try await authenticatedDecode(KGEntitlements.self, path: "api/user/entitlements")
        AppLog.kg.info("Fetched entitlements successfully")
        return result
    }

    func syncAppStoreSubscription(_ snapshot: KGAppStoreSubscriptionSyncRequest) async throws -> KGEntitlements {
        let result = try await authenticatedDecode(
            KGEntitlements.self,
            path: "api/billing/app-store/sync",
            method: "POST",
            body: try JSONEncoder().encode(snapshot)
        )
        AppLog.kg.info("Synced App Store subscription successfully")
        return result
    }

    func updateTranslationConfig(_ translationConfig: KGTranslationConfig) async throws -> KGUserConfig {
        let config = try await performUserConfigRequest { token in
            try await userConfigClient.updateTranslationConfig(
                baseURL: baseURL,
                token: token,
                translation: translationConfig
            )
        }
        AppLog.kg.info("Updated translation config successfully")
        return config
    }

    func updateReviewClockConfig(_ reviewClock: KGReviewClockConfig) async throws -> KGUserConfig {
        let config = try await performUserConfigRequest { token in
            try await userConfigClient.updateReviewClockConfig(
                baseURL: baseURL,
                token: token,
                reviewClock: reviewClock
            )
        }
        AppLog.kg.info("Updated review clock config successfully")
        return config
    }

    func updateReviewModeConfig(_ reviewMode: KGReviewModeConfig) async throws -> KGUserConfig {
        let config = try await performUserConfigRequest { token in
            try await userConfigClient.updateReviewModeConfig(
                baseURL: baseURL,
                token: token,
                reviewMode: reviewMode
            )
        }
        AppLog.kg.info("Updated review mode config successfully")
        return config
    }

    func updateVocabUIConfig(_ vocabUI: KGVocabUIConfig) async throws -> KGUserConfig {
        let config = try await performUserConfigRequest { token in
            try await userConfigClient.updateVocabUIConfig(
                baseURL: baseURL,
                token: token,
                vocabUI: vocabUI
            )
        }
        AppLog.kg.info("Updated vocab_ui (active notebook) config successfully")
        return config
    }

    func updateAutoLinkConfig(_ autoLink: KGAutoLinkConfig) async throws -> KGUserConfig {
        let config = try await performUserConfigRequest { token in
            try await userConfigClient.updateAutoLinkConfig(
                baseURL: baseURL,
                token: token,
                autoLink: autoLink
            )
        }
        AppLog.kg.info("Updated auto_link config successfully")
        return config
    }

    /// #3417: a 401 here is returned, not turned into a generic session teardown. The caller
    /// (`SettingsCoordinator.deleteAccount`) has already captured the account id, and
    /// `logoutAfterAccountDeletion` then erases that account's local data and namespaced
    /// preferences. A plain http_401 logout would skip the namespaced preference purge.
    func deleteAccount() async throws {
        let (data, response) = try await authenticatedRequest(
            path: "api/user/account",
            method: "DELETE",
            retryPolicy: .none,
            unauthorized: .returnResponse
        )
        guard response.statusCode == 401 || (200...299).contains(response.statusCode) else {
            throw KGError.httpError(
                statusCode: response.statusCode,
                detail: String(data: data, encoding: .utf8) ?? "DELETE api/user/account failed"
            )
        }
    }
}
