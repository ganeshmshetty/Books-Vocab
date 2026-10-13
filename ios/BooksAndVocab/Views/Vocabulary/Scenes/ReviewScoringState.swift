import Foundation

/// 純評分邏輯狀態 — 管理本次 session 的答題記錄與計數。
/// 不依賴導航、不依賴 DB、不依賴 autoplay。
@Observable @MainActor
final class ReviewScoringState {
    private(set) var submittedAnswers: [Int: TodayReviewState.SubmittedAnswer] = [:]
    private(set) var forgotCount = 0
    private(set) var rememberedCount = 0
    var rememberedFeedbackTrigger = 0
    var forgotFeedbackTrigger = 0

    enum ScoreOutcome: Equatable {
        /// First answer for this card.
        case recorded
        /// Same feedback pressed again — idempotent, nothing changed.
        case unchanged
        /// A different feedback replaced the earlier answer (user went back and changed their mind).
        case replaced(previous: ReviewFeedback)
    }

    /// Score `feedback` for the card at `index`, with replace semantics (#2025).
    /// - First answer → recorded. Same feedback → no-op. Different feedback →
    ///   the old answer's count is taken back, the new one added, the
    ///   `reviewRecordID` is kept (so a later flush updates the same DB record in
    ///   place) and `flushed` resets to false so the store catches up.
    /// Haptic triggers are monotonic: a replacement fires the NEW feedback's
    /// trigger and never decrements the old one.
    @discardableResult
    func score(_ feedback: ReviewFeedback, at index: Int) -> ScoreOutcome {
        guard let existing = submittedAnswers[index] else {
            record(feedback, at: index)
            return .recorded
        }
        guard existing.feedback != feedback else { return .unchanged }
        switch existing.feedback {
        case .remembered: rememberedCount -= 1
        case .forgot: forgotCount -= 1
        }
        record(feedback, at: index, reviewRecordID: existing.reviewRecordID)
        return .replaced(previous: existing.feedback)
    }

    @discardableResult
    func record(
        _ feedback: ReviewFeedback,
        at index: Int,
        reviewRecordID: UUID = UUID()
    ) -> TodayReviewState.SubmittedAnswer {
        let answer = TodayReviewState.SubmittedAnswer(
            feedback: feedback,
            answeredAt: Date(),
            reviewRecordID: reviewRecordID
        )
        submittedAnswers[index] = answer
        switch feedback {
        case .remembered:
            rememberedFeedbackTrigger += 1
            rememberedCount += 1
        case .forgot:
            forgotFeedbackTrigger += 1
            forgotCount += 1
        }
        return answer
    }

    func hasAnswer(at index: Int) -> Bool {
        submittedAnswers[index] != nil
    }

    /// 本 session 已評的卡數（#3371 header 進度的分子）。每張卡至多一筆答案，replace 不改變此數；
    /// 瀏覽（‹ ›、autoplay）不寫入評分 state，因此也不會改變此數。
    var gradedCount: Int { submittedAnswers.count }

    /// 此卡已評的結果；nil ＝ 尚未評分。revisit 已評的卡時，卡片標示由此取值（#3371）。
    func gradedFeedback(at index: Int) -> ReviewFeedback? {
        submittedAnswers[index]?.feedback
    }

    /// Mark an answer as DB-flush-confirmed. Called from the flush success
    /// callback so the snapshot can record `flushed=true` and restore won't
    /// re-flush it. No-op if the index has no recorded answer.
    func markFlushed(at index: Int) {
        submittedAnswers[index]?.flushed = true
    }

    func restore(
        submittedAnswers: [Int: TodayReviewState.SubmittedAnswer],
        rememberedCount: Int,
        forgotCount: Int
    ) {
        self.submittedAnswers = submittedAnswers
        self.rememberedCount = rememberedCount
        self.forgotCount = forgotCount
    }
}
