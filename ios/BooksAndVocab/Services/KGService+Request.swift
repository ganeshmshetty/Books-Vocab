//
//  KGService+Request.swift
//  Books & Vocab
//
//  Authenticated HTTP middleware — token attach, retry, Sentry breadcrumbs.
//

import Foundation

extension KGService {
    /// Foundation converts `httpBody` into a private stream before handing a
    /// request to a custom URLProtocol. Preserve the original bytes as an
    /// NSURLProtocol property so injected transports can inspect the same
    /// payload without changing anything sent over the wire.
    static let requestBodyURLProtocolPropertyKey = "KGServiceRequestBody"

    /// Build the request URL from `baseURL` + `path` + `queryItems`, percent-encoding
    /// any literal `+` in a query value to `%2B`.
    ///
    /// `URLComponents.queryItems` leaves `+` un-encoded — `+` is a legal RFC 3986 query
    /// character — but HTTP servers decode the query string as
    /// `application/x-www-form-urlencoded`, where `+` means a space. A value containing
    /// `+` (e.g. an ISO8601 cursor's `+00:00` offset) is therefore silently corrupted to
    /// a space on the wire (this caused the review-event download 400 deadlock). Encoding
    /// it as `%2B` makes every query value round-trip byte-for-byte. Only raw `+` from
    /// values reaches `percentEncodedQuery`; every other reserved char is already encoded
    /// by the `queryItems` setter, so the replacement is safe and idempotent.
    static func composeRequestURL(
        baseURL: URL, path: String, queryItems: [URLQueryItem]?
    ) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url
    }

    func authenticatedRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        headers: [String: String] = [:],
        retryPolicy: RetryPolicy = .default,
        onRetry: ((Int, Int) -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let token = try await currentAuthToken()

        guard let url = KGService.composeRequestURL(
            baseURL: baseURL, path: path, queryItems: queryItems
        ) else {
            throw KGError.serverError("Invalid URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        if let body {
            let mutableRequest = (request as NSURLRequest).mutableCopy()
                as! NSMutableURLRequest
            URLProtocol.setProperty(
                body,
                forKey: Self.requestBodyURLProtocolPropertyKey,
                in: mutableRequest
            )
            request = mutableRequest as URLRequest
        }
        let requestID = RequestObservation.attachRequestID(to: &request)

        var lastError: Error?
        var retryAfterOverride: TimeInterval? = nil

        for attempt in 1...retryPolicy.maxAttempts {
            do {
                if attempt > 1 {
                    onRetry?(attempt - 1, retryPolicy.maxAttempts - 1)
                    let delay: TimeInterval
                    if let override = retryAfterOverride {
                        delay = override
                        retryAfterOverride = nil
                    } else {
                        delay = retryPolicy.baseDelay * pow(2.0, Double(attempt - 2))
                    }
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                let (data, response) = try await transport.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw KGError.serverError("Invalid response from \(path)")
                }
                let responseRequestID = RequestObservation.responseRequestID(from: httpResponse, fallback: requestID)
                Self.recordHTTPBreadcrumb(
                    url: url,
                    method: method,
                    statusCode: httpResponse.statusCode,
                    requestID: responseRequestID
                )

                if httpResponse.statusCode == 401 {
                    // No client-side token refresh exists (AuthManager.token is a plain
                    // stored credential; there is no refresh-token flow). The server's 401 is
                    // the only authority that a session is invalid (#2806: the local clock is
                    // not), so it logs out here — the single point every required-auth call
                    // passes through — and then surfaces unauthorized to the caller.
                    AppLog.kg.info("401 received for \(path) request_id=\(responseRequestID), logging out")
                    await handleUnauthorized(modelContainer: nil, reason: "http_401")
                    throw KGError.unauthorized
                }

                // Retryable HTTP status — retry if policy allows
                if retryPolicy.retryableStatusCodes.contains(httpResponse.statusCode) {
                    lastError = KGError.httpError(
                        statusCode: httpResponse.statusCode,
                        detail: String(data: data, encoding: .utf8) ?? "\(method) \(path) failed"
                    )
                    if attempt < retryPolicy.maxAttempts {
                        // 429: 優先使用伺服器的 Retry-After header（秒數格式，cap 60s）
                        if httpResponse.statusCode == 429 {
                            retryAfterOverride = Self.retryAfterDelay(
                                from: httpResponse.value(forHTTPHeaderField: "Retry-After")
                            )
                        }
                        continue
                    }
                }

                return (data, httpResponse)
            } catch let error as KGError {
                throw error // non-retryable KGError propagates immediately
            } catch let error as URLError {
                // -999 `cancelled` is never a transport fault: URLSession only
                // produces it when the request was cancelled, which for these
                // `async` calls means the enclosing Swift task was cancelled.
                // Reporting it as `KGError.networkError` put a lifecycle event
                // (view teardown, a superseded refresh) in front of the user as
                // "網路錯誤：已取消" — complete with a wifi-slash glyph and a retry
                // button whose retry raced into the same cancellation. Rethrowing
                // as `CancellationError` puts it in the category the rest of the
                // codebase already filters on (Sentry filters, sync phase
                // reporting, the vocab banner).
                if error.code == .cancelled { throw CancellationError() }
                lastError = KGError.networkError(underlying: error)
                Self.recordHTTPBreadcrumb(
                    url: url,
                    method: method,
                    statusCode: nil,
                    requestID: requestID,
                    urlErrorCode: error.code.rawValue
                )
                switch error.code {
                case .timedOut, .networkConnectionLost:
                    if !connectivityGate.isConnected { throw KGError.networkError(underlying: error) }
                    if attempt < retryPolicy.maxAttempts { continue }
                default:
                    throw KGError.networkError(underlying: error)
                }
            } catch {
                throw error
            }
        }

        throw lastError ?? KGError.serverError("Request failed after \(retryPolicy.maxAttempts) attempts")
    }

    /// Drop a Sentry breadcrumb describing one HTTP attempt.
    ///
    /// Privacy:
    /// - The URL is redacted to its path only — no host (already known via env tag),
    ///   no query string (where auth tokens / id_tokens / OAuth codes live).
    /// - The request_id is included so Sentry crumbs cross-correlate with backend
    ///   logs that already log + echo the same id via `X-Request-ID`.
    ///
    /// Levels:
    /// - 2xx/3xx → `.info`
    /// - 4xx/5xx → `.warning`
    /// - URLError (no HTTP exchange completed) → `.warning`
    private static func recordHTTPBreadcrumb(
        url: URL,
        method: String,
        statusCode: Int?,
        requestID: String?,
        urlErrorCode: Int? = nil
    ) {
        let redactedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        var data: [String: Any] = [
            "url": redactedPath,
            "method": method,
        ]
        if let statusCode { data["status_code"] = statusCode }
        if let requestID, !requestID.isEmpty { data["request_id"] = requestID }
        if let urlErrorCode { data["url_error_code"] = urlErrorCode }

        let level: AppCrashReporting.BreadcrumbLevel
        if let statusCode {
            level = (200..<400).contains(statusCode) ? .info : .warning
        } else {
            level = .warning  // transport failure — no HTTP response materialized
        }

        AppCrashReporting.addBreadcrumb(
            category: "http",
            message: "\(method) \(redactedPath)",
            level: level,
            data: data
        )
    }

    func authenticatedDecode<T: Decodable>(
        _ type: T.Type,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        headers: [String: String] = [:],
        retryPolicy: RetryPolicy = .default,
        onRetry: ((Int, Int) -> Void)? = nil
    ) async throws -> T {
        let (data, httpResponse) = try await authenticatedRequest(
            path: path, method: method, queryItems: queryItems,
            body: body, headers: headers, retryPolicy: retryPolicy, onRetry: onRetry
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            throw KGError.httpError(
                statusCode: httpResponse.statusCode,
                detail: String(data: data, encoding: .utf8) ?? "\(method) \(path) failed"
            )
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw KGError.decodingError(underlying: error)
        }
    }

    func authenticatedVoid(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        retryPolicy: RetryPolicy = .none
    ) async throws {
        let (data, httpResponse) = try await authenticatedRequest(
            path: path, method: method, queryItems: queryItems,
            body: body, retryPolicy: retryPolicy
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            throw KGError.httpError(
                statusCode: httpResponse.statusCode,
                detail: String(data: data, encoding: .utf8) ?? "\(method) \(path) failed"
            )
        }
    }

    /// 429 的 Retry-After（秒數格式）→ 重試延遲；上限 60s。
    static func retryAfterDelay(from header: String?) -> TimeInterval? {
        guard let header, let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 else { return nil }
        return min(seconds, 60)
    }
}
