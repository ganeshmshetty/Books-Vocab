struct TodayReviewSessionState<Entry> {
    var queue: [Entry]
    var currentIndex = 0
    var revealStage: TodayReviewRevealStage = .front

    var currentEntry: Entry? {
        guard currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    var progressText: String {
        "\(min(currentIndex + 1, queue.count)) / \(queue.count)"
    }

    var canGoPrevious: Bool { currentIndex > 0 }
    var canGoNext: Bool { currentIndex < queue.count - 1 }
    var remainingCount: Int { max(queue.count - currentIndex - 1, 0) }
    var isComplete: Bool { currentIndex >= queue.count }

    /// autoplay 是否還有事可做。loop 每一圈只有兩種動作:翻面(需要 `.front`)與
    /// 推進(需要 `canGoNext`)。兩者皆不可能時開播,只會睡完 stayDelay 再自殺——
    /// 對使用者就是「播放列閃一下就退回去」的死按鈕。
    var canAutoplay: Bool { !isComplete && (canGoNext || revealStage == .front) }

    @discardableResult
    mutating func advanceReveal() -> Bool {
        guard revealStage == .front else { return false }
        revealStage.advance()
        return true
    }

    @discardableResult
    mutating func retractReveal() -> Bool {
        guard revealStage == .back else { return false }
        revealStage.retract()
        return true
    }

    @discardableResult
    mutating func goPrevious() -> Bool {
        guard canGoPrevious else { return false }
        revealStage = .front
        currentIndex -= 1
        return true
    }

    @discardableResult
    mutating func goNext() -> Bool {
        guard canGoNext else { return false }
        revealStage = .front
        currentIndex += 1
        return true
    }

    @discardableResult
    mutating func advanceAfterSubmission() -> Bool {
        revealStage = .front
        currentIndex += 1
        return isComplete
    }

    /// 洗牌可動的槽位：`currentIndex` 起、未被 `pinned` 釘住的槽。
    /// `pinned` = 已作答的槽（答案以 queue index 為鍵，移動即誤判；#2482）。
    private func shufflableSlots(pinned: Set<Int>) -> [Int] {
        guard currentIndex < queue.count else { return [] }
        return (currentIndex..<queue.count).filter { !pinned.contains($0) }
    }

    func canShuffle(pinned: Set<Int> = []) -> Bool {
        shufflableSlots(pinned: pinned).count > 1
    }

    @discardableResult
    mutating func shuffleRemaining(pinned: Set<Int> = []) -> Bool {
        var rng = SystemRandomNumberGenerator()
        return shuffleRemaining(pinned: pinned, using: &rng)
    }

    /// 只重排未釘住的槽；釘住的槽（已作答）原地不動。
    @discardableResult
    mutating func shuffleRemaining<RNG: RandomNumberGenerator>(
        pinned: Set<Int> = [],
        using rng: inout RNG
    ) -> Bool {
        guard canShuffle(pinned: pinned) else { return false }
        let slots = shufflableSlots(pinned: pinned)
        var entries = slots.map { queue[$0] }
        entries.shuffle(using: &rng)
        for (slot, entry) in zip(slots, entries) {
            queue[slot] = entry
        }
        revealStage = .front
        return true
    }
}
