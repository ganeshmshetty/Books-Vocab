import Foundation
import Testing
@testable import BooksAndVocab

struct ReviewCardLayoutGoldenTests {
    private struct Golden: Codable, Equatable {
        struct Face: Codable, Equatable {
            let rows: [String]
        }

        struct Mode: Codable, Equatable {
            let front: Face
            let back: Face
        }

        struct NaturalFace: Codable, Equatable {
            let explanationLineLimit: Int
            let collocationRowLimit: Int
            let naturalExampleRadius: Int?
        }

        struct NaturalTier: Codable, Equatable {
            let front: NaturalFace
            let back: NaturalFace
        }

        struct BackOverflow: Codable, Equatable {
            let presentation: String
            let exampleRadius: Int?
            let explanationLineLimit: Int?
            let collocationLineLimit: Int?
            let graphPresentation: String
            let summarizesOverflow: Bool
        }

        struct Viewport: Codable, Equatable {
            let containerHeight: Double
            let contentHeight: Double
            let revealZoneReserve: Double
            /// 天花板。
            let frontHeight: Double
            /// 一張只有核心列的卡實際畫多高（內容 86 + chrome 78）。它遠小於
            /// `frontHeight` 才是對的 —— 相等就代表正面又在瓜分卡片區。
            let frontDrawnHeightForShortContent: Double
        }

        let modes: [String: Mode]
        let naturalTier: NaturalTier
        let backOverflow: BackOverflow
        let viewport: Viewport
    }

    private let allContent = ReviewCardContentAvailability(
        partOfSpeech: true,
        difficultyTier: true,
        example: true,
        explanation: true,
        collocations: true,
        graphLinks: true
    )

    private var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Golden/review_card_layout.json")
    }

    @Test func default_layout_matches_review_card_layout_golden() throws {
        let data = try Data(contentsOf: goldenURL)
        let expected = try JSONDecoder().decode(Golden.self, from: data)
        let actual = makeSnapshot()
        let expectedText = String(data: data, encoding: .utf8) ?? "<unreadable>"
        let actualText = String(
            data: try JSONEncoder().encode(actual),
            encoding: .utf8
        ) ?? "<unreadable>"

        #expect(
            actual == expected,
            "review_card_layout golden mismatch. If this is an intentional visual change, update the golden and explain it in the commit message.\nexpected=\(expectedText)\nactual=\(actualText)"
        )
    }

    private func makeSnapshot() -> Golden {
        let modes: [String: Golden.Mode] = [
            "recognition": modeSnapshot(.recognition),
            "production": modeSnapshot(.production)
        ]
        let naturalTier = Golden.NaturalTier(
            front: .init(
                explanationLineLimit: ReviewCardLayoutSolver.explanationLineLimit(policyLineLimit: nil),
                collocationRowLimit: ReviewCardLayoutSolver.collocationRowLimit(lineLimit: nil),
                naturalExampleRadius: ReviewCardLayoutSolver.naturalExampleRadius(for: .front, staticRadius: 5)
            ),
            back: .init(
                explanationLineLimit: ReviewCardLayoutSolver.explanationLineLimit(policyLineLimit: nil),
                collocationRowLimit: ReviewCardLayoutSolver.collocationRowLimit(lineLimit: nil),
                naturalExampleRadius: ReviewCardLayoutSolver.naturalExampleRadius(for: .back, staticRadius: 5)
            )
        )
        let viewport = ReviewCardViewport(containerHeight: 600)
        return Golden(
            modes: modes,
            naturalTier: naturalTier,
            backOverflow: backOverflowSnapshot(),
            viewport: .init(
                containerHeight: Double(viewport.containerHeight),
                contentHeight: Double(viewport.contentHeight),
                revealZoneReserve: Double(viewport.revealZoneReserve),
                frontHeight: Double(viewport.frontHeight),
                frontDrawnHeightForShortContent: Double(
                    viewport.frontDrawnHeight(solvedContentHeight: 86, chrome: 78)
                )
            )
        )
    }

    private func backOverflowSnapshot() -> Golden.BackOverflow {
        let result = ReviewCardLayoutSolver.solve(.init(
            fields: [.example, .explanation, .collocations, .graphLinks],
            measurements: [
                .core: .init(naturalHeight: 100),
                .example: .init(naturalHeight: 80, compactHeight: 40),
                .explanation: .init(naturalHeight: 60, intermediateHeight: 40, compactHeight: 20),
                .collocations: .init(naturalHeight: 60, intermediateHeight: 40, compactHeight: 20),
                .graphLinks: .init(naturalHeight: 60, intermediateHeight: 40, compactHeight: 20)
            ],
            viewportHeight: 300,
            chromeHeight: 0,
            minimumHeight: 0,
            sectionSpacing: 0,
            compactSectionSpacing: 0,
            preset: .standard
        ))

        let graphPresentation: String = switch result.policy(for: .graphLinks).graphLinkPresentation {
        case .twoPerGroup: "twoPerGroup"
        case .onePerGroup: "onePerGroup"
        case .summary: "summary"
        case nil: "none"
        }
        let example = result.policy(for: .example)
        let explanation = result.policy(for: .explanation)
        let collocations = result.policy(for: .collocations)
        return .init(
            presentation: result.backPresentation == .scroll ? "scroll" : "natural",
            exampleRadius: example.exampleRadius,
            explanationLineLimit: explanation.lineLimit,
            collocationLineLimit: collocations.lineLimit,
            graphPresentation: graphPresentation,
            summarizesOverflow: collocations.summarizesOverflow
                || result.policy(for: .graphLinks).summarizesOverflow
        )
    }

    private func modeSnapshot(_ mode: VocabularyCardMode) -> Golden.Mode {
        let plan = ReviewCardRenderPlan.make(
            profile: .default,
            mode: mode,
            availability: allContent
        )
        return .init(
            front: .init(rows: plan.front.rows.map(rowName)),
            back: .init(rows: plan.back.rows.map(rowName))
        )
    }

    private func rowName(_ row: ReviewCardRenderPlan.Row) -> String {
        switch row {
        case .prompt: "prompt"
        case .answer: "answer"
        case .field(let field): "field.\(field.rawValue)"
        }
    }
}
