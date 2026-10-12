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

    /// #3227：超過值欄寬的項目必須在值欄內換行（不得溢出卡片），後續項目回到值欄。
    /// Red：舊實作以自然寬 200 放置，frame.maxX = 64 + 200 = 264 > 130。
    @Test func anOversizedFirstItemWrapsInsideTheValueColumn() {
        let maxWidth: CGFloat = 130
        let indent = Self.label.width + Self.gap
        let result = HangingIndentFlow.place(count: 3, spacing: Self.gap, maxWidth: maxWidth) { index, width in
            if index == 0 { return Self.label }
            if index == 1 { return Self.wrapping(natural: CGSize(width: 200, height: 16), at: width) }
            return Self.chip
        }
        #expect(result.frames[1].minY == 0, "the oversized item stays on the label row")
        #expect(result.frames[1].minX == indent, "it starts in the value column")
        #expect(result.frames[1].maxX <= maxWidth, "it is clamped to the value column, never past the card")
        #expect(result.frames[1].height > 16, "its text wraps to more lines, so its row grows")
        #expect(result.frames[2].minY >= result.frames[1].maxY, "the next item starts below the wrapped text")
        #expect(result.frames[2].minX == indent, "the next item returns to the value column")
    }

    /// 模擬文字量測：寬度不足時換行，高度依行數增加。
    private static func wrapping(natural: CGSize, at width: CGFloat?) -> CGSize {
        guard let width, width > 0, width < natural.width else { return natural }
        let lines = (natural.width / width).rounded(.up)
        return CGSize(width: width, height: natural.height * lines)
    }

    /// #3297：標籤已佔滿可用寬（valueWidth <= 0）時，項目不得被夾成 0 寬而隱形；
    /// 必須保留自然寬，仍在標籤列上。
    /// Red：舊實作 valueWidth = max(0, 40 - 64) = 0，line 74 將 chip 夾成 min(50, 0) = 0。
    @Test func zeroValueColumnKeepsNaturalChipWidth() {
        let result = HangingIndentFlow.place(
            sizes: [Self.label, Self.chip],
            spacing: Self.gap,
            maxWidth: 40
        )
        #expect(result.frames[1].width == Self.chip.width, "the chip must not collapse to zero width")
        #expect(result.frames[1].height == Self.chip.height)
        #expect(result.frames[1].minY == 0, "the chip stays on the label row")
    }

    @Test func emptyInputHasNoGeometry() {
        let result = HangingIndentFlow.place(sizes: [], spacing: Self.gap, maxWidth: 130)
        #expect(result.frames.isEmpty)
        #expect(result.height == 0)
    }
}
