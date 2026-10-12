#if DEBUG && canImport(Playbook)
import Playbook
import SwiftUI

/// Catalog scenarios for Word Detail surface — WordDetailSheet (full presenter,
/// data-driven from UI World VocabularyEntry seeds) and CardDocumentView (the
/// reusable card body, rendered from the same seeded card presentation).
///
/// 不掛 backend / SwiftData container：WordDetailSheet 在 `.task` 內由
/// `entry.cardPresentation` 同步計算 presenter state；entry content 仍由
/// UI World manifest 擔任 SoT。
enum WordDetailScenarios {
    static func register(in playbook: Playbook) {
        // MARK: Word Detail Sheet
        playbook.addScenarios(of: "Word Detail · Sheet") {
            Scenario("Rich entry", layout: .fill) {
                MainActor.assumeIsolated {
                    AppThemeContainer {
                        // presentsEagerly: Catalog opens the scene synchronously
                        // and does not await WordDetailSheet's deferred presentation
                        // `.task`, so seed the card up front (otherwise the shot
                        // captures the "載入中" loading placeholder). Data still pins
                        // the `.wordDetail` QA seed (ephemeral entry).
                        WordDetailSheet(entry: Self.entry(.rich), allEntries: Self.entries(), presentsEagerly: true)
                    }
                    .environmentObject(AppAppearanceStore.preview)
                }
            }
            Scenario("Minimal entry", layout: .fill) {
                MainActor.assumeIsolated {
                    AppThemeContainer {
                        // presentsEagerly: same immediate-presentation seam as "Rich entry".
                        // Data still pins the `.wordDetail` QA seed (terse entry).
                        WordDetailSheet(entry: Self.entry(.minimal), allEntries: Self.entries(), presentsEagerly: true)
                    }
                    .environmentObject(AppAppearanceStore.preview)
                }
            }
            // Full-content inspection state. Renders the complete Word Detail card — definition,
            // pronunciation, example, related words — content-vertically pinned to
            // the top (unlike Today Review's fold, whose front card overlaps the
            // answer). Driven by `scenarioContext.wordDetail`: entries[0] is the
            // focused hero, the whole seed is `allEntries` so its graph links
            // resolve to real related cards.
            Scenario("Full Content", layout: .fill) {
                MainActor.assumeIsolated {
                    Self.fullContentSheet()
                }
            }
        }

        // MARK: Card Document
        playbook.addScenarios(of: "Word Detail · Card Document") {
            Scenario("Full", layout: .compressed) {
                MainActor.assumeIsolated {
                    cardSheet(document: Self.document(.rich), compact: false)
                }
            }
            Scenario("Compact", layout: .compressed) {
                MainActor.assumeIsolated {
                    cardSheet(document: Self.document(.rich), compact: true)
                }
            }
            Scenario("No example / collocations", layout: .compressed) {
                MainActor.assumeIsolated {
                    cardSheet(document: Self.document(.minimal), compact: false)
                }
            }
        }
    }

    // MARK: - Card sheet helper

    private static func cardSheet(document: CardDocument, compact: Bool) -> some View {
        let skin = AppSkin.previewNeutral
        return ScrollView {
            CardDocumentView(document: document, compact: compact)
                .padding(skin.metrics.cardBlockPadding)
        }
        .background(skin.palette.pageBackground.ignoresSafeArea())
        .appSkin(skin)
    }

    // MARK: - Fixtures

    private enum WordDetailFixture {
        case rich
        case minimal

        var word: String {
            switch self {
            case .rich:
                return "ephemeral"
            case .minimal:
                return "terse"
            }
        }
    }

    private static func seed() -> UIWorldVocabularySeed {
        FixtureDatasetStore.requireVocabularySeed(for: .wordDetail)
    }

    @MainActor
    private static func entries() -> [VocabularyEntry] {
        let seed = seed()
        return seed.entries.map {
            UITestFixtureSeed.makeVocabularyEntry(from: $0, notebookId: seed.notebookRemoteId)
        }
    }

    /// Materializes the structured Word Detail seed (`scenarioContext.wordDetail`)
    /// into `VocabularyEntry` models. `entries[0]` is the focused hero card; the
    /// rest are its graph-link targets, so `WordDetailSheet(allEntries:)` resolves
    /// the related-word links to real cards. Distinct from the `.wordDetail` QA
    /// seed (ephemeral/terse), which the QA scenarios keep pinning.
    @MainActor
    private static func fullContentEntries() -> [VocabularyEntry] {
        guard let seed = FixtureDatasetStore.scenarioContext()?.wordDetail else {
            preconditionFailure("scenarioContext.wordDetail is required for the Word Detail Full Content scenario")
        }
        precondition(
            !seed.entries.isEmpty,
            "scenarioContext.wordDetail must declare at least one entry (the focused hero card)"
        )
        return seed.entries.map {
            UITestFixtureSeed.makeVocabularyEntry(from: $0, notebookId: seed.notebookRemoteId)
        }
    }

    /// Hoisted so the `Scenario` closure stays a single expression (multi-statement
    /// closures inside `MainActor.assumeIsolated` break `Scenario` init overload
    /// resolution). `entries[0]` is the hero; the whole seed is `allEntries`.
    @MainActor
    private static func fullContentSheet() -> some View {
        let entries = fullContentEntries()
        return AppThemeContainer {
            // presentsEagerly: Catalog opens the scene synchronously and does not
            // await WordDetailSheet's deferred presentation `.task`, so seed the
            // card presentation up front (otherwise the first frame captures the
            // "載入中" loading placeholder).
            // showsLifecycleActions: false — 封存／刪除是卡片管理動作，不屬於
            // pure content inspection state；預設會連 destructive 色的刪除列一起
            // 顯示。頂列 chrome 保留
            //（不可改用 showsInlineChrome: false，那會連 chrome 一起關掉）。
            WordDetailSheet(
                entry: entries[0],
                allEntries: entries,
                showsLifecycleActions: false,
                presentsEagerly: true
            )
        }
        // Force light to keep the content-inspection state deterministic when the
        // Simulator itself is dark.
        .environment(\.colorScheme, .light)
        .environmentObject(AppAppearanceStore.preview)
    }

    @MainActor
    private static func entry(_ fixture: WordDetailFixture) -> VocabularyEntry {
        let matches = entries().filter { $0.word == fixture.word }
        precondition(
            matches.count == 1,
            "UI World vocabulary.wordDetail expected exactly one entry for \(fixture.word), got \(matches.count)"
        )
        return matches[0]
    }

    @MainActor
    private static func document(_ fixture: WordDetailFixture) -> CardDocument {
        entry(fixture).cardPresentation.document
    }
}
#endif
