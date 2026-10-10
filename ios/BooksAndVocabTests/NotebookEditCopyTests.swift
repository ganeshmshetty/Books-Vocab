#if os(iOS)
import Testing
@testable import BooksAndVocab

struct NotebookEditCopyTests {

    @Test func createAndEditTitles_stayStable() {
        #expect(NotebookEditCopy.previewTitle == L10n.string("預覽"))
        #expect(NotebookEditCopy.namePlaceholder == L10n.string("單字本名稱"))
        #expect(NotebookEditCopy.navigationTitle(isCreating: true) == L10n.string("新增單字本"))
        #expect(NotebookEditCopy.navigationTitle(isCreating: false) == L10n.string("編輯單字本"))
        #expect(NotebookEditCopy.saveTitle(isCreating: true) == L10n.string("建立"))
        #expect(NotebookEditCopy.saveTitle(isCreating: false) == L10n.string("儲存"))
    }

    @Test func imagePickerAndSectionCopy_stayStable() {
        #expect(NotebookEditCopy.colorSectionTitle == L10n.string("顏色"))
        #expect(NotebookEditCopy.patternSectionTitle == L10n.string("圖案"))
        #expect(NotebookEditCopy.noPatternTitle == L10n.string("無"))
        #expect(NotebookEditCopy.customImageSectionTitle == L10n.string("自訂圖片"))
        #expect(NotebookEditCopy.imagePickerTitle(hasImage: false) == L10n.string("選擇圖片"))
        #expect(NotebookEditCopy.imagePickerTitle(hasImage: true) == L10n.string("更換圖片"))
        #expect(NotebookEditCopy.removeImageTitle == L10n.string("移除"))
        #expect(NotebookEditCopy.processingImageTitle == L10n.string("處理中..."))
    }

    @Test func nameLimit_clampsTo100AndKeepsShortNames() {
        let long = String(repeating: "a", count: 150)
        #expect(NotebookEditCopy.nameMaxLength == 100)
        #expect(NotebookEditCopy.clampedName(long).count == 100)
        #expect(NotebookEditCopy.clampedName("Short") == "Short")
        let cjk = String(repeating: "字", count: 150)
        #expect(NotebookEditCopy.clampedName(cjk).unicodeScalars.count == 100)
    }

    @Test func photoErrorMessages_mapEachFailure() {
        #expect(NotebookEditCopy.photoErrorMessage(.loadFailed) == L10n.string("無法載入圖片"))
        #expect(NotebookEditCopy.photoErrorMessage(.unsupportedFormat) == L10n.string("圖片格式不支援"))
        #expect(NotebookEditCopy.photoErrorMessage(.processingFailed) == L10n.string("圖片處理失敗"))
        #expect(NotebookEditCopy.photoErrorMessage(.fileTooLarge) == L10n.string("圖片太大，請選擇較小的圖片"))
        #expect(NotebookEditCopy.photoErrorMessage(.saveFailed) == L10n.string("儲存圖片失敗"))
    }
}
#endif
