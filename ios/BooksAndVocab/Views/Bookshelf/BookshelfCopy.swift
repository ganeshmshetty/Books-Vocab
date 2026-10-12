#if os(iOS)
import Foundation

struct BookshelfEmptyStateCopy: Equatable {
    let title: String
    let description: String
    let guidanceText: String
    let primaryActionTitle: String
    let loginActionTitle: String
    let demoActionTitle: String
}

enum BookshelfCopy {
    static var navigationTitle: String { L10n.string("書庫") }
    static var settingsAccessibilityLabel: String { L10n.string("設定") }
    static var syncAccessibilityLabel: String { L10n.string("同步") }
    static var importAccessibilityLabel: String { L10n.string("匯入") }
    static var confirmButtonTitle: String { L10n.string("確定") }
    static var unknownErrorTitle: String { L10n.string("未知錯誤") }
    static var readMoreTitle: String { L10n.string("了解更多") }
    static var readBookHint: String { L10n.string("點兩下開始閱讀") }
    static var deleteTitle: String { L10n.string("刪除") }
    static var retryImportTitle: String { L10n.string("再試匯入") }
    static var closeTitle: String { L10n.string("關閉") }

    /// 與可見標籤（BookCard）同一套四捨五入格式，避免 VoiceOver 讀到的百分比與畫面不一致。
    static func readingProgressAccessibilityValue(_ progression: Double?, locale: Locale = .current) -> String {
        ReadingProgressFormatter.percentText(progression ?? 0, locale: locale)
    }

    static var emptyState: BookshelfEmptyStateCopy {
        .init(
            title: L10n.string("尚無書籍"),
            description: L10n.string("匯入電子書開始閱讀（EPUB・TXT・MD・PDF）"),
            guidanceText: L10n.string("點擊上方匯入按鈕加入你的第一本書"),
            primaryActionTitle: L10n.string("匯入"),
            loginActionTitle: L10n.string("登入帳號"),
            demoActionTitle: L10n.string("體驗複習與圖譜")
        )
    }

    static func importErrorTitle(diagnosis: String?) -> String {
        diagnosis.map { L10n.format("匯入錯誤・%@", $0) } ?? L10n.string("匯入錯誤")
    }

    // 空書架 ≠ 真空：CloudKit 還原狀態線（CloudKitMirroringMonitor.phase）。
    static var cloudCheckingHint: String { L10n.string("正在確認 iCloud 書庫…") }
    static var cloudRestoringHint: String { L10n.string("正在從 iCloud 取回書庫…") }
    static func cloudSyncErrorHint(_ message: String) -> String {
        L10n.format("iCloud 書庫同步異常・%@", message)
    }
}
#endif
