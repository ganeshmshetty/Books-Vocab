#if os(iOS)
import Foundation

enum NotebookEditPhotoError: Equatable {
    case loadFailed
    case unsupportedFormat
    case processingFailed
    case fileTooLarge
    case saveFailed
}

enum NotebookEditCopy {
    /// Backend caps notebook name at 100 chars (notebook.py); keep the field within it.
    static let nameMaxLength = 100

    static func clampedName(_ name: String) -> String {
        name.unicodeScalars.count <= nameMaxLength ? name : String(String.UnicodeScalarView(name.unicodeScalars.prefix(nameMaxLength)))
    }

    static var previewTitle: String { L10n.string("預覽") }
    static var namePlaceholder: String { L10n.string("單字本名稱") }
    static var colorSectionTitle: String { L10n.string("顏色") }
    static var patternSectionTitle: String { L10n.string("圖案") }
    static var noPatternTitle: String { L10n.string("無") }
    static var customImageSectionTitle: String { L10n.string("自訂圖片") }
    static var removeImageTitle: String { L10n.string("移除") }
    static var processingImageTitle: String { L10n.string("處理中...") }
    static var cancelTitle: String { L10n.string("取消") }

    static func imagePickerTitle(hasImage: Bool) -> String {
        hasImage ? L10n.string("更換圖片") : L10n.string("選擇圖片")
    }

    static func navigationTitle(isCreating: Bool) -> String {
        isCreating ? L10n.string("新增單字本") : L10n.string("編輯單字本")
    }

    static func saveTitle(isCreating: Bool) -> String {
        isCreating ? L10n.string("建立") : L10n.string("儲存")
    }

    static func photoErrorMessage(_ error: NotebookEditPhotoError) -> String {
        switch error {
        case .loadFailed:
            return L10n.string("無法載入圖片")
        case .unsupportedFormat:
            return L10n.string("圖片格式不支援")
        case .processingFailed:
            return L10n.string("圖片處理失敗")
        case .fileTooLarge:
            return L10n.string("圖片太大，請選擇較小的圖片")
        case .saveFailed:
            return L10n.string("儲存圖片失敗")
        }
    }
}
#endif
