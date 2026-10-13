import Foundation
import Testing
@testable import BooksAndVocab

struct ReviewCardRenderPlanTests {
    private let all = ReviewCardContentAvailability(
        partOfSpeech: true,
        difficultyTier: true,
        example: true,
        explanation: true,
        collocations: true,
        graphLinks: true
    )

    @Test func defaults_preserve_the_phase_a_face_order() {
        let plan = ReviewCardRenderPlan.make(
            profile: .default,
            mode: .recognition,
            availability: all
        )
        #expect(plan.coreIsLocked)
        #expect(plan.front.fields == [.partOfSpeech])
        #expect(plan.back.fields == [.difficultyTier, .graphLinks, .example, .explanation, .collocations])
        // 詞性貼在核心詞的基線上，所以正面只剩核心那一列。
        #expect(plan.front.inlineFields == [.partOfSpeech])
        #expect(plan.front.blockFields.isEmpty)
        #expect(plan.front.rows == [.prompt])
        // 難度是詞的徽章，畫在答案字之上；其餘 block 欄位在答案之下。
        #expect(plan.back.aboveCore == [.difficultyTier])
        #expect(plan.back.belowCore == [.graphLinks, .example, .explanation, .collocations])
        #expect(plan.front.aboveCore.isEmpty)
        // 背面沒有 hairline：欄位之間的分隔只靠 spacing（layering，見 #3113）。
        #expect(plan.back.rows == [
            .field(.difficultyTier),
            .answer,
            .field(.graphLinks),
            .field(.example),
            .field(.explanation),
            .field(.collocations)
        ])
    }

    @Test("report AFTER keeps the complete back payload while a short front hugs content")
    func reportAfterKeepsCompleteBackPayloadWithoutBlankFrontCeiling() {
        let plan = ReviewCardRenderPlan.make(
            profile: .default,
            mode: .recognition,
            availability: all
        )
        let viewport = ReviewCardViewport(containerHeight: 767)
        let shortFront = viewport.frontDrawnHeight(solvedContentHeight: 86, chrome: 78)

        #expect(plan.back.fields == [.difficultyTier, .graphLinks, .example, .explanation, .collocations])
        #expect(shortFront == 164)
        #expect(shortFront < viewport.frontHeight)
        #expect(viewport.backHeight(frontOccupied: shortFront) == viewport.contentHeight - shortFront)
    }

    /// 版面自由度自 APP-20260808-7f0f3a 起塌縮成兩個 preset，所以這些測試不再
    /// 拿任意欄位陣列建 profile —— 它們驗的本來就是 availability 過濾與順序保留，
    /// 用 preset 產出的面一樣驗得到，而且不必為了測試保留一個沒人用得到的建構子。
    @Test func compact_preset_drops_the_three_long_form_fields() {
        let profile = ReviewCardLayoutProfile(recognition: .compact, production: .compact)
        let plan = ReviewCardRenderPlan.make(profile: profile, mode: .recognition, availability: all)

        #expect(plan.front.fields == [.partOfSpeech])
        #expect(plan.back.fields == [.difficultyTier, .graphLinks])
        // 詞性貼在核心詞的基線上，所以精簡正面同樣只有核心那一列。
        #expect(plan.front.inlineFields == [.partOfSpeech])
        #expect(plan.front.blockFields.isEmpty)
        #expect(plan.front.rows == [.prompt])
        // 難度仍是答案之上的徽章；答案底下只剩圖譜連結，沒有任何 hairline。
        #expect(plan.back.aboveCore == [.difficultyTier])
        #expect(plan.back.belowCore == [.graphLinks])
        #expect(plan.back.rows == [
            .field(.difficultyTier),
            .answer,
            .field(.graphLinks)
        ])
    }

    @Test func unavailable_optional_fields_are_filtered_per_face() {
        let plan = ReviewCardRenderPlan.make(
            profile: .default,
            mode: .recognition,
            availability: .init(partOfSpeech: false, difficultyTier: true, example: false, explanation: false, collocations: false, graphLinks: false)
        )

        #expect(plan.front.fields.isEmpty)
        #expect(plan.back.fields == [.difficultyTier])
        #expect(plan.front.rows == [.prompt])
        // 只剩難度時它在答案之上，而答案底下已無內容 —— 不畫那條懸空的線。
        #expect(plan.back.rows == [.field(.difficultyTier), .answer])
    }

    /// 產出方向的「正常」把例句同時放在正反面 —— 一個欄位可以在兩面都畫。
    @Test func a_field_can_render_on_both_faces() {
        let plan = ReviewCardRenderPlan.make(profile: .default, mode: .production, availability: .init(
            partOfSpeech: false,
            difficultyTier: false,
            example: true,
            explanation: false,
            collocations: false,
            graphLinks: false
        ))

        #expect(plan.front.fields == [.example])
        #expect(plan.back.fields == [.example])
        #expect(plan.front.rows == [.prompt, .field(.example)])
        #expect(plan.back.rows == [.answer, .field(.example)])
    }

    @Test func an_empty_back_face_draws_only_the_answer() {
        let plan = ReviewCardRenderPlan.make(profile: .default, mode: .recognition, availability: .init(
            partOfSpeech: false,
            difficultyTier: false,
            example: false,
            explanation: false,
            collocations: false,
            graphLinks: false
        ))

        #expect(plan.front.rows == [.prompt])
        #expect(plan.back.rows == [.answer])
    }

    /// 「畫在哪」是渲染的性質，不是 profile 的性質。恰好只有詞性是核心詞的附屬標註。
    @Test func part_of_speech_is_the_only_field_that_shares_the_core_row() {
        #expect(ReviewCardField.allCases.filter(\.rendersInlineWithCore) == [.partOfSpeech])
    }

    /// 重構後 solver 把詞性當一個獨立 section 計預算（fallback 22pt）並多收一個
    /// foldSectionSpacing，正面因此高出一列＋一個間距。這一則把省下來的量釘死。
    @Test func the_budget_no_longer_charges_a_section_for_an_inline_field() {
        let measurements: [ReviewCardLayoutSolver.Section: ReviewCardLayoutSolver.Measurement] = [
            .core: .init(naturalHeight: 112),
            .field(.partOfSpeech): .init(naturalHeight: 22)
        ]
        func solvedHeight(_ fields: [ReviewCardField]) -> CGFloat {
            ReviewCardLayoutSolver.solve(.init(
                face: .front,
                fields: fields,
                measurements: measurements,
                viewportHeight: 4000,
                minimumHeight: 0
            )).cardHeight
        }

        #expect(solvedHeight([.partOfSpeech]) - solvedHeight([])
            == 22 + TodayReviewMetrics.foldSectionSpacing)
        // 而渲染端交給 solver 的正是 blockFields，所以那 46pt 今天不再被收。
        let plan = ReviewCardRenderPlan.make(profile: .default, mode: .recognition, availability: all)
        #expect(plan.front.blockFields.isEmpty)
    }

    /// 挖空是「這一面還沒給答案」的性質，不是例句的性質。重構把 `mode: .cloze`
    /// 寫死在正反面共用的渲染點上，於是翻開後的背面仍然把目標詞挖掉＝答案只給一半。
    @Test func cloze_belongs_only_to_the_production_prompt() {
        #expect(ReviewCardExampleRendering.mode(face: .front, cardMode: .production) == .cloze)
        #expect(ReviewCardExampleRendering.mode(face: .back, cardMode: .production) == .highlight)
        #expect(ReviewCardExampleRendering.mode(face: .front, cardMode: .recognition) == .highlight)
        #expect(ReviewCardExampleRendering.mode(face: .back, cardMode: .recognition) == .highlight)
    }
}

struct ReviewCardLayoutSolverTests {
    private let fields: [ReviewCardField] = [.example, .explanation, .collocations, .graphLinks]

    private func input(
        height: CGFloat,
        preset: ReviewCardLayoutPreset = .compact
    ) -> ReviewCardLayoutSolver.Input {
        .init(
            fields: fields,
            measurements: [
                .core: .init(naturalHeight: 120, compactHeight: 120),
                .example: .init(naturalHeight: 100, compactHeight: 42),
                .explanation: .init(naturalHeight: 66, intermediateHeight: 44, compactHeight: 22),
                .collocations: .init(naturalHeight: 64, intermediateHeight: 48, compactHeight: 32),
                .graphLinks: .init(naturalHeight: 72, intermediateHeight: 48, compactHeight: 20)
            ],
            viewportHeight: height,
            chromeHeight: 0,
            minimumHeight: 80,
            sectionSpacing: 0,
            compactSectionSpacing: 0,
            preset: preset
        )
    }

    @Test func height_is_monotonic_and_minimum_does_not_stack_on_core() {
        let roomy = ReviewCardLayoutSolver.solve(input(height: 500))
        let constrained = ReviewCardLayoutSolver.solve(input(height: 280))

        #expect(roomy.cardHeight >= constrained.cardHeight)
        #expect(constrained.cardHeight <= 280)
        #expect(constrained.cardHeight >= 80)
        #expect(roomy.policy(for: .core).isVisible)
    }

    @Test func compacts_in_the_required_priority_order() {
        #expect(ReviewCardLayoutSolver.solve(input(height: 500)).policy(for: .explanation).lineLimit == nil)
        #expect(ReviewCardLayoutSolver.solve(input(height: 360)).policy(for: .example).exampleRadius == 3)
        #expect(ReviewCardLayoutSolver.solve(input(height: 360)).policy(for: .explanation).lineLimit == 2)
        #expect(ReviewCardLayoutSolver.solve(input(height: 320)).policy(for: .explanation).lineLimit == 1)
        #expect(ReviewCardLayoutSolver.solve(input(height: 310)).policy(for: .collocations).lineLimit == 2)
        #expect(ReviewCardLayoutSolver.solve(input(height: 290)).policy(for: .collocations).lineLimit == 1)
        #expect(ReviewCardLayoutSolver.solve(input(height: 270)).policy(for: .graphLinks).graphLinkPresentation == .onePerGroup)
        let graphSummary = ReviewCardLayoutSolver.solve(input(height: 260)).policy(for: .graphLinks)
        #expect(graphSummary.graphLinkPresentation == .summary)
        #expect(graphSummary.height == 20)
        #expect(ReviewCardLayoutSolver.solve(input(height: 220)).usesCompactSpacing)
    }

    @Test func standard_overflow_preserves_full_fields_and_exposes_scroll() {
        let result = ReviewCardLayoutSolver.solve(input(height: 300, preset: .standard))

        #expect(result.backPresentation == .scroll)
        #expect(!result.usesCompactSpacing)
        #expect(result.policy(for: .example).exampleRadius == nil)
        #expect(result.policy(for: .explanation).lineLimit == nil)
        #expect(result.policy(for: .collocations).lineLimit == nil)
        #expect(!result.policy(for: .collocations).summarizesOverflow)
        #expect(result.policy(for: .graphLinks).graphLinkPresentation == .twoPerGroup)
        #expect(!result.policy(for: .graphLinks).summarizesOverflow)
    }

    @Test func standard_fit_uses_the_natural_presentation_contract() {
        let result = ReviewCardLayoutSolver.solve(input(height: 500, preset: .standard))

        #expect(result.backPresentation == .natural)
    }

    @Test func standard_full_profile_selector_keeps_every_back_payload_field() {
        let profile = ReviewCardLayoutProfile(recognition: .standard, production: .standard)
        let plan = ReviewCardRenderPlan.make(
            profile: profile,
            mode: .recognition,
            availability: .init(
                partOfSpeech: true,
                difficultyTier: true,
                example: true,
                explanation: true,
                collocations: true,
                graphLinks: true
            )
        )

        #expect(plan.back.fields == [.difficultyTier, .graphLinks, .example, .explanation, .collocations])
        #expect(plan.back.rows.contains(.field(.graphLinks)))
        #expect(plan.back.rows.contains(.field(.example)))
        #expect(plan.back.rows.contains(.field(.explanation)))
        #expect(plan.back.rows.contains(.field(.collocations)))
    }

    @Test func compact_profile_is_the_only_summary_contract() {
        let standard = ReviewCardLayoutSolver.solve(input(height: 260, preset: .standard))
        let compact = ReviewCardLayoutSolver.solve(input(height: 260, preset: .compact))

        #expect(standard.backPresentation == .scroll)
        #expect(standard.policy(for: .graphLinks).graphLinkPresentation == .twoPerGroup)
        #expect(!standard.policy(for: .collocations).summarizesOverflow)
        #expect(compact.policy(for: .graphLinks).graphLinkPresentation == .summary)
        #expect(compact.policy(for: .graphLinks).summarizesOverflow)
    }

    @Test func standard_small_viewport_selector_keeps_full_payload_on_scroll_path() {
        let result = ReviewCardLayoutSolver.solve(input(height: 40, preset: .standard))

        #expect(result.backPresentation == .scroll)
        #expect(result.cardHeight == 80)
        #expect(result.policy(for: .example).isVisible)
        #expect(result.policy(for: .explanation).isVisible)
        #expect(result.policy(for: .collocations).isVisible)
        #expect(result.policy(for: .graphLinks).isVisible)
        #expect(result.policy(for: .example).exampleRadius == nil)
        #expect(result.policy(for: .explanation).lineLimit == nil)
        #expect(result.policy(for: .collocations).lineLimit == nil)
        #expect(result.policy(for: .graphLinks).graphLinkPresentation == .twoPerGroup)
    }

    @Test func large_text_measurements_keep_full_payload_on_scroll_path() {
        let result = ReviewCardLayoutSolver.solve(.init(
            fields: fields,
            measurements: [
                .core: .init(naturalHeight: 240, compactHeight: 80),
                .example: .init(naturalHeight: 210, compactHeight: 44),
                .explanation: .init(naturalHeight: 220, intermediateHeight: 100, compactHeight: 40),
                .collocations: .init(naturalHeight: 200, intermediateHeight: 100, compactHeight: 40),
                .graphLinks: .init(naturalHeight: 180, intermediateHeight: 90, compactHeight: 32)
            ],
            viewportHeight: 320,
            chromeHeight: 0,
            minimumHeight: 80,
            sectionSpacing: 0,
            compactSectionSpacing: 0,
            preset: .standard
        ))

        #expect(result.backPresentation == .scroll)
        #expect(result.policy(for: .core).height == 240)
        #expect(result.policy(for: .example).height == 210)
        #expect(result.policy(for: .explanation).height == 220)
        #expect(result.policy(for: .collocations).height == 200)
        #expect(result.policy(for: .graphLinks).height == 180)
        #expect(result.policy(for: .explanation).lineLimit == nil)
        #expect(result.policy(for: .collocations).lineLimit == nil)
        #expect(result.policy(for: .graphLinks).graphLinkPresentation == .twoPerGroup)
        #expect(!result.policy(for: .collocations).summarizesOverflow)
        #expect(!result.policy(for: .graphLinks).summarizesOverflow)
    }

    @Test func one_line_collocation_tier_caps_visible_pills_to_one() {
        #expect(ReviewCardLayoutSolver.visibleCollocationLimit(lineLimit: nil) == nil)
        #expect(ReviewCardLayoutSolver.visibleCollocationLimit(lineLimit: 2) == nil)
        #expect(ReviewCardLayoutSolver.visibleCollocationLimit(lineLimit: 1) == 1)
    }

    @Test func back_face_budget_subtracts_the_visible_front_face() {
        #expect(ReviewCardLayoutSolver.remainingHeight(viewport: 640, occupied: 180) == 460)
        #expect(ReviewCardLayoutSolver.remainingHeight(viewport: 120, occupied: 180) == 0)
    }

    @Test func compact_first_pass_still_requests_all_measurement_tiers() {
        #expect(ReviewCardLayoutSolver.missingMeasurementLevels(
            hasNatural: false,
            hasIntermediate: false,
            hasCompact: false
        ) == [.natural, .intermediate, .compact])
        #expect(ReviewCardLayoutSolver.missingMeasurementLevels(
            hasNatural: true,
            hasIntermediate: true,
            hasCompact: true
        ).isEmpty)
    }

    @Test func explanation_paragraphs_form_one_globally_limited_rich_text_field() {
        let paragraphs = [
            CardDocumentParagraph(inlines: [.text("first")]),
            CardDocumentParagraph(inlines: [.mark("second")])
        ]
        #expect(ReviewCardExplanationContent.rawMarkdown(from: paragraphs) == "first\n**second**")
    }

    @Test func tiny_viewport_exposes_scroll_instead_of_hiding_core() {
        let result = ReviewCardLayoutSolver.solve(input(height: 40))
        #expect(result.requiresScrollFallback)
        #expect(result.policy(for: .core).isVisible)
        #expect(result.cardHeight == 80)
    }

    @Test func measured_accessibility_height_triggers_scroll_fallback() {
        let result = ReviewCardLayoutSolver.solve(.init(
            fields: [],
            measurements: [.core: .init(naturalHeight: 360)],
            viewportHeight: 300,
            chromeHeight: 0,
            minimumHeight: 0,
            sectionSpacing: 0,
            compactSectionSpacing: 0,
            preset: .standard
        ))

        #expect(result.requiresScrollFallback)
        #expect(result.cardHeight == 300)
        #expect(result.policy(for: .core).height == 360)
    }

    @Test func compact_spacing_is_applied_per_section_gap() {
        let result = ReviewCardLayoutSolver.solve(.init(
            fields: [.example, .explanation],
            measurements: [
                .core: .init(naturalHeight: 120),
                .example: .init(naturalHeight: 100, compactHeight: 42),
                .explanation: .init(naturalHeight: 66, intermediateHeight: 44, compactHeight: 22)
            ],
            viewportHeight: 210,
            chromeHeight: 0,
            minimumHeight: 0,
            sectionSpacing: 24,
            compactSectionSpacing: 8,
            preset: .compact
        ))

        #expect(result.usesCompactSpacing)
        #expect(result.cardHeight == 200)
        #expect(!result.requiresScrollFallback)
    }

    @Test func front_and_back_select_the_same_semantic_section_spacing() {
        #expect(ReviewCardLayoutSolver.sectionSpacing(
            usesCompactSpacing: false,
            natural: 24,
            compact: 8
        ) == 24)
        #expect(ReviewCardLayoutSolver.sectionSpacing(
            usesCompactSpacing: true,
            natural: 24,
            compact: 8
        ) == 8)
    }

    /// Every section sits at its floor (natural == compact), so field compaction can
    /// absorb nothing and section spacing is the only variable left.
    private func spacingInput(
        fields: [ReviewCardField],
        viewportHeight: CGFloat,
        perSectionHeight: CGFloat = 40
    ) -> ReviewCardLayoutSolver.Input {
        let sections = [ReviewCardLayoutSolver.Section.core] + fields.map(ReviewCardLayoutSolver.Section.field)
        let measurements = Dictionary(uniqueKeysWithValues: sections.map { section in
            (section, ReviewCardLayoutSolver.Measurement(
                naturalHeight: perSectionHeight,
                compactHeight: perSectionHeight
            ))
        })
        return .init(
            fields: fields,
            measurements: measurements,
            viewportHeight: viewportHeight,
            chromeHeight: 0,
            minimumHeight: 0,
            sectionSpacing: 24,
            compactSectionSpacing: 8,
            preset: .compact
        )
    }

    @Test func result_publishes_the_exact_spacing_the_renderer_must_draw() {
        let roomy = ReviewCardLayoutSolver.solve(spacingInput(fields: [.example], viewportHeight: 500))
        #expect(!roomy.usesCompactSpacing)
        #expect(roomy.sectionSpacing == 24)

        let tight = ReviewCardLayoutSolver.solve(spacingInput(fields: [.example], viewportHeight: 100))
        #expect(tight.usesCompactSpacing)
        #expect(tight.sectionSpacing == 8)
        // 40 + 40 content plus the single 8pt gap the renderer is told to draw.
        #expect(tight.cardHeight == 88)
    }

    @Test func compact_spacing_saving_scales_with_the_gap_count() {
        let spacingDelta: CGFloat = 24 - 8

        // Two sections → one gap → the 24→8 delta is saved once (104 natural → 88).
        let oneGap = ReviewCardLayoutSolver.solve(spacingInput(fields: [.example], viewportHeight: 100))
        let oneGapNaturalHeight: CGFloat = 104
        #expect(oneGap.usesCompactSpacing)
        #expect(oneGapNaturalHeight - oneGap.cardHeight == spacingDelta * 1)

        // Four sections → three gaps → the same delta must save 3×, never a constant
        // (232 natural → 184). A fixed saving would land this at 216.
        let threeGaps = ReviewCardLayoutSolver.solve(
            spacingInput(fields: [.example, .explanation, .collocations], viewportHeight: 200)
        )
        let threeGapsNaturalHeight: CGFloat = 232
        #expect(threeGaps.usesCompactSpacing)
        #expect(threeGapsNaturalHeight - threeGaps.cardHeight == spacingDelta * 3)
    }

    @Test func presenter_front_slots_do_not_boot_from_the_back_face_minimum() {
        #expect(TodayReviewPresenter.initialFrontSlotHeight == 0)
        #expect(TodayReviewPresenter.initialFrontSlotHeight != TodayReviewMetrics.answerMinHeight)
    }

    @Test func non_active_slot_height_does_not_influence_active_shell_height() {
        #expect(ReviewCardLayoutSolver.activeShellHeight(
            heights: [600, 210, 700],
            activeIndex: 1
        ) == 210)
        #expect(ReviewCardLayoutSolver.activeShellHeight(
            heights: [600, 210, 700],
            activeIndex: nil
        ) == 0)
    }
}

/// The renderer and the solver must not be able to disagree about the card's own
/// chrome and gaps: whatever the view pads, the solver subtracts, from one token set.
struct ReviewCardChromeContractTests {

    @Test func face_chrome_matches_the_padding_the_renderer_draws() {
        #expect(ReviewCardChrome.padding == TodayReviewMetrics.foldPadding)
        #expect(ReviewCardChrome.extraTopInset(for: .back) == 0)
        #expect(ReviewCardChrome.extraTopInset(for: .front) == TodayReviewMetrics.foldHintBottomInset)

        for face in [ReviewCardFace.front, .back] {
            #expect(ReviewCardChrome.verticalInset(for: face)
                == ReviewCardChrome.padding * 2 + ReviewCardChrome.extraTopInset(for: face))
        }
    }

    @Test func front_budget_reserves_the_fold_hint_inset_the_renderer_draws() {
        func solved(_ face: ReviewCardFace) -> ReviewCardLayoutSolver.Result {
            ReviewCardLayoutSolver.solve(.init(
                face: face,
                fields: [.example, .explanation],
                measurements: [
                    .core: .init(naturalHeight: 200),
                    .example: .init(naturalHeight: 200),
                    .explanation: .init(naturalHeight: 200)
                ],
                viewportHeight: 300,
                minimumHeight: 0
            ))
        }

        let front = solved(.front)
        let back = solved(.back)
        #expect(front.cardHeight == 300 - ReviewCardChrome.verticalInset(for: .front))
        #expect(back.cardHeight == 300 - ReviewCardChrome.verticalInset(for: .back))
        #expect(back.cardHeight - front.cardHeight == TodayReviewMetrics.foldHintBottomInset)
    }

    @Test func face_bound_input_binds_the_tokens_the_renderer_draws() {
        let input = ReviewCardLayoutSolver.Input(
            face: .back,
            fields: [],
            measurements: [:],
            viewportHeight: 400,
            minimumHeight: 0
        )
        #expect(input.chromeHeight == ReviewCardChrome.verticalInset(for: .back))
        #expect(input.sectionSpacing == TodayReviewMetrics.foldSectionSpacing)
        #expect(input.compactSectionSpacing == TodayReviewMetrics.foldSectionSpacingCompact)
        // The compact tier stays a named token and keeps today's rendered value.
        #expect(TodayReviewMetrics.foldSectionSpacingCompact < TodayReviewMetrics.foldSectionSpacing)
        #expect(TodayReviewMetrics.foldSectionSpacingCompact == AppSpacing.s2)
    }
}
