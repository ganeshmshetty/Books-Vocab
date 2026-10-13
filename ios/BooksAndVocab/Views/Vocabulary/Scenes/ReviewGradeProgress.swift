import Foundation

/// 複習 header 的進度（#3371）：已評數 / 總數。
///
/// 只由評分計數決定；瀏覽位置（‹ ›、autoplay）不參與，使用者才分得出「在評分」與「在瀏覽」。
/// 已評數 clamp 進 `0...total`，避免 queue 縮減後的殘留答案讓分子超過分母。
struct ReviewGradeProgress: Equatable {
    let graded: Int
    let total: Int

    init(graded: Int, total: Int) {
        let clampedTotal = max(total, 0)
        self.total = clampedTotal
        self.graded = min(max(graded, 0), clampedTotal)
    }

    var text: String { "\(graded) / \(total)" }
}

/// 已評卡片的標示（#3371）：revisit 已評的卡時顯示「已評：記得／忘記」。純值，不可互動。
struct ReviewGradedBadge: Equatable {
    let feedback: ReviewFeedback

    /// `todayReview.card.graded`（「已評：%@」）帶入既有的「記得」「忘記」譯文。
    var text: String {
        let grade = L10n.string(feedback == .remembered ? "記得" : "忘記")
        return L10n.format("todayReview.card.graded", grade)
    }

    /// 只有此卡已有評分結果時才有標示；未評分的卡回傳 nil。
    static func resolve(_ feedback: ReviewFeedback?) -> ReviewGradedBadge? {
        feedback.map { ReviewGradedBadge(feedback: $0) }
    }
}
