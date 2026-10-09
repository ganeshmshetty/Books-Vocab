import Foundation

/// 單字庫批次操作文案，慣例對齊 `WordDetailCopy`。
enum KGVocabCopy {
    static func batchDeleteTitle(count: Int) -> String {
        L10n.format("刪除 %@ 個單字？", "\(count)")
    }

    /// 要指名損失：複習紀錄與知識連結都會消失，且不可復原。
    static var batchDeleteMessage: String {
        L10n.string("複習紀錄與知識連結會一併移除，無法復原。")
    }
}

/// 批次刪除的二段確認狀態：垃圾桶只「要求確認」，只有 `confirm` 才會真的執行刪除。
/// 不依賴 SwiftUI，讓「取消不刪、確認才刪一次」可直接單元測試。
struct BatchDeleteConfirmation {
    var isPending = false

    mutating func request(selectionCount: Int) {
        isPending = selectionCount > 0
    }

    mutating func cancel() {
        isPending = false
    }

    mutating func confirm(_ delete: () -> Void) {
        isPending = false
        delete()
    }
}
