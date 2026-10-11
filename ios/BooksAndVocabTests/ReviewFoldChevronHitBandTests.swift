#if canImport(UIKit)
import Testing
@testable import BooksAndVocab

/// #3117：摺頁 chevron 的 44pt 命中帶不得侵入任何存活中的翻轉或內容命中區。
/// 命中帶的實際 accessibility frame 由 `TodayReviewGapUITests` 斷言；這裡釘住它的幾何與互斥條件。
@MainActor
struct ReviewFoldChevronHitBandTests {
    @Test func chevron_hit_target_is_the_hig_minimum() {
        #expect(TodayReviewMetrics.chevronHitTarget >= 44)
    }

    /// 命中帶以摺線為中心對稱展開，半高 = `chevronHitTarget / 2`。
    /// 正反面共用同一個 `ReviewCardChrome.padding`，半高不超過它，帶子就只落在空白 padding 內，
    /// 不會蓋到任何按鈕或文字。
    @Test func hit_band_reach_stays_inside_both_faces_padding() {
        let reach = TodayReviewMetrics.chevronHitTarget / 2
        #expect(
            reach <= ReviewCardChrome.padding,
            "命中帶半高 \(reach)pt 超過 padding \(ReviewCardChrome.padding)pt，會蓋到內容"
        )
    }

    /// 正控制：露出答案前翻轉可點、chevron 不可點。
    @Test func positive_control_flip_is_live_only_before_the_answer_shows() {
        #expect(ReviewFoldTapTargets.flipEnabled(showsAnswer: false, interactive: true))
        #expect(!ReviewFoldTapTargets.chevronEnabled(showsAnswer: false))
    }

    /// 命中帶與翻轉區不得同時存活：任一狀態下 chevron 可點時翻轉必然失效。
    @Test func chevron_band_and_flip_region_are_never_live_together() {
        for showsAnswer in [false, true] {
            for interactive in [false, true] {
                let chevronLive = ReviewFoldTapTargets.chevronEnabled(showsAnswer: showsAnswer)
                let flipLive = ReviewFoldTapTargets.flipEnabled(showsAnswer: showsAnswer, interactive: interactive)
                #expect(
                    !(chevronLive && flipLive),
                    "showsAnswer=\(showsAnswer) interactive=\(interactive) 時命中帶與翻轉同時存活"
                )
            }
        }
    }
}
#endif
