import Foundation
import SwiftData
import Testing
@testable import BooksAndVocab

@Suite("Settings sync lifecycle root cause", .serialized)
@MainActor
struct SettingsSyncLifecycleRootCauseTests {
    @Test("partial terminal feedback explains incomplete sync and retryable items")
    func partialTerminalFeedbackUsesDistinctLocalizedSemantics() throws {
        let source = try Self.settingsSyncLifecycleFeedbackSource()

        #expect(source.contains("case .partial"))
        #expect(source.contains("L10n.string(\"部分同步完成\")"))
        #expect(source.contains("L10n.string(\"部分項目未成功同步，可直接再次重試。\")"))
        #expect(source.contains(".accessibilityValue(Text(accessibilityValue))"))
        #expect(source.contains("dataOutcome: dataOutcome"))
    }

    @Test("terminal feedback keeps generic failure actions and survives panel collapse")
    func terminalFeedbackBoundariesRemainUnchanged() throws {
        let source = try Self.settingsSyncLifecycleFeedbackSource()

        #expect(source.contains("title: L10n.string(\"同步失敗\")"))
        #expect(source.contains("primaryIdentifier: \"settings.syncLifecycle.retryButton\""))
        #expect(source.contains("secondaryIdentifier: \"settings.syncLifecycle.dismissButton\""))
        #expect(source.contains(".accessibilityIdentifier(\"settings.syncLifecycle\")"))
        #expect(source.contains(".transition(.statusRowReveal)"))
    }

    @Test("fixture evidence rejects events from a prior account session")
    func fixtureEvidenceIsSessionScoped() {
        let oldSession = SettingsSyncFixtureEvidenceStore.shared.beginSession()
        SettingsSyncFixtureEvidenceStore.shared.record(
            sessionID: oldSession,
            round: 1,
            path: "/api/vocab",
            statusCode: 200
        )

        let newSession = SettingsSyncFixtureEvidenceStore.shared.beginSession()
        SettingsSyncFixtureEvidenceStore.shared.record(
            sessionID: oldSession,
            round: 2,
            path: "/api/vocab",
            statusCode: 200
        )
        SettingsSyncFixtureEvidenceStore.shared.record(
            sessionID: newSession,
            round: 1,
            path: "/api/vocab",
            statusCode: 200
        )

        #expect(
            SettingsSyncFixtureEvidenceStore.shared.snapshot() == [
                SettingsSyncTransportEvent(round: 1, path: "/api/vocab", statusCode: 200)
            ]
        )

        // A later coordinator/transport may be materialized by SwiftUI before
        // the live coordinator executes. Its session allocation must not erase
        // the live session's already-recorded events.
        _ = SettingsSyncFixtureEvidenceStore.shared.beginSession()
        #expect(SettingsSyncFixtureEvidenceStore.shared.snapshot().isEmpty)
        #expect(
            SettingsSyncFixtureEvidenceStore.shared.snapshot(sessionID: newSession) == [
                SettingsSyncTransportEvent(round: 1, path: "/api/vocab", statusCode: 200)
            ]
        )
    }

    private static func settingsSyncLifecycleFeedbackSource() throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BooksAndVocab/Views/Settings/SettingsSyncLifecycleFeedback.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    @Test("canonical sync summary accepts terminal error provenance")
    func canonicalSyncSummaryCarriesLifecycleMetadata() throws {
        let data = Data(#"""
        {
            "isConnected": true,
            "isSyncing": false,
            "summaryText": "Connected",
            "lastSyncedText": null,
            "lifecycle": "terminalError",
            "message": "sync failed",
            "attempt": 1,
            "dataOutcome": "partial"
        }
        """#.utf8)

        let summary = try JSONDecoder().decode(SettingsFixtureSeed.SyncSummary.self, from: data)
        #expect(summary.lifecycle == .terminalError)
        #expect(summary.message == "sync failed")
        #expect(summary.attempt == 1)
        #expect(summary.dataOutcome == .partial)
    }

    @Test("legacy sync summary without lifecycle metadata fails decoding")
    func legacySyncSummaryMissingMetadataFailsClosed() {
        let data = Data(#"""
        {
            "isConnected": true,
            "isSyncing": false,
            "summaryText": "Connected",
            "lastSyncedText": null
        }
        """#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SettingsFixtureSeed.SyncSummary.self, from: data)
        }
    }

    @Test("fixture JSON serialization failure is typed and never replaced with an empty object")
    func fixtureJSONSerializationFailureIsTyped() {
        do {
            _ = try SettingsSyncFixtureTransport.encodeJSONBody(
                path: "/api/vocab",
                object: ["error": Date()]
            )
            Issue.record("invalid fixture JSON object unexpectedly encoded")
        } catch let error as SettingsSyncFixtureTransportError {
            guard case let .jsonSerializationFailed(path, reason) = error else {
                Issue.record("unexpected fixture transport error: \(error)")
                return
            }
            #expect(path == "/api/vocab")
            #expect(!reason.isEmpty)
        } catch {
            Issue.record("fixture JSON failure escaped as an untyped error: \(error)")
        }
    }

    @Test("fixture accepts both real background-sync push legs")
    func fixturePushEndpointsReturnAccounting() async throws {
        let summary = try JSONDecoder().decode(
            SettingsFixtureSeed.SyncSummary.self,
            from: Data(#"""
            {
              "isConnected": true,
              "isSyncing": false,
              "summaryText": "Connected",
              "lastSyncedText": null,
              "lifecycle": "terminalError",
              "message": "sync failed",
              "attempt": 1,
              "dataOutcome": "partial"
            }
            """#.utf8))
        let transport = SettingsSyncFixtureTransport(summary: summary)

        var stateRequest = URLRequest(url: URL(string: "https://settings-fixture.invalid/api/vocab/review")!)
        stateRequest.httpMethod = "PATCH"
        stateRequest.httpBody = Data(#"{"entries":[{"word":"residual"}]}"#.utf8)
        let (stateData, stateResponse) = try await transport.data(for: stateRequest)
        #expect((stateResponse as? HTTPURLResponse)?.statusCode == 200)
        let stateAccounting = try #require(
            try JSONSerialization.jsonObject(with: stateData) as? [String: Int]
        )
        #expect(stateAccounting["updated"] == 0)
        #expect(stateAccounting["skipped"] == 1)

        var eventRequest = URLRequest(url: URL(string: "https://settings-fixture.invalid/api/vocab/review-events")!)
        eventRequest.httpMethod = "PATCH"
        eventRequest.httpBody = Data(#"{"entries":[{},{}]}"#.utf8)
        let (eventData, eventResponse) = try await transport.data(for: eventRequest)
        #expect((eventResponse as? HTTPURLResponse)?.statusCode == 200)
        let eventAccounting = try #require(
            try JSONSerialization.jsonObject(with: eventData) as? [String: Int]
        )
        #expect(eventAccounting["inserted"] == 0)
        #expect(eventAccounting["skipped"] == 2)
    }

    @Test("illegal lifecycle transitions throw instead of silently changing the state")
    func illegalTransitionsAreObservable() {
        var lifecycle = SettingsSyncLifecycle.idle
        #expect(throws: SettingsSyncLifecycle.TransitionError.self) {
            try lifecycle.transition(.succeed)
        }

        #expect(throws: SettingsSyncLifecycle.TransitionError.self) {
            try lifecycle.transition(.dismiss)
        }
    }

    @Test("cancel returns an in-flight round to idle")
    func cancellationIsAnExplicitTransition() throws {
        var lifecycle = SettingsSyncLifecycle.idle
        try lifecycle.transition(.begin)
        try lifecycle.transition(.cancel)
        #expect(lifecycle == .idle)
    }

    @Test("real backgroundSync preserves local data after a failed pull and succeeds on retry")
    func realServiceFailureThenRetryReadsSwiftDataResidual() async throws {
        let defaults = UserDefaults.standard
        let defaultKeys = [
            KGService.SyncKeys.incrementalBoundary,
            KGService.SyncKeys.payloadVersion,
            KGService.SyncKeys.lastSyncDate,
            KGService.SyncKeys.reviewEventPullBoundary
        ]
        let priorDefaults: [String: Any?] = Dictionary(uniqueKeysWithValues: defaultKeys.map {
            ($0, defaults.object(forKey: $0))
        })
        defer {
            for key in defaultKeys {
                if let stored = priorDefaults[key], let value = stored {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.removeObject(forKey: KGService.SyncKeys.incrementalBoundary)
        defaults.removeObject(forKey: KGService.SyncKeys.payloadVersion)
        let summary = try JSONDecoder().decode(
            SettingsFixtureSeed.SyncSummary.self,
            from: Data(#"""
            {
              "isConnected": true,
              "isSyncing": false,
              "summaryText": "Connected",
              "lastSyncedText": null,
              "lifecycle": "terminalError",
              "message": "sync failed",
              "attempt": 1,
              "dataOutcome": "partial"
            }
            """#.utf8))
        SettingsSyncFixtureEvidenceStore.shared.reset()
        let transport = SettingsSyncFixtureTransport(summary: summary)
        let service = KGService(
            authSession: TestAuthSession(),
            sessionInvalidator: TestSessionInvalidator(),
            transport: transport,
            connectivityGate: FixedConnectivityGate(isConnected: true)
        )
        let container = try Self.makeContainer()
        let residual = VocabularyEntry(
            word: "residual",
            translation: "residual",
            context: "residual",
            bookTitle: "Settings Sync Fixture"
        )
        residual.syncStatus = VocabularySyncState.synced.rawValue
        residual.kgCardId = "settings-residual"
        residual.reviewStateSyncedAt = residual.dateAdded
        container.mainContext.insert(residual)
        try container.mainContext.save()

        let first = await service.backgroundSync(container: container, progress: nil)
        #expect(first == .failed)
        let residualAfterFailure = try container.mainContext.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(residualAfterFailure.map(\.word) == ["residual"])

        let second = await service.backgroundSync(container: container, progress: nil)
        #expect(second == .completed)
        let entriesAfterRetry = try container.mainContext.fetch(FetchDescriptor<VocabularyEntry>())
        #expect(entriesAfterRetry.map(\.word).sorted() == ["complete", "residual"])
        let expectedTransportLedger = Array(
            repeating: SettingsSyncTransportEvent(
                round: 1,
                path: "/api/vocab",
                statusCode: 429
            ),
            count: 3
        ) + [
            SettingsSyncTransportEvent(
                round: 2,
                path: "/api/vocab",
                statusCode: 200
            )
        ]
        #expect(
            SettingsSyncFixtureEvidenceStore.shared.snapshot()
                == expectedTransportLedger
        )
    }

    @Test("main-context save failure is fail-closed")
    func saveFailureCannotBecomeTerminalSuccess() async throws {
        let service = CompletedSyncService()
        let coordinator = SettingsCoordinator(
            settingsSyncService: service,
            syncPersistence: FailingSyncPersistence(),
            translationLifecycle: NoopAccountPreferenceLifecycle()
        )
        let auth = TestAuthManager()
        let container = try Self.makeContainer()

        await coordinator.resync(
            authManager: auth,
            kgService: service,
            modelContext: container.mainContext
        )

        #expect(coordinator.syncLifecycle == .terminalError(message: L10n.string("同步失敗")))
        #expect(coordinator.syncProgress.phase == .failed)
        #expect(coordinator.syncDataOutcome == .partial)
        #expect(coordinator.syncEvidence?.perfMarks == [
            SettingsSyncPerfRecord(
                label: "settings.sync.lifecycle.started",
                detail: "attempt=1"
            ),
            SettingsSyncPerfRecord(
                label: "settings.sync.lifecycle.saveResult",
                detail: "attempt=1 result=failure"
            ),
            SettingsSyncPerfRecord(
                label: "settings.sync.lifecycle.serviceResult",
                detail: "attempt=1 result=saveFailure"
            ),
            SettingsSyncPerfRecord(
                label: "settings.sync.lifecycle.terminal",
                detail: "attempt=1 state=terminalError data=partial"
            )
        ])
    }

    private static func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: VocabularyEntry.self, ReviewRecord.self, Notebook.self,
            PodcastSeries.self, PodcastEpisode.self,
            configurations: configuration
        )
    }

    private final class TestAuthSession: AuthSessionProviding {
        let isLoggedIn = true
        let token: String? = "settings-sync-test-token"
    }

    private final class TestSessionInvalidator: SessionInvalidating {
        func logout(modelContainer: ModelContainer?, reason: String) {}
        func waitForPendingLocalDataCleanup() async {}
    }

    private final class TestAuthManager: AuthManaging {
        var isLoggedIn = true
        var userId: String? = "settings-sync-test-user"
        var token: String? = "settings-sync-test-token"
        var displayName: String?
        var userEmail: String?
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

    private struct SaveFailure: Error {}

    private final class FailingSyncPersistence: SettingsSyncPersisting {
        func save(container: ModelContainer) throws {
            throw SaveFailure()
        }
    }

    private final class CompletedSyncService: BackgroundSyncing, HealthChecking, QuotaServing {
        var lastBackgroundSyncError: String?

        func backgroundSync(container: ModelContainer) async {}

        @discardableResult
        func backgroundSync(
            container: ModelContainer,
            progress: SyncProgressReporting?
        ) async -> SyncRoundOutcome {
            .completed
        }

        func healthCheck() async {}
        func fetchQuota() async {}
    }

}
