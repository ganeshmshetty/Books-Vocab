#if os(iOS)
import Foundation

enum SettingsDeleteAccountCopy {
    static var deletingTitle: String { L10n.string("刪除中…") }
    static var deleteTitle: String { L10n.string("永久刪除帳號") }
    static var navigationTitle: String { L10n.string("確認刪除帳號") }
    static var cancelTitle: String { L10n.string("取消") }
    static var heroTitle: String { L10n.string("此操作不可復原") }
    static var heroDescription: String {
        L10n.string("刪除後將立即移除你的帳號、雲端生詞、閱讀進度、訂閱記錄。請仔細確認下列項目後才能繼續。")
    }
    static var consequencesTitle: String { L10n.string("將被永久刪除的資料") }
    static var acknowledgementsTitle: String { L10n.string("請確認你已知悉") }
    static var confirmationTitle: String { L10n.string("輸入確認字串") }

    static var consequenceRows: [(icon: String, text: String)] {
        [
            ("person.crop.circle", L10n.string("帳號資訊與登入記錄")),
            ("books.vertical", L10n.string("雲端生詞與筆記本")),
            ("point.3.connected.trianglepath.dotted", L10n.string("知識圖譜與關聯")),
            ("book.closed", L10n.string("閱讀進度與書架")),
            ("checkmark.seal", L10n.string("訂閱記錄（App Store 訂閱請另行至設定取消）"))
        ]
    }

    static var acknowledgementRows: [String] {
        [
            L10n.string("我了解所有資料將被永久刪除"),
            L10n.string("我了解此操作無法復原"),
            L10n.string("我了解資料一旦刪除即無法經由客服救回")
        ]
    }

    static func confirmationPrompt(phrase: String) -> String {
        L10n.format("為避免誤觸，請輸入 %@ 後繼續：", phrase)
    }

    static func deleteButtonTitle(
        isDeleting: Bool,
        countdownRemaining: Int,
        isReadyForCountdown: Bool
    ) -> String {
        if isDeleting {
            return deletingTitle
        }
        if countdownRemaining > 0 && isReadyForCountdown {
            return L10n.format("等候 %@ 秒…", "\(countdownRemaining)")
        }
        return deleteTitle
    }
}
#endif
