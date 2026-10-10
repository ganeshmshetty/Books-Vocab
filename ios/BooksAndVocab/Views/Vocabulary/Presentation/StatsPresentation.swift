//
//  StatsPresentation.swift
//  Books & Vocab
//
//  統計頁面的資料計算邏輯。
//

import Foundation
import SwiftUI

private struct StatsProjectionClockKey: EnvironmentKey {
    static let defaultValue = StatsProjectionClock(
        now: Date(timeIntervalSince1970: 0),
        calendar: Calendar(identifier: .gregorian)
    )
}

extension EnvironmentValues {
    var statsProjectionClock: StatsProjectionClock {
        get { self[StatsProjectionClockKey.self] }
        set { self[StatsProjectionClockKey.self] = newValue }
    }
}

enum StatsPresentation {
    struct ForecastBucket: Identifiable, Equatable {
        let id: String
        let label: String
        let count: Int
    }

    /// All values that influence the Overview projection travel through one
    /// explicit input bundle. Keeping the clock beside the records prevents a
    /// fixture from accidentally mixing seeded data with a wall-clock forecast.
    struct Inputs {
        let entries: [VocabularyEntry]
        let reviewRecords: [ReviewRecord]
        let forecastDays: Int
        let clock: StatsProjectionClock

        init(
            entries: [VocabularyEntry],
            reviewRecords: [ReviewRecord],
            forecastDays: Int = 14,
            clock: StatsProjectionClock
        ) {
            self.entries = entries
            self.reviewRecords = reviewRecords
            self.forecastDays = forecastDays
            self.clock = clock
        }
    }

    /// Value identity for the inputs consumed by `project(_:)`.
    ///
    /// SwiftData can re-evaluate a view when a model field changes without
    /// changing the number of query results. A count-only task identity would
    /// then leave metrics, activity, or forecast buckets projected from the
    /// previous values. Capturing the projection fields as values gives the
    /// presenter an order-independent, collision-free task key.
    struct ProjectionKey: Hashable {
        struct Entry: Hashable {
            let id: UUID
            let notebookId: String
            let syncStatus: Int
            let actionType: String
            let isArchived: Bool
            let nextReviewAt: Date
        }

        struct Review: Hashable {
            let id: UUID
            let notebookId: String
            let reviewedAt: Date
        }

        let entries: Set<Entry>
        let reviews: Set<Review>
        let forecastDays: Int
        let now: Date
        let dueNow: Date
        let timeZoneIdentifier: String
    }

    static func projectionKey(for inputs: Inputs) -> ProjectionKey {
        let entryKeys = Set(inputs.entries.map {
            ProjectionKey.Entry(
                id: $0.id,
                notebookId: $0.notebookId,
                syncStatus: $0.syncStatus,
                actionType: $0.actionType,
                isArchived: $0.isArchived,
                nextReviewAt: $0.nextReviewAt
            )
        })

        let reviewKeys = Set(inputs.reviewRecords.map {
            ProjectionKey.Review(
                id: $0.id,
                notebookId: $0.notebookId,
                reviewedAt: $0.reviewedAt
            )
        })

        return ProjectionKey(
            entries: entryKeys,
            reviews: reviewKeys,
            forecastDays: inputs.forecastDays,
            now: inputs.clock.now,
            dueNow: inputs.clock.dueNow,
            timeZoneIdentifier: inputs.clock.calendar.timeZone.identifier
        )
    }

    struct Summary {
        let totalCards: Int
        let reviewedToday: Int
        let dueToday: Int
        let currentStreak: Int
        let longestStreak: Int
        let activity: [String: Int]
        let forecast: [ForecastBucket]
        let heatmapThresholds: [Int]

        func formattedCount(_ value: Int) -> String {
            LocaleAwareFormatter.shared.string(from: NSNumber(value: value))
        }
    }

    enum GraphThumbnailBodyKind: Equatable {
        case loading
        case empty
        case graph
    }

    static func graphThumbnailBodyKind(linksLoaded: Bool, nodeCount: Int) -> GraphThumbnailBodyKind {
        guard linksLoaded else { return .loading }
        return nodeCount == 0 ? .empty : .graph
    }

    /// Status row shown inside the graph card's content area (#2860).
    enum GraphCardNotice: Equatable {
        /// The latest load failed; the cached graph stays visible with its reason.
        case stale(reason: String)
        /// The thumbnail has not reported its first paint within the watchdog
        /// window. Neutral copy: a slow-converging graph is not stale data.
        case rendering

        var reason: String? {
            if case .stale(let reason) = self { return reason }
            return nil
        }
    }

    enum GraphCardState: Equatable {
        case loading
        /// No cached links and the load failed: error panel with reason + retry.
        case failed(reason: String)
        /// Links present. `notice` is the visible stale/status row, if any.
        case content(body: GraphThumbnailBodyKind, notice: GraphCardNotice?)
    }

    /// Pure state matrix for the Overview graph card. `failureReason` is the
    /// `SyncFailurePresentation.reason(for:)` text of the latest failed load
    /// (nil once a load succeeds). `paintTimedOut` means the web thumbnail did
    /// not report its first paint within the bounded window.
    static func graphCardState(
        linksLoaded: Bool,
        nodeCount: Int,
        failureReason: String?,
        paintTimedOut: Bool
    ) -> GraphCardState {
        guard linksLoaded else {
            if let failureReason { return .failed(reason: failureReason) }
            return .loading
        }
        let body = graphThumbnailBodyKind(linksLoaded: true, nodeCount: nodeCount)
        if let failureReason {
            return .content(body: body, notice: .stale(reason: failureReason))
        }
        if body == .graph && paintTimedOut {
            return .content(body: body, notice: .rendering)
        }
        return .content(body: body, notice: nil)
    }

    private static func compactDayLabel(for date: Date) -> String {
        LocaleAwareFormatter.shared.string(from: date, template: "Md")
    }

    static func buildSummary(
        from entries: [VocabularyEntry],
        reviewRecords: [ReviewRecord],
        forecastDays: Int = 14,
        now: Date = Date()
    ) -> Summary {
        project(Inputs(
            entries: entries,
            reviewRecords: reviewRecords,
            forecastDays: forecastDays,
            clock: StatsProjectionClock(now: now, calendar: Calendar.autoupdatingCurrent)
        ))
    }

    static func buildSummary(
        from entries: [VocabularyEntry],
        reviewRecords: [ReviewRecord],
        forecastDays: Int = 14,
        clock: StatsProjectionClock
    ) -> Summary {
        project(Inputs(
            entries: entries,
            reviewRecords: reviewRecords,
            forecastDays: forecastDays,
            clock: clock
        ))
    }

    static func project(
        entries: [VocabularyEntry],
        reviewRecords: [ReviewRecord],
        forecastDays: Int = 14,
        clock: StatsProjectionClock
    ) -> Summary {
        project(Inputs(
            entries: entries,
            reviewRecords: reviewRecords,
            forecastDays: forecastDays,
            clock: clock
        ))
    }

    static func project(_ inputs: Inputs) -> Summary {
        // shouldAppearInKnowledgeList == isSynced && !delete && !isArchived.
        // Archived entries must NOT inflate the review forecast / stats.
        let synced = inputs.entries.filter(\.shouldAppearInKnowledgeList)

        // Forecast
        var forecastMap: [String: Int] = [:]
        // Due/forecast follow the (possibly paused) review reference; activity,
        // streaks and reviewedToday below follow the wall clock.
        let dueNow = inputs.clock.dueNow
        let todayKey = inputs.clock.dayKey(dueNow)
        // Only cards in the review queue (reviewed at least once, not excluded)
        // are due; new cards' placeholder nextReviewAt must not count.
        for entry in synced where entry.shouldAppearInReview && entry.reviewCount > 0 {
            let key = inputs.clock.dayKey(entry.nextReviewAt)
            if key <= todayKey {
                forecastMap[todayKey, default: 0] += 1
            } else {
                forecastMap[key, default: 0] += 1
            }
        }

        var forecast: [ForecastBucket] = []
        for offset in 0..<inputs.forecastDays {
            guard let date = inputs.clock.date(
                byAdding: .day,
                value: offset,
                to: dueNow
            ) else { continue }
            let key = inputs.clock.dayKey(date)
            let label: String
            switch offset {
            case 0: label = "今天".localized
            case 1: label = "明天".localized
            default:
                label = Self.compactDayLabel(for: date)
            }
            forecast.append(ForecastBucket(id: key, label: label, count: forecastMap[key] ?? 0))
        }

        let dayKeys = inputs.reviewRecords.map { inputs.clock.dayKey($0.reviewedAt) }
        let activity = ReviewActivityLog.activity(
            for: 180,
            dayKeys: dayKeys,
            clock: inputs.clock
        )

        // Compute adaptive heatmap thresholds from activity data
        let nonZeroCounts = activity.values.filter { $0 > 0 }.sorted()
        let heatmapThresholds: [Int]
        if nonZeroCounts.count < 4 {
            heatmapThresholds = [1, 2, 3]  // simple fallback
        } else {
            let p25 = nonZeroCounts[nonZeroCounts.count / 4]
            let p50 = nonZeroCounts[nonZeroCounts.count / 2]
            let p75 = nonZeroCounts[nonZeroCounts.count * 3 / 4]
            heatmapThresholds = [p25, p50, p75]
        }

        let streakResult = ReviewActivityLog.streaks(
            dayKeys: dayKeys,
            clock: inputs.clock
        )

        return Summary(
            totalCards: synced.count,
            reviewedToday: ReviewActivityLog.reviewedToday(
                dayKeys: dayKeys,
                clock: inputs.clock
            ),
            dueToday: forecastMap[todayKey] ?? 0,
            currentStreak: streakResult.current,
            longestStreak: streakResult.longest,
            activity: activity,
            forecast: forecast,
            heatmapThresholds: heatmapThresholds
        )
    }
}
