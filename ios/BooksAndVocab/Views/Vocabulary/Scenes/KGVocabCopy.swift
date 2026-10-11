import Foundation

/// 單字庫批次操作文案，慣例對齊 `WordDetailCopy`。
enum KGVocabCopy {
    /// `language` 為 nil 時跟隨當前 app 語言；測試傳入明確語言以保持決定性。
    static func batchDeleteTitle(count: Int, language: AppLanguage? = nil) -> String {
        if count == 1 {
            return string("刪除這個單字？", language: language)
        }
        return format("刪除 %@ 個單字？", "\(count)", language: language)
    }

    /// 要指名損失：複習紀錄與知識連結都會消失，且不可復原。
    static func batchDeleteMessage(language: AppLanguage? = nil) -> String {
        string("複習紀錄與知識連結會一併移除，無法復原。", language: language)
    }

    private static func string(_ key: String, language: AppLanguage?) -> String {
        guard let language else { return L10n.string(key) }
        return L10n.string(key, language: language)
    }

    private static func format(_ key: String, _ argument: String, language: AppLanguage?) -> String {
        guard let language else { return L10n.format(key, argument) }
        return L10n.format(key, language: language, argument)
    }
}

/// 批次刪除的二段確認狀態：垃圾桶只「要求確認」，只有 `confirm` 才會真的執行刪除。
/// 不依賴 SwiftUI，讓「取消不刪、確認才刪一次」可直接單元測試。
struct BatchDeleteConfirmation {
    var isPending = false
    /// 請求當下的選取數快照。確認後 selection 會被清空，dialog dismiss 動畫期間標題必須仍顯示原數量，不能讀即時值。
    private(set) var requestedCount = 0

    mutating func request(selectionCount: Int) {
        isPending = selectionCount > 0
        if isPending {
            requestedCount = selectionCount
        }
    }

    mutating func cancel() {
        isPending = false
    }

    /// 空選取即使被程式性地送進來也不刪，避免產生「已刪除 0 個」。
    mutating func confirm(selectionCount: Int, _ delete: () -> Void) {
        isPending = false
        guard selectionCount > 0 else { return }
        delete()
    }
}
