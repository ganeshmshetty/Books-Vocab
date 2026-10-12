import Foundation
import Testing
@testable import BooksAndVocab

/// #2043 — the review card's "+N" link overflow is a real control: tapping it
/// expands that group in place to show every link, tapping again collapses.
@MainActor
struct ReviewCardLinkStripTests {
    private static func link(_ index: Int, kind: String = "shares_usage") -> KGCardLinkSummary {
        KGCardLinkSummary(
            id: "link-\(kind)-\(index)",
            cardId: "card-\(kind)-\(index)",
            word: "word\(index)",
            kind: kind,
            label: "共用用法",
            confidence: 0.9,
            reason: "reason \(index)"
        )
    }

    private static func group(items count: Int, unavailable: Int = 0) -> ReviewCardLinkGroup {
        ReviewCardLinkGroup(
            id: "shares_usage",
            label: "共用用法",
            items: (0..<count).map { link($0) },
            overflowCount: unavailable
        )
    }

    // MARK: Overflow arithmetic

    @Test func collapsedShowsTwoAndCountsTheRest() {
        let row = ReviewCardLinkStripLayout.row(for: Self.group(items: 5), presentation: .twoPerGroup, isExpanded: false)
        #expect(row.leading.map(\.id) == ["link-shares_usage-0", "link-shares_usage-1"])
        #expect(row.expanded.isEmpty)
        #expect(row.overflowCount == 3)
        #expect(row.isExpandable)
    }

    @Test func expandedShowsEveryLinkExactlyOnce() {
        let group = Self.group(items: 5)
        let row = ReviewCardLinkStripLayout.row(for: group, presentation: .twoPerGroup, isExpanded: true)
        #expect((row.leading + row.expanded).map(\.id) == group.items.map(\.id), "all links, in order, no duplicates")
        #expect(row.overflowCount == 0)
        #expect(row.isExpandable, "an expanded row keeps its control so it can collapse")
    }

    @Test func collapsedAndExpandedShareOneVisibleOrder() {
        // #3114: one flow renders both states, so the expanded strip starts with
        // exactly the collapsed items, in the same order, with no duplicates.
        let group = Self.group(items: 5)
        let collapsed = ReviewCardLinkStripLayout.row(for: group, presentation: .twoPerGroup, isExpanded: false)
        let expanded = ReviewCardLinkStripLayout.row(for: group, presentation: .twoPerGroup, isExpanded: true)
        #expect(
            expanded.visible.prefix(collapsed.visible.count).map(\.id) == collapsed.visible.map(\.id),
            "expanding only appends; it never reorders or re-renders the leading links"
        )
        #expect(expanded.visible.map(\.id) == group.items.map(\.id))
    }

    @Test func expansionIsBoundedAndCountsTheRest() {
        // Expanding must never grow the card without limit: past the cap the
        // remainder stays a count, and that count is not expandable twice.
        let total = ReviewCardLinkStripLayout.expandedLimit + 7
        let group = Self.group(items: total)
        let collapsed = ReviewCardLinkStripLayout.row(for: group, presentation: .twoPerGroup, isExpanded: false)
        #expect(collapsed.overflowCount == total - 2)

        let expanded = ReviewCardLinkStripLayout.row(for: group, presentation: .twoPerGroup, isExpanded: true)
        #expect(expanded.expanded.count == ReviewCardLinkStripLayout.expandedLimit)
        #expect(expanded.leading.count + expanded.expanded.count + expanded.overflowCount == total)
        #expect(expanded.overflowCount == 5)
        #expect(expanded.isExpandable, "an expanded row keeps its control so it can collapse")
    }

    @Test func compactedPresentationsExpandToEverythingToo() {
        let group = Self.group(items: 4)
        let one = ReviewCardLinkStripLayout.row(for: group, presentation: .onePerGroup, isExpanded: false)
        #expect(one.leading.count == 1)
        #expect(one.overflowCount == 3)

        let summary = ReviewCardLinkStripLayout.row(for: group, presentation: .summary, isExpanded: false)
        #expect(summary.leading.isEmpty)
        #expect(summary.overflowCount == 4)

        let expanded = ReviewCardLinkStripLayout.row(for: group, presentation: .summary, isExpanded: true)
        #expect((expanded.leading + expanded.expanded).count == 4)
    }

    @Test func nothingHiddenMeansNothingToExpand() {
        let row = ReviewCardLinkStripLayout.row(for: Self.group(items: 2), presentation: .twoPerGroup, isExpanded: false)
        #expect(row.overflowCount == 0)
        #expect(!row.isExpandable)
    }

    @Test func linksNotOnDeviceStayCountedButAreNotExpandable() {
        // overflowCount on the group = links the device does not hold; expanding
        // cannot show them, so they must never turn "+N" into a dead button.
        let row = ReviewCardLinkStripLayout.row(
            for: Self.group(items: 2, unavailable: 3),
            presentation: .twoPerGroup,
            isExpanded: false
        )
        #expect(row.overflowCount == 3)
        #expect(!row.isExpandable)
    }

    // MARK: Expansion state (memory only, per card)

    @Test func expansionIsPerGroupAndPerCard() {
        var expansion = ReviewCardLinkExpansion()
        #expect(!expansion.isExpanded("shares_usage", cardKey: "a"))

        expansion.toggle("shares_usage", cardKey: "a")
        #expect(expansion.isExpanded("shares_usage", cardKey: "a"))
        #expect(!expansion.isExpanded("contrasts_with", cardKey: "a"), "only the tapped group expands")
        #expect(!expansion.isExpanded("shares_usage", cardKey: "b"), "a recycled slot must not show it on another card")

        expansion.toggle("shares_usage", cardKey: "a")
        #expect(!expansion.isExpanded("shares_usage", cardKey: "a"), "tapping again collapses")
    }

    /// #3227：VoiceOver 文案與收合文案必須在每個語系的 `.lproj` 自己有譯文。`L10n` 會回退到 en，
    /// 因此這裡直接查各語系 bundle、不經回退；譯文也不得含 UTF-8 被當成 Latin-1 解讀的亂碼（U+0080–U+00FF）。
    /// Red：舊版 ja／ko／zh 的收合文案即為亂碼；缺鍵時 `L10n.format` 會回退英文，所以不能只靠它判定。
    @Test func reviewLinkStripStringsHaveOwnTranslationsInEveryLocale() throws {
        let keys = ["todayReview.card.link.overflow.a11y", "todayReview.card.link.collapse"]
        let missing = "__missing_translation__"
        let languages: [AppLanguage] = [.english, .traditionalChinese, .simplifiedChinese, .japanese, .korean]
        for language in languages {
            let code = try #require(language.localizationCode)
            let path = try #require(Bundle.main.path(forResource: code, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                let own = bundle.localizedString(forKey: key, value: missing, table: "Localizable")
                #expect(own != missing, "\(code) must define \(key) itself")
                let mojibake = own.unicodeScalars.contains { (0x80...0xFF).contains($0.value) }
                #expect(!mojibake, "\(code) \(key) is mis-decoded: \(own)")
            }
            let overflow = bundle.localizedString(forKey: keys[0], value: missing, table: "Localizable")
            #expect(overflow.contains("%@"), "\(code) keeps the hidden-link count placeholder")
            #expect(L10n.format(keys[0], language: language, "3").contains("3"), "\(code) renders the hidden-link count")
        }
    }

    @Test func expandingOnAnotherCardStartsFresh() {
        var expansion = ReviewCardLinkExpansion()
        expansion.toggle("shares_usage", cardKey: "a")
        expansion.toggle("contrasts_with", cardKey: "b")
        #expect(expansion.isExpanded("contrasts_with", cardKey: "b"))
        #expect(!expansion.isExpanded("shares_usage", cardKey: "a"), "state belongs to one card at a time")
        #expect(expansion.measurementVariant(cardKey: "b") != nil)
        #expect(expansion.measurementVariant(cardKey: "a") == nil)
    }

    @Test func collapseCopyIsLocalizedEverywhere() {
        let languages: [AppLanguage] = [.english, .traditionalChinese, .simplifiedChinese, .japanese, .korean]
        for language in languages {
            let value = L10n.string("todayReview.card.link.collapse", language: language)
            #expect(value != "todayReview.card.link.collapse", "missing in \(language)")
            #expect(!value.isEmpty)
        }
    }

    // MARK: Prepared card keeps every link

    @Test func preparedCardKeepsAllLinksForExpansion() throws {
        let entry = VocabularyEntry(
            word: "coax",
            translation: "哄勸",
            context: "She coaxed the cat down.",
            bookTitle: "Sample"
        )
        entry.graphLinksByKind = ["shares_usage": (0..<5).map { Self.link($0) }]
        entry.markSynced()

        let prepared = TodayReviewCardCache.buildOne(entry)
        let group = try #require(prepared.linkGroups.first)
        #expect(group.items.count == 5, "the strip can only expand to links the prepared card holds")
        #expect(group.overflowCount == 0)
    }
}
