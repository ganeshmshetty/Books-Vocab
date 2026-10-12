#if canImport(UIKit)
import SwiftUI
import Testing
@testable import BooksAndVocab

/// #3112: the front-face corner chrome is speaker + open-detail, plus the `⋯` menu
/// only when the menu has an item. The word-row reserve must never exceed the
/// previous maximum (three 44pt touch boxes and two gaps), so wrapping never gets worse.
@Suite struct ReviewCardFrontChromeReserveTests {
    private let gap: CGFloat = 8

    /// Today's maximum: the compact preset's three buttons (toggle, speaker, open-detail).
    private var previousMaximum: CGFloat { 44 * 3 + 2 * gap }

    @Test func threeButtons_matchPreviousMaximum() {
        #expect(ReviewCardView.frontChromeReserve(buttons: 3, gap: gap) == previousMaximum)
    }

    @Test func twoButtons_reserveOneTouchBoxAndOneGapLess() {
        #expect(ReviewCardView.frontChromeReserve(buttons: 2, gap: gap) == 44 * 2 + gap)
    }

    @Test func visibleSlots_neverExceedPreviousMaximum() {
        for buttons in 0...ReviewCardView.frontChromeMaxButtons {
            #expect(ReviewCardView.frontChromeReserve(buttons: buttons, gap: gap) <= previousMaximum)
        }
        #expect(ReviewCardView.frontChromeMaxButtons == 3)
    }
}
#endif
