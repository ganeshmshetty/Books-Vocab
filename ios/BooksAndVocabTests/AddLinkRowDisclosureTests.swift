import Foundation
import Testing
@testable import BooksAndVocab

@Suite("Add Link row disclosure (#3111)")
struct AddLinkRowDisclosureTests {
    @Test("toggling a row body expands it, emits no link effect, and a second toggle collapses it")
    func bodyTapTogglesWithoutLinking() {
        var state = AddLinkRowDisclosure()
        let row = UUID()

        #expect(state.send(.toggleRow(row)) == .nothing)
        #expect(state.expandedID == row)

        #expect(state.send(.toggleRow(row)) == .nothing)
        #expect(state.expandedID == nil)
    }

    @Test("expanding row B collapses row A: only one row is open at a time")
    func expandingOneRowCollapsesAnother() {
        var state = AddLinkRowDisclosure()
        let rowA = UUID()
        let rowB = UUID()

        _ = state.send(.toggleRow(rowA))
        #expect(state.expandedID == rowA)

        #expect(state.send(.toggleRow(rowB)) == .nothing)
        #expect(state.expandedID == rowB)
    }

    @Test("新增連結 emits the link effect for that row and leaves expansion alone")
    func linkButtonEmitsLinkEffect() {
        var state = AddLinkRowDisclosure()
        let row = UUID()
        _ = state.send(.toggleRow(row))

        #expect(state.send(.link(row)) == .link(row))
        #expect(state.expandedID == row)
    }

    @Test("打開卡片 emits the open-card effect and keeps the row expanded for the return trip")
    func openCardButtonEmitsOpenCardEffect() {
        var state = AddLinkRowDisclosure()
        let row = UUID()
        _ = state.send(.toggleRow(row))

        #expect(state.send(.openCard(row)) == .openCard(row))
        #expect(state.expandedID == row)
    }

    @Test("a query change resets expansion so no stale row stays open")
    func queryChangeResetsExpansion() {
        var state = AddLinkRowDisclosure()
        _ = state.send(.toggleRow(UUID()))

        #expect(state.send(.queryChanged) == .nothing)
        #expect(state.expandedID == nil)
    }
}
