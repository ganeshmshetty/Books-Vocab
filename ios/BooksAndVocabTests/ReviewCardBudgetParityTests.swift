import Foundation
import SwiftUI
import Testing
@testable import BooksAndVocab

// MARK: - Viewport budget

/// The front face's budget is not the GeometryReader's height: the card region
/// pads itself, and the reveal affordance holds a hard floor BELOW the card for
/// the whole front stage. `ReviewCardViewport` owns that arithmetic once so the
/// solver's budget and the drawn clamp cannot disagree.
struct ReviewCardViewportTests {

    @Test func front_budget_excludes_the_outer_inset_and_the_reveal_zone() {
        let viewport = ReviewCardViewport(containerHeight: 600)
        let insets = TodayReviewMetrics.cardTopInset + TodayReviewMetrics.cardBottomInset

        #expect(viewport.contentHeight == 600 - insets)
        #expect(viewport.revealZoneReserve == TodayReviewMetrics.revealZoneMinHeight)
        #expect(viewport.frontHeight == 600 - insets - TodayReviewMetrics.revealZoneMinHeight)
        // The defect this pins: the raw container height must never reach the solver.
        #expect(viewport.frontHeight < viewport.containerHeight)
    }

    @Test func reveal_zone_reserve_follows_the_ratio_once_it_beats_the_floor() {
        // 1000 × 0.22 = 220 > 180 floor.
        #expect(ReviewCardViewport(containerHeight: 1000).revealZoneReserve == 220)
        // 400 × 0.22 = 88 < 180 floor → the floor wins, exactly as the zone draws it.
        #expect(ReviewCardViewport(containerHeight: 400).revealZoneReserve == TodayReviewMetrics.revealZoneMinHeight)
    }

    @Test func back_budget_starts_from_the_inset_content_height_not_the_container() {
        let viewport = ReviewCardViewport(containerHeight: 600)
        #expect(viewport.backHeight(frontOccupied: 200) == viewport.contentHeight - 200)
        #expect(viewport.backHeight(frontOccupied: 10_000) == 0)
    }

    @Test func a_viewport_shorter_than_its_own_chrome_never_reports_negative_room() {
        let viewport = ReviewCardViewport(containerHeight: 10)
        #expect(viewport.contentHeight == 0)
        #expect(viewport.frontHeight == 0)
        #expect(viewport.backHeight(frontOccupied: 0) == 0)
    }

    /// On a region too short for the 180pt floor the zone must give way, not
    /// starve the card: reserving the floor there would leave the front ~0pt.
    @Test func the_reveal_zone_never_takes_more_than_half_a_short_region() {
        let short = ReviewCardViewport(containerHeight: 300)
        #expect(short.revealZoneReserve == short.contentHeight / 2)
        #expect(short.frontHeight == short.contentHeight / 2)
        #expect(short.frontHeight > 0)
        // The cap is inactive at every normal portrait size.
        #expect(ReviewCardViewport(containerHeight: 600).revealZoneReserve
            == TodayReviewMetrics.revealZoneMinHeight)
    }

    /// `frontHeight` 是天花板，不是繪製高度。彈性 frame 給了 max 之後是**貪婪**的
    /// （回報 min(max, 父提案)），所以「只有一個單字」的正面照樣吃掉 VStack 提案的
    /// 一半，底下留 341pt 沒人用的空白。正面必須貼合已解出的內容。
    @Test func the_front_face_hugs_its_content_between_a_floor_and_the_budget() {
        let viewport = ReviewCardViewport(containerHeight: 767)
        let chrome = ReviewCardChrome.verticalInset(for: .front)

        // 短卡貼合：內容 86 + chrome 78 = 164，遠小於 frontHeight。
        #expect(viewport.frontDrawnHeight(solvedContentHeight: 86, chrome: 78) == 164)
        // 地板：內容縮到 0 也不會比 frontMinHeight 矮。
        #expect(viewport.frontDrawnHeight(solvedContentHeight: 0, chrome: 78)
            == TodayReviewMetrics.frontMinHeight)
        // 天花板：solver 的 scroll fallback 分支解出滿版時，行為與今天相同。
        #expect(viewport.frontDrawnHeight(solvedContentHeight: 10_000, chrome: chrome)
            == viewport.frontHeight)
        // 正面縮了，背面自動變大 —— 兩者共用同一份 contentHeight。
        let drawn = viewport.frontDrawnHeight(solvedContentHeight: 86, chrome: 78)
        #expect(viewport.backHeight(frontOccupied: drawn) == viewport.contentHeight - drawn)
    }

    /// The defect in one assertion. 600pt container: the honest front budget is
    /// 600 − 16 inset − 180 reveal zone − 78 front chrome = 326pt, while the raw
    /// height gives the solver 522pt. A face measuring 468pt therefore "fits" on
    /// the naive budget — the ladder never runs and the VStack pushes through the
    /// expand zone's floor — but must compact on the honest one.
    @Test func an_overfull_front_face_compacts_inside_the_honest_budget() {
        let viewport = ReviewCardViewport(containerHeight: 600)
        let measurements: [ReviewCardLayoutSolver.Section: ReviewCardLayoutSolver.Measurement] = [
            .core: .init(naturalHeight: 120),
            .example: .init(naturalHeight: 150, compactHeight: 60),
            .explanation: .init(naturalHeight: 150, intermediateHeight: 100, compactHeight: 50)
        ]
        func solve(_ height: CGFloat) -> ReviewCardLayoutSolver.Result {
            ReviewCardLayoutSolver.solve(.init(
                face: .front,
                fields: [.example, .explanation],
                measurements: measurements,
                viewportHeight: height,
                minimumHeight: 0,
                preset: .compact
            ))
        }

        let honest = solve(viewport.frontHeight)
        #expect(honest.policy(for: .example).exampleRadius == 3)
        #expect(honest.cardHeight <= viewport.frontHeight)

        let naive = solve(viewport.containerHeight)
        #expect(naive.policy(for: .example).exampleRadius == nil)
        #expect(naive.cardHeight > viewport.frontHeight)
    }
}

struct ReviewCardFrontMeasurementTests {

    @Test func same_height_card_identity_invalidates_geometry_measurement() {
        let first = ReviewCardFrontMeasurement(height: 240, cardKey: "first-card")
        let next = ReviewCardFrontMeasurement(height: 240, cardKey: "next-card")

        #expect(first.height == next.height)
        #expect(first != next)
    }

    @Test func same_height_section_identity_invalidates_geometry_measurement() {
        let first = ReviewCardSectionMeasurement(height: 40, cardKey: "first-card")
        let next = ReviewCardSectionMeasurement(height: 40, cardKey: "next-card")

        #expect(first.height == next.height)
        #expect(first != next)
    }

    @Test func a_previous_card_height_cannot_shrink_the_next_card_back_budget() {
        let viewport = ReviewCardViewport(containerHeight: 600)
        let occupied = ReviewCardViewport.frontOccupiedHeight(
            measuredCardKey: "long-production-card",
            currentCardKey: "short-recognition-card",
            measuredHeight: 420
        )

        #expect(occupied == 0)
        #expect(viewport.backHeight(frontOccupied: occupied) == viewport.contentHeight)
    }

    @Test func the_current_card_keeps_its_measured_front_height() {
        #expect(
            ReviewCardViewport.frontOccupiedHeight(
                measuredCardKey: "current-card",
                currentCardKey: "current-card",
                measuredHeight: 196
            ) == 196
        )
    }
}

// MARK: - Default parity

struct ReviewCardDefaultParityTests {

    @Test func graph_link_section_stays_available_on_a_card_with_no_links() {
        let availability = ReviewCardContentAvailability.forReviewCard(
            partOfSpeech: "n.",
            difficultyTier: nil,
            exampleCount: 0,
            explanationParagraphCount: 0,
            collocationCount: 0
        )
        // The add-link affordance is the only entry point for the first link, so
        // the section must survive an empty link set.
        #expect(availability.graphLinks)
        #expect(availability.partOfSpeech)
        #expect(!availability.difficultyTier)
        #expect(!availability.example)
        #expect(!availability.explanation)
        #expect(!availability.collocations)
    }

    @Test func the_default_back_face_keeps_every_section_of_a_bare_card() {
        let plan = ReviewCardRenderPlan.make(
            profile: .default,
            mode: .recognition,
            availability: .forReviewCard(
                partOfSpeech: nil,
                difficultyTier: nil,
                exampleCount: 0,
                explanationParagraphCount: 0,
                collocationCount: 0
            )
        )
        #expect(plan.back.fields == [.graphLinks])
    }

    /// The shipped picture is the old `compact: true` document: explanation clamped
    /// to 3 lines, collocations to 2 rows. Those are the NATURAL tier here, not an
    /// already-compacted one — otherwise the default card starts looser than today.
    @Test func natural_tier_reproduces_todays_compact_document_presentation() {
        #expect(ReviewCardLayoutSolver.explanationLineLimit(policyLineLimit: nil) == 3)
        #expect(ReviewCardLayoutSolver.explanationLineLimit(policyLineLimit: 2) == 2)
        #expect(ReviewCardLayoutSolver.explanationLineLimit(policyLineLimit: 1) == 1)

        #expect(ReviewCardLayoutSolver.collocationRowLimit(lineLimit: nil) == 2)
        #expect(ReviewCardLayoutSolver.collocationRowLimit(lineLimit: 2) == 2)
        #expect(ReviewCardLayoutSolver.collocationRowLimit(lineLimit: 1) == 1)
    }

    /// The back face used to expand the example into whatever space was free
    /// (`answerExampleRadius`, effectively "show the sentence"); the front kept the
    /// static skin radius. The solver replaces the budget maths, so natural back =
    /// no truncation, natural front = the same static radius as before.
    @Test func natural_example_radius_is_face_dependent() {
        #expect(ReviewCardLayoutSolver.naturalExampleRadius(for: .back, staticRadius: 5) == nil)
        #expect(ReviewCardLayoutSolver.naturalExampleRadius(for: .front, staticRadius: 5) == 5)
    }

    @Test func back_only_difficulty_stays_above_the_answer_without_a_rule() {
        // 難度搬到 core 之上後，「背面只開難度」底下已經沒有東西了。
        // 版面自 APP-20260808-7f0f3a 起只有兩個 preset，表達不了「背面只有難度」。
        // 精簡背面是 [.difficultyTier, .graphLinks]，把圖譜連結標成不可用即得到同一個面
        // —— 驗的本來就是 availability 過濾後的結果，不是 profile 能不能任意組合。
        let tierOnly = ReviewCardRenderPlan.make(
            profile: ReviewCardLayoutProfile(recognition: .compact, production: .compact),
            mode: .recognition,
            availability: .init(
                partOfSpeech: false,
                difficultyTier: true,
                example: false,
                explanation: false,
                collocations: false,
                graphLinks: false
            )
        )
        #expect(tierOnly.back.aboveCore == [.difficultyTier])
        #expect(tierOnly.back.rows == [.field(.difficultyTier), .answer])
    }

    /// 背面 hairline 全數移除（#3113，layering）：相鄰區塊只靠 spacing 分隔，solver
    /// 不再為任何線記帳。gap 數 = section 數 − 1，高度只剩內容與 spacing。
    @Test func back_face_has_no_hairlines_and_budget_charges_spacing_only() {
        let fields: [ReviewCardField] = [.example, .explanation, .collocations]
        let sections = [ReviewCardLayoutSolver.Section.core] + fields.map(ReviewCardLayoutSolver.Section.field)
        let measurements = Dictionary(uniqueKeysWithValues: sections.map {
            ($0, ReviewCardLayoutSolver.Measurement(naturalHeight: 40))
        })
        let input = ReviewCardLayoutSolver.Input(
            face: .back,
            fields: fields,
            measurements: measurements,
            viewportHeight: 4000,
            minimumHeight: 0
        )
        // 4 段內容 → 3 個 gap；沒有 rule 的高度與 gap。
        #expect(ReviewCardLayoutSolver.solve(input).cardHeight
            == 40 * 4 + TodayReviewMetrics.foldSectionSpacing * 3)
    }
}
