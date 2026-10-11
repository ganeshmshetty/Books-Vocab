#if os(iOS)
import Foundation

struct NotebookListEmptyStateCopy: Equatable {
    let title: String
    let description: String
    let actionTitle: String
    let actionSystemImage: String
}

enum NotebookListCopy {
    static var navigationTitle: String { L10n.string("單字本") }
    static var deleteTitle: String { L10n.string("確定要刪除此單字本？") }
    static var deleteButtonTitle: String { L10n.string("刪除") }
    static var deleteMessage: String { L10n.string("此單字本及所有單字將被永久刪除，無法復原。") }
    static var sortMenuTitle: String { L10n.string("排序方式") }
    static var sortAccessibilityLabel: String { L10n.string("排序") }
    static var exportFailure: String { L10n.string("匯出失敗") }
    static var exportEmpty: String { L10n.string("單字本沒有可匯出的單字") }
    static var allWordsExportEmpty: String { L10n.string("所有單字本沒有可匯出的單字") }
    static var reconcileErrorTitle: String { L10n.string("單字本同步失敗") }
    static var retryTitle: String { L10n.string("重試") }

    /// Settings 全部單字 CSV 匯出失敗的 toast 文案；空匯出必須用 all-words 範圍文案，不得沿用單本單字本的 exportEmpty。
    static func allWordsExportFailureMessage(for error: VocabularyExportError) -> String {
        switch error {
        case .empty: return allWordsExportEmpty
        case .writeFailed: return exportFailure
        }
    }

    static func emptyState(isLoggedIn: Bool) -> NotebookListEmptyStateCopy {
        if isLoggedIn {
            return .init(
                title: L10n.string("還沒有單字本"),
                description: L10n.string("建立第一本，開始整理你的單字"),
                actionTitle: L10n.string("建立第一本單字本"),
                actionSystemImage: "plus.circle.fill"
            )
        }
        return .init(
            title: L10n.string("還沒有單字本"),
            description: L10n.string("登入後自動建立預設單字本"),
            actionTitle: L10n.string("登入帳號"),
            actionSystemImage: "person.crop.circle"
        )
    }
}
#endif
