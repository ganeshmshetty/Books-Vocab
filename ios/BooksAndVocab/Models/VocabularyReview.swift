//
//  VocabularyReview.swift
//  Books & Vocab
//
//  本地簡化版間隔複習規則與顯示輔助。
//

import Foundation
import SwiftData

enum ReviewFeedback: Int, Codable {
    case forgot = 0
    case remembered = 1
}

enum VocabularyCardMode: String, Codable, CaseIterable {
    case recognition
    case production

    var title: String {
        switch self {
        case .recognition:
            return "Recognition"
        case .production:
            return "Production"
        }
    }

    var localizedTitle: String {
        switch self {
        case .recognition:
            return L10n.string("辨識")
        case .production:
            return L10n.string("產出")
        }
    }
}

enum VocabularyReviewState: String, CaseIterable, Identifiable {
    case unlearned
    case due
    case reviewed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlearned: return L10n.string("未學習")
        case .due: return L10n.string("待複習")
        case .reviewed: return L10n.string("已複習")
        }
    }
}

struct VocabularyReviewSnapshot {
    let intervalHours: Double
    let nextReviewAt: Date
    let lastReviewedAt: Date?
    let reviewCount: Int
    let lapseCount: Int
    let streak: Int
    let lastFeedback: ReviewFeedback?

    var isDue: Bool {
        nextReviewAt <= Date()
    }
}

enum VocabularyReviewPolicy {
    static let initialIntervalHours: Double = 12

    static func nextIntervalHours(
        currentIntervalHours: Double,
        feedback: ReviewFeedback,
        settings: ReviewSettings
    ) -> Double {
        let minInterval = settings.effectiveMinimumIntervalHours
        let maxInterval = settings.effectiveMaximumIntervalHours
        let base = max(currentIntervalHours, minInterval)
        let multiplier = feedback == .remembered ? settings.effectiveRememberedMultiplier : settings.effectiveForgotMultiplier
        return min(maxInterval, max(minInterval, base * multiplier))
    }
}

extension VocabularyEntry {
    var reviewSnapshot: VocabularyReviewSnapshot {
        VocabularyReviewSnapshot(
            intervalHours: reviewIntervalHours,
            nextReviewAt: nextReviewAt,
            lastReviewedAt: lastReviewedAt,
            reviewCount: reviewCount,
            lapseCount: lapseCount,
            streak: reviewStreak,
            lastFeedback: ReviewFeedback(rawValue: lastReviewFeedbackRaw)
        )
    }

    var isReviewDue: Bool {
        reviewSnapshot.isDue
    }

    var reviewState: VocabularyReviewState {
        if reviewCount == 0 {
            return .unlearned
        }
        return isReviewDue ? .due : .reviewed
    }

    func reviewState(at now: Date) -> VocabularyReviewState {
        if reviewCount == 0 { return .unlearned }
        return nextReviewAt <= now ? .due : .reviewed
    }

}

extension Date {
    func reviewRelativeDescription(now: Date = Date()) -> String {
        LocaleAwareFormatter.shared.relativeString(for: self, relativeTo: now, style: .full)
    }
}
