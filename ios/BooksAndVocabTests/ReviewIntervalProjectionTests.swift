import Foundation
import Testing
@testable import BooksAndVocab

/// #3135 — the grade-button hint must equal the interval the flush writes, for every
/// card stage, notebook policy, feedback, and a same-session re-grade.
@MainActor
struct ReviewIntervalProjectionTests {
    private static func entry(reviewCount: Int, intervalHours: Double) -> VocabularyEntry {
        let entry = VocabularyEntry(
            word: "coax",
            translation: "哄勸",
            context: "She coaxed the cat down.",
            bookTitle: "Sample"
        )
        entry.reviewCount = reviewCount
        entry.reviewIntervalHours = intervalHours
        return entry
    }

    private static func settings(_ mode: ReviewSettingsMode) -> ReviewSettings {
        var settings = ReviewSettings.default
        settings.mode = mode
        return settings
    }

    private static func answer(_ feedback: ReviewFeedback) -> TodayReviewState.SubmittedAnswer {
        .init(feedback: feedback, answeredAt: Date(timeIntervalSince1970: 1_700_000_000), reviewRecordID: UUID())
    }

    @Test func projectionEqualsTheIntervalTheFlushWritesForEveryStage() {
        let stages: [(reviewCount: Int, intervalHours: Double)] = [
            (0, 0),       // new card
            (2, 24),      // learning
            (5, 800),     // long interval
        ]
        for mode in ReviewSettingsMode.allCases {
            let settings = Self.settings(mode)
            for stage in stages {
                for feedback in [ReviewFeedback.remembered, .forgot] {
                    let entry = Self.entry(reviewCount: stage.reviewCount, intervalHours: stage.intervalHours)
                    let baseline = ReviewSessionPersistence.makeBaseline(from: entry)
                    let projected = ReviewIntervalProjection.nextIntervalHours(
                        baseline: baseline,
                        feedback: feedback,
                        settings: settings
                    )
                    ReviewSessionPersistence.applySubmittedAnswer(
                        Self.answer(feedback),
                        baseline: baseline,
                        to: entry,
                        reviewSettings: settings
                    )
                    #expect(
                        projected == entry.reviewIntervalHours,
                        "mode \(mode) stage \(stage) feedback \(feedback): hint must equal the written interval"
                    )
                }
            }
        }
    }

    @Test func regradeInTheSameSessionStartsFromTheSessionBaseline() {
        let settings = Self.settings(.relaxed)
        let entry = Self.entry(reviewCount: 2, intervalHours: 24)
        let baseline = ReviewSessionPersistence.makeBaseline(from: entry)

        ReviewSessionPersistence.applySubmittedAnswer(
            Self.answer(.remembered), baseline: baseline, to: entry, reviewSettings: settings
        )
        // The user changes their mind: the second grade must be derived from the same baseline,
        // so the hint (projected from that baseline) still matches what the flush writes.
        let projected = ReviewIntervalProjection.nextIntervalHours(
            baseline: baseline, feedback: .forgot, settings: settings
        )
        ReviewSessionPersistence.applySubmittedAnswer(
            Self.answer(.forgot), baseline: baseline, to: entry, reviewSettings: settings
        )
        #expect(projected == entry.reviewIntervalHours)
    }
}
