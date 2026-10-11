#if DEBUG
import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@Suite(.serialized) struct SettingsFixturesTests {
    private static var marketingDemoData: Data {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // BooksAndVocabTests
                .deletingLastPathComponent() // ios
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("ops/fixtures/ui_worlds/marketing_demo.json")
            return try Data(contentsOf: url)
        }
    }

    private static var generatedDemoData: Data {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // BooksAndVocabTests
                .deletingLastPathComponent() // ios
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("ops/demo/generated/ios_fixture_dataset.json")
            return try Data(contentsOf: url)
        }
    }

    @Test func settingsFixtureRegistryExposesPreviewAndCatalogScenarios() async throws {
        let previewKeys = SettingsFixtures.recipes(for: .preview).map(\.key.rawValue)
        let catalogKeys = SettingsFixtures.recipes(for: .catalog).map(\.key.rawValue)

        // The enum manifest is the only ordering contract. Do not duplicate the
        // fixture list here: a new fixture must update one SoT, not this test.
        let expectedKeys = SettingsFixtureID.allCases
            .filter { $0 != .syncTerminalErrorRetrySuccess }
            .map { $0.key.rawValue }
        #expect(Set(expectedKeys).count == expectedKeys.count)
        #expect(previewKeys == expectedKeys)

        #expect(catalogKeys == previewKeys)
    }

    @Test func settingsFixtureRegistryIsManifestOnly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BooksAndVocabTests
            .deletingLastPathComponent() // ios
            .appendingPathComponent("BooksAndVocab/Support/Fixtures/Settings/SettingsFixtures.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let registryStart = try #require(source.range(of: "private static let registry"))
        let registryEnd = try #require(source.range(of: "static func recipes", range: registryStart.upperBound..<source.endIndex))
        let registrySource = String(source[registryStart.lowerBound..<registryEnd.lowerBound])

        #expect(registrySource.contains("SettingsFixtureID.allCases.map"))
        #expect(registrySource.contains("FixtureDatasetStore.requireSettingsSeed(for: fixtureID)"))
        #expect(!registrySource.contains(".init("), "Settings fixture registry must not construct local seed data")
    }

    @Test func repoAndGeneratedDatasetsDeclareNoUnknownSettingsFixtureKey() throws {
        let expected = Set(SettingsFixtureID.allCases.map(\.rawValue))
        let repoDocument = try FixtureDatasetStore.decode(Self.marketingDemoData)
        let generatedDocument = try FixtureDatasetStore.decode(Self.generatedDemoData)

        // FROZEN 2026-08-05 — 凍結前這兩行是雙向 `==`（world keys 必須等於 allCases），
        // 那是「加一個 FixtureID 就得回填兩份 world」的稅源。現只驗單向：world 不得含
        // app 不認識的 key（那種 key 永遠不會 render）。兩行各配一個 non-empty 正控——
        // 沒有正控的 subset 對空集合恆真（假綠）。復業第一步＝改回 `==`，完整配方見正本。
        // 正本 docs/reference/catalog_scope.md §FROZEN。
        #expect(!repoDocument.settings.isEmpty)
        #expect(Set(repoDocument.settings.keys).isSubset(of: expected))
        #expect(!generatedDocument.settings.isEmpty)
        #expect(Set(generatedDocument.settings.keys).isSubset(of: expected))
    }

    @Test func p15SettingsFixtureOrderMatchesBothV2WorldsAndSwiftRegistry() throws {
        let expected = SettingsFixtureID.allCases.map(\.rawValue)

        #expect(try Self.objectMemberOrder(Self.marketingDemoData, key: "settings") == expected)
        #expect(try Self.objectMemberOrder(Self.generatedDemoData, key: "settings") == expected)
    }

    @Test func subscriptionFreeFixtureComesFromUIWorld() async throws {
        try FixtureDatasetStore.withTestingData(Self.marketingDemoData) {
            let state = SettingsFixtures.state(for: .subscriptionFree)
            let subscription = try #require(state.subscription)
            #expect(subscription.isActive == false)
            #expect(subscription.planName == "免費方案")
            #expect(subscription.ctaTitle == "升級 Pro")
        }
    }

    @Test func accountLongIdentityFixtureComesFromUIWorld() async throws {
        try FixtureDatasetStore.withTestingData(Self.marketingDemoData) {
            let state = SettingsFixtures.state(for: .accountLongIdentity)
            #expect(state.auth.isLoggedIn == true)
            #expect(state.auth.displayName.contains("Wonderfully Long Display Name"))
            #expect(state.auth.email?.contains("layout.testing") == true)
            #expect(state.subscription?.isActive == true)
            #expect(state.danger?.isDeletingAccount == false)
        }
    }

    @Test func accountLoggedOutErrorFixtureComesFromUIWorld() async throws {
        try FixtureDatasetStore.withTestingData(Self.marketingDemoData) {
            let state = SettingsFixtures.state(for: .accountLoggedOutError)
            #expect(state.auth.isLoggedIn == false)
            #expect(state.auth.authError == "無法連線至驗證伺服器，請稍後再試。")
            #expect(state.subscription == nil)
            #expect(state.danger == nil)
        }
    }

    @Test func preferencesFixturesComeFromUIWorld() async throws {
        try FixtureDatasetStore.withTestingData(Self.marketingDemoData) {
            let autoSyncOff = SettingsFixtures.state(for: .preferencesAutoSyncOff).preferences
            #expect(autoSyncOff.selectedLanguage == "English")
            #expect(autoSyncOff.selectedAppearance == "淺色")
            #expect(autoSyncOff.translationTarget == "日本語")
            #expect(autoSyncOff.selectedReviewMode == "密集")
            #expect(autoSyncOff.autoSyncEnabled == false)
            #expect(autoSyncOff.showAutoSync == true)

            let loggedOut = SettingsFixtures.state(for: .preferencesLoggedOutNoSync).preferences
            #expect(loggedOut.selectedAppearance == "深色")
            #expect(loggedOut.selectedReviewMode == "已凍結 · 自訂")
            #expect(loggedOut.autoSyncEnabled == false)
            #expect(loggedOut.showAutoSync == false)
        }
    }

    @Test func reviewSettingsFixturesComeFromUIWorld() async throws {
        try FixtureDatasetStore.withTestingData(Self.marketingDemoData) {
            let relaxed = SettingsFixtures.reviewSettings(for: .subscriptionFree)
            #expect(relaxed.mode == .relaxed)
            #expect(relaxed.customInitialIntervalHours == 12)
            #expect(relaxed.isProgressPaused == false)

            let intensive = SettingsFixtures.reviewSettings(for: .preferencesAutoSyncOff)
            #expect(intensive.mode == .intensive)
            #expect(intensive.autoplaySpeed == .fast)

            let custom = SettingsFixtures.reviewSettings(for: .accountLongIdentity)
            #expect(custom.mode == .custom)
            #expect(custom.customInitialIntervalHours == 24)
            #expect(custom.customMaximumIntervalHours == 2160)

            let paused = SettingsFixtures.reviewSettings(for: .preferencesLoggedOutNoSync)
            #expect(paused.mode == .relaxed)
            #expect(paused.isProgressPaused == true)
            #expect(paused.progressPausedAt == Date(timeIntervalSince1970: 1_733_500_000))
        }
    }

    @Test func p15SettingsCounterexamplesAndInformationArchitectureContract() throws {
        let document = try FixtureDatasetStore.decode(Self.marketingDemoData)
        let expectedCounterexamples = [
            "long_content_counterexample",
            "reset_counterexample",
        ]

        for fixtureID in expectedCounterexamples {
            #expect(document.settings[fixtureID] != nil, "UI World must inject settings.\(fixtureID)")
        }

        let settingsSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BooksAndVocabTests
            .deletingLastPathComponent() // ios
            .appendingPathComponent("BooksAndVocab/Views/Settings/SettingsPreferencesSection.swift")
        let settingsSource = try String(contentsOf: settingsSourceURL, encoding: .utf8)
        for identifier in [
            "settings.preferences.appearanceGroup",
            "settings.preferences.learningGroup",
            "settings.preferences.feedbackGroup",
            "settings.preferences.readerGroup",
            "settings.preferences.syncGroup",
        ] {
            #expect(settingsSource.contains(identifier), "Settings section selector missing: \(identifier)")
        }

        let accountDetailURL = settingsSourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("SettingsAccountDetailView.swift")
        let accountDetailSource = try String(contentsOf: accountDetailURL, encoding: .utf8)
        #expect(accountDetailSource.contains("settings.account.dangerGroup"))
    }

    @Test func p15SettingsAccessibilityContractMatchesExactPageObjectElementTypes() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preferencesSource = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "BooksAndVocab/Views/Settings/SettingsPreferencesSection.swift"
            ),
            encoding: .utf8
        )
        let detailSource = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "BooksAndVocab/Views/Settings/SettingsAccountDetailView.swift"
            ),
            encoding: .utf8
        )
        let accountSource = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "BooksAndVocab/Views/Settings/SettingsAccountSection.swift"
            ),
            encoding: .utf8
        )
        let pageObjectSource = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "BooksAndVocabUITests/Pages/SettingsSheetPage.swift"
            ),
            encoding: .utf8
        )
        let flowSource = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "BooksAndVocabUITests/SettingsFlowUITests.swift"
            ),
            encoding: .utf8
        )

        let preferenceGroups = [
            "settings.preferences.appearanceGroup",
            "settings.preferences.learningGroup",
            "settings.preferences.feedbackGroup",
            "settings.preferences.readerGroup",
            "settings.preferences.syncGroup",
        ]
        for identifier in preferenceGroups {
            #expect(pageObjectSource.contains("exact(.other, \"\(identifier)\")"))
            #expect(sourceIdentifierIsContained(identifier, in: preferencesSource))
        }

        let accountGroups = [
            "settings.account.infoGroup",
            "settings.account.dataManagementGroup",
            "settings.account.dangerGroup",
            "settings.account.resetBoundary",
            "settings.account.resetBoundary.before",
            "settings.account.resetBoundary.after",
        ]
        for identifier in accountGroups {
            #expect(sourceIdentifierIsContained(identifier, in: detailSource))
        }
        #expect(pageObjectSource.contains("exact(.other, \"settings.account.dangerGroup\")"))
        #expect(pageObjectSource.contains("exact(.other, \"settings.account.resetBoundary\")"))
        #expect(pageObjectSource.contains("exact(.button, \"settings.account.accountDetailRow\")"))
        #expect(accountSource.contains("SettingsCardNavigationRow"))
        #expect(accountSource.contains(".accessibilityIdentifier(\"settings.account.accountDetailRow\")"))

        #expect(pageObjectSource.contains("private func exact(_ type: XCUIElement.ElementType, _ identifier: String)"))
        #expect(pageObjectSource.contains("app.descendants(matching: type)"))
        #expect(pageObjectSource.contains("matching(identifier: identifier)"))

        let typedPageSelectors: [(type: String, identifier: String)] = [
            ("button", "settings.dismissButton"),
            ("button", "settings.account.accountDetailRow"),
            ("button", "settings.account.resetBoundary.resetButton"),
            ("button", "settings.detail.backButton"),
            ("scrollView", "settings.home.scrollView"),
            ("scrollView", "settings.account.scrollView"),
            ("staticText", "settings.preferences.reviewRhythmValue"),
            ("staticText", "settings.preferences.translationLanguageValue"),
            ("staticText", "settings.account.info.name"),
            ("staticText", "settings.account.resetBoundary.phase"),
            ("switch", "settings.preferences.soundFeedbackToggle"),
            ("switch", "settings.preferences.hapticFeedbackToggle"),
            ("switch", "settings.review.pauseToggle"),
            ("other", "settings.preferences.appearanceGroup"),
            ("other", "settings.preferences.syncGroup"),
            ("other", "settings.account.dangerGroup"),
            ("other", "settings.account.resetBoundary"),
        ]
        for selector in typedPageSelectors {
            #expect(pageObjectSource.contains("exact(.\(selector.type), \"\(selector.identifier)\")"))
        }

        // Reviewer BLOCK: a Settings selector must resolve the production
        // contract itself. A firstMatch/boundBy:0 lookup can pass while the
        // wrong element is present or duplicated.
        #expect(!pageObjectSource.contains("firstMatch"))
        #expect(!pageObjectSource.contains("element(boundBy: 0)"))
        #expect(!flowSource.contains("firstMatch"))
        #expect(!flowSource.contains("element(boundBy: 0)"))
        #expect(flowSource.contains("assertExactlyOne"))
        #expect(flowSource.contains("assertAccountDetailEvidence"))
    }

    @Test func p15SettingsLiveConfigErrorsRemainTypedAndVisible() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinatorSource = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "BooksAndVocab/Views/Settings/SettingsCoordinator.swift"
            ),
            encoding: .utf8
        )
        let presentationSource = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "BooksAndVocab/Views/Settings/SettingsPresentation.swift"
            ),
            encoding: .utf8
        )
        let stateSource = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "BooksAndVocab/Views/Settings/SettingsView+State.swift"
            ),
            encoding: .utf8
        )
        let presenterSource = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "BooksAndVocab/Views/Settings/SettingsPresenter.swift"
            ),
            encoding: .utf8
        )

        #expect(coordinatorSource.contains("configurationIssue"))
        #expect(presentationSource.contains("SettingsConfigurationIssue"))
        #expect(stateSource.contains("configurationIssue: coordinator.configurationIssue"))
        #expect(presenterSource.contains("settings.configuration.error"))
    }

    @Test func p15SettingsCounterexampleWorldRejectsMissingAndUnknownFields() throws {
        var missingLongEvidence = try Self.jsonObject(Self.marketingDemoData)
        var longSettings = try #require(missingLongEvidence["settings"] as? [String: Any])
        var longSeed = try #require(longSettings["long_content_counterexample"] as? [String: Any])
        longSeed.removeValue(forKey: "evidence")
        longSettings["long_content_counterexample"] = longSeed
        missingLongEvidence["settings"] = longSettings
        #expect(throws: DecodingError.self) {
            try FixtureDatasetStore.decode(try Self.jsonData(missingLongEvidence))
        }

        var missingResetAfter = try Self.jsonObject(Self.marketingDemoData)
        var resetSettings = try #require(missingResetAfter["settings"] as? [String: Any])
        var resetSeed = try #require(resetSettings["reset_counterexample"] as? [String: Any])
        var resetLifecycle = try #require(resetSeed["resetLifecycle"] as? [String: Any])
        resetLifecycle.removeValue(forKey: "after")
        resetSeed["resetLifecycle"] = resetLifecycle
        resetSettings["reset_counterexample"] = resetSeed
        missingResetAfter["settings"] = resetSettings
        #expect(throws: DecodingError.self) {
            try FixtureDatasetStore.decode(try Self.jsonData(missingResetAfter))
        }

        var unknownResetField = try Self.jsonObject(Self.marketingDemoData)
        var unknownSettings = try #require(unknownResetField["settings"] as? [String: Any])
        var unknownSeed = try #require(unknownSettings["reset_counterexample"] as? [String: Any])
        var unknownLifecycle = try #require(unknownSeed["resetLifecycle"] as? [String: Any])
        unknownLifecycle["unexpectedField"] = true
        unknownSeed["resetLifecycle"] = unknownLifecycle
        unknownSettings["reset_counterexample"] = unknownSeed
        unknownResetField["settings"] = unknownSettings
        #expect(throws: DecodingError.self) {
            try FixtureDatasetStore.decode(try Self.jsonData(unknownResetField))
        }
    }

    @Test func p15LiveResetSnapshotReadFailureCannotBecomeZero() throws {
        let resetStoreURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BooksAndVocab/Views/Settings/SettingsResetStore.swift")
        let resetStoreSource = try String(contentsOf: resetStoreURL, encoding: .utf8)

        #expect(resetStoreSource.contains("unreadableLocalCardCount"))
        #expect(!resetStoreSource.contains("localCardCount = 0"))
    }

    @Test func p15ResetFailureInjectorMustCleanupBeforeThrowing() throws {
        let syncURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BooksAndVocab/Services/KGService+Sync.swift")
        let syncSource = try String(contentsOf: syncURL, encoding: .utf8)
        let actorURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BooksAndVocab/Services/BackgroundSyncActor.swift")
        let actorSource = try String(contentsOf: actorURL, encoding: .utf8)

        #expect(syncSource.contains("clearFirstUserDataForInjectedFailure"))
        #expect(syncSource.contains("try await actor.clearFirstUserDataForInjectedFailure()"))
        #expect(actorSource.contains("throw SettingsResetFailureInjectionError.noResetVisibleCard"))
        #expect(!syncSource.contains("kg.ui.test.settings.reset.failure.consumed"))
    }

    @Test @MainActor func p15FailureInjectorCommitsLiveSwiftDataPartialState() async throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let first = VocabularyEntry(word: "inject-first", translation: "t", context: "c", bookTitle: "b")
        let second = VocabularyEntry(word: "inject-second", translation: "t", context: "c", bookTitle: "b")
        first.markSynced()
        second.markSynced()
        context.insert(first)
        context.insert(second)
        try context.save()

        let before = try context.fetchCount(FetchDescriptor<VocabularyEntry>())
        let actor = BackgroundSyncActor(modelContainer: container)
        try await actor.clearFirstUserDataForInjectedFailure()
        let afterContext = ModelContext(container)
        let after = try afterContext.fetchCount(FetchDescriptor<VocabularyEntry>())

        #expect(before == 2)
        #expect(after == 1)
    }

    @Test func p15ResetFixtureSharesTheApplicationMainContext() throws {
        let seedSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BooksAndVocab/Support/UITestFixtureSeed+Settings.swift")
        let seedSource = try String(contentsOf: seedSourceURL, encoding: .utf8)

        #expect(seedSource.contains("let context = container.mainContext"))
        #expect(!seedSource.contains("let context = ModelContext(container)"))
    }

    @Test func p15EvidenceContractBindsRequiredAndCounterexampleAssetsOneToOne() throws {
        let expected: [(fixtureID: String, label: String, assetID: String, stepLabel: String)] = [
            ("preferences_auto_sync_off", "required-settings", "settings-required", "required-settings"),
            ("preferences_logged_out_no_sync", "section-navigation", "settings-section-navigation", "section-navigation"),
            ("long_content_counterexample", "long-content-counterexample", "settings-long-content-counterexample", "long-content-counterexample"),
            ("reset_counterexample", "reset-counterexample", "settings-reset-counterexample", "reset-counterexample"),
        ]
        let requiredAssetIDs = Set(expected.prefix(2).map(\.assetID))
        let counterexampleAssetIDs = Set(expected.suffix(2).map(\.assetID))
        #expect(requiredAssetIDs.isDisjoint(with: counterexampleAssetIDs))

        for data in [try Self.marketingDemoData, try Self.generatedDemoData] {
            let root = try Self.jsonObject(data)
            let settings = try #require(root["settings"] as? [String: Any])
            var assetIDs: [String] = []

            for contract in expected {
                let seed = try #require(settings[contract.fixtureID] as? [String: Any])
                let evidence = try #require(seed["evidence"] as? [String: Any])
                #expect(evidence["label"] as? String == contract.label)
                #expect(evidence["assetID"] as? String == contract.assetID)
                #expect(evidence["stepLabel"] as? String == contract.stepLabel)
                assetIDs.append(try #require(evidence["assetID"] as? String))
            }

            #expect(Set(assetIDs).count == expected.count, "Every evidence mapping must resolve to one distinct asset")
        }

        let manifestSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ops/ui_world_manifest.py")
        let manifestSource = try String(contentsOf: manifestSourceURL, encoding: .utf8)
        for label in expected.map(\.label) {
            #expect(manifestSource.contains(label), "Manifest must name evidence step label (label)")
        }
    }

    @Test func p15SettingsUITestRoutesConsumeCanonicalCounterexampleIDs() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launchSource = try String(
            contentsOf: iosRoot.appendingPathComponent("BooksAndVocabUITests/Helpers/UITestAppLaunch.swift"),
            encoding: .utf8
        )
        #expect(launchSource.contains("-seedFixture:settings:\(SettingsFixtureID.longContentCounterexample.rawValue)"))
        #expect(launchSource.contains("-seedFixture:settings:\(SettingsFixtureID.resetCounterexample.rawValue)"))

        let seedSource = try String(
            contentsOf: iosRoot.appendingPathComponent("BooksAndVocab/Support/UITestFixtureSeed+Settings.swift"),
            encoding: .utf8
        )
        #expect(seedSource.contains("SettingsFixtureID(rawValue: id)"))
        #expect(seedSource.contains("case .longContentCounterexample"))
        #expect(seedSource.contains("case .resetCounterexample"))
        #expect(seedSource.contains("requireVocabularySeed(for: .vocabListPopulated)"))
        #expect(!seedSource.contains("for (word, translation, contextText)"))
    }

    @Test func p15ResetCounterexampleHasObservableLifecycleBoundary() throws {
        let root = try Self.jsonObject(Self.marketingDemoData)
        let settings = try #require(root["settings"] as? [String: Any])
        let seed = try #require(settings["reset_counterexample"] as? [String: Any])
        let lifecycle = try #require(seed["resetLifecycle"] as? [String: Any])
        let before = try #require(lifecycle["before"] as? [String: Any])
        let after = try #require(lifecycle["after"] as? [String: Any])

        #expect((before["localCardCount"] as? Int ?? 0) > (after["localCardCount"] as? Int ?? 0))
        #expect((before["hasCustomPreferences"] as? Bool) != (after["hasCustomPreferences"] as? Bool))
        #expect(before["isLoggedIn"] as? Bool == true)
        #expect(after["isLoggedIn"] as? Bool == true)
        #expect(lifecycle["phase"] as? String == "succeeded")
        #expect(lifecycle["canRetry"] as? Bool == false)
        #expect((lifecycle["terminalMessage"] as? String)?.isEmpty == false)

        let accountDetailURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BooksAndVocab/Views/Settings/SettingsAccountDetailView.swift")
        let accountDetailSource = try String(contentsOf: accountDetailURL, encoding: .utf8)
        for contractIdentifier in [
            "settings.account.resetBoundary",
            "settings.account.resetBoundary.phase",
            "settings.account.resetBoundary.resetButton",
            "resetLifecycle",
        ] {
            #expect(accountDetailSource.contains(contractIdentifier), "Production reset boundary is missing (contractIdentifier)")
        }
    }

    @Test func p15ResetLifecycleAdapterAndTerminalTransitionsAreObservable() throws {
        try FixtureDatasetStore.withTestingData(Self.marketingDemoData) {
            let lifecycle = try #require(SettingsFixtures.state(for: .resetCounterexample).danger?.resetLifecycle)
            #expect(lifecycle.phase == .succeeded)
            #expect(lifecycle.before.localCardCount == 3)
            #expect(lifecycle.after.localCardCount == 0)
            #expect(lifecycle.before.hasCustomPreferences == true)
            #expect(lifecycle.after.hasCustomPreferences == false)
            #expect(lifecycle.before.isLoggedIn == lifecycle.after.isLoggedIn)
            #expect(lifecycle.terminalMessage?.isEmpty == false)
            #expect(lifecycle.canRetry == false)

            let preReset = SettingsResetLifecycle.preReset(before: lifecycle.before)
            let resetting = preReset.resetting()
            let failed = resetting.failed(after: lifecycle.before, message: "fixture failure")
            let retry = SettingsResetLifecycle.preReset(before: failed.before).resetting()
            #expect(preReset.phase == .preReset)
            #expect(resetting.phase == .resetting)
            #expect(failed.phase == .failed)
            #expect(failed.after == failed.before)
            #expect(failed.canRetry == true)
            #expect(retry.phase == .resetting)
            #expect(retry.before == failed.before)
        }
    }

    @Test @MainActor func p15ResetCoordinatorReadsStatefulStoreForBeforeAndTerminalAfter() async throws {
        let container = try ModelContainer(
            for: Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let authManager = LoggedInAuthStub()
        let resetStore = StatefulSettingsResetStore()
        let resetService = StatefulResetService(store: resetStore, outcomes: [
            .partialFailure,
            .success
        ])
        let context = ModelContext(container)
        let coordinator = SettingsCoordinator(resetStateStore: resetStore, translationLifecycle: NoopAccountPreferenceLifecycle())
        let before = SettingsResetLifecycle.Snapshot(
            localCardCount: 3,
            hasCustomPreferences: true,
            isLoggedIn: true
        )

        await coordinator.resetLocalData(
            authManager: authManager,
            kgService: resetService,
            modelContext: context
        )

        let failed = try #require(coordinator.resetLifecycle)
        #expect(failed.phase == .failed)
        #expect(failed.before == before)
        #expect(failed.after == .init(localCardCount: 1, hasCustomPreferences: true, isLoggedIn: true))
        #expect(failed.canRetry == true)
        #expect(resetService.callCount == 1)

        await coordinator.resetLocalData(
            authManager: authManager,
            kgService: resetService,
            modelContext: context
        )

        let succeeded = try #require(coordinator.resetLifecycle)
        #expect(succeeded.phase == .succeeded)
        #expect(succeeded.before == before)
        #expect(succeeded.after == .init(localCardCount: 0, hasCustomPreferences: false, isLoggedIn: true))
        #expect(succeeded.canRetry == false)
        #expect(resetService.callCount == 2)
        #expect(resetStore.readSnapshots.first == before)
        #expect(resetStore.readSnapshots.contains(.init(localCardCount: 1, hasCustomPreferences: true, isLoggedIn: true)))
        #expect(resetStore.readSnapshots.contains(.init(localCardCount: 0, hasCustomPreferences: false, isLoggedIn: true)))
    }

    @Test @MainActor func p15ResetCoordinatorFailsClosedWhenBeforeSnapshotIsUnreadable() async throws {
        let container = try ModelContainer(
            for: Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let authManager = LoggedInAuthStub()
        let resetStore = StatefulSettingsResetStore()
        resetStore.makeUnreadable()
        let resetService = StatefulResetService(store: resetStore, outcomes: [.success])
        let coordinator = SettingsCoordinator(resetStateStore: resetStore, translationLifecycle: NoopAccountPreferenceLifecycle())

        await coordinator.resetLocalData(
            authManager: authManager,
            kgService: resetService,
            modelContext: ModelContext(container)
        )

        let lifecycle = try #require(coordinator.resetLifecycle)
        #expect(lifecycle.phase == .preReset)
        #expect(lifecycle.before.localCardCount == nil)
        #expect(lifecycle.before.localCardCountError == "SwiftData read failed")
        #expect(lifecycle.after == lifecycle.before)
        #expect(lifecycle.canRetry == false)
        #expect(resetService.callCount == 0)
    }

    // MARK: - #2442 unsynced-data guard / #2439 server push / #2744 account boundary

    @Test @MainActor func p2442SnapshotCountsUnsyncedRowsSeparately() throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        for (word, status) in [("synced", 1), ("pending", 0), ("failed", 2)] {
            let entry = VocabularyEntry(word: word, translation: "t", context: "c", bookTitle: "b")
            entry.syncStatus = status
            context.insert(entry)
        }
        try context.save()

        let snapshot = LiveSettingsResetStore().readSnapshot(authManager: LoggedInAuthStub(), modelContext: context)

        #expect(snapshot.localCardCount == 1)
        #expect(snapshot.unsyncedCardCount == 2)
    }

    @Test @MainActor func p2442UnsyncedReviewEventsAloneRequireAcknowledgement() throws {
        let container = try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let entry = VocabularyEntry(word: "synced", translation: "t", context: "c", bookTitle: "b")
        entry.syncStatus = 1
        context.insert(entry)
        let owed = ReviewRecord(word: "synced", entryID: nil, feedback: 1)
        let acked = ReviewRecord(word: "synced", entryID: nil, feedback: 0)
        acked.pushedAt = Date()
        context.insert(owed)
        context.insert(acked)
        try context.save()

        let snapshot = LiveSettingsResetStore().readSnapshot(authManager: LoggedInAuthStub(), modelContext: context)

        #expect(snapshot.unsyncedCardCount == 0)
        #expect(snapshot.unsyncedReviewCount == 1)
        #expect(snapshot.requiresUnsyncedAcknowledgement == true)
    }

    @Test @MainActor func p2442ResetWithUnsyncedRowsIsBlockedUntilAcknowledged() async throws {
        let container = try ModelContainer(
            for: Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let resetStore = StatefulSettingsResetStore()
        resetStore.unsyncedCardCount = 2
        let service = StatefulResetService(store: resetStore, outcomes: [.success])
        let coordinator = SettingsCoordinator(resetStateStore: resetStore, translationLifecycle: NoopAccountPreferenceLifecycle())
        let context = ModelContext(container)
        let auth = LoggedInAuthStub()

        await coordinator.resetLocalData(authManager: auth, kgService: service, modelContext: context)

        let blocked = try #require(coordinator.resetLifecycle)
        #expect(blocked.phase == .preReset)
        #expect(blocked.before.unsyncedCardCount == 2)
        #expect(blocked.terminalMessage != nil)
        #expect(blocked.canRetry == true)
        #expect(service.callCount == 0)

        await coordinator.resetLocalData(
            authManager: auth,
            kgService: service,
            modelContext: context,
            acknowledgeUnsyncedLoss: true
        )

        #expect(service.callCount == 1)
        #expect(coordinator.resetLifecycle?.phase == .succeeded)
    }

    @Test func p2442ConfirmationRequiresAcknowledgementOnlyForReadableUnsyncedRows() {
        let clean = SettingsResetLifecycle.Snapshot(localCardCount: 3, hasCustomPreferences: true, isLoggedIn: true)
        let dirty = SettingsResetLifecycle.Snapshot(
            localCardCount: 3, unsyncedCardCount: 2, hasCustomPreferences: true, isLoggedIn: true
        )
        #expect(clean.unsyncedCardCount == 0)
        #expect(clean.requiresUnsyncedAcknowledgement == false)
        #expect(dirty.requiresUnsyncedAcknowledgement == true)
    }

    @Test @MainActor func p2439SignedInResetPushesDefaultConfigsBeforeClearingLocalData() async throws {
        let container = try ModelContainer(
            for: Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let order = OrderRecorder()
        let resetStore = StatefulSettingsResetStore()
        let service = CombinedResetService(store: resetStore, order: order)
        let coordinator = SettingsCoordinator(resetStateStore: resetStore, translationLifecycle: NoopAccountPreferenceLifecycle())

        await coordinator.resetLocalData(
            authManager: LoggedInAuthStub(),
            kgService: service,
            modelContext: ModelContext(container)
        )

        let defaults = ReviewSettings.default
        #expect(service.autoLink?.enabled == true)
        #expect(service.autoLink?.updated_at != nil)
        #expect(service.translation?.source_lang == "en")
        #expect(service.translation?.target_lang == "zh-Hant")
        #expect(service.translation?.updated_at != nil)
        #expect(service.reviewClock?.is_paused == false)
        #expect(service.reviewClock?.paused_at == nil)
        #expect(service.reviewMode?.mode == defaults.mode.rawValue)
        #expect(service.reviewMode?.custom_initial_interval_hours == defaults.customInitialIntervalHours)
        #expect(service.reviewMode?.custom_maximum_interval_hours == defaults.customMaximumIntervalHours)
        let events = order.events
        #expect(events.last == "clear")
        #expect(try #require(events.firstIndex(of: "clear")) > #require(events.firstIndex(of: "autoLink")))
        #expect(coordinator.resetLifecycle?.phase == .succeeded)
    }

    @Test @MainActor func p2442RetryAfterFailedPushRechecksUnsyncedRows() async throws {
        let container = try ModelContainer(
            for: Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let resetStore = StatefulSettingsResetStore()
        let service = CombinedResetService(store: resetStore, order: OrderRecorder())
        service.configFailure = ResetFailure()
        let coordinator = SettingsCoordinator(resetStateStore: resetStore, translationLifecycle: NoopAccountPreferenceLifecycle())
        let context = ModelContext(container)
        let auth = LoggedInAuthStub()

        await coordinator.resetLocalData(authManager: auth, kgService: service, modelContext: context)
        #expect(coordinator.resetLifecycle?.phase == .failed)

        resetStore.unsyncedCardCount = 2
        await coordinator.resetLocalData(authManager: auth, kgService: service, modelContext: context)

        let blocked = try #require(coordinator.resetLifecycle)
        #expect(blocked.phase == .preReset)
        #expect(blocked.before.unsyncedCardCount == 2)
        #expect(service.clearCallCount == 0)
    }

    @Test func p2442BlockedCardRefreshesAfterSyncCompletes() {
        let stale = SettingsResetLifecycle.Snapshot(
            localCardCount: 3, unsyncedCardCount: 2, hasCustomPreferences: true, isLoggedIn: true
        )
        let synced = SettingsResetLifecycle.Snapshot(localCardCount: 3, hasCustomPreferences: true, isLoggedIn: true)
        let fewer = SettingsResetLifecycle.Snapshot(
            localCardCount: 3, unsyncedCardCount: 1, hasCustomPreferences: true, isLoggedIn: true
        )
        let blocked = SettingsResetLifecycle.blockedByUnsynced(before: stale)

        let cleared = blocked.refreshed(with: synced)
        #expect(cleared.before == synced)
        #expect(cleared.terminalMessage == nil)
        #expect(blocked.refreshed(with: fewer).before.unsyncedCardCount == 1)
        let failed = SettingsResetLifecycle.preReset(before: stale).resetting().failed(after: stale, message: "x")
        #expect(failed.refreshed(with: synced) == failed)
    }

    @Test @MainActor func p2439PushFailureAbortsResetWithoutDeletingLocalData() async throws {
        let container = try ModelContainer(
            for: Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let resetStore = StatefulSettingsResetStore()
        let service = CombinedResetService(store: resetStore, order: OrderRecorder())
        service.configFailure = ResetFailure()
        let coordinator = SettingsCoordinator(resetStateStore: resetStore, translationLifecycle: NoopAccountPreferenceLifecycle())

        await coordinator.resetLocalData(
            authManager: LoggedInAuthStub(),
            kgService: service,
            modelContext: ModelContext(container)
        )

        let lifecycle = try #require(coordinator.resetLifecycle)
        #expect(lifecycle.phase == .failed)
        #expect(lifecycle.canRetry == true)
        #expect(service.clearCallCount == 0)
        #expect(resetStore.resetPreferencesCallCount == 0)
        #expect(resetStore.hasCustomPreferences == true)
    }

    @Test @MainActor func p2439DemoResetMakesNoServerCalls() async throws {
        let container = try ModelContainer(
            for: Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let resetStore = StatefulSettingsResetStore()
        let service = CombinedResetService(store: resetStore, order: OrderRecorder())
        let coordinator = SettingsCoordinator(resetStateStore: resetStore, translationLifecycle: NoopAccountPreferenceLifecycle())
        let demo = LoggedInAuthStub()
        demo.isDemoMode = true

        await coordinator.resetLocalData(authManager: demo, kgService: service, modelContext: ModelContext(container))

        #expect(service.clearCallCount == 1)
        #expect(service.configCallCount == 0)
    }

    @Test @MainActor func p2744AccountSwitchClearsPreviousAccountsResetLifecycle() async throws {
        let container = try ModelContainer(
            for: Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let resetStore = StatefulSettingsResetStore()
        let service = CombinedResetService(store: resetStore, order: OrderRecorder())
        let coordinator = SettingsCoordinator(resetStateStore: resetStore, translationLifecycle: NoopAccountPreferenceLifecycle())
        let auth = LoggedInAuthStub()

        await coordinator.resetLocalData(authManager: auth, kgService: service, modelContext: ModelContext(container))
        #expect(coordinator.resetLifecycle?.phase == .succeeded)

        // The same account re-entering the boundary keeps its terminal card.
        coordinator.resetForAccountBoundary(authManager: auth)
        #expect(coordinator.resetLifecycle?.phase == .succeeded)

        // A's own logout cleanup keeps the terminal card visible.
        auth.isLoggedIn = false
        auth.userId = nil
        coordinator.resetForAccountBoundary(authManager: auth)
        #expect(coordinator.resetLifecycle?.phase == .succeeded)

        // A different account must not inherit it.
        auth.isLoggedIn = true
        auth.userId = "another-user"
        coordinator.resetForAccountBoundary(authManager: auth)
        #expect(coordinator.resetLifecycle == nil)
    }

    @Test @MainActor func p2744InFlightResetCompletionIsIgnoredAfterAccountSwitch() async throws {
        let container = try ModelContainer(
            for: Notebook.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let resetStore = StatefulSettingsResetStore()
        let service = CombinedResetService(store: resetStore, order: OrderRecorder())
        service.gateClear()
        let auth = LoggedInAuthStub()
        let coordinator = SettingsCoordinator(resetStateStore: resetStore, translationLifecycle: NoopAccountPreferenceLifecycle())
        let context = ModelContext(container)

        let task = Task { @MainActor in
            await coordinator.resetLocalData(authManager: auth, kgService: service, modelContext: context)
        }
        await service.waitUntilClearStarted()
        auth.userId = "another-user"
        coordinator.resetForAccountBoundary(authManager: auth)
        #expect(coordinator.resetLifecycle == nil)

        service.openGate()
        await task.value

        #expect(coordinator.resetLifecycle == nil)
        #expect(resetStore.resetPreferencesCallCount == 0)
    }

    private final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var events: [String] { lock.withLock { storage } }
        func append(_ event: String) { lock.withLock { storage.append(event) } }
    }

    /// One fake for both seams the reset flow touches: local cleanup and the
    /// server config endpoints, so ordering between them is observable.
    private final class CombinedResetService: LocalDataResetting, UserConfigServing, @unchecked Sendable {
        private let lock = NSLock()
        private let store: StatefulSettingsResetStore
        private let order: OrderRecorder
        private var gated = false
        private var clearStarted = false
        private var gateOpen = false
        private(set) var clearCallCount = 0
        private(set) var configCallCount = 0
        private(set) var autoLink: KGAutoLinkConfig?
        private(set) var translation: KGTranslationConfig?
        private(set) var reviewClock: KGReviewClockConfig?
        private(set) var reviewMode: KGReviewModeConfig?
        var configFailure: Error?

        init(store: StatefulSettingsResetStore, order: OrderRecorder) {
            self.store = store
            self.order = order
        }

        func gateClear() { lock.withLock { gated = true } }
        func openGate() { lock.withLock { gateOpen = true } }
        func waitUntilClearStarted() async {
            while !lock.withLock({ clearStarted }) { try? await Task.sleep(nanoseconds: 5_000_000) }
        }

        func clearLocalData(container: ModelContainer, reason: String) async throws {
            lock.withLock { clearCallCount += 1; clearStarted = true }
            while lock.withLock({ gated && !gateOpen }) { try? await Task.sleep(nanoseconds: 5_000_000) }
            order.append("clear")
            await store.finishCleanup()
        }

        private func record(_ name: String) throws -> KGUserConfig {
            lock.withLock { configCallCount += 1 }
            if let configFailure { throw configFailure }
            order.append(name)
            return KGUserConfig(translation: nil, review_clock: nil, review_mode: nil, vocab_ui: nil, auto_link: nil)
        }

        func fetchUserConfig() async throws -> KGUserConfig { try record("fetch") }
        func updateTranslationConfig(_ c: KGTranslationConfig) async throws -> KGUserConfig {
            let r = try record("translation"); translation = c; return r
        }
        func updateVocabUIConfig(_ c: KGVocabUIConfig) async throws -> KGUserConfig { try record("vocabUI") }
        func updateReviewClockConfig(_ c: KGReviewClockConfig) async throws -> KGUserConfig {
            let r = try record("reviewClock"); reviewClock = c; return r
        }
        func updateReviewModeConfig(_ c: KGReviewModeConfig) async throws -> KGUserConfig {
            let r = try record("reviewMode"); reviewMode = c; return r
        }
        func updateAutoLinkConfig(_ c: KGAutoLinkConfig) async throws -> KGUserConfig {
            let r = try record("autoLink"); autoLink = c; return r
        }
    }

    private struct ResetFailure: Error {}

    @MainActor
    private final class StatefulSettingsResetStore: SettingsResetStorePort {
        var localCardCount = 3
        var unsyncedCardCount = 0
        var hasCustomPreferences = true
        private(set) var resetPreferencesCallCount = 0
        private(set) var readSnapshots: [SettingsResetLifecycle.Snapshot] = []
        private var unreadable = false

        func readSnapshot(
            authManager: any AuthManaging,
            modelContext: ModelContext
        ) -> SettingsResetLifecycle.Snapshot {
            if unreadable {
                let snapshot = SettingsResetLifecycle.Snapshot(
                    unreadableLocalCardCount: "SwiftData read failed",
                    hasCustomPreferences: hasCustomPreferences,
                    isLoggedIn: authManager.isLoggedIn
                )
                readSnapshots.append(snapshot)
                return snapshot
            }
            let snapshot = SettingsResetLifecycle.Snapshot(
                localCardCount: localCardCount,
                unsyncedCardCount: unsyncedCardCount,
                hasCustomPreferences: hasCustomPreferences,
                isLoggedIn: authManager.isLoggedIn
            )
            readSnapshots.append(snapshot)
            return snapshot
        }

        func resetPreferences() {
            resetPreferencesCallCount += 1
            hasCustomPreferences = false
        }

        func pushDefaultPreferences(to configService: any UserConfigServing) async throws {
            try await LiveSettingsResetStore.pushDefaultPreferences(to: configService)
        }

        func leavePartialCleanupState() {
            localCardCount = 1
        }

        func finishCleanup() {
            localCardCount = 0
            unsyncedCardCount = 0
        }

        func makeUnreadable() {
            unreadable = true
        }
    }

    private enum StatefulResetOutcome {
        case partialFailure
        case success
    }

    private final class StatefulResetService: LocalDataResetting, StubbedUserConfig, @unchecked Sendable {
        private let store: StatefulSettingsResetStore
        private var outcomes: [StatefulResetOutcome]
        private(set) var callCount = 0

        init(store: StatefulSettingsResetStore, outcomes: [StatefulResetOutcome]) {
            self.store = store
            self.outcomes = outcomes
        }

        func clearLocalData(container: ModelContainer, reason: String) async throws {
            callCount += 1
            let outcome = outcomes.removeFirst()
            switch outcome {
            case .partialFailure:
                await store.leavePartialCleanupState()
                throw ResetFailure()
            case .success:
                await store.finishCleanup()
            }
        }
    }

    private final class ScriptedResetService: LocalDataResetting, StubbedUserConfig, @unchecked Sendable {
        private var outcomes: [Result<Void, Error>]
        private(set) var callCount = 0

        init(outcomes: [Result<Void, Error>]) {
            self.outcomes = outcomes
        }

        func clearLocalData(container: ModelContainer, reason: String) async throws {
            callCount += 1
            try outcomes.removeFirst().get()
        }
    }

    @MainActor
    private final class LoggedInAuthStub: AuthManaging {
        var isLoggedIn = true
        var userId: String? = "settings-reset-test-user"
        var token: String? = "settings-reset-test-token"
        var displayName: String? = "Settings Reset Test"
        var userEmail: String? = "settings-reset@test.invalid"
        var avatarURL: URL?
        var authError: String?
        var isAuthenticating = false
        var isDemoMode = false

        func enterDemoMode(modelContainer: ModelContainer) {}
        func exitDemoMode(modelContainer: ModelContainer) {}
        func refreshSessionIfNeeded() {}
        func login(userId: String, token: String) {}
        func login(customToken: String) async {}
        func logout(modelContainer: ModelContainer?, reason: String) {}
        func logoutAfterAccountDeletion(modelContainer: ModelContainer?, deletedAccountID: String?) {}
        func loginWithGoogle(modelContainer: ModelContainer?) {}
        func loginWithApple(modelContainer: ModelContainer?) {}
    }

    private func sourceIdentifierIsContained(_ identifier: String, in source: String) -> Bool {
        let range = source.range(of: "accessibilityIdentifier(\"\(identifier)\")")
            ?? ((identifier.hasSuffix(".before") || identifier.hasSuffix(".after"))
                ? source.range(of: ".accessibilityIdentifier(identifier)")
                : nil)
        guard let range else {
            return false
        }
        return source[..<range.lowerBound]
            .suffix(320)
            .contains(".accessibilityElement(children: .contain)")
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func objectMemberOrder(_ data: Data, key objectKey: String) throws -> [String] {
        let text = try #require(String(data: data, encoding: .utf8))
        let characters = Array(text)
        let token = Array("\"\(objectKey)\"")
        guard characters.count >= token.count else {
            throw NSError(domain: "SettingsFixturesTests", code: 1)
        }

        var tokenStart: Int?
        for candidate in 0...(characters.count - token.count) {
            if Array(characters[candidate..<(candidate + token.count)]) == token {
                tokenStart = candidate
                break
            }
        }
        var index = try #require(tokenStart) + token.count
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        try #require(index < characters.count && characters[index] == ":")
        index += 1
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        try #require(index < characters.count && characters[index] == "{")

        var depth = 0
        var result: [String] = []
        var inString = false
        var escaped = false

        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" && !escaped {
                    escaped = true
                } else if character == "\"" && !escaped {
                    inString = false
                } else {
                    escaped = false
                }
                index += 1
                continue
            }

            switch character {
            case "\"":
                let start = index
                inString = true
                escaped = false
                index += 1
                while index < characters.count {
                    if characters[index] == "\\" && !escaped {
                        escaped = true
                    } else if characters[index] == "\"" && !escaped {
                        break
                    } else {
                        escaped = false
                    }
                    index += 1
                }
                let end = index
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead].isWhitespace { lookahead += 1 }
                if depth == 1, lookahead < characters.count, characters[lookahead] == ":" {
                    result.append(String(characters[(start + 1)..<end]))
                }
                inString = false
            case "{", "[":
                depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return result }
            default:
                break
            }
            index += 1
        }

        throw NSError(domain: "SettingsFixturesTests", code: 2)
    }
}

/// Fakes that only care about local cleanup accept every server config push,
/// so signed-in reset tests do not need a transport.
private protocol StubbedUserConfig: UserConfigServing {}

extension StubbedUserConfig {
    private var blankConfig: KGUserConfig {
        KGUserConfig(translation: nil, review_clock: nil, review_mode: nil, vocab_ui: nil, auto_link: nil)
    }
    func fetchUserConfig() async throws -> KGUserConfig { blankConfig }
    func updateTranslationConfig(_ translationConfig: KGTranslationConfig) async throws -> KGUserConfig { blankConfig }
    func updateReviewClockConfig(_ reviewClock: KGReviewClockConfig) async throws -> KGUserConfig { blankConfig }
    func updateReviewModeConfig(_ reviewMode: KGReviewModeConfig) async throws -> KGUserConfig { blankConfig }
    func updateVocabUIConfig(_ vocabUI: KGVocabUIConfig) async throws -> KGUserConfig { blankConfig }
    func updateAutoLinkConfig(_ autoLink: KGAutoLinkConfig) async throws -> KGUserConfig { blankConfig }
}
#endif
