#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import BooksAndVocab

/// #2044：「＋」新增連結的可點範圍放大到 44pt，但版面佔位必須等於 label 本身——
/// 否則連結區會被撐高，卡片高度與 solver 量到的 section 高度一起跳。
/// 可點範圍本身（accessibility frame ≥44pt）由 `TodayReviewAddLinkHitTargetUITests` 斷言。
@MainActor
struct ReviewCardHitTargetButtonTests {
    private let proposal = CGSize(width: 320, height: 320)

    private func fittingSize<V: View>(_ view: V) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: proposal)
    }

    private var plusGlyph: some View {
        Image(systemName: "plus").font(.system(size: 14, weight: .medium))
    }

    /// #3295：「+N」命中帶以渲染後的膠囊為基準上下各外擴 `linkOverflowHitBand`，不再用未量測的
    /// 膠囊高常數（舊值 24）。sub-default Dynamic Type 下膠囊實際高 < 24，舊推導讓外擴 > s1 而蓋到上一列。
    /// 這裡渲染 production 膠囊（XS 字級）、確認 band ≤ s1，且 band 不增加版面高度。
    @Test func link_overflow_hit_band_stays_within_the_row_gap_at_extra_small_type() {
        let capsule = ReviewCardLinkOverflowLabel(title: "+3", isExpanded: false)
            .environment(\.sizeCategory, .extraSmall)
        let bare = fittingSize(capsule)
        let wrapped = fittingSize(
            ReviewCardHitTargetButton(
                verticalBand: TodayReviewMetrics.linkOverflowHitBand,
                action: {},
                accessibilityIdentifier: "test.overflow"
            ) { capsule }
        )

        #expect(bare.height > 0)
        #expect(TodayReviewMetrics.linkOverflowHitBand <= AppSpacing.s1)
        #expect(wrapped == bare)
    }

    @Test func minimum_side_is_the_hig_hit_target() {
        #expect(TodayReviewMetrics.addLinkHitTarget >= 44)
    }

    @Test func icon_button_keeps_the_glyph_footprint() {
        let bare = fittingSize(plusGlyph)
        let wrapped = fittingSize(
            ReviewCardHitTargetButton(action: {}, accessibilityIdentifier: "test.plus") { plusGlyph }
        )
        #expect(bare.height > 0 && bare.height < TodayReviewMetrics.addLinkHitTarget, "positive control: glyph is smaller than the hit target")
        #expect(wrapped == bare)
    }

    @Test func text_prompt_keeps_its_single_line_footprint() {
        let prompt = HStack(spacing: 4) {
            Image(systemName: "plus").font(.system(size: 10))
            Text(verbatim: "Add link").font(.system(size: 12))
        }
        let bare = fittingSize(prompt)
        let wrapped = fittingSize(
            ReviewCardHitTargetButton(action: {}, accessibilityIdentifier: "test.prompt") { prompt }
        )
        #expect(bare.height < TodayReviewMetrics.addLinkHitTarget, "positive control: one caption line is shorter than the hit target")
        #expect(wrapped == bare)
    }

    /// The old shape — a bare `.frame(minWidth:minHeight:)` — is what the
    /// component exists to avoid: it reaches 44pt by growing the layout.
    @Test func naive_min_frame_would_grow_the_layout() {
        let naive = fittingSize(
            plusGlyph.frame(
                minWidth: TodayReviewMetrics.addLinkHitTarget,
                minHeight: TodayReviewMetrics.addLinkHitTarget
            )
        )
        #expect(naive.height >= TodayReviewMetrics.addLinkHitTarget)
        #expect(naive != fittingSize(plusGlyph))
    }
}
#endif
