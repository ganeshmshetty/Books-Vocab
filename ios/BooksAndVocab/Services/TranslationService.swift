//
//  TranslationService.swift
//  Books & Vocab
//
//  Created by 陳亮宇 on 2026/2/24.
//

import Foundation

/// AI 翻譯結果
struct TranslationResult: Codable {
    let translation: String
    let partOfSpeech: String?
    let explanation: String?     // Phase 2 填入
    var rootForm: String? = nil  // AI 判斷的詞根原形（e.g. "laid" → "lay"）
    var latency: TimeInterval?   // 耗時（秒）
}

/// AI 翻譯服務 — 使用 Gemini API 進行上下文感知翻譯
@Observable
final class TranslationService: Translating {
    @ObservationIgnored
    private let authSession: any AuthSessionProviding
    @ObservationIgnored
    private let quotaStore: any QuotaProviding
    @ObservationIgnored
    private let session: URLSession

    init(
        authSession: any AuthSessionProviding = MainActor.assumeIsolated({ AuthManager.shared }),
        quotaStore: any QuotaProviding = QuotaStore.shared,
        session: URLSession = sharedURLSession
    ) {
        self.authSession = authSession
        self.quotaStore = quotaStore
        self.session = session
    }

    /// 與 backend `MAX_WORD_LENGTH` 一致。
    private static let maxWordLength = 200

    /// Backend Server URL
    private var backendURL: String {
        KGService.getServerURL()
    }

    // MARK: - Phase 1: 精簡翻譯（~10 output tokens）

    func translateQuick(
        word: String,
        context: String,
        onRetry: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> TranslationResult {
        let startTime = Date()
        AppAnalytics.track(.translationRequested(word: word, type: .quick))
        let signpostState = AppAnalytics.beginInterval("TranslateQuick")

        var result: TranslationResult
        do {
            AppLog.translation.debug("Quick翻譯請求: \(word)")
            let data = try await callBackendWithRetry(
                endpoint: "/api/translate/quick", word: word, context: context,
                retryPolicy: .default, onRetry: onRetry
            )

            struct QuickResult: Codable {
                let t: String
                let p: String?
                let r: String?
            }

            let quick = try Self.decodeResponse(QuickResult.self, from: data)
            AppLog.translation.info("Quick翻譯: \(word) → \(quick.t) (root: \(quick.r ?? "nil"))")

            result = TranslationResult(
                translation: quick.t,
                partOfSpeech: quick.p,
                explanation: nil,
                rootForm: quick.r,
                latency: nil
            )
        } catch {
            AppAnalytics.endInterval("TranslateQuick", signpostState)
            recordTranslationFailure(error, word: word, type: .quick, context: "kg.translate.quick")
            throw error
        }

        let endTime = Date()
        result.latency = endTime.timeIntervalSince(startTime)
        AppAnalytics.endInterval("TranslateQuick", signpostState)
        let latency = result.latency ?? endTime.timeIntervalSince(startTime)
        let latencyMs = Int(latency * 1000)
        AppAnalytics.track(.translationCompleted(word: word, type: .quick, latencyMs: latencyMs))
        return result
    }

    // MARK: - Phase 1b: 短語翻譯（Flow 2，只回傳翻譯文字）

    func translatePhrase(
        phrase: String,
        context: String,
        onRetry: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> String {
        let startTime = Date()
        AppAnalytics.track(.translationRequested(word: phrase, type: .phrase))

        do {
            AppLog.translation.debug("短語翻譯請求: \(phrase)")
            let data = try await callBackendWithRetry(
                endpoint: "/api/translate/phrase", word: phrase, context: context,
                retryPolicy: .default, onRetry: onRetry
            )

            struct PhraseResult: Codable {
                let t: String
            }

            let result = try Self.decodeResponse(PhraseResult.self, from: data)
            AppLog.translation.info("短語翻譯: \(phrase) → \(result.t)")
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            AppAnalytics.track(.translationCompleted(word: phrase, type: .phrase, latencyMs: latencyMs))
            return result.t
        } catch {
            recordTranslationFailure(error, word: phrase, type: .phrase, context: "kg.translate.phrase")
            throw error
        }
    }

    // MARK: - Phase 2: 語境解釋（使用者按需觸發）

    func fetchExplanation(
        word: String,
        context: String,
        onRetry: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> (explanation: String, latency: TimeInterval) {
        let startTime = Date()
        AppAnalytics.track(.translationRequested(word: word, type: .explanation))
        let signpostState = AppAnalytics.beginInterval("FetchExplanation")

        do {
            AppLog.translation.debug("解釋請求: \(word)")
            let data = try await callBackendWithRetry(
                endpoint: "/api/translate/explain", word: word, context: context,
                retryPolicy: .default, onRetry: onRetry
            )

            struct ExplanationResult: Codable {
                let e: String
            }

            let result = try Self.decodeResponse(ExplanationResult.self, from: data)
            AppLog.translation.info("解釋完成: \(result.e.prefix(50))...")

            let endTime = Date()
            let latency = endTime.timeIntervalSince(startTime)
            AppAnalytics.endInterval("FetchExplanation", signpostState)
            AppAnalytics.track(.translationCompleted(word: word, type: .explanation, latencyMs: Int(latency * 1000)))
            return (result.e, latency)
        } catch {
            AppAnalytics.endInterval("FetchExplanation", signpostState)
            recordTranslationFailure(error, word: word, type: .explanation, context: "kg.translate.explain")
            throw error
        }
    }

    private func recordTranslationFailure(
        _ error: Error,
        word: String,
        type: AnalyticsEvent.TranslationType,
        context: String
    ) {
        AppAnalytics.track(.translationFailed(word: word, type: type, error: error.localizedDescription))
        recordTranslationFailureIfNeeded(error, context: context)
    }

    /// Filter helper: only forward server-side / parser / unexpected failures to Sentry.
    /// User-recoverable conditions (offline, login expired, quota exhausted, 429 rate-limit,
    /// missing token) are surfaced via `.userRecoverable` and dropped here to avoid
    /// flooding Sentry during token rotation / network blips.
    private func recordTranslationFailureIfNeeded(_ error: Error, context: String) {
        if error is CancellationError { return }
        if let tErr = error as? TranslationError {
            switch tErr {
            case .quotaExhausted, .userRecoverable:
                return
            case .apiError, .parseError, .clientError:
                break
            }
        }
        if let urlErr = error as? URLError,
           urlErr.code == .cancelled || urlErr.code == .notConnectedToInternet {
            return
        }
        AppCrashReporting.record(error, context: context)
    }

    // MARK: - API Error Model

    private struct APIErrorDetail: Decodable {
        let code: String?
        let detail: String?
    }

    // MARK: - Retry Wrapper

    private func callBackendWithRetry(
        endpoint: String,
        word: String,
        context: String,
        retryPolicy: RetryPolicy = .default,
        onRetry: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> Data {
        var lastError: Error?

        for attempt in 1...retryPolicy.maxAttempts {
            do {
                if attempt > 1 {
                    await onRetry?(attempt - 1, retryPolicy.maxAttempts - 1)
                    let delay = retryPolicy.baseDelay * pow(2.0, Double(attempt - 2))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                return try await callBackend(endpoint: endpoint, word: word, context: context)
            } catch let error as TranslationError {
                // quota_exhausted / 401 / user-recoverable 不重試
                switch error {
                case .quotaExhausted, .parseError, .userRecoverable, .clientError:
                    throw error
                case .apiError:
                    lastError = error
                    if attempt < retryPolicy.maxAttempts { continue }
                }
            } catch let error as URLError {
                lastError = error
                switch error.code {
                case .timedOut, .networkConnectionLost:
                    if !NetworkMonitor.shared.isConnected { throw error }
                    if attempt < retryPolicy.maxAttempts { continue }
                default:
                    throw error
                }
            } catch {
                throw error
            }
        }

        throw lastError ?? TranslationError.apiError(L10n.string("請求失敗"))
    }

    // MARK: - Backend Translation API 呼叫

    private func callBackend(endpoint: String, word: String, context: String) async throws -> Data {
        // 後端 translate schema 以 code point 計 max_length；超長仍送出只會換到 422 → .clientError，
        // 使用者拿不到可行動的提示，故在本地擋下、不送請求。
        guard word.unicodeScalars.count <= Self.maxWordLength else {
            throw TranslationError.userRecoverable(
                L10n.format("選取的文字超過 %@ 字元，請縮短後再試", "\(Self.maxWordLength)")
            )
        }

        guard NetworkMonitor.shared.isConnected else {
            throw TranslationError.userRecoverable(L10n.string("目前沒有網路連線"))
        }

        let baseURL = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanURL = baseURL
        if !cleanURL.hasPrefix("http://") && !cleanURL.hasPrefix("https://") {
            cleanURL = "http://" + cleanURL
        }
        
        guard let url = URL(string: "\(cleanURL)\(endpoint)") else {
            throw TranslationError.apiError(L10n.string("無效的後端 URL"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 帶上授權 Header (因為 /api/translate 是受保護的端點)
        // 不以本地 exp 預先攔截：與 KGService 一致交由伺服器 401 判定（401 分支見下方）。
        guard let token = await authSession.token else {
            throw TranslationError.userRecoverable(L10n.string("未登入，無法調用翻譯 API"))
        }
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let trimmedContext = context.count > 600 ? String(context.prefix(600)) : context
        let body: [String: String] = [
            "word": word,
            "context": trimmedContext,
            "source_lang": TranslationLanguage.currentSource.rawValue,
            "target_lang": TranslationLanguage.currentTarget.rawValue,
        ]

        request.httpBody = try JSONEncoder().encode(body)
        let requestID = RequestObservation.attachRequestID(to: &request)

        let quotaEpoch = quotaStore.epoch
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.apiError(L10n.string("無法取得 HTTP 回應"))
        }
        let responseRequestID = RequestObservation.responseRequestID(from: httpResponse, fallback: requestID)

        // Update quota from response headers (before status check).
        // QuotaStore is @Observable (non-isolated) and drives SwiftUI — mutate on main.
        await MainActor.run { quotaStore.update(from: httpResponse, ifEpoch: quotaEpoch) }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? L10n.string("(無法讀取)")
            AppLog.translation.error(
                "Backend API error [\(httpResponse.statusCode)] request_id=\(responseRequestID): \(errorBody)"
            )

            if httpResponse.statusCode == 401 {
                throw TranslationError.userRecoverable(L10n.string("登入憑證已失效，請重新登入"))
            }
            if httpResponse.statusCode == 429 {
                // Prefer structured JSON check, fallback to string match
                var isQuotaExhausted = false
                if let errorData = errorBody.data(using: .utf8),
                   let json = try? JSONDecoder().decode(APIErrorDetail.self, from: errorData),
                   json.code == "quota_exhausted" {
                    isQuotaExhausted = true
                } else if errorBody.contains("quota_exhausted") {
                    isQuotaExhausted = true
                }
                if isQuotaExhausted {
                    throw TranslationError.quotaExhausted(quotaStore.resetText)
                }
                throw TranslationError.userRecoverable(L10n.string("請求過於頻繁，請稍後再試"))
            }
            let message = L10n.format("後端伺服器錯誤 (%@)", "\(httpResponse.statusCode)")
            // 4xx 是永久性的請求錯誤，重試只會白等並多耗一次 rate limit。
            if Self.isPermanentClientStatus(httpResponse.statusCode) {
                throw TranslationError.clientError(message)
            }
            throw TranslationError.apiError(message)
        }

        return data
    }

    /// 4xx（401/429 已在上方分流）不可重試；5xx 與其他狀態維持 `.apiError` 可重試。
    static func isPermanentClientStatus(_ status: Int) -> Bool {
        (400..<500).contains(status)
    }

    /// 解碼失敗統一轉成 `.parseError`，避免 raw DecodingError 外洩。
    static func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TranslationError.parseError(String(describing: error))
        }
    }


}

enum TranslationError: LocalizedError {
    /// 真實後端/transport 錯誤（5xx、解碼前的 HTTP 異常、misconfig 等），值得進 Sentry。
    case apiError(String)
    /// JSON 解碼失敗等 parser 錯誤。
    case parseError(String)
    /// 額度用盡：使用者政策，非缺陷。
    case quotaExhausted(String)
    /// 使用者可自行恢復的條件：離線、未登入、登入過期、429 限速。**不**進 Sentry。
    case userRecoverable(String)
    /// 4xx 永久性請求錯誤：不重試，但仍屬缺陷訊號，進 Sentry。
    case clientError(String)

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return L10n.format("API 錯誤：%@", msg)
        case .parseError(let msg): return L10n.format("解析錯誤：%@", msg)
        case .quotaExhausted(let resetText): return L10n.format("今日額度已用完，%@", resetText)
        case .userRecoverable(let msg): return msg
        case .clientError(let msg): return L10n.format("API 錯誤：%@", msg)
        }
    }
}
