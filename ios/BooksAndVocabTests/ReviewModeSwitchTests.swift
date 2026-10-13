//
//  ReviewModeSwitchTests.swift
//  Books & Vocab Tests
//
//  #2042 Stage 3：辨識⇄產出切換的狀態層——方向與 pending 旗標、進度覆寫、
//  目前卡 session 基準重拍、已評分卡拒絕切換、開面板暫停自動播放。
//  映射本身見 ReviewProgressAdjustmentTests。
//

import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@MainActor
struct ReviewModeSwitchTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEntry(
        count: Int = 3,
        lapse: Int = 1,
        streak: Int = 2,
        intervalHours: Double = 40
    ) -> VocabularyEntry {
        let entry = VocabularyEntry(
            word: "switch-\(UUID().uuidString.prefix(6))",
            translation: "translation",
            context: "A sample sentence.",
            bookTitle: "Sample"
        )
        entry.markSynced()
        entry.reviewCount = count
        entry.lapseCount = lapse
        entry.reviewStreak = streak
        entry.reviewIntervalHours = intervalHours
        entry.lastReviewedAt = now.addingTimeInterval(-3600)
        return entry
    }

    // MARK: - Entry 層：進度覆寫

    @Test func keepLeavesProgressUntouchedAndQueuesNoOverride() {
        let entry = makeEntry()
        entry.applyReviewProgressAdjustment(.keep, now: now, initialIntervalHours: 12)
        #expect(entry.reviewCount == 3)
        #expect(entry.reviewIntervalHours == 40)
        #expect(entry.pendingReviewProgressReset == false)
    }

    @Test func rescheduleKeepsCountsAndQueuesOverrideFromNow() {
        let entry = makeEntry()
        entry.applyReviewProgressAdjustment(.reschedule(intervalHours: 20), now: now, initialIntervalHours: 12)
        #expect(entry.reviewCount == 3)
        #expect(entry.lapseCount == 1)
        #expect(entry.reviewStreak == 2)
        #expect(entry.reviewIntervalHours == 20)
        #expect(entry.nextReviewAt == now.addingTimeInterval(20 * 3600))
        #expect(entry.lastReviewedAt == now)
        #expect(entry.pendingReviewProgressReset)
    }

    @Test func resetUsesTheEffectiveInitialIntervalNotThePolicyDefault() {
        let entry = makeEntry()
        entry.applyReviewProgressAdjustment(.reset, now: now, initialIntervalHours: 6)
        #expect(entry.reviewCount == 0)
        #expect(entry.reviewIntervalHours == 6)
        #expect(entry.nextReviewAt == now)
        #expect(entry.pendingReviewProgressReset)
    }

    // MARK: - State 層：切換動作

    private func makeState(_ entries: [VocabularyEntry], userID: String? = nil) -> TodayReviewState {
        TodayReviewState(entries: entries, allEntries: entries, currentUserID: userID)
    }

    @Test func switchFlipsModeAndQueuesOnlyTheModePushWhenKept() {
        let entry = makeEntry()
        let state = makeState([entry])
        #expect(state.applyReviewModeSwitch(level: 0, initialIntervalHours: 12, now: now))
        #expect(entry.reviewMode == .production)
        #expect(entry.pendingReviewModePush)
        #expect(entry.pendingReviewProgressReset == false)
        #expect(entry.reviewCount == 3)
    }

    @Test func fullResetSwitchQueuesOverrideAndFlipsMode() {
        let entry = makeEntry()
        let state = makeState([entry])
        #expect(state.applyReviewModeSwitch(level: 1, initialIntervalHours: 12, now: now))
        #expect(entry.reviewMode == .production)
        #expect(entry.pendingReviewModePush)
        #expect(entry.reviewCount == 0)
        #expect(entry.pendingReviewProgressReset)
    }

    @Test func switchRebaselinesTheUnansweredCurrentCardSoGradingCannotOverwriteIt() {
        let entry = makeEntry(count: 3)
        let state = makeState([entry])
        // 正控：切換前 session 基準仍是舊進度。
        #expect(state.currentReviewBaseline?.reviewCount == 3)
        #expect(state.applyReviewModeSwitch(level: 1, initialIntervalHours: 12, now: now))
        #expect(state.currentReviewBaseline?.reviewCount == 0)
        #expect(state.currentReviewBaseline?.nextReviewAt == now)
    }

    @Test func switchWithoutACurrentCardIsRefused() {
        let state = makeState([])
        #expect(state.applyReviewModeSwitch(level: 0, initialIntervalHours: 12, now: now) == false)
    }

    @Test func answeredCurrentCardRefusesTheSwitchAndKeepsItsMode() throws {
        let userID = "switch-answered-user"
        TodayReviewSessionSnapshotStore.clear(for: userID)
        defer { TodayReviewSessionSnapshotStore.clear(for: userID) }
        let entries = [makeEntry(), makeEntry()]
        let container = try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        entries.forEach { context.insert($0) }
        #expect(context.safeSave())

        let state = makeState(entries, userID: userID)
        // 正控：未評分的目前卡可切換。
        #expect(state.canSwitchReviewMode)
        state.submit(.remembered, container: container, reviewSettings: .default)
        state.goPrevious()
        #expect(state.canSwitchReviewMode == false)
        #expect(state.applyReviewModeSwitch(level: 1, initialIntervalHours: 12, now: now) == false)
        #expect(entries[0].reviewMode == .recognition)
        #expect(entries[0].pendingReviewModePush == false)
    }

    // MARK: - 面板開啟：暫停自動播放

    @Test func beginningTheSwitchPausesAutoplayAndDoesNotResumeIt() {
        let entries = (0..<3).map { _ in makeEntry() }
        let state = makeState(entries)
        state.toggleAutoPlay()
        // 正控：自動播放確實在跑，否則「暫停」的斷言沒有意義。
        #expect(state.isAutoPlaying)
        state.beginReviewModeSwitch()
        #expect(state.isAutoPlaying == false)
        state.stopAutoPlay()
    }
}
