//
//  ReviewGradeProgressTests.swift
//  Books & Vocab Tests
//
//  Issue #3371：複習 header 進度改為「已評 / 總數」，只由評分計數決定；瀏覽（‹ ›、autoplay）
//  不改變已評數。已評的卡 revisit 時帶「已評：記得／忘記」標示。
//

import Foundation
import Testing
@testable import BooksAndVocab

@MainActor
struct ReviewGradeProgressTests {

    /// header 進度的輸入：total 取 session queue，已評數取評分 state（不取瀏覽位置）。
    private func progress(
        _ scoring: ReviewScoringState,
        _ session: TodayReviewSessionState<String>
    ) -> ReviewGradeProgress {
        ReviewGradeProgress(graded: scoring.gradedCount, total: session.queue.count)
    }

    // MARK: - Graded / total under grading

    @Test func gradingAdvancesGradedCountUpToTotal() {
        let scoring = ReviewScoringState()
        var session = TodayReviewSessionState(queue: ["a", "b", "c"])
        #expect(progress(scoring, session).text == "0 / 3")

        scoring.record(.remembered, at: session.currentIndex)
        session.advanceAfterSubmission()
        #expect(progress(scoring, session).text == "1 / 3")

        scoring.record(.forgot, at: session.currentIndex)
        session.advanceAfterSubmission()
        #expect(progress(scoring, session).text == "2 / 3")

        scoring.record(.remembered, at: session.currentIndex)
        let completed = session.advanceAfterSubmission()
        #expect(completed)
        #expect(progress(scoring, session).text == "3 / 3")
    }

    // MARK: - Browsing never changes the graded count

    @Test func browsingNeverChangesTheGradedCount() {
        let scoring = ReviewScoringState()
        var session = TodayReviewSessionState(queue: ["a", "b", "c"])
        scoring.record(.remembered, at: 0)

        session.goNext()
        session.goNext()
        session.goPrevious()
        session.goPrevious()
        session.goNext()

        #expect(session.currentIndex == 1)
        #expect(scoring.gradedFeedback(at: session.currentIndex) == nil)
        #expect(progress(scoring, session).text == "1 / 3")
    }

    @Test func revisitingAGradedCardShowsItsGradeWithoutCountingAgain() {
        let scoring = ReviewScoringState()
        var session = TodayReviewSessionState(queue: ["a", "b", "c"])
        scoring.record(.forgot, at: 0)
        session.advanceAfterSubmission()
        session.goPrevious()

        #expect(session.currentIndex == 0)
        #expect(scoring.gradedFeedback(at: session.currentIndex) == .forgot)
        #expect(progress(scoring, session).text == "1 / 3")
    }

    // MARK: - Undo (replace semantics, #2025)

    @Test func regradingAGradedCardKeepsTheGradedCount() {
        let scoring = ReviewScoringState()
        scoring.record(.remembered, at: 0)
        scoring.record(.remembered, at: 1)

        #expect(scoring.score(.forgot, at: 0) == .replaced(previous: .remembered))
        #expect(scoring.gradedCount == 2)
        #expect(scoring.gradedFeedback(at: 0) == .forgot)

        #expect(scoring.score(.forgot, at: 0) == .unchanged)
        #expect(scoring.gradedCount == 2)
    }

    @Test func goingBackAndRegradingKeepsTheTotalAndMovesOnlyTheGrade() {
        let scoring = ReviewScoringState()
        var session = TodayReviewSessionState(queue: ["a", "b", "c"])
        scoring.record(.remembered, at: 0)
        session.advanceAfterSubmission()
        session.goPrevious()

        scoring.score(.forgot, at: session.currentIndex)

        #expect(progress(scoring, session).text == "1 / 3")
        #expect(scoring.rememberedCount == 0)
        #expect(scoring.forgotCount == 1)
    }

    // MARK: - Restore

    @Test func restoredAnswersCountAsGraded() {
        let scoring = ReviewScoringState()
        scoring.restore(
            submittedAnswers: [
                0: TodayReviewState.SubmittedAnswer(feedback: .remembered, answeredAt: Date(), reviewRecordID: UUID()),
                3: TodayReviewState.SubmittedAnswer(feedback: .forgot, answeredAt: Date(), reviewRecordID: UUID()),
            ],
            rememberedCount: 1,
            forgotCount: 1
        )

        #expect(ReviewGradeProgress(graded: scoring.gradedCount, total: 5).text == "2 / 5")
    }

    // MARK: - Clamp

    @Test func gradedCountIsClampedIntoTheTotal() {
        #expect(ReviewGradeProgress(graded: 5, total: 3).text == "3 / 3")
        #expect(ReviewGradeProgress(graded: 0, total: 0).text == "0 / 0")
        #expect(ReviewGradeProgress(graded: -1, total: 2).text == "0 / 2")
    }

    // MARK: - Revisited graded card badge

    @Test func ungradedCardResolvesNoBadge() {
        let scoring = ReviewScoringState()
        #expect(ReviewGradedBadge.resolve(scoring.gradedFeedback(at: 0)) == nil)
    }

    @Test func revisitedGradedCardResolvesItsGradeBadge() {
        let scoring = ReviewScoringState()
        scoring.record(.forgot, at: 2)
        #expect(ReviewGradedBadge.resolve(scoring.gradedFeedback(at: 2)) == ReviewGradedBadge(feedback: .forgot))

        scoring.score(.remembered, at: 2)
        #expect(ReviewGradedBadge.resolve(scoring.gradedFeedback(at: 2)) == ReviewGradedBadge(feedback: .remembered))
    }

    @Test func badgeTextComposesTheExistingGradeWordsIntoTheGradedFormat() {
        #expect(ReviewGradedBadge(feedback: .remembered).text
            == L10n.format("todayReview.card.graded", L10n.string("記得")))
        #expect(ReviewGradedBadge(feedback: .forgot).text
            == L10n.format("todayReview.card.graded", L10n.string("忘記")))
    }

    // MARK: - Card content carries the badge of its own queue index

    private func makeState(cardCount: Int) -> TodayReviewState {
        let entries = (0..<cardCount).map { index -> VocabularyEntry in
            let entry = VocabularyEntry(
                word: "grade-\(UUID().uuidString.prefix(6))-\(index)",
                translation: "translation-\(index)",
                context: "A sample sentence for card \(index).",
                bookTitle: "Sample"
            )
            entry.markSynced()
            return entry
        }
        return TodayReviewState(entries: entries, allEntries: entries, currentUserID: nil)
    }

    @Test func revisitedGradedCardCarriesItsBadgeOnTheCardContent() {
        let state = makeState(cardCount: 3)
        state.scoring.record(.forgot, at: 0)

        #expect(state.currentCardForTesting?.gradedBadge == ReviewGradedBadge(feedback: .forgot))

        state.goNext()
        #expect(state.currentCardForTesting?.gradedBadge == nil)

        state.goPrevious()
        #expect(state.currentCardForTesting?.gradedBadge == ReviewGradedBadge(feedback: .forgot))
    }

    // MARK: - Header progress on the presenter (#3371, #3390)

    @Test func headerProgressIsTheGradedCountAndIgnoresBrowsing() {
        let state = makeState(cardCount: 5)
        state.scoring.record(.remembered, at: 0)
        #expect(state.progressText == "1 / 5")
        #expect(state.progressText == ReviewGradeProgress(graded: state.scoring.gradedCount, total: state.queue.count).text)

        state.goNext()
        state.goPrevious()
        state.goNext()
        #expect(state.currentIndex == 1)
        #expect(state.progressText == "1 / 5")
    }

    @Test func regradingKeepsTheHeaderCount() {
        let state = makeState(cardCount: 5)
        state.scoring.record(.remembered, at: 0)
        state.scoring.score(.forgot, at: 0)
        #expect(state.progressText == "1 / 5")
    }

    @Test func positionSignalStillMovesWhileTheHeaderStaysGraded() {
        let state = makeState(cardCount: 5)
        #expect(state.positionText == "1 / 5")

        state.goNext()
        #expect(state.positionText == "2 / 5")
        #expect(state.progressText == "0 / 5")
    }
}
