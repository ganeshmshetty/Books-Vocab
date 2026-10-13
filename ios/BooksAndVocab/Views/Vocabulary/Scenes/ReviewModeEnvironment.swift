import SwiftUI

/// #2042 Stage 3：複習卡 ⋯ 選單的「切換辨識⇄產出」動作，經 SwiftUI Environment 注入，
/// 不改 `ReviewCardActions` 的建構處。nil（設定頁預覽／catalog）＝選單不出現切換項目；
/// `isAvailable == false`（已評分的目前卡）＝項目停用，避免切換後被 flush 覆寫。
struct ReviewModeSwitchAction: Sendable {
    let isAvailable: Bool
    let perform: @MainActor @Sendable () -> Void
}

private struct ReviewModeSwitchActionKey: EnvironmentKey {
    static let defaultValue: ReviewModeSwitchAction? = nil
}

extension EnvironmentValues {
    var reviewModeSwitchAction: ReviewModeSwitchAction? {
        get { self[ReviewModeSwitchActionKey.self] }
        set { self[ReviewModeSwitchActionKey.self] = newValue }
    }
}

extension VocabularyCardMode {
    /// 切換一次後的方向（辨識⇄產出）。選單、面板與狀態層共用這一個定義。
    var toggledReviewMode: VocabularyCardMode {
        self == .production ? .recognition : .production
    }

    /// 「切換為 …」文案的 key，`self` 為切換後的目標方向（選單與面板標題共用）。
    var switchTargetLabelKey: String {
        self == .production
            ? "todayReview.card.reviewMode.toProduction"
            : "todayReview.card.reviewMode.toRecognition"
    }
}
