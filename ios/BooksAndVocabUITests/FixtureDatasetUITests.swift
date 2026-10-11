//
//  FixtureDatasetUITests.swift
//  Books & Vocab UI Tests
//
//  End-to-end proof for the `ios_test.sh --dataset <name>` chain:
//  runner env (KG_FIXTURE_DATASET_DEFLATE_B64, or legacy KG_FIXTURE_DATASET_B64)
//  → UITestLaunchConfiguration forwarding → app FixtureDatasetStore
//  → UITestFixtureSeed bookshelf seeder → rendered UI.
//
//  Without a UI World on the runner the test fails; run it via:
//      ./ops/ios_test.sh --ui --dataset marketing_demo -g FixtureDatasetUITests
//

import CryptoKit
import XCTest

private struct UITestAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private func rejectUnknownUITestKeys(
    in decoder: Decoder,
    allowedKeys: Set<String>,
    context: String
) throws {
    let rawContainer = try decoder.container(keyedBy: UITestAnyCodingKey.self)
    let unknownKeys = Set(rawContainer.allKeys.map(\.stringValue))
        .subtracting(allowedKeys)
    guard unknownKeys.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "\(context) contains unknown keys \(unknownKeys.sorted())"
            )
        )
    }
}

final class FixtureDatasetUITests: UITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Calendar evidence captures four states and derives month navigation
        // from the injected clock/history. Keep the allowance above XCTest's
        // default one-minute limit so a valid full flow is not killed after
        // the final screenshot. The flow intentionally launches the app twice
        // and captures six states; XCTest's default/short allowance can kill
        // it during AX attachment serialization rather than report a product
        // failure.
        executionTimeAllowance = 300
    }

    private enum ReviewCalendarClockSelector {
        static let canonical = "reviewCalendar.clock.history_plan.anchor_day"
        static let live = "reviewCalendar.clock.live"
    }

    private enum ReviewCalendarEvidence {
        static let selector = "FixtureDatasetUITests/testReviewCalendarRequiredEvidenceUsesStableSelectors"
        static let source = "ios/BooksAndVocabUITests/FixtureDatasetUITests.swift"
        static let calendarProjectionAttempts = 3
        static let requiredLabels = [
            "calendar",
            "empty-day",
            "populated-day",
            "timezone-boundary",
        ]
        static let counterexampleLabels = [
            "empty-day-counterexample",
            "timezone-boundary-counterexample",
        ]
    }

    /// Minimal mirror of `kg.fixture.dataset.v2` — enough to assert the runner
    /// injected the same required manifest shape the app consumes.
    private struct DatasetDocument: Decodable {
        struct Shelf: Decodable {
            struct Book: Decodable { let title: String }
            let books: [Book]
        }
        struct ReviewClock: Decodable {
            let now: String?
            let frozenEpoch: Int?
            let anchorDay: String?
            let timeZone: String?
            let source: String?

            enum CodingKeys: String, CodingKey, CaseIterable {
                case now
                case frozenEpoch
                case anchorDay
                case timeZone
                case source
            }

            init(from decoder: Decoder) throws {
                try rejectUnknownUITestKeys(
                    in: decoder,
                    allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
                    context: "UI test scenarioContext.reviewClock"
                )
                let container = try decoder.container(keyedBy: CodingKeys.self)
                now = try container.decodeIfPresent(String.self, forKey: .now)
                frozenEpoch = try container.decodeIfPresent(Int.self, forKey: .frozenEpoch)
                anchorDay = try container.decodeIfPresent(String.self, forKey: .anchorDay)
                timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
                source = try container.decodeIfPresent(String.self, forKey: .source)
            }
        }
        struct EvidenceAsset: Decodable {
            let fixtureID: String
            let stepLabel: String
            let index: Int
            let assetIDs: [String]

            enum CodingKeys: String, CodingKey, CaseIterable {
                case fixtureID
                case stepLabel
                case index
                case assetIDs
            }

            init(from decoder: Decoder) throws {
                try rejectUnknownUITestKeys(
                    in: decoder,
                    allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
                    context: "UI test reviewCalendar evidence row"
                )
                let container = try decoder.container(keyedBy: CodingKeys.self)
                fixtureID = try container.decode(String.self, forKey: .fixtureID)
                stepLabel = try container.decode(String.self, forKey: .stepLabel)
                index = try container.decode(Int.self, forKey: .index)
                assetIDs = try container.decode([String].self, forKey: .assetIDs)
            }
        }
        struct EvidenceGroups: Decodable {
            let required: [EvidenceAsset]
            let counterexamples: [EvidenceAsset]

            enum CodingKeys: String, CodingKey, CaseIterable {
                case required
                case counterexamples
            }

            init(from decoder: Decoder) throws {
                try rejectUnknownUITestKeys(
                    in: decoder,
                    allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
                    context: "UI test reviewCalendar evidence groups"
                )
                let container = try decoder.container(keyedBy: CodingKeys.self)
                required = try container.decode([EvidenceAsset].self, forKey: .required)
                counterexamples = try container.decode(
                    [EvidenceAsset].self,
                    forKey: .counterexamples
                )
            }
        }
        struct GeneratedEvidence: Codable {
            let fixtureID: String
            let stepLabel: String
            let manifestAssetID: String
            let manifestPath: String
            let assetID: String
            let artifactPath: String
            let bytes: Int
            let sha256: String
            let type: String
            let selector: String
            let source: String
            let datasetID: String
            let device: String
            let group: String
            let installedFixture: InstalledFixture

            enum CodingKeys: String, CodingKey, CaseIterable {
                case fixtureID
                case stepLabel
                case manifestAssetID
                case manifestPath
                case assetID
                case artifactPath
                case bytes
                case sha256
                case type
                case selector
                case source
                case datasetID
                case device
                case group
                case installedFixture
            }

            init(
                fixtureID: String,
                stepLabel: String,
                manifestAssetID: String,
                manifestPath: String,
                assetID: String,
                artifactPath: String,
                bytes: Int,
                sha256: String,
                type: String,
                selector: String,
                source: String,
                datasetID: String,
                device: String,
                group: String,
                installedFixture: InstalledFixture
            ) {
                self.fixtureID = fixtureID
                self.stepLabel = stepLabel
                self.manifestAssetID = manifestAssetID
                self.manifestPath = manifestPath
                self.assetID = assetID
                self.artifactPath = artifactPath
                self.bytes = bytes
                self.sha256 = sha256
                self.type = type
                self.selector = selector
                self.source = source
                self.datasetID = datasetID
                self.device = device
                self.group = group
                self.installedFixture = installedFixture
            }

            init(from decoder: Decoder) throws {
                try rejectUnknownUITestKeys(
                    in: decoder,
                    allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
                    context: "UI test generated reviewCalendar evidence"
                )
                let container = try decoder.container(keyedBy: CodingKeys.self)
                fixtureID = try container.decode(String.self, forKey: .fixtureID)
                stepLabel = try container.decode(String.self, forKey: .stepLabel)
                manifestAssetID = try container.decode(String.self, forKey: .manifestAssetID)
                manifestPath = try container.decode(String.self, forKey: .manifestPath)
                assetID = try container.decode(String.self, forKey: .assetID)
                artifactPath = try container.decode(String.self, forKey: .artifactPath)
                bytes = try container.decode(Int.self, forKey: .bytes)
                sha256 = try container.decode(String.self, forKey: .sha256)
                type = try container.decode(String.self, forKey: .type)
                selector = try container.decode(String.self, forKey: .selector)
                source = try container.decode(String.self, forKey: .source)
                datasetID = try container.decode(String.self, forKey: .datasetID)
                device = try container.decode(String.self, forKey: .device)
                group = try container.decode(String.self, forKey: .group)
                installedFixture = try container.decode(InstalledFixture.self, forKey: .installedFixture)
            }
        }
        struct InstalledFixture: Codable, Equatable {
            let datasetID: String
            let path: String
            let bytes: Int
            let sha256: String
            let type: String
            let sourceCommit: String
            let datasetSHA256: String

            enum CodingKeys: String, CodingKey, CaseIterable {
                case datasetID
                case path
                case bytes
                case sha256
                case type
                case sourceCommit
                case datasetSHA256
            }

            init(
                datasetID: String,
                path: String,
                bytes: Int,
                sha256: String,
                type: String,
                sourceCommit: String,
                datasetSHA256: String
            ) {
                self.datasetID = datasetID
                self.path = path
                self.bytes = bytes
                self.sha256 = sha256
                self.type = type
                self.sourceCommit = sourceCommit
                self.datasetSHA256 = datasetSHA256
            }

            init(from decoder: Decoder) throws {
                try rejectUnknownUITestKeys(
                    in: decoder,
                    allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
                    context: "UI test installed fixture proof"
                )
                let container = try decoder.container(keyedBy: CodingKeys.self)
                datasetID = try container.decode(String.self, forKey: .datasetID)
                path = try container.decode(String.self, forKey: .path)
                bytes = try container.decode(Int.self, forKey: .bytes)
                sha256 = try container.decode(String.self, forKey: .sha256)
                type = try container.decode(String.self, forKey: .type)
                sourceCommit = try container.decode(String.self, forKey: .sourceCommit)
                datasetSHA256 = try container.decode(String.self, forKey: .datasetSHA256)
            }
        }
        struct GeneratedEvidenceFile: Codable {
            let schema: String
            let sourceCommit: String
            let datasetID: String
            let datasetSHA256: String
            let device: String
            let selector: String
            let records: [GeneratedEvidence]

            enum CodingKeys: String, CodingKey, CaseIterable {
                case schema
                case sourceCommit
                case datasetID
                case datasetSHA256
                case device
                case selector
                case records
            }

            init(
                schema: String,
                sourceCommit: String,
                datasetID: String,
                datasetSHA256: String,
                device: String,
                selector: String,
                records: [GeneratedEvidence]
            ) {
                self.schema = schema
                self.sourceCommit = sourceCommit
                self.datasetID = datasetID
                self.datasetSHA256 = datasetSHA256
                self.device = device
                self.selector = selector
                self.records = records
            }

            init(from decoder: Decoder) throws {
                try rejectUnknownUITestKeys(
                    in: decoder,
                    allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
                    context: "UI test generated reviewCalendar evidence file"
                )
                let container = try decoder.container(keyedBy: CodingKeys.self)
                schema = try container.decode(String.self, forKey: .schema)
                sourceCommit = try container.decode(String.self, forKey: .sourceCommit)
                datasetID = try container.decode(String.self, forKey: .datasetID)
                datasetSHA256 = try container.decode(String.self, forKey: .datasetSHA256)
                device = try container.decode(String.self, forKey: .device)
                selector = try container.decode(String.self, forKey: .selector)
                records = try container.decode([GeneratedEvidence].self, forKey: .records)
            }
        }
        struct SurfaceContracts: Decodable {
            let explore: EvidenceGroups?
            let settings: EvidenceGroups?
            let reviewCalendar: EvidenceGroups?

            enum CodingKeys: String, CodingKey, CaseIterable {
                case explore
                case settings
                case reviewCalendar
            }

            init(from decoder: Decoder) throws {
                try rejectUnknownUITestKeys(
                    in: decoder,
                    allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
                    context: "UI test scenarioContext.surfaceContracts"
                )
                let container = try decoder.container(keyedBy: CodingKeys.self)
                explore = try container.decodeIfPresent(EvidenceGroups.self, forKey: .explore)
                settings = try container.decodeIfPresent(EvidenceGroups.self, forKey: .settings)
                reviewCalendar = try container.decodeIfPresent(EvidenceGroups.self, forKey: .reviewCalendar)
            }
        }
        struct ScenarioContext: Decodable {
            let reviewClock: ReviewClock?
            let surfaceContracts: SurfaceContracts?
        }
        struct ReviewHistoryItem: Decodable {
            let reviewedAt: Date
        }
        struct Vocabulary: Decodable {
            let reviewHistory: [ReviewHistoryItem]
        }
        let schema: String
        let datasetID: String
        let bookshelf: [String: Shelf]
        let scenarioContext: ScenarioContext?
        let vocabulary: [String: Vocabulary]
    }

    @MainActor
    func testBookshelfRendersDatasetOverriddenTitle() throws {
        let environment = ProcessInfo.processInfo.environment
        let data: Data
        if let deflateB64 = environment["KG_FIXTURE_DATASET_DEFLATE_B64"], !deflateB64.isEmpty {
            guard let compressed = Data(base64Encoded: deflateB64) else {
                XCTFail("KG_FIXTURE_DATASET_DEFLATE_B64 is not valid base64")
                return
            }
            data = try (compressed as NSData).decompressed(using: .zlib) as Data
        } else if let base64 = environment["KG_FIXTURE_DATASET_B64"], !base64.isEmpty {
            guard let decoded = Data(base64Encoded: base64) else {
                XCTFail("KG_FIXTURE_DATASET_B64 is not valid base64")
                return
            }
            data = decoded
        } else {
            XCTFail("missing UI World on the runner — run via ./ops/ios_test.sh --ui --dataset <name>")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(DatasetDocument.self, from: data)
        XCTAssertEqual(document.schema, "kg.fixture.dataset.v2")
        XCTAssertFalse(document.datasetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard let expectedTitle = document.bookshelf["with_books_library"]?.books.first?.title else {
            XCTFail("UI World defines no bookshelf.with_books_library entry")
            return
        }

        let app = launchIsolatedApp(fixtures: [.bookshelf("with_books_library")])
        // ContentView starts on `.bookshelf`; the fixture assertion must wait
        // for its projection, not tap an already-selected tab while AX is
        // still materialising the shell.
        let bookshelf = BookshelfPage(app: app)
        guard bookshelf.anyBookCard.waitUntilExists(timeout: 10) else {
            XCTFail("bookshelf fixture (with_books_library) should render at least one book card")
            return
        }
        // Wait on the card that carries the title, with the same budget as the
        // card wait. A bare staticTexts query with a 5 s window flakes on a
        // loaded ui-smoke runner; the combined card label is the stable surface.
        let titledCard = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH[c] %@ AND label CONTAINS[c] %@",
                "book.card.",
                expectedTitle
            ))
            .firstMatch
        XCTAssertTrue(
            titledCard.waitUntilExists(timeout: 10),
            "dataset-overridden book title '\(expectedTitle)' should render in a bookshelf card"
        )
    }

    @MainActor
    func testReviewCalendarRequiredEvidenceUsesStableSelectors() throws {
        let environment = ProcessInfo.processInfo.environment
        let encoded = environment["KG_FIXTURE_DATASET_DEFLATE_B64"]
            ?? environment["KG_FIXTURE_DATASET_B64"]
        guard let encoded, let compressedOrPlain = Data(base64Encoded: encoded) else {
            XCTFail("missing UI World — run with --dataset marketing_demo")
            return
        }
        let data: Data
        if environment["KG_FIXTURE_DATASET_DEFLATE_B64"] != nil {
            data = try (compressedOrPlain as NSData).decompressed(using: .zlib) as Data
        } else {
            data = compressedOrPlain
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(DatasetDocument.self, from: data)
        guard let clock = document.scenarioContext?.reviewClock,
              clock.now != nil,
              clock.frozenEpoch != nil,
              clock.anchorDay != nil,
              clock.timeZone != nil,
              clock.source != nil
        else {
            XCTFail("scenarioContext.reviewClock must be explicit; null/fallback clock is not valid evidence")
            return
        }
        XCTAssertFalse(document.datasetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let device = try evidenceDevice()
        let sourceCommit = try evidenceSourceCommit()
        let datasetSHA256 = dataSHA256(data)
        if let expectedDatasetSHA256 = environment["KG_UI_TEST_DATASET_SHA256"], !expectedDatasetSHA256.isEmpty {
            XCTAssertEqual(datasetSHA256, expectedDatasetSHA256, "UI test must attest the exact runner dataset bytes")
        }
        guard let screenshotDirectory = environment["KG_UI_TEST_SCREENSHOT_DIR"], !screenshotDirectory.isEmpty else {
            XCTFail("KG_UI_TEST_SCREENSHOT_DIR is required for app-written P9 proof")
            return
        }
        XCTAssertFalse(screenshotDirectory.isEmpty)
        let appProofRelativePath = "Evidence/\(document.datasetID).json"
        let retrievedProofRelativePath = "installed-fixtures/\(document.datasetID).json"
        let evidenceLaunchEnvironment = [
            "KG_P9_INSTALLED_FIXTURE_PROOF_RELATIVE_PATH": appProofRelativePath,
            "KG_UI_TEST_SOURCE_COMMIT": sourceCommit,
            "KG_UI_TEST_DATASET_ID": document.datasetID,
            "KG_UI_TEST_DATASET_SHA256": datasetSHA256,
            "KG_UI_TEST_DEVICE_UDID": device,
        ]
        let history = try XCTUnwrap(document.vocabulary["reviewCalendarDense"]?.reviewHistory)
        XCTAssertFalse(history.isEmpty, "reviewCalendarDense must provide populated-day evidence")
        let evidence = try XCTUnwrap(document.scenarioContext?.surfaceContracts?.reviewCalendar)
        assertManifestEvidenceMapping(evidence)
        XCTAssertEqual(clock.source, "history_plan.anchor_day")
        guard let boundaryDays = timezoneBoundaryDays(
            in: history,
            timeZoneIdentifier: clock.timeZone!
        ) else {
            XCTFail("reviewCalendarDense must include a UTC/local timezone-boundary event")
            return
        }
        XCTAssertNotEqual(
            boundaryDays.utcCount,
            boundaryDays.localCount,
            "UTC/local timezone counterexample must select different day-bucket states"
        )

        let anchorDay = try XCTUnwrap(clock.anchorDay)
        let anchorMonth = monthKey(for: anchorDay)
        let previousMonth = monthKey(for: anchorDay, offset: -1)
        let counts = dayCounts(in: history, timeZoneIdentifier: clock.timeZone!)
        let occupiedDays = Set(counts.local.keys)
        let emptyMonth = try XCTUnwrap(
            stride(from: -1, through: -12, by: -1)
                .map { monthKey(for: anchorDay, offset: $0) }
                .first { month in
                    guard let first = emptyDay(in: month, occupied: occupiedDays) else { return false }
                    return emptyDay(in: month, occupied: occupiedDays, excluding: [first]) != nil
                },
            "dense fixture must expose a month with two distinct empty days"
        )
        let emptyDayKey = try XCTUnwrap(
            emptyDay(in: emptyMonth, occupied: occupiedDays),
            "dense fixture must expose an empty day"
        )
        let emptyCounterexampleDay = try XCTUnwrap(
            emptyDay(in: emptyMonth, occupied: occupiedDays, excluding: [emptyDayKey]),
            "dense fixture must expose a second distinct empty day"
        )
        let monthCandidates = [previousMonth]
            + Array(stride(from: -2, through: -12, by: -1)).map { monthKey(for: anchorDay, offset: $0) }
        let populatedMonth = monthCandidates
            .first { mostPopulatedDay(in: $0, counts: counts.local) != nil }
            ?? monthKey(for: boundaryDays.local)
        let populatedDay = try XCTUnwrap(
            mostPopulatedDay(in: populatedMonth, counts: counts.local),
            "dense fixture must expose a populated day"
        )

        var generatedEvidence: [DatasetDocument.GeneratedEvidence] = []
        let app = launchIsolatedApp(
            fixtures: [.authSignedIn, .reviewCalendarDense],
            extraEnvironment: evidenceLaunchEnvironment,
            perfLog: "review-calendar"
        )
        let overview = AppPage(app: app).goToOverview()
        overview.assertOverviewAccessibilityHierarchy()
        guard overview.reviewCalendarButton.waitUntilExists(timeout: 10) else {
            captureStep("calendar", app: app)
            XCTFail("overview calendar entry point must render before opening Review Calendar")
            return
        }
        overview.scrollToReviewCalendarButton()
        overview.reviewCalendarButton.tapWhenReady()
        let calendar = ReviewCalendarPage(app: app)
        guard calendar.monthHeader.waitUntilExists(timeout: 10) else {
            captureStep("calendar", app: app)
            XCTFail("Review Calendar month header must render")
            return
        }
        assertClockProvenance(in: app)
        assertRuntimeGeometry(calendar)
        calendar.selectedDay.assertExists(timeout: 5)
        let installedFixture = try materializeInstalledFixture(
            from: calendar,
            datasetID: document.datasetID,
            sourceCommit: sourceCommit,
            datasetSHA256: datasetSHA256,
            expectedAppPath: appProofRelativePath,
            retrievedPath: retrievedProofRelativePath,
            sourceData: data
        )
        generatedEvidence.append(try captureEvidence(
            evidence.required[0], group: "required", app: app,
            datasetID: document.datasetID, device: device, installedFixture: installedFixture
        ))

        // All navigation and day keys are derived from the injected anchor and
        // decoded history; no localized labels or wall-clock dates are used.
        moveCalendar(calendar, from: anchorMonth, to: emptyMonth)
        guard calendar.day(emptyDayKey).waitUntilExists(timeout: 5) else {
            captureStep("empty-day", app: app)
            XCTFail("dense calendar fixture must expose an empty selectable day")
            return
        }
        calendar.day(emptyDayKey).tapWhenReady()
        guard calendar.emptyDayDetail.waitUntilExists(timeout: 5) else {
            captureStep("empty-day", app: app)
            XCTFail("empty-day selection must render the empty detail state")
            return
        }
        try assertEmptyDay(calendar, label: "empty-day")
        generatedEvidence.append(try captureEvidence(
            evidence.required[1], group: "required", app: app,
            datasetID: document.datasetID, device: device, installedFixture: installedFixture
        ))

        moveCalendar(calendar, from: emptyMonth, to: populatedMonth)
        guard calendar.day(populatedDay).waitUntilExists(timeout: 5) else {
            XCTFail("dense calendar fixture must expose a populated selectable day")
            return
        }
        calendar.day(populatedDay).tapWhenReady()
        try assertPopulatedDay(
            calendar,
            expectedCount: try XCTUnwrap(counts.local[populatedDay]),
            label: "populated-day"
        )
        generatedEvidence.append(try captureEvidence(
            evidence.required[2], group: "required", app: app,
            datasetID: document.datasetID, device: device, installedFixture: installedFixture
        ))
        let requiredBoundaryMonth = monthKey(for: boundaryDays.local)
        moveCalendar(calendar, from: populatedMonth, to: requiredBoundaryMonth)
        calendar.day(boundaryDays.local).tapWhenReady()
        let requiredBoundaryCount = try assertPopulatedDay(
            calendar,
            expectedCount: boundaryDays.localCount,
            label: "timezone-boundary"
        )
        XCTAssertEqual(requiredBoundaryCount, boundaryDays.localCount)
        generatedEvidence.append(try captureEvidence(
            evidence.required[3], group: "required", app: app,
            datasetID: document.datasetID, device: device, installedFixture: installedFixture
        ))

        // Counterexamples are captured from a separate app launch so their
        // screenshots cannot alias the required-state evidence.
        app.terminate()
        let counterexampleApp = launchIsolatedApp(
            fixtures: [.authSignedIn, .reviewCalendarDense],
            extraEnvironment: evidenceLaunchEnvironment,
            perfLog: "review-calendar-counterexamples"
        )
        let counterexampleOverview = AppPage(app: counterexampleApp).goToOverview()
        counterexampleOverview.scrollToReviewCalendarButton()
        counterexampleOverview.reviewCalendarButton.tapWhenReady()
        let counterexampleCalendar = ReviewCalendarPage(app: counterexampleApp)
        assertClockProvenance(in: counterexampleApp)
        moveCalendar(counterexampleCalendar, from: anchorMonth, to: emptyMonth)
        counterexampleCalendar.day(emptyCounterexampleDay).tapWhenReady()
        try assertEmptyDay(counterexampleCalendar, label: "empty-day-counterexample")
        generatedEvidence.append(try captureEvidence(
            evidence.counterexamples[0], group: "counterexamples", app: counterexampleApp,
            datasetID: document.datasetID, device: device, installedFixture: installedFixture
        ))
        let counterexampleBoundaryMonth = monthKey(for: boundaryDays.utc)
        moveCalendar(counterexampleCalendar, from: emptyMonth, to: counterexampleBoundaryMonth)
        counterexampleCalendar.day(boundaryDays.utc).tapWhenReady()
        let counterexampleBoundaryCount = try assertPopulatedDay(
            counterexampleCalendar,
            // The app always renders the selected day in the canonical
            // review timezone. ``boundaryDays.utc`` is the deliberately
            // misleading UTC label; derive its expected count from the same
            // local calendar projection the production UI uses.
            expectedCount: try XCTUnwrap(counts.local[boundaryDays.utc]),
            label: "timezone-boundary-counterexample"
        )
        XCTAssertNotEqual(
            counterexampleBoundaryCount,
            requiredBoundaryCount,
            "UTC/local selected day states must differ, not merely be non-empty"
        )
        generatedEvidence.append(try captureEvidence(
            evidence.counterexamples[1], group: "counterexamples", app: counterexampleApp,
            datasetID: document.datasetID, device: device, installedFixture: installedFixture
        ))

        assertGeneratedEvidence(
            evidence,
            records: generatedEvidence,
            datasetID: document.datasetID,
            device: device,
            sourceCommit: sourceCommit,
            datasetSHA256: datasetSHA256
        )
    }

    private struct DayBucket {
        let utc: String
        let local: String
        let utcCount: Int
        let localCount: Int
    }

    private struct DayCounts {
        let utc: [String: Int]
        let local: [String: Int]
    }

    private func timezoneBoundaryDays(
        in history: [DatasetDocument.ReviewHistoryItem],
        timeZoneIdentifier: String
    ) -> DayBucket? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = timeZone
        func key(_ components: DateComponents) -> String? {
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else { return nil }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        var utcCounts: [String: Int] = [:]
        var localCounts: [String: Int] = [:]
        var pairs: Set<String> = []
        for item in history {
            let utc = key(utcCalendar.dateComponents([.year, .month, .day], from: item.reviewedAt))
            let local = key(localCalendar.dateComponents([.year, .month, .day], from: item.reviewedAt))
            guard let utc, let local else { continue }
            utcCounts[utc, default: 0] += 1
            localCounts[local, default: 0] += 1
            if utc != local { pairs.insert("\(utc)|\(local)") }
        }
        return pairs.sorted().compactMap { pair in
            let parts = pair.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let utc = String(parts[0])
            let local = String(parts[1])
            let utcCount = utcCounts[utc, default: 0]
            let localCount = localCounts[local, default: 0]
            guard utcCount != localCount else { return nil }
            return DayBucket(utc: utc, local: local, utcCount: utcCount, localCount: localCount)
        }.first
    }

    private func dayCounts(
        in history: [DatasetDocument.ReviewHistoryItem],
        timeZoneIdentifier: String
    ) -> DayCounts {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            return DayCounts(utc: [:], local: [:])
        }
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = timeZone
        func key(_ components: DateComponents) -> String? {
            guard let year = components.year, let month = components.month,
                  let day = components.day else { return nil }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        var utc: [String: Int] = [:]
        var local: [String: Int] = [:]
        for item in history {
            if let key = key(utcCalendar.dateComponents([.year, .month, .day], from: item.reviewedAt)) {
                utc[key, default: 0] += 1
            }
            if let key = key(localCalendar.dateComponents([.year, .month, .day], from: item.reviewedAt)) {
                local[key, default: 0] += 1
            }
        }
        return DayCounts(utc: utc, local: local)
    }

    private func monthKey(for day: String, offset: Int = 0) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else { return day }
        let monthIndex = (parts[0] * 12 + parts[1] - 1) + offset
        let year = monthIndex / 12
        let month = monthIndex % 12 + 1
        return String(format: "%04d-%02d", year, month)
    }

    private func dayKeys(in month: String) -> [String] {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        return range.map { String(format: "%04d-%02d-%02d", parts[0], parts[1], $0) }
    }

    private func emptyDay(
        in month: String,
        occupied: Set<String>,
        excluding: [String] = []
    ) -> String? {
        let excluded = Set(excluding)
        return dayKeys(in: month).first { !occupied.contains($0) && !excluded.contains($0) }
    }

    private func mostPopulatedDay(in month: String, counts: [String: Int]) -> String? {
        counts.filter { $0.key.hasPrefix(month) }
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
            .first?.key
    }

    private func moveCalendar(_ page: ReviewCalendarPage, from current: String, to target: String) {
        let currentParts = current.split(separator: "-").compactMap { Int($0) }
        let targetParts = target.split(separator: "-").compactMap { Int($0) }
        guard currentParts.count == 2, targetParts.count == 2 else {
            XCTFail("calendar navigation requires YYYY-MM day keys")
            return
        }
        let delta = (targetParts[0] * 12 + targetParts[1]) - (currentParts[0] * 12 + currentParts[1])
        guard delta != 0 else { return }

        let direction = delta < 0 ? -1 : 1
        let button = direction < 0 ? page.previousMonthButton : page.nextMonthButton
        for step in 1 ... abs(delta) {
            let projectedMonth = monthKey(for: current, offset: direction * step)
            guard let dayKey = dayKeys(in: projectedMonth).first else {
                XCTFail("calendar navigation could not project a day for \(projectedMonth)")
                return
            }

            var projected = false
            for _ in 0 ..< ReviewCalendarEvidence.calendarProjectionAttempts {
                guard button.waitUntilHittable(timeout: 5) else { continue }
                button.tap()
                if waitForProjectedCalendarDay(page.app, dayKey: dayKey) {
                    projected = true
                    break
                }
            }
            XCTAssertTrue(
                projected,
                "calendar navigation must project target day before the next tap: \(dayKey)"
            )
        }
    }

    private func waitForProjectedCalendarDay(
        _ app: XCUIApplication,
        dayKey: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let query = app.buttons.matching(identifier: "reviewCalendar.day.\(dayKey)")
        let element = query.element(boundBy: 0)
        guard element.waitUntilExists(timeout: timeout) else { return false }
        return query.count == 1
    }

    private func assertEmptyDay(_ page: ReviewCalendarPage, label: String) throws {
        page.emptyDayDetail.assertExists(timeout: 5)
        page.selectedDay.assertExists(timeout: 5)
        page.emptyDaySummary.assertExists(timeout: 5)
        let value = try XCTUnwrap(
            page.emptyDaySummary.value as? String,
            "\(label) summary must expose an exact numeric accessibility value"
        )
        let actual = try XCTUnwrap(
            Int(value),
            "\(label) summary value must be an integer"
        )
        XCTAssertEqual(actual, 0, "\(label) must expose exact selected-day count zero")
    }

    @discardableResult
    private func assertPopulatedDay(
        _ page: ReviewCalendarPage,
        expectedCount: Int,
        label: String
    ) throws -> Int {
        page.populatedDayDetail.assertExists(timeout: 5)
        page.selectedDay.assertExists(timeout: 5)
        page.populatedDaySummary.assertExists(timeout: 5)
        let value = try XCTUnwrap(
            page.populatedDaySummary.value as? String,
            "\(label) summary must expose a numeric accessibility value"
        )
        let actual = try XCTUnwrap(
            Int(value),
            "\(label) summary value must be an integer"
        )
        XCTAssertEqual(actual, expectedCount, "\(label) must expose the selected day bucket count")
        return actual
    }

    private func assertManifestEvidenceMapping(_ evidence: DatasetDocument.EvidenceGroups) {
        XCTAssertEqual(evidence.required.map(\.stepLabel), ReviewCalendarEvidence.requiredLabels)
        XCTAssertEqual(evidence.counterexamples.map(\.stepLabel), ReviewCalendarEvidence.counterexampleLabels)
        let all = evidence.required + evidence.counterexamples
        XCTAssertEqual(all.count, Set(all.map(\.stepLabel)).count, "evidence labels must be unique")
        XCTAssertTrue(
            all.allSatisfy { $0.assetIDs.count == 1 },
            "each label maps to one logical asset ID"
        )
        XCTAssertEqual(all.count, Set(all.map { $0.assetIDs[0] }).count, "asset IDs must be one-to-one")
        XCTAssertEqual(
            Set(evidence.required.map { $0.assetIDs[0] }).intersection(Set(evidence.counterexamples.map { $0.assetIDs[0] })),
            [],
            "required/counterexample asset IDs must be disjoint"
        )
    }

    private func decodeDataset(_ data: Data) throws -> DatasetDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DatasetDocument.self, from: data)
    }

    private func assertClockProvenance(in app: XCUIApplication) {
        let canonical = app.descendants(matching: .any)
            .matching(identifier: ReviewCalendarClockSelector.canonical)
        let live = app.descendants(matching: .any)
            .matching(identifier: ReviewCalendarClockSelector.live)
        XCTAssertEqual(canonical.count, 1, "UI World must expose canonical history-plan clock provenance")
        XCTAssertEqual(live.count, 0, "UI World must not expose live Date() clock provenance")
    }

    private func captureEvidence(
        _ row: DatasetDocument.EvidenceAsset,
        group: String,
        app: XCUIApplication,
        datasetID: String,
        device: String,
        installedFixture: DatasetDocument.InstalledFixture
    ) throws -> DatasetDocument.GeneratedEvidence {
        XCTAssertEqual(row.assetIDs.count, 1, "evidence row must declare one logical asset ID")
        captureStep(row.stepLabel, app: app)

        guard let rawDirectory = ProcessInfo.processInfo.environment["KG_UI_TEST_SCREENSHOT_DIR"],
              !rawDirectory.isEmpty
        else {
            XCTFail("KG_UI_TEST_SCREENSHOT_DIR is required for generated evidence metadata")
            throw NSError(domain: "P9Evidence", code: 1)
        }
        let directory = URL(fileURLWithPath: rawDirectory)
        let safeLabel = row.stepLabel
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let artifacts = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            $0.pathExtension == "png" &&
            $0.deletingPathExtension().lastPathComponent.hasSuffix("-\(safeLabel)")
        } ?? []
        let artifact = try XCTUnwrap(
            artifacts.sorted { $0.lastPathComponent < $1.lastPathComponent }.last,
            "exactly one generated screenshot is required for \(row.stepLabel)"
        )
        XCTAssertEqual(artifacts.count, 1, "duplicate generated screenshot artifacts must fail")
        let bytes = try XCTUnwrap(fileByteCount(artifact), "generated screenshot must expose its byte size")
        let sha256 = try XCTUnwrap(fileSHA256(artifact), "generated screenshot must expose its SHA-256")
        return DatasetDocument.GeneratedEvidence(
            fixtureID: row.fixtureID,
            stepLabel: row.stepLabel,
            manifestAssetID: row.assetIDs[0],
            manifestPath: artifact.lastPathComponent,
            assetID: artifact.deletingPathExtension().lastPathComponent,
            artifactPath: relativePath(of: artifact, to: directory),
            bytes: bytes,
            sha256: sha256,
            type: "image/png",
            selector: ReviewCalendarEvidence.selector,
            source: ReviewCalendarEvidence.source,
            datasetID: datasetID,
            device: device,
            group: group,
            installedFixture: installedFixture
        )
    }

    private func assertGeneratedEvidence(
        _ evidence: DatasetDocument.EvidenceGroups,
        records: [DatasetDocument.GeneratedEvidence],
        datasetID: String,
        device: String,
        sourceCommit: String,
        datasetSHA256: String
    ) {
        let allRows = evidence.required + evidence.counterexamples
        XCTAssertEqual(records.count, allRows.count, "all manifest evidence rows must bind generated artifacts")
        XCTAssertEqual(Set(records.map(\.assetID)).count, records.count, "generated asset IDs must be unique")
        let required = Set(records.filter { $0.group == "required" }.map(\.assetID))
        let counterexamples = Set(records.filter { $0.group == "counterexamples" }.map(\.assetID))
        XCTAssertTrue(required.isDisjoint(with: counterexamples), "required/counterexample artifacts must be disjoint")

        let rowsByAssetID = Dictionary(uniqueKeysWithValues: (evidence.required + evidence.counterexamples).map {
            ($0.assetIDs[0], $0)
        })
        for record in records {
            guard let row = rowsByAssetID[record.manifestAssetID] else {
                XCTFail("generated evidence must reference a declared review manifest asset ID: \(record.manifestAssetID)")
                continue
            }
            XCTAssertEqual(record.fixtureID, row.fixtureID)
            XCTAssertEqual(record.stepLabel, row.stepLabel)
            XCTAssertEqual(record.datasetID, datasetID)
            XCTAssertEqual(record.device, device)
            XCTAssertEqual(record.selector, ReviewCalendarEvidence.selector)
            XCTAssertEqual(record.source, ReviewCalendarEvidence.source)
            XCTAssertEqual(record.type, "image/png")
            XCTAssertFalse(record.manifestPath.isEmpty)
            XCTAssertEqual(record.manifestPath, URL(fileURLWithPath: record.artifactPath).lastPathComponent)
            XCTAssertFalse(record.artifactPath.hasPrefix("/"), "artifactPath must be portable")
            XCTAssertGreaterThan(record.bytes, 0)
            XCTAssertEqual(record.installedFixture.datasetID, datasetID)
            XCTAssertGreaterThan(record.installedFixture.bytes, 0)
            XCTAssertEqual(record.installedFixture.type, "application/json")
            XCTAssertEqual(record.installedFixture.sourceCommit, sourceCommit)
            XCTAssertEqual(record.installedFixture.datasetSHA256, datasetSHA256)
            XCTAssertEqual(record.installedFixture, records[0].installedFixture)
        }

        let requiredLabelSet = Set(ReviewCalendarEvidence.requiredLabels)
        let counterexampleLabelSet = Set(ReviewCalendarEvidence.counterexampleLabels)
        XCTAssertEqual(
            requiredLabelSet.intersection(counterexampleLabelSet),
            [],
            "required/counterexample step labels must be disjoint"
        )
        XCTAssertEqual(
            requiredLabelSet.count,
            ReviewCalendarEvidence.requiredLabels.count,
            "required step labels must be unique"
        )
        XCTAssertEqual(
            counterexampleLabelSet.count,
            ReviewCalendarEvidence.counterexampleLabels.count,
            "counterexample step labels must be unique"
        )

        guard let rawDirectory = ProcessInfo.processInfo.environment["KG_UI_TEST_SCREENSHOT_DIR"],
              !rawDirectory.isEmpty
        else {
            XCTFail("KG_UI_TEST_SCREENSHOT_DIR is required for machine-verifiable UI World evidence")
            return
        }

        let directory = URL(fileURLWithPath: rawDirectory)
        let manifestURL = directory.appendingPathComponent("p9_review_calendar_review_manifest.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(DatasetDocument.GeneratedEvidenceFile(
                schema: "kg.p9.review_calendar.review_manifest.v2",
                sourceCommit: sourceCommit,
                datasetID: datasetID,
                datasetSHA256: datasetSHA256,
                device: device,
                selector: ReviewCalendarEvidence.selector,
                records: records
            ))
            try encoded.write(to: manifestURL)
            let consumer = try JSONDecoder().decode(
                DatasetDocument.GeneratedEvidenceFile.self,
                from: Data(contentsOf: manifestURL)
            )
            XCTAssertEqual(consumer.schema, "kg.p9.review_calendar.review_manifest.v2")
            XCTAssertEqual(consumer.sourceCommit, sourceCommit)
            XCTAssertEqual(consumer.datasetID, datasetID)
            XCTAssertEqual(consumer.datasetSHA256, datasetSHA256)
            XCTAssertEqual(consumer.device, device)
            XCTAssertEqual(consumer.selector, ReviewCalendarEvidence.selector)
            XCTAssertEqual(consumer.records.count, records.count)
            XCTAssertEqual(consumer.records.map(\.bytes), records.map(\.bytes))
            XCTAssertEqual(consumer.records.map(\.sha256), records.map(\.sha256))
            XCTAssertEqual(consumer.records.map(\.installedFixture), records.map(\.installedFixture))
        } catch {
            XCTFail("failed to write actual generated evidence metadata: \(error)")
        }

    }

    private func evidenceDevice() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["KG_UI_TEST_DEVICE_UDID", "SIMULATOR_UDID", "DEVICE_UDID"]
        guard let device = keys.lazy
            .compactMap({ environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else {
            XCTFail("UI evidence requires a concrete device identifier; run with --lease or --device")
            throw NSError(domain: "P9Evidence", code: 2)
        }
        return device
    }

    private func assertRuntimeGeometry(_ page: ReviewCalendarPage) {
        page.runtimeGeometry.assertExists(timeout: 5)
        XCTAssertGreaterThan(page.runtimeGeometry.frame.width, 0, "calendar runtime width must be positive")
        XCTAssertGreaterThan(page.runtimeGeometry.frame.height, 0, "calendar runtime height must be positive")
    }

    private func materializeInstalledFixture(
        from page: ReviewCalendarPage,
        datasetID: String,
        sourceCommit: String,
        datasetSHA256: String,
        expectedAppPath: String,
        retrievedPath: String,
        sourceData: Data
    ) throws -> DatasetDocument.InstalledFixture {
        let proof = try XCTUnwrap(
            page.installedFixtureProof.value as? String,
            "FixtureDatasetStore must expose the installed fixture proof"
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let appProof = try decoder.decode(DatasetDocument.InstalledFixture.self, from: Data(proof.utf8))
        XCTAssertEqual(appProof.datasetID, datasetID)
        XCTAssertEqual(appProof.path, expectedAppPath)
        XCTAssertEqual(appProof.type, "application/json")
        XCTAssertEqual(appProof.sourceCommit, sourceCommit)
        XCTAssertEqual(appProof.datasetSHA256, datasetSHA256)
        guard !appProof.path.hasPrefix("/"),
              appProof.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." })
        else {
            throw NSError(domain: "P9Evidence", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "installed proof path must be portable",
            ])
        }
        let canonicalObject = try JSONSerialization.jsonObject(with: sourceData, options: [.fragmentsAllowed])
        let canonicalData = try JSONSerialization.data(withJSONObject: canonicalObject, options: [.sortedKeys])
        XCTAssertEqual(appProof.bytes, canonicalData.count, "app proof bytes must describe canonical materialization")
        XCTAssertEqual(appProof.sha256, dataSHA256(canonicalData), "app proof hash must describe canonical materialization")
        return DatasetDocument.InstalledFixture(
            datasetID: datasetID,
            path: retrievedPath,
            bytes: appProof.bytes,
            sha256: appProof.sha256,
            type: appProof.type,
            sourceCommit: appProof.sourceCommit,
            datasetSHA256: appProof.datasetSHA256
        )
    }

    private func evidenceSourceCommit() throws -> String {
        guard let value = ProcessInfo.processInfo.environment["KG_UI_TEST_SOURCE_COMMIT"],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            XCTFail("P9 evidence requires the runner sourceCommit provenance")
            throw NSError(domain: "P9Evidence", code: 5)
        }
        return value
    }

    private func fileByteCount(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber
        else { return nil }
        return number.intValue
    }

    private func relativePath(of file: URL, to directory: URL) -> String {
        let root = directory.standardizedFileURL
        let path = file.standardizedFileURL
        guard path.path.hasPrefix(root.path + "/") else { return file.lastPathComponent }
        return String(path.path.dropFirst(root.path.count + 1))
    }

    private func fileSHA256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func dataSHA256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
