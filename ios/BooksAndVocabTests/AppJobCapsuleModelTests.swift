import Foundation
import Testing
@testable import BooksAndVocab

@Suite("App job capsule model (#3116)")
struct AppJobCapsuleModelTests {
    private func entry(_ key: String, _ word: String, _ fraction: Double) -> AppJobCapsuleModel.Entry {
        AppJobCapsuleModel.Entry(jobKey: key, word: word, fraction: fraction)
    }

    @Test("hidden and without a tap target when no job is running")
    func hiddenWithoutJobs() {
        let model = AppJobCapsuleModel(entries: [])
        #expect(!model.isVisible)
        #expect(model.openJobKey == nil)
    }

    @Test("one running job shows its word and its own progress")
    func singleJob() {
        let model = AppJobCapsuleModel(entries: [entry("k1", "luminous", 0.4)])
        #expect(model.isVisible)
        #expect(!model.isAggregate)
        #expect(model.word == "luminous")
        #expect(model.fraction == 0.4)
        #expect(model.percentText == "40%")
    }

    @Test("several running jobs aggregate into a count and a mean progress")
    func aggregateJobs() {
        let model = AppJobCapsuleModel(entries: [
            entry("a", "x", 0.2), entry("b", "y", 0.6), entry("c", "z", 0.4),
        ])
        #expect(model.isAggregate)
        #expect(model.count == 3)
        #expect(model.word == nil)
        #expect(abs(model.fraction - 0.4) < 0.000_001)
    }

    @Test("progress is clamped into 0...1 before it reaches the ring")
    func clampsFraction() {
        #expect(AppJobCapsuleModel(entries: [entry("a", "x", -0.5)]).fraction == 0)
        #expect(AppJobCapsuleModel(entries: [entry("a", "x", 1.7)]).fraction == 1)
    }

    @Test("tap opens the oldest running job, the first in creation order")
    func opensOldestJob() {
        let model = AppJobCapsuleModel(entries: [entry("old", "x", 0.1), entry("new", "y", 0.9)])
        #expect(model.openJobKey == "old")
    }

    @Test("the VoiceOver value rounds progress to a whole percent")
    func percentRounds() {
        #expect(AppJobCapsuleModel(entries: [entry("a", "x", 0.456)]).percentText == "46%")
    }

    @Test("suppression holds per holder: the capsule stays off while any holder is active")
    @MainActor
    func suppressionHoldsPerHolder() {
        let suppression = AppJobCapsuleSuppression()
        #expect(!suppression.isSuppressed)
        suppression.setHeld(true, by: "reader")
        suppression.setHeld(true, by: "other")
        suppression.setHeld(false, by: "reader")
        #expect(suppression.isSuppressed)
        suppression.setHeld(false, by: "other")
        #expect(!suppression.isSuppressed)
    }
}
