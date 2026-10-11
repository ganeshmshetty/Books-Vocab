import Testing
@testable import BooksAndVocab

struct TodayReviewSessionStateTests {

    @Test func advancingAndRetractingRevealOnlyMovesBetweenFrontAndBack() {
        var state = TodayReviewSessionState(queue: ["alpha", "beta"])

        #expect(state.revealStage == .front)
        // Swift Testing's #expect captures its expression into an immutable
        // closure ($0), so mutating members must be called before the macro.
        let advancedToBack = state.advanceReveal()
        #expect(advancedToBack)
        #expect(state.revealStage == .back)

        let advanceBlockedAtBack = state.advanceReveal()
        #expect(advanceBlockedAtBack == false)
        #expect(state.revealStage == .back)

        let retractedToFront = state.retractReveal()
        #expect(retractedToFront)
        #expect(state.revealStage == .front)

        let retractBlockedAtFront = state.retractReveal()
        #expect(retractBlockedAtFront == false)
        #expect(state.revealStage == .front)
    }

    @Test func navigationResetsRevealAndMovesWithinQueueBounds() {
        var state = TodayReviewSessionState(queue: ["alpha", "beta", "gamma"])

        let previousBlockedAtStart = state.goPrevious()
        #expect(previousBlockedAtStart == false)
        #expect(state.currentIndex == 0)

        let revealedBack = state.advanceReveal()
        #expect(revealedBack)
        #expect(state.revealStage == .back)

        let movedNext = state.goNext()
        #expect(movedNext)
        #expect(state.currentIndex == 1)
        #expect(state.revealStage == .front)

        let movedPrevious = state.goPrevious()
        #expect(movedPrevious)
        #expect(state.currentIndex == 0)
        #expect(state.revealStage == .front)
    }

    @Test func advanceAfterSubmissionMovesPastQueueAndReportsCompletion() {
        var state = TodayReviewSessionState(queue: ["alpha", "beta"])

        let advancedWithinQueue = state.advanceAfterSubmission()
        #expect(advancedWithinQueue == false)
        #expect(state.currentIndex == 1)
        #expect(state.currentEntry == "beta")
        #expect(state.revealStage == .front)

        let advancedPastQueue = state.advanceAfterSubmission()
        #expect(advancedPastQueue)
        #expect(state.currentIndex == 2)
        #expect(state.currentEntry == nil)
        #expect(state.isComplete)
    }

    @Test func shufflePreservesPrefixMembershipAndResetsReveal() {
        var state = TodayReviewSessionState(queue: ["alpha", "beta", "gamma", "delta"])
        state.currentIndex = 1
        _ = state.advanceReveal()

        var rng = FixedIndexRNG(indices: [1, 1])
        let shuffled = state.shuffleRemaining(using: &rng)
        #expect(shuffled)

        #expect(state.queue[0] == "alpha")
        #expect(state.currentIndex == 1)
        #expect(Set(state.queue[1...]) == Set(["beta", "gamma", "delta"]))
        #expect(state.revealStage == .front)
    }

    /// #2482: answered slots are pinned. A shuffle may only permute unpinned
    /// slots, otherwise the answer keyed by index grades the wrong card.
    @Test func shuffleNeverMovesPinnedSlots() {
        var state = TodayReviewSessionState(queue: ["a", "b", "c", "d", "e", "f"])
        state.currentIndex = 1
        let pinned: Set<Int> = [1, 2, 4]
        for _ in 0..<50 {
            let shuffled = state.shuffleRemaining(pinned: pinned)
            #expect(shuffled)
            #expect(state.queue[1] == "b")
            #expect(state.queue[2] == "c")
            #expect(state.queue[4] == "e")
            #expect(Set(state.queue) == Set(["a", "b", "c", "d", "e", "f"]))
        }
    }

    /// #2482: shuffle needs at least two unpinned slots from `currentIndex` on.
    @Test func canShuffleRequiresTwoUnpinnedRemainingSlots() {
        var state = TodayReviewSessionState(queue: ["a", "b", "c", "d"])
        state.currentIndex = 1
        #expect(state.canShuffle(pinned: []))
        #expect(state.canShuffle(pinned: [1]))
        #expect(state.canShuffle(pinned: [1, 2]) == false)

        var blocked = state
        let shuffled = blocked.shuffleRemaining(pinned: [1, 2])
        #expect(shuffled == false)
        #expect(blocked.queue == ["a", "b", "c", "d"])
    }
}

private struct FixedIndexRNG: RandomNumberGenerator {
    private var indices: [UInt64]
    private var cursor = 0

    init(indices: [UInt64]) {
        self.indices = indices
    }

    mutating func next() -> UInt64 {
        guard cursor < indices.count else { return 0 }
        defer { cursor += 1 }
        return indices[cursor]
    }
}
