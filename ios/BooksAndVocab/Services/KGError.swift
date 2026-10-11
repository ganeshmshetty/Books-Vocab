//
//  KGError.swift
//  Books & Vocab
//
//  KG API client error type.
//

import Foundation

enum KGError: LocalizedError {
    case notAuthenticated
    case unauthorized
    case offline
    case httpError(statusCode: Int, detail: String)
    case decodingError(underlying: Error)
    case networkError(underlying: Error)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated, .unauthorized:
            return L10n.string("未登入帳號或身份已過期")
        case .offline:
            return L10n.string("目前沒有網路連線")
        case .httpError(let code, let detail):
            return L10n.format("HTTP %@：%@", String(code), detail)
        case .decodingError(let err):
            return L10n.format("解碼錯誤：%@", err.localizedDescription)
        case .networkError(let err):
            return L10n.format("網路錯誤：%@", err.localizedDescription)
        case .serverError(let msg):
            return L10n.format("Books & Vocab 服務錯誤：%@", msg)
        }
    }

    var isNetworkRelated: Bool {
        switch self {
        case .offline, .networkError: return true
        default: return false
        }
    }

    var isRetryable: Bool {
        switch self {
        case .httpError(let code, _): return (500...599).contains(code) || code == 429
        case .offline, .networkError: return true
        default: return false
        }
    }
}

enum SyncFailurePresentation {
    /// Explicit language keeps presentation contracts deterministic without
    /// changing the application's selected language.
    static func message(label: String, error: Error, language: AppLanguage) -> String {
        L10n.format(
            "sync.failure.message",
            language: language,
            operationTitle(for: label, language: language),
            reasonTitle(for: error, language: language)
        )
    }

    /// 部分失敗的彙總訊息。同一原因的腿併成一組（操作名列在前、原因只說一次），
    /// 組與組之間用該語系的列表分隔符（zh 為「、」、en 為 ", " 的本地化形式），
    /// 不寫死 ASCII ", "。
    static func partialFailureSummary(
        _ failures: [(label: String, reason: String)],
        language: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        var reasonOrder: [String] = []
        var labelsByReason: [String: [String]] = [:]
        for failure in failures {
            if labelsByReason[failure.reason] == nil {
                reasonOrder.append(failure.reason)
            }
            labelsByReason[failure.reason, default: []].append(failure.label)
        }
        let groups = reasonOrder.map { reason -> String in
            let operations = (labelsByReason[reason] ?? []).map {
                operationTitle(for: $0, language: language)
            }
            return L10n.format(
                "sync.failure.message",
                language: language,
                localizedList(operations, language: language, preferredLanguages: preferredLanguages),
                reason
            )
        }
        return L10n.format(
            "背景同步部分失敗：%@",
            language: language,
            localizedList(groups, language: language, preferredLanguages: preferredLanguages)
        )
    }

    private static func localizedList(
        _ items: [String],
        language: AppLanguage,
        preferredLanguages: [String]
    ) -> String {
        let formatter = ListFormatter()
        formatter.locale = AppLanguageStore.shared.formatLocale(
            for: language,
            preferredLanguages: preferredLanguages
        )
        // ListFormatter.string(from:) 對非空陣列不會回 nil；callers 保證 items 非空。
        // 這裡不寫回寫死的 ASCII 分隔符，unreachable fallback 只保留不會把標點硬編在內的形式。
        return formatter.string(from: items) ?? items.joined()
    }

    private static func operationTitle(for label: String, language: AppLanguage) -> String {
        switch label {
        case "pushReview":
            return L10n.string("sync.failure.operation.pushReview", language: language)
        case "pushReviewEvents":
            return L10n.string("sync.failure.operation.pushReviewEvents", language: language)
        case "pull":
            return L10n.string("sync.failure.operation.pull", language: language)
        case "pullReviewEvents":
            return L10n.string("sync.failure.operation.pullReviewEvents", language: language)
        default:
            return L10n.string("sync.failure.operation.generic", language: language)
        }
    }

    /// 只取「為什麼失敗」，不帶「哪個操作失敗」的前綴。
    ///
    /// 給逐步同步清單用：那一列本身就是操作名，`message(label:error:)` 的
    /// 「『下載單字』失敗：…」在該處會把操作名說第二遍。更重要的是它擋住了
    /// `error.localizedDescription` 這條捷徑——後者對 `CancellationError` 會吐
    /// 英文的「The operation couldn't be completed.」，對 `KGError.httpError`
    /// 會把內部 path（"GET api/vocab failed"）漏到使用者眼前。
    static func reason(for error: Error) -> String {
        reason(for: error, language: AppLanguageStore.shared.selection)
    }

    static func reason(for error: Error, language: AppLanguage) -> String {
        reasonTitle(for: error, language: language)
    }

    private static func reasonTitle(for error: Error, language: AppLanguage) -> String {
        if let kgError = error as? KGError {
            return reasonTitle(for: kgError, language: language)
        }
        if let urlError = error as? URLError {
            return reasonTitle(for: urlError, language: language)
        }
        return L10n.string("sync.failure.reason.unknown", language: language)
    }

    private static func reasonTitle(for error: KGError, language: AppLanguage) -> String {
        switch error {
        case .notAuthenticated, .unauthorized:
            return L10n.string("sync.failure.reason.authExpired", language: language)
        case .offline:
            return L10n.string("sync.failure.reason.offline", language: language)
        case .networkError(let underlying):
            if let urlError = underlying as? URLError {
                return reasonTitle(for: urlError, language: language)
            }
            return L10n.string("sync.failure.reason.network", language: language)
        case .httpError(let statusCode, _):
            if statusCode == 429 {
                return L10n.string("sync.failure.reason.rateLimited", language: language)
            }
            if (500...599).contains(statusCode) {
                return L10n.string("sync.failure.reason.serverUnavailable", language: language)
            }
            // 4xx（非 429）帶上 status code，提供可觀測性 — 多數是契約/請求問題，
            // code 是定位的關鍵線索（見 review-event pull 死鎖案）。
            return L10n.format(
                "sync.failure.reason.serverRejectedCode",
                language: language,
                String(statusCode)
            )
        case .decodingError:
            return L10n.string("sync.failure.reason.decoding", language: language)
        case .serverError:
            return L10n.string("sync.failure.reason.server", language: language)
        }
    }

    private static func reasonTitle(for error: URLError, language: AppLanguage) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return L10n.string("sync.failure.reason.offline", language: language)
        case .timedOut:
            return L10n.string("sync.failure.reason.timeout", language: language)
        case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return L10n.string("sync.failure.reason.network", language: language)
        default:
            return L10n.string("sync.failure.reason.network", language: language)
        }
    }
}

/// isLoggedIn 已設、但 keychain token 尚未載入的空窗（#2714）。
/// 不是伺服器 401：呼叫端必須跳過這次工作，不可登出或清本地資料。
/// 刻意不是 `KGError` case —— 它不屬於任何 HTTP／網路分類，也不該被
/// 既有的 `.unauthorized` 分支（登出）接住。
struct KGSessionPendingError: Error, LocalizedError, Equatable {
    var errorDescription: String? { L10n.string("未登入帳號或身份已過期") }
}
