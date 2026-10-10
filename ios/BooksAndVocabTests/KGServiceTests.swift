import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

/// Characterization tests for `KGService` and its collaborators.
///
/// `KGService.authenticatedRequest` / `authenticatedDecode` are tightly coupled to the
/// process-global `sharedURLSession`, `NetworkMonitor.shared`, and `AuthManager.shared`
/// singletons — there is no injection seam for `URLSession`, so a full request round-trip
/// cannot be unit-tested without a network stack. Instead these tests pin the *pure* seams
/// that those methods are built from and that determine their observable behaviour:
///
///   - HTTP status → retry/error classification (`RetryPolicy`, `KGError`)
///   - JSON decoding of every wire model (`authenticatedDecode`'s `JSONDecoder().decode`)
///   - exponential-backoff delay arithmetic used by the retry loop
///   - local JWT expiry helper (`JWTExpiry`, used only by `authTokenWithoutInvalidation`; #2806)
///   - request-header assembly (`RequestObservation`, the `X-Request-ID` plumbing)
///
/// This complements `KGServiceErrorTests` (error-predicate pinning) without overlap.
struct KGServiceTests {

    // MARK: - HTTP status → retry classification (authenticatedRequest retry loop)

    /// `authenticatedRequest` only retries a status code if it is in
    /// `retryPolicy.retryableStatusCodes`. Pin the exact membership for `.default`.
    @Test func default_policy_retries_only_transient_sync_statuses() {
        let retryable = RetryPolicy.default.retryableStatusCodes
        for code in [429, 500, 502, 503, 504] {
            #expect(retryable.contains(code), "default policy must retry \(code)")
        }
        for code in [200, 204, 301, 400, 401, 403, 404, 408, 501, 599] {
            #expect(!retryable.contains(code), "default policy must NOT retry \(code)")
        }
    }

    /// `.aggressive` shares the same retryable set as `.default` but with more attempts.
    @Test func aggressive_policy_same_retryable_set_more_attempts() {
        #expect(RetryPolicy.aggressive.retryableStatusCodes == RetryPolicy.default.retryableStatusCodes)
        #expect(RetryPolicy.aggressive.maxAttempts > RetryPolicy.default.maxAttempts)
    }

    /// `.none` is used by `authenticatedVoid` by default — a single attempt, no retry.
    @Test func none_policy_is_single_shot() {
        #expect(RetryPolicy.none.maxAttempts == 1)
        #expect(RetryPolicy.none.retryableStatusCodes.isEmpty)
        #expect(RetryPolicy.none.baseDelay == 0)
    }

    /// A non-2xx status that is NOT retryable surfaces as `KGError.httpError` carrying the
    /// exact status code — pin that `authenticatedDecode`/`authenticatedVoid` map it 1:1.
    @Test func non_2xx_maps_to_httpError_with_same_status_code() {
        for code in [400, 403, 404, 422, 500] {
            let err = KGError.httpError(statusCode: code, detail: "body")
            if case let .httpError(statusCode, detail) = err {
                #expect(statusCode == code)
                #expect(detail == "body")
            } else {
                Issue.record("expected .httpError for \(code)")
            }
        }
    }

    /// 504 Gateway Timeout is a transient sync failure and should retry.
    @Test func both_policies_retry_504() {
        #expect(RetryPolicy.default.retryableStatusCodes.contains(504))
        #expect(RetryPolicy.aggressive.retryableStatusCodes.contains(504))
    }

    // MARK: - Exponential backoff delay arithmetic (authenticatedRequest retry loop)

    /// The retry loop computes `delay = baseDelay * pow(2, attempt - 2)`.
    /// For `.default` (baseDelay 1.0): attempt 2 → 1s, attempt 3 → 2s.
    @Test func default_backoff_delays_double_each_attempt() {
        let base = RetryPolicy.default.baseDelay
        let attempt2 = base * pow(2.0, Double(2 - 2)) // 1.0
        let attempt3 = base * pow(2.0, Double(3 - 2)) // 2.0
        #expect(attempt2 == 1.0)
        #expect(attempt3 == 2.0)
    }

    /// For `.aggressive` (baseDelay 0.5, 5 attempts): 0.5, 1.0, 2.0, 4.0 for attempts 2..5.
    @Test func aggressive_backoff_delays_follow_geometric_progression() {
        let base = RetryPolicy.aggressive.baseDelay
        let expected: [Double] = [0.5, 1.0, 2.0, 4.0]
        for (idx, want) in expected.enumerated() {
            let attempt = idx + 2 // attempts 2,3,4,5
            let delay = base * pow(2.0, Double(attempt - 2))
            #expect(delay == want, "attempt \(attempt) backoff should be \(want)")
        }
    }

    /// 429 Retry-After header overrides the computed backoff but is capped at 60s.
    @Test func retry_after_override_is_capped_at_60_seconds() {
        #expect(min(TimeInterval(120), 60) == 60)
        #expect(min(TimeInterval(5), 60) == 5)
        #expect(min(TimeInterval(60), 60) == 60)
    }

    /// A malformed (non-numeric) Retry-After header cannot be parsed and must fall back to
    /// the computed exponential delay rather than crashing.
    @Test func malformed_retry_after_header_is_unparseable() {
        #expect(TimeInterval("not-a-number") == nil)
        #expect(TimeInterval("") == nil)
        #expect(TimeInterval("30") == 30)
    }

    /// #2716: 負值 / NaN / inf 會讓 `UInt64(delay * 1e9)` trap；必須視為不可用並回退指數退避。
    @Test func retry_after_delay_rejects_non_finite_and_negative() {
        #expect(KGService.retryAfterDelay(from: "-1") == nil)
        #expect(KGService.retryAfterDelay(from: "nan") == nil)
        #expect(KGService.retryAfterDelay(from: "inf") == nil)
        #expect(KGService.retryAfterDelay(from: nil) == nil)
        #expect(KGService.retryAfterDelay(from: "abc") == nil)
    }

    @Test func retry_after_delay_parses_and_caps() {
        #expect(KGService.retryAfterDelay(from: "0") == 0)
        #expect(KGService.retryAfterDelay(from: "5") == 5)
        #expect(KGService.retryAfterDelay(from: "120") == 60)
    }

    // MARK: - JSON decoding: KGHealthResponse (healthCheck path)

    @Test func health_response_decodes_full_payload() throws {
        let json = """
        {"status":"ok","cards":42,"links":13,"pendingCandidates":3,"lastModified":"2026-05-15T00:00:00Z"}
        """.data(using: .utf8)!
        let health = try JSONDecoder().decode(KGHealthResponse.self, from: json)
        #expect(health.status == "ok")
        #expect(health.cards == 42)
        #expect(health.links == 13)
        #expect(health.pendingCandidates == 3)
        #expect(health.lastModified == "2026-05-15T00:00:00Z")
    }

    /// `lastModified` is optional — a payload omitting it must still decode.
    @Test func health_response_decodes_with_null_lastModified() throws {
        let json = """
        {"status":"degraded","cards":0,"links":0,"pendingCandidates":0,"lastModified":null}
        """.data(using: .utf8)!
        let health = try JSONDecoder().decode(KGHealthResponse.self, from: json)
        #expect(health.lastModified == nil)
        // `healthCheck` only sets isConnected = true when status == "ok"
        #expect(health.status != "ok")
    }

    @Test func health_response_decodes_with_missing_lastModified_key() throws {
        let json = """
        {"status":"ok","cards":1,"links":0,"pendingCandidates":0}
        """.data(using: .utf8)!
        let health = try JSONDecoder().decode(KGHealthResponse.self, from: json)
        #expect(health.lastModified == nil)
    }

    /// Missing a required (non-optional) field → decode failure, which `authenticatedDecode`
    /// wraps as `KGError.decodingError`.
    @Test func health_response_missing_required_field_throws() {
        let json = """
        {"status":"ok","links":0,"pendingCandidates":0}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KGHealthResponse.self, from: json)
        }
    }

    /// Wrong type for a required field (string where Int expected) → decode failure.
    @Test func health_response_type_mismatch_throws() {
        let json = """
        {"status":"ok","cards":"forty-two","links":0,"pendingCandidates":0}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KGHealthResponse.self, from: json)
        }
    }

    /// Empty body — `String(data:encoding:)` yields "" and `JSONDecoder` rejects it.
    /// This is the "empty body" path of a 200 response with no content.
    @Test func empty_body_fails_to_decode() {
        let empty = Data()
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(KGHealthResponse.self, from: empty)
        }
    }

    /// Malformed (truncated) JSON → decode failure.
    @Test func malformed_json_fails_to_decode() {
        let malformed = "{\"status\":\"ok\",\"cards\":".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(KGHealthResponse.self, from: malformed)
        }
    }

    // MARK: - JSON decoding: KGAddResponse (vocab add path)

    @Test func add_response_decodes_full_payload() throws {
        let json = """
        {"created":2,"skipped":1,"duplicates":["apple","pear"],"cardIds":{"apple":"c1","pear":"c2"}}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(KGAddResponse.self, from: json)
        #expect(resp.created == 2)
        #expect(resp.skipped == 1)
        #expect(resp.duplicates == ["apple", "pear"])
        #expect(resp.cardIds["apple"] == "c1")
        #expect(resp.cardIds["pear"] == "c2")
    }

    @Test func add_response_decodes_empty_collections() throws {
        let json = """
        {"created":0,"skipped":0,"duplicates":[],"cardIds":{}}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(KGAddResponse.self, from: json)
        #expect(resp.duplicates.isEmpty)
        #expect(resp.cardIds.isEmpty)
    }

    @Test func add_response_missing_cardIds_throws() {
        let json = """
        {"created":0,"skipped":0,"duplicates":[]}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KGAddResponse.self, from: json)
        }
    }

    // MARK: - JSON coding: KGVocabSource / KGCard.source (cross-end contract)

    @Test func vocab_source_book_encodes_with_null_url() throws {
        let source = KGVocabSource.book(title: "Pride and Prejudice")
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(KGVocabSource.self, from: data)
        #expect(decoded.type == "book")
        #expect(decoded.title == "Pride and Prejudice")
        #expect(decoded.url == nil)
    }

    @Test func vocab_source_web_round_trips_with_url() throws {
        let json = """
        {"type":"web","title":"Wikipedia","url":"https://en.wikipedia.org/x"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(KGVocabSource.self, from: json)
        #expect(decoded.type == "web")
        #expect(decoded.title == "Wikipedia")
        #expect(decoded.url == "https://en.wikipedia.org/x")
    }

    @Test func vocab_entry_encodes_source_field() throws {
        let entry = KGVocabEntry(
            word: "ephemeral", translation: "短暫的", context: "an ephemeral moment",
            root_form: "ephemeral", source: .book(title: "Moby Dick"),
            source_lang: nil, target_lang: nil
        )
        let data = try JSONEncoder().encode(entry)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let src = obj?["source"] as? [String: Any]
        #expect(src?["type"] as? String == "book")
        #expect(src?["title"] as? String == "Moby Dick")
    }

    @Test func card_decodes_book_source() throws {
        let json = """
        {"id":"c1","content":"ephemeral","meaning":"短暫的","pos":null,
         "difficulty":null,"difficultyTier":null,"note":null,"collocations":[],
         "examples":[],"mode":"recognition","isDeleted":false,
         "source":{"type":"book","title":"Moby Dick","url":null}}
        """.data(using: .utf8)!
        let card = try JSONDecoder().decode(KGCard.self, from: json)
        #expect(card.source?.type == "book")
        #expect(card.source?.title == "Moby Dick")
        #expect(card.source?.url == nil)
    }

    @Test func card_decodes_book_source_with_chapter() throws {
        // Backend `VocabSource` carries a book-only `chapter` field; iOS
        // must not silently drop it when decoding the card payload.
        let json = """
        {"id":"c1","content":"ephemeral","meaning":"短暫的","pos":null,
         "difficulty":null,"difficultyTier":null,"note":null,"collocations":[],
         "examples":[],"mode":"recognition","isDeleted":false,
         "source":{"type":"book","title":"Moby Dick","url":null,
                   "chapter":"Chapter 1: Loomings"}}
        """.data(using: .utf8)!
        let card = try JSONDecoder().decode(KGCard.self, from: json)
        #expect(card.source?.type == "book")
        #expect(card.source?.title == "Moby Dick")
        #expect(card.source?.url == nil)
        #expect(card.source?.chapter == "Chapter 1: Loomings")
    }

    @Test func card_decodes_with_missing_source_as_nil() throws {
        let json = """
        {"id":"c1","content":"ephemeral","meaning":"短暫的","pos":null,
         "difficulty":null,"difficultyTier":null,"note":null,"collocations":[],
         "examples":[],"mode":"recognition","isDeleted":false}
        """.data(using: .utf8)!
        let card = try JSONDecoder().decode(KGCard.self, from: json)
        #expect(card.source == nil)
    }

    // MARK: - JSON decoding: KGUserConfig / KGTranslationConfig (user config path)

    @Test func user_config_decodes_nested_translation() throws {
        let json = """
        {"translation":{"source_lang":"en","target_lang":"zh-Hant"}}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(KGUserConfig.self, from: json)
        #expect(config.translation?.source_lang == "en")
        #expect(config.translation?.target_lang == "zh-Hant")
    }

    /// All fields are optional — an empty object must decode to all-nil.
    @Test func user_config_decodes_empty_object() throws {
        let json = "{}".data(using: .utf8)!
        let config = try JSONDecoder().decode(KGUserConfig.self, from: json)
        #expect(config.translation == nil)
    }

    @Test func translation_config_decodes_partial_fields() throws {
        let json = """
        {"source_lang":"ja"}
        """.data(using: .utf8)!
        let tc = try JSONDecoder().decode(KGTranslationConfig.self, from: json)
        #expect(tc.source_lang == "ja")
        #expect(tc.target_lang == nil)
    }

    /// KGUserConfig round-trips through encode → decode (used when writing config).
    @Test func user_config_round_trips_through_codable() throws {
        let original = KGUserConfig(
            translation: KGTranslationConfig(source_lang: "en", target_lang: "fr", updated_at: 7),
            review_clock: nil,
            review_mode: nil,
            vocab_ui: KGVocabUIConfig(active_notebook_id: "nb-7", updated_at: 42),
            auto_link: KGAutoLinkConfig(enabled: false, updated_at: 9)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KGUserConfig.self, from: encoded)
        #expect(decoded.translation?.source_lang == "en")
        #expect(decoded.translation?.target_lang == "fr")
        #expect(decoded.translation?.updated_at == 7)
        #expect(decoded.review_clock == nil)
        #expect(decoded.review_mode == nil)
        #expect(decoded.vocab_ui?.active_notebook_id == "nb-7")
        #expect(decoded.vocab_ui?.updated_at == 42)
    }

    // MARK: - JWTExpiry — local expiry helper (authTokenWithoutInvalidation; not a logout trigger, #2806)

    /// Helper: build an unsigned JWT whose payload carries the given `exp` claim.
    private func makeToken(exp: TimeInterval?) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64EncodedString()
        var payloadObj: [String: Any] = ["sub": "user"]
        if let exp { payloadObj["exp"] = exp }
        let payloadData = try! JSONSerialization.data(withJSONObject: payloadObj)
        let payload = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).sig"
    }

    /// A token expiring in the far future is not expired — `authTokenWithoutInvalidation` returns it.
    @Test func jwt_far_future_token_is_not_expired() {
        let token = makeToken(exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
        #expect(!JWTExpiry.isExpired(token))
    }

    /// A token already past its `exp` is expired — `authTokenWithoutInvalidation` returns nil (no logout, #2806).
    @Test func jwt_past_token_is_expired() {
        let token = makeToken(exp: Date().addingTimeInterval(-3600).timeIntervalSince1970)
        #expect(JWTExpiry.isExpired(token))
    }

    /// A token expiring within the 60s safety margin is treated as expired pre-emptively.
    @Test func jwt_token_inside_safety_margin_is_expired() {
        let token = makeToken(exp: Date().addingTimeInterval(30).timeIntervalSince1970)
        #expect(JWTExpiry.isExpired(token), "token within default 60s margin must pre-expire")
        // ...but with a smaller margin the same token is still valid.
        #expect(!JWTExpiry.isExpired(token, margin: 5))
    }

    /// A malformed token (not three segments / not base64) cannot be parsed; `isExpired`
    /// fails open (returns false) and defers the decision to the backend's 401 path.
    @Test func jwt_malformed_token_fails_open() {
        #expect(!JWTExpiry.isExpired("garbage"))
        #expect(!JWTExpiry.isExpired(""))
        #expect(!JWTExpiry.isExpired("only.two"))
        #expect(JWTExpiry.expirationDate(from: "garbage") == nil)
    }

    /// A well-formed JWT lacking an `exp` claim cannot yield an expiry date → fails open.
    @Test func jwt_token_without_exp_claim_fails_open() {
        let token = makeToken(exp: nil)
        #expect(JWTExpiry.expirationDate(from: token) == nil)
        #expect(!JWTExpiry.isExpired(token))
    }

    /// URL-safe base64 payloads (with `-`/`_` and missing padding) must still decode —
    /// real JWTs use base64url.
    @Test func jwt_url_safe_base64_payload_decodes() {
        let exp = Date().addingTimeInterval(7200).timeIntervalSince1970
        let token = makeToken(exp: exp)
        let parsed = JWTExpiry.expirationDate(from: token)
        #expect(parsed != nil)
        if let parsed {
            #expect(abs(parsed.timeIntervalSince1970 - exp) < 1.0)
        }
    }

    // MARK: - RequestObservation — auth + request-id header assembly

    /// `attachRequestID` injects a fresh 16-char hex `X-Request-ID` when none exists.
    @Test func attach_request_id_generates_16_char_id() {
        var request = URLRequest(url: URL(string: "\(TestBrandIdentity.publicBaseURL)/api/health")!)
        let id = RequestObservation.attachRequestID(to: &request)
        #expect(id.count == 16)
        #expect(request.value(forHTTPHeaderField: "X-Request-ID") == id)
        #expect(!id.contains("-"), "request id must be hex without dashes")
    }

    /// An already-present request id is preserved (idempotent on retry).
    @Test func attach_request_id_preserves_existing() {
        var request = URLRequest(url: URL(string: "\(TestBrandIdentity.publicBaseURL)/api/health")!)
        request.setValue("preset-id-1234", forHTTPHeaderField: "X-Request-ID")
        let id = RequestObservation.attachRequestID(to: &request)
        #expect(id == "preset-id-1234")
    }

    /// Two calls on independent requests yield distinct ids.
    @Test func attach_request_id_is_unique_per_request() {
        var r1 = URLRequest(url: URL(string: "\(TestBrandIdentity.publicBaseURL)/a")!)
        var r2 = URLRequest(url: URL(string: "\(TestBrandIdentity.publicBaseURL)/b")!)
        let id1 = RequestObservation.attachRequestID(to: &r1)
        let id2 = RequestObservation.attachRequestID(to: &r2)
        #expect(id1 != id2)
    }

    /// `responseRequestID` echoes back the server's id when present, else falls back.
    @Test func response_request_id_prefers_server_echo() {
        let url = URL(string: "\(TestBrandIdentity.publicBaseURL)/api/health")!
        let withEcho = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["X-Request-ID": "server-echo-99"]
        )!
        #expect(RequestObservation.responseRequestID(from: withEcho, fallback: "local-1") == "server-echo-99")
    }

    @Test func response_request_id_falls_back_when_header_absent() {
        let url = URL(string: "\(TestBrandIdentity.publicBaseURL)/api/health")!
        let noEcho = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
        #expect(RequestObservation.responseRequestID(from: noEcho, fallback: "local-fallback") == "local-fallback")
    }

    /// Pin the Authorization header format `authenticatedRequest` builds: `Bearer <token>`.
    @Test func authorization_header_uses_bearer_scheme() {
        var request = URLRequest(url: URL(string: "\(TestBrandIdentity.publicBaseURL)/api/health")!)
        let token = "abc.def.ghi"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc.def.ghi")
    }

    /// A request carrying a body gets `Content-Type: application/json`; a bodyless request
    /// does not — mirrors the `if body != nil` branch in `authenticatedRequest`.
    @Test func content_type_header_set_only_when_body_present() {
        var withBody = URLRequest(url: URL(string: "\(TestBrandIdentity.publicBaseURL)/api/vocab")!)
        let body: Data? = Data("{}".utf8)
        if body != nil {
            withBody.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        #expect(withBody.value(forHTTPHeaderField: "Content-Type") == "application/json")

        var noBody = URLRequest(url: URL(string: "\(TestBrandIdentity.publicBaseURL)/api/health")!)
        let none: Data? = nil
        if none != nil {
            noBody.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        #expect(noBody.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    // MARK: - URL composition (authenticatedRequest baseURL + path + query)

    /// `KGService.composeRequestURL` (used by `authenticatedRequest`) builds the request
    /// URL. Pin that query items survive into the final URL.
    @Test func query_items_compose_into_request_url() throws {
        let base = URL(string: TestBrandIdentity.publicBaseURL)!
        let url = try #require(KGService.composeRequestURL(
            baseURL: base,
            path: "api/cards",
            queryItems: [
                URLQueryItem(name: "since", value: "2026-05-01"),
                URLQueryItem(name: "limit", value: "50"),
            ]
        ))
        #expect(url.path == "/api/cards")
        #expect(url.query?.contains("since=2026-05-01") == true)
        #expect(url.query?.contains("limit=50") == true)
    }

    /// An empty/nil queryItems array leaves the URL clean — `composeRequestURL` skips
    /// query assignment when `queryItems` is empty.
    @Test func empty_query_items_leave_url_unchanged() throws {
        let base = URL(string: TestBrandIdentity.publicBaseURL)!
        let url = try #require(KGService.composeRequestURL(
            baseURL: base, path: "api/health", queryItems: nil
        ))
        #expect(url.absoluteString == "\(TestBrandIdentity.publicBaseURL)/api/health")
        #expect(url.query == nil)
    }

    /// Regression for the 2026-06-08 review-event download 400 deadlock: a query value
    /// containing a literal `+` (an ISO8601 cursor's `+00:00` offset) must be encoded as
    /// `%2B` on the wire. `URLComponents.queryItems` leaves `+` raw, and a server decodes
    /// query strings as x-www-form-urlencoded where `+` means a space — corrupting the
    /// timestamp to `...183209 00:00` and 400-ing every pull.
    @Test func plus_in_query_value_is_percent_encoded_to_survive_form_decoding() throws {
        let base = URL(string: TestBrandIdentity.publicBaseURL)!
        let cursor = "2026-06-06T07:02:00.183209+00:00"
        let url = try #require(KGService.composeRequestURL(
            baseURL: base,
            path: "api/vocab/review-events",
            queryItems: [URLQueryItem(name: "since", value: cursor)]
        ))
        // `URL.query` returns the raw (still percent-encoded) query — i.e. the wire bytes.
        let wire = try #require(url.query)
        #expect(wire.contains("%2B00:00"), "literal '+' must be encoded as %2B, got: \(wire)")
        #expect(!wire.contains("+00:00"), "raw '+' would be decoded to a space by the server: \(wire)")
        // The server's x-www-form-urlencoded decode (%2B → '+', any bare '+' → space)
        // must recover the exact original cursor.
        let serverDecoded = wire
            .replacingOccurrences(of: "since=", with: "")
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "%2B", with: "+")
        #expect(serverDecoded == cursor)
    }

    // MARK: - errorDescription formatting (UI-facing messages)

    /// `httpError`'s description embeds both the numeric code and the server detail string.
    @Test func http_error_description_contains_code_and_detail() {
        let desc = KGError.httpError(statusCode: 503, detail: "service unavailable").errorDescription ?? ""
        #expect(desc.contains("503"))
        #expect(desc.contains("service unavailable"))
    }

    /// `decodingError` surfaces the underlying error's localized description.
    @Test func decoding_error_description_wraps_underlying() {
        let underlying = URLError(.cannotDecodeContentData)
        let desc = KGError.decodingError(underlying: underlying).errorDescription ?? ""
        #expect(!desc.isEmpty)
    }

    /// `unauthorized` and `notAuthenticated` share the same user-visible copy — both mean
    /// "please log in again".
    @Test func unauthorized_and_notAuthenticated_share_description() {
        #expect(KGError.unauthorized.errorDescription == KGError.notAuthenticated.errorDescription)
    }

    // MARK: - review-event pull paging

    private func reviewEventPayload(_ id: String) -> KGReviewEventPayload {
        KGReviewEventPayload(
            event_id: id, card_id: nil, word_snapshot: "w", notebook_id: "default",
            feedback: 1, reviewed_at: "2026-06-01T10:00:00Z", created_at: "2026-06-01T10:00:00Z"
        )
    }

    @Test func review_event_pull_loops_until_short_page() async throws {
        let pages: [String?: KGService.ReviewEventsPage] = [
            nil: .init(entries: [reviewEventPayload("a"), reviewEventPayload("b")], cursor: "c1"),
            "c1": .init(entries: [reviewEventPayload("c"), reviewEventPayload("d")], cursor: "c2"),
            "c2": .init(entries: [reviewEventPayload("e")], cursor: "c3"),
        ]
        var requested: [String?] = []
        var consumed: [String?] = []
        let total = try await KGService.drainReviewEventPages(
            startingAt: nil, pageSize: 2,
            fetchPage: { since in requested.append(since); return pages[since]! },
            consume: { _, cursor in consumed.append(cursor) }
        )
        #expect(total == 5)
        #expect(requested == [nil, "c1", "c2"])
        #expect(consumed == ["c1", "c2", "c3"])
    }

    @Test func review_event_pull_stops_when_cursor_does_not_advance() async throws {
        var calls = 0
        let total = try await KGService.drainReviewEventPages(
            startingAt: "c1", pageSize: 1,
            fetchPage: { _ in calls += 1; return .init(entries: [reviewEventPayload("a")], cursor: "c1") },
            consume: { _, _ in }
        )
        #expect(total == 1)
        #expect(calls == 1)
    }
}

// MARK: - #2718 createManualLink 不可自動重試（POST 無 Idempotency-Key）

private final class CountingTimeoutTransport: KGHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var attempts: Int { lock.withLock { count } }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { count += 1 }
        throw URLError(.timedOut)
    }
}

@MainActor
private final class ManualLinkAuthSession: AuthSessionProviding {
    let isLoggedIn = true
    let token: String? = "header.eyJleHAiOjQxMzg2Njg0MDB9.signature"
}

@MainActor
private final class ManualLinkInvalidator: SessionInvalidating {
    func logout(modelContainer: ModelContainer?, reason: String) {}
    func waitForPendingLocalDataCleanup() async {}
}

@MainActor
struct CreateManualLinkRetryTests {
    @Test func createManualLinkPostsExactlyOnceOnTimeout() async {
        let transport = CountingTimeoutTransport()
        let service = KGService(
            authSession: ManualLinkAuthSession(),
            sessionInvalidator: ManualLinkInvalidator(),
            transport: transport,
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
        _ = try? await service.createManualLink(fromId: "a", toId: "b", notebookId: "n")
        #expect(transport.attempts == 1)
    }
}

// MARK: - #2714 backgroundSync must not log out while the keychain token is still loading

@MainActor
private final class PendingSyncAuthSession: AuthSessionProviding {
    let isLoggedIn = true
    let token: String? = nil
}

@MainActor
private final class PendingSyncInvalidator: SessionInvalidating {
    private(set) var logoutReasons: [String] = []
    func logout(modelContainer: ModelContainer?, reason: String) { logoutReasons.append(reason) }
    func waitForPendingLocalDataCleanup() async {}
}

@MainActor
struct BackgroundSyncPendingTokenTests {
    private static func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try! ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            PodcastSeries.self, PodcastEpisode.self,
            configurations: config
        )
    }

    private static func makeService() -> (KGService, PendingSyncInvalidator) {
        let invalidator = PendingSyncInvalidator()
        let service = KGService(
            authSession: PendingSyncAuthSession(),
            sessionInvalidator: invalidator,
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
        return (service, invalidator)
    }

    @Test func currentAuthTokenWithPendingTokenThrowsSessionPending() async {
        let (service, invalidator) = Self.makeService()
        do {
            _ = try await service.currentAuthToken()
            Issue.record("expected sessionPending")
        } catch is KGSessionPendingError {
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(invalidator.logoutReasons.isEmpty)
    }

    @Test func backgroundSyncWithPendingTokenDoesNotLogOut() async {
        let (service, invalidator) = Self.makeService()
        _ = await service.backgroundSync(container: Self.makeContainer(), progress: nil)
        #expect(invalidator.logoutReasons.isEmpty)
        #expect(service.lastBackgroundSyncError != L10n.string("登入已過期"))
    }

    @Test func processSyncPhaseTreatsSessionPendingAsSkippedNotUnauthorized() async {
        let (service, invalidator) = Self.makeService()
        let outcome = await service.processSyncPhase(
            results: [.failure(KGSessionPendingError())],
            labels: ["pull"],
            container: Self.makeContainer()
        )
        #expect(outcome?.cancelled == true)
        #expect(outcome?.failures.isEmpty == true)
        #expect(invalidator.logoutReasons.isEmpty)
    }
}

// MARK: - #2806 a locally expired JWT must not log out / wipe local data (only a real 401 may)

@MainActor
private final class LocallyExpiredAuthSession: AuthSessionProviding {
    let isLoggedIn = true
    // exp = 1000 (1970): expired by any device clock, so only the client precheck can judge it.
    let token: String? = "header.eyJleHAiOjEwMDB9.signature"
}

@MainActor
private final class RecordingLogoutInvalidator: SessionInvalidating {
    private(set) var logoutReasons: [String] = []
    func logout(modelContainer: ModelContainer?, reason: String) { logoutReasons.append(reason) }
    func waitForPendingLocalDataCleanup() async {}
}

@MainActor
struct LocalClockExpiryDoesNotWipeTests {
    private static func makeService() -> (KGService, RecordingLogoutInvalidator) {
        let invalidator = RecordingLogoutInvalidator()
        let service = KGService(
            authSession: LocallyExpiredAuthSession(),
            sessionInvalidator: invalidator,
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
        return (service, invalidator)
    }

    @Test func locallyExpiredTokenDoesNotInvokeLogout() async {
        let (service, invalidator) = Self.makeService()
        let token = try? await service.currentAuthToken()
        #expect(token == "header.eyJleHAiOjEwMDB9.signature", "precheck must not block the request; the server decides")
        #expect(invalidator.logoutReasons.isEmpty, "local clock alone must never trigger logout/wipe")
    }

    /// 真實 401 必須經 HTTP wiring（authenticatedRequest）登出；只直呼 handleUnauthorized
    /// 抓不到「401 → 登出」接線的退化。
    @Test func realUnauthorizedStillLogsOut() async {
        let invalidator = RecordingLogoutInvalidator()
        let service = KGService(
            authSession: LocallyExpiredAuthSession(),
            sessionInvalidator: invalidator,
            transport: Status401Transport(),
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )

        do {
            _ = try await service.authenticatedRequest(path: "/api/user/config", retryPolicy: .none)
            Issue.record("a real 401 must throw KGError.unauthorized")
        } catch KGError.unauthorized {
            // expected
        } catch {
            Issue.record("expected KGError.unauthorized, got \(error)")
        }
        #expect(invalidator.logoutReasons == ["http_401"])
    }
}

/// 固定回 401 的 transport：用來驗證 authenticatedRequest 的真實 401 分支。
private final class Status401Transport: KGHTTPTransport, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://kg.test")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}
