import Foundation
import Testing
@testable import BooksAndVocab

/// Pins the error-classification & retry-policy contract that every authenticated KG call
/// (vocab CRUD, sync, graph fetch, podcast metadata) relies on. These are pure-function
/// predicates with no Network/URLSession dependency — perfect for fast unit pinning.
struct KGServiceErrorTests {

    // MARK: - KGError.isNetworkRelated

    @Test func offline_is_network_related() {
        #expect(KGError.offline.isNetworkRelated)
    }

    @Test func networkError_is_network_related() {
        let urlErr = URLError(.timedOut)
        #expect(KGError.networkError(underlying: urlErr).isNetworkRelated)
    }

    @Test func unauthorized_is_not_network_related() {
        // Auth failures should not be classified as network — UI surfaces a login prompt,
        // not an "offline" banner.
        #expect(!KGError.unauthorized.isNetworkRelated)
        #expect(!KGError.notAuthenticated.isNetworkRelated)
    }

    @Test func httpError_is_not_network_related() {
        #expect(!KGError.httpError(statusCode: 500, detail: "boom").isNetworkRelated)
        #expect(!KGError.httpError(statusCode: 404, detail: "missing").isNetworkRelated)
    }

    @Test func serverError_is_not_network_related() {
        #expect(!KGError.serverError("invalid response").isNetworkRelated)
    }

    @Test func decodingError_is_not_network_related() {
        struct DummyDecodingErr: Error {}
        #expect(!KGError.decodingError(underlying: DummyDecodingErr()).isNetworkRelated)
    }

    // MARK: - KGError.isRetryable

    @Test func offline_is_retryable() {
        #expect(KGError.offline.isRetryable)
    }

    @Test func networkError_is_retryable() {
        #expect(KGError.networkError(underlying: URLError(.networkConnectionLost)).isRetryable)
    }

    @Test func http_5xx_is_retryable() {
        #expect(KGError.httpError(statusCode: 500, detail: "").isRetryable)
        #expect(KGError.httpError(statusCode: 502, detail: "").isRetryable)
        #expect(KGError.httpError(statusCode: 503, detail: "").isRetryable)
        #expect(KGError.httpError(statusCode: 504, detail: "").isRetryable)
        #expect(KGError.httpError(statusCode: 599, detail: "").isRetryable)
    }

    @Test func http_429_is_retryable() {
        // Rate-limit must be retryable so the policy honours Retry-After backoff.
        #expect(KGError.httpError(statusCode: 429, detail: "").isRetryable)
    }

    @Test func http_4xx_other_than_429_not_retryable() {
        // 400/401/403/404 are client-side terminal — retrying just wastes quota.
        #expect(!KGError.httpError(statusCode: 400, detail: "").isRetryable)
        #expect(!KGError.httpError(statusCode: 401, detail: "").isRetryable)
        #expect(!KGError.httpError(statusCode: 403, detail: "").isRetryable)
        #expect(!KGError.httpError(statusCode: 404, detail: "").isRetryable)
    }

    @Test func http_2xx_not_retryable() {
        // Defensive: success codes wrapped in httpError (shouldn't happen, but guard anyway).
        #expect(!KGError.httpError(statusCode: 200, detail: "").isRetryable)
        #expect(!KGError.httpError(statusCode: 201, detail: "").isRetryable)
    }

    @Test func unauthorized_not_retryable() {
        #expect(!KGError.unauthorized.isRetryable)
        #expect(!KGError.notAuthenticated.isRetryable)
    }

    @Test func serverError_not_retryable() {
        #expect(!KGError.serverError("invalid url").isRetryable)
    }

    @Test func decodingError_not_retryable() {
        struct E: Error {}
        // Decode failures indicate a schema mismatch — retrying won't fix it.
        #expect(!KGError.decodingError(underlying: E()).isRetryable)
    }

    // MARK: - KGError.errorDescription is non-empty for every case

    @Test func error_description_present_for_all_cases() {
        let cases: [KGError] = [
            .notAuthenticated,
            .unauthorized,
            .offline,
            .httpError(statusCode: 500, detail: "x"),
            .decodingError(underlying: URLError(.cannotDecodeRawData)),
            .networkError(underlying: URLError(.timedOut)),
            .serverError("bad")
        ]
        for err in cases {
            #expect(err.errorDescription != nil && !(err.errorDescription ?? "").isEmpty,
                    "KGError.\(err) must surface a user-visible description")
        }
    }

    // MARK: - RetryPolicy presets

    @Test func retry_policy_none_disables_retries() {
        let p = RetryPolicy.none
        #expect(p.maxAttempts == 1)
        #expect(p.baseDelay == 0)
        #expect(p.retryableStatusCodes.isEmpty)
    }

    @Test func retry_policy_default_three_attempts_one_second_base() {
        let p = RetryPolicy.default
        #expect(p.maxAttempts == 3)
        #expect(p.baseDelay == 1.0)
        #expect(p.retryableStatusCodes == [429, 500, 502, 503, 504])
    }

    @Test func retry_policy_aggressive_five_attempts_half_second_base() {
        let p = RetryPolicy.aggressive
        #expect(p.maxAttempts == 5)
        #expect(p.baseDelay == 0.5)
        #expect(p.retryableStatusCodes == [429, 500, 502, 503, 504])
    }

    @Test func retry_policy_default_retries_504() {
        // Gateway timeouts are common transient sync failures and should retry.
        #expect(RetryPolicy.default.retryableStatusCodes.contains(504))
        #expect(RetryPolicy.aggressive.retryableStatusCodes.contains(504))
    }

    @Test func retry_policy_default_does_not_retry_401() {
        // 401 must never auto-retry — it goes through dedicated token-refresh path.
        #expect(!RetryPolicy.default.retryableStatusCodes.contains(401))
        #expect(!RetryPolicy.aggressive.retryableStatusCodes.contains(401))
    }

    // MARK: - SyncKeys payload version contract

    @Test func sync_payload_version_is_positive_int() {
        // If product bumps the schema, this test will break and force a deliberate review.
        #expect(KGService.SyncKeys.currentPayloadVersion == 1)
        #expect(KGService.SyncKeys.incrementalBoundary == "kg_last_incremental_sync")
        #expect(KGService.SyncKeys.payloadVersion == "kg_review_payload_version")
    }

    @Test func sync_failure_classifier_formats_network_timeout_for_review_events_pull() {
        let message = SyncFailurePresentation.message(
            label: "pullReviewEvents",
            error: KGError.networkError(underlying: URLError(.timedOut)),
            language: .traditionalChinese
        )

        #expect(message == "複習紀錄下載失敗：網路逾時")
    }

    @Test func sync_failure_classifier_formats_auth_expiry() {
        let message = SyncFailurePresentation.message(
            label: "pull",
            error: KGError.unauthorized,
            language: .traditionalChinese
        )

        #expect(message == "單字下載失敗：登入已過期")
    }

    @Test func sync_failure_classifier_formats_server_unavailable() {
        let message = SyncFailurePresentation.message(
            label: "pushReview",
            error: KGError.httpError(statusCode: 504, detail: "gateway"),
            language: .traditionalChinese
        )

        #expect(message == "複習進度上傳失敗：伺服器暫時不可用")
    }

    @Test func sync_failure_classifier_formats_decoding_mismatch() {
        struct E: Error {}
        let message = SyncFailurePresentation.message(
            label: "pullReviewEvents",
            error: KGError.decodingError(underlying: E()),
            language: .traditionalChinese
        )

        #expect(message == "複習紀錄下載失敗：資料格式不相容")
    }

    @Test func sync_failure_classifier_formats_unknown_label_and_error() {
        struct E: Error {}
        let message = SyncFailurePresentation.message(
            label: "newPhase",
            error: E(),
            language: .traditionalChinese
        )

        #expect(message == "同步失敗：未知錯誤")
    }

    // 可觀測性：4xx（非 429）拒絕須在 toast 帶上 HTTP status code，讓使用者/debug
    // 一眼看出「哪支請求被伺服器以什麼狀態碼拒絕」（review-event pull 死鎖案教訓：
    // 當初 toast 只說「伺服器拒絕請求」，無 code 得繞遠路才定位到 400）。
    @Test func sync_failure_4xx_includes_status_code() {
        let m400 = SyncFailurePresentation.message(
            label: "pullReviewEvents",
            error: KGError.httpError(statusCode: 400, detail: "Invalid since timestamp"),
            language: .traditionalChinese
        )
        #expect(m400.contains("400"))
        #expect(m400.contains("複習紀錄下載失敗"))

        let m403 = SyncFailurePresentation.message(
            label: "pull",
            error: KGError.httpError(statusCode: 403, detail: "forbidden"),
            language: .traditionalChinese
        )
        #expect(m403.contains("403"))
    }

    // 範圍精準：429（限流）與 5xx（伺服器異常）語意已清楚，維持原文案、不帶 code。
    @Test func sync_failure_429_and_5xx_keep_dedicated_reason_without_code() {
        let m429 = SyncFailurePresentation.message(
            label: "pull",
            error: KGError.httpError(statusCode: 429, detail: ""),
            language: .traditionalChinese
        )
        #expect(!m429.contains("429"))

        let m500 = SyncFailurePresentation.message(
            label: "pull",
            error: KGError.httpError(statusCode: 500, detail: ""),
            language: .traditionalChinese
        )
        #expect(!m500.contains("500"))
    }

    // 部分失敗彙總：同一原因只說一次；多組之間用該語系的列表分隔，不寫死 ASCII ", "。
    @Test func sync_failure_summary_states_a_shared_reason_once() {
        let language = AppLanguage.traditionalChinese
        let reason = SyncFailurePresentation.reason(for: KGError.offline, language: language)
        let summary = SyncFailurePresentation.partialFailureSummary(
            [("pull", reason), ("pullReviewEvents", reason)],
            language: language
        )

        #expect(summary.components(separatedBy: reason).count - 1 == 1, "同一原因重複列出：\(summary)")
    }

    // 每個語系的組間分隔都必須等於該語系的 ListFormatter 輸出（不寫死 ", "）。
    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func sync_failure_summary_joins_groups_with_locale_list_separator(language: AppLanguage) {
        let timeout = SyncFailurePresentation.reason(
            for: KGError.networkError(underlying: URLError(.timedOut)),
            language: language
        )
        let offline = SyncFailurePresentation.reason(for: KGError.offline, language: language)
        let summary = SyncFailurePresentation.partialFailureSummary(
            [("pull", offline), ("pullReviewEvents", timeout)],
            language: language
        )

        let listFormatter = ListFormatter()
        listFormatter.locale = language.locale
        let groups = [
            SyncFailurePresentation.message(label: "pull", error: KGError.offline, language: language),
            SyncFailurePresentation.message(
                label: "pullReviewEvents",
                error: KGError.networkError(underlying: URLError(.timedOut)),
                language: language
            ),
        ]
        let expectedList = listFormatter.string(from: groups) ?? ""
        #expect(summary == L10n.format("背景同步部分失敗：%@", language: language, expectedList),
                "分隔未依語系列表格式：\(summary)")
    }

    // 四腿（兩種原因 × 兩個操作）：每個原因只說一次、每個操作名只出現一次、組間以列表分隔。
    @Test func sync_failure_summary_four_legs_two_reasons_each_stated_once() {
        let language = AppLanguage.traditionalChinese
        let upload = SyncFailurePresentation.reason(
            for: KGError.httpError(statusCode: 503, detail: ""),
            language: language
        )
        let timeout = SyncFailurePresentation.reason(
            for: KGError.networkError(underlying: URLError(.timedOut)),
            language: language
        )
        let summary = SyncFailurePresentation.partialFailureSummary(
            [
                ("pushReview", upload),
                ("pushReviewEvents", upload),
                ("pull", timeout),
                ("pullReviewEvents", timeout),
            ],
            language: language
        )

        #expect(summary.components(separatedBy: upload).count - 1 == 1, "上傳原因重複：\(summary)")
        #expect(summary.components(separatedBy: timeout).count - 1 == 1, "逾時原因重複：\(summary)")
        for key in [
            "sync.failure.operation.pushReview",
            "sync.failure.operation.pushReviewEvents",
            "sync.failure.operation.pull",
            "sync.failure.operation.pullReviewEvents",
        ] {
            let title = L10n.string(key, language: language)
            #expect(summary.components(separatedBy: title).count - 1 == 1, "操作名 \(title) 未恰好出現一次：\(summary)")
        }
        #expect(summary.hasPrefix(L10n.format("背景同步部分失敗：%@", language: language, "")), "前綴遺失：\(summary)")
    }

    // 單一失敗：輸出必須與改動前的組合完全相同（不變的既有文案）。
    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func sync_failure_summary_single_leg_matches_pre_change_composition(language: AppLanguage) {
        let error = KGError.offline
        let summary = SyncFailurePresentation.partialFailureSummary(
            [("pull", SyncFailurePresentation.reason(for: error, language: language))],
            language: language
        )
        let expected = L10n.format(
            "背景同步部分失敗：%@",
            language: language,
            SyncFailurePresentation.message(label: "pull", error: error, language: language)
        )
        #expect(summary == expected)
    }
}
