import CoreGraphics
import Testing
@testable import BooksAndVocab

/// #3114 — collapsed and expanded link strips share one hanging-indent flow:
/// the label is the first cell, and every continuation line starts at the value
/// column (the label's trailing x plus the gap).
struct HangingIndentFlowLayoutTests {
    private static let label = CGSize(width: 60, height: 16)
    private static let chip = CGSize(width: 50, height: 16)
    private static let gap: CGFloat = 4

    @Test func firstChipSitsInTheValueColumnOnTheLabelRow() {
        let result = HangingIndentFlow.place(
            sizes: [Self.label, Self.chip],
            spacing: Self.gap,
            maxWidth: 300
        )
        #expect(result.frames[0].origin == .zero)
        #expect(result.frames[1].minX == Self.label.width + Self.gap)
        #expect(result.frames[1].minY == 0)
    }

    @Test func wrappedItemsReturnToTheSameValueColumn() {
        let indent = Self.label.width + Self.gap
        let result = HangingIndentFlow.place(
            sizes: [Self.label, Self.chip, Self.chip, Self.chip],
            spacing: Self.gap,
            maxWidth: 130
        )
        // Row 0: label (0…60) + first chip (64…114). The second chip would end at 168 > 130.
        #expect(result.frames[2].minY > result.frames[1].minY, "second chip wraps")
        #expect(result.frames[2].minX == indent, "wrapped chip starts in the value column")
        #expect(result.frames[3].minX == indent, "every continuation line keeps the value column")
        #expect(result.frames[3].minY > result.frames[2].minY)
    }

    @Test func itemsNeverExtendPastTheProposedWidthUnlessAloneOnALine() {
        let maxWidth: CGFloat = 130
        let result = HangingIndentFlow.place(
            sizes: [Self.label] + Array(repeating: Self.chip, count: 6),
            spacing: Self.gap,
            maxWidth: maxWidth
        )
        for frame in result.frames.dropFirst() {
            #expect(frame.maxX <= maxWidth, "a chip that fits its row must stay inside the proposal")
        }
    }

    @Test func anOversizedFirstItemDoesNotStartAnEmptyLine() {
        let wide = CGSize(width: 200, height: 16)
        let result = HangingIndentFlow.place(
            sizes: [Self.label, wide, Self.chip],
            spacing: Self.gap,
            maxWidth: 130
        )
        #expect(result.frames[1].minY == 0, "the first item stays on the label row even when it overflows")
        #expect(result.frames[2].minY > 0, "the next item wraps instead of sharing the overflow")
    }

    @Test func emptyInputHasNoGeometry() {
        let result = HangingIndentFlow.place(sizes: [], spacing: Self.gap, maxWidth: 130)
        #expect(result.frames.isEmpty)
        #expect(result.height == 0)
    }
}
