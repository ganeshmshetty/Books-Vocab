//
//  TodayReviewGradePipelineTests.swift
//  Books & Vocab Tests
//
//  #3127: every grade source (swipe, button, keyboard) shares one fling pipeline. A keyboard
//  grade is a request that the view flings, never a synchronous submit; a grade that arrives
//  mid-fling is buffered once; 記得 and 忘記 produce distinct haptics with the same sound.
//

import Foundation
import SwiftUI
import Testing
@testable import BooksAndVocab

@MainActor
@Suite(.serialized)
struct TodayReviewGradePipelineTests {
    private static let userID = "grade-pipeline-user"

    private func makeEntries(_ count: Int) -> [VocabularyEntry] {
        (0..<count).map { index in
            let entry = VocabularyEntry(
                word: "grade-\(UUID().uuidString.prefix(6))-\(index)",
                translation: "t\(index)",
                context: "Sentence \(index).",
                bookTitle: "Sample"
            )
            entry.kgCardId = "card-grade-\(UUID().uuidString.prefix(8))"
            entry.markSynced()
            return entry
        }
    }

    @Test func keyboardGradeIsARequestAndDoesNotSubmitSynchronously() {
        TodayReviewSessionSnapshotStore.clear(for: Self.userID)
        defer { TodayReviewSessionSnapshotStore.clear(for: Self.userID) }
        let entries = makeEntries(2)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: Self.userID)

        #expect(state.requestKeyboardGrade(remember: true))
        #expect(state.keyboardGrade == KeyboardGradeRequest(sequence: 1, remember: true))
        #expect(state.submittedAnswers.isEmpty)
        #expect(state.currentIndex == 0)
        #expect(state.hasUnflushedAnswers == false)

        // Each request is a new sequence so the view fires exactly one fling per key press.
        #expect(state.requestKeyboardGrade(remember: false))
        #expect(state.keyboardGrade == KeyboardGradeRequest(sequence: 2, remember: false))
        #expect(state.submittedAnswers.isEmpty)
    }

    @Test func keyboardGradeIsIgnoredWithoutACurrentCard() {
        let state = TodayReviewState(entries: [], allEntries: [], currentUserID: nil)

        #expect(state.requestKeyboardGrade(remember: true) == false)
        #expect(state.keyboardGrade == nil)
    }

    /// #3301：`onKeyPress` 預設同時送 `.down` 與 `.repeat`。只有初次 `.down` 可登記評分。
    /// Positive control：未加 phase 過濾時 `.repeat` 會通過（回傳 true），此斷言即失敗。
    @Test func gradeKeyRepeatPhaseIsNotAGradeRequest() {
        #expect(TodayReviewHotkeyPolicy.acceptsGradeKeyPhase(.down))
        #expect(TodayReviewHotkeyPolicy.acceptsGradeKeyPhase(.repeat) == false)
    }

    /// 按住一次方向鍵 = 1 個 `.down` + 多個 `.repeat`：只有 `.down` 會送出 `requestKeyboardGrade`，
    /// keyboardGrade 的 sequence 停在 1，不會把 FIFO 灌到上限。
    @Test func heldGradeKeyProducesExactlyOneGradeRequest() {
        TodayReviewSessionSnapshotStore.clear(for: Self.userID)
        defer { TodayReviewSessionSnapshotStore.clear(for: Self.userID) }
        let entries = makeEntries(2)
        let state = TodayReviewState(entries: entries, allEntries: entries, currentUserID: Self.userID)
        let phases: [KeyPress.Phases] = [.down] + Array(repeating: KeyPress.Phases.repeat, count: 20)

        var requests = 0
        for phase in phases where TodayReviewHotkeyPolicy.acceptsGradeKeyPhase(phase) {
            if state.requestKeyboardGrade(remember: true) { requests += 1 }
        }

        #expect(requests == 1)
        #expect(state.keyboardGrade == KeyboardGradeRequest(sequence: 1, remember: true))
        #expect(state.submittedAnswers.isEmpty)
    }

    @Test func gradeBufferedDuringFlingIsTakenOnceAtSettle() {
        var buffer = FlingGradeBuffer()
        buffer.receive(remember: true)

        #expect(buffer.takeAtSettle() == true)
        #expect(buffer.takeAtSettle() == nil)
    }

    @Test func laterGradeDuringTheSameFlingIsKeptAndAppliedInArrivalOrder() {
        var buffer = FlingGradeBuffer()
        buffer.receive(remember: true)
        buffer.receive(remember: false)

        #expect(buffer.takeAtSettle() == true)
        #expect(buffer.takeAtSettle() == false)
        #expect(buffer.takeAtSettle() == nil)
    }

    @Test func bufferIsBoundedAndDropsOnlyBeyondCapacity() {
        var buffer = FlingGradeBuffer()
        for _ in 0..<(FlingGradeBuffer.capacity + 3) {
            buffer.receive(remember: true)
        }

        var applied = 0
        while buffer.takeAtSettle() != nil { applied += 1 }
        #expect(applied == FlingGradeBuffer.capacity)
    }

    @Test func discardAllClearsEveryPendingGrade() {
        var buffer = FlingGradeBuffer()
        buffer.receive(remember: true)
        buffer.receive(remember: false)
        buffer.discardAll()

        #expect(buffer.takeAtSettle() == nil)
    }

    @Test func emptyBufferHasNothingToApply() {
        var buffer = FlingGradeBuffer()

        #expect(buffer.takeAtSettle() == nil)
    }

    @Test func rememberedAndForgotGradesUseDistinctHapticsWithTheSameSound() {
        let remembered = AppFeedbackEvent.reviewGrade(remember: true)
        let forgot = AppFeedbackEvent.reviewGrade(remember: false)

        #expect(remembered != forgot)
        #expect(remembered.sound == .review)
        #expect(forgot.sound == .review)
    }
}
