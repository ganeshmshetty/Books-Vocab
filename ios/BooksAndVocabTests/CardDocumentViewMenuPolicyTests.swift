import Testing
@testable import BooksAndVocab

/// #3125 — a collocation pill must never offer a context-menu item whose handler is nil
/// (Word Detail used to offer a dead 解釋 because it passed no explain handler).
struct CardDocumentViewMenuPolicyTests {
    @Test func unexplainedPillWithoutHandlersOffersOnlyCopy() {
        let actions = CardDocumentCollocationState.menuActions(
            hasExplanation: false,
            canExplain: false,
            canView: false,
            canDelete: false
        )
        #expect(actions == [.copy])
    }

    @Test func unexplainedPillWithExplainHandlerOffersExplainThenCopy() {
        let actions = CardDocumentCollocationState.menuActions(
            hasExplanation: false,
            canExplain: true,
            canView: false,
            canDelete: false
        )
        #expect(actions == [.explain, .copy])
    }

    @Test func explainedPillWithoutHandlersOffersOnlyCopy() {
        let actions = CardDocumentCollocationState.menuActions(
            hasExplanation: true,
            canExplain: false,
            canView: false,
            canDelete: false
        )
        #expect(actions == [.copy])
    }

    @Test func explainedPillWithHandlersOffersViewCopyDelete() {
        let actions = CardDocumentCollocationState.menuActions(
            hasExplanation: true,
            canExplain: true,
            canView: true,
            canDelete: true
        )
        #expect(actions == [.view, .copy, .delete])
    }
}
