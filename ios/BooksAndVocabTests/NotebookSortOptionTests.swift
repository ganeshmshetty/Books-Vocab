//
//  NotebookSortOptionTests.swift
//  Books & Vocab Tests
//
//  Pins NotebookSortOption.sort() for all 9 options + the isDefault pinning rule.
//  A regression in sort order silently reshuffles the user's notebook shelf.
//

import Foundation
import Testing
@testable import BooksAndVocab

struct NotebookSortOptionTests {

    private func makeNotebook(
        remoteId: String,
        name: String,
        sortOrder: Int = 0,
        isDefault: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) -> Notebook {
        let n = Notebook(remoteId: remoteId, name: name, isDefault: isDefault)
        n.sortOrder = sortOrder
        n.createdAt = createdAt
        n.updatedAt = updatedAt
        return n
    }

    private func makeStats(
        cardCount: Int = 0,
        dueCount: Int = 0,
        lastActivity: Date? = nil
    ) -> NotebookStats {
        NotebookStats(cardCount: cardCount, dueCount: dueCount, lastActivity: lastActivity)
    }

    // MARK: - isDefault pinning

    @Test func defaultNotebookAlwaysFirstRegardlessOfSortOption() {
        let a = makeNotebook(remoteId: "a", name: "Alpha", sortOrder: 0)
        let b = makeNotebook(remoteId: "b", name: "Beta", sortOrder: 0, isDefault: true)
        let stats: [String: NotebookStats] = [:]

        for option in NotebookSortOption.allCases {
            let sorted = option.sort([a, b], stats: stats)
            #expect(sorted.first?.remoteId == "b", "default must be first for \(option)")
        }
    }

    @Test func defaultNotebookFirstEvenWhenNameWouldPlaceItLast() {
        let a = makeNotebook(remoteId: "a", name: "Alpha")
        let z = makeNotebook(remoteId: "z", name: "Zulu", isDefault: true)
        let stats: [String: NotebookStats] = [:]

        let sorted = NotebookSortOption.nameAsc.sort([a, z], stats: stats)
        #expect(sorted.map(\.remoteId) == ["z", "a"])
    }

    // MARK: - manual

    @Test func manualSortUsesSortOrder() {
        let a = makeNotebook(remoteId: "a", name: "A", sortOrder: 3)
        let b = makeNotebook(remoteId: "b", name: "B", sortOrder: 1)
        let c = makeNotebook(remoteId: "c", name: "C", sortOrder: 2)
        let stats: [String: NotebookStats] = [:]

        let sorted = NotebookSortOption.manual.sort([a, b, c], stats: stats)
        #expect(sorted.map(\.remoteId) == ["b", "c", "a"])
    }

    @Test func manualSortBreaksSortOrderTiesByCreationTimeBeforeRemoteId() {
        // #3677：server sort_order 恆為 0。remoteId 為隨機 hex，不得決定手動排序；應依建立時間（同 server created_at）。
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)
        let first = makeNotebook(remoteId: "zz", name: "First", createdAt: t1)
        let second = makeNotebook(remoteId: "aa", name: "Second", createdAt: t2)
        let third = makeNotebook(remoteId: "mm", name: "Third", createdAt: t3)

        let sorted = NotebookSortOption.manual.sort([third, first, second], stats: [:])
        #expect(sorted.map(\.name) == ["First", "Second", "Third"])
    }

    // MARK: - nameAsc / nameDesc

    @Test func nameAscSortsAZ() {
        let c = makeNotebook(remoteId: "c", name: "Charlie")
        let a = makeNotebook(remoteId: "a", name: "Alpha")
        let b = makeNotebook(remoteId: "b", name: "Bravo")
        let stats: [String: NotebookStats] = [:]

        let sorted = NotebookSortOption.nameAsc.sort([c, a, b], stats: stats)
        #expect(sorted.map(\.remoteId) == ["a", "b", "c"])
    }

    @Test func nameDescSortsZA() {
        let c = makeNotebook(remoteId: "c", name: "Charlie")
        let a = makeNotebook(remoteId: "a", name: "Alpha")
        let b = makeNotebook(remoteId: "b", name: "Bravo")
        let stats: [String: NotebookStats] = [:]

        let sorted = NotebookSortOption.nameDesc.sort([a, b, c], stats: stats)
        #expect(sorted.map(\.remoteId) == ["c", "b", "a"])
    }

    @Test func equalNameKeysUseRemoteIdAsDeterministicTieBreaker() {
        let b = makeNotebook(remoteId: "b", name: "Same")
        let a = makeNotebook(remoteId: "a", name: "Same")
        let stats: [String: NotebookStats] = [:]

        let sorted = NotebookSortOption.nameAsc.sort([b, a], stats: stats)
        #expect(sorted.map(\.remoteId) == ["a", "b"])
    }

    // MARK: - createdNewest / createdOldest

    @Test func createdNewestPutsNewestFirst() {
        let old = makeNotebook(remoteId: "old", name: "Old", createdAt: Date(timeIntervalSince1970: 100))
        let new = makeNotebook(remoteId: "new", name: "New", createdAt: Date(timeIntervalSince1970: 200))
        let stats: [String: NotebookStats] = [:]

        let sorted = NotebookSortOption.createdNewest.sort([old, new], stats: stats)
        #expect(sorted.map(\.remoteId) == ["new", "old"])
    }

    @Test func createdOldestPutsOldestFirst() {
        let old = makeNotebook(remoteId: "old", name: "Old", createdAt: Date(timeIntervalSince1970: 100))
        let new = makeNotebook(remoteId: "new", name: "New", createdAt: Date(timeIntervalSince1970: 200))
        let stats: [String: NotebookStats] = [:]

        let sorted = NotebookSortOption.createdOldest.sort([old, new], stats: stats)
        #expect(sorted.map(\.remoteId) == ["old", "new"])
    }

    // MARK: - updatedNewest

    @Test func updatedNewestPutsMostRecentlyUpdatedFirst() {
        let stale = makeNotebook(remoteId: "stale", name: "Stale", updatedAt: Date(timeIntervalSince1970: 100))
        let fresh = makeNotebook(remoteId: "fresh", name: "Fresh", updatedAt: Date(timeIntervalSince1970: 200))
        let stats: [String: NotebookStats] = [:]

        let sorted = NotebookSortOption.updatedNewest.sort([stale, fresh], stats: stats)
        #expect(sorted.map(\.remoteId) == ["fresh", "stale"])
    }

    // MARK: - cardCountDesc

    @Test func cardCountDescPutsMoreCardsFirst() {
        let few = makeNotebook(remoteId: "few", name: "Few")
        let many = makeNotebook(remoteId: "many", name: "Many")
        let stats: [String: NotebookStats] = [
            "few": makeStats(cardCount: 5),
            "many": makeStats(cardCount: 100),
        ]

        let sorted = NotebookSortOption.cardCountDesc.sort([few, many], stats: stats)
        #expect(sorted.map(\.remoteId) == ["many", "few"])
    }

    @Test func cardCountDescFallsBackToZeroWhenStatsMissing() {
        let a = makeNotebook(remoteId: "a", name: "A")
        let b = makeNotebook(remoteId: "b", name: "B")
        let stats: [String: NotebookStats] = ["a": makeStats(cardCount: 3)]

        let sorted = NotebookSortOption.cardCountDesc.sort([a, b], stats: stats)
        // a has 3 cards, b has 0 (missing stats) → a first
        #expect(sorted.map(\.remoteId) == ["a", "b"])
    }

    // MARK: - dueCountDesc

    @Test func dueCountDescPutsMoreDueFirst() {
        let calm = makeNotebook(remoteId: "calm", name: "Calm")
        let busy = makeNotebook(remoteId: "busy", name: "Busy")
        let stats: [String: NotebookStats] = [
            "calm": makeStats(dueCount: 2),
            "busy": makeStats(dueCount: 50),
        ]

        let sorted = NotebookSortOption.dueCountDesc.sort([calm, busy], stats: stats)
        #expect(sorted.map(\.remoteId) == ["busy", "calm"])
    }

    // MARK: - lastActivity

    @Test func lastActivityPutsMostRecentFirst() {
        let old = makeNotebook(remoteId: "old", name: "Old")
        let recent = makeNotebook(remoteId: "recent", name: "Recent")
        let stats: [String: NotebookStats] = [
            "old": makeStats(lastActivity: Date(timeIntervalSince1970: 100)),
            "recent": makeStats(lastActivity: Date(timeIntervalSince1970: 200)),
        ]

        let sorted = NotebookSortOption.lastActivity.sort([old, recent], stats: stats)
        #expect(sorted.map(\.remoteId) == ["recent", "old"])
    }

    @Test func lastActivityFallsBackToDistantPastWhenMissing() {
        let active = makeNotebook(remoteId: "active", name: "Active")
        let inactive = makeNotebook(remoteId: "inactive", name: "Inactive")
        let stats: [String: NotebookStats] = [
            "active": makeStats(lastActivity: Date(timeIntervalSince1970: 200)),
        ]

        let sorted = NotebookSortOption.lastActivity.sort([active, inactive], stats: stats)
        #expect(sorted.map(\.remoteId) == ["active", "inactive"])
    }

    @Test func lastActivityMissingForBothIsStable() {
        let a = makeNotebook(remoteId: "a", name: "A")
        let b = makeNotebook(remoteId: "b", name: "B")
        let stats: [String: NotebookStats] = [:]

        let sorted = NotebookSortOption.lastActivity.sort([a, b], stats: stats)
        // Both fallback to distantPast; comparator returns false both ways,
        // so sort is stable (preserves input order).
        #expect(sorted.map(\.remoteId) == ["a", "b"])
    }
}
