#if DEBUG
import Foundation
import Testing
@testable import BooksAndVocab

/// Contract gate for every named UI World under `ops/fixtures/ui_worlds/`.
///
/// `FixtureDatasetStore` is the UI World SoT. A broken dataset must be caught at
/// the contract boundary: each repo dataset must decode, carry a `datasetID`
/// matching its filename, and only key into fixture IDs that exist in the Swift
/// registries.
struct RepoFixtureDatasetsContractTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BooksAndVocabTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repo root
    }

    private static var datasetsDirectory: URL {
        // …/ios/BooksAndVocabTests/RepoFixtureDatasetsContractTests.swift → repo root
        Self.repoRoot
            .appendingPathComponent("ops/fixtures/ui_worlds", isDirectory: true)
    }

    private static func datasetURLs() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: datasetsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func generatedDemoTopLevel() throws -> [String: Any] {
        let url = datasetsDirectory
            .deletingLastPathComponent() // ui_worlds
            .deletingLastPathComponent() // fixtures
            .appendingPathComponent("demo/generated/ios_fixture_dataset.json")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func encodedGeneratedDemo(
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var topLevel = try generatedDemoTopLevel()
        try mutate(&topLevel)
        return try JSONSerialization.data(withJSONObject: topLevel)
    }

    /// Podcast fixture invariants (#2906): a preview can never be longer than its
    /// episode, and the runtime podcast clips pin the real length of the audio
    /// asset they point to (ffprobe: `podcast_demo_long.mp3` = 120.000 s,
    /// `podcast_demo.mp3` = 12.000 s).
    @Test func runtimePodcastEpisodeDurationsMatchClipsAndPreviewBounds() throws {
        let fixturesRoot = Self.datasetsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let urls = [
            Self.datasetsDirectory.appendingPathComponent("marketing_demo.json"),
            fixturesRoot.appendingPathComponent("demo/generated/ios_fixture_dataset.json"),
        ]
        let clipSeconds: [String: Double] = [
            "playablePreview": 120.0,
            "tieredCatalog": 12.0,
        ]

        for url in urls {
            let top = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let runtime = try #require(top["runtimePodcast"] as? [String: Any], "\(url.lastPathComponent): runtimePodcast")
            for (fixtureID, value) in runtime {
                let series = try #require(value as? [String: Any])
                let episodes = try #require(series["episodes"] as? [[String: Any]])
                for episode in episodes {
                    let remoteID = episode["remoteId"] as? String ?? "?"
                    let durationSec = try #require(episode["durationSec"] as? Double, "\(remoteID) durationSec")
                    if episode["previewAvailable"] as? Bool == true {
                        let previewSec = try #require(episode["previewDurationSec"] as? Double, "\(remoteID) previewDurationSec")
                        #expect(previewSec > 0 && previewSec <= durationSec,
                                "\(url.lastPathComponent) \(remoteID): previewDurationSec \(previewSec) must be within durationSec \(durationSec)")
                    }
                    if episode["audioAvailable"] as? Bool == true {
                        // Fail closed on a renamed runtime key: a missing clip pin must not skip the check.
                        let clip = try #require(clipSeconds[fixtureID], "\(url.lastPathComponent) \(fixtureID): no pinned clip length")
                        #expect(abs(durationSec - clip) < 0.05,
                                "\(url.lastPathComponent) \(remoteID): durationSec \(durationSec) must match clip length \(clip)")
                    }
                }
            }
        }
    }

    @Test func repoContainsAtLeastOneDataset() throws {
        #expect(try !Self.datasetURLs().isEmpty)
    }

    @Test func generatedDemoDatasetDecodes() throws {
        let url = Self.datasetsDirectory
            .deletingLastPathComponent() // ui_worlds
            .deletingLastPathComponent() // fixtures
            .appendingPathComponent("demo/generated/ios_fixture_dataset.json")
        let data = try Data(contentsOf: url)
        let document = try FixtureDatasetStore.decode(data)
        let topLevel = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(document.schema == "kg.fixture.dataset.v2")
        #expect(document.datasetID == "demo-demo-user")
        #expect(!document.assets.books.isEmpty)
        #expect(!document.assets.audio.isEmpty)
        #expect(!document.assets.subtitles.isEmpty)
        #expect(document.auth["signedIn"]?.isLoggedIn == true)
        #expect(document.auth["signedIn"]?.keychainTokenState == .available)
        #expect(document.entitlements["pro"]?.pro.is_active == true)
        // FROZEN 2026-08-05 — 這四行與下方 syncPresenter 那行，凍結前是雙向 `==`
        // （generated world 必須等於 allCases），那是「加一個 FixtureID 就得回填
        // world」的稅源。現只驗單向 isSubset：world 不得含 app 不認識的 key。
        // 每行都配一個 non-empty 正控——沒有正控的 subset 對空集合恆真（假綠）。
        // 復業第一步＝改回 `==`；完整配方見 docs/reference/catalog_scope.md §FROZEN。
        #expect(!document.bookshelf.isEmpty)
        #expect(Set(document.bookshelf.keys).isSubset(of: Set(BookshelfFixtureID.allCases.map(\.rawValue))))
        #expect(!document.podcast.isEmpty)
        #expect(Set(document.podcast.keys).isSubset(of: Set(PodcastFixtureID.allCases.map(\.rawValue))))
        #expect(!document.runtimePodcast.isEmpty)
        #expect(Set(document.runtimePodcast.keys).isSubset(of: Set(UIWorldRuntimePodcastFixtureID.allCases.map(\.rawValue))))
        #expect(!document.todayReview.isEmpty)
        #expect(Set(document.todayReview.keys).isSubset(of: Set(TodayReviewFixtureID.allCases.map(\.rawValue))))
        #expect(document.settings["preferences_auto_sync_off"] != nil)
        #expect(document.settings["preferences_logged_out_no_sync"] != nil)
        #expect(document.settings["subscription_free"]?.reviewSettings != nil)
        #expect(document.settings["preferences_auto_sync_off"]?.reviewSettings != nil)
        #expect(document.settings["account_long_identity"]?.reviewSettings != nil)
        #expect(document.settings["preferences_logged_out_no_sync"]?.reviewSettings != nil)
        // FROZEN 2026-08-05（同上）— 見 docs/reference/catalog_scope.md §FROZEN。
        #expect(!document.syncPresenter.isEmpty)
        #expect(Set(document.syncPresenter.keys).isSubset(of: Set(UIWorldSyncPresenterFixtureID.allCases.map(\.rawValue))))

        // Canonical scenario context carries one clock, surface contracts, and
        // reusable Reader/Word Detail content.
        let scenario = try #require(document.scenarioContext, "generated demo must declare scenarioContext")
        let reviewClock = try #require(scenario.reviewClock, "generated demo must declare reviewClock")
        let clock = try Self.requireCanonicalClock(reviewClock)
        #expect(clock.provenance == ReviewCalendarClock.historyPlanSource)
        #expect(clock.dayKey(for: clock.now) == reviewClock.anchorDay)
        let surfaceContracts = try #require(
            scenario.surfaceContracts,
            "canonical scenarioContext must declare surfaceContracts"
        )
        #expect(surfaceContracts["explore"]?.required.isEmpty == false)
        #expect(surfaceContracts["settings"]?.required.isEmpty == false)
        let passage = try #require(scenario.readerPassage, "scenarioContext must declare readerPassage")
        #expect(!passage.paragraphs.isEmpty)
        #expect(passage.activeWords == [passage.activeWord])
        // The active word must appear as a token in the passage (punctuation-trimmed).
        let passageTokens = Set(passage.paragraphs.flatMap { $0.split(separator: " ") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\u{201C}\u{201D}\u{2018}\u{2019}\"'")) })
        #expect(passageTokens.contains(passage.activeWord), "active word must appear as a token in readerPassage")
        let wordDetail = try #require(scenario.wordDetail, "scenarioContext must declare wordDetail")
        #expect(wordDetail.entries.first?.word == passage.activeWord, "wordDetail hero must match the reader passage active word")

        try expectValidAssetManifest(document: document, dataset: "ios_fixture_dataset")
        expectUniqueInstallPaths(document: document, dataset: "ios_fixture_dataset")
        expectSettingsKeys(topLevel, dataset: "ios_fixture_dataset")
        expectEntitlementsKeys(topLevel, dataset: "ios_fixture_dataset")
        expectTodayReviewKeys(topLevel, dataset: "ios_fixture_dataset")
        expectRuntimePodcastAssetRefs(document: document, dataset: "ios_fixture_dataset")
    }

    @Test func committedExploreDatasetsUseTopLevelSharedDecksContract() throws {
        let expectedFixtureIDs = Set(UIWorldExploreFixtureID.allCases.map(\.rawValue))
        let expectedRequiredDeckIDs = Set(["deck_official_gre_high_freq"])
        let expectedCounterexampleDeckIDs = Set(["deck_counterexample_retry"])
        let expectedRequiredAssetIDs = Set([
            "images.explore_required",
            "images.explore_required_empty",
        ])
        let expectedCounterexampleAssetIDs = Set([
            "images.explore_counterexample_empty",
            "images.explore_counterexample_retry",
        ])

        let urls = [
            Self.datasetsDirectory.appendingPathComponent("marketing_demo.json"),
            Self.datasetsDirectory
                .deletingLastPathComponent() // ui_worlds
                .deletingLastPathComponent() // fixtures
                .appendingPathComponent("demo/generated/ios_fixture_dataset.json"),
        ]

        for url in urls {
            let data = try Data(contentsOf: url)
            let document = try FixtureDatasetStore.decode(data)
            let catalog = document.sharedDecks

            #expect(Set(catalog.fixtures.keys) == expectedFixtureIDs)
            #expect(catalog.requiredFixtureLabels == UIWorldExploreFixtureID.required.map(\.label))
            #expect(catalog.counterexampleFixtureLabels == UIWorldExploreFixtureID.counterexamples.map(\.label))
            #expect(catalog.requiredDeckIDs == expectedRequiredDeckIDs)
            #expect(catalog.counterexampleDeckIDs == expectedCounterexampleDeckIDs)
            #expect(catalog.requiredAssetIDs == expectedRequiredAssetIDs)
            #expect(catalog.counterexampleAssetIDs == expectedCounterexampleAssetIDs)

            let loaded = try #require(catalog.fixtures[UIWorldExploreFixtureID.loaded.rawValue])
            #expect(loaded.phase == .loaded)
            #expect(loaded.deckIDs == ["deck_official_gre_high_freq"])
            #expect(loaded.assetIDs == ["images.explore_required"])

            let emptyCounterexample = try #require(
                catalog.fixtures[UIWorldExploreFixtureID.emptyCounterexample.rawValue]
            )
            #expect(emptyCounterexample.phase == .empty)
            #expect(emptyCounterexample.deckIDs.isEmpty)
            #expect(emptyCounterexample.assetIDs == ["images.explore_counterexample_empty"])

            let requiredDeck = try #require(catalog.deck(for: "deck_official_gre_high_freq"))
            #expect(requiredDeck.assetID == "images.explore_required")
            #expect(requiredDeck.title.count >= 80)
            #expect(requiredDeck.title.contains("🧭"))
            #expect(requiredDeck.title.unicodeScalars.contains { scalar in
                (0x0590...0x08FF).contains(Int(scalar.value))
            })
        }
    }

    @Test func legacyScenarioContextShapesRemainReadable() throws {
        let url = Self.datasetsDirectory
            .deletingLastPathComponent() // ui_worlds
            .deletingLastPathComponent() // fixtures
            .appendingPathComponent("demo/generated/ios_fixture_dataset.json")
        let data = try Data(contentsOf: url)
        var topLevel = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var context = try #require(topLevel["scenarioContext"] as? [String: Any])
        context.removeValue(forKey: "surfaceContracts")
        context["reviewClock"] = NSNull()
        topLevel["scenarioContext"] = context
        let nullClockData = try JSONSerialization.data(withJSONObject: topLevel)
        _ = try FixtureDatasetStore.decode(nullClockData)

        context["reviewClock"] = [
            "frozenNow": "2026-06-15T23:59:59Z",
            "frozenEpoch": 1781567999,
            "anchorDay": "2026-06-15",
            "source": "legacy.fixture",
        ]
        topLevel["scenarioContext"] = context
        let frozenNowData = try JSONSerialization.data(withJSONObject: topLevel)
        let legacyDocument = try FixtureDatasetStore.decode(frozenNowData)
        #expect(legacyDocument.scenarioContext?.reviewClock?.frozenNow == "2026-06-15T23:59:59Z")
    }

    @Test func legacyScenarioContextRequiresReaderAndWordDetailWithCompatibleClocks() throws {
        let clocks: [Any] = [
            NSNull(),
            [
                "frozenNow": "2026-06-15T23:59:59Z",
                "frozenEpoch": 1781567999,
                "anchorDay": "2026-06-15",
                "source": "legacy.fixture",
            ] as [String: Any],
        ]

        for missingField in ["readerPassage", "wordDetail"] {
            for clock in clocks {
                let data = try Self.encodedGeneratedDemo { topLevel in
                    var context = try #require(topLevel["scenarioContext"] as? [String: Any])
                    context.removeValue(forKey: "surfaceContracts")
                    context["reviewClock"] = clock
                    context[missingField] = NSNull()
                    topLevel["scenarioContext"] = context
                }
                #expect(throws: (any Error).self) {
                    try FixtureDatasetStore.decode(data)
                }
            }
        }
    }

    @Test func canonicalScenarioContextRejectsPartialAndMixedShapes() throws {
        for missingField in ["surfaceContracts"] {
            let data = try Self.encodedGeneratedDemo { topLevel in
                var context = try #require(topLevel["scenarioContext"] as? [String: Any])
                context.removeValue(forKey: missingField)
                topLevel["scenarioContext"] = context
            }
            #expect(throws: (any Error).self) {
                try FixtureDatasetStore.decode(data)
            }
        }

        let mixedData = try Self.encodedGeneratedDemo { topLevel in
            var context = try #require(topLevel["scenarioContext"] as? [String: Any])
            context["reviewClock"] = [
                "frozenNow": "2026-06-15T23:59:59Z",
                "frozenEpoch": 1781567999,
                "anchorDay": "2026-06-15",
                "source": "legacy.fixture",
            ] as [String: Any]
            topLevel["scenarioContext"] = context
        }
        #expect(throws: (any Error).self) {
            try FixtureDatasetStore.decode(mixedData)
        }
    }

    @Test func canonicalSurfaceContractsRejectDuplicateRowsAndUnknownAssets() throws {
        let duplicateRowData = try Self.encodedGeneratedDemo { topLevel in
            var context = try #require(topLevel["scenarioContext"] as? [String: Any])
            var contracts = try #require(context["surfaceContracts"] as? [String: Any])
            var explore = try #require(contracts["explore"] as? [String: Any])
            var required = try #require(explore["required"] as? [[String: Any]])
            required.append(try #require(required.first))
            explore["required"] = required
            contracts["explore"] = explore
            context["surfaceContracts"] = contracts
            topLevel["scenarioContext"] = context
        }
        #expect(throws: (any Error).self) {
            try FixtureDatasetStore.decode(duplicateRowData)
        }

        let unknownAssetData = try Self.encodedGeneratedDemo { topLevel in
            var context = try #require(topLevel["scenarioContext"] as? [String: Any])
            var contracts = try #require(context["surfaceContracts"] as? [String: Any])
            var explore = try #require(contracts["explore"] as? [String: Any])
            var required = try #require(explore["required"] as? [[String: Any]])
            required[0]["assetIDs"] = ["missing_asset"]
            explore["required"] = required
            contracts["explore"] = explore
            context["surfaceContracts"] = contracts
            topLevel["scenarioContext"] = context
        }
        #expect(throws: (any Error).self) {
            try FixtureDatasetStore.decode(unknownAssetData)
        }
    }

    @Test func canonicalExploreSurfaceContractsRejectExistingAssetProjectionMismatch() throws {
        let existingButWrongAssetData = try Self.encodedGeneratedDemo { topLevel in
            var context = try #require(topLevel["scenarioContext"] as? [String: Any])
            var contracts = try #require(context["surfaceContracts"] as? [String: Any])
            var explore = try #require(contracts["explore"] as? [String: Any])
            var required = try #require(explore["required"] as? [[String: Any]])
            // This asset exists in the manifest and is valid for another
            // Explore projection row. ID existence alone must not make this
            // scenarioContext projection acceptable.
            required[0]["assetIDs"] = ["explore_required_empty"]
            explore["required"] = required
            contracts["explore"] = explore
            context["surfaceContracts"] = contracts
            topLevel["scenarioContext"] = context
        }

        #expect(throws: (any Error).self) {
            try FixtureDatasetStore.decode(existingButWrongAssetData)
        }
    }

    @Test func canonicalAssetManifestRejectsEmptyKeysAndCrossTypeDuplicateIDs() throws {
        let emptyKeyData = try Self.encodedGeneratedDemo { topLevel in
            var assets = try #require(topLevel["assets"] as? [String: Any])
            var images = try #require(assets["images"] as? [String: Any])
            var asset = try #require(images["notebook_cover_app_icon"] as? [String: Any])
            asset["installAs"] = "Assets/empty-key.png"
            images["   "] = asset
            assets["images"] = images
            topLevel["assets"] = assets
        }
        #expect(throws: (any Error).self) {
            try FixtureDatasetStore.decode(emptyKeyData)
        }

        let duplicateIDData = try Self.encodedGeneratedDemo { topLevel in
            var assets = try #require(topLevel["assets"] as? [String: Any])
            var images = try #require(assets["images"] as? [String: Any])
            let asset = try #require(images["notebook_cover_app_icon"] as? [String: Any])
            images["catalog_reader_epub"] = asset
            assets["images"] = images
            topLevel["assets"] = assets
        }
        #expect(throws: (any Error).self) {
            try FixtureDatasetStore.decode(duplicateIDData)
        }
    }

    @Test func canonicalSurfaceContractsRejectEmptyAndUnknownAssetValues() throws {
        let emptyAssetIDData = try Self.encodedGeneratedDemo { topLevel in
            var context = try #require(topLevel["scenarioContext"] as? [String: Any])
            var contracts = try #require(context["surfaceContracts"] as? [String: Any])
            var explore = try #require(contracts["explore"] as? [String: Any])
            var required = try #require(explore["required"] as? [[String: Any]])
            required[0]["assetIDs"] = [""]
            explore["required"] = required
            contracts["explore"] = explore
            context["surfaceContracts"] = contracts
            topLevel["scenarioContext"] = context
        }
        #expect(throws: (any Error).self) {
            try FixtureDatasetStore.decode(emptyAssetIDData)
        }

        let unknownAssetData = try Self.encodedGeneratedDemo { topLevel in
            var context = try #require(topLevel["scenarioContext"] as? [String: Any])
            var contracts = try #require(context["surfaceContracts"] as? [String: Any])
            var explore = try #require(contracts["explore"] as? [String: Any])
            var required = try #require(explore["required"] as? [[String: Any]])
            required[0]["assetIDs"] = ["missing_asset"]
            explore["required"] = required
            contracts["explore"] = explore
            context["surfaceContracts"] = contracts
            topLevel["scenarioContext"] = context
        }
        #expect(throws: (any Error).self) {
            try FixtureDatasetStore.decode(unknownAssetData)
        }
    }

    @Test func canonicalReviewHistoryRejectsDatesAfterReviewClockNow() throws {
        let data = try Self.encodedGeneratedDemo { topLevel in
            var vocabulary = try #require(topLevel["vocabulary"] as? [String: Any])
            var seed = try #require(vocabulary["reviewCalendarDense"] as? [String: Any])
            var history = try #require(seed["reviewHistory"] as? [[String: Any]])
            history[0]["reviewedAt"] = "2026-07-11T00:00:00Z"
            seed["reviewHistory"] = history
            vocabulary["reviewCalendarDense"] = seed
            topLevel["vocabulary"] = vocabulary
        }
        #expect(throws: (any Error).self) {
            try FixtureDatasetStore.decode(data)
        }
    }

    @Test func emittedAndCommittedReviewCalendarSeedsMatchHistoryPlanGeometry() throws {
        let generatedURL = Self.repoRoot
            .appendingPathComponent("ops/demo/generated/ios_fixture_dataset.json")
        let marketingURL = Self.datasetsDirectory.appendingPathComponent("marketing_demo.json")
        let generated = try FixtureDatasetStore.decode(Data(contentsOf: generatedURL))
        let marketing = try FixtureDatasetStore.decode(Data(contentsOf: marketingURL))
        let generatedClock = try #require(generated.scenarioContext?.reviewClock)
        let marketingClock = try #require(marketing.scenarioContext?.reviewClock)
        let clock = try Self.requireCanonicalClock(generatedClock)
        let dense = try #require(generated.vocabulary[UIWorldVocabularyFixtureID.reviewCalendarDense.rawValue])
        let committedDense = try #require(marketing.vocabulary[UIWorldVocabularyFixtureID.reviewCalendarDense.rawValue])
        let planData = try Data(contentsOf: Self.repoRoot
            .appendingPathComponent("ops/demo/ui_world_seed/history_plan.json"))
        let plan = try #require(try JSONSerialization.jsonObject(with: planData) as? [String: Any])
        let eventHours = try #require(plan["event_utc_hours"] as? [Int])
        let expectedCurrent = try #require(plan["current_streak_days"] as? Int)
        let expectedLongest = try #require(plan["longest_streak_days"] as? Int)
        let expectedDue = try #require(plan["due_at_anchor"] as? [String: Any])
        let expectedPrimaryDue = try #require(expectedDue["primary"] as? Int)
        let boundary = try #require(plan["review_calendar_boundary_event"] as? [String: Any])
        let boundaryWord = try #require(boundary["word"] as? String)
        let boundaryFeedback = try #require(boundary["feedback"] as? Int)
        let boundaryReviewedAtText = try #require(boundary["reviewedAt"] as? String)
        let boundaryReviewedAt = try #require(
            ISO8601DateFormatter().date(from: boundaryReviewedAtText)
        )
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!

        #expect(generatedClock == marketingClock)
        #expect(dense == committedDense)
        #expect(!dense.reviewHistory.isEmpty)
        #expect(dense.reviewHistory.allSatisfy { event in
            let isBoundary = event.word == boundaryWord
                && event.feedback == boundaryFeedback
                && event.reviewedAt == boundaryReviewedAt
            if isBoundary { return true }
            let hour = utcCalendar.component(.hour, from: event.reviewedAt)
            return eventHours[0] <= hour && hour <= eventHours[1]
        }, "emitted dense history must use history_plan.event_utc_hours")

        var dayCounts: [String: Int] = [:]
        for event in dense.reviewHistory {
            let key = clock.dayKey(for: event.reviewedAt)
            dayCounts[key, default: 0] += 1
        }
        let anchor = try #require(generatedClock.anchorDay)
        var current = 0
        var cursor = try #require(Self.date(forDayKey: anchor, clock: clock))
        while dayCounts[clock.dayKey(for: cursor), default: 0] > 0 {
            current += 1
            guard let previous = clock.calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        let sortedDates = dayCounts.keys.compactMap { Self.date(forDayKey: $0, clock: clock) }.sorted()
        var longest = 0
        var run = 0
        if let first = sortedDates.first, let last = sortedDates.last {
            var day = first
            while day <= last {
                if dayCounts[clock.dayKey(for: day), default: 0] > 0 {
                    run += 1
                    longest = max(longest, run)
                } else {
                    run = 0
                }
                guard let next = clock.calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        #expect(current == expectedCurrent, "emitted current streak must equal history_plan")
        #expect(longest == expectedLongest, "emitted longest streak must equal history_plan")

        let dueToday = dense.entries.filter { entry in
            guard let next = entry.nextReviewAt else { return false }
            return clock.dayKey(for: next) <= anchor
        }.count
        #expect(dueToday == expectedPrimaryDue, "emitted UI due count must equal history_plan.primary")
    }

    private static func requireCanonicalClock(_ seed: FixtureReviewClockSeed) throws -> ReviewCalendarClock {
        try #require(seed.now)
        try #require(seed.frozenEpoch)
        try #require(seed.anchorDay)
        try #require(seed.timeZone)
        try #require(seed.source)
        return ReviewCalendarClock.fromFixture(seed, fixtureID: "repo fixture contract")
    }

    private static func date(forDayKey key: String, clock: ReviewCalendarClock) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return clock.calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]
        ))
    }

    @Test func everyRepoDatasetDeclaresValidAssetManifest() throws {
        for url in try Self.datasetURLs() {
            let data = try Data(contentsOf: url)
            let document = try FixtureDatasetStore.decode(data)
            let stem = url.deletingPathExtension().lastPathComponent

            #expect(document.schema == "kg.fixture.dataset.v2", "\(stem): repo UI Worlds must use the asset-manifest schema")
            #expect(!document.assets.isEmpty, "\(stem): repo UI Worlds must declare assets")
            #expect(!document.preferences.isEmpty, "\(stem): repo UI Worlds must declare preferences")
            let topLevel = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            expectNoLegacyAssetPathKeys(topLevel, dataset: stem)
            expectPreferenceWrapperKeys(topLevel, dataset: stem)
            expectAuthKeychainStateKeys(topLevel, dataset: stem)
            expectAuthUIStateKeys(topLevel, dataset: stem)
            expectSettingsKeys(topLevel, dataset: stem)
            expectEntitlementsKeys(topLevel, dataset: stem)
            expectCatalogPodcastPlaybackKeys(topLevel, dataset: stem)
            expectTodayReviewKeys(topLevel, dataset: stem)
            expectRuntimePodcastDownloadKeys(topLevel, dataset: stem)
            expectSwiftDataRowStateKeys(topLevel, document: document, dataset: stem)
            expectSyncPresenterKeys(topLevel, dataset: stem)
            expectValidPreferenceKeys(document.preferences.userDefaults.keys, dataset: stem, domain: "preferences.userDefaults")
            expectValidPreferenceKeys(document.preferences.ubiquitousKeyValueStore.keys, dataset: stem, domain: "preferences.ubiquitousKeyValueStore")

            try expectValidAssetManifest(document: document, dataset: stem)
            expectUniqueInstallPaths(document: document, dataset: stem)

            expectRuntimePodcastAssetRefs(document: document, dataset: stem)
            expectRuntimePodcastNotebookRefs(document: document, dataset: stem)

            for (fixtureKey, seed) in document.reader {
                expectNotebookSyncStatus(
                    seed.notebookSyncStatus,
                    dataset: stem,
                    owner: "reader.\(fixtureKey).notebookSyncStatus"
                )
                expectVocabularyRowState(
                    seed.entry,
                    dataset: stem,
                    owner: "reader.\(fixtureKey).entry.\(seed.entry.word)"
                )
                expectInstallableAssetRef(
                    seed.textAssetRef,
                    document: document,
                    dataset: stem,
                    owner: "reader.\(fixtureKey).textAssetRef"
                )
                expectBookAssetRef(
                    seed.bookAssetRef,
                    document: document,
                    dataset: stem,
                    owner: "reader.\(fixtureKey).bookAssetRef",
                    fileName: seed.bookFileName,
                    format: .epub
                )
            }

            for (fixtureKey, seed) in document.bookshelf {
                for book in seed.books {
                    guard let ref = book.bookAssetRef?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !ref.isEmpty else {
                        Issue.record("\(stem): bookshelf.\(fixtureKey) book \(book.title) is missing bookAssetRef")
                        continue
                    }
                    expectBookAssetRef(
                        ref,
                        document: document,
                        dataset: stem,
                        owner: "bookshelf.\(fixtureKey).\(book.title)",
                        fileName: book.fileName,
                        format: book.format
                    )
                    if let preferredNotebookId = book.preferredNotebookId,
                       !preferredNotebookId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        expectNotebookRef(
                            preferredNotebookId,
                            document: document,
                            dataset: stem,
                            owner: "bookshelf.\(fixtureKey).\(book.title).preferredNotebookId"
                        )
                    }
                }
            }

            for (fixtureKey, seed) in document.notebook {
                for notebook in seed.notebooks {
                    expectNotebookSyncStatus(
                        notebook.syncStatus,
                        dataset: stem,
                        owner: "notebook.\(fixtureKey).\(notebook.remoteId).syncStatus"
                    )
                    if let coverImageAssetRef = notebook.coverImageAssetRef {
                        expectAssetRef(
                            coverImageAssetRef,
                            document: document,
                            expectedPrefix: "images.",
                            dataset: stem,
                            owner: "notebook.\(fixtureKey).\(notebook.remoteId).coverImageAssetRef"
                        )
                    }
                    for entry in notebook.entries {
                        expectNotebookEntryRowState(
                            entry,
                            dataset: stem,
                            owner: "notebook.\(fixtureKey).\(notebook.remoteId).entry.\(entry.word)"
                        )
                    }
                }
            }

            for (fixtureKey, seed) in document.vocabulary {
                expectNotebookSyncStatus(
                    seed.notebookSyncStatus,
                    dataset: stem,
                    owner: "vocabulary.\(fixtureKey).notebookSyncStatus"
                )
                for entry in seed.entries {
                    expectVocabularyRowState(
                        entry,
                        dataset: stem,
                        owner: "vocabulary.\(fixtureKey).entry.\(entry.word)"
                    )
                }
            }

            for (fixtureKey, seed) in document.reviewDeck {
                expectNotebookSyncStatus(
                    seed.notebookSyncStatus,
                    dataset: stem,
                    owner: "reviewDeck.\(fixtureKey).notebookSyncStatus"
                )
                for entry in seed.entries {
                    expectVocabularyRowState(
                        entry,
                        dataset: stem,
                        owner: "reviewDeck.\(fixtureKey).entry.\(entry.word)"
                    )
                }
            }

            for (fixtureKey, seed) in document.auth {
                expectAuthKeychainState(
                    seed,
                    dataset: stem,
                    owner: "auth.\(fixtureKey)"
                )
            }

            for (fixtureKey, seed) in document.settings {
                expectSettingsStateRefs(
                    seed,
                    document: document,
                    dataset: stem,
                    owner: "settings.\(fixtureKey)"
                )
            }
        }
    }

    @Test func everyRepoDatasetDecodesAndMatchesKnownFixtureIDs() throws {
        for url in try Self.datasetURLs() {
            let data = try Data(contentsOf: url)
            let document = try FixtureDatasetStore.decode(data)
            let stem = url.deletingPathExtension().lastPathComponent

            #expect(document.schema == "kg.fixture.dataset.v2", "\(stem): unexpected schema")
            #expect(document.datasetID == stem, "\(stem): datasetID must match filename")

            // Keyed decoding ignores unknown top-level keys, so a domain-level
            // typo ("podcasts") silently drops the whole domain — exactly the
            // failure class this suite exists to close.
            let topLevel = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let unknownTopLevel = Set(topLevel.keys).subtracting(FixtureDatasetDocument.knownTopLevelKeys)
            #expect(
                unknownTopLevel.isEmpty,
                "\(stem): unknown top-level keys \(unknownTopLevel.sorted()) would be silently ignored"
            )

            expectKnownKeys(document.settings.keys, SettingsFixtureID.self, domain: "settings", dataset: stem)
            expectKnownKeys(document.auth.keys, UIWorldAuthFixtureID.self, domain: "auth", dataset: stem)
            expectKnownKeys(document.entitlements.keys, UIWorldEntitlementsFixtureID.self, domain: "entitlements", dataset: stem)
            expectKnownKeys(document.bookshelf.keys, BookshelfFixtureID.self, domain: "bookshelf", dataset: stem)
            expectKnownKeys(document.todayReview.keys, TodayReviewFixtureID.self, domain: "todayReview", dataset: stem)
            expectKnownKeys(document.notebook.keys, NotebookFixtureID.self, domain: "notebook", dataset: stem)
            expectKnownKeys(document.podcast.keys, PodcastFixtureID.self, domain: "podcast", dataset: stem)
            expectKnownKeys(document.runtimePodcast.keys, UIWorldRuntimePodcastFixtureID.self, domain: "runtimePodcast", dataset: stem)
            expectKnownKeys(document.reader.keys, UIWorldReaderFixtureID.self, domain: "reader", dataset: stem)
            expectKnownKeys(document.vocabulary.keys, UIWorldVocabularyFixtureID.self, domain: "vocabulary", dataset: stem)
            expectKnownKeys(document.reviewDeck.keys, UIWorldReviewDeckFixtureID.self, domain: "reviewDeck", dataset: stem)
            expectKnownKeys(document.syncPresenter.keys, UIWorldSyncPresenterFixtureID.self, domain: "syncPresenter", dataset: stem)

            // Duplicate identities render undefined (ForEach ids / notebookId
            // joins derive from them), so they must be unique within a seed.
            for (fixtureKey, seed) in document.podcast {
                let numbers = seed.episodes.map(\.episodeNumber)
                #expect(
                    Set(numbers).count == numbers.count,
                    "\(stem): podcast.\(fixtureKey) has duplicate episodeNumber values"
                )
            }
            for (fixtureKey, seed) in document.notebook {
                let ids = seed.notebooks.map(\.remoteId)
                #expect(
                    Set(ids).count == ids.count,
                    "\(stem): notebook.\(fixtureKey) has duplicate notebook remoteId values"
                )
            }
            for (fixtureKey, seed) in document.runtimePodcast {
                let ids = seed.episodes.map(\.remoteId)
                #expect(
                    Set(ids).count == ids.count,
                    "\(stem): runtimePodcast.\(fixtureKey) has duplicate episode remoteId values"
                )
            }
            for (fixtureKey, seed) in document.vocabulary {
                let words = seed.entries.map(\.word)
                #expect(
                    Set(words).count == words.count,
                    "\(stem): vocabulary.\(fixtureKey) has duplicate word values"
                )
                let entryWords = Set(words)
                for record in seed.reviewHistory {
                    #expect(
                        entryWords.contains(record.word),
                        "\(stem): vocabulary.\(fixtureKey).reviewHistory.\(record.word) must reference an entry in the same seed"
                    )
                }
            }
            for (fixtureKey, seed) in document.reviewDeck {
                let words = seed.entries.map(\.word)
                #expect(
                    Set(words).count == words.count,
                    "\(stem): reviewDeck.\(fixtureKey) has duplicate word values"
                )
            }
        }
    }

    private func expectKnownKeys<ID: RawRepresentable & CaseIterable>(
        _ keys: some Sequence<String>,
        _ idType: ID.Type,
        domain: String,
        dataset: String
    ) where ID.RawValue == String {
        let known = Set(idType.allCases.map(\.rawValue))
        let unknown = Set(keys).subtracting(known)
        #expect(
            unknown.isEmpty,
            "\(dataset): domain \(domain) keys \(unknown.sorted()) have no matching fixture ID — they would silently never render"
        )
    }

    private func expectNoLegacyAssetPathKeys(_ topLevel: [String: Any], dataset: String) {
        let runtimePodcast = topLevel["runtimePodcast"] as? [String: [String: Any]] ?? [:]
        for (fixtureKey, seed) in runtimePodcast {
            let legacy = Set(seed.keys).intersection(["audioPath", "subtitlePath"])
            #expect(
                legacy.isEmpty,
                "\(dataset): runtimePodcast.\(fixtureKey) uses legacy bare path keys \(legacy.sorted()); use audioAssetRef/subtitleAssetRef"
            )
        }

        let reader = topLevel["reader"] as? [String: [String: Any]] ?? [:]
        let readerKeys: Set<String> = [
            "textAssetRef",
            "bookAssetRef",
            "title",
            "author",
            "bookFileName",
            "notebookRemoteId",
            "notebookName",
            "notebookSyncStatus",
            "entry",
        ]
        for (fixtureKey, seed) in reader {
            let legacy = Set(seed.keys).intersection(["textPath"])
            #expect(
                legacy.isEmpty,
                "\(dataset): reader.\(fixtureKey) uses legacy bare path keys \(legacy.sorted()); use textAssetRef"
            )
            #expect(
                seed.keys.contains("bookAssetRef"),
                "\(dataset): reader.\(fixtureKey) must declare bookAssetRef for the complete reader book"
            )
            let unknown = Set(seed.keys).subtracting(readerKeys)
            #expect(
                unknown.isEmpty,
                "\(dataset): reader.\(fixtureKey) contains unknown keys \(unknown.sorted())"
            )
        }
    }

    private func expectRuntimePodcastDownloadKeys(_ topLevel: [String: Any], dataset: String) {
        let runtimePodcast = topLevel["runtimePodcast"] as? [String: [String: Any]] ?? [:]
        let seriesKeys: Set<String> = [
            "audioAssetRef",
            "subtitleAssetRef",
            "seriesRemoteId",
            "seriesTitle",
            "hostNames",
            "preferredNotebookId",
            "color",
            "coverPattern",
            "sortOrder",
            "durationSec",
            "episodes",
        ]
        let episodeKeys: Set<String> = [
            "remoteId",
            "episodeNumber",
            "title",
            "durationSec",
            "audioAvailable",
            "previewAvailable",
            "previewDurationSec",
            "subtitleAvailable",
            "download",
        ]
        let downloadKeys: Set<String> = [
            "audioAssetRef",
            "subtitleAssetRef",
            "localAudioPath",
            "localSubtitlePath",
        ]
        for (fixtureKey, seed) in runtimePodcast {
            for key in seriesKeys {
                #expect(
                    seed.keys.contains(key),
                    "\(dataset): runtimePodcast.\(fixtureKey) must explicitly declare \(key)"
                )
            }
            let unknownSeriesKeys = Set(seed.keys).subtracting(seriesKeys)
            #expect(
                unknownSeriesKeys.isEmpty,
                "\(dataset): runtimePodcast.\(fixtureKey) contains unknown keys \(unknownSeriesKeys.sorted())"
            )

            let episodes = seed["episodes"] as? [[String: Any]] ?? []
            for episode in episodes {
                let remoteId = episode["remoteId"] as? String ?? "<missing-remote-id>"
                for key in episodeKeys {
                    #expect(
                        episode.keys.contains(key),
                        "\(dataset): runtimePodcast.\(fixtureKey).episode.\(remoteId) must explicitly declare \(key)"
                    )
                }
                let unknownEpisodeKeys = Set(episode.keys).subtracting(episodeKeys)
                #expect(
                    unknownEpisodeKeys.isEmpty,
                    "\(dataset): runtimePodcast.\(fixtureKey).episode.\(remoteId) contains unknown keys \(unknownEpisodeKeys.sorted())"
                )

                if let download = episode["download"] as? [String: Any] {
                    for key in downloadKeys {
                        #expect(
                            download.keys.contains(key),
                            "\(dataset): runtimePodcast.\(fixtureKey).episode.\(remoteId).download must explicitly declare \(key)"
                        )
                    }
                    let unknownDownloadKeys = Set(download.keys).subtracting(downloadKeys)
                    #expect(
                        unknownDownloadKeys.isEmpty,
                        "\(dataset): runtimePodcast.\(fixtureKey).episode.\(remoteId).download contains unknown keys \(unknownDownloadKeys.sorted())"
                    )
                }
            }
        }
    }

    private func expectCatalogPodcastPlaybackKeys(_ topLevel: [String: Any], dataset: String) {
        let podcast = topLevel["podcast"] as? [String: [String: Any]] ?? [:]
        for (fixtureKey, seed) in podcast {
            let series = seed["series"] as? [String: Any] ?? [:]
            for key in ["colorHex", "coverPattern"] {
                #expect(
                    series.keys.contains(key),
                    "\(dataset): podcast.\(fixtureKey).series must explicitly declare \(key)"
                )
            }
            let episodes = seed["episodes"] as? [[String: Any]] ?? []
            for episode in episodes {
                let episodeNumber = episode["episodeNumber"] as? Int ?? -1
                for key in ["durationSec", "lastPlayedTime"] {
                    #expect(
                        episode.keys.contains(key),
                        "\(dataset): podcast.\(fixtureKey).episode.\(episodeNumber) must explicitly declare \(key)"
                    )
                }
            }
        }
    }

    private func expectTodayReviewKeys(_ topLevel: [String: Any], dataset: String) {
        let todayReview = topLevel["todayReview"] as? [String: [String: Any]] ?? [:]
        let sessionKeys = [
            "progressText",
            "currentCard",
            "nextCard",
            "revealStage",
            "canShuffle",
            "canGoPrevious",
            "canGoNext",
            "remainingCount",
            "forgotCount",
            "rememberedCount",
            "rememberedFeedbackTrigger",
            "forgotFeedbackTrigger",
            "isAutoPlaying",
            "isAutoPlayPaused",
            "autoplayProgress",
            "autoplaySpeed",
            "autoplaySoundEnabled",
            "showFirstRunHint",
        ]
        let cardKeys = [
            "word",
            "translation",
            "context",
            "explanation",
            "partOfSpeech",
            "bookTitle",
            "chapterTitle",
            "dateAdded",
            "difficultyTier",
            "reviewMode",
            "reviewExamples",
            "rootForm",
            "inflections",
            "graphLinksByKind",
        ]
        let linkKeys = [
            "id",
            "cardId",
            "word",
            "kind",
            "label",
            "confidence",
            "reason",
            "hidden",
        ]
        for (fixtureKey, seed) in todayReview {
            for key in sessionKeys {
                #expect(
                    seed.keys.contains(key),
                    "\(dataset): todayReview.\(fixtureKey) must explicitly declare \(key)"
                )
            }
            for cardKey in ["currentCard", "nextCard"] {
                guard let card = seed[cardKey] as? [String: Any] else {
                    continue
                }
                for key in cardKeys {
                    #expect(
                        card.keys.contains(key),
                        "\(dataset): todayReview.\(fixtureKey).\(cardKey) must explicitly declare \(key)"
                    )
                }
                let linksByKind = card["graphLinksByKind"] as? [String: [[String: Any]]] ?? [:]
                for (kind, links) in linksByKind {
                    for link in links {
                        for key in linkKeys {
                            #expect(
                                link.keys.contains(key),
                                "\(dataset): todayReview.\(fixtureKey).\(cardKey).graphLinksByKind.\(kind) must explicitly declare \(key)"
                            )
                        }
                    }
                }
            }
        }
    }

    private func expectValidAssetManifest(document: FixtureDatasetDocument, dataset: String) throws {
        for ref in document.assets.refs {
            let asset = try #require(document.assets.asset(for: ref), "\(dataset): asset \(ref) must resolve")
            #expect(!asset.sourcePath.hasPrefix("/"), "\(dataset): asset \(ref) sourcePath must be repo-relative")
            let url = try FixtureDatasetStore.resolveSourceURL(for: asset)
            #expect(asset.byteSize > 0, "\(dataset): asset \(ref) byteSize must be positive")
            expectAssetInstallPath(asset, ref: ref, dataset: dataset)
            expectAssetContentType(asset, ref: ref, dataset: dataset)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(dataset): asset \(ref) missing at \(url.path)")
            #expect(
                try FixtureDatasetStore.byteSize(for: url) == asset.byteSize,
                "\(dataset): asset \(ref) byteSize drift"
            )
            #expect(
                try FixtureDatasetStore.sha256Hex(for: url) == asset.sha256,
                "\(dataset): asset \(ref) sha256 drift"
            )
        }
    }

    private func expectAssetInstallPath(_ asset: UIWorldAsset, ref: String, dataset: String) {
        let trimmed = asset.installAs.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty, "\(dataset): asset \(ref) installAs must be non-empty")
        #expect(!trimmed.hasPrefix("/"), "\(dataset): asset \(ref) installAs must be relative")
        let components = trimmed.split(separator: "/").map(String.init)
        #expect(
            components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." },
            "\(dataset): asset \(ref) installAs contains unsafe path components"
        )
    }

    private func expectAssetContentType(_ asset: UIWorldAsset, ref: String, dataset: String) {
        let contentType = asset.contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!contentType.isEmpty, "\(dataset): asset \(ref) contentType must not be empty")

        let allowedByDomain: [String: [String]] = [
            "books": ["application/epub+zip", "application/pdf", "text/markdown; charset=utf-8", "text/plain; charset=utf-8"],
            "audio": ["audio/mp4", "audio/mpeg"],
            "subtitles": ["application/x-subrip; charset=utf-8", "text/vtt; charset=utf-8"],
            "text": ["text/markdown; charset=utf-8", "text/plain; charset=utf-8"],
            "images": ["image/png", "image/jpeg"],
        ]
        let domain = ref.split(separator: ".", maxSplits: 1).first.map(String.init) ?? "<missing-domain>"
        #expect(
            allowedByDomain[domain]?.contains(contentType) == true,
            "\(dataset): asset \(ref) contentType \(contentType) is invalid for domain \(domain)"
        )

        let installExtension = URL(fileURLWithPath: asset.installAs).pathExtension.lowercased()
        let sourceExtension = URL(fileURLWithPath: asset.sourcePath).pathExtension.lowercased()
        let ext = installExtension.isEmpty ? sourceExtension : installExtension
        let expectedByExtension: [String: String] = [
            "epub": "application/epub+zip",
            "pdf": "application/pdf",
            "md": "text/markdown; charset=utf-8",
            "txt": "text/plain; charset=utf-8",
            "m4a": "audio/mp4",
            "mp3": "audio/mpeg",
            "srt": "application/x-subrip; charset=utf-8",
            "vtt": "text/vtt; charset=utf-8",
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
        ]
        if let expected = expectedByExtension[ext] {
            #expect(
                contentType == expected,
                "\(dataset): asset \(ref) contentType \(contentType) must match .\(ext) as \(expected)"
            )
        }
    }

    private func expectRuntimePodcastAssetRefs(document: FixtureDatasetDocument, dataset: String) {
        for (fixtureKey, seed) in document.runtimePodcast {
            expectInstallableAssetRef(
                seed.audioAssetRef,
                document: document,
                dataset: dataset,
                owner: "runtimePodcast.\(fixtureKey).audioAssetRef"
            )
            expectInstallableAssetRef(
                seed.subtitleAssetRef,
                document: document,
                dataset: dataset,
                owner: "runtimePodcast.\(fixtureKey).subtitleAssetRef"
            )
            for episode in seed.episodes {
                guard let download = episode.download else { continue }
                expectInstallableAssetRef(
                    download.audioAssetRef,
                    document: document,
                    dataset: dataset,
                    owner: "runtimePodcast.\(fixtureKey).episode.\(episode.remoteId).download.audioAssetRef"
                )
                expectDownloadLocalPath(
                    download.localAudioPath,
                    assetRef: download.audioAssetRef,
                    document: document,
                    dataset: dataset,
                    owner: "runtimePodcast.\(fixtureKey).episode.\(episode.remoteId).download.localAudioPath"
                )
                if let subtitleAssetRef = download.subtitleAssetRef {
                    expectInstallableAssetRef(
                        subtitleAssetRef,
                        document: document,
                        dataset: dataset,
                        owner: "runtimePodcast.\(fixtureKey).episode.\(episode.remoteId).download.subtitleAssetRef"
                    )
                    expectDownloadLocalPath(
                        download.localSubtitlePath,
                        assetRef: subtitleAssetRef,
                        document: document,
                        dataset: dataset,
                        owner: "runtimePodcast.\(fixtureKey).episode.\(episode.remoteId).download.localSubtitlePath"
                    )
                } else {
                    #expect(
                        download.localSubtitlePath == nil,
                        "\(dataset): runtimePodcast.\(fixtureKey).episode.\(episode.remoteId).download.localSubtitlePath must be null when subtitleAssetRef is null"
                    )
                }
            }
        }
    }

    private func expectRuntimePodcastNotebookRefs(document: FixtureDatasetDocument, dataset: String) {
        for (fixtureKey, seed) in document.runtimePodcast {
            guard let preferredNotebookId = seed.preferredNotebookId,
                  !preferredNotebookId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            expectNotebookRef(
                preferredNotebookId,
                document: document,
                dataset: dataset,
                owner: "runtimePodcast.\(fixtureKey).preferredNotebookId"
            )
        }
    }

    private func expectNotebookRef(
        _ notebookId: String,
        document: FixtureDatasetDocument,
        dataset: String,
        owner: String
    ) {
        let notebookIDs = Set(document.notebook.values.flatMap { seed in
            seed.notebooks.map(\.remoteId)
        })
        #expect(
            notebookIDs.contains(notebookId),
            "\(dataset): \(owner) references missing notebook \(notebookId)"
        )
    }

    private func expectAuthKeychainStateKeys(_ topLevel: [String: Any], dataset: String) {
        let authFixtures = topLevel["auth"] as? [String: [String: Any]] ?? [:]
        let authKeys: Set<String> = [
            "isLoggedIn",
            "userId",
            "token",
            "keychainTokenState",
            "displayName",
            "email",
            "authError",
            "isAuthenticating",
            "provider",
            "providerUserId",
        ]
        for (fixtureKey, seed) in authFixtures {
            for key in authKeys {
                #expect(
                    seed.keys.contains(key),
                    "\(dataset): auth.\(fixtureKey) must explicitly declare \(key)"
                )
            }
            let unknown = Set(seed.keys).subtracting(authKeys)
            #expect(
                unknown.isEmpty,
                "\(dataset): auth.\(fixtureKey) contains unknown keys \(unknown.sorted())"
            )
        }
    }

    private func expectPreferenceWrapperKeys(_ topLevel: [String: Any], dataset: String) {
        let preferences = topLevel["preferences"] as? [String: Any] ?? [:]
        let keys: Set<String> = [
            "userDefaults",
            "ubiquitousKeyValueStore",
        ]
        for key in keys {
            #expect(
                preferences.keys.contains(key),
                "\(dataset): preferences must explicitly declare \(key)"
            )
        }
        let unknown = Set(preferences.keys).subtracting(keys)
        #expect(
            unknown.isEmpty,
            "\(dataset): preferences contains unknown keys \(unknown.sorted())"
        )
    }

    private func expectAuthUIStateKeys(_ topLevel: [String: Any], dataset: String) {
        let authFixtures = topLevel["auth"] as? [String: [String: Any]] ?? [:]
        for (fixtureKey, seed) in authFixtures {
            for key in ["authError", "isAuthenticating"] {
                #expect(
                    seed.keys.contains(key),
                    "\(dataset): auth.\(fixtureKey) must explicitly declare \(key)"
                )
            }
        }
    }

    private func expectEntitlementsKeys(_ topLevel: [String: Any], dataset: String) {
        let entitlements = topLevel["entitlements"] as? [String: [String: Any]] ?? [:]
        let seedKeys: Set<String> = ["pro"]
        let proKeys: Set<String> = [
            "is_active",
            "product_id",
            "plan_name",
            "price_display",
            "status",
            "is_trial",
            "trial_days",
            "will_renew",
            "expires_at",
            "source",
            "last_synced_at",
        ]
        for (fixtureKey, seed) in entitlements {
            let unknownSeedKeys = Set(seed.keys).subtracting(seedKeys)
            #expect(
                unknownSeedKeys.isEmpty,
                "\(dataset): entitlements.\(fixtureKey) contains unknown keys \(unknownSeedKeys.sorted())"
            )
            #expect(
                seed.keys.contains("pro"),
                "\(dataset): entitlements.\(fixtureKey) must explicitly declare pro"
            )
            guard let pro = seed["pro"] as? [String: Any] else {
                continue
            }
            for key in proKeys {
                #expect(
                    pro.keys.contains(key),
                    "\(dataset): entitlements.\(fixtureKey).pro must explicitly declare \(key)"
                )
            }
            let unknownProKeys = Set(pro.keys).subtracting(proKeys)
            #expect(
                unknownProKeys.isEmpty,
                "\(dataset): entitlements.\(fixtureKey).pro contains unknown keys \(unknownProKeys.sorted())"
            )
        }
    }

    private func expectSettingsKeys(_ topLevel: [String: Any], dataset: String) {
        let settingsFixtures = topLevel["settings"] as? [String: [String: Any]] ?? [:]
        let seedKeys: Set<String> = [
            "auth",
            "authFixtureRef",
            "entitlementsFixtureRef",
            "preferences",
            "reviewSettings",
            "kg",
            "subscription",
            "syncSummary",
            "bookSync",
            "about",
            "danger",
            "manualLoginUserId",
            "debugLocalServerURL",
            "evidence",
            "resetLifecycle",
        ]
        let authKeys: Set<String> = [
            "isLoggedIn",
            "userInitials",
            "avatarURL",
            "displayName",
            "email",
            "authError",
            "isAuthenticating",
            "iconBreathing",
            "manualLoginHint",
        ]
        let preferencesKeys: Set<String> = [
            "selectedLanguage",
            "selectedAppearance",
            "translationSource",
            "translationTarget",
            "selectedReviewMode",
            "autoSyncEnabled",
            "showAutoSync",
        ]
        let kgKeys: Set<String> = [
            "serverURL",
            "isConnected",
            "connectionPulse",
            "serverCardCount",
            "lastSyncDescription",
            "isUsingLocalServer",
            "localServerURL",
            "observation",
        ]
        let observationKeys: Set<String> = ["previewLines", "totalCount"]
        let subscriptionKeys: Set<String> = [
            "isActive",
            "planName",
            "badgeText",
            "badgeTone",
            "summary",
            "detail",
            "sourceLabel",
            "managementNote",
            "pricingUnavailableMessage",
            "restoreLabel",
            "restoreDescription",
            "isRestoreAvailable",
            "ctaTitle",
            "isRefreshing",
        ]
        let reviewKeys: Set<String> = [
            "mode",
            "customInitialIntervalHours",
            "customRememberedMultiplier",
            "customForgotMultiplier",
            "customMinimumIntervalHours",
            "customMaximumIntervalHours",
            "isProgressPaused",
            "progressPausedAt",
            "autoplaySpeed",
            "autoplaySoundEnabled",
        ]
        let syncSummaryKeys: Set<String> = [
            "isConnected",
            "isSyncing",
            "summaryText",
            "lastSyncedText",
            "lifecycle",
            "message",
            "attempt",
            "dataOutcome",
        ]
        let aboutKeys: Set<String> = ["version", "developerName"]
        let dangerKeys: Set<String> = ["isDeletingAccount"]
        let bookSyncKeys: Set<String> = ["text", "detail", "tone"]

        for (fixtureKey, seed) in settingsFixtures {
            expectExactKeys(seed, seedKeys, dataset: dataset, owner: "settings.\(fixtureKey)")
            if let auth = seed["auth"] as? [String: Any] {
                expectExactKeys(auth, authKeys, dataset: dataset, owner: "settings.\(fixtureKey).auth")
            }
            if let preferences = seed["preferences"] as? [String: Any] {
                expectExactKeys(preferences, preferencesKeys, dataset: dataset, owner: "settings.\(fixtureKey).preferences")
            }
            if let kg = seed["kg"] as? [String: Any] {
                expectExactKeys(kg, kgKeys, dataset: dataset, owner: "settings.\(fixtureKey).kg")
                if let observation = kg["observation"] as? [String: Any] {
                    expectExactKeys(observation, observationKeys, dataset: dataset, owner: "settings.\(fixtureKey).kg.observation")
                }
            }
            if let subscription = seed["subscription"] as? [String: Any] {
                expectExactKeys(subscription, subscriptionKeys, dataset: dataset, owner: "settings.\(fixtureKey).subscription")
            }
            if let review = seed["reviewSettings"] as? [String: Any] {
                expectExactKeys(review, reviewKeys, dataset: dataset, owner: "settings.\(fixtureKey).reviewSettings")
            }
            if let syncSummary = seed["syncSummary"] as? [String: Any] {
                expectExactKeys(syncSummary, syncSummaryKeys, dataset: dataset, owner: "settings.\(fixtureKey).syncSummary")
            }
            if let about = seed["about"] as? [String: Any] {
                expectExactKeys(about, aboutKeys, dataset: dataset, owner: "settings.\(fixtureKey).about")
            }
            if let danger = seed["danger"] as? [String: Any] {
                expectExactKeys(danger, dangerKeys, dataset: dataset, owner: "settings.\(fixtureKey).danger")
            }
            if let bookSync = seed["bookSync"] as? [String: Any] {
                expectExactKeys(bookSync, bookSyncKeys, dataset: dataset, owner: "settings.\(fixtureKey).bookSync")
            }
        }
    }

    private func expectExactKeys(_ object: [String: Any], _ allowed: Set<String>, dataset: String, owner: String) {
        let missing = allowed.subtracting(object.keys)
        #expect(missing.isEmpty, "\(dataset): \(owner) missing keys \(missing.sorted())")
        let unknown = Set(object.keys).subtracting(allowed)
        #expect(unknown.isEmpty, "\(dataset): \(owner) contains unknown keys \(unknown.sorted())")
    }

    private func expectSwiftDataRowStateKeys(_ topLevel: [String: Any], document: FixtureDatasetDocument, dataset: String) {
        let requiredEntryKeys: Set<String> = ["syncStatus", "actionType", "isArchived"]
        let requiredNotebookEntryKeys = requiredEntryKeys.union(["context", "explanation", "partOfSpeech", "bookTitle", "chapterTitle"])
        let notebookEntryKeys = requiredNotebookEntryKeys.union(["word", "translation"])
        let requiredUIWorldEntryKeys = requiredEntryKeys.union([
            "bookTitle",
            "reviewMode",
            "explanation",
            "partOfSpeech",
            "chapterTitle",
            "kgCardId",
            "difficultyTier",
            "reviewExamples",
            "collocations",
            "rootForm",
            "inflections",
            "reviewIntervalHours",
            "nextReviewAt",
            "lastReviewedAt",
            "reviewCount",
            "reviewStreak",
            "lastReviewFeedbackRaw",
            "graphLinksByKind",
        ])
        let uiWorldEntryKeys = requiredUIWorldEntryKeys.union([
            "word",
            "translation",
            "context",
        ])
        let vocabularySeedKeys: Set<String> = [
            "notebookRemoteId",
            "notebookName",
            "notebookSyncStatus",
            "bookTitle",
            "entries",
            "reviewHistory",
            "baseFixture",
            "entryOverrides",
        ]
        let reviewDeckSeedKeys: Set<String> = [
            "notebookRemoteId",
            "notebookName",
            "notebookSyncStatus",
            "entries",
        ]
        let reviewHistoryKeys: Set<String> = [
            "word",
            "feedback",
            "reviewedAt",
        ]
        let requiredBookshelfSeedKeys: Set<String> = [
            "books",
            "referenceDate",
        ]
        let requiredBookshelfBookKeys: Set<String> = [
            "title",
            "author",
            "fileName",
            "format",
            "bookAssetRef",
            "progression",
            "preferredNotebookId",
            "dateAdded",
            "dateLastRead",
        ]
        let requiredNotebookFixtureKeys: Set<String> = ["notebooks", "editStates"]
        let requiredNotebookRowKeys: Set<String> = [
            "remoteId",
            "name",
            "color",
            "coverPattern",
            "coverImageAssetRef",
            "cardState",
            "syncStatus",
            "isDefault",
            "sortOrder",
            "entries",
        ]

        let bookshelfFixtures = topLevel["bookshelf"] as? [String: [String: Any]] ?? [:]
        for (fixtureKey, seed) in bookshelfFixtures {
            let unknownSeedKeys = Set(seed.keys).subtracting(requiredBookshelfSeedKeys)
            #expect(
                unknownSeedKeys.isEmpty,
                "\(dataset): bookshelf.\(fixtureKey) contains unknown keys \(unknownSeedKeys.sorted())"
            )
            let books = seed["books"] as? [[String: Any]] ?? []
            for book in books {
                let title = book["title"] as? String ?? "<missing-title>"
                let missing = requiredBookshelfBookKeys.subtracting(book.keys)
                #expect(
                    missing.isEmpty,
                    "\(dataset): bookshelf.\(fixtureKey).book.\(title) missing row state keys \(missing.sorted())"
                )
                let unknown = Set(book.keys).subtracting(requiredBookshelfBookKeys)
                #expect(
                    unknown.isEmpty,
                    "\(dataset): bookshelf.\(fixtureKey).book.\(title) contains unknown keys \(unknown.sorted())"
                )
            }
        }

        let notebookFixtures = topLevel["notebook"] as? [String: [String: Any]] ?? [:]
        for (fixtureKey, seed) in notebookFixtures {
            let unknownSeedKeys = Set(seed.keys).subtracting(requiredNotebookFixtureKeys)
            #expect(
                unknownSeedKeys.isEmpty,
                "\(dataset): notebook.\(fixtureKey) contains unknown keys \(unknownSeedKeys.sorted())"
            )
            #expect(
                seed.keys.contains("editStates"),
                "\(dataset): notebook.\(fixtureKey) must explicitly declare editStates"
            )
            let editStates = seed["editStates"] as? [[String: Any]] ?? []
            for editState in editStates {
                expectNotebookEditStateKeys(
                    editState,
                    document: document,
                    dataset: dataset,
                    owner: "notebook.\(fixtureKey).editStates.\(editState["id"] as? String ?? "<missing-id>")"
                )
            }
            let notebooks = seed["notebooks"] as? [[String: Any]] ?? []
            for notebook in notebooks {
                let remoteId = notebook["remoteId"] as? String ?? "<missing-remote-id>"
                let unknownNotebookKeys = Set(notebook.keys).subtracting(requiredNotebookRowKeys)
                #expect(
                    unknownNotebookKeys.isEmpty,
                    "\(dataset): notebook.\(fixtureKey).\(remoteId) contains unknown keys \(unknownNotebookKeys.sorted())"
                )
                #expect(
                    notebook.keys.contains("syncStatus"),
                    "\(dataset): notebook.\(fixtureKey).\(remoteId) must explicitly declare syncStatus"
                )
                for key in ["isDefault", "sortOrder", "coverPattern", "coverImageAssetRef", "cardState"] {
                    #expect(
                        notebook.keys.contains(key),
                        "\(dataset): notebook.\(fixtureKey).\(remoteId) must explicitly declare \(key)"
                    )
                }
                if let cardState = notebook["cardState"] as? [String: Any] {
                    expectNotebookCardStateKeys(cardState, dataset: dataset, owner: "notebook.\(fixtureKey).\(remoteId).cardState")
                }
                let entries = notebook["entries"] as? [[String: Any]] ?? []
                for entry in entries {
                    let word = entry["word"] as? String ?? "<missing-word>"
                    let missing = requiredNotebookEntryKeys.subtracting(entry.keys)
                    #expect(
                        missing.isEmpty,
                        "\(dataset): notebook.\(fixtureKey).\(remoteId).entry.\(word) missing row state keys \(missing.sorted())"
                    )
                    let unknown = Set(entry.keys).subtracting(notebookEntryKeys)
                    #expect(
                        unknown.isEmpty,
                        "\(dataset): notebook.\(fixtureKey).\(remoteId).entry.\(word) contains unknown keys \(unknown.sorted())"
                    )
                }
            }
        }

        let readerFixtures = topLevel["reader"] as? [String: [String: Any]] ?? [:]
        for (fixtureKey, seed) in readerFixtures {
            #expect(
                seed.keys.contains("notebookSyncStatus"),
                "\(dataset): reader.\(fixtureKey) must explicitly declare notebookSyncStatus"
            )
            if let entry = seed["entry"] as? [String: Any] {
                let word = entry["word"] as? String ?? "<missing-word>"
                let missing = requiredUIWorldEntryKeys.subtracting(entry.keys)
                #expect(
                    missing.isEmpty,
                    "\(dataset): reader.\(fixtureKey).entry.\(word) missing row state keys \(missing.sorted())"
                )
                let unknown = Set(entry.keys).subtracting(uiWorldEntryKeys)
                #expect(
                    unknown.isEmpty,
                    "\(dataset): reader.\(fixtureKey).entry.\(word) contains unknown keys \(unknown.sorted())"
                )
            }
        }

        for domain in ["vocabulary", "reviewDeck"] {
            let fixtures = topLevel[domain] as? [String: [String: Any]] ?? [:]
            for (fixtureKey, seed) in fixtures {
                let seedKeys = domain == "vocabulary" ? vocabularySeedKeys : reviewDeckSeedKeys
                let unknownSeedKeys = Set(seed.keys).subtracting(seedKeys)
                #expect(
                    unknownSeedKeys.isEmpty,
                    "\(dataset): \(domain).\(fixtureKey) contains unknown keys \(unknownSeedKeys.sorted())"
                )
                #expect(
                    seed.keys.contains("notebookSyncStatus"),
                    "\(dataset): \(domain).\(fixtureKey) must explicitly declare notebookSyncStatus"
                )
                if domain == "reviewDeck" {
                    for key in ["notebookRemoteId", "notebookName"] {
                        #expect(
                            seed[key] is String,
                            "\(dataset): reviewDeck.\(fixtureKey) must explicitly declare non-null \(key)"
                        )
                    }
                }
                let entries = seed["entries"] as? [[String: Any]] ?? []
                for entry in entries {
                    let word = entry["word"] as? String ?? "<missing-word>"
                    let missing = requiredUIWorldEntryKeys.subtracting(entry.keys)
                    #expect(
                        missing.isEmpty,
                        "\(dataset): \(domain).\(fixtureKey).entry.\(word) missing row state keys \(missing.sorted())"
                    )
                    let unknown = Set(entry.keys).subtracting(uiWorldEntryKeys)
                    #expect(
                        unknown.isEmpty,
                        "\(dataset): \(domain).\(fixtureKey).entry.\(word) contains unknown keys \(unknown.sorted())"
                    )
                }
                if domain == "vocabulary" {
                    let reviewHistory = seed["reviewHistory"] as? [[String: Any]] ?? []
                    for record in reviewHistory {
                        let word = record["word"] as? String ?? "<missing-word>"
                        let missing = reviewHistoryKeys.subtracting(record.keys)
                        #expect(
                            missing.isEmpty,
                            "\(dataset): vocabulary.\(fixtureKey).reviewHistory.\(word) missing keys \(missing.sorted())"
                        )
                        let unknown = Set(record.keys).subtracting(reviewHistoryKeys)
                        #expect(
                            unknown.isEmpty,
                            "\(dataset): vocabulary.\(fixtureKey).reviewHistory.\(word) contains unknown keys \(unknown.sorted())"
                        )
                    }
                }
            }
        }
    }

    private func expectSyncPresenterKeys(_ topLevel: [String: Any], dataset: String) {
        guard let fixtures = topLevel["syncPresenter"] as? [String: [String: Any]] else {
            Issue.record("\(dataset): UI World must explicitly declare syncPresenter")
            return
        }
        let requiredSeedKeys: Set<String> = [
            "isLoggedIn",
            "isConnected",
            "phase",
            "failureKind",
            "pendingCount",
            "addCount",
            "deleteCount",
            "steps",
            "summaryText",
            "pendingRows",
        ]
        let requiredStepKeys: Set<String> = ["id", "label", "status", "current", "total", "detail"]
        let requiredPendingRowKeys: Set<String> = [
            "id",
            "word",
            "partOfSpeech",
            "translation",
            "wordTone",
            "isStrikethrough",
            "actionSystemImage",
            "actionTone",
            "actionAccessibilityLabel",
        ]
        let validPhases = ["ready", "running", "completed", "failed"]
        let validFailureKinds = ["partial", "full", "cancelled"]
        let validStepStatuses = ["waiting", "running", "retry", "done", "skipped", "error"]
        let validTones = ["primary", "secondary", "tertiary", "quaternary", "destructive", "reviewDue"]

        for (fixtureKey, seed) in fixtures {
            let missingSeedKeys = requiredSeedKeys.subtracting(seed.keys)
            #expect(
                missingSeedKeys.isEmpty,
                "\(dataset): syncPresenter.\(fixtureKey) missing keys \(missingSeedKeys.sorted())"
            )
            let unknownSeedKeys = Set(seed.keys).subtracting(requiredSeedKeys)
            #expect(
                unknownSeedKeys.isEmpty,
                "\(dataset): syncPresenter.\(fixtureKey) contains unknown keys \(unknownSeedKeys.sorted())"
            )

            let phase = seed["phase"] as? String ?? "<missing-phase>"
            #expect(validPhases.contains(phase), "\(dataset): syncPresenter.\(fixtureKey).phase is invalid")
            if let failureKind = seed["failureKind"] as? String {
                #expect(
                    validFailureKinds.contains(failureKind),
                    "\(dataset): syncPresenter.\(fixtureKey).failureKind is invalid"
                )
                #expect(phase == "failed", "\(dataset): syncPresenter.\(fixtureKey) non-null failureKind requires failed phase")
            } else {
                #expect(
                    seed["failureKind"] is NSNull || seed.keys.contains("failureKind"),
                    "\(dataset): syncPresenter.\(fixtureKey).failureKind must be explicit null when absent"
                )
            }

            let pendingCount = seed["pendingCount"] as? Int ?? -1
            let addCount = seed["addCount"] as? Int ?? -1
            let deleteCount = seed["deleteCount"] as? Int ?? -1
            #expect(pendingCount >= 0, "\(dataset): syncPresenter.\(fixtureKey).pendingCount must be non-negative")
            #expect(addCount >= 0, "\(dataset): syncPresenter.\(fixtureKey).addCount must be non-negative")
            #expect(deleteCount >= 0, "\(dataset): syncPresenter.\(fixtureKey).deleteCount must be non-negative")
            #expect(
                pendingCount == addCount + deleteCount,
                "\(dataset): syncPresenter.\(fixtureKey).pendingCount must equal addCount + deleteCount"
            )

            let steps = seed["steps"] as? [[String: Any]] ?? []
            for step in steps {
                let id = step["id"] as? String ?? "<missing-id>"
                let missingStepKeys = requiredStepKeys.subtracting(step.keys)
                #expect(
                    missingStepKeys.isEmpty,
                    "\(dataset): syncPresenter.\(fixtureKey).steps.\(id) missing keys \(missingStepKeys.sorted())"
                )
                let unknownStepKeys = Set(step.keys).subtracting(requiredStepKeys)
                #expect(
                    unknownStepKeys.isEmpty,
                    "\(dataset): syncPresenter.\(fixtureKey).steps.\(id) contains unknown keys \(unknownStepKeys.sorted())"
                )
                let status = step["status"] as? String ?? "<missing-status>"
                #expect(
                    validStepStatuses.contains(status),
                    "\(dataset): syncPresenter.\(fixtureKey).steps.\(id).status is invalid"
                )
                #expect((step["current"] as? Int ?? -1) >= 0, "\(dataset): syncPresenter.\(fixtureKey).steps.\(id).current must be non-negative")
                #expect((step["total"] as? Int ?? -1) >= 0, "\(dataset): syncPresenter.\(fixtureKey).steps.\(id).total must be non-negative")
            }

            let pendingRows = seed["pendingRows"] as? [[String: Any]] ?? []
            if phase == "ready" {
                #expect(
                    pendingRows.count == pendingCount,
                    "\(dataset): syncPresenter.\(fixtureKey).pendingRows count must equal pendingCount in ready phase"
                )
            }
            for row in pendingRows {
                let word = row["word"] as? String ?? "<missing-word>"
                let missingRowKeys = requiredPendingRowKeys.subtracting(row.keys)
                #expect(
                    missingRowKeys.isEmpty,
                    "\(dataset): syncPresenter.\(fixtureKey).pendingRows.\(word) missing keys \(missingRowKeys.sorted())"
                )
                let unknownRowKeys = Set(row.keys).subtracting(requiredPendingRowKeys)
                #expect(
                    unknownRowKeys.isEmpty,
                    "\(dataset): syncPresenter.\(fixtureKey).pendingRows.\(word) contains unknown keys \(unknownRowKeys.sorted())"
                )
                let id = row["id"] as? String ?? ""
                #expect(UUID(uuidString: id) != nil, "\(dataset): syncPresenter.\(fixtureKey).pendingRows.\(word).id must be UUID")
                for key in ["wordTone", "actionTone"] {
                    let tone = row[key] as? String ?? "<missing-tone>"
                    #expect(
                        validTones.contains(tone),
                        "\(dataset): syncPresenter.\(fixtureKey).pendingRows.\(word).\(key) is invalid"
                    )
                }
            }
        }
    }

    private func expectNotebookEditStateKeys(_ editState: [String: Any], document: FixtureDatasetDocument, dataset: String, owner: String) {
        let requiredKeys: Set<String> = ["id", "mode", "name", "color", "coverPattern", "coverImageAssetRef"]
        let unknownKeys = Set(editState.keys).subtracting(requiredKeys)
        #expect(unknownKeys.isEmpty, "\(dataset): \(owner) contains unknown keys \(unknownKeys.sorted())")
        for key in requiredKeys {
            #expect(editState.keys.contains(key), "\(dataset): \(owner) must explicitly declare \(key)")
        }
        let mode = editState["mode"] as? String ?? "<missing-mode>"
        #expect(["create", "edit"].contains(mode), "\(dataset): \(owner).mode must be create or edit")
        if mode == "create" {
            #expect((editState["name"] as? String ?? "<missing-name>").isEmpty, "\(dataset): \(owner) create mode must have an empty name")
            #expect(editState["color"] is NSNull, "\(dataset): \(owner) create mode color must be null")
            #expect(editState["coverPattern"] is NSNull, "\(dataset): \(owner) create mode coverPattern must be null")
            #expect(editState["coverImageAssetRef"] is NSNull, "\(dataset): \(owner) create mode coverImageAssetRef must be null")
        }
        if let coverPattern = editState["coverPattern"] as? String {
            #expect(!coverPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(dataset): \(owner).coverPattern must not be blank")
        }
        if let coverImageAssetRef = editState["coverImageAssetRef"] as? String {
            expectAssetRef(
                coverImageAssetRef,
                document: document,
                expectedPrefix: "images.",
                dataset: dataset,
                owner: "\(owner).coverImageAssetRef"
            )
        }
    }

    private func expectNotebookCardStateKeys(_ cardState: [String: Any], dataset: String, owner: String) {
        let requiredKeys: Set<String> = ["cardCount", "dueCount", "unlearnedCount", "reviewedCount", "pendingCount", "lastActivity", "isActive"]
        let unknownKeys = Set(cardState.keys).subtracting(requiredKeys)
        #expect(unknownKeys.isEmpty, "\(dataset): \(owner) contains unknown keys \(unknownKeys.sorted())")
        for key in requiredKeys {
            #expect(cardState.keys.contains(key), "\(dataset): \(owner) must explicitly declare \(key)")
        }
        let cardCount = cardState["cardCount"] as? Int ?? -1
        let dueCount = cardState["dueCount"] as? Int ?? -1
        let unlearnedCount = cardState["unlearnedCount"] as? Int ?? -1
        let reviewedCount = cardState["reviewedCount"] as? Int ?? -1
        let pendingCount = cardState["pendingCount"] as? Int ?? -1
        #expect(cardCount >= 0, "\(dataset): \(owner).cardCount must be non-negative")
        #expect(dueCount >= 0, "\(dataset): \(owner).dueCount must be non-negative")
        #expect(unlearnedCount >= 0, "\(dataset): \(owner).unlearnedCount must be non-negative")
        #expect(reviewedCount >= 0, "\(dataset): \(owner).reviewedCount must be non-negative")
        #expect(pendingCount >= 0, "\(dataset): \(owner).pendingCount must be non-negative")
        #expect(
            cardCount == dueCount + unlearnedCount + reviewedCount,
            "\(dataset): \(owner).cardCount must equal dueCount + unlearnedCount + reviewedCount"
        )
        if cardState["isActive"] as? Bool == true {
            #expect(cardCount > 0, "\(dataset): \(owner) active card must not be empty")
        }
    }

    private func expectNotebookSyncStatus(_ syncStatus: Int, dataset: String, owner: String) {
        #expect(
            [0, 1].contains(syncStatus),
            "\(dataset): \(owner) must be a valid Notebook.syncStatus (0=pending, 1=synced)"
        )
    }

    private func expectAuthKeychainState(
        _ seed: UIWorldAuthSeed,
        dataset: String,
        owner: String
    ) {
        switch seed.keychainTokenState {
        case .available:
            #expect(seed.isLoggedIn, "\(dataset): \(owner) keychainTokenState=available requires isLoggedIn=true")
            #expect(
                seed.token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "\(dataset): \(owner) keychainTokenState=available requires non-empty token"
            )
        case .readFailed:
            #expect(seed.isLoggedIn, "\(dataset): \(owner) keychainTokenState=readFailed requires isLoggedIn=true")
            #expect(seed.userId != nil, "\(dataset): \(owner) keychainTokenState=readFailed requires persisted userId")
            #expect(seed.token == nil, "\(dataset): \(owner) keychainTokenState=readFailed must not also expose a readable token")
        case .absent:
            #expect(!seed.isLoggedIn, "\(dataset): \(owner) keychainTokenState=absent requires isLoggedIn=false")
            #expect(seed.token == nil, "\(dataset): \(owner) keychainTokenState=absent must not include token")
        }
        if seed.isLoggedIn {
            #expect(!seed.isAuthenticating, "\(dataset): \(owner) logged-in auth seed must not also be authenticating")
            #expect(seed.authError == nil, "\(dataset): \(owner) logged-in auth seed must not carry login error copy")
        }
    }

    private func expectSettingsStateRefs(
        _ seed: SettingsFixtureSeed,
        document: FixtureDatasetDocument,
        dataset: String,
        owner: String
    ) {
        let authRef = seed.authFixtureRef.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(authRef.hasPrefix("auth."), "\(dataset): \(owner).authFixtureRef must point into auth.*, got \(authRef)")
        let authKey = String(authRef.dropFirst("auth.".count))
        guard let authSeed = document.auth[authKey] else {
            Issue.record("\(dataset): \(owner).authFixtureRef references missing \(authRef)")
            return
        }
        #expect(
            seed.auth.isLoggedIn == authSeed.isLoggedIn,
            "\(dataset): \(owner).auth.isLoggedIn must match \(authRef).isLoggedIn"
        )
        #expect(
            seed.auth.authError == authSeed.authError,
            "\(dataset): \(owner).auth.authError must match \(authRef).authError"
        )
        if seed.auth.isLoggedIn {
            #expect(
                seed.auth.email == authSeed.email,
                "\(dataset): \(owner).auth.email must match \(authRef).email"
            )
            #expect(
                seed.auth.displayName == authSeed.displayName,
                "\(dataset): \(owner).auth.displayName must match \(authRef).displayName"
            )
        }

        if let entitlementsRef = seed.entitlementsFixtureRef?.trimmingCharacters(in: .whitespacesAndNewlines) {
            #expect(
                entitlementsRef.hasPrefix("entitlements."),
                "\(dataset): \(owner).entitlementsFixtureRef must point into entitlements.*, got \(entitlementsRef)"
            )
            let entitlementsKey = String(entitlementsRef.dropFirst("entitlements.".count))
            guard let entitlementsSeed = document.entitlements[entitlementsKey] else {
                Issue.record("\(dataset): \(owner).entitlementsFixtureRef references missing \(entitlementsRef)")
                return
            }
            if let subscription = seed.subscription, !subscription.isRefreshing {
                #expect(
                    subscription.isActive == entitlementsSeed.pro.is_active,
                    "\(dataset): \(owner).subscription.isActive must match \(entitlementsRef).pro.is_active"
                )
            }
        } else {
            #expect(seed.subscription == nil, "\(dataset): \(owner) without entitlementsFixtureRef must not declare subscription UI state")
        }
    }

    private func expectVocabularyRowState(
        _ entry: UIWorldVocabularyEntrySeed,
        dataset: String,
        owner: String
    ) {
        expectVocabularyRowState(
            syncStatus: entry.syncStatus,
            actionType: entry.actionType,
            isArchived: entry.isArchived,
            dataset: dataset,
            owner: owner
        )
    }

    private func expectNotebookEntryRowState(
        _ entry: NotebookEntrySeed,
        dataset: String,
        owner: String
    ) {
        expectVocabularyRowState(
            syncStatus: entry.syncStatus,
            actionType: entry.actionType,
            isArchived: entry.isArchived,
            dataset: dataset,
            owner: owner
        )
    }

    private func expectVocabularyRowState(
        syncStatus: Int,
        actionType: String,
        isArchived: Bool,
        dataset: String,
        owner: String
    ) {
        #expect(
            [0, 1, 2].contains(syncStatus),
            "\(dataset): \(owner).syncStatus must be valid VocabularyEntry.syncStatus (0=pending, 1=synced, 2=failed)"
        )
        #expect(
            ["add", "delete", "edit"].contains(actionType),
            "\(dataset): \(owner).actionType must be add/delete/edit"
        )
        _ = isArchived
    }

    private func expectInstallableAssetRef(
        _ ref: String,
        document: FixtureDatasetDocument,
        dataset: String,
        owner: String
    ) {
        guard let asset = document.assets.asset(for: ref) else {
            Issue.record("\(dataset): \(owner) \(ref) is not declared")
            return
        }
        let installAs = asset.installAs.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!installAs.isEmpty, "\(dataset): \(owner) \(ref) must declare installAs so the asset is materialized into the app container")
    }

    private func expectDownloadLocalPath(
        _ localPath: String?,
        assetRef: String,
        document: FixtureDatasetDocument,
        dataset: String,
        owner: String
    ) {
        guard let asset = document.assets.asset(for: assetRef) else {
            Issue.record("\(dataset): \(owner) cannot validate local path because \(assetRef) is not declared")
            return
        }
        #expect(
            localPath == asset.installAs,
            "\(dataset): \(owner) must match \(assetRef).installAs \(asset.installAs), got \(localPath ?? "nil")"
        )
    }

    private func expectAssetRef(
        _ ref: String,
        document: FixtureDatasetDocument,
        expectedPrefix: String,
        dataset: String,
        owner: String
    ) {
        #expect(ref.hasPrefix(expectedPrefix), "\(dataset): \(owner) must point into assets.\(expectedPrefix), got \(ref)")
        guard document.assets.asset(for: ref) != nil else {
            Issue.record("\(dataset): \(owner) \(ref) is not declared")
            return
        }
    }

    private func expectUniqueInstallPaths(document: FixtureDatasetDocument, dataset: String) {
        var seen: [String: String] = [:]
        for ref in document.assets.refs {
            guard let asset = document.assets.asset(for: ref) else {
                continue
            }
            let installAs = asset.installAs.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !installAs.isEmpty else { continue }
            if let previous = seen[installAs] {
                Issue.record("\(dataset): assets \(previous) and \(ref) share installAs \(installAs)")
            } else {
                seen[installAs] = ref
            }
        }
    }

    private func expectValidPreferenceKeys(
        _ keys: some Sequence<String>,
        dataset: String,
        domain: String
    ) {
        for key in keys {
            #expect(
                !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(dataset): \(domain) contains an empty key"
            )
        }
    }

    private func expectBookAssetRef(
        _ ref: String,
        document: FixtureDatasetDocument,
        dataset: String,
        owner: String,
        fileName: String,
        format: BookFormat
    ) {
        #expect(ref.hasPrefix("books."), "\(dataset): \(owner) bookAssetRef must point into assets.books, got \(ref)")
        guard let asset = document.assets.asset(for: ref) else {
            Issue.record("\(dataset): \(owner) \(ref) is not declared")
            return
        }
        let installAs = asset.installAs.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            installAs == "Books/\(fileName)",
            "\(dataset): \(owner) \(ref) must install as Books/\(fileName), got \(installAs)"
        )
        let expectedContentType: String
        switch format {
        case .epub:
            expectedContentType = "application/epub+zip"
        case .pdf:
            expectedContentType = "application/pdf"
        case .md:
            expectedContentType = "text/markdown; charset=utf-8"
        case .txt:
            expectedContentType = "text/plain; charset=utf-8"
        }
        #expect(
            asset.contentType == expectedContentType,
            "\(dataset): \(owner) format \(format.rawValue) requires \(expectedContentType), got \(asset.contentType)"
        )
    }
}
#endif
