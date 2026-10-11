#if canImport(UIKit)
import Testing
@testable import BooksAndVocab

/// #3117：搭配解釋 sheet 的垃圾桶按鈕原本沒有 accessibilityLabel，VoiceOver 會唸 SF symbol 名 "trash"。
@MainActor
struct CollocationExplainSheetLabelTests {
    @Test func trash_button_speaks_a_localized_name_not_the_symbol() {
        let label = CollocationExplainSheet.deleteAccessibilityLabel
        #expect(!label.isEmpty)
        #expect(label != "trash", "VoiceOver 不得唸 SF symbol 名")
        #expect(label != "vocab.chromeIcon.collocation.delete", "key 必須能經 L10n 解析成文案")
    }
}
#endif
