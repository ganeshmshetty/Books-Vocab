#if os(iOS)
import Foundation
import Testing
@testable import BooksAndVocab

struct BookshelfCopyTests {

    @Test func emptyState_copy_staysStable() {
        let copy = BookshelfCopy.emptyState

        #expect(copy.title == L10n.string("尚無書籍"))
        #expect(copy.description == L10n.string("匯入電子書開始閱讀（EPUB・TXT・MD・PDF）"))
        #expect(copy.guidanceText == L10n.string("點擊上方匯入按鈕加入你的第一本書"))
        #expect(copy.primaryActionTitle == L10n.string("匯入"))
        #expect(copy.loginActionTitle == L10n.string("登入帳號"))
        #expect(copy.demoActionTitle == L10n.string("體驗複習與圖譜"))
    }

    @Test func importErrorTitle_usesDiagnosisWhenPresent() {
        #expect(BookshelfCopy.importErrorTitle(diagnosis: nil) == L10n.string("匯入錯誤"))
        #expect(
            BookshelfCopy.importErrorTitle(diagnosis: "PDF")
                == L10n.format("匯入錯誤・%@", "PDF")
        )
    }

    @Test func readingProgressAccessibilityValue_matchesVisibleRoundedPercent() {
        let english = Locale(identifier: "en_US")

        // 0.567 must read 57% (rounded), same as the visible BookCard label; truncation gave 56%.
        #expect(BookshelfCopy.readingProgressAccessibilityValue(0.567, locale: english) == "57%")
        #expect(
            BookshelfCopy.readingProgressAccessibilityValue(0.567, locale: english)
                == ReadingProgressFormatter.percentText(0.567, locale: english)
        )
        #expect(
            BookshelfCopy.readingProgressAccessibilityValue(0.564, locale: english)
                == ReadingProgressFormatter.percentText(0.564, locale: english)
        )
        #expect(BookshelfCopy.readingProgressAccessibilityValue(-0.2, locale: english) == "0%")
        #expect(BookshelfCopy.readingProgressAccessibilityValue(1.4, locale: english) == "100%")
        #expect(BookshelfCopy.readingProgressAccessibilityValue(nil, locale: english) == "0%")
    }

    @Test func toolbarAndBannerLabels_stayStable() {
        #expect(BookshelfCopy.navigationTitle == L10n.string("書庫"))
        #expect(BookshelfCopy.settingsAccessibilityLabel == L10n.string("設定"))
        #expect(BookshelfCopy.syncAccessibilityLabel == L10n.string("同步"))
        #expect(BookshelfCopy.importAccessibilityLabel == L10n.string("匯入"))
        #expect(BookshelfCopy.retryImportTitle == L10n.string("再試匯入"))
        #expect(BookshelfCopy.closeTitle == L10n.string("關閉"))
    }
}
#endif
