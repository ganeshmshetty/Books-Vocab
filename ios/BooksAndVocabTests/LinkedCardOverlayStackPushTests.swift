import Foundation
import Testing
@testable import BooksAndVocab

/// #2734 — the linked-card stack must never hold the same entry twice, otherwise
/// `ForEach(stack, id: \.element.id)` renders duplicate identities.
@MainActor
struct LinkedCardOverlayStackPushTests {
    private static func entry(_ word: String) -> VocabularyEntry {
        VocabularyEntry(word: word, translation: "t", context: "c", bookTitle: "b")
    }

    @Test func pushingDistinctEntriesAppendsInOrder() {
        let (a, b, c) = (Self.entry("a"), Self.entry("b"), Self.entry("c"))
        var stack: [VocabularyEntry] = []
        stack.pushLinkedCard(a)
        stack.pushLinkedCard(b)
        stack.pushLinkedCard(c)
        #expect(stack.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func pushB_C_B_keepsIdsUniqueAndClosesNestedLayers() {
        let (b, c) = (Self.entry("b"), Self.entry("c"))
        var stack: [VocabularyEntry] = []
        stack.pushLinkedCard(b)
        stack.pushLinkedCard(c)
        stack.pushLinkedCard(b)
        #expect(stack.map(\.id) == [b.id])
        #expect(Set(stack.map(\.id)).count == stack.count)
    }

    @Test func pushingTopEntryAgainIsNoOp() {
        let (a, b) = (Self.entry("a"), Self.entry("b"))
        var stack = [a, b]
        stack.pushLinkedCard(b)
        #expect(stack.map(\.id) == [a.id, b.id])
    }

    /// #3129 — the layer title is the linked word itself, never an English literal;
    /// an empty word falls back to the localized 連結卡片.
    @Test func layerTitleShowsWordWithLocalizedFallback() {
        #expect(LinkedCardOverlayStack.layerTitle(for: "abrasive") == "abrasive")
        #expect(LinkedCardOverlayStack.layerTitle(for: "  abrasive ") == "abrasive")
        #expect(LinkedCardOverlayStack.layerTitle(for: "") == L10n.string("連結卡片"))
        #expect(LinkedCardOverlayStack.layerTitle(for: " \n") == L10n.string("連結卡片"))
        // 上面兩句在 key 缺失時也成立（兩邊都回 key 原文），所以另以英文值證明 key 真的存在於 bundle。
        #expect(L10n.string("連結卡片", language: .english) == "Linked Card")
    }
}

/// #3129 — one term per concept across shipped locales: retired duplicate keys are gone
/// and the zh-Hant values for the same concept agree.
@MainActor
struct OneTermPerConceptTests {
    private static let locales = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    private static func strings(_ locale: String) -> [String: String] {
        guard
            let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: locale),
            let dict = NSDictionary(contentsOfFile: path) as? [String: String]
        else { return [:] }
        return dict
    }

    @Test func retiredDuplicateKeysAreRemovedFromEveryLocale() {
        for locale in Self.locales {
            let dict = Self.strings(locale)
            #expect(dict["隱藏此連結"] == nil, "\(locale) still carries 隱藏此連結")
            #expect(dict["點兩下查看詳細資訊"] == nil, "\(locale) still carries 點兩下查看詳細資訊")
            #expect(dict["點兩下查看詳情"] != nil, "\(locale) lacks 點兩下查看詳情")
        }
    }

    @Test func zhHantConceptsResolveToOneTerm() {
        let zh = Self.strings("zh-Hant")
        #expect(zh["vocab.card.addLink"] == zh["新增連結"])
        #expect(zh["vocab.chromeIcon.translation.detail"] == zh["查看詳情"])
        #expect(zh["vocab.card.speak"]?.contains("播放") == true)
        #expect(zh["vocab.card.speak"]?.contains("朗讀") == false)
        #expect(zh["translation.vocab.speak"]?.contains("朗讀") == false)
    }
}
