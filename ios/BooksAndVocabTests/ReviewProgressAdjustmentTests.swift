//
//  ReviewProgressAdjustmentTests.swift
//  Books & Vocab Tests
//
//  #2042 Stage 3：拉桿 level → 進度覆寫的純函式映射，以及拉桿觸點 → level 的換算。
//  每個 scenario 都配正控：映射若永遠回同一值，這裡就會紅。
//

import Testing
@testable import BooksAndVocab

struct ReviewProgressAdjustmentTests {

    @Test func levelZeroKeepsProgressAndOnlySwitchesMode() {
        let adjustment = ReviewProgressAdjustment.forgetting(
            level: 0, currentIntervalHours: 24, initialIntervalHours: 12
        )
        #expect(adjustment == .keep)
    }

    @Test func levelOneResetsProgress() {
        let adjustment = ReviewProgressAdjustment.forgetting(
            level: 1, currentIntervalHours: 24, initialIntervalHours: 12
        )
        #expect(adjustment == .reset)
    }

    @Test func levelAtSnapThresholdResetsButJustBelowReschedules() {
        #expect(ReviewProgressAdjustment.forgetting(
            level: 0.92, currentIntervalHours: 40, initialIntervalHours: 12
        ) == .reset)
        let below = ReviewProgressAdjustment.forgetting(
            level: 0.91, currentIntervalHours: 40, initialIntervalHours: 12
        )
        if case .reschedule = below {
        } else {
            Issue.record("正控：0.91 低於吸附門檻，應為 reschedule，實際 \(below)")
        }
    }

    @Test func intermediateLevelScalesIntervalByRemainingFraction() {
        // 40 × (1 − 0.5) = 20，高於初始間隔 12，不被夾住。
        let adjustment = ReviewProgressAdjustment.forgetting(
            level: 0.5, currentIntervalHours: 40, initialIntervalHours: 12
        )
        #expect(adjustment == .reschedule(intervalHours: 20))
    }

    @Test func rescheduledIntervalNeverDropsBelowTheInitialInterval() {
        // 20 × (1 − 0.75) = 5，但不低於有效初始間隔 12。
        let adjustment = ReviewProgressAdjustment.forgetting(
            level: 0.75, currentIntervalHours: 20, initialIntervalHours: 12
        )
        #expect(adjustment == .reschedule(intervalHours: 12))
    }

    @Test func outOfRangeLevelIsClampedToTheTrack() {
        #expect(ReviewProgressAdjustment.forgetting(
            level: -0.3, currentIntervalHours: 24, initialIntervalHours: 12
        ) == .keep)
        #expect(ReviewProgressAdjustment.forgetting(
            level: 1.7, currentIntervalHours: 24, initialIntervalHours: 12
        ) == .reset)
    }

    @Test func snapRoundsNearRightEndToOneAndLeavesMiddleValuesAlone() {
        #expect(ReviewProgressAdjustment.snapped(0.95) == 1)
        #expect(ReviewProgressAdjustment.snapped(0.5) == 0.5)
        #expect(ReviewProgressAdjustment.snapped(-1) == 0)
    }

    @Test func sliderMapsTouchInsideTheTrackToLevel() {
        // 寬 200、旋鈕 40：可行中心區間 [20, 180]。
        #expect(ReviewForgettingSlider.level(forX: 20, width: 200, knobSize: 40) == 0)
        #expect(ReviewForgettingSlider.level(forX: 100, width: 200, knobSize: 40) == 0.5)
        #expect(ReviewForgettingSlider.level(forX: 180, width: 200, knobSize: 40) == 1)
    }

    @Test func sliderClampsTouchesOutsideTheTrack() {
        #expect(ReviewForgettingSlider.level(forX: -50, width: 200, knobSize: 40) == 0)
        #expect(ReviewForgettingSlider.level(forX: 500, width: 200, knobSize: 40) == 1)
    }

    @Test func sliderWithoutRoomForTravelReadsAsKeep() {
        #expect(ReviewForgettingSlider.level(forX: 10, width: 40, knobSize: 40) == 0)
    }
}
