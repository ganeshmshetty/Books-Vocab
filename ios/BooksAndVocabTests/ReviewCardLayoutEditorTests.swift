import Foundation
import SwiftUI
import Testing
@testable import BooksAndVocab

// MARK: - Editor field model

struct ReviewCardFieldOrderingTests {

    @Test func canonical_order_matches_the_agreed_row_order() {
        #expect(ReviewCardField.canonicalOrder == [
            .partOfSpeech, .difficultyTier, .graphLinks, .example, .explanation, .collocations
        ])
        #expect(Set(ReviewCardField.canonicalOrder) == Set(ReviewCardField.allCases))
    }

    /// preset 產出的每一面都必須落在 canonicalOrder 上 —— 編輯頁的預覽與卡片
    /// 讀的是同一個順序，順序漂掉就等於預覽在說謊。
    @Test func every_preset_face_is_already_in_canonical_order() {
        for preset in ReviewCardLayoutPreset.allCases {
            for mode in VocabularyCardMode.allCases {
                let layout = preset.layout(for: mode)
                #expect(layout.front == ReviewCardField.canonicalOrder.filter(layout.front.contains))
                #expect(layout.back == ReviewCardField.canonicalOrder.filter(layout.back.contains))
            }
        }
    }

    @Test func compact_is_a_strict_subset_of_standard_on_every_face() {
        for mode in VocabularyCardMode.allCases {
            let standard = ReviewCardLayoutPreset.standard.layout(for: mode)
            let compact = ReviewCardLayoutPreset.compact.layout(for: mode)
            #expect(Set(compact.front).isSubset(of: Set(standard.front)))
            #expect(Set(compact.back).isStrictSubset(of: Set(standard.back)))
            // 精簡的定義就是「拿掉例句、詳解、搭配詞」。
            #expect(!compact.front.contains(.example))
            #expect(Set(compact.back).isDisjoint(with: [.example, .explanation, .collocations]))
        }
    }

    /// 「畫在 core 之上」只有背面的難度徽章成立。canonicalOrder 排不了 field 與 core
    /// 的先後，所以這個規則必須自成一條，且不能被 face 混淆。
    @Test func only_the_back_difficulty_tier_renders_above_the_core_row() {
        #expect(ReviewCardField.rendersAboveCore(.difficultyTier, on: .back))
        #expect(!ReviewCardField.rendersAboveCore(.difficultyTier, on: .front))
        for field in ReviewCardField.allCases where field != .difficultyTier {
            #expect(!ReviewCardField.rendersAboveCore(field, on: .front))
            #expect(!ReviewCardField.rendersAboveCore(field, on: .back))
        }
    }

    @Test func splitting_a_face_keeps_both_halves_in_their_original_order() {
        let fields: [ReviewCardField] = [.graphLinks, .difficultyTier, .example, .explanation]

        let back = ReviewCardField.split(fields, on: .back)
        #expect(back.aboveCore == [.difficultyTier])
        #expect(back.belowCore == [.graphLinks, .example, .explanation])

        let front = ReviewCardField.split(fields, on: .front)
        #expect(front.aboveCore.isEmpty)
        #expect(front.belowCore == fields)
    }

    @Test func every_field_has_a_localizable_label_key() {
        let languages = AppLanguage.allCases.filter { $0.localizationCode != nil }
        for field in ReviewCardField.canonicalOrder {
            #expect(!field.titleKey.isEmpty)
            for language in languages {
                let value = L10n.string(field.titleKey, language: language)
                #expect(value != field.titleKey, "missing \(field.titleKey) in \(language.rawValue)")
                #expect(!value.isEmpty, "empty \(field.titleKey) in \(language.rawValue)")
            }
        }
        #expect(Set(ReviewCardField.canonicalOrder.map(\.titleKey)).count == ReviewCardField.allCases.count)
    }
}

// MARK: - Built-in preview sample card

/// 設定頁沒有「當前那張卡」時，預覽用的是程式內常數範例卡。它必須六個可選欄位
/// 全部備齊 —— `ReviewCardContentAvailability.forReviewCard` 會濾掉缺席的欄位，
/// 缺一個就會讓使用者切 preset 時預覽紋風不動，看起來像壞掉。
@MainActor
struct ReviewCardLayoutPreviewSampleTests {

    @Test func sample_card_has_every_optional_field_available() {
        for mode in VocabularyCardMode.allCases {
            let sample = ReviewCardLayoutPreviewCard.sampleCard(for: mode)
            let availability = ReviewCardContentAvailability.forReviewCard(
                partOfSpeech: sample.card.partOfSpeech,
                difficultyTier: sample.card.difficultyTier,
                exampleCount: sample.card.examples.count,
                explanationParagraphCount: sample.backDocument.meaningParagraphs().count,
                collocationCount: sample.card.collocations.count
            )

            for field in ReviewCardField.canonicalOrder {
                #expect(availability.contains(field), "範例卡缺了 \(field.rawValue)，預覽會對該欄位無反應")
            }
        }
    }

    @Test func sample_card_carries_the_mode_it_was_asked_for() {
        for mode in VocabularyCardMode.allCases {
            #expect(ReviewCardLayoutPreviewCard.sampleCard(for: mode).card.reviewMode == mode)
        }
    }
}

// MARK: - Review toolbar edit scope (#3124)

/// 複習頁工具列開的編輯器必須改「卡片實際在用的那份」：有 notebook override 的卡改 override，
/// 否則改全域。以前工具列永遠傳全域，有 override 的單字本上編輯等於沒作用。
struct ReviewCardLayoutEditScopeTests {

    private let notebookOverride = ReviewCardLayoutProfile(recognition: .compact, production: .compact)

    private func makeResolver(overriddenNotebookId: String?) -> NotebookSettingsResolver {
        NotebookSettingsResolver(
            globalReviewSettings: .default,
            globalCardLayout: .default,
            overrides: overriddenNotebookId.map {
                [$0: NotebookSettingsOverride(reviewPolicy: nil, cardLayout: notebookOverride)]
            } ?? [:]
        )
    }

    @Test func card_from_a_notebook_with_an_override_edits_that_override_not_the_global() {
        let resolver = makeResolver(overriddenNotebookId: "nb-overridden")

        #expect(resolver.cardLayoutEditScope(notebookId: "nb-overridden") == .notebook)
        #expect(resolver.resolve(notebookId: "nb-overridden").cardLayout == notebookOverride)
        #expect(notebookOverride != ReviewCardLayoutProfile.default)
    }

    @Test func card_from_a_notebook_without_an_override_edits_the_global_profile() {
        let resolver = makeResolver(overriddenNotebookId: "nb-overridden")

        #expect(resolver.cardLayoutEditScope(notebookId: "nb-plain") == .global)
    }
}

// MARK: - Editor ↔ store

@MainActor
struct ReviewCardLayoutEditorStoreTests {

    private func store() -> ReviewCardLayoutStore { .inMemory() }

    @Test func settings_and_review_read_the_same_shared_profile() {
        #expect(EnvironmentValues().reviewCardLayoutStore === ReviewCardLayoutStore.shared)
    }

    @Test func choosing_a_preset_persists_only_the_edited_direction() {
        let store = store()
        store.setPreset(.compact, for: .recognition)

        #expect(store.profile.recognition == .compact)
        #expect(store.profile.production == .standard)
        #expect(store.profile.layout(for: .recognition).back == [.difficultyTier, .graphLinks])
        #expect(store.profile.layout(for: .production) == ReviewCardLayoutPreset.standard.layout(for: .production))
    }

    @Test func reset_all_restores_both_directions() {
        let store = store()
        store.setPreset(.compact, for: .recognition)
        store.setPreset(.compact, for: .production)

        store.resetAll()

        #expect(store.profile == .default)
    }

    @Test func summary_names_the_shared_preset_and_falls_back_to_mixed() {
        #expect(ReviewCardLayoutSummary.titleKey(for: .default) == "settings.reviewCardLayout.standard")
        #expect(
            ReviewCardLayoutSummary.titleKey(
                for: .init(recognition: .compact, production: .compact)
            ) == "settings.reviewCardLayout.compact"
        )
        #expect(
            ReviewCardLayoutSummary.titleKey(
                for: .init(recognition: .standard, production: .compact)
            ) == "settings.reviewCardLayout.mixed"
        )
    }
}

// MARK: - Autoplay interruption

@MainActor
struct TodayReviewAutoplayInterruptionTests {

    private func controller() -> TodayReviewAutoplayController {
        TodayReviewAutoplayController(settingsStore: ReviewSettingsStore(previewSettings: .default))
    }

    @Test func opening_the_editor_pauses_a_running_autoplay() {
        let autoplay = controller()
        autoplay.togglePlayback(restartLoop: {})
        #expect(autoplay.isPlaying)
        #expect(!autoplay.isPaused)

        autoplay.pauseForInterruption()

        #expect(autoplay.isPlaying)
        #expect(autoplay.isPaused)
        #expect(!autoplay.isLoopActive)
    }

    @Test func the_pause_outlives_the_editor_and_never_starts_playback() {
        let stopped = controller()
        stopped.pauseForInterruption()
        #expect(!stopped.isPlaying)
        #expect(!stopped.isPaused)

        let running = controller()
        running.togglePlayback(restartLoop: {})
        running.pauseForInterruption()
        running.pauseForInterruption()
        #expect(running.isPaused)
    }
}
