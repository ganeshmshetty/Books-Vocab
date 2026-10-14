//
//  KGService+ReviewEvents.swift
//  Books & Vocab
//

import Foundation
import SwiftData

struct KGReviewEventPayload: Codable, Sendable, Equatable {
    let event_id: String
    let card_id: String?
    let word_snapshot: String
    let notebook_id: String
    let feedback: Int
    let reviewed_at: String
    let created_at: String
    // SRS 前後快照(對應後端 ReviewEventEntry 加寬欄位)。全 optional:legacy 紀錄不帶、
    // pull 回舊事件缺鍵時 Codable 自動 nil。is_synthetic 不送 —— iOS 上報一律真實事件,
    // 後端預設 False。
    let interval_before: Double?
    let interval_after: Double?
    let next_review_before: String?  // ISO8601
    let next_review_after: String?   // ISO8601
    let review_count_after: Int?
    let streak_after: Int?
    let lapse_after: Int?

    init(
        event_id: String,
        card_id: String?,
        word_snapshot: String,
        notebook_id: String,
        feedback: Int,
        reviewed_at: String,
        created_at: String,
        interval_before: Double? = nil,
        interval_after: Double? = nil,
        next_review_before: String? = nil,
        next_review_after: String? = nil,
        review_count_after: Int? = nil,
        streak_after: Int? = nil,
        lapse_after: Int? = nil
    ) {
        self.event_id = event_id
        self.card_id = card_id
        self.word_snapshot = word_snapshot
        self.notebook_id = notebook_id
        self.feedback = feedback
        self.reviewed_at = reviewed_at
        self.created_at = created_at
        self.interval_before = interval_before
        self.interval_after = interval_after
        self.next_review_before = next_review_before
        self.next_review_after = next_review_after
        self.review_count_after = review_count_after
        self.streak_after = streak_after
        self.lapse_after = lapse_after
    }
}

// MARK: - Review Event Sync

extension KGService {
    private static let reviewEventPushBatchSize = 1000

    /// Pushes until no request is pending. A caller that finds a push in flight
    /// returns `(0, 0)` at once and leaves its saved events to the owner, which
    /// runs one more round for them (#3907). Each round rebuilds its payload, so
    /// a record saved after a round's snapshot is never stranded until the next sync.
    func pushReviewEvents(container: ModelContainer) async throws -> (inserted: Int, skipped: Int) {
        guard claimReviewEventPush() else {
            AppLog.kg.info("pushReviewEvents deferred: another push in flight will run another round")
            return (0, 0)
        }

        // Captured once per claim, before any round: every batch of every round belongs to this session only (#3806).
        let sessionEpoch = await authSession.sessionEpoch
        var totalInserted = 0
        var totalSkipped = 0
        do {
            repeat {
                let round = try await pushReviewEventsRound(container: container, sessionEpoch: sessionEpoch)
                totalInserted += round.inserted
                totalSkipped += round.skipped
            } while finishReviewEventPushRound()
        } catch {
            releaseReviewEventPush()
            throw error
        }
        return (totalInserted, totalSkipped)
    }

    private func pushReviewEventsRound(
        container: ModelContainer,
        sessionEpoch: Int
    ) async throws -> (inserted: Int, skipped: Int) {
        let actor = BackgroundSyncActor(modelContainer: container)
        let payload = try await actor.buildReviewEventsPushPayload()
        guard !payload.isEmpty else { return (0, 0) }

        struct PushResponse: Decodable {
            let inserted: Int
            let skipped: Int
        }

        var totalInserted = 0
        var totalSkipped = 0
        for batchStart in stride(from: 0, to: payload.count, by: Self.reviewEventPushBatchSize) {
            let batchEnd = min(batchStart + Self.reviewEventPushBatchSize, payload.count)
            let batch = Array(payload[batchStart..<batchEnd])
            // Re-checked per batch: a session change between batches must stop the drain here, so no
            // later batch is sent under the new account's token (#3806).
            try await ensureSessionUnchanged(since: sessionEpoch)
            let result = try await authenticatedDecode(
                PushResponse.self,
                path: "api/vocab/review-events",
                method: "PATCH",
                body: try JSONEncoder().encode(["entries": batch])
            )
            // Every entry must land in exactly one of the server's two buckets.
            // `PushResponse` ignores unknown keys, so if the server ever grows a
            // third outcome (a rejected list, a validation-tolerant mode), this
            // loop would mark the rejected rows as pushed and lose them with no
            // trace. Refuse to acknowledge a batch we cannot account for.
            guard result.inserted + result.skipped == batch.count else {
                throw KGError.serverError(
                    "review-events push returned \(result.inserted) inserted + \(result.skipped) skipped for \(batch.count) entries; not acknowledging an unaccounted batch"
                )
            }
            // Acknowledge per batch, not once at the end. The batches are the
            // unit the server actually accepted, so a later batch throwing
            // (offline, 401, or the 429 this very burst used to provoke) must
            // still leave the landed ones marked — that is what lets a large
            // legacy history drain across syncs instead of restarting each time.
            try await ensureSessionUnchanged(since: sessionEpoch)
            try await actor.markReviewEventsPushed(eventIDs: batch.map(\.event_id))
            totalInserted += result.inserted
            totalSkipped += result.skipped
        }
        AppLog.kg.info("pushReviewEvents: inserted=\(totalInserted), skipped=\(totalSkipped), batches=\((payload.count + Self.reviewEventPushBatchSize - 1) / Self.reviewEventPushBatchSize)")
        return (totalInserted, totalSkipped)
    }

    /// Mirrors backend `REVIEW_EVENTS_PAGE_SIZE`: a page with fewer entries is the last.
    static let reviewEventPullPageSize = 1000

    struct ReviewEventsPage: Decodable {
        let entries: [KGReviewEventPayload]
        let cursor: String?
    }

    /// Pulls pages until a short/empty page, calling `consume` per page (merge + watermark
    /// advance) so a failure mid-way keeps the pages already applied. Returns events consumed.
    /// Stops if the server returns no cursor or one that did not advance (no infinite loop).
    @discardableResult
    static func drainReviewEventPages(
        startingAt initial: String?,
        pageSize: Int = reviewEventPullPageSize,
        fetchPage: (String?) async throws -> ReviewEventsPage,
        consume: ([KGReviewEventPayload], String?) async throws -> Void
    ) async throws -> Int {
        var since = initial
        var total = 0
        while true {
            let page = try await fetchPage(since)
            guard !page.entries.isEmpty else { return total }
            try await consume(page.entries, page.cursor)
            total += page.entries.count
            guard page.entries.count >= pageSize, let next = page.cursor, next != since else { return total }
            since = next
        }
    }

    func pullReviewEvents(container: ModelContainer) async throws {
        let defaults = UserDefaults.standard
        let actor = BackgroundSyncActor(modelContainer: container)
        let total = try await Self.drainReviewEventPages(
            startingAt: defaults.string(forKey: SyncKeys.reviewEventPullBoundary),
            fetchPage: { since in
                try await self.authenticatedDecode(
                    ReviewEventsPage.self,
                    path: "api/vocab/review-events",
                    queryItems: since.map { [URLQueryItem(name: "since", value: $0)] }
                )
            },
            consume: { entries, cursor in
                try await actor.mergeReviewEvents(entries)
                // Advance the watermark by the server-assigned ingestion cursor, not by
                // max(reviewed_at): the cursor is monotonic in ingestion order, so a later
                // pull cannot skip an event whose reviewed_at lies before this boundary.
                if let cursor {
                    defaults.set(cursor, forKey: SyncKeys.reviewEventPullBoundary)
                } else {
                    // Contract violation: a non-empty batch must carry a cursor. Surface it
                    // instead of silently re-merging the same batch every sync.
                    AppLog.kg.error("pullReviewEvents: non-empty batch returned nil cursor; watermark not advanced")
                }
            }
        )
        if total > 0 { AppLog.kg.info("pullReviewEvents: merged \(total) remote events") }
    }
}

// MARK: - Watermark self-heal migration

extension KGService {
    /// review-event pull watermark 是否為「乾淨、可安全回送」的格式。
    ///
    /// 乾淨 cursor 一律來自後端 `_format_timestamp`（tz-aware ISO8601，帶 offset、
    /// 可選小數秒），故以嚴格 `ISO8601DateFormatter` 能否解析為準。舊版 app 曾把
    /// 非嚴格字串（naive / 空格分隔 / 純日期）寫入此 key，後端 review-event pull
    /// 對其回 400 → watermark 永不前進 → 每輪背景同步 partial fail → 每次回前台彈
    /// toast（死鎖）。
    static func isCleanReviewEventBoundary(_ raw: String) -> Bool {
        AppDateFormatters.parseISO8601(raw) != nil
    }

    /// 一次性自癒 migration：清除無法回送的舊 watermark，下次 pull 走全量
    /// （冪等、無損：review events 以 `event_id` 去重 merge）。打破「壞 watermark →
    /// 後端 400 → 永不前進」死鎖。在 app 啟動早期（任何背景同步之前）呼叫。
    static func migrateReviewEventBoundaryIfNeeded(defaults: UserDefaults = .standard) {
        guard let raw = defaults.string(forKey: SyncKeys.reviewEventPullBoundary) else { return }
        guard !isCleanReviewEventBoundary(raw) else { return }
        defaults.removeObject(forKey: SyncKeys.reviewEventPullBoundary)
        AppLog.kg.info("Cleared stale review-event boundary (not tz-aware ISO8601): \(raw)")
    }
}
