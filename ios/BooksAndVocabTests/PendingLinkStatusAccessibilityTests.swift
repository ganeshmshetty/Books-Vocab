import Testing
@testable import BooksAndVocab

/// #3425: the pending-link status block must expose its creation state through
/// a state-specific accessibility identifier, never through a raw English
/// accessibility value (`warning` / `failed` / `creating`).
struct PendingLinkStatusAccessibilityTests {
    private static let englishTokens: Set<String> = ["warning", "failed", "creating", "missing"]

    @Test("each pending-link state has its own status identifier")
    func statusIdentifiersArePerState() {
        let identifiers = PendingLinkStatusKind.allCases.map(\.accessibilityIdentifier)

        #expect(Set(identifiers).count == PendingLinkStatusKind.allCases.count)
        #expect(identifiers.contains("todayReview.card.link.pending.status.warning"))
        #expect(identifiers.contains("todayReview.card.link.pending.status.failed"))
        #expect(identifiers.contains("todayReview.card.link.pending.status.creating"))
    }

    @Test("status identifiers never equal the English value tokens")
    func statusIdentifiersAreNotEnglishValueTokens() {
        for kind in PendingLinkStatusKind.allCases {
            #expect(!Self.englishTokens.contains(kind.accessibilityIdentifier))
        }
    }
}
