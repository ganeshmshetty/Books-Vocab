//
//  ExploreSyncStateTests.swift
//  Books & Vocab Tests
//
//  Explore 目錄同步狀態機（#3682）：取消不得清掉失敗態、舊的 overlapping run 不得關掉新 run 的 loading。
//

#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

@Suite(.serialized)
@MainActor
struct ExploreSyncStateTests {

    private func phase(_ state: ExploreSyncState, decks: Int) -> ExplorePhase {
        ExplorePhase.resolve(
            isSyncing: state.isSyncing, syncFailed: state.syncFailed,
            totalDeckCount: decks, filteredCount: decks,
            isFilteringOrSearching: false
        )
    }

    /// 先經一次真失敗把 syncFailed 設為 true，再以取消結束的 run 不得把它清成 false（否則 0 牌組會落到 .empty）。
    @Test func cancelled_run_keeps_previous_failure_so_empty_catalog_stays_error() {
        var state = ExploreSyncState()
        let failed = state.begin()
        state.apply(outcome: .failed(.listFetch), generation: failed)
        #expect(state.syncFailed == true)

        let cancelled = state.begin()
        state.apply(outcome: .cancelled, generation: cancelled)

        #expect(state.syncFailed == true, "cancellation must not clear the failure state")
        #expect(state.isSyncing == false)
        #expect(phase(state, decks: 0) == .error, "not .empty: a cancelled sync is not 'no decks yet'")
    }

    /// run A 較舊、B 較新：A 結束時不得關掉 B 的 loading；只有最新 run 結束才 isSyncing = false。
    @Test func older_overlapping_run_cannot_clear_newer_run_loading_flag() {
        var state = ExploreSyncState()
        let a = state.begin()
        let b = state.begin()

        state.apply(outcome: .completed(catalogCount: 0), generation: a)
        #expect(state.isSyncing == true, "run A finishing must not clear run B's loading flag")

        state.apply(outcome: .completed(catalogCount: 3), generation: b)
        #expect(state.isSyncing == false)
        #expect(state.syncFailed == false)
    }

    /// 有快取牌組（.partial）時取消：過期資料提示必須保留，不得退回 .content。
    @Test func cancelled_run_keeps_partial_phase_with_cached_decks() {
        var state = ExploreSyncState()
        let failed = state.begin()
        state.apply(outcome: .failed(.listFetch), generation: failed)

        let cancelled = state.begin()
        state.apply(outcome: .cancelled, generation: cancelled)

        #expect(phase(state, decks: 5) == .partial)
    }
}
#endif
